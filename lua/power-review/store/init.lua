--- PowerReview.nvim persistence store
--- Delegates all session persistence to the CLI tool.
--- The CLI stores sessions at $XDG_DATA_HOME/PowerReview/sessions/ (v3 format).
local M = {}

local cli = require("power-review.cli")
local log = require("power-review.utils.log")

--- Save is a no-op: the CLI handles persistence on every mutation.
---@param _session PowerReview.ReviewSession
---@return boolean success, string|nil error
function M.save(_session)
  -- The CLI persists session state automatically on every command.
  -- No Lua-side save needed.
  return true, nil
end

--- Load a review session by PR URL (delegates to CLI).
---@param pr_url string The PR URL to load session for
---@return PowerReview.ReviewSession|nil session, string|nil error
function M.load(pr_url)
  return cli.get_session_sync(pr_url)
end

--- Delete a review session (delegates to CLI).
---@param session_id string Session identifier
---@return boolean success, string|nil error
function M.delete(session_id)
  return cli.delete_session(session_id)
end

--- List all saved review sessions (returns summaries).
---@return PowerReview.SessionSummary[]
function M.list()
  local summaries, err = cli.list_sessions()
  if err then
    log.warn("Failed to list sessions: %s", err)
    return {}
  end
  return summaries or {}
end

--- Delete all saved sessions.
function M.clean()
  local count, err = cli.clean_sessions()
  if err then
    log.error("Failed to clean sessions: %s", err)
    return
  end
  log.info("Deleted %d session(s)", count or 0)
end

return M
