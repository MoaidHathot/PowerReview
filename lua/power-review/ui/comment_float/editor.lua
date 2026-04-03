--- PowerReview.nvim comment float — comment editor popup
--- Floating editor for composing or editing draft comments, with live preview
--- and thread context support.
local M = {}

local log = require("power-review.utils.log")
local config = require("power-review.config")
local preview = require("power-review.ui.comment_float.preview")
local layout = require("power-review.ui.comment_float.layout")

--- Open a floating editor for composing or editing a comment.
---@param opts table { file_path: string, line: number, line_end?: number, session: PowerReview.ReviewSession, draft_id?: string, initial_body?: string, thread_id?: number, col_start?: number, col_end?: number }
---@param float_module table Reference to the parent comment_float module
function M.open(opts, float_module)
  -- Close any existing editor
  float_module.close_editor()

  local ok, Popup = pcall(require, "nui.popup")
  if not ok then
    -- Fallback to vim.ui.input
    M.fallback(opts)
    return
  end

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
  if not opts.line then
    -- File-level comment
    subtitle = string.format(" %s (file-level) ", opts.file_path)
  elseif opts.line_end and opts.line_end ~= opts.line then
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
        float_module.close_editor()
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
        float_module.close_editor()
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
    float_module.close_editor()
  end, { noremap = true })

  editor:map("n", "q", function()
    float_module.close_editor()
  end, { noremap = true })

  -- Toggle hide/show the editor float (<C-h>)
  local function toggle_hide()
    layout.toggle_editor_visibility(float_module)
  end
  editor:map("n", "<C-h>", toggle_hide, { noremap = true })
  editor:map("i", "<C-h>", toggle_hide, { noremap = true })

  -- Move between float and split modes (<C-l>)
  local function toggle_split()
    layout.toggle_editor_split(float_module)
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
  vim.keymap.set("n", "<C-h>", function() layout.toggle_editor_visibility(float_module) end, buf_kopts)
  vim.keymap.set("i", "<C-h>", function() layout.toggle_editor_visibility(float_module) end, buf_kopts)
  vim.keymap.set("n", "<C-l>", function() layout.toggle_editor_split(float_module) end, buf_kopts)
  vim.keymap.set("i", "<C-l>", function()
    vim.cmd("stopinsert")
    layout.toggle_editor_split(float_module)
  end, buf_kopts)
  vim.keymap.set("n", "q", function() float_module.close_editor() end, buf_kopts)

  -- Live markdown preview: create after editor is fully mounted
  vim.schedule(function()
    if not editor.winid or not vim.api.nvim_win_is_valid(editor.winid) then
      return
    end
    local e_width = vim.api.nvim_win_get_width(editor.winid)
    preview.create_preview_popup(editor.winid, e_width, float_module)
    preview.setup_preview_autocmds(editor.bufnr, float_module)
    -- Initial render of existing content (for edit mode)
    preview.update_preview(editor.bufnr, float_module)
  end)

  -- Toggle preview with <C-p>
  editor:map("n", "<C-p>", function()
    if float_module._preview then
      preview.close_preview(float_module)
    else
      if editor.winid and vim.api.nvim_win_is_valid(editor.winid) then
        local e_width = vim.api.nvim_win_get_width(editor.winid)
        preview.create_preview_popup(editor.winid, e_width, float_module)
        preview.update_preview(editor.bufnr, float_module)
      end
    end
  end, { noremap = true })

  editor:map("i", "<C-p>", function()
    if float_module._preview then
      preview.close_preview(float_module)
    else
      if editor.winid and vim.api.nvim_win_is_valid(editor.winid) then
        local e_width = vim.api.nvim_win_get_width(editor.winid)
        preview.create_preview_popup(editor.winid, e_width, float_module)
        preview.update_preview(editor.bufnr, float_module)
      end
    end
  end, { noremap = true })

  -- Toggle thread context popup (<C-t>) -- only for reply-to-thread
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
      if float_module._editor_split_winid and vim.api.nvim_win_is_valid(float_module._editor_split_winid) then
        e_winid = float_module._editor_split_winid
      end
      if not e_winid or not vim.api.nvim_win_is_valid(e_winid) then
        return
      end
      local e_width = vim.api.nvim_win_get_width(e_winid)
      preview.toggle_thread_context(e_winid, e_width, reply_thread, float_module)
    end
    editor:map("n", "<C-t>", toggle_thread_ctx, { noremap = true })
    editor:map("i", "<C-t>", toggle_thread_ctx, { noremap = true })
    -- Also set buffer-level keymaps for split mode
    vim.keymap.set("n", "<C-t>", toggle_thread_ctx, { noremap = true, buffer = editor.bufnr })
    vim.keymap.set("i", "<C-t>", toggle_thread_ctx, { noremap = true, buffer = editor.bufnr })
  end

  float_module._editor = editor
  float_module._editor_opts = opts
  float_module._editor_hidden = false
  float_module._editor_split_winid = nil

  -- Show code context above the editor (the lines being commented on)
  if opts.line and opts.file_path and not is_reply then
    vim.schedule(function()
      if not editor.winid or not vim.api.nvim_win_is_valid(editor.winid) then
        return
      end
      M._show_code_context(editor.winid, opts, float_module)
    end)
  end
end

--- Fallback comment editor when nui.nvim is not available.
---@param opts table
function M.fallback(opts)
  local range_label = ""
  if not opts.line then
    range_label = string.format("%s (file-level)", opts.file_path)
  elseif opts.line_end and opts.line_end ~= opts.line then
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

--- Show a code context popup above the editor displaying the lines being commented on.
--- Reads from the review working directory or the current buffer.
---@param editor_winid number
---@param opts table Editor opts with file_path, line, line_end, session
---@param float_module table Reference to the parent comment_float module
function M._show_code_context(editor_winid, opts, float_module)
  -- Close any existing code context popup
  M._close_code_context(float_module)

  local ok_popup, Popup = pcall(require, "nui.popup")
  if not ok_popup then
    return
  end

  local line_start = opts.line
  local line_end = opts.line_end or line_start
  local context_before = 2
  local context_after = 2
  local read_from = math.max(1, line_start - context_before)
  local read_to = line_end + context_after

  -- Try to read the file content
  local file_lines
  local session = opts.session

  -- Try reading from review working directory via signs resolution
  local source_bufnr = nil
  local signs_mod = require("power-review.ui.signs")
  for bufnr, info in pairs(signs_mod._attached_bufs) do
    if info.file_path == opts.file_path and vim.api.nvim_buf_is_valid(bufnr) then
      source_bufnr = bufnr
      break
    end
  end

  if source_bufnr then
    local total = vim.api.nvim_buf_line_count(source_bufnr)
    read_to = math.min(read_to, total)
    file_lines = vim.api.nvim_buf_get_lines(source_bufnr, read_from - 1, read_to, false)
  else
    -- Fallback: try reading from worktree path
    local base = session and session.worktree_path or vim.fn.getcwd()
    local full_path = base:gsub("[\\/]$", "") .. "/" .. opts.file_path:gsub("\\", "/")
    local ok_read, content = pcall(vim.fn.readfile, full_path, "", read_to)
    if ok_read and #content >= read_from then
      file_lines = {}
      for i = read_from, math.min(read_to, #content) do
        table.insert(file_lines, content[i])
      end
    end
  end

  if not file_lines or #file_lines == 0 then
    return
  end

  -- Build display lines with line numbers and highlight indicators
  local display_lines = {}
  for i, line in ipairs(file_lines) do
    local actual_line = read_from + i - 1
    local prefix
    local is_target = actual_line >= line_start and actual_line <= line_end
    if is_target then
      prefix = string.format(" %3d ", actual_line)
    else
      prefix = string.format("  %3d ", actual_line)
    end
    table.insert(display_lines, prefix .. line)
  end

  -- Detect filetype for syntax highlighting
  local ext = opts.file_path:match("%.([^%.]+)$")
  local ft = ext and vim.filetype.match({ filename = "file." .. ext }) or nil

  -- Position above the editor
  local win_pos = vim.api.nvim_win_get_position(editor_winid)
  local editor_width = vim.api.nvim_win_get_width(editor_winid)
  local context_height = math.min(#display_lines, 12, win_pos[1] - 1)

  if context_height < 1 then
    return
  end

  local context_row = win_pos[1] - context_height - 2
  if context_row < 0 then
    context_row = 0
  end

  local popup = Popup({
    enter = false,
    focusable = false,
    relative = "editor",
    position = {
      row = context_row,
      col = win_pos[2],
    },
    size = {
      width = editor_width,
      height = context_height,
    },
    border = {
      style = "rounded",
      text = {
        top = string.format("  %s:%d ", opts.file_path, line_start),
        top_align = "left",
      },
    },
    buf_options = {
      modifiable = false,
      readonly = true,
      buftype = "nofile",
    },
    win_options = {
      winhighlight = "Normal:NormalFloat,FloatBorder:FloatBorder",
      wrap = false,
      number = false,
      cursorline = false,
    },
  })

  popup:mount()

  vim.bo[popup.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(popup.bufnr, 0, -1, false, display_lines)
  vim.bo[popup.bufnr].modifiable = false

  -- Highlight target lines
  local ns = vim.api.nvim_create_namespace("power_review_code_context")
  for i, _ in ipairs(display_lines) do
    local actual_line = read_from + i - 1
    if actual_line >= line_start and actual_line <= line_end then
      pcall(vim.api.nvim_buf_set_extmark, popup.bufnr, ns, i - 1, 0, {
        line_hl_group = "Visual",
        priority = 50,
      })
    end
  end

  -- Try to apply syntax highlighting
  if ft then
    vim.schedule(function()
      if popup.bufnr and vim.api.nvim_buf_is_valid(popup.bufnr) then
        pcall(vim.treesitter.start, popup.bufnr, ft)
      end
    end)
  end

  float_module._code_context = popup
end

--- Close the code context popup.
---@param float_module table Reference to the parent comment_float module
function M._close_code_context(float_module)
  if float_module._code_context then
    pcall(function()
      float_module._code_context:unmount()
    end)
    float_module._code_context = nil
  end
end

return M
