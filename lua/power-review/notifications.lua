--- PowerReview.nvim notification module
--- Centralized, toggleable notifications for review events.
--- All notifications respect both config toggles and runtime overrides.
local M = {}

local config = require("power-review.config")

---@type boolean|nil Runtime override for notifications.enabled (nil = use config)
M._runtime_enabled = nil

--- Check if notifications are globally enabled.
---@return boolean
function M.is_enabled()
  if M._runtime_enabled ~= nil then
    return M._runtime_enabled
  end
  local cfg = config.get().notifications or {}
  return cfg.enabled ~= false
end

--- Enable notifications at runtime (overrides config).
function M.enable()
  M._runtime_enabled = true
end

--- Disable notifications at runtime (overrides config).
function M.disable()
  M._runtime_enabled = false
end

--- Toggle notifications at runtime.
---@return boolean new_state
function M.toggle()
  if M._runtime_enabled == nil then
    -- First toggle: flip the config value
    local cfg = config.get().notifications or {}
    M._runtime_enabled = not (cfg.enabled ~= false)
  else
    M._runtime_enabled = not M._runtime_enabled
  end
  return M._runtime_enabled
end

--- Reset runtime override (revert to config value).
function M.reset()
  M._runtime_enabled = nil
end

-- ============================================================================
-- Notification senders
-- ============================================================================

--- Check if a specific notification category is enabled.
---@param category string e.g. "ai_activity", "sync_complete"
---@return boolean
local function category_enabled(category)
  if not M.is_enabled() then
    return false
  end
  local cfg = config.get().notifications or {}
  return cfg[category] ~= false
end

--- Send a notification (respects global toggle).
---@param msg string
---@param level? number vim.log.levels value (default: INFO)
function M.notify(msg, level)
  if not M.is_enabled() then
    return
  end
  vim.notify("[PowerReview] " .. msg, level or vim.log.levels.INFO)
end

--- Notify about AI activity (draft created/edited/deleted by AI agent).
---@param msg string
function M.ai_activity(msg)
  if category_enabled("ai_activity") then
    vim.notify("[PowerReview] " .. msg, vim.log.levels.INFO)
  end
end

--- Notify about thread sync completion.
---@param thread_count number
function M.sync_complete(thread_count)
  if category_enabled("sync_complete") then
    vim.notify(
      string.format("[PowerReview] Synced %d thread(s)", thread_count),
      vim.log.levels.INFO
    )
  end
end

--- Notify about session file changes detected by the watcher.
---@param session table The updated session
function M.watcher_update(session)
  if category_enabled("watcher") then
    vim.notify("[PowerReview] Session updated (external change detected)", vim.log.levels.INFO)
  end
end

--- Notify about AI drafts detected after a watcher update.
---@param old_count number Previous AI draft count
---@param new_count number New AI draft count
function M.ai_drafts_changed(old_count, new_count)
  if not category_enabled("ai_activity") then
    return
  end
  local diff = new_count - old_count
  if diff > 0 then
    vim.notify(
      string.format("[PowerReview] %d new AI draft(s) detected (%d total)", diff, new_count),
      vim.log.levels.INFO
    )
  elseif diff < 0 then
    vim.notify(
      string.format("[PowerReview] %d AI draft(s) removed (%d remaining)", -diff, new_count),
      vim.log.levels.INFO
    )
  end
end

return M
