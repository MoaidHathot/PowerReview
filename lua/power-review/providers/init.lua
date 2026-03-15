--- PowerReview.nvim provider registry and factory
local M = {}

local log = require("power-review.utils.log")
local base = require("power-review.providers.base")

---@type table<string, PowerReview.Provider>
local _providers = {}

--- Create and return a provider instance for the given type.
---@param provider_type PowerReview.ProviderType
---@param opts table Provider-specific options (org, project, repo, auth_header, etc.)
---@return PowerReview.Provider|nil provider, string|nil error
function M.create(provider_type, opts)
  if provider_type == "azdo" then
    local azdo = require("power-review.providers.azdo")
    local provider = azdo.new(opts)
    local valid, err = base.validate(provider)
    if not valid then
      return nil, "AzDO provider validation failed: " .. (err or "unknown")
    end
    return provider, nil
  elseif provider_type == "github" then
    local github = require("power-review.providers.github")
    local provider = github.new(opts)
    local valid, err = base.validate(provider)
    if not valid then
      return nil, "GitHub provider validation failed: " .. (err or "unknown")
    end
    log.warn("GitHub provider is a stub. All API calls will return 'not yet implemented'.")
    return provider, nil
  else
    return nil, "Unknown provider type: " .. tostring(provider_type)
  end
end

--- Detect provider type from a URL
---@param url string
---@return PowerReview.ProviderType|nil
function M.detect_from_url(url)
  local url_util = require("power-review.utils.url")
  return url_util.detect_provider(url)
end

return M
