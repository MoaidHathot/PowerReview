--- PowerReview.nvim PAT (Personal Access Token) authentication
local M = {}

local log = require("power-review.utils.log")

--- Get authorization header using a Personal Access Token.
--- Tries config value first, then environment variables.
---@param provider_type PowerReview.ProviderType
---@param callback fun(err?: string, auth_header?: string)
function M.get_token(provider_type, callback)
  local config = require("power-review.config")
  local auth_config = config.get_auth_config(provider_type)

  local pat = nil

  -- Try config first
  if auth_config.pat and auth_config.pat ~= "" then
    pat = auth_config.pat
  end

  -- Try environment variables
  if not pat then
    if provider_type == "azdo" then
      pat = vim.env.POWER_REVIEW_AZDO_PAT or vim.env.AZDO_PAT
    elseif provider_type == "github" then
      pat = vim.env.POWER_REVIEW_GITHUB_PAT or vim.env.GITHUB_TOKEN
    end
  end

  if not pat or pat == "" then
    callback("No PAT found. Set it in config or via environment variable.")
    return
  end

  if provider_type == "azdo" then
    -- AzDO uses Basic auth with base64-encoded ":PAT"
    local encoded = vim.base64.encode(":" .. pat)
    local header = "Basic " .. encoded
    log.debug("PAT auth: using Basic auth for AzDO")
    callback(nil, header)
  elseif provider_type == "github" then
    -- GitHub uses Bearer token
    local header = "Bearer " .. pat
    log.debug("PAT auth: using Bearer auth for GitHub")
    callback(nil, header)
  else
    callback("Unknown provider type for PAT auth: " .. tostring(provider_type))
  end
end

return M
