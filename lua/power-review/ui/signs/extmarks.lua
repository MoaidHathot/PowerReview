--- PowerReview.nvim signs — core extmark placement & virtual text formatting
local M = {}

local config = require("power-review.config")
local hl = require("power-review.ui.signs.highlights")

--- Namespace for all PowerReview extmarks
M.ns = vim.api.nvim_create_namespace("power_review_signs")

--- Place extmarks for a list of comment indicators on a buffer.
--- Clears existing PowerReview extmarks first, then places new ones.
--- Supports column-level highlighting for comments targeting specific code spans.
--- When the buffer is displayed in a diff-mode window, line highlights are suppressed.
---@param bufnr number Buffer number
---@param indicators PowerReview.CommentIndicator[]
function M.set_indicators(bufnr, indicators)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)

  local ui_cfg = config.get_ui_config()
  local sign_icons = ui_cfg.comments.signs

  -- Detect if this buffer is shown in a diff-mode window.
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
    local line = ind.line - 1
    if line >= 0 and line < line_count then
      local sign_text, sign_hl, line_hl, virt_text

      if ind.kind == "remote" then
        sign_text = sign_icons.remote
        sign_hl = hl.groups.remote
        line_hl = hl.groups.remote_line
        virt_text = M._format_remote_virt_text(ind)
      elseif ind.kind == "ai_draft" then
        sign_text = sign_icons.ai_draft
        sign_hl = hl.groups.ai_draft
        line_hl = hl.groups.ai_draft_line
        virt_text = M._format_draft_virt_text(ind)
      else
        sign_text = sign_icons.draft
        sign_hl = hl.groups.draft
        line_hl = hl.groups.draft_line
        virt_text = M._format_draft_virt_text(ind)
      end

      local extmark_opts = {
        sign_text = sign_text,
        sign_hl_group = sign_hl,
        priority = ind.kind == "remote" and 10 or 20,
      }

      if not in_diff then
        extmark_opts.line_hl_group = line_hl
      end
      if virt_text and #virt_text > 0 then
        extmark_opts.virt_text = virt_text
        extmark_opts.virt_text_pos = "eol"
      end

      pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, line, 0, extmark_opts)

      -- Column-level highlighting
      if ind.col_start and ind.col_end then
        local col_hl = ind.kind == "remote" and hl.groups.col_highlight or hl.groups.col_highlight_draft
        local buf_line = vim.api.nvim_buf_get_lines(bufnr, line, line + 1, false)[1]
        if buf_line then
          local start_col = math.min(ind.col_start - 1, #buf_line)
          local end_col
          if ind.line_end and ind.line_end ~= ind.line then
            end_col = #buf_line
          else
            end_col = math.min(ind.col_end, #buf_line)
          end
          if start_col < end_col then
            pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, line, start_col, {
              end_col = end_col,
              hl_group = col_hl,
              priority = 30,
            })
          end
        end
      end

      -- Handle range comments
      if ind.line_end and ind.line_end > ind.line then
        for range_line = ind.line + 1, ind.line_end do
          local rline = range_line - 1
          if rline >= 0 and rline < line_count then
            local range_opts = {
              priority = ind.kind == "remote" and 10 or 20,
              sign_text = "",
              sign_hl_group = sign_hl,
            }
            if not in_diff then
              range_opts.line_hl_group = line_hl
            end

            pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, rline, 0, range_opts)

            if range_line == ind.line_end and ind.col_start and ind.col_end then
              local col_hl_r = ind.kind == "remote" and hl.groups.col_highlight or hl.groups.col_highlight_draft
              local buf_line_r = vim.api.nvim_buf_get_lines(bufnr, rline, rline + 1, false)[1]
              if buf_line_r then
                local end_col_r = math.min(ind.col_end, #buf_line_r)
                if end_col_r > 0 then
                  pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, rline, 0, {
                    end_col = end_col_r,
                    hl_group = col_hl_r,
                    priority = 30,
                  })
                end
              end
            end

            if ind.col_start and ind.col_end and range_line ~= ind.line_end then
              local col_hl_m = ind.kind == "remote" and hl.groups.col_highlight or hl.groups.col_highlight_draft
              local buf_line_m = vim.api.nvim_buf_get_lines(bufnr, rline, rline + 1, false)[1]
              if buf_line_m and #buf_line_m > 0 then
                pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, rline, 0, {
                  end_col = #buf_line_m,
                  hl_group = col_hl_m,
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
---@param ind PowerReview.CommentIndicator
---@return table[]|nil
function M._format_remote_virt_text(ind)
  local chunks = {}
  local max_len = (config.get().ui.virtual_text or {}).max_length or 80

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
  table.insert(chunks, { "  " .. status_icon, hl.groups.virt_thread_status })

  if ind.author then
    table.insert(chunks, { ind.author .. ": ", hl.groups.virt_author })
  end

  local preview = ind.preview or ""
  local first_line = preview:match("^([^\n]*)")
  if first_line and #first_line > max_len then
    first_line = first_line:sub(1, max_len - 3) .. "..."
  end
  if first_line and first_line ~= "" then
    table.insert(chunks, { first_line, hl.groups.virt_body })
  end

  if ind.count and ind.count > 1 then
    table.insert(chunks, { string.format("  (+%d)", ind.count - 1), hl.groups.virt_thread_status })
  end

  return #chunks > 0 and chunks or nil
end

--- Format virtual text for a draft comment indicator.
---@param ind PowerReview.CommentIndicator
---@return table[]|nil
function M._format_draft_virt_text(ind)
  local chunks = {}
  local max_len = (config.get().ui.virtual_text or {}).max_length or 80

  local badge_hl = hl.groups[ind.kind]
  local label
  if ind.kind == "ai_draft" then
    label = ind.author_name and string.format("  [AI Draft: %s] ", ind.author_name) or "  [AI Draft] "
  else
    label = "  [Draft] "
  end
  table.insert(chunks, { label, badge_hl })

  local preview = ind.preview or ""
  local first_line = preview:match("^([^\n]*)")
  if first_line and #first_line > max_len then
    first_line = first_line:sub(1, max_len - 3) .. "..."
  end
  if first_line and first_line ~= "" then
    table.insert(chunks, { first_line, hl.groups.virt_body })
  end

  return #chunks > 0 and chunks or nil
end

return M
