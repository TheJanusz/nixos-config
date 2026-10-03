#!/usr/bin/env ruby
# frozen_string_literal: true

# Find audiobook chapter starts and rewrite the .cue for split-cue.
#
#   chapters init book.mp3
#   # skip title/credits, listen to how chapter 1 starts, edit book.pattern.yml
#   chapters detect book.mp3
#   chapters detect book.mp3 --write
#   chapters preview book.cue
#   split-cue book.cue

require "json"
require "yaml"
require "optparse"
require "fileutils"
require "open3"
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
      chapters detect AUDIO [-p pattern.yml] [--cue FILE] [--model PATH] [--write]
      chapters preview [CUE|AUDIO]

      Skip the opening title/credits. Listen to how chapter 1 starts, then set
      patterns in *.pattern.yml. detect transcribes short windows after long
      silences (not the whole file). preview plays ~6s at each INDEX:
        Enter next   b back   d drop   +/- nudge 0.5s   w write cue   q quit
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
      # then edit patterns (and language). English: language en, prompt Chapter,
      # patterns like '^chapter' or '^„', title '$text'.
      language: pl
      silence_s: 1.2
      silence_noise_db: -30
      window_s: 20
      min_gap_min: 8
      preamble_title: Credits
      prompt: "Rozdział"
      patterns:
        - '^rozdział'
        - '^rozdzial'
      title: 'Rozdział $n'
    YAML
    puts "Wrote #{path}"
    puts "Skip title/credits, listen to how chapter 1 starts, fill patterns."
  end

  def cmd_detect(argv)
    options = { write: false, pattern: nil, cue: nil, model: nil }
    parser = OptionParser.new do |opts|
      opts.on("-p", "--pattern PATH", "pattern.yml") { |v| options[:pattern] = v }
      opts.on("--cue FILE", "cue sheet to update") { |v| options[:cue] = v }
      opts.on("--model PATH", "whisper ggml model") { |v| options[:model] = v }
      opts.on("--write", "rewrite the cue (keeps the first .bak)") { options[:write] = true }
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

    tracks = detect_tracks(audio, cfg, model: options[:model])
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

    i = 0
    loop do
      i = [[i, 0].max, tracks.size - 1].min
      tr = tracks[i]
      puts
      puts "#{i + 1}/#{tracks.size}  #{format_clock(tr[:t])}  #{tr[:title]}"
      puts "  Enter next  b back  d drop  +/- nudge 0.5s  w write  q quit"
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
        tracks.delete_at(i)
        if tracks.empty?
          warn "no tracks left"
          exit 1
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

  def detect_tracks(audio, cfg, model: nil)
    silence_s = (cfg["silence_s"] || 1.2).to_f
    noise = (cfg["silence_noise_db"] || -30).to_f
    window_s = (cfg["window_s"] || 20).to_f
    language = (cfg["language"] || "pl").to_s
    prompt = cfg["prompt"].to_s
    candidates = silence_candidates(audio, silence_s, noise)
    warn "#{candidates.size} silence candidate(s); raise silence_s if this is slow" if candidates.size > 80

    cache = load_cache(audio)
    Dir.mktmpdir("chapters") do |dir|
      windows = candidates.each_with_index.map do |t, idx|
        warn format("whisper %d/%d  %s", idx + 1, candidates.size, format_clock(t))
        text = cached_or_transcribe(
          cache, audio, t, window_s, language, model,
          prompt: t <= 0.05 ? nil : prompt,
          dir: dir
        )
        { t: t, text: text }
      end
      save_cache(audio, cache)
      classify(windows, cfg)
    end
  end

  def silence_candidates(audio, silence_s, noise_db)
    _out, err, status = Open3.capture3(
      "ffmpeg", "-i", audio,
      "-af", format("silencedetect=noise=%gdB:d=%g", noise_db, silence_s),
      "-f", "null", "-"
    )
    abort "ffmpeg silencedetect failed" unless status.success? || err.to_s.include?("silence_")

    ends = []
    err.to_s.scan(/silence_end:\s*([0-9.]+)/) { ends << Regexp.last_match(1).to_f }
    ([0.0] + ends).uniq.sort
  rescue Errno::ENOENT
    abort "ffmpeg not on PATH"
  end

  def cached_or_transcribe(cache, audio, start_s, window_s, language, model, prompt:, dir:)
    model_key = model.to_s.empty? ? ENV["SUBPIPE_WHISPER_MODEL"].to_s : model.to_s
    key = [format("%.2f", start_s), window_s, language, model_key, prompt.to_s].join("|")
    return cache[key] if cache.key?(key)

    tag = format("%.2f", start_s).tr(".", "_")
    wav = File.join(dir, "win_#{tag}.wav")
    prefix = File.join(dir, "asr_#{tag}")
    ok = system(
      "ffmpeg", "-y", "-ss", format("%.3f", start_s), "-t", window_s.to_s,
      "-i", audio, "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", wav,
      out: File::NULL, err: File::NULL
    )
    abort "ffmpeg window cut failed at #{start_s}" unless ok && File.file?(wav)
    result = WhisperCli.transcribe(wav, language: language, model: model, prompt: prompt, out_prefix: prefix)
    cache[key] = result.text.to_s
  rescue WhisperCli::Error => e
    abort e.message
  end

  def classify(windows, cfg)
    patterns = Array(cfg["patterns"]).map(&:to_s).reject(&:empty?)
    abort "pattern.yml needs patterns:" if patterns.empty?

    preamble_title = (cfg["preamble_title"] || "Credits").to_s
    title_tmpl = (cfg["title"] || "Chapter $n").to_s
    min_gap = (cfg["min_gap_min"] || 8).to_f * 60.0

    tracks = []
    at0 = windows.find { |w| w[:t] <= 0.05 }
    if at0 && match_patterns(at0[:text], patterns).nil?
      tracks << { t: 0.0, title: preamble_title, kind: :preamble, text: at0[:text].to_s }
    end

    n = 0
    windows.sort_by { |w| w[:t] }.each do |w|
      next if tracks.any? { |t| t[:kind] == :preamble } && w[:t] <= 0.05

      m = match_patterns(w[:text], patterns)
      next unless m
      if tracks.last && tracks.last[:kind] == :chapter && (w[:t] - tracks.last[:t]) < min_gap
        next
      end

      n += 1
      tracks << {
        t: w[:t],
        title: apply_title(title_tmpl, n: n, text: w[:text], match: m),
        kind: :chapter,
        text: w[:text].to_s
      }
    end
    tracks
  end

  def match_patterns(text, patterns)
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
          return m if m
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

  def apply_title(template, n:, text:, match:)
    first = text.to_s.strip.sub(/\s+/, " ")
    out = template.to_s.gsub("$n", n.to_s).gsub("$text", first)
    out.gsub(/\$(\d+)/) { match[Regexp.last_match(1).to_i].to_s }
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
    narrator = sheet[:tracks].map { |t| t[:performer] }.compact.find { |p| !p.empty? }
    header = sheet[:header].to_s.sub(/\s+\z/, "")
    if header.empty? || !header.match?(/^\s*FILE\s+"/i)
      stem = File.basename(audio, ".*")
      header = <<~CUE.chomp
        TITLE "#{cue_escape(stem)}"
        FILE "#{cue_escape(File.basename(audio))}" MP3
      CUE
    end
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

  def save_cache(audio, cache)
    File.write(cache_path(audio), JSON.generate(cache))
  end

  def play_async(audio, start_s)
    cmd = if command?("ffplay")
            ["ffplay", "-nodisp", "-autoexit", "-loglevel", "error", "-ss", format("%.3f", start_s), "-t", "6", audio]
          elsif command?("mpv")
            ["mpv", "--no-video", "--really-quiet", "--start=#{format('%.3f', start_s)}", "--length=6", audio]
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
