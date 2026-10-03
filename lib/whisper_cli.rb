# frozen_string_literal: true

require "json"
require "open3"
require "time"

# Shared whisper-cli runner. Callers own policy (vocab prompts, windows, metrics).
module WhisperCli
  module_function

  Result = Struct.new(:text, :segments, :json_path, :elapsed_s, keyword_init: true)

  class Error < StandardError; end

  def transcribe(audio_path, language:, model: nil, prompt: nil, out_prefix:)
    audio_path = File.expand_path(audio_path.to_s)
    raise Error, "audio not found: #{audio_path}" unless File.file?(audio_path)

    model = resolve_model(model)
    bin = resolve_bin
    prefix = out_prefix.to_s
    raise Error, "out_prefix required" if prefix.empty?

    cmd = [bin, "-m", model, "-f", audio_path, "-l", language.to_s, "-oj", "-ojf", "-of", prefix]
    prompt = prompt.to_s.strip
    unless prompt.empty?
      cmd += ["--prompt", prompt, "--carry-initial-prompt"]
    end

    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    _stdout, stderr, status = Open3.capture3(*cmd)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
    unless status.success?
      tail = stderr.to_s.lines.last(12).join
      raise Error, "whisper-cli failed#{"\n" + tail unless tail.strip.empty?}"
    end

    json_path = "#{prefix}.json"
    raise Error, "expected #{json_path}" unless File.file?(json_path)

    parsed = parse_json(json_path)
    Result.new(
      text: parsed[:text],
      segments: parsed[:segments],
      json_path: json_path,
      elapsed_s: elapsed
    )
  end

  def parse_json(path)
    data = JSON.parse(File.read(path))
    raw = data["transcription"] || data["segments"] || []
    segments = raw.is_a?(Array) ? raw : []
    text =
      if data["text"] && !data["text"].to_s.strip.empty?
        data["text"].to_s
      else
        segments.map { |s| s["text"] || s["word"] }.compact.join(" ")
      end
    { text: text.gsub(/\s+/, " ").strip, segments: segments }
  rescue JSON::ParserError => e
    raise Error, "whisper json: #{e.message}"
  end

  def resolve_model(model)
    model = model.to_s.strip
    model = ENV["SUBPIPE_WHISPER_MODEL"].to_s.strip if model.empty?
    if model.empty?
      raise Error, "no whisper model; set SUBPIPE_WHISPER_MODEL or pass --model"
    end
    raise Error, "model not found: #{model}" unless File.file?(model)

    model
  end

  def resolve_bin
    bin = ENV.fetch("SUBPIPE_WHISPER_BIN", "whisper-cli")
    return bin if File.executable?(bin) || system("command", "-v", bin, out: File::NULL, err: File::NULL)

    raise Error, "whisper-cli not on PATH (set SUBPIPE_WHISPER_BIN)"
  end
end
