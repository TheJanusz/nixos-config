# frozen_string_literal: true

require "json"
require_relative "softsub"
require_relative "ass"
require_relative "timing"
require_relative "vocab"

module Subpipe
  module Merge
    module_function

    OVERLAP_MIN_RATIO = 0.25

    def run(out_dir, vocab_path: nil)
      extract_path = File.join(out_dir, "extract.json")
      whisper_path = File.join(out_dir, "whisper.json")
      Subpipe.abort!("missing #{extract_path}") unless File.file?(extract_path)
      Subpipe.abort!("missing #{whisper_path}") unless File.file?(whisper_path)

      extract = JSON.parse(File.read(extract_path))
      whisper = JSON.parse(File.read(whisper_path))
      asr_segments = whisper_segments(whisper)

      softsub_rel = extract.dig("assets", "softsub")
      softsub_path = softsub_rel && File.join(out_dir, softsub_rel)
      soft_cues = Softsub.load(softsub_path)

      filename_vocab = Array(extract.dig("source", "filename_vocab"))
      video_path = extract.dig("source", "path")
      stem = Subpipe.source_stem(extract["source"] || {})
      # Prefer walking from the video's folder so show/episode vocabs resolve.
      start_dir = if video_path && File.directory?(File.dirname(video_path))
                    File.dirname(video_path)
                  else
                    out_dir
                  end
      show_store, vocab_files = Vocab.load_effective(
        start_dir: start_dir,
        stem: stem,
        video_path: video_path,
        explicit: vocab_path
      )
      vocab_meta = Vocab.asset_meta(
        start_dir: start_dir,
        stem: stem,
        video_path: video_path,
        explicit: vocab_path
      )
      cues = align(asr_segments, soft_cues)
      apply_vocab_corrections!(cues, show_store, extra: filename_vocab)
      glossary = build_glossary(cues, filename_vocab)
      glossary = Vocab.merge_into_glossary(glossary, show_store)

      source = extract.fetch("source").merge(
        "language_guess" => "en",
        "stem" => stem
      )
      en_ass_name = File.basename(Subpipe.ass_path(out_dir, stem, "en"))

      context = {
        "schema_version" => Subpipe::SCHEMA_VERSION,
        "source" => source,
        "assets" => {
          "audio" => extract.dig("assets", "audio"),
          "softsub" => softsub_rel,
          "softsub_track" => extract.dig("assets", "softsub_track"),
          "whisper_json" => "whisper.json",
          "en_ass" => en_ass_name,
          "vocab_files" => vocab_meta["vocab_files"],
          "show_vocab" => vocab_meta["show_vocab"],
          "episode_vocab" => vocab_meta["episode_vocab"]
        },
        "cues" => cues,
        "glossary" => glossary,
        "future" => {
          "notes" => "Fill text_pl / lektor_line / tts_voice per cue in later stages without re-running ASR. Promote glossary prefs with: subpipe vocab promote",
          "target_language" => "pl"
        }
      }

      context_path = File.join(out_dir, "context.json")
      File.write(context_path, JSON.pretty_generate(context))

      ass_path = Subpipe.ass_path(out_dir, stem, "en")
      Ass.write(ass_path, cues, title: extract.dig("source", "basename") || "subpipe")

      warn "Vocab files: #{vocab_files.join(', ')}" unless vocab_files.empty?
      puts "Merged #{cues.size} cues → #{context_path}, #{ass_path}"
      context
    end

    def whisper_segments(whisper)
      transcription = whisper["transcription"] || whisper["segments"] || []
      transcription.map do |seg|
        text = (seg["text"] || seg["word"] || "").to_s.strip
        # whisper.cpp JSON uses offsets in milliseconds under "offsets"
        offsets = seg["offsets"] || {}
        start_ms =
          if offsets["from"]
            offsets["from"].to_i
          elsif seg["timestamps"]
            timestamp_to_ms(seg["timestamps"]["from"])
          else
            ((seg["start"] || 0).to_f * 1000).round
          end
        end_ms =
          if offsets["to"]
            offsets["to"].to_i
          elsif seg["timestamps"]
            timestamp_to_ms(seg["timestamps"]["to"])
          else
            ((seg["end"] || 0).to_f * 1000).round
          end
        conf = seg["confidence"] || seg.dig("tokens", 0, "p")
        {
          start_ms: start_ms,
          end_ms: [end_ms, start_ms + 1].max,
          text: text,
          confidence: conf
        }
      end.reject { |s| s[:text].empty? }
    end

    def timestamp_to_ms(ts)
      return 0 if ts.nil?

      # "00:00:01,230" or "00:00:01.230"
      Softsub.srt_time_to_ms(ts.to_s.tr(",", "."))
    rescue StandardError
      0
    end

    def align(asr_segments, soft_cues)
      cues =
        if soft_cues.empty?
          asr_segments.each_with_index.map { |seg, i| cue_from_asr(seg, i + 1) }
        else
          align_with_softsubs(asr_segments, soft_cues)
        end

      Timing.clamp_cues!(cues)
      cues
    end

    def align_with_softsubs(asr_segments, soft_cues)
      used_asr = {}
      cues = []

      soft_cues.each_with_index do |soft, idx|
        asr_i = best_asr_for_timing(soft, asr_segments, used_asr, soft_index: idx)
        asr = asr_i && asr_segments[asr_i]
        used_asr[asr_i] = true if asr_i

        cues << {
          "id" => format("c%04d", idx + 1),
          "start_ms" => soft[:start_ms],
          "end_ms" => soft[:end_ms],
          "asr_start_ms" => asr&.dig(:start_ms),
          "asr_end_ms" => asr&.dig(:end_ms),
          "text_en" => soft[:text],
          "asr_text" => asr&.dig(:text),
          "subtitle_text" => soft[:text],
          "confidence" => asr&.dig(:confidence),
          "speakers" => nil,
          "notes" => nil,
          "text_pl" => nil,
          "lektor_line" => nil,
          "tts_voice" => nil
        }
      end

      # Append ASR-only segments that didn't match (gaps / missing softsubs)
      asr_segments.each_with_index do |seg, i|
        next if used_asr[i]
        next if covered_by?(seg, cues)

        cues << cue_from_asr(seg, cues.size + 1)
      end

      cues.sort_by { |c| [c["start_ms"], c["end_ms"]] }.each_with_index.map do |c, i|
        c.merge("id" => format("c%04d", i + 1))
      end
    end

    # Prefer IoU match; else ASR center inside soft window / max intersection;
    # else sequential index when soft timing looks broken (very long or starts at 0).
    def best_asr_for_timing(soft, asr_segments, used_asr, soft_index:)
      best_i, best_score = best_asr_match(soft, asr_segments, used_asr)
      return best_i if best_i

      best_i = nil
      best_score = 0
      asr_segments.each_with_index do |seg, i|
        next if used_asr[i]

        inter = [0, [soft[:end_ms], seg[:end_ms]].min - [soft[:start_ms], seg[:start_ms]].max].max
        center = (seg[:start_ms] + seg[:end_ms]) / 2
        in_range = center >= soft[:start_ms] && center <= soft[:end_ms]
        score = in_range ? (1_000_000 + inter) : inter
        if score > best_score
          best_score = score
          best_i = i
        end
      end
      return best_i if best_i && best_score.positive?

      soft_dur = soft[:end_ms] - soft[:start_ms]
      broken = soft_dur > Timing::MAX_MS || soft[:start_ms] <= 0
      return nil unless broken
      return soft_index if soft_index < asr_segments.size && !used_asr[soft_index]

      asr_segments.each_index.find { |i| !used_asr[i] }
    end

    def cue_from_asr(seg, id_num)
      {
        "id" => format("c%04d", id_num),
        "start_ms" => seg[:start_ms],
        "end_ms" => seg[:end_ms],
        "asr_start_ms" => seg[:start_ms],
        "asr_end_ms" => seg[:end_ms],
        "text_en" => seg[:text],
        "asr_text" => seg[:text],
        "subtitle_text" => nil,
        "confidence" => seg[:confidence],
        "speakers" => nil,
        "notes" => nil,
        "text_pl" => nil,
        "lektor_line" => nil,
        "tts_voice" => nil
      }
    end

    def best_asr_match(soft, asr_segments, used_asr)
      best_i = nil
      best_score = 0.0
      asr_segments.each_with_index do |seg, i|
        next if used_asr[i]

        score = overlap_ratio(soft[:start_ms], soft[:end_ms], seg[:start_ms], seg[:end_ms])
        if score > best_score
          best_score = score
          best_i = i
        end
      end
      return [nil, 0.0] if best_score < OVERLAP_MIN_RATIO

      [best_i, best_score]
    end

    def overlap_ratio(a0, a1, b0, b1)
      inter = [0, [a1, b1].min - [a0, b0].max].max
      return 0.0 if inter <= 0

      union = [a1, b1].max - [a0, b0].min
      return 0.0 if union <= 0

      inter.to_f / union
    end

    def covered_by?(seg, cues)
      cues.any? do |c|
        overlap_ratio(seg[:start_ms], seg[:end_ms], c["start_ms"], c["end_ms"]) >= 0.5
      end
    end

    def apply_vocab_corrections!(cues, store, extra: [])
      cues.each do |cue|
        if cue["asr_text"]
          cue["asr_text"] = Vocab.correct_with_vocab(cue["asr_text"], store, extra: extra)
        end
        if cue["text_en"]
          cue["text_en"] = Vocab.correct_with_vocab(cue["text_en"], store, extra: extra)
        end
      end
    end

    def build_glossary(cues, filename_vocab = [])
      terms = Hash.new { |h, k| h[k] = { "count" => 0, "sources" => [] } }

      Array(filename_vocab).each do |term|
        terms[term]["count"] += 1
        terms[term]["sources"] << "filename" unless terms[term]["sources"].include?("filename")
      end

      cues.each do |cue|
        extract_proper_nouns(cue["subtitle_text"]).each do |term|
          terms[term]["count"] += 1
          terms[term]["sources"] << "subtitle" unless terms[term]["sources"].include?("subtitle")
        end
        extract_proper_nouns(cue["asr_text"]).each do |term|
          terms[term]["count"] += 1
          terms[term]["sources"] << "asr" unless terms[term]["sources"].include?("asr")
        end

        # Flag ASR/subtitle disagreements on capitalized tokens
        next unless cue["subtitle_text"] && cue["asr_text"]

        sub_caps = extract_proper_nouns(cue["subtitle_text"])
        asr_caps = extract_proper_nouns(cue["asr_text"])
        (sub_caps - asr_caps).each do |term|
          terms[term]["sources"] << "subtitle_only" unless terms[term]["sources"].include?("subtitle_only")
        end
      end

      terms
        .select { |_t, meta| meta["count"] >= 1 }
        .sort_by { |t, meta| [-meta["count"], t] }
        .first(200)
        .map do |term, meta|
          {
            "term" => term,
            "count" => meta["count"],
            "sources" => meta["sources"],
            "preferred_translations" => [],
            "preferred_translation" => nil,
            "notes" => meta["sources"].include?("filename") ? "from episode filename" : nil
          }
        end
    end

    def extract_proper_nouns(text)
      return [] if text.nil? || text.empty?

      text.scan(/\b[A-Z][A-Za-z0-9'\-]{1,}\b/).reject do |w|
        %w[I I\'m I\'ve I\'ll I\'d OK A The].include?(w)
      end.uniq
    end
  end
end
