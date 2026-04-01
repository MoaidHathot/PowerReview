--- PowerReview.nvim all-comments split panel
--- A nui.nvim NuiSplit panel listing all comments across all files.
--- Supports both remote threads and local drafts with full markdown bodies,
--- code context snippets, expandable reply threads, and treesitter rendering.
local M = {}

local log = require("power-review.utils.log")
local config = require("power-review.config")

---@type table|nil The NuiSplit instance
M._split = nil
---@type boolean
M._visible = false
---@type table[] Flat list of rendered sections for jump/fold tracking
M._sections = {}
---@type table<string, boolean> Collapsed state: key -> is_collapsed
M._collapsed = {}
---@type PowerReview.ReviewSession|nil Cached session
M._session = nil

-- ============================================================================
-- Highlights
-- ============================================================================

local HL = {
  FILE_HEADER = "PowerReviewCommentsFile",
  REMOTE_AUTHOR = "PowerReviewCommentsAuthor",
  REMOTE_BODY = "PowerReviewCommentsBody",
  DRAFT_BADGE = "PowerReviewCommentsDraft",
  AI_BADGE = "PowerReviewCommentsAI",
  PENDING_BADGE = "PowerReviewCommentsPending",
  SUBMITTED_BADGE = "PowerReviewCommentsSubmitted",
  LINE_NUM = "PowerReviewCommentsLineNum",
  SEPARATOR = "PowerReviewCommentsSeparator",
  TITLE = "PowerReviewCommentsTitle",
  EXPANDER = "PowerReviewCommentsExpander",
  STATUS_ACTIVE = "PowerReviewCommentsStatusActive",
  STATUS_RESOLVED = "PowerReviewCommentsStatusResolved",
  STATUS_WONTFIX = "PowerReviewCommentsStatusWontFix",
  STATUS_CLOSED = "PowerReviewCommentsStatusClosed",
  STATUS_BYDESIGN = "PowerReviewCommentsStatusByDesign",
  CODE_CONTEXT = "PowerReviewCommentsCodeContext",
  CODE_CONTEXT_BG = "PowerReviewCommentsCodeContextBg",
  REPLY_INDENT = "PowerReviewCommentsReplyIndent",
  TIMESTAMP = "PowerReviewCommentsTimestamp",
  COUNT_BADGE = "PowerReviewCommentsCountBadge",
  HELP_TEXT = "PowerReviewCommentsHelp",
  PANEL_BAR = "PowerReviewPanelBar",
}

local hl_created = false
local function ensure_highlights()
  if hl_created then
    return
  end
  hl_created = true

  local links = {
    [HL.FILE_HEADER] = "Directory",
    [HL.REMOTE_AUTHOR] = "Title",
    [HL.REMOTE_BODY] = "Normal",
    [HL.DRAFT_BADGE] = "DiagnosticHint",
    [HL.AI_BADGE] = "DiagnosticWarn",
    [HL.PENDING_BADGE] = "DiagnosticInfo",
    [HL.SUBMITTED_BADGE] = "String",
    [HL.LINE_NUM] = "LineNr",
    [HL.SEPARATOR] = "Comment",
    [HL.TITLE] = "Title",
    [HL.EXPANDER] = "SpecialChar",
    [HL.STATUS_ACTIVE] = "DiagnosticWarn",
    [HL.STATUS_RESOLVED] = "DiagnosticOk",
    [HL.STATUS_WONTFIX] = "DiagnosticError",
    [HL.STATUS_CLOSED] = "Comment",
    [HL.STATUS_BYDESIGN] = "DiagnosticInfo",
    [HL.CODE_CONTEXT] = "Comment",
    [HL.CODE_CONTEXT_BG] = "CursorLine",
    [HL.REPLY_INDENT] = "NonText",
    [HL.TIMESTAMP] = "Comment",
    [HL.COUNT_BADGE] = "Special",
    [HL.HELP_TEXT] = "Comment",
    [HL.PANEL_BAR] = "StatusLine",
  }

  for hl_name, link_to in pairs(links) do
    local ok, existing = pcall(vim.api.nvim_get_hl, 0, { name = hl_name })
    if not ok or vim.tbl_isempty(existing) then
      vim.api.nvim_set_hl(0, hl_name, { link = link_to })
    end
  end
end

-- ============================================================================
-- Rendering helpers
-- ============================================================================

--- Format a relative timestamp from an ISO string.
---@param iso_str string
---@return string
local function format_time(iso_str)
  if not iso_str or iso_str == "" then
    return ""
  end
  -- Try to extract just date portion for display
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
---@param file_path? string
---@param col_end? number
---@return string
local function location_label(line_start, line_end, col_start, col_end, file_path)
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
local function draft_status_icon(status)
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
--- Each AzDO thread status gets a unique icon for visual differentiation:
---   active (1)   =  (speech bubble — needs attention)
---   fixed (2)    =  (check — resolved/fixed)
---   wontfix (3)  =  (cancel — deliberately not fixing)
---   closed (4)   =  (archive — closed/dismissed)
---   bydesign (5) = 󰗡 (thumb-up — intentional, by design)
---   pending (6)  =  (clock — waiting for action)
---@param status string
---@return string icon, string hl
local function thread_status_icon(status)
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
--- Preserves structure: blank lines, indented code blocks, list items.
--- Returns lines with no trailing blank lines.
---@param body string
---@param max_width? number Max characters per line (nil = no wrapping)
---@return string[]
local function wrap_body(body, max_width)
  if not body or body == "" then
    return { "(empty)" }
  end
  local raw_lines = {}
  for line in (body .. "\n"):gmatch("([^\n]*)\n") do
    table.insert(raw_lines, line)
  end
  -- Trim trailing empty lines
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
    -- Don't wrap blank lines, code fences, indented code (4+ spaces), or list items starting with  - / * / 1.
    if line == "" or line:match("^```") or line:match("^    ") or #line <= max_width then
      table.insert(result, line)
    else
      -- Soft-wrap at word boundaries
      local remaining = line
      while #remaining > max_width do
        -- Find the last space within max_width
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
-- Section-based rendering
-- ============================================================================

--- A section represents a renderable block in the panel buffer.
--- Sections are collected, then written to the buffer in order.
--- Each section tracks its start/end lines for fold and jump support.
---@class PowerReview.PanelSection
---@field type string "header"|"file"|"thread"|"draft"|"comment"|"separator"|"help"
---@field lines string[] Raw text lines
---@field highlights table[] { line: number, col_start: number, col_end: number, hl_group: string }
---@field data table Metadata (file_path, thread_id, draft_id, etc.)
---@field buf_start? number 1-indexed buffer line where section starts
---@field buf_end? number 1-indexed buffer line where section ends

--- Build all sections from the session data.
---@param session PowerReview.ReviewSession
---@param panel_width? number Current panel width for text wrapping
---@return PowerReview.PanelSection[]
local function build_sections(session, panel_width)
  local review = require("power-review.review")
  local helpers = require("power-review.session_helpers")
  local sections = {} ---@type PowerReview.PanelSection[]

  -- Effective width for body text (subtract indent + padding)
  local body_width = panel_width and math.max(20, panel_width - 8) or nil

  local counts = helpers.get_draft_counts(session)
  local all_threads = review.get_all_threads(session)

  -- Count remote threads
  local remote_count = 0
  for _, t in ipairs(all_threads) do
    if t.type ~= "draft" then
      remote_count = remote_count + 1
    end
  end

  -- ── Header ──
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

  -- ── Group by file ──
  local files_map = {} ---@type table<string, { threads: table[], drafts: PowerReview.DraftComment[] }>
  local file_order = {} ---@type string[]

  -- Collect remote threads per file
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

  -- Collect drafts per file (skip drafts that are replies to existing threads —
  -- those show under their parent thread)
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

  -- Collect reply drafts keyed by thread_id for merging
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
    local is_file_collapsed = M._collapsed["file:" .. fp]

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

    -- Try to get a file icon from nvim-web-devicons
    local file_icon = " "
    local ok_devicons, devicons = pcall(require, "nvim-web-devicons")
    if ok_devicons then
      local ext = fp:match("%.([^%.]+)$")
      local icon, _ = devicons.get_icon(fp, ext, { default = true })
      if icon then
        file_icon = icon .. " "
      end
    end

    -- ── File header ──
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
      -- ── Remote threads ──
      for _, thread in ipairs(file_data.threads) do
        local lines = {}
        local hls = {}
        local loc = location_label(thread.line_start, thread.line_end, thread.col_start, thread.col_end, thread.file_path)
        local status_icon_str, status_hl = thread_status_icon(thread.status or "active")
        local comment_count = thread.comments and #thread.comments or 0
        local reply_draft_count = reply_drafts_by_thread[thread.id] and #reply_drafts_by_thread[thread.id] or 0

        local is_thread_collapsed = M._collapsed["thread:" .. thread.id]
        local t_expander = is_thread_collapsed and "  " or "  "

        -- Thread header line
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
          -- Render each comment in the thread
          for ci, comment in ipairs(thread.comments or {}) do
            if not comment.is_deleted then
              local indent = ci == 1 and "    " or "      "
              local reply_marker = ci > 1 and " " or ""

              -- Author + timestamp line
              local author_line = string.format("%s%s%s  %s", indent, reply_marker, comment.author, format_time(comment.created_at))
              table.insert(lines, author_line)
              table.insert(hls, { line = #lines, col_start = 0, col_end = #indent + #reply_marker + #comment.author, hl_group = HL.REMOTE_AUTHOR })
              table.insert(hls, { line = #lines, col_start = #author_line - #format_time(comment.created_at), col_end = #author_line, hl_group = HL.TIMESTAMP })

              -- Body lines (width-aware wrapping)
              local body_lines = wrap_body(comment.body, body_width and (body_width - #indent - 2) or nil)
              for _, bl in ipairs(body_lines) do
                table.insert(lines, indent .. "  " .. bl)
                table.insert(hls, { line = #lines, col_start = 0, col_end = -1, hl_group = HL.REMOTE_BODY })
              end

              -- Spacing between comments in same thread
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
              local s_icon, s_hl = draft_status_icon(rd.status)
              local ai_label = rd.author == "ai" and " 󰚩" or ""
              local rd_header = string.format("      %s%s%s (draft reply)", s_icon, ai_label, rd.author)
              table.insert(lines, "")
              table.insert(lines, rd_header)
              table.insert(hls, { line = #lines, col_start = 6, col_end = 6 + #s_icon, hl_group = s_hl })

              local body_lines = wrap_body(rd.body, body_width and (body_width - 8) or nil)
              for _, bl in ipairs(body_lines) do
                table.insert(lines, "        " .. bl)
                table.insert(hls, { line = #lines, col_start = 0, col_end = -1, hl_group = HL.REMOTE_BODY })
              end
            end
          end
        end

        -- Separator
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

      -- ── Local standalone drafts (new threads, not replies) ──
      for _, draft in ipairs(file_data.drafts) do
        local lines = {}
        local hls = {}

        local s_icon, s_hl = draft_status_icon(draft.status)
        local ai_label = draft.author == "ai" and " 󰚩" or ""
        local loc = location_label(draft.line_start, draft.line_end, draft.col_start, draft.col_end, draft.file_path)

        local header = string.format("  %s%s%s %s", s_icon, ai_label, loc, draft.author)
        table.insert(lines, header)
        table.insert(hls, { line = 1, col_start = 2, col_end = 2 + #s_icon, hl_group = s_hl })
        if draft.author == "ai" then
          table.insert(hls, { line = 1, col_start = 2 + #s_icon, col_end = 2 + #s_icon + #ai_label, hl_group = HL.AI_BADGE })
        end

        -- Body (width-aware wrapping)
        local body_lines = wrap_body(draft.body, body_width and (body_width - 4) or nil)
        for _, bl in ipairs(body_lines) do
          table.insert(lines, "    " .. bl)
          table.insert(hls, { line = #lines, col_start = 0, col_end = -1, hl_group = HL.REMOTE_BODY })
        end

        -- Separator
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

  -- No help footer section — the footer is rendered as a sticky winbar/statusline
  -- in the panel window (see M.open / _set_sticky_footer).

  return sections
end

-- ============================================================================
-- Fenced code block syntax highlighting
-- ============================================================================

--- Map common markdown fence language tags to treesitter parser names.
---@type table<string, string>
local lang_aliases = {
  csharp = "c_sharp",
  cs = "c_sharp",
  ["c#"] = "c_sharp",
  cpp = "cpp",
  ["c++"] = "cpp",
  js = "javascript",
  ts = "typescript",
  tsx = "tsx",
  jsx = "javascript",
  py = "python",
  rb = "ruby",
  rs = "rust",
  sh = "bash",
  shell = "bash",
  zsh = "bash",
  yml = "yaml",
  tf = "hcl",
  dockerfile = "dockerfile",
  proto = "proto",
  viml = "vim",
  vimscript = "vim",
  jsonc = "json",
  ["objective-c"] = "objc",
  ["objective-cpp"] = "objc",
}

--- Detect fenced code blocks in the buffer (even with leading whitespace) and
--- apply language-specific syntax highlighting via treesitter.
--- Falls back to vim syntax regex highlights for languages without a treesitter parser.
---@param bufnr number
local function apply_code_block_highlights(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local ns_code = vim.api.nvim_create_namespace("power_review_code_blocks")
  vim.api.nvim_buf_clear_namespace(bufnr, ns_code, 0, -1)

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  -- Find fenced code blocks: lines matching optional whitespace + ``` + optional language
  ---@type { lang: string, start_line: number, end_line: number, indent: number }[]
  local code_blocks = {}
  local i = 1
  while i <= #lines do
    local indent_str, lang = lines[i]:match("^(%s*)```(%S*)")
    if indent_str and lang then
      local fence_indent = #indent_str
      -- Find matching closing fence (same or less indent, just ```)
      local block_start = i + 1
      local block_end = nil
      for j = block_start, #lines do
        local close_indent_str = lines[j]:match("^(%s*)```%s*$")
        if close_indent_str then
          block_end = j - 1
          i = j + 1
          break
        end
      end
      if block_end and block_end >= block_start and lang ~= "" then
        table.insert(code_blocks, {
          lang = lang:lower(),
          start_line = block_start, -- 1-indexed, first line of code content
          end_line = block_end,     -- 1-indexed, last line of code content
          indent = fence_indent,
        })
      elseif not block_end then
        -- Unclosed fence — skip
        i = i + 1
      end
    else
      i = i + 1
    end
  end

  if #code_blocks == 0 then
    return
  end

  -- Apply a subtle left-border indicator to code block lines for visual separation.
  -- We use a virtual text "▎" at the start of each line rather than a full-line
  -- background (CursorLine), which would clash with treesitter syntax colors.
  for _, block in ipairs(code_blocks) do
    -- Mark the opening fence line
    pcall(vim.api.nvim_buf_set_extmark, bufnr, ns_code, block.start_line - 2, 0, {
      virt_text = { { "▎", "Comment" } },
      virt_text_pos = "inline",
    })
    -- Mark code content lines
    for ln = block.start_line, block.end_line do
      pcall(vim.api.nvim_buf_set_extmark, bufnr, ns_code, ln - 1, 0, {
        virt_text = { { "▎", "Comment" } },
        virt_text_pos = "inline",
      })
    end
    -- Mark the closing fence line
    if block.end_line + 1 <= #lines then
      pcall(vim.api.nvim_buf_set_extmark, bufnr, ns_code, block.end_line, 0, {
        virt_text = { { "▎", "Comment" } },
        virt_text_pos = "inline",
      })
    end
  end

  -- For each code block, try to apply treesitter highlighting
  for _, block in ipairs(code_blocks) do
    local ts_lang = lang_aliases[block.lang] or block.lang

    -- Check if the treesitter parser is available
    local parser_ok = pcall(vim.treesitter.language.inspect, ts_lang)
    if not parser_ok then
      -- Try loading (nvim 0.10+)
      parser_ok = pcall(vim.treesitter.language.add, ts_lang)
    end

    if parser_ok then
      -- Build the code text by stripping leading indent from each line.
      -- Track the exact column offset per line so we can map highlights back.
      -- The fence markers sit at the same indentation level as the comment body text
      -- (indent + "  " prefix from build_sections), so block.indent already captures
      -- the full prefix. We only strip exactly block.indent characters.
      local code_lines = {}
      local col_offsets = {} -- col_offsets[i] = number of chars stripped from line i (1-indexed within block)
      for ln = block.start_line, block.end_line do
        local line = lines[ln] or ""
        local stripped = 0
        -- Strip the section indent (same as fence indent)
        if block.indent > 0 and line:sub(1, block.indent) == string.rep(" ", block.indent) then
          line = line:sub(block.indent + 1)
          stripped = block.indent
        end
        table.insert(code_lines, line)
        table.insert(col_offsets, stripped)
      end
      local code_text = table.concat(code_lines, "\n")

      -- Parse with treesitter
      local ok_parse, parser = pcall(vim.treesitter.get_string_parser, code_text, ts_lang)
      if ok_parse and parser then
        local ok_tree, trees = pcall(parser.parse, parser)
        if ok_tree and trees then
          -- Walk the tree and apply highlights
          local query_ok, query = pcall(vim.treesitter.query.get, ts_lang, "highlights")
          if query_ok and query then
            for _, tree in ipairs(trees) do
              local root = tree:root()
              for id, node, _ in query:iter_captures(root, code_text) do
                local name = query.captures[id]
                local hl_group = "@" .. name .. "." .. ts_lang
                -- Check if hl group exists; fall back to the base capture
                if vim.fn.hlexists(hl_group) == 0 then
                  hl_group = "@" .. name
                end
                local node_start_row, node_start_col, node_end_row, node_end_col = node:range()
                -- Map from string-parser coordinates to buffer coordinates (0-indexed)
                local buf_start_row = block.start_line - 1 + node_start_row
                local buf_end_row = block.start_line - 1 + node_end_row

                -- Add back the column offset that was stripped
                local start_offset = col_offsets[node_start_row + 1] or 0
                local end_offset = col_offsets[node_end_row + 1] or 0

                local adj_start_col = node_start_col + start_offset
                local adj_end_col = node_end_col + end_offset

                -- Clamp to line length
                local start_line_len = #(lines[buf_start_row + 1] or "")
                local end_line_len = #(lines[buf_end_row + 1] or "")
                if adj_start_col > start_line_len then adj_start_col = start_line_len end
                if adj_end_col > end_line_len then adj_end_col = end_line_len end

                pcall(vim.api.nvim_buf_set_extmark, bufnr, ns_code, buf_start_row, adj_start_col, {
                  end_row = buf_end_row,
                  end_col = adj_end_col,
                  hl_group = hl_group,
                  priority = 200, -- Higher than section highlights
                })
              end
            end
          end
        end
      end
    end
  end
end

--- Render all sections into the panel buffer.
---@param bufnr number
---@param sections PowerReview.PanelSection[]
local function render_sections(bufnr, sections)
  -- Collect all lines and track section positions
  local all_lines = {} ---@type string[]
  local all_hls = {} ---@type table[]

  for _, section in ipairs(sections) do
    section.buf_start = #all_lines + 1
    for li, line_text in ipairs(section.lines) do
      table.insert(all_lines, line_text)
      -- Map section-local highlights to buffer-global
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

  -- Write to buffer
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, all_lines)
  vim.bo[bufnr].modifiable = false

  -- Apply highlights via extmarks
  local ns = vim.api.nvim_create_namespace("power_review_comments_panel")
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

  for _, hl in ipairs(all_hls) do
    local end_col = hl.col_end
    if end_col == -1 then
      end_col = #all_lines[hl.line]
    end
    -- Clamp to line length
    local line_len = #(all_lines[hl.line] or "")
    if hl.col_start > line_len then
      goto continue
    end
    if end_col > line_len then
      end_col = line_len
    end
    if hl.col_start >= end_col then
      -- Fall back to whole-line highlight
      end_col = line_len
    end
    pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, hl.line - 1, hl.col_start, {
      end_col = end_col,
      hl_group = hl.hl_group,
    })
    ::continue::
  end
end

-- ============================================================================
-- Section lookup
-- ============================================================================

--- Find the section at a given buffer line.
---@param line number 1-indexed
---@return PowerReview.PanelSection|nil
local function section_at_line(line)
  for _, section in ipairs(M._sections) do
    if section.buf_start and section.buf_end then
      if line >= section.buf_start and line <= section.buf_end then
        return section
      end
    end
  end
  return nil
end

--- Resolve a draft ID from a section under the cursor.
--- Works for both standalone "draft" sections (which carry draft_id directly)
--- and "thread" sections (which may contain reply drafts).
--- For threads with a single reply draft, auto-selects it.
--- For threads with multiple reply drafts, prompts the user to pick one.
---@param section PowerReview.PanelSection|nil
---@param action_name string Human-readable action name for messages (e.g. "approve", "edit", "delete")
---@param callback fun(draft_id: string) Called with the resolved draft_id
local function resolve_draft_from_section(section, action_name, callback)
  if not section then
    log.info("Select a draft comment to %s", action_name)
    return
  end

  -- Direct draft section
  if section.type == "draft" and section.data.draft_id then
    callback(section.data.draft_id)
    return
  end

  -- Thread section with reply drafts
  if section.type == "thread" and section.data.reply_draft_ids and #section.data.reply_draft_ids > 0 then
    local ids = section.data.reply_draft_ids
    if #ids == 1 then
      callback(ids[1])
      return
    end

    -- Multiple reply drafts: let user pick
    local helpers = require("power-review.session_helpers")
    local cur_session = M._session
    local items = {}
    for _, id in ipairs(ids) do
      local draft = cur_session and helpers.get_draft(cur_session, id)
      if draft then
        local preview = (draft.body or ""):sub(1, 60):gsub("\n", " ")
        table.insert(items, { id = id, label = string.format("[%s] %s", draft.status, preview) })
      end
    end

    vim.ui.select(items, {
      prompt = "Select reply draft to " .. action_name .. ":",
      format_item = function(item) return item.label end,
    }, function(choice)
      if choice then
        callback(choice.id)
      end
    end)
    return
  end

  log.info("Select a draft comment to %s", action_name)
end

-- ============================================================================
-- Window management for open-file / open-diff actions
-- ============================================================================

--- Check if a window belongs to the comments panel.
---@param winid number
---@return boolean
local function is_panel_window(winid)
  if not vim.api.nvim_win_is_valid(winid) then
    return false
  end
  -- Check by winid
  if M._split and M._split.winid and M._split.winid == winid then
    return true
  end
  -- Also check by bufnr (more robust — survives window recreation)
  if M._split and M._split.bufnr then
    local win_buf = vim.api.nvim_win_get_buf(winid)
    if win_buf == M._split.bufnr then
      return true
    end
  end
  return false
end

--- Find or create a window to the LEFT of the comments panel.
--- The panel is a NuiSplit on the right side. We want to open files in the
--- main editor area (any non-panel window). If no suitable window exists,
--- we create a vertical split from the panel and move left.
---@return number winid The window ID to use
local function find_or_create_left_window()
  -- Collect all normal (non-floating, non-panel) windows in the current tabpage
  local wins = vim.api.nvim_tabpage_list_wins(0)
  local candidates = {}
  for _, winid in ipairs(wins) do
    if not is_panel_window(winid) then
      local win_cfg = vim.api.nvim_win_get_config(winid)
      -- Exclude floating windows
      if win_cfg.relative == "" then
        table.insert(candidates, winid)
      end
    end
  end

  if #candidates > 0 then
    -- Pick the most recently used non-panel window, or the first candidate
    -- Try vim.fn.win_getid(vim.fn.winnr('#')) for previous window
    local prev_winid = vim.fn.win_getid(vim.fn.winnr("#"))
    if prev_winid ~= 0 and not is_panel_window(prev_winid) then
      for _, winid in ipairs(candidates) do
        if winid == prev_winid then
          return prev_winid
        end
      end
    end
    return candidates[1]
  end

  -- No suitable window found — create one by splitting from the panel
  local panel_winid = M._split and M._split.winid or nil
  if panel_winid and vim.api.nvim_win_is_valid(panel_winid) then
    vim.api.nvim_set_current_win(panel_winid)
    vim.cmd("leftabove vnew")
    local new_winid = vim.api.nvim_get_current_win()
    return new_winid
  end

  -- Last resort: just use the current window
  return vim.api.nvim_get_current_win()
end

--- Resolve the full file path for a section's file_path relative to the session.
---@param session PowerReview.ReviewSession
---@param rel_path string Relative file path from section data
---@return string full_path
local function resolve_full_path(session, rel_path)
  local base
  if session.worktree_path and vim.fn.isdirectory(session.worktree_path) == 1 then
    base = session.worktree_path
  else
    base = vim.fn.getcwd()
  end
  local full = base .. "/" .. rel_path:gsub("\\", "/")
  return full:gsub("\\", "/")
end

--- Open a raw file (no diff) to the left of the comments panel,
--- scrolled to the comment's target line with flash highlight.
---@param section PowerReview.PanelSection
---@param session PowerReview.ReviewSession
local function open_file_action(section, session)
  local data = section.data
  if not data.file_path then
    log.info("No file path for this section")
    return
  end

  local full_path = resolve_full_path(session, data.file_path)
  local target_winid = find_or_create_left_window()

  -- Safety: make absolutely sure we're not opening in the panel window
  if is_panel_window(target_winid) then
    log.warn("Could not find a non-panel window to open file")
    return
  end

  -- Switch to the target window, open the file
  vim.api.nvim_set_current_win(target_winid)
  local ok, err = pcall(vim.cmd, "edit " .. vim.fn.fnameescape(full_path))
  if not ok then
    log.error("Failed to open file: %s", tostring(err))
    return
  end

  local bufnr = vim.api.nvim_win_get_buf(target_winid)
  local signs = require("power-review.ui.signs")

  -- Auto-attach signs if not already attached
  if not signs._attached_bufs[bufnr] then
    signs.attach(bufnr, data.file_path, session)
  end

  -- Flash highlight the target region
  if data.line_start then
    signs.flash_highlight({
      bufnr = bufnr,
      winid = target_winid,
      line_start = data.line_start,
      line_end = data.line_end or data.line_start,
      col_start = data.col_start,
      col_end = data.col_end,
    })
  end
end

--- Open a diff view for the comment's file using native diff.
--- We deliberately use native diff (not codediff) when opening from the
--- comments panel. codediff.nvim's TabClosed cleanup handler fails with
--- E5108 ("Problem while switching windows") when extra windows (like the
--- NuiSplit panel) exist during tab close. The native diff is self-contained
--- and avoids this issue entirely.
---@param section PowerReview.PanelSection
---@param session PowerReview.ReviewSession
local function open_diff_action(section, session)
  local data = section.data
  if not data.file_path then
    log.info("No file path for this section")
    return
  end

  -- Move focus to a non-panel window before opening the new tab.
  -- This ensures `tabnew` doesn't inherit any panel buffer context.
  local target_winid = find_or_create_left_window()
  if not is_panel_window(target_winid) then
    vim.api.nvim_set_current_win(target_winid)
  end

  local diff_mod = require("power-review.ui.diff")

  -- Always use native diff from the panel to avoid codediff quit errors.
  -- open_file_native already creates its own tab.
  local success = diff_mod.open_file_native(session, data.file_path, function()
    if not data.line_start then
      return
    end

    local signs = require("power-review.ui.signs")
    -- Flash on the right pane (source version) which is the current window
    -- after open_file_native finishes
    local current_win = vim.api.nvim_get_current_win()
    local current_buf = vim.api.nvim_win_get_buf(current_win)

    signs.flash_highlight({
      bufnr = current_buf,
      winid = current_win,
      line_start = data.line_start,
      line_end = data.line_end or data.line_start,
      col_start = data.col_start,
      col_end = data.col_end,
    })
  end)

  if not success then
    log.warn("Failed to open diff for %s", data.file_path)
  end
end

-- ============================================================================
-- Panel lifecycle
-- ============================================================================

--- Set up the sticky header bar on the panel window.
--- Uses winbar (always visible per-window bar) to display keybinding hints.
--- Note: statusline doesn't work when laststatus=3 (global statusline).
--- We schedule the winbar set to run after nui.nvim finishes its mount
--- (nui may overwrite win_options during mount), and we also add WinBar
--- to the winhighlight so the bar is visible against the NormalFloat bg.
---@param winid number
local function set_sticky_footer(winid)
  if not winid or not vim.api.nvim_win_is_valid(winid) then
    return
  end
  local bar = table.concat({
    "%#PowerReviewPanelBar#",
    " o:file  gd:diff  a:add  e:edit  d:del  A:approve  R:refresh  q:close",
    "%*",
  }, "")

  -- Schedule to run after nui.nvim mount finishes applying its own win_options,
  -- otherwise nui may overwrite our winbar value.
  vim.schedule(function()
    if not vim.api.nvim_win_is_valid(winid) then
      return
    end
    vim.wo[winid].winbar = bar

    -- Ensure WinBar highlight is visible in this window by including it in
    -- winhighlight. Without this, the NormalFloat remap can make the bar
    -- blend into the background.
    local existing_whl = vim.wo[winid].winhighlight or ""
    if not existing_whl:find("WinBar") then
      local sep = existing_whl ~= "" and "," or ""
      vim.wo[winid].winhighlight = existing_whl .. sep .. "WinBar:PowerReviewPanelBar,WinBarNC:PowerReviewPanelBar"
    end
  end)
end

--- Toggle the all-comments panel.
---@param session PowerReview.ReviewSession
function M.toggle(session)
  if M._visible then
    M.close()
  else
    M.open(session)
  end
end

--- Open the all-comments panel.
---@param session PowerReview.ReviewSession
function M.open(session)
  local ok_nui, NuiSplit = pcall(require, "nui.split")
  if not ok_nui then
    M._quickfix_fallback(session)
    return
  end

  ensure_highlights()

  local ui_cfg = config.get_ui_config()
  local panel_cfg = ui_cfg.comments.panel

  -- Close existing panel if any
  M.close()

  -- Create split
  local position = panel_cfg.position or "right"
  local size_key = (position == "right" or position == "left") and "width" or "height"
  local size_val = panel_cfg[size_key] or 60

  local split = NuiSplit({
    relative = "editor",
    position = position,
    size = size_val,
    buf_options = {
      modifiable = false,
      filetype = "power-review-comments",
      buftype = "nofile",
      swapfile = false,
    },
    win_options = {
      number = false,
      relativenumber = false,
      signcolumn = "no",
      cursorline = true,
      wrap = false,
      winhighlight = "Normal:NormalFloat,CursorLine:Visual",
      conceallevel = 2,
      concealcursor = "nc",
    },
  })

  split:mount()

  M._split = split
  M._visible = true
  M._session = session

  -- Build and render
  M._render(session)

  -- Setup keymaps
  M._setup_keymaps(split, session)

  -- Set the sticky footer (always-visible keymap hints)
  set_sticky_footer(split.winid)

  -- NOTE: We intentionally do NOT start treesitter markdown on this buffer.
  -- The panel uses section-based rendering with indented body text (4-8 spaces).
  -- Treesitter markdown misinterprets this indentation as code blocks and
  -- applies unwanted highlighting that clashes with our extmark-based system.
  -- Instead, fenced code blocks get language-specific treesitter highlighting
  -- via apply_code_block_highlights() in the render pipeline.

  -- Re-render on panel resize so text wrapping adapts to new width
  vim.api.nvim_create_autocmd("WinResized", {
    callback = function()
      if not M._visible or not M._split or not M._split.winid then
        return true -- remove autocmd
      end
      if not vim.api.nvim_win_is_valid(M._split.winid) then
        return true
      end
      -- Check if our panel window is among the resized windows
      local resized = vim.v.event and vim.v.event.windows or {}
      for _, winid in ipairs(resized) do
        if winid == M._split.winid and M._session then
          M._render(M._session)
          return
        end
      end
    end,
  })
end

--- Render (or re-render) the panel content.
---@param session PowerReview.ReviewSession
function M._render(session)
  if not M._split or not M._split.bufnr then
    return
  end
  if not vim.api.nvim_buf_is_valid(M._split.bufnr) then
    return
  end

  -- Compute current panel width for text wrapping
  local panel_width
  if M._split.winid and vim.api.nvim_win_is_valid(M._split.winid) then
    panel_width = vim.api.nvim_win_get_width(M._split.winid)
  end

  local sections = build_sections(session, panel_width)
  render_sections(M._split.bufnr, sections)
  apply_code_block_highlights(M._split.bufnr)
  M._sections = sections
  M._session = session
end

--- Close the panel.
function M.close()
  if M._split then
    pcall(function()
      M._split:unmount()
    end)
    M._split = nil
    M._visible = false
    M._sections = {}
    M._session = nil
  end
end

--- Refresh the panel content.
---@param session PowerReview.ReviewSession
function M.refresh(session)
  if not M._visible then
    return
  end
  M._render(session)
end

--- Check if the panel is visible.
---@return boolean
function M.is_visible()
  return M._visible
end

-- ============================================================================
-- Keymaps
-- ============================================================================

---@param split table NuiSplit
---@param session PowerReview.ReviewSession
function M._setup_keymaps(split, session)
  -- Close
  split:map("n", "q", function()
    M.close()
  end, { noremap = true })

  -- Enter: toggle collapse on collapsible sections, or open diff (same as gd) on leaf items
  split:map("n", "<CR>", function()
    local line = vim.api.nvim_win_get_cursor(0)[1]
    local section = section_at_line(line)
    if not section then
      return
    end

    -- If section is collapsible and cursor is on the header line, toggle collapse
    if section.data.collapsible and line == section.buf_start then
      local key = section.data.collapse_key
      M._collapsed[key] = not M._collapsed[key]
      M._render(M._session or session)
      pcall(vim.api.nvim_win_set_cursor, 0, { math.min(line, vim.api.nvim_buf_line_count(0)), 0 })
      return
    end

    -- Otherwise, open diff (same as gd)
    if section.data.file_path then
      open_diff_action(section, M._session or session)
    end
  end, { noremap = true })

  -- o: open file (raw, no diff) to the left of the panel
  split:map("n", "o", function()
    local line = vim.api.nvim_win_get_cursor(0)[1]
    local section = section_at_line(line)
    if not section then
      return
    end
    if section.data.file_path then
      open_file_action(section, M._session or session)
    end
  end, { noremap = true })

  -- gd: open diff view to the left of the panel
  split:map("n", "gd", function()
    local line = vim.api.nvim_win_get_cursor(0)[1]
    local section = section_at_line(line)
    if not section then
      return
    end
    if section.data.file_path then
      open_diff_action(section, M._session or session)
    end
  end, { noremap = true })

  -- l: expand
  split:map("n", "l", function()
    local line = vim.api.nvim_win_get_cursor(0)[1]
    local section = section_at_line(line)
    if section and section.data.collapsible and M._collapsed[section.data.collapse_key] then
      M._collapsed[section.data.collapse_key] = false
      M._render(M._session or session)
      pcall(vim.api.nvim_win_set_cursor, 0, { math.min(line, vim.api.nvim_buf_line_count(0)), 0 })
    end
  end, { noremap = true })

  -- h: collapse
  split:map("n", "h", function()
    local line = vim.api.nvim_win_get_cursor(0)[1]
    local section = section_at_line(line)
    if section and section.data.collapsible and not M._collapsed[section.data.collapse_key] then
      M._collapsed[section.data.collapse_key] = true
      M._render(M._session or session)
      pcall(vim.api.nvim_win_set_cursor, 0, { math.min(line, vim.api.nvim_buf_line_count(0)), 0 })
    end
  end, { noremap = true })

  -- L: expand all
  split:map("n", "L", function()
    M._collapsed = {}
    M._render(M._session or session)
  end, { noremap = true })

  -- H: collapse all
  split:map("n", "H", function()
    -- Collapse all files and threads
    for _, section in ipairs(M._sections) do
      if section.data.collapse_key then
        M._collapsed[section.data.collapse_key] = true
      end
    end
    M._render(M._session or session)
  end, { noremap = true })

  -- a: add comment / reply to thread
  split:map("n", "a", function()
    local line = vim.api.nvim_win_get_cursor(0)[1]
    local section = section_at_line(line)
    if not section or not section.data.file_path then
      return
    end
    local comment_float = require("power-review.ui.comment_float")
    local editor_opts = {
      file_path = section.data.file_path,
      line = section.data.line_start or 1,
      session = M._session or session,
    }
    if section.data.thread_id then
      editor_opts.thread_id = section.data.thread_id
    end
    comment_float.open_comment_editor(editor_opts)
  end, { noremap = true })

  -- e: edit draft (works on standalone drafts and reply drafts in thread sections)
  split:map("n", "e", function()
    local line = vim.api.nvim_win_get_cursor(0)[1]
    local section = section_at_line(line)
    resolve_draft_from_section(section, "edit", function(draft_id)
      local helpers = require("power-review.session_helpers")
      local cur_session = M._session or session
      local draft = helpers.get_draft(cur_session, draft_id)
      if not draft then
        log.warn("Draft not found")
        return
      end

      local comment_float = require("power-review.ui.comment_float")
      comment_float.open_comment_editor({
        file_path = draft.file_path,
        line = draft.line_start,
        line_end = draft.line_end,
        col_start = draft.col_start,
        col_end = draft.col_end,
        session = cur_session,
        draft_id = draft.id,
        initial_body = draft.body,
      })
    end)
  end, { noremap = true })

  -- d: delete draft (works on standalone drafts and reply drafts in thread sections)
  split:map("n", "d", function()
    local line = vim.api.nvim_win_get_cursor(0)[1]
    local section = section_at_line(line)
    resolve_draft_from_section(section, "delete", function(draft_id)
      vim.ui.input({ prompt = "Delete draft? (y/n): " }, function(input)
        if input == "y" or input == "Y" then
          local pr = require("power-review")
          local ok_del, err = pr.api.delete_draft_comment(draft_id)
          if ok_del then
            log.info("Draft deleted")
            local cur_session = M._session or session
            M._render(cur_session)
          else
            log.error("Failed to delete: %s", err or "unknown")
          end
        end
      end)
    end)
  end, { noremap = true })

  -- A: approve draft (works on standalone drafts and reply drafts in thread sections)
  split:map("n", "A", function()
    local line = vim.api.nvim_win_get_cursor(0)[1]
    local section = section_at_line(line)
    resolve_draft_from_section(section, "approve", function(draft_id)
      local pr = require("power-review")
      local ok_appr, err = pr.api.approve_draft(draft_id)
      if ok_appr then
        log.info("Draft approved (now pending)")
        local cur_session = M._session or session
        M._render(cur_session)
      else
        log.error("Failed to approve: %s", err or "unknown")
      end
    end)
  end, { noremap = true })

  -- R: refresh
  split:map("n", "R", function()
    local pr = require("power-review")
    local current = pr.get_current_session()
    if current then
      M._render(current)
      log.info("Comments panel refreshed")
    end
  end, { noremap = true })

  -- r: resolve/change thread status
  split:map("n", "r", function()
    local line = vim.api.nvim_win_get_cursor(0)[1]
    local section = section_at_line(line)
    if not section or not section.data.thread_id then
      log.info("No thread under cursor")
      return
    end

    local cur_session = M._session or session
    if not cur_session or not cur_session.pr_url then
      log.error("No active session")
      return
    end

    local thread_id = section.data.thread_id
    local current_status = section.data.thread_status or "active"

    local status_options = { "active", "fixed", "wontfix", "closed", "bydesign", "pending" }
    vim.ui.select(status_options, {
      prompt = string.format("Thread #%d status (current: %s):", thread_id, current_status),
      format_item = function(item)
        local icons = {
          active = " Active",
          fixed = " Fixed / Resolved",
          wontfix = " Won't Fix",
          closed = " Closed",
          bydesign = "󰗡 By Design",
          pending = " Pending",
        }
        local marker = item == current_status and " (current)" or ""
        return (icons[item] or item) .. marker
      end,
    }, function(choice)
      if not choice or choice == current_status then
        return
      end

      local cli = require("power-review.cli")
      cli.update_thread_status(cur_session.pr_url, thread_id, choice, function(err, _result)
        if err then
          log.error("Failed to update thread status: %s", err)
          return
        end
        log.info("Thread #%d status changed to %s", thread_id, choice)
        -- Refresh session and re-render
        vim.schedule(function()
          local pr = require("power-review")
          pr.api.sync_threads(function(sync_err)
            if sync_err then
              log.warn("Sync after status update failed: %s", sync_err)
            end
            local updated = pr.get_current_session()
            if updated then
              M._render(updated)
            end
          end)
        end)
      end)
    end)
  end, { noremap = true })
end

-- ============================================================================
-- Quickfix fallback
-- ============================================================================

--- Quickfix fallback when nui.nvim is not available.
---@param session PowerReview.ReviewSession
function M._quickfix_fallback(session)
  local review = require("power-review.review")
  local all_threads = review.get_all_threads(session)
  local qf_items = {}

  -- Drafts
  for _, draft in ipairs(session.drafts) do
    table.insert(qf_items, {
      filename = draft.file_path,
      lnum = draft.line_start,
      text = string.format("[%s] %s: %s", draft.status:upper(), draft.author, draft.body:sub(1, 80)),
    })
  end

  -- Remote threads
  for _, thread in ipairs(all_threads) do
    if thread.type ~= "draft" and thread.file_path then
      local first = thread.comments and thread.comments[1]
      table.insert(qf_items, {
        filename = thread.file_path,
        lnum = thread.line_start or 1,
        text = string.format("[THREAD] %s: %s",
          first and first.author or "unknown",
          first and first.body:sub(1, 80) or ""),
      })
    end
  end

  if #qf_items == 0 then
    log.info("No comments in this review")
    return
  end

  vim.fn.setqflist(qf_items, "r")
  vim.fn.setqflist({}, "a", { title = "PowerReview Comments" })
  vim.cmd("copen")
end

return M
