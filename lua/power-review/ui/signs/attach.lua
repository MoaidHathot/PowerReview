--- PowerReview.nvim signs — buffer attachment & lifecycle
local M = {}

local log = require("power-review.utils.log")

--- Track which buffers we've attached to.
--- Maps bufnr -> { file_path: string, session_id: string }
---@type table<number, table>
M.attached_bufs = {}

--- Track autocommand group ID
---@type number|nil
M.augroup = nil

--- Attach to a buffer to display comment signs.
---@param bufnr number
---@param file_path string Relative file path
---@param session PowerReview.ReviewSession
---@param build_indicators fun(session: table, file_path: string): table[]
---@param set_indicators fun(bufnr: number, indicators: table[])
function M.attach(bufnr, file_path, session, build_indicators, set_indicators)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  M.attached_bufs[bufnr] = {
    file_path = file_path,
    session_id = session.id,
  }

  local indicators = build_indicators(session, file_path)
  set_indicators(bufnr, indicators)

  local ui = require("power-review.ui")
  ui.setup_buffer_keymaps(bufnr)

  log.debug("Attached signs to buffer %d for %s (%d indicators)", bufnr, file_path, #indicators)
end

--- Detach from a buffer.
---@param bufnr number
---@param ns number Namespace
function M.detach(bufnr, ns)
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  end
  M.attached_bufs[bufnr] = nil
  local ui_ok, ui = pcall(require, "power-review.ui")
  if ui_ok then
    ui.cleanup_buffer_keymaps(bufnr)
  end
end

--- Detach from all tracked buffers.
---@param ns number Namespace
function M.detach_all(ns)
  for bufnr, _ in pairs(M.attached_bufs) do
    M.detach(bufnr, ns)
  end
  M.attached_bufs = {}
end

--- Refresh signs on all attached buffers.
---@param build_indicators fun(session: table, file_path: string): table[]
---@param set_indicators fun(bufnr: number, indicators: table[])
function M.refresh(build_indicators, set_indicators)
  local pr = require("power-review")
  local session = pr.get_current_session()
  if not session then
    return
  end

  local to_remove = {}
  for bufnr, _ in pairs(M.attached_bufs) do
    if not vim.api.nvim_buf_is_valid(bufnr) then
      table.insert(to_remove, bufnr)
    end
  end
  for _, bufnr in ipairs(to_remove) do
    M.attached_bufs[bufnr] = nil
  end

  for bufnr, info in pairs(M.attached_bufs) do
    if info.session_id == session.id then
      local indicators = build_indicators(session, info.file_path)
      set_indicators(bufnr, indicators)
    end
  end
end

--- Refresh signs for a specific file path.
---@param file_path string
---@param build_indicators fun(session: table, file_path: string): table[]
---@param set_indicators fun(bufnr: number, indicators: table[])
function M.refresh_file(file_path, build_indicators, set_indicators)
  local pr = require("power-review")
  local session = pr.get_current_session()
  if not session then
    return
  end

  local indicators = build_indicators(session, file_path)

  for bufnr, info in pairs(M.attached_bufs) do
    if info.file_path == file_path and info.session_id == session.id then
      if vim.api.nvim_buf_is_valid(bufnr) then
        set_indicators(bufnr, indicators)
      end
    end
  end
end

--- Resolve a buffer's file path relative to the review session.
---@param bufnr number
---@param session PowerReview.ReviewSession
---@return string|nil
function M.resolve_review_file_path(bufnr, session)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end

  local buf_name = vim.api.nvim_buf_get_name(bufnr)
  if buf_name == "" then
    return nil
  end

  buf_name = buf_name:gsub("\\", "/")

  local bases = {}
  if session.worktree_path then
    table.insert(bases, (session.worktree_path:gsub("\\", "/")))
  end
  local cwd = (vim.fn.getcwd():gsub("\\", "/"))
  table.insert(bases, cwd)

  for _, base in ipairs(bases) do
    base = base:gsub("/$", "")
    if buf_name:find(base, 1, true) == 1 then
      local rel = buf_name:sub(#base + 2)
      if M._is_review_file(session, rel) then
        return rel
      end
    end
  end

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
  rel_path = rel_path:gsub("\\", "/")
  for _, file in ipairs(session.files) do
    local fp = file.path:gsub("\\", "/")
    if fp == rel_path then
      return true
    end
  end
  return false
end

--- Setup autocommands to auto-attach signs when diff buffers are opened.
---@param try_auto_attach fun(bufnr: number)
---@param attach_visible fun()
---@param refresh_fn fun()
function M.setup_autocommands(try_auto_attach, attach_visible, refresh_fn)
  if M.augroup then
    vim.api.nvim_del_augroup_by_id(M.augroup)
  end

  M.augroup = vim.api.nvim_create_augroup("PowerReviewSigns", { clear = true })

  vim.api.nvim_create_autocmd("BufEnter", {
    group = M.augroup,
    callback = function(args)
      local ok, err = pcall(try_auto_attach, args.buf)
      if not ok then
        log.debug("Signs auto-attach error (non-fatal): %s", tostring(err))
      end
    end,
  })

  vim.api.nvim_create_autocmd("User", {
    group = M.augroup,
    pattern = "CodeDiffOpen",
    callback = function()
      vim.schedule(attach_visible)
    end,
  })

  vim.api.nvim_create_autocmd("BufDelete", {
    group = M.augroup,
    callback = function(args)
      if M.attached_bufs[args.buf] then
        M.attached_bufs[args.buf] = nil
        local ui_ok, ui = pcall(require, "power-review.ui")
        if ui_ok then
          ui.cleanup_buffer_keymaps(args.buf)
        end
      end
    end,
  })

  vim.api.nvim_create_autocmd("TabEnter", {
    group = M.augroup,
    callback = function()
      local tab_wins = vim.api.nvim_tabpage_list_wins(0)
      local has_attached = false
      for _, winid in ipairs(tab_wins) do
        if vim.api.nvim_win_is_valid(winid) then
          local bufnr = vim.api.nvim_win_get_buf(winid)
          if M.attached_bufs[bufnr] then
            has_attached = true
            break
          end
        end
      end
      if has_attached then
        vim.schedule(refresh_fn)
      end
    end,
  })
end

return M
