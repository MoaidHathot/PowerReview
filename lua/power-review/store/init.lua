--- PowerReview.nvim persistence store
--- High-level API for saving, loading, listing, and deleting review sessions.
local M = {}

local json_store = require("power-review.store.json")
local log = require("power-review.utils.log")

--- Generate a session filename from its ID
---@param session_id string
---@return string
local function session_filename(session_id)
  return session_id .. ".json"
end

--- Save a review session to disk
---@param session PowerReview.ReviewSession
---@return boolean success, string|nil error
function M.save(session)
  local async = require("power-review.utils.async")
  session.updated_at = async.timestamp()
  return json_store.write(session_filename(session.id), session)
end

--- Load a review session from disk
---@param session_id string
---@return PowerReview.ReviewSession|nil session, string|nil error
function M.load(session_id)
  local data, err = json_store.read(session_filename(session_id))
  if not data then
    return nil, err
  end

  -- Ensure required fields exist (migration safety)
  data.drafts = data.drafts or {}
  data.files = data.files or {}
  data.version = data.version or 1

  return data, nil
end

--- Delete a review session from disk
---@param session_id string
---@return boolean success, string|nil error
function M.delete(session_id)
  return json_store.delete(session_filename(session_id))
end

--- List all saved review sessions (returns summaries, not full sessions)
---@return PowerReview.SessionSummary[]
function M.list()
  local filenames = json_store.list_files()
  local summaries = {}

  for _, filename in ipairs(filenames) do
    local data, _ = json_store.read(filename)
    if data then
      ---@type PowerReview.SessionSummary
      local summary = {
        id = data.id or filename:gsub("%.json$", ""),
        pr_id = data.pr_id or 0,
        pr_title = data.pr_title or "(untitled)",
        pr_url = data.pr_url or "",
        provider_type = data.provider_type or "azdo",
        org = data.org or "",
        project = data.project or "",
        repo = data.repo or "",
        draft_count = data.drafts and #data.drafts or 0,
        created_at = data.created_at or "",
        updated_at = data.updated_at or "",
      }
      table.insert(summaries, summary)
    end
  end

  -- Sort by updated_at descending (most recent first)
  table.sort(summaries, function(a, b)
    return a.updated_at > b.updated_at
  end)

  return summaries
end

--- Delete all saved sessions
function M.clean()
  local filenames = json_store.list_files()
  for _, filename in ipairs(filenames) do
    json_store.delete(filename)
  end
  log.info("Deleted %d session(s)", #filenames)
end

return M
