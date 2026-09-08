# frozen_string_literal: true

require "json"
require "time"

module Subpipe
  # Parse softsubs (SRT / ASS / VTT) into [{start_ms, end_ms, text}, ...]
  module Softsub
    module_function

    def load(path)
      return [] if path.nil? || !File.file?(path)

      body = File.read(path, encoding: "UTF-8").sub(/\A\uFEFF/, "")
      case File.extname(path).downcase
      when ".srt" then parse_srt(body)
      when ".ass", ".ssa" then parse_ass(body)
      when ".vtt" then parse_vtt(body)
      else
        if body.include?("[Events]")
          parse_ass(body)
        else
          parse_srt(body)
        end
      end
    end

    def parse_srt(body)
      cues = []
      body.gsub("\r\n", "\n").split(/\n\n+/).each do |block|
        lines = block.strip.split("\n")
        next if lines.size < 2

        timing_idx = lines[0].match?(/^\d+$/) ? 1 : 0
        timing = lines[timing_idx]
        next unless timing&.include?("-->")

        start_s, end_s = timing.split("-->").map(&:strip)
        text = lines[(timing_idx + 1)..].join("\n")
        text = strip_tags(text)
        next if text.strip.empty?

        cues << {
          start_ms: srt_time_to_ms(start_s),
          end_ms: srt_time_to_ms(end_s),
          text: text.strip
        }
      end
      cues
    end

    def parse_ass(body)
      cues = []
      body.each_line do |line|
        next unless line.start_with?("Dialogue:")

        # Dialogue: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        payload = line.sub(/^Dialogue:\s*/, "")
        parts = payload.split(",", 10)
        next if parts.size < 10

        text = parts[9].to_s.gsub(/\{[^}]*\}/, "").gsub("\\N", "\n").gsub("\\n", "\n")
        text = strip_tags(text).strip
        next if text.empty?

        cues << {
          start_ms: ass_time_to_ms(parts[1]),
          end_ms: ass_time_to_ms(parts[2]),
          text: text
        }
      end
      cues
    end

    def parse_vtt(body)
      cues = []
      body.gsub("\r\n", "\n").sub(/\AWEBVTT[^\n]*\n/, "").split(/\n\n+/).each do |block|
        lines = block.strip.split("\n")
        next if lines.empty?

        timing_idx = lines[0].include?("-->") ? 0 : 1
        timing = lines[timing_idx]
        next unless timing&.include?("-->")

        start_s, end_s = timing.split("-->").map { |t| t.strip.split(/\s+/).first }
        text = lines[(timing_idx + 1)..].join("\n")
        text = strip_tags(text).strip
        next if text.empty?

        cues << {
          start_ms: vtt_time_to_ms(start_s),
          end_ms: vtt_time_to_ms(end_s),
          text: text
        }
      end
      cues
    end

    def srt_time_to_ms(t)
      # 00:00:00,000 or 00:00:00.000
      h, m, rest = t.tr(",", ".").split(":")
      s, frac = rest.split(".")
      ((h.to_i * 3600 + m.to_i * 60 + s.to_i) * 1000) + frac.to_s.ljust(3, "0")[0, 3].to_i
    end

    def vtt_time_to_ms(t)
      srt_time_to_ms(t)
    end

    def ass_time_to_ms(t)
      # H:MM:SS.cs
      h, m, rest = t.strip.split(":")
      s, cs = rest.split(".")
      ((h.to_i * 3600 + m.to_i * 60 + s.to_i) * 1000) + (cs.to_s.ljust(2, "0")[0, 2].to_i * 10)
    end

    def strip_tags(text)
      text.gsub(/<[^>]+>/, "")
    end
  end
end
