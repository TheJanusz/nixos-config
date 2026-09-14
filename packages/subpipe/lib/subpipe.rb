# frozen_string_literal: true

require "fileutils"
require "json"

module Subpipe
  SCHEMA_VERSION = 1

  def self.abort!(msg, code: 1)
    warn "subpipe: #{msg}"
    exit code
  end

  def self.ensure_dir!(path)
    FileUtils.mkdir_p(path)
    path
  end
end

require_relative "subpipe/extract"
require_relative "subpipe/metrics"
require_relative "subpipe/transcribe"
require_relative "subpipe/merge"
require_relative "subpipe/ass"
require_relative "subpipe/timing"
require_relative "subpipe/vocab"
require_relative "subpipe/analyze"
require_relative "subpipe/translate"
require_relative "subpipe/feedback"
require_relative "subpipe/mentor_undo"
require_relative "subpipe/config"
require_relative "subpipe/mentor"
require_relative "subpipe/mentor_reflect"
require_relative "subpipe/mentor_action"
require_relative "subpipe/diarize"
require_relative "subpipe/lektor"
require_relative "subpipe/lektor_direct"

module Subpipe
  # e.g. ass_path("/out", "Show.S01E01", "en") → /out/Show.S01E01.en.ass
  def self.ass_path(out_dir, stem, lang)
    stem = stem.to_s.strip
    stem = "subpipe" if stem.empty?
    File.join(out_dir, "#{stem}.#{lang}.ass")
  end

  def self.source_stem(source)
    return source["stem"] if source.is_a?(Hash) && source["stem"] && !source["stem"].to_s.empty?
    return Vocab.stem_for(source["basename"] || source["path"]) if source.is_a?(Hash)

    Vocab.stem_for(source)
  end

  # Default work dir beside the video: "S01E01 Title.mkv" → "S01E01 Title.subpipe/"
  def self.default_out_dir(video_path)
    video = File.expand_path(video_path.to_s, Dir.pwd)
    stem = Vocab.stem_for(video)
    Subpipe.abort!("cannot derive output dir from empty video path") if stem.empty?

    File.join(File.dirname(video), "#{stem}.subpipe")
  end
end
