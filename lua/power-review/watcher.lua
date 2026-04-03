--- PowerReview.nvim session file watcher
--- Monitors the session JSON file for external changes (e.g., AI agents via MCP)
--- and triggers an automatic UI refresh when changes are detected.
local M = {}

local log = require("power-review.utils.log")
local config = require("power-review.config")

---@type userdata|nil UV fs_event handle
M._handle = nil

---@type uv_timer_t|nil Debounce timer
M._timer = nil

---@type string|nil Currently watched file path
M._watched_path = nil

--- Start watching a session file for changes.
--- Debounces rapid changes (e.g., multiple writes from CLI) and reloads the session.
---@param session_path string Absolute path to the session JSON file
---@param pr_url string The PR URL (used to reload the session via CLI)
function M.start(session_path, pr_url)
  if not config.get().watcher.enabled then
    log.debug("Watcher: disabled by config")
    return
  end

  -- Stop any existing watcher
  M.stop()

  local uv = vim.uv or vim.loop
  local handle = uv.new_fs_event()
  if not handle then
    log.warn("Watcher: failed to create fs_event handle")
    return
  end

  local debounce_ms = config.get().watcher.debounce_ms or 200

  local ok, err = handle:start(session_path, {}, function(fs_err, filename, events)
    if fs_err then
      log.debug("Watcher: fs_event error: %s", fs_err)
      return
    end

    -- Debounce: cancel previous timer, start a new one
    if M._timer then
      M._timer:stop()
    end

    M._timer = vim.defer_fn(function()
      M._on_change(pr_url)
    end, debounce_ms)
  end)

  if not ok then
    log.warn("Watcher: failed to start watching %s: %s", session_path, err or "unknown")
    handle:close()
    return
  end

  M._handle = handle
  M._watched_path = session_path
  log.debug("Watcher: monitoring %s (debounce: %dms)", session_path, debounce_ms)
end

--- Stop watching the session file.
function M.stop()
  if M._timer then
    M._timer:stop()
    M._timer = nil
  end

  if M._handle then
    if not M._handle:is_closing() then
      M._handle:stop()
      M._handle:close()
    end
    M._handle = nil
  end

  if M._watched_path then
    log.debug("Watcher: stopped monitoring %s", M._watched_path)
    M._watched_path = nil
  end
end

--- Handle a detected file change: reload session and refresh UI.
---@param pr_url string
function M._on_change(pr_url)
  local pr_mod = require("power-review")
  local current = pr_mod.get_current_session()
  if not current then
    log.debug("Watcher: change detected but no active session, ignoring")
    return
  end

  -- Only reload if the change is for the current session
  if current.pr_url ~= pr_url then
    log.debug("Watcher: change for different PR URL, ignoring")
    return
  end

  log.debug("Watcher: session file changed, reloading")

  -- Capture old session state for diff notifications
  local old_ai_count = 0
  for _, d in ipairs(current.drafts or {}) do
    if (d.author or ""):lower() == "ai" then
      old_ai_count = old_ai_count + 1
    end
  end

  -- Reload the session from disk via CLI
  local cli = require("power-review.cli")
  local updated, err = cli.reload_session(pr_url)
  if not updated then
    log.warn("Watcher: failed to reload session: %s", err or "unknown")
    return
  end

  vim.schedule(function()
    pr_mod._set_current_session(updated)

    -- Refresh all UI components
    require("power-review.ui.signs").refresh()
    require("power-review.ui").refresh_neotree()

    local comments_panel = require("power-review.ui.comments_panel")
    if comments_panel.is_visible() then
      comments_panel.refresh(updated)
    end

    -- Notifications
    local notifications = require("power-review.notifications")
    notifications.watcher_update(updated)

    -- Check for AI draft count changes
    local new_ai_count = 0
    for _, d in ipairs(updated.drafts or {}) do
      if (d.author or ""):lower() == "ai" then
        new_ai_count = new_ai_count + 1
      end
    end
    if new_ai_count ~= old_ai_count then
      notifications.ai_drafts_changed(old_ai_count, new_ai_count)
    end

    log.debug("Watcher: session reloaded (%d drafts, %d threads)",
      #(updated.drafts or {}), #(updated.threads or {}))
  end)
end

--- Check if the watcher is currently active.
---@return boolean
function M.is_active()
  return M._handle ~= nil and M._watched_path ~= nil
end

--- Get the currently watched file path.
---@return string|nil
function M.get_watched_path()
  return M._watched_path
end

return M
