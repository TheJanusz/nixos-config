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
