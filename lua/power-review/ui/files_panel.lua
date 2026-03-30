--- PowerReview.nvim built-in file panel
--- A nui.nvim-based split panel showing changed files for users without neo-tree.
--- This is the fallback when config.ui.files.provider == "builtin".
local M = {}

local log = require("power-review.utils.log")

---@type table|nil The NuiSplit instance
M._split = nil
---@type table|nil The NuiTree instance
M._tree = nil
---@type boolean Whether the panel is currently visible
M._visible = false

--- Highlight groups for the builtin panel
local HL = {
  ROOT = "PowerReviewPanelRoot",
  DIR = "PowerReviewPanelDir",
  FILE_ADD = "PowerReviewPanelAdded",
  FILE_EDIT = "PowerReviewPanelModified",
  FILE_DELETE = "PowerReviewPanelDeleted",
  FILE_RENAME = "PowerReviewPanelRenamed",
  DRAFT_COUNT = "PowerReviewPanelDraftCount",
  THREAD_COUNT = "PowerReviewPanelThreadCount",
  STATS_ADD = "PowerReviewPanelStatsAdd",
  STATS_DEL = "PowerReviewPanelStatsDel",
  CHANGE_ICON = "PowerReviewPanelChangeIcon",
  EXPANDER = "PowerReviewPanelExpander",
  TITLE = "PowerReviewPanelTitle",
}

--- Change type config
local change_type_config = {
  add = { icon = "A", hl = HL.FILE_ADD },
  edit = { icon = "M", hl = HL.FILE_EDIT },
  delete = { icon = "D", hl = HL.FILE_DELETE },
  rename = { icon = "R", hl = HL.FILE_RENAME },
}

local hl_created = false
local function ensure_highlights()
  if hl_created then
    return
  end
  hl_created = true

  local links = {
    [HL.ROOT] = "Title",
    [HL.DIR] = "Directory",
    [HL.FILE_ADD] = "DiffAdd",
    [HL.FILE_EDIT] = "DiffChange",
    [HL.FILE_DELETE] = "DiffDelete",
    [HL.FILE_RENAME] = "DiffText",
    [HL.DRAFT_COUNT] = "DiagnosticWarn",
    [HL.THREAD_COUNT] = "DiagnosticInfo",
    [HL.STATS_ADD] = "DiffAdd",
    [HL.STATS_DEL] = "DiffDelete",
    [HL.CHANGE_ICON] = "Comment",
    [HL.EXPANDER] = "SpecialChar",
    [HL.TITLE] = "Title",
  }

  for hl_name, link_to in pairs(links) do
    local ok, existing = pcall(vim.api.nvim_get_hl, 0, { name = hl_name })
    if not ok or vim.tbl_isempty(existing) then
      vim.api.nvim_set_hl(0, hl_name, { link = link_to })
    end
  end
end

--- Build NuiTree nodes from the session's changed files.
---@param session PowerReview.ReviewSession
---@return table[] NuiTree.Node list
local function build_nodes(session)
  local NuiTree = require("nui.tree")
  local helpers = require("power-review.session_helpers")
  local counts = helpers.get_draft_counts(session)

  -- Group files by directory
  local dirs = {} ---@type table<string, PowerReview.ChangedFile[]>
  local dir_order = {} ---@type string[]

  for _, file in ipairs(session.files) do
    local dir = vim.fn.fnamemodify(file.path, ":h")
    if dir == "." then
      dir = ""
    end
    if not dirs[dir] then
      dirs[dir] = {}
      table.insert(dir_order, dir)
    end
    table.insert(dirs[dir], file)
  end

  table.sort(dir_order)

  -- Build child nodes
  local children = {}

  for _, dir in ipairs(dir_order) do
    local files_in_dir = dirs[dir]
    if dir == "" then
      -- Root-level files
      for _, file in ipairs(files_in_dir) do
        local file_drafts = session_mod.get_drafts_for_file(session, file.path)
        local file_threads = session_mod.get_threads_for_file(session, file.path)
        table.insert(children, NuiTree.Node({
          text = vim.fn.fnamemodify(file.path, ":t"),
          type = "file",
          file_path = file.path,
          original_path = file.original_path,
          change_type = file.change_type,
          additions = file.additions,
          deletions = file.deletions,
          draft_count = #file_drafts,
          thread_count = #file_threads,
        }))
      end
    else
      -- Directory with children
      local file_nodes = {}
      for _, file in ipairs(files_in_dir) do
        local file_drafts = session_mod.get_drafts_for_file(session, file.path)
        local file_threads = session_mod.get_threads_for_file(session, file.path)
        table.insert(file_nodes, NuiTree.Node({
          text = vim.fn.fnamemodify(file.path, ":t"),
          type = "file",
          file_path = file.path,
          original_path = file.original_path,
          change_type = file.change_type,
          additions = file.additions,
          deletions = file.deletions,
          draft_count = #file_drafts,
          thread_count = #file_threads,
        }))
      end

      table.insert(children, NuiTree.Node({
        text = dir .. "/",
        type = "directory",
        dir_path = dir,
        file_count = #files_in_dir,
      }, file_nodes))
    end
  end

  -- Root node
  local root_text = string.format("PR #%d: %s", session.pr_id, session.pr_title)
  if counts.total > 0 then
    root_text = root_text .. string.format(" [%d drafts]", counts.total)
  end

  local root = NuiTree.Node({
    text = root_text,
    type = "root",
    pr_id = session.pr_id,
    pr_title = session.pr_title,
    file_count = #session.files,
    draft_counts = counts,
  }, children)

  return { root }
end

--- Prepare a node for rendering (NuiTree prepare_node callback).
---@param node table NuiTree.Node
---@return table NuiLine
local function prepare_node(node)
  local NuiLine = require("nui.line")
  ensure_highlights()

  local line = NuiLine()
  local depth = node:get_depth()

  -- Indentation
  line:append(string.rep("  ", depth - 1))

  -- Expander for nodes with children
  if node:has_children() then
    line:append(node:is_expanded() and " " or " ", HL.EXPANDER)
  else
    line:append("  ")
  end

  if node.type == "root" then
    line:append(" ", HL.ROOT)
    line:append(node.text, HL.ROOT)
  elseif node.type == "directory" then
    local dir_icon = node:is_expanded() and " " or " "
    line:append(dir_icon, HL.DIR)
    line:append(node.text, HL.DIR)
  elseif node.type == "file" then
    -- Change type icon
    local ct = change_type_config[node.change_type]
    if ct then
      line:append(ct.icon .. " ", ct.hl)
    else
      line:append("? ", HL.CHANGE_ICON)
    end

    -- File icon (devicons if available)
    local icon_ok, devicons = pcall(require, "nvim-web-devicons")
    if icon_ok then
      local ext = vim.fn.fnamemodify(node.text, ":e")
      local icon, icon_hl = devicons.get_icon(node.text, ext, { default = true })
      if icon then
        line:append(icon .. " ", icon_hl)
      end
    end

    -- Comment count badge (LEFT of filename so it's always visible even when truncated)
    local thread_n = node.thread_count or 0
    local draft_n = node.draft_count or 0
    if thread_n > 0 or draft_n > 0 then
      local badge_parts = {}
      if thread_n > 0 then
        table.insert(badge_parts, { text = string.format(" %d", thread_n), hl = HL.THREAD_COUNT })
      end
      if draft_n > 0 then
        table.insert(badge_parts, { text = string.format(" %d", draft_n), hl = HL.DRAFT_COUNT })
      end
      for _, bp in ipairs(badge_parts) do
        line:append(bp.text, bp.hl)
      end
      line:append(" ")
    end

    -- File name
    local name_hl = ct and ct.hl or HL.FILE_EDIT
    line:append(node.text, name_hl)

    -- File stats
    if node.additions and node.additions > 0 then
      line:append(" +" .. tostring(node.additions), HL.STATS_ADD)
    end
    if node.deletions and node.deletions > 0 then
      line:append(" -" .. tostring(node.deletions), HL.STATS_DEL)
    end
  else
    line:append(node.text or "")
  end

  return line
end

--- Toggle the builtin file panel.
---@param session PowerReview.ReviewSession
function M.toggle(session)
  if M._visible and M._split then
    M.close()
  else
    M.open(session)
  end
end

--- Open the builtin file panel.
---@param session PowerReview.ReviewSession
function M.open(session)
  if M._visible and M._split then
    M.refresh(session)
    return
  end

  local ok, Split = pcall(require, "nui.split")
  if not ok then
    -- Ultimate fallback: quickfix list
    M._qf_fallback(session)
    return
  end

  local NuiTree = require("nui.tree")
  local config = require("power-review.config")
  local ui_cfg = config.get_ui_config()
  local panel_cfg = ui_cfg.comments.panel -- Reuse panel dimensions

  ensure_highlights()

  -- Create the split
  M._split = Split({
    relative = "editor",
    position = "left",
    size = panel_cfg.width or 40,
    enter = true,
    buf_options = {
      modifiable = false,
      buftype = "nofile",
      bufhidden = "wipe",
      swapfile = false,
      filetype = "power-review-files",
    },
    win_options = {
      number = false,
      relativenumber = false,
      cursorline = true,
      signcolumn = "no",
      wrap = false,
      spell = false,
      list = false,
      foldcolumn = "0",
    },
  })

  M._split:mount()
  M._visible = true

  -- Build the tree
  local nodes = build_nodes(session)
  M._tree = NuiTree({
    winid = M._split.winid,
    nodes = nodes,
    prepare_node = prepare_node,
  })

  -- Expand root by default
  local root_nodes = M._tree:get_nodes()
  for _, node in ipairs(root_nodes) do
    node:expand()
  end

  M._tree:render()

  -- Setup keymaps
  local map_opts = { noremap = true, nowait = true }

  -- Close
  M._split:map("n", "q", function()
    M.close()
  end, map_opts)

  -- Open file diff
  M._split:map("n", "<CR>", function()
    local node = M._tree:get_node()
    if not node then
      return
    end

    if node.type == "file" and node.file_path then
      local ui = require("power-review.ui")
      ui.open_file_diff(session, node.file_path)
    elseif node:has_children() then
      if node:is_expanded() then
        node:collapse()
      else
        node:expand()
      end
      M._tree:render()
    end
  end, map_opts)

  -- Expand
  M._split:map("n", "l", function()
    local node = M._tree:get_node()
    if node and node:expand() then
      M._tree:render()
    end
  end, map_opts)

  -- Collapse
  M._split:map("n", "h", function()
    local node = M._tree:get_node()
    if node and node:collapse() then
      M._tree:render()
    end
  end, map_opts)

  -- Expand all
  M._split:map("n", "L", function()
    local updated = false
    for _, node in pairs(M._tree.nodes.by_id) do
      updated = node:expand() or updated
    end
    if updated then
      M._tree:render()
    end
  end, map_opts)

  -- Collapse all
  M._split:map("n", "H", function()
    local updated = false
    for _, node in pairs(M._tree.nodes.by_id) do
      updated = node:collapse() or updated
    end
    if updated then
      M._tree:render()
    end
  end, map_opts)

  -- Refresh
  M._split:map("n", "R", function()
    local pr = require("power-review")
    local s = pr.get_current_session()
    if s then
      M.refresh(s)
    end
  end, map_opts)

  -- Add comment
  M._split:map("n", "a", function()
    local node = M._tree:get_node()
    if not node or node.type ~= "file" then
      return
    end

    local ui = require("power-review.ui")
    ui.open_file_diff(session, node.file_path, function()
      ui.add_comment()
    end)
  end, map_opts)

  -- Copy path
  M._split:map("n", "y", function()
    local node = M._tree:get_node()
    if not node then
      return
    end
    local path = node.file_path or node.dir_path
    if path then
      vim.fn.setreg("+", path)
      log.info("Copied: %s", path)
    end
  end, map_opts)

  -- Show details
  M._split:map("n", "i", function()
    local node = M._tree:get_node()
    if not node then
      return
    end
    local lines = {}
    if node.type == "file" then
      table.insert(lines, "File: " .. (node.file_path or ""))
      table.insert(lines, "Change: " .. (node.change_type or ""))
      if node.original_path then
        table.insert(lines, "Renamed from: " .. node.original_path)
      end
      if node.additions then
        table.insert(lines, "Additions: +" .. tostring(node.additions))
      end
      if node.deletions then
        table.insert(lines, "Deletions: -" .. tostring(node.deletions))
      end
      if node.draft_count and node.draft_count > 0 then
        table.insert(lines, "Draft comments: " .. tostring(node.draft_count))
      end
      if node.thread_count and node.thread_count > 0 then
        table.insert(lines, "Remote threads: " .. tostring(node.thread_count))
      end
    end
    if #lines > 0 then
      vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
    end
  end, map_opts)

  -- Auto-close on BufLeave (optional - let the split persist)
  -- M._split:on(require("nui.utils.autocmd").event.BufLeave, function()
  --   M.close()
  -- end)

  log.debug("Builtin file panel opened (%d files)", #session.files)
end

--- Close the builtin file panel.
function M.close()
  if M._split then
    M._split:unmount()
    M._split = nil
  end
  M._tree = nil
  M._visible = false
end

--- Refresh the builtin file panel with current session data.
---@param session PowerReview.ReviewSession
function M.refresh(session)
  if not M._visible or not M._split or not M._tree then
    return
  end

  local NuiTree = require("nui.tree")
  local nodes = build_nodes(session)

  -- Rebuild tree (preserving expand state is complex; just re-expand root)
  M._tree = NuiTree({
    winid = M._split.winid,
    nodes = nodes,
    prepare_node = prepare_node,
  })

  -- Expand root by default
  local root_nodes = M._tree:get_nodes()
  for _, node in ipairs(root_nodes) do
    node:expand()
  end

  M._tree:render()
end

--- Quickfix fallback when nui.nvim is also not available.
---@param session PowerReview.ReviewSession
function M._qf_fallback(session)
  local items = {}
  for _, file in ipairs(session.files) do
    local ct = change_type_config[file.change_type]
    local icon = ct and ct.icon or "?"
    table.insert(items, {
      filename = file.path,
      text = string.format("[%s] %s", icon, file.path),
      lnum = 1,
    })
  end

  vim.fn.setqflist(items, "r")
  vim.fn.setqflist({}, "a", {
    title = string.format("PR #%d: %s (%d files)", session.pr_id, session.pr_title, #session.files),
  })
  vim.cmd("copen")
  log.info("Changed files loaded to quickfix (%d files)", #session.files)
end

--- Check if the panel is currently visible.
---@return boolean
function M.is_visible()
  return M._visible
end

return M
