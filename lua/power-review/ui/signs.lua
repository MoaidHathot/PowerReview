--- PowerReview.nvim comment signs & extmarks
--- Places signs/extmarks in diff buffers to indicate comment threads and drafts.
--- Uses the modern nvim_buf_set_extmark API with sign_text.
local M = {}

local log = require("power-review.utils.log")
local config = require("power-review.config")

-- Namespace for all PowerReview extmarks
M._ns = vim.api.nvim_create_namespace("power_review_signs")

--- Highlight groups used for comment signs
M._hl_groups = {
  remote = "PowerReviewSignRemote",
  draft = "PowerReviewSignDraft",
  ai_draft = "PowerReviewSignAIDraft",
  remote_line = "PowerReviewLineRemote",
  draft_line = "PowerReviewLineDraft",
  ai_draft_line = "PowerReviewLineAIDraft",
  col_highlight = "PowerReviewColHighlight",
  col_highlight_draft = "PowerReviewColHighlightDraft",
  virt_author = "PowerReviewVirtAuthor",
  virt_body = "PowerReviewVirtBody",
  virt_thread_status = "PowerReviewVirtThreadStatus",
}

--- Track which buffers we've attached to, so we can clean up.
--- Maps bufnr -> { file_path: string, session_id: string }
---@type table<number, table>
M._attached_bufs = {}

--- Track autocommand group ID
---@type number|nil
M._augroup = nil

-- ============================================================================
-- Highlight setup
-- ============================================================================

--- Define default highlight groups (linked to sensible defaults).
--- Users can override these in their colorscheme.
function M.setup_highlights()
  local colors = config.get().ui.colors or {}

  -- Sign text highlights
  vim.api.nvim_set_hl(0, M._hl_groups.remote, { default = true, link = "DiagnosticSignInfo" })
  vim.api.nvim_set_hl(0, M._hl_groups.draft, { default = true, link = "DiagnosticSignHint" })
  vim.api.nvim_set_hl(0, M._hl_groups.ai_draft, { default = true, link = "DiagnosticSignWarn" })

  -- Line highlights (subtle background tint)
  vim.api.nvim_set_hl(0, M._hl_groups.remote_line, { default = true, link = "DiagnosticVirtualTextInfo" })
  vim.api.nvim_set_hl(0, M._hl_groups.draft_line, { default = true, link = "DiagnosticVirtualTextHint" })
  vim.api.nvim_set_hl(0, M._hl_groups.ai_draft_line, { default = true, link = "DiagnosticVirtualTextWarn" })

  -- Column-level span highlights (underline to mark the exact code the comment targets)
  vim.api.nvim_set_hl(0, M._hl_groups.col_highlight, {
    default = true, undercurl = true, sp = colors.comment_undercurl or "#61afef",
  })
  vim.api.nvim_set_hl(0, M._hl_groups.col_highlight_draft, {
    default = true, undercurl = true, sp = colors.draft_undercurl or "#98c379",
  })

  -- Virtual text sub-highlights
  vim.api.nvim_set_hl(0, M._hl_groups.virt_author, { default = true, link = "Title" })
  vim.api.nvim_set_hl(0, M._hl_groups.virt_body, { default = true, link = "Comment" })
  vim.api.nvim_set_hl(0, M._hl_groups.virt_thread_status, { default = true, link = "DiagnosticInfo" })
end

-- ============================================================================
-- Core extmark placement
-- ============================================================================

--- Place extmarks for a list of comment indicators on a buffer.
--- Clears existing PowerReview extmarks first, then places new ones.
--- Supports column-level highlighting for comments targeting specific code spans.
--- When the buffer is displayed in a diff-mode window, line highlights and
--- virtual text are suppressed to avoid visual overload with diff coloring.
---@param bufnr number Buffer number
---@param indicators PowerReview.CommentIndicator[]
function M.set_indicators(bufnr, indicators)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  -- Clear all existing extmarks in our namespace for this buffer
  vim.api.nvim_buf_clear_namespace(bufnr, M._ns, 0, -1)

  local ui_cfg = config.get_ui_config()
  local sign_icons = ui_cfg.comments.signs

  -- Detect if this buffer is shown in a diff-mode window.
  -- When in diff mode, Neovim's built-in DiffAdd/DiffChange/DiffDelete/DiffText
  -- highlights already provide line backgrounds. Adding our own line_hl_group
  -- and virtual text on top creates visual clutter, so we suppress them.
  local in_diff = false
  for _, winid in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_buf(winid) == bufnr then
      if vim.wo[winid].diff then
        in_diff = true
        break
      end
    end
  end

  local line_count = vim.api.nvim_buf_line_count(bufnr)

  for _, ind in ipairs(indicators) do
    local line = ind.line - 1 -- Convert 1-indexed to 0-indexed
    if line >= 0 and line < line_count then
      local sign_text, sign_hl, line_hl, virt_text

      if ind.kind == "remote" then
        sign_text = sign_icons.remote
        sign_hl = M._hl_groups.remote
        line_hl = M._hl_groups.remote_line
        virt_text = M._format_remote_virt_text(ind)
      elseif ind.kind == "ai_draft" then
        sign_text = sign_icons.ai_draft
        sign_hl = M._hl_groups.ai_draft
        line_hl = M._hl_groups.ai_draft_line
        virt_text = M._format_draft_virt_text(ind)
      else -- "draft"
        sign_text = sign_icons.draft
        sign_hl = M._hl_groups.draft
        line_hl = M._hl_groups.draft_line
        virt_text = M._format_draft_virt_text(ind)
      end

      local extmark_opts = {
        sign_text = sign_text,
        sign_hl_group = sign_hl,
        priority = ind.kind == "remote" and 10 or 20, -- Drafts on top of remote
      }

      -- In diff mode, skip line highlights (diff coloring already provides
      -- background tints for changed regions). Virtual text is always shown
      -- so that comment previews remain visible even in diff views.
      if not in_diff then
        extmark_opts.line_hl_group = line_hl
      end
      -- Add virtual text with comment preview (right-aligned)
      if virt_text and #virt_text > 0 then
        extmark_opts.virt_text = virt_text
        extmark_opts.virt_text_pos = "eol"
      end

      pcall(vim.api.nvim_buf_set_extmark, bufnr, M._ns, line, 0, extmark_opts)

      -- Column-level highlighting: underline the exact code span the comment targets.
      -- Uses col_start/col_end (1-indexed) to place an extmark with hl_group
      -- that underlines only the targeted code, not the entire line.
      if ind.col_start and ind.col_end then
        local col_hl = ind.kind == "remote" and M._hl_groups.col_highlight or M._hl_groups.col_highlight_draft
        local buf_line = vim.api.nvim_buf_get_lines(bufnr, line, line + 1, false)[1]
        if buf_line then
          local start_col = math.min(ind.col_start - 1, #buf_line) -- 0-indexed byte offset
          local end_col
          if ind.line_end and ind.line_end ~= ind.line then
            -- Multi-line column range: highlight from col_start to end of first line
            end_col = #buf_line
          else
            -- Single-line column range
            end_col = math.min(ind.col_end, #buf_line)
          end
          if start_col < end_col then
            pcall(vim.api.nvim_buf_set_extmark, bufnr, M._ns, line, start_col, {
              end_col = end_col,
              hl_group = col_hl,
              priority = 30, -- Above line highlight
            })
          end
        end
      end

      -- Handle range comments: highlight continuation lines and add column highlight on last line
      if ind.line_end and ind.line_end > ind.line then
        for range_line = ind.line + 1, ind.line_end do
          local rline = range_line - 1 -- 0-indexed
          if rline >= 0 and rline < line_count then
            local range_opts = {
              priority = ind.kind == "remote" and 10 or 20,
            }
            -- Add a continuation sign on range lines
            range_opts.sign_text = ""
            range_opts.sign_hl_group = sign_hl
            -- Only add line highlight outside diff mode
            if not in_diff then
              range_opts.line_hl_group = line_hl
            end

            pcall(vim.api.nvim_buf_set_extmark, bufnr, M._ns, rline, 0, range_opts)

            -- If this is the last line and we have col_end, highlight up to col_end
            if range_line == ind.line_end and ind.col_start and ind.col_end then
              local col_hl = ind.kind == "remote" and M._hl_groups.col_highlight or M._hl_groups.col_highlight_draft
              local buf_line = vim.api.nvim_buf_get_lines(bufnr, rline, rline + 1, false)[1]
              if buf_line then
                local end_col = math.min(ind.col_end, #buf_line)
                if end_col > 0 then
                  pcall(vim.api.nvim_buf_set_extmark, bufnr, M._ns, rline, 0, {
                    end_col = end_col,
                    hl_group = col_hl,
                    priority = 30,
                  })
                end
              end
            end

            -- For middle lines of a column range, highlight the whole line
            if ind.col_start and ind.col_end and range_line ~= ind.line_end then
              local col_hl = ind.kind == "remote" and M._hl_groups.col_highlight or M._hl_groups.col_highlight_draft
              local buf_line = vim.api.nvim_buf_get_lines(bufnr, rline, rline + 1, false)[1]
              if buf_line and #buf_line > 0 then
                pcall(vim.api.nvim_buf_set_extmark, bufnr, M._ns, rline, 0, {
                  end_col = #buf_line,
                  hl_group = col_hl,
                  priority = 30,
                })
              end
            end
          end
        end
      end
    end
  end
end

--- Format virtual text for a remote comment indicator.
--- Shows thread status, author, reply count, and body preview.
---@param ind PowerReview.CommentIndicator
---@return table[]|nil virt_text chunks {text, hl_group}
function M._format_remote_virt_text(ind)
  local chunks = {}
  local max_len = (config.get().ui.virtual_text or {}).max_length or 80

  -- Thread status icon (full set matching panel icons)
  local status = ind.thread_status or "active"
  local status_icons = {
    active = " ",
    fixed = " ",
    wontfix = " ",
    closed = " ",
    bydesign = "󰗡 ",
    pending = " ",
  }
  local status_icon = status_icons[status] or status_icons.active
  table.insert(chunks, { "  " .. status_icon, M._hl_groups.virt_thread_status })

  -- Author
  if ind.author then
    table.insert(chunks, { ind.author .. ": ", M._hl_groups.virt_author })
  end

  -- Body preview (first line, capped)
  local preview = ind.preview or ""
  -- Take first line only
  local first_line = preview:match("^([^\n]*)")
  if first_line and #first_line > max_len then
    first_line = first_line:sub(1, max_len - 3) .. "..."
  end
  if first_line and first_line ~= "" then
    table.insert(chunks, { first_line, M._hl_groups.virt_body })
  end

  -- Reply count
  if ind.count and ind.count > 1 then
    table.insert(chunks, { string.format("  (+%d)", ind.count - 1), M._hl_groups.virt_thread_status })
  end

  return #chunks > 0 and chunks or nil
end

--- Format virtual text for a draft comment indicator.
--- Shows draft status badge, author type, and body preview.
---@param ind PowerReview.CommentIndicator
---@return table[]|nil virt_text chunks {text, hl_group}
function M._format_draft_virt_text(ind)
  local chunks = {}
  local max_len = (config.get().ui.virtual_text or {}).max_length or 80

  -- Draft badge
  local badge_hl = M._hl_groups[ind.kind]
  local label = ind.kind == "ai_draft" and "  [AI Draft] " or "  [Draft] "
  table.insert(chunks, { label, badge_hl })

  -- Body preview (first line, capped)
  local preview = ind.preview or ""
  local first_line = preview:match("^([^\n]*)")
  if first_line and #first_line > max_len then
    first_line = first_line:sub(1, max_len - 3) .. "..."
  end
  if first_line and first_line ~= "" then
    table.insert(chunks, { first_line, M._hl_groups.virt_body })
  end

  return #chunks > 0 and chunks or nil
end

-- ============================================================================
-- Building indicators from session data
-- ============================================================================

---@class PowerReview.CommentIndicator
---@field kind "remote"|"draft"|"ai_draft"
---@field line number 1-indexed
---@field line_end? number 1-indexed end of range
---@field col_start? number 1-indexed start column
---@field col_end? number 1-indexed end column
---@field count? number Number of comments at this location
---@field preview? string First comment body preview
---@field author? string First comment author
---@field draft_id? string For drafts, the draft comment ID
---@field thread_id? number For remote threads, the thread ID
---@field thread_status? string Thread status string (active/resolved/etc.)

--- Build indicators for a specific file from the current session.
--- Merges remote threads + local drafts.
---@param session PowerReview.ReviewSession
---@param file_path string Relative file path (normalized with forward slashes)
---@return PowerReview.CommentIndicator[]
function M.build_indicators(session, file_path)
  local indicators = {}

  -- 1. Local drafts from session
  local helpers = require("power-review.session_helpers")
  local drafts = helpers.get_drafts_for_file(session, file_path)

  for _, draft in ipairs(drafts) do
    if draft.line_start and draft.line_start > 0 then
      table.insert(indicators, {
        kind = draft.author == "ai" and "ai_draft" or "draft",
        line = draft.line_start,
        line_end = draft.line_end,
        col_start = draft.col_start,
        col_end = draft.col_end,
        count = 1,
        preview = draft.body,
        author = draft.author,
        draft_id = draft.id,
      })
    end
  end

  -- 2. Remote threads (from review coordinator cache)
  local review = require("power-review.review")
  local threads = review.get_threads_for_file(session, file_path)

  for _, thread in ipairs(threads) do
    if thread.type ~= "draft" and thread.line_start and thread.line_start > 0 then
      -- Remote thread
      local first_comment = thread.comments and thread.comments[1]
      table.insert(indicators, {
        kind = "remote",
        line = thread.line_start,
        line_end = thread.line_end,
        col_start = thread.col_start,
        col_end = thread.col_end,
        count = thread.comments and #thread.comments or 0,
        preview = first_comment and first_comment.body or "",
        author = first_comment and first_comment.author or nil,
        thread_id = thread.id,
        thread_status = thread.status,
      })
    end
  end

  -- Sort by line number (remote first, then drafts for same line)
  table.sort(indicators, function(a, b)
    if a.line ~= b.line then
      return a.line < b.line
    end
    -- Remote before draft on same line
    if a.kind == "remote" and b.kind ~= "remote" then
      return true
    end
    return false
  end)

  log.debug("build_indicators(%s): %d drafts + %d remote threads → %d indicators",
    file_path, #drafts, #threads, #indicators)

  return indicators
end

-- ============================================================================
-- Buffer attachment & lifecycle
-- ============================================================================

--- Attach to a buffer to display comment signs.
--- Tracks the buffer so we can refresh it later when drafts change.
---@param bufnr number
---@param file_path string Relative file path
---@param session PowerReview.ReviewSession
function M.attach(bufnr, file_path, session)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  M._attached_bufs[bufnr] = {
    file_path = file_path,
    session_id = session.id,
  }

  -- Place initial indicators
  local indicators = M.build_indicators(session, file_path)
  M.set_indicators(bufnr, indicators)

  -- Setup buffer-local keymaps for this diff buffer
  local ui = require("power-review.ui")
  ui.setup_buffer_keymaps(bufnr)

  log.debug("Attached signs to buffer %d for %s (%d indicators)", bufnr, file_path, #indicators)
end

--- Detach from a buffer (clear extmarks, remove tracking).
---@param bufnr number
function M.detach(bufnr)
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, M._ns, 0, -1)
  end
  M._attached_bufs[bufnr] = nil
  -- Clean up buffer-local keymaps tracking
  local ui_ok, ui = pcall(require, "power-review.ui")
  if ui_ok then
    ui.cleanup_buffer_keymaps(bufnr)
  end
end

--- Detach from all tracked buffers.
function M.detach_all()
  for bufnr, _ in pairs(M._attached_bufs) do
    M.detach(bufnr)
  end
  M._attached_bufs = {}
end

--- Refresh signs on all attached buffers for the current session.
--- Call this after draft create/edit/delete or after fetching remote threads.
function M.refresh()
  local pr = require("power-review")
  local session = pr.get_current_session()
  if not session then
    return
  end

  -- Clean up invalid buffers first
  local to_remove = {}
  for bufnr, _ in pairs(M._attached_bufs) do
    if not vim.api.nvim_buf_is_valid(bufnr) then
      table.insert(to_remove, bufnr)
    end
  end
  for _, bufnr in ipairs(to_remove) do
    M._attached_bufs[bufnr] = nil
  end

  -- Refresh each attached buffer
  for bufnr, info in pairs(M._attached_bufs) do
    if info.session_id == session.id then
      local indicators = M.build_indicators(session, info.file_path)
      M.set_indicators(bufnr, indicators)
    end
  end
end

--- Refresh signs for a specific file path across all attached buffers.
---@param file_path string Relative file path
function M.refresh_file(file_path)
  local pr = require("power-review")
  local session = pr.get_current_session()
  if not session then
    return
  end

  local indicators = M.build_indicators(session, file_path)

  for bufnr, info in pairs(M._attached_bufs) do
    if info.file_path == file_path and info.session_id == session.id then
      if vim.api.nvim_buf_is_valid(bufnr) then
        M.set_indicators(bufnr, indicators)
      end
    end
  end
end

-- ============================================================================
-- Query API (for clicking on signs, navigation)
-- ============================================================================

--- Get the comment indicator at a specific line in a buffer.
--- Returns the extmark data and associated indicator metadata.
---@param bufnr number
---@param line number 1-indexed line number
---@return PowerReview.CommentIndicator[]
function M.get_indicators_at_line(bufnr, line)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return {}
  end

  local info = M._attached_bufs[bufnr]
  if not info then
    return {}
  end

  local pr = require("power-review")
  local session = pr.get_current_session()
  if not session or session.id ~= info.session_id then
    return {}
  end

  -- Rebuild indicators for this file and filter by line
  local all_indicators = M.build_indicators(session, info.file_path)
  local at_line = {}
  for _, ind in ipairs(all_indicators) do
    if ind.line == line then
      table.insert(at_line, ind)
    elseif ind.line_end and line >= ind.line and line <= ind.line_end then
      table.insert(at_line, ind)
    end
  end
  return at_line
end

--- Navigate to the next comment sign in the current buffer.
---@param direction number 1 for forward, -1 for backward
function M.goto_next(direction)
  direction = direction or 1
  local bufnr = vim.api.nvim_get_current_buf()
  local info = M._attached_bufs[bufnr]
  if not info then
    log.info("No comment signs in this buffer")
    return
  end

  local pr = require("power-review")
  local session = pr.get_current_session()
  if not session then
    return
  end

  local indicators = M.build_indicators(session, info.file_path)
  if #indicators == 0 then
    log.info("No comments in this file")
    return
  end

  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]

  -- Collect unique lines
  local lines = {}
  local seen = {}
  for _, ind in ipairs(indicators) do
    if not seen[ind.line] then
      table.insert(lines, ind.line)
      seen[ind.line] = true
    end
  end
  table.sort(lines)

  local target_line
  if direction > 0 then
    -- Find next line after cursor
    for _, l in ipairs(lines) do
      if l > cursor_line then
        target_line = l
        break
      end
    end
    -- Wrap around
    if not target_line then
      target_line = lines[1]
    end
  else
    -- Find previous line before cursor
    for i = #lines, 1, -1 do
      if lines[i] < cursor_line then
        target_line = lines[i]
        break
      end
    end
    -- Wrap around
    if not target_line then
      target_line = lines[#lines]
    end
  end

  if target_line then
    vim.api.nvim_win_set_cursor(0, { target_line, 0 })
    -- Show indicators at this line for quick reference
    local at_line = M.get_indicators_at_line(bufnr, target_line)
    if #at_line > 0 then
      local first = at_line[1]
      local kind_label = first.kind == "remote" and "Comment" or "Draft"
      local preview = first.preview and first.preview:sub(1, 60) or ""
      log.info("[%s] Line %d: %s", kind_label, target_line, preview)
    end
  end
end

--- Go to next comment in the current buffer.
function M.goto_next_comment()
  M.goto_next(1)
end

--- Go to previous comment in the current buffer.
function M.goto_prev_comment()
  M.goto_next(-1)
end

-- ============================================================================
-- Auto-attach to diff buffers
-- ============================================================================

--- Setup autocommands to auto-attach signs when diff buffers are opened.
--- Listens for BufEnter/FileType events and CodeDiff user events.
function M.setup_autocommands()
  if M._augroup then
    vim.api.nvim_del_augroup_by_id(M._augroup)
  end

  M._augroup = vim.api.nvim_create_augroup("PowerReviewSigns", { clear = true })

  -- Auto-attach when entering a buffer that belongs to a review session
  vim.api.nvim_create_autocmd("BufEnter", {
    group = M._augroup,
    callback = function(args)
      local ok, err = pcall(M._try_auto_attach, args.buf)
      if not ok then
        local log = require("power-review.utils.log")
        log.debug("Signs auto-attach error (non-fatal): %s", tostring(err))
      end
    end,
  })

  -- Listen for CodeDiff events to attach to diff buffers
  vim.api.nvim_create_autocmd("User", {
    group = M._augroup,
    pattern = "CodeDiffOpen",
    callback = function()
      -- After CodeDiff opens, try to attach to all visible windows
      vim.schedule(function()
        M._attach_visible_diff_buffers()
      end)
    end,
  })

  -- Clean up when buffers are deleted
  vim.api.nvim_create_autocmd("BufDelete", {
    group = M._augroup,
    callback = function(args)
      if M._attached_bufs[args.buf] then
        M._attached_bufs[args.buf] = nil
        -- Clean up buffer-local keymaps tracking
        local ui_ok, ui = pcall(require, "power-review.ui")
        if ui_ok then
          ui.cleanup_buffer_keymaps(args.buf)
        end
      end
    end,
  })

  -- Refresh signs when switching tabs (handles the case where threads
  -- were loaded via background sync after the diff tab was opened)
  vim.api.nvim_create_autocmd("TabEnter", {
    group = M._augroup,
    callback = function()
      -- Only refresh if we have attached buffers in this tab
      local tab_wins = vim.api.nvim_tabpage_list_wins(0)
      local has_attached = false
      for _, winid in ipairs(tab_wins) do
        if vim.api.nvim_win_is_valid(winid) then
          local bufnr = vim.api.nvim_win_get_buf(winid)
          if M._attached_bufs[bufnr] then
            has_attached = true
            break
          end
        end
      end
      if has_attached then
        vim.schedule(function()
          M.refresh()
        end)
      end
    end,
  })
end

--- Try to auto-attach signs to a buffer if it's part of a review.
---@param bufnr number
function M._try_auto_attach(bufnr)
  -- Don't re-attach
  if M._attached_bufs[bufnr] then
    return
  end

  local pr = require("power-review")
  local session = pr.get_current_session()
  if not session then
    return
  end

  -- Try to resolve the buffer's file path relative to the review
  local file_path = M._resolve_review_file_path(bufnr, session)
  if file_path then
    M.attach(bufnr, file_path, session)
  end
end

--- Try to attach signs to all visible diff buffers.
function M._attach_visible_diff_buffers()
  local pr = require("power-review")
  local session = pr.get_current_session()
  if not session then
    return
  end

  for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local bufnr = vim.api.nvim_win_get_buf(winid)
    if not M._attached_bufs[bufnr] then
      local file_path = M._resolve_review_file_path(bufnr, session)
      if file_path then
        M.attach(bufnr, file_path, session)
      end
    end
  end
end

--- Resolve a buffer's file path relative to the review session.
--- Returns nil if the buffer doesn't belong to the current review.
---@param bufnr number
---@param session PowerReview.ReviewSession
---@return string|nil file_path Relative path or nil
function M._resolve_review_file_path(bufnr, session)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end

  local buf_name = vim.api.nvim_buf_get_name(bufnr)
  if buf_name == "" then
    return nil
  end

  -- Normalize path separators
  buf_name = buf_name:gsub("\\", "/")

  -- Build a list of base paths to try stripping
  local bases = {}

  if session.worktree_path then
    table.insert(bases, (session.worktree_path:gsub("\\", "/")))
  end

  local cwd = (vim.fn.getcwd():gsub("\\", "/"))
  table.insert(bases, cwd)

  for _, base in ipairs(bases) do
    -- Ensure base ends without trailing slash
    base = base:gsub("/$", "")
    if buf_name:find(base, 1, true) == 1 then
      local rel = buf_name:sub(#base + 2) -- +2 for the slash
      -- Verify this file is in the changed files list
      if M._is_review_file(session, rel) then
        return rel
      end
    end
  end

  -- Also check CodeDiff-style buffer names like "[main] path/to/file.lua"
  local ref_match = buf_name:match("^%[.-%]%s+(.+)$")
  if ref_match and M._is_review_file(session, ref_match) then
    return ref_match
  end

  return nil
end

--- Check if a relative file path is in the session's changed files.
---@param session PowerReview.ReviewSession
---@param rel_path string
---@return boolean
function M._is_review_file(session, rel_path)
  -- Normalize for comparison
  rel_path = rel_path:gsub("\\", "/")
  for _, file in ipairs(session.files) do
    local fp = file.path:gsub("\\", "/")
    if fp == rel_path then
      return true
    end
  end
  return false
end

-- ============================================================================
-- Temporary flash highlight (for panel → file jump)
-- ============================================================================

--- Namespace for temporary flash highlights
M._flash_ns = vim.api.nvim_create_namespace("power_review_flash")

--- Flash highlight group (bright, attention-grabbing)
M._hl_groups.flash = "PowerReviewFlash"
M._hl_groups.flash_col = "PowerReviewFlashCol"

--- Place a temporary flash highlight on a region in a buffer/window.
--- The highlight auto-clears after `duration_ms` (default 2000ms).
--- Scrolls the window to center the target line.
---@param opts { bufnr: number, winid: number, line_start: number, line_end?: number, col_start?: number, col_end?: number, duration_ms?: number }
function M.flash_highlight(opts)
  local bufnr = opts.bufnr
  local winid = opts.winid
  local line_start = opts.line_start
  local line_end = opts.line_end or line_start
  local col_start = opts.col_start
  local col_end = opts.col_end
  local ui_cfg = config.get().ui
  local colors = ui_cfg.colors or {}
  local duration = opts.duration_ms or (ui_cfg.flash or {}).duration or 2000

  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  if not vim.api.nvim_win_is_valid(winid) then
    return
  end

  -- Ensure flash highlight groups exist
  vim.api.nvim_set_hl(0, M._hl_groups.flash, {
    default = true, bg = colors.flash_bg or "#3e4452", bold = true,
  })
  vim.api.nvim_set_hl(0, M._hl_groups.flash_col, {
    default = true, undercurl = true,
    sp = colors.flash_border or "#e5c07b",
    bg = colors.flash_bg or "#3e4452", bold = true,
  })

  -- Clear any prior flash
  vim.api.nvim_buf_clear_namespace(bufnr, M._flash_ns, 0, -1)

  local line_count = vim.api.nvim_buf_line_count(bufnr)

  -- Scroll to center the target line
  vim.api.nvim_win_set_cursor(winid, { math.min(line_start, line_count), 0 })
  vim.api.nvim_win_call(winid, function()
    vim.cmd("normal! zz")
  end)

  -- Place line highlights on the full range
  for lnum = line_start, math.min(line_end, line_count) do
    pcall(vim.api.nvim_buf_set_extmark, bufnr, M._flash_ns, lnum - 1, 0, {
      end_row = lnum - 1,
      line_hl_group = M._hl_groups.flash,
      priority = 100,
    })
  end

  -- Place column-level highlight if specified
  if col_start and col_end then
    local start_line = line_start
    local end_line = line_end

    -- Single-line column range
    if start_line == end_line then
      local buf_line = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, start_line, false)[1]
      if buf_line then
        local sc = math.min(col_start - 1, #buf_line)
        local ec = math.min(col_end, #buf_line)
        if sc < ec then
          pcall(vim.api.nvim_buf_set_extmark, bufnr, M._flash_ns, start_line - 1, sc, {
            end_col = ec,
            hl_group = M._hl_groups.flash_col,
            priority = 110,
          })
        end
      end
    else
      -- Multi-line: first line col_start→EOL, middle lines full, last line start→col_end
      for lnum = start_line, math.min(end_line, line_count) do
        local buf_line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]
        if buf_line and #buf_line > 0 then
          local sc, ec
          if lnum == start_line then
            sc = math.min(col_start - 1, #buf_line)
            ec = #buf_line
          elseif lnum == end_line then
            sc = 0
            ec = math.min(col_end, #buf_line)
          else
            sc = 0
            ec = #buf_line
          end
          if sc < ec then
            pcall(vim.api.nvim_buf_set_extmark, bufnr, M._flash_ns, lnum - 1, sc, {
              end_col = ec,
              hl_group = M._hl_groups.flash_col,
              priority = 110,
            })
          end
        end
      end
    end
  end

  -- Auto-clear after duration
  vim.defer_fn(function()
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_clear_namespace(bufnr, M._flash_ns, 0, -1)
    end
  end, duration)
end

-- ============================================================================
-- Module initialization
-- ============================================================================

--- Initialize the signs module.
--- Called during plugin setup.
function M.setup()
  M.setup_highlights()
  M.setup_autocommands()
end

return M
