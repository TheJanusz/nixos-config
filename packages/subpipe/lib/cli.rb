#!/usr/bin/env ruby
# frozen_string_literal: true

require "optparse"
require "fileutils"
require "json"
require "pathname"

ROOT = File.expand_path(__dir__)
$LOAD_PATH.unshift(ROOT) unless $LOAD_PATH.include?(ROOT)

require "subpipe"

COMMANDS = {
  "extract" => {
    usage: "subpipe extract VIDEO [-o DIR] [--track N]",
    summary: "Pull audio (and softsubs if present) from a video; default -o is {stem}.subpipe/ beside the video.",
    needs: nil
  },
  "transcribe" => {
    usage: "subpipe transcribe (-o DIR | VIDEO) [--language LANG] [--model PATH] [--vocab PATH]",
    summary: "Run Whisper ASR on extracted audio.wav (prompted with filename + show vocab) and write whisper.json.",
    needs: "extract"
  },
  "merge" => {
    usage: "subpipe merge (-o DIR | VIDEO) [--vocab PATH]",
    summary: "Align ASR with softsubs into context.json and {stem}.en.ass; clamp timing; apply hierarchical vocab.",
    needs: "extract + transcribe"
  },
  "analyze" => {
    usage: "subpipe analyze (-o DIR | VIDEO) [--force] [--model PATH]",
    summary: "Tag each cue with emotion/delivery from audio loudness + LLM; write into context.json for translate/dub.",
    needs: "merge (needs audio.wav + context.json)"
  },
  "translate" => {
    usage: "subpipe translate (-o DIR | VIDEO) [--mode auto|draft|apply] [--force] [--model PATH] [--vocab PATH]",
    summary: "EN→PL speakable text_pl (subtitle = lektor) → {stem}.pl.ass; uses emotion tags when present.",
    needs: "merge (prefer: analyze first)"
  },
  "review" => {
    usage: "subpipe review (-o DIR | VIDEO) [--filter all|pending|edited|clean|flagged] [--vocab PATH]",
    summary: "Neovim mentor: cue list (jk) + EN/PL detail; accepts → Show/corrections.jsonl.",
    needs: "nvim; translate --mode draft (or context with text_pl)"
  },
  "diarize" => {
    usage: "subpipe diarize (-o DIR | VIDEO) [--force]",
    summary: "Speaker diarization (pyannote) → cue.speakers; map names in subpipe-project.json.",
    needs: "merge (audio.wav + context.json)"
  },
  "run" => {
    usage: "subpipe run VIDEO [-o DIR] [--track N] [--language LANG] [--model PATH] [--vocab PATH]",
    summary: "English pipeline: extract → transcribe → merge (then usually: analyze → translate → review).",
    needs: nil
  },
  "vocab" => {
    usage: "subpipe vocab <init|add|promote> …",
    summary: "Manage vocabulary: init | add | promote (show vocab.json + episode {stem}.subpipe/vocab.json).",
    needs: nil
  },
  "config" => {
    usage: "subpipe config <get|set> KEY [VALUE]",
    summary: "Global ~/.config/subpipe/config.json (show subpipe-project.json mentor.* overrides).",
    needs: nil
  },
  "mentor-action" => {
    usage: "subpipe mentor-action --out DIR [--session DIR]  < JSON",
    summary: "Internal JSON protocol for the long-lived Neovim mentor plugin.",
    needs: nil
  },
  "lektor" => {
    usage: "subpipe lektor <init|tui|direct|generate> (-o DIR | VIDEO) …",
    summary: "Offline narrator (Orpheus PL default, or XTTS-v2): voice.json, preview TUI, batch cue WAVs.",
    needs: "translate (context.json with text_pl); analyze tags optional for delivery / speakable phrasing"
  }
}.freeze

LEKTOR_COMMANDS = {
  "init" => {
    usage: "subpipe lektor init (-o DIR | VIDEO) [--reference WAV]",
    summary: "Create voice.json (Orpheus tomasz / v2.5 by default); --reference only needed for XTTS."
  },
  "tui" => {
    usage: "subpipe lektor [tui] (-o DIR | VIDEO)",
    summary: "Browse cues (j/k), preview TTS, edit text_pl (subtitle+lektor), tweak/save voice profile."
  },
  "direct" => {
    usage: "subpipe lektor direct (-o DIR | VIDEO) [--force] [--model PATH]",
    summary: "Optional: re-shape text_pl for speakable lektor (updates pl.ass); skip if already directed unless --force."
  },
  "generate" => {
    usage: "subpipe lektor generate (-o DIR | VIDEO) [--force]",
    summary: "Synthesize lektor/*.wav for spoken cues; skip silence/unchanged; print metrics."
  }
}.freeze

VOCAB_COMMANDS = {
  "init" => {
    usage: "subpipe vocab init [PATH|VIDEO] [--show NAME]",
    summary: "Create vocab.json (default: ./vocab.json). Pass a video to create {stem}.subpipe/vocab.json."
  },
  "add" => {
    usage: "subpipe vocab add [PATH|VIDEO] --term WORD [--pl PL]… [--alias A]… [--avoid-pl PL]… [--notes TEXT] [--keep-english]",
    summary: "Add/update a term. Default: ./vocab.json. Pass a video for episode {stem}.subpipe/vocab.json.",
    details: <<~DETAILS.chomp
      Target file:
        [PATH|VIDEO]   Optional. vocab.json path, or a video (.mkv/.mp4/…) to write
                       {stem}.subpipe/vocab.json beside that file. If omitted, uses ./vocab.json
                       when it exists in the current directory.
        --vocab PATH   Same as positional PATH|VIDEO.

      Term fields (merged into an existing entry if --term already exists):
        --term WORD    Required. Canonical English form (e.g. motor, Syrena, boot).
                       Used for ASR bias, fuzzy cleanup, and translation glossary.
        --pl PL        Allowed Polish form(s) for this term (repeatable).
                       Pass several times when the translator may choose by context:
                         --term boot --pl bagażnik --pl but
                       A single --pl "a, b, c" is also split into alternatives.
                       The model must pick one of these; it must not invent another.
        --alias A      Known ASR misspelling or alternate English spelling (repeatable).
                       Example: --term Syrena --alias Serena
        --avoid-pl PL  Polish wording the model must not use (repeatable).
                       Example: --term motor --pl motor --avoid-pl motocykl
        --notes TEXT   Free-form note shown in review / glossary context.
        --keep-english Prefer leaving the term in English in Polish subtitles.

      Examples:
        cd ./Show && subpipe vocab add --term motor --pl motor --avoid-pl motocykl
        subpipe vocab add --term boot --pl bagażnik --pl but --notes "car vs footwear"
        subpipe vocab add ./Ep.S01E01.Syrena.mkv --term Syrena --alias Serena --pl Syrena
    DETAILS
  },
  "promote" => {
    usage: "subpipe vocab promote (-o DIR | VIDEO) [--local] [PATH|VIDEO]",
    summary: "Copy glossary prefs from context.json into vocab (nearest vocab.json, --local episode work dir, or PATH/VIDEO)."
  }
}.freeze

def usage!(code: 1)
  lines = ["usage: subpipe <#{COMMANDS.keys.join('|')}> [options]", "", "commands:"]
  COMMANDS.each do |name, meta|
    lines << "  #{name}"
    lines << "      #{meta[:usage]}"
    lines << "      #{meta[:summary]}"
    lines << "      Requires: #{meta[:needs]}" if meta[:needs]
  end
  lines << ""
  lines << "Typical flow: run → analyze → translate --mode draft → review → translate --mode apply → lektor"
  lines << "Mentor review accepts → Show/corrections.jsonl; optional: diarize, then lektor generate"
  lines << ""
  lines << "Vocab discovery (far → near; closer wins):"
  lines << "  ~/.config/subpipe/vocab.json"
  lines << "  …/Show/vocab.json  (any ancestor directory)"
  lines << "  VideoStem.subpipe/vocab.json beside the source video (episode overrides)"
  lines << "  legacy VideoStem.vocab.json beside the video (still read)"
  lines << "  --vocab PATH / SUBPIPE_VOCAB (highest precedence)"
  lines << ""
  lines << "Outputs: work dir defaults to {stem}.subpipe/ beside the video; ASS files are {stem}.{lang}.ass inside it."
  lines << ""
  lines << "Examples:"
  lines << "  subpipe run ./Show/S01E01\\ Title.mkv   # → ./Show/S01E01 Title.subpipe/"
  lines << "  cd ./Show && subpipe vocab init && subpipe vocab add --term motor --pl motor --avoid-pl motocykl"
  lines << "  subpipe vocab add ./Ep.S01E01.Syrena.mkv --term Syrena --alias Serena --pl Syrena"
  lines << "  subpipe translate -o ./ep01 --mode draft && subpipe review -o ./ep01"
  lines << "  subpipe diarize -o ./ep01           # optional speakers → subpipe-project.json map"
  lines << "  subpipe vocab promote -o ./ep01          # → nearest vocab.json"
  lines << "  subpipe vocab promote -o ./ep01 --local  # → {stem}.subpipe/vocab.json"
  lines << ""
  lines << "Tip: run → analyze → translate --mode draft → review → promote vocab → lektor."
  lines << "     (optional: subpipe lektor direct to re-shape text_pl without EN retranslate)"
  lines << "Env: SUBPIPE_VOCAB=/path/to/vocab.json"
  lines << "Lektor: SUBPIPE_ORPHEUS_WORKER, SUBPIPE_ORPHEUS_MODEL, SUBPIPE_ORPHEUS_DEVICE,"
  lines << "        SUBPIPE_XTTS_WORKER, SUBPIPE_XTTS_MODEL, SUBPIPE_XTTS_DEVICE, SUBPIPE_*_HOOK"
  warn lines.join("\n")
  exit code
end

def lektor_usage!(code: 1, error: nil)
  lines = []
  lines << "subpipe: #{error}" if error
  lines << "subpipe lektor — offline narrator (Orpheus PL default, or XTTS-v2)"
  lines << ""
  LEKTOR_COMMANDS.each do |name, meta|
    lines << "  #{name}"
    lines << "      #{meta[:summary]}"
    lines << "      #{meta[:usage]}"
  end
  lines << ""
  lines << "voice.json: engine=orpheus_pl + voice=tomasz|jan|… + orpheus.{temperature,top_p,repetition_penalty}"
  lines << "         or engine=xtts_v2 + reference.wav (+ speed)"
  lines << "Default: subpipe lektor -o DIR  → same as subpipe lektor tui -o DIR"
  warn lines.join("\n")
  exit code
end

def lektor_help!(name, extra: nil, code: 1)
  meta = LEKTOR_COMMANDS.fetch(name)
  lines = [meta[:usage], meta[:summary]]
  lines << extra if extra
  warn lines.join("\n")
  exit code
end

def command_help!(name, extra: nil, code: 1)
  meta = COMMANDS.fetch(name)
  lines = [meta[:usage], meta[:summary]]
  lines << "Requires: #{meta[:needs]}" if meta[:needs]
  lines << extra if extra
  warn lines.join("\n")
  exit code
end

def vocab_usage!(code: 1, error: nil)
  lines = []
  lines << "subpipe: #{error}" if error
  lines << "subpipe vocab — manage show/episode vocabulary"
  lines << ""
  VOCAB_COMMANDS.each do |name, meta|
    lines << "  #{name}"
    lines << "      #{meta[:summary]}"
    lines << "      #{meta[:usage]}"
  end
  lines << ""
  lines << "PATH may be vocab.json or a video (.mkv → {stem}.subpipe/vocab.json)."
  lines << "With no PATH, init/add use ./vocab.json (add requires it to exist unless you pass a path)."
  warn lines.join("\n")
  exit code
end

def vocab_help!(name, extra: nil, code: 1)
  meta = VOCAB_COMMANDS.fetch(name)
  lines = [meta[:usage], meta[:summary]]
  lines << meta[:details] if meta[:details]
  lines << extra if extra
  warn lines.join("\n")
  exit code
end

def add_vocab_option!(opts, options)
  opts.on("--vocab=PATH", "--vocab PATH", "vocab.json or video (.mkv → {stem}.subpipe/vocab.json); default ./vocab.json") { |v| options[:vocab] = v }
end

def vocab_write_target_from!(options, argv, create_cwd: false)
  raw = options[:vocab]
  raw = argv.shift if (raw.nil? || raw.to_s.strip.empty?) && !argv.empty? && !argv.first.start_with?("-")
  Subpipe::Vocab.resolve_write_target(raw, create_cwd: create_cwd)
end

# Resolve -o DIR, or derive {stem}.subpipe/ from a VIDEO path (argv or explicit).
# Returns [out_dir, video_or_nil]
def resolve_out_dir!(command, options, argv, video: nil, require_video: false)
  if options[:out_set]
    out = File.expand_path(options[:out], Dir.pwd)
    vid = video
    if vid.nil? && !argv.empty? && Subpipe::Vocab.media_path?(argv.first)
      vid = File.expand_path(argv.shift, Dir.pwd)
    end
    return [out, vid]
  end

  vid = video
  if vid.nil? && !argv.empty? && Subpipe::Vocab.media_path?(argv.first)
    vid = File.expand_path(argv.shift, Dir.pwd)
  end

  if vid
    out = Subpipe.default_out_dir(vid)
    warn "subpipe: using output dir #{out}"
    return [out, vid]
  end

  if require_video
    command_help!(command, extra: "VIDEO required (creates {stem}.subpipe/ when -o is omitted)")
  else
    command_help!(command, extra: "-o DIR or VIDEO required (VIDEO → {stem}.subpipe/ beside the file)")
  end
end

command = ARGV.shift
usage!(code: 0) if command.nil? || %w[-h --help help].include?(command)
usage! unless COMMANDS.key?(command)

case command
when "extract"
  options = { out: nil, out_set: false, track: nil }
  OptionParser.new do |opts|
    meta = COMMANDS["extract"]
    opts.banner = "#{meta[:usage]}\n#{meta[:summary]}\nDefault -o: {video_dir}/{stem}.subpipe/"
    opts.on("-o DIR", "--out DIR", "Output directory (default: {stem}.subpipe/ beside VIDEO)") { |v| options[:out] = v; options[:out_set] = true }
    opts.on("--track N", Integer, "Subtitle track index (mkvmerge)") { |v| options[:track] = v }
    opts.on("-h", "--help", "Show help") { puts opts; exit 0 }
  end.parse!
  command_help!("extract", extra: "VIDEO required") if ARGV.empty?
  video = File.expand_path(ARGV.shift, Dir.pwd)
  out, = resolve_out_dir!("extract", options, ARGV, video: video, require_video: true)
  Subpipe::Extract.run(video, out, track: options[:track])

when "transcribe"
  options = { out: nil, out_set: false, language: "en", model: nil, vocab: nil }
  OptionParser.new do |opts|
    meta = COMMANDS["transcribe"]
    opts.banner = "#{meta[:usage]}\n#{meta[:summary]}\nRequires: #{meta[:needs]}\nPass -o DIR or VIDEO ({stem}.subpipe/)."
    opts.on("-o DIR", "--out DIR", "Output directory (expects audio.wav)") { |v| options[:out] = v; options[:out_set] = true }
    opts.on("--language LANG", "Whisper language (default: en)") { |v| options[:language] = v }
    opts.on("--model PATH", "ggml model path") { |v| options[:model] = v }
    opts.on("--vocab=PATH", "--vocab PATH", "Show-level vocab.json (relative ok)") { |v| options[:vocab] = v }
    opts.on("-h", "--help", "Show help") { puts opts; exit 0 }
  end.parse!
  out, = resolve_out_dir!("transcribe", options, ARGV)
  Subpipe::Transcribe.run(
    out,
    language: options[:language],
    model: options[:model],
    vocab_path: options[:vocab]
  )

when "merge"
  options = { out: nil, out_set: false, vocab: nil }
  OptionParser.new do |opts|
    meta = COMMANDS["merge"]
    opts.banner = "#{meta[:usage]}\n#{meta[:summary]}\nRequires: #{meta[:needs]}\nPass -o DIR or VIDEO ({stem}.subpipe/)."
    opts.on("-o DIR", "--out DIR", "Output directory") { |v| options[:out] = v; options[:out_set] = true }
    opts.on("--vocab=PATH", "--vocab PATH", "Show-level vocab.json (relative ok)") { |v| options[:vocab] = v }
    opts.on("-h", "--help", "Show help") { puts opts; exit 0 }
  end.parse!
  out, = resolve_out_dir!("merge", options, ARGV)
  Subpipe::Merge.run(out, vocab_path: options[:vocab])

when "analyze"
  options = { out: nil, out_set: false, force: false, model: nil }
  OptionParser.new do |opts|
    meta = COMMANDS["analyze"]
    opts.banner = <<~BANNER.chomp
      #{meta[:usage]}
      #{meta[:summary]}
      Requires: #{meta[:needs]}
      For each cue: measure loudness on audio.wav, then LLM-label emotion + delivery into context.json.
      Starts llama-server once (model stays loaded), stops it when done or on Ctrl+C.
      Batches cues (SUBPIPE_ANALYZE_BATCH, default 8); skips LLM on obvious silence.
      Prefer running this before translate so Polish wording can use the tags (also used later for lektor).
      Labels: emotion=#{Subpipe::Analyze::EMOTIONS.join('|')}
               delivery=#{Subpipe::Analyze::DELIVERIES.join('|')}
    BANNER
    opts.on("-o DIR", "--out DIR", "Episode output directory") { |v| options[:out] = v; options[:out_set] = true }
    opts.on("--force", "Re-analyze cues that already have emotion tags") { options[:force] = true }
    opts.on("--model PATH", "GGUF model path (default: translate model)") { |v| options[:model] = v }
    opts.on("-h", "--help", "Show help") { puts opts; exit 0 }
  end.parse!
  out, = resolve_out_dir!("analyze", options, ARGV)
  Subpipe::Analyze.run(out, force: options[:force], model: options[:model])

when "translate"
  options = { out: nil, out_set: false, mode: "auto", force: false, model: nil, vocab: nil }
  OptionParser.new do |opts|
    meta = COMMANDS["translate"]
    opts.banner = <<~BANNER.chomp
      #{meta[:usage]}
      #{meta[:summary]}
      Requires: #{meta[:needs]}
      Pass -o DIR or VIDEO ({stem}.subpipe/).
      Starts llama-server once (model stays loaded), HTTP keep-alive; stops on finish/Ctrl+C.
      Batches cues (SUBPIPE_TRANSLATE_BATCH, default 2); skips LLM on empty/obvious silence.
      Unparseable/incomplete batches retry those cues singly.
      Modes:
        --mode auto   Run the model, write draft+review, apply into context.json and {stem}.pl.ass.
        --mode draft  Write draft/review only; does not change context.json or {stem}.pl.ass.
        --mode apply  Merge edited translation-draft.json into context.json and {stem}.pl.ass (no model).
    BANNER
    opts.on("-o DIR", "--out DIR", "Output directory (expects context.json)") { |v| options[:out] = v; options[:out_set] = true }
    opts.on("--mode MODE", %w[auto draft apply], "Translation mode: auto, draft, or apply (default: auto)") { |v| options[:mode] = v }
    opts.on("--force", "Retranslate cues that already have text_pl") { options[:force] = true }
    opts.on("--model PATH", "GGUF model path") { |v| options[:model] = v }
    opts.on("--vocab=PATH", "--vocab PATH", "Show-level vocab.json (relative ok)") { |v| options[:vocab] = v }
    opts.on("-h", "--help", "Show help") { puts opts; exit 0 }
  end.parse!
  out, = resolve_out_dir!("translate", options, ARGV)
  Subpipe::Translate.run(
    out,
    mode: options[:mode],
    force: options[:force],
    model: options[:model],
    vocab_path: options[:vocab]
  )

when "review"
  options = { out: nil, out_set: false, vocab: nil, filter: "all" }
  OptionParser.new do |opts|
    meta = COMMANDS["review"]
    opts.banner = <<~BANNER.chomp
      #{meta[:usage]}
      #{meta[:summary]}
      Requires: #{meta[:needs]}
      Neovim cue-list mentor (requires nvim).
      Browse (list focused): j/k next/prev, gg/G first/last, e/t edit EN/PL, Esc back,
        a accept both, E/T accept EN/PL, P accept PL + teach ask, s save, p synth preview,
        A accept voice take, u undo, f filter, h/? help, q quit.
      List colors: gray=pending, green=clean (accepted unchanged), yellow=edited.
      Filter (f): all → pending → edited → clean → flagged (skips empty).
      Teach panel: y / N / S / G / E / 1..9 (bare keys while a question is shown).
      mentor.propagate_on_accept (ask|auto|off; default ask). SUBPIPE_REFLECT=0 = heuristic only.
      Accepts → Show/corrections.jsonl (and voice_takes.jsonl for takes).
    BANNER
    opts.on("-o DIR", "--out DIR", "Episode output directory") { |v| options[:out] = v; options[:out_set] = true }
    opts.on("--filter MODE", %w[all pending unaccepted edited clean flagged], "Cue filter (default: all)") { |v| options[:filter] = v }
    opts.on("--vocab=PATH", "--vocab PATH", "Show-level vocab.json (relative ok)") { |v| options[:vocab] = v }
    opts.on("-h", "--help", "Show help") { puts opts; exit 0 }
  end.parse!
  out, = resolve_out_dir!("review", options, ARGV)
  Subpipe::Mentor.run(out, vocab_path: options[:vocab], filter: options[:filter].to_sym)

when "mentor-action"
  Subpipe::MentorAction.run!(ARGV)

when "diarize"
  options = { out: nil, out_set: false, force: false }
  OptionParser.new do |opts|
    meta = COMMANDS["diarize"]
    opts.banner = <<~BANNER.chomp
      #{meta[:usage]}
      #{meta[:summary]}
      Requires: #{meta[:needs]}
      Needs pyannote.audio + HF_TOKEN (accept model terms on Hugging Face).
      After run, edit Show/subpipe-project.json speaker_map and re-run with --force to apply names.
      Optional speakers/Mike.json profiles feed translate few-shot register hints.
    BANNER
    opts.on("-o DIR", "--out DIR", "Episode output directory") { |v| options[:out] = v; options[:out_set] = true }
    opts.on("--force", "Re-diarize even if speakers already set") { options[:force] = true }
    opts.on("-h", "--help", "Show help") { puts opts; exit 0 }
  end.parse!
  out, = resolve_out_dir!("diarize", options, ARGV)
  Subpipe::Diarize.run(out, force: options[:force])

when "run"
  options = { out: nil, out_set: false, track: nil, language: "en", model: nil, vocab: nil }
  OptionParser.new do |opts|
    meta = COMMANDS["run"]
    opts.banner = "#{meta[:usage]}\n#{meta[:summary]}\nDefault -o: {video_dir}/{stem}.subpipe/"
    opts.on("-o DIR", "--out DIR", "Output directory (default: {stem}.subpipe/ beside VIDEO)") { |v| options[:out] = v; options[:out_set] = true }
    opts.on("--track N", Integer, "Subtitle track index") { |v| options[:track] = v }
    opts.on("--language LANG", "Whisper language (default: en)") { |v| options[:language] = v }
    opts.on("--model PATH", "ggml whisper model path") { |v| options[:model] = v }
    opts.on("--vocab=PATH", "--vocab PATH", "Show-level vocab.json (relative ok)") { |v| options[:vocab] = v }
    opts.on("-h", "--help", "Show help") { puts opts; exit 0 }
  end.parse!
  command_help!("run", extra: "VIDEO required") if ARGV.empty?
  video = File.expand_path(ARGV.shift, Dir.pwd)
  out, = resolve_out_dir!("run", options, ARGV, video: video, require_video: true)
  Subpipe::Extract.run(video, out, track: options[:track])
  Subpipe::Transcribe.run(out, language: options[:language], model: options[:model], vocab_path: options[:vocab])
  Subpipe::Merge.run(out, vocab_path: options[:vocab])
  stem = begin
    ctx = JSON.parse(File.read(File.join(out, "context.json")))
    Subpipe.source_stem(ctx["source"] || {})
  rescue StandardError
    "subpipe"
  end
  puts "Wrote #{Subpipe.ass_path(out, stem, 'en')} and #{File.join(out, 'context.json')}"

when "config"
  sub = ARGV.shift
  meta = COMMANDS["config"]
  if sub.nil? || %w[-h --help help].include?(sub)
    puts <<~HELP
      #{meta[:usage]}
      #{meta[:summary]}
      Keys:
        mentor.propagate_on_accept   ask | auto | off  (default ask)
      Show override: Show/subpipe-project.json → {"mentor":{"propagate_on_accept":"off"}}
      Examples:
        subpipe config get mentor.propagate_on_accept
        subpipe config set mentor.propagate_on_accept auto
    HELP
    exit 0
  end
  case sub
  when "get"
    key = ARGV.shift
    Subpipe.abort!("usage: subpipe config get KEY") if key.nil? || key.empty?
    val = Subpipe::Config.get(key)
    if val.nil?
      puts "(unset; default may apply)"
    else
      puts val.is_a?(String) ? val : JSON.pretty_generate(val)
    end
  when "set"
    key = ARGV.shift
    value = ARGV.shift
    Subpipe.abort!("usage: subpipe config set KEY VALUE") if key.nil? || value.nil?
    out = Subpipe::Config.set!(key, value)
    puts "Set #{key} = #{out.inspect} → #{Subpipe::Config.global_path}"
  else
    Subpipe.abort!("unknown config command #{sub.inspect} (get|set)")
  end

when "vocab"
  sub = ARGV.shift
  if sub.nil? || %w[-h --help help].include?(sub)
    vocab_usage!(code: 0)
  end
  vocab_usage!(error: "unknown vocab command #{sub.inspect}") unless VOCAB_COMMANDS.key?(sub)

  case sub
  when "init"
    options = { vocab: nil, show: nil }
    OptionParser.new do |opts|
      meta = VOCAB_COMMANDS["init"]
      opts.banner = "#{meta[:usage]}\n#{meta[:summary]}"
      add_vocab_option!(opts, options)
      opts.on("--show NAME", "Optional show label") { |v| options[:show] = v }
      opts.on("-h", "--help", "Show help") { puts opts; exit 0 }
    end.parse!
    path = vocab_write_target_from!(options, ARGV, create_cwd: true)
    Subpipe::Vocab.init_file!(path, show: options[:show])

  when "add"
    options = { vocab: nil, term: nil, pl: [], aliases: [], avoid: [], notes: nil, keep_en: nil }
    OptionParser.new do |opts|
      meta = VOCAB_COMMANDS["add"]
      opts.banner = "#{meta[:usage]}\n#{meta[:summary]}\n\n#{meta[:details]}"
      add_vocab_option!(opts, options)
      opts.on("--term WORD", "Canonical English term to add/update (required), e.g. motor") { |v| options[:term] = v }
      opts.on("--pl PL", "Allowed Polish form (repeatable; model picks one by context)") { |v| options[:pl] << v }
      opts.on("--alias A", "ASR misspelling / alternate English form (repeatable)") { |v| options[:aliases] << v }
      opts.on("--avoid-pl PL", "Polish form to forbid for this term (repeatable)") { |v| options[:avoid] << v }
      opts.on("--notes TEXT", "Free-form note for review / glossary") { |v| options[:notes] = v }
      opts.on("--keep-english", "Prefer leaving this term in English in PL subtitles") { options[:keep_en] = true }
      opts.on("-h", "--help", "Show help") { puts opts; exit 0 }
    end.parse!
    vocab_help!("add", extra: "--term WORD required") if options[:term].nil? || options[:term].to_s.strip.empty?
    path = vocab_write_target_from!(options, ARGV)
    store = File.file?(path) ? Subpipe::Vocab.load_file(path) : Subpipe::Vocab.empty_store
    Subpipe::Vocab.add_term!(
      store,
      term: options[:term],
      preferred_translations: options[:pl],
      aliases: options[:aliases],
      avoid_pl: options[:avoid],
      notes: options[:notes],
      keep_english: options[:keep_en]
    )
    Subpipe::Vocab.save_file!(path, store)
    puts "Updated #{path} (#{store['terms'].size} terms)"

  when "promote"
    options = { out: nil, out_set: false, vocab: nil, local: false }
    OptionParser.new do |opts|
      meta = VOCAB_COMMANDS["promote"]
      opts.banner = <<~BANNER.chomp
        #{meta[:usage]}
        #{meta[:summary]}
        Episode dir: -o DIR, or VIDEO → {stem}.subpipe/ beside it.
        Default vocab target: nearest vocab.json up the tree.
        --local writes {stem}.subpipe/vocab.json beside the source video.
        Pass an extra PATH|VIDEO to force the vocab write target.
      BANNER
      opts.on("-o DIR", "--out DIR", "Episode output dir with context.json") { |v| options[:out] = v; options[:out_set] = true }
      opts.on("--local", "Write episode {stem}.subpipe/vocab.json") { options[:local] = true }
      add_vocab_option!(opts, options)
      opts.on("-h", "--help", "Show help") { puts opts; exit 0 }
    end.parse!

    out =
      if options[:out_set]
        File.expand_path(options[:out], Dir.pwd)
      elsif !ARGV.empty? && Subpipe::Vocab.media_path?(ARGV.first)
        vid = File.expand_path(ARGV.shift, Dir.pwd)
        derived = Subpipe.default_out_dir(vid)
        warn "subpipe: using output dir #{derived}"
        derived
      else
        vocab_help!("promote", extra: "-o DIR or VIDEO required (VIDEO → {stem}.subpipe/)")
      end

    ctx_path = File.join(out, "context.json")
    Subpipe.abort!("missing #{ctx_path}") unless File.file?(ctx_path)
    context = JSON.parse(File.read(ctx_path))
    video_path = context.dig("source", "path")
    start_dir = if video_path && File.directory?(File.dirname(video_path))
                  File.dirname(video_path)
                else
                  File.expand_path(out)
                end

    explicit = options[:vocab]
    explicit = ARGV.shift if (explicit.nil? || explicit.to_s.strip.empty?) && !ARGV.empty? && !ARGV.first.start_with?("-")

    path =
      if explicit && !explicit.to_s.strip.empty?
        Subpipe::Vocab.resolve_write_target(explicit, create_cwd: false)
      else
        Subpipe::Vocab.default_promote_path(
          start_dir: start_dir,
          video_path: video_path,
          local: options[:local]
        )
      end
    Subpipe.abort!("could not resolve promote vocab path") if path.nil? || path.empty?

    store = File.file?(path) ? Subpipe::Vocab.load_file(path) : Subpipe::Vocab.empty_store
    stats = Subpipe::Vocab.promote_from_context!(store, context)
    Subpipe::Vocab.save_file!(path, store)
    puts "Promoted into #{path}: +#{stats[:added]} new, #{stats[:updated]} updated (#{stats[:total]} total terms)"
  end

when "lektor"
  sub = ARGV.shift
  # Bare `subpipe lektor -o DIR` → tui; also accept tui|preview|init|direct|generate
  if sub.nil? || %w[-h --help help].include?(sub)
    lektor_usage!(code: 0)
  end

  mode =
    if %w[init tui preview direct generate].include?(sub)
      sub == "preview" ? "tui" : sub
    elsif sub.start_with?("-")
      ARGV.unshift(sub)
      "tui"
    else
      lektor_usage!(error: "unknown lektor command #{sub.inspect}")
    end

  options = { out: nil, out_set: false, force: false, reference: nil, model: nil }
  OptionParser.new do |opts|
    meta = LEKTOR_COMMANDS.fetch(mode == "tui" ? "tui" : mode)
    opts.banner = <<~BANNER.chomp
      #{meta[:usage]}
      #{meta[:summary]}
      Pass -o DIR or VIDEO ({stem}.subpipe/).
      voice.json: engine (orpheus_pl|xtts_v2), voice (Orpheus), speed, language, reference_wav (XTTS).
      Orpheus PL default voice=tomasz, model=v2.5; tune pace via orpheus.{temperature,top_p,repetition_penalty}.
      XTTS needs reference.wav (+ speed).
      direct: optional re-shape of text_pl (subtitle = lektor); skips cues with lektor_directed_at unless --force.
      Translate already writes speakable text_pl (… / —); primary path needs no separate direct.
      Env: SUBPIPE_ORPHEUS_WORKER, SUBPIPE_ORPHEUS_MODEL, SUBPIPE_ORPHEUS_DEVICE,
           SUBPIPE_XTTS_WORKER, SUBPIPE_XTTS_MODEL, SUBPIPE_XTTS_DEVICE, SUBPIPE_*_HOOK,
           SUBPIPE_TRANSLATE_MODEL, SUBPIPE_LEKTOR_DIRECT_BATCH, SUBPIPE_LEKTOR_DIRECT_HOOK
    BANNER
    opts.on("-o DIR", "--out DIR", "Episode output directory") { |v| options[:out] = v; options[:out_set] = true }
    opts.on("--reference WAV", "Copy reference clip into work dir (init)") { |v| options[:reference] = v }
    opts.on("--force", "Regenerate WAVs / re-direct even when already directed") { options[:force] = true }
    opts.on("--model PATH", "GGUF model for direct (default: translate model)") { |v| options[:model] = v }
    opts.on("-h", "--help", "Show help") { puts opts; exit 0 }
  end.parse!

  out, = resolve_out_dir!("lektor", options, ARGV)
  Subpipe::Lektor.run(
    out,
    mode: mode,
    force: options[:force],
    reference: options[:reference],
    model: options[:model]
  )
end
