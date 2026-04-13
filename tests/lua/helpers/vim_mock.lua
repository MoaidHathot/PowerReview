--- Minimal vim mock for busted tests.
--- Provides just enough of the vim.* API to test modules that depend on it
--- (config, notifications) without requiring a real Neovim runtime.
---
--- Usage: require("helpers.vim_mock").install()

local M = {}

--- Install the mock vim global.
--- Captures all vim.notify calls into a table for assertions.
---@return table vim_mock The mock vim object
function M.install()
  local mock = {
    log = {
      levels = {
        DEBUG = 0,
        INFO = 1,
        WARN = 2,
        ERROR = 3,
      },
    },

    --- Captured notifications: { { msg, level }, ... }
    _notifications = {},

    --- Mock vim.schedule: run fn immediately (tests are synchronous).
    schedule = function(fn)
      fn()
    end,

    --- Mock vim.tbl_isempty: check if a table has no entries.
    tbl_isempty = function(tbl)
      return next(tbl) == nil
    end,

    --- Mock vim.json.decode: thin wrapper around a JSON library.
    --- In busted we can use cjson or dkjson if available; otherwise stub.
    json = {
      decode = function(str)
        -- Try dkjson (pure Lua, commonly bundled with LuaRocks/busted)
        local ok, dkjson = pcall(require, "dkjson")
        if ok then
          return dkjson.decode(str)
        end
        -- Try cjson
        local ok2, cjson = pcall(require, "cjson")
        if ok2 then
          return cjson.decode(str)
        end
        error("No JSON decoder available in test environment")
      end,
      encode = function(val)
        local ok, dkjson = pcall(require, "dkjson")
        if ok then
          return dkjson.encode(val)
        end
        local ok2, cjson = pcall(require, "cjson")
        if ok2 then
          return cjson.encode(val)
        end
        error("No JSON encoder available in test environment")
      end,
    },

    --- Mock vim.islist: check if a table is a list (sequential integer keys).
    islist = function(tbl)
      if type(tbl) ~= "table" then
        return false
      end
      local count = 0
      for _ in pairs(tbl) do
        count = count + 1
      end
      for i = 1, count do
        if tbl[i] == nil then
          return false
        end
      end
      return count > 0
    end,
  }

  --- Mock vim.notify: records calls for assertion.
  --- Defined after the table so `mock` is a valid upvalue.
  mock.notify = function(msg, level)
    table.insert(mock._notifications, { msg = msg, level = level })
  end

  --- Mock vim.deepcopy: simple deep copy (tables only, no metatables).
  --- Defined after the table so `mock` is a valid upvalue for recursion.
  mock.deepcopy = function(tbl)
    if type(tbl) ~= "table" then
      return tbl
    end
    local copy = {}
    for k, v in pairs(tbl) do
      copy[k] = mock.deepcopy(v)
    end
    return copy
  end

  -- Install as global
  _G.vim = mock
  return mock
end

--- Clear captured notifications.
function M.clear_notifications()
  if _G.vim then
    _G.vim._notifications = {}
  end
end

--- Uninstall the mock (restore nil).
function M.uninstall()
  _G.vim = nil
end

return M
