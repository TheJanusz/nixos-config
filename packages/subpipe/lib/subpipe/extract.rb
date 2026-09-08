# frozen_string_literal: true

require "json"
require "fileutils"
require "open3"
require "digest"
require_relative "vocab"

module Subpipe
  module Extract
    module_function

    def run(video, out_dir, track: nil)
      Subpipe.abort!("video not found: #{video}") unless File.file?(video)
      Subpipe.ensure_dir!(out_dir)

      video = File.expand_path(video)
      basename = File.basename(video)
      stem = Vocab.stem_for(basename)
      filename_vocab = Vocab.filename_terms(basename)
      meta = {
        "path" => video,
        "basename" => basename,
        "stem" => stem,
        "sha256" => Digest::SHA256.file(video).hexdigest,
        "duration_ms" => probe_duration_ms(video),
        "filename_vocab" => filename_vocab
      }

      audio_path = File.join(out_dir, "audio.wav")
      extract_audio!(video, audio_path)

      sub_info = select_subtitle_track(video, track)
      softsub_path = nil
      if sub_info
        softsub_path = File.join(out_dir, "softsub#{sub_info['ext']}")
        extract_subtitle!(video, sub_info, softsub_path)
      end

      manifest = {
        "source" => meta,
        "assets" => {
          "audio" => File.basename(audio_path),
          "softsub" => softsub_path && File.basename(softsub_path),
          "softsub_track" => sub_info
        }
      }
      File.write(File.join(out_dir, "extract.json"), JSON.pretty_generate(manifest))
      vocab_note = filename_vocab.empty? ? "" : " (vocab: #{filename_vocab.join(', ')})"
      puts "Extracted audio#{softsub_path ? ' + softsub' : ' (no softsub)'}#{vocab_note} → #{out_dir}"
      manifest
    end

    def probe_duration_ms(video)
      out, status = Open3.capture2(
        "ffprobe", "-v", "error", "-show_entries", "format=duration",
        "-of", "default=noprint_wrappers=1:nokey=1", video
      )
      Subpipe.abort!("ffprobe failed for #{video}") unless status.success?
      (out.strip.to_f * 1000).round
    end

    def extract_audio!(video, dest)
      ok = system(
        "ffmpeg", "-y", "-i", video,
        "-vn", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le",
        dest,
        out: File::NULL, err: File::NULL
      )
      Subpipe.abort!("ffmpeg audio extract failed") unless ok
    end

    def select_subtitle_track(video, preferred_id)
      via_mkvmerge(video, preferred_id) || via_ffprobe(video, preferred_id)
    end

    def via_mkvmerge(video, preferred_id)
      out, status = Open3.capture2("mkvmerge", "-J", video)
      return nil unless status.success?

      data = JSON.parse(out)
      tracks = Array(data["tracks"]).select { |t| t["type"] == "subtitles" }
      return nil if tracks.empty?

      chosen =
        if preferred_id
          tracks.find { |t| t["id"] == preferred_id } ||
            Subpipe.abort!("subtitle track #{preferred_id} not found")
        else
          eng = tracks.find do |t|
            props = t["properties"] || {}
            lang = (props["language"] || props["language_ietf"] || "").downcase
            lang.start_with?("en") || lang == "eng"
          end
          eng || tracks.first
        end

      codec = chosen.dig("properties", "codec_id").to_s
      {
        "id" => chosen["id"],
        "codec_id" => codec,
        "language" => chosen.dig("properties", "language"),
        "ext" => codec_ext(codec),
        "method" => "mkvextract"
      }
    end

    def via_ffprobe(video, preferred_id)
      out, status = Open3.capture2(
        "ffprobe", "-v", "error", "-select_streams", "s",
        "-show_entries", "stream=index,codec_name,codec_tag_string:stream_tags=language",
        "-of", "json", video
      )
      return nil unless status.success?

      streams = Array(JSON.parse(out)["streams"])
      return nil if streams.empty?

      chosen =
        if preferred_id
          streams.find { |s| s["index"] == preferred_id } ||
            Subpipe.abort!("subtitle stream #{preferred_id} not found")
        else
          eng = streams.find do |s|
            lang = s.dig("tags", "language").to_s.downcase
            lang.start_with?("en") || lang == "eng"
          end
          eng || streams.first
        end

      codec = chosen["codec_name"].to_s
      {
        "id" => chosen["index"],
        "codec_id" => codec,
        "language" => chosen.dig("tags", "language"),
        "ext" => codec_ext(codec),
        "method" => "ffmpeg"
      }
    end

    def codec_ext(codec)
      case codec
      when /ASS|SSA|ass|ssa/i then ".ass"
      when /SUBRIP|SRT|subrip|srt/i then ".srt"
      when /VTT|webvtt/i then ".vtt"
      when /UTF8|ASCII|TEXT|mov_text/i then ".srt"
      else ".srt"
      end
    end

    def extract_subtitle!(video, info, dest)
      case info["method"]
      when "mkvextract"
        ok = system("mkvextract", "tracks", video, "#{info['id']}:#{dest}", out: File::NULL, err: File::NULL)
        Subpipe.abort!("mkvextract failed for track #{info['id']}") unless ok
      else
        # Map ffprobe stream index to ffmpeg 0-based subtitle stream selector
        ok = system(
          "ffmpeg", "-y", "-i", video,
          "-map", "0:#{info['id']}",
          dest,
          out: File::NULL, err: File::NULL
        )
        Subpipe.abort!("ffmpeg subtitle extract failed for stream #{info['id']}") unless ok
      end
    end
  end
end
