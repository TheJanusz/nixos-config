#!/usr/bin/env ruby
# frozen_string_literal: true

# Find audiobook chapter starts and rewrite the .cue for split-cue.
#
#   chapters init book.mp3
#   # skip title/credits, listen to how chapter 1 starts, edit book.pattern.yml
#   chapters detect book.mp3          # one Whisper pass, book.vtt, dry-run chapters
#   chapters detect book.mp3 --write  # also rewrite book.cue
#   chapters preview book.cue
#   split-cue book.cue

require "json"
require "yaml"
require "optparse"
require "fileutils"
require "io/console"
require "tmpdir"
require "shellwords"

lib = File.expand_path("../lib", __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "whisper_cli"

module Chapters
  module_function

  FOLD = {
    "ą" => "a", "ć" => "c", "ę" => "e", "ł" => "l", "ń" => "n",
    "ó" => "o", "ś" => "s", "ź" => "z", "ż" => "z"
  }.freeze

  PLAY_S = 30
  TITLE_WORDS = 8
  NUMBER_WORDS = %w[
    pierwszy pierwsza pierwsze drugi druga drugie trzeci trzecia trzecie
    czwarty czwarta czwarte piaty piata piate szosty szosta szoste
    siodmy siodma siodme osmy osma osme dziewiaty dziewiata dziewiate
    dziesiaty dziesiata dziesiate jedenasty jedenasta dwunasty dwunasta
    trzynasty trzynasta czternasty czternasta pietnasty pietnasta
    szesnasty szesnasta siedemnasty siedemnasta osiemnasty osiemnasta
    dziewietnasty dziewietnasta dwudziesty dwudziesta
  ].freeze

  def main(argv)
    cmd = argv.shift
    case cmd
    when "init" then cmd_init(argv)
    when "detect" then cmd_detect(argv)
    when "preview" then cmd_preview(argv)
    when "-h", "--help", nil then usage
    else
      warn "unknown command: #{cmd}"
      usage(1)
    end
  end

  def usage(code = 0)
    warn <<~TXT
      chapters init AUDIO
      chapters detect AUDIO [-p pattern.yml] [--cue FILE] [--model PATH] [--write] [--chapter-titles]
      chapters preview [CUE|AUDIO] [--chapter-titles]

      Skip the opening title/credits. Listen to how chapter 1 starts, then set
      patterns in *.pattern.yml. detect transcribes the whole file once, then
      re-reads pauses that produced no cue, writes book.vtt, and prints chapter
      guesses. The transcript is cached in *.chapters-cache.json (pattern edits
      do not re-run Whisper). A newer book.vtt is reused after that pause fill
      is cached. --write updates the .cue.
      Chapter titles include the words after the number. --no-chapter-titles
      keeps the number only (or set chapter_titles: false in the pattern file).
      preview plays ~30s at each INDEX:
        Enter next   b back   d drop   e edit title   n transcript   r redetect
        +/- nudge 0.5s   w write cue   q quit
      Then: split-cue book.cue
      Whisper: SUBPIPE_WHISPER_MODEL or --model, SUBPIPE_WHISPER_BIN or whisper-cli.
    TXT
    exit code
  end

  def cmd_init(argv)
    audio = argv.shift
    usage if audio.nil? || audio == "-h"
    audio = File.expand_path(audio)
    abort "audio not found: #{audio}" unless File.file?(audio)

    path = pattern_path_for(audio)
    if File.file?(path)
      puts "pattern already exists: #{path}"
      exit 0
    end
    File.write(path, <<~YAML)
      # Skip the opening title and credits. Listen to how chapter 1 starts,
      # then edit patterns (and language). English: language en,
      # patterns like '^chapter' or '^„', title '$text'.
      # chapter_titles: false keeps the number only. Otherwise the words after
      # the number are filled in, and you can edit a title in preview.
      language: pl
      min_gap_min: 8
      preamble_title: Credits
      patterns:
        - '^rozdział'
        - '^rozdzial'
      title: 'Rozdział $n'
    YAML
    puts "Wrote #{path}"
    puts "Skip title/credits, listen to how chapter 1 starts, fill patterns."
  end

  def cmd_detect(argv)
    options = { write: false, pattern: nil, cue: nil, model: nil, chapter_titles: nil }
    parser = OptionParser.new do |opts|
      opts.on("-p", "--pattern PATH", "pattern.yml") { |v| options[:pattern] = v }
      opts.on("--cue FILE", "cue sheet to update") { |v| options[:cue] = v }
      opts.on("--model PATH", "whisper ggml model") { |v| options[:model] = v }
      opts.on("--write", "rewrite the cue (keeps the first .bak)") { options[:write] = true }
      opts.on("--[no-]chapter-titles", "append words after the chapter number") { |v| options[:chapter_titles] = v }
      opts.on("-h", "--help") { usage }
    end
    parser.parse!(argv)
    audio = argv.shift
    usage if audio.nil?
    audio = File.expand_path(audio)
    abort "audio not found: #{audio}" unless File.file?(audio)

    cfg_path = options[:pattern] ? File.expand_path(options[:pattern]) : pattern_path_for(audio)
    abort "missing #{cfg_path}; run: chapters init #{audio}" unless File.file?(cfg_path)
    cfg = YAML.safe_load(File.read(cfg_path), permitted_classes: [], aliases: false) || {}
    cue_path = options[:cue] ? File.expand_path(options[:cue]) : cue_path_for(audio)

    language = (cfg["language"] || "pl").to_s
    patterns = Array(cfg["patterns"]).map(&:to_s).reject(&:empty?)
    segments = load_segments(audio, language, model: options[:model], patterns: patterns)
    vtt_path = vtt_path_for(audio)
    cue_count = write_vtt!(vtt_path, segments)
    puts "Wrote #{vtt_path} (#{cue_count} cues)"

    tracks = classify(segments, cfg, chapter_titles: chapter_titles_enabled?(cfg, options[:chapter_titles]))
    chapters = tracks.count { |t| t[:kind] == :chapter }
    if tracks.empty? || chapters.zero?
      warn "no chapter matches (#{tracks.size} preamble). Tweak patterns in #{cfg_path}"
      tracks.each { |t| print_hit(t) }
      exit 1
    end
    tracks.each { |t| print_hit(t) }
    puts "#{chapters} chapter(s), #{tracks.size} track(s)"
    if options[:write]
      write_cue!(cue_path, audio, tracks, existing: File.file?(cue_path) ? File.read(cue_path) : nil)
      puts "Wrote #{cue_path}"
    else
      puts "Dry run. Re-run with --write to update #{cue_path}"
    end
  end

  def cmd_preview(argv)
    options = { chapter_titles: nil }
    parser = OptionParser.new do |opts|
      opts.on("--[no-]chapter-titles", "append words after the chapter number") { |v| options[:chapter_titles] = v }
      opts.on("-h", "--help") { usage }
    end
    parser.parse!(argv)
    target = argv.shift
    usage if target.nil? || target == "-h"
    abort "preview needs a terminal" unless $stdin.tty?

    target = File.expand_path(target)
    if target.end_with?(".cue")
      cue_path = target
      audio = audio_from_cue(cue_path)
    else
      audio = target
      cue_path = cue_path_for(audio)
    end
    abort "missing cue: #{cue_path}" unless File.file?(cue_path)
    abort "audio not found: #{audio}" unless audio && File.file?(audio)

    sheet = parse_cue(File.read(cue_path))
    tracks = sheet[:tracks].map { |t| t.merge(kind: :chapter) }
    abort "cue has no tracks" if tracks.empty?
    number_prefix = number_prefix_for(audio)
    cfg = load_pattern(audio)
    chapter_titles = chapter_titles_enabled?(cfg, options[:chapter_titles])
    segments = cached_segments(audio)
    hits = load_hits(segments, cfg, chapter_titles)
    attach_src_ms!(tracks, hits)
    prefill_bare_titles!(tracks, hits, number_prefix, chapter_titles, cfg["title"])
    rejected = {}

    i = 0
    loop do
      i = [[i, 0].max, tracks.size - 1].min
      tr = tracks[i]
      puts
      puts "#{i + 1}/#{tracks.size}  #{format_clock(tr[:t])}  #{tr[:title]}"
      puts "  Enter next  b back  d drop  e edit title  n transcript  r redetect"
      puts "  +/- nudge 0.5s  w write  q quit"
      pid = play_async(audio, tr[:t])
      key = $stdin.getch
      stop_play(pid)
      case key
      when "q", "\u0003"
        puts
        exit 0
      when "\r", "\n", "j"
        i += 1
        i = tracks.size - 1 if i >= tracks.size
      when "b", "k"
        i -= 1
      when "d"
        i = refill_after_drop(tracks, i, hits, cfg, rejected, number_prefix)
      when "e"
        edit_title!(tracks[i], segments, cfg, chapter_titles, number_prefix)
      when "n"
        open_transcript!(audio, tracks[i], segments)
      when "r"
        cfg = load_pattern(audio)
        chapter_titles = chapter_titles_enabled?(cfg, options[:chapter_titles])
        number_prefix = number_prefix_for(audio)
        found = redetect_tracks(audio, cfg, chapter_titles, reject_ms: rejected)
        if found.nil? || found.none? { |t| t[:kind] == :chapter }
          warn "no chapter matches in the transcript"
        else
          tracks = found
          segments = cached_segments(audio)
          hits = load_hits(segments, cfg, chapter_titles)
          i = [i, tracks.size - 1].min
          puts "#{tracks.count { |t| t[:kind] == :chapter }} chapter(s), #{tracks.size} track(s)"
        end
      when "+"
        nudge!(tracks, i, 0.5)
      when "-"
        nudge!(tracks, i, -0.5)
      when "w"
        write_cue!(cue_path, audio, tracks, existing: File.read(cue_path))
        puts "Wrote #{cue_path}"
      else
        warn "unknown key #{key.inspect}"
      end
    end
  end

  CACHE_VERSION = 1

  # whisper-cli 1.9.5 has no --no-context. max-context 0 is that switch:
  # a chunk is not steered by the previous sentence, so a short title between
  # two sentences is less likely to be dropped. The thresholds keep a decoded
  # cue that the defaults would discard for silence, entropy, or log-probability.
  WHISPER_KEEP = [
    "--max-context", "0",
    "--no-speech-thold", "0.9",
    "--entropy-thold", "3.0",
    "--logprob-thold", "-2.0"
  ].freeze
  WHISPER_KEEP_ID = "mc=0,nth=0.9,et=3.0,lpt=-2.0"
  # Pauses at least this long with no cue. The missed chapter titles sat in holes of about 6s.
  GAP_MIN_S = 1.0
  GAP_PAD_S = 0.25
  GAPFILL_ID = "1.0"

  def load_segments(audio, language, model: nil, patterns: [])
    model_path = WhisperCli.resolve_model(model)
    stat = File.stat(audio)
    cached = load_cache(audio)
    if cache_valid?(cached, stat, model_path, language)
      if (imported = import_newer_vtt(audio))
        warn "imported #{imported.size} cues from #{vtt_path_for(audio)}, skipped whisper"
        segments = imported
      else
        segments = normalize_segments(cached["segments"])
        warn "cached transcript, skipped whisper (#{segments.size} segments)"
      end
      return finish_gap_fill(audio, segments, language, model_path, patterns, cached, stat)
    end

    warn "transcribing #{audio}"
    segments = transcribe_segments(audio, language, model_path)
    save_cache(audio, stat, model_path, language, segments, gapfill: nil)
    finish_gap_fill(audio, segments, language, model_path, patterns, {}, stat)
  rescue WhisperCli::Error => e
    abort e.message
  end

  # Runs the pause pass unless this cache already has it. Does not start a full transcription.
  def finish_gap_fill(audio, segments, language, model_path, patterns, cached, stat)
    return segments if cached["gapfill"] == GAPFILL_ID

    filled, done = fill_gaps(audio, segments, language, model_path, patterns)
    return segments unless done

    save_cache(audio, stat, model_path, language, filled, whisper: cached["whisper"] || WHISPER_KEEP_ID, gapfill: GAPFILL_ID)
    warn "cached gap fill → #{cache_path(audio)}"
    filled
  end

  def transcribe_segments(audio, language, model_path)
    Dir.mktmpdir("chapters") do |dir|
      result = WhisperCli.transcribe(
        audio,
        language: language,
        model: model_path,
        out_prefix: File.join(dir, "asr"),
        progress: true,
        cli_args: WHISPER_KEEP
      )
      segments_from_whisper(result.segments)
    end
  end

  # Re-read each hole the full pass left empty, including a pause before a cue
  # that already looks like a heading. trim_gap_text drops a fill that only
  # repeats that next cue.
  def fill_gaps(audio, segments, language, model_path, patterns)
    unless command?("ffmpeg")
      warn "ffmpeg not on PATH, skipped gap fill"
      return [segments, false]
    end

    holes = []
    segments.each_cons(2) do |prev, nxt|
      gap_s = (nxt[:from_ms] - prev[:to_ms]) / 1000.0
      next if gap_s < GAP_MIN_S

      holes << [prev, nxt, gap_s]
    end
    return [segments, true] if holes.empty?

    warn "filling #{holes.size} gap(s)"
    inserts = {}
    holes.each_with_index do |(prev, nxt, gap_s), n|
      start_s = prev[:to_ms] / 1000.0
      warn format("gap %d/%d  %s  %.1fs", n + 1, holes.size, format_clock(start_s), gap_s)
      found = transcribe_gap(audio, language, model_path, start_s, nxt[:from_ms] / 1000.0)
      kept = found.filter_map do |seg|
        # A cue that runs past the hole swallowed the following sentence.
        next if seg[:to_ms] > nxt[:from_ms] + 500

        text = trim_gap_text(seg[:text], prev[:text], nxt[:text])
        next if text.empty? || gap_hallucination?(text)

        seg.merge(text: text)
      end
      warn "  #{kept.map { |seg| seg[:text] }.join(' | ')}" unless kept.empty?
      inserts[nxt.object_id] = kept
    end

    out = []
    segments.each do |seg|
      out.concat(inserts[seg.object_id] || [])
      out << seg
    end
    [out, true]
  end

  # Whisper's stock output on a stretch of silence, not words from the recording.
  GAP_HALLUCINATIONS = [
    "wszystkie prawa zastrzezone",
    "dziekuje za ogladanie",
    "dzieki za ogladanie",
    "napisy stworzone przez",
    "thanks for watching",
    "subtitles by"
  ].freeze

  def gap_hallucination?(text)
    key = fold_pl(scrub(text))
    GAP_HALLUCINATIONS.any? { |phrase| key.include?(phrase) }
  end

  def heading_cue?(text, patterns)
    list = Array(patterns).map(&:to_s).reject(&:empty?)
    return false if list.empty?

    !match_patterns(text, list).nil?
  end

  def transcribe_gap(audio, language, model_path, gap_start_s, gap_end_s)
    clip_start = [gap_start_s - GAP_PAD_S, 0].max
    duration = (gap_end_s + GAP_PAD_S) - clip_start
    return [] if duration <= 0

    Dir.mktmpdir("chapters-gap") do |dir|
      wav = File.join(dir, "gap.wav")
      unless extract_wav(audio, clip_start, duration, wav)
        warn "  ffmpeg could not read that span"
        return []
      end

      result = WhisperCli.transcribe(
        wav,
        language: language,
        model: model_path,
        out_prefix: File.join(dir, "asr"),
        cli_args: WHISPER_KEEP
      )
      offset = (clip_start * 1000).round
      segments_from_whisper(result.segments).map do |seg|
        seg.merge(from_ms: seg[:from_ms] + offset, to_ms: seg[:to_ms] + offset)
      end
    end
  rescue WhisperCli::Error => e
    warn "  #{e.message}"
    []
  end

  def extract_wav(audio, start_s, duration_s, wav)
    system(
      "ffmpeg", "-hide_banner", "-loglevel", "error",
      "-ss", format("%.3f", start_s),
      "-t", format("%.3f", duration_s),
      "-i", audio,
      "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le",
      "-y", wav,
      out: File::NULL, err: File::NULL
    ) && File.file?(wav) && File.size(wav) > 44
  end

  # Drop words the clip repeated from the cue before or after the hole.
  def trim_gap_text(text, prev_text, next_text)
    words = text.to_s.strip.split(/\s+/)
    return "" if words.empty?

    prev_words = prev_text.to_s.split(/\s+/)
    next_words = next_text.to_s.split(/\s+/)
    words = drop_edge_overlap(words, prev_words, :prefix)
    words = drop_edge_overlap(words, next_words, :suffix)
    words.pop if next_words[0] && word_prefix?(words.last, next_words[0])
    words.shift if prev_words[-1] && word_prefix?(words.first, prev_words[-1])
    return "" if words.empty?

    joined = words.join(" ")
    folded = scrub(joined)
    return "" if folded.length < 2
    return "" if phrase_inside?(prev_text, folded) || phrase_inside?(next_text, folded)

    joined
  end

  def drop_edge_overlap(words, neighbor, edge)
    max = [words.size, neighbor.size].min
    cut = 0
    (1..max).each do |k|
      piece = edge == :prefix ? words.first(k) : words.last(k)
      other = edge == :prefix ? neighbor.last(k) : neighbor.first(k)
      cut = k if piece.zip(other).all? { |a, b| same_word?(a, b) }
    end
    return words if cut.zero?
    return [] if cut == words.size

    edge == :prefix ? words.drop(cut) : words[0...-cut]
  end

  def word_key(word)
    fold_pl(scrub(word.to_s.gsub(/[[:punct:]]/, "")))
  end

  def same_word?(a, b)
    left = word_key(a)
    !left.empty? && left == word_key(b)
  end

  # "Wystarczy." is the clipped start of the next cue's "Wystarczyłoby".
  def word_prefix?(fragment, full)
    short = word_key(fragment)
    long = word_key(full)
    short.length >= 4 && long.length > short.length && long.start_with?(short)
  end

  def phrase_inside?(haystack, folded_needle)
    folded = scrub(haystack.to_s)
    !folded.empty? && folded.include?(folded_needle)
  end

  def segments_from_whisper(raw_segments)
    raw_segments.filter_map do |seg|
      text = (seg["text"] || seg["word"] || "").to_s.strip.gsub(/\s+/, " ")
      next if text.empty?

      from_ms, to_ms = segment_times(seg)
      { from_ms: from_ms, to_ms: [to_ms, from_ms + 1].max, text: text }
    end
  end

  def segment_times(seg)
    offsets = seg["offsets"] || {}
    from_ms =
      if offsets.key?("from")
        offsets["from"].to_i
      elsif seg["timestamps"]
        timestamp_to_ms(seg["timestamps"]["from"])
      else
        ((seg["start"] || 0).to_f * 1000).round
      end
    to_ms =
      if offsets.key?("to")
        offsets["to"].to_i
      elsif seg["timestamps"]
        timestamp_to_ms(seg["timestamps"]["to"])
      else
        ((seg["end"] || 0).to_f * 1000).round
      end
    [from_ms, to_ms]
  end

  def timestamp_to_ms(ts)
    return 0 if ts.nil?

    s = ts.to_s.strip.tr(",", ".")
    if (m = s.match(/(\d+):(\d+):(\d+(?:\.\d+)?)/))
      ((m[1].to_i * 3600 + m[2].to_i * 60 + m[3].to_f) * 1000).round
    elsif (m = s.match(/(\d+):(\d+(?:\.\d+)?)/))
      ((m[1].to_i * 60 + m[2].to_f) * 1000).round
    else
      0
    end
  end

  def classify(segments, cfg, chapter_titles: false, reject_ms: nil)
    hits = pattern_hits(segments, cfg, chapter_titles: chapter_titles)
    preamble_title = (cfg["preamble_title"] || "Credits").to_s
    title_tmpl = (cfg["title"] || "Chapter $n").to_s
    rejected = reject_ms || {}

    tracks = []
    first = segments.first
    if first && hits.none? { |hit| hit[:src_ms] == first[:from_ms] }
      tracks << { t: 0.0, src_ms: 0, title: preamble_title, kind: :preamble, text: first[:text].to_s }
    end

    n = 0
    hits.each do |hit|
      t = hit[:t]
      next if tracks.any? { |tr| tr[:kind] == :preamble } && t <= 0.05
      # A rejected cue is not a chapter, so it must not open a min_gap hole.
      next if rejected.key?(hit[:src_ms])

      n += 1
      tracks << {
        t: t,
        src_ms: hit[:src_ms],
        title: apply_title(title_tmpl, n: n, text: hit[:text], match: hit[:match], chapter_titles: chapter_titles, extra: hit[:tail]),
        kind: :chapter,
        text: hit[:text]
      }
    end
    tracks
  end

  # Every pattern match. A heading glued on after a period is split out first,
  # so the existing start-of-cue rule still sees it.
  def pattern_hits(segments, cfg, chapter_titles: false)
    patterns = Array(cfg["patterns"]).map(&:to_s).reject(&:empty?)
    abort "pattern.yml needs patterns:" if patterns.empty?

    title_tmpl = (cfg["title"] || "Chapter $n").to_s
    segments = split_heading_cues(segments, patterns)
    hits = []
    segments.each_with_index do |seg, i|
      nxt = segments[i + 1]
      found = match_segment(seg[:text], nxt && nxt[:text], patterns)
      next unless found

      match, used = found
      tail = title_tail(used, match, nxt, patterns)
      hits << {
        src_ms: seg[:from_ms],
        t: seg[:from_ms] / 1000.0,
        text: used.to_s,
        match: match,
        tail: tail,
        title: apply_title(title_tmpl, n: hits.size + 1, text: used, match: match, chapter_titles: chapter_titles, extra: tail)
      }
    end
    hits
  end

  def split_heading_cues(segments, patterns)
    segments.flat_map { |seg| split_heading_cue(seg, patterns) }
  end

  def split_heading_cue(seg, patterns)
    text = seg[:text].to_s
    cuts = heading_cuts(text, patterns)
    return [seg] if cuts.empty?

    from = seg[:from_ms].to_i
    to_ms = seg[:to_ms].to_i
    span = [to_ms - from, 1].max
    length = [text.length, 1].max
    edges = [0, *cuts, text.length]
    parts = []
    edges.each_cons(2) do |start_at, stop_at|
      piece = text[start_at...stop_at].to_s.strip
      next if piece.empty?

      start_ms = from + (span * start_at / length)
      stop_ms = stop_at == text.length ? to_ms : from + (span * stop_at / length)
      parts << { from_ms: start_ms, to_ms: [stop_ms, start_ms + 1].max, text: piece }
    end
    parts.empty? ? [seg] : parts
  end

  # Offsets where a chapter pattern begins after sentence punctuation.
  # A match at the start of the cue is left for the normal matcher.
  def heading_cuts(text, patterns)
    hay = fold_pl(text.to_s.downcase)
    cuts = []
    patterns.each do |pat|
      body = scrub(pat).sub(/\A\^+/, "").sub(/\$+\z/, "")
      next if body.empty?

      re = Regexp.new(fold_pl(body), Regexp::IGNORECASE)
      hay.scan(re) do
        match = Regexp.last_match
        idx = match.begin(0)
        next if idx.zero?
        next unless sentence_boundary?(hay, idx)
        next unless heading_boundary_after?(hay, match.end(0))

        cuts << idx
      end
    end
    cuts.uniq.sort
  rescue RegexpError => e
    abort "bad pattern: #{e.message}"
  end

  def sentence_boundary?(text, idx)
    text[0...idx].to_s.match?(/(\.\.\.|[.!?…])\s*\z/)
  end

  def heading_boundary_after?(text, idx)
    char = text[idx]
    return true if char.nil? || char.empty?

    char.match?(/[[:space:][:punct:]]/) || char == "…"
  end

  def load_hits(segments, cfg, chapter_titles)
    return [] if segments.nil? || segments.empty?
    return [] if Array(cfg["patterns"]).map(&:to_s).reject(&:empty?).empty?

    pattern_hits(segments, cfg, chapter_titles: chapter_titles)
  end

  # Nearest hit that sits closer to this track than to either neighbor.
  # Nudges change t and leave src_ms on the cue that produced the row.
  def attach_src_ms!(tracks, hits)
    tracks.each_with_index do |track, idx|
      prev_t = idx.positive? ? tracks[idx - 1][:t] : nil
      next_t = idx + 1 < tracks.size ? tracks[idx + 1][:t] : nil
      best = nil
      best_dt = nil
      hits.each do |hit|
        dt = (hit[:t] - track[:t]).abs
        next if prev_t && dt >= (hit[:t] - prev_t).abs
        next if next_t && dt >= (hit[:t] - next_t).abs
        next if best_dt && dt >= best_dt

        best = hit
        best_dt = dt
      end
      track[:src_ms] = best ? best[:src_ms] : (track[:t].to_f * 1000).round
    end
  end

  # Drop one row and insert matches that were hidden only by its min_gap window.
  # Returns the index to select. Other rows keep their titles and nudged times.
  def refill_after_drop(tracks, index, hits, cfg, rejected, number_prefix)
    dropped = tracks[index]
    rejected[dropped[:src_ms]] = true if dropped[:src_ms]
    preamble_title = (cfg["preamble_title"] || "Credits").to_s
    min_gap = (cfg["min_gap_min"] || 8).to_f * 60.0

    anchor = nil
    (index - 1).downto(0) do |j|
      prev = tracks[j]
      next if prev[:kind] == :preamble
      next if prev[:t].to_f <= 0.05 && prev[:title].to_s == preamble_title

      anchor = prev
      break
    end

    tracks.delete_at(index)
    kept = {}
    tracks.each { |track| kept[track[:src_ms]] = true if track[:src_ms] }
    inserts = []
    unless hits.empty?
      dropped_t = dropped[:src_ms] ? dropped[:src_ms] / 1000.0 : dropped[:t].to_f
      last_t = anchor ? anchor[:t].to_f : nil
      hits.each do |hit|
        next if rejected.key?(hit[:src_ms]) || kept.key?(hit[:src_ms])
        next unless hit[:t] > dropped_t
        next unless (hit[:t] - dropped_t) < min_gap
        next if last_t && (hit[:t] - last_t) < min_gap

        inserts << {
          t: hit[:t],
          src_ms: hit[:src_ms],
          title: hit[:title],
          kind: :chapter,
          text: hit[:text]
        }
        last_t = hit[:t]
      end
    end

    inserts.each do |track|
      at = tracks.index { |row| row[:t].to_f > track[:t] } || tracks.size
      tracks.insert(at, track)
    end
    if tracks.empty?
      warn "no tracks left"
      exit 1
    end

    renumber_titles!(tracks, number_prefix)
    if hits.empty?
      warn "no transcript, can't refill"
    else
      puts "uncovered #{inserts.size} chapter(s)"
    end
    return index if inserts.empty?

    tracks.index { |track| track[:src_ms] == inserts.first[:src_ms] } || index
  end

  # Current segment, then current+next so a title split across two segments still hits.
  # The match must start in the current segment. Returns [MatchData, text] or nil.
  def match_segment(text, next_text, patterns)
    m = match_patterns(text, patterns)
    return [m, text] if m
    return nil if next_text.to_s.strip.empty?

    joined = "#{text} #{next_text}"
    m = match_patterns(joined, patterns, start_limit: scrub(text).length)
    m ? [m, joined] : nil
  end

  def match_patterns(text, patterns, start_limit: nil)
    raw = scrub(text)
    folded = fold_pl(raw)
    patterns.each do |pat|
      ps = scrub(pat)
      regexes = [Regexp.new(ps, Regexp::IGNORECASE)]
      folded_pat = fold_pl(ps)
      regexes << Regexp.new(folded_pat, Regexp::IGNORECASE) if folded_pat != ps
      regexes.each do |re|
        [raw, folded].each do |candidate|
          m = re.match(candidate)
          next unless m
          next if start_limit && m.begin(0) > start_limit

          return m
        end
      end
    end
    nil
  rescue RegexpError => e
    abort "bad pattern: #{e.message}"
  end

  def scrub(s)
    s.to_s.unicode_normalize(:nfkc).tr("„“”«»", "\"\"\"\"\"").downcase.gsub(/\s+/, " ").strip
  end

  def fold_pl(s)
    s.to_s.chars.map { |c| FOLD[c] || c }.join
  end

  def apply_title(template, n:, text:, match:, chapter_titles: false, extra: :auto)
    first = text.to_s.strip.sub(/\s+/, " ")
    out = template.to_s.gsub("$n", n.to_s).gsub("$text", first)
    out = out.gsub(/\$(\d+)/) { match[Regexp.last_match(1).to_i].to_s }
    return out unless chapter_titles && !template.to_s.include?("$text")

    extra = words_after_match(text, match) if extra == :auto
    extra = extra.to_s
    extra.empty? ? out : "#{out} #{extra}"
  end

  # Words that follow the spoken number. A short cue after a bare "Rozdział drugi."
  # is the title ("Rozbita szyba"); a long following sentence is not.
  def title_tail(text, match, nxt, patterns)
    extra = words_after_match(text, match)
    return extra unless extra.empty?
    return "" unless nxt.is_a?(Hash) && short_heading?(nxt[:text])
    return "" if heading_cue?(nxt[:text], patterns)

    words_after_match(nxt[:text], nil)
  end

  def short_heading?(text)
    words = text.to_s.strip.split(/\s+/)
    !words.empty? && words.size <= TITLE_WORDS
  end

  def chapter_titles_enabled?(cfg, override)
    return override unless override.nil?

    cfg["chapter_titles"] != false
  end

  def load_pattern(audio)
    path = pattern_path_for(audio)
    return {} unless File.file?(path)

    YAML.safe_load(File.read(path), permitted_classes: [], aliases: false) || {}
  rescue Psych::SyntaxError
    {}
  end

  def words_after_match(original, match, limit: TITLE_WORDS)
    words = original.to_s.strip.split(/\s+/)
    if match
      target = match.end(0)
      acc = +""
      idx = 0
      while idx < words.size
        acc = idx.zero? ? words[idx] : "#{acc} #{words[idx]}"
        idx += 1
        break if scrub(acc).length >= target
      end
      words = words.drop(idx)
    end
    words.shift while number_word?(words.first)
    words.first(limit).filter_map { |w| w.gsub(/\A[[:punct:]]+|[[:punct:]]+\z/, "").then { |s| s.empty? ? nil : s } }.join(" ")
  end

  def number_word?(word)
    w = fold_pl(scrub(word.to_s.gsub(/[[:punct:]]/, "")))
    return false if w.empty?
    return true if w.match?(/\A\d+\z/)
    return true if w.match?(/\A[ivx]+\z/) && w != "i"

    NUMBER_WORDS.include?(w)
  end

  def edit_title!(track, segments, cfg, chapter_titles, prefix)
    suggestion = suggested_title(track, segments, cfg, chapter_titles, prefix)
    line = read_line("title: ", suggestion)
    return if line.nil? || line.strip.empty?

    track[:title] = line.strip
    puts track[:title]
  end

  def suggested_title(track, segments, cfg, chapter_titles, prefix)
    current = track[:title].to_s
    return current unless chapter_titles && bare_number_title?(current, prefix)

    seg = segment_at(segments, track[:t])
    return current unless seg

    patterns = Array(cfg["patterns"]).map(&:to_s).reject(&:empty?)
    return current if patterns.empty?

    idx = segments.index(seg)
    hit = match_segment(seg[:text], nil, patterns)
    return current unless hit

    n = title_number(current, prefix) || 1
    template = (cfg["title"].to_s.empty? ? "Chapter $n" : cfg["title"].to_s)
    nxt = idx && segments[idx + 1]
    tail = title_tail(hit[1], hit[0], nxt, patterns)
    apply_title(template, n: n, text: hit[1], match: hit[0], chapter_titles: true, extra: tail)
  end

  def bare_number_title?(title, prefix)
    return false if prefix.nil? || prefix.empty?
    return false unless title.to_s.start_with?(prefix)

    rest = title.to_s[prefix.length..] || ""
    rest.match?(/\A\d+\z/)
  end

  # Cue sheets written as "Rozdział 3" pick up the heading words already in the transcript.
  # A title that already has those words, or any other edit, is left as it is.
  def prefill_bare_titles!(tracks, hits, prefix, chapter_titles, template)
    return unless chapter_titles

    tmpl = template.to_s.empty? ? "Chapter $n" : template.to_s
    tracks.each do |track|
      next unless bare_number_title?(track[:title], prefix)

      hit = hits.find { |row| row[:src_ms] == track[:src_ms] }
      next if hit.nil? || hit[:tail].to_s.empty?

      n = title_number(track[:title], prefix) || 1
      track[:title] = apply_title(tmpl, n: n, text: hit[:text], match: hit[:match], chapter_titles: true, extra: hit[:tail])
    end
  end

  def title_number(title, prefix)
    if prefix && title.to_s.start_with?(prefix)
      rest = title.to_s[prefix.length..] || ""
      return Regexp.last_match(1).to_i if rest.match(/\A(\d+)/)
    elsif (m = title.to_s.match(/(\d+)\s*\z/))
      return m[1].to_i
    end
    nil
  end

  def segment_at(segments, seconds)
    return nil if segments.nil? || segments.empty?

    ms = (seconds.to_f * 1000).round
    segments.min_by { |seg| (seg[:from_ms] - ms).abs }
  end

  def read_line(prompt, prefill)
    buf = prefill.to_s.dup
    cursor = buf.length
    $stdin.raw do
      paint_line(prompt, buf, cursor)
      loop do
        char = $stdin.getch
        case char
        when "\r", "\n"
          $stdout.puts
          return buf
        when "\u0003"
          $stdout.puts
          return nil
        when "\u007F", "\b"
          if cursor.positive?
            buf.slice!(cursor - 1)
            cursor -= 1
          end
        when "\u0015"
          buf.clear
          cursor = 0
        when "\e"
          seq = +""
          seq << $stdin.read_nonblock(1) rescue nil
          seq << $stdin.read_nonblock(1) rescue nil
          case seq
          when "[D"
            cursor -= 1 if cursor.positive?
          when "[C"
            cursor += 1 if cursor < buf.length
          when "[3"
            $stdin.getch rescue nil
            buf.slice!(cursor) if cursor < buf.length
          end
        else
          next unless char.match?(/[[:print:]]/)

          buf.insert(cursor, char)
          cursor += 1
        end
        paint_line(prompt, buf, cursor)
      end
    end
  end

  def paint_line(prompt, buf, cursor)
    $stdout.print "\r\e[K#{prompt}#{buf}"
    $stdout.print "\e[#{prompt.length + cursor + 1}G"
    $stdout.flush
  end

  def open_transcript!(audio, track, segments)
    path = vtt_path_for(audio)
    if !File.file?(path)
      if segments.nil? || segments.empty?
        warn "no transcript; run chapters detect first"
        return
      end
      write_vtt!(path, segments)
    end
    line = vtt_line_for(path, track[:t])
    unless command?("nvim")
      warn "nvim not on PATH"
      return
    end
    system("nvim", "+#{line}", path)
  end

  def vtt_line_for(path, seconds)
    best = 1
    best_dt = nil
    line_no = 0
    File.foreach(path) do |line|
      line_no += 1
      next unless (m = line.match(/(\d+):(\d+):(\d+)[.,](\d+)/))

      t = m[1].to_i * 3600 + m[2].to_i * 60 + m[3].to_i + (m[4].to_i / 1000.0)
      dt = (t - seconds.to_f).abs
      next unless best_dt.nil? || dt < best_dt

      best_dt = dt
      best = line_no
    end
    best
  end

  def redetect_tracks(audio, cfg, chapter_titles, reject_ms: nil)
    segments = segments_for_redetect(audio)
    if segments.empty?
      warn "no transcript; run chapters detect first"
      return nil
    end

    classify(segments, cfg, chapter_titles: chapter_titles, reject_ms: reject_ms)
  end

  def segments_for_redetect(audio)
    vtt = vtt_path_for(audio)
    if File.file?(vtt)
      segments = parse_vtt(File.read(vtt))
      replace_cache_segments(audio, segments) unless segments.empty?
      return segments
    end
    cached_segments(audio)
  end

  def import_newer_vtt(audio)
    vtt = vtt_path_for(audio)
    cache = cache_path(audio)
    return nil unless File.file?(vtt)
    return nil if File.file?(cache) && File.mtime(vtt) <= File.mtime(cache)

    segments = parse_vtt(File.read(vtt))
    return nil if segments.empty?
    return segments if replace_cache_segments(audio, segments)

    nil
  end

  def cached_segments(audio)
    cached = load_cache(audio)
    return [] unless cached.is_a?(Hash) && cached["segments"].is_a?(Array)

    normalize_segments(cached["segments"])
  end

  def replace_cache_segments(audio, segments)
    cached = load_cache(audio)
    return false unless cached.is_a?(Hash) && cached["v"] == CACHE_VERSION

    stamp = Struct.new(:size, :mtime).new(cached["audio_size"], cached["audio_mtime"])
    save_cache(
      audio, stamp, cached["model"], cached["language"], segments,
      whisper: cached["whisper"], gapfill: cached["gapfill"]
    )
    true
  end

  def parse_vtt(text)
    segments = []
    lines = text.to_s.lines
    i = 0
    while i < lines.size
      line = lines[i].strip
      unless (m = line.match(/\A(\d+):(\d+):(\d+)[.,](\d+)\s+-->\s+(\d+):(\d+):(\d+)[.,](\d+)/))
        i += 1
        next
      end

      from_ms = vtt_stamp_ms(m[1], m[2], m[3], m[4])
      to_ms = vtt_stamp_ms(m[5], m[6], m[7], m[8])
      i += 1
      body = []
      while i < lines.size && !lines[i].strip.empty? && !lines[i].include?("-->")
        body << lines[i].strip
        i += 1
      end
      cue = vtt_unescape(body.join(" "))
      next if cue.empty?

      segments << { from_ms: from_ms, to_ms: [to_ms, from_ms + 1].max, text: cue }
    end
    segments
  end

  def vtt_stamp_ms(hours, mins, secs, millis)
    (hours.to_i * 3_600_000) + (mins.to_i * 60_000) + (secs.to_i * 1000) + millis.to_i
  end

  def vtt_unescape(text)
    text.to_s.gsub("&lt;", "<").gsub("&amp;", "&")
  end

  # Literal text before $n in *.pattern.yml, or nil when titles should be
  # renumbered by a trailing integer instead.
  def number_prefix_for(audio)
    path = pattern_path_for(audio)
    return nil unless File.file?(path)

    cfg = YAML.safe_load(File.read(path), permitted_classes: [], aliases: false) || {}
    template = cfg["title"].to_s
    return nil unless template.include?("$n")

    template.split("$n", 2).first
  rescue Psych::SyntaxError
    nil
  end

  def renumber_titles!(tracks, prefix)
    n = 0
    tracks.each do |tr|
      title = renumber_title(tr[:title].to_s, prefix, n + 1)
      next unless title

      n += 1
      tr[:title] = title
    end
  end

  def renumber_title(title, prefix, n)
    if prefix.nil?
      return nil unless title.match?(/\d+\s*\z/)

      title.sub(/(\d+)(\s*)\z/) { "#{n}#{$2}" }
    else
      return nil unless title.start_with?(prefix)

      rest = title[prefix.length..] || ""
      return nil unless rest.match?(/\A\d+/)

      prefix + rest.sub(/\A\d+/, n.to_s)
    end
  end

  def print_hit(track)
    snippet = track[:text].to_s.gsub(/\s+/, " ")[0, 80]
    puts format("%s  %-8s  %s", format_clock(track[:t]), track[:kind], track[:title])
    puts "    #{snippet}" unless snippet.empty?
  end

  def format_clock(seconds)
    seconds = 0 if seconds.to_f.negative?
    total = seconds.to_f.round
    ss = total % 60
    mm = (total / 60) % 60
    hh = total / 3600
    format("%d:%02d:%02d", hh, mm, ss)
  end

  def format_index(seconds)
    seconds = 0 if seconds.to_f.negative?
    frames = (seconds.to_f * 75).round
    ff = frames % 75
    total_s = frames / 75
    ss = total_s % 60
    mm = total_s / 60
    format("INDEX 01 %d:%02d:%02d", mm, ss, ff)
  end

  def nudge!(tracks, index, delta)
    if index <= 0
      warn "track 1 stays at the start of the file"
      return
    end
    cur = tracks[index][:t] + delta
    prev = tracks[index - 1][:t] + 0.5
    nxt = tracks[index + 1] ? tracks[index + 1][:t] - 0.5 : cur + 1
    if cur < prev || cur > nxt
      warn "nudge would cross a neighbor"
      return
    end
    tracks[index][:t] = cur
  end

  def parse_cue(text)
    header = []
    tracks = []
    cur = nil
    text.to_s.each_line do |line|
      if line =~ /^\s*TRACK\s+\d+\s+AUDIO/i
        tracks << cur if cur
        cur = { title: "", performer: nil, t: 0.0 }
      elsif cur && (m = line.match(/^\s*TITLE\s+"(.*)"\s*$/i))
        cur[:title] = m[1]
      elsif cur && (m = line.match(/^\s*PERFORMER\s+"(.*)"\s*$/i))
        cur[:performer] = m[1]
      elsif cur && (m = line.match(/^\s*INDEX\s+\d+\s+(\d+):(\d+):(\d+)/i))
        cur[:t] = m[1].to_i * 60 + m[2].to_i + (m[3].to_i / 75.0)
      elsif cur.nil?
        header << line
      end
    end
    tracks << cur if cur
    { header: header.join, tracks: tracks }
  end

  def write_cue!(path, audio, tracks, existing:)
    sheet = existing ? parse_cue(existing) : { header: "", tracks: [] }
    bak_sheet = File.file?("#{path}.bak") ? parse_cue(File.read("#{path}.bak")) : nil
    header = cue_header_for(sheet, bak_sheet, audio)
    narrator = first_track_performer(sheet) || first_track_performer(bak_sheet)
    body = +""
    tracks.each_with_index do |tr, i|
      body << format("  TRACK %02d AUDIO\n", i + 1)
      body << "    TITLE \"#{cue_escape(tr[:title])}\"\n"
      body << "    PERFORMER \"#{cue_escape(narrator)}\"\n" if narrator
      body << "    #{format_index(tr[:t])}\n"
    end
    if File.file?(path)
      bak = "#{path}.bak"
      unless File.file?(bak)
        FileUtils.cp(path, bak)
        puts "Backup #{bak}"
      end
    end
    File.write(path, "#{header}\n#{body}")
  end

  # A header is usable when it names the audio file. PERFORMER before FILE is the
  # author, so the header does not have to start with FILE. If this cue already
  # lost that line, the .bak still has it.
  def cue_header_for(sheet, bak_sheet, audio)
    header = cue_header(sheet && sheet[:header])
    bak_header = cue_header(bak_sheet && bak_sheet[:header])
    if header.nil?
      header = bak_header
    elsif header_performer(header).nil? && header_performer(bak_header)
      header = bak_header
    end
    return header if header

    stem = File.basename(audio, ".*")
    <<~CUE.chomp
      TITLE "#{cue_escape(stem)}"
      FILE "#{cue_escape(File.basename(audio))}" MP3
    CUE
  end

  def cue_header(text)
    header = text.to_s.sub(/\s+\z/, "")
    return nil if header.empty? || !header.match?(/^\s*FILE\s+"/im)

    header
  end

  def header_performer(header)
    return nil if header.nil?

    match = header.match(/^\s*PERFORMER\s+"(.*)"\s*$/i)
    match && !match[1].empty? ? match[1] : nil
  end

  def first_track_performer(sheet)
    return nil unless sheet

    sheet[:tracks].map { |track| track[:performer] }.compact.find { |name| !name.empty? }
  end

  def cue_escape(text)
    text.to_s.gsub('"', "'")
  end

  def audio_from_cue(cue_path)
    dir = File.dirname(cue_path)
    text = File.read(cue_path)
    return nil unless (m = text.match(/^\s*FILE\s+"(.*)"/i))

    rel = m[1]
    abs = File.absolute_path?(rel) ? rel : File.join(dir, rel)
    File.file?(abs) ? abs : (File.file?(rel) ? rel : abs)
  end

  def pattern_path_for(audio)
    audio.sub(/\.[^.]+$/, ".pattern.yml")
  end

  def cue_path_for(audio)
    audio.sub(/\.[^.]+$/, ".cue")
  end

  def vtt_path_for(audio)
    audio.sub(/\.[^.]+$/, ".vtt")
  end

  def cache_path(audio)
    audio.sub(/\.[^.]+$/, ".chapters-cache.json")
  end

  def load_cache(audio)
    path = cache_path(audio)
    return {} unless File.file?(path)

    JSON.parse(File.read(path))
  rescue JSON::ParserError
    {}
  end

  def cache_valid?(cache, stat, model, language)
    return false unless cache.is_a?(Hash) && cache["v"] == CACHE_VERSION
    return false unless cache["audio_size"] == stat.size
    return false unless cache["audio_mtime"] == stat.mtime.to_i
    return false unless cache["model"] == model
    return false unless cache["language"] == language
    return false unless cache["whisper"] == WHISPER_KEEP_ID

    cache["segments"].is_a?(Array)
  end

  def save_cache(audio, stat, model, language, segments, whisper: WHISPER_KEEP_ID, gapfill: nil)
    payload = {
      "v" => CACHE_VERSION,
      "audio_size" => stat.size,
      "audio_mtime" => stat.mtime.to_i,
      "model" => model,
      "language" => language,
      "whisper" => whisper,
      "gapfill" => gapfill,
      "segments" => segments.map { |s| { "from_ms" => s[:from_ms], "to_ms" => s[:to_ms], "text" => s[:text] } }
    }
    File.write(cache_path(audio), JSON.generate(payload))
  end

  def normalize_segments(list)
    list.filter_map do |seg|
      from_ms = (seg["from_ms"] || seg[:from_ms]).to_i
      to_ms = (seg["to_ms"] || seg[:to_ms]).to_i
      text = (seg["text"] || seg[:text]).to_s.strip.gsub(/\s+/, " ")
      next if text.empty?

      { from_ms: from_ms, to_ms: [to_ms, from_ms + 1].max, text: text }
    end
  end

  def write_vtt!(path, segments)
    body = +""
    n = 0
    segments.each do |seg|
      text = vtt_escape(seg[:text])
      next if text.empty?

      body << "#{format_vtt_time(seg[:from_ms])} --> #{format_vtt_time(seg[:to_ms])}\n"
      body << "#{text}\n\n"
      n += 1
    end
    File.write(path, "WEBVTT\n\n#{body}")
    n
  end

  def format_vtt_time(ms)
    ms = 0 if ms.to_i.negative?
    ms = ms.to_i
    hours = ms / 3_600_000
    ms %= 3_600_000
    mins = ms / 60_000
    ms %= 60_000
    secs = ms / 1000
    millis = ms % 1000
    format("%02d:%02d:%02d.%03d", hours, mins, secs, millis)
  end

  def vtt_escape(text)
    text.to_s.gsub(/\s+/, " ").strip.gsub("&", "&amp;").gsub("<", "&lt;").gsub("-->", "—>")
  end

  def play_async(audio, start_s)
    cmd = if command?("ffplay")
            ["ffplay", "-nodisp", "-autoexit", "-loglevel", "error", "-ss", format("%.3f", start_s), "-t", PLAY_S.to_s, audio]
          elsif command?("mpv")
            ["mpv", "--no-video", "--really-quiet", "--start=#{format('%.3f', start_s)}", "--length=#{PLAY_S}", audio]
          else
            warn "no ffplay or mpv; skipping playback"
            return nil
          end
    spawn(*cmd, out: File::NULL, err: File::NULL)
  end

  def stop_play(pid)
    return unless pid

    Process.kill("TERM", pid)
    Process.wait(pid)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end

  def command?(name)
    # `command` is a shell builtin; multi-arg system does not start a shell.
    system("sh", "-c", "command -v \"$1\" >/dev/null 2>&1", "sh", name)
  end
end

Chapters.main(ARGV) if $PROGRAM_NAME == __FILE__
