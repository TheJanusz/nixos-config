---@diagnostic disable: undefined-global
-- Equal-height stack for the rotated monitor. Dwindle only ever halves
-- the focused window, so three windows become 1/2 + 1/4 + 1/4.
hl.layout.register("rows", {
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

hl.workspace_rule({
  workspace = "m[DP-4]",
  layout = "lua:rows",
})

-- Workspaces are one left-to-right strip: lower ids on the left screen,
-- then the main screen, then anything opened further right. A new id is
-- created on the window's own monitor, so focus that window first.
local aligning_workspaces = false

local function workspace_snapshot()
  local list = {}
  for _, ws in ipairs(hl.get_workspaces()) do
    if ws.id and ws.id > 0 and not ws.special and ws.monitor and ws.windows and ws.windows > 0 then
      table.insert(list, {
        id = ws.id,
        x = ws.monitor.x,
        y = ws.monitor.y,
      })
    end
  end
  table.sort(list, function(a, b)
    if a.x ~= b.x then
      return a.x < b.x
    end
    if a.y ~= b.y then
      return a.y < b.y
    end
    return a.id < b.id
  end)
  return list
end

local function addresses_on(id)
  local found = {}
  for _, window in ipairs(hl.get_windows()) do
    if window.address and window.workspace and window.workspace.id == id then
      table.insert(found, window.address)
    end
  end
  return found
end

local function find_window(addr)
  if not addr then
    return
  end
  for _, window in ipairs(hl.get_windows()) do
    if window.address == addr then
      return window
    end
  end
end

local function move_window_to_id(addr, id)
  local window = find_window(addr)
  local src = window and window.monitor and window.monitor.name
  if not src then
    return false
  end
  local existing = hl.get_workspace(tostring(id))
  if existing and existing.monitor and existing.monitor.name ~= src then
    return false
  end
  hl.dispatch(hl.dsp.focus({ window = "address:" .. addr }))
  hl.dispatch(hl.dsp.window.move({
    workspace = tostring(id),
    window = "address:" .. addr,
    follow = true,
  }))
  local moved = find_window(addr)
  local mon = moved and moved.monitor and moved.monitor.name
  local ws = moved and moved.workspace and moved.workspace.id
  return mon == src and ws == id
end

local function relocate(slots, field)
  for _, slot in ipairs(slots) do
    for _, addr in ipairs(slot.addrs) do
      if not move_window_to_id(addr, slot[field]) then
        return false
      end
    end
  end
  return true
end

-- dest, list, found. found is false when the active workspace is not in the strip.
local function neighbor(direction)
  local list = workspace_snapshot()
  local current = hl.get_active_workspace()
  if not current then
    return nil, list, false
  end
  local step = direction == "right" and 1 or -1
  for i, item in ipairs(list) do
    if item.id == current.id then
      return list[i + step], list, true
    end
  end
  return nil, list, false
end

function align_workspace_ids()
  if aligning_workspaces then
    return
  end
  local list = workspace_snapshot()
  if #list == 0 then
    return
  end
  for i, item in ipairs(list) do
    if item.id ~= i then
      aligning_workspaces = true
      local active = hl.get_active_window()
      local active_addr = active and active.address
      local parked = {}
      for index, slot in ipairs(list) do
        parked[index] = {
          temp = 1000 + index,
          final = index,
          addrs = addresses_on(slot.id),
        }
      end
      if relocate(parked, "temp") then
        relocate(parked, "final")
      end
      if active_addr then
        hl.dispatch(hl.dsp.focus({ window = "address:" .. active_addr }))
      end
      aligning_workspaces = false
      return
    end
  end
end

local function shift_ids_up(active_addr)
  local list = workspace_snapshot()
  for i = #list, 1, -1 do
    local id = list[i].id
    for _, addr in ipairs(addresses_on(id)) do
      if not move_window_to_id(addr, id + 1) then
        return false
      end
    end
  end
  if active_addr then
    return move_window_to_id(active_addr, 1)
  end
  return true
end

function focus_workspace_spatial(direction)
  local dest = neighbor(direction)
  if dest then
    hl.dispatch(hl.dsp.focus({ workspace = tostring(dest.id) }))
  end
end

function move_workspace_spatial(direction)
  align_workspace_ids()

  local ws = hl.get_active_workspace()
  local monitor = ws and ws.monitor
  if not monitor then
    return
  end

  local vertical = monitor.transform % 2 == 1
  if not vertical then
    local win = hl.get_active_window()
    local function signature(target)
      if not target or not target.at or not target.size then
        return ""
      end
      return string.format(
        "%s:%s:%s:%s:%s",
        tostring(target.at.x),
        tostring(target.at.y),
        tostring(target.size.x),
        tostring(target.size.y),
        tostring(target.workspace and target.workspace.id)
      )
    end
    local before = signature(win)
    local before_ws = win and win.workspace and win.workspace.id
    hl.config({ binds = { window_direction_monitor_fallback = false } })
    pcall(function()
      hl.dispatch(hl.dsp.window.move({ direction = direction }))
    end)
    hl.config({ binds = { window_direction_monitor_fallback = true } })
    local moved = find_window(win and win.address)
    local after_ws = moved and moved.workspace and moved.workspace.id
    if signature(moved) ~= before and after_ws == before_ws then
      return
    end
  end

  local dest, list, found = neighbor(direction)
  if not found then
    return
  end
  if dest then
    local win = hl.get_active_window()
    if win and win.address then
      hl.dispatch(hl.dsp.window.move({
        workspace = tostring(dest.id),
        window = "address:" .. win.address,
        follow = true,
      }))
    end
    return
  end

  if direction == "right" then
    hl.dispatch(hl.dsp.window.move({ workspace = tostring(#list + 1) }))
    return
  end

  local win = hl.get_active_window()
  if win and win.address then
    shift_ids_up(win.address)
  end
end

align_workspace_ids()

hl.on("window.open", function()
  align_workspace_ids()
end)
