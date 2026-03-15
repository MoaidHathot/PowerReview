--- PowerReview.nvim floating comment window
--- Displays comment threads and draft editor in a nui.nvim popup.
local M = {}

local log = require("power-review.utils.log")
local config = require("power-review.config")

--- Currently open popup reference (only one at a time)
---@type table|nil
M._popup = nil

--- Currently open editor popup (for composing/editing)
---@type table|nil
M._editor = nil

--- Currently open preview popup (for live markdown rendering below editor)
---@type table|nil
M._preview = nil

--- Whether the editor is currently hidden (toggled off temporarily)
---@type boolean
M._editor_hidden = false

--- The split window ID when editor is in split mode (nil = float mode)
---@type number|nil
M._editor_split_winid = nil

--- Stored editor opts for restoring float from split
---@type table|nil
M._editor_opts = nil

--- Currently open thread context popup (shown above editor when replying)
---@type table|nil
M._thread_context = nil

--- Whether the thread context popup is currently visible
---@type boolean
M._thread_context_visible = false

--- Timer for debounced preview updates
---@type userdata|nil
M._preview_timer = nil

-- ============================================================================
-- Thread viewer popup
-- ============================================================================

--- Open a floating window showing comment threads at the cursor line.
--- Shows remote comments + local drafts, with option to reply or create new.
---@param opts? table { bufnr?: number, line?: number }
function M.open_thread_viewer(opts)
  opts = opts or {}
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local line = opts.line or vim.api.nvim_win_get_cursor(0)[1]

  local pr = require("power-review")
  local session = pr.get_current_session()
  if not session then
    log.warn("No active review session")
    return
  end

  -- Get file path from signs module
  local signs = require("power-review.ui.signs")
  local info = signs._attached_bufs[bufnr]
  local file_path
  if info then
    file_path = info.file_path
  else
    -- Try to resolve from buffer name
    file_path = M._resolve_file_path(bufnr, session)
  end

  if not file_path then
    log.warn("Cannot determine file path for this buffer")
    return
  end

  -- Gather indicators at this line
  local indicators = signs.get_indicators_at_line(bufnr, line)

  -- Also get drafts directly (indicators might not include all if signs aren't attached)
  local session_mod = require("power-review.review.session")
  local drafts = session_mod.get_drafts_for_file(session, file_path)
  local line_drafts = {}
  for _, d in ipairs(drafts) do
    if d.line_start == line then
      table.insert(line_drafts, d)
    end
  end

  -- Get remote threads for this line
  local review = require("power-review.review")
  local threads = review.get_threads_for_file(session, file_path)
  local line_threads = {}
  for _, t in ipairs(threads) do
    if t.line_start == line and t.type ~= "draft" then
      table.insert(line_threads, t)
    end
  end

  -- Build content lines for the popup
  local content_lines, content_hls = M._build_thread_content(line_threads, line_drafts, file_path, line)

  if #content_lines == 0 then
    -- No existing comments; open the editor directly
    M.open_comment_editor({
      file_path = file_path,
      line = line,
      session = session,
    })
    return
  end

  -- Close any existing popup
  M.close()

  -- Create the popup
  local ok, Popup = pcall(require, "nui.popup")
  if not ok then
    -- Fallback: show in vim.notify
    for _, l in ipairs(content_lines) do
      log.info(l)
    end
    return
  end

  local event = require("nui.utils.autocmd").event
  local ui_cfg = config.get_ui_config()
  local float_cfg = ui_cfg.comments.float

  local popup = Popup({
    enter = true,
    focusable = true,
    relative = "cursor",
    position = {
      row = 1,
      col = 0,
    },
    size = {
      width = math.min(float_cfg.width, vim.o.columns - 4),
      height = math.min(#content_lines + 2, float_cfg.height, vim.o.lines - 4),
    },
    border = {
      style = "rounded",
      text = {
        top = string.format(" %s:%d ", file_path, line),
        top_align = "left",
        bottom = " q:close  a:reply  e:edit  d:del  A:approve  U:unapprove ",
        bottom_align = "center",
      },
    },
    buf_options = {
      modifiable = false,
      readonly = true,
      filetype = "markdown",
    },
    win_options = {
      winhighlight = "Normal:NormalFloat,FloatBorder:FloatBorder",
      wrap = true,
      linebreak = true,
      cursorline = true,
    },
  })

  popup:mount()

  -- Set content
  vim.bo[popup.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(popup.bufnr, 0, -1, false, content_lines)
  vim.bo[popup.bufnr].modifiable = false

  -- Apply highlights
  local ns = vim.api.nvim_create_namespace("power_review_float")
  for _, hl in ipairs(content_hls) do
    pcall(vim.api.nvim_buf_add_highlight, popup.bufnr, ns, hl.group, hl.line, hl.col_start, hl.col_end)
  end

  -- Store context for keybinding actions
  local ctx = {
    file_path = file_path,
    line = line,
    session = session,
    line_drafts = line_drafts,
    line_threads = line_threads,
  }

  -- Keymaps
  popup:map("n", "q", function()
    M.close()
  end, { noremap = true })

  popup:map("n", "<Esc>", function()
    M.close()
  end, { noremap = true })

  -- Reply / new comment
  popup:map("n", "a", function()
    M.close()
    M.open_comment_editor({
      file_path = ctx.file_path,
      line = ctx.line,
      session = ctx.session,
      -- If there's a remote thread, reply to it
      thread_id = ctx.line_threads[1] and ctx.line_threads[1].id or nil,
    })
  end, { noremap = true })

  -- Edit draft on this line (if multiple, user picks)
  popup:map("n", "e", function()
    if #ctx.line_drafts == 0 then
      log.info("No draft comments to edit on this line")
      return
    end

    local function do_edit(draft)
      M.close()
      M.open_comment_editor({
        file_path = ctx.file_path,
        line = ctx.line,
        line_end = draft.line_end,
        session = ctx.session,
        draft_id = draft.id,
        initial_body = draft.body,
      })
    end

    if #ctx.line_drafts == 1 then
      do_edit(ctx.line_drafts[1])
    else
      M.close()
      vim.ui.select(ctx.line_drafts, {
        prompt = "Select draft to edit:",
        format_item = function(d)
          local preview = d.body:gsub("\n", " "):sub(1, 60)
          local author_label = d.author == "ai" and " (AI)" or ""
          return string.format("[%s]%s %s", d.status:upper(), author_label, preview)
        end,
      }, function(selected)
        if selected then
          do_edit(selected)
        end
      end)
    end
  end, { noremap = true })

  -- Delete draft on this line (if multiple, user picks)
  popup:map("n", "d", function()
    if #ctx.line_drafts == 0 then
      log.info("No draft comments to delete on this line")
      return
    end

    local function do_delete(draft)
      vim.ui.input({ prompt = "Delete draft? (y/n): " }, function(input)
        if input == "y" or input == "Y" then
          local ok_del, err = require("power-review").api.delete_draft_comment(draft.id)
          if ok_del then
            log.info("Draft deleted")
            M.close()
          else
            log.error("Failed to delete draft: %s", err or "unknown")
          end
        end
      end)
    end

    if #ctx.line_drafts == 1 then
      do_delete(ctx.line_drafts[1])
    else
      M.close()
      vim.ui.select(ctx.line_drafts, {
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
  end, { noremap = true })

  -- Approve draft (draft -> pending)
  popup:map("n", "A", function()
    local approvable = {}
    for _, d in ipairs(ctx.line_drafts) do
      if d.status == "draft" then
        table.insert(approvable, d)
      end
    end

    if #approvable == 0 then
      log.info("No draft comments to approve on this line")
      return
    end

    local function do_approve(draft)
      local pr = require("power-review")
      local ok_appr, err = pr.api.approve_draft(draft.id)
      if ok_appr then
        log.info("Draft approved (pending)")
        M.close()
      else
        log.error("Failed to approve draft: %s", err or "unknown")
      end
    end

    if #approvable == 1 then
      do_approve(approvable[1])
    else
      M.close()
      vim.ui.select(approvable, {
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
  end, { noremap = true })

  -- Unapprove draft (pending -> draft)
  popup:map("n", "U", function()
    local unapprovable = {}
    for _, d in ipairs(ctx.line_drafts) do
      if d.status == "pending" then
        table.insert(unapprovable, d)
      end
    end

    if #unapprovable == 0 then
      log.info("No pending comments to unapprove on this line")
      return
    end

    local function do_unapprove(draft)
      local pr = require("power-review")
      local ok_u, err = pr.api.unapprove_draft(draft.id)
      if ok_u then
        log.info("Draft unapproved (back to draft)")
        M.close()
      else
        log.error("Failed to unapprove: %s", err or "unknown")
      end
    end

    if #unapprovable == 1 then
      do_unapprove(unapprovable[1])
    else
      M.close()
      vim.ui.select(unapprovable, {
        prompt = "Select draft to unapprove:",
        format_item = function(d)
          local preview = d.body:gsub("\n", " "):sub(1, 60)
          return string.format("[PENDING] %s", preview)
        end,
      }, function(selected)
        if selected then
          do_unapprove(selected)
        end
      end)
    end
  end, { noremap = true })

  -- Auto-close on BufLeave
  popup:on(event.BufLeave, function()
    M.close()
  end)

  M._popup = popup
end

--- Build content lines and highlights for the thread viewer.
---@param threads table[] Remote threads at this line
---@param drafts PowerReview.DraftComment[] Local drafts at this line
---@param file_path string
---@param line number
---@return string[] lines, table[] highlights
function M._build_thread_content(threads, drafts, file_path, line)
  local lines = {}
  local hls = {}

  -- Remote threads
  for _, thread in ipairs(threads) do
    if thread.comments then
      for ci, comment in ipairs(thread.comments) do
        local prefix = ci == 1 and ">> " or "   "
        local header = string.format("%s%s  (%s)", prefix, comment.author or "unknown", comment.created_at or "")
        table.insert(lines, header)
        table.insert(hls, {
          group = "Title",
          line = #lines - 1,
          col_start = 0,
          col_end = #header,
        })

        -- Comment body (may be multiline)
        for _, body_line in ipairs(vim.split(comment.body or "", "\n")) do
          table.insert(lines, "   " .. body_line)
        end
        table.insert(lines, "")
      end
    end
  end

  -- Local drafts
  for _, draft in ipairs(drafts) do
    local status_badge = string.format("[%s]", draft.status:upper())
    local author_label = draft.author == "ai" and " (AI)" or ""
    local header = string.format("%s%s %s", status_badge, author_label, draft.created_at or "")
    table.insert(lines, header)

    local hl_group = draft.author == "ai" and "DiagnosticWarn" or "DiagnosticHint"
    table.insert(hls, {
      group = hl_group,
      line = #lines - 1,
      col_start = 0,
      col_end = #status_badge,
    })

    for _, body_line in ipairs(vim.split(draft.body or "", "\n")) do
      table.insert(lines, "   " .. body_line)
    end
    table.insert(lines, "")
  end

  -- Remove trailing empty line
  if #lines > 0 and lines[#lines] == "" then
    table.remove(lines)
  end

  return lines, hls
end

-- ============================================================================
-- Editor visibility toggle & split mode
-- ============================================================================

--- Toggle the editor float visibility (hide/show without destroying).
--- When hidden, the code underneath becomes visible.
--- A global <C-h> keymap is set so the user can bring the editor back.
function M.toggle_editor_visibility()
  if not M._editor then
    return
  end

  if M._editor_hidden then
    -- Show: restore the float window
    pcall(function() M._editor:show() end)
    M._editor_hidden = false
    -- Also restore preview if it was open
    if M._preview then
      pcall(function() M._preview:show() end)
    end
    -- Also restore thread context if it was open
    if M._thread_context then
      pcall(function() M._thread_context:show() end)
    end
    -- Focus the editor
    if M._editor.winid and vim.api.nvim_win_is_valid(M._editor.winid) then
      vim.api.nvim_set_current_win(M._editor.winid)
    end
    -- Remove global unhide keymap
    pcall(vim.keymap.del, "n", "<C-h>")
    log.debug("Editor shown")
  else
    -- Hide: hide the float window
    pcall(function() M._editor:hide() end)
    M._editor_hidden = true
    -- Also hide preview
    if M._preview then
      pcall(function() M._preview:hide() end)
    end
    -- Also hide thread context
    if M._thread_context then
      pcall(function() M._thread_context:hide() end)
    end
    -- Set a temporary global keymap to bring it back
    vim.keymap.set("n", "<C-h>", function()
      M.toggle_editor_visibility()
    end, { noremap = true, desc = "PowerReview: show comment editor" })
    log.debug("Editor hidden (press <C-h> to show)")
  end
end

--- Move the editor between float mode and split mode.
--- In split mode, the editor buffer is shown in a vertical split on the right,
--- allowing side-by-side code + comment editing.
function M.toggle_editor_split()
  if not M._editor or not M._editor.bufnr then
    return
  end
  if not vim.api.nvim_buf_is_valid(M._editor.bufnr) then
    return
  end

  local bufnr = M._editor.bufnr

  if M._editor_split_winid and vim.api.nvim_win_is_valid(M._editor_split_winid) then
    -- Currently in split mode -> move back to float
    -- Close the split window (but keep the buffer)
    vim.api.nvim_win_close(M._editor_split_winid, false)
    M._editor_split_winid = nil

    -- Re-show the nui popup (it still owns the buffer)
    pcall(function() M._editor:show() end)
    M._editor_hidden = false

    -- Focus the float
    if M._editor.winid and vim.api.nvim_win_is_valid(M._editor.winid) then
      vim.api.nvim_set_current_win(M._editor.winid)
    end
    log.info("Editor: float mode")
  else
    -- Currently in float mode -> move to split
    -- Get current content cursor position
    local cursor = { 1, 0 }
    if M._editor.winid and vim.api.nvim_win_is_valid(M._editor.winid) then
      cursor = vim.api.nvim_win_get_cursor(M._editor.winid)
    end

    -- Hide the float (don't destroy — we want to be able to go back)
    pcall(function() M._editor:hide() end)
    M._editor_hidden = true

    -- Also hide preview
    if M._preview then
      pcall(function() M._preview:hide() end)
    end

    -- Create a vertical split on the right and show the editor buffer there
    vim.cmd("botright vsplit")
    local split_winid = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(split_winid, bufnr)
    pcall(vim.api.nvim_win_set_cursor, split_winid, cursor)

    -- Set up split window options
    vim.wo[split_winid].wrap = true
    vim.wo[split_winid].linebreak = true
    vim.wo[split_winid].number = false
    vim.wo[split_winid].signcolumn = "no"
    vim.wo[split_winid].winbar = "%#Comment# <C-s>:save  <C-l>:float  <C-h>:hide  q:cancel %*"

    M._editor_split_winid = split_winid
    M._editor_hidden = false -- technically visible, just in split form

    log.info("Editor: split mode")
  end
end

-- ============================================================================
-- Live markdown preview
-- ============================================================================

--- Create and mount the live preview popup below the editor.
--- The preview mirrors the editor content with treesitter markdown rendering.
---@param editor_winid number The editor's window ID
---@param editor_width number The editor's width
local function create_preview_popup(editor_winid, editor_width)
  M.close_preview()

  local ok_popup, Popup = pcall(require, "nui.popup")
  if not ok_popup then
    return
  end

  -- Get the editor window's position to place preview below it
  local win_pos = vim.api.nvim_win_get_position(editor_winid)
  local editor_height = vim.api.nvim_win_get_height(editor_winid)

  -- Preview goes below the editor: row = editor_top + editor_height + 2 (for border)
  local preview_row = win_pos[1] + editor_height + 2
  local preview_col = win_pos[2]
  local preview_height = math.min(12, vim.o.lines - preview_row - 2)

  if preview_height < 3 then
    -- Not enough space below; try above the editor
    preview_height = math.min(12, win_pos[1] - 2)
    preview_row = win_pos[1] - preview_height - 2
  end

  if preview_height < 3 then
    log.debug("Not enough space for markdown preview")
    return
  end

  local preview = Popup({
    enter = false,
    focusable = false,
    relative = "editor",
    position = {
      row = preview_row,
      col = preview_col,
    },
    size = {
      width = editor_width,
      height = preview_height,
    },
    border = {
      style = "rounded",
      text = {
        top = "  Preview ",
        top_align = "left",
      },
    },
    buf_options = {
      modifiable = false,
      readonly = true,
      filetype = "markdown",
      buftype = "nofile",
    },
    win_options = {
      winhighlight = "Normal:NormalFloat,FloatBorder:FloatBorder",
      wrap = true,
      linebreak = true,
      conceallevel = 2,
      concealcursor = "nvic",
    },
  })

  preview:mount()

  -- Enable treesitter markdown rendering
  vim.schedule(function()
    if preview.bufnr and vim.api.nvim_buf_is_valid(preview.bufnr) then
      pcall(vim.treesitter.start, preview.bufnr, "markdown")
    end
  end)

  M._preview = preview
end

--- Update the preview content from the editor buffer.
---@param editor_bufnr number
local function update_preview(editor_bufnr)
  if not M._preview or not M._preview.bufnr then
    return
  end
  if not vim.api.nvim_buf_is_valid(M._preview.bufnr) then
    return
  end
  if not vim.api.nvim_buf_is_valid(editor_bufnr) then
    return
  end

  local lines = vim.api.nvim_buf_get_lines(editor_bufnr, 0, -1, false)

  vim.bo[M._preview.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(M._preview.bufnr, 0, -1, false, lines)
  vim.bo[M._preview.bufnr].modifiable = false
end

--- Set up debounced live preview updates on the editor buffer.
---@param editor_bufnr number
local function setup_preview_autocmds(editor_bufnr)
  local debounce_ms = 150

  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    buffer = editor_bufnr,
    callback = function()
      -- Debounce: cancel previous timer, start a new one
      if M._preview_timer then
        M._preview_timer:stop()
      end
      M._preview_timer = vim.defer_fn(function()
        update_preview(editor_bufnr)
      end, debounce_ms)
    end,
  })
end

-- ============================================================================
-- Thread context popup (shown above editor when replying)
-- ============================================================================

--- Create and show the thread context popup above the editor.
--- Displays the original thread being replied to in a readonly popup.
---@param editor_winid number The editor's window ID
---@param editor_width number The editor's width
---@param thread table The thread data (from session.threads)
local function create_thread_context_popup(editor_winid, editor_width, thread)
  M.close_thread_context()

  local ok_popup, Popup = pcall(require, "nui.popup")
  if not ok_popup then
    return
  end

  -- Build thread content lines
  local lines = {}
  local hls = {}

  if thread.comments then
    for ci, comment in ipairs(thread.comments) do
      if not comment.is_deleted then
        local prefix = ci == 1 and "" or " "
        local time_str = ""
        if comment.created_at then
          local date = tostring(comment.created_at):match("^(%d%d%d%d%-%d%d%-%d%d)")
          time_str = date and ("  " .. date) or ""
        end
        local author_line = string.format("%s%s%s", prefix, comment.author or "unknown", time_str)
        table.insert(lines, author_line)
        table.insert(hls, { line = #lines - 1, hl = "Title" })

        -- Body
        for _, body_line in ipairs(vim.split(comment.body or "", "\n")) do
          table.insert(lines, "  " .. body_line)
        end

        if ci < #thread.comments then
          table.insert(lines, "  " .. string.rep("╌", math.min(40, editor_width - 6)))
          table.insert(hls, { line = #lines - 1, hl = "Comment" })
        end
      end
    end
  end

  if #lines == 0 then
    lines = { "(empty thread)" }
  end

  -- Position above the editor
  local win_pos = vim.api.nvim_win_get_position(editor_winid)
  local context_height = math.min(#lines + 2, 15, win_pos[1] - 1)
  if context_height < 3 then
    log.debug("Not enough space above editor for thread context")
    return
  end

  local context_row = win_pos[1] - context_height - 2
  if context_row < 0 then
    context_row = 0
  end
  local context_col = win_pos[2]

  local popup = Popup({
    enter = false,
    focusable = false,
    relative = "editor",
    position = {
      row = context_row,
      col = context_col,
    },
    size = {
      width = editor_width,
      height = context_height,
    },
    border = {
      style = "rounded",
      text = {
        top = string.format("  Thread #%s ", tostring(thread.id or "?")),
        top_align = "left",
      },
    },
    buf_options = {
      modifiable = false,
      readonly = true,
      filetype = "markdown",
      buftype = "nofile",
    },
    win_options = {
      winhighlight = "Normal:NormalFloat,FloatBorder:FloatBorder",
      wrap = true,
      linebreak = true,
      conceallevel = 2,
      concealcursor = "nvic",
    },
  })

  popup:mount()

  -- Set content
  vim.bo[popup.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(popup.bufnr, 0, -1, false, lines)
  vim.bo[popup.bufnr].modifiable = false

  -- Apply highlights
  local ns = vim.api.nvim_create_namespace("power_review_thread_context")
  for _, hl in ipairs(hls) do
    pcall(vim.api.nvim_buf_add_highlight, popup.bufnr, ns, hl.hl, hl.line, 0, -1)
  end

  -- Enable treesitter markdown
  vim.schedule(function()
    if popup.bufnr and vim.api.nvim_buf_is_valid(popup.bufnr) then
      pcall(vim.treesitter.start, popup.bufnr, "markdown")
    end
  end)

  M._thread_context = popup
  M._thread_context_visible = true
end

--- Close the thread context popup.
function M.close_thread_context()
  if M._thread_context then
    pcall(function()
      M._thread_context:unmount()
    end)
    M._thread_context = nil
    M._thread_context_visible = false
  end
end

--- Toggle the thread context popup visibility.
---@param editor_winid number
---@param editor_width number
---@param thread table
function M.toggle_thread_context(editor_winid, editor_width, thread)
  if M._thread_context_visible then
    M.close_thread_context()
  else
    create_thread_context_popup(editor_winid, editor_width, thread)
  end
end

-- ============================================================================
-- Comment editor popup
-- ============================================================================

--- Open a floating editor for composing or editing a comment.
---@param opts table { file_path: string, line: number, line_end?: number, session: PowerReview.ReviewSession, draft_id?: string, initial_body?: string, thread_id?: number }
function M.open_comment_editor(opts)
  -- Close any existing editor
  M.close_editor()

  local ok, Popup = pcall(require, "nui.popup")
  if not ok then
    -- Fallback to vim.ui.input
    M._editor_fallback(opts)
    return
  end

  local event = require("nui.utils.autocmd").event
  local ui_cfg = config.get_ui_config()
  local float_cfg = ui_cfg.comments.float

  local is_edit = opts.draft_id ~= nil
  local is_reply = opts.thread_id ~= nil and not is_edit
  local title
  if is_edit then
    title = " Edit Draft "
  elseif is_reply then
    title = " Reply to Thread "
  else
    title = " New Comment "
  end
  local subtitle
  if opts.line_end and opts.line_end ~= opts.line then
    if opts.col_start and opts.col_end then
      subtitle = string.format(" %s:%d:%d-%d:%d ", opts.file_path, opts.line, opts.col_start, opts.line_end, opts.col_end)
    else
      subtitle = string.format(" %s:%d-%d ", opts.file_path, opts.line, opts.line_end)
    end
  else
    if opts.col_start and opts.col_end then
      subtitle = string.format(" %s:%d:%d-%d ", opts.file_path, opts.line, opts.col_start, opts.col_end)
    else
      subtitle = string.format(" %s:%d ", opts.file_path, opts.line)
    end
  end

  local editor = Popup({
    enter = true,
    focusable = true,
    relative = "cursor",
    position = {
      row = 1,
      col = 0,
    },
    size = {
      width = math.min(float_cfg.width, vim.o.columns - 4),
      height = math.min(float_cfg.height, vim.o.lines - 4),
    },
    border = {
      style = "rounded",
      text = {
        top = title .. subtitle,
        top_align = "left",
        bottom = is_reply
          and " <C-s>:save  <C-t>:thread  <C-p>:preview  <C-h>:hide  <C-l>:split  <Esc>:cancel "
          or  " <C-s>:save  <C-p>:preview  <C-h>:hide  <C-l>:split  <Esc>:cancel ",
        bottom_align = "center",
      },
    },
    buf_options = {
      modifiable = true,
      readonly = false,
      filetype = "markdown",
      buftype = "acwrite",
    },
    win_options = {
      winhighlight = "Normal:NormalFloat,FloatBorder:FloatBorder",
      wrap = true,
      linebreak = true,
    },
  })

  editor:mount()

  -- Set initial content if editing
  if opts.initial_body and opts.initial_body ~= "" then
    local body_lines = vim.split(opts.initial_body, "\n")
    vim.api.nvim_buf_set_lines(editor.bufnr, 0, -1, false, body_lines)
  end

  -- Enter insert mode for new comments
  if not is_edit then
    vim.cmd("startinsert")
  end

  -- Save action
  local function save()
    local body_lines = vim.api.nvim_buf_get_lines(editor.bufnr, 0, -1, false)
    local body = table.concat(body_lines, "\n")

    -- Trim trailing whitespace
    body = body:gsub("%s+$", "")

    if body == "" then
      log.warn("Comment body is empty")
      return
    end

    local pr = require("power-review")

    if is_edit then
      -- Edit existing draft
      local ok_edit, err = pr.api.edit_draft_comment(opts.draft_id, body)
      if ok_edit then
        log.info("Draft updated")
        M.close_editor()
      else
        log.error("Failed to update draft: %s", err or "unknown")
      end
    else
      -- Create new draft
      local create_opts = {
        file_path = opts.file_path,
        line_start = opts.line,
        line_end = opts.line_end,
        col_start = opts.col_start,
        col_end = opts.col_end,
        body = body,
        author = "user",
      }
      if opts.thread_id then
        create_opts.thread_id = opts.thread_id
      end
      local draft, err = pr.api.create_draft_comment(create_opts)
      if draft then
        log.info("Draft comment created: %s", draft.id)
        M.close_editor()
      else
        log.error("Failed to create comment: %s", err or "unknown")
      end
    end
  end

  -- Keymaps
  editor:map("n", "<C-s>", save, { noremap = true })
  editor:map("i", "<C-s>", function()
    vim.cmd("stopinsert")
    save()
  end, { noremap = true })

  editor:map("n", "<Esc>", function()
    M.close_editor()
  end, { noremap = true })

  editor:map("n", "q", function()
    M.close_editor()
  end, { noremap = true })

  -- Toggle hide/show the editor float (<C-h>)
  local function toggle_hide()
    M.toggle_editor_visibility()
  end
  editor:map("n", "<C-h>", toggle_hide, { noremap = true })
  editor:map("i", "<C-h>", toggle_hide, { noremap = true })

  -- Move between float and split modes (<C-l>)
  local function toggle_split()
    M.toggle_editor_split()
  end
  editor:map("n", "<C-l>", toggle_split, { noremap = true })
  editor:map("i", "<C-l>", function()
    vim.cmd("stopinsert")
    toggle_split()
  end, { noremap = true })

  -- Handle BufWriteCmd for :w support (since buftype=acwrite)
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = editor.bufnr,
    callback = function()
      save()
      -- Mark buffer as saved to prevent "modified" warnings
      vim.bo[editor.bufnr].modified = false
    end,
  })

  -- Buffer-level keymaps (work in both float and split modes)
  -- These supplement the popup-level maps for when the buffer is in a split window.
  local buf_kopts = { noremap = true, buffer = editor.bufnr }
  vim.keymap.set("n", "<C-s>", save, buf_kopts)
  vim.keymap.set("i", "<C-s>", function()
    vim.cmd("stopinsert")
    save()
  end, buf_kopts)
  vim.keymap.set("n", "<C-h>", function() M.toggle_editor_visibility() end, buf_kopts)
  vim.keymap.set("i", "<C-h>", function() M.toggle_editor_visibility() end, buf_kopts)
  vim.keymap.set("n", "<C-l>", function() M.toggle_editor_split() end, buf_kopts)
  vim.keymap.set("i", "<C-l>", function()
    vim.cmd("stopinsert")
    M.toggle_editor_split()
  end, buf_kopts)
  vim.keymap.set("n", "q", function() M.close_editor() end, buf_kopts)

  -- Live markdown preview: create after editor is fully mounted
  vim.schedule(function()
    if not editor.winid or not vim.api.nvim_win_is_valid(editor.winid) then
      return
    end
    local e_width = vim.api.nvim_win_get_width(editor.winid)
    create_preview_popup(editor.winid, e_width)
    setup_preview_autocmds(editor.bufnr)
    -- Initial render of existing content (for edit mode)
    update_preview(editor.bufnr)
  end)

  -- Toggle preview with <C-p>
  editor:map("n", "<C-p>", function()
    if M._preview then
      M.close_preview()
    else
      if editor.winid and vim.api.nvim_win_is_valid(editor.winid) then
        local e_width = vim.api.nvim_win_get_width(editor.winid)
        create_preview_popup(editor.winid, e_width)
        update_preview(editor.bufnr)
      end
    end
  end, { noremap = true })

  editor:map("i", "<C-p>", function()
    if M._preview then
      M.close_preview()
    else
      if editor.winid and vim.api.nvim_win_is_valid(editor.winid) then
        local e_width = vim.api.nvim_win_get_width(editor.winid)
        create_preview_popup(editor.winid, e_width)
        update_preview(editor.bufnr)
      end
    end
  end, { noremap = true })

  -- Toggle thread context popup (<C-t>) — only for reply-to-thread
  if is_reply and opts.thread_id then
    local function toggle_thread_ctx()
      -- Look up the thread from the session
      local reply_session = opts.session
      local reply_thread = nil
      for _, t in ipairs(reply_session.threads or {}) do
        if t.id == opts.thread_id then
          reply_thread = t
          break
        end
      end
      if not reply_thread then
        log.info("Thread #%s not found in session", tostring(opts.thread_id))
        return
      end
      local e_winid = editor.winid
      if M._editor_split_winid and vim.api.nvim_win_is_valid(M._editor_split_winid) then
        e_winid = M._editor_split_winid
      end
      if not e_winid or not vim.api.nvim_win_is_valid(e_winid) then
        return
      end
      local e_width = vim.api.nvim_win_get_width(e_winid)
      M.toggle_thread_context(e_winid, e_width, reply_thread)
    end
    editor:map("n", "<C-t>", toggle_thread_ctx, { noremap = true })
    editor:map("i", "<C-t>", toggle_thread_ctx, { noremap = true })
    -- Also set buffer-level keymaps for split mode
    vim.keymap.set("n", "<C-t>", toggle_thread_ctx, { noremap = true, buffer = editor.bufnr })
    vim.keymap.set("i", "<C-t>", toggle_thread_ctx, { noremap = true, buffer = editor.bufnr })
  end

  M._editor = editor
  M._editor_opts = opts
  M._editor_hidden = false
  M._editor_split_winid = nil
end

--- Fallback comment editor when nui.nvim is not available.
---@param opts table
function M._editor_fallback(opts)
  local range_label = ""
  if opts.line_end and opts.line_end ~= opts.line then
    range_label = string.format("%s:%d-%d", opts.file_path, opts.line, opts.line_end)
  else
    range_label = string.format("%s:%d", opts.file_path, opts.line)
  end
  local prompt = opts.draft_id and "Edit comment: " or string.format("Comment on %s: ", range_label)
  vim.ui.input({ prompt = prompt, default = opts.initial_body or "" }, function(body)
    if not body or body == "" then
      return
    end

    local pr = require("power-review")
    if opts.draft_id then
      local ok_edit, err = pr.api.edit_draft_comment(opts.draft_id, body)
      if ok_edit then
        log.info("Draft updated")
      else
        log.error("Failed to update draft: %s", err or "unknown")
      end
    else
      local create_opts = {
        file_path = opts.file_path,
        line_start = opts.line,
        line_end = opts.line_end,
        body = body,
        author = "user",
      }
      if opts.thread_id then
        create_opts.thread_id = opts.thread_id
      end
      local draft, err = pr.api.create_draft_comment(create_opts)
      if draft then
        log.info("Draft comment created: %s", draft.id)
      else
        log.error("Failed to create comment: %s", err or "unknown")
      end
    end
  end)
end

-- ============================================================================
-- Lifecycle
-- ============================================================================

--- Close the thread viewer popup.
function M.close()
  if M._popup then
    pcall(function()
      M._popup:unmount()
    end)
    M._popup = nil
  end
end

--- Close the comment editor popup.
function M.close_editor()
  M.close_preview()
  M.close_thread_context()
  -- Close split window if in split mode
  if M._editor_split_winid and vim.api.nvim_win_is_valid(M._editor_split_winid) then
    pcall(vim.api.nvim_win_close, M._editor_split_winid, true)
    M._editor_split_winid = nil
  end
  -- Remove global unhide keymap if set
  pcall(vim.keymap.del, "n", "<C-h>")
  -- Unmount the nui popup
  if M._editor then
    pcall(function()
      M._editor:unmount()
    end)
    M._editor = nil
  end
  M._editor_hidden = false
  M._editor_opts = nil
end

--- Close the live markdown preview popup.
function M.close_preview()
  if M._preview_timer then
    M._preview_timer:stop()
    M._preview_timer = nil
  end
  if M._preview then
    pcall(function()
      M._preview:unmount()
    end)
    M._preview = nil
  end
end

--- Close all floating windows.
function M.close_all()
  M.close()
  M.close_editor()
end

--- Check if the thread viewer is open.
---@return boolean
function M.is_viewer_open()
  return M._popup ~= nil
end

--- Check if the editor is open.
---@return boolean
function M.is_editor_open()
  return M._editor ~= nil
end

-- ============================================================================
-- Helpers
-- ============================================================================

--- Resolve file path from buffer name relative to the review session.
---@param bufnr number
---@param session PowerReview.ReviewSession
---@return string|nil
function M._resolve_file_path(bufnr, session)
  local signs = require("power-review.ui.signs")
  return signs._resolve_review_file_path(bufnr, session)
end

return M
