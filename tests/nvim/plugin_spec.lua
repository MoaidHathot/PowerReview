--- Headless integration tests: version check and plugin loading.
--- Verifies the plugin loads correctly in a real Neovim runtime.

local function assert_eq(actual, expected, msg)
  if actual ~= expected then
    error(string.format("%s: expected %s, got %s", msg or "assert_eq", tostring(expected), tostring(actual)), 2)
  end
end

local function assert_true(val, msg)
  if not val then
    error(string.format("%s: expected truthy, got %s", msg or "assert_true", tostring(val)), 2)
  end
end

local function assert_match(str, pattern, msg)
  if not str:find(pattern) then
    error(string.format("%s: expected '%s' to match pattern '%s'", msg or "assert_match", str, pattern), 2)
  end
end

return {
  -- 1. vim.version() returns a valid table
  {
    name = "vim.version() is available and returns a table",
    fn = function()
      local v = vim.version()
      assert_true(type(v) == "table", "vim.version() should return a table")
      assert_true(type(v.major) == "number", "version.major should be a number")
      assert_true(type(v.minor) == "number", "version.minor should be a number")
      assert_true(type(v.patch) == "number", "version.patch should be a number")
    end,
  },

  -- 2. The version utility module loads and reports correct minimum
  {
    name = "version utility loads and MIN_VERSION is 0.10.0",
    fn = function()
      local ver = require("power-review.utils.version")
      assert_eq(ver.MIN_VERSION.major, 0, "MIN_VERSION.major")
      assert_eq(ver.MIN_VERSION.minor, 10, "MIN_VERSION.minor")
      assert_eq(ver.MIN_VERSION.patch, 0, "MIN_VERSION.patch")
    end,
  },

  -- 3. The running Neovim meets the minimum version
  {
    name = "running Neovim meets minimum version",
    fn = function()
      local ver = require("power-review.utils.version")
      local err = ver.check()
      assert_eq(err, nil, "version.check() should return nil on >= 0.10")
    end,
  },

  -- 4. meets_minimum works correctly with real vim.version()
  {
    name = "meets_minimum returns true for current Neovim",
    fn = function()
      local ver = require("power-review.utils.version")
      local v = vim.version()
      assert_true(ver.meets_minimum(v), "current Neovim should meet minimum")
    end,
  },

  -- 5. The plugin loaded (vim.g.loaded_power_review is set)
  {
    name = "plugin/power-review.lua loaded successfully",
    fn = function()
      assert_true(vim.g.loaded_power_review, "vim.g.loaded_power_review should be truthy")
    end,
  },

  -- 6. The :PowerReview command is registered
  {
    name = ":PowerReview command exists",
    fn = function()
      local cmds = vim.api.nvim_get_commands({})
      assert_true(cmds["PowerReview"] ~= nil, ":PowerReview command should be registered")
    end,
  },

  -- 7. Core modules can be required without error
  {
    name = "core modules load without error",
    fn = function()
      local modules = {
        "power-review",
        "power-review.config",
        "power-review.cli",
        "power-review.session_helpers",
        "power-review.watcher",
        "power-review.utils.log",
        "power-review.utils.version",
      }
      for _, mod in ipairs(modules) do
        local ok, err = pcall(require, mod)
        if not ok then
          error(string.format("Failed to require '%s': %s", mod, err), 2)
        end
      end
    end,
  },

  -- 8. vim.system is available (the primary 0.10+ dependency)
  {
    name = "vim.system is available",
    fn = function()
      assert_true(type(vim.system) == "function", "vim.system should be a function")
    end,
  },

  -- 9. vim.islist is available
  {
    name = "vim.islist is available",
    fn = function()
      assert_true(type(vim.islist) == "function", "vim.islist should be a function")
    end,
  },

  -- 10. Extmark sign API works (sign_text field)
  {
    name = "nvim_buf_set_extmark supports sign_text",
    fn = function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "test line" })
      local ns = vim.api.nvim_create_namespace("powerreview_test")
      -- This would error on Neovim < 0.10
      local ok, err = pcall(vim.api.nvim_buf_set_extmark, buf, ns, 0, 0, {
        sign_text = ">>",
        sign_hl_group = "Comment",
      })
      vim.api.nvim_buf_delete(buf, { force = true })
      if not ok then
        error("sign_text extmark not supported: " .. tostring(err), 2)
      end
    end,
  },

  -- 11. adapt_session works end-to-end in real Neovim
  {
    name = "cli.adapt_session works in real Neovim runtime",
    fn = function()
      local cli = require("power-review.cli")
      local session = cli.adapt_session({
        id = "integration-test",
        pull_request = { id = 99, title = "Test PR", author = { display_name = "Tester" } },
        provider = { type = "github", organization = "o", project = "p", repository = "r" },
        vote = "Approve",
        drafts = { ["x"] = { body = "hi", created_at = "2025-01-01" } },
        draft_actions = { ["a"] = { action_type = "thread_status_change", thread_id = 99, created_at = "2025-01-02" } },
      })
      assert_eq(session.pr_id, 99, "pr_id")
      assert_eq(session.pr_title, "Test PR", "pr_title")
      assert_eq(session.pr_author, "Tester", "pr_author")
      assert_eq(session.vote, 10, "vote should be 10 for Approve")
      assert_eq(#session.drafts, 1, "draft count")
      assert_eq(session.drafts[1].id, "x", "draft id")
      assert_eq(#session.draft_actions, 1, "draft action count")
      assert_eq(session.draft_actions[1].id, "a", "draft action id")
    end,
  },

  -- 12. open/refresh result adapter preserves session metadata
  {
    name = "cli._adapt_session_result preserves open action and session path",
    fn = function()
      local cli = require("power-review.cli")
      local session = cli._adapt_session_result({
        action = "refreshed",
        session_file_path = "/tmp/powerreview/session.json",
        session = {
          id = "integration-test",
          pull_request = { id = 99, title = "Test PR", author = { display_name = "Tester" } },
          provider = { type = "github", organization = "o", project = "p", repository = "r" },
        },
      })
      assert_eq(session._open_action, "refreshed", "open action")
      assert_eq(session._session_file_path, "/tmp/powerreview/session.json", "session path")
      assert_eq(session.pr_id, 99, "pr_id")
    end,
  },
}
