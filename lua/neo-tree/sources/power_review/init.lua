--- Neo-tree custom source for PowerReview.nvim
--- Displays changed files from the active PR review session.
---
--- Users register this source in their neo-tree setup:
---   require("neo-tree").setup({
---     sources = { "filesystem", "buffers", "git_status", "power_review" },
---   })
---
--- Then open with:  :Neotree source=power_review
local renderer = require("neo-tree.ui.renderer")
local manager = require("neo-tree.sources.manager")
local events = require("neo-tree.events")
local utils = require("neo-tree.utils")

local M = {
  name = "power_review",
  display_name = " 󰍉 Review ",
}

--- Default config for this source. Neo-tree picks this up automatically so
--- users don't have to specify renderers manually.
M.default_config = {
  renderers = {
    pr_root = {
      { "indent" },
      { "icon" },
      { "name" },
      { "comment_count" },
    },
    pr_dir = {
      { "indent" },
      { "icon" },
      { "name" },
    },
    pr_file = {
      { "indent" },
      { "change_type" },
      { "icon" },
      { "comment_count" },
      { "name" },
      { "file_stats" },
    },
    message = {
      { "indent" },
      { "icon" },
      { "name" },
    },
  },
}

local wrap = function(func)
  return utils.wrap(func, M.name)
end

local refresh = wrap(manager.refresh)

--- Build the tree items from the current review session's changed files.
--- Uses a flat file list (no directory grouping) with change type marks.
--- Each file shows its full relative path with M/A/D/R prefix for easy scanning.
---@param session PowerReview.ReviewSession
---@return table[] items
local function build_items(session)
  local helpers = require("power-review.session_helpers")
  local counts = helpers.get_draft_counts(session)

  -- Root node: PR info
  local root = {
    id = "pr_root",
    name = string.format("PR #%d: %s", session.pr_id, session.pr_title),
    type = "pr_root",
    loaded = true,
    children = {},
    extra = {
      pr_id = session.pr_id,
      pr_title = session.pr_title,
      pr_author = session.pr_author,
      source_branch = session.source_branch,
      target_branch = session.target_branch,
      draft_counts = counts,
      provider_type = session.provider_type,
    },
  }

  -- Sort files by path for a clean flat list
  local sorted_files = {}
  for _, file in ipairs(session.files) do
    table.insert(sorted_files, file)
  end
  table.sort(sorted_files, function(a, b)
    return a.path < b.path
  end)

  -- Flat file list: each file as a direct child of the root node
  for _, file in ipairs(sorted_files) do
    local file_drafts = session_mod.get_drafts_for_file(session, file.path)
    local file_threads = session_mod.get_threads_for_file(session, file.path)

    table.insert(root.children, {
      id = "file:" .. file.path,
      name = file.path, -- Full relative path for flat view
      type = "pr_file",
      path = file.path,
      extra = {
        file_path = file.path,
        original_path = file.original_path,
        change_type = file.change_type,
        additions = file.additions,
        deletions = file.deletions,
        draft_count = #file_drafts,
        thread_count = #file_threads,
      },
    })
  end

  return { root }
end

--- Build a "no session" placeholder tree
---@return table[] items
local function build_empty_items()
  return {
    {
      id = "no_session",
      name = "No active review session",
      type = "message",
      extra = {
        message = "Use :PowerReview open <url> to start a review",
      },
    },
  }
end

--- Navigate: the main entry point called by neo-tree to render this source.
---@param state table Neo-tree state object
---@param path string? Not used for this source
---@param path_to_reveal string? Node ID to focus after rendering
---@param callback function? Called after navigation completes
---@param async boolean? Not used
M.navigate = function(state, path, path_to_reveal, callback, async)
  state.dirty = false
  state.path = path or vim.fn.getcwd()

  if path_to_reveal then
    renderer.position.set(state, path_to_reveal)
  end

  -- Get the current review session
  local pr = require("power-review")
  local session = pr.get_current_session()

  local items
  if session and session.files and #session.files > 0 then
    items = build_items(session)
    -- Auto-expand the root node
    state.default_expanded_nodes = { "pr_root" }
  else
    items = build_empty_items()
  end

  renderer.show_nodes(items, state)

  if type(callback) == "function" then
    vim.schedule(callback)
  end
end

--- Setup: register event subscriptions for this source.
---@param config table Source-specific config
---@param global_config table Global neo-tree config
M.setup = function(config, global_config)
  -- Refresh when a buffer is entered (in case session changed externally)
  manager.subscribe(M.name, {
    event = events.VIM_BUFFER_ENTER,
    handler = function(_args)
      -- Only refresh if the source is actually visible
      local state = manager.get_state(M.name)
      if state and state.winid and vim.api.nvim_win_is_valid(state.winid) then
        if state.dirty then
          refresh()
        end
      end
    end,
  })

  -- Mark dirty when the directory changes (could indicate worktree switch)
  manager.subscribe(M.name, {
    event = events.VIM_DIR_CHANGED,
    handler = function(_args)
      local state = manager.get_state(M.name)
      if state then
        state.dirty = true
      end
    end,
  })
end

--- Utility: called by PowerReview when session data changes (files refresh, drafts change, etc.)
--- External code can call this to trigger a neo-tree refresh.
M.refresh_if_visible = function()
  local ok, mgr = pcall(require, "neo-tree.sources.manager")
  if not ok then
    return
  end
  local state = mgr.get_state(M.name)
  if state and state.winid and vim.api.nvim_win_is_valid(state.winid) then
    mgr.refresh(M.name)
  else
    -- Mark dirty so it refreshes when next shown
    if state then
      state.dirty = true
    end
  end
end

return M
