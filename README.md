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
- **CLI + MCP server** -- .NET CLI tool with built-in MCP server for external AI agents (Claude, Copilot, etc.) to review PRs
- **Repository file access** -- AI agents can read any file in the repo (not just changed files) for full context during review
- **Session persistence** -- JSON-based session storage; resume reviews across Neovim restarts

## Requirements

- Neovim >= 0.10.0
- [nui.nvim](https://github.com/MunifTanjim/nui.nvim) (required for floating windows and panels)
- [codediff.nvim](https://github.com/esmuellert/codediff.nvim) (recommended for diff views)
- [neo-tree.nvim](https://github.com/nvim-neo-tree/neo-tree.nvim) (optional, for file tree panel)
- [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim) (optional, for fuzzy pickers)
- [.NET 10 SDK](https://dotnet.microsoft.com/download) (required for the CLI tool / MCP server)
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

PowerReview has a split configuration model:

- **CLI config** (`$XDG_CONFIG_HOME/PowerReview/powerreview.json`) -- owns authentication, git strategy, provider settings, and data directory. See [CLI Configuration](#cli-configuration) below.
- **Lua config** (`require("power-review").setup({...})`) -- owns UI settings only: keymaps, signs, panels, diff provider, CLI executable path.

### Neovim Plugin Configuration

All Lua options with their defaults:

```lua
require("power-review").setup({
  -- CLI tool
  cli = {
    executable = { "dnx", "--yes", "--add-source", "https://api.nuget.org/v3/index.json", "PowerReview", "--" },
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
      provider = "native",  -- "native" | "codediff"
    },
  },

  -- Keymaps (set any to `false` to disable)
  keymaps = {
    open_review     = "<leader>pr",
    list_sessions   = "<leader>pl",
    toggle_files    = "<leader>pf",
    toggle_comments = "<leader>pc",
    next_comment    = "]r",
    prev_comment    = "[r",
    add_comment     = "<leader>pa",
    reply_comment   = "<leader>pR",
    edit_comment    = "<leader>pe",
    approve_comment = "<leader>pA",
    submit_all      = "<leader>pS",
    set_vote        = "<leader>pv",
    sync_threads    = "<leader>ps",
    close_review    = "<leader>pQ",
    delete_session  = "<leader>pD",
  },

  -- Logging
  log = {
    level = "info",  -- "debug" | "info" | "warn" | "error"
  },
})
```

### CLI Configuration

The CLI reads its config from `$XDG_CONFIG_HOME/PowerReview/powerreview.json` (or `%APPDATA%\PowerReview\powerreview.json` on Windows). Create this file to configure authentication, git strategy, and providers:

```json
{
  "auth": {
    "azdo": {
      "method": "auto",
      "pat_env_var": "AZDO_PAT"
    },
    "github": {
      "pat_env_var": "GITHUB_TOKEN"
    }
  },
  "git": {
    "strategy": "worktree",
    "worktree_dir": ".power-review-worktrees",
    "cleanup_on_close": true
  },
  "providers": {
    "azdo": {
      "api_version": "7.1"
    }
  },
  "data_dir": null
}
```

| Field | Description |
|-------|-------------|
| `auth.azdo.method` | `"auto"` (try az CLI then PAT), `"az_cli"`, or `"pat"` |
| `auth.azdo.pat_env_var` | Environment variable name for AzDO PAT (default: `"AZDO_PAT"`) |
| `auth.github.pat_env_var` | Environment variable name for GitHub token (default: `"GITHUB_TOKEN"`) |
| `git.strategy` | `"worktree"` or `"checkout"` (default: `"worktree"`) |
| `git.worktree_dir` | Directory name for worktrees, relative to repo root |
| `git.cleanup_on_close` | Remove worktree when closing a review (default: `true`) |
| `data_dir` | Override default data directory for session storage |

Session data is stored at `{data_dir}/sessions/`. The default data directory is `$XDG_DATA_HOME/PowerReview` (or `%LOCALAPPDATA%\PowerReview` on Windows).

## Authentication

Authentication is configured in the CLI's `powerreview.json` (see [CLI Configuration](#cli-configuration)).

### Azure DevOps

When `method` is `"auto"` (default), the CLI tries in order:

1. **Azure CLI** (`az account get-access-token`) -- recommended, no config needed if you're logged in
2. **PAT** -- set via the environment variable named in `auth.azdo.pat_env_var` (default: `AZDO_PAT`)

### GitHub (planned)

Set a token via the environment variable named in `auth.github.pat_env_var` (default: `GITHUB_TOKEN`).

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
| `<leader>pR` | Reply to thread at cursor |
| `<leader>pe` | Edit draft at cursor |
| `<leader>pA` | Approve draft at cursor |
| `<leader>pS` | Submit all pending comments |
| `<leader>pv` | Set review vote |
| `<leader>ps` | Sync remote threads |
| `<leader>pQ` | Close current review |
| `<leader>pD` | Delete session |

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

## CLI Tool

PowerReview includes a .NET CLI tool that handles all PR review business logic. The Neovim plugin uses it under the hood, and it also serves as a standalone MCP server for AI agents.

### Installation

```bash
dotnet tool install -g PowerReview
```

Or build from source:

```bash
cd cli
dotnet build
```

### CLI Commands

```
dnx PowerReview -- open --pr-url <url> [--repo-path <path>]   # Open/resume a review
dnx PowerReview -- session --pr-url <url>                      # Get session info
dnx PowerReview -- files --pr-url <url>                        # List changed files
dnx PowerReview -- diff --pr-url <url> --file <path>           # Get file diff info
dnx PowerReview -- threads --pr-url <url> [--file <path>]      # List comment threads
dnx PowerReview -- comment create|edit|delete|approve|...      # Manage draft comments
dnx PowerReview -- reply --pr-url <url> --thread-id <n>        # Reply to a thread
dnx PowerReview -- submit --pr-url <url>                       # Submit pending comments
dnx PowerReview -- vote --pr-url <url> --value <value>         # Set review vote
dnx PowerReview -- sync --pr-url <url>                         # Sync threads from remote
dnx PowerReview -- close --pr-url <url>                        # Close a review session
dnx PowerReview -- sessions list|delete|clean                  # Manage saved sessions
dnx PowerReview -- working-dir --pr-url <url>                   # Get working directory path
dnx PowerReview -- read-file --pr-url <url> --file <path>      # Read any file from the repo
dnx PowerReview -- config --path-only                          # Show configuration
dnx PowerReview -- mcp                                         # Start MCP server (stdio)
```

All commands output JSON to stdout, errors to stderr. Exit codes: 0=success, 1=error, 2=usage error.

## MCP Server

The CLI doubles as an MCP (Model Context Protocol) server. Running `dnx PowerReview -- mcp` starts a stdio-based MCP server that AI agents can connect to directly -- no Neovim instance required.

### Setup

Configure your AI tool's MCP settings (e.g. `.mcp.json`, Claude Desktop config, etc.):

```json
{
  "mcpServers": {
    "power-review": {
      "command": "dnx",
      "args": ["PowerReview", "--", "mcp"]
    }
  }
}
```

### MCP Tools

The MCP server exposes these tools to AI agents:

| Tool | Parameters | Description |
|------|-----------|-------------|
| `GetReviewSession` | `prUrl` | Get session metadata (PR info, drafts, vote) |
| `ListChangedFiles` | `prUrl` | List all changed files with change types |
| `GetFileDiff` | `prUrl`, `filePath` | Get unified diff for a specific file |
| `ListCommentThreads` | `prUrl`, `filePath?` | List remote threads and local drafts |
| `GetDraftCounts` | `prUrl` | Get draft comment counts by status |
| `CreateComment` | `prUrl`, `filePath`, `lineStart`, `body`, `lineEnd?` | Create a draft comment (author=ai) |
| `ReplyToThread` | `prUrl`, `threadId`, `body` | Reply to an existing thread (author=ai) |
| `EditDraftComment` | `prUrl`, `draftId`, `newBody` | Edit a draft comment (draft status only) |
| `DeleteDraftComment` | `prUrl`, `draftId` | Delete a draft comment (draft status only) |
| `GetWorkingDirectory` | `prUrl` | Get the filesystem path to the PR working directory |
| `ReadFile` | `prUrl`, `filePath`, `offset?`, `limit?` | Read any file in the repository (not just changed files) |
| `ListRepositoryFiles` | `prUrl`, `directory?`, `pattern?`, `recursive?` | List/discover files in the repository structure |

AI-created comments are tagged with `author=ai` and start as drafts that require user approval before submission.

The file access tools (`GetWorkingDirectory`, `ReadFile`, `ListRepositoryFiles`) let AI agents read any file in the repository for context -- not just files changed in the PR. This is useful for understanding callers, checking types/interfaces, reviewing tests, or exploring project structure. All file paths are security-validated to prevent access outside the repository root.

### Architecture

The MCP server operates standalone, calling the same .NET services as the CLI:

```
AI Agent <-> dnx PowerReview -- mcp (stdio) <-> PowerReview.Core (.NET)
                                              |
                                     SessionStore (JSON files)
```

No running Neovim instance is needed. The Neovim plugin can pick up changes by watching session files on disk.

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

PowerReview is split into two components:

1. **CLI tool** (`.NET 10 global tool`) -- handles all PR review business logic: auth, git operations, Azure DevOps/GitHub API, session storage, draft management, and MCP server.
2. **Neovim plugin** (Lua) -- thin UI wrapper that calls the CLI for all operations and handles only Neovim-specific concerns: signs, panels, floats, keymaps, neo-tree, telescope.

```
PowerReview.nvim/
  plugin/power-review.lua        -- :PowerReview command registration
  lua/power-review/
    init.lua                     -- setup(), keymaps, public API
    config.lua                   -- UI-only configuration (CLI path, keymaps, signs, panels)
    cli.lua                      -- CLI bridge (spawns dnx PowerReview, parses JSON, session adapter)
    session_helpers.lua          -- Pure data helpers (get_drafts_for_file, get_threads_for_file, etc.)
    types.lua                    -- LuaCATS type annotations
    review/
      init.lua                   -- Review lifecycle coordinator (delegates to CLI)
    store/
      init.lua                   -- Session store (delegates to CLI)
    statusline.lua               -- Lualine/statusline integration
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
    utils/
      log.lua                    -- Logging utility
  lua/neo-tree/sources/power_review/
    init.lua, commands.lua, components.lua
  lua/telescope/_extensions/
    power_review.lua             -- Telescope extension entry point
  cli/                           -- .NET 10 CLI + MCP server
    PowerReview.slnx             -- Solution file
    src/
      PowerReview.Core/          -- Core library (models, services, providers, auth, git)
      PowerReview.Cli/           -- Console app (.NET global tool)
        Commands/                -- System.CommandLine CLI commands
        Mcp/                     -- MCP server (stdio transport, 12 tools)
    tests/
      PowerReview.Core.Tests/    -- xUnit tests
```

## Roadmap

- [ ] Full GitHub provider implementation
- [ ] Additional diff providers (diffview.nvim, native vim diff)
- [ ] fzf-lua picker support
- [ ] Thread resolution/status management
- [ ] File-level comments (not line-specific)
- [ ] PR description editing
- [ ] CI/pipeline status integration

## License

MIT
