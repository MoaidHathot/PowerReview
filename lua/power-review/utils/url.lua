--- PowerReview.nvim URL parsing utilities
--- Parses PR URLs from Azure DevOps and GitHub to extract structured data.
local M = {}

---@class PowerReview.ParsedUrl
---@field provider_type PowerReview.ProviderType
---@field organization string Org (AzDO) or owner (GitHub)
---@field project string Project (AzDO) or repo name (GitHub)
---@field repository string Repository name
---@field pr_id number Pull request ID

--- Parse an Azure DevOps PR URL.
--- Supports both formats:
---   https://dev.azure.com/{org}/{project}/_git/{repo}/pullrequest/{id}
---   https://{org}.visualstudio.com/{project}/_git/{repo}/pullrequest/{id}
---   https://dev.azure.com/{org}/{project}/_git/{repo}/pullrequest/{id}?_a=overview (with query params)
---@param url string
---@return PowerReview.ParsedUrl|nil parsed, string|nil error
function M.parse_azdo_url(url)
  -- Remove query string and fragment
  local clean_url = url:match("^([^?#]+)") or url

  -- Format: https://dev.azure.com/{org}/{project}/_git/{repo}/pullrequest/{id}
  local org, project, repo, pr_id = clean_url:match(
    "https?://dev%.azure%.com/([^/]+)/([^/]+)/_git/([^/]+)/pullrequest/(%d+)"
  )

  if not org then
    -- Format: https://{org}.visualstudio.com/{project}/_git/{repo}/pullrequest/{id}
    org, project, repo, pr_id = clean_url:match(
      "https?://([^%.]+)%.visualstudio%.com/([^/]+)/_git/([^/]+)/pullrequest/(%d+)"
    )
  end

  if not org then
    -- Format: https://dev.azure.com/{org}/{project}/_git/{repo}/pullrequest/{id}
    -- Sometimes the project is URL-encoded or has special characters
    -- Try a more lenient match
    org, project, repo, pr_id = clean_url:match(
      "dev%.azure%.com/([^/]+)/([^/]+)/_git/([^/]+)/pullrequest/(%d+)"
    )
  end

  if org and project and repo and pr_id then
    return {
      provider_type = "azdo",
      organization = M._url_decode(org),
      project = M._url_decode(project),
      repository = M._url_decode(repo),
      pr_id = tonumber(pr_id),
    }, nil
  end

  return nil, "Could not parse Azure DevOps PR URL: " .. url
end

--- Parse a GitHub PR URL.
--- Format: https://github.com/{owner}/{repo}/pull/{id}
---@param url string
---@return PowerReview.ParsedUrl|nil parsed, string|nil error
function M.parse_github_url(url)
  local clean_url = url:match("^([^?#]+)") or url

  local owner, repo, pr_id = clean_url:match(
    "https?://github%.com/([^/]+)/([^/]+)/pull/(%d+)"
  )

  if owner and repo and pr_id then
    return {
      provider_type = "github",
      organization = owner,
      project = repo,
      repository = repo,
      pr_id = tonumber(pr_id),
    }, nil
  end

  return nil, "Could not parse GitHub PR URL: " .. url
end

--- Auto-detect provider type from URL and parse it
---@param url string
---@return PowerReview.ParsedUrl|nil parsed, string|nil error
function M.parse(url)
  if url:find("dev%.azure%.com") or url:find("%.visualstudio%.com") then
    return M.parse_azdo_url(url)
  elseif url:find("github%.com") then
    return M.parse_github_url(url)
  else
    return nil, "Unrecognized PR URL format. Expected Azure DevOps or GitHub URL: " .. url
  end
end

--- Detect provider type from a URL without full parsing
---@param url string
---@return PowerReview.ProviderType|nil
function M.detect_provider(url)
  if url:find("dev%.azure%.com") or url:find("%.visualstudio%.com") then
    return "azdo"
  elseif url:find("github%.com") then
    return "github"
  end
  return nil
end

--- URL-decode a percent-encoded string
---@param str string
---@return string
function M._url_decode(str)
  return (str:gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end))
end

--- URL-encode a string for use in API paths
---@param str string
---@return string
function M.url_encode(str)
  return (str:gsub("([^%w%-%.%_%~])", function(c)
    return string.format("%%%02X", string.byte(c))
  end))
end

return M
