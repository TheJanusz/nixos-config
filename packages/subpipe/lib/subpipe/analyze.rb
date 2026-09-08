# frozen_string_literal: true

require "json"
require "open3"
require "tempfile"
require "fileutils"
require "time"
require "socket"
require "net/http"
require "uri"
require "timeout"
require_relative "metrics"

module Subpipe
  # Per-cue delivery analysis: ffmpeg loudness + LLM labels → context.json.
  # Runs after merge, before translate. Same fields later drive lektor/TTS.
  #
  # Cue fields written:
  #   emotion, emotion_intensity (0..1), delivery, prosody { mean_db, max_db, duration_ms }
  #
  # Perf: one llama-server, HTTP keep-alive, batched cues, silence short-circuit.
  module Analyze
    module_function

    EMOTIONS = %w[
      neutral happy amused sad angry fearful surprised disgusted
    ].freeze

    DELIVERIES = %w[
      normal whisper shout laugh cry rushed slow
    ].freeze

    # Treat as non-speech → skip LLM (neutral/normal).
    SILENCE_MEAN_DB = -45.0
    SILENCE_MAX_DURATION_MS = 120
    SILENCE_MAX_TEXT_CHARS = 2

    DEFAULT_BATCH = 8

    SYSTEM_PROMPT = <<~PROMPT.freeze
      You label spoken subtitle cues for emotion and delivery style.
      Use the English text plus acoustic hints (loudness dB, duration).
      Pick emotion from: #{EMOTIONS.join(', ')}.
      Pick delivery from: #{DELIVERIES.join(', ')}.
      emotion_intensity is 0.0 (subtle) to 1.0 (extreme).
      Prefer neutral/normal when unsure. Do not invent speakers.

      You will receive a JSON object with a "cues" array (1 or more items).
      Reply with ONLY a JSON array with one object per cue, same ids, same order:
      [{"id":"<cue id>","emotion":"neutral","emotion_intensity":0.3,"delivery":"normal"}]
      No markdown, no commentary.
    PROMPT

    def run(out_dir, force: false, model: nil, llama_bin: nil)
      t0 = Metrics.monotonic
      out_dir = File.expand_path(out_dir)
      context = load_context!(out_dir)
      audio = resolve_audio!(out_dir, context)
      cues = Array(context["cues"])
      Subpipe.abort!("no cues in context.json") if cues.empty?

      analyzed = 0
      skipped = 0
      silence = 0
      total = cues.size
      tty = $stderr.tty?
      batch_size = ENV.fetch("SUBPIPE_ANALYZE_BATCH", DEFAULT_BATCH.to_s).to_i
      batch_size = DEFAULT_BATCH if batch_size < 1
      use_hook = ENV["SUBPIPE_ANALYZE_HOOK"].to_s.strip != ""
      en_words = 0
      llm_started = nil
      llm_elapsed = 0.0

      with_inference(model: model, server_bin: llama_bin, use_hook: use_hook) do |infer|
        llm_started = Metrics.monotonic
        pending = []

        flush = lambda do
          next if pending.empty?

          results = infer.call(pending)
          by_id = results.to_h { |r| [r["id"].to_s, r] }
          pending.each do |item|
            cue = item[:cue]
            result = by_id[cue["id"].to_s]
            Subpipe.abort!("analyze batch missing id #{cue['id']}") unless result
            apply_result!(cue, result)
            analyzed += 1
            en_words += Metrics.word_count(cue["text_en"])
            detail = "#{cue['emotion']}/#{cue['delivery']}  #{cue['emotion_intensity']}"
            progress_line!(tty, item[:n], total, cue["id"], detail)
          end
          pending.clear
        end

        cues.each_with_index do |cue, idx|
          n = idx + 1
          if !force && cue["emotion"] && !cue["emotion"].to_s.strip.empty?
            skipped += 1
            progress_line!(tty, n, total, cue["id"], "skip")
            next
          end

          prosody = measure_prosody(audio, cue)
          cue["prosody"] = prosody

          if silence_cue?(cue, prosody)
            apply_silence!(cue)
            silence += 1
            progress_line!(tty, n, total, cue["id"], "silence")
            next
          end

          pending << {
            cue: cue,
            n: n,
            prev: idx.positive? ? cues[idx - 1] : nil,
            nxt: cues[idx + 1],
            prosody: prosody
          }
          flush.call if pending.size >= batch_size
        end
        flush.call
      end
      llm_elapsed = Metrics.monotonic - llm_started if llm_started
      $stderr.print "\n" if tty

      context["future"] ||= {}
      context["future"]["analyze_applied_at"] = Time.now.utc.iso8601
      context["future"]["notes"] = [
        context.dig("future", "notes"),
        "Emotion/delivery from subpipe analyze; edit in review before translate/dub."
      ].compact.reject(&:empty?).uniq.join(" ")

      context["assets"] ||= {}
      context["assets"]["audio"] ||= File.basename(audio)

      path = File.join(out_dir, "context.json")
      File.write(path, JSON.pretty_generate(context))
      puts "Analyzed #{analyzed} cue(s), silence #{silence}, skipped #{skipped} → #{path}"

      total_s = Metrics.monotonic - t0
      rows = [
        ["wall time", Metrics.format_duration(total_s)],
        ["inference", Metrics.format_duration(llm_elapsed)],
        ["batch size", batch_size.to_s],
        ["cues", "#{analyzed} analyzed, #{skipped} skipped, #{silence} silence"]
      ]
      per_cue = Metrics.per_unit(llm_elapsed, analyzed, unit: "cue")
      rows << ["per cue", per_cue] if per_cue
      if en_words.positive?
        rows << ["EN words", en_words.to_s]
        per_w = Metrics.per_unit(llm_elapsed, en_words, unit: "word")
        rows << ["per EN word", per_w] if per_w
      end
      Metrics.print_report("Analyze", rows)
      context
    end

    def silence_cue?(cue, prosody)
      text = [cue["text_en"], cue["asr_text"]].compact.map { |t| t.to_s.strip }.reject(&:empty?).join(" ")
      short_text = text.length <= SILENCE_MAX_TEXT_CHARS
      tiny = prosody["duration_ms"].to_i <= SILENCE_MAX_DURATION_MS
      quiet = prosody["mean_db"] && prosody["mean_db"] <= SILENCE_MEAN_DB
      # Need acoustic silence (or tiny slice) AND little/no text.
      short_text && (quiet || tiny)
    end

    def apply_silence!(cue)
      cue["emotion"] = "neutral"
      cue["emotion_intensity"] = 0.0
      cue["delivery"] = "normal"
    end

    # Yields callable: pending_items → array of result hashes.
    def with_inference(model:, server_bin:, use_hook:)
      if use_hook
        hook = ENV["SUBPIPE_ANALYZE_HOOK"]
        yield(lambda do |pending|
          prompt = build_batch_prompt(pending)
          out, status = Open3.capture2(hook, stdin_data: prompt)
          Subpipe.abort!("analyze hook failed") unless status.success?
          parse_batch_json(out, pending.map { |p| p[:cue]["id"].to_s })
        end)
        return
      end

      model ||= ENV["SUBPIPE_TRANSLATE_MODEL"]
      Subpipe.abort!("no model; set SUBPIPE_TRANSLATE_MODEL") if model.nil? || model.empty?
      Subpipe.abort!("model not found: #{model}") unless File.file?(model)

      server = start_server!(model: model, server_bin: server_bin)
      old_int = Signal.trap("INT") do
        stop_server!(server)
        exit 130
      end
      old_term = Signal.trap("TERM") do
        stop_server!(server)
        exit 143
      end
      begin
        uri = URI(server[:base_url])
        Net::HTTP.start(uri.host, uri.port, open_timeout: 30, read_timeout: ENV.fetch("SUBPIPE_LLAMA_SERVER_TIMEOUT", "180").to_i) do |http|
          yield(lambda do |pending|
            prompt = build_batch_prompt(pending)
            ids = pending.map { |p| p[:cue]["id"].to_s }
            content = chat_complete(http, uri, prompt, max_tokens: [128 * pending.size, 256].max)
            parse_batch_json(content, ids)
          end)
        end
      ensure
        Signal.trap("INT", old_int || "DEFAULT")
        Signal.trap("TERM", old_term || "DEFAULT")
        stop_server!(server)
      end
    end

    def free_port
      TCPServer.open("127.0.0.1", 0) do |s|
        s.addr[1]
      end
    end

    def start_server!(model:, server_bin:)
      bin = ENV["SUBPIPE_LLAMA_SERVER_BIN"].to_s.strip
      bin = server_bin.to_s.strip if bin.empty? && server_bin && !server_bin.to_s.include?("llama-cli")
      bin = "llama-server" if bin.empty?
      port = ENV.fetch("SUBPIPE_LLAMA_SERVER_PORT", free_port.to_s).to_i
      host = "127.0.0.1"
      ngl = ENV.fetch("SUBPIPE_LLAMA_NGL", "99")
      log_path = File.join(Dir.tmpdir, "subpipe-llama-server-#{Process.pid}-#{port}.log")
      # Room for a small batch of cues + JSON reply.
      ctx = ENV.fetch("SUBPIPE_ANALYZE_CTX", "4096")
      cmd = [
        bin,
        "-m", model,
        "--host", host,
        "--port", port.to_s,
        "-c", ctx,
        "-n", "512",
        "-ngl", ngl,
        "--log-disable"
      ]
      warn "Starting #{bin} on #{host}:#{port} (#{File.basename(model)}) …"
      pid = spawn(*cmd, out: log_path, err: log_path)
      server = { pid: pid, host: host, port: port, base_url: "http://#{host}:#{port}", log_path: log_path }
      wait_until_ready!(server)
      warn "llama-server ready at #{server[:base_url]}"
      server
    end

    def wait_until_ready!(server)
      deadline = Time.now + ENV.fetch("SUBPIPE_LLAMA_SERVER_TIMEOUT", "180").to_i
      health = URI("#{server[:base_url]}/health")
      models = URI("#{server[:base_url]}/v1/models")
      loop do
        begin
          if Process.waitpid(server[:pid], Process::WNOHANG)
            Subpipe.abort!("llama-server exited before ready\n#{read_server_log(server)}")
          end
        rescue Errno::ECHILD
          Subpipe.abort!("llama-server process missing")
        end

        begin
          res = Net::HTTP.get_response(health)
          return if res.is_a?(Net::HTTPSuccess)

          res = Net::HTTP.get_response(models)
          return if res.is_a?(Net::HTTPSuccess)
        rescue Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EHOSTUNREACH, EOFError, Net::OpenTimeout, Net::ReadTimeout
          # still starting
        end

        if Time.now > deadline
          stop_server!(server)
          Subpipe.abort!("timed out waiting for llama-server\n#{read_server_log(server)}")
        end
        sleep 0.25
      end
    end

    def read_server_log(server)
      path = server && server[:log_path]
      return "" if path.nil? || !File.file?(path)

      File.read(path).to_s[-2000, 2000].to_s
    rescue StandardError
      ""
    end

    def stop_server!(server)
      return if server.nil? || server[:stopped]

      server[:stopped] = true
      pid = server[:pid]
      begin
        Process.kill("TERM", pid)
      rescue Errno::ESRCH
        cleanup_server_log!(server)
        return
      end
      begin
        Timeout.timeout(15) { Process.wait(pid) }
      rescue Timeout::Error
        begin
          Process.kill("KILL", pid)
          Process.wait(pid)
        rescue Errno::ESRCH, Errno::ECHILD
        end
      rescue Errno::ECHILD
      end
      cleanup_server_log!(server)
    end

    def cleanup_server_log!(server)
      path = server && server[:log_path]
      File.delete(path) if path && File.file?(path) && !ENV["SUBPIPE_VERBOSE"]
    rescue StandardError
      nil
    end

    def chat_complete(http, base_uri, user_prompt, max_tokens: 256)
      path = "#{base_uri.path}/v1/chat/completions".gsub(%r{//+}, "/")
      path = "/v1/chat/completions" if base_uri.path.nil? || base_uri.path.empty? || base_uri.path == "/"
      body = {
        "messages" => [
          { "role" => "system", "content" => SYSTEM_PROMPT },
          { "role" => "user", "content" => user_prompt }
        ],
        "temperature" => 0.1,
        "max_tokens" => max_tokens,
        "stream" => false
      }
      req = Net::HTTP::Post.new(path)
      req["Content-Type"] = "application/json"
      req["Connection"] = "keep-alive"
      req.body = JSON.generate(body)
      res = http.request(req)
      unless res.is_a?(Net::HTTPSuccess)
        Subpipe.abort!("llama-server chat failed HTTP #{res.code}: #{res.body.to_s[0, 1000]}")
      end
      data = JSON.parse(res.body)
      content = data.dig("choices", 0, "message", "content").to_s
      content = data.dig("choices", 0, "text").to_s if content.empty?
      Subpipe.abort!("llama-server returned empty content") if content.strip.empty?

      content
    rescue JSON::ParserError => e
      Subpipe.abort!("invalid llama-server JSON: #{e.message}")
    end

    def progress_line!(tty, n, total, cue_id, detail)
      msg = format("analyze %d/%d  %s  %s", n, total, cue_id, detail)
      if tty
        width = [80, msg.length + 4].max
        $stderr.print "\r#{msg.ljust(width)}"
        $stderr.flush
      else
        warn msg
      end
    end

    def load_context!(out_dir)
      path = File.join(out_dir, "context.json")
      Subpipe.abort!("missing #{path}; run merge first") unless File.file?(path)
      JSON.parse(File.read(path))
    end

    def resolve_audio!(out_dir, context)
      rel = context.dig("assets", "audio") || "audio.wav"
      path = File.join(out_dir, rel)
      Subpipe.abort!("missing #{path}; run extract first") unless File.file?(path)
      path
    end

    def measure_prosody(audio_path, cue)
      start_ms = cue["start_ms"].to_i
      end_ms = cue["end_ms"].to_i
      end_ms = start_ms + 500 if end_ms <= start_ms
      duration_ms = end_ms - start_ms
      start_s = start_ms / 1000.0
      dur_s = [duration_ms / 1000.0, 0.05].max

      cmd = [
        "ffmpeg", "-hide_banner", "-nostats",
        "-ss", format("%.3f", start_s),
        "-t", format("%.3f", dur_s),
        "-i", audio_path,
        "-af", "volumedetect",
        "-f", "null", "-"
      ]
      _out, err, status = Open3.capture3(*cmd)
      mean_db = nil
      max_db = nil
      if status.success?
        err.to_s.each_line do |line|
          mean_db = Regexp.last_match(1).to_f if line =~ /mean_volume:\s*([-\d.]+)\s*dB/
          max_db = Regexp.last_match(1).to_f if line =~ /max_volume:\s*([-\d.]+)\s*dB/
        end
      else
        warn "volumedetect failed for #{cue['id']}: #{err.to_s.lines.last}" if ENV["SUBPIPE_VERBOSE"]
      end

      {
        "duration_ms" => duration_ms,
        "mean_db" => mean_db,
        "max_db" => max_db
      }
    end

    def build_batch_prompt(pending)
      cues = pending.map do |item|
        cue = item[:cue]
        prev_cue = item[:prev]
        next_cue = item[:nxt]
        {
          "id" => cue["id"],
          "text_en" => cue["text_en"],
          "asr_text" => cue["asr_text"],
          "prosody" => item[:prosody],
          "previous" => prev_cue && { "id" => prev_cue["id"], "text_en" => prev_cue["text_en"] },
          "next" => next_cue && { "id" => next_cue["id"], "text_en" => next_cue["text_en"] }
        }.compact
      end
      payload = { "cues" => cues }
      "Label emotion and delivery for each cue.\n#{JSON.generate(payload)}"
    end

    def apply_result!(cue, result)
      emotion = result["emotion"].to_s.strip.downcase
      emotion = "neutral" unless EMOTIONS.include?(emotion)
      delivery = result["delivery"].to_s.strip.downcase
      delivery = "normal" unless DELIVERIES.include?(delivery)
      intensity = result["emotion_intensity"]
      intensity =
        begin
          f = Float(intensity)
          [[f, 0.0].max, 1.0].min.round(3)
        rescue ArgumentError, TypeError
          0.3
        end

      cue["emotion"] = emotion
      cue["emotion_intensity"] = intensity
      cue["delivery"] = delivery
    end

    def parse_batch_json(raw, expected_ids)
      text = raw.to_s
      # Prefer a top-level JSON array of label objects.
      arrays = extract_json_arrays(text)
      parsed_list = arrays.reverse.filter_map do |blob|
        JSON.parse(blob)
      rescue JSON::ParserError
        nil
      end.find { |a| a.is_a?(Array) && a.any? { |h| h.is_a?(Hash) && h.key?("emotion") } }

      unless parsed_list
        # Fallback: gather individual objects with emotion.
        objects = extract_json_objects(text).filter_map do |blob|
          JSON.parse(blob)
        rescue JSON::ParserError
          nil
        end.select { |h| h.is_a?(Hash) && h.key?("emotion") }
        parsed_list = objects unless objects.empty?
      end

      Subpipe.abort!("failed to parse analyze batch JSON\n---\n#{text[0, 2000]}") if parsed_list.nil? || parsed_list.empty?

      by_id = parsed_list.to_h { |h| [h["id"].to_s, h] }
      expected_ids.map do |id|
        h = by_id[id]
        # If model omitted ids but returned same length, zip by order.
        if h.nil? && parsed_list.size == expected_ids.size
          h = parsed_list[expected_ids.index(id)]
          h = h.merge("id" => id) if h.is_a?(Hash)
        end
        Subpipe.abort!("analyze batch missing cue id #{id}") unless h.is_a?(Hash)

        h
      end
    end

    def extract_json_arrays(text)
      arrays = []
      i = 0
      while (start = text.index("[", i))
        depth = 0
        in_str = false
        escape = false
        closed = false
        (start...text.length).each do |j|
          ch = text[j]
          if in_str
            if escape
              escape = false
            elsif ch == "\\"
              escape = true
            elsif ch == '"'
              in_str = false
            end
            next
          end

          case ch
          when '"'
            in_str = true
          when "["
            depth += 1
          when "]"
            depth -= 1
            if depth.zero?
              arrays << text[start..j]
              i = j + 1
              closed = true
              break
            end
          end
        end
        i = start + 1 unless closed
      end
      arrays
    end

    def extract_json_objects(text)
      objects = []
      i = 0
      while (start = text.index("{", i))
        depth = 0
        in_str = false
        escape = false
        closed = false
        (start...text.length).each do |j|
          ch = text[j]
          if in_str
            if escape
              escape = false
            elsif ch == "\\"
              escape = true
            elsif ch == '"'
              in_str = false
            end
            next
          end

          case ch
          when '"'
            in_str = true
          when "{"
            depth += 1
          when "}"
            depth -= 1
            if depth.zero?
              objects << text[start..j]
              i = j + 1
              closed = true
              break
            end
          end
        end
        i = start + 1 unless closed
      end
      objects
    end
  end
end
