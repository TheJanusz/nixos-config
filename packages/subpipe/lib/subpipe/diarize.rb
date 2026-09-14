# frozen_string_literal: true

require "json"
require "open3"
require "fileutils"
require_relative "feedback"

module Subpipe
  # Optional speaker diarization → cue["speakers"] = "SPEAKER_00" etc.
  # Uses SUBPIPE_DIARIZE_HOOK or bundled diarize_worker.py (pyannote; needs HF token).
  #
  #   subpipe diarize (-o DIR | VIDEO)
  #   Map names in Show/subpipe-project.json → speaker_map
  module Diarize
    module_function

    def run(out_dir, force: false)
      out_dir = File.expand_path(out_dir)
      context_path = File.join(out_dir, "context.json")
      Subpipe.abort!("missing #{context_path}; run merge first") unless File.file?(context_path)
      context = JSON.parse(File.read(context_path))
      audio = File.join(out_dir, context.dig("assets", "audio") || "audio.wav")
      Subpipe.abort!("missing #{audio}") unless File.file?(audio)

      unless force
        labeled = Array(context["cues"]).count { |c| !c["speakers"].nil? && !c["speakers"].to_s.empty? }
        if labeled == Array(context["cues"]).size && labeled.positive?
          puts "All cues already have speakers (#{labeled}); pass --force to re-run"
          return
        end
      end

      segments = run_diarization(audio)
      Subpipe.abort!("diarization returned no segments") if segments.empty?

      assign_speakers!(context["cues"], segments)
      Feedback.ensure_project_meta!(out_dir, context)
      Feedback.ensure_speakers_dir!(out_dir, context)
      apply_speaker_map!(out_dir, context)
      File.write(context_path, JSON.pretty_generate(context) + "\n")
      counts = Array(context["cues"]).map { |c| c["speakers"] }.tally
      puts "Diarized → #{context_path}"
      counts.each { |spk, n| puts "  #{spk || 'nil'}: #{n}" }
      meta = Feedback.load_project_meta(out_dir, context)
      puts "Rename speakers in #{Feedback.project_meta_path(out_dir, context)} → speaker_map"
      puts "  example: #{JSON.generate({ 'SPEAKER_00' => 'Mike', 'SPEAKER_01' => 'Edd' })}" if meta["speaker_map"].to_h.empty?
      puts "Optional profiles: #{Feedback.speakers_dir(out_dir, context)}/<Name>.json"
    end

    def run_diarization(audio_path)
      if (hook = ENV["SUBPIPE_DIARIZE_HOOK"].to_s.strip) != ""
        out, status = Open3.capture2(hook, audio_path)
        Subpipe.abort!("diarize hook failed") unless status.success?
        return parse_segments(out)
      end

      worker = ENV["SUBPIPE_DIARIZE_WORKER"].to_s.strip
      if worker.empty?
        candidate = File.expand_path("../../diarize_worker.py", __dir__)
        worker = candidate if File.file?(candidate)
      end
      if worker.empty? || !File.file?(worker)
        Subpipe.abort!(<<~MSG)
          no diarize worker. Install pyannote and set:
            SUBPIPE_DIARIZE_WORKER=/path/to/diarize_worker.py
            HF_TOKEN=…  (accept pyannote/speaker-diarization-3.1 terms)
          Or SUBPIPE_DIARIZE_HOOK='my-script.sh' that prints JSON segments on stdout.
        MSG
      end

      token = ENV["HF_TOKEN"] || ENV["HUGGING_FACE_HUB_TOKEN"] || ""
      env = ENV.to_h
      env["HF_TOKEN"] = token unless token.empty?
      out, err, status = Open3.capture3(env, "python3", worker, audio_path)
      unless status.success?
        Subpipe.abort!("diarize worker failed:\n#{err.to_s[0, 2000]}\n#{out.to_s[0, 500]}")
      end
      parse_segments(out)
    end

    def parse_segments(raw)
      data = JSON.parse(raw)
      segs = data.is_a?(Hash) ? data["segments"] : data
      Array(segs).map do |s|
        {
          "start_ms" => (s["start_ms"] || (s["start"].to_f * 1000)).to_i,
          "end_ms" => (s["end_ms"] || (s["end"].to_f * 1000)).to_i,
          "speaker" => s["speaker"].to_s
        }
      end.reject { |s| s["speaker"].empty? }
    rescue JSON::ParserError => e
      Subpipe.abort!("invalid diarize JSON: #{e.message}")
    end

    def assign_speakers!(cues, segments)
      cues.each do |cue|
        start_ms = cue["start_ms"].to_i
        end_ms = cue["end_ms"].to_i
        best = nil
        best_overlap = 0
        segments.each do |seg|
          inter = [0, [end_ms, seg["end_ms"]].min - [start_ms, seg["start_ms"]].max].max
          if inter > best_overlap
            best_overlap = inter
            best = seg["speaker"]
          end
        end
        cue["speakers"] = best if best
      end
    end

    def apply_speaker_map!(out_dir, context)
      meta = Feedback.load_project_meta(out_dir, context)
      map = meta["speaker_map"] || {}
      return if map.empty?

      Array(context["cues"]).each do |cue|
        sp = cue["speakers"].to_s
        cue["speakers"] = map[sp] if map.key?(sp)
      end
    end
  end
end
