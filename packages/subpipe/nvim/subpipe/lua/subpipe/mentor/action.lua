-- Mentor RPC: busy flag, jobstart, pending goto coalesce
local panel = require("subpipe.panel")

local M = {}

local S = {
  state = nil, -- shared mentor state table
  json_encode = nil,
  write_buffers = nil,
  buffer_line = nil,
  on_response = nil, -- function(raw)
  on_idle = nil, -- function() after busy clears (flush pending)
}

function M.bind(opts)
  S.state = opts.state
  S.json_encode = opts.json_encode
  S.write_buffers = opts.write_buffers
  S.buffer_line = opts.buffer_line
  S.on_response = opts.on_response
  S.on_idle = opts.on_idle
end

function M.is_busy()
  return S.state and S.state.busy
end

function M.request_goto(cue_id)
  local state = S.state
  if not state or not cue_id then
    return
  end
  cue_id = tostring(cue_id)
  if state.loaded_cue_id and tostring(state.loaded_cue_id) == cue_id then
    state.pending_goto_id = nil
    return
  end
  state.pending_goto_id = cue_id
  if state.busy then
    return
  end
  M.flush_pending_goto()
end

function M.flush_pending_goto()
  local state = S.state
  if not state or state.busy then
    return
  end
  local id = state.pending_goto_id
  if not id then
    return
  end
  if state.loaded_cue_id and tostring(state.loaded_cue_id) == tostring(id) then
    state.pending_goto_id = nil
    return
  end
  state.pending_goto_id = nil
  M.run("goto", { cue_id = id })
end

local LABELS = {
  load = "Loading…",
  next = "Next cue…",
  prev = "Previous cue…",
  ["goto"] = "Jumping…",
  save = "Saving…",
  accept_en = "Accepting EN…",
  accept_pl = "Accepting PL…",
  accept_both = "Accepting EN+PL…",
  accept_pl_propagate = "Accepting PL…",
  generate = "Generating preview…",
  accept_voice = "Accepting voice take…",
  reflect = "Reflecting edit…",
  propagate_confirm = "Propagating…",
  propagate_skip = "Skipping propagate…",
  undo = "Undoing cue…",
  toggle_filter = "Cycling filter…",
  quit = "Saving & quitting…",
}

function M.run(op, extra)
  local state = S.state
  if not state then
    return
  end
  if state.busy then
    if op == "goto" and extra and extra.cue_id then
      state.pending_goto_id = tostring(extra.cue_id)
      return
    end
    panel.set_status("Busy — wait for current job…")
    return
  end
  extra = extra or {}
  local cur_en = S.buffer_line(state.en_buf)
  local cur_pl = S.buffer_line(state.pl_buf)
  local dirty = cur_en ~= state.loaded_en or cur_pl ~= state.loaded_pl
  extra.buffer_cue_id = state.loaded_cue_id
  extra.sync_buffers = dirty
    or op == "accept_both"
    or op == "accept_en"
    or op == "accept_pl"
    or op == "accept_pl_propagate"
    or op == "save"
    or op == "quit"
  if extra.sync_buffers then
    S.write_buffers()
  end
  state.busy = true
  state.last_op = op
  panel.set_status(LABELS[op] or ("Processing " .. tostring(op) .. "…"))
  local payload = vim.tbl_extend("force", { op = op }, extra)
  local cmd = {
    state.bin,
    "mentor-action",
    "--out",
    state.out,
    "--session",
    state.session,
  }
  local stdout = {}
  local stderr = {}
  local job = vim.fn.jobstart(cmd, {
    stdin = "pipe",
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if data then
        for _, line in ipairs(data) do
          if line ~= "" then
            table.insert(stdout, line)
          end
        end
      end
    end,
    on_stderr = function(_, data)
      if data then
        for _, line in ipairs(data) do
          if line ~= "" then
            table.insert(stderr, line)
            local short = line
            if #short > 80 then
              short = short:sub(1, 77) .. "…"
            end
            vim.schedule(function()
              if state.busy then
                panel.set_status(short)
              end
            end)
          end
        end
      end
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        local raw = table.concat(stdout, "\n")
        if code ~= 0 and raw == "" then
          state.busy = false
          panel.set_status("mentor-action exit " .. tostring(code))
          if #stderr > 0 then
            panel.set_status(stderr[#stderr]:sub(1, 80))
          end
          panel.flush_queue_if_idle()
          if S.on_idle then
            S.on_idle()
          end
          return
        end
        if S.on_response then
          S.on_response(raw)
        end
        if S.on_idle then
          S.on_idle()
        end
      end)
    end,
  })
  if job <= 0 then
    state.busy = false
    panel.set_status("failed to start mentor-action")
    panel.flush_queue_if_idle()
    if S.on_idle then
      S.on_idle()
    end
    return
  end
  vim.fn.chansend(job, S.json_encode(payload) .. "\n")
  vim.fn.chanclose(job, "stdin")
end

return M
