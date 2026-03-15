--- PowerReview.nvim authentication dispatcher
--- Resolves authentication based on configured method and provider type.
local M = {}

local log = require("power-review.utils.log")

--- Get authorization header for a given provider type.
--- Uses the configured auth method (auto, az_cli, pat).
---
--- For "auto" (default): tries az_cli first, falls back to PAT.
--- For "az_cli": only tries Azure CLI.
--- For "pat": only tries Personal Access Token.
---
---@param provider_type PowerReview.ProviderType
---@param callback fun(err?: string, auth_header?: string)
function M.get_token(provider_type, callback)
  local config = require("power-review.config")
  local auth_config = config.get_auth_config(provider_type)
  local method = auth_config.method or "auto"

  if provider_type == "azdo" then
    if method == "az_cli" then
      M._try_az_cli(callback)
    elseif method == "pat" then
      M._try_pat(provider_type, callback)
    else
      -- "auto": try az_cli first, fall back to PAT
      M._try_az_cli(function(err, header)
        if err then
          log.debug("az_cli auth failed (%s), falling back to PAT", err)
          M._try_pat(provider_type, function(pat_err, pat_header)
            if pat_err then
              callback("All auth methods failed. az_cli: " .. err .. " | PAT: " .. pat_err)
            else
              callback(nil, pat_header)
            end
          end)
        else
          callback(nil, header)
        end
      end)
    end
  elseif provider_type == "github" then
    -- GitHub only supports PAT for now
    M._try_pat(provider_type, callback)
  else
    callback("Unknown provider type: " .. tostring(provider_type))
  end
end

--- Try Azure CLI authentication
---@param callback fun(err?: string, auth_header?: string)
function M._try_az_cli(callback)
  local az_cli = require("power-review.auth.az_cli")
  az_cli.get_token(callback)
end

--- Try PAT authentication
---@param provider_type PowerReview.ProviderType
---@param callback fun(err?: string, auth_header?: string)
function M._try_pat(provider_type, callback)
  local pat = require("power-review.auth.pat")
  pat.get_token(provider_type, callback)
end

return M
