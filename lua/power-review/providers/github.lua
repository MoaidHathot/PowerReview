--- PowerReview.nvim GitHub provider (STUB)
--- This provider is a placeholder for future GitHub PR review support.
--- All methods return a "not yet implemented" error.
local M = {}

local log = require("power-review.utils.log")

local NOT_IMPL = "GitHub provider is not yet implemented"

--- Create a new GitHub provider instance.
---@param opts table { owner: string, repo: string, auth_header: string }
---@return PowerReview.Provider
function M.new(opts)
  ---@type PowerReview.Provider
  local provider = {
    type = "github",
    _owner = opts.owner or opts.organization or "",
    _repo = opts.repository or opts.repo or "",
    _auth_header = opts.auth_header or "",
  }

  --- Fetch a pull request by ID.
  ---@param pr_id number
  ---@param callback fun(err?: string, pr?: PowerReview.PR)
  function provider:get_pull_request(pr_id, callback)
    log.warn(NOT_IMPL)
    callback(NOT_IMPL)
  end

  --- Get the list of changed files for a PR.
  ---@param pr_id number
  ---@param callback fun(err?: string, files?: PowerReview.ChangedFile[])
  function provider:get_changed_files(pr_id, callback)
    log.warn(NOT_IMPL)
    callback(NOT_IMPL)
  end

  --- Get comment threads for a PR.
  ---@param pr_id number
  ---@param callback fun(err?: string, threads?: PowerReview.CommentThread[])
  function provider:get_threads(pr_id, callback)
    log.warn(NOT_IMPL)
    callback(NOT_IMPL)
  end

  --- Create a new comment thread on a PR.
  ---@param pr_id number
  ---@param thread table Thread data
  ---@param callback fun(err?: string, thread?: PowerReview.CommentThread)
  function provider:create_thread(pr_id, thread, callback)
    log.warn(NOT_IMPL)
    callback(NOT_IMPL)
  end

  --- Reply to an existing comment thread.
  ---@param pr_id number
  ---@param thread_id number
  ---@param body string
  ---@param callback fun(err?: string, comment?: PowerReview.Comment)
  function provider:reply_to_thread(pr_id, thread_id, body, callback)
    log.warn(NOT_IMPL)
    callback(NOT_IMPL)
  end

  --- Update an existing comment.
  ---@param pr_id number
  ---@param thread_id number
  ---@param comment_id number
  ---@param body string
  ---@param callback fun(err?: string, comment?: PowerReview.Comment)
  function provider:update_comment(pr_id, thread_id, comment_id, body, callback)
    log.warn(NOT_IMPL)
    callback(NOT_IMPL)
  end

  --- Delete a comment.
  ---@param pr_id number
  ---@param thread_id number
  ---@param comment_id number
  ---@param callback fun(err?: string, ok?: boolean)
  function provider:delete_comment(pr_id, thread_id, comment_id, callback)
    log.warn(NOT_IMPL)
    callback(NOT_IMPL)
  end

  --- Set a review vote (approval/rejection).
  ---@param pr_id number
  ---@param reviewer_id string
  ---@param vote PowerReview.ReviewVote
  ---@param callback fun(err?: string, ok?: boolean)
  function provider:set_vote(pr_id, reviewer_id, vote, callback)
    log.warn(NOT_IMPL)
    callback(NOT_IMPL)
  end

  --- Get file content at a specific version.
  ---@param pr_id number
  ---@param file_path string
  ---@param version string
  ---@param callback fun(err?: string, content?: string)
  function provider:get_file_content(pr_id, file_path, version, callback)
    log.warn(NOT_IMPL)
    callback(NOT_IMPL)
  end

  return provider
end

return M
