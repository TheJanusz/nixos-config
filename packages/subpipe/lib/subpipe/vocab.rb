# frozen_string_literal: true

require "json"
require "fileutils"

module Subpipe
  # Filename mining + hierarchical vocabulary (quirks across episodes).
  #
  # Discovery (far → near; closer wins on merge):
  #   ~/.config/subpipe/vocab.json
  #   …/Show/vocab.json               (any ancestor directory named vocab.json)
  #   …/Show/Ep.subpipe/vocab.json    (episode work dir beside the video)
  #   legacy: …/Show/Ep.vocab.json    (still read if present)
  #   --vocab PATH / SUBPIPE_VOCAB    (highest precedence)
  #
  # Aliases: exact whole-word remap to canonical term at merge (Ed→Edd, Kristoff→Krzysztof).
  # Short aliases (<4 chars) only when capitalized (Ed, not ed).
  #
  # Vocab file (JSON):
  #   { "schema_version": 1, "show": "car-show", "terms": [
  #     { "term": "boot",
  #       "preferred_translations": ["bagażnik", "but"],
  #       "aliases": [], "avoid_pl": ["bot"],
  #       "keep_english": false, "notes": "car part vs footwear" }
  #   ]}
  # Legacy single preferred_translation is still accepted and normalized to a list.
  #
  # Episode-local add (optional video path):
  #   subpipe vocab add ./Ep.mkv --term Edd --alias Ed --pl Edd
  #   → ./Ep.subpipe/vocab.json
  #
  # Promote after review (default: nearest vocab.json; --local: episode work-dir vocab):
  #   subpipe vocab promote -o ./ep01
  #   subpipe vocab promote -o ./ep01 --local
  module Vocab
    module_function

    DIR_VOCAB_NAME = "vocab.json"
    GLOBAL_VOCAB = File.join(Dir.home, ".config", "subpipe", "vocab.json").freeze
    MEDIA_EXTENSIONS = %w[
      .mkv .mp4 .avi .mov .webm .m4v .ts .m2ts .mpg .mpeg .wmv .flv
    ].freeze

    SKIP_WORDS = %w[
      the a an and or of to for in on at with from by
      season episode ep disc disk part pt special finale
      2160p 1080p 720p 480p 576p 4k uhd hdr dv webrip web-dl
      bluray bdrip dvdrip hdtv x264 x265 hevc aac ac3 dts
      proper repack internal limited extended unrated
      eng english forced srt ass multi
    ].freeze

    EPISODE_PATTERNS = [
      /\bS\d{1,2}E\d{1,3}\b/i,
      /\bS\d{1,2}\.?E\d{1,3}\b/i,
      /\b\d{1,2}x\d{1,3}\b/i,
      /\bSeason\s*\d{1,2}\b/i,
      /\bEpisode\s*\d{1,3}\b/i,
      /\bEP?\s*\d{1,3}\b/i,
      /\b\d{1,2}\.\d{2}\b/
    ].freeze

    def resolve_path(explicit = nil)
      path = explicit.to_s.strip
      path = ENV["SUBPIPE_VOCAB"].to_s.strip if path.empty?
      return nil if path.empty?

      # Relative to the caller's cwd (nix wrapper keeps Dir.pwd).
      File.expand_path(path, Dir.pwd)
    end

    def cwd_vocab_path
      File.join(Dir.pwd, DIR_VOCAB_NAME)
    end

    def media_path?(path)
      return false if path.nil? || path.to_s.strip.empty?

      ext = File.extname(path.to_s).downcase
      MEDIA_EXTENSIONS.include?(ext)
    end

    # Resolve where vocab init/add/promote should write.
    # Accepts: vocab.json path, video path (→ {stem}.subpipe/vocab.json), or nil.
    # When nil: use ./vocab.json (must exist unless create_cwd: true, e.g. init).
    def resolve_write_target(explicit = nil, create_cwd: false)
      raw = explicit.to_s.strip
      if raw.empty?
        cwd = cwd_vocab_path
        return cwd if create_cwd || File.file?(cwd)

        Subpipe.abort!(
          "no vocab path: pass a vocab.json, a video file, or run from a directory that has ./vocab.json"
        )
      end

      path = File.expand_path(raw, Dir.pwd)
      return episode_vocab_path(path) if media_path?(path)

      path
    end

    def stem_for(path_or_basename)
      name = File.basename(path_or_basename.to_s)
      return "" if name.empty?

      # Strip one extension (.mkv); keep multi-part stems intact.
      File.basename(name, File.extname(name))
    end

    # Episode vocab lives in the work dir: {stem}.subpipe/vocab.json beside the video.
    def episode_vocab_path(video_path)
      return nil if video_path.nil? || video_path.to_s.empty?

      video = File.expand_path(video_path)
      stem = stem_for(video)
      return nil if stem.empty?

      File.join(Subpipe.default_out_dir(video), DIR_VOCAB_NAME)
    end

    # Older layout: {stem}.vocab.json beside the video (still discovered for reads).
    def legacy_episode_vocab_path(video_path)
      return nil if video_path.nil? || video_path.to_s.empty?

      video = File.expand_path(video_path)
      stem = stem_for(video)
      return nil if stem.empty?

      File.join(File.dirname(video), "#{stem}.vocab.json")
    end

    # Ordered far → near (later overrides earlier on merge).
    def discover_paths(start_dir:, stem: nil, video_path: nil)
      start = File.expand_path(start_dir.to_s.empty? ? Dir.pwd : start_dir)
      paths = []

      paths << GLOBAL_VOCAB if File.file?(GLOBAL_VOCAB)

      ancestors = []
      dir = start
      loop do
        candidate = File.join(dir, DIR_VOCAB_NAME)
        ancestors << candidate if File.file?(candidate)
        parent = File.dirname(dir)
        break if parent == dir

        dir = parent
      end
      paths.concat(ancestors.reverse)

      # Prefer new episode path; still load legacy beside-video file if present.
      legacy = legacy_episode_vocab_path(video_path)
      if legacy.nil? && stem && !stem.to_s.empty?
        legacy = File.join(start, "#{stem}.vocab.json")
      end
      paths << legacy if legacy && File.file?(legacy)

      ep = episode_vocab_path(video_path)
      if ep.nil? && stem && !stem.to_s.empty?
        ep = File.join(start, "#{stem}.subpipe", DIR_VOCAB_NAME)
      end
      paths << ep if ep && File.file?(ep)

      paths.uniq
    end

    def merge_stores(*stores)
      out = empty_store
      stores.compact.each do |store|
        show = store["show"]
        out["show"] = show if show && !show.to_s.empty?
        Array(store["terms"]).each do |t|
          merge_term_into!(out, t)
        end
      end
      out
    end

    def merge_term_into!(store, term_hash)
      term = term_hash["term"].to_s.strip
      return if term.empty?

      term_hash = normalize_term!(term_hash.dup)
      terms = Array(store["terms"])
      existing = terms.find { |t| t["term"].to_s.casecmp?(term) }
      if existing
        prefs = preferred_list(term_hash)
        # Closer layer replaces preferred list when it provides any.
        apply_preferred!(existing, prefs, replace: !prefs.empty?)
        existing["aliases"] = (Array(existing["aliases"]) + Array(term_hash["aliases"])).map(&:to_s).uniq
        existing["avoid_pl"] = (Array(existing["avoid_pl"]) + Array(term_hash["avoid_pl"])).map(&:to_s).uniq
        if term_hash["notes"] && !term_hash["notes"].to_s.empty?
          existing["notes"] = [existing["notes"], term_hash["notes"]].compact.reject(&:empty?).uniq.join("; ")
        end
        existing["keep_english"] = term_hash["keep_english"] unless term_hash["keep_english"].nil?
        existing["term"] = term_hash["term"] if term_hash["term"]
        normalize_term!(existing)
      else
        terms << term_hash
        store["terms"] = terms
      end
      store
    end

    # Returns [store, paths_used]
    def load_effective(start_dir:, stem: nil, video_path: nil, explicit: nil)
      paths = discover_paths(start_dir: start_dir, stem: stem, video_path: video_path)
      explicit_path = resolve_path(explicit)
      paths << explicit_path if explicit_path && File.file?(explicit_path)
      paths.uniq!

      stores = paths.map { |p| load_file(p) }
      [merge_stores(*stores), paths]
    end

    # Nearest directory vocab.json, or create target per plan; --local → episode work-dir vocab.
    def default_promote_path(start_dir:, video_path: nil, local: false)
      video = video_path.to_s.strip.empty? ? nil : File.expand_path(video_path)
      start = File.expand_path(start_dir.to_s.empty? ? (video ? File.dirname(video) : Dir.pwd) : start_dir)

      if local
        ep = episode_vocab_path(video)
        return ep if ep

        stem = stem_for(video || "")
        Subpipe.abort!("--local requires a source video path to name {stem}.subpipe/vocab.json") if stem.empty?

        return File.join(start, "#{stem}.subpipe", DIR_VOCAB_NAME)
      end

      dir = start
      loop do
        candidate = File.join(dir, DIR_VOCAB_NAME)
        return candidate if File.file?(candidate)

        parent = File.dirname(dir)
        break if parent == dir

        dir = parent
      end

      video_dir = video ? File.dirname(video) : start
      parent = File.dirname(video_dir)
      if parent != video_dir
        File.join(parent, DIR_VOCAB_NAME)
      else
        File.join(video_dir, DIR_VOCAB_NAME)
      end
    end

    def asset_meta(start_dir:, stem: nil, video_path: nil, explicit: nil)
      _store, paths = load_effective(
        start_dir: start_dir,
        stem: stem,
        video_path: video_path,
        explicit: explicit
      )
      {
        "vocab_files" => paths,
        "show_vocab" => default_promote_path(start_dir: start_dir, video_path: video_path, local: false),
        "episode_vocab" => episode_vocab_path(video_path) || (
          stem && !stem.to_s.empty? ? File.join(File.expand_path(start_dir), "#{stem}.subpipe", DIR_VOCAB_NAME) : nil
        )
      }
    end

    def empty_store(show: nil)
      {
        "schema_version" => 1,
        "show" => show,
        "terms" => []
      }
    end

    def load_file(path)
      return empty_store if path.nil? || path.empty?
      return empty_store unless File.file?(path)

      data = JSON.parse(File.read(path))
      data["schema_version"] ||= 1
      data["terms"] = Array(data["terms"]).map { |t| normalize_term!(t) }
      data
    rescue JSON::ParserError => e
      Subpipe.abort!("invalid vocab file #{path}: #{e.message}")
    end

    # preferred_translations[] plus legacy preferred_translation → unique list.
    def preferred_list(entry)
      return [] if entry.nil?

      list = Array(entry["preferred_translations"]) + Array(entry["preferred_translation"])
      list.map { |p| p.to_s.strip }.reject(&:empty?).uniq
    end

    def normalize_term!(entry)
      entry = entry.transform_keys(&:to_s)
      prefs = preferred_list(entry)
      entry["preferred_translations"] = prefs
      entry["preferred_translation"] = prefs.first
      entry["aliases"] = Array(entry["aliases"]).map(&:to_s)
      entry["avoid_pl"] = Array(entry["avoid_pl"]).map(&:to_s)
      entry
    end

    def apply_preferred!(entry, translations, replace: false)
      incoming = Array(translations).map { |p| p.to_s.strip }.reject(&:empty?)
      return entry if incoming.empty? && !replace

      prefs = replace ? incoming : (preferred_list(entry) + incoming).uniq
      entry["preferred_translations"] = prefs
      entry["preferred_translation"] = prefs.first
      entry
    end

    def save_file!(path, store)
      Subpipe.abort!("vocab path required") if path.nil? || path.empty?

      store = store.dup
      store["terms"] = Array(store["terms"]).map { |t| normalize_term!(t.dup) }
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, JSON.pretty_generate(store) + "\n")
      path
    end

    def init_file!(path, show: nil)
      if File.file?(path)
        warn "vocab already exists: #{path}"
        return load_file(path)
      end

      store = empty_store(show: show)
      save_file!(path, store)
      puts "Initialized #{path}"
      store
    end

    def filename_terms(basename)
      name = File.basename(basename.to_s, ".*")
      EPISODE_PATTERNS.each { |re| name = name.gsub(re, " ") }
      name = name.tr("._+[](){}", " ")
      name = name.gsub(/[-–—]+/, " ")

      name.scan(/[A-Za-z][A-Za-z0-9']{2,}/).filter_map do |tok|
        lower = tok.downcase
        next if SKIP_WORDS.include?(lower)
        next if tok.match?(/\A\d/)

        tok.match?(/[A-Z]/) ? tok : tok.capitalize
      end.uniq
    end

    # Strings used to bias Whisper (canonical terms + aliases).
    def asr_terms(store, extra: [])
      from_store = Array(store && store["terms"]).flat_map do |t|
        [t["term"], *Array(t["aliases"])]
      end
      (from_store + Array(extra)).map(&:to_s).reject(&:empty?).uniq
    end

    # Canonical spellings only (for fuzzy near-miss cleanup — not aliases).
    def canonical_terms(store, extra: [])
      from_store = Array(store && store["terms"]).map { |t| t["term"].to_s }
      (from_store + Array(extra)).map(&:to_s).reject(&:empty?).uniq
    end

    # alias (downcase) → canonical term. Longer aliases win on key collision.
    def alias_to_canonical(store)
      map = {} # key => { term:, alias_len: }
      Array(store && store["terms"]).each do |t|
        canon = t["term"].to_s.strip
        next if canon.empty?

        Array(t["aliases"]).each do |al|
          a = al.to_s.strip
          next if a.empty? || a.casecmp?(canon)

          key = a.downcase
          prev = map[key]
          next if prev && a.length < prev[:alias_len]

          map[key] = { term: canon, alias_len: a.length }
        end
      end
      map.transform_values { |v| v[:term] }
    end

    def whisper_prompt(terms)
      list = Array(terms).map(&:to_s).reject(&:empty?).uniq
      return nil if list.empty?

      "Proper names: #{list.join(', ')}."
    end

    # Exact whole-word alias → canonical. Short aliases (<4) only if capitalized (Ed, not ed).
    def remap_aliases(text, store)
      return text if text.nil? || text.empty?

      map = alias_to_canonical(store)
      return text if map.empty?

      text.gsub(/\b[A-Za-z][A-Za-z0-9']*\b/) do |word|
        canon = map[word.downcase]
        next word unless canon
        next word if word.length < 4 && word == word.downcase

        apply_canonical_case(canon, word)
      end
    end

    def apply_canonical_case(canonical, original)
      return canonical.upcase if original == original.upcase && original.match?(/[A-Z]/)
      return canonical.downcase if original == original.downcase

      canonical
    end

    # Fuzzy near-miss cleanup against canonical terms (length ≥ 4).
    def correct_text(text, terms)
      return text if text.nil? || text.empty?

      list = Array(terms).map(&:to_s).reject { |t| t.length < 4 }
      return text if list.empty?

      text.gsub(/\b[A-Za-z][A-Za-z0-9']+\b/) do |word|
        best = list.find { |term| close_match?(word, term) }
        best || word
      end
    end

    # Alias remap then fuzzy canonical cleanup.
    def correct_with_vocab(text, store, extra: [])
      return text if text.nil? || text.empty?

      remapped = remap_aliases(text, store)
      correct_text(remapped, canonical_terms(store, extra: extra))
    end

    # Merge show vocab into episode glossary entries (preferred list wins from vocab).
    def merge_into_glossary(glossary, store)
      glossary = Array(glossary).map { |g| normalize_term!(g.transform_keys(&:to_s)) }
      by_term = glossary.to_h { |g| [g["term"].to_s.downcase, g] }

      Array(store && store["terms"]).each do |t|
        term = t["term"].to_s
        next if term.empty?

        key = term.downcase
        entry = by_term[key] || {
          "term" => term,
          "count" => 0,
          "sources" => [],
          "preferred_translations" => [],
          "preferred_translation" => nil,
          "notes" => nil
        }
        entry["term"] = term if entry["term"].to_s.empty?
        entry["sources"] = Array(entry["sources"])
        entry["sources"] << "show_vocab" unless entry["sources"].include?("show_vocab")
        prefs = preferred_list(t)
        apply_preferred!(entry, prefs, replace: !prefs.empty?)
        entry["notes"] = [entry["notes"], t["notes"]].compact.reject(&:empty?).uniq.join("; ")
        entry["notes"] = nil if entry["notes"].empty?
        entry["avoid_pl"] = Array(t["avoid_pl"]) unless Array(t["avoid_pl"]).empty?
        entry["keep_english"] = t["keep_english"] unless t["keep_english"].nil?
        aliases = Array(t["aliases"]).map(&:to_s).reject(&:empty?)
        unless aliases.empty?
          entry["aliases"] = (Array(entry["aliases"]) + aliases).map(&:to_s).uniq
        end
        by_term[key] = normalize_term!(entry)
      end

      by_term.values.sort_by { |g| [-g["count"].to_i, g["term"].to_s] }
    end

    def add_term!(store, term:, preferred_translation: nil, preferred_translations: nil, aliases: [], avoid_pl: [], notes: nil, keep_english: nil)
      term = term.to_s.strip
      Subpipe.abort!("term required") if term.empty?

      incoming = Array(preferred_translations)
      incoming << preferred_translation unless preferred_translation.nil?
      incoming = incoming.map { |p| p.to_s.strip }.reject(&:empty?)

      terms = Array(store["terms"])
      existing = terms.find { |t| t["term"].to_s.casecmp?(term) }
      if existing
        apply_preferred!(existing, incoming, replace: false) unless incoming.empty?
        existing["aliases"] = (Array(existing["aliases"]) + Array(aliases)).map(&:to_s).uniq
        existing["avoid_pl"] = (Array(existing["avoid_pl"]) + Array(avoid_pl)).map(&:to_s).uniq
        existing["notes"] = notes if notes
        existing["keep_english"] = keep_english unless keep_english.nil?
        normalize_term!(existing)
      else
        entry = {
          "term" => term,
          "aliases" => Array(aliases).map(&:to_s),
          "avoid_pl" => Array(avoid_pl).map(&:to_s),
          "keep_english" => keep_english,
          "notes" => notes
        }
        apply_preferred!(entry, incoming, replace: true)
        terms << normalize_term!(entry)
      end
      store["terms"] = terms
      store
    end

    # Pull learned translations from episode context.json glossary into show vocab.
    def promote_from_context!(store, context)
      added = 0
      updated = 0
      Array(context["glossary"]).each do |g|
        term = g["term"].to_s.strip
        next if term.empty?

        prefs = preferred_list(g)
        notes = g["notes"]
        # Promote when user set preferred PL form(s), or marked keep/avoid
        next if prefs.empty? && Array(g["avoid_pl"]).empty? && g["keep_english"].nil?

        before = store["terms"].find { |t| t["term"].to_s.casecmp?(term) }&.dup
        add_term!(
          store,
          term: term,
          preferred_translations: prefs,
          aliases: [],
          avoid_pl: Array(g["avoid_pl"]),
          notes: notes,
          keep_english: g["keep_english"]
        )
        after = store["terms"].find { |t| t["term"].to_s.casecmp?(term) }
        if before.nil?
          added += 1
        elsif before != after
          updated += 1
        end
      end
      { added: added, updated: updated, total: store["terms"].size }
    end

    def close_match?(word, term)
      return true if word.casecmp?(term)
      return false if (word.length - term.length).abs > 2
      return false if [word.length, term.length].min < 4
      return false unless word[0].downcase == term[0].downcase

      levenshtein(word.downcase, term.downcase) <= (term.length >= 7 ? 2 : 1)
    end

    def levenshtein(a, b)
      return b.length if a.empty?
      return a.length if b.empty?

      prev = (0..b.length).to_a
      a.chars.each_with_index do |ca, i|
        cur = [i + 1]
        b.chars.each_with_index do |cb, j|
          cost = ca == cb ? 0 : 1
          cur << [cur[j] + 1, prev[j + 1] + 1, prev[j] + cost].min
        end
        prev = cur
      end
      prev.last
    end
  end
end
