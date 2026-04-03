--- PowerReview.nvim review lifecycle coordinator
--- Orchestrates the review flow by delegating to the CLI tool.
--- The CLI handles: URL parsing, auth, provider API calls, git setup, session persistence.
--- This module handles: Neovim UI coordination, worktree navigation, session state in Lua.
local M = {}

local log = require("power-review.utils.log")
local cli = require("power-review.cli")
local config = require("power-review.config")
local watcher = require("power-review.watcher")

--- Detect the git repository root from the current working directory.
--- Returns the repo root path, or nil if not inside a git repo.
---@return string|nil
local function find_git_root()
  local cwd = vim.fn.getcwd()
  local git_dir = vim.fn.finddir(".git", cwd .. ";")
  if git_dir == "" then
    return nil
  end
  local root = vim.fn.fnamemodify(git_dir, ":h")
  if root == "." then
    root = cwd
  end
  return root
end

--- Start a new review from a PR URL.
--- Delegates to `powerreview open --pr-url <url>` which handles auth, API, git, and session.
---@param pr_url string The PR URL
---@param callback fun(err?: string, session?: PowerReview.ReviewSession)
function M.start_review(pr_url, callback)
  log.info("Starting review for: %s", pr_url)

  local repo_path = find_git_root()

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
    local repo_path = find_git_root()

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
---@param progress_cb? fun(status: string, pending_count: number)
function M.submit_pending(session, callback, progress_cb)
  local pending_count = 0
  for _, d in ipairs(session.drafts) do
    if d.status == "pending" then
      pending_count = pending_count + 1
    end
  end

  if pending_count == 0 then
    callback("No pending drafts to submit")
    return
  end

  -- The CLI handles submission atomically; report start/finish, not per-draft
  if progress_cb then
    progress_cb("submitting", pending_count)
  end

  cli.submit(session.pr_url, function(err, result)
    if err then
      callback(err)
      return
    end

    -- Reload session to get updated draft statuses
    M._reload_current_session(session.pr_url, result)

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

  cli.sync(session.pr_url, function(err, result)
    if err then
      callback("Failed to sync threads: " .. err)
      return
    end

    local thread_count = result and result.thread_count or 0

    -- Reload session to get updated threads
    M._reload_current_session(session.pr_url, result)

    -- Refresh UI
    require("power-review.ui.signs").refresh()
    local comments_panel = require("power-review.ui.comments_panel")
    if comments_panel.is_visible() then
      local updated_session = pr_mod.get_current_session()
      if updated_session then
        comments_panel.refresh(updated_session)
      end
    end

    -- Check if a new iteration was detected during sync
    if result and result.iteration_check and result.iteration_check.has_new_iteration then
      local ic = result.iteration_check
      local changed_count = ic.changed_files and #ic.changed_files or 0
      local msg = string.format(
        "New iteration detected (#%s -> #%s). %d file(s) have new changes.",
        tostring(ic.old_iteration_id or "?"),
        tostring(ic.new_iteration_id or "?"),
        changed_count)
      vim.notify(msg, vim.log.levels.INFO, { title = "PowerReview" })
      -- Refresh file panels to show updated review indicators
      require("power-review.ui").refresh_neotree()
    end

    log.info("Synced %d remote thread(s)", thread_count)
    require("power-review.notifications").sync_complete(thread_count)
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

-- ===== Iteration tracking =====

--- Mark a file as reviewed in the current session.
--- Updates the session via CLI and refreshes all file list UIs.
---@param file_path string Relative file path
---@param callback fun(err?: string)
function M.mark_reviewed(file_path, callback)
  local pr_mod = require("power-review")
  local session = pr_mod.get_current_session()
  if not session then
    callback("No active review session")
    return
  end

  cli.mark_reviewed_async(session.pr_url, file_path, function(err, _result)
    if err then
      callback("Failed to mark reviewed: " .. err)
      return
    end

    -- Reload session to get updated review state
    M._reload_current_session(session.pr_url, _result)

    -- Refresh all file list UIs
    require("power-review.ui").refresh_neotree()

    log.info("Marked as reviewed: %s", file_path)
    callback(nil)
  end)
end

--- Unmark a file as reviewed (remove its reviewed status).
---@param file_path string Relative file path
---@param callback fun(err?: string)
function M.unmark_reviewed(file_path, callback)
  local pr_mod = require("power-review")
  local session = pr_mod.get_current_session()
  if not session then
    callback("No active review session")
    return
  end

  cli.unmark_reviewed_async(session.pr_url, file_path, function(err, _result)
    if err then
      callback("Failed to unmark reviewed: " .. err)
      return
    end

    M._reload_current_session(session.pr_url, _result)
    require("power-review.ui").refresh_neotree()

    log.info("Unmarked as reviewed: %s", file_path)
    callback(nil)
  end)
end

--- Toggle the reviewed status of a file.
--- If currently reviewed, unmarks it. If not reviewed, marks it.
---@param file_path string Relative file path
---@param callback fun(err?: string)
function M.toggle_reviewed(file_path, callback)
  local pr_mod = require("power-review")
  local session = pr_mod.get_current_session()
  if not session then
    callback("No active review session")
    return
  end

  local helpers = require("power-review.session_helpers")
  if helpers.is_file_reviewed(session, file_path) then
    M.unmark_reviewed(file_path, callback)
  else
    M.mark_reviewed(file_path, callback)
  end
end

--- Mark all changed files as reviewed.
---@param callback fun(err?: string)
function M.mark_all_reviewed(callback)
  local pr_mod = require("power-review")
  local session = pr_mod.get_current_session()
  if not session then
    callback("No active review session")
    return
  end

  cli.mark_all_reviewed_async(session.pr_url, function(err, _result)
    if err then
      callback("Failed to mark all reviewed: " .. err)
      return
    end

    M._reload_current_session(session.pr_url, _result)
    require("power-review.ui").refresh_neotree()

    log.info("Marked all %d files as reviewed", #session.files)
    callback(nil)
  end)
end

--- Check for new iterations from the remote provider.
--- If a new iteration is detected, the CLI applies smart reset automatically.
---@param callback fun(err?: string, result?: table)
function M.check_iteration(callback)
  local pr_mod = require("power-review")
  local session = pr_mod.get_current_session()
  if not session then
    callback("No active review session")
    return
  end

  cli.check_iteration(session.pr_url, function(err, result)
    if err then
      callback("Failed to check iteration: " .. err)
      return
    end

    -- Reload session to get updated iteration/review state
    M._reload_current_session(session.pr_url, result)

    -- Refresh all UIs
    require("power-review.ui").refresh_neotree()

    if result and result.has_new_iteration then
      local changed_count = result.changed_files and #result.changed_files or 0
      local msg = string.format(
        "New iteration detected (#%s -> #%s). %d file(s) have new changes.",
        tostring(result.old_iteration_id or "?"),
        tostring(result.new_iteration_id or "?"),
        changed_count)
      vim.notify(msg, vim.log.levels.INFO, { title = "PowerReview" })
    else
      vim.notify("No new iterations detected.", vim.log.levels.INFO, { title = "PowerReview" })
    end

    log.info("Iteration check complete: has_new=%s", tostring(result and result.has_new_iteration or false))
    callback(nil, result)
  end)
end

--- Open an iteration diff view for a specific file.
--- Shows what changed between the last reviewed iteration and the current one.
---@param file_path string Relative file path
---@param callback? fun(err?: string)
function M.iteration_diff(file_path, callback)
  callback = callback or function() end

  local pr_mod = require("power-review")
  local session = pr_mod.get_current_session()
  if not session then
    callback("No active review session")
    return
  end

  -- We need the reviewed_source_commit and current source_commit
  if not session.reviewed_source_commit then
    callback("No previous review point found. Mark files as reviewed first, then check for new iterations.")
    return
  end

  if not session.source_commit then
    callback("No current source commit found. Try syncing first.")
    return
  end

  if session.reviewed_source_commit == session.source_commit then
    callback("No iteration changes. The reviewed commit matches the current commit.")
    return
  end

  -- Open a native diff between the two commits for this file
  local diff_mod = require("power-review.ui.diff")
  diff_mod.open_iteration_diff(session, file_path, session.reviewed_source_commit, session.source_commit, callback)
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
--- If `mutation_result` contains a `session` field (returned by some CLI mutations),
--- uses that directly instead of spawning a new CLI process.
---@param pr_url string
---@param mutation_result? table Optional result from the mutation that may contain updated session data
function M._reload_current_session(pr_url, mutation_result)
  -- If the mutation response includes updated session data, use it directly
  if mutation_result and mutation_result.session then
    local updated = cli.adapt_session(mutation_result.session)
    local pr_mod = require("power-review")
    pr_mod._set_current_session(updated)
    return
  end

  -- Otherwise, fall back to a CLI reload
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
