--- PowerReview.nvim session helpers
--- Pure data-access functions that operate on the flat session shape.
--- These replace the old review/session.lua and review/status.lua modules
--- without any business logic or side effects.
local M = {}

-- ============================================================================
-- Draft helpers
-- ============================================================================

--- Get all drafts for a specific file.
---@param session PowerReview.ReviewSession
---@param file_path string
---@return PowerReview.DraftComment[]
function M.get_drafts_for_file(session, file_path)
  local file_drafts = {}
  local norm_path = file_path:gsub("\\", "/")
  for _, draft in ipairs(session.drafts or {}) do
    local dp = (draft.file_path or ""):gsub("\\", "/")
    if dp == norm_path then
      table.insert(file_drafts, draft)
    end
  end
  return file_drafts
end

--- Get a single draft by ID.
---@param session PowerReview.ReviewSession
---@param draft_id string
---@return PowerReview.DraftComment|nil
function M.get_draft(session, draft_id)
  for _, draft in ipairs(session.drafts or {}) do
    if draft.id == draft_id then
      return draft
    end
  end
  return nil
end

--- Get draft counts by status.
---@param session PowerReview.ReviewSession
---@return table { draft: number, pending: number, submitted: number, total: number }
function M.get_draft_counts(session)
  local drafts = session.drafts or {}
  local counts = { draft = 0, pending = 0, submitted = 0, total = #drafts }
  for _, d in ipairs(drafts) do
    if counts[d.status] then
      counts[d.status] = counts[d.status] + 1
    end
  end
  return counts
end

-- ============================================================================
-- Thread helpers
-- ============================================================================

--- Get cached remote threads for a specific file.
---@param session PowerReview.ReviewSession
---@param file_path string
---@return PowerReview.CommentThread[]
function M.get_threads_for_file(session, file_path)
  local threads = session.threads or {}
  local file_threads = {}
  local norm_path = file_path:gsub("\\", "/")
  for _, thread in ipairs(threads) do
    if thread.file_path then
      local tp = thread.file_path:gsub("\\", "/")
      if tp == norm_path then
        table.insert(file_threads, thread)
      end
    end
  end
  return file_threads
end

-- ============================================================================
-- Vote helpers (replaces review/status.lua)
-- ============================================================================

--- Get vote choices for UI selection.
--- If current_vote is provided, marks the matching choice.
---@param current_vote? PowerReview.ReviewVote
---@return table[] List of { label: string, value: number, key: string, is_current?: boolean }
function M.get_vote_choices(current_vote)
  local choices = {
    { label = "Approved", value = 10, key = "approved" },
    { label = "Approved with suggestions", value = 5, key = "approved_with_suggestions" },
    { label = "No vote (reset)", value = 0, key = "no_vote" },
    { label = "Wait for author", value = -5, key = "wait_for_author" },
    { label = "Rejected", value = -10, key = "rejected" },
  }

  if current_vote ~= nil then
    for _, choice in ipairs(choices) do
      if choice.value == current_vote then
        choice.label = choice.label .. " (current)"
        choice.is_current = true
      end
    end
  end

  return choices
end

--- Get human-readable label for a numeric vote value.
---@param vote PowerReview.ReviewVote
---@return string
function M.vote_label(vote)
  local labels = {
    [10] = "Approved",
    [5] = "Approved with suggestions",
    [0] = "No vote",
    [-5] = "Wait for author",
    [-10] = "Rejected",
  }
  return labels[vote] or ("Unknown (" .. tostring(vote) .. ")")
end

-- ============================================================================
-- Review status helpers (iteration tracking)
-- ============================================================================

--- Check if a file has been marked as reviewed in the current session.
---@param session PowerReview.ReviewSession
---@param file_path string
---@return boolean
function M.is_file_reviewed(session, file_path)
  local norm_path = file_path:gsub("\\", "/")
  for _, reviewed in ipairs(session.reviewed_files or {}) do
    if reviewed:gsub("\\", "/") == norm_path then
      return true
    end
  end
  return false
end

--- Check if a file has changes since the last reviewed iteration.
--- These are files that were previously reviewed but have been modified
--- in a new iteration (smart reset has cleared their reviewed status).
---@param session PowerReview.ReviewSession
---@param file_path string
---@return boolean
function M.is_file_changed_since_review(session, file_path)
  local norm_path = file_path:gsub("\\", "/")
  for _, changed in ipairs(session.changed_since_review or {}) do
    if changed:gsub("\\", "/") == norm_path then
      return true
    end
  end
  return false
end

--- Get the review status of a file for display purposes.
--- Returns a status string and icon suitable for UI rendering.
---@param session PowerReview.ReviewSession
---@param file_path string
---@return string status One of "reviewed", "changed", "unreviewed"
---@return string icon Display icon
function M.get_file_review_status(session, file_path)
  if M.is_file_reviewed(session, file_path) then
    return "reviewed", ""
  elseif M.is_file_changed_since_review(session, file_path) then
    return "changed", ""
  else
    return "unreviewed", ""
  end
end

--- Count review progress for the session.
---@param session PowerReview.ReviewSession
---@return table { reviewed: number, changed: number, unreviewed: number, total: number }
function M.get_review_progress(session)
  local total = #(session.files or {})
  local reviewed = #(session.reviewed_files or {})
  local changed = #(session.changed_since_review or {})
  -- unreviewed = total files minus reviewed minus changed
  -- (changed files are NOT in reviewed_files after smart reset)
  local unreviewed = total - reviewed - changed
  if unreviewed < 0 then
    unreviewed = 0
  end
  return {
    reviewed = reviewed,
    changed = changed,
    unreviewed = unreviewed,
    total = total,
  }
end

return M
