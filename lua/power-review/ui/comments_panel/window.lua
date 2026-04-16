--- PowerReview.nvim comments panel — window management helpers
local M = {}

local log = require("power-review.utils.log")

--- Reference to the parent module's _split field (set via M.set_split_ref).
---@type fun(): table|nil
M._get_split = function()
  return nil
end

--- Set the getter function for the current split reference.
---@param getter fun(): table|nil
function M.set_split_ref(getter)
  M._get_split = getter
end

--- Check if a window belongs to the comments panel.
---@param winid number
---@return boolean
function M.is_panel_window(winid)
  if not vim.api.nvim_win_is_valid(winid) then
    return false
  end
  local split = M._get_split()
  if not split then
    return false
  end
  -- Check by winid
  if split.winid and split.winid == winid then
    return true
  end
  -- Also check by bufnr (more robust — survives window recreation)
  if split.bufnr then
    local win_buf = vim.api.nvim_win_get_buf(winid)
    if win_buf == split.bufnr then
      return true
    end
  end
  return false
end

--- Find or create a window to the LEFT of the comments panel.
--- The panel is a NuiSplit on the right side. We want to open files in the
--- main editor area (any non-panel window). If no suitable window exists,
--- we create a vertical split from the panel and move left.
---@return number winid The window ID to use
function M.find_or_create_left_window()
  local wins = vim.api.nvim_tabpage_list_wins(0)
  local candidates = {}
  for _, winid in ipairs(wins) do
    if not M.is_panel_window(winid) then
      local win_cfg = vim.api.nvim_win_get_config(winid)
      if win_cfg.relative == "" then
        table.insert(candidates, winid)
      end
    end
  end

  if #candidates > 0 then
    local prev_winid = vim.fn.win_getid(vim.fn.winnr("#"))
    if prev_winid ~= 0 and not M.is_panel_window(prev_winid) then
      for _, winid in ipairs(candidates) do
        if winid == prev_winid then
          return prev_winid
        end
      end
    end
    return candidates[1]
  end

  -- No suitable window found — create one by splitting from the panel
  local split = M._get_split()
  local panel_winid = split and split.winid or nil
  if panel_winid and vim.api.nvim_win_is_valid(panel_winid) then
    vim.api.nvim_set_current_win(panel_winid)
    vim.cmd("leftabove vnew")
    local new_winid = vim.api.nvim_get_current_win()
    return new_winid
  end

  -- Last resort: just use the current window
  return vim.api.nvim_get_current_win()
end

--- Resolve the full file path for a section's file_path relative to the session.
---@param session PowerReview.ReviewSession
---@param rel_path string Relative file path from section data
---@return string full_path
function M.resolve_full_path(session, rel_path)
  local base
  if session.worktree_path and vim.fn.isdirectory(session.worktree_path) == 1 then
    base = session.worktree_path
  else
    base = vim.fn.getcwd()
  end
  local full = base .. "/" .. rel_path:gsub("\\", "/")
  return full:gsub("\\", "/")
end

--- Open a raw file (no diff) to the left of the comments panel,
--- scrolled to the comment's target line with flash highlight.
---@param section PowerReview.PanelSection
---@param session PowerReview.ReviewSession
function M.open_file_action(section, session)
  local data = section.data
  if not data.file_path then
    log.info("No file path for this section")
    return
  end

  local full_path = M.resolve_full_path(session, data.file_path)
  local target_winid = M.find_or_create_left_window()

  if M.is_panel_window(target_winid) then
    log.warn("Could not find a non-panel window to open file")
    return
  end

  vim.api.nvim_set_current_win(target_winid)
  local ok, err = pcall(vim.cmd, "edit " .. vim.fn.fnameescape(full_path))
  if not ok then
    log.error("Failed to open file: %s", tostring(err))
    return
  end

  local bufnr = vim.api.nvim_win_get_buf(target_winid)
  local signs = require("power-review.ui.signs")

  if not signs._attached_bufs[bufnr] then
    signs.attach(bufnr, data.file_path, session)
  end

  if data.line_start then
    signs.flash_highlight({
      bufnr = bufnr,
      winid = target_winid,
      line_start = data.line_start,
      line_end = data.line_end or data.line_start,
      col_start = data.col_start,
      col_end = data.col_end,
    })
  end
end

--- Open a diff view for the comment's file using native diff.
---@param section PowerReview.PanelSection
---@param session PowerReview.ReviewSession
function M.open_diff_action(section, session)
  local data = section.data
  if not data.file_path then
    log.info("No file path for this section")
    return
  end

  local target_winid = M.find_or_create_left_window()
  if not M.is_panel_window(target_winid) then
    vim.api.nvim_set_current_win(target_winid)
  end

  local diff_mod = require("power-review.ui.diff")

  local success = diff_mod.open_file_native(session, data.file_path, function()
    if not data.line_start then
      return
    end

    local signs = require("power-review.ui.signs")
    local current_win = vim.api.nvim_get_current_win()
    local current_buf = vim.api.nvim_win_get_buf(current_win)

    signs.flash_highlight({
      bufnr = current_buf,
      winid = current_win,
      line_start = data.line_start,
      line_end = data.line_end or data.line_start,
      col_start = data.col_start,
      col_end = data.col_end,
    })
  end)

  if not success then
    log.warn("Failed to open diff for %s", data.file_path)
  end
end

--- Set up the sticky header bar on the panel window.
---@param winid number
function M.set_sticky_footer(winid)
  if not winid or not vim.api.nvim_win_is_valid(winid) then
    return
  end
  local bar = table.concat({
    "%#PowerReviewPanelBar#",
    " o:file  gd:diff  a:add  e:edit  d:del  A:approve  R:refresh  q:close",
    "%*",
  }, "")

  vim.schedule(function()
    if not vim.api.nvim_win_is_valid(winid) then
      return
    end
    vim.wo[winid].winbar = bar

    local existing_whl = vim.wo[winid].winhighlight or ""
    if not existing_whl:find("WinBar") then
      local sep = existing_whl ~= "" and "," or ""
      vim.wo[winid].winhighlight = existing_whl .. sep .. "WinBar:PowerReviewPanelBar,WinBarNC:PowerReviewPanelBar"
    end
  end)
end

return M
