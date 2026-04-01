--- Tests for power-review.config
--- Requires a vim mock shim since config uses vim.deepcopy and vim.islist.
local vim_mock = require("helpers.vim_mock")

-- Install vim mock BEFORE requiring modules that use vim.*
vim_mock.install()

local config = require("power-review.config")

-- ============================================================================
-- Helpers
-- ============================================================================

local function reset()
  config._config = nil
end

-- ============================================================================
-- defaults / get
-- ============================================================================

describe("get", function()
  before_each(reset)

  it("returns default config when setup() not called", function()
    local cfg = config.get()
    assert.is_table(cfg)
    assert.is_table(cfg.cli)
    assert.is_table(cfg.ui)
    assert.is_table(cfg.keymaps)
  end)

  it("returns same config on subsequent calls", function()
    local cfg1 = config.get()
    local cfg2 = config.get()
    assert.equal(cfg1, cfg2)
  end)

  it("has default CLI executable", function()
    local cfg = config.get()
    assert.is_table(cfg.cli.executable)
    assert.truthy(#cfg.cli.executable > 0)
  end)

  it("has default timeouts", function()
    local cfg = config.get()
    assert.is_number(cfg.cli.timeouts.default)
    assert.is_number(cfg.cli.timeouts.open)
    assert.is_number(cfg.cli.timeouts.submit)
    assert.is_number(cfg.cli.timeouts.vote)
    assert.is_number(cfg.cli.timeouts.sync)
  end)

  it("has default keymaps", function()
    local cfg = config.get()
    assert.is_string(cfg.keymaps.open_review)
    assert.is_string(cfg.keymaps.toggle_files)
    assert.is_string(cfg.keymaps.add_comment)
    assert.is_string(cfg.keymaps.submit_all)
  end)

  it("has default notification settings", function()
    local cfg = config.get()
    assert.is_true(cfg.notifications.enabled)
    assert.is_true(cfg.notifications.ai_activity)
    assert.is_true(cfg.notifications.sync_complete)
  end)

  it("has default watcher settings", function()
    local cfg = config.get()
    assert.is_true(cfg.watcher.enabled)
    assert.is_number(cfg.watcher.debounce_ms)
  end)

  it("has default UI colors", function()
    local cfg = config.get()
    assert.is_string(cfg.ui.colors.comment_undercurl)
    assert.is_string(cfg.ui.colors.draft_undercurl)
    assert.is_string(cfg.ui.colors.flash_bg)
  end)
end)

-- ============================================================================
-- setup
-- ============================================================================

describe("setup", function()
  before_each(reset)

  it("merges user overrides into defaults", function()
    config.setup({ keymaps = { open_review = "<leader>or" } })
    local cfg = config.get()
    assert.equal("<leader>or", cfg.keymaps.open_review)
    -- Other keymaps should still be defaults
    assert.is_string(cfg.keymaps.toggle_files)
  end)

  it("deep merges nested tables", function()
    config.setup({ cli = { timeouts = { default = 99999 } } })
    local cfg = config.get()
    assert.equal(99999, cfg.cli.timeouts.default)
    -- Other timeouts still defaults
    assert.equal(60000, cfg.cli.timeouts.open)
  end)

  it("accepts empty opts", function()
    config.setup({})
    local cfg = config.get()
    assert.is_table(cfg.cli)
  end)

  it("accepts nil opts", function()
    config.setup(nil)
    local cfg = config.get()
    assert.is_table(cfg.cli)
  end)

  it("overrides notification settings", function()
    config.setup({ notifications = { enabled = false, ai_activity = false } })
    local cfg = config.get()
    assert.is_false(cfg.notifications.enabled)
    assert.is_false(cfg.notifications.ai_activity)
    -- sync_complete should still be default
    assert.is_true(cfg.notifications.sync_complete)
  end)

  it("overrides watcher settings", function()
    config.setup({ watcher = { enabled = false, debounce_ms = 500 } })
    local cfg = config.get()
    assert.is_false(cfg.watcher.enabled)
    assert.equal(500, cfg.watcher.debounce_ms)
  end)

  it("replaces list values entirely (not merged)", function()
    config.setup({ cli = { executable = { "custom-cli" } } })
    local cfg = config.get()
    assert.equal(1, #cfg.cli.executable)
    assert.equal("custom-cli", cfg.cli.executable[1])
  end)
end)

-- ============================================================================
-- get_ui_config
-- ============================================================================

describe("get_ui_config", function()
  before_each(reset)

  it("returns the ui subtable", function()
    local ui = config.get_ui_config()
    assert.is_table(ui)
    assert.is_table(ui.files)
    assert.is_table(ui.comments)
    assert.is_table(ui.diff)
  end)

  it("reflects setup overrides", function()
    config.setup({ ui = { files = { provider = "builtin" } } })
    local ui = config.get_ui_config()
    assert.equal("builtin", ui.files.provider)
  end)
end)

-- ============================================================================
-- get_keymaps
-- ============================================================================

describe("get_keymaps", function()
  before_each(reset)

  it("returns keymaps subtable", function()
    local keymaps = config.get_keymaps()
    assert.is_table(keymaps)
    assert.is_string(keymaps.open_review)
  end)

  it("reflects setup overrides", function()
    config.setup({ keymaps = { open_review = "<C-p>" } })
    local keymaps = config.get_keymaps()
    assert.equal("<C-p>", keymaps.open_review)
  end)
end)

-- ============================================================================
-- get_log_level
-- ============================================================================

describe("get_log_level", function()
  before_each(reset)

  it("returns default log level", function()
    assert.equal("info", config.get_log_level())
  end)

  it("reflects setup overrides", function()
    config.setup({ log = { level = "debug" } })
    assert.equal("debug", config.get_log_level())
  end)
end)
