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
require "set"
require_relative "ass"
require_relative "vocab"
require_relative "metrics"
require_relative "feedback"

module Subpipe
  # EN→PL draft via llama-server (keep-alive) + optional cue batches.
  # Perf: one server, HTTP reuse, skip silence, batch via SUBPIPE_TRANSLATE_BATCH.
  module Translate
    module_function

    SYSTEM_PROMPT = <<~PROMPT.freeze
      You translate English video subtitles into Polish that is BOTH the on-screen
      subtitle and the TV-lektor narration (same text_pl for both; same punctuation).

      Goals, in order:
      1. Clear meaning and tone a Polish viewer would actually say aloud.
      2. Idiomatic, concise, flowing Polish — prefer natural rephrase over calques.
      3. Fit the cue's timing: if duration is short or the English is dense, compress —
         convey the sense in a shorter sentence; do not translate every word.
      4. Respect the glossary and proper nouns.
      5. Shape for Orpheus TTS / warm TV lektor: slight emotion from tags — not dry
         documentary, not stage acting. Prefer shorter breath groups over long run-ons.

      Glossary rules:
      - If preferred_translations (a list) is given, pick exactly one of those Polish
        lemmas/canonical forms for that English term — best fit for this cue; do not
        invent a synonym or different wording.
        Each list item is one alternative (e.g. ["samochód","auto"]), never paste the whole list.
      - You MAY inflect that chosen form for Polish case/number/gender so the sentence is
        grammatical (e.g. lemma "Fani Czterech Kółek" → "w Fanach Czterech Kółek").
      - If a single preferred_translation is given, you MUST use that lemma (inflected as needed),
        not a different translation of the English term.
      - If avoid_pl is given, never use those Polish words for that term.
      - keep_english terms stay in English in the Polish line.
      - Honour glossary notes (e.g. grammatical gender: Syrena → rzadka, not rzadki;
        show references: EN "on/in Title" → natural PL framing, often "w" + locative,
        not a calque "na" + nominative).
      - For TV/show titles used as the setting ("on Wheeler Dealers", "in the show"),
        prefer idiomatic Polish (typically "w" + declined title), not word-for-word "na …".

      Style / direction (keep these marks in text_pl — they appear on screen too):
      - Use … and — for natural pauses/breaths when emotion or delivery needs them.
      - Match intensity: low → subtle punctuation; high → clearer pauses.
      - delivery: whisper → softer/shorter; shout → punchier; rushed → tighter;
        slow → more … / —; laugh/cry → light rhythm, still narratable aloud.
      - When emotion / emotion_intensity / delivery are present, gently reflect them
        in wording and register — do not exaggerate or add stage directions.
        Examples: angry → sharper; amused → lighter; whisper → softer; shout → blunt/short.
      - No SSML, markdown, English tags like <laugh>, stage directions, or wrapping quotes.
      - Drop filler and redundant clauses if needed to stay speakable at a natural pace.

      Also flag specialized language in the English cue for human review:
      - names: people, places, brands, model names, titles
      - jargon: slang, technical, or domain-specific terms
      - keep_english: terms that should stay in English in the Polish subtitle

      You will receive a JSON object with a "cues" array (1 or more items).
      Reply with ONLY a JSON array with one object per cue, same ids, same order:
      [{"id":"<cue id>","text_pl":"<Polish for subtitle and lektor>","names":[],"jargon":[],"keep_english":[]}]
      Arrays may be empty. No markdown, no commentary.
    PROMPT

    # Offline only: no web/RAG. Domain terms (cars, etc.) must already be in
    # context.json glossary — see modules/home/subtitling.nix "Future: specialized terminology".

    # Kept for documentation; grammar/json-schema not passed to the server.
    JSON_SCHEMA = {
      "type" => "object",
      "properties" => {
        "id" => { "type" => "string" },
        "text_pl" => { "type" => "string" },
        "names" => { "type" => "array", "items" => { "type" => "string" } },
        "jargon" => { "type" => "array", "items" => { "type" => "string" } },
        "keep_english" => { "type" => "array", "items" => { "type" => "string" } }
      },
      "required" => %w[id text_pl names jargon keep_english],
      "additionalProperties" => false
    }.freeze

    SKIP_NAME_WORDS = %w[
      I I\'m I\'ve I\'ll I\'d OK A The An And Or But So If We You He She They It
      This That These Those My Your His Her Our Their
    ].freeze

    # Skip LLM when there is nothing meaningful to translate.
    SILENCE_MAX_TEXT_CHARS = 2
    SILENCE_MEAN_DB = -45.0
    SILENCE_MAX_DURATION_MS = 120

    DEFAULT_BATCH = 2

    def run(out_dir, mode: "auto", force: false, model: nil, llama_bin: nil, vocab_path: nil)
      case mode.to_s
      when "auto"
        draft = generate_draft(out_dir, force: force, model: model, llama_bin: llama_bin, vocab_path: vocab_path)
        write_draft_files!(out_dir, draft)
        apply_draft!(out_dir, draft)
      when "draft"
        draft = generate_draft(out_dir, force: force, model: model, llama_bin: llama_bin, vocab_path: vocab_path)
        write_draft_files!(out_dir, draft)
        flagged = draft.fetch("translations").count { |t| t["needs_review"] }
        puts "Draft written (#{flagged} cue(s) flagged for names/jargon). Edit #{File.join(out_dir, 'translation-draft.json')} then: subpipe translate -o #{out_dir} --mode apply"
      when "apply"
        draft_path = File.join(out_dir, "translation-draft.json")
        Subpipe.abort!("missing #{draft_path}; run --mode draft first") unless File.file?(draft_path)
        draft = JSON.parse(File.read(draft_path))
        apply_draft!(out_dir, draft)
      else
        Subpipe.abort!("unknown translate mode: #{mode} (use auto|draft|apply)")
      end
    end

    def generate_draft(out_dir, force: false, model: nil, llama_bin: nil, vocab_path: nil, only_ids: nil)
      t0 = Metrics.monotonic
      context = load_context!(out_dir)
      cues = context.fetch("cues")
      only_set = only_ids && Array(only_ids).map(&:to_s).reject(&:empty?).uniq.to_set
      video_path = context.dig("source", "path")
      stem = Subpipe.source_stem(context["source"] || {})
      start_dir = if video_path && File.directory?(File.dirname(video_path))
                    File.dirname(video_path)
                  else
                    out_dir
                  end
      show_store, vocab_files = Vocab.load_effective(
        start_dir: start_dir,
        stem: stem,
        video_path: video_path,
        explicit: vocab_path
      )
      vocab_meta = Vocab.asset_meta(
        start_dir: start_dir,
        stem: stem,
        video_path: video_path,
        explicit: vocab_path
      )
      glossary = Vocab.merge_into_glossary(Array(context["glossary"]), show_store)
      # Persist merged glossary so promote/review see show prefs
      context["glossary"] = glossary
      context["assets"] ||= {}
      context["assets"].merge!(vocab_meta)
      File.write(File.join(out_dir, "context.json"), JSON.pretty_generate(context))
      warn "Vocab files: #{vocab_files.join(', ')}" unless vocab_files.empty?
      warn "Retranslating cue ids: #{only_set.to_a.join(', ')}" if only_set

      batch_size = ENV.fetch("SUBPIPE_TRANSLATE_BATCH", DEFAULT_BATCH.to_s).to_i
      batch_size = DEFAULT_BATCH if batch_size < 1
      use_hook = ENV["SUBPIPE_TRANSLATE_HOOK"].to_s.strip != ""

      translations = []
      translated_pl = {}
      translated = 0
      skipped = 0
      silence = 0
      pending = []
      en_words_llm = 0
      en_chars_llm = 0
      pl_words_llm = 0
      pl_chars_llm = 0
      llm_started = nil
      llm_elapsed = 0.0

      with_inference(model: model, server_bin: llama_bin, use_hook: use_hook) do |infer|
        llm_started = Metrics.monotonic
        flush = lambda do
          next if pending.empty?

          results = infer.call(pending)
          pending.each_with_index do |item, i|
            cue = item[:cue]
            result = results[i]
            Subpipe.abort!("translate batch missing id #{cue['id']}") unless result
            result = normalize_result(result)
            text_pl = result["text_pl"].to_s.strip
            Subpipe.abort!("empty translation for #{cue['id']}") if text_pl.empty?
            flags = normalize_flags(
              names: result["names"],
              jargon: result["jargon"],
              keep_english: result["keep_english"],
              cue: cue,
              glossary: glossary
            )
            translations << entry_for(cue, text_pl, flags, skipped: false)
            translated_pl[cue["id"].to_s] = text_pl
            translated += 1
            en = cue["text_en"].to_s
            en_words_llm += Metrics.word_count(en)
            en_chars_llm += Metrics.char_count(en)
            pl_words_llm += Metrics.word_count(text_pl)
            pl_chars_llm += Metrics.char_count(text_pl)
            warn "translated #{cue['id']}: #{cue['text_en'].inspect} → #{text_pl.inspect}#{flags['needs_review'] ? ' [review]' : ''}"
          end
          pending.clear
        end

        cues.each_with_index do |cue, idx|
          existing = cue["text_pl"].to_s.strip
          in_only = only_set.nil? || only_set.include?(cue["id"].to_s)

          if only_set && !in_only
            flush.call
            flags = normalize_flags(
              names: cue["review_names"],
              jargon: cue["review_jargon"],
              keep_english: cue["review_keep_english"],
              cue: cue,
              glossary: glossary
            )
            translations << entry_for(cue, existing, flags, skipped: true)
            translated_pl[cue["id"].to_s] = existing
            skipped += 1
            next
          end

          if !force && only_set.nil? && !existing.empty?
            flush.call
            flags = normalize_flags(
              names: cue["review_names"],
              jargon: cue["review_jargon"],
              keep_english: cue["review_keep_english"],
              cue: cue,
              glossary: glossary
            )
            translations << entry_for(cue, existing, flags, skipped: true)
            translated_pl[cue["id"].to_s] = existing
            skipped += 1
            next
          end

          if silence_cue?(cue)
            flush.call
            flags = normalize_flags(
              names: [],
              jargon: [],
              keep_english: [],
              cue: cue,
              glossary: glossary
            )
            translations << entry_for(cue, "", flags, skipped: true)
            translated_pl[cue["id"].to_s] = ""
            silence += 1
            warn "silence #{cue['id']} (skip LLM)"
            next
          end

          prev_cue = idx.positive? ? cues[idx - 1] : nil
          if prev_cue
            prev_cue = prev_cue.merge(
              "text_pl" => translated_pl[prev_cue["id"].to_s] || prev_cue["text_pl"]
            )
          end
          next_cue = cues[idx + 1]
          pending << {
            cue: cue,
            prev: prev_cue,
            nxt: next_cue,
            glossary: glossary_for_cue(cue, glossary),
            few_shot: few_shot_examples(out_dir, cue, context),
            speaker_profile: speaker_profile_for(out_dir, cue, context)
          }
          flush.call if pending.size >= batch_size
        end
        flush.call
      end
      llm_elapsed = Metrics.monotonic - llm_started if llm_started

      total_elapsed = Metrics.monotonic - t0
      flagged = translations.count { |t| t["needs_review"] }
      print_translate_metrics!(
        total_s: total_elapsed,
        llm_s: llm_elapsed,
        translated: translated,
        skipped: skipped,
        silence: silence,
        flagged: flagged,
        en_words: en_words_llm,
        en_chars: en_chars_llm,
        pl_words: pl_words_llm,
        pl_chars: pl_chars_llm,
        batch_size: batch_size
      )

      {
        "schema_version" => Subpipe::SCHEMA_VERSION,
        "target_language" => "pl",
        "translations" => translations
      }
    end

    def print_translate_metrics!(total_s:, llm_s:, translated:, skipped:, silence:, flagged:, en_words:, en_chars:, pl_words:, pl_chars:, batch_size:)
      puts "Translated #{translated} cue(s), silence #{silence}, skipped #{skipped}"
      rows = [
        ["wall time", "#{Metrics.format_duration(total_s)}  (inference window #{Metrics.format_duration(llm_s)})"],
        ["batch size", batch_size.to_s],
        ["cues", "#{translated} translated, #{skipped} skipped, #{silence} silence, #{flagged} flagged"]
      ]
      per_cue = Metrics.per_unit(llm_s, translated, unit: "cue")
      rows << ["per cue", "#{per_cue} (inference / translated cue)"] if per_cue
      if en_words.positive? && llm_s.positive?
        rows << ["per EN word", "#{format('%.3fs', llm_s / en_words)}  (#{en_words} EN words → #{pl_words} PL words)"]
      elsif translated.positive?
        rows << ["EN/PL words", "#{en_words} → #{pl_words}"]
      end
      if en_chars.positive?
        ratio = pl_chars.to_f / en_chars
        rows << ["chars", "#{en_chars} EN → #{pl_chars} PL  (PL/EN #{format('%.2f', ratio)})"]
      end
      Metrics.print_report("Translate", rows)
    end

    def silence_cue?(cue)
      text = [cue["text_en"], cue["asr_text"], cue["subtitle_text"]]
             .compact.map { |t| t.to_s.strip }.reject(&:empty?).join(" ")
      return true if text.empty?

      short_text = text.length <= SILENCE_MAX_TEXT_CHARS
      return false unless short_text

      prosody = cue["prosody"]
      if prosody.is_a?(Hash)
        tiny = prosody["duration_ms"].to_i <= SILENCE_MAX_DURATION_MS
        quiet = prosody["mean_db"] && prosody["mean_db"].to_f <= SILENCE_MEAN_DB
        return true if quiet || tiny
      end

      # Analyze already marked obvious non-speech.
      cue["emotion"].to_s == "neutral" &&
        cue["delivery"].to_s == "normal" &&
        cue["emotion_intensity"].to_f <= 0.05
    end

    # Yields callable: pending_items → array of result hashes (same order as pending).
    # Retries missing/unparseable cues one-at-a-time when a multi-cue batch fails.
    def with_inference(model:, server_bin:, use_hook:)
      if use_hook
        hook = ENV["SUBPIPE_TRANSLATE_HOOK"]
        batch_once = lambda do |pending|
          prompt = build_batch_prompt(pending)
          out, status = Open3.capture2(hook, stdin_data: prompt)
          Subpipe.abort!("translate hook failed") unless status.success?
          parse_batch_json(out, pending.map { |p| p[:cue]["id"].to_s })
        end
        yield(lambda { |pending| complete_batch(batch_once, pending) })
        return
      end

      model ||= ENV["SUBPIPE_TRANSLATE_MODEL"]
      Subpipe.abort!("no translate model; set SUBPIPE_TRANSLATE_MODEL") if model.nil? || model.empty?
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
          batch_once = lambda do |pending|
            prompt = build_batch_prompt(pending)
            ids = pending.map { |p| p[:cue]["id"].to_s }
            content = chat_complete(http, uri, prompt, max_tokens: [512 * pending.size, 1024].max)
            parse_batch_json(content, ids)
          end
          yield(lambda { |pending| complete_batch(batch_once, pending) })
        end
      ensure
        Signal.trap("INT", old_int || "DEFAULT")
        Signal.trap("TERM", old_term || "DEFAULT")
        stop_server!(server)
      end
    end

    # Never abort on a multi-cue batch parse miss — fall back to singles.
    def complete_batch(batch_once, pending)
      ids = pending.map { |p| p[:cue]["id"].to_s }
      results =
        begin
          batch_once.call(pending)
        rescue StandardError => e
          warn "translate batch error (#{e.message}); retrying singly" if pending.size > 1
          Array.new(pending.size)
        end
      results = Array.new(pending.size) if results.nil?
      results = results.take(pending.size) + Array.new([pending.size - results.size, 0].max) if results.size != pending.size

      missing_idx = results.each_index.select { |i| results[i].nil? }
      if missing_idx.any? && pending.size > 1
        if missing_idx.size == pending.size
          warn "translate batch unparseable; retrying #{pending.size} cue(s) singly"
        else
          warn "translate batch incomplete (missing #{missing_idx.map { |i| ids[i] }.join(', ')}); retrying those singly"
        end
        missing_idx.each do |i|
          solo =
            begin
              batch_once.call([pending[i]])
            rescue StandardError => e
              warn "translate single #{ids[i]} error: #{e.message}"
              [nil]
            end
          results[i] = solo && solo[0]
        end
      end

      still = results.each_index.select { |i| results[i].nil? }.map { |i| ids[i] }
      unless still.empty?
        Subpipe.abort!("translate failed for cue id #{still.join(', ')} (unparseable JSON after retries)")
      end

      results
    end

    def free_port
      TCPServer.open("127.0.0.1", 0) do |s|
        s.addr[1]
      end
    end

    def gpu_mem_snapshot
      out, = Open3.capture2("nvidia-smi", "--query-gpu=memory.free,memory.used,memory.total", "--format=csv,noheader,nounits")
      free, used, total = out.to_s.strip.split(",").map { |x| x.to_s.strip.to_i }
      { "free_mib" => free, "used_mib" => used, "total_mib" => total }
    rescue StandardError => e
      { "error" => e.message }
    end

    def start_server!(model:, server_bin:)
      bin = ENV["SUBPIPE_LLAMA_SERVER_BIN"].to_s.strip
      bin = server_bin.to_s.strip if bin.empty? && server_bin && !server_bin.to_s.include?("llama-cli")
      bin = "llama-server" if bin.empty?
      port = ENV.fetch("SUBPIPE_LLAMA_SERVER_PORT", free_port.to_s).to_i
      host = "127.0.0.1"
      ngl = ENV.fetch("SUBPIPE_LLAMA_NGL", "99")
      log_path = File.join(Dir.tmpdir, "subpipe-llama-server-#{Process.pid}-#{port}.log")
      # 8192×4 slots blew KV (~1.6GiB) after weights on 10GiB cards; one slot + 4k is enough for batches.
      ctx = ENV.fetch("SUBPIPE_TRANSLATE_CTX", "4096")
      parallel = ENV.fetch("SUBPIPE_TRANSLATE_PARALLEL", "1")
      # Keep server stderr in log_path so OOM/load errors surface on abort.
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
      snap = gpu_mem_snapshot
      free = snap.is_a?(Hash) ? snap["free_mib"].to_i : 0
      if free.positive? && free < 6500 && ngl.to_i >= 50
        warn "Warning: only ~#{free} MiB GPU free; Bielik Q4 typically needs ~6.5 GiB. Close other GPU apps or expect CUDA OOM."
      end
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
          status = Process.waitpid(server[:pid], Process::WNOHANG)
          if status
            log_tail = read_server_log(server)
            snap = gpu_mem_snapshot
            hint = ""
            if log_tail.match?(/out of memory|cudaMalloc|failed to allocate CUDA|unable to allocate CUDA/i)
              free = snap.is_a?(Hash) ? snap["free_mib"] : nil
              hint = "\nHint: GPU out of memory"
              hint += " (only ~#{free} MiB free)" if free
              hint += ". Close other GPU apps (games/Proton/etc.), then retry. Bielik Q4 needs ~6.5 GiB free with default -ngl 99."
            end
            Subpipe.abort!("llama-server exited before ready#{hint}\n#{log_tail}")
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
      # Ruby str[-N,N] is nil when length < N — do not use that form.
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

    # One-shot chat for mentor edit-reflection (starts/stops llama-server).
    # Returns content string, or nil if model missing / SUBPIPE_REFLECT=0 / failure (non-abort).
    def one_shot_chat(user_prompt, system: nil, max_tokens: 384, model: nil, server_bin: nil)
      return nil if ENV["SUBPIPE_REFLECT"].to_s == "0"
      return nil if ENV["SUBPIPE_TRANSLATE_HOOK"].to_s.strip != "" # hook mode: skip server reflect

      model ||= ENV["SUBPIPE_TRANSLATE_MODEL"]
      return nil if model.nil? || model.empty? || !File.file?(model)

      server = nil
      begin
        server = start_server!(model: model, server_bin: server_bin)
        uri = URI(server[:base_url])
        content = nil
        Net::HTTP.start(uri.host, uri.port, open_timeout: 30, read_timeout: ENV.fetch("SUBPIPE_LLAMA_SERVER_TIMEOUT", "180").to_i) do |http|
          content = chat_complete(http, uri, user_prompt, max_tokens: max_tokens, system: system || SYSTEM_PROMPT)
        end
        content
      rescue StandardError => e
        warn "reflect LLM skipped: #{e.message}"
        nil
      ensure
        stop_server!(server) if server
      end
    end

    def chat_complete(http, base_uri, user_prompt, max_tokens: 512, system: nil)
      path = "#{base_uri.path}/v1/chat/completions".gsub(%r{//+}, "/")
      path = "/v1/chat/completions" if base_uri.path.nil? || base_uri.path.empty? || base_uri.path == "/"
      body = {
        "messages" => [
          { "role" => "system", "content" => (system || SYSTEM_PROMPT) },
          { "role" => "user", "content" => user_prompt }
        ],
        "temperature" => 0.2,
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
      finish = data.dig("choices", 0, "finish_reason").to_s
      warn "translate LLM truncated output (finish_reason=length)" if finish == "length"
      Subpipe.abort!("llama-server returned empty content") if content.strip.empty?

      content
    rescue JSON::ParserError => e
      Subpipe.abort!("invalid llama-server JSON: #{e.message}")
    end

    def build_batch_prompt(pending)
      cues = pending.map do |item|
        cue = item[:cue]
        prev_cue = item[:prev]
        next_cue = item[:nxt]
        en = cue["text_en"].to_s
        asr = cue["asr_text"].to_s
        sub = cue["subtitle_text"].to_s
        few = Array(item[:few_shot]).filter_map { |r| Feedback.few_shot_prompt_pair(r) }
        {
          "id" => cue["id"],
          "text_en" => en,
          "asr_text" => (asr.empty? || asr == en) ? nil : asr,
          "subtitle_text" => (sub.empty? || sub == en) ? nil : sub,
          "emotion" => cue["emotion"],
          "emotion_intensity" => cue["emotion_intensity"],
          "delivery" => cue["delivery"],
          "speakers" => cue["speakers"],
          "speaker_profile" => item[:speaker_profile],
          "duration_ms" => cue.dig("prosody", "duration_ms") || (
            cue["start_ms"] && cue["end_ms"] ? (cue["end_ms"].to_i - cue["start_ms"].to_i) : nil
          ),
          "previous" => prev_cue && {
            "id" => prev_cue["id"],
            "text_en" => prev_cue["text_en"],
            "text_pl" => prev_cue["text_pl"]
          },
          "next" => next_cue && { "id" => next_cue["id"], "text_en" => next_cue["text_en"] },
          "glossary" => item[:glossary].nil? || item[:glossary].empty? ? nil : item[:glossary],
          "few_shot_corrections" => few.empty? ? nil : few
        }.compact
      end
      payload = { "cues" => cues }
      "Translate each subtitle cue to Polish and flag names/jargon.\n" \
        "If few_shot_corrections are present, prefer pl_gold for similar source_en phrasing " \
        "(pl_draft is the previous engine draft; ignore engine identity).\n" \
        "If speaker_profile is present, match that speaker's register.\n" \
        "#{JSON.generate(payload)}"
    end

    def few_shot_examples(out_dir, cue, context)
      return [] if ENV.fetch("SUBPIPE_FEEDBACK_FEWSHOT", "1") == "0"

      exclude = ENV["SUBPIPE_FEEDBACK_EXCLUDE_TAGS"].to_s.split(",").map(&:strip).reject(&:empty?)
      limit = ENV.fetch("SUBPIPE_FEEDBACK_FEWSHOT_N", "3").to_i
      Feedback.few_shot_for_cue(out_dir, cue, context: context, limit: limit, exclude_tags: exclude)
    end

    def speaker_profile_for(out_dir, cue, context)
      sp = Feedback.primary_speaker(cue)
      return nil if sp.nil? || sp.empty?

      meta = Feedback.load_project_meta(out_dir, context)
      mapped = (meta["speaker_map"] || {})[sp] || sp
      path = File.join(Feedback.speakers_dir(out_dir, context), "#{mapped}.json")
      path = File.join(Feedback.speakers_dir(out_dir, context), "#{sp}.json") unless File.file?(path)
      return nil unless File.file?(path)

      JSON.parse(File.read(path))
    rescue StandardError
      nil
    end

    # Soft-fail: returns Array of Hash/nil aligned to expected_ids (never aborts).
    def parse_batch_json(raw, expected_ids)
      text = preprocess_llm_json(raw.to_s)
      parsed_list = extract_translation_list(text)
      return expected_ids.map { nil } if parsed_list.nil? || parsed_list.empty?

      by_id = {}
      parsed_list.each do |h|
        next unless h.is_a?(Hash) && h.key?("text_pl")

        key = normalize_cue_id(h["id"])
        by_id[key] = h unless key.empty?
      end

      expected_ids.map.with_index do |id, idx|
        h = by_id[normalize_cue_id(id)]
        if h.nil? && parsed_list.size == expected_ids.size
          cand = parsed_list[idx]
          h = cand.merge("id" => id) if cand.is_a?(Hash) && cand.key?("text_pl")
        end
        if h.nil? && expected_ids.size == 1 && parsed_list.size == 1 && parsed_list[0].is_a?(Hash)
          h = parsed_list[0].merge("id" => id)
        end
        h
      end
    end

    def preprocess_llm_json(text)
      s = text.to_s.strip
      s = s.sub(/\A```(?:json)?\s*/i, "")
      s = s.sub(/\s*```\z/, "")
      if (idx = s.index(/[\{\[]/))
        s = s[idx..]
      end
      s
    end

    def extract_translation_list(text)
      arrays = extract_json_arrays(text)
      candidates = arrays.filter_map { |blob| try_parse_json(blob) }
                        .select { |a| translation_array?(a) }
      parsed = candidates.max_by(&:size)
      return parsed if parsed

      repaired = repair_truncated_json(text)
      if repaired
        val = try_parse_json(repaired)
        return val if translation_array?(val)
        return [val] if translation_object?(val)
      end

      objects = extract_json_objects(text).filter_map { |blob| try_parse_json(blob) }
                                         .select { |h| translation_object?(h) }
      return objects unless objects.empty?

      salvage_text_pl_hashes(text)
    end

    def translation_array?(val)
      val.is_a?(Array) && val.any? { |h| translation_object?(h) }
    end

    def translation_object?(val)
      val.is_a?(Hash) && val.key?("text_pl")
    end

    def try_parse_json(blob)
      JSON.parse(blob)
    rescue JSON::ParserError
      nil
    end

    def repair_truncated_json(text)
      s = text.to_s.strip
      return nil unless s.start_with?("[", "{")

      if odd_unescaped_quotes?(s)
        last = s.rindex(/[^\\]"/)
        return nil unless last

        s = s[0..last]
      end

      if s.include?("{") && s.count("{") > s.count("}")
        cut = s.rindex("{")
        head = s[0...cut].sub(/,\s*\z/, "")
        s = head unless head.empty?
      end

      open_sq = s.count("[") - s.count("]")
      open_br = s.count("{") - s.count("}")
      return nil if open_sq.negative? || open_br.negative?

      s + ("}" * open_br) + ("]" * open_sq)
    end

    def odd_unescaped_quotes?(s)
      n = 0
      i = 0
      while i < s.length
        if s[i] == "\\"
          i += 2
          next
        end
        n += 1 if s[i] == '"'
        i += 1
      end
      n.odd?
    end

    def salvage_text_pl_hashes(text)
      results = []
      text.to_s.scan(/\{[^{}]*"text_pl"\s*:\s*"(?:\\.|[^"\\])*"\s*(?:,\s*"[^"]+"\s*:\s*(?:"(?:\\.|[^"\\])*"|\[.*?\]|[^,}]+))*\s*\}/m) do |blob|
        h = try_parse_json(blob)
        results << h if translation_object?(h)
      end
      if results.empty?
        text.to_s.scan(/"id"\s*:\s*"([^"]+)".*?"text_pl"\s*:\s*"((?:\\.|[^"\\])*)"/m) do |id, pl|
          pl_val =
            begin
              JSON.parse("\"#{pl}\"")
            rescue JSON::ParserError
              pl.gsub('\\"', '"')
            end
          results << { "id" => id, "text_pl" => pl_val, "names" => [], "jargon" => [], "keep_english" => [] }
        end
      end
      results
    end

    def normalize_cue_id(id)
      id.to_s.strip.downcase
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

    def entry_for(cue, text_pl, flags, skipped:)
      {
        "id" => cue["id"],
        "text_en" => cue["text_en"],
        "text_pl" => text_pl,
        "names" => flags["names"],
        "jargon" => flags["jargon"],
        "keep_english" => flags["keep_english"],
        "needs_review" => flags["needs_review"],
        "skipped" => skipped
      }
    end

    def normalize_flags(names:, jargon:, keep_english:, cue:, glossary:)
      heuristic = heuristic_flags(cue, glossary)
      merged_names = uniq_terms(Array(names) + heuristic["names"])
      merged_jargon = uniq_terms(Array(jargon) + heuristic["jargon"])
      merged_keep = uniq_terms(Array(keep_english) + heuristic["keep_english"])
      {
        "names" => merged_names,
        "jargon" => merged_jargon,
        "keep_english" => merged_keep,
        "needs_review" => !(merged_names.empty? && merged_jargon.empty? && merged_keep.empty?)
      }
    end

    def heuristic_flags(cue, glossary)
      names = capitalized_terms(cue["text_en"])
      glossary_hits = glossary_for_cue(cue, glossary).map { |g| g["term"] }
      {
        "names" => names,
        "jargon" => glossary_hits,
        "keep_english" => []
      }
    end

    def capitalized_terms(text)
      return [] if text.nil? || text.empty?

      names = []
      text.to_s.split(/(?<=[.!?…])\s+|\n+/).each do |sentence|
        words = sentence.scan(/\b[A-Za-z0-9'\-]+\b/)
        words.each_with_index do |w, i|
          if w.match?(/\A[A-Z]{2,}\z/)
            names << w
            next
          end
          next if i.zero?
          next unless w.match?(/\A[A-Z]/)
          next if SKIP_NAME_WORDS.include?(w)

          names << w
        end
      end
      names.uniq
    end

    def uniq_terms(list)
      list.map { |t| t.to_s.strip }.reject(&:empty?).uniq
    end

    def write_draft_files!(out_dir, draft)
      draft_path = File.join(out_dir, "translation-draft.json")
      File.write(draft_path, JSON.pretty_generate(draft))

      review_path = File.join(out_dir, "translation-review.md")
      translations = draft.fetch("translations")
      flagged = translations.select { |t| t["needs_review"] }

      lines = ["# Translation review", ""]
      lines << "Flagged for names / jargon / keep-English: **#{flagged.size}** / #{translations.size}"
      lines << ""

      unless flagged.empty?
        lines << "## Needs review"
        lines << ""
        lines.concat(review_table(flagged, include_flags: true))
        lines << ""
      end

      lines << "## All cues"
      lines << ""
      lines.concat(review_table(translations, include_flags: true))
      File.write(review_path, lines.join("\n") + "\n")
      puts "Wrote #{draft_path} and #{review_path}"
    end

    def review_table(rows, include_flags:)
      header = ["| ID | English | Polish | Flags |", "|----|---------|--------|-------|"]
      header = ["| ID | English | Polish |", "|----|---------|--------|"] unless include_flags

      body = rows.map do |t|
        en = md_cell(t["text_en"])
        pl = md_cell(t["text_pl"])
        if include_flags
          "| #{t['id']} | #{en} | #{pl} | #{md_cell(format_flags(t))} |"
        else
          "| #{t['id']} | #{en} | #{pl} |"
        end
      end
      header + body
    end

    def format_flags(t)
      parts = []
      parts << "names: #{Array(t['names']).join(', ')}" unless Array(t["names"]).empty?
      parts << "jargon: #{Array(t['jargon']).join(', ')}" unless Array(t["jargon"]).empty?
      parts << "keep EN: #{Array(t['keep_english']).join(', ')}" unless Array(t["keep_english"]).empty?
      parts.empty? ? "—" : parts.join("; ")
    end

    def md_cell(text)
      text.to_s.gsub("|", "\\|").gsub("\n", " ")
    end

    def apply_draft!(out_dir, draft, refresh_model_ids: nil)
      context = load_context!(out_dir)
      by_id = draft.fetch("translations").to_h { |t| [t.fetch("id"), t] }
      refresh = refresh_model_ids && Array(refresh_model_ids).map(&:to_s).to_set

      missing = context["cues"].map { |c| c["id"] } - by_id.keys
      Subpipe.abort!("draft missing cue ids: #{missing.join(', ')}") unless missing.empty?

      context["cues"].each do |cue|
        t = by_id.fetch(cue["id"])
        pl = t.fetch("text_pl")
        cue["text_pl"] = pl
        # Baseline for mentor Feedback (model → user). Keep first model output if re-apply.
        # Retranslate path refreshes model baseline for touched ids.
        if refresh&.include?(cue["id"].to_s)
          cue["text_pl_model"] = pl
          cue["pl_accepted_at"] = nil
        elsif cue["text_pl_model"].to_s.empty?
          cue["text_pl_model"] = pl
        end
        cue["text_en_model"] = cue["text_en"].to_s if cue["text_en_model"].to_s.empty?
        # Single source of truth: subtitle == lektor; drop diverging overrides.
        cue["lektor_line"] = nil
        cue["lektor_directed_at"] = nil
        cue["review_names"] = Array(t["names"])
        cue["review_jargon"] = Array(t["jargon"])
        cue["review_keep_english"] = Array(t["keep_english"])
        cue["needs_review"] = !!t["needs_review"]
      end
      context["future"] ||= {}
      context["future"]["target_language"] = "pl"
      context["future"]["translation_applied_at"] = Time.now.utc.iso8601

      context_path = File.join(out_dir, "context.json")
      File.write(context_path, JSON.pretty_generate(context))

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
      File.write(context_path, JSON.pretty_generate(context))
      flagged = context["cues"].count { |c| c["needs_review"] }
      puts "Applied translations → #{context_path}, #{ass_path} (#{flagged} cue(s) still marked needs_review)"
    end

    # Mentor propagate: force-translate a cue id subset (glossary already in vocab/context).
    def retranslate_cues!(out_dir, cue_ids:, vocab_path: nil, model: nil, llama_bin: nil)
      ids = Array(cue_ids).map(&:to_s).reject(&:empty?).uniq
      return [] if ids.empty?

      draft = generate_draft(
        out_dir,
        force: false,
        model: model,
        llama_bin: llama_bin,
        vocab_path: vocab_path,
        only_ids: ids
      )
      write_draft_files!(out_dir, draft)
      apply_draft!(out_dir, draft, refresh_model_ids: ids)
      ids
    end

    def load_context!(out_dir)
      path = File.join(out_dir, "context.json")
      Subpipe.abort!("missing #{path}; run merge/run first") unless File.file?(path)
      JSON.parse(File.read(path))
    end

    def glossary_for_cue(cue, glossary)
      hay = [cue["text_en"], cue["asr_text"], cue["subtitle_text"]].compact.join(" ")
      glossary.select do |g|
        needles = [g["term"], *Array(g["aliases"])].map(&:to_s).reject(&:empty?)
        needles.any? { |n| hay.match?(/\b#{Regexp.escape(n)}\b/i) }
      end.map do |g|
        prefs = Vocab.preferred_list(g)
        mapped = {
          "term" => g["term"],
          "preferred_translations" => prefs.empty? ? nil : prefs,
          "preferred_translation" => prefs.first,
          "avoid_pl" => g["avoid_pl"],
          "keep_english" => g["keep_english"],
          "notes" => g["notes"]
        }.compact
        mapped
      end
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

    def normalize_result(result)
      %w[names jargon keep_english].each do |key|
        val = result[key]
        result[key] =
          case val
          when Array then val.map(&:to_s)
          when String then val.empty? ? [] : [val]
          when true then []
          when false, nil then []
          else Array(val).map(&:to_s)
          end
      end
      result["id"] = result["id"].to_s
      result["text_pl"] = result["text_pl"].to_s
      result
    end
  end
end
