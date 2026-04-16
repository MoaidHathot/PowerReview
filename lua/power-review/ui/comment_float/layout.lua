--- PowerReview.nvim comment float — editor visibility toggle & split mode
local M = {}

local log = require("power-review.utils.log")

--- Toggle the editor float visibility (hide/show without destroying).
--- When hidden, the code underneath becomes visible.
--- A global <C-h> keymap is set so the user can bring the editor back.
---@param float_module table Reference to the parent comment_float module
function M.toggle_editor_visibility(float_module)
  if not float_module._editor then
    return
  end

  if float_module._editor_hidden then
    -- Show: restore the float window
    pcall(function()
      float_module._editor:show()
    end)
    float_module._editor_hidden = false
    -- Also restore preview if it was open
    if float_module._preview then
      pcall(function()
        float_module._preview:show()
      end)
    end
    -- Also restore thread context if it was open
    if float_module._thread_context then
      pcall(function()
        float_module._thread_context:show()
      end)
    end
    -- Focus the editor
    if float_module._editor.winid and vim.api.nvim_win_is_valid(float_module._editor.winid) then
      vim.api.nvim_set_current_win(float_module._editor.winid)
    end
    -- Remove global unhide keymap
    pcall(vim.keymap.del, "n", "<C-h>")
    log.debug("Editor shown")
  else
    -- Hide: hide the float window
    pcall(function()
      float_module._editor:hide()
    end)
    float_module._editor_hidden = true
    -- Also hide preview
    if float_module._preview then
      pcall(function()
        float_module._preview:hide()
      end)
    end
    -- Also hide thread context
    if float_module._thread_context then
      pcall(function()
        float_module._thread_context:hide()
      end)
    end
    -- Set a temporary global keymap to bring it back
    vim.keymap.set("n", "<C-h>", function()
      M.toggle_editor_visibility(float_module)
    end, { noremap = true, desc = "PowerReview: show comment editor" })
    log.debug("Editor hidden (press <C-h> to show)")
  end
end

--- Move the editor between float mode and split mode.
--- In split mode, the editor buffer is shown in a vertical split on the right,
--- allowing side-by-side code + comment editing.
---@param float_module table Reference to the parent comment_float module
function M.toggle_editor_split(float_module)
  if not float_module._editor or not float_module._editor.bufnr then
    return
  end
  if not vim.api.nvim_buf_is_valid(float_module._editor.bufnr) then
    return
  end

  local bufnr = float_module._editor.bufnr

  if float_module._editor_split_winid and vim.api.nvim_win_is_valid(float_module._editor_split_winid) then
    -- Currently in split mode -> move back to float
    -- Close the split window (but keep the buffer)
    vim.api.nvim_win_close(float_module._editor_split_winid, false)
    float_module._editor_split_winid = nil

    -- Re-show the nui popup (it still owns the buffer)
    pcall(function()
      float_module._editor:show()
    end)
    float_module._editor_hidden = false

    -- Focus the float
    if float_module._editor.winid and vim.api.nvim_win_is_valid(float_module._editor.winid) then
      vim.api.nvim_set_current_win(float_module._editor.winid)
    end
    log.info("Editor: float mode")
  else
    -- Currently in float mode -> move to split
    -- Get current content cursor position
    local cursor = { 1, 0 }
    if float_module._editor.winid and vim.api.nvim_win_is_valid(float_module._editor.winid) then
      cursor = vim.api.nvim_win_get_cursor(float_module._editor.winid)
    end

    -- Hide the float (don't destroy -- we want to be able to go back)
    pcall(function()
      float_module._editor:hide()
    end)
    float_module._editor_hidden = true

    -- Also hide preview
    if float_module._preview then
      pcall(function()
        float_module._preview:hide()
      end)
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

    float_module._editor_split_winid = split_winid
    float_module._editor_hidden = false -- technically visible, just in split form

    log.info("Editor: split mode")
  end
end

return M
