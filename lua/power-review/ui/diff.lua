--- PowerReview.nvim diff view integration
--- Manages diff viewing through codediff.nvim (primary) or native Neovim diff (fallback).
local M = {}

local log = require("power-review.utils.log")
local config = require("power-review.config")

-- ============================================================================
-- Subtle diff highlights for PowerReview diff windows
-- ============================================================================

--- Highlight groups for toned-down diff colors.
--- These use very low-alpha backgrounds so the diff is visible but not overwhelming.
--- Applied via winhighlight on diff windows only — global diff colors are unaffected.
M._diff_hl_groups = {
  add = "PowerReviewDiffAdd",
  change = "PowerReviewDiffChange",
  delete = "PowerReviewDiffDelete",
  text = "PowerReviewDiffText",
}

--- Define the subtle diff highlight groups.
--- Keeps conventional color meanings (green=added, red=deleted, yellow=changed)
--- but at reduced intensity so they don't overwhelm syntax highlighting and
--- comment virtual text. Works well with dark themes (Catppuccin, etc.)
function M.setup_diff_highlights()
  local colors = config.get().ui.colors or {}
  -- Green for added lines
  vim.api.nvim_set_hl(0, M._diff_hl_groups.add, { default = true, bg = colors.diff_added or "#264a35" })
  -- Yellow/amber tint for changed lines
  vim.api.nvim_set_hl(0, M._diff_hl_groups.change, { default = true, bg = colors.diff_changed or "#2a3040" })
  -- Red for deleted lines
  vim.api.nvim_set_hl(0, M._diff_hl_groups.delete, { default = true, bg = colors.diff_deleted or "#4a2626" })
  -- Brighter highlight for the exact changed text within a changed line
  vim.api.nvim_set_hl(0, M._diff_hl_groups.text, { default = true, bg = colors.diff_text or "#364060" })
end

--- Build the winhighlight string that maps standard Diff* groups to our subtle versions.
---@return string
local function build_diff_winhighlight()
  return string.format(
    "DiffAdd:%s,DiffChange:%s,DiffDelete:%s,DiffText:%s",
    M._diff_hl_groups.add,
    M._diff_hl_groups.change,
    M._diff_hl_groups.delete,
    M._diff_hl_groups.text
  )
end

--- Track open diff state so we can restore/navigate
---@type table|nil
M._current_diff = nil

--- Strip refs/heads/ prefix from branch names (common in AzDO responses)
---@param branch string
---@return string
local function normalize_branch(branch)
  return (branch:gsub("^refs/heads/", ""))
end

--- Get the working directory for diff operations.
--- Uses the worktree path if the session is using worktree strategy,
--- otherwise uses the current working directory.
---@param session PowerReview.ReviewSession
---@return string
local function get_diff_cwd(session)
  if session.worktree_path and vim.fn.isdirectory(session.worktree_path) == 1 then
    return session.worktree_path
  end
  return vim.fn.getcwd()
end

-- ============================================================================
-- codediff.nvim integration
-- ============================================================================

--- Check if codediff.nvim is available and functional.
---@return boolean
function M.has_codediff()
  local ok, _ = pcall(require, "codediff")
  return ok
end

--- Open a single file diff using codediff.nvim.
--- Uses the `CodeDiff file <ref>` command to compare the target branch version
--- against the current (source branch / worktree) version.
---@param session PowerReview.ReviewSession
---@param file_path string Relative file path
---@param callback? fun() Called after the diff view is open
function M.open_file_codediff(session, file_path, callback)
  if not M.has_codediff() then
    log.warn("codediff.nvim is not available")
    return false
  end

  local target = normalize_branch(session.target_branch)
  local diff_cwd = get_diff_cwd(session)
  local full_path = diff_cwd .. "/" .. file_path:gsub("\\", "/")

  -- Normalize path
  full_path = full_path:gsub("\\", "/")

  -- First, open the file so codediff can use it as the current buffer
  local edit_ok, edit_err = pcall(vim.cmd, "edit " .. vim.fn.fnameescape(full_path))
  if not edit_ok then
    log.error("Failed to open file %s: %s", full_path, tostring(edit_err))
    return false
  end

  -- Use CodeDiff file <target_branch> to compare current buffer against target
  local cmd = string.format("CodeDiff file %s", target)
  local ok, err = pcall(vim.cmd, cmd)
  if not ok then
    log.warn("CodeDiff command failed: %s", tostring(err))
    return false
  end

  M._current_diff = {
    file_path = file_path,
    session_id = session.id,
    provider = "codediff",
  }

  log.debug("Opened codediff for %s (vs %s)", file_path, target)

  -- Attach comment signs to diff buffers after codediff opens
  vim.schedule(function()
    local signs = require("power-review.ui.signs")
    signs._attach_visible_diff_buffers()
  end)

  if type(callback) == "function" then
    vim.schedule(callback)
  end
  return true
end

--- Open the full explorer-style diff using codediff.nvim.
--- Shows all changed files in a PR-like merge-base diff.
---@param session PowerReview.ReviewSession
---@param callback? fun() Called after the diff view is open
function M.open_explorer_codediff(session, callback)
  if not M.has_codediff() then
    log.warn("codediff.nvim is not available")
    return false
  end

  local target = normalize_branch(session.target_branch)
  local source = normalize_branch(session.source_branch)

  -- Use merge-base syntax: CodeDiff target...source
  -- This shows only changes introduced since branching from target
  local cmd = string.format("CodeDiff %s...%s", target, source)
  local ok, err = pcall(vim.cmd, cmd)
  if not ok then
    -- Fallback: try target...HEAD (if source isn't fetched yet)
    cmd = string.format("CodeDiff %s...", target)
    ok, err = pcall(vim.cmd, cmd)
    if not ok then
      log.warn("CodeDiff explorer command failed: %s", tostring(err))
      return false
    end
  end

  M._current_diff = {
    file_path = nil, -- explorer mode
    session_id = session.id,
    provider = "codediff",
  }

  log.debug("Opened codediff explorer (%s...%s)", target, source)

  if type(callback) == "function" then
    vim.schedule(callback)
  end
  return true
end

-- ============================================================================
-- Native Neovim diff (fallback)
-- ============================================================================

--- Open a file diff using native Neovim diff mode.
--- Creates a vertical split with target branch version on left and source on right.
---@param session PowerReview.ReviewSession
---@param file_path string Relative file path
---@param callback? fun() Called after the diff view is open
function M.open_file_native(session, file_path, callback)
  local target = normalize_branch(session.target_branch)
  local diff_cwd = get_diff_cwd(session)
  local full_path = diff_cwd .. "/" .. file_path:gsub("\\", "/")

  -- Get the target branch version of the file via git show
  local git_cmd = { "git", "show", target .. ":" .. file_path }
  local result = vim.system(git_cmd, { cwd = diff_cwd, text = true }):wait()

  local target_lines
  if result.code == 0 and result.stdout then
    target_lines = vim.split(result.stdout, "\n", { trimempty = false })
    -- Remove trailing empty line from git output
    if #target_lines > 0 and target_lines[#target_lines] == "" then
      table.remove(target_lines)
    end
  else
    target_lines = { "-- File not found in " .. target .. " (new file) --" }
  end

  -- Open in a new tab for clean workspace
  vim.cmd("tabnew")

  -- Left pane: target branch version (readonly)
  vim.cmd("enew")
  local left_buf = vim.api.nvim_get_current_buf()
  vim.bo[left_buf].buftype = "nofile"
  vim.bo[left_buf].bufhidden = "wipe"
  vim.bo[left_buf].swapfile = false
  vim.bo[left_buf].modifiable = true
  vim.api.nvim_buf_set_name(left_buf, string.format("[%s] %s", target, file_path))
  vim.api.nvim_buf_set_lines(left_buf, 0, -1, false, target_lines)

  -- Set filetype for syntax highlighting
  local ft = vim.filetype.match({ filename = file_path })
  if ft then
    vim.bo[left_buf].filetype = ft
  end
  vim.bo[left_buf].modifiable = false
  vim.cmd("diffthis")

  -- Right pane: current source version
  vim.cmd("vsplit " .. vim.fn.fnameescape(full_path))
  vim.cmd("diffthis")

  -- Set up window-local options for a clean diff view
  -- Apply subtle diff highlights so the diff coloring isn't overwhelming
  M.setup_diff_highlights()
  local diff_winhighlight = build_diff_winhighlight()
  for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    vim.wo[winid].foldmethod = "diff"
    vim.wo[winid].foldlevel = 99
    vim.wo[winid].wrap = false
    vim.wo[winid].signcolumn = "yes"
    -- Append our diff highlight overrides to any existing winhighlight
    local existing = vim.wo[winid].winhighlight or ""
    if existing ~= "" then
      vim.wo[winid].winhighlight = existing .. "," .. diff_winhighlight
    else
      vim.wo[winid].winhighlight = diff_winhighlight
    end
  end

  -- Set up 'q' keymap on both buffers to close the diff tab
  local diff_tabpage = vim.api.nvim_get_current_tabpage()
  local right_buf = vim.api.nvim_get_current_buf()
  for _, buf in ipairs({ left_buf, right_buf }) do
    vim.keymap.set("n", "q", function()
      if vim.api.nvim_tabpage_is_valid(diff_tabpage) then
        local tabnr = vim.api.nvim_tabpage_get_number(diff_tabpage)
        -- If this is the only tab, don't close it (use :q instead)
        if #vim.api.nvim_list_tabpages() > 1 then
          pcall(vim.cmd, tabnr .. "tabclose")
        else
          vim.cmd("confirm qall")
        end
      end
    end, { buffer = buf, silent = true, desc = "[PowerReview] Close diff" })
  end

  M._current_diff = {
    file_path = file_path,
    session_id = session.id,
    provider = "native",
    tabpage = vim.api.nvim_get_current_tabpage(),
  }

  log.debug("Opened native diff for %s (vs %s)", file_path, target)

  -- Attach comment signs to both diff panes.
  -- We do an immediate attach, then schedule a deferred refresh.
  -- The deferred refresh ensures signs appear even if:
  --  (a) diff mode window options weren't fully applied yet
  --  (b) threads were empty at open time but loaded via background sync
  local signs = require("power-review.ui.signs")
  for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local bufnr = vim.api.nvim_win_get_buf(winid)
    signs.attach(bufnr, file_path, session)
  end

  -- Deferred refresh: re-place indicators after the event loop settles.
  -- This catches cases where the sign column or diff state wasn't ready.
  vim.schedule(function()
    signs.refresh()
  end)

  if type(callback) == "function" then
    vim.schedule(callback)
  end
  return true
end

-- ============================================================================
-- Public API
-- ============================================================================

--- Open a diff view for a specific file.
--- Always uses native Neovim diff mode. While codediff.nvim provides a richer
--- diff experience, its TabClosed cleanup handler (cleanup.lua → welcome_window.apply_normal)
--- throws E5108 ("Problem while switching windows") when other plugin windows
--- (e.g., NuiSplit panels, neo-tree) exist during tab close. The native diff
--- avoids this entirely and provides a reliable, self-contained experience.
---@param session PowerReview.ReviewSession
---@param file_path string Relative file path
---@param callback? fun() Called after the diff view is open
---@return boolean success
function M.open_file(session, file_path, callback)
  return M.open_file_native(session, file_path, callback)
end

--- Open the full diff explorer (all files).
--- Only available with codediff.nvim; falls back to opening files panel.
---@param session PowerReview.ReviewSession
---@param callback? fun()
---@return boolean success
function M.open_explorer(session, callback)
  local ui_cfg = config.get_ui_config()
  local provider = ui_cfg.diff.provider

  if provider == "codediff" and M.has_codediff() then
    return M.open_explorer_codediff(session, callback)
  end

  -- No native explorer; inform the user
  log.info("Full diff explorer requires codediff.nvim. Use :PowerReview files to see changed files.")
  return false
end

--- Close the current diff view.
function M.close()
  if not M._current_diff then
    return
  end

  if M._current_diff.provider == "native" and M._current_diff.tabpage then
    -- Close the tab we opened for native diff
    local tabpage = M._current_diff.tabpage
    if vim.api.nvim_tabpage_is_valid(tabpage) then
      local tabnr = vim.api.nvim_tabpage_get_number(tabpage)
      pcall(vim.cmd, tabnr .. "tabclose")
    end
  elseif M._current_diff.provider == "codediff" then
    -- codediff manages its own cleanup via 'q' keymap
    -- We just clear our tracking state
  end

  M._current_diff = nil
end

--- Get the current diff state.
---@return table|nil
function M.get_current()
  return M._current_diff
end

--- Check if a diff view is currently open.
---@return boolean
function M.is_open()
  return M._current_diff ~= nil
end

-- ============================================================================
-- Iteration diff (between two commit SHAs)
-- ============================================================================

--- Open a diff view between two commit SHAs for a specific file.
--- Shows what changed between the last-reviewed iteration and the current one.
--- Left pane = file at old_commit (previously reviewed), right pane = file at new_commit (current).
---@param session PowerReview.ReviewSession
---@param file_path string Relative file path
---@param old_commit string The previously-reviewed source commit SHA
---@param new_commit string The current source commit SHA
---@param callback? fun(err?: string) Called after the diff view is open
---@return boolean success
function M.open_iteration_diff(session, file_path, old_commit, new_commit, callback)
  callback = callback or function() end

  local diff_cwd = get_diff_cwd(session)

  -- Get the old commit version of the file
  local old_cmd = { "git", "show", old_commit .. ":" .. file_path }
  local old_result = vim.system(old_cmd, { cwd = diff_cwd, text = true }):wait()

  local old_lines
  if old_result.code == 0 and old_result.stdout then
    old_lines = vim.split(old_result.stdout, "\n", { trimempty = false })
    if #old_lines > 0 and old_lines[#old_lines] == "" then
      table.remove(old_lines)
    end
  else
    old_lines = { "-- File not found at " .. old_commit:sub(1, 8) .. " (new file in this iteration) --" }
  end

  -- Get the new commit version of the file
  local new_cmd = { "git", "show", new_commit .. ":" .. file_path }
  local new_result = vim.system(new_cmd, { cwd = diff_cwd, text = true }):wait()

  local new_lines
  if new_result.code == 0 and new_result.stdout then
    new_lines = vim.split(new_result.stdout, "\n", { trimempty = false })
    if #new_lines > 0 and new_lines[#new_lines] == "" then
      table.remove(new_lines)
    end
  else
    new_lines = { "-- File not found at " .. new_commit:sub(1, 8) .. " (deleted in this iteration) --" }
  end

  -- Open in a new tab
  vim.cmd("tabnew")

  -- Left pane: old commit version (readonly)
  vim.cmd("enew")
  local left_buf = vim.api.nvim_get_current_buf()
  vim.bo[left_buf].buftype = "nofile"
  vim.bo[left_buf].bufhidden = "wipe"
  vim.bo[left_buf].swapfile = false
  vim.bo[left_buf].modifiable = true
  vim.api.nvim_buf_set_name(left_buf, string.format("[%s] %s", old_commit:sub(1, 8), file_path))
  vim.api.nvim_buf_set_lines(left_buf, 0, -1, false, old_lines)

  local ft = vim.filetype.match({ filename = file_path })
  if ft then
    vim.bo[left_buf].filetype = ft
  end
  vim.bo[left_buf].modifiable = false
  vim.cmd("diffthis")

  -- Right pane: new commit version (readonly)
  vim.cmd("vnew")
  local right_buf = vim.api.nvim_get_current_buf()
  vim.bo[right_buf].buftype = "nofile"
  vim.bo[right_buf].bufhidden = "wipe"
  vim.bo[right_buf].swapfile = false
  vim.bo[right_buf].modifiable = true
  vim.api.nvim_buf_set_name(right_buf, string.format("[%s] %s", new_commit:sub(1, 8), file_path))
  vim.api.nvim_buf_set_lines(right_buf, 0, -1, false, new_lines)

  if ft then
    vim.bo[right_buf].filetype = ft
  end
  vim.bo[right_buf].modifiable = false
  vim.cmd("diffthis")

  -- Apply subtle diff highlights
  M.setup_diff_highlights()
  local diff_winhighlight = build_diff_winhighlight()
  for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    vim.wo[winid].foldmethod = "diff"
    vim.wo[winid].foldlevel = 99
    vim.wo[winid].wrap = false
    local existing = vim.wo[winid].winhighlight or ""
    if existing ~= "" then
      vim.wo[winid].winhighlight = existing .. "," .. diff_winhighlight
    else
      vim.wo[winid].winhighlight = diff_winhighlight
    end
  end

  -- Set up 'q' keymap to close the iteration diff tab
  local diff_tabpage = vim.api.nvim_get_current_tabpage()
  for _, buf in ipairs({ left_buf, right_buf }) do
    vim.keymap.set("n", "q", function()
      if vim.api.nvim_tabpage_is_valid(diff_tabpage) then
        local tabnr = vim.api.nvim_tabpage_get_number(diff_tabpage)
        if #vim.api.nvim_list_tabpages() > 1 then
          pcall(vim.cmd, tabnr .. "tabclose")
        else
          vim.cmd("confirm qall")
        end
      end
    end, { buffer = buf, silent = true, desc = "[PowerReview] Close iteration diff" })
  end

  M._current_diff = {
    file_path = file_path,
    session_id = session.id,
    provider = "iteration",
    tabpage = diff_tabpage,
    old_commit = old_commit,
    new_commit = new_commit,
  }

  log.debug("Opened iteration diff for %s (%s..%s)", file_path, old_commit:sub(1, 8), new_commit:sub(1, 8))

  if type(callback) == "function" then
    vim.schedule(function() callback(nil) end)
  end
  return true
end

return M
