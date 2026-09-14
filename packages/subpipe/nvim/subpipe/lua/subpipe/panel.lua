-- PL-side mentor panel: status + queued questions (unfocused by default)
local M = {}

local S = {
  win = nil, -- parent PL edit window
  float_win = nil,
  float_buf = nil,
  mode = "hidden", -- hidden | status | question | edit
  status_msg = "",
  queue = {},
  current = nil, -- { title, body_lines, choices, fields, on_answer }
  edit_fields = nil, -- { {label, value}, ... }
  augroup = nil,
  on_return_focus = nil, -- function() — prefer list browse after field edit
}

local function return_focus()
  if S.on_return_focus then
    pcall(S.on_return_focus)
    return
  end
  if valid_parent() then
    pcall(vim.api.nvim_set_current_win, S.win)
  end
end

local function valid_parent()
  return S.win and vim.api.nvim_win_is_valid(S.win)
end

local function close_float()
  if S.float_win and vim.api.nvim_win_is_valid(S.float_win) then
    pcall(vim.api.nvim_win_close, S.float_win, true)
  end
  S.float_win = nil
  S.float_buf = nil
end

local function geometry()
  if not valid_parent() then
    return nil
  end
  local width = vim.api.nvim_win_get_width(S.win)
  local height = vim.api.nvim_win_get_height(S.win)
  local fw = math.max(24, width - 2)
  local fh = math.min(12, math.max(4, height - 3))
  local row = math.max(1, height - fh - 1)
  return {
    relative = "win",
    win = S.win,
    width = fw,
    height = fh,
    row = row,
    col = 1,
    style = "minimal",
    border = "rounded",
    title = " subpipe ",
    title_pos = "center",
    focusable = S.mode == "edit",
    zindex = 40,
  }
end

local function set_lines(lines)
  if not S.float_buf or not vim.api.nvim_buf_is_valid(S.float_buf) then
    return
  end
  vim.bo[S.float_buf].modifiable = true
  vim.api.nvim_buf_set_lines(S.float_buf, 0, -1, false, lines)
  if S.mode ~= "edit" then
    vim.bo[S.float_buf].modifiable = false
  end
end

local function render_question(q)
  local lines = {}
  if q.title and q.title ~= "" then
    table.insert(lines, q.title)
    table.insert(lines, "")
  end
  for _, ln in ipairs(q.body_lines or {}) do
    table.insert(lines, ln)
  end
  if q.fields then
    table.insert(lines, "")
    for _, f in ipairs(q.fields) do
      table.insert(lines, string.format("%s: %s", f.label, f.value or ""))
    end
  end
  table.insert(lines, "")
  for i, c in ipairs(q.choices or {}) do
    local key = c.key or tostring(i)
    table.insert(lines, string.format("  %s  %s", key, c.label or c.id or "?"))
  end
  if #(S.queue) > 0 then
    table.insert(lines, "")
    table.insert(lines, string.format("(+%d queued)", #S.queue))
  end
  return lines
end

local function ensure_float()
  if not valid_parent() then
    return false
  end
  local cfg = geometry()
  if not cfg then
    return false
  end
  if S.float_win and vim.api.nvim_win_is_valid(S.float_win) and S.float_buf and vim.api.nvim_buf_is_valid(S.float_buf) then
    pcall(vim.api.nvim_win_set_config, S.float_win, cfg)
    return true
  end
  S.float_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[S.float_buf].bufhidden = "wipe"
  vim.bo[S.float_buf].filetype = "subpipe-panel"
  S.float_win = vim.api.nvim_open_win(S.float_buf, false, cfg)
  return true
end

local function show_current()
  if not S.current then
    if S.mode == "status" and S.status_msg ~= "" then
      if ensure_float() then
        set_lines({ S.status_msg })
      end
      return
    end
    S.mode = "hidden"
    close_float()
    return
  end
  S.mode = "question"
  if not ensure_float() then
    return
  end
  set_lines(render_question(S.current))
end

local function pop_next()
  S.current = table.remove(S.queue, 1)
  show_current()
end

function M.attach(pl_win, opts)
  opts = opts or {}
  S.win = pl_win
  S.on_return_focus = opts.on_return_focus
  if S.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, S.augroup)
  end
  S.augroup = vim.api.nvim_create_augroup("SubpipePanel", { clear = true })
  vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
    group = S.augroup,
    callback = function()
      if S.mode ~= "hidden" then
        ensure_float()
        if S.mode == "status" then
          set_lines({ S.status_msg })
        elseif S.current then
          set_lines(render_question(S.current))
        end
      end
    end,
  })
end

function M.detach()
  close_float()
  if S.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, S.augroup)
    S.augroup = nil
  end
  S.win = nil
  S.queue = {}
  S.current = nil
  S.mode = "hidden"
  S.status_msg = ""
end

function M.set_status(msg)
  S.status_msg = msg or ""
  if S.current then
    -- question takes priority; status waits underneath
    return
  end
  if S.status_msg == "" then
    S.mode = "hidden"
    close_float()
    return
  end
  S.mode = "status"
  if ensure_float() then
    set_lines({ S.status_msg })
  end
end

function M.clear_status()
  S.status_msg = ""
  if not S.current then
    S.mode = "hidden"
    close_float()
  end
end

--- Drop open question + queue without answering (e.g. undo while teach panel is up).
function M.dismiss_all()
  local had = S.current ~= nil or #S.queue > 0
  S.queue = {}
  S.current = nil
  S.edit_fields = nil
  S.status_msg = ""
  S.mode = "hidden"
  close_float()
  return had
end

--- question = { title, body_lines, choices = {{key, label, id}}, fields?, on_answer(id, fields?) }
function M.ask(question)
  if not question or not question.on_answer then
    return
  end
  if S.current then
    table.insert(S.queue, question)
    show_current() -- refresh queued count
    return
  end
  S.current = question
  S.status_msg = ""
  show_current()
end

function M.has_question()
  return S.current ~= nil
end

function M.queue_len()
  return #S.queue + (S.current and 1 or 0)
end

local function finish_answer(id, fields)
  local q = S.current
  S.current = nil
  S.mode = "hidden"
  close_float()
  if q and q.on_answer then
    q.on_answer(id, fields)
  end
  -- Caller (mentor) must call flush_queue_if_idle when not starting a job
end

function M.answer(key)
  if S.mode == "edit" then
    return false
  end
  local q = S.current
  if not q then
    return false
  end
  key = tostring(key or "")
  local choice = nil
  for i, c in ipairs(q.choices or {}) do
    if tostring(c.key) == key or tostring(i) == key then
      choice = c
      break
    end
  end
  if not choice then
    return false
  end
  if choice.id == "edit" then
    M.begin_edit()
    return true
  end
  local fields = nil
  if q.fields then
    fields = {}
    for _, f in ipairs(q.fields) do
      fields[f.id or f.label] = f.value
    end
  end
  finish_answer(choice.id, fields)
  return true
end

function M.begin_edit()
  local q = S.current
  if not q or not q.fields or #q.fields == 0 then
    return
  end
  S.mode = "edit"
  S.edit_fields = vim.deepcopy(q.fields)
  if not ensure_float() then
    return
  end
  -- Focus float for editing
  pcall(vim.api.nvim_set_current_win, S.float_win)
  local lines = { "Edit fields — <CR> commit, <Esc> cancel", "" }
  for _, f in ipairs(S.edit_fields) do
    table.insert(lines, string.format("%s: %s", f.label, f.value or ""))
  end
  vim.bo[S.float_buf].modifiable = true
  vim.api.nvim_buf_set_lines(S.float_buf, 0, -1, false, lines)
  vim.api.nvim_win_set_cursor(S.float_win, { 3, 0 })

  local buf = S.float_buf
  vim.keymap.set("n", "<CR>", function()
    M.commit_edit()
  end, { buffer = buf, silent = true, nowait = true })
  vim.keymap.set("n", "<Esc>", function()
    M.cancel_edit()
  end, { buffer = buf, silent = true, nowait = true })
  vim.keymap.set("i", "<CR>", function()
    vim.cmd("stopinsert")
    M.commit_edit()
  end, { buffer = buf, silent = true, nowait = true })
end

function M.commit_edit()
  if S.mode ~= "edit" or not S.float_buf then
    return
  end
  local lines = vim.api.nvim_buf_get_lines(S.float_buf, 0, -1, false)
  local fields = S.edit_fields or {}
  local fi = 1
  for _, ln in ipairs(lines) do
    local label, val = ln:match("^([^:]+):%s*(.*)$")
    if label and fields[fi] and label == fields[fi].label then
      fields[fi].value = val or ""
      fi = fi + 1
    end
  end
  if S.current then
    S.current.fields = fields
  end
  S.mode = "question"
  return_focus()
  ensure_float()
  set_lines(render_question(S.current))
end

function M.cancel_edit()
  if S.mode ~= "edit" then
    return
  end
  S.mode = "question"
  return_focus()
  ensure_float()
  set_lines(render_question(S.current))
end

--- Called after a job finishes so queued questions can surface
function M.flush_queue_if_idle()
  if S.current then
    show_current()
    return
  end
  if #S.queue > 0 then
    pop_next()
  elseif S.status_msg ~= "" then
    M.set_status(S.status_msg)
  else
    close_float()
  end
end

return M
