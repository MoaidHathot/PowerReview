--- PowerReview.nvim version check utility
--- Provides a testable version comparison function used by the plugin entry point.
local M = {}

--- Minimum required Neovim version.
---@type { major: number, minor: number, patch: number }
M.MIN_VERSION = { major = 0, minor = 10, patch = 0 }

--- Check whether the given version meets the minimum requirement.
--- Compares major.minor.patch numerically.
---@param version { major: number, minor: number, patch: number }
---@param minimum? { major: number, minor: number, patch: number } Defaults to M.MIN_VERSION
---@return boolean meets True if version >= minimum
function M.meets_minimum(version, minimum)
  minimum = minimum or M.MIN_VERSION
  if version.major ~= minimum.major then
    return version.major > minimum.major
  end
  if version.minor ~= minimum.minor then
    return version.minor > minimum.minor
  end
  return version.patch >= minimum.patch
end

--- Format a version table as a string (e.g. "0.10.0").
---@param version { major: number, minor: number, patch: number }
---@return string
function M.format(version)
  return string.format("%d.%d.%d", version.major, version.minor, version.patch)
end

--- Check the running Neovim version and return an error message if too old.
--- Returns nil when the version is sufficient.
---@return string|nil error_message
function M.check()
  local v = vim.version()
  if not M.meets_minimum(v) then
    return string.format("[PowerReview] Requires Neovim >= %s, but found %s", M.format(M.MIN_VERSION), M.format(v))
  end
  return nil
end

return M
