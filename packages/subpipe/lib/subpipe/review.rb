# frozen_string_literal: true

require "json"
require "fileutils"
require "io/console"
require_relative "translate"
require_relative "vocab"
require_relative "ass"

module Subpipe
  # Interactive review UI for translation drafts (stdlib only; no embedded player).
  # Single-cue browser: full wrapped EN/PL, j/k navigation (yazi-style).
  # Future: optional preview of generated lektor audio once that stage exists.
  module Review
    module_function

    def run(out_dir, vocab_path: nil)
      out_dir = File.expand_path(out_dir)
      Subpipe.abort!("missing #{File.join(out_dir, 'context.json')}; run merge first") unless File.file?(File.join(out_dir, "context.json"))

      state = load_state!(out_dir, vocab_path: vocab_path)
      filter = :flagged # :flagged | :all
      clamp_cursor!(state, filter)

      loop do
        clear_screen
        print_header(state, filter)
        print_focused_cue(state, filter)
        puts
        puts menu_lines(filter)
        key = read_key
        break if key.nil?

        case key
        when "q"
          if state[:dirty] && !confirm("Unsaved changes. Quit anyway?")
            next
          end
          puts "Bye."
          break
        when "f"
          filter = filter == :flagged ? :all : :flagged
          clamp_cursor!(state, filter)
        when "j", :down
          move_cursor!(state, filter, +1)
        when "k", :up
          move_cursor!(state, filter, -1)
        when "0"
          state[:cursor] = 0
          clamp_cursor!(state, filter)
        when "G"
          idxs = visible_indices(state, filter)
          state[:cursor] = [idxs.size - 1, 0].max
        when "e"
          with_focused_translation(state, filter) { |t, _cue| edit_polish!(state, t) }
        when "m"
          with_focused_translation(state, filter) { |_t, cue| edit_emotion!(state, cue) }
        when "t"
          with_focused_translation(state, filter) do |t, _cue|
            t["needs_review"] = !t["needs_review"]
            state[:dirty] = true
            clamp_cursor!(state, filter)
          end
        when "c"
          with_focused_translation(state, filter) do |t, _cue|
            t["names"] = []
            t["jargon"] = []
            t["keep_english"] = []
            t["needs_review"] = false
            state[:dirty] = true
            clamp_cursor!(state, filter)
          end
        when "s"
          save_draft!(state, pause: true)
        when "a"
          save_draft!(state, pause: false) if state[:dirty]
          apply!(state)
        when "v"
          promote!(state)
        when "g"
          edit_glossary!(state)
        when "w"
          save_draft!(state, pause: false) if state[:dirty]
          write_preview_ass!(state)
        when "r"
          if state[:dirty] && !confirm("Reload and discard unsaved edits?")
            next
          end
          state = load_state!(out_dir, vocab_path: vocab_path)
          clamp_cursor!(state, filter)
        when "h", "?"
          print_help
          pause
        when "\r", "\n"
          # ignore Enter on main view
        else
          # unknown key — ignore (no pause spam while browsing)
        end
      end
    end

    def load_state!(out_dir, vocab_path: nil)
      context = JSON.parse(File.read(File.join(out_dir, "context.json")))
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
      context["glossary"] = Vocab.merge_into_glossary(Array(context["glossary"]), show_store)
      context["assets"] ||= {}
      context["assets"].merge!(vocab_meta)

      draft_path = File.join(out_dir, "translation-draft.json")
      draft =
        if File.file?(draft_path)
          JSON.parse(File.read(draft_path))
        else
          draft_from_context(context)
        end

      sync_draft_from_context_flags!(draft, context)

      {
        out_dir: out_dir,
        context: context,
        draft: draft,
        vocab_path: vocab_meta["show_vocab"],
        episode_vocab: vocab_meta["episode_vocab"],
        vocab_files: vocab_files,
        start_dir: start_dir,
        video_path: video_path,
        cursor: 0,
        dirty: false
      }
    end

    def draft_from_context(context)
      {
        "schema_version" => Subpipe::SCHEMA_VERSION,
        "target_language" => "pl",
        "translations" => Array(context["cues"]).map do |cue|
          {
            "id" => cue["id"],
            "text_en" => cue["text_en"],
            "text_pl" => cue["text_pl"].to_s,
            "names" => Array(cue["review_names"]),
            "jargon" => Array(cue["review_jargon"]),
            "keep_english" => Array(cue["review_keep_english"]),
            "needs_review" => cue["needs_review"] != false && (
              cue["needs_review"] == true ||
              Array(cue["review_names"]).any? ||
              Array(cue["review_jargon"]).any? ||
              Array(cue["review_keep_english"]).any? ||
              cue["text_pl"].to_s.strip.empty?
            ),
            "skipped" => false
          }
        end
      }
    end

    def sync_draft_from_context_flags!(draft, context)
      by_id = Array(context["cues"]).to_h { |c| [c["id"], c] }
      Array(draft["translations"]).each do |t|
        cue = by_id[t["id"]]
        next unless cue

        t["text_en"] ||= cue["text_en"]
        if t["text_pl"].to_s.empty? && cue["text_pl"]
          t["text_pl"] = cue["text_pl"]
        end
      end
    end

    def print_header(state, filter)
      draft = state[:draft]
      translations = Array(draft["translations"])
      flagged = translations.count { |t| t["needs_review"] }
      empty = translations.count { |t| t["text_pl"].to_s.strip.empty? }
      idxs = visible_indices(state, filter)
      pos = idxs.empty? ? 0 : state[:cursor] + 1
      puts "subpipe review — #{state[:out_dir]}"
      puts "cues: #{translations.size}  flagged: #{flagged}  empty PL: #{empty}  filter: #{filter}" \
           "  viewing: #{pos}/#{idxs.size}" \
           "#{state[:dirty] ? '  *unsaved*' : ''}"
      puts "vocab: #{state[:vocab_path] || '(none)'}  episode: #{state[:episode_vocab] || '(none)'}"
      files = Array(state[:vocab_files])
      puts "loaded: #{files.join(' → ')}" unless files.empty?
      puts "-" * [term_width, 72].min
    end

    def print_focused_cue(state, filter)
      idxs = visible_indices(state, filter)
      if idxs.empty?
        puts "(no cues in this filter — press f to show all)"
        return
      end

      ti = idxs[state[:cursor]]
      t = state[:draft]["translations"][ti]
      cue = Array(state[:context]["cues"]).find { |c| c["id"] == t["id"] } || {}
      width = term_width
      mark = t["needs_review"] ? "*" : " "
      empty = t["text_pl"].to_s.strip.empty? ? "!" : " "

      puts "#{mark}#{empty} #{t['id']}"
      puts
      puts "EN:"
      wrap_text(t["text_en"].to_s, width).each { |line| puts line }
      puts
      puts "PL:"
      wrap_text(t["text_pl"].to_s, width).each { |line| puts line }
      puts
      emo = cue["emotion"] || "-"
      del = cue["delivery"] || "-"
      inten = cue["emotion_intensity"] || "-"
      puts "emotion: #{emo}  intensity: #{inten}  delivery: #{del}"
      if cue["prosody"]
        puts "prosody: mean=#{cue.dig('prosody', 'mean_db')} dB  max=#{cue.dig('prosody', 'max_db')} dB"
      end
      flags = format_flags(t)
      puts "flags: #{flags.empty? ? '—' : flags}  needs_review: #{t['needs_review']}"
    end

    def menu_lines(filter)
      other = filter == :flagged ? "all" : "flagged"
      [
        "[j]/[k] next/prev   [0]/[G] first/last   [e] edit PL   [m] emotion   [t] toggle review   [c] clear flags",
        "[f] show #{other}   [g] glossary   [s] save   [a] apply   [v] promote   [w] ass preview   [r] reload   [h] help   [q] quit"
      ]
    end

    def print_help
      puts <<~HELP

        Review TUI (single-cue browser)
          j / ↓     next cue
          k / ↑     previous cue
          0         first cue
          G         last cue
          e         edit Polish text
          m         emotion / intensity / delivery
          t         toggle needs_review
          c         clear flags
          f         toggle flagged ↔ all
          g         glossary editor
          s / a / v save draft / apply / promote vocab
          w / r / q ass preview / reload / quit

          Flagged cues are those with needs_review (names/jargon/keep-EN).
          EN/PL are fully wrapped to the terminal width (no truncation).

          Workflow tip:
            1) subpipe analyze (emotion/delivery on cues)
            2) translate --mode draft → fix flagged cues / glossary / emotion in review
            3) save → apply → promote vocab
      HELP
    end

    def visible_indices(state, filter)
      translations = Array(state[:draft]["translations"])
      translations.each_index.select do |i|
        filter == :all || translations[i]["needs_review"]
      end
    end

    def clamp_cursor!(state, filter)
      idxs = visible_indices(state, filter)
      state[:cursor] = 0 if state[:cursor].nil?
      if idxs.empty?
        state[:cursor] = 0
      elsif state[:cursor] >= idxs.size
        state[:cursor] = idxs.size - 1
      elsif state[:cursor].negative?
        state[:cursor] = 0
      end
    end

    def move_cursor!(state, filter, delta)
      idxs = visible_indices(state, filter)
      return if idxs.empty?

      state[:cursor] = [[state[:cursor] + delta, 0].max, idxs.size - 1].min
    end

    def with_focused_translation(state, filter)
      idxs = visible_indices(state, filter)
      return if idxs.empty?

      ti = idxs[state[:cursor]]
      t = state[:draft]["translations"][ti]
      cue = Array(state[:context]["cues"]).find { |c| c["id"] == t["id"] } || {}
      yield t, cue
    end

    def edit_polish!(state, t)
      puts "New Polish text (empty keeps current):"
      print "> "
      line = stdin_line
      return if line.nil?

      unless line.strip.empty?
        t["text_pl"] = line.rstrip
        state[:dirty] = true
      end
    end

    def edit_emotion!(state, cue)
      puts "Emotions: #{Subpipe::Analyze::EMOTIONS.join(', ')}"
      print "emotion [#{cue['emotion']}]: "
      line = stdin_line
      unless line.nil? || line.strip.empty?
        val = line.strip.downcase
        if Subpipe::Analyze::EMOTIONS.include?(val)
          cue["emotion"] = val
          state[:dirty] = true
        else
          puts "Unknown emotion; keeping #{cue['emotion']}"
          pause
          return
        end
      end
      print "intensity 0..1 [#{cue['emotion_intensity']}]: "
      line = stdin_line
      unless line.nil? || line.strip.empty?
        begin
          cue["emotion_intensity"] = [[Float(line.strip), 0.0].max, 1.0].min.round(3)
          state[:dirty] = true
        rescue ArgumentError
          puts "Invalid number."
          pause
        end
      end
      puts "Delivery: #{Subpipe::Analyze::DELIVERIES.join(', ')}"
      print "delivery [#{cue['delivery']}]: "
      line = stdin_line
      return if line.nil? || line.strip.empty?

      val = line.strip.downcase
      if Subpipe::Analyze::DELIVERIES.include?(val)
        cue["delivery"] = val
        state[:dirty] = true
      else
        puts "Unknown delivery; keeping #{cue['delivery']}"
        pause
      end
    end

    def edit_glossary!(state)
      glossary = Array(state[:context]["glossary"])
      loop do
        clear_screen
        puts "Glossary (#{glossary.size} terms) — preferred PL list / avoid_pl for show quirks"
        glossary.first(40).each_with_index do |g, i|
          pref = Vocab.preferred_list(g)
          pref_s = pref.empty? ? "-" : pref.join("|")
          avoid = Array(g["avoid_pl"]).join(",")
          avoid = "-" if avoid.empty?
          puts format("%2d. %-20s  PL:%-20s  avoid:%-16s  %s", i + 1, truncate(g["term"], 20), truncate(pref_s, 20), truncate(avoid, 16), g["notes"])
        end
        puts "…" if glossary.size > 40
        puts
        puts "[#] edit term   [a] add term   [b] back"
        print "> "
        c = stdin_line
        break if c.nil? || c.strip.downcase == "b"

        if c.strip.downcase == "a"
          print "English term: "
          term = stdin_line
          next if term.nil? || term.strip.empty?

          print "Preferred Polish forms (comma-separated, blank = none): "
          pl = stdin_line
          print "Avoid Polish forms (comma-separated): "
          avoid = stdin_line
          prefs = pl.to_s.split(",").map(&:strip).reject(&:empty?)
          entry = {
            "term" => term.strip,
            "count" => 0,
            "sources" => ["manual"],
            "avoid_pl" => avoid.to_s.split(",").map(&:strip).reject(&:empty?),
            "notes" => "added in review TUI"
          }
          Vocab.apply_preferred!(entry, prefs, replace: true)
          glossary << Vocab.normalize_term!(entry)
          state[:context]["glossary"] = glossary
          state[:dirty] = true
          next
        end

        next unless c.strip.match?(/\A\d+\z/)

        i = c.to_i - 1
        g = glossary[i]
        next unless g

        current = Vocab.preferred_list(g).join(",")
        puts "Editing #{g['term']}"
        print "preferred_translations comma-list [#{current}]: "
        pl = stdin_line
        unless pl.nil?
          if pl.strip == "-"
            Vocab.apply_preferred!(g, [], replace: true)
          elsif !pl.strip.empty?
            Vocab.apply_preferred!(g, pl.split(",").map(&:strip), replace: true)
          end
        end
        print "avoid_pl comma-list [#{Array(g['avoid_pl']).join(',')}]: "
        avoid = stdin_line
        unless avoid.nil?
          if avoid.strip == "-"
            g["avoid_pl"] = []
          elsif !avoid.strip.empty?
            g["avoid_pl"] = avoid.split(",").map(&:strip).reject(&:empty?)
          end
        end
        print "notes [#{g['notes']}]: "
        notes = stdin_line
        g["notes"] = notes.strip unless notes.nil? || notes.strip.empty?
        Vocab.normalize_term!(g)
        state[:context]["glossary"] = glossary
        state[:dirty] = true
      end
    end

    def save_draft!(state, pause: true)
      out = state[:out_dir]
      File.write(File.join(out, "context.json"), JSON.pretty_generate(state[:context]))
      Translate.write_draft_files!(out, state[:draft])
      state[:dirty] = false
      puts "Saved translation-draft.json, translation-review.md, context.json"
      pause() if pause
    end

    def apply!(state)
      out = state[:out_dir]
      File.write(File.join(out, "context.json"), JSON.pretty_generate(state[:context]))
      Translate.write_draft_files!(out, state[:draft])
      Translate.apply_draft!(out, state[:draft])
      state[:dirty] = false
      state[:context] = JSON.parse(File.read(File.join(out, "context.json")))
      sync_draft_from_context_flags!(state[:draft], state[:context])
      puts "Applied → context.json + *.pl.ass"
      pause
    end

    def promote!(state)
      path = state[:vocab_path]
      if path.nil? || path.empty?
        path = Vocab.default_promote_path(
          start_dir: state[:start_dir] || state[:out_dir],
          video_path: state[:video_path] || state[:context].dig("source", "path"),
          local: false
        )
        state[:vocab_path] = path
      end
      puts "Promote target: #{path}"
      print "Promote here? [Y=show / L=episode local / path / N=cancel] "
      raw = stdin_line
      return if raw.nil?

      choice = raw.strip
      case choice.downcase
      when "", "y", "yes"
        # keep path
      when "l", "local"
        path = Vocab.default_promote_path(
          start_dir: state[:start_dir] || state[:out_dir],
          video_path: state[:video_path] || state[:context].dig("source", "path"),
          local: true
        )
        state[:episode_vocab] = path
      when "n", "no", "c", "cancel"
        return
      else
        path = Vocab.resolve_path(choice)
        state[:vocab_path] = path
      end

      save_draft!(state, pause: false) if state[:dirty]
      store = File.file?(path) ? Vocab.load_file(path) : Vocab.empty_store
      stats = Vocab.promote_from_context!(store, state[:context])
      Vocab.save_file!(path, store)
      puts "Promoted into #{path}: +#{stats[:added]} new, #{stats[:updated]} updated (#{stats[:total]} total)"
      pause
    end

    def write_preview_ass!(state)
      out = state[:out_dir]
      by_id = Array(state[:draft]["translations"]).to_h { |t| [t["id"], t] }
      cues = Array(state[:context]["cues"]).map do |cue|
        t = by_id[cue["id"]]
        cue.merge("text_pl" => t ? t["text_pl"] : cue["text_pl"])
      end
      stem = Subpipe.source_stem(state[:context]["source"] || {})
      path = Subpipe.ass_path(out, stem, "pl")
      Ass.write(path, cues, title: "#{state[:context].dig('source', 'basename') || 'subpipe'} (pl)", text_key: "text_pl")
      puts "Wrote #{path}"
      pause
    end

    def format_flags(t)
      parts = []
      parts << "n:#{Array(t['names']).join(',')}" unless Array(t["names"]).empty?
      parts << "j:#{Array(t['jargon']).join(',')}" unless Array(t["jargon"]).empty?
      parts << "k:#{Array(t['keep_english']).join(',')}" unless Array(t["keep_english"]).empty?
      parts.empty? ? "" : parts.join(" ")
    end

    def truncate(text, len)
      s = text.to_s.gsub(/\s+/, " ")
      return s if s.length <= len

      "#{s[0, len - 1]}…"
    end

    def term_width
      cols = IO.console&.winsize&.[](1)
      w = cols.to_i
      w = 80 if w < 40
      w
    rescue StandardError
      80
    end

    def wrap_text(text, width)
      width = [[width.to_i, 20].max, 500].min
      lines = []
      text.to_s.each_line(chomp: true) do |para|
        if para.empty?
          lines << ""
          next
        end
        words = para.split(/\s+/)
        row = +""
        words.each do |word|
          if row.empty?
            if word.length > width
              word.chars.each_slice(width) { |chunk| lines << chunk.join }
              row = +""
            else
              row = word.dup
            end
          elsif row.length + 1 + word.length <= width
            row << " " << word
          else
            lines << row
            if word.length > width
              word.chars.each_slice(width) { |chunk| lines << chunk.join }
              row = +""
            else
              row = word.dup
            end
          end
        end
        lines << row unless row.empty?
      end
      lines.empty? ? [""] : lines
    end

    def clear_screen
      print "\e[2J\e[H" if $stdout.tty?
    end

    def pause
      print "\n[Enter] "
      stdin_line
    end

    def confirm(msg)
      print "#{msg} [y/N] "
      line = stdin_line
      line.to_s.strip.downcase.start_with?("y")
    end

    def stdin_line
      line = $stdin.gets
      return nil if line.nil?

      line.chomp
    end

    # Single key on TTY (getch); line+Enter when not a TTY.
    # Returns String key, :up/:down for arrows, or nil on EOF.
    def read_key
      unless $stdin.tty?
        line = stdin_line
        return nil if line.nil?

        s = line.strip
        return "\n" if s.empty?

        return s[0]
      end

      ch = $stdin.getch
      return nil if ch.nil? || ch == "\u0004" # Ctrl-D

      if ch == "\e"
        seq = read_escape_suffix
        return :up if seq.start_with?("[A")
        return :down if seq.start_with?("[B")

        return "\e"
      end

      ch
    end

    def read_escape_suffix
      return "" unless IO.select([$stdin], nil, nil, 0.05)

      buf = +""
      begin
        loop do
          buf << $stdin.read_nonblock(8)
          break unless IO.select([$stdin], nil, nil, 0)
        end
      rescue IO::WaitReadable, EOFError, Errno::EAGAIN
      end
      buf
    end
  end
end
