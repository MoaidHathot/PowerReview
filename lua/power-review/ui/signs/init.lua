--- PowerReview.nvim comment signs & extmarks
--- Re-exports submodules and maintains backward-compatible API surface.
---
--- Submodules:
---   highlights  — highlight group definitions
---   extmarks    — core extmark placement & virtual text formatting
---   indicators  — building indicators from session data
---   navigation  — goto next/prev comment
---   attach      — buffer attachment, auto-attach, path resolution
---   flash       — temporary flash highlight effects
local M = {}

local highlights = require("power-review.ui.signs.highlights")
local extmarks = require("power-review.ui.signs.extmarks")
local indicators_mod = require("power-review.ui.signs.indicators")
local navigation = require("power-review.ui.signs.navigation")
local attach_mod = require("power-review.ui.signs.attach")
local flash_mod = require("power-review.ui.signs.flash")

-- Re-export namespace and highlight groups for external consumers
M._ns = extmarks.ns
M._hl_groups = highlights.groups
M._flash_ns = flash_mod.ns

-- Re-export attached_bufs for external access (statusline, keymaps, etc.)
M._attached_bufs = attach_mod.attached_bufs

-- ============================================================================
-- Highlight setup
-- ============================================================================

M.setup_highlights = highlights.setup

-- ============================================================================
-- Core extmark placement
-- ============================================================================

M.set_indicators = extmarks.set_indicators

-- Expose internal formatters for backward compatibility
M._format_remote_virt_text = extmarks._format_remote_virt_text
M._format_draft_virt_text = extmarks._format_draft_virt_text

-- ============================================================================
-- Building indicators from session data
-- ============================================================================

M.build_indicators = indicators_mod.build

-- ============================================================================
-- Buffer attachment & lifecycle
-- ============================================================================

function M.attach(bufnr, file_path, session)
  attach_mod.attach(bufnr, file_path, session, indicators_mod.build, extmarks.set_indicators)
end

function M.detach(bufnr)
  attach_mod.detach(bufnr, extmarks.ns)
end

function M.detach_all()
  attach_mod.detach_all(extmarks.ns)
end

function M.refresh()
  attach_mod.refresh(indicators_mod.build, extmarks.set_indicators)
end

function M.refresh_file(file_path)
  attach_mod.refresh_file(file_path, indicators_mod.build, extmarks.set_indicators)
end

-- ============================================================================
-- Query API
-- ============================================================================

function M.get_indicators_at_line(bufnr, line)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return {}
  end

  local info = attach_mod.attached_bufs[bufnr]
  if not info then
    return {}
  end

  local pr = require("power-review")
  local session = pr.get_current_session()
  if not session or session.id ~= info.session_id then
    return {}
  end

  local all_indicators = indicators_mod.build(session, info.file_path)
  local at_line = {}
  for _, ind in ipairs(all_indicators) do
    if ind.line == line then
      table.insert(at_line, ind)
    elseif ind.line_end and line >= ind.line and line <= ind.line_end then
      table.insert(at_line, ind)
    end
  end
  return at_line
end

-- ============================================================================
-- Navigation
-- ============================================================================

function M.goto_next(direction)
  navigation.goto_next(direction, attach_mod.attached_bufs, indicators_mod.build)
end

function M.goto_next_comment()
  M.goto_next(1)
end

function M.goto_prev_comment()
  M.goto_next(-1)
end

-- ============================================================================
-- Flash highlight
-- ============================================================================

M.flash_highlight = flash_mod.highlight

-- ============================================================================
-- Path resolution (for external consumers)
-- ============================================================================

M._resolve_review_file_path = attach_mod.resolve_review_file_path
M._is_review_file = attach_mod._is_review_file

-- ============================================================================
-- Auto-attach setup
-- ============================================================================

function M.setup_autocommands()
  local function try_auto_attach(bufnr)
    if attach_mod.attached_bufs[bufnr] then
      return
    end

    local pr = require("power-review")
    local session = pr.get_current_session()
    if not session then
      return
    end

    local file_path = attach_mod.resolve_review_file_path(bufnr, session)
    if file_path then
      M.attach(bufnr, file_path, session)
    end
  end

  local function attach_visible()
    local pr = require("power-review")
    local session = pr.get_current_session()
    if not session then
      return
    end

    for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      local bufnr = vim.api.nvim_win_get_buf(winid)
      if not attach_mod.attached_bufs[bufnr] then
        local file_path = attach_mod.resolve_review_file_path(bufnr, session)
        if file_path then
          M.attach(bufnr, file_path, session)
        end
      end
    end
  end

  attach_mod.setup_autocommands(try_auto_attach, attach_visible, function() M.refresh() end)
end

-- ============================================================================
-- Module initialization
-- ============================================================================

function M.setup()
  M.setup_highlights()
  M.setup_autocommands()
end

return M
