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

--- Get draft comment/reply counts by status, with action counts separate.
---@param session PowerReview.ReviewSession
---@return table { draft: number, pending: number, submitted: number, total: number }
function M.get_draft_counts(session)
  local counts = {
    draft = 0,
    pending = 0,
    submitted = 0,
    total = 0,
    comments_total = 0,
    replies_total = 0,
    actions_draft = 0,
    actions_pending = 0,
    actions_submitted = 0,
    actions_total = 0,
  }

  local function count_draft(op)
    local status = op.status or ""
    counts.total = counts.total + 1
    if counts[status] then
      counts[status] = counts[status] + 1
    end

    local operation_type = op.operation_type or op.action_type
    if operation_type == "Reply" or operation_type == "reply" then
      counts.replies_total = counts.replies_total + 1
    else
      counts.comments_total = counts.comments_total + 1
    end
  end

  local function count_action(op)
    local status = op.status or ""
    counts.actions_total = counts.actions_total + 1
    local key = "actions_" .. status
    if counts[key] then
      counts[key] = counts[key] + 1
    end
  end

  local operations = session.draft_operations or {}
  if #operations > 0 then
    for _, op in ipairs(operations) do
      local operation_type = op.operation_type or op.action_type
      local is_comment = operation_type == "Comment"
        or operation_type == "Reply"
        or operation_type == "comment"
        or operation_type == "reply"
      if is_comment then
        count_draft(op)
      else
        count_action(op)
      end
    end
  else
    for _, d in ipairs(session.drafts or {}) do
      count_draft(d)
    end
    for _, a in ipairs(session.draft_actions or {}) do
      count_action(a)
    end
  end
  return counts
end

---@param action PowerReview.DraftAction
---@return string
function M.draft_action_label(action)
  local operation_type = action.operation_type or action.action_type
  if operation_type == "thread_status_change" or operation_type == "ThreadStatusChange" then
    return string.format(
      "Thread #%s: %s -> %s%s",
      tostring(action.thread_id or "?"),
      tostring(action.from_thread_status or "?"),
      tostring(action.to_thread_status or "?"),
      action.note and (" - " .. action.note) or ""
    )
  end

  if operation_type == "comment_reaction" or operation_type == "CommentReaction" then
    return string.format(
      "%s comment #%s in thread #%s%s",
      tostring(action.reaction or "react"),
      tostring(action.comment_id or "?"),
      tostring(action.thread_id or "?"),
      action.note and (" - " .. action.note) or ""
    )
  end

  return action.note or tostring(operation_type or "draft operation")
end

---@param session PowerReview.ReviewSession
---@param action_id string
---@return PowerReview.DraftAction|nil
function M.get_draft_action(session, action_id)
  for _, action in ipairs(session.draft_actions or {}) do
    if action.id == action_id then
      return action
    end
  end
  return nil
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
-- New-replies helpers (Phase 3 of new-replies feature)
-- ============================================================================

--- Build a fast lookup of "comment_id -> bucket" from `last_deltas`.
--- Used by UI surfaces (comments panel, files panel, neo-tree, comment_preview)
--- to mark new replies without re-running classification logic.
---
--- Buckets:
---   "to_ai"          -> reply_to_ai
---   "to_human"       -> reply_to_human
---   "in_others"      -> reply_in_others_thread
---   "new_thread"     -> new_thread_others
---   "self_echo"      -> self_echo (NOT shown as NEW; suppressed by UI)
---@param session PowerReview.ReviewSession
---@return table<number, string> bucket_by_comment_id Empty if no deltas / silent priming.
function M.get_new_replies_lookup(session)
  local lookup = {}
  local deltas = session.last_deltas
  if type(deltas) ~= "table" then
    return lookup
  end
  local function fill(list, bucket)
    for _, entry in ipairs(list or {}) do
      if entry.comment_id then
        lookup[entry.comment_id] = bucket
      end
    end
  end
  fill(deltas.reply_to_ai, "to_ai")
  fill(deltas.reply_to_human, "to_human")
  fill(deltas.reply_in_others_thread, "in_others")
  fill(deltas.new_thread_others, "new_thread")
  fill(deltas.self_echo, "self_echo")
  return lookup
end

--- Predicate for "this comment is a new/unacked reply we should mark NEW in the UI".
--- Excludes self_echo entries.
---@param lookup table<number, string> from `get_new_replies_lookup`
---@param comment_id number
---@return boolean
function M.is_new_reply(lookup, comment_id)
  local bucket = lookup[comment_id]
  return bucket ~= nil and bucket ~= "self_echo"
end

--- Count new replies on a single thread (excludes self_echo).
---@param lookup table<number, string>
---@param thread PowerReview.CommentThread
---@return number
function M.count_new_replies_on_thread(lookup, thread)
  local count = 0
  for _, c in ipairs(thread.comments or {}) do
    if M.is_new_reply(lookup, c.id) then
      count = count + 1
    end
  end
  return count
end

--- Count new replies across all threads on a file (excludes self_echo).
---@param session PowerReview.ReviewSession
---@param file_path string
---@param lookup? table<number, string> Optional precomputed lookup
---@return number
function M.count_new_replies_for_file(session, file_path, lookup)
  lookup = lookup or M.get_new_replies_lookup(session)
  local total = 0
  for _, t in ipairs(M.get_threads_for_file(session, file_path)) do
    total = total + M.count_new_replies_on_thread(lookup, t)
  end
  return total
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
  if session.metadata and session.metadata.review then
    return {
      reviewed = session.metadata.review.reviewed_files or 0,
      changed = session.metadata.review.changed_since_review or 0,
      unreviewed = session.metadata.review.unreviewed_files or 0,
      total = session.metadata.review.total_files or 0,
    }
  end

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

--- Get derived metadata summaries for the session.
---@param session PowerReview.ReviewSession
---@return PowerReview.ReviewMetadata|table
function M.get_metadata(session)
  return session.metadata or {}
end

return M
