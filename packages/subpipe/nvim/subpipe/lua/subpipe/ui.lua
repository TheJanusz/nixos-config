-- subpipe mentor UI helpers
local M = {}

local help_buf, help_win

local HELP_TEXT = [[
subpipe mentor — cue list + detail

Layout: left = cue list · right = EN / PL
Browse (list focused): bare keys, no leader
Edit: e = EN · t = PL · Esc = back to list

List colors:
  gray   pending (not fully accepted)
  green  clean (accepted unchanged)
  yellow edited (accepted with changes)

Keys (browse):
  j / k     next / prev cue
  gg / G    first / last (G = promote when teach ask)
  e / t     edit EN / PL
  a         accept EN+PL
  E / T     accept EN / PL (E = edit fields when teach ask)
  P         accept PL + propagate ask
  s         save
  p / A     synth preview / accept voice take
  u         undo cue
  f         filter: all → pending → edited → clean → flagged
  h / ?     this help
  q         quit

Teach panel (while question shown):
  y  yes / default
  N  skip
  S  style only
  G  promote glossary
  E  edit fields
  1..9  choice #

Yellow highlight in EN/PL: names / EN leftovers (visual only).
]]

function M.notify(msg, level)
  vim.notify(msg or "", level or vim.log.levels.INFO, { title = "subpipe" })
end

function M.toggle_help()
  if help_win and vim.api.nvim_win_is_valid(help_win) then
    vim.api.nvim_win_close(help_win, true)
    help_win = nil
    help_buf = nil
    return
  end
  help_buf = vim.api.nvim_create_buf(false, true)
  local lines = vim.split(HELP_TEXT, "\n", { plain = true })
  vim.api.nvim_buf_set_lines(help_buf, 0, -1, false, lines)
  vim.bo[help_buf].modifiable = false
  vim.bo[help_buf].bufhidden = "wipe"
  local width = 62
  local height = #lines + 2
  local row = 1
  local col = math.max(0, math.floor((vim.o.columns - width) / 2))
  help_win = vim.api.nvim_open_win(help_buf, false, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " mentor help ",
    title_pos = "center",
    focusable = false,
    zindex = 50,
  })
end

return M
