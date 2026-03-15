# PowerReview.nvim

A Neovim plugin for reviewing Pull Requests from Azure DevOps (with GitHub support planned) directly inside your editor. Supports manual and LLM-assisted review with draft comment staging, rich UI panels, diff views, and an MCP server for external AI agent integration.

## Features

- **Azure DevOps PR review** -- Fetch PR metadata, changed files, comment threads, set votes
- **Git worktree/checkout** -- Automatically set up a worktree or checkout the PR branch
- **Draft comment workflow** -- Create, edit, approve, and submit comments in a draft->pending->submitted pipeline
- **LLM safety guards** -- AI can only modify comments in `draft` status; `pending`/`submitted` are immutable to LLMs
- **Rich diff view** -- codediff.nvim integration for VSCode-style side-by-side diffs with character-level highlighting
- **Neo-tree source** -- Custom file tree panel showing changed files with change type icons and draft counts
- **Built-in fallback panels** -- NuiSplit+NuiTree panels for files, comments, drafts, and sessions (no dependency on Neo-tree)
- **Floating comment windows** -- nui.nvim floating editor for writing/editing comments with markdown
- **Comment signs/extmarks** -- Inline indicators in diff buffers showing where comments and drafts exist
- **Telescope pickers** -- Fuzzy find changed files, comments, and sessions
- **MCP server** -- TypeScript/Node.js MCP server for external AI agents (Claude, Copilot, etc.) to review PRs
- **Session persistence** -- JSON-based session storage; resume reviews across Neovim restarts

## Requirements

- Neovim >= 0.10.0
- [nui.nvim](https://github.com/MunifTanjim/nui.nvim) (required for floating windows and panels)
- [codediff.nvim](https://github.com/esmuellert/codediff.nvim) (recommended for diff views)
- [neo-tree.nvim](https://github.com/nvim-neo-tree/neo-tree.nvim) (optional, for file tree panel)
- [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim) (optional, for fuzzy pickers)
- `curl` on PATH (for HTTP requests to AzDO/GitHub APIs)
- For Azure DevOps: `az` CLI (recommended) or a Personal Access Token (PAT)

## Installation

### lazy.nvim

```lua
{
  "your-username/PowerReview.nvim",
  dependencies = {
    "MunifTanjim/nui.nvim",
    "esmuellert/codediff.nvim",        -- recommended
    "nvim-neo-tree/neo-tree.nvim",      -- optional
    "nvim-telescope/telescope.nvim",    -- optional
  },
  config = function()
    require("power-review").setup({
      -- See Configuration below for all options
    })
  end,
}
```

If using Neo-tree, register the `power_review` source in your Neo-tree config:

```lua
require("neo-tree").setup({
  sources = {
    "filesystem",
    "buffers",
    "git_status",
    "power_review",  -- Add this
  },
  power_review = require("power-review.config").get().ui.neotree,
})
```

If using Telescope, load the extension:

```lua
require("telescope").load_extension("power_review")
```

## Configuration

All options with their defaults:

```lua
require("power-review").setup({
  -- Per-repo provider config, keyed by absolute path
  repos = {
    -- ["/path/to/repo"] = {
    --   provider = "azdo",
    --   azdo = {
    --     organization = "myorg",
    --     project = "myproject",
    --     repository = "myrepo",
    --   },
    -- },
  },

  -- Authentication
  auth = {
    azdo = {
      method = "auto",  -- "auto" | "az_cli" | "pat"
      pat = nil,        -- or set POWER_REVIEW_AZDO_PAT / AZDO_PAT env var
    },
    github = {
      pat = nil,        -- or set GITHUB_TOKEN / POWER_REVIEW_GITHUB_PAT env var
    },
  },

  -- Git strategy
  git = {
    strategy = "worktree",                     -- "worktree" | "checkout"
    worktree_dir = ".power-review-worktrees",  -- relative to repo root
    cleanup_on_close = true,                   -- remove worktree on review close
  },

  -- UI configuration
  ui = {
    files = {
      provider = "neo-tree",  -- "neo-tree" | "builtin"
    },
    comments = {
      float = {
        width = 80,
        height = 20,
        border = "rounded",
      },
      panel = {
        position = "right",  -- "right" | "bottom"
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
      provider = "codediff",  -- "codediff" (more providers planned)
    },
  },

  -- MCP server integration
  mcp = {
    enabled = false,  -- Write server_info.json for MCP server connection
  },

  -- Keymaps (set any to `false` to disable)
  keymaps = {
    open_review    = "<leader>pr",
    list_sessions  = "<leader>pl",
    toggle_files   = "<leader>pf",
    toggle_comments = "<leader>pc",
    next_comment   = "]r",
    prev_comment   = "[r",
    add_comment    = "<leader>pa",
    reply_comment  = "<leader>prr",
    edit_comment   = "<leader>pe",
    approve_comment = "<leader>pA",
    submit_all     = "<leader>pS",
    set_vote       = "<leader>pv",
  },

  -- Logging
  log = {
    level = "info",  -- "debug" | "info" | "warn" | "error"
  },
})
```

## Authentication

### Azure DevOps

The plugin tries authentication methods in this order when `method = "auto"`:

1. **Azure CLI** (`az account get-access-token`) -- recommended, no config needed if you're logged in
2. **PAT** -- set via `auth.azdo.pat` in config or environment variables:
   - `POWER_REVIEW_AZDO_PAT`
   - `AZDO_PAT`

### GitHub (planned)

Set a token via `auth.github.pat` or environment variables:
- `GITHUB_TOKEN`
- `POWER_REVIEW_GITHUB_PAT`

## Commands

All commands are under `:PowerReview`:

| Command | Description |
|---------|-------------|
| `:PowerReview <url>` | Start a review from a PR URL |
| `:PowerReview open [url]` | Start review from URL, or pick from saved sessions |
| `:PowerReview sessions` | Toggle the session management panel |
| `:PowerReview list` | List saved sessions in messages |
| `:PowerReview delete [id]` | Delete a saved session (with picker if no ID) |
| `:PowerReview clean` | Delete all saved sessions (with confirmation) |
| `:PowerReview files` | Toggle the changed files panel |
| `:PowerReview comments` | Toggle the all-comments panel |
| `:PowerReview drafts` | Toggle the draft management panel |
| `:PowerReview comment` | Add a comment at cursor (supports visual selection) |
| `:PowerReview thread` | View/reply to thread at cursor |
| `:PowerReview diff [file]` | Open diff for a file, or the diff explorer |
| `:PowerReview next` | Jump to next comment in buffer |
| `:PowerReview prev` | Jump to previous comment in buffer |
| `:PowerReview approve [id]` | Approve a draft (at cursor if no ID) |
| `:PowerReview approve_all` | Approve all drafts (with confirmation) |
| `:PowerReview submit` | Submit all pending comments to remote |
| `:PowerReview vote` | Set review vote (approve, reject, etc.) |
| `:PowerReview refresh` | Refresh session data from remote |
| `:PowerReview close` | Close the current review session |

## Keymaps

### Global Keymaps

These are registered on `setup()` and work everywhere:

| Key | Action |
|-----|--------|
| `<leader>pr` | Open/resume a review |
| `<leader>pl` | List saved sessions |
| `<leader>pf` | Toggle files panel |
| `<leader>pc` | Toggle comments panel |
| `]r` | Next comment |
| `[r` | Previous comment |
| `<leader>pa` | Add comment (normal: at cursor, visual: on selection) |
| `<leader>prr` | Reply to thread at cursor |
| `<leader>pe` | Edit draft at cursor |
| `<leader>pA` | Approve draft at cursor |
| `<leader>pS` | Submit all pending comments |
| `<leader>pv` | Set review vote |

### Buffer-Local Keymaps (Diff Buffers)

Automatically registered when comment signs attach to a diff buffer. These mirror the global keymaps but are scoped to the buffer.

### Panel Keymaps

#### Files Panel (builtin)
| Key | Action |
|-----|--------|
| `<CR>` | Open diff for file |
| `a` | Add comment |
| `R` | Refresh |
| `q` | Close panel |

#### Drafts Panel
| Key | Action |
|-----|--------|
| `<CR>` | Navigate to file/line or expand/collapse |
| `a` | Approve draft |
| `A` | Approve all drafts |
| `u` | Unapprove (revert pending to draft) |
| `e` | Edit draft |
| `d` | Delete draft |
| `i` | Show full details |
| `R` | Refresh |
| `q` | Close panel |

#### Sessions Panel
| Key | Action |
|-----|--------|
| `<CR>` / `o` | Resume selected session |
| `d` | Delete selected session |
| `n` | Start new review from URL |
| `l` / `h` | Expand/collapse details |
| `R` | Refresh |
| `?` | Show help |
| `q` | Close panel |

## Telescope Pickers

Available via the Telescope extension or the Lua API:

```vim
:Telescope power_review changed_files
:Telescope power_review comments
:Telescope power_review sessions
```

Or from Lua:

```lua
require("power-review.telescope").changed_files()
require("power-review.telescope").comments()
require("power-review.telescope").sessions()
```

## Draft Comment Workflow

Comments follow a strict lifecycle:

```
draft -> pending -> submitted
```

1. **Draft** -- Created locally. Can be edited, deleted, or approved. LLMs can modify drafts.
2. **Pending** -- Approved and ready to submit. Immutable to LLMs. Can be unapproved (reverted to draft).
3. **Submitted** -- Sent to the remote provider. Immutable.

This design ensures LLM-generated comments always go through human approval before submission.

## MCP Server

PowerReview includes an MCP (Model Context Protocol) server that allows external AI agents to interact with your review session.

### Setup

1. Enable MCP in your config:

```lua
require("power-review").setup({
  mcp = { enabled = true },
})
```

2. Install the MCP server dependencies:

```bash
cd /path/to/PowerReview.nvim/mcp
npm install
npm run build
```

3. Configure your AI tool's `.mcp.json`:

```json
{
  "mcpServers": {
    "power-review": {
      "command": "node",
      "args": ["/path/to/PowerReview.nvim/mcp/dist/index.js"]
    }
  }
}
```

Or if published to npm:

```json
{
  "mcpServers": {
    "power-review": {
      "command": "npx",
      "args": ["power-review-mcp"]
    }
  }
}
```

### MCP Tools

The MCP server exposes these tools to AI agents:

| Tool | Description |
|------|-------------|
| `get_review_session` | Get current session metadata |
| `list_changed_files` | List all changed files in the PR |
| `get_file_diff` | Get inline diff for a specific file |
| `list_comment_threads` | List all comment threads and drafts |
| `create_comment` | Create a new draft comment (author=ai) |
| `reply_to_thread` | Reply to an existing thread |
| `edit_draft_comment` | Edit a draft comment (draft status only) |
| `delete_draft_comment` | Delete a draft comment (draft status only) |

### Architecture

The MCP server connects to the running Neovim instance via msgpack-RPC:

```
AI Agent <-> MCP Server (stdio) <-> Neovim (RPC socket)
                                        |
                                  PowerReview Lua API
```

The server auto-discovers the Neovim socket from `server_info.json` written by the plugin. Environment variable overrides: `NVIM_SOCKET_PATH`, `NVIM`, `POWER_REVIEW_SERVER_INFO`.

## Lua API

The public API is available at `require("power-review").api`:

```lua
local api = require("power-review").api

-- Files
api.get_changed_files()                          -- Returns ChangedFile[] or nil, error
api.get_file_diff(file_path)                     -- Returns diff string or nil, error

-- Threads
api.get_all_threads()                            -- Returns thread table or nil, error
api.get_threads_for_file(file_path)              -- Returns thread table or nil, error

-- Draft comments
api.create_draft_comment({
  file_path = "src/main.lua",
  line_start = 42,
  line_end = 45,       -- optional, for range comments
  body = "Consider...",
  author = "user",     -- "user" | "ai"
})
api.edit_draft_comment(draft_id, new_body)       -- Returns bool, error
api.delete_draft_comment(draft_id)               -- Returns bool, error
api.approve_draft(draft_id)                      -- Returns bool, error
api.approve_all_drafts()                         -- Returns count
api.unapprove_draft(draft_id)                    -- Returns bool, error

-- Submit
api.submit_pending(callback, progress_cb)        -- Async
api.retry_failed_submissions(failed, callback)   -- Async

-- Vote
api.set_vote(vote, callback)                     -- Async, vote: 10|5|0|-5|-10

-- Session
api.get_review_session()                         -- Returns session info table
api.reply_to_thread({ thread_id, body, ... })    -- Returns draft or nil, error
```

## Architecture

```
PowerReview.nvim/
  plugin/power-review.lua        -- :PowerReview command registration
  lua/power-review/
    init.lua                     -- setup(), keymaps, public API
    config.lua                   -- Configuration with deep merge
    types.lua                    -- LuaCATS type annotations
    providers/
      init.lua                   -- Provider factory
      base.lua                   -- Provider interface validator
      azdo.lua                   -- Azure DevOps provider (full)
      github.lua                 -- GitHub provider (stub)
    auth/
      init.lua                   -- Auth dispatcher
      pat.lua                    -- PAT authentication
      az_cli.lua                 -- Azure CLI authentication
    git/
      init.lua                   -- Git coordinator
      worktree.lua               -- Worktree strategy
      branch.lua                 -- Branch/checkout strategy
    review/
      init.lua                   -- Review lifecycle coordinator
      session.lua                -- Session model
      comment.lua                -- Comment model
      status.lua                 -- Vote management
    store/
      init.lua                   -- Persistence high-level API
      json.lua                   -- JSON file backend
    ui/
      init.lua                   -- UI coordinator
      files_panel.lua            -- Built-in file list panel
      diff.lua                   -- Diff view integration
      signs.lua                  -- Comment signs/extmarks
      comment_float.lua          -- Floating comment editor
      comments_panel.lua         -- All-comments split panel
      drafts.lua                 -- Draft management panel
      sessions.lua               -- Session management panel
    telescope/
      init.lua                   -- Telescope pickers
    mcp/
      init.lua                   -- MCP Neovim-side helpers
    utils/
      log.lua, http.lua, async.lua, url.lua
  lua/neo-tree/sources/power_review/
    init.lua, commands.lua, components.lua
  lua/telescope/_extensions/
    power_review.lua             -- Telescope extension entry point
  mcp/                           -- MCP TypeScript server
    src/index.ts, nvim-client.ts, tools.ts
    dist/                        -- Compiled JS
    package.json, tsconfig.json
```

## Roadmap

- [ ] Full GitHub provider implementation
- [ ] Additional diff providers (diffview.nvim, native vim diff)
- [ ] fzf-lua picker support
- [ ] Remote thread fetching and caching
- [ ] Thread resolution/status management
- [ ] File-level comments (not line-specific)
- [ ] PR description editing
- [ ] CI/pipeline status integration
- [ ] Publish MCP server to npm

## License

MIT
