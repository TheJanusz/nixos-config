# frozen_string_literal: true

require "json"
require "fileutils"
require "time"

module Subpipe
  # Append-only correction / accept corpus for mentor review and future LoRA/few-shot.
  #
  # Show-level (preferred):  …/Show/corrections.jsonl
  # Episode-level fallback:  {stem}.subpipe/corrections.jsonl
  # Voice takes:             …/Show/voice_takes.jsonl  (or episode)
  #
  # Row kinds: asr | translate | voice
  #
  # Model-agnostic gold (schema_version 2):
  #   after          — accepted / preferred text (gold)
  #   source_text    — input for the task (EN for translate; usually unset for asr)
  # Engine-specific metadata (optional for retrieval; useful for eval):
  #   draft_before   — model draft before user edit (also mirrored as `before` for compat)
  #   model          — which engine produced the draft
  # Corpus gathering requires mentor accept (`subpipe review`).
  module Feedback
    module_function

    CORRECTIONS_NAME = "corrections.jsonl"
    VOICE_TAKES_NAME = "voice_takes.jsonl"
    SPEAKERS_DIR = "speakers"
    PROJECT_META = "subpipe-project.json"
    CORRECTION_SCHEMA = 2

    def show_dir_for(out_dir, context = nil)
      video = context&.dig("source", "path")
      if video && File.file?(video.to_s)
        # Season folder → prefer show root (parent of Season N)
        dir = File.dirname(File.expand_path(video))
        base = File.basename(dir)
        if base.match?(/\ASeason\s*\d+/i) || base.match?(/\AS\d+\z/i)
          return File.dirname(dir)
        end
        return dir
      end
      File.dirname(File.expand_path(out_dir))
    end

    def corrections_path(out_dir, context = nil)
      show = show_dir_for(out_dir, context)
      File.join(show, CORRECTIONS_NAME)
    end

    def voice_takes_path(out_dir, context = nil)
      show = show_dir_for(out_dir, context)
      File.join(show, VOICE_TAKES_NAME)
    end

    def project_meta_path(out_dir, context = nil)
      File.join(show_dir_for(out_dir, context), PROJECT_META)
    end

    def speakers_dir(out_dir, context = nil)
      File.join(show_dir_for(out_dir, context), SPEAKERS_DIR)
    end

    def load_project_meta(out_dir, context = nil)
      path = project_meta_path(out_dir, context)
      if File.file?(path)
        JSON.parse(File.read(path))
      else
        {
          "schema_version" => 1,
          "style_tags" => [],
          "speaker_map" => {} # SPEAKER_00 → "Mike"
        }
      end
    rescue JSON::ParserError
      { "schema_version" => 1, "style_tags" => [], "speaker_map" => {} }
    end

    def save_project_meta!(out_dir, meta, context = nil)
      path = project_meta_path(out_dir, context)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, JSON.pretty_generate(meta) + "\n")
      path
    end

    def ensure_project_meta!(out_dir, context = nil)
      path = project_meta_path(out_dir, context)
      return path if File.file?(path)

      save_project_meta!(out_dir, load_project_meta(out_dir, context), context)
    end

    # Speaker profile shape (Show/speakers/Mike.json):
    #   { "name": "Mike", "register": "casual", "notes": "short sentences; slang OK", "prefer_pl": [], "avoid_pl": [] }
    def ensure_speakers_dir!(out_dir, context = nil)
      dir = speakers_dir(out_dir, context)
      FileUtils.mkdir_p(dir)
      dir
    end

    def style_tags_for(out_dir, context = nil, vocab_store = nil)
      tags = []
      tags.concat(Array(load_project_meta(out_dir, context)["style_tags"]))
      tags.concat(Array(vocab_store && vocab_store["style_tags"]))
      tags.concat(Array(context&.dig("future", "style_tags")))
      tags.map(&:to_s).reject(&:empty?).uniq
    end

    def append_correction!(out_dir, row, context: nil)
      path = corrections_path(out_dir, context)
      write_jsonl!(path, normalize_correction_row(row, out_dir, context))
      path
    end

    def append_voice_take!(out_dir, row, context: nil)
      path = voice_takes_path(out_dir, context)
      write_jsonl!(path, normalize_voice_row(row, out_dir, context))
      path
    end

    def write_jsonl!(path, hash)
      FileUtils.mkdir_p(File.dirname(path))
      File.open(path, "a") { |f| f.puts(JSON.generate(hash)) }
      path
    end

    def normalize_correction_row(row, out_dir, context)
      draft = row.key?("draft_before") ? row["draft_before"].to_s : row["before"].to_s
      {
        "schema_version" => CORRECTION_SCHEMA,
        "kind" => row["kind"].to_s, # asr | translate
        "cue_id" => row["cue_id"],
        "source_text" => row["source_text"], # EN for translate; usually nil for asr
        "before" => draft, # compat: engine draft
        "draft_before" => draft,
        "after" => row["after"].to_s, # gold / accepted text
        "accepted_unchanged" => !!row["accepted_unchanged"],
        "show" => context&.dig("source", "basename") || File.basename(show_dir_for(out_dir, context)),
        "episode" => Subpipe.source_stem(context&.dig("source") || {}),
        "style_tags" => Array(row["style_tags"] || style_tags_for(out_dir, context)),
        "speaker_id" => row["speaker_id"],
        "model" => row["model"],
        "audio_clip" => row["audio_clip"], # optional; Whisper LoRA
        "ts" => row["ts"] || Time.now.utc.iso8601
      }.compact
    end

    def normalize_voice_row(row, out_dir, context)
      {
        "schema_version" => 1,
        "kind" => "voice",
        "cue_id" => row["cue_id"],
        "text" => row["text"].to_s,
        "wav" => row["wav"],
        "orpheus" => row["orpheus"],
        "emotion" => row["emotion"],
        "delivery" => row["delivery"],
        "direction_note" => row["direction_note"],
        "style_tags" => Array(row["style_tags"] || style_tags_for(out_dir, context)),
        "speaker_id" => row["speaker_id"],
        "voice" => row["voice"],
        "accepted" => row.key?("accepted") ? !!row["accepted"] : true,
        "ts" => row["ts"] || Time.now.utc.iso8601
      }.compact
    end

    # Accept EN and/or PL on a cue; append JSONL; stamp accepted_at.
    def accept_cue!(out_dir, context, cue, fields:, style_tags: nil)
      fields = Array(fields).map(&:to_s)
      tags = style_tags || style_tags_for(out_dir, context)
      stem = Subpipe.source_stem(context["source"] || {})
      now = Time.now.utc.iso8601
      paths = []

      if fields.include?("en") || fields.include?("asr")
        before = cue["text_en_model"].to_s
        before = cue["asr_text"].to_s if before.empty?
        before = cue["text_en"].to_s if before.empty?
        after = cue["text_en"].to_s
        unchanged = before == after
        clip = nil
        if ENV.fetch("SUBPIPE_FEEDBACK_CLIPS", "0") != "0"
          clip = export_asr_clip!(out_dir, context, cue)
        end
        paths << append_correction!(out_dir, {
          "kind" => "asr",
          "cue_id" => cue["id"],
          "before" => before,
          "draft_before" => before,
          "after" => after,
          "accepted_unchanged" => unchanged,
          "style_tags" => tags,
          "speaker_id" => primary_speaker(cue),
          "model" => context.dig("assets", "whisper_model") || ENV["SUBPIPE_WHISPER_MODEL"],
          "audio_clip" => clip
        }, context: context)
        cue["en_accepted_at"] = now
      end

      if fields.include?("pl") || fields.include?("translate")
        before = cue["text_pl_model"].to_s
        before = cue["text_pl"].to_s if before.empty?
        after = cue["text_pl"].to_s
        unchanged = before == after
        paths << append_correction!(out_dir, {
          "kind" => "translate",
          "cue_id" => cue["id"],
          "source_text" => cue["text_en"].to_s,
          "before" => before,
          "draft_before" => before,
          "after" => after,
          "accepted_unchanged" => unchanged,
          "style_tags" => tags,
          "speaker_id" => primary_speaker(cue),
          "model" => ENV["SUBPIPE_TRANSLATE_MODEL"]
        }, context: context)
        cue["pl_accepted_at"] = now
      end

      { paths: paths.uniq, cue: cue, episode: stem }
    end

    def primary_speaker(cue)
      sp = cue["speakers"]
      return sp if sp.is_a?(String) && !sp.empty?
      return sp.first if sp.is_a?(Array) && !sp.empty?

      nil
    end

    def read_corrections(out_dir, context: nil, kind: nil, style_tags: nil, exclude_tags: nil, limit: nil)
      path = corrections_path(out_dir, context)
      return [] unless File.file?(path)

      want_tags = Array(style_tags).map(&:to_s).reject(&:empty?)
      skip_tags = Array(exclude_tags).map(&:to_s).reject(&:empty?)
      rows = []
      File.foreach(path) do |line|
        line = line.strip
        next if line.empty?

        begin
          row = JSON.parse(line)
        rescue JSON::ParserError
          next
        end
        next if kind && row["kind"].to_s != kind.to_s

        row_tags = Array(row["style_tags"]).map(&:to_s)
        next if !skip_tags.empty? && (row_tags & skip_tags).any?
        # Untagged rows always match; tagged rows must overlap want_tags when set.
        next if !want_tags.empty? && !row_tags.empty? && (row_tags & want_tags).empty?

        rows << row
      end
      rows = rows.last(limit) if limit && limit.positive?
      rows
    end

    # Few-shot: translate corrections whose source/gold/draft shares a word with the cue.
    # Prefer changed accepts (style teaching); fill remaining slots with unchanged.
    def few_shot_for_cue(out_dir, cue, context: nil, limit: 3, exclude_tags: nil)
      hay = [cue["text_en"], cue["text_pl"]].compact.join(" ").downcase
      words = hay.scan(/[a-zà-ž0-9]{4,}/).uniq
      return [] if words.empty?

      tags = style_tags_for(out_dir, context)
      scored = read_corrections(
        out_dir,
        context: context,
        kind: "translate",
        style_tags: tags.empty? ? nil : tags,
        exclude_tags: exclude_tags
      ).map do |row|
        blob = [
          row["source_text"],
          row["after"],
          row["draft_before"] || row["before"]
        ].compact.join(" ").downcase
        score = words.count { |w| blob.include?(w) }
        [score, row]
      end
      hits = scored.select { |s, _| s.positive? }
      changed = hits.reject { |_, r| r["accepted_unchanged"] }.sort_by { |s, _| -s }
      unchanged = hits.select { |_, r| r["accepted_unchanged"] }.sort_by { |s, _| -s }
      (changed + unchanged).first(limit).map(&:last)
    end

    # Map a correction row to prompt few-shot (source EN → gold PL).
    # Legacy rows without source_text are skipped (before was mislabeled PL draft).
    def few_shot_prompt_pair(row)
      source = row["source_text"].to_s
      gold = row["after"].to_s
      return nil if source.empty? || gold.empty?

      draft = (row["draft_before"] || row["before"]).to_s
      {
        "source_en" => source,
        "pl_gold" => gold,
        "pl_draft" => (draft.empty? || draft == gold) ? nil : draft
      }.compact
    end

    # Phase 4 helper: ASR accept rows with optional audio_clip for Whisper LoRA export.
    def asr_lora_pairs(out_dir, context: nil)
      read_corrections(out_dir, context: context, kind: "asr").map do |row|
        {
          "text" => row["after"].to_s,
          "before" => (row["draft_before"] || row["before"]).to_s,
          "audio_clip" => row["audio_clip"],
          "cue_id" => row["cue_id"],
          "style_tags" => row["style_tags"]
        }.compact
      end.reject { |r| r["text"].empty? }
    end

    # Translate gold pairs for any MT model: source_text → after.
    def translate_gold_pairs(out_dir, context: nil)
      read_corrections(out_dir, context: context, kind: "translate").map do |row|
        src = row["source_text"].to_s
        next if src.empty?

        {
          "source_text" => src,
          "after" => row["after"].to_s,
          "draft_before" => row["draft_before"] || row["before"],
          "accepted_unchanged" => row["accepted_unchanged"],
          "cue_id" => row["cue_id"],
          "style_tags" => row["style_tags"],
          "model" => row["model"]
        }.compact
      end.compact.reject { |r| r["after"].to_s.empty? }
    end

    def export_asr_clip!(out_dir, context, cue, audio_path: nil)
      audio = audio_path || File.join(out_dir, context.dig("assets", "audio") || "audio.wav")
      return nil unless File.file?(audio)

      start_ms = cue["start_ms"].to_i
      end_ms = cue["end_ms"].to_i
      end_ms = start_ms + 500 if end_ms <= start_ms
      clips = File.join(out_dir, "feedback_clips")
      FileUtils.mkdir_p(clips)
      out = File.join(clips, "#{cue['id']}.wav")
      dur = (end_ms - start_ms) / 1000.0
      ss = start_ms / 1000.0
      cmd = [
        "ffmpeg", "-hide_banner", "-nostats", "-y",
        "-ss", format("%.3f", ss), "-t", format("%.3f", dur),
        "-i", audio, "-ac", "1", "-ar", "16000", out
      ]
      ok = system(*cmd, out: File::NULL, err: File::NULL)
      ok ? out : nil
    end
  end
end
