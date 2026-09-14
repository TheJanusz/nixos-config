# frozen_string_literal: true

require "json"
require "fileutils"
require "tmpdir"
require "open3"
require "shellwords"
require "rbconfig"
require_relative "feedback"
require_relative "vocab"
require_relative "ass"
require_relative "lektor"
require_relative "translate"
require_relative "config"
require_relative "mentor_reflect"
require_relative "mentor_undo"

module Subpipe
  # Mentor review: Ruby owns episode state; Neovim cue-list plugin.
  #
  #   subpipe review -o DIR
  #
  # Browse list (jk) + bare keys; e/t edit EN/PL; Esc back to list.
  #   p synth preview, f filter cycle, a/E/T/P accept, …
  module Mentor
    module_function

    # Review status for list coloring / filters.
    # pending = EN or PL not accepted; clean = both accepted unchanged vs model;
    # edited = both accepted with at least one side changed.
    def cue_review_status(cue)
      en_ok = !cue["en_accepted_at"].to_s.empty?
      pl_ok = !cue["pl_accepted_at"].to_s.empty?
      return "pending" unless en_ok && pl_ok

      en = normalize_cue_line(cue["text_en"])
      pl = normalize_cue_line(cue["text_pl"])
      en_model = normalize_cue_line(cue["text_en_model"])
      pl_model = normalize_cue_line(cue["text_pl_model"])
      # Missing baseline → treat that side as unchanged (avoid false "edited").
      en_changed = !en_model.empty? && en != en_model
      pl_changed = !pl_model.empty? && pl != pl_model
      (en_changed || pl_changed) ? "edited" : "clean"
    end

    def normalize_cue_line(s)
      s.to_s.gsub(/\s+/, " ").strip
    end

    def run(out_dir, vocab_path: nil, filter: :all)
      out_dir = File.expand_path(out_dir)
      nvim = ENV.fetch("SUBPIPE_NVIM", "nvim")
      Subpipe.abort!("nvim not found (set SUBPIPE_NVIM)") unless command?(nvim)

      rtp = bundled_nvim_rtp
      Subpipe.abort!("mentor nvim plugin missing (expected under nvim/subpipe)") if rtp.nil?

      context = load_context!(out_dir)
      ensure_baselines!(context)
      Feedback.ensure_project_meta!(out_dir, context)
      Feedback.ensure_speakers_dir!(out_dir, context)
      save_context!(out_dir, context) # persist filled text_*_model for honest clean/edited status

      session_dir = File.join(out_dir, "mentor-session")
      FileUtils.mkdir_p(session_dir)
      idxs = visible_indices(context["cues"], filter)
      Subpipe.abort!("no cues to review (filter=#{filter})") if idxs.empty?

      # Navigate the full list (:all) but open on the review head (first incomplete cue).
      start_cursor = resume_cursor(context["cues"], idxs)

      state = {
        "cursor" => start_cursor,
        "filter" => filter.to_s,
        "vocab_path" => vocab_path
      }
      File.write(File.join(session_dir, "state.json"), JSON.pretty_generate(state) + "\n")
      write_session_files!(session_dir, context, context["cues"][idxs[start_cursor]], start_cursor, idxs.size, filter)

      en = File.join(session_dir, "cue.en.txt")
      pl = File.join(session_dir, "cue.pl.txt")
      # Always drive mentor-action from the same package that launched this session
      # (avoids PATH "subpipe" lagging behind workspace / flake lib + Lua rtp).
      bin = ENV["SUBPIPE_BIN"].to_s.strip
      bin = write_session_bin!(session_dir) if bin.empty?

      env = ENV.to_h.merge(
        "SUBPIPE_MENTOR_OUT" => out_dir,
        "SUBPIPE_MENTOR_SESSION" => session_dir,
        "SUBPIPE_MENTOR_FILTER" => filter.to_s,
        "SUBPIPE_MENTOR_VOCAB" => vocab_path.to_s,
        "SUBPIPE_BIN" => bin,
        "SUBPIPE_NVIM_RTP" => rtp
      )

      # Bootstrap rtp + start without relying on user init
      boot = File.join(session_dir, "boot.lua")
      File.write(boot, <<~LUA)
        vim.opt.rtp:prepend(#{JSON.generate(rtp)})
        require("subpipe.mentor").start()
      LUA

      # Seed EN/PL files; Lua builds list | EN/PL layout (avoid fragile -O geometry).
      cmd = [nvim, en, "-u", "NONE", "-n", "-c", "lua dofile(#{JSON.generate(boot)})"]
      Process.wait(spawn(env, *cmd, chdir: session_dir))
      puts "Mentor session ended (#{File.join(out_dir, 'context.json')})"
    end

    # Wrapper so nvim mentor-action uses this checkout/store lib, not a stale PATH binary.
    def write_session_bin!(session_dir)
      lib_dir = File.expand_path("..", __dir__)
      cli = File.join(lib_dir, "cli.rb")
      path = File.join(session_dir, "subpipe-bin")
      File.write(path, <<~SH)
        #!/bin/sh
        exec #{Shellwords.escape(RbConfig.ruby)} -I #{Shellwords.escape(lib_dir)} #{Shellwords.escape(cli)} "$@"
      SH
      File.chmod(0o755, path)
      path
    end

    def bundled_nvim_rtp
      env = ENV["SUBPIPE_NVIM_RTP"].to_s
      return env if !env.empty? && File.directory?(File.join(env, "lua"))

      candidates = [
        File.expand_path("../../nvim/subpipe", __dir__),
        File.expand_path("../nvim/subpipe", File.dirname(__dir__))
      ]
      candidates.find { |p| File.directory?(File.join(p, "lua", "subpipe")) }
    end

    # Plugin protocol: decide without stdin. Returns { action: :skip|:ask|:auto, ... }
    def propagate_decision(out_dir, context, cue, force_ask: false)
      mode = Config.propagate_on_accept(out_dir, context)
      mode = "ask" if force_ask
      return { action: :skip } if mode == "off" && !force_ask

      draft = cue["text_pl_model"].to_s
      gold = cue["text_pl"].to_s
      unchanged = draft == gold
      return { action: :skip } if unchanged && !force_ask

      # PL span from the edit; EN is guessed by reflect from draft/gold (not jargon hits).
      _en_ignored, pl_pre = propagate_prefills(cue, context)
      case mode
      when "auto"
        reflected = MentorReflect.reflect(cue, nil, pl_pre, use_llm: true)
        unless reflected["write_vocab"]
          return { action: :skip, message: "style-only accept (no vocab); corrections.jsonl already logged" }
        end
        if reflected["term_en"].empty? || reflected["term_pl"].empty?
          return { action: :skip, message: "propagate skipped (ambiguous)" }
        end
        {
          action: :auto,
          term_en: reflected["term_en"],
          term_pl: reflected["term_pl"],
          notes: reflected["notes"],
          avoid_pl: reflected["avoid_pl"],
          kind: reflected["kind"],
          template_id: reflected["template_id"]
        }
      else
        # Ask path: reflect after the edit so term_en targets the PL change.
        warn "Reflecting edit for teach package…"
        reflected = MentorReflect.reflect(cue, nil, pl_pre, use_llm: true)
        {
          action: :ask,
          en_pre: reflected["term_en"],
          pl_pre: reflected["term_pl"].empty? ? pl_pre : reflected["term_pl"],
          notes_pre: reflected["notes"],
          avoid_pl_pre: reflected["avoid_pl"],
          kind_pre: reflected["kind"],
          template_id: reflected["template_id"],
          draft_span: reflected["draft_span"],
          gold_span: reflected["gold_span"],
          write_vocab: reflected["write_vocab"],
          reflect_pre: reflected
        }
      end
    end

    def apply_propagate!(out_dir, context, cue_index, term_en, term_pl, vocab_path: nil, notes: nil, avoid_pl: nil)
      cue = context["cues"][cue_index]
      ids = cue_ids_ahead_matching(context["cues"], cue_index, term_en)
      upsert_propagate_vocab!(
        out_dir, context, term_en, term_pl,
        vocab_path: vocab_path, notes: notes, avoid_pl: avoid_pl, cue: cue
      )
      if ids.empty?
        warn "Vocab updated for #{term_en.inspect} → #{term_pl.inspect}; no later cues match"
        return load_context!(out_dir)
      end
      warn "Propagating #{term_en.inspect} → #{term_pl.inspect} to #{ids.size} cue(s): #{ids.join(', ')}"
      begin
        Translate.retranslate_cues!(out_dir, cue_ids: ids, vocab_path: vocab_path)
      rescue StandardError => e
        warn "propagate retranslate failed: #{e.message}"
        return load_context!(out_dir)
      end
      warn "Propagated #{ids.size} cue(s)"
      load_context!(out_dir)
    end

    def propagate_prefills(cue, _context = nil)
      # EN is no longer guessed from jargon/glossary highlights — reflect does that.
      draft = cue["text_pl_model"].to_s.strip
      gold = cue["text_pl"].to_s.strip
      pl_pre = guess_pl_form_from_edit(draft, gold)
      ["", pl_pre]
    end

    # Prefer changed span vs model draft; else a short gold line as the lemma.
    def guess_pl_form_from_edit(draft, gold)
      return "" if gold.empty?

      words = gold.split(/\s+/)
      draft = draft.to_s.strip

      if !draft.empty? && draft != gold
        db = draft.split(/\s+/)
        gb = words
        i = 0
        i += 1 while i < db.size && i < gb.size && db[i] == gb[i]
        j = 0
        j += 1 while j < (db.size - i) && j < (gb.size - i) && db[db.size - 1 - j] == gb[gb.size - 1 - j]
        span = gb[i...(gb.size - j)]
        if span && !span.empty? && span.size < gb.size
          return span.join(" ")
        end
      end

      return gold if gold.length <= 48 && words.size <= 6

      ""
    end

    def cue_ids_ahead_matching(cues, cue_index, phrase)
      needle = phrase.to_s.gsub(/\s+/, " ").strip.downcase
      return [] if needle.empty?

      ids = []
      cues.each_with_index do |c, i|
        next if i <= cue_index

        hay = "#{c['text_en']} #{c['asr_text']}".gsub(/\s+/, " ").downcase
        next if hay.strip.empty?
        next unless hay.include?(needle)

        ids << c["id"]
      end
      ids
    end

    def upsert_propagate_vocab!(out_dir, context, term_en, term_pl, vocab_path: nil, notes: nil, avoid_pl: nil, cue: nil)
      video_path = context.dig("source", "path")
      start_dir = if video_path && File.directory?(File.dirname(video_path))
                    File.dirname(video_path)
                  else
                    out_dir
                  end
      path = if vocab_path && !vocab_path.to_s.empty?
               File.expand_path(vocab_path)
             else
               Vocab.default_promote_path(start_dir: start_dir, video_path: video_path, local: false)
             end
      store = File.file?(path) ? Vocab.load_file(path) : Vocab.empty_store
      before_entry = MentorUndo.deep_copy(MentorUndo.find_term_entry(store, term_en))
      cue_before = cue ? MentorUndo.cue_snapshot(cue) : nil
      note = notes.to_s.strip
      note = "Canonical/lemma form; inflect for Polish case/number/gender as needed." if note.empty?
      avoid = Array(avoid_pl).map { |x| x.to_s.strip }.reject(&:empty?)
      if avoid.empty? && note.match?(/show\/setting|\"w\" \+ locative|prefer Polish \"w\"/i)
        avoid << "na #{term_pl}"
      end
      Vocab.add_term!(
        store,
        term: term_en,
        preferred_translations: [term_pl],
        avoid_pl: avoid,
        notes: note
      )
      Vocab.save_file!(path, store)
      after_entry = MentorUndo.deep_copy(MentorUndo.find_term_entry(store, term_en))
      warn "Vocab ← #{term_en.inspect} → #{term_pl.inspect} notes=#{note[0, 80].inspect} avoid=#{avoid.inspect} (#{path})"

      context["glossary"] = Vocab.merge_into_glossary(Array(context["glossary"]), store)
      File.write(File.join(out_dir, "context.json"), JSON.pretty_generate(context) + "\n")

      if cue
        MentorUndo.record_vocab!(
          out_dir, context, cue,
          cue_before: cue_before,
          vocab_path: path,
          term: term_en,
          before_entry: before_entry,
          after_entry: after_entry
        )
      end
    end

    def advance_after_accept(_idxs, cues, cursor, filter)
      idxs = visible_indices(cues, filter)
      return 0 if idxs.empty?

      case Mentor.normalize_filter(filter)
      when :pending, :edited, :clean
        # Cue may drop out of filter → same index is the next remaining cue.
        [cursor, idxs.size - 1].min
      else
        # Full list (:all / :flagged): step forward past the cue just accepted.
        [cursor + 1, idxs.size - 1].min
      end
    end

    # Index into idxs for the first cue that still needs EN or PL accept.
    # Falls back to 0 when everything is accepted.
    def resume_cursor(cues, idxs)
      found = idxs.index do |i|
        cue = cues[i]
        cue["pl_accepted_at"].to_s.empty? || cue["en_accepted_at"].to_s.empty?
      end
      found || 0
    end

    def normalize_filter(filter)
      f = filter.to_s.to_sym
      f = :pending if f == :unaccepted
      f
    end

    def visible_indices(cues, filter)
      filter = normalize_filter(filter)
      cues.each_index.select do |i|
        cue = cues[i]
        status = cue_review_status(cue)
        case filter
        when :pending
          status == "pending"
        when :edited
          status == "edited"
        when :clean
          status == "clean"
        when :flagged
          cue["needs_review"]
        else
          true
        end
      end
    end

    def ensure_baselines!(context)
      Array(context["cues"]).each do |cue|
        cue["text_en_model"] = cue["text_en"].to_s if cue["text_en_model"].to_s.empty?
        cue["text_pl_model"] = cue["text_pl"].to_s if cue["text_pl_model"].to_s.empty? && !cue["text_pl"].to_s.empty?
      end
    end

    def truncate_preview(s, max = 48)
      t = normalize_cue_line(s)
      return t if t.length <= max

      "#{t[0, max - 1]}…"
    end

    def write_cue_list!(session_dir, context, idxs, filter)
      rows = idxs.map do |i|
        cue = context["cues"][i]
        {
          "id" => cue["id"],
          "en" => truncate_preview(cue["text_en"]),
          "pl" => truncate_preview(cue["text_pl"]),
          "en_ok" => !cue["en_accepted_at"].to_s.empty?,
          "pl_ok" => !cue["pl_accepted_at"].to_s.empty?,
          "status" => cue_review_status(cue),
          "flagged" => !!cue["needs_review"]
        }
      end
      payload = {
        "filter" => normalize_filter(filter).to_s,
        "cues" => rows
      }
      File.write(File.join(session_dir, "cues.list.json"), JSON.pretty_generate(payload) + "\n")
    end

    def write_session_files!(session_dir, context, cue, cursor, total, filter)
      # Single-line editor buffers — collapse accidental newlines so reload never
      # shows duplicated blank rows from a polluted buffer write.
      en_line = normalize_cue_line(cue["text_en"])
      pl_line = normalize_cue_line(cue["text_pl"])
      File.write(File.join(session_dir, "cue.en.txt"), en_line + "\n")
      File.write(File.join(session_dir, "cue.pl.txt"), pl_line + "\n")
      dir_note = File.join(session_dir, "direction.txt")
      File.write(dir_note, "") unless File.file?(dir_note)
      meta = {
        "cue_id" => cue["id"],
        "index" => cursor + 1,
        "total" => total,
        "filter" => normalize_filter(filter).to_s,
        "status" => cue_review_status(cue),
        "emotion" => cue["emotion"],
        "delivery" => cue["delivery"],
        "speakers" => cue["speakers"],
        "en_accepted_at" => cue["en_accepted_at"],
        "pl_accepted_at" => cue["pl_accepted_at"],
        "names" => cue["review_names"] || cue["names"],
        "keep_english" => cue["review_keep_english"] || cue["keep_english"],
        "jargon" => cue["review_jargon"] || cue["jargon"],
        "glossary_terms" => Array(context["glossary"]).map { |g| g["term"] }.compact
      }
      File.write(File.join(session_dir, "meta.json"), JSON.pretty_generate(meta) + "\n")
      File.write(File.join(session_dir, "highlights.txt"), highlight_terms(cue).join("\n") + "\n")
      # idxs for list = visible under current filter; rebuild from context
      idxs = visible_indices(context["cues"], filter)
      write_cue_list!(session_dir, context, idxs, filter)
    end

    # Visual-only: names + keep_english + Latin leftovers in PL that also appear in EN.
    # Not used for teach/propagate EN guessing.
    def highlight_terms(cue)
      words = []
      words.concat(Array(cue["review_names"] || cue["names"]))
      words.concat(Array(cue["review_keep_english"] || cue["keep_english"]))
      words.concat(en_leftovers_in_pl(cue["text_en"], cue["text_pl"]))
      words.map(&:to_s).map(&:strip).reject(&:empty?).uniq
    end

    HIGHLIGHT_STOP = %w[
      a an the and or but if of to in on at for from with as is are was were be
      i you he she it we they my your ok oh ah um hmm
    ].freeze

    def en_leftovers_in_pl(text_en, text_pl)
      en = text_en.to_s
      pl = text_pl.to_s
      return [] if en.empty? || pl.empty?

      en_set = en.scan(/\b[A-Za-z][A-Za-z0-9'\-]{1,}\b/).map(&:downcase).uniq
      en_set -= HIGHLIGHT_STOP
      pl.scan(/\b[A-Za-z][A-Za-z0-9'\-]{1,}\b/).select do |tok|
        next false if tok.length < 2
        next false if HIGHLIGHT_STOP.include?(tok.downcase)

        en_set.include?(tok.downcase)
      end.uniq
    end

    def load_context!(out_dir)
      path = File.join(out_dir, "context.json")
      Subpipe.abort!("missing #{path}") unless File.file?(path)
      JSON.parse(File.read(path))
    end

    def save_context!(out_dir, context)
      File.write(File.join(out_dir, "context.json"), JSON.pretty_generate(context) + "\n")
      draft_path = File.join(out_dir, "translation-draft.json")
      return unless File.file?(draft_path)

      draft = JSON.parse(File.read(draft_path))
      by_id = Array(draft["translations"]).to_h { |t| [t["id"], t] }
      context["cues"].each do |cue|
        t = by_id[cue["id"]] || { "id" => cue["id"] }
        t["text_en"] = cue["text_en"]
        t["text_pl"] = cue["text_pl"]
        by_id[cue["id"]] = t
      end
      draft["translations"] = by_id.values
      File.write(draft_path, JSON.pretty_generate(draft) + "\n")
    end

    def generate_preview!(out_dir, context, cue, session_dir, play: true)
      text = cue["text_pl"].to_s.strip
      if text.empty?
        warn "nothing to synth for #{cue['id']}"
        return { ok: false, message: "nothing to synth" }
      end
      voice = Lektor.load_or_init_voice(out_dir)
      wav = File.join(session_dir, "preview.wav")
      ref = Lektor.resolve_reference(out_dir, voice)
      begin
        Lektor.with_worker(voice: voice, reference: ref) do |worker|
          Lektor.preview_cue_to_path!(out_dir, worker, voice, cue, wav)
        end
        File.write(File.join(session_dir, "last_preview.json"), JSON.generate({
          "wav" => wav,
          "text" => text,
          "orpheus" => Lektor.effective_orpheus(voice, cue),
          "emotion" => cue["emotion"],
          "delivery" => cue["delivery"]
        }))
        play_wav(wav) if play
        warn "Preview → #{wav}  (A to accept take)"
        { ok: true, wav: wav, message: "preview ready" }
      rescue StandardError => e
        warn "generate failed: #{e.message}"
        { ok: false, message: "generate failed: #{e.message}" }
      end
    end

    def accept_voice_take!(out_dir, context, cue, session_dir)
      meta_path = File.join(session_dir, "last_preview.json")
      unless File.file?(meta_path)
        warn "no preview to accept; press p first"
        return "no preview"
      end
      meta = JSON.parse(File.read(meta_path))
      dest_dir = File.join(out_dir, Lektor::LEKTOR_DIR)
      FileUtils.mkdir_p(dest_dir)
      dest = File.join(dest_dir, "#{cue['id']}.wav")
      FileUtils.cp(meta["wav"], dest) if File.file?(meta["wav"])
      direction = File.join(session_dir, "direction.txt")
      note = File.file?(direction) ? File.read(direction).to_s.strip : ""
      Feedback.append_voice_take!(out_dir, {
        "cue_id" => cue["id"],
        "text" => meta["text"],
        "wav" => dest,
        "orpheus" => meta["orpheus"],
        "emotion" => meta["emotion"],
        "delivery" => meta["delivery"],
        "direction_note" => note.empty? ? nil : note,
        "speaker_id" => Feedback.primary_speaker(cue),
        "voice" => Lektor.load_or_init_voice(out_dir)["voice"],
        "accepted" => true
      }, context: context)
      cue["voice_accepted_at"] = Time.now.utc.iso8601
      msg = "Voice take accepted → #{Feedback.voice_takes_path(out_dir, context)}"
      warn msg
      msg
    end

    def play_wav(path)
      %w[ffplay mpv aplay].each do |bin|
        next unless command?(bin)

        case bin
        when "ffplay"
          system(bin, "-nodisp", "-autoexit", "-loglevel", "quiet", path)
        when "mpv"
          system(bin, "--no-video", "--really-quiet", path)
        else
          system(bin, path)
        end
        return
      end
      warn "no ffplay/mpv/aplay to play #{path}"
    end

    def command?(name)
      ENV["PATH"].to_s.split(File::PATH_SEPARATOR).any? { |d| File.executable?(File.join(d, name)) }
    end
  end
end
