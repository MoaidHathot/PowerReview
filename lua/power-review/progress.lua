--- PowerReview.nvim progress/loading indicators
--- Provides spinner notifications for long-running CLI operations.
--- Integrates with nvim-notify/fidget.nvim via vim.notify's replace pattern.
local M = {}

local config = require("power-review.config")

---@class PowerReview.ProgressHandle
---@field id number|nil Notification ID for replacement
---@field msg string Current message
---@field active boolean Whether the operation is still running

--- Active progress handles
---@type table<number, PowerReview.ProgressHandle>
M._handles = {}
M._next_id = 1

--- Spinner frames for animation
local spinner_frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

--- Check if progress notifications are enabled.
---@return boolean
local function is_enabled()
  local cfg = config.get()
  if cfg.notifications and cfg.notifications.progress == false then
    return false
  end
  return true
end

--- Start a progress notification. Returns a handle for updates.
---@param msg string Initial message (e.g., "Opening review...")
---@return number handle_id
function M.start(msg)
  if not is_enabled() then
    return 0
  end

  local id = M._next_id
  M._next_id = M._next_id + 1

  local handle = {
    id = nil,
    msg = msg,
    active = true,
    frame = 1,
  }
  M._handles[id] = handle

  -- Show initial notification
  local display = spinner_frames[1] .. " [PowerReview] " .. msg
  vim.schedule(function()
    vim.notify(display, vim.log.levels.INFO, {
      title = "PowerReview",
      timeout = false,
      -- nvim-notify specific: allow replacement
      replace = handle.id,
    })
  end)

  return id
end

--- Update a progress notification's message.
---@param handle_id number
---@param msg string New message
function M.update(handle_id, msg)
  if handle_id == 0 then
    return
  end
  local handle = M._handles[handle_id]
  if not handle or not handle.active then
    return
  end

  handle.msg = msg
  handle.frame = (handle.frame % #spinner_frames) + 1
  local display = spinner_frames[handle.frame] .. " [PowerReview] " .. msg

  vim.schedule(function()
    vim.notify(display, vim.log.levels.INFO, {
      title = "PowerReview",
      timeout = false,
      replace = handle.id,
    })
  end)
end

--- Complete a progress notification with a success message.
---@param handle_id number
---@param msg? string Final message (defaults to the last update message)
function M.done(handle_id, msg)
  if handle_id == 0 then
    return
  end
  local handle = M._handles[handle_id]
  if not handle then
    return
  end

  handle.active = false
  local display = "[PowerReview] " .. (msg or handle.msg)

  vim.schedule(function()
    vim.notify(display, vim.log.levels.INFO, {
      title = "PowerReview",
      replace = handle.id,
    })
  end)

  M._handles[handle_id] = nil
end

--- Complete a progress notification with a failure message.
---@param handle_id number
---@param msg? string Error message
function M.fail(handle_id, msg)
  if handle_id == 0 then
    return
  end
  local handle = M._handles[handle_id]
  if not handle then
    return
  end

  handle.active = false
  local display = "[PowerReview] " .. (msg or handle.msg)

  vim.schedule(function()
    vim.notify(display, vim.log.levels.ERROR, {
      title = "PowerReview",
      replace = handle.id,
    })
  end)

  M._handles[handle_id] = nil
end

return M
