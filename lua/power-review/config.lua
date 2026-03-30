--- PowerReview.nvim configuration module
--- Manages default config, user overrides, and per-repo settings.
--- Auth, git strategy, and provider config are owned by the CLI tool
--- (configured at $XDG_CONFIG_HOME/PowerReview/config.json).
--- This module only holds UI-related config: keymaps, signs, panels, diff provider, CLI path.
local M = {}

---@type table
M._config = nil

--- Default configuration
---@return table
local function defaults()
  return {
    -- CLI tool configuration
    cli = {
      executable = "powerreview", -- Path or name of the CLI executable
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
