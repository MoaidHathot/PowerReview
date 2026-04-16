--- PowerReview.nvim health check
--- Run with :checkhealth power-review
local M = {}

function M.check()
  vim.health.start("PowerReview.nvim")

  -- 1. Neovim version
  local version = require("power-review.utils.version")
  local ver_err = version.check()
  if ver_err then
    vim.health.error(ver_err)
  else
    vim.health.ok(string.format("Neovim %s (>= 0.10.0 required)", version.format(vim.version())))
  end

  -- 2. CLI tool reachability
  local config = require("power-review.config")
  local cli_cfg = config.get().cli or {}
  local executable = cli_cfg.executable
  local cli_cmd
  if type(executable) == "table" then
    cli_cmd = table.concat(executable, " ")
  else
    cli_cmd = executable or "powerreview"
  end

  -- Try to run the CLI with --version or just invoke it
  local cli_test_args = type(executable) == "table" and vim.deepcopy(executable) or { executable or "powerreview" }
  table.insert(cli_test_args, "--version")

  local cli_result = vim.system(cli_test_args, { text = true, timeout = 10000 }):wait()
  if cli_result.code == 0 then
    local ver_out = (cli_result.stdout or ""):gsub("%s+$", "")
    vim.health.ok(string.format("CLI tool reachable: %s (%s)", cli_cmd, ver_out ~= "" and ver_out or "ok"))
  else
    local stderr = (cli_result.stderr or ""):gsub("%s+$", "")
    vim.health.error(string.format("CLI tool not reachable: %s", cli_cmd), {
      "Install the CLI: dotnet tool install -g PowerReview",
      stderr ~= "" and ("Error: " .. stderr) or nil,
    })
  end

  -- 3. .NET SDK
  local dotnet_result = vim.system({ "dotnet", "--version" }, { text = true, timeout = 10000 }):wait()
  if dotnet_result.code == 0 then
    local dotnet_ver = (dotnet_result.stdout or ""):gsub("%s+$", "")
    vim.health.ok(string.format(".NET SDK: %s", dotnet_ver))
  else
    vim.health.warn(".NET SDK not found", { "Install .NET 10 SDK from https://dotnet.microsoft.com/download" })
  end

  -- 4. Authentication
  vim.health.start("PowerReview.nvim: Authentication")

  -- Azure DevOps
  local azdo_pat = vim.env.AZDO_PAT
  if azdo_pat and azdo_pat ~= "" then
    vim.health.ok("Azure DevOps: AZDO_PAT environment variable set")
  else
    -- Check az CLI
    local az_result = vim.system({ "az", "account", "show" }, { text = true, timeout = 10000 }):wait()
    if az_result.code == 0 then
      vim.health.ok("Azure DevOps: az CLI authenticated")
    else
      vim.health.info("Azure DevOps: no authentication configured", {
        "Set AZDO_PAT environment variable, or",
        "Login with: az login",
      })
    end
  end

  -- GitHub
  local gh_token = vim.env.GITHUB_TOKEN
  if gh_token and gh_token ~= "" then
    vim.health.ok("GitHub: GITHUB_TOKEN environment variable set")
  else
    vim.health.info(
      "GitHub: GITHUB_TOKEN not set (GitHub provider not yet implemented)",
      { "Set GITHUB_TOKEN when GitHub support is available" }
    )
  end

  -- 5. Required dependencies
  vim.health.start("PowerReview.nvim: Dependencies")

  local required_deps = {
    { "nui.nvim", "nui.popup", true },
  }

  for _, dep in ipairs(required_deps) do
    local name, mod, is_required = dep[1], dep[2], dep[3]
    local ok = pcall(require, mod)
    if ok then
      vim.health.ok(string.format("%s: installed", name))
    elseif is_required then
      vim.health.warn(
        string.format("%s: not installed (recommended for full UI, fallbacks available)", name),
        { "Install: add '" .. name .. "' to your plugin manager dependencies" }
      )
    end
  end

  -- Optional dependencies
  local optional_deps = {
    { "neo-tree.nvim", "neo-tree", "Files panel (falls back to builtin panel)" },
    { "telescope.nvim", "telescope", "Fuzzy pickers (falls back to vim.ui.select)" },
    { "fzf-lua", "fzf-lua", "Alternative fuzzy pickers" },
    { "codediff.nvim", "codediff", "Alternative diff provider (native diff used by default)" },
    { "nvim-web-devicons", "nvim-web-devicons", "File type icons in panels" },
  }

  for _, dep in ipairs(optional_deps) do
    local name, mod, desc = dep[1], dep[2], dep[3]
    local ok = pcall(require, mod)
    if ok then
      vim.health.ok(string.format("%s: installed (%s)", name, desc))
    else
      vim.health.info(string.format("%s: not installed (%s)", name, desc))
    end
  end

  -- 6. Active session status
  vim.health.start("PowerReview.nvim: Session")

  local pr = require("power-review")
  local session = pr.get_current_session()
  if session then
    local helpers = require("power-review.session_helpers")
    local counts = helpers.get_draft_counts(session)
    vim.health.ok(
      string.format(
        "Active session: PR #%d - %s (%d files, %d drafts, %d threads)",
        session.pr_id or 0,
        session.pr_title or "?",
        #(session.files or {}),
        counts.total,
        #(session.threads or {})
      )
    )
  else
    vim.health.info("No active review session")
  end

  -- 7. File watcher status
  local watcher = require("power-review.watcher")
  if watcher.is_active() then
    vim.health.ok(string.format("File watcher: active (%s)", watcher.get_watched_path() or "?"))
  else
    vim.health.info("File watcher: not active")
  end
end

return M
