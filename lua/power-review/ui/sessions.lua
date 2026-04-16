--- PowerReview.nvim session management UI
--- A dedicated panel/picker for browsing, resuming, and deleting saved review sessions.
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
  TITLE = "PowerReviewSessionTitle",
  PROVIDER = "PowerReviewSessionProvider",
  PR_ID = "PowerReviewSessionPrId",
  PR_TITLE = "PowerReviewSessionPrTitle",
  DRAFT_COUNT = "PowerReviewSessionDraftCount",
  TIMESTAMP = "PowerReviewSessionTimestamp",
  ACTIVE = "PowerReviewSessionActive",
  META = "PowerReviewSessionMeta",
  EXPANDER = "PowerReviewSessionExpander",
}

local hl_created = false
local function ensure_highlights()
  if hl_created then
    return
  end
  hl_created = true

  local links = {
    [HL.TITLE] = "Title",
    [HL.PROVIDER] = "Type",
    [HL.PR_ID] = "Number",
    [HL.PR_TITLE] = "String",
    [HL.DRAFT_COUNT] = "DiagnosticHint",
    [HL.TIMESTAMP] = "Comment",
    [HL.ACTIVE] = "DiagnosticOk",
    [HL.META] = "NonText",
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

--- Format a timestamp for display (truncate to date + time).
---@param ts string ISO timestamp or empty string
---@return string
local function format_timestamp(ts)
  if not ts or ts == "" then
    return "unknown"
  end
  -- ISO format: 2024-01-15T10:30:00.000Z -> 2024-01-15 10:30
  local date_part = ts:match("^(%d%d%d%d%-%d%d%-%d%d)")
  local time_part = ts:match("T(%d%d:%d%d)")
  if date_part and time_part then
    return date_part .. " " .. time_part
  end
  return ts:sub(1, 19)
end

--- Build NuiTree nodes from session summaries.
---@param summaries PowerReview.SessionSummary[]
---@param active_id? string Currently active session ID
---@return table[] NuiTree.Node list
local function build_nodes(summaries, active_id)
  local NuiTree = require("nui.tree")

  if #summaries == 0 then
    return { NuiTree.Node({ text = "No saved review sessions", node_type = "empty" }) }
  end

  local header = NuiTree.Node({
    text = string.format("Review Sessions (%d)", #summaries),
    node_type = "header",
  })

  local session_nodes = {}
  for _, s in ipairs(summaries) do
    local is_active = active_id and s.id == active_id
    local active_marker = is_active and " *" or ""
    local draft_label = s.draft_count > 0 and string.format(" [%d drafts]", s.draft_count) or ""

    -- Main display line
    local display =
      string.format("[%s]%s PR #%d: %s%s", s.provider_type:upper(), active_marker, s.pr_id, s.pr_title, draft_label)

    -- Detail child nodes
    local children = {}
    table.insert(
      children,
      NuiTree.Node({
        text = string.format("Repo: %s/%s/%s", s.org, s.project, s.repo),
        node_type = "detail",
      })
    )
    if s.pr_url and s.pr_url ~= "" then
      table.insert(
        children,
        NuiTree.Node({
          text = string.format("URL: %s", s.pr_url),
          node_type = "detail",
        })
      )
    end
    table.insert(
      children,
      NuiTree.Node({
        text = string.format("Updated: %s", format_timestamp(s.updated_at)),
        node_type = "detail",
      })
    )
    table.insert(
      children,
      NuiTree.Node({
        text = string.format("Created: %s", format_timestamp(s.created_at)),
        node_type = "detail",
      })
    )

    table.insert(
      session_nodes,
      NuiTree.Node({
        text = display,
        node_type = "session",
        session_id = s.id,
        session_summary = s,
        is_active = is_active,
      }, children)
    )
  end

  return { header, unpack(session_nodes) }
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

  if node_type == "header" then
    line:append(node.text or "", HL.TITLE)
  elseif node_type == "empty" then
    line:append(node.text or "", "Comment")
  elseif node_type == "session" then
    local s = node.session_summary

    -- Provider badge
    line:append(string.format("[%s] ", (s.provider_type or "?"):upper()), HL.PROVIDER)

    -- Active marker
    if node.is_active then
      line:append("* ", HL.ACTIVE)
    end

    -- PR ID
    line:append(string.format("#%d ", s.pr_id), HL.PR_ID)

    -- PR title
    local title = s.pr_title or "(untitled)"
    if #title > 50 then
      title = title:sub(1, 47) .. "..."
    end
    line:append(title .. " ", HL.PR_TITLE)

    -- Draft count
    if s.draft_count > 0 then
      line:append(string.format("[%d drafts] ", s.draft_count), HL.DRAFT_COUNT)
    end

    -- Timestamp
    line:append(format_timestamp(s.updated_at), HL.TIMESTAMP)
  elseif node_type == "detail" then
    line:append(node.text or "", HL.META)
  end

  return line
end

-- ============================================================================
-- Panel lifecycle
-- ============================================================================

--- Toggle the sessions management panel.
function M.toggle()
  if M._visible then
    M.close()
  else
    M.open()
  end
end

--- Open the sessions management panel.
function M.open()
  local ok_nui, NuiSplit = pcall(require, "nui.split")
  if not ok_nui then
    -- Fallback: vim.ui.select picker
    M._select_fallback()
    return
  end

  ensure_highlights()

  local NuiTree = require("nui.tree")
  local store = require("power-review.store")
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
      filetype = "power-review-sessions",
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

  local pr = require("power-review")
  local current = pr.get_current_session()
  local active_id = current and current.id or nil

  local summaries = store.list()
  local nodes = build_nodes(summaries, active_id)
  local tree = NuiTree({
    bufnr = split.bufnr,
    nodes = nodes,
    prepare_node = prepare_node,
  })

  tree:render()

  M._split = split
  M._tree = tree
  M._visible = true

  M._setup_keymaps(split, tree)
end

--- Close the sessions panel.
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

--- Refresh the sessions panel.
function M.refresh()
  if not M._visible or not M._split then
    return
  end

  local NuiTree = require("nui.tree")
  local store = require("power-review.store")

  local pr = require("power-review")
  local current = pr.get_current_session()
  local active_id = current and current.id or nil

  local summaries = store.list()
  local nodes = build_nodes(summaries, active_id)
  M._tree = NuiTree({
    bufnr = M._split.bufnr,
    nodes = nodes,
    prepare_node = prepare_node,
  })
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
function M._setup_keymaps(split, tree)
  -- Close
  split:map("n", "q", function()
    M.close()
  end, { noremap = true })

  -- Toggle expand/collapse or resume session
  split:map("n", "<CR>", function()
    local node = tree:get_node()
    if not node then
      return
    end

    if node:has_children() then
      -- If it's a session node, resume it
      if node.node_type == "session" then
        M._resume_session(node.session_id)
        return
      end
      -- Otherwise toggle expand
      if node:is_expanded() then
        node:collapse()
      else
        node:expand()
      end
      tree:render()
      return
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

  -- Resume session (o)
  split:map("n", "o", function()
    local node = M._get_session_node(tree)
    if not node then
      log.info("Select a session to resume")
      return
    end
    M._resume_session(node.session_id)
  end, { noremap = true })

  -- Delete session (d)
  split:map("n", "d", function()
    local node = M._get_session_node(tree)
    if not node then
      log.info("Select a session to delete")
      return
    end

    local s = node.session_summary
    vim.ui.input({
      prompt = string.format("Delete session for PR #%d '%s'? (y/n): ", s.pr_id, s.pr_title),
    }, function(input)
      if input == "y" or input == "Y" then
        local store = require("power-review.store")
        local ok_del, err = store.delete(node.session_id)
        if ok_del then
          log.info("Session deleted: %s", node.session_id)
          M.refresh()
        else
          log.error("Failed to delete session: %s", err or "unknown")
        end
      end
    end)
  end, { noremap = true })

  -- Refresh (R)
  split:map("n", "R", function()
    M.refresh()
    log.info("Sessions panel refreshed")
  end, { noremap = true })

  -- Open new review from URL (n)
  split:map("n", "n", function()
    vim.ui.input({ prompt = "PR URL: " }, function(url)
      if url and url ~= "" then
        local review = require("power-review.review")
        review.start_review(url, function(err, session)
          if err then
            log.error("%s", err)
          else
            log.info("Review started: %s", session.pr_title)
            M.refresh()
          end
        end)
      end
    end)
  end, { noremap = true })

  -- Help (?)
  split:map("n", "?", function()
    local help_lines = {
      "Sessions Panel Keymaps:",
      "  <CR>  Resume selected session",
      "  o     Resume selected session",
      "  d     Delete selected session",
      "  n     Open new review from URL",
      "  R     Refresh list",
      "  l/h   Expand/collapse details",
      "  q     Close panel",
      "  ?     Show this help",
    }
    log.info(table.concat(help_lines, "\n"))
  end, { noremap = true })
end

-- ============================================================================
-- Helpers
-- ============================================================================

--- Get the session node at cursor, walking up to parent if on a detail node.
---@param tree table NuiTree
---@return table|nil NuiTree.Node with node_type == "session"
function M._get_session_node(tree)
  local node = tree:get_node()
  if not node then
    return nil
  end

  -- If on a detail child, walk up to the session parent
  if node.node_type == "detail" then
    local parent_id = node:get_parent_id()
    if parent_id then
      node = tree:get_node(parent_id)
    end
  end

  if node and node.node_type == "session" then
    return node
  end
  return nil
end

--- Resume a session by ID, closing the panel afterward.
---@param session_id string
function M._resume_session(session_id)
  local review = require("power-review.review")
  log.info("Resuming session: %s", session_id)

  review.resume_session(session_id, function(err, session)
    if err then
      log.error("Failed to resume: %s", err)
    else
      log.info("Resumed: PR #%d - %s", session.pr_id, session.pr_title)
      vim.schedule(function()
        M.close()
      end)
    end
  end)
end

--- Fallback when nui.nvim is not available: use vim.ui.select.
function M._select_fallback()
  local store = require("power-review.store")
  local summaries = store.list()

  if #summaries == 0 then
    log.info("No saved review sessions")
    return
  end

  local pr = require("power-review")
  local current = pr.get_current_session()
  local active_id = current and current.id or nil

  vim.ui.select(summaries, {
    prompt = "Review Sessions:",
    format_item = function(s)
      local active_marker = (active_id and s.id == active_id) and " *" or ""
      local draft_label = s.draft_count > 0 and string.format(" [%d drafts]", s.draft_count) or ""
      return string.format(
        "[%s]%s PR #%d: %s%s (%s)",
        s.provider_type:upper(),
        active_marker,
        s.pr_id,
        s.pr_title,
        draft_label,
        format_timestamp(s.updated_at)
      )
    end,
  }, function(selected)
    if not selected then
      return
    end

    -- Sub-action picker
    local actions = {
      { label = "Resume", action = "resume" },
      { label = "Delete", action = "delete" },
    }

    vim.ui.select(actions, {
      prompt = "Action:",
      format_item = function(a)
        return a.label
      end,
    }, function(act)
      if not act then
        return
      end

      if act.action == "resume" then
        M._resume_session(selected.id)
      elseif act.action == "delete" then
        vim.ui.input({
          prompt = string.format("Delete session for PR #%d? (y/n): ", selected.pr_id),
        }, function(input)
          if input == "y" or input == "Y" then
            local ok_del, err = store.delete(selected.id)
            if ok_del then
              log.info("Session deleted")
            else
              log.error("Failed to delete: %s", err or "unknown")
            end
          end
        end)
      end
    end)
  end)
end

return M
