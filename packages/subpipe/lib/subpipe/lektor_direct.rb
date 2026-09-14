# frozen_string_literal: true

require "json"
require "open3"
require "fileutils"
require "time"
require "socket"
require "net/http"
require "uri"
require "timeout"
require "tmpdir"
require_relative "metrics"

module Subpipe
  # Optional re-pass: reshape existing text_pl for speakable TV-lektor (same field
  # for subtitle + Orpheus). Primary path is unified translate; use this after
  # heavy manual edits without EN→PL again.
  #
  # Writes cue["text_pl"], clears lektor_line, refreshes pl.ass.
  # Skip: empty text_pl / silence cues only (rewrites all speakable cues).
  module LektorDirect
    module_function

    DEFAULT_BATCH = 6

    SYSTEM_PROMPT = <<~PROMPT.freeze
      You are a Polish TV lektor director. Rewrite each cue's text_pl in place.
      The result is BOTH the on-screen subtitle and the Orpheus narration
      (same wording and punctuation).

      Goals:
      - Keep meaning and Polish; do not invent facts or change names/terms.
      - Prefer concise, flowing phrasing over stiff or wordy lines.
      - Warm TV-lektor tone: slight emotion from the tags — not dry documentary,
        not stage acting or cartoon exaggeration.
      - Shape breath groups: use … and — for natural pauses where delivery needs it
        (hesitation, weight, rush breaks). Prefer shorter phrases over long run-ons.
      - Match intensity: low intensity → subtle punctuation only; high → clearer pauses.
      - delivery hints: whisper → softer/shorter; shout → punchier; rushed → tighter;
        slow → more … / —; laugh/cry → light rhythm, still narratable aloud.
      - No SSML, no markdown, no English tags like <laugh>, no stage directions,
        no quotes around the whole line, no commentary.

      You receive JSON with a "cues" array. Reply with ONLY a JSON array, same ids/order:
      [{"id":"<cue id>","text_pl":"..."}]
    PROMPT

    def run(out_dir, force: false, model: nil, llama_bin: nil)
      t0 = Metrics.monotonic
      out_dir = File.expand_path(out_dir)
      context = load_context!(out_dir)
      cues = Array(context["cues"])
      Subpipe.abort!("no cues in context.json") if cues.empty?

      directed = 0
      skipped = 0
      silence = 0
      total = cues.size
      tty = $stderr.tty?
      batch_size = ENV.fetch("SUBPIPE_LEKTOR_DIRECT_BATCH", DEFAULT_BATCH.to_s).to_i
      batch_size = DEFAULT_BATCH if batch_size < 1
      use_hook = ENV["SUBPIPE_LEKTOR_DIRECT_HOOK"].to_s.strip != ""
      pl_words = 0
      llm_started = nil
      llm_elapsed = 0.0

      # force: rewrite even when lektor_directed_at is set (incremental re-runs).
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
            Subpipe.abort!("lektor direct batch missing id #{cue['id']}") unless result
            line = sanitize_line(result["text_pl"] || result["lektor_line"], fallback: item[:text_pl])
            cue["text_pl"] = line
            cue["lektor_line"] = nil
            cue["lektor_directed_at"] = Time.now.utc.iso8601
            # Direct becomes the mentor baseline (not a human edit vs translate).
            cue["text_pl_model"] = line
            cue["pl_accepted_at"] = nil
            directed += 1
            pl_words += Metrics.word_count(line)
            preview = line.length > 48 ? "#{line[0, 45]}…" : line
            progress_line!(tty, item[:n], total, cue["id"], preview)
          end
          pending.clear
        end

        cues.each_with_index do |cue, idx|
          n = idx + 1
          text_pl = cue["text_pl"].to_s.strip

          if text_pl.empty? || Lektor.silence_cue?(cue)
            silence += 1
            progress_line!(tty, n, total, cue["id"], "silence")
            next
          end

          if !force && cue["lektor_directed_at"] && !cue["lektor_directed_at"].to_s.strip.empty?
            skipped += 1
            progress_line!(tty, n, total, cue["id"], "skip")
            next
          end

          pending << {
            cue: cue,
            n: n,
            text_pl: text_pl,
            prev: idx.positive? ? cues[idx - 1] : nil,
            nxt: cues[idx + 1]
          }
          flush.call if pending.size >= batch_size
        end
        flush.call
      end
      llm_elapsed = Metrics.monotonic - llm_started if llm_started
      $stderr.print "\n" if tty

      context["future"] ||= {}
      context["future"]["lektor_direct_applied_at"] = Time.now.utc.iso8601
      context["future"]["notes"] = [
        context.dig("future", "notes"),
        "text_pl re-shaped by subpipe lektor direct (subtitle = lektor); edit in TUI (e)."
      ].compact.reject(&:empty?).uniq.join(" ")

      path = File.join(out_dir, "context.json")
      File.write(path, JSON.pretty_generate(context))

      stem = Subpipe.source_stem(context["source"] || {})
      ass_path = Subpipe.ass_path(out_dir, stem, "pl")
      Ass.write(
        ass_path,
        context["cues"],
        title: "#{context.dig('source', 'basename') || 'subpipe'} (pl)",
        text_key: "text_pl"
      )
      context["assets"] ||= {}
      context["assets"]["pl_ass"] = File.basename(ass_path)
      File.write(path, JSON.pretty_generate(context))

      puts "Directed #{directed} cue(s), silence #{silence}, skipped #{skipped} → #{path}, #{ass_path}"

      total_s = Metrics.monotonic - t0
      rows = [
        ["wall time", "#{Metrics.format_duration(total_s)}  (inference window #{Metrics.format_duration(llm_elapsed)})"],
        ["batch size", batch_size.to_s],
        ["cues", "#{directed} directed, #{skipped} skipped, #{silence} silence"]
      ]
      per_cue = Metrics.per_unit(llm_elapsed, directed, unit: "cue")
      rows << ["per cue", "#{per_cue} (inference / directed cue)"] if per_cue
      if pl_words.positive? && llm_elapsed.positive?
        rows << ["per PL word", "#{format('%.3fs', llm_elapsed / pl_words)}  (#{pl_words} PL words)"]
      elsif pl_words.positive?
        rows << ["PL words", pl_words.to_s]
      end
      Metrics.print_report("Lektor direct", rows)
    end

    def with_inference(model:, server_bin:, use_hook:)
      if use_hook
        hook = ENV["SUBPIPE_LEKTOR_DIRECT_HOOK"]
        yield(lambda do |pending|
          prompt = build_batch_prompt(pending)
          out, status = Open3.capture2(hook, stdin_data: prompt)
          Subpipe.abort!("lektor direct hook failed") unless status.success?
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
        timeout = ENV.fetch("SUBPIPE_LLAMA_SERVER_TIMEOUT", "180").to_i
        Net::HTTP.start(uri.host, uri.port, open_timeout: 30, read_timeout: timeout) do |http|
          yield(lambda do |pending|
            prompt = build_batch_prompt(pending)
            ids = pending.map { |p| p[:cue]["id"].to_s }
            content = chat_complete(http, uri, prompt, max_tokens: [192 * pending.size, 768].max)
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
      ctx = ENV.fetch("SUBPIPE_LEKTOR_DIRECT_CTX", "4096")
      parallel = ENV.fetch("SUBPIPE_LEKTOR_DIRECT_PARALLEL", "1")
      cmd = [
        bin,
        "-m", model,
        "--host", host,
        "--port", port.to_s,
        "-c", ctx,
        "-np", parallel,
        "-n", "1024",
        "-ngl", ngl
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

      text = File.read(path).to_s
      text.length > 2000 ? text[-2000..] : text
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

    def chat_complete(http, base_uri, user_prompt, max_tokens: 512)
      path = "#{base_uri.path}/v1/chat/completions".gsub(%r{//+}, "/")
      path = "/v1/chat/completions" if base_uri.path.nil? || base_uri.path.empty? || base_uri.path == "/"
      body = {
        "messages" => [
          { "role" => "system", "content" => SYSTEM_PROMPT },
          { "role" => "user", "content" => user_prompt }
        ],
        "temperature" => 0.25,
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
      msg = format("lektor direct %d/%d  %s  %s", n, total, cue_id, detail)
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
      Subpipe.abort!("missing #{path}; run translate first") unless File.file?(path)
      JSON.parse(File.read(path))
    end

    def build_batch_prompt(pending)
      cues = pending.map do |item|
        cue = item[:cue]
        prev_cue = item[:prev]
        next_cue = item[:nxt]
        {
          "id" => cue["id"],
          "text_pl" => item[:text_pl],
          "text_en" => cue["text_en"],
          "emotion" => cue["emotion"] || "neutral",
          "emotion_intensity" => cue["emotion_intensity"].nil? ? 0.3 : cue["emotion_intensity"],
          "delivery" => cue["delivery"] || "normal",
          "previous" => prev_cue && {
            "id" => prev_cue["id"],
            "text_pl" => prev_cue["text_pl"] || prev_cue["lektor_line"]
          },
          "next" => next_cue && {
            "id" => next_cue["id"],
            "text_pl" => next_cue["text_pl"] || next_cue["lektor_line"]
          }
        }.compact
      end
      "Rewrite each cue's text_pl for speakable TV-lektor (subtitle = narration).\n#{JSON.generate({ 'cues' => cues })}"
    end

    def sanitize_line(raw, fallback:)
      line = raw.to_s.strip
      line = line.gsub(/\A```(?:json)?\s*/i, "").gsub(/\s*```\z/, "").strip
      line = line.gsub(/\A["'«»„"]+|["'«»„"]+\z/, "").strip
      line = fallback.to_s.strip if line.empty?
      max = Lektor::MAX_CHARS
      if line.length > max
        cut = line[0, max]
        sp = cut.rindex(/\s/)
        line = (sp && sp > max * 0.6 ? cut[0, sp] : cut).rstrip
        line = "#{line}…" unless line.end_with?("…", ".", "!", "?")
      end
      line
    end

    def parse_batch_json(raw, expected_ids)
      text = raw.to_s
      line_key = lambda { |h| h.is_a?(Hash) && (h.key?("text_pl") || h.key?("lektor_line")) }
      arrays = extract_json_arrays(text)
      parsed_list = arrays.reverse.filter_map do |blob|
        JSON.parse(blob)
      rescue JSON::ParserError
        nil
      end.find { |a| a.is_a?(Array) && a.any? { |h| line_key.call(h) } }

      unless parsed_list
        objects = extract_json_objects(text).filter_map do |blob|
          JSON.parse(blob)
        rescue JSON::ParserError
          nil
        end.select { |h| line_key.call(h) }
        parsed_list = objects unless objects.empty?
      end

      Subpipe.abort!("failed to parse lektor direct batch JSON\n---\n#{text[0, 2000]}") if parsed_list.nil? || parsed_list.empty?

      by_id = parsed_list.to_h { |h| [h["id"].to_s, h] }
      expected_ids.map do |id|
        h = by_id[id]
        if h.nil? && parsed_list.size == expected_ids.size
          h = parsed_list[expected_ids.index(id)]
          h = h.merge("id" => id) if h.is_a?(Hash)
        end
        Subpipe.abort!("lektor direct batch missing cue id #{id}") unless h.is_a?(Hash)

        h
      end
    end

    def extract_json_arrays(text)
      arrays = []
      i = 0
      while (start = text.index("[", i))
        depth = 0
        j = start
        while j < text.length
          c = text[j]
          if c == "["
            depth += 1
          elsif c == "]"
            depth -= 1
            if depth.zero?
              arrays << text[start..j]
              break
            end
          elsif c == '"'
            j += 1
            while j < text.length
              break if text[j] == '"' && text[j - 1] != "\\"

              j += 1
            end
          end
          j += 1
        end
        i = start + 1
      end
      arrays
    end

    def extract_json_objects(text)
      objects = []
      i = 0
      while (start = text.index("{", i))
        depth = 0
        j = start
        while j < text.length
          c = text[j]
          if c == "{"
            depth += 1
          elsif c == "}"
            depth -= 1
            if depth.zero?
              objects << text[start..j]
              break
            end
          elsif c == '"'
            j += 1
            while j < text.length
              break if text[j] == '"' && text[j - 1] != "\\"

              j += 1
            end
          end
          j += 1
        end
        i = start + 1
      end
      objects
    end
  end
end
