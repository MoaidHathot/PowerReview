--- Minimal init.lua for headless Neovim integration tests.
--- Usage:
---   nvim --headless -u tests/minimal_init.lua -c "lua require('tests.nvim.run')"
---
--- Sets up the runtimepath so `require("power-review.*")` resolves to the
--- local plugin source under lua/, and plugin/ auto-loads.

-- Add plugin root to rtp so lua/ and plugin/ are found
local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(plugin_root)

-- Add tests/ to Lua package path so tests can require("tests.nvim.*")
package.path = plugin_root .. "/tests/?.lua;" .. plugin_root .. "/tests/?/init.lua;" .. package.path

-- Disable swapfile, shada, and other noisy features for clean test runs
vim.o.swapfile = false
vim.o.shadafile = "NONE"
vim.o.loadplugins = false

-- Source plugin/ files (the version guard, user commands, etc.)
local plugin_dir = plugin_root .. "/plugin"
for _, file in ipairs(vim.fn.glob(plugin_dir .. "/*.lua", false, true)) do
  vim.cmd.source(file)
end
