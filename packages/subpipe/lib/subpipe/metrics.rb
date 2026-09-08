# frozen_string_literal: true

module Subpipe
  # Shared timing / throughput stats for long model stages (transcribe, analyze,
  # translate, and future lektor/TTS). Prefer Metrics.print_report at stage end.
  module Metrics
    module_function

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def format_duration(seconds)
      s = seconds.to_f
      return format("%.2fs", s) if s < 60

      m = (s / 60).floor
      rem = s - (m * 60)
      format("%dm %04.1fs", m, rem)
    end

    def word_count(text)
      text.to_s.scan(/[A-Za-zÀ-ž0-9][A-Za-zÀ-ž0-9']*/).size
    end

    def char_count(text)
      text.to_s.gsub(/\s+/, " ").strip.length
    end

    # rows: Array of [label, value] or Hash; values already formatted strings/numbers.
    def print_report(stage, rows)
      puts "#{stage} metrics:"
      list =
        case rows
        when Hash then rows.to_a
        else Array(rows)
        end
      width = list.map { |k, _| k.to_s.length }.max || 0
      list.each do |key, val|
        puts format("  %-#{width}s  %s", key, val)
      end
    end

    def per_unit(seconds, count, unit:)
      return nil unless count.to_i.positive? && seconds.to_f.positive?

      format("%.3fs/%s", seconds.to_f / count, unit)
    end
  end
end
