--- Neo-tree commands for the PowerReview source
--- Defines keybinding actions available when the power_review source is active.
local cc = require("neo-tree.sources.common.commands")
local manager = require("neo-tree.sources.manager")
local utils = require("neo-tree.utils")

local M = {}

local SOURCE_NAME = "power_review"
local refresh = utils.wrap(manager.refresh, SOURCE_NAME)

--- Open the selected file's diff view (using codediff.nvim or fallback)
---@param state table Neo-tree state
M.open = function(state)
  local node = state.tree:get_node()
  if not node then
    return
  end

  -- Only act on file nodes
  if node.type ~= "pr_file" then
    return
  end

  local file_path = node.extra and node.extra.file_path
  if not file_path then
    return
  end

  local pr = require("power-review")
  local session = pr.get_current_session()
  if not session then
    vim.notify("[PowerReview] No active review session", vim.log.levels.WARN)
    return
  end

  -- Delegate to the UI coordinator for diff opening
  local ui = require("power-review.ui")
  ui.open_file_diff(session, file_path)
end

--- Open file in a vertical split
---@param state table Neo-tree state
M.open_vsplit = function(state)
  -- For review files, "open" always means "open diff"
  M.open(state)
end

--- Open file in a horizontal split
---@param state table Neo-tree state
M.open_split = function(state)
  M.open(state)
end

--- Open file in a new tab
---@param state table Neo-tree state
M.open_tabnew = function(state)
  M.open(state)
end

--- Toggle node expansion (for directory nodes)
---@param state table Neo-tree state
M.toggle_node = function(state)
  local node = state.tree:get_node()
  if not node then
    return
  end

  if node:has_children() then
    if node:is_expanded() then
      node:collapse()
    else
      node:expand()
    end
    require("neo-tree.ui.renderer").redraw(state)
  else
    -- If it's a file node, open it
    M.open(state)
  end
end

--- Add a comment on the selected file
---@param state table Neo-tree state
M.add_comment = function(state)
  local node = state.tree:get_node()
  if not node or node.type ~= "pr_file" then
    vim.notify("[PowerReview] Select a file to add a comment", vim.log.levels.INFO)
    return
  end

  local file_path = node.extra and node.extra.file_path
  if not file_path then
    return
  end

  -- Open the file diff first, then let the user add a comment there
  local pr = require("power-review")
  local session = pr.get_current_session()
  if not session then
    vim.notify("[PowerReview] No active review session", vim.log.levels.WARN)
    return
  end

  local ui = require("power-review.ui")
  ui.open_file_diff(session, file_path, function()
    -- After the diff is open, trigger comment creation
    ui.add_comment()
  end)
end

--- Show file details in a floating window
---@param state table Neo-tree state
M.show_file_details = function(state)
  local node = state.tree:get_node()
  if not node or not node.extra then
    return
  end

  local lines = {}
  if node.type == "pr_root" then
    local e = node.extra
    table.insert(lines, "PR #" .. tostring(e.pr_id) .. ": " .. (e.pr_title or ""))
    table.insert(lines, "Author: " .. (e.pr_author or ""))
    table.insert(lines, "Branch: " .. (e.source_branch or "") .. " -> " .. (e.target_branch or ""))
    if e.draft_counts then
      table.insert(
        lines,
        string.format(
          "Drafts: %d total (%d draft, %d pending, %d submitted)",
          e.draft_counts.total,
          e.draft_counts.draft,
          e.draft_counts.pending,
          e.draft_counts.submitted
        )
      )
    end
  elseif node.type == "pr_file" then
    local e = node.extra
    table.insert(lines, "File: " .. (e.file_path or ""))
    table.insert(lines, "Change: " .. (e.change_type or ""))
    if e.original_path then
      table.insert(lines, "Renamed from: " .. e.original_path)
    end
    if e.additions then
      table.insert(lines, "Additions: +" .. tostring(e.additions))
    end
    if e.deletions then
      table.insert(lines, "Deletions: -" .. tostring(e.deletions))
    end
    if e.draft_count and e.draft_count > 0 then
      table.insert(lines, "Draft comments: " .. tostring(e.draft_count))
    end
  elseif node.type == "pr_dir" then
    local e = node.extra
    table.insert(lines, "Directory: " .. (e.dir_path or ""))
    table.insert(lines, "Files: " .. tostring(e.file_count or 0))
  end

  if #lines > 0 then
    vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
  end
end

--- Refresh the review data from remote
---@param state table Neo-tree state
M.refresh = function(state)
  local pr = require("power-review")
  local session = pr.get_current_session()
  if not session then
    vim.notify("[PowerReview] No active review session", vim.log.levels.WARN)
    return
  end

  local review = require("power-review.review")
  review.refresh_session(function(err)
    if err then
      vim.notify("[PowerReview] Refresh failed: " .. err, vim.log.levels.ERROR)
    else
      vim.notify("[PowerReview] Session refreshed", vim.log.levels.INFO)
      refresh()
    end
  end)
end

--- Copy file path to clipboard
---@param state table Neo-tree state
M.copy_path = function(state)
  local node = state.tree:get_node()
  if not node or not node.extra then
    return
  end
  local path = node.extra.file_path or node.extra.dir_path
  if path then
    vim.fn.setreg("+", path)
    vim.notify("[PowerReview] Copied: " .. path, vim.log.levels.INFO)
  end
end

--- Toggle the reviewed status of the selected file.
--- If currently reviewed, unmarks it. If not reviewed, marks it.
---@param state table Neo-tree state
M.toggle_reviewed = function(state)
  local node = state.tree:get_node()
  if not node or node.type ~= "pr_file" then
    vim.notify("[PowerReview] Select a file to toggle reviewed status", vim.log.levels.INFO)
    return
  end

  local file_path = node.extra and node.extra.file_path
  if not file_path then
    return
  end

  local review = require("power-review.review")
  review.toggle_reviewed(file_path, function(err)
    if err then
      vim.notify("[PowerReview] " .. err, vim.log.levels.ERROR)
    else
      refresh()
    end
  end)
end

--- Mark all changed files as reviewed.
---@param state table Neo-tree state
M.mark_all_reviewed = function(state)
  local review = require("power-review.review")
  review.mark_all_reviewed(function(err)
    if err then
      vim.notify("[PowerReview] " .. err, vim.log.levels.ERROR)
    else
      vim.notify("[PowerReview] All files marked as reviewed", vim.log.levels.INFO)
      refresh()
    end
  end)
end

-- Add common commands that we don't override
cc._add_common_commands(M)

return M
