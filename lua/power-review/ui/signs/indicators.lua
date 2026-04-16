--- PowerReview.nvim signs — building indicators from session data
local M = {}

local log = require("power-review.utils.log")

---@class PowerReview.CommentIndicator
---@field kind "remote"|"draft"|"ai_draft"
---@field line number 1-indexed
---@field line_end? number 1-indexed end of range
---@field col_start? number 1-indexed start column
---@field col_end? number 1-indexed end column
---@field count? number Number of comments at this location
---@field preview? string First comment body preview
---@field author? string First comment author
---@field author_name? string Display name of the agent (for AI drafts)
---@field draft_id? string For drafts, the draft comment ID
---@field thread_id? number For remote threads, the thread ID
---@field thread_status? string Thread status string (active/resolved/etc.)

--- Build indicators for a specific file from the current session.
--- Merges remote threads + local drafts.
---@param session PowerReview.ReviewSession
---@param file_path string Relative file path (normalized with forward slashes)
---@return PowerReview.CommentIndicator[]
function M.build(session, file_path)
  local indicators = {}

  local helpers = require("power-review.session_helpers")
  local drafts = helpers.get_drafts_for_file(session, file_path)

  for _, draft in ipairs(drafts) do
    if draft.line_start and draft.line_start > 0 then
      table.insert(indicators, {
        kind = draft.author == "ai" and "ai_draft" or "draft",
        line = draft.line_start,
        line_end = draft.line_end,
        col_start = draft.col_start,
        col_end = draft.col_end,
        count = 1,
        preview = draft.body,
        author = draft.author,
        author_name = draft.author_name,
        draft_id = draft.id,
      })
    end
  end

  local review = require("power-review.review")
  local threads = review.get_threads_for_file(session, file_path)

  for _, thread in ipairs(threads) do
    if thread.type ~= "draft" and thread.line_start and thread.line_start > 0 then
      local first_comment = thread.comments and thread.comments[1]
      table.insert(indicators, {
        kind = "remote",
        line = thread.line_start,
        line_end = thread.line_end,
        col_start = thread.col_start,
        col_end = thread.col_end,
        count = thread.comments and #thread.comments or 0,
        preview = first_comment and first_comment.body or "",
        author = first_comment and first_comment.author or nil,
        thread_id = thread.id,
        thread_status = thread.status,
      })
    end
  end

  table.sort(indicators, function(a, b)
    if a.line ~= b.line then
      return a.line < b.line
    end
    if a.kind == "remote" and b.kind ~= "remote" then
      return true
    end
    return false
  end)

  log.debug(
    "build_indicators(%s): %d drafts + %d remote threads -> %d indicators",
    file_path,
    #drafts,
    #threads,
    #indicators
  )

  return indicators
end

return M
