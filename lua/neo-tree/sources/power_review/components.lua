--- Neo-tree custom components for the PowerReview source
--- Provides change type indicators, draft counts, and custom name rendering.
local common = require("neo-tree.sources.common.components")
local highlights = require("neo-tree.ui.highlights")

local M = {}

--- Highlight groups for PowerReview (defined here, created in setup)
local HL = {
  PR_ROOT = "PowerReviewNeoTreeRoot",
  DIR_NAME = "PowerReviewNeoTreeDir",
  FILE_ADD = "PowerReviewNeoTreeAdded",
  FILE_EDIT = "PowerReviewNeoTreeModified",
  FILE_DELETE = "PowerReviewNeoTreeDeleted",
  FILE_RENAME = "PowerReviewNeoTreeRenamed",
  CHANGE_ICON = "PowerReviewNeoTreeChangeIcon",
  DRAFT_COUNT = "PowerReviewNeoTreeDraftCount",
  THREAD_COUNT = "PowerReviewNeoTreeThreadCount",
  STATS_ADD = "PowerReviewNeoTreeStatsAdd",
  STATS_DEL = "PowerReviewNeoTreeStatsDel",
  MESSAGE = "PowerReviewNeoTreeMessage",
  REVIEW_DONE = "PowerReviewNeoTreeReviewDone",
  REVIEW_CHANGED = "PowerReviewNeoTreeReviewChanged",
  REVIEW_PROGRESS = "PowerReviewNeoTreeReviewProgress",
}

--- Create highlight groups if they don't already exist
local hl_created = false
local function ensure_highlights()
  if hl_created then
    return
  end
  hl_created = true

  -- Use safe defaults that link to common highlight groups
  local links = {
    [HL.PR_ROOT] = "NeoTreeRootName",
    [HL.DIR_NAME] = "NeoTreeDirectoryName",
    [HL.FILE_ADD] = "DiffAdd",
    [HL.FILE_EDIT] = "DiffChange",
    [HL.FILE_DELETE] = "DiffDelete",
    [HL.FILE_RENAME] = "DiffText",
    [HL.CHANGE_ICON] = "Comment",
    [HL.DRAFT_COUNT] = "DiagnosticWarn",
    [HL.THREAD_COUNT] = "DiagnosticInfo",
    [HL.STATS_ADD] = "DiffAdd",
    [HL.STATS_DEL] = "DiffDelete",
    [HL.MESSAGE] = "Comment",
    [HL.REVIEW_DONE] = "DiagnosticOk",
    [HL.REVIEW_CHANGED] = "DiagnosticWarn",
    [HL.REVIEW_PROGRESS] = "Comment",
  }

  for hl_name, link_to in pairs(links) do
    -- Only set if not already defined (allows user overrides)
    local ok, existing = pcall(vim.api.nvim_get_hl, 0, { name = hl_name })
    if not ok or vim.tbl_isempty(existing) then
      vim.api.nvim_set_hl(0, hl_name, { link = link_to })
    end
  end
end

--- Change type icons and highlight mapping
local change_type_config = {
  add = { icon = "A", hl = HL.FILE_ADD },
  edit = { icon = "M", hl = HL.FILE_EDIT },
  delete = { icon = "D", hl = HL.FILE_DELETE },
  rename = { icon = "R", hl = HL.FILE_RENAME },
}

--- Component: change_type_icon
--- Renders the file change type indicator (A/M/D/R) before the file name.
---@param config table Component config
---@param node table NuiTree.Node
---@param state table Neo-tree state
---@return table
M.change_type = function(config, node, state)
  ensure_highlights()

  if node.type ~= "pr_file" then
    return {}
  end

  local change_type = node.extra and node.extra.change_type
  if not change_type then
    return {}
  end

  local ct = change_type_config[change_type]
  if not ct then
    return { text = "? ", highlight = HL.CHANGE_ICON }
  end

  return { text = ct.icon .. " ", highlight = ct.hl }
end

--- Component: draft_count (LEGACY — kept for backward compatibility)
--- Shows the number of draft comments on a file as a badge.
---@param config table Component config
---@param node table NuiTree.Node
---@param state table Neo-tree state
---@return table
M.draft_count = function(config, node, state)
  ensure_highlights()

  if node.type ~= "pr_file" then
    -- For the root node, show total draft count
    if node.type == "pr_root" and node.extra and node.extra.draft_counts then
      local counts = node.extra.draft_counts
      if counts.total + (counts.actions_total or 0) > 0 then
        return {
          text = string.format(" [%d drafts, %d actions]", counts.total, counts.actions_total or 0),
          highlight = HL.DRAFT_COUNT,
        }
      end
    end
    return {}
  end

  local count = node.extra and node.extra.draft_count or 0
  if count == 0 then
    return {}
  end

  return {
    text = string.format(" [%d]", count),
    highlight = HL.DRAFT_COUNT,
  }
end

--- Component: comment_count
--- Shows combined thread + draft counts as a badge.
--- Placed BEFORE the filename so it's always visible even when long names truncate.
--- Format: " N  N " (thread icon + draft icon with counts)
---@param config table Component config
---@param node table NuiTree.Node
---@param state table Neo-tree state
---@return table[]
M.comment_count = function(config, node, state)
  ensure_highlights()

  if node.type == "pr_root" then
    -- Root node: show aggregate counts
    if node.extra and node.extra.draft_counts then
      local counts = node.extra.draft_counts
      if counts.total + (counts.actions_total or 0) > 0 then
        return {
          text = string.format(" [%d drafts, %d actions]", counts.total, counts.actions_total or 0),
          highlight = HL.DRAFT_COUNT,
        }
      end
    end
    return {}
  end

  if node.type ~= "pr_file" then
    return {}
  end

  local thread_n = node.extra and node.extra.thread_count or 0
  local draft_n = node.extra and node.extra.draft_count or 0

  if thread_n == 0 and draft_n == 0 then
    return {}
  end

  -- Build a multi-segment badge using a list of {text, highlight} pairs.
  -- Neo-tree components can return a list of tables for multi-highlight segments.
  local parts = {}
  if thread_n > 0 then
    table.insert(parts, { text = string.format(" %d", thread_n), highlight = HL.THREAD_COUNT })
  end
  if draft_n > 0 then
    table.insert(parts, { text = string.format(" %d", draft_n), highlight = HL.DRAFT_COUNT })
  end
  -- Add trailing space to separate from filename
  if #parts > 0 then
    parts[#parts].text = parts[#parts].text .. " "
  end

  -- Neo-tree components expect a single {text, highlight} table, not a list.
  -- Concatenate into a single string, using the most important highlight.
  local combined_text = ""
  for _, p in ipairs(parts) do
    combined_text = combined_text .. p.text
  end
  local primary_hl = draft_n > 0 and HL.DRAFT_COUNT or HL.THREAD_COUNT

  return {
    text = combined_text,
    highlight = primary_hl,
  }
end

--- Component: review_status
--- Shows the review status indicator for a file:
---  = reviewed,  = changed since last review, nothing for unreviewed.
--- For the root node, shows review progress summary (e.g., "3/10 reviewed").
---@param config table Component config
---@param node table NuiTree.Node
---@param state table Neo-tree state
---@return table
M.review_status = function(config, node, state)
  ensure_highlights()

  if node.type == "pr_root" then
    -- Root node: show review progress
    local progress = node.extra and node.extra.review_progress
    if not progress or progress.total == 0 then
      return {}
    end
    -- Only show if at least one file has been reviewed or changed
    if progress.reviewed == 0 and progress.changed == 0 then
      return {}
    end
    local text = string.format(" [%d/%d reviewed", progress.reviewed, progress.total)
    if progress.changed > 0 then
      text = text .. string.format(", %d changed", progress.changed)
    end
    text = text .. "]"
    local hl = progress.reviewed == progress.total and HL.REVIEW_DONE or HL.REVIEW_PROGRESS
    return { text = text, highlight = hl }
  end

  if node.type ~= "pr_file" then
    return {}
  end

  local status = node.extra and node.extra.review_status
  if not status or status == "unreviewed" then
    return {}
  end

  if status == "reviewed" then
    return { text = " ", highlight = HL.REVIEW_DONE }
  elseif status == "changed" then
    return { text = " ", highlight = HL.REVIEW_CHANGED }
  end

  return {}
end

--- Component: file_stats
--- Shows +additions/-deletions for a file.
---@param config table Component config
---@param node table NuiTree.Node
---@param state table Neo-tree state
---@return table[]
M.file_stats = function(config, node, state)
  ensure_highlights()

  if node.type ~= "pr_file" then
    return {}
  end

  local adds = node.extra and node.extra.additions
  local dels = node.extra and node.extra.deletions
  if not adds and not dels then
    return {}
  end

  local result = {}
  if adds and adds > 0 then
    table.insert(result, { text = " +" .. tostring(adds), highlight = HL.STATS_ADD })
  end
  if dels and dels > 0 then
    table.insert(result, { text = " -" .. tostring(dels), highlight = HL.STATS_DEL })
  end

  return result
end

--- Component: name (override)
--- Custom name rendering for PowerReview nodes.
---@param config table Component config
---@param node table NuiTree.Node
---@param state table Neo-tree state
---@return table
M.name = function(config, node, state)
  ensure_highlights()

  local name = node.name or ""
  local highlight = config.highlight or highlights.FILE_NAME

  if node.type == "pr_root" then
    highlight = HL.PR_ROOT
  elseif node.type == "pr_dir" then
    highlight = HL.DIR_NAME
    -- Add trailing slash for directories
    name = name .. "/"
  elseif node.type == "pr_file" then
    -- Use change-type-specific highlight for the file name
    local change_type = node.extra and node.extra.change_type
    if change_type and change_type_config[change_type] then
      highlight = change_type_config[change_type].hl
    end
  elseif node.type == "message" then
    highlight = HL.MESSAGE
  end

  return {
    text = name,
    highlight = highlight,
  }
end

--- Component: icon (override)
--- Custom icons for PowerReview node types.
---@param config table Component config
---@param node table NuiTree.Node
---@param state table Neo-tree state
---@return table
M.icon = function(config, node, state)
  ensure_highlights()

  if node.type == "pr_root" then
    return { text = " ", highlight = HL.PR_ROOT }
  elseif node.type == "pr_dir" then
    local is_expanded = node:is_expanded()
    return {
      text = is_expanded and " " or " ",
      highlight = HL.DIR_NAME,
    }
  elseif node.type == "pr_file" then
    -- Use devicons if available, otherwise use a generic file icon
    local ok, devicons = pcall(require, "nvim-web-devicons")
    if ok then
      local filename = vim.fn.fnamemodify(node.extra and node.extra.file_path or node.name or "", ":t")
      local ext = vim.fn.fnamemodify(filename, ":e")
      local icon, icon_hl = devicons.get_icon(filename, ext, { default = true })
      if icon then
        return { text = icon .. " ", highlight = icon_hl or highlights.FILE_ICON }
      end
    end
    return { text = " ", highlight = highlights.FILE_ICON }
  elseif node.type == "message" then
    return { text = " ", highlight = HL.MESSAGE }
  end

  return {}
end

-- Merge with common components (our overrides take precedence)
return vim.tbl_deep_extend("force", common, M)
