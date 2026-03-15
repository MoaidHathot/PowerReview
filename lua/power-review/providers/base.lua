--- PowerReview.nvim provider base interface documentation
--- This file documents the provider interface contract.
--- Each provider (azdo, github, etc.) must implement these methods.
---
--- This is NOT a base class to inherit from. Lua providers are plain tables
--- that implement the documented methods. This file serves as:
--- 1. Type annotation reference for lua-language-server
--- 2. Documentation of the contract
---
--- See types.lua for the full @class PowerReview.Provider definition.

local M = {}

--- Validate that a provider table implements all required methods.
---@param provider table
---@return boolean valid, string|nil error
function M.validate(provider)
  local required_methods = {
    "get_pull_request",
    "get_changed_files",
    "get_threads",
    "create_thread",
    "reply_to_thread",
    "update_comment",
    "delete_comment",
    "set_vote",
    "get_file_content",
  }

  for _, method in ipairs(required_methods) do
    if type(provider[method]) ~= "function" then
      return false, "Provider missing required method: " .. method
    end
  end

  if not provider.type then
    return false, "Provider missing 'type' field"
  end

  return true, nil
end

return M
