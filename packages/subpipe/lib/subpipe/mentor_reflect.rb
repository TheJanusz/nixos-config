# frozen_string_literal: true

require "json"
require_relative "translate"

module Subpipe
  # Classify accepted EN→PL edits into kinds + preset note templates.
  # Heuristic first; optional Bielik refine (SUBPIPE_REFLECT=0 disables LLM).
  module MentorReflect
    module_function

    KINDS = %w[show_ref jargon prefer_over style other].freeze

    # template_id → note string with %{term_en} %{term_pl} %{draft_span} %{gold_span} %{en_bit}
    TEMPLATES = {
      "lemma_inflect" =>
        "Canonical/lemma form; inflect for Polish case/number/gender as needed.",
      "show_ref_w" =>
        "Show/setting reference: EN \"on/in %{term_en}\" → prefer Polish \"w\" + locative of \"%{term_pl}\", not a calque \"na %{term_pl}\".",
      "prefer_pl" =>
        "Prefer \"%{gold_span}\" over \"%{draft_span}\"%{en_bit}.",
      "shorter_register" =>
        "Prefer shorter, more spoken Polish for this sense; avoid stiff or calqued wording.",
      "keep_english" =>
        "Keep \"%{term_en}\" in English in the Polish line.",
      "none" => ""
    }.freeze

    # write_vocab: jargon/show_ref/prefer_over → true; style/other → false by default
    WRITE_VOCAB = {
      "show_ref" => true,
      "jargon" => true,
      "prefer_over" => true,
      "style" => false,
      "other" => false
    }.freeze

    REFLECT_SYSTEM = <<~PROMPT.freeze
      You analyze one accepted English→Polish subtitle correction.
      Return ONLY compact JSON (no markdown fences):
      {
        "kind":"show_ref|jargon|prefer_over|style|other",
        "template_id":"lemma_inflect|show_ref_w|prefer_pl|shorter_register|keep_english|none",
        "term_en":"...",
        "term_pl":"...",
        "draft_span":"...",
        "gold_span":"...",
        "avoid_pl":["..."],
        "notes":"...",
        "write_vocab":true
      }

      Kinds:
      - show_ref: EN on/in show/setting title framing
      - jargon: recurring proper term / glossary lemma
      - prefer_over: local phrasing preference (prefer gold_span over draft_span)
      - style: one-off sentence polish; corrections.jsonl is enough; write_vocab false
      - other: unclear

      term_en MUST be the English span the Polish edit was correcting (the source of the
      changed meaning/phrasing). Do NOT pick an unrelated proper noun or the first word
      of the English line just because it is capitalized. If the edit is whole-sentence
      style polish with no clear EN term, leave term_en empty and use kind=style.

      Prefer template_id + filled slots over free-form notes. If you set notes, keep ≤280 chars
      and consistent with template_id. Ground spans in draft_pl vs gold_pl. Do not invent show facts.
    PROMPT

    def render_template(template_id, slots)
      tpl = TEMPLATES[template_id.to_s] || TEMPLATES["none"]
      en = slots["term_en"].to_s
      en_bit = en.empty? ? "" : " for \"#{en}\""
      format(
        tpl,
        term_en: en,
        term_pl: slots["term_pl"].to_s,
        draft_span: slots["draft_span"].to_s,
        gold_span: slots["gold_span"].to_s,
        en_bit: en_bit
      )
    rescue KeyError, ArgumentError
      TEMPLATES["none"]
    end

    # Longest common prefix/suffix word span between draft and gold.
    def pl_span_diff(draft, gold)
      draft = draft.to_s.strip
      gold = gold.to_s.strip
      return { "draft_span" => "", "gold_span" => "" } if gold.empty? || draft == gold

      db = draft.split(/\s+/)
      gb = gold.split(/\s+/)
      i = 0
      i += 1 while i < db.size && i < gb.size && db[i] == gb[i]
      j = 0
      j += 1 while j < (db.size - i) && j < (gb.size - i) && db[db.size - 1 - j] == gb[gb.size - 1 - j]
      dspan = db[i...(db.size - j)] || []
      gspan = gb[i...(gb.size - j)] || []
      {
        "draft_span" => clean_span(dspan.join(" ")),
        "gold_span" => clean_span(gspan.join(" "))
      }
    end

    def clean_span(s)
      s.to_s.strip.gsub(/\A[[:punct:]]+/, "").gsub(/[[:punct:]]+\z/, "").strip
    end

    def empty_package
      {
        "kind" => "other",
        "template_id" => "none",
        "term_en" => "",
        "term_pl" => "",
        "draft_span" => "",
        "gold_span" => "",
        "notes" => "",
        "avoid_pl" => [],
        "write_vocab" => false,
        "source" => "heuristic"
      }
    end

    def package_from(
      kind:, template_id:, term_en:, term_pl:, draft_span:, gold_span:,
      avoid_pl: nil, notes: nil, write_vocab: nil, source: "heuristic"
    )
      kind = KINDS.include?(kind.to_s) ? kind.to_s : "other"
      template_id = TEMPLATES.key?(template_id.to_s) ? template_id.to_s : "none"
      slots = {
        "term_en" => term_en.to_s.strip,
        "term_pl" => term_pl.to_s.strip,
        "draft_span" => draft_span.to_s.strip,
        "gold_span" => gold_span.to_s.strip
      }
      note = notes.to_s.strip
      note = render_template(template_id, slots) if note.empty?
      avoid = Array(avoid_pl).map { |x| x.to_s.strip }.reject(&:empty?)
      if avoid.empty? && kind == "show_ref" && !slots["term_pl"].empty?
        avoid << "na #{slots['term_pl']}"
      end
      if avoid.empty? && !slots["draft_span"].empty? && %w[prefer_over style].include?(kind)
        avoid << slots["draft_span"]
      end
      wv = write_vocab.nil? ? WRITE_VOCAB.fetch(kind, false) : !!write_vocab
      # Prefer-over needs an EN key to retranslate later cues; otherwise style-only.
      wv = false if wv && slots["term_en"].empty? && kind != "show_ref" && kind != "jargon"

      {
        "kind" => kind,
        "template_id" => template_id,
        "term_en" => slots["term_en"],
        "term_pl" => slots["term_pl"].empty? ? slots["gold_span"] : slots["term_pl"],
        "draft_span" => slots["draft_span"],
        "gold_span" => slots["gold_span"],
        "notes" => note,
        "avoid_pl" => avoid.uniq,
        "write_vocab" => wv,
        "source" => source
      }
    end

    # term_en/term_pl are optional prefills from mentor (glossary hit + PL guess).
    def heuristic_package(cue, term_en = nil, term_pl = nil)
      en_line = cue["text_en"].to_s
      draft = cue["text_pl_model"].to_s
      gold = cue["text_pl"].to_s
      spans = pl_span_diff(draft, gold)
      term_en = term_en.to_s.strip
      term_pl = term_pl.to_s.strip
      term_pl = spans["gold_span"] if term_pl.empty?

      if term_en.empty? && gold == draft
        return empty_package
      end

      show_ref = !term_en.empty? && en_line.match?(/\b(?:on|in|onto)\s+#{Regexp.escape(term_en)}\b/i)
      if show_ref
        extra = ""
        if draft.match?(/\bna\b/i) && gold.match?(/\bw\b/i)
          extra = " User correction preferred \"w …\" over \"na …\"."
        end
        pkg = package_from(
          kind: "show_ref",
          template_id: "show_ref_w",
          term_en: term_en,
          term_pl: term_pl,
          draft_span: spans["draft_span"],
          gold_span: spans["gold_span"],
          avoid_pl: ["na #{term_pl}"],
          write_vocab: true
        )
        pkg["notes"] = "#{pkg['notes']}#{extra}".strip unless extra.empty?
        return pkg
      end

      # Clear PL rephrase span → prefer_over (with EN key) or style (accept-only)
      if !spans["gold_span"].empty? && spans["gold_span"] != spans["draft_span"]
        gold_words = gold.split(/\s+/).size
        span_words = spans["gold_span"].split(/\s+/).size
        almost_full = term_en.empty? && span_words >= [gold_words - 2, 1].max && gold_words >= 8
        kind = if almost_full
                 "style"
               elsif term_en.empty?
                 "style"
               else
                 "prefer_over"
               end
        # Glossary EN hit + local span change still prefer_over (not lemma boilerplate)
        kind = "prefer_over" if !term_en.empty? && !spans["draft_span"].empty?
        template = if kind == "prefer_over" || !spans["draft_span"].empty?
                     "prefer_pl"
                   else
                     "shorter_register"
                   end
        pl_out = if !term_pl.empty? && kind == "jargon"
                   term_pl
                 else
                   (spans["gold_span"].empty? ? term_pl : spans["gold_span"])
                 end
        pl_out = term_pl if pl_out.empty?
        return package_from(
          kind: kind,
          template_id: template,
          term_en: term_en,
          term_pl: pl_out,
          draft_span: spans["draft_span"],
          gold_span: spans["gold_span"],
          avoid_pl: spans["draft_span"].empty? ? [] : [spans["draft_span"]],
          write_vocab: kind == "prefer_over" && !term_en.empty?
        )
      end

      if !term_en.empty? && !term_pl.empty?
        return package_from(
          kind: "jargon",
          template_id: "lemma_inflect",
          term_en: term_en,
          term_pl: term_pl,
          draft_span: spans["draft_span"],
          gold_span: spans["gold_span"],
          write_vocab: true
        )
      end

      package_from(
        kind: "style",
        template_id: "none",
        term_en: term_en,
        term_pl: term_pl,
        draft_span: spans["draft_span"],
        gold_span: spans["gold_span"],
        write_vocab: false
      )
    end

    def reflect(cue, term_en = nil, term_pl = nil, use_llm: true)
      base = heuristic_package(cue, term_en, term_pl)
      return base unless use_llm

      content = Translate.one_shot_chat(
        build_user_prompt(cue, base),
        system: REFLECT_SYSTEM,
        max_tokens: 384
      )
      return base if content.nil? || content.strip.empty?

      parsed = parse_reflect_json(content)
      return base if parsed.nil?

      merge_llm(base, parsed)
    end

    def merge_llm(base, parsed)
      kind = parsed["kind"].to_s.strip
      kind = base["kind"] unless KINDS.include?(kind)
      template_id = parsed["template_id"].to_s.strip
      template_id = base["template_id"] unless TEMPLATES.key?(template_id)

      term_en = parsed["term_en"].to_s.strip
      term_en = base["term_en"] if term_en.empty?
      term_pl = parsed["term_pl"].to_s.strip
      term_pl = base["term_pl"] if term_pl.empty?
      draft_span = parsed["draft_span"].to_s.strip
      draft_span = base["draft_span"] if draft_span.empty?
      gold_span = parsed["gold_span"].to_s.strip
      gold_span = base["gold_span"] if gold_span.empty?

      avoid = Array(parsed["avoid_pl"]).map { |x| x.to_s.strip }.reject(&:empty?)
      avoid = base["avoid_pl"] if avoid.empty?

      notes = parsed["notes"].to_s.strip
      write_vocab = parsed.key?("write_vocab") ? !!parsed["write_vocab"] : nil

      package_from(
        kind: kind,
        template_id: template_id,
        term_en: term_en,
        term_pl: term_pl,
        draft_span: draft_span,
        gold_span: gold_span,
        avoid_pl: avoid,
        notes: notes,
        write_vocab: write_vocab,
        source: "llm"
      )
    end

    def build_user_prompt(cue, heuristic)
      <<~USER
        text_en: #{cue['text_en']}
        draft_pl: #{cue['text_pl_model']}
        gold_pl: #{cue['text_pl']}
        heuristic: #{JSON.generate(heuristic)}
      USER
    end

    def parse_reflect_json(content)
      text = content.to_s.strip
      text = text.sub(/\A```(?:json)?\s*/i, "").sub(/\s*```\z/, "")
      start = text.index("{")
      finish = text.rindex("}")
      return nil if start.nil? || finish.nil? || finish < start

      data = JSON.parse(text[start..finish])
      return nil unless data.is_a?(Hash)

      data
    rescue JSON::ParserError
      nil
    end
  end
end
