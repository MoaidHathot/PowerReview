--- PowerReview.nvim signs — comment navigation
local M = {}

local log = require("power-review.utils.log")

--- Navigate to the next comment sign in the current buffer.
---@param direction number 1 for forward, -1 for backward
---@param attached_bufs table<number, table> Buffer attachment tracking
---@param build_indicators fun(session: table, file_path: string): table[] Indicator builder
function M.goto_next(direction, attached_bufs, build_indicators)
  direction = direction or 1
  local bufnr = vim.api.nvim_get_current_buf()
  local info = attached_bufs[bufnr]
  if not info then
    log.info("No comment signs in this buffer")
    return
  end

  local pr = require("power-review")
  local session = pr.get_current_session()
  if not session then
    return
  end

  local indicators = build_indicators(session, info.file_path)
  if #indicators == 0 then
    log.info("No comments in this file")
    return
  end

  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]

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
    for _, l in ipairs(lines) do
      if l > cursor_line then
        target_line = l
        break
      end
    end
    if not target_line then
      target_line = lines[1]
    end
  else
    for i = #lines, 1, -1 do
      if lines[i] < cursor_line then
        target_line = lines[i]
        break
      end
    end
    if not target_line then
      target_line = lines[#lines]
    end
  end

  if target_line then
    vim.api.nvim_win_set_cursor(0, { target_line, 0 })
    -- Show quick reference
    local at_line = {}
    for _, ind in ipairs(indicators) do
      if ind.line == target_line or (ind.line_end and target_line >= ind.line and target_line <= ind.line_end) then
        table.insert(at_line, ind)
      end
    end
    if #at_line > 0 then
      local first = at_line[1]
      local kind_label = first.kind == "remote" and "Comment" or "Draft"
      local preview = first.preview and first.preview:sub(1, 60) or ""
      log.info("[%s] Line %d: %s", kind_label, target_line, preview)
    end
  end
end

return M
