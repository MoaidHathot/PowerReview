--- PowerReview.nvim Azure CLI authentication
--- Gets tokens via `az account get-access-token`
local M = {}

local log = require("power-review.utils.log")

-- Azure DevOps resource ID for token scoping
local AZDO_RESOURCE_ID = "499b84ac-1321-427f-aa17-267ca6975798"

--- Get authorization header using Azure CLI.
--- Runs `az account get-access-token` asynchronously.
---@param callback fun(err?: string, auth_header?: string)
function M.get_token(callback)
  local cmd = {
    "az", "account", "get-access-token",
    "--resource", AZDO_RESOURCE_ID,
    "--query", "accessToken",
    "-o", "tsv",
  }

  log.debug("az_cli: requesting token via az account get-access-token")

  vim.system(cmd, { text = true, timeout = 15000 }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        local stderr = result.stderr or ""
        -- Common errors: az not installed, not logged in, etc.
        if stderr:find("not recognized") or stderr:find("not found") or result.code == 127 then
          callback("Azure CLI (az) is not installed or not in PATH")
        elseif stderr:find("Please run 'az login'") or stderr:find("AADSTS") then
          callback("Azure CLI: not logged in. Run 'az login' first.")
        else
          callback("Azure CLI token request failed: " .. stderr:sub(1, 200))
        end
        return
      end

      local token = (result.stdout or ""):gsub("%s+", "")
      if token == "" then
        callback("Azure CLI returned empty token")
        return
      end

      local header = "Bearer " .. token
      log.debug("az_cli: token obtained successfully")
      callback(nil, header)
    end)
  end)
end

return M
