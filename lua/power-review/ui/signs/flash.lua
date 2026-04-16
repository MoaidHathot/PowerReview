--- PowerReview.nvim signs — flash highlight effects
local M = {}

local config = require("power-review.config")
local hl = require("power-review.ui.signs.highlights")

--- Namespace for temporary flash highlights
M.ns = vim.api.nvim_create_namespace("power_review_flash")

--- Place a temporary flash highlight on a region in a buffer/window.
--- The highlight auto-clears after `duration_ms`.
---@param opts { bufnr: number, winid: number, line_start: number, line_end?: number, col_start?: number, col_end?: number, duration_ms?: number }
function M.highlight(opts)
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
  vim.api.nvim_set_hl(0, hl.groups.flash, {
    default = true,
    bg = colors.flash_bg or "#3e4452",
    bold = true,
  })
  vim.api.nvim_set_hl(0, hl.groups.flash_col, {
    default = true,
    undercurl = true,
    sp = colors.flash_border or "#e5c07b",
    bg = colors.flash_bg or "#3e4452",
    bold = true,
  })

  vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)

  local line_count = vim.api.nvim_buf_line_count(bufnr)

  -- Scroll to center the target line
  vim.api.nvim_win_set_cursor(winid, { math.min(line_start, line_count), 0 })
  vim.api.nvim_win_call(winid, function()
    vim.cmd("normal! zz")
  end)

  -- Place line highlights
  for lnum = line_start, math.min(line_end, line_count) do
    pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, lnum - 1, 0, {
      end_row = lnum - 1,
      line_hl_group = hl.groups.flash,
      priority = 100,
    })
  end

  -- Place column-level highlight if specified
  if col_start and col_end then
    if line_start == line_end then
      local buf_line = vim.api.nvim_buf_get_lines(bufnr, line_start - 1, line_start, false)[1]
      if buf_line then
        local sc = math.min(col_start - 1, #buf_line)
        local ec = math.min(col_end, #buf_line)
        if sc < ec then
          pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, line_start - 1, sc, {
            end_col = ec,
            hl_group = hl.groups.flash_col,
            priority = 110,
          })
        end
      end
    else
      for lnum = line_start, math.min(line_end, line_count) do
        local buf_line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]
        if buf_line and #buf_line > 0 then
          local sc, ec
          if lnum == line_start then
            sc = math.min(col_start - 1, #buf_line)
            ec = #buf_line
          elseif lnum == line_end then
            sc = 0
            ec = math.min(col_end, #buf_line)
          else
            sc = 0
            ec = #buf_line
          end
          if sc < ec then
            pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, lnum - 1, sc, {
              end_col = ec,
              hl_group = hl.groups.flash_col,
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
      vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
    end
  end, duration)
end

return M
