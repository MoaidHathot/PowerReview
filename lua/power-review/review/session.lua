--- PowerReview.nvim review session model
--- Manages review session state, including draft comment operations.
local M = {}

local comment_mod = require("power-review.review.comment")
local async_util = require("power-review.utils.async")
local log = require("power-review.utils.log")

--- Create a new review session
---@param opts table
---@return PowerReview.ReviewSession
function M.new(opts)
  local now = async_util.timestamp()

  -- Build session ID: org_project_repo_prId
  local id = string.format("%s_%s_%s_%d",
    (opts.org or ""):gsub("[^%w%-]", "_"),
    (opts.project or ""):gsub("[^%w%-]", "_"),
    (opts.repo or ""):gsub("[^%w%-]", "_"),
    opts.pr_id or 0
  )

  ---@type PowerReview.ReviewSession
  return {
    version = 2,
    id = id,
    pr_id = opts.pr_id,
    provider_type = opts.provider_type,
    org = opts.org or "",
    project = opts.project or "",
    repo = opts.repo or "",
    pr_url = opts.pr_url or "",
    pr_title = opts.pr_title or "",
    pr_description = opts.pr_description or "",
    pr_author = opts.pr_author or "",
    pr_status = opts.pr_status or "active",
    pr_is_draft = opts.pr_is_draft or false,
    pr_closed_at = opts.pr_closed_at,
    source_branch = opts.source_branch or "",
    target_branch = opts.target_branch or "",
    merge_status = opts.merge_status,
    reviewers = opts.reviewers or {},
    labels = opts.labels or {},
    work_items = opts.work_items or {},
    iteration_id = opts.iteration_id,
    source_commit = opts.source_commit,
    target_commit = opts.target_commit,
    worktree_path = opts.worktree_path,
    git_strategy = opts.git_strategy or "worktree",
    created_at = now,
    updated_at = now,
    vote = nil,
    drafts = {},
    threads = {},
    files = opts.files or {},
  }
end

--- Add a draft comment to the session
---@param session PowerReview.ReviewSession
---@param draft PowerReview.DraftComment
function M.add_draft(session, draft)
  table.insert(session.drafts, draft)
  session.updated_at = async_util.timestamp()
  log.debug("Added draft %s to session %s", draft.id, session.id)
end

--- Edit a draft comment's body. Only works on "draft" status comments.
---@param session PowerReview.ReviewSession
---@param draft_id string
---@param new_body string
---@return boolean success, string|nil error
function M.edit_draft(session, draft_id, new_body)
  for _, draft in ipairs(session.drafts) do
    if draft.id == draft_id then
      if not comment_mod.can_edit(draft) then
        return false, string.format(
          "Cannot edit comment %s: status is '%s' (only 'draft' comments can be edited)",
          draft_id, draft.status
        )
      end
      draft.body = new_body
      draft.updated_at = async_util.timestamp()
      session.updated_at = draft.updated_at
      log.debug("Edited draft %s", draft_id)
      return true, nil
    end
  end
  return false, "Draft not found: " .. draft_id
end

--- Delete a draft comment. Only works on "draft" status comments.
---@param session PowerReview.ReviewSession
---@param draft_id string
---@return boolean success, string|nil error
function M.delete_draft(session, draft_id)
  for i, draft in ipairs(session.drafts) do
    if draft.id == draft_id then
      if not comment_mod.can_delete(draft) then
        return false, string.format(
          "Cannot delete comment %s: status is '%s' (only 'draft' comments can be deleted)",
          draft_id, draft.status
        )
      end
      table.remove(session.drafts, i)
      session.updated_at = async_util.timestamp()
      log.debug("Deleted draft %s", draft_id)
      return true, nil
    end
  end
  return false, "Draft not found: " .. draft_id
end

--- Approve a draft (move from "draft" to "pending")
---@param session PowerReview.ReviewSession
---@param draft_id string
---@return boolean success, string|nil error
function M.approve_draft(session, draft_id)
  for _, draft in ipairs(session.drafts) do
    if draft.id == draft_id then
      if draft.status ~= "draft" then
        return false, string.format(
          "Cannot approve comment %s: status is '%s' (expected 'draft')",
          draft_id, draft.status
        )
      end
      draft.status = "pending"
      draft.updated_at = async_util.timestamp()
      session.updated_at = draft.updated_at
      log.debug("Approved draft %s", draft_id)
      return true, nil
    end
  end
  return false, "Draft not found: " .. draft_id
end

--- Approve all drafts (move all "draft" to "pending")
---@param session PowerReview.ReviewSession
---@return number count Number of drafts approved
function M.approve_all_drafts(session)
  local count = 0
  local now = async_util.timestamp()
  for _, draft in ipairs(session.drafts) do
    if draft.status == "draft" then
      draft.status = "pending"
      draft.updated_at = now
      count = count + 1
    end
  end
  if count > 0 then
    session.updated_at = now
    log.info("Approved %d draft(s)", count)
  end
  return count
end

--- Unapprove a draft (revert from "pending" back to "draft")
---@param session PowerReview.ReviewSession
---@param draft_id string
---@return boolean success, string|nil error
function M.unapprove_draft(session, draft_id)
  for _, draft in ipairs(session.drafts) do
    if draft.id == draft_id then
      if draft.status ~= "pending" then
        return false, string.format(
          "Cannot unapprove comment %s: status is '%s' (expected 'pending')",
          draft_id, draft.status
        )
      end
      draft.status = "draft"
      draft.updated_at = async_util.timestamp()
      session.updated_at = draft.updated_at
      log.debug("Unapproved draft %s (reverted to draft)", draft_id)
      return true, nil
    end
  end
  return false, "Draft not found: " .. draft_id
end

--- Get all pending drafts (ready to submit)
---@param session PowerReview.ReviewSession
---@return PowerReview.DraftComment[]
function M.get_pending_drafts(session)
  local pending = {}
  for _, draft in ipairs(session.drafts) do
    if draft.status == "pending" then
      table.insert(pending, draft)
    end
  end
  return pending
end

--- Get all drafts for a specific file
---@param session PowerReview.ReviewSession
---@param file_path string
---@return PowerReview.DraftComment[]
function M.get_drafts_for_file(session, file_path)
  local file_drafts = {}
  local norm_path = file_path:gsub("\\", "/")
  for _, draft in ipairs(session.drafts) do
    local dp = (draft.file_path or ""):gsub("\\", "/")
    if dp == norm_path then
      table.insert(file_drafts, draft)
    end
  end
  return file_drafts
end

--- Mark a draft as submitted
---@param session PowerReview.ReviewSession
---@param draft_id string
---@return boolean success
function M.mark_submitted(session, draft_id)
  for _, draft in ipairs(session.drafts) do
    if draft.id == draft_id then
      draft.status = "submitted"
      draft.updated_at = async_util.timestamp()
      session.updated_at = draft.updated_at
      return true
    end
  end
  return false
end

--- Get a draft by ID
---@param session PowerReview.ReviewSession
---@param draft_id string
---@return PowerReview.DraftComment|nil
function M.get_draft(session, draft_id)
  for _, draft in ipairs(session.drafts) do
    if draft.id == draft_id then
      return draft
    end
  end
  return nil
end

--- Get draft counts by status
---@param session PowerReview.ReviewSession
---@return table { draft: number, pending: number, submitted: number, total: number }
function M.get_draft_counts(session)
  local counts = { draft = 0, pending = 0, submitted = 0, total = #session.drafts }
  for _, d in ipairs(session.drafts) do
    if counts[d.status] then
      counts[d.status] = counts[d.status] + 1
    end
  end
  return counts
end

--- Update the session's cached remote threads.
--- Replaces the entire threads list with fresh data from the provider.
---@param session PowerReview.ReviewSession
---@param threads PowerReview.CommentThread[]
function M.set_threads(session, threads)
  session.threads = threads or {}
  session.updated_at = async_util.timestamp()
  log.debug("Updated remote threads on session %s (%d threads)", session.id, #session.threads)
end

--- Get all cached remote threads
---@param session PowerReview.ReviewSession
---@return PowerReview.CommentThread[]
function M.get_threads(session)
  return session.threads or {}
end

--- Get cached remote threads for a specific file
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

return M
