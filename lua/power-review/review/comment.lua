--- PowerReview.nvim comment data model
--- Functions for creating and validating draft comments.
local M = {}

local async = require("power-review.utils.async")

--- Create a new draft comment
---@param opts table { file_path: string, line_start: number, line_end?: number, col_start?: number, col_end?: number, body: string, author?: "user"|"ai", thread_id?: number, parent_comment_id?: number }
---@return PowerReview.DraftComment
function M.new_draft(opts)
  local now = async.timestamp()
  ---@type PowerReview.DraftComment
  return {
    id = async.uuid(),
    file_path = opts.file_path or "",
    line_start = opts.line_start or 0,
    line_end = opts.line_end,
    col_start = opts.col_start,
    col_end = opts.col_end,
    body = opts.body or "",
    status = "draft",
    author = opts.author or "user",
    thread_id = opts.thread_id,
    parent_comment_id = opts.parent_comment_id,
    created_at = now,
    updated_at = now,
  }
end

--- Check if a draft comment can be edited
--- Only drafts with status "draft" can be edited.
---@param draft PowerReview.DraftComment
---@return boolean
function M.can_edit(draft)
  return draft.status == "draft"
end

--- Check if a draft comment can be deleted
--- Only drafts with status "draft" can be deleted.
---@param draft PowerReview.DraftComment
---@return boolean
function M.can_delete(draft)
  return draft.status == "draft"
end

--- Check if a draft is a reply to an existing thread
---@param draft PowerReview.DraftComment
---@return boolean
function M.is_reply(draft)
  return draft.thread_id ~= nil
end

--- Check if a draft was created by an AI/LLM
---@param draft PowerReview.DraftComment
---@return boolean
function M.is_ai_authored(draft)
  return draft.author == "ai"
end

return M
