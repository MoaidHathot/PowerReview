--- PowerReview.nvim comments panel — section-based renderer
local M = {}

local HL = require("power-review.ui.comments_panel.highlights").HL

-- ============================================================================
-- Rendering helpers
-- ============================================================================

--- Format a relative timestamp from an ISO string.
---@param iso_str string
---@return string
function M.format_time(iso_str)
  if not iso_str or iso_str == "" then
    return ""
  end
  local date = iso_str:match("^(%d%d%d%d%-%d%d%-%d%d)")
  if date then
    return date
  end
  return iso_str:sub(1, 19)
end

--- Build a location label string from line/col info.
---@param line_start? number
---@param line_end? number
---@param col_start? number
---@param col_end? number
---@param file_path? string
---@return string
function M.location_label(line_start, line_end, col_start, col_end, file_path)
  if not line_start then
    if file_path and file_path ~= "" then
      return "File-level"
    end
    return "PR-level"
  end
  local parts = "L" .. tostring(line_start)
  if line_end and line_end ~= line_start then
    parts = parts .. "-" .. tostring(line_end)
  end
  if col_start and col_end then
    parts = parts .. string.format(" (col %d-%d)", col_start, col_end)
  end
  return parts
end

--- Get the draft status icon.
---@param status string
---@return string icon, string hl
function M.draft_status_icon(status)
  if status == "draft" then
    return " ", HL.DRAFT_BADGE
  elseif status == "pending" then
    return " ", HL.PENDING_BADGE
  elseif status == "submitted" then
    return " ", HL.SUBMITTED_BADGE
  end
  return "? ", HL.DRAFT_BADGE
end

--- Get the thread status icon.
---@param status string
---@return string icon, string hl
function M.thread_status_icon(status)
  if status == "active" then
    return " ", HL.STATUS_ACTIVE
  elseif status == "fixed" or status == "resolved" then
    return " ", HL.STATUS_RESOLVED
  elseif status == "wontfix" then
    return " ", HL.STATUS_WONTFIX
  elseif status == "closed" then
    return " ", HL.STATUS_CLOSED
  elseif status == "bydesign" then
    return "󰗡 ", HL.STATUS_BYDESIGN
  elseif status == "pending" then
    return " ", HL.PENDING_BADGE
  end
  return " ", HL.STATUS_ACTIVE
end

--- Wrap a markdown body into lines, soft-wrapping long lines to a max width.
---@param body string
---@param max_width? number Max characters per line (nil = no wrapping)
---@return string[]
function M.wrap_body(body, max_width)
  if not body or body == "" then
    return { "(empty)" }
  end
  local raw_lines = {}
  for line in (body .. "\n"):gmatch("([^\n]*)\n") do
    table.insert(raw_lines, line)
  end
  while #raw_lines > 0 and raw_lines[#raw_lines]:match("^%s*$") do
    table.remove(raw_lines)
  end
  if #raw_lines == 0 then
    return { "(empty)" }
  end

  if not max_width or max_width < 20 then
    return raw_lines
  end

  local result = {}
  for _, line in ipairs(raw_lines) do
    if line == "" or line:match("^```") or line:match("^    ") or #line <= max_width then
      table.insert(result, line)
    else
      local remaining = line
      while #remaining > max_width do
        local break_at = max_width
        local space_pos = remaining:sub(1, max_width):find("%s[^%s]*$")
        if space_pos and space_pos > 10 then
          break_at = space_pos
        end
        table.insert(result, remaining:sub(1, break_at))
        remaining = remaining:sub(break_at + 1)
      end
      if #remaining > 0 then
        table.insert(result, remaining)
      end
    end
  end
  return result
end

-- ============================================================================
-- Section building
-- ============================================================================

--- Build all sections from the session data.
---@param session PowerReview.ReviewSession
---@param panel_width? number Current panel width for text wrapping
---@param collapsed table<string, boolean> Collapsed state map
---@return PowerReview.PanelSection[]
function M.build_sections(session, panel_width, collapsed)
  local review = require("power-review.review")
  local helpers = require("power-review.session_helpers")
  local sections = {} ---@type PowerReview.PanelSection[]

  local body_width = panel_width and math.max(20, panel_width - 8) or nil

  local counts = helpers.get_draft_counts(session)
  local all_threads = review.get_all_threads(session)

  local remote_count = 0
  for _, t in ipairs(all_threads) do
    if t.type ~= "draft" then
      remote_count = remote_count + 1
    end
  end

  -- Header
  local sep_width = panel_width and math.max(20, panel_width - 2) or 50
  local header_sep = string.rep("─", sep_width)
  table.insert(sections, {
    type = "header",
    lines = {
      string.format(" PowerReview: %s", session.pr_title or "PR #" .. session.pr_id),
      string.format("  %d threads   %d drafts   %d pending   %d submitted",
        remote_count, counts.total, counts.pending, counts.submitted),
      header_sep,
    },
    highlights = {
      { line = 1, col_start = 0, col_end = -1, hl_group = HL.TITLE },
      { line = 2, col_start = 0, col_end = -1, hl_group = HL.COUNT_BADGE },
      { line = 3, col_start = 0, col_end = -1, hl_group = HL.SEPARATOR },
    },
    data = {},
  })

  -- Group by file
  local files_map = {} ---@type table<string, { threads: table[], drafts: PowerReview.DraftComment[] }>
  local file_order = {} ---@type string[]

  for _, thread in ipairs(all_threads) do
    if thread.type ~= "draft" and thread.file_path then
      local fp = thread.file_path
      if not files_map[fp] then
        files_map[fp] = { threads = {}, drafts = {} }
        table.insert(file_order, fp)
      end
      table.insert(files_map[fp].threads, thread)
    end
  end

  for _, draft in ipairs(session.drafts) do
    local fp = draft.file_path
    if not files_map[fp] then
      files_map[fp] = { threads = {}, drafts = {} }
      table.insert(file_order, fp)
    end
    if not draft.thread_id then
      table.insert(files_map[fp].drafts, draft)
    end
  end

  local reply_drafts_by_thread = {} ---@type table<number, PowerReview.DraftComment[]>
  for _, draft in ipairs(session.drafts) do
    if draft.thread_id then
      if not reply_drafts_by_thread[draft.thread_id] then
        reply_drafts_by_thread[draft.thread_id] = {}
      end
      table.insert(reply_drafts_by_thread[draft.thread_id], draft)
    end
  end

  table.sort(file_order)

  for _, fp in ipairs(file_order) do
    local file_data = files_map[fp]
    local is_file_collapsed = collapsed["file:" .. fp]

    local thread_count = #file_data.threads
    local draft_count = #file_data.drafts
    local badge = ""
    if thread_count > 0 or draft_count > 0 then
      local parts = {}
      if thread_count > 0 then
        table.insert(parts, " " .. thread_count)
      end
      if draft_count > 0 then
        table.insert(parts, " " .. draft_count)
      end
      badge = "  " .. table.concat(parts, "  ")
    end
    local expander = is_file_collapsed and " " or " "

    local file_icon = " "
    local ok_devicons, devicons = pcall(require, "nvim-web-devicons")
    if ok_devicons then
      local ext = fp:match("%.([^%.]+)$")
      local icon, _ = devicons.get_icon(fp, ext, { default = true })
      if icon then
        file_icon = icon .. " "
      end
    end

    -- File header
    table.insert(sections, {
      type = "file",
      lines = { expander .. file_icon .. fp .. badge },
      highlights = {
        { line = 1, col_start = 0, col_end = #expander, hl_group = HL.EXPANDER },
        { line = 1, col_start = #expander, col_end = #expander + #file_icon + #fp, hl_group = HL.FILE_HEADER },
        { line = 1, col_start = #expander + #file_icon + #fp, col_end = -1, hl_group = HL.COUNT_BADGE },
      },
      data = { file_path = fp, collapsible = true, collapse_key = "file:" .. fp },
    })

    if not is_file_collapsed then
      -- Remote threads
      for _, thread in ipairs(file_data.threads) do
        local lines = {}
        local hls = {}
        local loc = M.location_label(thread.line_start, thread.line_end, thread.col_start, thread.col_end, thread.file_path)
        local status_icon_str, status_hl = M.thread_status_icon(thread.status or "active")
        local comment_count = thread.comments and #thread.comments or 0
        local reply_draft_count = reply_drafts_by_thread[thread.id] and #reply_drafts_by_thread[thread.id] or 0

        local is_thread_collapsed = collapsed["thread:" .. thread.id]
        local t_expander = is_thread_collapsed and "  " or "  "

        local count_badge = ""
        if comment_count > 1 or reply_draft_count > 0 then
          local parts = {}
          if comment_count > 1 then
            table.insert(parts, (comment_count - 1) .. " replies")
          end
          if reply_draft_count > 0 then
            table.insert(parts, reply_draft_count .. " draft reply(ies)")
          end
          count_badge = "  (" .. table.concat(parts, ", ") .. ")"
        end

        local header = string.format("%s%s %s [%s]%s", t_expander, status_icon_str, loc, thread.status or "active", count_badge)
        table.insert(lines, header)
        table.insert(hls, { line = #lines, col_start = 0, col_end = #t_expander, hl_group = HL.EXPANDER })
        table.insert(hls, { line = #lines, col_start = #t_expander, col_end = #t_expander + #status_icon_str, hl_group = status_hl })

        if not is_thread_collapsed then
          for ci, comment in ipairs(thread.comments or {}) do
            if not comment.is_deleted then
              local indent = ci == 1 and "    " or "      "
              local reply_marker = ci > 1 and " " or ""

              local author_line = string.format("%s%s%s  %s", indent, reply_marker, comment.author, M.format_time(comment.created_at))
              table.insert(lines, author_line)
              table.insert(hls, { line = #lines, col_start = 0, col_end = #indent + #reply_marker + #comment.author, hl_group = HL.REMOTE_AUTHOR })
              table.insert(hls, { line = #lines, col_start = #author_line - #M.format_time(comment.created_at), col_end = #author_line, hl_group = HL.TIMESTAMP })

              local body_lines = M.wrap_body(comment.body, body_width and (body_width - #indent - 2) or nil)
              for _, bl in ipairs(body_lines) do
                table.insert(lines, indent .. "  " .. bl)
                table.insert(hls, { line = #lines, col_start = 0, col_end = -1, hl_group = HL.REMOTE_BODY })
              end

              if ci < #thread.comments then
                table.insert(lines, "")
              end
            end
          end

          -- Render reply drafts under this thread
          local reply_drafts = reply_drafts_by_thread[thread.id]
          local reply_draft_ids = {}
          if reply_drafts then
            for _, rd in ipairs(reply_drafts) do
              table.insert(reply_draft_ids, rd.id)
              local s_icon, s_hl = M.draft_status_icon(rd.status)
              local ai_label = rd.author == "ai" and " 󰚩" or ""
              local rd_header = string.format("      %s%s%s (draft reply)", s_icon, ai_label, rd.author)
              table.insert(lines, "")
              table.insert(lines, rd_header)
              table.insert(hls, { line = #lines, col_start = 6, col_end = 6 + #s_icon, hl_group = s_hl })

              local body_lines = M.wrap_body(rd.body, body_width and (body_width - 8) or nil)
              for _, bl in ipairs(body_lines) do
                table.insert(lines, "        " .. bl)
                table.insert(hls, { line = #lines, col_start = 0, col_end = -1, hl_group = HL.REMOTE_BODY })
              end
            end
          end
        end

        table.insert(lines, "")

        table.insert(sections, {
          type = "thread",
          lines = lines,
          highlights = hls,
          data = {
            file_path = fp,
            line_start = thread.line_start,
            line_end = thread.line_end,
            col_start = thread.col_start,
            col_end = thread.col_end,
            thread_id = thread.id,
            thread_status = thread.status,
            reply_draft_ids = reply_draft_ids,
            collapsible = true,
            collapse_key = "thread:" .. thread.id,
          },
        })
      end

      -- Local standalone drafts
      for _, draft in ipairs(file_data.drafts) do
        local lines = {}
        local hls = {}

        local s_icon, s_hl = M.draft_status_icon(draft.status)
        local ai_label = draft.author == "ai" and " 󰚩" or ""
        local loc = M.location_label(draft.line_start, draft.line_end, draft.col_start, draft.col_end, draft.file_path)

        local header = string.format("  %s%s%s %s", s_icon, ai_label, loc, draft.author)
        table.insert(lines, header)
        table.insert(hls, { line = 1, col_start = 2, col_end = 2 + #s_icon, hl_group = s_hl })
        if draft.author == "ai" then
          table.insert(hls, { line = 1, col_start = 2 + #s_icon, col_end = 2 + #s_icon + #ai_label, hl_group = HL.AI_BADGE })
        end

        local body_lines = M.wrap_body(draft.body, body_width and (body_width - 4) or nil)
        for _, bl in ipairs(body_lines) do
          table.insert(lines, "    " .. bl)
          table.insert(hls, { line = #lines, col_start = 0, col_end = -1, hl_group = HL.REMOTE_BODY })
        end

        table.insert(lines, "")

        table.insert(sections, {
          type = "draft",
          lines = lines,
          highlights = hls,
          data = {
            file_path = fp,
            line_start = draft.line_start,
            line_end = draft.line_end,
            col_start = draft.col_start,
            col_end = draft.col_end,
            draft_id = draft.id,
            draft_status = draft.status,
            draft_author = draft.author,
          },
        })
      end
    end

    -- File separator
    table.insert(sections, {
      type = "separator",
      lines = { string.rep("─", sep_width) },
      highlights = { { line = 1, col_start = 0, col_end = -1, hl_group = HL.SEPARATOR } },
      data = {},
    })
  end

  return sections
end

-- ============================================================================
-- Buffer rendering
-- ============================================================================

--- Render all sections into the panel buffer.
---@param bufnr number
---@param sections PowerReview.PanelSection[]
function M.render_sections(bufnr, sections)
  local all_lines = {} ---@type string[]
  local all_hls = {} ---@type table[]

  for _, section in ipairs(sections) do
    section.buf_start = #all_lines + 1
    for li, line_text in ipairs(section.lines) do
      table.insert(all_lines, line_text)
      for _, hl in ipairs(section.highlights) do
        if hl.line == li then
          table.insert(all_hls, {
            line = #all_lines,
            col_start = hl.col_start,
            col_end = hl.col_end,
            hl_group = hl.hl_group,
          })
        end
      end
    end
    section.buf_end = #all_lines
  end

  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, all_lines)
  vim.bo[bufnr].modifiable = false

  local ns = vim.api.nvim_create_namespace("power_review_comments_panel")
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

  for _, hl in ipairs(all_hls) do
    local end_col = hl.col_end
    if end_col == -1 then
      end_col = #all_lines[hl.line]
    end
    local line_len = #(all_lines[hl.line] or "")
    if hl.col_start > line_len then
      goto continue
    end
    if end_col > line_len then
      end_col = line_len
    end
    if hl.col_start >= end_col then
      end_col = line_len
    end
    pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, hl.line - 1, hl.col_start, {
      end_col = end_col,
      hl_group = hl.hl_group,
    })
    ::continue::
  end
end

return M
