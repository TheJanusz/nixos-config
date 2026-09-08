# frozen_string_literal: true

require "json"
require "fileutils"
require "open3"
require_relative "vocab"
require_relative "metrics"

module Subpipe
  module Transcribe
    module_function

    def run(out_dir, language: "en", model: nil, vocab_path: nil)
      t0 = Metrics.monotonic
      audio = File.join(out_dir, "audio.wav")
      Subpipe.abort!("missing #{audio}; run extract first") unless File.file?(audio)

      model ||= ENV["SUBPIPE_WHISPER_MODEL"]
      Subpipe.abort!("no whisper model; set SUBPIPE_WHISPER_MODEL") if model.nil? || model.empty?
      Subpipe.abort!("model not found: #{model}") unless File.file?(model)

      whisper = ENV.fetch("SUBPIPE_WHISPER_BIN", "whisper-cli")
      prefix = File.join(out_dir, "whisper")

      extract = load_extract(out_dir)
      filename_terms = Array(extract.dig("source", "filename_vocab"))
      video_path = extract.dig("source", "path")
      stem = Subpipe.source_stem(extract["source"] || {})
      start_dir = video_path && File.directory?(File.dirname(video_path)) ? File.dirname(video_path) : out_dir
      show_store, vocab_files = Vocab.load_effective(
        start_dir: start_dir,
        stem: stem,
        video_path: video_path,
        explicit: vocab_path
      )
      terms = Vocab.asr_terms(show_store, extra: filename_terms)
      prompt = Vocab.whisper_prompt(terms)
      warn "Vocab files: #{vocab_files.join(', ')}" unless vocab_files.empty?

      cmd = [
        whisper,
        "-m", model,
        "-f", audio,
        "-l", language,
        "-oj",
        "-ojf",
        "-of", prefix
      ]
      if prompt
        cmd += ["--prompt", prompt, "--carry-initial-prompt"]
        warn "Whisper vocab prompt: #{prompt}"
      end

      warn "Running: #{cmd.join(' ')}"
      infer_t0 = Metrics.monotonic
      ok = system(*cmd)
      infer_s = Metrics.monotonic - infer_t0
      Subpipe.abort!("whisper-cli failed") unless ok

      json_path = "#{prefix}.json"
      Subpipe.abort!("expected #{json_path}") unless File.file?(json_path)
      puts "Transcription → #{json_path}"

      total_s = Metrics.monotonic - t0
      print_metrics!(
        total_s: total_s,
        infer_s: infer_s,
        extract: extract,
        whisper_path: json_path,
        audio_path: audio
      )
      json_path
    end

    def print_metrics!(total_s:, infer_s:, extract:, whisper_path:, audio_path:)
      audio_ms = extract.dig("source", "duration_ms").to_i
      audio_ms = probe_wav_duration_ms(audio_path) if audio_ms <= 0
      stats = whisper_stats(whisper_path)

      rows = []
      rows << ["wall time", Metrics.format_duration(total_s)]
      rows << ["whisper time", Metrics.format_duration(infer_s)]
      if audio_ms.positive?
        audio_s = audio_ms / 1000.0
        rows << ["audio", Metrics.format_duration(audio_s)]
        if infer_s.positive?
          rows << ["realtime factor", format("%.2f× (whisper/audio)", infer_s / audio_s)]
        end
      end
      rows << ["segments", stats[:segments].to_s] if stats[:segments]
      if stats[:words]&.positive?
        rows << ["words", stats[:words].to_s]
        per = Metrics.per_unit(infer_s, stats[:words], unit: "word")
        rows << ["per word", per] if per
      end
      Metrics.print_report("Transcribe", rows)
    end

    def whisper_stats(path)
      data = JSON.parse(File.read(path))
      transcription = data["transcription"] || data["segments"] || []
      segments =
        case transcription
        when Array then transcription
        else []
        end
      text =
        if data["text"]
          data["text"].to_s
        else
          segments.map { |s| s["text"] || s["word"] }.compact.join(" ")
        end
      {
        segments: segments.size,
        words: Metrics.word_count(text)
      }
    rescue StandardError
      {}
    end

    def probe_wav_duration_ms(path)
      return 0 unless File.file?(path)

      out, status = Open3.capture2(
        "ffprobe", "-v", "error", "-show_entries", "format=duration",
        "-of", "default=noprint_wrappers=1:nokey=1", path
      )
      return 0 unless status.success?

      (out.to_s.strip.to_f * 1000).round
    rescue StandardError
      0
    end

    def load_extract(out_dir)
      path = File.join(out_dir, "extract.json")
      return {} unless File.file?(path)

      JSON.parse(File.read(path))
    rescue JSON::ParserError
      {}
    end
  end
end
