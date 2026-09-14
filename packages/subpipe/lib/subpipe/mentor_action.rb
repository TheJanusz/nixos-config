# frozen_string_literal: true

require "json"
require "fileutils"
require "stringio"
require_relative "mentor"

module Subpipe
  # JSON action protocol for the long-lived Neovim mentor plugin.
  # Invoked as: subpipe mentor-action --out DIR --session DIR
  # Reads one JSON object from stdin (or --op / leftover args).
  module MentorAction
    module_function

    STATE_NAME = "state.json"

    def run!(argv)
      options = { out: nil, session: nil }
      args = argv.dup
      while (a = args.shift)
        case a
        when "--out" then options[:out] = args.shift
        when "--session" then options[:session] = args.shift
        when "-h", "--help"
          puts "subpipe mentor-action --out DIR --session DIR  < JSON"
          exit 0
        else
          args.unshift(a)
          break
        end
      end

      out_dir = File.expand_path(options[:out].to_s)
      Subpipe.abort!("mentor-action: --out required") if out_dir.empty?
      session_dir = options[:session].to_s.empty? ? File.join(out_dir, "mentor-session") : File.expand_path(options[:session])
      FileUtils.mkdir_p(session_dir)

      raw = if !args.empty?
              args.join(" ")
            elsif !$stdin.tty?
              $stdin.read
            else
              "{}"
            end

      req = JSON.parse(raw.to_s.strip.empty? ? "{}" : raw)
      log = StringIO.new
      real_out = $stdout
      real_err = $stderr
      res = nil
      begin
        $stdout = log
        $stderr = log
        res = dispatch(out_dir, session_dir, req)
      ensure
        $stdout = real_out
        $stderr = real_err
      end
      noise = log.string.strip
      warn noise unless noise.empty?
      real_out.puts(JSON.generate(res))
      exit(res["ok"] ? 0 : 1)
    rescue JSON::ParserError => e
      $stdout.puts(JSON.generate({ "ok" => false, "error" => "invalid JSON: #{e.message}" }))
      exit 1
    rescue StandardError => e
      $stdout.puts(JSON.generate({ "ok" => false, "error" => e.message }))
      exit 1
    end

    def dispatch(out_dir, session_dir, req)
      op = req["op"].to_s
      state = load_state(session_dir, req)
      context = Mentor.load_context!(out_dir)
      Mentor.ensure_baselines!(context)
      Feedback.ensure_project_meta!(out_dir, context)
      Feedback.ensure_speakers_dir!(out_dir, context)

      filter = Mentor.normalize_filter(state["filter"] || "all")
      vocab_path = state["vocab_path"]
      idxs = Mentor.visible_indices(context["cues"], filter)
      return err("no cues to review (filter=#{filter})") if idxs.empty?

      cursor = [[state["cursor"].to_i, idxs.size - 1].min, 0].max
      cue_i = idxs[cursor]
      cue = context["cues"][cue_i]
      meta_before = read_meta(session_dir)

      # Teach follow-ups must target the cue still shown in meta (just accepted),
      # not idxs[cursor] after an unaccepted-filter shrink.
      if %w[propagate_skip propagate_confirm reflect].include?(op)
        meta_id = meta_before["cue_id"].to_s
        if !meta_id.empty? && meta_id != cue["id"].to_s
          found = context["cues"].index { |c| c["id"].to_s == meta_id }
          if found
            cue_i = found
            cue = context["cues"][cue_i]
          end
        end
      end

      # Apply editor buffers only when Lua says they changed (or accept/save/quit).
      # Sync target is buffer_cue_id = last loaded cue, never the nav cursor alone.
      unless %w[status load].include?(op)
        sync_from_buffers!(session_dir, context, req, meta_before)
      end

      case op
      when "status", "load"
        write_current!(session_dir, context, idxs, cursor, filter)
        ok(session_dir, context, idxs, cursor, filter, message: "loaded")
      when "next"
        Mentor.save_context!(out_dir, context)
        cursor = [cursor + 1, idxs.size - 1].min
        state["cursor"] = cursor
        save_state!(session_dir, state)
        write_current!(session_dir, context, idxs, cursor, filter)
        ok(session_dir, context, idxs, cursor, filter, message: "next")
      when "prev"
        Mentor.save_context!(out_dir, context)
        cursor = [cursor - 1, 0].max
        state["cursor"] = cursor
        save_state!(session_dir, state)
        write_current!(session_dir, context, idxs, cursor, filter)
        ok(session_dir, context, idxs, cursor, filter, message: "prev")
      when "goto"
        Mentor.save_context!(out_dir, context)
        target_id = req["cue_id"].to_s.strip
        if !target_id.empty?
          found = idxs.index { |i| context["cues"][i]["id"].to_s == target_id }
          return err("cue #{target_id.inspect} not in filter=#{filter}") if found.nil?

          cursor = found
        elsif req.key?("cursor")
          cursor = [[req["cursor"].to_i, idxs.size - 1].min, 0].max
        else
          return err("goto needs cue_id or cursor")
        end
        state["cursor"] = cursor
        save_state!(session_dir, state)
        write_current!(session_dir, context, idxs, cursor, filter)
        ok(session_dir, context, idxs, cursor, filter, message: "goto #{context['cues'][idxs[cursor]]['id']}")
      when "save"
        Mentor.save_context!(out_dir, context)
        write_current!(session_dir, context, idxs, cursor, filter)
        ok(session_dir, context, idxs, cursor, filter, message: "saved")
      when "accept_en"
        before = MentorUndo.cue_snapshot(cue)
        Feedback.accept_cue!(out_dir, context, cue, fields: %w[en])
        MentorUndo.record_accept!(out_dir, context, cue, before, correction_kinds: %w[asr])
        Mentor.save_context!(out_dir, context)
        refresh = after_mutate!(out_dir, session_dir, state, context, filter, cursor, vocab_path)
        ok_refresh(refresh, message: "accepted EN #{cue['id']}")
      when "accept_pl"
        handle_accept_pl(out_dir, session_dir, state, context, cue, cue_i, idxs, cursor, filter, vocab_path, force_ask: false)
      when "accept_both"
        before = MentorUndo.cue_snapshot(cue)
        Feedback.accept_cue!(out_dir, context, cue, fields: %w[en pl])
        MentorUndo.record_accept!(out_dir, context, cue, before, correction_kinds: %w[asr translate])
        Mentor.save_context!(out_dir, context)
        handle_accept_pl_followup(out_dir, session_dir, state, context, cue, cue_i, idxs, cursor, filter, vocab_path, force_ask: false, message: "accepted EN+PL #{cue['id']}")
      when "accept_pl_propagate"
        before = MentorUndo.cue_snapshot(cue)
        Feedback.accept_cue!(out_dir, context, cue, fields: %w[pl])
        MentorUndo.record_accept!(out_dir, context, cue, before, correction_kinds: %w[translate])
        Mentor.save_context!(out_dir, context)
        handle_accept_pl_followup(out_dir, session_dir, state, context, cue, cue_i, idxs, cursor, filter, vocab_path, force_ask: true, message: "accepted PL #{cue['id']} (propagate)")
      when "undo"
        result = MentorUndo.undo_cue!(out_dir, context, cue["id"])
        return err(result[:message]) unless result[:ok]

        context = result[:context]
        Mentor.save_context!(out_dir, context)
        idxs = Mentor.visible_indices(context["cues"], filter)
        # Jump to the cue we actually undid (may differ after accept advanced the cursor)
        target = result[:cue_id].to_s
        if !target.empty? && !idxs.empty?
          found = idxs.index { |i| context["cues"][i]["id"].to_s == target }
          cursor = found unless found.nil?
        end
        cursor = [[cursor.to_i, [idxs.size - 1, 0].max].min, 0].max
        state["cursor"] = cursor
        save_state!(session_dir, state)
        if idxs.empty?
          return { "ok" => true, "done" => true, "message" => result[:message], "meta" => {} }
        end
        write_current!(session_dir, context, idxs, cursor, filter)
        ok(session_dir, context, idxs, cursor, filter, message: result[:message])
      when "propagate_confirm"
        term_en = req["term_en"].to_s.strip
        term_pl = req["term_pl"].to_s.strip
        notes = req["notes"].to_s.strip
        avoid_raw = req["avoid_pl"]
        avoid_pl = case avoid_raw
                   when Array
                     avoid_raw.map { |x| x.to_s.strip }.reject(&:empty?)
                   when String
                     avoid_raw.split(",").map(&:strip).reject(&:empty?)
                   else
                     []
                   end
        return err("propagate_confirm needs term_en and term_pl") if term_en.empty? || term_pl.empty?

        context = Mentor.apply_propagate!(
          out_dir, context, cue_i, term_en, term_pl,
          vocab_path: vocab_path, notes: notes.empty? ? nil : notes, avoid_pl: avoid_pl
        )
        idxs = Mentor.visible_indices(context["cues"], filter)
        cursor = Mentor.advance_after_accept(idxs, context["cues"], cursor, filter)
        state["cursor"] = cursor
        save_state!(session_dir, state)
        if idxs.empty?
          return { "ok" => true, "done" => true, "message" => "all cues accepted", "meta" => {} }
        end
        write_current!(session_dir, context, idxs, cursor, filter)
        ok(session_dir, context, idxs, cursor, filter, message: "propagated #{term_en.inspect}")
      when "reflect"
        term_en = req["term_en"].to_s.strip
        term_pl = req["term_pl"].to_s.strip
        # Empty EN/PL allowed — reflect will classify style-only from cue spans
        warn "Reflecting edit…"
        reflected = MentorReflect.reflect(cue, term_en.empty? ? nil : term_en, term_pl.empty? ? nil : term_pl, use_llm: true)
        # Optional kind override from UI
        if req["force_kind"].to_s != "" && MentorReflect::KINDS.include?(req["force_kind"].to_s)
          reflected = MentorReflect.package_from(
            kind: req["force_kind"],
            template_id: reflected["template_id"],
            term_en: reflected["term_en"],
            term_pl: reflected["term_pl"],
            draft_span: reflected["draft_span"],
            gold_span: reflected["gold_span"],
            avoid_pl: reflected["avoid_pl"],
            notes: reflected["notes"],
            write_vocab: nil,
            source: reflected["source"]
          )
        end
        write_current!(session_dir, context, idxs, cursor, filter)
        meta = read_meta(session_dir)
        {
          "ok" => true,
          "need_notes_confirm" => true,
          "reflect" => reflected,
          "meta" => meta,
          "message" => "reflected (#{reflected['source']} #{reflected['kind']}/#{reflected['template_id']})"
        }
      when "propagate_skip"
        idxs = Mentor.visible_indices(context["cues"], filter)
        cursor = Mentor.advance_after_accept(idxs, context["cues"], cursor, filter)
        state["cursor"] = cursor
        save_state!(session_dir, state)
        Mentor.save_context!(out_dir, context)
        if idxs.empty?
          return { "ok" => true, "done" => true, "message" => "all cues accepted", "meta" => {} }
        end
        write_current!(session_dir, context, idxs, cursor, filter)
        ok(session_dir, context, idxs, cursor, filter, message: "propagate skipped")
      when "generate"
        Mentor.save_context!(out_dir, context)
        result = Mentor.generate_preview!(out_dir, context, cue, session_dir, play: true)
        write_current!(session_dir, context, idxs, cursor, filter)
        ok(session_dir, context, idxs, cursor, filter, message: result[:message] || "preview", extra: { "wav" => result[:wav] })
      when "accept_voice"
        Mentor.save_context!(out_dir, context)
        msg = Mentor.accept_voice_take!(out_dir, context, cue, session_dir)
        Mentor.save_context!(out_dir, context)
        write_current!(session_dir, context, idxs, cursor, filter)
        ok(session_dir, context, idxs, cursor, filter, message: msg || "voice accepted")
      when "toggle_filter"
        Mentor.save_context!(out_dir, context)
        cur_id = cue["id"].to_s
        # all → pending → edited → clean → flagged → all (skip empty buckets)
        order = %i[all pending edited clean flagged]
        start = order.index(Mentor.normalize_filter(filter)) || 0
        next_filter = nil
        idxs = []
        (1..order.size).each do |step|
          cand = order[(start + step) % order.size]
          cand_idxs = Mentor.visible_indices(context["cues"], cand)
          next if cand_idxs.empty? && cand != :all

          next_filter = cand
          idxs = cand_idxs
          break
        end
        return err("no cues to review") if next_filter.nil? || idxs.empty?

        found = idxs.index { |i| context["cues"][i]["id"].to_s == cur_id }
        cursor = found.nil? ? 0 : found
        state["filter"] = next_filter.to_s
        state["cursor"] = cursor
        save_state!(session_dir, state)
        write_current!(session_dir, context, idxs, cursor, next_filter)
        ok(session_dir, context, idxs, cursor, next_filter, message: "filter=#{next_filter}")
      when "quit"
        Mentor.save_context!(out_dir, context)
        { "ok" => true, "quit" => true, "message" => "saved #{File.join(out_dir, 'context.json')}" }
      else
        err("unknown op: #{op.inspect}")
      end
    end

    def handle_accept_pl(out_dir, session_dir, state, context, cue, cue_i, idxs, cursor, filter, vocab_path, force_ask:)
      before = MentorUndo.cue_snapshot(cue)
      Feedback.accept_cue!(out_dir, context, cue, fields: %w[pl])
      MentorUndo.record_accept!(out_dir, context, cue, before, correction_kinds: %w[translate])
      Mentor.save_context!(out_dir, context)
      handle_accept_pl_followup(out_dir, session_dir, state, context, cue, cue_i, idxs, cursor, filter, vocab_path, force_ask: force_ask, message: "accepted PL #{cue['id']}")
    end

    def handle_accept_pl_followup(out_dir, session_dir, state, context, cue, cue_i, idxs, cursor, filter, vocab_path, force_ask:, message:)
      decision = Mentor.propagate_decision(out_dir, context, cue, force_ask: force_ask)
      case decision[:action]
      when :skip
        refresh = after_mutate!(out_dir, session_dir, state, context, filter, cursor, vocab_path)
        ok_refresh(refresh, message: message)
      when :ask
        write_current!(session_dir, context, idxs, cursor, filter)
        meta = read_meta(session_dir)
        {
          "ok" => true,
          "need_propagate" => true,
          "propagate" => {
            "en_pre" => decision[:en_pre],
            "pl_pre" => decision[:pl_pre],
            "notes_pre" => decision[:notes_pre],
            "avoid_pl_pre" => decision[:avoid_pl_pre] || [],
            "kind_pre" => decision[:kind_pre],
            "template_id" => decision[:template_id],
            "draft_span" => decision[:draft_span],
            "gold_span" => decision[:gold_span],
            "write_vocab" => decision[:write_vocab],
            "cue_index" => cue_i
          },
          "meta" => meta,
          "message" => message
        }
      when :auto
        context = Mentor.apply_propagate!(
          out_dir, context, cue_i, decision[:term_en], decision[:term_pl],
          vocab_path: vocab_path, notes: decision[:notes], avoid_pl: decision[:avoid_pl]
        )
        refresh = after_mutate!(out_dir, session_dir, state, context, filter, cursor, vocab_path)
        ok_refresh(refresh, message: "#{message}; propagated")
      else
        refresh = after_mutate!(out_dir, session_dir, state, context, filter, cursor, vocab_path)
        ok_refresh(refresh, message: message)
      end
    end

    def after_mutate!(out_dir, session_dir, state, context, filter, cursor, _vocab_path)
      context = Mentor.load_context!(out_dir) # in case propagate wrote
      idxs = Mentor.visible_indices(context["cues"], filter)
      cursor = Mentor.advance_after_accept(idxs, context["cues"], cursor, filter)
      state["cursor"] = cursor
      save_state!(session_dir, state)
      if idxs.empty?
        return { done: true, context: context, idxs: idxs, cursor: cursor, filter: filter }
      end
      write_current!(session_dir, context, idxs, cursor, filter)
      { done: false, context: context, idxs: idxs, cursor: cursor, filter: filter, session_dir: session_dir }
    end

    def ok_refresh(refresh, message:)
      if refresh[:done]
        return { "ok" => true, "done" => true, "message" => "all cues accepted", "meta" => {} }
      end
      ok(refresh[:session_dir], refresh[:context], refresh[:idxs], refresh[:cursor], refresh[:filter], message: message)
    end

    def write_current!(session_dir, context, idxs, cursor, filter)
      cue = context["cues"][idxs[cursor]]
      Mentor.write_session_files!(session_dir, context, cue, cursor, idxs.size, filter)
    end


    # Sync disk buffers into the cue that owns them (by id), not the nav cursor cue.
    def sync_from_buffers!(session_dir, context, req, meta_before)
      # Skip when Lua reports buffers unchanged (pure navigation).
      sync_flag = req["sync_buffers"]
      return false if sync_flag == false || sync_flag.to_s == "false"

      bid = req["buffer_cue_id"].to_s.strip
      bid = meta_before["cue_id"].to_s if bid.empty?
      return false if bid.empty?

      fi = context["cues"].index { |c| c["id"].to_s == bid }
      return false if fi.nil?

      apply_buffer_files!(session_dir, context["cues"][fi])
      true
    end

    def apply_buffer_files!(session_dir, cue)
      en = File.join(session_dir, "cue.en.txt")
      pl = File.join(session_dir, "cue.pl.txt")
      if File.file?(en)
        en_text = File.read(en).to_s.gsub(/\r\n?/, "\n").gsub(/\s+/, " ").strip
        # Refuse vocab/JSON dumps accidentally pasted into the EN editor.
        unless en_text.include?("{") && en_text.match?(/"term"\s*:/)
          cue["text_en"] = en_text
        end
      end
      if File.file?(pl)
        pl_text = File.read(pl).to_s.gsub(/\r\n?/, "\n").gsub(/\s+/, " ").strip
        unless pl_text.include?("{") && pl_text.match?(/"term"\s*:/)
          cue["text_pl"] = pl_text
        end
      end
      cue["lektor_line"] = nil
      true
    end

    def load_state(session_dir, req)
      path = File.join(session_dir, STATE_NAME)
      state = if File.file?(path)
                JSON.parse(File.read(path))
              else
                {
                  "cursor" => 0,
                  "filter" => "all",
                  "vocab_path" => nil
                }
              end
      state["filter"] = "all" if state["filter"].to_s.empty?
      state["filter"] = Mentor.normalize_filter(state["filter"]).to_s
      # Explicit request wins (toggle_filter / CLI); otherwise keep session state.
      if req.key?("filter") && !req["filter"].to_s.empty?
        state["filter"] = Mentor.normalize_filter(req["filter"]).to_s
      end
      state["vocab_path"] = req["vocab_path"] if req.key?("vocab_path")
      state["cursor"] = req["cursor"] if req.key?("cursor")
      state
    end

    def save_state!(session_dir, state)
      File.write(File.join(session_dir, STATE_NAME), JSON.pretty_generate(state) + "\n")
    end

    def read_meta(session_dir)
      path = File.join(session_dir, "meta.json")
      return {} unless File.file?(path)

      JSON.parse(File.read(path))
    rescue JSON::ParserError
      {}
    end

    def ok(session_dir, context, idxs, cursor, filter, message:, extra: {})
      {
        "ok" => true,
        "message" => message,
        "meta" => read_meta(session_dir),
        "cursor" => cursor,
        "total" => idxs.size,
        "filter" => filter.to_s
      }.merge(extra)
    end

    def err(msg)
      { "ok" => false, "error" => msg }
    end
  end
end
