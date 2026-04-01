--- Tests for power-review.notifications
--- Requires a vim mock shim since notifications uses vim.notify and config.
local vim_mock = require("helpers.vim_mock")

-- Install vim mock BEFORE requiring modules that use vim.*
local mock = vim_mock.install()

local config = require("power-review.config")
local notifications = require("power-review.notifications")

-- ============================================================================
-- Helpers
-- ============================================================================

--- Reset all state between tests.
local function reset()
  vim_mock.clear_notifications()
  notifications.reset()
  notifications._runtime_enabled = nil
  -- Reset config to defaults
  config._config = nil
end

-- ============================================================================
-- is_enabled
-- ============================================================================

describe("is_enabled", function()
  before_each(reset)

  it("returns true by default (config defaults)", function()
    assert.is_true(notifications.is_enabled())
  end)

  it("returns false when config disables notifications", function()
    config.setup({ notifications = { enabled = false } })
    assert.is_false(notifications.is_enabled())
  end)

  it("returns true when runtime override is true", function()
    config.setup({ notifications = { enabled = false } })
    notifications.enable()
    assert.is_true(notifications.is_enabled())
  end)

  it("returns false when runtime override is false", function()
    config.setup({ notifications = { enabled = true } })
    notifications.disable()
    assert.is_false(notifications.is_enabled())
  end)

  it("reverts to config after reset()", function()
    notifications.disable()
    assert.is_false(notifications.is_enabled())
    notifications.reset()
    assert.is_true(notifications.is_enabled())
  end)
end)

-- ============================================================================
-- enable / disable / toggle
-- ============================================================================

describe("enable", function()
  before_each(reset)

  it("sets runtime override to true", function()
    notifications.enable()
    assert.is_true(notifications._runtime_enabled)
  end)
end)

describe("disable", function()
  before_each(reset)

  it("sets runtime override to false", function()
    notifications.disable()
    assert.is_false(notifications._runtime_enabled)
  end)
end)

describe("toggle", function()
  before_each(reset)

  it("first toggle: flips config value (true -> false)", function()
    config.setup({ notifications = { enabled = true } })
    local result = notifications.toggle()
    assert.is_false(result)
    assert.is_false(notifications.is_enabled())
  end)

  it("first toggle: flips config value (false -> true)", function()
    config.setup({ notifications = { enabled = false } })
    local result = notifications.toggle()
    assert.is_true(result)
    assert.is_true(notifications.is_enabled())
  end)

  it("second toggle: flips runtime value", function()
    notifications.toggle() -- true -> false
    local result = notifications.toggle() -- false -> true
    assert.is_true(result)
  end)

  it("returns the new state", function()
    local r1 = notifications.toggle()
    local r2 = notifications.toggle()
    assert.not_equal(r1, r2)
  end)
end)

-- ============================================================================
-- reset
-- ============================================================================

describe("reset", function()
  before_each(reset)

  it("clears runtime override", function()
    notifications.enable()
    assert.not_nil(notifications._runtime_enabled)
    notifications.reset()
    assert.is_nil(notifications._runtime_enabled)
  end)
end)

-- ============================================================================
-- notify
-- ============================================================================

describe("notify", function()
  before_each(reset)

  it("sends a notification when enabled", function()
    notifications.notify("test message")
    assert.equal(1, #mock._notifications)
    assert.truthy(mock._notifications[1].msg:find("test message"))
  end)

  it("prefixes message with [PowerReview]", function()
    notifications.notify("hello")
    assert.truthy(mock._notifications[1].msg:find("^%[PowerReview%]"))
  end)

  it("uses INFO level by default", function()
    notifications.notify("test")
    assert.equal(vim.log.levels.INFO, mock._notifications[1].level)
  end)

  it("supports custom log level", function()
    notifications.notify("warning", vim.log.levels.WARN)
    assert.equal(vim.log.levels.WARN, mock._notifications[1].level)
  end)

  it("does not send when disabled", function()
    notifications.disable()
    notifications.notify("hidden")
    assert.equal(0, #mock._notifications)
  end)
end)

-- ============================================================================
-- ai_activity
-- ============================================================================

describe("ai_activity", function()
  before_each(reset)

  it("sends notification when ai_activity is enabled", function()
    config.setup({ notifications = { enabled = true, ai_activity = true } })
    notifications.ai_activity("AI created a draft")
    assert.equal(1, #mock._notifications)
    assert.truthy(mock._notifications[1].msg:find("AI created a draft"))
  end)

  it("does not send when ai_activity is disabled", function()
    config.setup({ notifications = { enabled = true, ai_activity = false } })
    notifications.ai_activity("AI created a draft")
    assert.equal(0, #mock._notifications)
  end)

  it("does not send when globally disabled", function()
    notifications.disable()
    notifications.ai_activity("AI created a draft")
    assert.equal(0, #mock._notifications)
  end)
end)

-- ============================================================================
-- sync_complete
-- ============================================================================

describe("sync_complete", function()
  before_each(reset)

  it("sends notification with thread count", function()
    notifications.sync_complete(5)
    assert.equal(1, #mock._notifications)
    assert.truthy(mock._notifications[1].msg:find("5 thread"))
  end)

  it("does not send when sync_complete is disabled", function()
    config.setup({ notifications = { enabled = true, sync_complete = false } })
    notifications.sync_complete(3)
    assert.equal(0, #mock._notifications)
  end)
end)

-- ============================================================================
-- watcher_update
-- ============================================================================

describe("watcher_update", function()
  before_each(reset)

  it("sends notification when enabled", function()
    notifications.watcher_update({})
    assert.equal(1, #mock._notifications)
    assert.truthy(mock._notifications[1].msg:find("external change"))
  end)

  it("does not send when sync_complete category is disabled", function()
    config.setup({ notifications = { enabled = true, sync_complete = false } })
    notifications.watcher_update({})
    assert.equal(0, #mock._notifications)
  end)
end)

-- ============================================================================
-- ai_drafts_changed
-- ============================================================================

describe("ai_drafts_changed", function()
  before_each(reset)

  it("notifies when new AI drafts are added", function()
    notifications.ai_drafts_changed(2, 5)
    assert.equal(1, #mock._notifications)
    assert.truthy(mock._notifications[1].msg:find("3 new AI draft"))
    assert.truthy(mock._notifications[1].msg:find("5 total"))
  end)

  it("notifies when AI drafts are removed", function()
    notifications.ai_drafts_changed(5, 2)
    assert.equal(1, #mock._notifications)
    assert.truthy(mock._notifications[1].msg:find("3 AI draft%(s%) removed"))
    assert.truthy(mock._notifications[1].msg:find("2 remaining"))
  end)

  it("does not notify when count is unchanged", function()
    notifications.ai_drafts_changed(3, 3)
    assert.equal(0, #mock._notifications)
  end)

  it("does not notify when ai_activity is disabled", function()
    config.setup({ notifications = { enabled = true, ai_activity = false } })
    notifications.ai_drafts_changed(0, 5)
    assert.equal(0, #mock._notifications)
  end)
end)
