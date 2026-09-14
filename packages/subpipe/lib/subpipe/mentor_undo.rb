# frozen_string_literal: true

require "json"
require "fileutils"
require "securerandom"
require "time"
require_relative "feedback"
require_relative "vocab"

module Subpipe
  # Append-only mentor undo journal (Show/mentor-undo.jsonl).
  # Restores current-cue text/flags, strips matching corrections, rolls back vocab.
  # Does not restore later cues retranslated by propagate.
  module MentorUndo
    module_function

    UNDO_NAME = "mentor-undo.jsonl"

    def undo_path(out_dir, context = nil)
      File.join(Feedback.show_dir_for(out_dir, context), UNDO_NAME)
    end

    def cue_snapshot(cue)
      {
        "text_en" => cue["text_en"].to_s,
        "text_pl" => cue["text_pl"].to_s,
        "en_accepted_at" => cue["en_accepted_at"],
        "pl_accepted_at" => cue["pl_accepted_at"]
      }
    end

    def apply_cue_snapshot!(cue, snap)
      return if snap.nil?

      cue["text_en"] = snap["text_en"].to_s
      cue["text_pl"] = snap["text_pl"].to_s
      cue["en_accepted_at"] = snap["en_accepted_at"]
      cue["pl_accepted_at"] = snap["pl_accepted_at"]
      cue["lektor_line"] = nil
    end

    def find_term_entry(store, term)
      term = term.to_s.strip
      return nil if term.empty?

      Array(store["terms"]).find { |t| t["term"].to_s.casecmp?(term) }
    end

    def deep_copy(obj)
      JSON.parse(JSON.generate(obj))
    rescue StandardError
      nil
    end

    def append_entry!(out_dir, context, entry)
      path = undo_path(out_dir, context)
      FileUtils.mkdir_p(File.dirname(path))
      File.open(path, "a") { |f| f.puts(JSON.generate(entry)) }
      path
    end

    def record_accept!(out_dir, context, cue, cue_before, correction_kinds:)
      append_entry!(out_dir, context, {
        "id" => SecureRandom.uuid,
        "cue_id" => cue["id"],
        "at" => Time.now.utc.iso8601,
        "kind" => "accept",
        "cue_before" => cue_before,
        "correction_kinds" => Array(correction_kinds).map(&:to_s),
        "vocab" => nil,
        "undone" => false
      })
    end

    def record_vocab!(out_dir, context, cue, cue_before:, vocab_path:, term:, before_entry:, after_entry:)
      append_entry!(out_dir, context, {
        "id" => SecureRandom.uuid,
        "cue_id" => cue["id"],
        "at" => Time.now.utc.iso8601,
        "kind" => "vocab",
        "cue_before" => cue_before,
        "correction_kinds" => [],
        "vocab" => {
          "path" => vocab_path,
          "term" => term,
          "before" => before_entry,
          "after" => after_entry
        },
        "undone" => false
      })
    end

    def read_entries(out_dir, context = nil)
      path = undo_path(out_dir, context)
      return [] unless File.file?(path)

      rows = []
      File.foreach(path) do |line|
        line = line.strip
        next if line.empty?

        begin
          rows << JSON.parse(line)
        rescue JSON::ParserError
          next
        end
      end
      rows
    end

    # Effective open entries: apply tombstones (undone:true / undo_of).
    def open_entries(out_dir, context = nil)
      undone_ids = {}
      entries = []
      read_entries(out_dir, context).each do |row|
        if row["kind"].to_s == "tombstone" || row["undone"] == true
          id = (row["undo_of"] || row["id"]).to_s
          undone_ids[id] = true unless id.empty?
          next
        end
        entries << row
      end
      entries.reject { |r| undone_ids[r["id"].to_s] }
    end

    def latest_open_for_cue(out_dir, cue_id, context = nil)
      open_entries(out_dir, context).reverse.find { |r| r["cue_id"].to_s == cue_id.to_s }
    end

    def tombstone!(out_dir, context, entry_id)
      append_entry!(out_dir, context, {
        "id" => SecureRandom.uuid,
        "kind" => "tombstone",
        "undo_of" => entry_id,
        "at" => Time.now.utc.iso8601,
        "undone" => true
      })
    end

    def restore_vocab!(vocab_info)
      return false if vocab_info.nil?

      path = vocab_info["path"].to_s
      term = vocab_info["term"].to_s
      return false if path.empty? || term.empty? || !File.file?(path)

      store = Vocab.load_file(path)
      before = vocab_info["before"]
      terms = Array(store["terms"])
      terms.reject! { |t| t["term"].to_s.casecmp?(term) }
      terms << before if before.is_a?(Hash)
      store["terms"] = terms
      Vocab.save_file!(path, store)
      true
    end

    def strip_corrections!(out_dir, context, cue_id, kinds:, since_at:)
      path = Feedback.corrections_path(out_dir, context)
      return 0 unless File.file?(path)

      kinds = Array(kinds).map(&:to_s).reject(&:empty?)
      kinds = %w[translate asr] if kinds.empty?
      max_remove = kinds.size
      since = begin
        Time.parse(since_at.to_s) - 5
      rescue StandardError
        nil
      end

      kept = []
      removed = 0
      File.readlines(path).reverse_each do |line|
        raw = line.strip
        if raw.empty?
          kept.unshift(line)
          next
        end
        begin
          row = JSON.parse(raw)
        rescue JSON::ParserError
          kept.unshift(line)
          next
        end

        can_drop = removed < max_remove &&
                   row["cue_id"].to_s == cue_id.to_s &&
                   kinds.include?(row["kind"].to_s)
        if can_drop && since
          begin
            can_drop = Time.parse(row["ts"].to_s) >= since
          rescue StandardError
            # keep can_drop
          end
        end

        if can_drop
          removed += 1
          next
        end
        kept.unshift(line)
      end

      File.write(path, kept.join)
      removed
    end

    def latest_open(out_dir, context = nil)
      open_entries(out_dir, context).last
    end

    # Mutates context cue + glossary; caller must save_context!.
    # Returns { ok:, message:, context:, cue_id: }
    # If cue_id has no entry, falls back to the most recent open journal entry
    # (accept often advances to the next unaccepted cue before \\u).
    def undo_cue!(out_dir, context, cue_id)
      out_dir = File.expand_path(out_dir)
      open = open_entries(out_dir, context)
      entry = latest_open_for_cue(out_dir, cue_id, context)
      fallback = false
      if entry.nil? && !open.empty?
        entry = open.last
        fallback = true
      end
      return { ok: false, message: "nothing to undo for cue #{cue_id}", context: context } if entry.nil?

      target_id = entry["cue_id"]
      cue = Array(context["cues"]).find { |c| c["id"].to_s == target_id.to_s }
      return { ok: false, message: "cue #{target_id} missing", context: context } if cue.nil?

      apply_cue_snapshot!(cue, entry["cue_before"]) if entry["cue_before"]

      kinds = Array(entry["correction_kinds"]).map(&:to_s)
      if entry["kind"].to_s == "accept"
        kinds = %w[translate asr] if kinds.empty?
        strip_corrections!(out_dir, context, target_id, kinds: kinds, since_at: entry["at"])
      end

      if entry["vocab"]
        restore_vocab!(entry["vocab"])
        vpath = entry.dig("vocab", "path").to_s
        term = entry.dig("vocab", "term").to_s
        if File.file?(vpath)
          store = Vocab.load_file(vpath)
          context["glossary"] = Vocab.merge_into_glossary(Array(context["glossary"]), store)
        end
        if entry.dig("vocab", "before").nil? && !term.empty?
          context["glossary"] = Array(context["glossary"]).reject { |g| g["term"].to_s.casecmp?(term) }
        end
      end

      tombstone!(out_dir, context, entry["id"])
      msg = "undid #{entry['kind']} for cue #{target_id}"
      msg += " (not current cue #{cue_id})" if fallback && target_id.to_s != cue_id.to_s
      {
        ok: true,
        message: msg,
        context: context,
        entry_id: entry["id"],
        cue_id: target_id
      }
    end
  end
end
