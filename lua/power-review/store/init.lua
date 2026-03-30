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

  -- Migrate from v1 -> v2 (or older sessions without version)
  data = M._migrate(data)

  -- Validate required fields
  local valid, validation_err = M._validate(data)
  if not valid then
    log.warn("Session %s has validation issues: %s", session_id, validation_err or "unknown")
    -- Continue loading despite validation warnings
  end

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
        pr_status = data.pr_status,
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

--- Migrate a session from older schema versions to the current version (v2).
--- All new fields are given safe defaults so older sessions load without errors.
---@param data table Raw session data from JSON
---@return table Migrated session data
function M._migrate(data)
  local old_version = data.version or 0

  -- Fields that must always exist (from v1)
  data.drafts = data.drafts or {}
  data.files = data.files or {}
  data.threads = data.threads or {}

  -- v1 -> v2 migration: add new fields with safe defaults
  if old_version < 2 then
    data.pr_status = data.pr_status or "active"
    data.pr_is_draft = data.pr_is_draft or false
    -- pr_closed_at, merge_status, iteration_id, source_commit, target_commit
    -- are nullable so nil is a valid default
    data.reviewers = data.reviewers or {}
    data.labels = data.labels or {}
    data.work_items = data.work_items or {}

    log.debug("Migrated session %s from v%s to v2", data.id or "unknown", tostring(old_version))
  end

  data.version = 2
  return data
end

--- Validate essential session fields. Returns true if valid, false + reason if not.
--- Validation is lenient: logs warnings but allows loading of partially valid sessions.
---@param data table Session data to validate
---@return boolean valid
---@return string|nil error_message
function M._validate(data)
  local issues = {}

  -- Required string fields
  local required_strings = { "id", "pr_url", "pr_title", "org", "project", "repo", "source_branch", "target_branch" }
  for _, field in ipairs(required_strings) do
    if not data[field] or data[field] == "" then
      table.insert(issues, string.format("missing or empty field '%s'", field))
    end
  end

  -- Required numeric fields
  if not data.pr_id or type(data.pr_id) ~= "number" then
    table.insert(issues, "missing or invalid 'pr_id'")
  end

  -- Provider type
  if data.provider_type ~= "azdo" and data.provider_type ~= "github" then
    table.insert(issues, string.format("invalid provider_type '%s'", tostring(data.provider_type)))
  end

  -- Arrays should be tables
  local array_fields = { "drafts", "files", "threads", "reviewers", "labels", "work_items" }
  for _, field in ipairs(array_fields) do
    if data[field] and type(data[field]) ~= "table" then
      table.insert(issues, string.format("'%s' should be an array, got %s", field, type(data[field])))
      data[field] = {} -- auto-fix
    end
  end

  if #issues > 0 then
    return false, table.concat(issues, "; ")
  end
  return true, nil
end

return M
