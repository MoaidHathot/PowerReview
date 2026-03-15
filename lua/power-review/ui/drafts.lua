--- PowerReview.nvim draft management UI
--- A dedicated panel/picker for browsing, approving, editing, and deleting all drafts.
local M = {}

local log = require("power-review.utils.log")
local config = require("power-review.config")

---@type table|nil The NuiSplit instance
M._split = nil
---@type table|nil The NuiTree instance
M._tree = nil
---@type boolean
M._visible = false

-- ============================================================================
-- Highlights
-- ============================================================================

local HL = {
  DRAFT_STATUS = "PowerReviewDraftStatus",
  PENDING_STATUS = "PowerReviewDraftPending",
  SUBMITTED_STATUS = "PowerReviewDraftSubmitted",
  AI_BADGE = "PowerReviewDraftAI",
  FILE_PATH = "PowerReviewDraftFile",
  LINE_NUM = "PowerReviewDraftLine",
  PREVIEW = "PowerReviewDraftPreview",
  SUMMARY = "PowerReviewDraftSummary",
  EXPANDER = "PowerReviewDraftExpander",
}

local hl_created = false
local function ensure_highlights()
  if hl_created then
    return
  end
  hl_created = true

  local links = {
    [HL.DRAFT_STATUS] = "DiagnosticHint",
    [HL.PENDING_STATUS] = "DiagnosticInfo",
    [HL.SUBMITTED_STATUS] = "String",
    [HL.AI_BADGE] = "DiagnosticWarn",
    [HL.FILE_PATH] = "Directory",
    [HL.LINE_NUM] = "LineNr",
    [HL.PREVIEW] = "Normal",
    [HL.SUMMARY] = "Title",
    [HL.EXPANDER] = "SpecialChar",
  }

  for hl_name, link_to in pairs(links) do
    local ok, existing = pcall(vim.api.nvim_get_hl, 0, { name = hl_name })
    if not ok or vim.tbl_isempty(existing) then
      vim.api.nvim_set_hl(0, hl_name, { link = link_to })
    end
  end
end

-- ============================================================================
-- Tree node building
-- ============================================================================

--- Build NuiTree nodes from all drafts in the session.
---@param session PowerReview.ReviewSession
---@return table[] NuiTree.Node list
local function build_nodes(session)
  local NuiTree = require("nui.tree")
  local session_mod = require("power-review.review.session")
  local counts = session_mod.get_draft_counts(session)

  -- Summary header
  local summary_text = string.format(
    "Drafts: %d total (%d draft, %d pending, %d submitted)",
    counts.total, counts.draft, counts.pending, counts.submitted
  )

  -- Group drafts by status
  local by_status = { draft = {}, pending = {}, submitted = {} }
  for _, d in ipairs(session.drafts) do
    if by_status[d.status] then
      table.insert(by_status[d.status], d)
    end
  end

  local root_children = {}

  -- Draft section
  if #by_status.draft > 0 then
    local draft_children = {}
    for _, d in ipairs(by_status.draft) do
      local preview = d.body:gsub("\n", " "):sub(1, 50)
      local author_label = d.author == "ai" and " AI" or ""
      table.insert(draft_children, NuiTree.Node({
        text = string.format("[DRAFT]%s %s:%d %s", author_label, d.file_path, d.line_start, preview),
        node_type = "draft_item",
        draft_id = d.id,
        draft_status = d.status,
        draft_author = d.author,
        file_path = d.file_path,
        line_start = d.line_start,
        line_end = d.line_end,
        preview = preview,
        body = d.body,
      }))
    end
    table.insert(root_children, NuiTree.Node({
      text = string.format(" Drafts (%d) - ready to approve", #by_status.draft),
      node_type = "status_group",
      group_status = "draft",
    }, draft_children))
  end

  -- Pending section
  if #by_status.pending > 0 then
    local pending_children = {}
    for _, d in ipairs(by_status.pending) do
      local preview = d.body:gsub("\n", " "):sub(1, 50)
      local author_label = d.author == "ai" and " AI" or ""
      table.insert(pending_children, NuiTree.Node({
        text = string.format("[PENDING]%s %s:%d %s", author_label, d.file_path, d.line_start, preview),
        node_type = "draft_item",
        draft_id = d.id,
        draft_status = d.status,
        draft_author = d.author,
        file_path = d.file_path,
        line_start = d.line_start,
        line_end = d.line_end,
        preview = preview,
        body = d.body,
      }))
    end
    table.insert(root_children, NuiTree.Node({
      text = string.format(" Pending (%d) - ready to submit", #by_status.pending),
      node_type = "status_group",
      group_status = "pending",
    }, pending_children))
  end

  -- Submitted section
  if #by_status.submitted > 0 then
    local submitted_children = {}
    for _, d in ipairs(by_status.submitted) do
      local preview = d.body:gsub("\n", " "):sub(1, 50)
      table.insert(submitted_children, NuiTree.Node({
        text = string.format("[SUBMITTED] %s:%d %s", d.file_path, d.line_start, preview),
        node_type = "draft_item",
        draft_id = d.id,
        draft_status = d.status,
        draft_author = d.author,
        file_path = d.file_path,
        line_start = d.line_start,
        preview = preview,
        body = d.body,
      }))
    end
    table.insert(root_children, NuiTree.Node({
      text = string.format(" Submitted (%d)", #by_status.submitted),
      node_type = "status_group",
      group_status = "submitted",
    }, submitted_children))
  end

  if #root_children == 0 then
    return { NuiTree.Node({ text = "No drafts", node_type = "empty" }) }
  end

  local root = NuiTree.Node({
    text = summary_text,
    node_type = "root",
  }, root_children)

  return { root }
end

--- Prepare a NuiTree node for rendering as a NuiLine.
---@param node table NuiTree.Node
---@return table NuiLine
local function prepare_node(node)
  local NuiLine = require("nui.line")
  local line = NuiLine()

  local depth = node:get_depth()
  local indent = string.rep("  ", depth - 1)

  -- Expander for nodes with children
  if node:has_children() then
    local icon = node:is_expanded() and " " or " "
    line:append(indent .. icon, HL.EXPANDER)
  else
    line:append(indent .. "  ")
  end

  local node_type = node.node_type or "unknown"

  if node_type == "root" then
    line:append(node.text or "", HL.SUMMARY)
  elseif node_type == "empty" then
    line:append(node.text or "", "Comment")
  elseif node_type == "status_group" then
    local hl = HL.DRAFT_STATUS
    if node.group_status == "pending" then
      hl = HL.PENDING_STATUS
    elseif node.group_status == "submitted" then
      hl = HL.SUBMITTED_STATUS
    end
    line:append(node.text or "", hl)
  elseif node_type == "draft_item" then
    -- Status badge
    local badge_hl = HL.DRAFT_STATUS
    if node.draft_status == "pending" then
      badge_hl = HL.PENDING_STATUS
    elseif node.draft_status == "submitted" then
      badge_hl = HL.SUBMITTED_STATUS
    end
    line:append(string.format("[%s] ", (node.draft_status or "draft"):upper()), badge_hl)

    -- AI badge
    if node.draft_author == "ai" then
      line:append("AI ", HL.AI_BADGE)
    end

    -- File path + line
    local loc = node.file_path or ""
    if node.line_start then
      if node.line_end and node.line_end ~= node.line_start then
        loc = loc .. string.format(":%d-%d", node.line_start, node.line_end)
      else
        loc = loc .. string.format(":%d", node.line_start)
      end
    end
    line:append(loc .. " ", HL.FILE_PATH)

    -- Preview
    line:append(node.preview or "", HL.PREVIEW)
  end

  return line
end

-- ============================================================================
-- Panel lifecycle
-- ============================================================================

--- Toggle the drafts management panel.
---@param session PowerReview.ReviewSession
function M.toggle(session)
  if M._visible then
    M.close()
  else
    M.open(session)
  end
end

--- Open the drafts management panel.
---@param session PowerReview.ReviewSession
function M.open(session)
  local ok_nui, NuiSplit = pcall(require, "nui.split")
  if not ok_nui then
    -- Fallback: vim.ui.select picker
    M._select_fallback(session)
    return
  end

  ensure_highlights()

  local NuiTree = require("nui.tree")
  local ui_cfg = config.get_ui_config()
  local panel_cfg = ui_cfg.comments.panel

  -- Close existing
  M.close()

  local position = panel_cfg.position or "right"
  local size_key = (position == "right" or position == "left") and "width" or "height"
  local size_val = panel_cfg[size_key] or 50

  local split = NuiSplit({
    relative = "editor",
    position = position,
    size = size_val,
    buf_options = {
      modifiable = false,
      readonly = true,
      filetype = "power-review-drafts",
      buftype = "nofile",
      swapfile = false,
    },
    win_options = {
      number = false,
      relativenumber = false,
      signcolumn = "no",
      cursorline = true,
      wrap = true,
      winhighlight = "Normal:NormalFloat,CursorLine:Visual",
    },
  })

  split:mount()

  local nodes = build_nodes(session)
  local tree = NuiTree({
    bufnr = split.bufnr,
    nodes = nodes,
    prepare_node = prepare_node,
  })

  -- Expand all by default
  M._expand_all(tree)
  tree:render()

  M._split = split
  M._tree = tree
  M._visible = true

  M._setup_keymaps(split, tree, session)
end

--- Close the drafts panel.
function M.close()
  if M._split then
    pcall(function()
      M._split:unmount()
    end)
    M._split = nil
    M._tree = nil
    M._visible = false
  end
end

--- Refresh the drafts panel.
---@param session PowerReview.ReviewSession
function M.refresh(session)
  if not M._visible or not M._split then
    return
  end

  local NuiTree = require("nui.tree")
  local nodes = build_nodes(session)
  M._tree = NuiTree({
    bufnr = M._split.bufnr,
    nodes = nodes,
    prepare_node = prepare_node,
  })
  M._expand_all(M._tree)
  M._tree:render()
end

--- Check if visible.
---@return boolean
function M.is_visible()
  return M._visible
end

-- ============================================================================
-- Keymaps
-- ============================================================================

---@param split table NuiSplit
---@param tree table NuiTree
---@param session PowerReview.ReviewSession
function M._setup_keymaps(split, tree, session)
  local pr = require("power-review")

  -- Close
  split:map("n", "q", function() M.close() end, { noremap = true })

  -- Toggle expand/collapse or navigate to file
  split:map("n", "<CR>", function()
    local node = tree:get_node()
    if not node then return end

    if node:has_children() then
      if node:is_expanded() then
        node:collapse()
      else
        node:expand()
      end
      tree:render()
      return
    end

    -- Leaf: navigate to file/line
    if node.file_path and node.line_start then
      local ui = require("power-review.ui")
      ui.open_file_diff(session, node.file_path, function()
        vim.schedule(function()
          pcall(vim.api.nvim_win_set_cursor, 0, { node.line_start, 0 })
        end)
      end)
    end
  end, { noremap = true })

  -- Expand/collapse
  split:map("n", "l", function()
    local node = tree:get_node()
    if node and node:has_children() and not node:is_expanded() then
      node:expand()
      tree:render()
    end
  end, { noremap = true })

  split:map("n", "h", function()
    local node = tree:get_node()
    if node and node:has_children() and node:is_expanded() then
      node:collapse()
      tree:render()
    end
  end, { noremap = true })

  -- Approve individual draft (a)
  split:map("n", "a", function()
    local node = tree:get_node()
    if not node or node.node_type ~= "draft_item" then
      log.info("Select a draft to approve")
      return
    end
    if node.draft_status ~= "draft" then
      log.info("Only drafts can be approved (current: %s)", node.draft_status)
      return
    end

    local ok_appr, err = pr.api.approve_draft(node.draft_id)
    if ok_appr then
      log.info("Draft approved (now pending)")
      M.refresh(session)
      require("power-review.ui").refresh_neotree()
    else
      log.error("Failed to approve: %s", err or "unknown")
    end
  end, { noremap = true })

  -- Approve ALL drafts (A)
  split:map("n", "A", function()
    local session_mod = require("power-review.review.session")
    local counts = session_mod.get_draft_counts(session)
    if counts.draft == 0 then
      log.info("No drafts to approve")
      return
    end

    vim.ui.input({
      prompt = string.format("Approve all %d draft(s)? (y/n): ", counts.draft),
    }, function(input)
      if input == "y" or input == "Y" then
        local count = pr.api.approve_all_drafts()
        log.info("Approved %d draft(s)", count)
        M.refresh(session)
        require("power-review.ui").refresh_neotree()
      end
    end)
  end, { noremap = true })

  -- Unapprove (revert pending back to draft) (u)
  split:map("n", "u", function()
    local node = tree:get_node()
    if not node or node.node_type ~= "draft_item" then
      log.info("Select a pending draft to unapprove")
      return
    end
    if node.draft_status ~= "pending" then
      log.info("Only pending drafts can be unapproved (current: %s)", node.draft_status)
      return
    end

    local ok_u, err = pr.api.unapprove_draft(node.draft_id)
    if ok_u then
      log.info("Draft unapproved (reverted to draft)")
      M.refresh(session)
      require("power-review.ui").refresh_neotree()
    else
      log.error("Failed to unapprove: %s", err or "unknown")
    end
  end, { noremap = true })

  -- Edit draft (e)
  split:map("n", "e", function()
    local node = tree:get_node()
    if not node or node.node_type ~= "draft_item" then
      log.info("Select a draft to edit")
      return
    end
    if node.draft_status ~= "draft" then
      log.info("Only drafts can be edited (current: %s)", node.draft_status)
      return
    end

    local comment_float = require("power-review.ui.comment_float")
    comment_float.open_comment_editor({
      file_path = node.file_path,
      line = node.line_start,
      line_end = node.line_end,
      session = session,
      draft_id = node.draft_id,
      initial_body = node.body,
    })
  end, { noremap = true })

  -- Delete draft (d)
  split:map("n", "d", function()
    local node = tree:get_node()
    if not node or node.node_type ~= "draft_item" then
      log.info("Select a draft to delete")
      return
    end
    if node.draft_status ~= "draft" then
      log.info("Only drafts can be deleted (current: %s)", node.draft_status)
      return
    end

    vim.ui.input({ prompt = "Delete draft? (y/n): " }, function(input)
      if input == "y" or input == "Y" then
        local ok_del, err = pr.api.delete_draft_comment(node.draft_id)
        if ok_del then
          log.info("Draft deleted")
          M.refresh(session)
        else
          log.error("Failed to delete: %s", err or "unknown")
        end
      end
    end)
  end, { noremap = true })

  -- Show full details (i)
  split:map("n", "i", function()
    local node = tree:get_node()
    if not node or node.node_type ~= "draft_item" then
      return
    end

    local session_mod = require("power-review.review.session")
    local draft = session_mod.get_draft(session, node.draft_id)
    if draft then
      local lines = {
        string.format("Draft: %s", draft.id),
        string.format("File: %s:%d", draft.file_path, draft.line_start),
        draft.line_end and string.format("Range: %d-%d", draft.line_start, draft.line_end) or "",
        string.format("Status: %s", draft.status),
        string.format("Author: %s", draft.author),
        string.format("Created: %s", draft.created_at),
        string.format("Updated: %s", draft.updated_at),
        "",
        draft.body,
      }
      -- Filter empty strings
      lines = vim.tbl_filter(function(l) return l ~= "" or true end, lines)
      log.info(table.concat(lines, "\n"))
    end
  end, { noremap = true })

  -- Refresh (R)
  split:map("n", "R", function()
    local current = pr.get_current_session()
    if current then
      M.refresh(current)
      log.info("Drafts panel refreshed")
    end
  end, { noremap = true })
end

-- ============================================================================
-- Helpers
-- ============================================================================

--- Expand all nodes recursively.
---@param tree table NuiTree
function M._expand_all(tree)
  local function expand(node_id)
    local node = tree:get_node(node_id)
    if node and node:has_children() then
      node:expand()
      for _, child_id in ipairs(node:get_child_ids()) do
        expand(child_id)
      end
    end
  end
  for _, node in ipairs(tree:get_nodes()) do
    expand(node:get_id())
  end
end

--- Fallback when nui.nvim is not available: use vim.ui.select.
---@param session PowerReview.ReviewSession
function M._select_fallback(session)
  local drafts = session.drafts
  if #drafts == 0 then
    log.info("No draft comments")
    return
  end

  vim.ui.select(drafts, {
    prompt = "Draft comments:",
    format_item = function(d)
      local preview = d.body:gsub("\n", " "):sub(1, 50)
      local author_label = d.author == "ai" and " (AI)" or ""
      return string.format("[%s]%s %s:%d %s", d.status:upper(), author_label, d.file_path, d.line_start, preview)
    end,
  }, function(selected)
    if not selected then return end

    -- Sub-action picker
    local actions = {}
    if selected.status == "draft" then
      table.insert(actions, { label = "Approve (move to pending)", action = "approve" })
      table.insert(actions, { label = "Edit", action = "edit" })
      table.insert(actions, { label = "Delete", action = "delete" })
    elseif selected.status == "pending" then
      table.insert(actions, { label = "View", action = "view" })
    end
    table.insert(actions, { label = "Navigate to file", action = "navigate" })

    vim.ui.select(actions, {
      prompt = "Action:",
      format_item = function(a) return a.label end,
    }, function(act)
      if not act then return end
      local pr = require("power-review")

      if act.action == "approve" then
        local ok_a, err = pr.api.approve_draft(selected.id)
        if ok_a then
          log.info("Draft approved")
        else
          log.error("Failed: %s", err or "unknown")
        end
      elseif act.action == "edit" then
        local comment_float = require("power-review.ui.comment_float")
        comment_float.open_comment_editor({
          file_path = selected.file_path,
          line = selected.line_start,
          line_end = selected.line_end,
          session = session,
          draft_id = selected.id,
          initial_body = selected.body,
        })
      elseif act.action == "delete" then
        local ok_d, err = pr.api.delete_draft_comment(selected.id)
        if ok_d then
          log.info("Draft deleted")
        else
          log.error("Failed: %s", err or "unknown")
        end
      elseif act.action == "navigate" then
        local ui = require("power-review.ui")
        ui.open_file_diff(session, selected.file_path, function()
          vim.schedule(function()
            pcall(vim.api.nvim_win_set_cursor, 0, { selected.line_start, 0 })
          end)
        end)
      elseif act.action == "view" then
        log.info("[%s] %s:%d\n%s", selected.status:upper(), selected.file_path, selected.line_start, selected.body)
      end
    end)
  end)
end

return M
