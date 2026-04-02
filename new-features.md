# PowerReview.nvim -- New Features: Iteration & Review Tracking

This document covers the iteration and review tracking features added to PowerReview.nvim.
These features let you track your review progress per-file, detect when the PR author pushes
new changes (iterations), and see exactly what changed since your last review.

---

## Overview

When reviewing a pull request, the PR author often pushes follow-up commits in response to
feedback. Each push creates a new **iteration**. Without tracking, you'd have to re-review
every file from scratch. These features solve that:

- **Per-file review marking** -- Mark individual files as "reviewed" with a single keypress.
- **Iteration detection** -- Automatically detect (or manually check) when new iterations arrive.
- **Smart reset** -- When a new iteration is found, only files that actually changed lose
  their "reviewed" status. Files with no changes keep their mark.
- **Iteration diff** -- View a side-by-side diff of what changed between your last review
  and the current iteration for any file.
- **Visual indicators** -- All file list UIs show review status icons next to each file.
- **Statusline** -- Iteration number and review progress appear in your statusline.

---

## How It Works

### Review State

The session file (v4 schema) stores a `review` object:

```json
{
  "review": {
    "reviewed_iteration_id": 2,
    "reviewed_source_commit": "abc123...",
    "reviewed_files": ["src/validators/user.lua", "src/utils/helper.lua"],
    "changed_since_review": ["src/handlers/register.lua"]
  }
}
```

- `reviewed_files` -- files you've explicitly marked as reviewed.
- `changed_since_review` -- files the smart reset identified as changed in the latest iteration.
- `reviewed_iteration_id` / `reviewed_source_commit` -- your last review checkpoint.

### Smart Reset Algorithm

When a new iteration is detected:

1. The system runs `git diff --name-only <old_commit> <new_commit>` to find which files
   actually changed between iterations.
2. Files that changed are added to `changed_since_review` and removed from `reviewed_files`.
3. Files that did **not** change keep their "reviewed" mark.

This means you only need to re-review the files that actually have new code.

### Iteration Diff

The iteration diff view opens a new tab with two readonly panes:

- **Left pane**: file content at the previously-reviewed commit
- **Right pane**: file content at the current commit

Both panes use Neovim's native diff mode with subtle highlight colors. Press `q` to close.

---

## CLI Commands

All iteration commands are subcommands of the PowerReview CLI. Replace `<pr-url>` with
your pull request URL.

### Mark a file as reviewed

```sh
dnx PowerReview -- mark-reviewed --pr-url <pr-url> --file <path>
```

Adds the file to `reviewed_files`. Returns JSON with the updated review state.

### Unmark a file

```sh
dnx PowerReview -- unmark-reviewed --pr-url <pr-url> --file <path>
```

Removes the file from `reviewed_files`.

### Mark all files as reviewed

```sh
dnx PowerReview -- mark-all-reviewed --pr-url <pr-url>
```

Adds every changed file in the PR to `reviewed_files`.

### Check for new iterations

```sh
dnx PowerReview -- check-iteration --pr-url <pr-url>
```

Queries the remote provider (AzDO) for the latest iteration. If a new one is found,
performs a smart reset automatically. Returns JSON:

```json
{
  "has_new_iteration": true,
  "old_iteration_id": 2,
  "new_iteration_id": 3,
  "changed_files": ["src/handlers/register.lua"]
}
```

### Get iteration diff for a file

```sh
dnx PowerReview -- iteration-diff --pr-url <pr-url> --file <path>
```

Returns the diff content between the previously-reviewed commit and the current commit
for the specified file. This is the data the Neovim plugin uses for the iteration diff view.

### Sync (with automatic iteration check)

The existing `sync` command now also checks for new iterations:

```sh
dnx PowerReview -- sync --pr-url <pr-url>
```

The returned `SyncResult` includes an `iteration_check` field alongside the thread count.
If a new iteration is found during sync, the smart reset runs automatically and a
notification appears in Neovim.

---

## Neovim Usage

### User Commands

All iteration commands are available as `:PowerReview` subcommands:

| Command | Description |
|---------|-------------|
| `:PowerReview mark_reviewed [file]` | Mark a file as reviewed. Defaults to the current buffer's file if omitted. |
| `:PowerReview unmark_reviewed [file]` | Remove the reviewed mark from a file. |
| `:PowerReview mark_all_reviewed` | Mark every changed file in the PR as reviewed. |
| `:PowerReview check_iteration` | Check the remote for new iterations. Notifies and smart-resets if found. |
| `:PowerReview iteration_diff [file]` | Open a side-by-side diff showing what changed between iterations. |

### Global Keymaps

These keymaps are available in any buffer when a review session is active:

| Keymap | Action | Description |
|--------|--------|-------------|
| `<leader>pm` | Toggle reviewed | Marks/unmarks the current buffer's file as reviewed. |
| `<leader>pM` | Mark all reviewed | Marks all changed files as reviewed at once. |
| `<leader>pI` | Check iteration | Checks the remote for new iterations. |
| `<leader>pn` | Iteration diff | Opens the iteration diff for the current buffer's file. |

All keymaps are configurable via `require("power-review").setup({ keymaps = { ... } })`.

### File List UI Keymaps

Review actions are available directly in all file list UIs:

**Neo-tree (`power_review` source)**

| Key | Action |
|-----|--------|
| `v` | Toggle reviewed status on the selected file |
| `V` | Mark all files as reviewed |

Add these to your Neo-tree config:

```lua
require("neo-tree").setup({
  sources = { "filesystem", "power_review" },
  power_review = {
    window = {
      mappings = {
        ["v"] = "toggle_reviewed",
        ["V"] = "mark_all_reviewed",
      },
    },
    renderers = {
      pr_root = {
        { "indent" }, { "icon" }, { "name" }, { "comment_count" }, { "review_status" },
      },
      pr_dir = {
        { "indent" }, { "icon" }, { "name" }, { "review_status" },
      },
      pr_file = {
        { "indent" }, { "icon" }, { "name" }, { "comment_count" }, { "review_status" },
      },
    },
  },
})
```

**Builtin panel (NuiTree)**

| Key | Action |
|-----|--------|
| `v` | Toggle reviewed status on the selected file |
| `V` | Mark all files as reviewed |

Review indicators appear automatically. No extra configuration needed.

**Telescope picker**

| Key | Action |
|-----|--------|
| `<C-v>` | Toggle reviewed status (works in both normal and insert mode) |

The picker prompt shows review progress: `Changed Files [2/5 ●1]` (2 of 5 reviewed,
1 changed since review). The picker refreshes in-place after toggling.

**fzf-lua picker**

| Key | Action |
|-----|--------|
| `ctrl-v` | Toggle reviewed status |

The picker reopens after toggling to show updated status. Progress is shown in the prompt.

### Visual Indicators

All file list UIs (Neo-tree, builtin panel, Telescope, fzf-lua) display status icons:

| Icon | Highlight Group | Meaning |
|------|-----------------|---------|
| `✓` | `PowerReviewReviewed` | File has been marked as reviewed |
| `●` | `PowerReviewChangedSinceReview` | File has changed since your last review (needs re-review) |
| *(none)* | | File has not been reviewed yet |

Default highlight colors:

- `PowerReviewReviewed` -- green (reviewed, no action needed)
- `PowerReviewChangedSinceReview` -- orange/yellow (changed, needs attention)
- `PowerReviewUnreviewed` -- dimmed/grey (not yet reviewed)

### Statusline

The statusline component now includes iteration and review progress:

```
 PR #42 #3 [4/7 ●2] [1 draft]
```

- `#3` -- current reviewed iteration number
- `[4/7 ●2]` -- 4 of 7 files reviewed, 2 files changed since review
- Draft counts and per-file comment counts continue to work as before.

#### Lualine setup (unchanged)

```lua
require("lualine").setup({
  sections = {
    lualine_x = {
      require("power-review.statusline").lualine(),
    },
  },
})
```

#### Manual statusline

```lua
-- Returns formatted string, empty when no session is active
require("power-review.statusline").get()

-- Check if a review session is active (use as condition)
require("power-review.statusline").is_active()
```

---

## Typical Workflow

1. **Open a review**: `:PowerReview open <pr-url>`

2. **Review files**: Open diffs, read code, leave comments as usual.

3. **Mark files as reviewed**: As you finish each file, press `v` in the file list
   (or `<C-v>` in Telescope/fzf-lua, or `<leader>pm` from any buffer).

4. **Track progress**: Watch the review progress in your statusline (`[3/7]`)
   and the `✓` icons in file lists.

5. **Author pushes new changes**: The PR author addresses your feedback and pushes.

6. **Detect the new iteration**: Either:
   - Run `:PowerReview sync` (auto-detects during thread sync), or
   - Run `:PowerReview check_iteration` (or press `<leader>pI`).

7. **Smart reset happens**: Files that changed get a `●` icon and lose their reviewed
   mark. Files that didn't change keep their `✓`.

8. **Review only what changed**: Focus on files with `●`. Open iteration diffs with
   `<leader>pn` or `:PowerReview iteration_diff` to see exactly what the author changed.

9. **Re-mark as reviewed**: Mark the changed files as reviewed once you've verified them.

10. **Repeat** as the author pushes more iterations.

---

## Configuration

All keymaps can be customized in setup:

```lua
require("power-review").setup({
  keymaps = {
    mark_reviewed = "<leader>pm",       -- toggle reviewed on current file
    mark_all_reviewed = "<leader>pM",   -- mark all files reviewed
    check_iteration = "<leader>pI",     -- check for new iterations
    iteration_diff = "<leader>pn",      -- open iteration diff
  },
})
```

Set any keymap to `false` to disable it.

---

## Session Schema Changes

The session file schema has been bumped from **v3 to v4**. The only addition is the
`review` object at the top level. Existing v3 sessions are migrated automatically --
an empty `ReviewState` is inserted with no reviewed files and no change tracking.

See `doc/session-schema.md` for the full v4 specification.

---

## Architecture Notes (for developers)

### CLI-first design

All review state mutations go through the .NET CLI tool:

```
Neovim (Lua) --spawn--> CLI (C#) --mutate--> session.json
                                       |
                              git diff --name-only
                                       |
                              AzDO API (iterations)
```

The Lua side is a pure UI layer. It calls CLI commands, reloads the session JSON,
and refreshes UI components. No business logic lives in Lua.

### Key C# types

| Type | File | Purpose |
|------|------|---------|
| `ReviewState` | `Models/CommonModels.cs` | Persisted review tracking data |
| `ReviewSession` | `Models/ReviewSession.cs` | Top-level session (v4, includes `Review` property) |
| `SessionMigration` | `Store/SessionMigration.cs` | v3 -> v4 migration logic |
| `ReviewService` | `Services/ReviewService.cs` | Core methods: mark/unmark, check iteration, smart reset |
| `CommandBuilder` | `Commands/CommandBuilder.cs` | CLI command definitions |

### Key Lua modules

| Module | File | Purpose |
|--------|------|---------|
| `cli` | `lua/power-review/cli.lua` | CLI bridge: spawns commands, adapts JSON |
| `review` | `lua/power-review/review/init.lua` | Review lifecycle coordinator |
| `session_helpers` | `lua/power-review/session_helpers.lua` | Pure data-access helpers for review state |
| `diff` | `lua/power-review/ui/diff.lua` | Diff view including `open_iteration_diff` |
| `statusline` | `lua/power-review/statusline.lua` | Statusline with iteration/review progress |
| `config` | `lua/power-review/config.lua` | Default keymaps and recommended Neo-tree config |

### Key Lua helper functions (session_helpers)

```lua
local helpers = require("power-review.session_helpers")

-- Check if a specific file is marked as reviewed
helpers.is_file_reviewed(session, file_path)  --> boolean

-- Check if a file has changes since the last review
helpers.is_file_changed_since_review(session, file_path)  --> boolean

-- Get display status and icon for a file
helpers.get_file_review_status(session, file_path)  --> status, icon
-- Returns: ("reviewed", "✓"), ("changed", "●"), or ("unreviewed", "")

-- Get overall review progress counts
helpers.get_review_progress(session)
-- Returns: { reviewed = 3, changed = 1, unreviewed = 3, total = 7 }
```

### UI integration points

Review indicators are rendered in 5 file list UIs:

1. **Neo-tree** -- `review_status` component in `components.lua`, `toggle_reviewed` / `mark_all_reviewed` commands in `commands.lua`
2. **Builtin panel** -- Review prefix in `prepare_node` callback, `v`/`V` keymaps in `files_panel.lua`
3. **Telescope** -- Status prefix in display string, `<C-v>` mapping in `telescope/init.lua`
4. **fzf-lua** -- Status prefix in display string, `ctrl-v` action in `fzf_lua/init.lua`
5. **Quickfix** -- Falls back to the standard file list (no review icons in quickfix)

### Highlight groups

Three new highlight groups are defined for review indicators:

| Group | Default | Used for |
|-------|---------|----------|
| `PowerReviewReviewed` | Green foreground | `✓` reviewed icon |
| `PowerReviewChangedSinceReview` | Orange foreground | `●` changed icon |
| `PowerReviewUnreviewed` | Grey foreground | Unreviewed files (dimmed) |

These are set with `default = true`, so your colorscheme or user config can override them.
