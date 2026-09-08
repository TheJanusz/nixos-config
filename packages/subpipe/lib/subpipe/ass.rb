# frozen_string_literal: true

require "json"

module Subpipe
  module Ass
    module_function

    DEFAULT_STYLE = {
      name: "Default",
      fontname: "Arial",
      fontsize: 48,
      primary: "&H00FFFFFF",
      secondary: "&H000000FF",
      outline_c: "&H00000000",
      back: "&H80000000",
      bold: -1,
      italic: 0,
      underline: 0,
      strikeout: 0,
      scale_x: 100,
      scale_y: 100,
      spacing: 0,
      angle: 0,
      border_style: 1,
      outline: 2,
      shadow: 1,
      alignment: 2,
      margin_l: 20,
      margin_r: 20,
      margin_v: 40,
      encoding: 1
    }.freeze

    def write(path, cues, title: "subpipe", text_key: "text_en")
      lines = []
      lines << "[Script Info]"
      lines << "Title: #{title}"
      lines << "ScriptType: v4.00+"
      lines << "WrapStyle: 0"
      lines << "ScaledBorderAndShadow: yes"
      lines << "YCbCr Matrix: None"
      lines << "PlayResX: 1920"
      lines << "PlayResY: 1080"
      lines << ""
      lines << "[V4+ Styles]"
      lines << "Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, " \
              "Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, " \
              "Alignment, MarginL, MarginR, MarginV, Encoding"
      s = DEFAULT_STYLE
      lines << format(
        "Style: %s,%s,%d,%s,%s,%s,%s,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d",
        s[:name], s[:fontname], s[:fontsize], s[:primary], s[:secondary], s[:outline_c], s[:back],
        s[:bold], s[:italic], s[:underline], s[:strikeout], s[:scale_x], s[:scale_y], s[:spacing], s[:angle],
        s[:border_style], s[:outline], s[:shadow], s[:alignment], s[:margin_l], s[:margin_r], s[:margin_v],
        s[:encoding]
      )
      lines << ""
      lines << "[Events]"
      lines << "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text"
      cues.each do |cue|
        text = escape(cue[text_key].to_s)
        next if text.strip.empty?

        lines << format(
          "Dialogue: 0,%s,%s,Default,,0,0,0,,%s",
          ms_to_ass(cue.fetch("start_ms")),
          ms_to_ass(cue.fetch("end_ms")),
          text.gsub("\n", "\\N")
        )
      end
      File.write(path, lines.join("\n") + "\n")
      path
    end

    def ms_to_ass(ms)
      ms = ms.to_i
      cs = (ms / 10) % 100
      total_s = ms / 1000
      s = total_s % 60
      total_m = total_s / 60
      m = total_m % 60
      h = total_m / 60
      format("%d:%02d:%02d.%02d", h, m, s, cs)
    end

    def escape(text)
      text.gsub("\\", "\\\\").gsub("{", "\\{").gsub("}", "\\}")
    end
  end
end
