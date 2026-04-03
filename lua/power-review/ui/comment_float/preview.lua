--- PowerReview.nvim comment float — live markdown preview & thread context popups
local M = {}

local log = require("power-review.utils.log")
local config = require("power-review.config")

-- ============================================================================
-- Live markdown preview
-- ============================================================================

--- Create and mount the live preview popup below the editor.
--- The preview mirrors the editor content with treesitter markdown rendering.
---@param editor_winid number The editor's window ID
---@param editor_width number The editor's width
---@param float_module table Reference to the parent comment_float module
function M.create_preview_popup(editor_winid, editor_width, float_module)
  M.close_preview(float_module)

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

  float_module._preview = preview
end

--- Update the preview content from the editor buffer.
---@param editor_bufnr number
---@param float_module table Reference to the parent comment_float module
function M.update_preview(editor_bufnr, float_module)
  if not float_module._preview or not float_module._preview.bufnr then
    return
  end
  if not vim.api.nvim_buf_is_valid(float_module._preview.bufnr) then
    return
  end
  if not vim.api.nvim_buf_is_valid(editor_bufnr) then
    return
  end

  local lines = vim.api.nvim_buf_get_lines(editor_bufnr, 0, -1, false)

  vim.bo[float_module._preview.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(float_module._preview.bufnr, 0, -1, false, lines)
  vim.bo[float_module._preview.bufnr].modifiable = false
end

--- Set up debounced live preview updates on the editor buffer.
---@param editor_bufnr number
---@param float_module table Reference to the parent comment_float module
function M.setup_preview_autocmds(editor_bufnr, float_module)
  local debounce_ms = (config.get().ui.comments or {}).preview_debounce or 150

  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    buffer = editor_bufnr,
    callback = function()
      -- Debounce: cancel previous timer, start a new one
      if float_module._preview_timer then
        float_module._preview_timer:stop()
      end
      float_module._preview_timer = vim.defer_fn(function()
        M.update_preview(editor_bufnr, float_module)
      end, debounce_ms)
    end,
  })
end

--- Close the live markdown preview popup.
---@param float_module table Reference to the parent comment_float module
function M.close_preview(float_module)
  if float_module._preview_timer then
    float_module._preview_timer:stop()
    float_module._preview_timer = nil
  end
  if float_module._preview then
    pcall(function()
      float_module._preview:unmount()
    end)
    float_module._preview = nil
  end
end

-- ============================================================================
-- Thread context popup (shown above editor when replying)
-- ============================================================================

--- Create and show the thread context popup above the editor.
--- Displays the original thread being replied to in a readonly popup.
---@param editor_winid number The editor's window ID
---@param editor_width number The editor's width
---@param thread table The thread data (from session.threads)
---@param float_module table Reference to the parent comment_float module
function M.create_thread_context_popup(editor_winid, editor_width, thread, float_module)
  M.close_thread_context(float_module)

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

  float_module._thread_context = popup
  float_module._thread_context_visible = true
end

--- Close the thread context popup.
---@param float_module table Reference to the parent comment_float module
function M.close_thread_context(float_module)
  if float_module._thread_context then
    pcall(function()
      float_module._thread_context:unmount()
    end)
    float_module._thread_context = nil
    float_module._thread_context_visible = false
  end
end

--- Toggle the thread context popup visibility.
---@param editor_winid number
---@param editor_width number
---@param thread table
---@param float_module table Reference to the parent comment_float module
function M.toggle_thread_context(editor_winid, editor_width, thread, float_module)
  if float_module._thread_context_visible then
    M.close_thread_context(float_module)
  else
    M.create_thread_context_popup(editor_winid, editor_width, thread, float_module)
  end
end

return M
