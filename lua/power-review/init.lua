--- PowerReview.nvim - PR Review plugin for Neovim
--- Main entry point and public API
--- All business logic delegates to the `powerreview` CLI tool.
local M = {}

local config = require("power-review.config")

---@type PowerReview.ReviewSession|nil
M._current_session = nil

--- Setup the plugin with user configuration
---@param opts? table User configuration (see config.lua for schema)
function M.setup(opts)
  config.setup(opts)

  -- Configure CLI bridge
  local cli = require("power-review.cli")
  local cli_cfg = config.get().cli or {}
  cli.configure({ executable = cli_cfg.executable })

  -- Initialize UI subsystems that need early setup
  local signs = require("power-review.ui.signs")
  signs.setup()

  -- Register global keymaps
  M.setup_keymaps()
end

--- Register global keymaps from config.keymaps.
--- Keymaps set to nil or false are skipped (allows users to disable defaults).
function M.setup_keymaps()
  local keymaps = config.get_keymaps()
  if not keymaps then
    return
  end

  local ui = require("power-review.ui")
  local review = require("power-review.review")

  local function map(mode, lhs, rhs, desc)
    if lhs and lhs ~= false then
      vim.keymap.set(mode, lhs, rhs, { silent = true, desc = "[PowerReview] " .. desc })
    end
  end

  -- Open review: prompt for URL or pick from saved sessions
  map("n", keymaps.open_review, function()
    review.open_or_resume(nil, function(err, session)
      if err then
        vim.notify("[PowerReview] " .. err, vim.log.levels.ERROR)
      elseif session then
        vim.notify("[PowerReview] Review started: " .. session.pr_title, vim.log.levels.INFO)
      end
    end)
  end, "Open/resume review")

  -- List saved sessions
  map("n", keymaps.list_sessions, function()
    vim.cmd("PowerReview list")
  end, "List review sessions")

  -- Toggle files panel
  map("n", keymaps.toggle_files, function()
    ui.toggle_files()
  end, "Toggle files panel")

  -- Toggle all-comments panel
  map("n", keymaps.toggle_comments, function()
    ui.toggle_comments()
  end, "Toggle comments panel")

  -- Next/prev comment navigation
  map("n", keymaps.next_comment, function()
    ui.goto_next_comment()
  end, "Next comment")

  map("n", keymaps.prev_comment, function()
    ui.goto_prev_comment()
  end, "Previous comment")

  -- Add comment (normal mode: current line)
  map("n", keymaps.add_comment, function()
    ui.add_comment()
  end, "Add comment at cursor")

  -- Add comment (visual mode: selected range)
  map("v", keymaps.add_comment, function()
    -- Exit visual mode first so '< '> marks are set, then invoke
    vim.cmd("normal! " .. vim.api.nvim_replace_termcodes("<Esc>", true, false, true))
    ui.add_comment({ visual = true })
  end, "Add comment on selection")

  -- Reply to thread at cursor
  map("n", keymaps.reply_comment, function()
    ui.open_thread_at_cursor()
  end, "Reply to thread at cursor")

  -- Edit draft at cursor
  map("n", keymaps.edit_comment, function()
    ui.edit_comment_at_cursor()
  end, "Edit draft at cursor")

  -- Approve draft at cursor
  map("n", keymaps.approve_comment, function()
    ui.approve_comment_at_cursor()
  end, "Approve draft at cursor")

  -- Unapprove pending draft at cursor
  map("n", keymaps.unapprove_comment, function()
    ui.unapprove_comment_at_cursor()
  end, "Unapprove draft at cursor")

  -- Delete draft at cursor
  map("n", keymaps.delete_comment, function()
    ui.delete_comment_at_cursor()
  end, "Delete draft at cursor")

  -- Submit all pending
  map("n", keymaps.submit_all, function()
    vim.cmd("PowerReview submit")
  end, "Submit pending comments")

  -- Set vote
  map("n", keymaps.set_vote, function()
    ui.set_vote()
  end, "Set review vote")

  -- Sync remote threads
  map("n", keymaps.sync_threads, function()
    vim.cmd("PowerReview sync")
  end, "Sync remote comment threads")

  -- Close review session
  map("n", keymaps.close_review, function()
    vim.cmd("PowerReview close")
  end, "Close review session")

  -- Delete a saved review session
  map("n", keymaps.delete_session, function()
    vim.cmd("PowerReview delete")
  end, "Delete saved review session")

  -- Resolve / change thread status at cursor
  map("n", keymaps.resolve_thread, function()
    if not M.get_current_session() then
      vim.notify("[PowerReview] No active review session", vim.log.levels.WARN)
      return
    end
    -- Open thread viewer which has the 'r' keybinding,
    -- or if no threads exist, notify the user
    ui.open_thread_at_cursor()
  end, "Resolve thread at cursor")

  -- AI drafts panel (batch approve/reject)
  map("n", keymaps.ai_drafts, function()
    if not M.get_current_session() then
      vim.notify("[PowerReview] No active review session", vim.log.levels.WARN)
      return
    end
    ui.toggle_drafts()
  end, "AI drafts panel")

  -- Show PR description (view-only)
  map("n", keymaps.show_description, function()
    ui.toggle_description()
  end, "Show PR description")

  -- Mark current file as reviewed / toggle reviewed
  map("n", keymaps.mark_reviewed, function()
    vim.cmd("PowerReview mark_reviewed")
  end, "Toggle file reviewed status")

  -- Mark all files as reviewed
  map("n", keymaps.mark_all_reviewed, function()
    vim.cmd("PowerReview mark_all_reviewed")
  end, "Mark all files reviewed")

  -- Check for new iterations
  map("n", keymaps.check_iteration, function()
    vim.cmd("PowerReview check_iteration")
  end, "Check for new iterations")

  -- Open iteration diff for current file
  map("n", keymaps.iteration_diff, function()
    vim.cmd("PowerReview iteration_diff")
  end, "Iteration diff for current file")

  -- Navigate to next/prev unreviewed file
  map("n", keymaps.next_unreviewed, function()
    if not M.get_current_session() then
      vim.notify("[PowerReview] No active review session", vim.log.levels.WARN)
      return
    end
    ui.goto_unreviewed_file(1)
  end, "Next unreviewed file")

  map("n", keymaps.prev_unreviewed, function()
    if not M.get_current_session() then
      vim.notify("[PowerReview] No active review session", vim.log.levels.WARN)
      return
    end
    ui.goto_unreviewed_file(-1)
  end, "Previous unreviewed file")
end

--- Get the current active review session
---@return PowerReview.ReviewSession|nil
function M.get_current_session()
  return M._current_session
end

--- Set the current active review session (used internally)
---@param session PowerReview.ReviewSession|nil
function M._set_current_session(session)
  M._current_session = session
end

--- Public API for external consumers (LLM plugins, MCP server, etc.)
--- All functions delegate to the CLI for business logic and reload session state.
M.api = {}

--- Get the list of changed files in the current review
---@return PowerReview.ChangedFile[]|nil files, string|nil error
function M.api.get_changed_files()
  local session = M._current_session
  if not session then
    return nil, "No active review session"
  end
  return session.files, nil
end

--- Get diff content for a specific file
---@param file_path string Relative file path
---@return string|nil diff_content, string|nil error
function M.api.get_file_diff(file_path)
  local session = M._current_session
  if not session then
    return nil, "No active review session"
  end
  local review = require("power-review.review")
  return review.get_file_diff(session, file_path)
end

--- Get all comment threads (remote + local drafts)
---@return table|nil threads, string|nil error
function M.api.get_all_threads()
  local session = M._current_session
  if not session then
    return nil, "No active review session"
  end
  local review = require("power-review.review")
  return review.get_all_threads(session)
end

--- Get comment threads for a specific file
---@param file_path string Relative file path
---@return table|nil threads, string|nil error
function M.api.get_threads_for_file(file_path)
  local session = M._current_session
  if not session then
    return nil, "No active review session"
  end
  local review = require("power-review.review")
  return review.get_threads_for_file(session, file_path)
end

--- Create a new draft comment (delegates to CLI)
---@param opts table { file_path: string, line_start: number, line_end?: number, col_start?: number, col_end?: number, body: string, author?: "user"|"ai", thread_id?: number, parent_comment_id?: number }
---@return PowerReview.DraftComment|nil draft, string|nil error
function M.api.create_draft_comment(opts)
  local session = M._current_session
  if not session then
    return nil, "No active review session"
  end

  local cli = require("power-review.cli")
  local result, err = cli.create_draft(session.pr_url, {
    file_path = opts.file_path,
    line_start = opts.line_start,
    line_end = opts.line_end,
    col_start = opts.col_start,
    col_end = opts.col_end,
    body = opts.body,
    author = opts.author or "user",
    thread_id = opts.thread_id,
    parent_comment_id = opts.parent_comment_id,
  })

  if not result then
    return nil, err
  end

  -- Reload session to get fresh state
  local review = require("power-review.review")
  review._reload_current_session(session.pr_url, result)

  -- Refresh UI
  local ui = require("power-review.ui")
  ui.refresh_neotree()
  if opts.file_path then
    require("power-review.ui.signs").refresh_file(opts.file_path)
  end

  -- Construct a draft-like return value from CLI result
  local draft = result.draft or {}
  draft.id = result.id or draft.id
  return draft, nil
end

--- Edit a draft comment's body (delegates to CLI).
---@param draft_id string The local draft UUID
---@param new_body string New markdown content
---@return boolean success, string|nil error
function M.api.edit_draft_comment(draft_id, new_body)
  local session = M._current_session
  if not session then
    return false, "No active review session"
  end

  local cli = require("power-review.cli")
  local result, err = cli.edit_draft(session.pr_url, draft_id, new_body)
  if not result then
    return false, err
  end

  -- Reload session
  local review = require("power-review.review")
  review._reload_current_session(session.pr_url, result)

  -- Refresh UI
  local ui = require("power-review.ui")
  ui.refresh_neotree()
  -- Refresh signs for the affected file
  local updated_session = M._current_session
  if updated_session then
    for _, d in ipairs(updated_session.drafts) do
      if d.id == draft_id then
        require("power-review.ui.signs").refresh_file(d.file_path)
        break
      end
    end
  end

  return true, nil
end

--- Delete a draft comment (delegates to CLI).
---@param draft_id string The local draft UUID
---@return boolean success, string|nil error
function M.api.delete_draft_comment(draft_id)
  local session = M._current_session
  if not session then
    return false, "No active review session"
  end

  -- Grab file_path before deletion for sign refresh
  local file_path = nil
  for _, d in ipairs(session.drafts) do
    if d.id == draft_id then
      file_path = d.file_path
      break
    end
  end

  local cli = require("power-review.cli")
  local result, err = cli.delete_draft(session.pr_url, draft_id)
  if not result then
    return false, err
  end

  -- Reload session
  local review = require("power-review.review")
  review._reload_current_session(session.pr_url, result)

  -- Refresh UI
  require("power-review.ui").refresh_neotree()
  if file_path then
    require("power-review.ui.signs").refresh_file(file_path)
  end

  return true, nil
end

--- Approve a draft comment (delegates to CLI).
---@param draft_id string The local draft UUID
---@return boolean success, string|nil error
function M.api.approve_draft(draft_id)
  local session = M._current_session
  if not session then
    return false, "No active review session"
  end

  local cli = require("power-review.cli")
  local result, err = cli.approve_draft(session.pr_url, draft_id)
  if not result then
    return false, err
  end

  -- Reload session
  local review = require("power-review.review")
  review._reload_current_session(session.pr_url, result)

  -- Refresh UI
  local updated_session = M._current_session
  if updated_session then
    for _, d in ipairs(updated_session.drafts) do
      if d.id == draft_id then
        require("power-review.ui.signs").refresh_file(d.file_path)
        break
      end
    end
  end
  require("power-review.ui").refresh_neotree()

  return true, nil
end

--- Approve all draft comments (delegates to CLI).
---@return number count Number of drafts approved, string|nil error
function M.api.approve_all_drafts()
  local session = M._current_session
  if not session then
    return 0, "No active review session"
  end

  local cli = require("power-review.cli")
  local result, err = cli.approve_all_drafts(session.pr_url)
  if not result then
    return 0, err
  end

  -- Reload session
  local review = require("power-review.review")
  review._reload_current_session(session.pr_url, result)

  return result.approved or 0, nil
end

--- Unapprove a draft comment (delegates to CLI).
---@param draft_id string The local draft UUID
---@return boolean success, string|nil error
function M.api.unapprove_draft(draft_id)
  local session = M._current_session
  if not session then
    return false, "No active review session"
  end

  -- Grab file_path before unapproval for sign refresh
  local file_path = nil
  for _, d in ipairs(session.drafts) do
    if d.id == draft_id then
      file_path = d.file_path
      break
    end
  end

  local cli = require("power-review.cli")
  local result, err = cli.unapprove_draft(session.pr_url, draft_id)
  if not result then
    return false, err
  end

  -- Reload session
  local review = require("power-review.review")
  review._reload_current_session(session.pr_url, result)

  -- Refresh UI
  require("power-review.ui").refresh_neotree()
  if file_path then
    require("power-review.ui.signs").refresh_file(file_path)
  end

  return true, nil
end

--- Submit all pending comments to the remote provider
---@param callback fun(err?: string, result?: PowerReview.SubmitResult)
---@param progress_cb? fun(status: string, pending_count: number)
function M.api.submit_pending(callback, progress_cb)
  local session = M._current_session
  if not session then
    callback("No active review session")
    return
  end
  local review = require("power-review.review")
  review.submit_pending(session, callback, progress_cb)
end

--- Retry failed submissions from a previous submit attempt.
---@param failed_drafts table[] Array of { draft: PowerReview.DraftComment, error: string }
---@param callback fun(err?: string, result?: PowerReview.SubmitResult)
function M.api.retry_failed_submissions(failed_drafts, callback)
  local session = M._current_session
  if not session then
    callback("No active review session")
    return
  end
  local review = require("power-review.review")
  review.retry_failed_submissions(session, failed_drafts, callback)
end

--- Get current review session metadata
---@return table|nil session_info, string|nil error
function M.api.get_review_session()
  local session = M._current_session
  if not session then
    return nil, "No active review session"
  end

  -- Vote label mapping
  local vote_labels = {
    [10] = "Approved",
    [5] = "Approved with suggestions",
    [0] = "No vote",
    [-5] = "Wait for author",
    [-10] = "Rejected",
  }
  local vote_label = session.vote and vote_labels[session.vote] or "None"

  return {
    id = session.id,
    pr_id = session.pr_id,
    pr_title = session.pr_title,
    pr_description = session.pr_description,
    pr_author = session.pr_author,
    pr_url = session.pr_url,
    provider_type = session.provider_type,
    source_branch = session.source_branch,
    target_branch = session.target_branch,
    draft_count = #(session.drafts or {}),
    file_count = #(session.files or {}),
    vote = session.vote,
    vote_label = vote_label,
  }, nil
end

--- Set the review vote
---@param vote PowerReview.ReviewVote
---@param callback fun(err?: string, ok?: boolean)
function M.api.set_vote(vote, callback)
  local session = M._current_session
  if not session then
    callback("No active review session")
    return
  end
  local review = require("power-review.review")
  review.set_vote(session, vote, callback)
end

--- Sync remote comment threads.
---@param callback fun(err?: string, thread_count?: number)
function M.api.sync_threads(callback)
  local review = require("power-review.review")
  review.sync_threads(callback)
end

--- Close the current review session.
---@param callback? fun(err?: string)
function M.api.close_review(callback)
  callback = callback or function(err)
    if err then
      vim.notify("[PowerReview] " .. err, vim.log.levels.ERROR)
    else
      vim.notify("[PowerReview] Review closed", vim.log.levels.INFO)
    end
  end
  local review = require("power-review.review")
  review.close_review(callback)
end

--- Reply to an existing remote thread (creates a draft reply via CLI)
---@param opts table { thread_id: number, body: string, author?: "user"|"ai", file_path?: string, line_start?: number }
---@return PowerReview.DraftComment|nil draft, string|nil error
function M.api.reply_to_thread(opts)
  local session = M._current_session
  if not session then
    return nil, "No active review session"
  end

  local cli = require("power-review.cli")
  local result, err = cli.reply_to_thread(
    session.pr_url,
    opts.thread_id,
    opts.body,
    opts.author or "user"
  )

  if not result then
    return nil, err
  end

  -- Reload session
  local review = require("power-review.review")
  review._reload_current_session(session.pr_url, result)

  -- Refresh UI
  require("power-review.ui").refresh_neotree()
  if opts.file_path and opts.file_path ~= "" then
    require("power-review.ui.signs").refresh_file(opts.file_path)
  end

  local draft = result.draft or {}
  draft.id = result.id or draft.id
  return draft, nil
end

-- ============================================================================
-- Statusline
-- ============================================================================

--- Statusline integration module.
--- Lazy-loaded: use require("power-review.statusline") directly,
--- or access via require("power-review").statusline.
M.statusline = require("power-review.statusline")

return M
