--- PowerReview.nvim review lifecycle coordinator
--- Orchestrates the full review flow: parse URL -> auth -> fetch PR -> git setup -> session
local M = {}

local log = require("power-review.utils.log")
local url_util = require("power-review.utils.url")
local auth = require("power-review.auth")
local providers = require("power-review.providers")
local git = require("power-review.git")
local session_mod = require("power-review.review.session")
local store = require("power-review.store")
local config = require("power-review.config")

--- Currently active provider instance (for making API calls during a session)
---@type PowerReview.Provider|nil
M._provider = nil

--- Start a new review from a PR URL.
--- This is the main entry point for the full review flow:
--- 1. Parse the URL
--- 2. Resolve provider config (from URL or per-repo config or user prompt)
--- 3. Authenticate
--- 4. Fetch PR metadata + changed files + threads
--- 5. Setup git (worktree or checkout)
--- 6. Create and persist a ReviewSession
--- 7. Set the session as current
---
---@param pr_url string The PR URL
---@param callback fun(err?: string, session?: PowerReview.ReviewSession)
function M.start_review(pr_url, callback)
  log.info("Starting review for: %s", pr_url)

  -- Step 1: Parse the URL
  local parsed, parse_err = url_util.parse(pr_url)
  if not parsed then
    -- URL parsing failed; try to resolve from per-repo config + prompt
    M._start_with_manual_input(pr_url, callback)
    return
  end

  -- Step 2: Authenticate
  auth.get_token(parsed.provider_type, function(auth_err, auth_header)
    if auth_err then
      callback("Authentication failed: " .. auth_err)
      return
    end

    -- Step 3: Create provider
    local provider, prov_err = providers.create(parsed.provider_type, {
      organization = parsed.organization,
      project = parsed.project,
      repository = parsed.repository,
      auth_header = auth_header,
    })

    if not provider then
      callback("Failed to create provider: " .. (prov_err or "unknown"))
      return
    end

    M._provider = provider

    -- Step 4: Fetch PR metadata
    provider:get_pull_request(parsed.pr_id, function(pr_err, pr)
      if pr_err then
        callback("Failed to fetch PR: " .. pr_err)
        return
      end

      -- Step 5: Fetch changed files
      provider:get_changed_files(parsed.pr_id, function(files_err, files, iter_meta)
        if files_err then
          callback("Failed to fetch changed files: " .. files_err)
          return
        end

        -- Step 5b: Fetch remote comment threads
        provider:get_threads(parsed.pr_id, function(threads_err, threads)
          -- Threads are non-critical; log warning but continue
          if threads_err then
            log.warn("Failed to fetch remote threads: %s", threads_err)
            threads = {}
          end

          -- Step 6: Setup git
          M._setup_git(pr, parsed, function(git_err, git_result)
            if git_err then
              callback("Git setup failed: " .. git_err)
              return
            end

            -- Step 7: Create session
            local git_cfg = config.get_git_config()
            local reused_main = git_result and git_result.reused_main or false
            local session = session_mod.new({
              pr_id = pr.id,
              provider_type = parsed.provider_type,
              org = parsed.organization,
              project = parsed.project,
              repo = parsed.repository,
              pr_url = pr_url,
              pr_title = pr.title,
              pr_description = pr.description,
              pr_author = pr.author,
              pr_status = pr.status,
              pr_is_draft = pr.is_draft,
              pr_closed_at = pr.closed_at,
              merge_status = pr.merge_status,
              reviewers = pr.reviewers,
              labels = pr.labels,
              work_items = pr.work_items,
              source_branch = pr.source_branch,
              target_branch = pr.target_branch,
              worktree_path = git_result and git_result.worktree_path or nil,
              git_strategy = reused_main and "reused_main" or (git_cfg.strategy or "worktree"),
              files = files or {},
              iteration_id = iter_meta and iter_meta.iteration_id or nil,
              source_commit = iter_meta and iter_meta.source_commit or nil,
              target_commit = iter_meta and iter_meta.target_commit or nil,
            })

            -- Store remote threads on the session
            session_mod.set_threads(session, threads or {})

            -- Check if there's an existing session for this PR (resume drafts)
            local existing, _ = store.load(session.id)
            if existing and existing.drafts and #existing.drafts > 0 then
              -- Merge existing drafts into new session
              session.drafts = existing.drafts
              log.info("Resumed %d existing draft(s) from previous session", #existing.drafts)
            end

            -- Save session
            local save_ok, save_err = store.save(session)
            if not save_ok then
              log.warn("Failed to save session: %s", save_err or "")
            end

            -- Set as current session
            local pr_mod = require("power-review")
            pr_mod._set_current_session(session)

            -- Write MCP server info for external MCP server connection
            local mcp_cfg = config.get().mcp
            if mcp_cfg and mcp_cfg.enabled then
              local mcp = require("power-review.mcp")
              mcp.write_server_info(true, session.pr_id)
            end

            -- Navigate to the worktree or repo
            M._navigate_to_review(session, git_result)

            -- Refresh neo-tree source if visible
            require("power-review.ui").refresh_neotree()

            log.info("Review session started: %s (PR #%d: %s) — %d remote threads",
              session.id, session.pr_id, session.pr_title, #(session.threads or {}))
            callback(nil, session)
          end)
        end)
      end)
    end)
  end)
end

--- Resume a saved review session
---@param session_id string
---@param callback fun(err?: string, session?: PowerReview.ReviewSession)
function M.resume_session(session_id, callback)
  local session, load_err = store.load(session_id)
  if not session then
    callback("Failed to load session: " .. (load_err or "unknown"))
    return
  end

  -- Re-authenticate
  auth.get_token(session.provider_type, function(auth_err, auth_header)
    if auth_err then
      callback("Authentication failed: " .. auth_err)
      return
    end

    -- Recreate provider
    local provider, prov_err = providers.create(session.provider_type, {
      organization = session.org,
      project = session.project,
      repository = session.repo,
      auth_header = auth_header,
    })

    if not provider then
      callback("Failed to create provider: " .. (prov_err or "unknown"))
      return
    end

    M._provider = provider

    -- Set as current session
    local pr_mod = require("power-review")
    pr_mod._set_current_session(session)

    -- Write MCP server info for external MCP server connection
    local mcp_cfg = config.get().mcp
    if mcp_cfg and mcp_cfg.enabled then
      local mcp = require("power-review.mcp")
      mcp.write_server_info(true, session.pr_id)
    end

    -- Navigate to review location
    if session.worktree_path and vim.fn.isdirectory(session.worktree_path) == 1 then
      vim.cmd("tcd " .. vim.fn.fnameescape(session.worktree_path))
      log.info("Navigated to worktree: %s", session.worktree_path)
    end

    -- Ensure session has threads field (backward compat with older saved sessions)
    if not session.threads then
      session.threads = {}
    end

    -- Background sync: fetch latest remote threads
    provider:get_threads(session.pr_id, function(threads_err, threads)
      if threads_err then
        log.warn("Background thread sync failed: %s", threads_err)
      else
        session_mod.set_threads(session, threads or {})
        store.save(session)
        -- Refresh signs and comments panel
        require("power-review.ui.signs").refresh()
        local comments_panel = require("power-review.ui.comments_panel")
        if comments_panel.is_visible() then
          comments_panel.refresh(session)
        end
        log.info("Background sync: %d remote thread(s)", #(session.threads or {}))
      end
    end)

    log.info("Resumed session: %s (PR #%d: %s)", session.id, session.pr_id, session.pr_title)
    callback(nil, session)
  end)
end

--- Close the current review session
---@param callback fun(err?: string)
function M.close_review(callback)
  local pr_mod = require("power-review")
  local session = pr_mod.get_current_session()

  if not session then
    callback("No active review session")
    return
  end

  -- Save current state before closing
  store.save(session)

  -- Teardown all UI elements (comments panel, diff tabs, signs, neo-tree, floats)
  local ui = require("power-review.ui")
  pcall(ui.teardown_all)

  -- Clear MCP server info
  local mcp_cfg = config.get().mcp
  if mcp_cfg and mcp_cfg.enabled then
    local mcp = require("power-review.mcp")
    mcp.clear_server_info()
  end

  -- Cleanup git state
  local git_cfg = config.get_git_config()
  if git_cfg.cleanup_on_close then
    git.cleanup(session, function(cleanup_err)
      if cleanup_err then
        log.warn("Git cleanup warning: %s", cleanup_err)
      end

      pr_mod._set_current_session(nil)
      M._provider = nil
      log.info("Review session closed: %s", session.id)
      callback(nil)
    end)
  else
    pr_mod._set_current_session(nil)
    M._provider = nil
    log.info("Review session closed (worktree preserved): %s", session.id)
    callback(nil)
  end
end

--- Refresh the current session (re-fetch PR data from remote)
---@param callback fun(err?: string)
function M.refresh_session(callback)
  local pr_mod = require("power-review")
  local session = pr_mod.get_current_session()

  if not session then
    callback("No active review session")
    return
  end

  if not M._provider then
    callback("No provider available. Try reopening the review.")
    return
  end

  -- Refresh PR metadata
  M._provider:get_pull_request(session.pr_id, function(pr_err, pr)
    if pr_err then
      log.warn("Failed to refresh PR metadata: %s", pr_err)
      -- Continue even if metadata refresh fails
    else
      -- Update mutable PR metadata on the session
      session.pr_title = pr.title
      session.pr_description = pr.description
      session.pr_status = pr.status
      session.pr_is_draft = pr.is_draft
      session.pr_closed_at = pr.closed_at
      session.merge_status = pr.merge_status
      session.reviewers = pr.reviewers
      session.labels = pr.labels
      session.work_items = pr.work_items
    end

    -- Refresh changed files
    M._provider:get_changed_files(session.pr_id, function(files_err, files, iter_meta)
      if files_err then
        callback("Failed to refresh files: " .. files_err)
        return
      end

      session.files = files or session.files
      if iter_meta then
        session.iteration_id = iter_meta.iteration_id
        session.source_commit = iter_meta.source_commit
        session.target_commit = iter_meta.target_commit
      end

      -- Also refresh remote threads
      M._provider:get_threads(session.pr_id, function(threads_err, threads)
        if threads_err then
          log.warn("Failed to refresh remote threads: %s", threads_err)
          -- Continue even if threads fail -- files were updated successfully
        else
          session_mod.set_threads(session, threads or {})
          -- Refresh signs on diff buffers to show new remote comments
          require("power-review.ui.signs").refresh()
        end

        store.save(session)
        -- Refresh neo-tree to show updated file list
        require("power-review.ui").refresh_neotree()
        -- Refresh comments panel if visible
        local comments_panel = require("power-review.ui.comments_panel")
        if comments_panel.is_visible() then
          comments_panel.refresh(session)
        end

        local thread_count = session.threads and #session.threads or 0
        log.info("Session refreshed: %d files, %d remote threads", #session.files, thread_count)
        callback(nil)
      end)
    end)
  end)
end

--- Get file diff content via the active provider
---@param session PowerReview.ReviewSession
---@param file_path string
---@return string|nil diff_content, string|nil error
function M.get_file_diff(session, file_path)
  -- This is a synchronous wrapper; for the full diff we'd need the provider
  -- For now, return a placeholder. The actual diff view uses codediff.nvim
  -- which works on the git worktree files directly.
  return nil, "Use the diff view (codediff.nvim) for file diffs"
end

--- Get all comment threads (remote + local drafts formatted as threads)
---@param session PowerReview.ReviewSession
---@return table threads
function M.get_all_threads(session)
  local threads = {}

  -- 1. Remote threads from session cache
  local remote_threads = session_mod.get_threads(session)
  for _, thread in ipairs(remote_threads) do
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
  for _, draft in ipairs(session.drafts) do
    local key = draft.file_path .. ":" .. tostring(draft.line_start)
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

--- Get threads for a specific file
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

--- Submit all pending draft comments to the remote provider.
--- Provides progress reporting via the callback and progress_cb.
---@param session PowerReview.ReviewSession
---@param callback fun(err?: string, result?: PowerReview.SubmitResult)
---@param progress_cb? fun(current: number, total: number, draft: PowerReview.DraftComment)
function M.submit_pending(session, callback, progress_cb)
  if not M._provider then
    callback("No provider available")
    return
  end

  local pending = session_mod.get_pending_drafts(session)
  if #pending == 0 then
    callback(nil, { submitted = 0, failed = 0, errors = {}, total = 0 })
    return
  end

  local submitted = 0
  local failed_drafts = {} ---@type { draft: PowerReview.DraftComment, error: string }[]
  local remaining = #pending
  local total = #pending

  for idx, draft in ipairs(pending) do
    -- Report progress
    if progress_cb then
      progress_cb(idx, total, draft)
    end

    if draft.thread_id then
      -- Reply to existing thread
      M._provider:reply_to_thread(session.pr_id, draft.thread_id, draft.body, function(err, _comment)
        remaining = remaining - 1
        if err then
          table.insert(failed_drafts, {
            draft = draft,
            error = string.format("Reply to thread %d failed: %s", draft.thread_id, err),
          })
        else
          session_mod.mark_submitted(session, draft.id)
          submitted = submitted + 1
        end
        if remaining == 0 then
          store.save(session)
          local result = {
            submitted = submitted,
            failed = #failed_drafts,
            total = total,
            errors = failed_drafts,
          }
          if #failed_drafts > 0 then
            local err_msgs = {}
            for _, f in ipairs(failed_drafts) do
              table.insert(err_msgs, f.error)
            end
            callback(table.concat(err_msgs, "; "), result)
          else
            callback(nil, result)
          end
        end
      end)
    else
      -- Create new thread
      local thread_data = {
        file_path = draft.file_path,
        line_start = draft.line_start,
        line_end = draft.line_end,
        col_start = draft.col_start,
        col_end = draft.col_end,
        body = draft.body,
        status = "active",
      }
      M._provider:create_thread(session.pr_id, thread_data, function(err, _thread)
        remaining = remaining - 1
        if err then
          table.insert(failed_drafts, {
            draft = draft,
            error = string.format("Create thread on %s:%d failed: %s", draft.file_path, draft.line_start, err),
          })
        else
          session_mod.mark_submitted(session, draft.id)
          submitted = submitted + 1
        end
        if remaining == 0 then
          store.save(session)
          local result = {
            submitted = submitted,
            failed = #failed_drafts,
            total = total,
            errors = failed_drafts,
          }
          if #failed_drafts > 0 then
            local err_msgs = {}
            for _, f in ipairs(failed_drafts) do
              table.insert(err_msgs, f.error)
            end
            callback(table.concat(err_msgs, "; "), result)
          else
            callback(nil, result)
          end
        end
      end)
    end
  end
end

--- Retry submitting failed drafts.
--- Takes the failed_drafts from a previous submit result, reverts them to pending,
--- and resubmits.
---@param session PowerReview.ReviewSession
---@param failed_drafts table[] Array of { draft: PowerReview.DraftComment, error: string }
---@param callback fun(err?: string, result?: PowerReview.SubmitResult)
function M.retry_failed_submissions(session, failed_drafts, callback)
  -- Revert failed drafts back to pending status
  for _, f in ipairs(failed_drafts) do
    for _, d in ipairs(session.drafts) do
      if d.id == f.draft.id and d.status ~= "submitted" then
        d.status = "pending"
      end
    end
  end
  store.save(session)
  M.submit_pending(session, callback)
end

--- Set the review vote on the PR
---@param session PowerReview.ReviewSession
---@param vote PowerReview.ReviewVote
---@param callback fun(err?: string, ok?: boolean)
function M.set_vote(session, vote, callback)
  if not M._provider then
    callback("No provider available")
    return
  end

  -- Need the current user's reviewer ID
  if session.provider_type == "azdo" then
    ---@type PowerReview.AzDOProvider
    local azdo_provider = M._provider
    azdo_provider:get_current_reviewer_id(session.pr_id, function(id_err, reviewer_id)
      if id_err then
        callback("Failed to get reviewer ID: " .. id_err)
        return
      end

      M._provider:set_vote(session.pr_id, reviewer_id, vote, function(vote_err, ok)
        if vote_err then
          callback("Failed to set vote: " .. vote_err)
          return
        end
        session.vote = vote
        store.save(session)
        callback(nil, ok)
      end)
    end)
  else
    callback("Vote not yet supported for provider: " .. session.provider_type)
  end
end

--- Sync remote comment threads only (lighter than full refresh).
--- Fetches threads from the remote provider and updates the session cache,
--- then refreshes signs and comment panels.
---@param callback fun(err?: string, thread_count?: number)
function M.sync_threads(callback)
  local pr_mod = require("power-review")
  local session = pr_mod.get_current_session()

  if not session then
    callback("No active review session")
    return
  end

  if not M._provider then
    callback("No provider available. Try reopening the review.")
    return
  end

  M._provider:get_threads(session.pr_id, function(threads_err, threads)
    if threads_err then
      callback("Failed to sync threads: " .. threads_err)
      return
    end

    session_mod.set_threads(session, threads or {})
    store.save(session)

    -- Refresh signs on diff buffers
    require("power-review.ui.signs").refresh()

    -- Refresh comments panel if visible
    local comments_panel = require("power-review.ui.comments_panel")
    if comments_panel.is_visible() then
      comments_panel.refresh(session)
    end

    local thread_count = #(session.threads or {})
    log.info("Synced %d remote thread(s)", thread_count)
    callback(nil, thread_count)
  end)
end

--- Get the current active provider
---@return PowerReview.Provider|nil
function M.get_provider()
  return M._provider
end

-- ===== Internal helpers =====

--- Setup git for the review (fetch branch, create worktree or checkout)
---@param pr PowerReview.PR
---@param parsed PowerReview.ParsedUrl
---@param callback fun(err?: string, result?: table)
function M._setup_git(pr, parsed, callback)
  -- Find the repo root. Try current directory first, then prompt.
  git.get_current_repo_root(function(root_err, repo_root)
    if root_err then
      -- Not in a git repo - user might need to clone first
      callback("Not in a git repository. Please navigate to the repository first.")
      return
    end

    git.setup_for_review({
      repo_root = repo_root,
      source_branch = pr.source_branch,
      pr_id = pr.id,
    }, callback)
  end)
end

--- Navigate to the review location (worktree or repo root)
---@param session PowerReview.ReviewSession
---@param git_result? table
function M._navigate_to_review(session, git_result)
  if git_result and git_result.worktree_path then
    -- Use tcd to scope the tab to the worktree
    vim.cmd("tcd " .. vim.fn.fnameescape(git_result.worktree_path))
    log.info("Working directory set to worktree: %s", git_result.worktree_path)
  end
end

--- Handle manual input when URL parsing fails
---@param pr_url string
---@param callback fun(err?: string, session?: PowerReview.ReviewSession)
function M._start_with_manual_input(pr_url, callback)
  -- Try to detect provider from URL
  local provider_type = url_util.detect_provider(pr_url)

  if not provider_type then
    -- Check per-repo config
    git.get_current_repo_root(function(root_err, repo_root)
      if root_err then
        callback("Cannot determine provider. Not in a git repo and URL is not recognized.")
        return
      end

      local repo_config = config.get_repo_config(repo_root)
      if repo_config then
        provider_type = repo_config.provider
        M._prompt_for_pr_id(provider_type, repo_config, callback)
      else
        -- Prompt user to select provider
        vim.ui.select({ "azdo", "github" }, {
          prompt = "Select PR provider:",
        }, function(selected)
          if not selected then
            callback("Cancelled")
            return
          end
          M._prompt_for_details(selected, callback)
        end)
      end
    end)
    return
  end

  callback("Could not parse PR URL. Please provide a valid Azure DevOps or GitHub PR URL.")
end

--- Prompt user for PR ID when we have repo config but no parseable URL
---@param provider_type PowerReview.ProviderType
---@param repo_config PowerReview.RepoConfig
---@param callback fun(err?: string, session?: PowerReview.ReviewSession)
function M._prompt_for_pr_id(provider_type, repo_config, callback)
  vim.ui.input({ prompt = "Enter PR ID: " }, function(input)
    if not input or input == "" then
      callback("Cancelled")
      return
    end

    local pr_id = tonumber(input)
    if not pr_id then
      callback("Invalid PR ID: " .. input)
      return
    end

    -- Build a synthetic URL and restart
    if provider_type == "azdo" and repo_config.azdo then
      local url = string.format(
        "https://dev.azure.com/%s/%s/_git/%s/pullrequest/%d",
        repo_config.azdo.organization,
        repo_config.azdo.project,
        repo_config.azdo.repository,
        pr_id
      )
      M.start_review(url, callback)
    else
      callback("Cannot construct URL for provider: " .. tostring(provider_type))
    end
  end)
end

--- Prompt user for full provider details
---@param provider_type PowerReview.ProviderType
---@param callback fun(err?: string, session?: PowerReview.ReviewSession)
function M._prompt_for_details(provider_type, callback)
  if provider_type == "azdo" then
    vim.ui.input({ prompt = "Organization: " }, function(org)
      if not org or org == "" then callback("Cancelled") return end
      vim.ui.input({ prompt = "Project: " }, function(project)
        if not project or project == "" then callback("Cancelled") return end
        vim.ui.input({ prompt = "Repository: " }, function(repo)
          if not repo or repo == "" then callback("Cancelled") return end
          vim.ui.input({ prompt = "PR ID: " }, function(pr_id_str)
            if not pr_id_str or pr_id_str == "" then callback("Cancelled") return end
            local pr_id = tonumber(pr_id_str)
            if not pr_id then callback("Invalid PR ID") return end

            local url = string.format(
              "https://dev.azure.com/%s/%s/_git/%s/pullrequest/%d",
              org, project, repo, pr_id
            )
            M.start_review(url, callback)
          end)
        end)
      end)
    end)
  else
    callback("Manual input not yet supported for: " .. provider_type)
  end
end

return M
