# frozen_string_literal: true

module Subpipe
  # Display-time clamping for ASS cues (Netflix-ish adult reading norms).
  module Timing
    module_function

    CPS = 17.0 # characters per second (comfortable adult target)
    MIN_MS = 1000
    MAX_MS = 7000
    POST_SPEECH_PAD_MS = 300
    MIN_GAP_MS = 200
    CHAIN_GAP_MS = 80

    def ideal_duration_ms(text)
      chars = text.to_s.gsub(/\s+/, " ").strip.length
      chars = 1 if chars < 1
      ms = ((chars / CPS) * 1000).round
      ms.clamp(MIN_MS, MAX_MS)
    end

    def clamp_cues!(cues)
      cues.each do |cue|
        cue["timing_raw_start_ms"] = cue["start_ms"]
        cue["timing_raw_end_ms"] = cue["end_ms"]
      end

      cues.each_with_index do |cue, i|
        snap_start_to_asr!(cue)
        clamp_end!(cue)
      end

      # Starts may have moved (e.g. off frame 0); keep chronological order
      cues.sort_by! { |c| [c["start_ms"].to_i, c["end_ms"].to_i] }

      cues.each_with_index do |cue, i|
        next_cue = cues[i + 1]
        enforce_gap!(cue, next_cue) if next_cue
        cue["end_ms"] = cue["start_ms"].to_i + 1 if cue["end_ms"].to_i <= cue["start_ms"].to_i
      end

      cues
    end

    def snap_start_to_asr!(cue)
      asr_start = cue["asr_start_ms"]
      return if asr_start.nil?

      # Always sync on-screen start to detected speech onset
      cue["start_ms"] = asr_start.to_i
    end

    def clamp_end!(cue)
      start_ms = cue["start_ms"].to_i
      ideal = ideal_duration_ms(cue["text_en"])
      has_asr = !cue["asr_end_ms"].nil?

      if has_asr
        speech_end = cue["asr_end_ms"].to_i
        # Stay up through the spoken words, and at least long enough to read
        end_ms = [speech_end + POST_SPEECH_PAD_MS, start_ms + ideal].max
        end_ms = [end_ms, start_ms + MIN_MS].max
        # Cap silence hang, but never cut off before speech ends
        capped = [end_ms, start_ms + MAX_MS].min
        end_ms = [capped, speech_end + POST_SPEECH_PAD_MS].max
      else
        # No ASR: shorten long softsub hangs to reading time
        raw_end = cue["end_ms"].to_i
        end_ms = [raw_end, start_ms + ideal].min
        end_ms = [end_ms, start_ms + MIN_MS].max
        end_ms = [end_ms, start_ms + MAX_MS].min
      end

      cue["end_ms"] = end_ms
    end

    def enforce_gap!(cue, next_cue)
      start_ms = cue["start_ms"].to_i
      end_ms = cue["end_ms"].to_i
      next_start = next_cue["start_ms"].to_i

      # Prefer not to truncate active speech for the next cue
      speech_end = cue["asr_end_ms"]
      min_end = speech_end ? speech_end.to_i + POST_SPEECH_PAD_MS : start_ms + 1

      if end_ms >= next_start
        # Overlap: pull back, but keep through speech when possible
        pulled = next_start - CHAIN_GAP_MS
        cue["end_ms"] = [[pulled, min_end].max, start_ms + 1].max
        # If next still overlaps speech, leave through speech (next start snap should have fixed order)
        return
      end

      gap = next_start - end_ms
      if gap < CHAIN_GAP_MS
        pulled = next_start - CHAIN_GAP_MS
        cue["end_ms"] = [[pulled, min_end].max, start_ms + 1].max
      end
    end
  end
end
