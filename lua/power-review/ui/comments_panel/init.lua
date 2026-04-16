--- PowerReview.nvim all-comments split panel
--- A nui.nvim NuiSplit panel listing all comments across all files.
--- Supports both remote threads and local drafts with full markdown bodies,
--- code context snippets, expandable reply threads, and treesitter rendering.
---
--- This is the orchestrator module that wires together:
---   highlights  — highlight group definitions and lazy creation
---   renderer    — section building and buffer rendering
---   highlighter — fenced code block syntax highlighting via treesitter
---   window      — window management, file/diff openers, sticky footer
---   keymaps     — keymap handler setup
local M = {}

local log = require("power-review.utils.log")
local config = require("power-review.config")

local highlights = require("power-review.ui.comments_panel.highlights")
local renderer = require("power-review.ui.comments_panel.renderer")
local highlighter = require("power-review.ui.comments_panel.highlighter")
local window = require("power-review.ui.comments_panel.window")
local keymaps = require("power-review.ui.comments_panel.keymaps")

-- ============================================================================
-- Module state
-- ============================================================================

---@type table|nil The NuiSplit instance
M._split = nil
---@type boolean
M._visible = false
---@type PowerReview.PanelSection[] Flat list of rendered sections for jump/fold tracking
M._sections = {}
---@type table<string, boolean> Collapsed state: key -> is_collapsed
M._collapsed = {}
---@type PowerReview.ReviewSession|nil Cached session
M._session = nil

-- Wire window helpers so they can access the split without circular requires.
window.set_split_ref(function()
  return M._split
end)

-- ============================================================================
-- Panel lifecycle
-- ============================================================================

--- Toggle the all-comments panel.
---@param session PowerReview.ReviewSession
function M.toggle(session)
  if M._visible then
    M.close()
  else
    M.open(session)
  end
end

--- Open the all-comments panel.
---@param session PowerReview.ReviewSession
function M.open(session)
  local ok_nui, NuiSplit = pcall(require, "nui.split")
  if not ok_nui then
    M._quickfix_fallback(session)
    return
  end

  highlights.ensure()

  local ui_cfg = config.get_ui_config()
  local panel_cfg = ui_cfg.comments.panel

  -- Close existing panel if any
  M.close()

  -- Create split
  local position = panel_cfg.position or "right"
  local size_key = (position == "right" or position == "left") and "width" or "height"
  local size_val = panel_cfg[size_key] or 60

  local split = NuiSplit({
    relative = "editor",
    position = position,
    size = size_val,
    buf_options = {
      modifiable = false,
      filetype = "power-review-comments",
      buftype = "nofile",
      swapfile = false,
    },
    win_options = {
      number = false,
      relativenumber = false,
      signcolumn = "no",
      cursorline = true,
      wrap = false,
      winhighlight = "Normal:NormalFloat,CursorLine:Visual",
      conceallevel = 2,
      concealcursor = "nc",
    },
  })

  split:mount()

  M._split = split
  M._visible = true
  M._session = session

  -- Build and render
  M._render(session)

  -- Setup keymaps
  keymaps.setup(split, session, M)

  -- Set the sticky footer (always-visible keymap hints)
  window.set_sticky_footer(split.winid)

  -- NOTE: We intentionally do NOT start treesitter markdown on this buffer.
  -- The panel uses section-based rendering with indented body text (4-8 spaces).
  -- Treesitter markdown misinterprets this indentation as code blocks and
  -- applies unwanted highlighting that clashes with our extmark-based system.
  -- Instead, fenced code blocks get language-specific treesitter highlighting
  -- via highlighter.apply() in the render pipeline.

  -- Re-render on panel resize so text wrapping adapts to new width
  vim.api.nvim_create_autocmd("WinResized", {
    callback = function()
      if not M._visible or not M._split or not M._split.winid then
        return true -- remove autocmd
      end
      if not vim.api.nvim_win_is_valid(M._split.winid) then
        return true
      end
      -- Check if our panel window is among the resized windows
      local resized = vim.v.event and vim.v.event.windows or {}
      for _, winid in ipairs(resized) do
        if winid == M._split.winid and M._session then
          M._render(M._session)
          return
        end
      end
    end,
  })
end

--- Render (or re-render) the panel content.
---@param session PowerReview.ReviewSession
function M._render(session)
  if not M._split or not M._split.bufnr then
    return
  end
  if not vim.api.nvim_buf_is_valid(M._split.bufnr) then
    return
  end

  -- Compute current panel width for text wrapping
  local panel_width
  if M._split.winid and vim.api.nvim_win_is_valid(M._split.winid) then
    panel_width = vim.api.nvim_win_get_width(M._split.winid)
  end

  local sections = renderer.build_sections(session, panel_width, M._collapsed)
  renderer.render_sections(M._split.bufnr, sections)
  highlighter.apply(M._split.bufnr)
  M._sections = sections
  M._session = session
end

--- Close the panel.
function M.close()
  if M._split then
    pcall(function()
      M._split:unmount()
    end)
    M._split = nil
    M._visible = false
    M._sections = {}
    M._session = nil
  end
end

--- Refresh the panel content.
---@param session PowerReview.ReviewSession
function M.refresh(session)
  if not M._visible then
    return
  end
  M._render(session)
end

--- Check if the panel is visible.
---@return boolean
function M.is_visible()
  return M._visible
end

-- ============================================================================
-- Quickfix fallback
-- ============================================================================

--- Quickfix fallback when nui.nvim is not available.
---@param session PowerReview.ReviewSession
function M._quickfix_fallback(session)
  local review = require("power-review.review")
  local all_threads = review.get_all_threads(session)
  local qf_items = {}

  -- Drafts
  for _, draft in ipairs(session.drafts) do
    table.insert(qf_items, {
      filename = draft.file_path,
      lnum = draft.line_start,
      text = string.format("[%s] %s: %s", draft.status:upper(), draft.author, draft.body:sub(1, 80)),
    })
  end

  -- Remote threads
  for _, thread in ipairs(all_threads) do
    if thread.type ~= "draft" and thread.file_path then
      local first = thread.comments and thread.comments[1]
      table.insert(qf_items, {
        filename = thread.file_path,
        lnum = thread.line_start or 1,
        text = string.format(
          "[THREAD] %s: %s",
          first and first.author or "unknown",
          first and first.body:sub(1, 80) or ""
        ),
      })
    end
  end

  if #qf_items == 0 then
    log.info("No comments in this review")
    return
  end

  vim.fn.setqflist(qf_items, "r")
  vim.fn.setqflist({}, "a", { title = "PowerReview Comments" })
  vim.cmd("copen")
end

return M
