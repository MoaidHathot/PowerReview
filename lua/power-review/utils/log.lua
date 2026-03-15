--- PowerReview.nvim logging utility
local M = {}

local LEVELS = {
  debug = 1,
  info = 2,
  warn = 3,
  error = 4,
}

local VIM_LEVELS = {
  debug = vim.log.levels.DEBUG,
  info = vim.log.levels.INFO,
  warn = vim.log.levels.WARN,
  error = vim.log.levels.ERROR,
}

local PREFIX = "[PowerReview]"

--- Get the configured log level threshold
---@return number
local function get_level_threshold()
  local ok, config = pcall(require, "power-review.config")
  if ok then
    local level_name = config.get_log_level()
    return LEVELS[level_name] or LEVELS.info
  end
  return LEVELS.info
end

--- Log a message at a given level
---@param level string "debug" | "info" | "warn" | "error"
---@param msg string
---@param ... any Additional format arguments
local function log(level, msg, ...)
  local threshold = get_level_threshold()
  local level_num = LEVELS[level] or LEVELS.info

  if level_num < threshold then
    return
  end

  local formatted
  if select("#", ...) > 0 then
    formatted = string.format(msg, ...)
  else
    formatted = msg
  end

  vim.schedule(function()
    vim.notify(PREFIX .. " " .. formatted, VIM_LEVELS[level] or vim.log.levels.INFO)
  end)
end

---@param msg string
---@param ... any
function M.debug(msg, ...)
  log("debug", msg, ...)
end

---@param msg string
---@param ... any
function M.info(msg, ...)
  log("info", msg, ...)
end

---@param msg string
---@param ... any
function M.warn(msg, ...)
  log("warn", msg, ...)
end

---@param msg string
---@param ... any
function M.error(msg, ...)
  log("error", msg, ...)
end

return M
