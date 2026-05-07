# PowerReview

A pull request review system with human-in-the-loop AI integration. PowerReview combines a .NET CLI tool (with built-in MCP server) and a Neovim plugin to let you review PRs from your editor -- with or without AI assistance.

Currently supports **Azure DevOps**, with GitHub support planned.

## Components

PowerReview is two things:

1. **CLI tool & MCP server** (`.NET 10`) -- handles all business logic: authentication, git operations, Azure DevOps API, session persistence, draft management, and an MCP server for AI agent integration. Published as a [NuGet global tool](https://www.nuget.org/packages/PowerReview). No Neovim required.
2. **Neovim plugin** (Lua) -- thin UI layer that calls the CLI for every operation. Handles signs, panels, floating windows, keymaps, diff views, and integrations with Neo-tree, Telescope, and fzf-lua.

No business logic lives in Lua. The CLI can be used standalone or through the MCP server by any AI agent.

## Features

- **Draft operation workflow** -- `draft -> pending -> submitted` pipeline with human approval gate
- **LLM safety guards** -- AI agents create local draft operations; remote PR mutations require user approval and submit
- **MCP server** -- 23 tools exposed via stdio for AI agents (Claude, Copilot, etc.) to review PRs and respond to comments autonomously
- **Proposed code fixes** -- AI agents can create code changes on temporary branches in response to PR comments; user reviews diffs and approves before merging
- **Fix worktree** -- isolated git worktree for AI agents to make code changes without affecting the user's working directory
- **Iteration tracking** -- detects when the PR author pushes new commits; smart reset preserves review status for unchanged files
- **Review progress** -- mark files as reviewed, track progress per-file with visual indicators
- **Rich diff views** -- native vim diff or codediff.nvim for side-by-side diffs with character-level highlighting
- **Iteration diff** -- see exactly what changed between the iteration you reviewed and the latest push
- **Comment signs & extmarks** -- inline indicators in diff buffers with virtual text previews, column-level highlighting, and flash navigation
- **File watcher** -- monitors session files on disk; UI updates in real-time when AI agents create comments via MCP
- **Notification system** -- categorized, toggleable notifications for AI activity, sync events, and watcher updates
- **PR description viewer** -- floating window with full PR metadata (author, reviewers, branches, work items, labels, votes)
- **Thread resolution** -- change thread status (active, fixed, won't fix, closed, by design, pending)
- **Session persistence** -- JSON-based storage with atomic writes and file locking; resume reviews across Neovim restarts
- **Statusline integration** -- shows PR number, iteration, review progress, draft counts, and per-file comment breakdown
- **Multiple file browsers** -- Neo-tree custom source, built-in NuiTree panel, Telescope pickers, fzf-lua pickers
- **Health check** -- `:checkhealth power-review` validates CLI, .NET SDK, auth, dependencies, and active session state
- **Repository file access** -- AI agents can read any file in the repo (not just changed files) for full context during review
- **Git worktree support** -- automatically sets up a worktree or checks out the PR branch

## Requirements

- [.NET 10 SDK](https://dotnet.microsoft.com/download) (required for the CLI tool / MCP server)
- Neovim >= 0.10.0 (for the plugin)
- [nui.nvim](https://github.com/MunifTanjim/nui.nvim) (required for floating windows and panels)
- [codediff.nvim](https://github.com/esmuellert/codediff.nvim) (optional, for side-by-side diffs)
- [neo-tree.nvim](https://github.com/nvim-neo-tree/neo-tree.nvim) (optional, for file tree panel)
- [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim) (optional, for fuzzy pickers)
- [fzf-lua](https://github.com/ibhagwan/fzf-lua) (optional, alternative fuzzy pickers)
- For Azure DevOps: `az` CLI (recommended) or a Personal Access Token (PAT)

## Installation

### CLI Tool

Install as a .NET global tool:

```bash
dotnet tool install -g PowerReview
```

Or build from source:

```bash
cd cli
dotnet build
```

### Neovim Plugin (lazy.nvim)

```lua
{
  "MoaidHathot/PowerReview.nvim",
  dependencies = {
    "MunifTanjim/nui.nvim",
    "esmuellert/codediff.nvim",        -- optional
    "nvim-neo-tree/neo-tree.nvim",      -- optional
    "nvim-telescope/telescope.nvim",    -- optional
    "ibhagwan/fzf-lua",                 -- optional
  },
  config = function()
    require("power-review").setup({
      -- See Configuration below
    })
  end,
}
```

If using Neo-tree, register the `power_review` source:

```lua
require("neo-tree").setup({
  sources = {
    "filesystem",
    "buffers",
    "git_status",
    "power_review",
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

- **CLI config** (`$XDG_CONFIG_HOME/PowerReview/powerreview.json`) -- authentication, git strategy, provider settings, data directory
- **Lua config** (`require("power-review").setup({...})`) -- UI settings only: keymaps, signs, panels, diff provider, CLI executable path

### Neovim Plugin Configuration

All Lua options with their defaults:

```lua
require("power-review").setup({
  cli = {
    executable = { "dnx", "--yes", "--add-source", "https://api.nuget.org/v3/index.json", "PowerReview", "--" },
    timeouts = {
      default = 30000,
      open = 60000,
      submit = 60000,
      vote = 30000,
      sync = 30000,
    },
  },

  ui = {
    files = {
      provider = "neo-tree",   -- "neo-tree" | "builtin"
    },
    pickers = {
      provider = "telescope",  -- "telescope" | "fzf-lua"
    },
    comments = {
      float = { width = 80, height = 20, border = "rounded" },
      panel = { position = "right", width = 50, height = 15 },
      signs = {
        remote = "",
        draft = "",
        ai_draft = "󰚩",
      },
      preview_debounce = 150,
    },
    diff = {
      provider = "native",  -- "native" | "codediff"
    },
    virtual_text = { max_length = 80 },
    flash = { duration = 2000 },
    colors = {
      comment_undercurl = "#61afef",
      draft_undercurl = "#98c379",
      flash_bg = "#3e4452",
      flash_border = "#e5c07b",
      diff_added = "#264a35",
      diff_changed = "#2a3040",
      diff_deleted = "#4a2626",
      diff_text = "#364060",
      statusline_fg = "#61afef",
    },
  },

  watcher = {
    enabled = true,
    debounce_ms = 200,
  },

  notifications = {
    enabled = true,
    ai_activity = true,
    sync_complete = true,
    watcher = true,
  },

  keymaps = {
    open_review      = "<leader>pr",
    list_sessions    = "<leader>pl",
    toggle_files     = "<leader>pf",
    toggle_comments  = "<leader>pc",
    next_comment     = "]r",
    prev_comment     = "[r",
    add_comment      = "<leader>pa",
    reply_comment    = "<leader>pR",
    edit_comment     = "<leader>pe",
    approve_comment  = "<leader>pA",
    unapprove_comment = "<leader>pU",
    delete_comment   = "<leader>pX",
    submit_all       = "<leader>pS",
    set_vote         = "<leader>pv",
    sync_threads     = "<leader>ps",
    close_review     = "<leader>pQ",
    delete_session   = "<leader>pD",
    show_description = "<leader>pd",
    resolve_thread   = "<leader>px",
    ai_drafts        = "<leader>pi",
    mark_reviewed    = "<leader>pm",
    mark_all_reviewed = "<leader>pM",
    check_iteration  = "<leader>pI",
    iteration_diff   = "<leader>pn",
    next_unreviewed  = "]u",
    prev_unreviewed  = "[u",
  },

  log = {
    level = "info",  -- "debug" | "info" | "warn" | "error"
  },
})
```

Set any keymap to `false` to disable it.

### CLI Configuration

The CLI reads from `$XDG_CONFIG_HOME/PowerReview/powerreview.json` (or `%APPDATA%\PowerReview\powerreview.json` on Windows):

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
    "always_separate_worktree": false,
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
| `git.worktree_dir` | Directory hosting review worktrees. **Relative** (default `".power-review-worktrees"`) joins with the repo root. **Absolute** (e.g. `"P:\\Work\\PowerReview\\Sessions"`) places worktrees outside the repo, namespaced by repo identity, so multiple repos can share one base directory and the repo itself stays clean. |
| `git.always_separate_worktree` | If `true`, always create a separate linked worktree even when the main repo is already on the PR's source branch. Keeps your repo's branch state untouched by reviews (default: `false`). |
| `git.cleanup_on_close` | Remove worktree when closing a review (default: `true`) |
| `data_dir` | Override default data directory for session storage |

Session data is stored at `{data_dir}/sessions/`. The default data directory is `$XDG_DATA_HOME/PowerReview` (or `%LOCALAPPDATA%\PowerReview` on Windows).

### Recommended layout: keep your dev repo clean

PR reviews inherently need a working tree on the PR's source branch, which means *something* on disk has to host that branch. If you don't want PowerReview to attach review branches to your everyday clone (changing what `git status` / `git branch` show, occupying branches you may want to use yourself, etc.), use this layout:

```
P:\Work\<project>\<repo>\               <- your normal dev clone, never used by PowerReview
P:\Work\PowerReview\<repo>\             <- a separate clone, parked on `main`, used by PowerReview
P:\Work\PowerReview\Sessions\           <- (optional) absolute base for review worktrees
```

Then in `powerreview.json`:

```json
{
  "git": {
    "strategy": "worktree",
    "repo_base_path": "P:\\Work\\PowerReview\\<repo>",
    "worktree_dir": "P:\\Work\\PowerReview\\Sessions",
    "always_separate_worktree": true,
    "cleanup_on_close": true,
    "auto_clone": true
  }
}
```

What this gives you:

- Your everyday clone is never touched by reviews -- no attached review branches, no `.power-review-*` directories appearing in it.
- Review worktrees live under one external folder, namespaced by repo identity, so several repos can share the same `worktree_dir`.
- `always_separate_worktree: true` prevents PowerReview from "reusing" the main checkout when it happens to already be on the PR's source branch, so the review clone stays predictable.
- AI fix worktrees automatically follow: when `worktree_dir` is absolute, fix worktrees go under `{worktree_dir}/.fixes/<repoId>/<prId>` instead of being written into the repo.

If you instead leave `worktree_dir` relative, worktrees are placed under the configured clone (the legacy default) -- which is fine as long as that clone is dedicated to PowerReview and not used for normal branch work.

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
| `:PowerReview sessions` | Open sessions picker (Telescope/fzf-lua) |
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
| `:PowerReview refresh` | Full refresh of session data from remote |
| `:PowerReview sync` | Lightweight sync of remote threads + iteration check |
| `:PowerReview close` | Close the current review session |
| `:PowerReview show_description` | Toggle the PR description floating window |
| `:PowerReview resolve_thread <id> <status>` | Change thread status (active/fixed/wontfix/closed/bydesign/pending) |
| `:PowerReview mark_reviewed [file]` | Mark a file as reviewed |
| `:PowerReview unmark_reviewed [file]` | Remove reviewed status from a file |
| `:PowerReview mark_all_reviewed` | Mark all PR files as reviewed |
| `:PowerReview check_iteration` | Check for new iterations (smart reset) |
| `:PowerReview iteration_diff [file]` | View what changed between iterations for a file |
| `:PowerReview toggle_notifications` | Toggle notification system on/off |

## Keymaps

### Global Keymaps

Registered on `setup()` and available everywhere:

| Key | Mode | Action |
|-----|------|--------|
| `<leader>pr` | n | Open/resume a review |
| `<leader>pl` | n | List saved sessions |
| `<leader>pf` | n | Toggle files panel |
| `<leader>pc` | n | Toggle comments panel |
| `]r` | n | Next comment |
| `[r` | n | Previous comment |
| `<leader>pa` | n, v | Add comment (at cursor or on visual selection) |
| `<leader>pR` | n | Reply to thread at cursor |
| `<leader>pe` | n | Edit draft at cursor |
| `<leader>pA` | n | Approve draft at cursor |
| `<leader>pU` | n | Unapprove draft at cursor |
| `<leader>pX` | n | Delete draft at cursor |
| `<leader>pS` | n | Submit all pending comments |
| `<leader>pv` | n | Set review vote |
| `<leader>ps` | n | Sync remote threads |
| `<leader>pQ` | n | Close current review |
| `<leader>pD` | n | Delete session |
| `<leader>pd` | n | Show PR description |
| `<leader>px` | n | Resolve thread at cursor |
| `<leader>pi` | n | AI drafts panel |
| `<leader>pm` | n | Toggle file reviewed status |
| `<leader>pM` | n | Mark all files reviewed |
| `<leader>pI` | n | Check for new iterations |
| `<leader>pn` | n | Iteration diff for current file |
| `]u` | n | Next unreviewed file |
| `[u` | n | Previous unreviewed file |

### Panel Keymaps

#### Files Panel (builtin)
| Key | Action |
|-----|--------|
| `<CR>` | Open diff for file |
| `a` | Add comment |
| `R` | Refresh |
| `q` | Close panel |

#### Neo-tree (power_review source)
| Key | Action |
|-----|--------|
| `<CR>` / `o` | Open diff |
| `<C-v>` / `<C-x>` / `<C-t>` | Open in vsplit/split/tab |
| `a` | Add comment |
| `v` | Toggle reviewed status |
| `V` | Mark all files reviewed |
| `i` | Show file details |
| `R` | Refresh |
| `y` | Copy path |

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

## Pickers

### Telescope

```vim
:Telescope power_review changed_files
:Telescope power_review comments
:Telescope power_review sessions
```

### fzf-lua

```lua
require("power-review.fzf_lua").changed_files()
require("power-review.fzf_lua").comments()
require("power-review.fzf_lua").sessions()
```

fzf-lua pickers include custom previewers (diff preview, comment thread preview, session detail preview) and review status indicators.

## Draft Comment Workflow

Comments follow a strict lifecycle:

```
draft -> pending -> submitted
```

1. **Draft** -- created locally. Can be edited, deleted, or approved. AI agents can modify drafts they created.
2. **Pending** -- approved and ready to submit. Immutable to AI. Can be unapproved (reverted to draft).
3. **Submitted** -- sent to the remote provider. Immutable.

AI-created comments are tagged with `author=ai` and always start as drafts that require human approval before submission.

## Iteration Tracking & Smart Reset

When the PR author pushes new commits:

1. `:PowerReview check_iteration` (or `<leader>pI`) detects new iterations
2. **Smart reset** runs: only files that actually changed between iterations lose their "reviewed" status
3. Files that were not modified keep their reviewed mark
4. `:PowerReview iteration_diff [file]` (or `<leader>pn`) shows exactly what changed between the iteration you reviewed and the latest push

Sync (`:PowerReview sync`) also checks for new iterations automatically.

## Statusline

PowerReview provides a statusline component showing PR number, iteration, review progress, draft counts, and per-file comment breakdown.

### Lualine

```lua
require("lualine").setup({
  sections = {
    lualine_x = {
      require("power-review.statusline").lualine(),
    },
  },
})
```

### Manual

```lua
local sl = require("power-review.statusline")
if sl.is_active() then
  print(sl.get())
end
```

## CLI Tool

The CLI handles all PR review business logic. The Neovim plugin calls it under the hood, but it also works standalone.

### CLI Commands

```
powerreview open --pr-url <url> [--repo-path <path>]
powerreview session --pr-url <url>
powerreview files --pr-url <url>
powerreview diff --pr-url <url> --file <path> [--format patch|metadata]
powerreview threads --pr-url <url> [--file <path>]
powerreview comment create|edit|delete|approve|approve-all|unapprove ...
powerreview reply --pr-url <url> --thread-id <n> --body <text>
powerreview submit --pr-url <url>
powerreview vote --pr-url <url> --value <value>
powerreview sync --pr-url <url>
powerreview close --pr-url <url>
powerreview sessions list|delete|clean
powerreview working-dir --pr-url <url>
powerreview read-file --pr-url <url> --file <path>
powerreview config --path-only
powerreview mark-reviewed --pr-url <url> --file <path>
powerreview unmark-reviewed --pr-url <url> --file <path>
powerreview mark-all-reviewed --pr-url <url>
powerreview check-iteration --pr-url <url>
powerreview iteration-diff --pr-url <url> --file <path>
powerreview resolve-thread --pr-url <url> --thread-id <n> --status <status>
powerreview fix-worktree prepare|cleanup|path|create-branch ...
powerreview proposal create|list|diff|approve|apply|reject|delete ...
powerreview mcp
```

All commands output JSON to stdout, errors to stderr. Exit codes: 0 = success, 1 = error, 2 = usage error.

`powerreview open` is idempotent. It returns `{ "action": "opened" | "refreshed", "session_file_path": "...", "session": ... }`; existing sessions are refreshed in place without creating another git worktree.

`powerreview diff` defaults to `--format patch` and returns `{ "file": ..., "diff": "..." }` with unified diff text generated from the local PR worktree. Use `--format metadata` to return only the changed-file record.

## MCP Server

Running `powerreview mcp` starts a stdio-based MCP server. No Neovim instance is required.

### Setup

Configure your AI tool's MCP settings (e.g. `.mcp.json`, Claude Desktop config, etc.):

```json
{
  "mcpServers": {
    "power-review": {
      "command": "powerreview",
      "args": ["mcp"]
    }
  }
}
```

### MCP Tools

| Tool | Parameters | Description |
|------|-----------|-------------|
| `GetReviewSession` | `prUrl` | Get session metadata (PR info, drafts, vote, derived counts) |
| `ListChangedFiles` | `prUrl` | List all changed files with change types |
| `GetFileDiff` | `prUrl`, `filePath` | Get unified diff for a specific file |
| `ListCommentThreads` | `prUrl`, `filePath?` | List remote threads and local drafts |
| `GetDraftCounts` | `prUrl` | Get draft operation counts by status and kind |
| `SyncThreads` | `prUrl` | Sync threads from remote + check for new iterations |
| `CheckIteration` | `prUrl` | Check for new PR iterations, apply smart reset |
| `GetIterationDiff` | `prUrl`, `filePath` | Get diff between reviewed iteration and current |
| `CreateComment` | `prUrl`, `filePath`, `lineStart`, `body`, ... | Create a draft comment (author=ai) |
| `EditDraftComment` | `prUrl`, `draftId`, `newBody` | Edit an AI-authored draft |
| `DeleteDraftComment` | `prUrl`, `draftId` | Delete an AI-authored draft |
| `ReplyToThread` | `prUrl`, `threadId`, `body` | Reply to an existing thread |
| `DraftThreadStatusChange` | `prUrl`, `threadId`, `status`, `reason?` | Create an approval-gated draft operation to change thread status |
| `DraftCommentReaction` | `prUrl`, `threadId`, `commentId`, `reaction` | Create an approval-gated draft operation to react to a comment |
| `GetWorkingDirectory` | `prUrl` | Get filesystem path to the PR working directory |
| `ReadFile` | `prUrl`, `filePath`, `offset?`, `limit?` | Read any file in the repository |
| `ListRepositoryFiles` | `prUrl`, `directory?`, `pattern?`, `recursive?` | List/discover files in the repository |
| `PrepareFixWorktree` | `prUrl` | Create an isolated worktree for AI code changes |
| `GetFixWorktreePath` | `prUrl` | Get the fix worktree filesystem path |
| `CreateFixBranch` | `prUrl`, `threadId` | Create a fix branch for a comment thread |
| `CreateProposal` | `prUrl`, `threadId`, `branchName`, `description`, ... | Register a proposed code fix |
| `ListProposals` | `prUrl` | List all proposals and their statuses |
| `GetProposalDiff` | `prUrl`, `proposalId` | Get the code diff for a proposed fix |

File access tools (`ReadFile`, `ListRepositoryFiles`, `GetWorkingDirectory`) let AI agents read any file in the repo for context -- not just files changed in the PR. All paths are security-validated to prevent access outside the repository root. MCP tools do not directly resolve threads or react to comments on the remote provider; they create draft operations that the user must approve before `submit` applies them remotely.

### Architecture

```
AI Agent <-> powerreview mcp (stdio) <-> PowerReview.Core (.NET)
                                       |
                              SessionStore (JSON files)
                                       |
           Neovim plugin (watches session files for real-time UI updates)
```

The MCP server operates standalone. The Neovim plugin picks up changes by watching session files on disk, so AI agents and the editor stay in sync automatically.

## File Watcher

When enabled (default), PowerReview watches the session JSON file using `vim.uv` filesystem events. When an AI agent modifies the session through the MCP server, the Neovim UI updates automatically -- signs refresh, panels update, and notifications appear for new AI drafts.

Configure via:

```lua
watcher = { enabled = true, debounce_ms = 200 },
notifications = {
  enabled = true,
  ai_activity = true,    -- AI creates/edits/deletes drafts
  sync_complete = true,  -- thread sync finished
  watcher = true,        -- external session changes
},
```

## Lua API

The public API is available at `require("power-review").api`:

```lua
local api = require("power-review").api

-- Files
api.get_changed_files()
api.get_file_diff(file_path)

-- Threads
api.get_all_threads()
api.get_threads_for_file(file_path)

-- Draft comments
api.create_draft_comment({
  file_path = "src/main.lua",
  line_start = 42,
  line_end = 45,       -- optional, for range comments
  body = "Consider...",
  author = "user",     -- "user" | "ai"
})
api.edit_draft_comment(draft_id, new_body)
api.delete_draft_comment(draft_id)
api.approve_draft(draft_id)
api.approve_all_drafts()
api.unapprove_draft(draft_id)

-- Submit
api.submit_pending(callback, progress_cb)
api.retry_failed_submissions(failed, callback)

-- Vote
api.set_vote(vote, callback)  -- 10=Approved, 5=Approved w/ suggestions, 0=No vote, -5=Wait, -10=Rejected

-- Session
api.get_review_session()
api.get_review_metadata()
api.reply_to_thread({ thread_id = id, body = "...", author = "user" })
api.sync_threads(callback)
api.close_review(callback)
```

## Architecture

```
PowerReview/
  plugin/power-review.lua         -- :PowerReview command registration
  lua/power-review/
    init.lua                      -- setup(), keymaps, public API
    config.lua                    -- UI-only configuration
    cli.lua                       -- CLI bridge (spawns process, parses JSON)
    session_helpers.lua           -- Pure data helpers
    types.lua                     -- LuaCATS type annotations
    review/init.lua               -- Review lifecycle (iterations, votes, reviewed files)
    store/init.lua                -- Session store (delegates to CLI)
    watcher.lua                   -- UV fs_event watcher for real-time AI sync
    notifications.lua             -- Categorized notification system
    statusline.lua                -- Lualine/statusline integration
    health.lua                    -- :checkhealth power-review
    ui/
      init.lua                    -- UI coordinator
      diff.lua                    -- Diff view (native vim diff, codediff.nvim, iteration diff)
      files_panel.lua             -- Built-in file list panel
      comment_float/              -- Floating comment editor with markdown preview
      comments_panel/             -- All-comments split panel with thread viewer
      drafts.lua                  -- Draft management panel
      sessions.lua                -- Session management panel
      description.lua             -- PR description floating viewer
      signs/                      -- Comment signs, extmarks, flash, navigation (7 modules)
    telescope/init.lua            -- Telescope pickers
    fzf_lua/init.lua              -- fzf-lua pickers with custom previewers
  lua/neo-tree/sources/power_review/
    init.lua, commands.lua, components.lua
  lua/telescope/_extensions/
    power_review.lua
  cli/
    PowerReview.slnx              -- .NET solution
    src/
      PowerReview.Core/           -- Core library (models, services, providers, auth, git, store)
      PowerReview.Cli/            -- Console app (.NET global tool)
        Commands/                 -- System.CommandLine CLI commands
        Mcp/                      -- MCP server (stdio, 23 tools)
    tests/
      PowerReview.Core.Tests/     -- xUnit tests
  skills/
    reviewing-prs/                -- AI agent instructions and MCP tool reference for PR review
    responding-to-comments/       -- AI agent instructions for responding to PR comments with code fixes
```

## Health Check

Run `:checkhealth power-review` to verify your setup. It checks:

- Neovim version (>= 0.10.0)
- CLI tool reachability
- .NET SDK availability
- Authentication (Azure CLI / PAT)
- Dependencies (nui.nvim, neo-tree, telescope, fzf-lua, codediff.nvim)
- Active session state
- File watcher status

## Roadmap

- [ ] Full GitHub provider implementation
- [ ] Additional diff providers (diffview.nvim)
- [ ] PR description editing
- [ ] CI/pipeline status integration
- [ ] Neovim UI for proposals (proposal panel, approve/reject/apply keymaps)
- [x] Proposed code fixes (AI agents respond to PR comments with code changes)
- [x] Fix worktree (isolated worktree for AI code changes)
- [x] fzf-lua picker support
- [x] Thread resolution/status management
- [x] File-level comments (not line-specific)
- [x] Native vim diff (default diff provider)
- [x] Iteration tracking with smart reset
- [x] Review progress tracking (per-file reviewed status)
- [x] File watcher for real-time AI sync
- [x] Statusline integration
- [x] PR description viewer
- [x] Notification system

## License

MIT
