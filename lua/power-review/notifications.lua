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
    vim.notify(string.format("[PowerReview] Synced %d thread(s)", thread_count), vim.log.levels.INFO)
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

-- ============================================================================
-- New replies (post-sync deltas)
-- ============================================================================

--- Notify about new replies addressed at the local user (or AI on their behalf).
--- Surfaces replies in `last_deltas.reply_to_ai` + `last_deltas.reply_to_human`.
---@param to_ai_count number Count of replies in threads where AI participated
---@param to_human_count number Count of replies in threads where the human user participated
function M.replies_to_me(to_ai_count, to_human_count)
  if not category_enabled("replies_to_me") then
    return
  end
  local total = (to_ai_count or 0) + (to_human_count or 0)
  if total <= 0 then
    return
  end
  -- Distinguish "AI thread" vs "human thread" because these usually warrant
  -- different responses (AI can auto-draft a follow-up; human probably wants to handle their own).
  local parts = {}
  if to_ai_count and to_ai_count > 0 then
    table.insert(parts, string.format("%d on AI thread(s)", to_ai_count))
  end
  if to_human_count and to_human_count > 0 then
    table.insert(parts, string.format("%d on your thread(s)", to_human_count))
  end
  vim.notify(
    string.format("[PowerReview] %d new reply/replies — %s", total, table.concat(parts, ", ")),
    vim.log.levels.INFO
  )
end

--- Notify about new replies / new threads on the PR that don't directly
--- involve the local user or AI. Useful for full-PR awareness; off by default.
---@param replies_count number Count from `last_deltas.reply_in_others_thread`
---@param new_threads_count number Count from `last_deltas.new_thread_others`
function M.replies_to_others(replies_count, new_threads_count)
  if not category_enabled("replies_to_others") then
    return
  end
  local total = (replies_count or 0) + (new_threads_count or 0)
  if total <= 0 then
    return
  end
  local parts = {}
  if replies_count and replies_count > 0 then
    table.insert(parts, string.format("%d new reply/replies", replies_count))
  end
  if new_threads_count and new_threads_count > 0 then
    table.insert(parts, string.format("%d new thread(s)", new_threads_count))
  end
  vim.notify(
    string.format("[PowerReview] PR activity: %s (no direct involvement)", table.concat(parts, ", ")),
    vim.log.levels.INFO
  )
end

return M
