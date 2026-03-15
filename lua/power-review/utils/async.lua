--- PowerReview.nvim async utilities
--- Provides coroutine-based async/await pattern for writing sequential-looking async code.
local M = {}

--- Wrap an async callback-style function to work with coroutines.
--- The wrapped function can be called inside M.run() and will yield until the callback fires.
---
--- Usage:
---   local get_token = async.wrap(auth.get_token)  -- auth.get_token(callback) signature
---   async.run(function()
---     local err, token = get_token()
---     if err then return end
---     -- use token
---   end)
---
---@param fn function The async function that takes a callback as its last argument
---@param argc? number Number of arguments before the callback (auto-detected if nil)
---@return function wrapped Function that yields in a coroutine context
function M.wrap(fn, argc)
  return function(...)
    local args = { ... }
    local co = coroutine.running()
    assert(co, "async.wrap: must be called inside async.run()")

    -- Add callback as last argument
    table.insert(args, function(...)
      -- Resume the coroutine with the callback results
      local ok, err = coroutine.resume(co, ...)
      if not ok then
        vim.schedule(function()
          error("async.wrap callback resume failed: " .. tostring(err))
        end)
      end
    end)

    fn(unpack(args))
    return coroutine.yield()
  end
end

--- Run an async function. The function can use wrapped async calls that yield.
---@param fn function The async function to run
---@param on_error? fun(err: string) Error handler (defaults to vim.notify)
function M.run(fn, on_error)
  local co = coroutine.create(fn)
  local ok, err = coroutine.resume(co)
  if not ok then
    local handler = on_error or function(e)
      vim.schedule(function()
        vim.notify("[PowerReview] Async error: " .. tostring(e), vim.log.levels.ERROR)
      end)
    end
    handler(tostring(err))
  end
end

--- Generate a UUID v4 string (for draft comment IDs)
---@return string
function M.uuid()
  -- Use math.random seeded by os.time + os.clock for uniqueness
  local template = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
  return (template:gsub("[xy]", function(c)
    local v = (c == "x") and math.random(0, 0xf) or math.random(8, 0xb)
    return string.format("%x", v)
  end))
end

--- Get current ISO 8601 timestamp
---@return string
function M.timestamp()
  return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

return M
