# PowerReview Session File Schema (v6)

This document defines the JSON schema for PowerReview session state files as stored by the CLI tool.
External tools that create or consume these files **must** conform to this specification.

> **Neovim adapter**: The CLI outputs v4 (nested) JSON. The Neovim plugin's `cli.adapt_session()` converts
> this to a flat v2-compatible shape for UI code. See `lua/power-review/cli.lua` for the mapping.

## File Location

Session files are managed by the CLI and stored at:

```
{data_dir}/sessions/{session_id}.json
```

The data directory is resolved in this order:

1. `data_dir` field in CLI's `powerreview.json`
2. `$XDG_DATA_HOME/PowerReview`
3. Windows: `%LOCALAPPDATA%\PowerReview`; Linux/Mac: `~/.local/share/PowerReview`

Run `dnx PowerReview -- config --path-only` to see the resolved config path.

### Session ID

The `session_id` is constructed as:

```
{provider}_{org}_{project}_{repo}_{pr_id}
```

All characters are lowercased and non-alphanumeric, non-hyphen characters are replaced with underscores.

Example: `azdo_my-org_my-project_my-repo_42` produces the file `azdo_my-org_my-project_my-repo_42.json`.

Writes are atomic: data is written to a `.tmp` file first, then renamed to the final `.json` path.

---

## Top-Level Object: `ReviewSession`

The v6 format uses a nested structure with logical groupings.

| Field          | Type                             | Required | Description                                           |
|----------------|----------------------------------|----------|-------------------------------------------------------|
| `version`      | `number`                         | yes      | Schema version. Must be `6`.                          |
| `id`           | `string`                         | yes      | Session identifier.                                   |
| `provider`     | `ProviderInfo`                   | yes      | Provider metadata.                                    |
| `pull_request` | `PullRequestInfo`                | yes      | PR metadata.                                          |
| `iteration`    | `IterationMeta`                  | no       | Iteration tracking for incremental sync.              |
| `review`       | `ReviewState`                    | no       | Per-file review tracking and iteration change state.  |
| `git`          | `GitInfo`                        | yes      | Git workspace state.                                  |
| `files`        | `ChangedFile[]`                  | yes      | List of files changed in the PR.                      |
| `threads`      | `ThreadsInfo`                    | yes      | Remote comment threads.                               |
| `drafts`       | `object`                         | yes      | Local draft comments. Map of `{uuid: DraftComment}`.  |
| `proposals`    | `object`                         | yes      | Proposed code fixes. Map of `{uuid: ProposedFix}`.    |
| `fix_worktree` | `FixWorktreeInfo \| null`        | no       | Fix worktree info for AI code changes, or `null`.     |
| `metadata`     | `ReviewMetadata`                 | yes      | Derived metadata summaries for UI and AI agents.      |
| `vote`         | `string \| null`                 | yes      | Review vote enum string, or `null`.                   |
| `created_at`   | `string`                         | yes      | ISO 8601 UTC timestamp of session creation.           |
| `updated_at`   | `string`                         | yes      | ISO 8601 UTC timestamp of last modification.          |

---

## `ReviewMetadata` Object

Derived counts and normalized labels useful for UI and AI agents. Recomputed by the CLI when sessions are saved or loaded.

| Field        | Type     | Description                                      |
|--------------|----------|--------------------------------------------------|
| `reviewers`  | `object` | Reviewer totals by required/vote state.          |
| `files`      | `object` | Changed-file totals by change type.              |
| `threads`    | `object` | Thread totals by status and location level.      |
| `drafts`     | `object` | Draft totals by status and author type.          |
| `work_items` | `object` | Work item totals by type/state.                  |
| `review`     | `object` | File review progress counts.                     |
| `iteration`  | `object` | Current and reviewed iteration commit metadata.  |
| `state`      | `object` | PR state, merge conflict flag, vote label.       |
| `timestamps` | `object` | Session, PR, and thread sync timestamps.         |

### String Formats

- **Timestamps**: ISO 8601 UTC format `YYYY-MM-DDTHH:MM:SSZ`.
- **UUIDs** (draft keys): Version 4 UUID, e.g. `"a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d"`.
- **Commit SHAs**: Full 40-character hex SHA.
- **Enums**: Serialized as lowercase strings (e.g. `"approved"`, `"active"`, `"worktree"`).
- **Nulls**: Omitted from serialized output.

---

## `ProviderInfo` Object

| Field          | Type     | Required | Description                                          |
|----------------|----------|----------|------------------------------------------------------|
| `type`         | `string` | yes      | Provider type: `"azdo"` or `"github"`.               |
| `organization` | `string` | yes      | Organization (AzDO) or repository owner (GitHub).    |
| `project`      | `string` | yes      | Project (AzDO) or repository name (GitHub).          |
| `repository`   | `string` | yes      | Repository name.                                     |

---

## `PullRequestInfo` Object

| Field           | Type                | Required | Description                                                |
|-----------------|---------------------|----------|------------------------------------------------------------|
| `id`            | `number`            | yes      | Pull request number from the provider.                     |
| `url`           | `string`            | yes      | Original PR URL.                                           |
| `title`         | `string`            | yes      | Pull request title.                                        |
| `description`   | `string`            | yes      | Pull request description (markdown).                       |
| `author`        | `PersonIdentity`    | yes      | PR author identity.                                        |
| `status`        | `string`            | yes      | PR lifecycle status. See PR Status Values.                 |
| `is_draft`      | `boolean`           | yes      | Whether the PR is a draft / work-in-progress.              |
| `closed_at`     | `string \| null`    | no       | ISO 8601 UTC timestamp of PR closure/completion.           |
| `source_branch` | `string`            | yes      | Source / feature branch name.                              |
| `target_branch` | `string`            | yes      | Target / base branch name.                                 |
| `merge_status`  | `string \| null`    | no       | Merge feasibility status. See Merge Status Values.         |
| `reviewers`     | `Reviewer[]`        | yes      | List of PR reviewers with their votes.                     |
| `labels`        | `string[]`          | yes      | PR labels / tags.                                          |
| `work_items`    | `WorkItem[]`        | yes      | Linked work items / issues.                                |

### `PersonIdentity` Object

| Field           | Type             | Required | Description                                    |
|-----------------|------------------|----------|------------------------------------------------|
| `name`          | `string`         | yes      | Display name.                                  |
| `id`            | `string \| null` | no       | Provider-assigned ID.                          |
| `unique_name`   | `string \| null` | no       | Email or login.                                |

### PR Status Values

| Value         | Description                            |
|---------------|----------------------------------------|
| `"active"`    | Open and reviewable.                   |
| `"completed"` | Merged / completed.                   |
| `"abandoned"` | Closed without merging.                |

### Merge Status Values

| Value         | Description                            |
|---------------|----------------------------------------|
| `"succeeded"` | Merge will succeed cleanly.            |
| `"conflicts"` | Merge has conflicts.                   |
| `"queued"`    | Merge evaluation is queued.            |
| `"notSet"`    | Not yet evaluated.                     |
| `"failure"`   | Merge failed.                          |
| `null`        | Not available from the provider.       |

---

## `IterationMeta` Object

Tracks the iteration state for incremental sync.

| Field           | Type             | Required | Description                                    |
|-----------------|------------------|----------|------------------------------------------------|
| `id`            | `number \| null` | no       | Latest iteration ID the session was synced to. |
| `source_commit` | `string \| null` | no       | Source branch commit SHA at last sync.         |
| `target_commit` | `string \| null` | no       | Target branch commit SHA at last sync.         |

---

## `ReviewState` Object

Tracks per-file review status and iteration change detection. This enables the reviewer to
mark files as reviewed, detect when new iterations arrive, and perform smart resets that only
unmark files that actually changed between iterations.

| Field                   | Type             | Required | Description                                                                  |
|-------------------------|------------------|----------|------------------------------------------------------------------------------|
| `reviewed_iteration_id` | `number \| null` | no       | Iteration ID the reviewer last reviewed against. `null` if no review started.|
| `reviewed_source_commit`| `string \| null` | no       | Source branch commit SHA at the time of the last review pass.                |
| `reviewed_files`        | `string[]`       | yes      | File paths explicitly marked as reviewed in the current iteration.           |
| `changed_since_review`  | `string[]`       | yes      | File paths that changed since the last reviewed iteration (via git diff).    |

When a new iteration is detected (via `check-iteration` or during `sync`), the system:

1. Compares the new source commit against `reviewed_source_commit` using `git diff --name-only`.
2. Populates `changed_since_review` with the list of changed file paths.
3. Removes any files in `reviewed_files` that appear in `changed_since_review` (smart reset).
4. Updates `reviewed_iteration_id` and `reviewed_source_commit` to the new iteration's values.

Files that were not modified between iterations retain their "reviewed" mark.

### Example

```json
{
  "reviewed_iteration_id": 3,
  "reviewed_source_commit": "abc123def456789012345678901234567890abcd",
  "reviewed_files": ["src/validators/user.lua"],
  "changed_since_review": ["src/handlers/register.lua"]
}
```

---

## `GitInfo` Object

| Field           | Type             | Required | Description                                                    |
|-----------------|------------------|----------|----------------------------------------------------------------|
| `repo_path`     | `string \| null` | no       | Filesystem path to the main git repository, or `null`.         |
| `worktree_path` | `string \| null` | no       | Filesystem path to the git worktree, or `null`.                |
| `strategy`      | `string`         | yes      | Git strategy used. See Git Strategy Values.                    |

### Git Strategy Values

| Value            | Description                                                    |
|------------------|----------------------------------------------------------------|
| `"worktree"`     | A dedicated git worktree was created for the review.           |
| `"clone"`        | The repository was cloned for the review.                      |
| `"cwd"`          | The current working directory is used directly.                |

---

## `ThreadsInfo` Object

| Field           | Type               | Required | Description                              |
|-----------------|--------------------|----------|------------------------------------------|
| `items`         | `CommentThread[]`  | yes      | Array of remote comment threads.         |
| `synced_at`     | `string \| null`   | no       | ISO 8601 UTC timestamp of last sync.     |

---

## Vote Values

The `vote` field is a string enum (or `null`):

| Value                       | Meaning                  |
|-----------------------------|--------------------------|
| `"approved"`                | Approved                 |
| `"approved_with_suggestions"` | Approved with suggestions |
| `"no_vote"`                 | No vote / reset          |
| `"wait_for_author"`         | Wait for author          |
| `"rejected"`                | Rejected                 |
| `null`                      | Not yet voted            |

> **Neovim adapter mapping**: The `cli.adapt_session()` function converts these strings to numeric values
> for UI code compatibility: `approved`=10, `approved_with_suggestions`=5, `no_vote`=0,
> `wait_for_author`=-5, `rejected`=-10.

---

## `Reviewer` Object

| Field         | Type             | Required | Description                                          |
|---------------|------------------|----------|------------------------------------------------------|
| `name`        | `string`         | yes      | Display name of the reviewer.                        |
| `id`          | `string \| null` | no       | Provider-assigned reviewer ID.                       |
| `unique_name` | `string \| null` | no       | Reviewer email or login.                             |
| `vote`        | `number \| null` | yes      | Review vote (integer). See Vote Values.          |
| `is_required` | `boolean`        | yes      | Whether the reviewer is a required reviewer.         |

### Example

```json
{
  "name": "Alice Smith",
  "id": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
  "unique_name": "alice@example.com",
  "vote": 10,
  "is_required": true
}
```

---

## `WorkItem` Object

| Field   | Type             | Required | Description                                          |
|---------|------------------|----------|------------------------------------------------------|
| `id`    | `number`         | yes      | Work item / issue ID.                                |
| `title` | `string \| null` | no       | Work item title.                                     |
| `url`   | `string \| null` | no       | Web URL to the work item.                            |

### Example

```json
{
  "id": 1234,
  "title": "Implement input validation",
  "url": "https://dev.azure.com/my-org/my-project/_workitems/edit/1234"
}
```

---

## `ChangedFile` Object

| Field           | Type             | Required | Description                                          |
|-----------------|------------------|----------|------------------------------------------------------|
| `path`          | `string`         | yes      | Relative file path.                                  |
| `original_path` | `string \| null`| no       | Original path before rename.                         |
| `change_type`   | `string`         | yes      | `"add"`, `"edit"`, `"delete"`, or `"rename"`.        |

### Example

```json
{
  "path": "src/utils/helper.lua",
  "change_type": "edit"
}
```

---

## `CommentThread` Object

A comment thread fetched from the provider and cached locally.

| Field             | Type             | Required | Description                                                             |
|-------------------|------------------|----------|-------------------------------------------------------------------------|
| `id`              | `number`         | yes      | Provider-assigned thread ID.                                            |
| `file_path`       | `string \| null` | yes      | Relative file path. `null` for PR-level threads.                        |
| `line_start`      | `number \| null` | yes      | Start line (1-indexed, right/source side).                              |
| `line_end`        | `number \| null` | yes      | End line (1-indexed, right/source side).                                |
| `col_start`       | `number \| null` | yes      | Start column (1-indexed byte offset).                                   |
| `col_end`         | `number \| null` | yes      | End column (1-indexed byte offset).                                     |
| `left_line_start` | `number \| null` | no       | Start line on the base/target side (for deleted code comments).         |
| `left_line_end`   | `number \| null` | no       | End line on the base/target side.                                       |
| `status`          | `string`         | yes      | Thread status. See Thread Status Values.                                |
| `is_deleted`      | `boolean`        | yes      | Whether the thread has been soft-deleted.                               |
| `published_at`    | `string \| null` | no       | ISO 8601 UTC timestamp of thread creation.                              |
| `updated_at`      | `string \| null` | no       | ISO 8601 UTC timestamp of last thread update.                           |
| `comments`        | `Comment[]`      | yes      | Ordered list of comments in the thread.                                 |

### Thread Status Values

| Value        | Description                          |
|--------------|--------------------------------------|
| `"active"`   | Open, unresolved thread.             |
| `"fixed"`    | Resolved as fixed.                   |
| `"wontfix"`  | Resolved as won't fix.               |
| `"closed"`   | Closed.                              |
| `"bydesign"` | Resolved as by design.               |
| `"pending"`  | Pending resolution.                  |

### Example

```json
{
  "id": 12345,
  "file_path": "src/main.lua",
  "line_start": 42,
  "line_end": 45,
  "status": "active",
  "is_deleted": false,
  "published_at": "2026-03-26T08:00:00Z",
  "updated_at": "2026-03-26T09:15:00Z",
  "comments": [
    {
      "id": 67890,
      "thread_id": 12345,
      "author": {
        "name": "Jane Smith",
        "id": "b2c3d4e5-f6a7-8901-bcde-f12345678901",
        "unique_name": "jane@example.com"
      },
      "body": "Consider using `pcall` here for error safety.",
      "created_at": "2026-03-26T08:00:00Z",
      "updated_at": "2026-03-26T09:15:00Z",
      "is_deleted": false
    }
  ]
}
```

---

## `Comment` Object

A single comment within a `CommentThread`.

| Field               | Type             | Required | Description                                    |
|---------------------|------------------|----------|------------------------------------------------|
| `id`                | `number`         | yes      | Provider-assigned comment ID.                  |
| `thread_id`         | `number`         | yes      | Parent thread ID.                              |
| `author`            | `PersonIdentity` | yes      | Comment author identity.                       |
| `parent_comment_id` | `number \| null` | no       | Parent comment ID for nested replies.          |
| `body`              | `string`         | yes      | Comment content (markdown).                    |
| `created_at`        | `string`         | yes      | ISO 8601 UTC timestamp of creation.            |
| `updated_at`        | `string`         | yes      | ISO 8601 UTC timestamp of last edit.           |
| `is_deleted`        | `boolean`        | yes      | Whether the comment has been soft-deleted.     |

---

## `DraftComment` Object

A locally-created comment not yet submitted to the provider. Stored as values in the `drafts` map, keyed by UUID.

Drafts follow a strict lifecycle: `draft` -> `pending` -> `submitted`.

| Field               | Type             | Required | Description                                                                  |
|---------------------|------------------|----------|------------------------------------------------------------------------------|
| `file_path`         | `string`         | yes      | Relative file path the comment targets.                                      |
| `line_start`        | `number`         | yes      | Start line number (1-indexed).                                               |
| `line_end`          | `number \| null` | yes      | End line for multi-line range comments.                                      |
| `col_start`         | `number \| null` | yes      | Start column (1-indexed byte offset).                                        |
| `col_end`           | `number \| null` | yes      | End column (1-indexed byte offset).                                          |
| `body`              | `string`         | yes      | Comment content (markdown).                                                  |
| `status`            | `string`         | yes      | Draft lifecycle status. See Draft Status Values.                             |
| `author`            | `string`         | yes      | Who created the draft. See Draft Author Values.                              |
| `author_name`       | `string \| null` | no       | Display name of the agent or person (e.g. "SecurityReviewer").               |
| `thread_id`         | `number \| null` | yes      | Remote thread ID when replying, or `null` for new threads.                   |
| `parent_comment_id` | `number \| null` | yes      | Specific comment being replied to, or `null`.                                |
| `created_at`        | `string`         | yes      | ISO 8601 UTC timestamp.                                                      |
| `updated_at`        | `string`         | yes      | ISO 8601 UTC timestamp.                                                      |

> **Note**: The draft's UUID is the *key* in the `drafts` map, not a field in the object itself.
> The Neovim adapter adds it as `draft.id` when converting to the flat array format.

### Draft Status Values

| Value         | Description                                              |
|---------------|----------------------------------------------------------|
| `"draft"`     | Editable. Can be modified or deleted.                    |
| `"pending"`   | Approved by the user, ready for submission. Immutable.   |
| `"submitted"` | Sent to the remote provider. Immutable.                  |

### Draft Author Values

| Value    | Description                          |
|----------|--------------------------------------|
| `"user"` | Created by the human reviewer.       |
| `"ai"`   | Generated by an LLM / AI assistant.  |

### Example

In the `drafts` map:

```json
{
  "a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d": {
    "file_path": "src/main.lua",
    "line_start": 42,
    "body": "This function should be refactored to reduce complexity.",
    "status": "draft",
    "author": "ai",
    "created_at": "2026-03-27T11:00:00Z",
    "updated_at": "2026-03-27T11:30:00Z"
  }
}
```

---

## `ProposedFix` Object

A proposed code fix created by an AI agent in response to a PR comment. Stored as values in the `proposals` map, keyed by UUID. Each proposal represents code changes on a temporary branch that must be approved before being applied (merged into the PR source branch).

Proposals follow a lifecycle: `draft` -> `approved` -> `applied` (or `rejected`).

| Field               | Type             | Required | Description                                                                  |
|---------------------|------------------|----------|------------------------------------------------------------------------------|
| `thread_id`         | `number`         | yes      | Remote thread ID this proposal responds to.                                  |
| `description`       | `string`         | yes      | Human-readable description of what the fix does.                             |
| `status`            | `string`         | yes      | Proposal lifecycle status. See Proposal Status Values.                       |
| `author`            | `string`         | yes      | Who created the proposal. See Draft Author Values.                           |
| `author_name`       | `string \| null` | no       | Display name of the agent (e.g. "CodeFixer").                                |
| `branch_name`       | `string`         | yes      | Temporary branch holding the fix commits (e.g. `powerreview/fix/thread-42`). |
| `files_changed`     | `string[]`       | yes      | List of file paths modified by this fix.                                     |
| `reply_draft_id`    | `string \| null` | no       | UUID of a linked draft reply. Auto-approved when proposal is approved.       |
| `created_at`        | `string`         | yes      | ISO 8601 UTC timestamp.                                                      |
| `updated_at`        | `string`         | yes      | ISO 8601 UTC timestamp.                                                      |

> **Note**: The proposal's UUID is the *key* in the `proposals` map, not a field in the object itself.

### Proposal Status Values

| Value         | Description                                                        |
|---------------|--------------------------------------------------------------------|
| `"draft"`     | AI-created, awaiting user review. Can be modified or deleted.      |
| `"approved"`  | Approved by the user, ready to be applied (merged into PR branch). |
| `"applied"`   | Successfully applied (cherry-picked into the PR source branch).    |
| `"rejected"`  | Rejected by the user. Can be deleted.                              |

### Example

In the `proposals` map:

```json
{
  "b2c3d4e5-f6a7-4b8c-9d0e-1f2a3b4c5d6e": {
    "thread_id": 100,
    "description": "Added null check for user input as requested",
    "status": "draft",
    "author": "ai",
    "author_name": "CodeFixer",
    "branch_name": "powerreview/fix/thread-100",
    "files_changed": ["src/handlers/register.lua"],
    "reply_draft_id": "a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d",
    "created_at": "2026-03-27T13:00:00Z",
    "updated_at": "2026-03-27T13:00:00Z"
  }
}
```

---

## `FixWorktreeInfo` Object

Information about the isolated fix worktree used by AI agents to make code changes without affecting the user's working directory. One worktree per PR, reused across all fixes.

| Field           | Type     | Required | Description                                              |
|-----------------|----------|----------|----------------------------------------------------------|
| `path`          | `string` | yes      | Filesystem path to the fix worktree directory.            |
| `base_branch`   | `string` | yes      | The PR source branch this worktree was created from.      |
| `created_at`    | `string` | yes      | ISO 8601 UTC timestamp of worktree creation.              |

### Example

```json
{
  "path": "/home/user/projects/my-repo/.power-review-fixes/42",
  "base_branch": "feature/user-validation",
  "created_at": "2026-03-27T13:00:00Z"
}
```

---

## Full Example

A complete v6 session file:

```json
{
  "version": 5,
  "id": "azdo_my-org_my-project_my-repo_42",
  "provider": {
    "type": "azdo",
    "organization": "my-org",
    "project": "my-project",
    "repository": "my-repo"
  },
  "pull_request": {
    "id": 42,
    "url": "https://dev.azure.com/my-org/my-project/_git/my-repo/pullrequest/42",
    "title": "Add input validation to user registration",
    "description": "This PR adds server-side validation for the user registration endpoint.",
    "author": {
      "name": "John Doe",
      "id": "c3d4e5f6-a7b8-9012-cdef-3456789abcde",
      "unique_name": "john@example.com"
    },
    "status": "active",
    "is_draft": false,
    "source_branch": "feature/user-validation",
    "target_branch": "main",
    "merge_status": "succeeded",
    "reviewers": [
      {
        "name": "Alice Smith",
        "id": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
        "unique_name": "alice@example.com",
        "is_required": true
      },
      {
        "name": "Bob Jones",
        "id": "f6a7b8c9-d0e1-2345-6789-0abcdef12345",
        "unique_name": "bob@example.com",
        "vote": 5,
        "is_required": false
      }
    ],
    "labels": ["backend", "validation"],
    "work_items": [
      {
        "id": 1234,
        "title": "Implement input validation",
        "url": "https://dev.azure.com/my-org/my-project/_workitems/edit/1234"
      }
    ]
  },
  "iteration": {
    "id": 3,
    "source_commit": "abc123def456789012345678901234567890abcd",
    "target_commit": "def456abc789012345678901234567890abcd1234"
  },
  "review": {
    "reviewed_iteration_id": 2,
    "reviewed_source_commit": "999888def456789012345678901234567890ffff",
    "reviewed_files": ["src/validators/user.lua"],
    "changed_since_review": ["src/handlers/register.lua"]
  },
  "git": {
    "repo_path": "/home/user/projects/my-repo",
    "strategy": "worktree",
    "worktree_path": "/home/user/projects/my-repo/.power-review-worktrees/42"
  },
  "files": [
    {
      "path": "src/handlers/register.lua",
      "change_type": "edit"
    },
    {
      "path": "src/validators/user.lua",
      "change_type": "add"
    },
    {
      "path": "src/old_validator.lua",
      "change_type": "delete"
    }
  ],
  "threads": {
    "items": [
      {
        "id": 100,
        "file_path": "src/handlers/register.lua",
        "line_start": 18,
        "line_end": 22,
        "status": "active",
        "is_deleted": false,
        "published_at": "2026-03-27T10:30:00Z",
        "updated_at": "2026-03-27T11:00:00Z",
        "comments": [
          {
            "id": 200,
            "thread_id": 100,
            "author": {
              "name": "Alice Smith",
              "id": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
              "unique_name": "alice@example.com"
            },
            "body": "Should we add rate limiting here?",
            "created_at": "2026-03-27T10:30:00Z",
            "updated_at": "2026-03-27T10:30:00Z",
            "is_deleted": false
          },
          {
            "id": 201,
            "thread_id": 100,
            "author": {
              "name": "John Doe",
              "id": "c3d4e5f6-a7b8-9012-cdef-3456789abcde",
              "unique_name": "john@example.com"
            },
            "parent_comment_id": 200,
            "body": "Good point, I'll add it in a follow-up PR.",
            "created_at": "2026-03-27T11:00:00Z",
            "updated_at": "2026-03-27T11:00:00Z",
            "is_deleted": false
          }
        ]
      },
      {
        "id": 101,
        "status": "active",
        "is_deleted": false,
        "published_at": "2026-03-27T10:15:00Z",
        "updated_at": "2026-03-27T10:15:00Z",
        "comments": [
          {
            "id": 202,
            "thread_id": 101,
            "author": {
              "name": "Bob Jones",
              "id": "f6a7b8c9-d0e1-2345-6789-0abcdef12345",
              "unique_name": "bob@example.com"
            },
            "body": "Looks good overall. One minor comment on the handler file.",
            "created_at": "2026-03-27T10:15:00Z",
            "updated_at": "2026-03-27T10:15:00Z",
            "is_deleted": false
          }
        ]
      }
    ],
    "synced_at": "2026-03-27T12:00:00Z"
  },
  "drafts": {
    "f47ac10b-58cc-4372-a567-0e02b2c3d479": {
      "file_path": "src/validators/user.lua",
      "line_start": 15,
      "line_end": 28,
      "body": "This validation block could be simplified with a pattern match.",
      "status": "draft",
      "author": "user",
      "created_at": "2026-03-27T12:00:00Z",
      "updated_at": "2026-03-27T12:00:00Z"
    },
    "9c4d8e2f-1a3b-4c5d-8e7f-6a5b4c3d2e1f": {
      "file_path": "src/handlers/register.lua",
      "line_start": 18,
      "body": "Agreed, rate limiting would be important for this endpoint.",
      "status": "pending",
      "author": "user",
      "thread_id": 100,
      "parent_comment_id": 200,
      "created_at": "2026-03-27T12:30:00Z",
      "updated_at": "2026-03-27T12:45:00Z"
    },
    "d1e2f3a4-b5c6-4d7e-8f9a-0b1c2d3e4f5a": {
      "body": "Fixed: added null check for user input as requested.",
      "status": "draft",
      "author": "ai",
      "author_name": "CodeFixer",
      "thread_id": 100,
      "created_at": "2026-03-27T13:00:00Z",
      "updated_at": "2026-03-27T13:00:00Z"
    }
  },
  "proposals": {
    "b2c3d4e5-f6a7-4b8c-9d0e-1f2a3b4c5d6e": {
      "thread_id": 100,
      "description": "Added null check for user input in registration handler",
      "status": "draft",
      "author": "ai",
      "author_name": "CodeFixer",
      "branch_name": "powerreview/fix/thread-100",
      "files_changed": ["src/handlers/register.lua"],
      "reply_draft_id": "d1e2f3a4-b5c6-4d7e-8f9a-0b1c2d3e4f5a",
      "created_at": "2026-03-27T13:00:00Z",
      "updated_at": "2026-03-27T13:00:00Z"
    }
  },
  "fix_worktree": {
    "path": "/home/user/projects/my-repo/.power-review-fixes/42",
    "base_branch": "feature/user-validation",
    "created_at": "2026-03-27T12:55:00Z"
  },
  "vote": "no_vote",
  "created_at": "2026-03-27T10:00:00Z",
  "updated_at": "2026-03-27T12:45:00Z"
}
```

### Notes on the full example

- The `vote` is `"no_vote"` -- the reviewer has not cast a meaningful vote yet.
- The `pull_request.status` is `"active"` and `is_draft` is `false` -- this is an open, non-draft PR.
- The `pull_request.merge_status` is `"succeeded"` -- the PR can merge cleanly.
- The `pull_request.reviewers` array shows Alice (required, no vote) and Bob (optional, vote 5 = approved with suggestions).
- The `pull_request.author` uses `PersonIdentity` with `name`, `id`, and `unique_name`.
- The `iteration` records the sync state (iteration 3 with commit SHAs).
- The `review` records per-file review progress: `src/validators/user.lua` was reviewed during iteration 2, but `src/handlers/register.lua` changed since then and needs re-review.
- The `git` object records the strategy and worktree path.
- The `files` array shows three types of changes: edit, add, and delete. Null fields are omitted.
- The `threads.items` array contains one file-level thread (with a reply using `parent_comment_id`) and one PR-level thread (`file_path` is omitted/null).
- The `drafts` is a **map** keyed by UUID, not an array. Each draft's UUID is the key.
  - First draft: new standalone comment (status `"draft"`, no `thread_id`).
  - Second draft: reply to existing thread (status `"pending"`, `thread_id` and `parent_comment_id` set).
  - Third draft: AI-authored reply linked to a proposal (`author` is `"ai"`, `author_name` identifies the agent).
- The `proposals` map contains one proposed code fix by an AI agent. The proposal:
  - Responds to thread 100 (`thread_id` = 100).
  - Has committed changes on branch `powerreview/fix/thread-100`.
  - Links to the third draft reply via `reply_draft_id` (when approved, the reply is auto-approved too).
  - Is in `"draft"` status, awaiting user review and approval.
- The `fix_worktree` records the isolated worktree where the AI agent made its code changes.

---

## Neovim Adapter Mapping (v4 -> flat)

The Neovim plugin's `cli.adapt_session()` function converts the nested v4 format to a flat shape:

| v4 Path | Flat Field |
|---------|-----------|
| `pull_request.id` | `pr_id` |
| `pull_request.url` | `pr_url` |
| `pull_request.title` | `pr_title` |
| `pull_request.description` | `pr_description` |
| `pull_request.author.name` | `pr_author` |
| `pull_request.status` | `pr_status` |
| `pull_request.is_draft` | `pr_is_draft` |
| `pull_request.closed_at` | `pr_closed_at` |
| `pull_request.source_branch` | `source_branch` |
| `pull_request.target_branch` | `target_branch` |
| `pull_request.merge_status` | `merge_status` |
| `pull_request.reviewers` | `reviewers` |
| `pull_request.labels` | `labels` |
| `pull_request.work_items` | `work_items` |
| `provider.type` | `provider_type` |
| `provider.organization` | `org` |
| `provider.project` | `project` |
| `provider.repository` | `repo` |
| `git.strategy` | `git_strategy` |
| `git.worktree_path` | `worktree_path` |
| `iteration.id` | `iteration_id` |
| `iteration.source_commit` | `source_commit` |
| `iteration.target_commit` | `target_commit` |
| `review.reviewed_iteration_id` | `reviewed_iteration_id` |
| `review.reviewed_source_commit` | `reviewed_source_commit` |
| `review.reviewed_files` | `reviewed_files` |
| `review.changed_since_review` | `changed_since_review` |
| `threads.items` | `threads` (array) |
| `drafts` (map) | `drafts` (array, sorted by `created_at`, `id` field added) |
| `vote` (string enum) | `vote` (number: approved=10, approved_with_suggestions=5, no_vote=0, wait_for_author=-5, rejected=-10) |

---

## Schema Migrations

### v3 -> v4

- Added the `review` object (type `ReviewState`) to the top-level session.
- Existing v3 sessions are migrated automatically: a default empty `ReviewState` is inserted with `reviewed_files: []`, `changed_since_review: []`, and null `reviewed_iteration_id` / `reviewed_source_commit`.
- No other fields are changed. The migration is non-destructive.

### v4 -> v5

- Added the `proposals` object (type `Map<UUID, ProposedFix>`) for tracking AI-proposed code fixes.
- Added the `fix_worktree` object (type `FixWorktreeInfo | null`) for the isolated worktree used by AI agents.
- Existing v4 sessions are migrated automatically: `proposals` defaults to an empty map `{}`, `fix_worktree` defaults to `null`.
- No other fields are changed. The migration is non-destructive.

---

## Refresh Semantics

When a session is refreshed (`dnx PowerReview -- open --pr-url ...` on an existing session, or `dnx PowerReview -- refresh --pr-url ...`):

- **PR metadata** is re-fetched: title, description, status, is_draft, closed_at, merge_status, reviewers, labels, work_items.
- **Files** are fully replaced with the latest iteration's changed files. Iteration metadata is updated.
- **Threads** are fully replaced with fresh data from the provider.
- **Review state** undergoes smart reset: if the iteration changed, files that were modified between iterations lose their "reviewed" mark; unchanged files retain it. `changed_since_review` is recomputed.
- **Drafts** are preserved. They are never affected by refresh operations.
- **Proposals** and **fix worktree** are preserved. They are never affected by refresh operations.

When only threads are synced (`dnx PowerReview -- sync --pr-url ...`):

- Only **threads** are re-fetched and replaced.
- An **iteration check** is performed: if a new iteration is detected, the review state is smart-reset (same logic as refresh).
- Files and PR metadata are not updated.
