--- PowerReview.nvim configuration module
--- Manages default config, user overrides, and per-repo settings.
--- Auth, git strategy, and provider config are owned by the CLI tool
--- (configured at $XDG_CONFIG_HOME/PowerReview/powerreview.json).
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
      executable = { "dnx", "--yes", "--add-source", "https://api.nuget.org/v3/index.json", "PowerReview", "--" },
      -- CLI executable command; uses .NET 10 dnx runner by default.
      -- --yes: skip interactive confirmation prompts.
      -- --add-source: ensure nuget.org is always available (repos with custom nuget.config may hide it).
      -- Can be a string (e.g., "powerreview") or a table for multi-arg commands.

      -- Timeout values for CLI operations (milliseconds).
      timeouts = {
        default = 30000,  -- Default for most operations
        open = 60000,     -- Opening a review (fetches PR data, sets up git)
        submit = 60000,   -- Submitting all pending drafts to remote
        vote = 30000,     -- Setting review vote
        sync = 30000,     -- Syncing threads from remote
      },
    },

    -- UI configuration
    ui = {
      files = {
        provider = "neo-tree", -- "neo-tree" | "builtin" (| "telescope" future)
      },
      pickers = {
        provider = "telescope", -- "telescope" | "fzf-lua"
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
        preview_debounce = 150, -- Debounce delay (ms) for live markdown preview in comment editor
      },
      diff = {
        provider = "native", -- "native" | "codediff" (codediff has a cleanup bug, see README)
      },
      virtual_text = {
        max_length = 80, -- Max length of inline virtual text previews (signs)
      },
      flash = {
        duration = 2000, -- Duration (ms) of flash highlights when navigating to comments
      },
      colors = {
        -- Colors for sign-related highlights (undercurl).
        -- Set to nil/false to use the default highlight group links instead.
        comment_undercurl = "#61afef",     -- Undercurl color for remote comment signs
        draft_undercurl = "#98c379",       -- Undercurl color for draft comment signs
        -- Colors for flash highlights
        flash_bg = "#3e4452",              -- Background color for flash highlights
        flash_border = "#e5c07b",          -- Undercurl/border color for flash column highlights
        -- Colors for subtle diff backgrounds
        diff_added = "#264a35",            -- Background for added lines in diff
        diff_changed = "#2a3040",          -- Background for changed lines in diff
        diff_deleted = "#4a2626",          -- Background for deleted lines in diff
        diff_text = "#364060",             -- Background for changed text within a line
        -- Statusline icon color
        statusline_fg = "#61afef",         -- Foreground color for the statusline component
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
            ["v"] = "toggle_reviewed",
            ["V"] = "mark_all_reviewed",
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
            { "review_status" },
          },
          pr_dir = {
            { "indent" },
            { "icon" },
            { "name" },
          },
          pr_file = {
            { "indent" },
            { "review_status" },
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

    -- Session file watcher (for real-time refresh when AI creates drafts)
    watcher = {
      enabled = true,       -- Watch the session file for changes
      debounce_ms = 200,    -- Debounce delay before reloading session on file change
    },

    -- Notifications
    notifications = {
      enabled = true,        -- Master toggle for all notifications
      ai_activity = true,    -- Notify when AI creates/edits/deletes drafts
      sync_complete = true,  -- Notify when thread sync completes
      watcher = true,        -- Notify when session file changes externally (e.g. AI agent via MCP)
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
      unapprove_comment = "<leader>pU",
      delete_comment = "<leader>pX",
      submit_all = "<leader>pS",
      set_vote = "<leader>pv",
      sync_threads = "<leader>ps",
      close_review = "<leader>pQ",
      delete_session = "<leader>pD",
      show_description = "<leader>pd",
      resolve_thread = "<leader>px",
      ai_drafts = "<leader>pi",
      mark_reviewed = "<leader>pm",
      mark_all_reviewed = "<leader>pM",
      check_iteration = "<leader>pI",
      iteration_diff = "<leader>pn",
      next_unreviewed = "]u",
      prev_unreviewed = "[u",
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
