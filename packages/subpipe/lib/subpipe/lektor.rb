# frozen_string_literal: true

require "json"
require "fileutils"
require "digest"
require "open3"
require "time"
require "io/console"
require "shellwords"
require "pathname"
require_relative "metrics"

module Subpipe
  # Offline lektor: Orpheus PL (default) or XTTS-v2 via JSON-lines workers.
  module Lektor
    module_function

    VOICE_NAME = "voice.json"
    LEKTOR_DIR = "lektor"
    MANIFEST_NAME = "manifest.json"
    MAX_CHARS = 220

    DEFAULT_VOICE = {
      "schema_version" => 1,
      "engine" => "orpheus_pl",
      "voice" => "tomasz",
      "model" => "TeeZee/Orpheus-TTS-pl-v2.5",
      "language" => "pl",
      "reference_wav" => "reference.wav",
      "speed" => 1.0,
      "orpheus" => {
        # Slightly expressive baseline (Canopy-ish); emotion/delivery nudge per cue.
        "temperature" => 0.7,
        "top_p" => 0.85,
        "repetition_penalty" => 1.35
      },
      "delivery_defaults" => {
        "whisper" => { "speed" => 0.92 },
        "shout" => { "speed" => 1.08 },
        "rushed" => { "speed" => 1.12 },
        "slow" => { "speed" => 0.88 },
        "laugh" => { "speed" => 1.05 },
        "cry" => { "speed" => 0.95 },
        "normal" => { "speed" => 1.0 }
      }
    }.freeze

    ORPHEUS_TEMP_MIN = 0.2
    ORPHEUS_TEMP_MAX = 1.5
    ORPHEUS_REP_MIN = 1.1
    ORPHEUS_REP_MAX = 1.8
    ORPHEUS_TOP_P_MIN = 0.1
    ORPHEUS_TOP_P_MAX = 1.0

    # Deltas added to voice orpheus knobs (scaled by emotion_intensity when present).
    ORPHEUS_EMOTION_DELTA = {
      "neutral" => {},
      "happy" => { "temperature" => 0.08, "repetition_penalty" => 0.05 },
      "amused" => { "temperature" => 0.1, "top_p" => 0.03, "repetition_penalty" => 0.05 },
      "sad" => { "temperature" => -0.06, "top_p" => -0.05, "repetition_penalty" => -0.05 },
      "angry" => { "temperature" => 0.12, "repetition_penalty" => 0.1 },
      "fearful" => { "temperature" => 0.06, "top_p" => 0.02 },
      "surprised" => { "temperature" => 0.1, "repetition_penalty" => 0.06 },
      "disgusted" => { "temperature" => 0.05, "repetition_penalty" => 0.04 }
    }.freeze

    ORPHEUS_DELIVERY_DELTA = {
      "normal" => {},
      "whisper" => { "temperature" => -0.08, "top_p" => -0.05, "repetition_penalty" => -0.06 },
      "shout" => { "temperature" => 0.14, "repetition_penalty" => 0.12 },
      "laugh" => { "temperature" => 0.1, "top_p" => 0.05, "repetition_penalty" => 0.05 },
      "cry" => { "temperature" => -0.05, "top_p" => -0.03, "repetition_penalty" => -0.04 },
      "rushed" => { "temperature" => 0.1, "repetition_penalty" => 0.12 },
      "slow" => { "temperature" => -0.06, "repetition_penalty" => -0.08 }
    }.freeze

    ORPHEUS_ENGINES = %w[orpheus_pl orpheus].freeze
    XTTS_ENGINES = %w[xtts_v2 xtts].freeze

    def run(out_dir, mode: "tui", force: false, reference: nil, model: nil, llama_bin: nil)
      out_dir = File.expand_path(out_dir)
      case mode.to_s
      when "init"
        init!(out_dir, reference: reference)
      when "direct"
        LektorDirect.run(out_dir, force: force, model: model, llama_bin: llama_bin)
      when "generate"
        generate!(out_dir, force: force)
      when "tui", "preview"
        tui!(out_dir)
      else
        Subpipe.abort!("unknown lektor mode: #{mode} (use init|tui|direct|generate)")
      end
    end

    def init!(out_dir, reference: nil)
      Subpipe.ensure_dir!(out_dir)
      voice_path = File.join(out_dir, VOICE_NAME)
      voice = DEFAULT_VOICE.dup
      voice["delivery_defaults"] = DEFAULT_VOICE["delivery_defaults"].dup
      voice["orpheus"] = DEFAULT_VOICE["orpheus"].dup

      if reference && !reference.to_s.empty?
        src = File.expand_path(reference, Dir.pwd)
        Subpipe.abort!("reference not found: #{src}") unless File.file?(src)
        dest = File.join(out_dir, "reference.wav")
        FileUtils.cp(src, dest)
        voice["reference_wav"] = "reference.wav"
        puts "Copied reference → #{dest}"
      end

      File.write(voice_path, JSON.pretty_generate(voice) + "\n")
      puts "Initialized #{voice_path} (engine=#{voice['engine']})"
      if needs_reference?(voice)
        ref = resolve_reference(out_dir, voice)
        unless File.file?(ref)
          warn "Place a 6–30s clean mono WAV at #{File.join(out_dir, 'reference.wav')} (or pass --reference PATH)"
        end
      else
        puts "Orpheus voice=#{voice['voice']} (no reference.wav required)"
      end
      voice_path
    end

    def generate!(out_dir, force: false)
      t0 = Metrics.monotonic
      context = load_context!(out_dir)
      voice = load_voice!(out_dir)
      ref = resolve_reference(out_dir, voice)
      if needs_reference?(voice)
        Subpipe.abort!("missing reference WAV: #{ref} (subpipe lektor init --reference FILE)") unless File.file?(ref)
      end

      lektor_dir = File.join(out_dir, LEKTOR_DIR)
      FileUtils.mkdir_p(lektor_dir)

      cues = Array(context["cues"])
      generated = 0
      skipped = 0
      silence = 0
      empty = 0
      audio_out_s = 0.0
      pl_words = 0
      infer_s = 0.0

      with_worker(voice: voice, reference: ref) do |worker|
        cues.each_with_index do |cue, idx|
          text = spoken_text(cue)
          n = idx + 1
          if text.empty?
            empty += 1
            warn format("lektor %d/%d  %s  empty", n, cues.size, cue["id"])
            next
          end
          if silence_cue?(cue)
            silence += 1
            warn format("lektor %d/%d  %s  silence", n, cues.size, cue["id"])
            next
          end

          out_wav = File.join(lektor_dir, "#{cue['id']}.wav")
          meta = cue_fingerprint(cue, voice, ref)
          meta_path = "#{out_wav}.meta.json"
          if !force && File.file?(out_wav) && File.file?(meta_path)
            prev = JSON.parse(File.read(meta_path)) rescue {}
            if prev["fingerprint"] == meta
              skipped += 1
              audio_out_s += prev["duration_s"].to_f
              next
            end
          end

          speed = effective_speed(voice, cue)
          orpheus = effective_orpheus(voice, cue)
          t1 = Metrics.monotonic
          result = worker.synth(
            text: text,
            out_path: out_wav,
            speed: speed,
            language: voice["language"],
            speaker: voice["voice"],
            orpheus: orpheus
          )
          infer_s += Metrics.monotonic - t1
          Subpipe.abort!("lektor synth failed for #{cue['id']}: #{result['error']}") unless result["ok"]

          dur = result["duration_s"].to_f
          audio_out_s += dur
          pl_words += Metrics.word_count(text)
          generated += 1
          File.write(meta_path, JSON.pretty_generate(
            "fingerprint" => meta,
            "duration_s" => dur,
            "text" => text,
            "speed" => speed,
            "orpheus" => orpheus,
            "engine" => voice["engine"],
            "voice" => voice["voice"],
            "generated_at" => Time.now.utc.iso8601
          ) + "\n")
          warn format("lektor %d/%d  %s  %.2fs", n, cues.size, cue["id"], dur)
        end
      end

      manifest = {
        "schema_version" => 1,
        "generated_at" => Time.now.utc.iso8601,
        "voice" => voice,
        "cues" => cues.filter_map do |cue|
          wav = File.join(LEKTOR_DIR, "#{cue['id']}.wav")
          abs = File.join(out_dir, wav)
          next unless File.file?(abs)

          meta = JSON.parse(File.read("#{abs}.meta.json")) rescue {}
          {
            "id" => cue["id"],
            "wav" => wav,
            "duration_s" => meta["duration_s"],
            "start_ms" => cue["start_ms"],
            "end_ms" => cue["end_ms"]
          }
        end
      }
      File.write(File.join(out_dir, LEKTOR_DIR, MANIFEST_NAME), JSON.pretty_generate(manifest) + "\n")

      total_s = Metrics.monotonic - t0
      puts "Lektor generate → #{lektor_dir} (#{generated} new, #{skipped} cached)"
      rows = [
        ["wall time", Metrics.format_duration(total_s)],
        ["inference", Metrics.format_duration(infer_s)],
        ["cues", "#{generated} generated, #{skipped} cached, #{silence} silence, #{empty} empty"],
        ["audio out", Metrics.format_duration(audio_out_s)]
      ]
      if audio_out_s.positive? && infer_s.positive?
        rows << ["realtime factor", format("%.2f× (infer/audio)", infer_s / audio_out_s)]
      end
      per_cue = Metrics.per_unit(infer_s, generated, unit: "cue")
      rows << ["per cue", per_cue] if per_cue
      if pl_words.positive?
        rows << ["PL words", pl_words.to_s]
        per_w = Metrics.per_unit(infer_s, pl_words, unit: "word")
        rows << ["per PL word", per_w] if per_w
      end
      Metrics.print_report("Lektor", rows)
    end

    def tui!(out_dir)
      context = load_context!(out_dir)
      voice_path = File.join(out_dir, VOICE_NAME)
      unless File.file?(voice_path)
        init!(out_dir)
      end
      voice = load_voice!(out_dir)
      ref = resolve_reference(out_dir, voice)
      cues = Array(context["cues"])
      Subpipe.abort!("no cues in context.json") if cues.empty?

      filter = :all # :all | :spoken
      cursor = 0
      dirty_voice = false
      dirty_context = false

      worker_holder = []
      start_worker = lambda do
        next worker_holder[0] if worker_holder[0]

        if needs_reference?(voice)
          Subpipe.abort!("missing reference WAV: #{ref}") unless File.file?(ref)
        end
        eng = voice["engine"].to_s
        warn "Starting lektor worker (#{eng}; first load may take a while)…"
        worker_holder[0] = Worker.start!(voice: voice, reference: ref)
        worker_holder[0]
      end

      begin
        loop do
          idxs = visible_indices(cues, filter)
          clamp_cursor = lambda do
            cursor = 0 if idxs.empty?
            cursor = [[cursor, 0].max, [idxs.size - 1, 0].max].min
          end
          clamp_cursor.call

          clear_screen
          print_tui_header(out_dir, voice, ref, filter, cursor, idxs.size, dirty_voice, dirty_context)
          if idxs.empty?
            puts "(no cues in this filter)"
          else
            cue = cues[idxs[cursor]]
            print_focused_cue(cue, voice)
          end
          puts
          puts menu_lines(filter)
          key = read_key
          break if key.nil?

          case key
          when "q"
            if (dirty_voice || dirty_context) && !confirm("Unsaved changes. Quit anyway?")
              next
            end
            puts "Bye."
            break
          when "j", :down
            cursor += 1 unless idxs.empty? || cursor >= idxs.size - 1
          when "k", :up
            cursor -= 1 if cursor.positive?
          when "0"
            cursor = 0
          when "G"
            cursor = [idxs.size - 1, 0].max
          when "f"
            filter = filter == :all ? :spoken : :all
            cursor = 0
          when "p", " "
            next if idxs.empty?
            cue = cues[idxs[cursor]]
            text = spoken_text(cue)
            if text.empty?
              puts "Nothing to speak for #{cue['id']}"
              pause
              next
            end
            begin
              w = start_worker.call
              preview_cue!(out_dir, w, voice, cue)
            rescue StandardError => e
              warn "preview failed: #{e.message}"
              pause
            end
          when "e"
            next if idxs.empty?
            cue = cues[idxs[cursor]]
            puts "Polish line (subtitle + lektor; empty keeps current; '-' clears leftover lektor_line override):"
            print "> "
            line = stdin_line
            next if line.nil?
            if line.strip == "-"
              cue["lektor_line"] = nil
              dirty_context = true
            elsif !line.strip.empty?
              cue["text_pl"] = line.rstrip
              cue["lektor_line"] = nil
              cue["lektor_directed_at"] = nil
              dirty_context = true
            end
          when "+"
            if orpheus_engine?(voice)
              nudge_orpheus_pace!(voice, +0.05)
            else
              voice["speed"] = (voice["speed"].to_f + 0.05).round(2)
            end
            dirty_voice = true
          when "-"
            if orpheus_engine?(voice)
              nudge_orpheus_pace!(voice, -0.05)
            else
              voice["speed"] = [voice["speed"].to_f - 0.05, 0.5].max.round(2)
            end
            dirty_voice = true
          when "s"
            save_voice!(out_dir, voice)
            dirty_voice = false
            if dirty_context
              File.write(File.join(out_dir, "context.json"), JSON.pretty_generate(context))
              dirty_context = false
              puts "Saved context.json"
            end
            pause
          when "w"
            save_voice!(out_dir, voice)
            dirty_voice = false
            pause
          when "c"
            if dirty_context || true
              File.write(File.join(out_dir, "context.json"), JSON.pretty_generate(context))
              dirty_context = false
              puts "Saved context.json"
              pause
            end
          when "g"
            puts "Running generate (force=false)…"
            worker_holder[0]&.stop!
            worker_holder[0] = nil
            generate!(out_dir, force: false)
            pause
          when "h", "?"
            print_help
            pause
          end
        end
      ensure
        worker_holder[0]&.stop!
      end
    end

    def preview_cue!(out_dir, worker, voice, cue)
      text = spoken_text(cue)
      tmp = File.join(out_dir, LEKTOR_DIR, ".preview.wav")
      FileUtils.mkdir_p(File.dirname(tmp))
      speed = effective_speed(voice, cue)
      orpheus = effective_orpheus(voice, cue)
      if orpheus_engine?(voice)
        warn format(
          "Synthesizing preview (engine=%s voice=%s temp=%.2f top_p=%.2f rep=%.2f)…",
          voice["engine"], voice["voice"],
          orpheus["temperature"], orpheus["top_p"], orpheus["repetition_penalty"]
        )
      else
        warn "Synthesizing preview (engine=#{voice['engine']} voice=#{voice['voice']} speed=#{speed})…"
      end
      result = worker.synth(
        text: text,
        out_path: tmp,
        speed: speed,
        language: voice["language"],
        speaker: voice["voice"],
        orpheus: orpheus
      )
      Subpipe.abort!("preview synth failed: #{result['error']}") unless result["ok"]
      play_wav!(tmp)
    end

    def play_wav!(path)
      players = [
        %w[ffplay -nodisp -autoexit -loglevel error],
        %w[mpv --no-video --really-quiet],
        %w[aplay]
      ]
      players.each do |cmd|
        bin = cmd[0]
        next unless Open3.capture2("sh", "-c", "command -v #{Shellwords.escape(bin)}").last.success?

        return if system(*cmd, path)
      end
      warn "No ffplay/mpv/aplay found; wrote #{path}"
      pause
    end

    def print_tui_header(out_dir, voice, ref, filter, cursor, total, dirty_voice, dirty_context)
      puts "subpipe lektor — #{out_dir}"
      dirty = [dirty_voice ? "voice*" : nil, dirty_context ? "context*" : nil].compact.join(" ")
      eng = voice["engine"].to_s
      voice_id = voice["voice"].to_s
      puts "filter: #{filter}  cue: #{total.zero? ? 0 : cursor + 1}/#{total}  engine: #{eng}" \
           "#{voice_id.empty? ? '' : "  voice: #{voice_id}"}  lang: #{voice['language']}" \
           "#{dirty.empty? ? '' : "  #{dirty}"}"
      if orpheus_engine?(voice)
        o = effective_orpheus(voice, {})
        puts format(
          "orpheus: temp=%.2f  top_p=%.2f  rep=%.2f  model=%s",
          o["temperature"], o["top_p"], o["repetition_penalty"],
          voice["model"].to_s.empty? ? "(default)" : voice["model"]
        )
      else
        puts "speed: #{voice['speed']}"
        puts "reference: #{ref}#{File.file?(ref) ? '' : '  (MISSING)'}" if needs_reference?(voice)
      end
      puts "-" * [72, term_width].min
    end

    def print_focused_cue(cue, voice)
      width = term_width
      text = spoken_text(cue)
      puts "#{cue['id']}  emotion=#{cue['emotion'] || '-'}  delivery=#{cue['delivery'] || '-'}"
      puts
      puts "EN:"
      wrap_text(cue["text_en"].to_s, width).each { |l| puts l }
      puts
      puts "PL (subtitle + lektor#{cue['lektor_line'] ? '; legacy lektor_line override' : ''}):"
      wrap_text(text, width).each { |l| puts l }
      puts
      if orpheus_engine?(voice)
        o = effective_orpheus(voice, cue)
        puts format(
          "orpheus for cue: temp=%.2f  top_p=%.2f  rep=%.2f  (emotion=%s/%.2f delivery=%s)",
          o["temperature"], o["top_p"], o["repetition_penalty"],
          cue["emotion"] || "-", cue["emotion_intensity"].to_f,
          cue["delivery"] || "-"
        )
      else
        puts "speed for cue: #{effective_speed(voice, cue)}"
      end
    end

    def menu_lines(filter)
      other = filter == :all ? "spoken-only" : "all"
      [
        "[j]/[k] next/prev   [0]/[G] first/last   [p]/[space] preview   [e] edit PL line",
        "[+]/[-] pace/speed   [f] show #{other}   [s] save voice+context   [g] generate   [h] help   [q] quit"
      ]
    end

    def print_help
      puts <<~HELP

        Lektor TUI
          voice.json engine: orpheus_pl (default; preset voice, no reference) or xtts_v2 (needs reference.wav).
          Orpheus default: model TeeZee/Orpheus-TTS-pl-v2.5, voice tomasz (Common Voice PL).
          Other voices: jan konrad wojciech … (see model card). Legacy v2.0: bartek/ola/…
          Orpheus sampling in voice.json → orpheus.{temperature,top_p,repetition_penalty}
            Analyze emotion/delivery nudge those knobs per cue (intensity scales).
            Optional cue.orpheus overrides win last. Higher temp+rep ≈ more energy.
          Translate already writes speakable text_pl (subtitle = lektor, same punctuation).
            Edit with e; optional `subpipe lektor direct` re-shapes text_pl without EN retranslate.
          XTTS: timbre from reference.wav; +/- adjusts speed.

          j/k     next/prev cue
          p       synthesize + play current line
          e       edit text_pl (subtitle + lektor)
          +/-     Orpheus: nudge temp+rep pace; XTTS: global speed
          s       save voice.json and context.json
          g       generate all missing/changed cue WAVs
      HELP
    end

    def needs_reference?(voice)
      eng = voice["engine"].to_s
      eng.empty? || XTTS_ENGINES.include?(eng)
    end

    def orpheus_engine?(voice)
      ORPHEUS_ENGINES.include?(voice["engine"].to_s)
    end

    def visible_indices(cues, filter)
      cues.each_index.select do |i|
        filter == :all || !spoken_text(cues[i]).empty?
      end
    end

    def spoken_text(cue)
      line = cue["lektor_line"].to_s.strip
      return line unless line.empty?

      cue["text_pl"].to_s.strip
    end

    SILENCE_MEAN_DB = -45.0
    SILENCE_MAX_DURATION_MS = 120
    SILENCE_MAX_TEXT_CHARS = 2

    def silence_cue?(cue)
      # Prefer analyze tags for obvious non-speech.
      if cue["emotion"].to_s == "neutral" &&
         cue["delivery"].to_s == "normal" &&
         cue["emotion_intensity"].to_f <= 0.05 &&
         spoken_text(cue).length <= SILENCE_MAX_TEXT_CHARS
        return true
      end

      text = spoken_text(cue)
      return true if text.empty?

      short_text = text.length <= SILENCE_MAX_TEXT_CHARS
      return false unless short_text

      prosody = cue["prosody"]
      return false unless prosody.is_a?(Hash)

      tiny = prosody["duration_ms"].to_i <= SILENCE_MAX_DURATION_MS
      quiet = prosody["mean_db"] && prosody["mean_db"].to_f <= SILENCE_MEAN_DB
      quiet || tiny
    end

    def effective_speed(voice, cue)
      base = voice["speed"].to_f
      base = 1.0 if base <= 0
      delivery = cue["delivery"].to_s
      adj = voice.dig("delivery_defaults", delivery, "speed")
      return base unless adj

      (base * adj.to_f).round(3)
    end

    def effective_orpheus(voice, cue = nil)
      base = DEFAULT_VOICE["orpheus"].merge(voice["orpheus"] || {})
      cue_hash = cue.is_a?(Hash) ? cue : {}

      # Analyze tags → sampling deltas (story lektor range; intensity scales 0..1).
      intensity = cue_hash["emotion_intensity"]
      scale = begin
        f = Float(intensity)
        f.nan? ? 0.55 : [[f, 0.0].max, 1.0].min
      rescue StandardError
        # Missing intensity: still apply a mild delivery/emotion nudge.
        0.55
      end
      # Neutral+normal with ~0 intensity → no delta.
      emotion = cue_hash["emotion"].to_s
      delivery = cue_hash["delivery"].to_s
      if emotion.empty? && delivery.empty?
        scale = 0.0
      elsif emotion == "neutral" && (delivery.empty? || delivery == "normal") && scale <= 0.05
        scale = 0.0
      end

      delta = Hash.new(0.0)
      (ORPHEUS_EMOTION_DELTA[emotion] || {}).each { |k, v| delta[k] += v.to_f }
      (ORPHEUS_DELIVERY_DELTA[delivery] || {}).each { |k, v| delta[k] += v.to_f }
      %w[temperature top_p repetition_penalty].each do |k|
        base[k] = base[k].to_f + (delta[k] * scale)
      end

      # Explicit cue.orpheus wins last.
      override = cue_hash["orpheus"] || {}
      merged = base.merge(override)
      {
        "temperature" => clamp_f(merged["temperature"], ORPHEUS_TEMP_MIN, ORPHEUS_TEMP_MAX, 0.7),
        "top_p" => clamp_f(merged["top_p"], ORPHEUS_TOP_P_MIN, ORPHEUS_TOP_P_MAX, 0.85),
        "repetition_penalty" => clamp_f(merged["repetition_penalty"], ORPHEUS_REP_MIN, ORPHEUS_REP_MAX, 1.35)
      }
    end

    def clamp_f(val, min_v, max_v, default)
      f = begin
        Float(val)
      rescue StandardError
        default
      end
      [[f, min_v].max, max_v].min.round(3)
    end

    def nudge_orpheus_pace!(voice, delta)
      voice["orpheus"] = effective_orpheus(voice, nil)
      voice["orpheus"]["temperature"] =
        clamp_f(voice["orpheus"]["temperature"] + delta, ORPHEUS_TEMP_MIN, ORPHEUS_TEMP_MAX, 0.7)
      voice["orpheus"]["repetition_penalty"] =
        clamp_f(voice["orpheus"]["repetition_penalty"] + delta, ORPHEUS_REP_MIN, ORPHEUS_REP_MAX, 1.35)
      voice["orpheus"]
    end

    def cue_fingerprint(cue, voice, ref)
      payload = {
        "text" => spoken_text(cue),
        "speed" => effective_speed(voice, cue),
        "language" => voice["language"],
        "engine" => voice["engine"],
        "voice" => voice["voice"],
        "model" => voice["model"],
        "orpheus" => effective_orpheus(voice, cue),
        "emotion" => cue["emotion"],
        "delivery" => cue["delivery"],
        "ref" => (File.basename(ref) if needs_reference?(voice)),
        "ref_mtime" => (File.mtime(ref).to_i if needs_reference?(voice) && File.file?(ref)),
        "voice_speed" => voice["speed"]
      }
      Digest::SHA256.hexdigest(JSON.generate(payload))
    end

    def load_context!(out_dir)
      path = File.join(out_dir, "context.json")
      Subpipe.abort!("missing #{path}; run merge/translate first") unless File.file?(path)
      JSON.parse(File.read(path))
    end

    def load_voice!(out_dir)
      path = File.join(out_dir, VOICE_NAME)
      Subpipe.abort!("missing #{path}; run: subpipe lektor init -o DIR") unless File.file?(path)
      data = JSON.parse(File.read(path))
      DEFAULT_VOICE.merge(data).tap do |v|
        v["delivery_defaults"] = DEFAULT_VOICE["delivery_defaults"].merge(data["delivery_defaults"] || {})
        v["orpheus"] = DEFAULT_VOICE["orpheus"].merge(data["orpheus"] || {})
      end
    end

    def load_or_init_voice(out_dir)
      path = File.join(out_dir, VOICE_NAME)
      init!(out_dir) unless File.file?(path)
      load_voice!(out_dir)
    end

    def preview_cue_to_path!(out_dir, worker, voice, cue, out_path)
      text = spoken_text(cue)
      FileUtils.mkdir_p(File.dirname(out_path))
      speed = effective_speed(voice, cue)
      orpheus = effective_orpheus(voice, cue)
      result = worker.synth(
        text: text,
        out_path: out_path,
        speed: speed,
        language: voice["language"],
        speaker: voice["voice"],
        orpheus: orpheus
      )
      raise "preview synth failed: #{result['error']}" unless result["ok"]

      result
    end

    def save_voice!(out_dir, voice)
      path = File.join(out_dir, VOICE_NAME)
      File.write(path, JSON.pretty_generate(voice) + "\n")
      puts "Saved #{path}"
    end

    def resolve_reference(out_dir, voice)
      rel = voice["reference_wav"].to_s
      rel = "reference.wav" if rel.empty?
      return rel if Pathname.new(rel).absolute? && File.file?(rel)

      File.join(out_dir, rel)
    end

    def with_worker(voice:, reference:)
      worker = Worker.start!(voice: voice, reference: reference)
      begin
        yield worker
      ensure
        worker.stop!
      end
    end

    # ---- Worker (JSON-lines over stdin) ----
    class Worker
      def self.start!(voice:, reference:)
        eng = voice["engine"].to_s
        if Lektor.orpheus_engine?(voice)
          if (hook = ENV["SUBPIPE_ORPHEUS_HOOK"].to_s.strip) != ""
            cmd = Shellwords.split(hook)
          else
            cmd = [ENV.fetch("SUBPIPE_ORPHEUS_WORKER", "subpipe-orpheus-worker")]
          end
        elsif (hook = ENV["SUBPIPE_XTTS_HOOK"].to_s.strip) != ""
          cmd = Shellwords.split(hook)
        else
          cmd = [ENV.fetch("SUBPIPE_XTTS_WORKER", "subpipe-xtts-worker")]
        end
        # Keep stderr separate so torch / HF logs do not corrupt JSON-lines stdout.
        stdin, stdout, stderr, wait_thr = Open3.popen3(*cmd)
        Thread.new do
          begin
            stderr.each_line { |line| warn line }
          rescue StandardError
            nil
          end
        end
        worker = new(stdin, stdout, wait_thr)
        load_args = { "language" => voice["language"] }
        load_args["voice"] = voice["voice"] if voice["voice"]
        load_args["model"] = voice["model"] if voice["model"].to_s.strip != ""
        if Lektor.needs_reference?(voice) && reference && File.file?(reference.to_s)
          load_args["reference_wav"] = reference
        end
        res = worker.request("load", load_args)
        raise "lektor load failed (#{eng}): #{res['error']}" if res && res["ok"] == false

        worker
      end

      def initialize(stdin, stdout, wait_thr)
        @stdin = stdin
        @stdout = stdout
        @wait_thr = wait_thr
      end

      def request(cmd, extra = {})
        payload = extra.merge("cmd" => cmd)
        @stdin.puts(JSON.generate(payload))
        @stdin.flush
        loop do
          line = @stdout.gets
          raise "lektor worker died" if line.nil?

          line = line.strip
          next if line.empty?
          unless line.start_with?("{")
            warn "lektor worker: #{line}" unless line.start_with?(">")
            next
          end

          msg = JSON.parse(line)
          next if msg["event"] == "loading"
          next if cmd == "load" && msg["event"] == "ready" && !msg.key?("loaded")

          return msg
        end
      end

      def synth(text:, out_path:, speed:, language:, speaker: nil, orpheus: nil)
        extra = {
          "text" => text,
          "out_path" => out_path,
          "speed" => speed,
          "language" => language
        }
        extra["voice"] = speaker if speaker && !speaker.to_s.empty?
        if orpheus.is_a?(Hash)
          extra["temperature"] = orpheus["temperature"]
          extra["top_p"] = orpheus["top_p"]
          extra["repetition_penalty"] = orpheus["repetition_penalty"]
        end
        request("synth", extra)
      end

      def stop!
        begin
          request("quit")
        rescue StandardError
          nil
        end
        @stdin.close unless @stdin.closed?
        @stdout.close unless @stdout.closed?
        Process.kill("TERM", @wait_thr.pid) rescue nil
        @wait_thr.join(5)
      rescue StandardError
        nil
      end
    end

    # ---- tiny TUI helpers (shared style with review) ----
    def clear_screen
      print "\e[2J\e[H" if $stdout.tty?
    end

    def term_width
      IO.console&.winsize&.[](1).to_i.clamp(40, 500)
    rescue StandardError
      80
    end

    def wrap_text(text, width)
      width = width.clamp(20, 500)
      lines = []
      text.to_s.each_line(chomp: true) do |para|
        if para.empty?
          lines << ""
          next
        end
        row = +""
        para.split(/\s+/).each do |word|
          if row.empty?
            row = word.dup
          elsif row.length + 1 + word.length <= width
            row << " " << word
          else
            lines << row
            row = word.dup
          end
        end
        lines << row unless row.empty?
      end
      lines.empty? ? [""] : lines
    end

    def pause
      print "\n[Enter] "
      stdin_line
    end

    def confirm(msg)
      print "#{msg} [y/N] "
      stdin_line.to_s.strip.downcase.start_with?("y")
    end

    def stdin_line
      line = $stdin.gets
      return nil if line.nil?

      line.chomp
    end

    def read_key
      unless $stdin.tty?
        line = stdin_line
        return nil if line.nil?

        s = line.strip
        return "\n" if s.empty?

        return s[0]
      end

      ch = $stdin.getch
      return nil if ch.nil? || ch == "\u0004"

      if ch == "\e"
        seq = +""
        if IO.select([$stdin], nil, nil, 0.05)
          begin
            loop do
              seq << $stdin.read_nonblock(8)
              break unless IO.select([$stdin], nil, nil, 0)
            end
          rescue IO::WaitReadable, EOFError, Errno::EAGAIN
          end
        end
        return :up if seq.start_with?("[A")
        return :down if seq.start_with?("[B")

        return "\e"
      end
      ch
    end
  end
end
