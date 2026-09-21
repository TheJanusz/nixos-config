-- Cue list buffer: browse with j/k, color by review status
local M = {}

local S = {
  buf = nil,
  win = nil,
  rows = {}, -- 1-based line → { id, status, ... }
  ns = nil,
  on_select = nil, -- function(cue_id)
}

local function ensure_highlights()
  vim.cmd([[
    highlight default SubpipePending ctermfg=8 guifg=#808080
    highlight default SubpipeClean ctermfg=2 guifg=#6a9955
    highlight default SubpipeEdited ctermfg=3 guifg=#caca00
    highlight default SubpipeListId ctermfg=6 guifg=#569cd6
  ]])
end

local function valid_buf()
  return S.buf and vim.api.nvim_buf_is_valid(S.buf)
end

local function valid_win()
  return S.win and vim.api.nvim_win_is_valid(S.win)
end

function M.buf()
  return S.buf
end

function M.win()
  return S.win
end

function M.create(on_select)
  S.on_select = on_select
  ensure_highlights()
  S.ns = S.ns or vim.api.nvim_create_namespace("SubpipeList")
  S.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[S.buf].buftype = "nofile"
  vim.bo[S.buf].bufhidden = "hide"
  vim.bo[S.buf].swapfile = false
  vim.bo[S.buf].modifiable = false
  vim.bo[S.buf].filetype = "subpipe-list"
  pcall(vim.api.nvim_buf_set_name, S.buf, "subpipe://cues")
  return S.buf
end

function M.attach_win(win)
  S.win = win
  if valid_win() and valid_buf() then
    vim.api.nvim_win_set_buf(win, S.buf)
    vim.wo[win].cursorline = true
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].signcolumn = "no"
    vim.wo[win].wrap = false
  end
end

local function status_hl(status)
  if status == "clean" then
    return "SubpipeClean"
  elseif status == "edited" then
    return "SubpipeEdited"
  end
  return "SubpipePending"
end

local function mark(en_ok, pl_ok)
  local a = en_ok and "E" or "·"
  local b = pl_ok and "P" or "·"
  return a .. b
end

function M.render(payload, current_id)
  if not valid_buf() then
    return
  end
  ensure_highlights()
  payload = payload or {}
  local cues = payload.cues or {}
  S.rows = {}
  local lines = {}
  local filter = payload.filter or "?"
  table.insert(lines, string.format("filter=%s  (%d)  pending|edited|clean|flagged", filter, #cues))
  for i, row in ipairs(cues) do
    -- Known columns only; extra keys (flagged, speaker, visual, …) stay on the row.
    local id = tostring(row.id or "?")
    local en = tostring(row.en or "")
    local pl = tostring(row.pl or "")
    -- Fixed prefix "EP id  …" so id highlight is column-stable
    local line = string.format("%s %s  %s  |  %s", mark(row.en_ok, row.pl_ok), id, en, pl)
    table.insert(lines, line)
    S.rows[i + 1] = row -- line 1 is header
  end
  if #cues == 0 then
    table.insert(lines, "(no cues)")
  end

  vim.bo[S.buf].modifiable = true
  vim.api.nvim_buf_set_lines(S.buf, 0, -1, false, lines)
  vim.bo[S.buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(S.buf, S.ns, 0, -1)

  for lnum, row in pairs(S.rows) do
    local status = row.status or "pending"
    local hl = status_hl(status)
    vim.api.nvim_buf_add_highlight(S.buf, S.ns, hl, lnum - 1, 0, -1)
    -- id starts after "EP " (2 mark chars + space) → 0-based col 3
    local id = tostring(row.id or "")
    local id_col = 3
    vim.api.nvim_buf_add_highlight(S.buf, S.ns, "SubpipeListId", lnum - 1, id_col, id_col + #id)
  end
  vim.api.nvim_buf_add_highlight(S.buf, S.ns, "Comment", 0, 0, -1)

  M.focus_id(current_id)
end

function M.focus_id(cue_id)
  if not cue_id or not valid_win() then
    return
  end
  cue_id = tostring(cue_id)
  for lnum, row in pairs(S.rows) do
    if tostring(row.id) == cue_id then
      pcall(vim.api.nvim_win_set_cursor, S.win, { lnum, 0 })
      return
    end
  end
end

function M.cue_id_at_cursor()
  if not valid_win() then
    return nil
  end
  local lnum = vim.api.nvim_win_get_cursor(S.win)[1]
  local row = S.rows[lnum]
  return row and tostring(row.id) or nil
end

function M.move(delta)
  if not valid_win() or not valid_buf() then
    return
  end
  local lnum = vim.api.nvim_win_get_cursor(S.win)[1]
  local max = vim.api.nvim_buf_line_count(S.buf)
  local next_ln = lnum + delta
  if next_ln < 2 then
    next_ln = 2
  end
  if next_ln > max then
    next_ln = max
  end
  while next_ln >= 2 and next_ln <= max and not S.rows[next_ln] do
    next_ln = next_ln + (delta > 0 and 1 or -1)
  end
  if not S.rows[next_ln] then
    return
  end
  vim.api.nvim_win_set_cursor(S.win, { next_ln, 0 })
  local id = tostring(S.rows[next_ln].id)
  if S.on_select then
    S.on_select(id)
  end
end

function M.jump_edge(first)
  if not valid_win() then
    return
  end
  local keys = {}
  for lnum, _ in pairs(S.rows) do
    table.insert(keys, lnum)
  end
  table.sort(keys)
  if #keys == 0 then
    return
  end
  local target = first and keys[1] or keys[#keys]
  vim.api.nvim_win_set_cursor(S.win, { target, 0 })
  local id = tostring(S.rows[target].id)
  if S.on_select then
    S.on_select(id)
  end
end

function M.focus()
  if valid_win() then
    pcall(vim.api.nvim_set_current_win, S.win)
  end
end

function M.close()
  S.rows = {}
  S.win = nil
end

return M
