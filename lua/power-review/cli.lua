--- PowerReview.nvim CLI bridge
--- Spawns the `powerreview` CLI tool and parses JSON output.
--- All business logic flows through this module.
local M = {}

local log = require("power-review.utils.log")
local config = require("power-review.config")

--- The CLI executable. Can be a string (single command) or a table (command prefix).
--- When a table, the first element is the executable and the rest are prepended args.
--- Example: { "dotnet", "run", "--project", "/path/to/project", "--" }
---@type string|string[]
M._executable = { "dnx", "--yes", "--add-source", "https://api.nuget.org/v3/index.json", "PowerReview", "--" }

--- Configure the CLI bridge.
---@param opts? { executable?: string|string[] }
function M.configure(opts)
  opts = opts or {}
  if opts.executable then
    M._executable = opts.executable
  end
end

-- ============================================================================
-- Low-level CLI execution
-- ============================================================================

--- Run a CLI command synchronously.
--- Returns parsed JSON output on success, or nil + error string on failure.
---@param args string[] CLI arguments (e.g., {"open", "--pr-url", url})
---@param opts? { stdin?: string, timeout?: number }
---@return table|nil result, string|nil error
function M.run(args, opts)
  opts = opts or {}
  local cfg_timeouts = config.get().cli.timeouts or {}
  local timeout = opts.timeout or cfg_timeouts.default or 30000

  local cmd = type(M._executable) == "table" and { unpack(M._executable) } or { M._executable }
  for _, arg in ipairs(args) do
    table.insert(cmd, arg)
  end

  log.debug("CLI: %s", table.concat(cmd, " "))

  local result = vim.system(cmd, {
    text = true,
    stdin = opts.stdin,
    timeout = timeout,
  }):wait()

  -- Check for process errors
  if result.code ~= 0 then
    local err_msg = M._parse_error(result.stderr, result.code)
    log.debug("CLI error (exit %d): %s", result.code, err_msg)
    return nil, err_msg
  end

  -- Parse stdout as JSON
  local stdout = (result.stdout or ""):match("^%s*(.-)%s*$") -- trim
  if stdout == "" then
    return {}, nil
  end

  local ok, parsed = pcall(vim.json.decode, stdout)
  if not ok then
    return nil, "Failed to parse CLI output as JSON: " .. tostring(parsed)
  end

  return parsed, nil
end

--- Run a CLI command asynchronously.
--- Calls callback(err, result) when done.
---@param args string[] CLI arguments
---@param callback fun(err?: string, result?: table)
---@param opts? { stdin?: string, timeout?: number }
function M.run_async(args, callback, opts)
  opts = opts or {}
  local timeout = opts.timeout or 30000

  local cmd = type(M._executable) == "table" and { unpack(M._executable) } or { M._executable }
  for _, arg in ipairs(args) do
    table.insert(cmd, arg)
  end

  log.debug("CLI async: %s", table.concat(cmd, " "))

  vim.system(cmd, {
    text = true,
    stdin = opts.stdin,
    timeout = timeout,
  }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        local err_msg = M._parse_error(result.stderr, result.code)
        log.debug("CLI async error (exit %d): %s", result.code, err_msg)
        callback(err_msg)
        return
      end

      local stdout = (result.stdout or ""):match("^%s*(.-)%s*$")
      if stdout == "" then
        callback(nil, {})
        return
      end

      local ok, parsed = pcall(vim.json.decode, stdout)
      if not ok then
        callback("Failed to parse CLI output as JSON: " .. tostring(parsed))
        return
      end

      callback(nil, parsed)
    end)
  end)
end

-- ============================================================================
-- Session shape adapter (CLI v3 -> Lua flat shape)
-- ============================================================================

--- Convert a CLI v3 session JSON into the flat shape the Lua UI code expects.
--- The UI accesses fields like session.pr_id, session.pr_title, session.drafts (array),
--- session.threads (array), session.files, etc.
---@param cli_session table The raw v3 session JSON from CLI
---@return PowerReview.ReviewSession session The flat Lua session
function M.adapt_session(cli_session)
  -- If it's already in flat shape (e.g., from cache), return as-is
  if cli_session.pr_id and not cli_session.pull_request then
    return cli_session
  end

  local pr = cli_session.pull_request or {}
  local provider = cli_session.provider or {}
  local git = cli_session.git or {}
  local threads_info = cli_session.threads or {}
  local iteration = cli_session.iteration or {}
  local review = cli_session.review or {}

  -- Convert drafts from map {id -> draft} to array with id field
  local drafts = {}
  local raw_drafts = cli_session.drafts or {}
  for id, draft in pairs(raw_drafts) do
    draft.id = id
    table.insert(drafts, draft)
  end

  -- Sort drafts by created_at for consistent ordering
  table.sort(drafts, function(a, b)
    return (a.created_at or "") < (b.created_at or "")
  end)

  ---@type PowerReview.ReviewSession
  local session = {
    version = cli_session.version or 3,
    id = cli_session.id or "",
    pr_id = pr.id or 0,
    provider_type = provider.type or "azdo",
    org = provider.organization or "",
    project = provider.project or "",
    repo = provider.repository or "",
    pr_url = pr.url or "",
    pr_title = pr.title or "",
    pr_description = pr.description or "",
    pr_author = pr.author and pr.author.display_name or "",
    pr_status = pr.status or "active",
    pr_is_draft = pr.is_draft or false,
    pr_closed_at = pr.closed_at,
    source_branch = pr.source_branch or "",
    target_branch = pr.target_branch or "",
    merge_status = pr.merge_status,
    reviewers = pr.reviewers or {},
    labels = pr.labels or {},
    work_items = pr.work_items or {},
    iteration_id = iteration.iteration_id,
    source_commit = iteration.source_commit,
    target_commit = iteration.target_commit,
    reviewed_iteration_id = review.reviewed_iteration_id,
    reviewed_source_commit = review.reviewed_source_commit,
    reviewed_files = review.reviewed_files or {},
    changed_since_review = review.changed_since_review or {},
    worktree_path = git.worktree_path,
    git_strategy = git.strategy or "worktree",
    created_at = cli_session.created_at or "",
    updated_at = cli_session.updated_at or "",
    vote = M._vote_string_to_number(cli_session.vote),
    drafts = drafts,
    threads = threads_info.items or {},
    files = cli_session.files or {},
  }

  return session
end

-- ============================================================================
-- High-level CLI commands
-- ============================================================================

--- Open a review for a PR URL.
--- The CLI returns `{ session_file_path, session }`. The session_file_path is
--- attached to the adapted session as `_session_file_path` for the watcher.
---@param pr_url string
---@param repo_path? string
---@param callback fun(err?: string, session?: PowerReview.ReviewSession)
function M.open(pr_url, repo_path, callback)
  local args = { "open", "--pr-url", pr_url }
  if repo_path then
    table.insert(args, "--repo-path")
    table.insert(args, repo_path)
  end

  M.run_async(args, function(err, result)
    if err then
      callback(err)
      return
    end
    -- CLI wraps the response: { session_file_path: "...", session: { ... } }
    local session_file_path = result.session_file_path
    local raw_session = result.session or result
    local session = M.adapt_session(raw_session)
    session._session_file_path = session_file_path
    callback(nil, session)
  end, { timeout = config.get().cli.timeouts.open }) -- open can be slow (git fetch, API calls)
end

--- Get session info for a PR URL.
---@param pr_url string
---@param callback fun(err?: string, session?: PowerReview.ReviewSession)
function M.get_session(pr_url, callback)
  local args = { "session", "--pr-url", pr_url }

  M.run_async(args, function(err, result)
    if err then
      callback(err)
      return
    end
    -- Check if session was found
    if result.found == false then
      callback("No session found for this PR")
      return
    end
    callback(nil, M.adapt_session(result))
  end)
end

--- Get session info synchronously.
---@param pr_url string
---@return PowerReview.ReviewSession|nil session, string|nil error
function M.get_session_sync(pr_url)
  local result, err = M.run({ "session", "--pr-url", pr_url })
  if err then
    return nil, err
  end
  if result.found == false then
    return nil, "No session found for this PR"
  end
  return M.adapt_session(result), nil
end

--- Get the session file path.
---@param pr_url string
---@return string|nil path, string|nil error
function M.get_session_path(pr_url)
  local result, err = M.run({ "session", "--pr-url", pr_url, "--path-only" })
  if err then
    return nil, err
  end
  return result.path, nil
end

--- List changed files.
---@param pr_url string
---@return PowerReview.ChangedFile[]|nil files, string|nil error
function M.get_files(pr_url)
  return M.run({ "files", "--pr-url", pr_url })
end

--- Get diff info for a file.
---@param pr_url string
---@param file_path string
---@return table|nil diff_info, string|nil error
function M.get_file_diff(pr_url, file_path)
  return M.run({ "diff", "--pr-url", pr_url, "--file", file_path })
end

--- List comment threads.
---@param pr_url string
---@param file_path? string
---@return PowerReview.CommentThread[]|nil threads, string|nil error
function M.get_threads(pr_url, file_path)
  local args = { "threads", "--pr-url", pr_url }
  if file_path then
    table.insert(args, "--file")
    table.insert(args, file_path)
  end
  return M.run(args)
end

--- Create a draft comment.
---@param pr_url string
---@param opts table { file_path?: string, line_start?: number, line_end?: number, col_start?: number, col_end?: number, body: string, author?: string, thread_id?: number, parent_comment_id?: number }
---@return table|nil result { id: string, draft: table }, string|nil error
function M.create_draft(pr_url, opts)
  local args = { "comment", "create", "--pr-url", pr_url }
  if opts.file_path then
    table.insert(args, "--file")
    table.insert(args, opts.file_path)
  end
  if opts.line_start then
    table.insert(args, "--line-start")
    table.insert(args, tostring(opts.line_start))
  end
  if opts.line_end then
    table.insert(args, "--line-end")
    table.insert(args, tostring(opts.line_end))
  end
  if opts.col_start then
    table.insert(args, "--col-start")
    table.insert(args, tostring(opts.col_start))
  end
  if opts.col_end then
    table.insert(args, "--col-end")
    table.insert(args, tostring(opts.col_end))
  end
  if opts.author then
    table.insert(args, "--author")
    table.insert(args, opts.author)
  end
  if opts.thread_id then
    table.insert(args, "--thread-id")
    table.insert(args, tostring(opts.thread_id))
  end
  if opts.parent_comment_id then
    table.insert(args, "--parent-comment-id")
    table.insert(args, tostring(opts.parent_comment_id))
  end
  -- Use stdin for body to handle multi-line
  table.insert(args, "--body-stdin")
  return M.run(args, { stdin = opts.body or "" })
end

--- Edit a draft comment.
---@param pr_url string
---@param draft_id string
---@param new_body string
---@return table|nil result, string|nil error
function M.edit_draft(pr_url, draft_id, new_body)
  local args = { "comment", "edit", "--pr-url", pr_url, "--draft-id", draft_id, "--body-stdin" }
  return M.run(args, { stdin = new_body })
end

--- Delete a draft comment.
---@param pr_url string
---@param draft_id string
---@return table|nil result, string|nil error
function M.delete_draft(pr_url, draft_id)
  return M.run({ "comment", "delete", "--pr-url", pr_url, "--draft-id", draft_id })
end

--- Approve a draft comment.
---@param pr_url string
---@param draft_id string
---@return table|nil result, string|nil error
function M.approve_draft(pr_url, draft_id)
  return M.run({ "comment", "approve", "--pr-url", pr_url, "--draft-id", draft_id })
end

--- Approve all drafts.
---@param pr_url string
---@return table|nil result { approved: number }, string|nil error
function M.approve_all_drafts(pr_url)
  return M.run({ "comment", "approve-all", "--pr-url", pr_url })
end

--- Unapprove a draft comment.
---@param pr_url string
---@param draft_id string
---@return table|nil result, string|nil error
function M.unapprove_draft(pr_url, draft_id)
  return M.run({ "comment", "unapprove", "--pr-url", pr_url, "--draft-id", draft_id })
end

--- Create a reply draft to an existing thread.
---@param pr_url string
---@param thread_id number
---@param body string
---@param author? string
---@return table|nil result, string|nil error
function M.reply_to_thread(pr_url, thread_id, body, author)
  local args = { "reply", "--pr-url", pr_url, "--thread-id", tostring(thread_id), "--body-stdin" }
  if author then
    table.insert(args, "--author")
    table.insert(args, author)
  end
  return M.run(args, { stdin = body })
end

--- Submit all pending drafts.
---@param pr_url string
---@param callback fun(err?: string, result?: PowerReview.SubmitResult)
function M.submit(pr_url, callback)
  M.run_async({ "submit", "--pr-url", pr_url }, function(err, result)
    if err then
      callback(err)
      return
    end
    callback(nil, result)
  end, { timeout = config.get().cli.timeouts.submit })
end

--- Set the review vote.
---@param pr_url string
---@param vote_value string Vote string: "approve", "approve-with-suggestions", "no-vote", "wait-for-author", "reject"
---@param callback fun(err?: string)
function M.vote(pr_url, vote_value, callback)
  M.run_async({ "vote", "--pr-url", pr_url, "--value", vote_value }, function(err, _result)
    callback(err)
  end, { timeout = config.get().cli.timeouts.vote })
end

--- Sync remote threads.
---@param pr_url string
---@param callback fun(err?: string, result?: { thread_count: number, iteration_check?: table })
function M.sync(pr_url, callback)
  M.run_async({ "sync", "--pr-url", pr_url }, function(err, result)
    if err then
      callback(err)
      return
    end
    callback(nil, result)
  end, { timeout = config.get().cli.timeouts.sync })
end

--- Close a review session.
---@param pr_url string
---@param callback fun(err?: string)
function M.close(pr_url, callback)
  M.run_async({ "close", "--pr-url", pr_url }, function(err, _result)
    callback(err)
  end)
end

-- ============================================================================
-- Iteration tracking commands
-- ============================================================================

--- Mark a file as reviewed.
---@param pr_url string
---@param file_path string
---@return table|nil result, string|nil error
function M.mark_reviewed(pr_url, file_path)
  return M.run({ "mark-reviewed", "--pr-url", pr_url, "--file", file_path })
end

--- Mark a file as reviewed (async).
---@param pr_url string
---@param file_path string
---@param callback fun(err?: string, result?: table)
function M.mark_reviewed_async(pr_url, file_path, callback)
  M.run_async({ "mark-reviewed", "--pr-url", pr_url, "--file", file_path }, function(err, result)
    if err then
      callback(err)
      return
    end
    callback(nil, result)
  end)
end

--- Unmark a file as reviewed.
---@param pr_url string
---@param file_path string
---@return table|nil result, string|nil error
function M.unmark_reviewed(pr_url, file_path)
  return M.run({ "unmark-reviewed", "--pr-url", pr_url, "--file", file_path })
end

--- Unmark a file as reviewed (async).
---@param pr_url string
---@param file_path string
---@param callback fun(err?: string, result?: table)
function M.unmark_reviewed_async(pr_url, file_path, callback)
  M.run_async({ "unmark-reviewed", "--pr-url", pr_url, "--file", file_path }, function(err, result)
    if err then
      callback(err)
      return
    end
    callback(nil, result)
  end)
end

--- Mark all files as reviewed.
---@param pr_url string
---@return table|nil result, string|nil error
function M.mark_all_reviewed(pr_url)
  return M.run({ "mark-all-reviewed", "--pr-url", pr_url })
end

--- Mark all files as reviewed (async).
---@param pr_url string
---@param callback fun(err?: string, result?: table)
function M.mark_all_reviewed_async(pr_url, callback)
  M.run_async({ "mark-all-reviewed", "--pr-url", pr_url }, function(err, result)
    if err then
      callback(err)
      return
    end
    callback(nil, result)
  end)
end

--- Check for new iterations from the remote.
---@param pr_url string
---@param callback fun(err?: string, result?: table)
function M.check_iteration(pr_url, callback)
  M.run_async({ "check-iteration", "--pr-url", pr_url }, function(err, result)
    if err then
      callback(err)
      return
    end
    callback(nil, result)
  end, { timeout = config.get().cli.timeouts.sync })
end

--- Get iteration diff for a specific file.
---@param pr_url string
---@param file_path string
---@return table|nil result { file: string, diff: string }, string|nil error
function M.get_iteration_diff(pr_url, file_path)
  return M.run({ "iteration-diff", "--pr-url", pr_url, "--file", file_path })
end

--- Update the status of a remote comment thread.
---@param pr_url string
---@param thread_id number
---@param status string Thread status: "active", "fixed", "wontfix", "closed", "bydesign", "pending"
---@param callback fun(err?: string, result?: table)
function M.update_thread_status(pr_url, thread_id, status, callback)
  M.run_async({
    "thread-status",
    "--pr-url", pr_url,
    "--thread-id", tostring(thread_id),
    "--status", status,
  }, function(err, result)
    if err then
      callback(err)
      return
    end
    callback(nil, result)
  end)
end

--- List all saved sessions.
---@return PowerReview.SessionSummary[]|nil summaries, string|nil error
function M.list_sessions()
  local result, err = M.run({ "sessions", "list" })
  if err then
    return nil, err
  end
  return M._adapt_session_summaries(result), nil
end

--- List all saved sessions asynchronously.
---@param callback fun(err?: string, summaries?: PowerReview.SessionSummary[])
function M.list_sessions_async(callback)
  M.run_async({ "sessions", "list" }, function(err, result)
    if err then
      callback(err)
      return
    end
    callback(nil, M._adapt_session_summaries(result))
  end)
end

--- Adapt raw CLI session list JSON into SessionSummary array.
---@param result table[] Raw CLI output
---@return PowerReview.SessionSummary[]
function M._adapt_session_summaries(result)
  -- The CLI returns an array of session summaries
  -- Adapt field names: the CLI uses nested structure but sessions list is flat
  local summaries = {}
  for _, s in ipairs(result) do
    table.insert(summaries, {
      id = s.id or "",
      pr_id = s.pull_request and s.pull_request.id or s.pr_id or 0,
      pr_title = s.pull_request and s.pull_request.title or s.pr_title or "",
      pr_url = s.pull_request and s.pull_request.url or s.pr_url or "",
      pr_status = s.pull_request and s.pull_request.status or s.pr_status,
      provider_type = s.provider and s.provider.type or s.provider_type or "azdo",
      org = s.provider and s.provider.organization or s.org or "",
      project = s.provider and s.provider.project or s.project or "",
      repo = s.provider and s.provider.repository or s.repo or "",
      draft_count = s.draft_count or 0,
      created_at = s.created_at or "",
      updated_at = s.updated_at or "",
    })
  end
  return summaries
end

--- Delete a specific session.
---@param session_id string
---@return boolean success, string|nil error
function M.delete_session(session_id)
  local result, err = M.run({ "sessions", "delete", "--session-id", session_id })
  if err then
    return false, err
  end
  return result.deleted or false, nil
end

--- Clean all sessions.
---@return number|nil count, string|nil error
function M.clean_sessions()
  local result, err = M.run({ "sessions", "clean" })
  if err then
    return nil, err
  end
  return result.cleaned or 0, nil
end

-- ============================================================================
-- Helpers
-- ============================================================================

--- Parse error output from CLI stderr.
---@param stderr string|nil
---@param exit_code number
---@return string
function M._parse_error(stderr, exit_code)
  if not stderr or stderr == "" then
    return string.format("CLI exited with code %d", exit_code)
  end

  -- Try to parse as JSON error
  local ok, parsed = pcall(vim.json.decode, stderr:match("^%s*(.-)%s*$"))
  if ok and parsed and parsed.error then
    return parsed.error
  end

  -- Fall back to raw stderr
  return stderr:match("^%s*(.-)%s*$") or string.format("CLI exited with code %d", exit_code)
end

--- Reload the current session from CLI.
--- This is called after mutations to refresh the in-memory session.
---@param pr_url string
---@return PowerReview.ReviewSession|nil session, string|nil error
function M.reload_session(pr_url)
  return M.get_session_sync(pr_url)
end

--- Map numeric vote value to CLI vote string.
---@param vote_value number
---@return string
function M.vote_value_to_string(vote_value)
  local map = {
    [10] = "approve",
    [5] = "approve-with-suggestions",
    [0] = "no-vote",
    [-5] = "wait-for-author",
    [-10] = "reject",
  }
  return map[vote_value] or "no-vote"
end

--- Map CLI vote string to numeric value.
--- The CLI outputs vote as a string enum (e.g., "Approve", "NoVote").
--- The Lua UI code expects numeric values (10, 5, 0, -5, -10).
---@param vote_str string|nil
---@return PowerReview.ReviewVote|nil
function M._vote_string_to_number(vote_str)
  if not vote_str or vote_str == "" then
    return nil
  end
  -- Normalize: lowercase for case-insensitive matching
  local normalized = vote_str:lower():gsub("[_%-]", "")
  local map = {
    approve = 10,
    approved = 10,
    approvewithsuggestions = 5,
    approvedwithsuggestions = 5,
    novote = 0,
    none = 0,
    waitforauthor = -5,
    reject = -10,
    rejected = -10,
  }
  local value = map[normalized]
  if value ~= nil then
    return value
  end
  -- Try parsing as a number (in case CLI sends numeric)
  local num = tonumber(vote_str)
  if num then
    return num
  end
  return nil
end

return M
