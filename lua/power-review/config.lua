--- PowerReview.nvim configuration module
--- Manages default config, user overrides, and per-repo settings.
local M = {}

---@type table
M._config = nil

--- Default configuration
---@return table
local function defaults()
  return {
    -- Per-repo provider config, keyed by absolute path
    -- Example:
    -- repos = {
    --   ["/path/to/repo"] = {
    --     provider = "azdo",
    --     azdo = { organization = "myorg", project = "myproject", repository = "myrepo" },
    --   },
    -- },
    repos = {},

    -- Authentication
    auth = {
      azdo = {
        method = "auto", -- "auto" | "az_cli" | "pat"
        pat = nil, -- PAT string, or set POWER_REVIEW_AZDO_PAT / AZDO_PAT env var
      },
      github = {
        pat = nil, -- or set GITHUB_TOKEN / POWER_REVIEW_GITHUB_PAT env var
      },
    },

    -- Git strategy
    git = {
      strategy = "worktree", -- "worktree" | "checkout"
      worktree_dir = ".power-review-worktrees", -- relative to repo root
      cleanup_on_close = true, -- remove worktree when review is closed
    },

    -- UI configuration
    ui = {
      files = {
        provider = "neo-tree", -- "neo-tree" | "builtin" (| "telescope" future)
      },
      comments = {
        float = {
          width = 80,
          height = 20,
          border = "rounded",
        },
        panel = {
          position = "right", -- "right" | "bottom"
          width = 50,
          height = 15,
        },
        signs = {
          remote = "",
          draft = "",
          ai_draft = "󰚩",
        },
      },
      diff = {
        provider = "native", -- "native" | "codediff" (codediff has a cleanup bug, see README)
      },
      -- Neo-tree source configuration (passed to neo-tree setup by the user)
      -- This is the recommended config to add to neo-tree's power_review source:
      neotree = {
        window = {
          position = "left",
          width = 40,
          mappings = {
            ["<cr>"] = "open",
            ["o"] = "open",
            ["<C-v>"] = "open_vsplit",
            ["<C-x>"] = "open_split",
            ["<C-t>"] = "open_tabnew",
            ["a"] = "add_comment",
            ["i"] = "show_file_details",
            ["R"] = "refresh",
            ["y"] = "copy_path",
          },
        },
        renderers = {
          pr_root = {
            { "indent" },
            { "icon" },
            { "name" },
            { "comment_count" },
          },
          pr_dir = {
            { "indent" },
            { "icon" },
            { "name" },
          },
          pr_file = {
            { "indent" },
            { "change_type" },
            { "icon" },
            { "comment_count" },
            { "name" },
            { "file_stats" },
          },
          message = {
            { "indent" },
            { "icon" },
            { "name" },
          },
        },
      },
    },

    -- MCP server configuration
    mcp = {
      enabled = false,
    },

    -- Keymaps
    keymaps = {
      open_review = "<leader>pr",
      list_sessions = "<leader>pl",
      toggle_files = "<leader>pf",
      toggle_comments = "<leader>pc",
      next_comment = "]r",
      prev_comment = "[r",
      add_comment = "<leader>pa",
      reply_comment = "<leader>pR",
      edit_comment = "<leader>pe",
      approve_comment = "<leader>pA",
      submit_all = "<leader>pS",
      set_vote = "<leader>pv",
      sync_threads = "<leader>ps",
      close_review = "<leader>pQ",
      delete_session = "<leader>pD",
    },

    -- Logging
    log = {
      level = "info", -- "debug" | "info" | "warn" | "error"
    },
  }
end

--- Deep merge two tables. Values from `override` take precedence.
---@param base table
---@param override table
---@return table
local function deep_merge(base, override)
  local result = vim.deepcopy(base)
  for k, v in pairs(override) do
    if type(v) == "table" and type(result[k]) == "table" and not vim.islist(v) then
      result[k] = deep_merge(result[k], v)
    else
      result[k] = vim.deepcopy(v)
    end
  end
  return result
end

--- Initialize configuration with user overrides
---@param opts? table User configuration
function M.setup(opts)
  M._config = deep_merge(defaults(), opts or {})
end

--- Get the full resolved configuration
---@return table
function M.get()
  if not M._config then
    M._config = defaults()
  end
  return M._config
end

--- Get provider configuration for a specific repository path.
--- Resolves the repo path against the `repos` table in config.
---@param repo_path string Absolute path to the repository root
---@return PowerReview.RepoConfig|nil
function M.get_repo_config(repo_path)
  local cfg = M.get()
  if not cfg.repos then
    return nil
  end

  -- Normalize path separators for comparison
  local normalized = repo_path:gsub("\\", "/"):gsub("/$", "")

  for path, repo_cfg in pairs(cfg.repos) do
    local norm_key = path:gsub("\\", "/"):gsub("/$", "")
    if normalized == norm_key or normalized:find(norm_key, 1, true) == 1 then
      return repo_cfg
    end
  end

  return nil
end

--- Get auth configuration for a specific provider type
---@param provider_type PowerReview.ProviderType
---@return table
function M.get_auth_config(provider_type)
  local cfg = M.get()
  if provider_type == "azdo" then
    return cfg.auth.azdo or {}
  elseif provider_type == "github" then
    return cfg.auth.github or {}
  end
  return {}
end

--- Get the git strategy configuration
---@return table
function M.get_git_config()
  return M.get().git
end

--- Get UI configuration
---@return table
function M.get_ui_config()
  return M.get().ui
end

--- Get keymap configuration
---@return table
function M.get_keymaps()
  return M.get().keymaps
end

--- Get log level
---@return string
function M.get_log_level()
  return M.get().log.level
end

return M
