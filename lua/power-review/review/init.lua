--- PowerReview.nvim review lifecycle coordinator
--- Orchestrates the review flow by delegating to the CLI tool.
--- The CLI handles: URL parsing, auth, provider API calls, git setup, session persistence.
--- This module handles: Neovim UI coordination, worktree navigation, session state in Lua.
local M = {}

local log = require("power-review.utils.log")
local cli = require("power-review.cli")
local config = require("power-review.config")
local watcher = require("power-review.watcher")

--- Start a new review from a PR URL.
--- Delegates to `powerreview open --pr-url <url>` which handles auth, API, git, and session.
---@param pr_url string The PR URL
---@param callback fun(err?: string, session?: PowerReview.ReviewSession)
function M.start_review(pr_url, callback)
  log.info("Starting review for: %s", pr_url)

  -- Determine repo path for CLI
  local repo_path = nil
  local cwd = vim.fn.getcwd()
  -- Check if we're in a git repo
  local git_dir = vim.fn.finddir(".git", cwd .. ";")
  if git_dir ~= "" then
    repo_path = vim.fn.fnamemodify(git_dir, ":h")
    if repo_path == "." then
      repo_path = cwd
    end
  end

  cli.open(pr_url, repo_path, function(err, session)
    if err then
      callback("CLI: " .. err)
      return
    end

    -- Set as current session
    local pr_mod = require("power-review")
    pr_mod._set_current_session(session)

    -- Navigate to worktree if applicable
    M._navigate_to_review(session)

    -- Start file watcher for external changes (e.g., AI agents via MCP)
    M._start_watcher(session)

    -- Refresh UI
    require("power-review.ui").refresh_neotree()

    log.info("Review session started: %s (PR #%d: %s) - %d remote threads",
      session.id, session.pr_id, session.pr_title, #(session.threads or {}))
    callback(nil, session)
  end)
end

--- Resume a saved review session.
--- Loads the session from CLI and sets it as current.
---@param session_id_or_url string Session ID or PR URL
---@param callback fun(err?: string, session?: PowerReview.ReviewSession)
function M.resume_session(session_id_or_url, callback)
  -- We need to figure out the PR URL from the session.
  -- First, try to load session list and find the matching one.
  cli.list_sessions_async(function(list_err, summaries)
    if list_err then
      callback("Failed to list sessions: " .. list_err)
      return
    end

    local pr_url = nil
    for _, s in ipairs(summaries or {}) do
      if s.id == session_id_or_url then
        pr_url = s.pr_url
        break
      end
    end

    if not pr_url then
      -- Maybe it's already a URL
      pr_url = session_id_or_url
    end

    -- Use open to re-fetch and resume (CLI handles existing session merging)
    local repo_path = nil
    local cwd = vim.fn.getcwd()
    local git_dir = vim.fn.finddir(".git", cwd .. ";")
    if git_dir ~= "" then
      repo_path = vim.fn.fnamemodify(git_dir, ":h")
      if repo_path == "." then
        repo_path = cwd
      end
    end

    cli.open(pr_url, repo_path, function(err, session)
      if err then
        callback("Resume failed: " .. err)
        return
      end

      -- Set as current session
      local pr_mod = require("power-review")
      pr_mod._set_current_session(session)

      -- Navigate to worktree if applicable
      M._navigate_to_review(session)

      -- Start file watcher for external changes (e.g., AI agents via MCP)
      M._start_watcher(session)

      -- Refresh UI
      require("power-review.ui").refresh_neotree()

      log.info("Resumed session: %s (PR #%d: %s)", session.id, session.pr_id, session.pr_title)
      callback(nil, session)
    end)
  end)
end

--- Close the current review session.
---@param callback fun(err?: string)
function M.close_review(callback)
  local pr_mod = require("power-review")
  local session = pr_mod.get_current_session()

  if not session then
    callback("No active review session")
    return
  end

  -- Teardown UI
  local ui = require("power-review.ui")
  pcall(ui.teardown_all)

  -- Stop file watcher
  watcher.stop()

  -- Tell CLI to close (handles git cleanup)
  cli.close(session.pr_url, function(err)
    if err then
      log.warn("CLI close warning: %s", err)
    end

    pr_mod._set_current_session(nil)
    log.info("Review session closed: %s", session.id)
    callback(nil)
  end)
end

--- Refresh the current session (re-fetch from CLI which re-fetches from remote).
---@param callback fun(err?: string)
function M.refresh_session(callback)
  local pr_mod = require("power-review")
  local session = pr_mod.get_current_session()

  if not session then
    callback("No active review session")
    return
  end

  -- Re-open refreshes everything
  local repo_path = nil
  if session.worktree_path then
    -- Use the original repo, not the worktree
    repo_path = vim.fn.fnamemodify(session.worktree_path, ":h:h")
  else
    repo_path = vim.fn.getcwd()
  end

  cli.open(session.pr_url, repo_path, function(err, refreshed)
    if err then
      callback("Refresh failed: " .. err)
      return
    end

    pr_mod._set_current_session(refreshed)

    -- Refresh UI
    require("power-review.ui.signs").refresh()
    require("power-review.ui").refresh_neotree()
    local comments_panel = require("power-review.ui.comments_panel")
    if comments_panel.is_visible() then
      comments_panel.refresh(refreshed)
    end

    log.info("Session refreshed: %d files, %d remote threads",
      #refreshed.files, #(refreshed.threads or {}))
    callback(nil)
  end)
end

--- Submit all pending draft comments.
---@param session PowerReview.ReviewSession
---@param callback fun(err?: string, result?: PowerReview.SubmitResult)
---@param progress_cb? fun(current: number, total: number, draft: PowerReview.DraftComment)
function M.submit_pending(session, callback, progress_cb)
  -- The CLI handles submission atomically; we can't report per-draft progress
  -- but we can report start/finish
  if progress_cb then
    local pending_count = 0
    for _, d in ipairs(session.drafts) do
      if d.status == "pending" then
        pending_count = pending_count + 1
      end
    end
    if pending_count > 0 then
      progress_cb(1, pending_count, session.drafts[1])
    end
  end

  cli.submit(session.pr_url, function(err, result)
    if err then
      callback(err)
      return
    end

    -- Reload session to get updated draft statuses
    M._reload_current_session(session.pr_url)

    callback(nil, result)
  end)
end

--- Retry failed submissions (re-submit all pending).
---@param session PowerReview.ReviewSession
---@param failed_drafts table[]
---@param callback fun(err?: string, result?: PowerReview.SubmitResult)
function M.retry_failed_submissions(session, failed_drafts, callback)
  -- Just re-submit; the CLI will pick up any still-pending drafts
  M.submit_pending(session, callback)
end

--- Set the review vote.
---@param session PowerReview.ReviewSession
---@param vote PowerReview.ReviewVote
---@param callback fun(err?: string, ok?: boolean)
function M.set_vote(session, vote, callback)
  local vote_str = cli.vote_value_to_string(vote)

  cli.vote(session.pr_url, vote_str, function(err)
    if err then
      callback("Failed to set vote: " .. err)
      return
    end

    -- Reload session to get updated vote
    M._reload_current_session(session.pr_url)

    callback(nil, true)
  end)
end

--- Sync remote comment threads.
---@param callback fun(err?: string, thread_count?: number)
function M.sync_threads(callback)
  local pr_mod = require("power-review")
  local session = pr_mod.get_current_session()

  if not session then
    callback("No active review session")
    return
  end

  cli.sync(session.pr_url, function(err, thread_count)
    if err then
      callback("Failed to sync threads: " .. err)
      return
    end

    -- Reload session to get updated threads
    M._reload_current_session(session.pr_url)

    -- Refresh UI
    require("power-review.ui.signs").refresh()
    local comments_panel = require("power-review.ui.comments_panel")
    if comments_panel.is_visible() then
      local updated_session = pr_mod.get_current_session()
      if updated_session then
        comments_panel.refresh(updated_session)
      end
    end

    log.info("Synced %d remote thread(s)", thread_count or 0)
    require("power-review.notifications").sync_complete(thread_count or 0)
    callback(nil, thread_count)
  end)
end

--- Get all comment threads (remote + local drafts formatted as threads).
---@param session PowerReview.ReviewSession
---@return table threads
function M.get_all_threads(session)
  local threads = {}

  -- 1. Remote threads from session cache
  for _, thread in ipairs(session.threads or {}) do
    table.insert(threads, {
      type = "remote",
      id = thread.id,
      file_path = thread.file_path,
      line_start = thread.line_start,
      line_end = thread.line_end,
      status = thread.status,
      comments = thread.comments or {},
      is_deleted = thread.is_deleted,
    })
  end

  -- 2. Local drafts grouped by file:line as pseudo-threads
  local drafts_by_file = {}
  for _, draft in ipairs(session.drafts or {}) do
    local key = (draft.file_path or "") .. ":" .. tostring(draft.line_start or 0)
    if not drafts_by_file[key] then
      drafts_by_file[key] = {
        file_path = draft.file_path,
        line_start = draft.line_start,
        drafts = {},
      }
    end
    table.insert(drafts_by_file[key].drafts, draft)
  end

  for _, group in pairs(drafts_by_file) do
    table.insert(threads, {
      type = "draft",
      file_path = group.file_path,
      line_start = group.line_start,
      drafts = group.drafts,
    })
  end

  return threads
end

--- Get threads for a specific file.
---@param session PowerReview.ReviewSession
---@param file_path string
---@return table threads
function M.get_threads_for_file(session, file_path)
  local all = M.get_all_threads(session)
  local filtered = {}
  local norm_path = file_path:gsub("\\", "/")
  for _, thread in ipairs(all) do
    local tp = (thread.file_path or ""):gsub("\\", "/")
    if tp == norm_path then
      table.insert(filtered, thread)
    end
  end
  return filtered
end

--- Get file diff content.
--- The actual diff is handled by the diff UI (codediff.nvim or native),
--- which works directly on the git worktree files.
---@param session PowerReview.ReviewSession
---@param file_path string
---@return string|nil diff_content, string|nil error
function M.get_file_diff(session, file_path)
  return nil, "Use the diff view (codediff.nvim) for file diffs"
end

-- ===== Internal helpers =====

--- Navigate to the review location (worktree or repo root).
---@param session PowerReview.ReviewSession
function M._navigate_to_review(session)
  if session.worktree_path and vim.fn.isdirectory(session.worktree_path) == 1 then
    vim.cmd("tcd " .. vim.fn.fnameescape(session.worktree_path))
    log.info("Working directory set to worktree: %s", session.worktree_path)
  end
end

--- Reload the current session from CLI after a mutation.
--- Updates the in-memory session object.
---@param pr_url string
function M._reload_current_session(pr_url)
  local updated, err = cli.reload_session(pr_url)
  if updated then
    local pr_mod = require("power-review")
    pr_mod._set_current_session(updated)
  else
    log.warn("Failed to reload session after mutation: %s", err or "unknown")
  end
end

--- Start the session file watcher for a session.
--- Uses the session_file_path returned by the CLI open command, or falls back
--- to querying it via the standalone `session --path-only` command.
---@param session PowerReview.ReviewSession
function M._start_watcher(session)
  local session_path = session._session_file_path
  if not session_path then
    -- Fallback: query session path from CLI
    local path, err = cli.get_session_path(session.pr_url)
    if err or not path then
      log.warn("Watcher: could not determine session file path: %s", err or "unknown")
      return
    end
    session_path = path
  end

  watcher.start(session_path, session.pr_url)
end

return M
