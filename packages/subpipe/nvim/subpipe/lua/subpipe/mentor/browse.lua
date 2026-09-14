-- Browse mode: layout, list navigation, enter/leave edit, bare keymaps
local ui = require("subpipe.ui")
local panel = require("subpipe.panel")
local list = require("subpipe.list")

local M = {}

local S = {
  state = nil,
  action = nil, -- mentor.action module
  session_path = nil,
  write_buffers = nil,
  set_detail_readonly = nil,
  unlock_one = nil, -- function(which) unlock only en or pl
}

function M.bind(opts)
  S.state = opts.state
  S.action = opts.action
  S.session_path = opts.session_path
  S.write_buffers = opts.write_buffers
  S.set_detail_readonly = opts.set_detail_readonly
  S.unlock_one = opts.unlock_one
end

local function map_list(lhs, fn, desc)
  local buf = list.buf()
  if not buf then
    return
  end
  vim.keymap.set("n", lhs, fn, { buffer = buf, silent = true, nowait = true, desc = desc or "subpipe" })
end

local function enter_edit(which)
  local state = S.state
  if state.busy then
    panel.set_status("Busy — wait…")
    return
  end
  local win = which == "en" and state.en_win or state.pl_win
  local buf = which == "en" and state.en_buf or state.pl_buf
  if not win or not buf or not vim.api.nvim_win_is_valid(win) then
    return
  end
  state.mode = which == "en" and "edit_en" or "edit_pl"
  -- Keep the other side locked
  S.set_detail_readonly(true)
  S.unlock_one(which)
  vim.api.nvim_set_current_win(win)
  vim.cmd("startinsert!")
end

local function leave_edit()
  local state = S.state
  if state.mode == "browse" then
    return
  end
  vim.cmd("stopinsert")
  state.mode = "browse"
  S.write_buffers()
  local function norm(buf)
    if not buf or not vim.api.nvim_buf_is_valid(buf) then
      return ""
    end
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    return (vim.trim(table.concat(lines, " ")):gsub("%s+", " "))
  end
  local dirty = norm(state.en_buf) ~= state.loaded_en or norm(state.pl_buf) ~= state.loaded_pl
  S.set_detail_readonly(true)
  list.focus()
  if dirty then
    S.action.run("save")
  end
end

function M.setup_keymaps()
  local action = S.action
  map_list("j", function()
    list.move(1)
  end, "subpipe next cue")
  map_list("k", function()
    list.move(-1)
  end, "subpipe prev cue")
  map_list("gg", function()
    list.jump_edge(true)
  end, "subpipe first cue")

  map_list("e", function()
    enter_edit("en")
  end, "subpipe edit EN")
  map_list("t", function()
    enter_edit("pl")
  end, "subpipe edit PL")

  map_list("a", function()
    action.run("accept_both")
  end, "subpipe accept both")
  map_list("E", function()
    if panel.has_question() then
      panel.answer("E")
    else
      action.run("accept_en")
    end
  end, "subpipe accept EN / panel edit")
  map_list("T", function()
    action.run("accept_pl")
  end, "subpipe accept PL")
  map_list("P", function()
    action.run("accept_pl_propagate")
  end, "subpipe accept PL propagate")
  map_list("s", function()
    action.run("save")
  end, "subpipe save")
  map_list("p", function()
    action.run("generate")
  end, "subpipe generate preview")
  map_list("A", function()
    action.run("accept_voice")
  end, "subpipe accept voice")
  map_list("f", function()
    action.run("toggle_filter")
  end, "subpipe filter")
  map_list("q", function()
    action.run("quit")
  end, "subpipe quit")
  map_list("u", function()
    panel.dismiss_all()
    action.run("undo")
  end, "subpipe undo")
  map_list("h", ui.toggle_help, "subpipe help")
  map_list("?", ui.toggle_help, "subpipe help")

  local function answer(key)
    return function()
      panel.answer(key)
    end
  end
  map_list("y", answer("y"), "subpipe panel y")
  map_list("N", answer("N"), "subpipe panel N")
  map_list("S", answer("S"), "subpipe panel S")
  map_list("G", function()
    if panel.has_question() then
      panel.answer("G")
    else
      list.jump_edge(false)
    end
  end, "subpipe last / panel G")
  for i = 1, 9 do
    map_list(tostring(i), answer(tostring(i)), "subpipe panel " .. i)
  end

  local state = S.state
  for _, buf in ipairs({ state.en_buf, state.pl_buf }) do
    if buf and vim.api.nvim_buf_is_valid(buf) then
      vim.keymap.set("n", "<Esc>", function()
        leave_edit()
      end, { buffer = buf, silent = true, desc = "subpipe leave edit" })
      vim.keymap.set("i", "<Esc>", function()
        vim.cmd("stopinsert")
        leave_edit()
      end, { buffer = buf, silent = true, desc = "subpipe leave edit" })
    end
  end
end

function M.setup_layout()
  local state = S.state
  local en_path = S.session_path("cue.en.txt")
  local pl_path = S.session_path("cue.pl.txt")

  vim.cmd("edit " .. vim.fn.fnameescape(en_path))
  state.en_buf = vim.api.nvim_get_current_buf()
  state.en_win = vim.api.nvim_get_current_win()
  vim.bo[state.en_buf].bufhidden = "hide"

  list.create(function(cue_id)
    S.action.request_goto(cue_id)
  end)

  vim.cmd("leftabove vertical split")
  state.list_win = vim.api.nvim_get_current_win()
  list.attach_win(state.list_win)
  pcall(vim.api.nvim_win_set_width, state.list_win, math.max(36, math.floor(vim.o.columns * 0.34)))

  vim.api.nvim_set_current_win(state.en_win)
  vim.cmd("belowright split " .. vim.fn.fnameescape(pl_path))
  state.pl_buf = vim.api.nvim_get_current_buf()
  state.pl_win = vim.api.nvim_get_current_win()
  vim.bo[state.pl_buf].bufhidden = "hide"

  panel.attach(state.pl_win, { on_return_focus = list.focus })
  S.set_detail_readonly(true)
  list.focus()
end

return M
