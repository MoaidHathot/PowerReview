--- PowerReview.nvim floating comment window
--- Displays comment threads and draft editor in a nui.nvim popup.
---
--- This is the orchestrator module that wires together:
---   thread_viewer — thread/draft viewer popup with keymaps
---   editor        — comment editor popup with save, preview, and split support
---   preview       — live markdown preview and thread context popups
---   layout        — editor visibility toggle and float/split mode switching
local M = {}

local preview_mod = require("power-review.ui.comment_float.preview")

-- ============================================================================
-- Module state
-- ============================================================================

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
-- Public API
-- ============================================================================

--- Open a floating window showing comment threads at the cursor line.
--- Shows remote comments + local drafts, with option to reply or create new.
---@param opts? table { bufnr?: number, line?: number }
function M.open_thread_viewer(opts)
  local thread_viewer = require("power-review.ui.comment_float.thread_viewer")
  thread_viewer.open(opts, M)
end

--- Open a floating editor for composing or editing a comment.
---@param opts table { file_path: string, line: number, line_end?: number, session: PowerReview.ReviewSession, draft_id?: string, initial_body?: string, thread_id?: number, col_start?: number, col_end?: number }
function M.open_comment_editor(opts)
  local editor = require("power-review.ui.comment_float.editor")
  editor.open(opts, M)
end

--- Toggle the editor float visibility (hide/show without destroying).
function M.toggle_editor_visibility()
  local layout = require("power-review.ui.comment_float.layout")
  layout.toggle_editor_visibility(M)
end

--- Move the editor between float mode and split mode.
function M.toggle_editor_split()
  local layout = require("power-review.ui.comment_float.layout")
  layout.toggle_editor_split(M)
end

--- Toggle the thread context popup visibility.
---@param editor_winid number
---@param editor_width number
---@param thread table
function M.toggle_thread_context(editor_winid, editor_width, thread)
  preview_mod.toggle_thread_context(editor_winid, editor_width, thread, M)
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
  preview_mod.close_preview(M)
  preview_mod.close_thread_context(M)
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
  preview_mod.close_preview(M)
end

--- Close the thread context popup.
function M.close_thread_context()
  preview_mod.close_thread_context(M)
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

--- Build content lines and highlights for the thread viewer.
--- (Delegated to thread_viewer submodule, exposed here for backwards compatibility)
---@param threads table[]
---@param drafts PowerReview.DraftComment[]
---@param file_path string
---@param line number
---@return string[] lines, table[] highlights
function M._build_thread_content(threads, drafts, file_path, line)
  local thread_viewer = require("power-review.ui.comment_float.thread_viewer")
  return thread_viewer.build_thread_content(threads, drafts, file_path, line)
end

--- Fallback comment editor when nui.nvim is not available.
--- (Delegated to editor submodule, exposed here for backwards compatibility)
---@param opts table
function M._editor_fallback(opts)
  local editor = require("power-review.ui.comment_float.editor")
  editor.fallback(opts)
end

return M
