---@diagnostic disable: undefined-global
-- Kitty and other clients ask to be maximized on launch. In a tiling
-- layout that takes the whole workspace. Ignore the request.
hl.window_rule({
  name = "suppress-maximize",
  match = { class = ".*" },
  suppress_event = "maximize",
})

-- Each monitor keeps its own persistent range. DP-4 is 1-5, DP-3 is 6-10.
-- package.path is set in hyprland.nix before this file is loaded.
smw = require("split-monitor-workspaces")
smw.setup({
  workspace_count = 5,
  enable_persistent_workspaces = true,
  enable_wrapping = true,
  link_monitors = false,
  monitor_priority = { "DP-4", "DP-3" },
})

-- setup only remaps on config.reloaded. Map once now so the ranges exist
-- on the first start.
require("monitors").remap_all_monitors()

-- Portrait workspaces stack every window full-width. ctx:row splits the
-- monitor's height; ctx:column would put them side by side. A registered
-- layout is selected as "lua:<name>". Up and down still swap along that
-- stack. Left and right have no side neighbor, and this layout does not
-- fall through to the next monitor, so move_window sends those there.
hl.layout.register("column", {
  recalculate = function(ctx)
    local n = #ctx.targets
    if n == 0 then
      return
    end
    for i, target in ipairs(ctx.targets) do
      target:place(ctx:row(i, n))
    end
  end,
})

-- replaceOrAdd keeps one rule per workspace. split-monitor-workspaces
-- rewrites 1-5 on config.reloaded and when a monitor is added, and that
-- rewrite has no layout, so dwindle comes back. Put the column back after
-- those handlers, and keep the monitor and persistent fields on the same rule.
local function apply_column_rules()
  for id = 1, 5 do
    hl.workspace_rule({
      workspace = tostring(id),
      monitor = "DP-4",
      persistent = true,
      layout = "lua:column",
    })
  end
end

hl.on("config.reloaded", apply_column_rules)
hl.on("monitor.added", apply_column_rules)
apply_column_rules()

-- Dwindle's default (force_split = 0) opens a window on the cursor side of
-- the tile under the pointer. This layout only appends, so put a new window
-- back at that row: above the tile when the pointer is in its top half,
-- below it otherwise. Left and right of this monitor are left alone.
local function column_insert_index(cursor_y, top, height, n_old)
  if n_old < 1 or height <= 0 then
    return n_old
  end
  local f = (cursor_y - top) / height
  if f < 0 then
    return 0
  end
  if f >= 1 then
    return n_old
  end
  local idx = math.floor(f * n_old)
  if idx >= n_old then
    idx = n_old - 1
  end
  local local_f = f * n_old - idx
  if local_f < 0.5 then
    return idx
  end
  return idx + 1
end

local function place_new_column_window(window)
  if not window or window.floating or not window.mapped or not window.at or not window.size then
    return
  end
  local ws = window.workspace
  if not ws or ws.tiled_layout ~= "lua:column" then
    return
  end
  local cursor = hl.get_cursor_pos()
  if not cursor then
    return
  end
  local tiled = {}
  for _, w in ipairs(ws:get_windows()) do
    if w.mapped and not w.floating and w.at and w.size then
      table.insert(tiled, w)
    end
  end
  if #tiled < 2 then
    return
  end
  table.sort(tiled, function(a, b)
    return a.at.y < b.at.y
  end)
  local from_i = nil
  for i, w in ipairs(tiled) do
    if w.address == window.address then
      from_i = i - 1
      break
    end
  end
  if not from_i then
    return
  end
  local left = tiled[1].at.x
  local right = left + tiled[1].size.x
  if cursor.x < left or cursor.x >= right then
    return
  end
  local top = tiled[1].at.y
  local last = tiled[#tiled]
  local height = last.at.y + last.size.y - top
  local desired = column_insert_index(cursor.y, top, height, #tiled - 1)
  local steps = from_i - desired
  local direction = "up"
  if steps < 0 then
    direction = "down"
    steps = -steps
  end
  for _ = 1, steps do
    hl.dispatch(hl.dsp.window.move({ direction = direction, window = window }))
  end
end

hl.on("window.open", place_new_column_window)

-- Lua layouts swap with the previous or next target and then stop. On the
-- column, left and right have nowhere to go inside the workspace, so send
-- the window to the monitor in that direction. Other layouts keep a normal
-- direction move, including dwindle's monitor fallback.
function move_window(direction)
  local ws = hl.get_active_workspace()
  if ws and ws.tiled_layout == "lua:column" and (direction == "left" or direction == "right") then
    hl.dispatch(hl.dsp.window.move({ monitor = direction == "left" and "l" or "r" }))
    return
  end
  hl.dispatch(hl.dsp.window.move({ direction = direction }))
end

-- Swipe changes the space on this monitor only. The built-in workspace
-- gesture uses global ids and can open a new workspace on this screen.
hl.gesture({
  fingers = 3,
  direction = "left",
  action = function()
    smw.workspace("-1")()
  end,
})

hl.gesture({
  fingers = 3,
  direction = "right",
  action = function()
    smw.workspace("+1")()
  end,
})
