--- Minimal test runner for headless Neovim integration tests.
--- Discovers and executes all *_spec.lua files under tests/nvim/.
--- Each spec file should return a table of { name = string, fn = function } entries.
---
--- Usage:
---   nvim --headless -u tests/minimal_init.lua -c "lua require('tests.nvim.run')"
---
--- Exit codes: 0 = all passed, 1 = failures exist.

local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
local spec_dir = plugin_root .. "/tests/nvim"

-- Collect spec files
local spec_files = vim.fn.glob(spec_dir .. "/*_spec.lua", false, true)
table.sort(spec_files)

local total = 0
local passed = 0
local failed = 0
local errors = {}

for _, file in ipairs(spec_files) do
  local rel = file:sub(#plugin_root + 2) -- relative path for display
  local ok_load, spec = pcall(dofile, file)

  if not ok_load then
    failed = failed + 1
    total = total + 1
    table.insert(errors, string.format("  LOAD ERROR: %s\n    %s", rel, spec))
  elseif type(spec) ~= "table" then
    failed = failed + 1
    total = total + 1
    table.insert(errors, string.format("  LOAD ERROR: %s\n    spec file must return a table", rel))
  else
    for _, test in ipairs(spec) do
      total = total + 1
      local ok_run, err = pcall(test.fn)
      if ok_run then
        passed = passed + 1
      else
        failed = failed + 1
        table.insert(errors, string.format("  FAIL: %s :: %s\n    %s", rel, test.name, err))
      end
    end
  end
end

-- Report
print(string.format("\n=== Headless Neovim Tests ==="))
print(string.format("  Total: %d  Passed: %d  Failed: %d", total, passed, failed))

if #errors > 0 then
  print("")
  for _, e in ipairs(errors) do
    print(e)
  end
end

print("")

-- Exit with appropriate code
vim.cmd("cquit" .. (failed > 0 and " 1" or " 0"))
