--- PowerReview.nvim shared comment preview builder
--- Extracted from telescope module so both telescope and fzf-lua can reuse it.
local M = {}

--- Format an ISO timestamp to a readable date string.
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

--- Status icons for threads and drafts.
M.status_icons = {
  active = "",
  fixed = "",
  wontfix = "",
  closed = "",
  bydesign = "󰗡",
  pending = "",
  draft = "",
  submitted = "",
}

--- Build rich preview lines + highlights for a comment item.
--- For remote threads: shows full thread with all replies, author, timestamp, status.
--- For drafts: shows draft metadata + body.
---@param item table The comment item from the picker
---@param session PowerReview.ReviewSession
---@return string[] lines, table[] highlights Array of { line, hl_group }
function M.build(item, session)
  local lines = {}
  local hls = {}

  --- Helper to add a highlighted line
  local function add(text, hl_group)
    table.insert(lines, text)
    if hl_group then
      table.insert(hls, { line = #lines, hl_group = hl_group })
    end
  end

  --- Helper to add body lines (split on newlines)
  local function add_body(body, indent, hl_group)
    if not body or body == "" then
      add(indent .. "(empty)", "Comment")
      return
    end
    for body_line in (body .. "\n"):gmatch("([^\n]*)\n") do
      add(indent .. body_line, hl_group)
    end
  end

  local icon = M.status_icons[item.status] or "?"

  if item.kind == "thread" then
    -- Thread header
    local loc = "L" .. tostring(item.line_start)
    if item.line_end and item.line_end ~= item.line_start then
      loc = loc .. "-" .. tostring(item.line_end)
    end

    add(string.format("%s  %s  [%s]", icon, item.file_path, item.status:upper()), "Title")
    add(string.format("   %s", loc), "LineNr")
    if item.thread_id then
      add(string.format("   Thread #%s", tostring(item.thread_id)), "Comment")
    end
    add("")

    -- Separator
    add(string.rep("─", 60), "Comment")
    add("")

    -- Full thread with all comments
    local full_thread = nil
    for _, t in ipairs(session.threads or {}) do
      if t.id == item.thread_id then
        full_thread = t
        break
      end
    end

    if full_thread and full_thread.comments then
      for ci, comment in ipairs(full_thread.comments) do
        if not comment.is_deleted then
          local role = ci == 1 and "Author" or "Reply"
          local time_str = M.format_time(comment.created_at)
          local time_label = time_str ~= "" and ("  " .. time_str) or ""

          if ci > 1 then
            add("  " .. string.rep("╌", 56), "Comment")
            add("")
          end
          add(string.format("  %s  %s%s", role == "Reply" and "" or "", comment.author, time_label), "Title")
          if ci > 1 then
            add("  (reply)", "Comment")
          end
          add("")

          add_body(comment.body, "  ", nil)
          add("")
        end
      end
    else
      add("  " .. (item.author or "unknown") .. "  " .. M.format_time(item.created_at), "Title")
      add("")
      add_body(item.body, "  ", nil)
      add("")
    end

    -- Reply drafts
    local reply_drafts = {}
    for _, draft in ipairs(session.drafts or {}) do
      if draft.thread_id == item.thread_id then
        table.insert(reply_drafts, draft)
      end
    end

    if #reply_drafts > 0 then
      add(string.rep("─", 60), "Comment")
      add(string.format("  Draft Replies (%d)", #reply_drafts), "DiagnosticHint")
      add("")

      for _, rd in ipairs(reply_drafts) do
        local s_icon = M.status_icons[rd.status] or "?"
        local ai_label = rd.author == "ai" and " 󰚩" or ""
        local author_display = rd.author
        if rd.author_name then
          author_display = author_display .. " (" .. rd.author_name .. ")"
        end
        add(string.format("  %s%s %s  [%s]", s_icon, ai_label, author_display, rd.status:upper()), "DiagnosticHint")
        add("")
        add_body(rd.body, "  ", nil)
        add("")
      end
    end
  else
    -- Draft comment
    local s_icon = M.status_icons[item.status] or "?"
    local ai_label = item.author == "ai" and " 󰚩" or ""
    local loc = "L" .. tostring(item.line_start)
    if item.line_end and item.line_end ~= item.line_start then
      loc = loc .. "-" .. tostring(item.line_end)
    end

    add(string.format("%s%s  Draft Comment  [%s]", s_icon, ai_label, item.status:upper()), "DiagnosticHint")
    add(string.format("   %s  %s", item.file_path, loc), "Directory")
    local author_display = item.author
    if item.author_name then
      author_display = author_display .. " (" .. item.author_name .. ")"
    end
    add(string.format("   Author: %s", author_display), "Title")
    if item.created_at ~= "" then
      add(string.format("   Created: %s", M.format_time(item.created_at)), "Comment")
    end
    if item.thread_id then
      add(string.format("   Reply to thread #%s", tostring(item.thread_id)), "Comment")
    end
    if item.draft_id then
      add(string.format("   Draft ID: %s", item.draft_id), "Comment")
    end
    add("")
    add(string.rep("─", 60), "Comment")
    add("")
    add_body(item.body, "  ", nil)
  end

  return lines, hls
end

--- Build a unified list of comment items from a session (remote threads + local drafts).
--- Used by both telescope and fzf-lua pickers.
---@param session PowerReview.ReviewSession
---@param get_all_threads fun(session: PowerReview.ReviewSession): table[]
---@return table[] items
function M.build_items(session, get_all_threads)
  local all_threads = get_all_threads(session)
  local items = {}

  -- Remote threads
  for _, thread in ipairs(all_threads) do
    if thread.type ~= "draft" and thread.file_path then
      local first = thread.comments and thread.comments[1]
      local author = first and first.author or "unknown"
      local body = first and first.body or ""
      local reply_count = thread.comments and math.max(0, #thread.comments - 1) or 0
      table.insert(items, {
        kind = "thread",
        file_path = thread.file_path,
        line_start = thread.line_start or 1,
        line_end = thread.line_end,
        status = thread.status or "active",
        author = author,
        body = body,
        reply_count = reply_count,
        thread_id = thread.id,
        created_at = first and first.created_at or "",
      })
    end
  end

  -- Drafts
  for _, draft in ipairs(session.drafts) do
    table.insert(items, {
      kind = "draft",
      file_path = draft.file_path,
      line_start = draft.line_start,
      line_end = draft.line_end,
      status = draft.status,
      author = draft.author,
      author_name = draft.author_name,
      body = draft.body,
      reply_count = 0,
      thread_id = draft.thread_id,
      draft_id = draft.id,
      created_at = draft.created_at or "",
    })
  end

  return items
end

--- Format a comment item as a single display string for picker lists.
---@param item table
---@return string
function M.format_display(item)
  local icon = M.status_icons[item.status] or "?"
  local kind_label = item.kind == "thread" and "" or " "
  local preview = item.body:gsub("\n", " "):sub(1, 40)
  local range = ""
  if item.line_end and item.line_end ~= item.line_start then
    range = string.format(":%d-%d", item.line_start, item.line_end)
  else
    range = string.format(":%d", item.line_start)
  end
  local reply_badge = item.reply_count > 0 and string.format(" (%d)", item.reply_count) or ""
  local author_display = item.author
  if item.author_name then
    author_display = author_display .. ":" .. item.author_name
  end

  return string.format(
    "%s%s %s%s %s%s %s",
    kind_label,
    icon,
    item.file_path,
    range,
    author_display,
    reply_badge,
    preview
  )
end

return M
