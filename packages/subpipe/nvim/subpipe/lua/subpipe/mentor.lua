-- Long-lived subpipe mentor session (façade)
local ui = require("subpipe.ui")
local panel = require("subpipe.panel")
local list = require("subpipe.list")
local action = require("subpipe.mentor.action")
local browse = require("subpipe.mentor.browse")
local M = {}

local state = {
  out = nil,
  session = nil,
  bin = "subpipe",
  busy = false,
  pending_goto_id = nil,
  en_buf = nil,
  pl_buf = nil,
  en_win = nil,
  pl_win = nil,
  list_win = nil,
  mode = "browse", -- browse | edit_en | edit_pl
  loaded_cue_id = nil,
  loaded_en = "",
  loaded_pl = "",
}

local function json_decode(raw)
  if vim.json and vim.json.decode then
    return vim.json.decode(raw)
  end
  return vim.fn.json_decode(raw)
end

local function json_encode(tbl)
  if vim.json and vim.json.encode then
    return vim.json.encode(tbl)
  end
  return vim.fn.json_encode(tbl)
end

local function session_path(name)
  return state.session .. "/" .. name
end

local function read_file(path)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local data = f:read("*a")
  f:close()
  return data
end

local function normalize_line(s)
  return (vim.trim(s or ""):gsub("%s+", " "))
end

local function buffer_line(buf)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return ""
  end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  return normalize_line(table.concat(lines, " "))
end

local function write_buffers_to_disk()
  for _, pair in ipairs({
    { state.en_buf, "cue.en.txt" },
    { state.pl_buf, "cue.pl.txt" },
  }) do
    local buf, name = pair[1], pair[2]
    if buf and vim.api.nvim_buf_is_valid(buf) then
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      if #lines == 0 then
        lines = { "" }
      end
      local f = io.open(session_path(name), "w")
      if f then
        f:write(table.concat(lines, "\n"))
        f:write("\n")
        f:close()
      end
      vim.bo[buf].modified = false
    end
  end
end

local function remember_loaded(meta, en_text, pl_text)
  state.loaded_cue_id = meta and meta.cue_id and tostring(meta.cue_id) or state.loaded_cue_id
  state.loaded_en = normalize_line(en_text)
  state.loaded_pl = normalize_line(pl_text)
end

local function set_detail_readonly(ro)
  for _, buf in ipairs({ state.en_buf, state.pl_buf }) do
    if buf and vim.api.nvim_buf_is_valid(buf) then
      vim.bo[buf].modifiable = not ro
      vim.bo[buf].readonly = ro
    end
  end
end

local function unlock_one(which)
  local buf = which == "en" and state.en_buf or state.pl_buf
  if buf and vim.api.nvim_buf_is_valid(buf) then
    vim.bo[buf].readonly = false
    vim.bo[buf].modifiable = true
  end
end

local function refresh_list(meta)
  local raw = read_file(session_path("cues.list.json"))
  local payload = { filter = meta and meta.filter or "?", cues = {} }
  if raw then
    local ok, decoded = pcall(json_decode, raw)
    if ok and type(decoded) == "table" then
      payload = decoded
    end
  end
  list.render(payload, meta and meta.cue_id)
end

local function clear_term_matches(win)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end
  for _, m in ipairs(vim.fn.getmatches(win)) do
    if m.group == "SubpipeTerm" then
      pcall(vim.fn.matchdelete, m.id, win)
    end
  end
end

local function apply_highlights()
  local text = read_file(session_path("highlights.txt")) or ""
  M.ns = M.ns or vim.api.nvim_create_namespace("SubpipeTerm")
  vim.cmd("highlight default SubpipeTerm ctermfg=Yellow guifg=#caca00")
  for _, win in ipairs({ state.en_win, state.pl_win }) do
    clear_term_matches(win)
  end
  for _, buf in ipairs({ state.en_buf, state.pl_buf }) do
    if buf and vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
    end
  end
  for w in text:gmatch("[^\r\n]+") do
    if w ~= "" then
      local pat = "\\<" .. vim.fn.escape(w, "\\") .. "\\>"
      for _, pair in ipairs({
        { state.en_win, state.en_buf },
        { state.pl_win, state.pl_buf },
      }) do
        local win, buf = pair[1], pair[2]
        if win and buf and vim.api.nvim_win_is_valid(win) and vim.api.nvim_buf_is_valid(buf) then
          pcall(vim.fn.matchadd, "SubpipeTerm", pat, 10, -1, { window = win })
        end
      end
    end
  end
end

local function apply_signs_and_status(meta)
  meta = meta or {}
  local status = string.format(
    "%s  %s/%s  [%s]  %s",
    meta.cue_id or "?",
    tostring(meta.index or "?"),
    tostring(meta.total or "?"),
    tostring(meta.filter or "?"),
    tostring(meta.status or "")
  )
  if meta.speakers then
    status = status .. "  spk=" .. vim.inspect(meta.speakers):gsub("%s+", " ")
  end
  vim.g.subpipe_status = status
  vim.cmd("set statusline=%f\\ %=%{get(g:,'subpipe_status','')}")

  local function place(buf)
    if not buf or not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    vim.fn.sign_unplace("Subpipe", { buffer = buf })
    local en_ok = meta.en_accepted_at and meta.en_accepted_at ~= vim.NIL and meta.en_accepted_at ~= ""
    local pl_ok = meta.pl_accepted_at and meta.pl_accepted_at ~= vim.NIL and meta.pl_accepted_at ~= ""
    if en_ok or pl_ok then
      vim.fn.sign_define("SubpipeOk", { text = "✓", texthl = "DiffAdd" })
      vim.fn.sign_place(1, "Subpipe", "SubpipeOk", buf, { lnum = 1 })
    end
  end
  place(state.en_buf)
  place(state.pl_buf)
end

local function reload_buffers(meta)
  if state.en_win and vim.api.nvim_win_is_valid(state.en_win) and state.en_buf then
    pcall(vim.api.nvim_win_set_buf, state.en_win, state.en_buf)
  end
  if state.pl_win and vim.api.nvim_win_is_valid(state.pl_win) and state.pl_buf then
    pcall(vim.api.nvim_win_set_buf, state.pl_win, state.pl_buf)
  end

  local loaded_en, loaded_pl = "", ""
  for _, pair in ipairs({
    { state.en_buf, session_path("cue.en.txt"), "en" },
    { state.pl_buf, session_path("cue.pl.txt"), "pl" },
  }) do
    local buf, path, which = pair[1], pair[2], pair[3]
    if buf and vim.api.nvim_buf_is_valid(buf) then
      local lines = {}
      local f = io.open(path, "r")
      if f then
        for line in f:lines() do
          table.insert(lines, line)
        end
        f:close()
      end
      if #lines == 0 then
        lines = { "" }
      elseif #lines > 1 then
        local parts = {}
        for _, l in ipairs(lines) do
          local t = vim.trim(l)
          if t ~= "" then
            table.insert(parts, t)
          end
        end
        lines = { #parts > 0 and table.concat(parts, " ") or "" }
      end
      vim.bo[buf].readonly = false
      vim.bo[buf].modifiable = true
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      vim.bo[buf].modified = false
      if which == "en" then
        loaded_en = normalize_line(lines[1] or "")
      else
        loaded_pl = normalize_line(lines[1] or "")
      end
    end
  end
  remember_loaded(meta, loaded_en, loaded_pl)
  apply_highlights()
  apply_signs_and_status(meta)
  refresh_list(meta)
  if state.mode == "browse" then
    set_detail_readonly(true)
  elseif state.mode == "edit_en" then
    set_detail_readonly(true)
    unlock_one("en")
  elseif state.mode == "edit_pl" then
    set_detail_readonly(true)
    unlock_one("pl")
  end
end

local function split_avoid(s)
  local out = {}
  for part in string.gmatch(s or "", "[^,]+") do
    local t = vim.trim(part)
    if t ~= "" then
      table.insert(out, t)
    end
  end
  return out
end

local function ask_notes_confirm(r)
  local notes0 = r.notes or ""
  local avoid0 = table.concat(r.avoid_pl or {}, ", ")
  local src = r.source or "heuristic"
  local kind = r.kind or "?"
  local tpl = r.template_id or "?"
  local write_vocab = r.write_vocab
  if write_vocab == nil then
    write_vocab = true
  end

  local body = {
    string.format("%s / %s  (%s)", kind, tpl, src),
    string.format("%s → %s", r.term_en ~= "" and r.term_en or "(no EN)", r.term_pl or "?"),
  }
  if r.draft_span and r.draft_span ~= "" then
    table.insert(body, "avoid: " .. r.draft_span:sub(1, 80))
  end
  if r.gold_span and r.gold_span ~= "" and r.gold_span ~= r.term_pl then
    table.insert(body, "prefer: " .. r.gold_span:sub(1, 80))
  end

  local choices
  if write_vocab then
    choices = {
      { key = "y", label = "accept → vocab + retranslate", id = "yes" },
      { key = "E", label = "edit notes / avoid / EN / PL", id = "edit" },
      { key = "S", label = "style only (no vocab)", id = "style" },
      { key = "N", label = "skip", id = "no" },
    }
  else
    choices = {
      { key = "y", label = "style only — done (corrections logged)", id = "style" },
      { key = "G", label = "promote to vocab anyway", id = "promote" },
      { key = "E", label = "edit fields", id = "edit" },
      { key = "N", label = "skip", id = "no" },
    }
  end

  panel.ask({
    title = "Confirm teach package",
    body_lines = body,
    fields = {
      { id = "term_en", label = "EN", value = r.term_en or "" },
      { id = "term_pl", label = "PL", value = r.term_pl or "" },
      { id = "notes", label = "notes", value = notes0 },
      { id = "avoid_pl", label = "avoid_pl", value = avoid0 },
    },
    choices = choices,
    on_answer = function(id, fields)
      if id == "no" then
        M.action("propagate_skip")
        return
      end
      if id == "style" then
        panel.set_status("Style-only — corrections.jsonl already has this accept")
        M.action("propagate_skip")
        return
      end
      fields = fields or {}
      local en = vim.trim(fields.term_en or r.term_en or "")
      local pl = vim.trim(fields.term_pl or r.term_pl or "")
      if id == "promote" or id == "yes" then
        if en == "" or pl == "" then
          panel.set_status("EN and PL required to write vocab")
          M.action("propagate_skip")
          return
        end
        M.action("propagate_confirm", {
          term_en = en,
          term_pl = pl,
          notes = fields.notes or notes0,
          avoid_pl = split_avoid(fields.avoid_pl or avoid0),
        })
      end
    end,
  })
end

local function ask_mapping_then_reflect(en0, pl0, force_kind)
  panel.ask({
    title = "Vocab mapping",
    body_lines = { "EN key + PL form for glossary / prefer_over" },
    fields = {
      { id = "term_en", label = "EN", value = en0 or "" },
      { id = "term_pl", label = "PL", value = pl0 or "" },
    },
    choices = {
      { key = "y", label = "reflect notes", id = "yes" },
      { key = "E", label = "edit EN / PL", id = "edit" },
      { key = "N", label = "skip", id = "no" },
    },
    on_answer = function(id, fields)
      if id == "no" then
        M.action("propagate_skip")
        return
      end
      fields = fields or {}
      local en = vim.trim(fields.term_en or en0 or "")
      local pl = vim.trim(fields.term_pl or pl0 or "")
      if en == "" or pl == "" then
        panel.set_status("EN and PL required")
        M.action("propagate_skip")
        return
      end
      panel.set_status("Reflecting edit…")
      local extra = { term_en = en, term_pl = pl }
      if force_kind then
        extra.force_kind = force_kind
      end
      M.action("reflect", extra)
    end,
  })
end

local function handle_propagate(res)
  local p = res.propagate or {}
  local en0 = p.en_pre or ""
  local pl0 = p.pl_pre or ""
  local notes0 = p.notes_pre or ""
  local kind = p.kind_pre or "other"
  local tpl = p.template_id or "none"
  local write_vocab = p.write_vocab
  if write_vocab == nil then
    write_vocab = false
  end
  local draft_span = p.draft_span or ""
  local gold_span = p.gold_span or ""

  local body = {
    string.format("kind=%s  template=%s  vocab=%s", kind, tpl, write_vocab and "yes" or "no"),
  }
  if en0 ~= "" or pl0 ~= "" then
    table.insert(body, string.format("%s  →  %s", en0 ~= "" and en0 or "(no EN)", pl0 ~= "" and pl0 or "?"))
  end
  if gold_span ~= "" then
    table.insert(body, "prefer: " .. gold_span:sub(1, 90))
  end
  if draft_span ~= "" then
    table.insert(body, "avoid:  " .. draft_span:sub(1, 90))
  end
  if notes0 ~= "" then
    table.insert(body, "note: " .. notes0:sub(1, 100))
  end

  local default_label = write_vocab and "accept → reflect / vocab" or "style only — done"
  panel.ask({
    title = "Teach from this edit?",
    body_lines = body,
    fields = {
      { id = "term_en", label = "EN", value = en0 },
      { id = "term_pl", label = "PL", value = pl0 ~= "" and pl0 or gold_span },
      { id = "notes", label = "notes", value = notes0 },
      { id = "avoid_pl", label = "avoid_pl", value = table.concat(p.avoid_pl_pre or {}, ", ") },
    },
    choices = {
      { key = "y", label = default_label, id = "yes" },
      { key = "G", label = "promote glossary / prefer_over", id = "glossary" },
      { key = "S", label = "style only (no vocab)", id = "style" },
      { key = "E", label = "edit fields", id = "edit" },
      { key = "N", label = "skip", id = "no" },
    },
    on_answer = function(id, fields)
      if id == "no" then
        M.action("propagate_skip")
        return
      end
      if id == "style" then
        panel.set_status("Style-only — corrections.jsonl already logged")
        M.action("propagate_skip")
        return
      end
      fields = fields or {}
      local en = vim.trim(fields.term_en or en0 or "")
      local pl = vim.trim(fields.term_pl or pl0 or gold_span or "")
      if id == "yes" and not write_vocab then
        panel.set_status("Style-only — corrections.jsonl already logged")
        M.action("propagate_skip")
        return
      end
      if id == "glossary" or (id == "yes" and write_vocab) then
        if en == "" or pl == "" then
          ask_mapping_then_reflect(en, pl, id == "glossary" and "prefer_over" or nil)
          panel.flush_queue_if_idle()
          return
        end
        panel.set_status("Reflecting edit…")
        M.action("reflect", {
          term_en = en,
          term_pl = pl,
          force_kind = id == "glossary" and "prefer_over" or nil,
        })
        return
      end
    end,
  })
end

local function on_response(raw)
  state.busy = false
  local last_op = state.last_op
  state.last_op = nil
  if last_op == "undo" then
    panel.dismiss_all()
  end
  panel.clear_status()
  local ok, res = pcall(json_decode, raw)
  if not ok or type(res) ~= "table" then
    panel.set_status("bad mentor-action response")
    panel.flush_queue_if_idle()
    return
  end
  if not res.ok then
    panel.set_status(res.error or "action failed")
    panel.flush_queue_if_idle()
    return
  end
  if res.quit or res.done then
    list.close()
    panel.detach()
    ui.notify(res.message or "done")
    vim.cmd("qa!")
    return
  end
  if res.need_propagate then
    reload_buffers(res.meta)
    handle_propagate(res)
    panel.flush_queue_if_idle()
    return
  end
  if res.need_notes_confirm then
    reload_buffers(res.meta)
    ask_notes_confirm(res.reflect or {})
    panel.flush_queue_if_idle()
    return
  end
  if res.message then
    panel.set_status(res.message)
    vim.defer_fn(function()
      if not state.busy and not panel.has_question() then
        panel.clear_status()
        panel.flush_queue_if_idle()
      end
    end, 1800)
  end
  reload_buffers(res.meta)
  panel.flush_queue_if_idle()
end

function M.action(op, extra)
  action.run(op, extra)
end

function M.start()
  state.out = vim.env.SUBPIPE_MENTOR_OUT
  state.session = vim.env.SUBPIPE_MENTOR_SESSION
  state.bin = vim.env.SUBPIPE_BIN or "subpipe"
  state.mode = "browse"
  state.pending_goto_id = nil
  if not state.out or not state.session then
    ui.notify("SUBPIPE_MENTOR_OUT/SESSION not set", vim.log.levels.ERROR)
    return
  end

  action.bind({
    state = state,
    json_encode = json_encode,
    write_buffers = write_buffers_to_disk,
    buffer_line = buffer_line,
    on_response = on_response,
    on_idle = function()
      if panel.has_question() then
        return
      end
      action.flush_pending_goto()
    end,
  })
  browse.bind({
    state = state,
    action = action,
    session_path = session_path,
    write_buffers = write_buffers_to_disk,
    set_detail_readonly = set_detail_readonly,
    unlock_one = unlock_one,
  })

  vim.opt.signcolumn = "yes"
  browse.setup_layout()
  browse.setup_keymaps()

  M.action("load")
  panel.set_status("Ready — j/k list · e/t edit · a accept · p preview · f filter · h help")
  vim.defer_fn(function()
    if not state.busy and not panel.has_question() then
      panel.clear_status()
    end
  end, 2800)
end

return M
