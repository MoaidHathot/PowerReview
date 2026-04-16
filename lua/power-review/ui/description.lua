--- PowerReview.nvim PR description viewer
--- Read-only floating window showing PR title, metadata, and description body.
local M = {}

local log = require("power-review.utils.log")

---@type number|nil The floating window handle
M._win = nil
---@type number|nil The buffer handle
M._buf = nil

-- ============================================================================
-- Highlights
-- ============================================================================

local HL = {
  TITLE = "PowerReviewDescTitle",
  META_KEY = "PowerReviewDescMetaKey",
  META_VAL = "PowerReviewDescMetaVal",
  AUTHOR = "PowerReviewDescAuthor",
  BRANCH = "PowerReviewDescBranch",
  STATUS = "PowerReviewDescStatus",
  REVIEWER = "PowerReviewDescReviewer",
  SEPARATOR = "PowerReviewDescSeparator",
  LABEL = "PowerReviewDescLabel",
}

local hl_created = false
local function ensure_highlights()
  if hl_created then
    return
  end
  hl_created = true

  local links = {
    [HL.TITLE] = "Title",
    [HL.META_KEY] = "Identifier",
    [HL.META_VAL] = "String",
    [HL.AUTHOR] = "Type",
    [HL.BRANCH] = "Constant",
    [HL.STATUS] = "DiagnosticInfo",
    [HL.REVIEWER] = "Function",
    [HL.SEPARATOR] = "NonText",
    [HL.LABEL] = "Tag",
  }

  for hl_name, link_to in pairs(links) do
    local ok, existing = pcall(vim.api.nvim_get_hl, 0, { name = hl_name })
    if not ok or vim.tbl_isempty(existing) then
      vim.api.nvim_set_hl(0, hl_name, { link = link_to })
    end
  end
end

-- ============================================================================
-- Content building
-- ============================================================================

--- Map vote number to display label.
---@param vote number
---@return string
local function vote_label(vote)
  local labels = {
    [10] = "Approved",
    [5] = "Approved with suggestions",
    [0] = "No vote",
    [-5] = "Waiting for author",
    [-10] = "Rejected",
  }
  return labels[vote] or string.format("Unknown (%d)", vote)
end

--- Map vote number to icon.
---@param vote number
---@return string
local function vote_icon(vote)
  if vote == 10 then
    return "+"
  end
  if vote == 5 then
    return "~"
  end
  if vote == -5 then
    return "?"
  end
  if vote == -10 then
    return "x"
  end
  return " "
end

--- Format PR status for display.
---@param status string|nil
---@param is_draft boolean|nil
---@return string
local function format_status(status, is_draft)
  local label = (status or "unknown"):sub(1, 1):upper() .. (status or "unknown"):sub(2)
  if is_draft then
    label = label .. " (Draft)"
  end
  return label
end

--- Build the content lines and highlight ranges for the description float.
---@param session PowerReview.ReviewSession
---@return string[] lines
---@return table[] highlights Array of { line, col_start, col_end, hl_group }
local function build_content(session)
  local lines = {}
  local highlights = {}

  local function add(text, hl)
    table.insert(lines, text)
    if hl then
      table.insert(highlights, {
        line = #lines,
        col_start = 0,
        col_end = #text,
        hl_group = hl,
      })
    end
  end

  local function add_meta(key, value, val_hl)
    local text = string.format("  %s: %s", key, value)
    table.insert(lines, text)
    -- Highlight key portion
    table.insert(highlights, {
      line = #lines,
      col_start = 2,
      col_end = 2 + #key + 1,
      hl_group = HL.META_KEY,
    })
    -- Highlight value portion
    if val_hl then
      table.insert(highlights, {
        line = #lines,
        col_start = 2 + #key + 2,
        col_end = #text,
        hl_group = val_hl,
      })
    end
  end

  -- Title
  local title = session.pr_title or "(untitled)"
  add(string.format("PR #%d: %s", session.pr_id, title), HL.TITLE)
  add("")

  -- Metadata section
  add_meta("Author", session.pr_author or "unknown", HL.AUTHOR)
  add_meta("Status", format_status(session.pr_status, session.pr_is_draft), HL.STATUS)
  add_meta("Source", session.source_branch or "?", HL.BRANCH)
  add_meta("Target", session.target_branch or "?", HL.BRANCH)

  if session.merge_status then
    add_meta("Merge", session.merge_status, HL.STATUS)
  end

  -- Labels
  if session.labels and #session.labels > 0 then
    add_meta("Labels", table.concat(session.labels, ", "), HL.LABEL)
  end

  -- Work items
  if session.work_items and #session.work_items > 0 then
    local items = {}
    for _, wi in ipairs(session.work_items) do
      if wi.title then
        table.insert(items, string.format("#%s %s", wi.id or "?", wi.title))
      else
        table.insert(items, string.format("#%s", wi.id or "?"))
      end
    end
    add_meta("Work Items", table.concat(items, "; "), HL.META_VAL)
  end

  -- Reviewers
  if session.reviewers and #session.reviewers > 0 then
    add("")
    add("  Reviewers:", HL.META_KEY)
    for _, r in ipairs(session.reviewers) do
      local icon = vote_icon(r.vote or 0)
      local label = vote_label(r.vote or 0)
      local reviewer_text = string.format("    [%s] %s - %s", icon, r.display_name or r.name or "?", label)
      add(reviewer_text, HL.REVIEWER)
    end
  end

  -- Separator
  add("")
  local sep = string.rep("-", 60)
  add(sep, HL.SEPARATOR)
  add("")

  -- Track where the description body starts (1-indexed line number)
  local description_start_line = #lines + 1

  -- Description body
  local desc = session.pr_description or ""
  if desc == "" then
    add("(No description provided)", HL.SEPARATOR)
  else
    -- Split description into lines, preserving blank lines
    for line in (desc .. "\n"):gmatch("([^\n]*)\n") do
      table.insert(lines, line)
    end
  end

  return lines, highlights, description_start_line
end

-- ============================================================================
-- Window management
-- ============================================================================

--- Check if the description float is currently visible.
---@return boolean
function M.is_visible()
  return M._win ~= nil and vim.api.nvim_win_is_valid(M._win)
end

--- Close the description float.
function M.close()
  if M._win and vim.api.nvim_win_is_valid(M._win) then
    vim.api.nvim_win_close(M._win, true)
  end
  M._win = nil

  if M._buf and vim.api.nvim_buf_is_valid(M._buf) then
    vim.api.nvim_buf_delete(M._buf, { force = true })
  end
  M._buf = nil
  M._editing = false
  M._desc_start_line = nil
end

--- Toggle the description float.
function M.toggle()
  local pr = require("power-review")
  local session = pr.get_current_session()
  if not session then
    log.warn("No active review session")
    return
  end

  if M.is_visible() then
    M.close()
  else
    M.open(session)
  end
end

--- Open the description float for the given session.
---@param session PowerReview.ReviewSession
function M.open(session)
  ensure_highlights()

  -- Close any existing instance
  M.close()

  local content_lines, hl_ranges, desc_start_line = build_content(session)

  -- Create buffer
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, content_lines)

  -- Apply highlights
  local ns = vim.api.nvim_create_namespace("power_review_description")
  for _, hl in ipairs(hl_ranges) do
    pcall(vim.api.nvim_buf_add_highlight, buf, ns, hl.hl_group, hl.line - 1, hl.col_start, hl.col_end)
  end

  -- Buffer options
  vim.bo[buf].modifiable = false
  vim.bo[buf].readonly = true
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "power-review-description"

  -- Calculate window size (centered, up to 80% of editor)
  local editor_width = vim.o.columns
  local editor_height = vim.o.lines - 2 -- account for cmdline + statusline
  local win_width = math.min(math.max(80, math.floor(editor_width * 0.6)), editor_width - 4)
  local win_height = math.min(#content_lines + 2, math.floor(editor_height * 0.8))
  win_height = math.max(win_height, 10) -- minimum height

  local row = math.floor((editor_height - win_height) / 2)
  local col = math.floor((editor_width - win_width) / 2)

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = row,
    col = col,
    width = win_width,
    height = win_height,
    style = "minimal",
    border = "rounded",
    title = " PR Description ",
    title_pos = "center",
  })

  -- Window options
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].cursorline = true
  vim.wo[win].winhighlight = "Normal:NormalFloat,CursorLine:Visual"
  vim.wo[win].signcolumn = "no"
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false

  M._win = win
  M._buf = buf

  -- Keymaps
  local map_opts = { buffer = buf, noremap = true, silent = true }
  vim.keymap.set("n", "q", function()
    M.close()
  end, map_opts)
  vim.keymap.set("n", "<Esc>", function()
    M.close()
  end, map_opts)

  -- Edit description keymap
  vim.keymap.set("n", "e", function()
    if M._editing then
      return
    end
    M._editing = true
    M._desc_start_line = desc_start_line

    -- Make the buffer editable
    vim.bo[buf].modifiable = true
    vim.bo[buf].readonly = false
    vim.bo[buf].buftype = "acwrite"

    -- Update title to indicate edit mode
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_set_config(win, {
        title = " PR Description [EDITING] ",
        title_pos = "center",
      })
    end

    -- Jump cursor to description body
    vim.api.nvim_win_set_cursor(win, { desc_start_line, 0 })

    -- Handle :w to save
    vim.api.nvim_create_autocmd("BufWriteCmd", {
      buffer = buf,
      callback = function()
        local all_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        -- Extract only the description body (after the separator)
        local body_lines = {}
        for i = desc_start_line, #all_lines do
          table.insert(body_lines, all_lines[i])
        end
        local new_body = table.concat(body_lines, "\n")

        -- Submit to CLI
        local cli = require("power-review.cli")
        cli.run_async({ "update-description", "--pr-url", session.pr_url, "--body-stdin" }, function(err)
          if err then
            vim.notify("[PowerReview] Failed to update description: " .. err, vim.log.levels.ERROR)
          else
            vim.notify("[PowerReview] Description updated", vim.log.levels.INFO)
            -- Update the session's description in memory
            session.pr_description = new_body
            vim.bo[buf].modified = false
          end
        end, { stdin = new_body })
      end,
    })

    vim.notify("[PowerReview] Editing description. :w to save, q to cancel.", vim.log.levels.INFO)
  end, map_opts)

  -- Auto-close when leaving the window (only if not editing)
  vim.api.nvim_create_autocmd("WinLeave", {
    buffer = buf,
    once = true,
    callback = function()
      vim.schedule(function()
        if not M._editing then
          M.close()
        end
      end)
    end,
  })
end

return M
