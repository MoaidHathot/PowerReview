--- PowerReview.nvim statusline integration
--- Provides functions for lualine and other statusline plugins.
--- Shows review mode indicator, PR info, draft counts, and per-file comment counts.
local M = {}

--- Check if a review session is currently active.
---@return boolean
function M.is_active()
  local pr = require("power-review")
  return pr._current_session ~= nil
end

--- Resolve the current buffer's file path relative to the review session.
--- Returns nil if the buffer isn't part of the review.
---@param session PowerReview.ReviewSession
---@return string|nil file_path
local function resolve_current_file(session)
  local signs = require("power-review.ui.signs")
  local bufnr = vim.api.nvim_get_current_buf()

  -- First check if signs already tracks this buffer (fast path)
  local info = signs._attached_bufs[bufnr]
  if info and info.session_id == session.id then
    return info.file_path
  end

  -- Fallback: try to resolve from buffer name
  return signs._resolve_review_file_path(bufnr, session)
end

--- Count comments (remote threads + drafts) for a specific file.
--- Distinguishes active vs resolved remote threads.
---@param session PowerReview.ReviewSession
---@param file_path string
---@return number active_count, number resolved_count, number draft_count
local function count_file_comments(session, file_path)
  local helpers = require("power-review.session_helpers")
  local remote_threads = helpers.get_threads_for_file(session, file_path)
  local drafts = helpers.get_drafts_for_file(session, file_path)

  local active_count = 0
  local resolved_count = 0
  for _, thread in ipairs(remote_threads) do
    if thread.line_start and thread.line_start > 0 and not thread.is_deleted then
      local status = (thread.status or "active"):lower()
      if status == "active" or status == "pending" then
        active_count = active_count + 1
      else
        resolved_count = resolved_count + 1
      end
    end
  end

  return active_count, resolved_count, #drafts
end

--- Get the statusline display string for lualine.
--- Returns a formatted string with review icon, PR number, draft count,
--- and per-file comment count for the current buffer.
--- Returns empty string when no review is active (use M.is_active as cond).
---@return string
function M.get()
  local pr = require("power-review")
  local session = pr._current_session
  if not session then
    return ""
  end

  local helpers = require("power-review.session_helpers")
  local counts = helpers.get_draft_counts(session)
  local progress = helpers.get_review_progress(session)

  local parts = {}
  -- Review mode icon + PR identifier
  table.insert(parts, string.format(" PR #%d", session.pr_id))

  -- Iteration number (if tracked)
  if session.reviewed_iteration_id and session.reviewed_iteration_id > 0 then
    table.insert(parts, string.format("#%d", session.reviewed_iteration_id))
  end

  -- Review progress (if any files have been reviewed or changed)
  if progress.total > 0 then
    local reviewed = progress.reviewed or 0
    local unreviewed = progress.total - reviewed
    local prog_parts = {}
    table.insert(prog_parts, string.format("%d/%d", reviewed, progress.total))
    if progress.changed > 0 then
      table.insert(prog_parts, string.format("%d", progress.changed))
    end
    local bracket = "[" .. table.concat(prog_parts, " ") .. "]"
    if unreviewed > 0 then
      bracket = bracket .. string.format(" %d unreviewed", unreviewed)
    end
    table.insert(parts, bracket)
  end

  -- Draft counts (only if there are any)
  if counts.total > 0 then
    local draft_parts = {}
    if counts.draft > 0 then
      table.insert(draft_parts, counts.draft .. " draft")
    end
    if counts.pending > 0 then
      table.insert(draft_parts, counts.pending .. " pending")
    end
    table.insert(parts, "[" .. table.concat(draft_parts, ", ") .. "]")
  end

  -- Per-file comment count for current buffer
  local file_path = resolve_current_file(session)
  if file_path then
    local active, resolved, drafts = count_file_comments(session, file_path)
    local total = active + resolved + drafts
    if total > 0 then
      local file_parts = {}
      if active > 0 then
        table.insert(file_parts, active .. "")
      end
      if resolved > 0 then
        table.insert(file_parts, resolved .. "")
      end
      if drafts > 0 then
        table.insert(file_parts, drafts .. "")
      end
      table.insert(parts, " " .. table.concat(file_parts, " "))
    end
  end

  return table.concat(parts, " ")
end

--- Lualine-compatible component table.
--- Usage in lualine config:
---   require("power-review.statusline").lualine()
--- Returns a table that lualine can use directly in a section.
---@return table lualine_component
function M.lualine()
  local colors = require("power-review.config").get().ui.colors or {}
  return {
    M.get,
    cond = M.is_active,
    color = { fg = colors.statusline_fg or "#61afef", gui = "bold" },
  }
end

return M
