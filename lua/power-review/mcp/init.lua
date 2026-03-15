--- PowerReview.nvim MCP integration (Neovim side)
--- Writes server info for the external MCP server to connect back to this Neovim instance.
local M = {}

local log = require("power-review.utils.log")

--- Get the path to the server info file
---@return string
function M.get_info_path()
  return vim.fn.stdpath("data") .. "/power-review/server_info.json"
end

--- Write server info so the MCP server can find this Neovim instance.
--- Called when a review session starts.
---@param session_active boolean
---@param pr_id? number
function M.write_server_info(session_active, pr_id)
  local info = {
    socket = vim.v.servername or "",
    pid = vim.fn.getpid(),
    session_active = session_active,
    pr_id = pr_id,
    updated_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
  }

  local dir = vim.fn.fnamemodify(M.get_info_path(), ":h")
  if vim.fn.isdirectory(dir) ~= 1 then
    vim.fn.mkdir(dir, "p")
  end

  local ok, json_str = pcall(vim.json.encode, info)
  if not ok then
    log.warn("Failed to encode MCP server info: %s", tostring(json_str))
    return
  end

  local file, err = io.open(M.get_info_path(), "w")
  if not file then
    log.warn("Failed to write MCP server info: %s", err or "")
    return
  end

  file:write(json_str)
  file:close()

  log.debug("MCP server info written: socket=%s, session_active=%s", info.socket, tostring(session_active))
end

--- Clear server info (called when review session ends)
function M.clear_server_info()
  M.write_server_info(false, nil)
end

--- Ensure the public API functions are accessible via Neovim RPC.
--- External MCP servers call these via nvim_exec_lua / nvim_call_function.
--- The API is already exposed via require("power-review").api, which is
--- directly callable from RPC with:
---   nvim.exec_lua("return require('power-review').api.get_changed_files()")
---
--- This function is a no-op but documents the integration pattern.
function M.setup()
  -- Nothing to do - the Lua API in init.lua is already RPC-accessible.
  -- The MCP TypeScript server will use the neovim npm package to connect
  -- to this Neovim instance and call:
  --   await nvim.lua("return vim.json.encode(require('power-review').api.get_changed_files())")
  --
  -- We just need to ensure server info is written when sessions start/stop.
  log.debug("MCP integration ready. API accessible via Neovim RPC.")
end

return M
