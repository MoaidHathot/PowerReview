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

    --- Mock vim.notify: records calls for assertion.
    notify = function(msg, level)
      table.insert(mock._notifications, { msg = msg, level = level })
    end,

    --- Mock vim.deepcopy: simple deep copy (tables only, no metatables).
    deepcopy = function(tbl)
      if type(tbl) ~= "table" then
        return tbl
      end
      local copy = {}
      for k, v in pairs(tbl) do
        copy[k] = mock.deepcopy(v)
      end
      return copy
    end,

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
