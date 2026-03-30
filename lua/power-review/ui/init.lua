--- PowerReview.nvim UI coordinator
--- Coordinates all UI components: files panel (neo-tree / builtin), diff view, comments.
local M = {}

local log = require("power-review.utils.log")
local config = require("power-review.config")

-- ============================================================================
-- Files Panel
-- ============================================================================

--- Toggle the changed files panel.
--- Delegates to neo-tree source or builtin fallback based on config.
function M.toggle_files()
  local pr = require("power-review")
  local session = pr.get_current_session()
  if not session then
    log.warn("No active review session")
    return
  end

  local ui_cfg = config.get_ui_config()
  local files_provider = ui_cfg.files.provider

  if files_provider == "neo-tree" then
    M._toggle_neotree_files()
  else
    -- Builtin fallback (Phase 2.2)
    M._toggle_builtin_files(session)
  end
end

--- Toggle the neo-tree power_review source panel.
function M._toggle_neotree_files()
  local ok, _ = pcall(require, "neo-tree")
  if not ok then
    log.warn("neo-tree.nvim is not installed. Set ui.files.provider = 'builtin' or install neo-tree.nvim")
    -- Fall back to builtin
    local pr = require("power-review")
    local session = pr.get_current_session()
    if session then
      M._toggle_builtin_files(session)
    end
    return
  end

  -- Use the :Neotree command to toggle the power_review source
  vim.cmd("Neotree toggle source=power_review position=left")
end

--- Show the neo-tree power_review source (without toggle — always open).
function M._show_neotree_files()
  local ok, _ = pcall(require, "neo-tree")
  if not ok then
    return
  end
  vim.cmd("Neotree show source=power_review position=left")
end

--- Refresh the neo-tree source if it's visible.
--- Also refreshes builtin panel, comments panel, and comment signs in diff buffers.
function M.refresh_neotree()
  local ok, source = pcall(require, "neo-tree.sources.power_review")
  if ok and source.refresh_if_visible then
    source.refresh_if_visible()
  end
  -- Also refresh builtin panel if visible
  M.refresh_builtin_files()
  -- Refresh comments panel if visible
  M.refresh_comments_panel()
  -- Refresh comment signs in diff buffers
  require("power-review.ui.signs").refresh()
end

--- Builtin file list fallback (for users without neo-tree).
--- Uses nui.nvim split panel with NuiTree, or quickfix as ultimate fallback.
---@param session PowerReview.ReviewSession
function M._toggle_builtin_files(session)
  local files_panel = require("power-review.ui.files_panel")
  files_panel.toggle(session)
end

--- Refresh the builtin file panel if visible.
function M.refresh_builtin_files()
  local files_panel = require("power-review.ui.files_panel")
  if files_panel.is_visible() then
    local pr = require("power-review")
    local session = pr.get_current_session()
    if session then
      files_panel.refresh(session)
    end
  end
end

--- Refresh the all-comments panel if visible.
function M.refresh_comments_panel()
  local comments_panel = require("power-review.ui.comments_panel")
  if comments_panel.is_visible() then
    local pr = require("power-review")
    local session = pr.get_current_session()
    if session then
      comments_panel.refresh(session)
    end
  end
end

-- ============================================================================
-- Diff View (delegates to power-review.ui.diff)
-- ============================================================================

local diff = require("power-review.ui.diff")

--- Open a diff view for a specific file in the review.
--- Delegates to the diff module which handles provider selection and fallback.
---@param session PowerReview.ReviewSession
---@param file_path string Relative file path
---@param callback? fun() Called after the diff view is open
function M.open_file_diff(session, file_path, callback)
  diff.open_file(session, file_path, callback)
end

--- Open the full diff explorer showing all changed files.
--- Only available with codediff.nvim.
---@param session PowerReview.ReviewSession
---@param callback? fun()
function M.open_diff_explorer(session, callback)
  diff.open_explorer(session, callback)
end

--- Close the current diff view.
function M.close_diff()
  diff.close()
end

--- Get the current diff state.
---@return table|nil
function M.get_current_diff()
  return diff.get_current()
end

-- ============================================================================
-- Comments
-- ============================================================================

--- Toggle the all-comments panel
function M.toggle_comments()
  local pr = require("power-review")
  local session = pr.get_current_session()
  if not session then
    log.warn("No active review session")
    return
  end

  local comments_panel = require("power-review.ui.comments_panel")
  comments_panel.toggle(session)
end

--- Toggle the sessions management panel.
function M.toggle_sessions()
  local sessions_panel = require("power-review.ui.sessions")
  sessions_panel.toggle()
end

--- Toggle the draft management panel.
function M.toggle_drafts()
  local pr = require("power-review")
  local session = pr.get_current_session()
  if not session then
    log.warn("No active review session")
    return
  end

  local drafts_panel = require("power-review.ui.drafts")
  drafts_panel.toggle(session)
end

--- Add a comment on the current cursor line or visual selection.
--- Opens the floating comment editor (nui.nvim) or falls back to vim.ui.input.
--- When called from visual mode, captures the selection range for multi-line comments.
--- Supports column-level selection: in characterwise visual mode ('v'), captures
--- the start and end columns so the comment can target a specific code span.
---@param opts? { visual?: boolean }
function M.add_comment(opts)
  opts = opts or {}
  local pr = require("power-review")
  local session = pr.get_current_session()
  if not session then
    log.warn("No active review session")
    return
  end

  local comment_float = require("power-review.ui.comment_float")
  local bufnr = vim.api.nvim_get_current_buf()

  -- Detect visual mode range
  local line_start, line_end, col_start, col_end
  if opts.visual then
    -- Get visual selection range (works from both 'v' and 'V' modes)
    local vis_mode = vim.fn.visualmode()
    line_start = vim.fn.line("'<")
    line_end = vim.fn.line("'>")
    -- Capture columns for characterwise visual mode
    if vis_mode == "v" then
      col_start = vim.fn.col("'<")
      col_end = vim.fn.col("'>")
    end
    -- Ensure correct order
    if line_start > line_end then
      line_start, line_end = line_end, line_start
      col_start, col_end = col_end, col_start
    end
    -- Single-line selection: treat as no range for line_end, but keep columns
    if line_start == line_end then
      line_end = nil
    end
  else
    line_start = vim.api.nvim_win_get_cursor(0)[1]
    line_end = nil
  end

  -- Try to resolve file path
  local file_path
  local signs_mod = require("power-review.ui.signs")
  local info = signs_mod._attached_bufs[bufnr]
  if info then
    file_path = info.file_path
  else
    file_path = comment_float._resolve_file_path(bufnr, session)
  end

  if not file_path then
    -- Fallback: derive from buffer name
    local buf_name = vim.api.nvim_buf_get_name(bufnr)
    local cwd = vim.fn.getcwd()
    file_path = buf_name
    if buf_name:find(cwd, 1, true) == 1 then
      file_path = buf_name:sub(#cwd + 2)
    end
    file_path = file_path:gsub("\\", "/")
  end

  comment_float.open_comment_editor({
    file_path = file_path,
    line = line_start,
    line_end = line_end,
    col_start = col_start,
    col_end = col_end,
    session = session,
  })
end

--- Open the thread viewer at the cursor position.
--- Shows existing comments and drafts at the current line.
function M.open_thread_at_cursor()
  local comment_float = require("power-review.ui.comment_float")
  comment_float.open_thread_viewer()
end

--- Close all floating comment windows.
function M.close_comment_floats()
  local comment_float = require("power-review.ui.comment_float")
  comment_float.close_all()
end

--- Edit a draft comment at the cursor position.
--- If there are multiple drafts at the cursor line, prompts user to select.
function M.edit_comment_at_cursor()
  local pr = require("power-review")
  local session = pr.get_current_session()
  if not session then
    log.warn("No active review session")
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local line = vim.api.nvim_win_get_cursor(0)[1]

  -- Get drafts at this line
  local signs_mod = require("power-review.ui.signs")
  local info = signs_mod._attached_bufs[bufnr]
  local file_path
  if info then
    file_path = info.file_path
  else
    local comment_float = require("power-review.ui.comment_float")
    file_path = comment_float._resolve_file_path(bufnr, session)
  end

  if not file_path then
    log.warn("Cannot determine file path for this buffer")
    return
  end

  local helpers = require("power-review.session_helpers")
  local drafts = helpers.get_drafts_for_file(session, file_path)
  local line_drafts = {}
  for _, d in ipairs(drafts) do
    if d.line_start == line and d.status == "draft" then
      table.insert(line_drafts, d)
    end
  end

  if #line_drafts == 0 then
    log.info("No editable drafts at line %d", line)
    return
  end

  local function open_editor(draft)
    local comment_float = require("power-review.ui.comment_float")
    comment_float.open_comment_editor({
      file_path = draft.file_path,
      line = draft.line_start,
      line_end = draft.line_end,
      session = session,
      draft_id = draft.id,
      initial_body = draft.body,
    })
  end

  if #line_drafts == 1 then
    open_editor(line_drafts[1])
  else
    -- Multiple drafts: let user choose
    vim.ui.select(line_drafts, {
      prompt = "Select draft to edit:",
      format_item = function(d)
        local preview = d.body:gsub("\n", " "):sub(1, 60)
        local author_label = d.author == "ai" and " (AI)" or ""
        return string.format("[%s]%s %s", d.status:upper(), author_label, preview)
      end,
    }, function(selected)
      if selected then
        open_editor(selected)
      end
    end)
  end
end

--- Delete a draft comment at the cursor position.
--- If there are multiple drafts at the cursor line, prompts user to select.
function M.delete_comment_at_cursor()
  local pr = require("power-review")
  local session = pr.get_current_session()
  if not session then
    log.warn("No active review session")
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local line = vim.api.nvim_win_get_cursor(0)[1]

  -- Get drafts at this line
  local signs_mod = require("power-review.ui.signs")
  local info = signs_mod._attached_bufs[bufnr]
  local file_path
  if info then
    file_path = info.file_path
  else
    local comment_float = require("power-review.ui.comment_float")
    file_path = comment_float._resolve_file_path(bufnr, session)
  end

  if not file_path then
    log.warn("Cannot determine file path for this buffer")
    return
  end

  local helpers = require("power-review.session_helpers")
  local drafts = helpers.get_drafts_for_file(session, file_path)
  local line_drafts = {}
  for _, d in ipairs(drafts) do
    if d.line_start == line and d.status == "draft" then
      table.insert(line_drafts, d)
    end
  end

  if #line_drafts == 0 then
    log.info("No deletable drafts at line %d", line)
    return
  end

  local function do_delete(draft)
    vim.ui.input({ prompt = "Delete draft? (y/n): " }, function(input)
      if input == "y" or input == "Y" then
        local ok_del, err = pr.api.delete_draft_comment(draft.id)
        if ok_del then
          log.info("Draft deleted")
        else
          log.error("Failed to delete draft: %s", err or "unknown")
        end
      end
    end)
  end

  if #line_drafts == 1 then
    do_delete(line_drafts[1])
  else
    vim.ui.select(line_drafts, {
      prompt = "Select draft to delete:",
      format_item = function(d)
        local preview = d.body:gsub("\n", " "):sub(1, 60)
        return string.format("[%s] %s", d.status:upper(), preview)
      end,
    }, function(selected)
      if selected then
        do_delete(selected)
      end
    end)
  end
end

--- Approve a draft comment at the cursor position.
--- If there are multiple drafts at the cursor line, prompts user to select.
function M.approve_comment_at_cursor()
  local pr = require("power-review")
  local session = pr.get_current_session()
  if not session then
    log.warn("No active review session")
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local line = vim.api.nvim_win_get_cursor(0)[1]

  local signs_mod = require("power-review.ui.signs")
  local info = signs_mod._attached_bufs[bufnr]
  local file_path
  if info then
    file_path = info.file_path
  else
    local comment_float = require("power-review.ui.comment_float")
    file_path = comment_float._resolve_file_path(bufnr, session)
  end

  if not file_path then
    log.warn("Cannot determine file path for this buffer")
    return
  end

  local helpers = require("power-review.session_helpers")
  local drafts = helpers.get_drafts_for_file(session, file_path)
  local line_drafts = {}
  for _, d in ipairs(drafts) do
    if d.line_start == line and d.status == "draft" then
      table.insert(line_drafts, d)
    end
  end

  if #line_drafts == 0 then
    log.info("No drafts to approve at line %d", line)
    return
  end

  local function do_approve(draft)
    local ok_appr, err = pr.api.approve_draft(draft.id)
    if ok_appr then
      log.info("Draft approved (now pending)")
      M.refresh_neotree()
    else
      log.error("Failed to approve: %s", err or "unknown")
    end
  end

  if #line_drafts == 1 then
    do_approve(line_drafts[1])
  else
    vim.ui.select(line_drafts, {
      prompt = "Select draft to approve:",
      format_item = function(d)
        local preview = d.body:gsub("\n", " "):sub(1, 60)
        local author_label = d.author == "ai" and " (AI)" or ""
        return string.format("[%s]%s %s", d.status:upper(), author_label, preview)
      end,
    }, function(selected)
      if selected then
        do_approve(selected)
      end
    end)
  end
end

-- ============================================================================
-- Comment Navigation
-- ============================================================================

local signs = require("power-review.ui.signs")

--- Go to the next comment sign in the current buffer.
function M.goto_next_comment()
  signs.goto_next_comment()
end

--- Go to the previous comment sign in the current buffer.
function M.goto_prev_comment()
  signs.goto_prev_comment()
end

--- Get comment indicators at the cursor's current line.
---@return PowerReview.CommentIndicator[]
function M.get_comments_at_cursor()
  local bufnr = vim.api.nvim_get_current_buf()
  local line = vim.api.nvim_win_get_cursor(0)[1]
  return signs.get_indicators_at_line(bufnr, line)
end

-- ============================================================================
-- Vote
-- ============================================================================

--- Open the vote selection UI with current vote display and confirmation.
function M.set_vote()
  local pr = require("power-review")
  local session = pr.get_current_session()
  if not session then
    log.warn("No active review session")
    return
  end

  local helpers = require("power-review.session_helpers")
  local current_vote = session.vote
  local current_label = current_vote and helpers.vote_label(current_vote) or "None"

  log.info("Current vote: %s", current_label)

  local choices = helpers.get_vote_choices(current_vote)
  vim.ui.select(choices, {
    prompt = "Set review vote (current: " .. current_label .. "):",
    format_item = function(c)
      return c.label
    end,
  }, function(selected)
    if not selected then
      return
    end

    if selected.is_current then
      log.info("Vote unchanged: %s", selected.label)
      return
    end

    local needs_confirm = selected.value == -10 or selected.value == -5
    local function do_vote()
      pr.api.set_vote(selected.value, function(err)
        if err then
          log.error("Failed to set vote: %s", err)
        else
          log.info("Vote set: %s", selected.label)
        end
      end)
    end

    if needs_confirm then
      vim.ui.input({
        prompt = string.format("Confirm vote '%s'? (y/n): ", selected.label),
      }, function(input)
        if input == "y" or input == "Y" then
          do_vote()
        else
          log.info("Vote cancelled")
        end
      end)
    else
      do_vote()
    end
  end)
end

-- ============================================================================
-- Buffer-local keymaps for diff buffers
-- ============================================================================

--- Track which buffers already have keymaps attached.
---@type table<number, boolean>
M._keymap_bufs = {}

--- Setup buffer-local keymaps on a diff buffer.
--- Called automatically when signs attach to a buffer.
--- Provides comment navigation, add/edit/approve keymaps scoped to the buffer.
---@param bufnr number
function M.setup_buffer_keymaps(bufnr)
  if M._keymap_bufs[bufnr] then
    return
  end
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  M._keymap_bufs[bufnr] = true

  local keymaps = config.get_keymaps()
  if not keymaps then
    return
  end

  local function buf_map(mode, lhs, rhs, desc)
    if lhs and lhs ~= false then
      vim.keymap.set(mode, lhs, rhs, { buffer = bufnr, silent = true, desc = "[PowerReview] " .. desc })
    end
  end

  -- Comment navigation (buffer-local overrides ensure they work in diff buffers)
  buf_map("n", keymaps.next_comment, function()
    M.goto_next_comment()
  end, "Next comment")

  buf_map("n", keymaps.prev_comment, function()
    M.goto_prev_comment()
  end, "Previous comment")

  -- Add comment at cursor
  buf_map("n", keymaps.add_comment, function()
    M.add_comment()
  end, "Add comment at cursor")

  -- Add comment on visual selection
  buf_map("v", keymaps.add_comment, function()
    vim.cmd("normal! " .. vim.api.nvim_replace_termcodes("<Esc>", true, false, true))
    M.add_comment({ visual = true })
  end, "Add comment on selection")

  -- Reply to thread at cursor
  buf_map("n", keymaps.reply_comment, function()
    M.open_thread_at_cursor()
  end, "Reply to thread at cursor")

  -- Edit draft at cursor
  buf_map("n", keymaps.edit_comment, function()
    M.edit_comment_at_cursor()
  end, "Edit draft at cursor")

  -- Approve draft at cursor
  buf_map("n", keymaps.approve_comment, function()
    M.approve_comment_at_cursor()
  end, "Approve draft at cursor")

  log.debug("Buffer keymaps set for buffer %d", bufnr)
end

--- Clean up keymap tracking for a buffer.
---@param bufnr number
function M.cleanup_buffer_keymaps(bufnr)
  M._keymap_bufs[bufnr] = nil
end

-- ============================================================================
-- Full UI teardown (for closing a review session)
-- ============================================================================

--- Close all PowerReview UI elements.
--- Called when the user closes the review session entirely.
--- Closes: comments panel, floating comments, neo-tree source, diff tabs,
--- detaches all signs/extmarks, cleans up buffer keymaps.
function M.teardown_all()
  -- 1. Close the comments panel
  local ok_cp, comments_panel = pcall(require, "power-review.ui.comments_panel")
  if ok_cp and comments_panel.is_visible() then
    comments_panel.close()
  end

  -- 2. Close floating comment windows
  local ok_cf, comment_float = pcall(require, "power-review.ui.comment_float")
  if ok_cf and comment_float.close_all then
    pcall(comment_float.close_all)
  end

  -- 3. Close diff view if open
  local ok_diff, diff_mod = pcall(require, "power-review.ui.diff")
  if ok_diff then
    pcall(diff_mod.close)
  end

  -- 4. Detach all signs and clear extmarks
  local ok_signs, signs_mod = pcall(require, "power-review.ui.signs")
  if ok_signs then
    pcall(signs_mod.detach_all)
  end

  -- 5. Close neo-tree power_review source if open
  pcall(function()
    local neo_ok, _ = pcall(require, "neo-tree")
    if neo_ok then
      vim.cmd("Neotree close source=power_review")
    end
  end)

  -- 6. Clean up all buffer keymaps
  for bufnr, _ in pairs(M._keymap_bufs) do
    M._keymap_bufs[bufnr] = nil
  end

  log.info("All PowerReview UI elements closed")
end

-- ============================================================================
-- Helpers
-- ============================================================================

--- Get icon for a change type
---@param change_type string
---@return string
function M._change_type_icon(change_type)
  local icons = {
    add = "A",
    edit = "M",
    delete = "D",
    rename = "R",
  }
  return icons[change_type] or "?"
end

return M
