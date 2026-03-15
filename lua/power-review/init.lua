--- PowerReview.nvim - PR Review plugin for Neovim
--- Main entry point and public API
local M = {}

local config = require("power-review.config")

---@type PowerReview.ReviewSession|nil
M._current_session = nil

--- Setup the plugin with user configuration
---@param opts? table User configuration (see config.lua for schema)
function M.setup(opts)
  config.setup(opts)

  -- Initialize UI subsystems that need early setup
  local signs = require("power-review.ui.signs")
  signs.setup()

  -- Initialize MCP integration if enabled
  local mcp_cfg = config.get().mcp
  if mcp_cfg and mcp_cfg.enabled then
    local mcp = require("power-review.mcp")
    mcp.setup()
    -- If there's already an active session, write server info immediately
    if M._current_session then
      mcp.write_server_info(true, M._current_session.pr_id)
    end
  end

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
  local store = require("power-review.store")

  local function map(mode, lhs, rhs, desc)
    if lhs and lhs ~= false then
      vim.keymap.set(mode, lhs, rhs, { silent = true, desc = "[PowerReview] " .. desc })
    end
  end

  -- Open review: prompt for URL or pick from saved sessions
  map("n", keymaps.open_review, function()
    local function prompt_for_url()
      vim.ui.input({ prompt = "PR URL: " }, function(url)
        if url and url ~= "" then
          review.start_review(url, function(err, session)
            if err then
              vim.notify("[PowerReview] " .. err, vim.log.levels.ERROR)
            else
              vim.notify("[PowerReview] Review started: " .. session.pr_title, vim.log.levels.INFO)
            end
          end)
        end
      end)
    end

    local sessions = store.list()
    if #sessions == 0 then
      prompt_for_url()
    else
      -- Add a "New review..." option at the top of the session list
      local choices = { { id = "__new__", label = " Enter a new PR URL..." } }
      for _, s in ipairs(sessions) do
        table.insert(choices, s)
      end

      vim.ui.select(choices, {
        prompt = "Select review session or start new:",
        format_item = function(item)
          if item.id == "__new__" then
            return item.label
          end
          return string.format("[%s] PR #%d: %s (%d drafts)", item.provider_type, item.pr_id, item.pr_title, item.draft_count)
        end,
      }, function(selected)
        if not selected then
          return
        end
        if selected.id == "__new__" then
          prompt_for_url()
          return
        end
        review.resume_session(selected.id, function(err)
          if err then
            vim.notify("[PowerReview] " .. err, vim.log.levels.ERROR)
          end
        end)
      end)
    end
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
    M.api.close_review()
  end, "Close review session")

  -- Delete a saved review session
  map("n", keymaps.delete_session, function()
    vim.cmd("PowerReview delete")
  end, "Delete saved review session")
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
--- All functions guard against nil session and draft-only operations where appropriate.
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

--- Create a new draft comment
---@param opts table { file_path: string, line_start: number, line_end?: number, col_start?: number, col_end?: number, body: string, author?: "user"|"ai", thread_id?: number, parent_comment_id?: number }
---@return PowerReview.DraftComment|nil draft, string|nil error
function M.api.create_draft_comment(opts)
  local session = M._current_session
  if not session then
    return nil, "No active review session"
  end
  local comment_mod = require("power-review.review.comment")
  local draft = comment_mod.new_draft({
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
  local session_mod = require("power-review.review.session")
  session_mod.add_draft(session, draft)
  local store = require("power-review.store")
  store.save(session)
  -- Refresh neo-tree to show updated draft counts
  local ui = require("power-review.ui")
  ui.refresh_neotree()
  -- Refresh signs in diff buffers
  require("power-review.ui.signs").refresh_file(opts.file_path)
  return draft, nil
end

--- Edit a draft comment's body. Only works on comments with status "draft".
---@param draft_id string The local draft UUID
---@param new_body string New markdown content
---@return boolean success, string|nil error
function M.api.edit_draft_comment(draft_id, new_body)
  local session = M._current_session
  if not session then
    return false, "No active review session"
  end
  local session_mod = require("power-review.review.session")
  local ok, err = session_mod.edit_draft(session, draft_id, new_body)
  if ok then
    local store = require("power-review.store")
    store.save(session)
    -- Refresh UI (neo-tree, comments panel, signs)
    local ui = require("power-review.ui")
    ui.refresh_neotree()
    -- Refresh signs for the affected file
    local draft = session_mod.get_draft(session, draft_id)
    if draft then
      require("power-review.ui.signs").refresh_file(draft.file_path)
    end
  end
  return ok, err
end

--- Delete a draft comment. Only works on comments with status "draft".
---@param draft_id string The local draft UUID
---@return boolean success, string|nil error
function M.api.delete_draft_comment(draft_id)
  local session = M._current_session
  if not session then
    return false, "No active review session"
  end
  local session_mod = require("power-review.review.session")
  -- Grab file_path before deletion for sign refresh
  local draft = session_mod.get_draft(session, draft_id)
  local file_path = draft and draft.file_path
  local ok, err = session_mod.delete_draft(session, draft_id)
  if ok then
    local store = require("power-review.store")
    store.save(session)
    require("power-review.ui").refresh_neotree()
    if file_path then
      require("power-review.ui.signs").refresh_file(file_path)
    end
  end
  return ok, err
end

--- Approve a draft comment (move from "draft" to "pending")
---@param draft_id string The local draft UUID
---@return boolean success, string|nil error
function M.api.approve_draft(draft_id)
  local session = M._current_session
  if not session then
    return false, "No active review session"
  end
  local session_mod = require("power-review.review.session")
  local ok, err = session_mod.approve_draft(session, draft_id)
  if ok then
    local store = require("power-review.store")
    store.save(session)
    -- Refresh UI to show updated status
    local draft = session_mod.get_draft(session, draft_id)
    if draft then
      require("power-review.ui.signs").refresh_file(draft.file_path)
    end
    require("power-review.ui").refresh_neotree()
  end
  return ok, err
end

--- Approve all draft comments (move all "draft" to "pending")
---@return number count Number of drafts approved, string|nil error
function M.api.approve_all_drafts()
  local session = M._current_session
  if not session then
    return 0, "No active review session"
  end
  local session_mod = require("power-review.review.session")
  local count = session_mod.approve_all_drafts(session)
  if count > 0 then
    local store = require("power-review.store")
    store.save(session)
  end
  return count, nil
end

--- Unapprove a draft comment (revert from "pending" back to "draft")
---@param draft_id string The local draft UUID
---@return boolean success, string|nil error
function M.api.unapprove_draft(draft_id)
  local session = M._current_session
  if not session then
    return false, "No active review session"
  end
  local session_mod = require("power-review.review.session")
  local ok, err = session_mod.unapprove_draft(session, draft_id)
  if ok then
    local store = require("power-review.store")
    store.save(session)
    require("power-review.ui").refresh_neotree()
  end
  return ok, err
end

--- Submit all pending comments to the remote provider
---@param callback fun(err?: string, result?: PowerReview.SubmitResult)
---@param progress_cb? fun(current: number, total: number, draft: PowerReview.DraftComment)
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
  local status_mod = require("power-review.review.status")
  local vote_label = session.vote and status_mod.vote_label(session.vote) or "None"

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
    draft_count = #session.drafts,
    file_count = #session.files,
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

--- Sync remote comment threads (fetch latest from provider).
---@param callback fun(err?: string, thread_count?: number)
function M.api.sync_threads(callback)
  local review = require("power-review.review")
  review.sync_threads(callback)
end

--- Close the current review session.
--- Tears down all UI, saves session state, cleans up git.
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

--- Reply to an existing remote thread (creates a draft reply)
---@param opts table { thread_id: number, body: string, author?: "user"|"ai" }
---@return PowerReview.DraftComment|nil draft, string|nil error
function M.api.reply_to_thread(opts)
  local session = M._current_session
  if not session then
    return nil, "No active review session"
  end
  local comment_mod = require("power-review.review.comment")
  local draft = comment_mod.new_draft({
    file_path = opts.file_path or "",
    line_start = opts.line_start or 0,
    body = opts.body,
    author = opts.author or "user",
    thread_id = opts.thread_id,
  })
  local session_mod = require("power-review.review.session")
  session_mod.add_draft(session, draft)
  local store = require("power-review.store")
  store.save(session)
  require("power-review.ui").refresh_neotree()
  if opts.file_path and opts.file_path ~= "" then
    require("power-review.ui.signs").refresh_file(opts.file_path)
  end
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
