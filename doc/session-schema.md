# PowerReview Session File Schema (v2)

This document defines the JSON schema for PowerReview session state files.
External tools that create or consume these files **must** conform to this specification.

## File Location

Session files are stored at:

```
{nvim_data_dir}/power-review/sessions/{session_id}.json
```

| Platform    | Typical `nvim_data_dir`                  |
|-------------|------------------------------------------|
| Linux/macOS | `~/.local/share/nvim`                    |
| Windows     | `%LOCALAPPDATA%/nvim-data`               |

### Session ID

The `session_id` is constructed as:

```
{org}_{project}_{repo}_{pr_id}
```

All characters that are not alphanumeric or hyphens are replaced with underscores.

Example: `my-org_my-project_my-repo_42` produces the file `my-org_my-project_my-repo_42.json`.

---

## Top-Level Object: `ReviewSession`

| Field            | Type                        | Required | Description                                                |
|------------------|-----------------------------|----------|------------------------------------------------------------|
| `version`        | `number`                    | yes      | Schema version. Must be `2`.                               |
| `id`             | `string`                    | yes      | Session identifier (`{org}_{project}_{repo}_{pr_id}`).     |
| `pr_id`          | `number`                    | yes      | Pull request number from the provider.                     |
| `provider_type`  | `string`                    | yes      | `"azdo"` or `"github"`.                                    |
| `org`            | `string`                    | yes      | Organization (AzDO) or repository owner (GitHub).          |
| `project`        | `string`                    | yes      | Project (AzDO) or repository name (GitHub).                |
| `repo`           | `string`                    | yes      | Repository name.                                           |
| `pr_url`         | `string`                    | yes      | Original PR URL.                                           |
| `pr_title`       | `string`                    | yes      | Pull request title.                                        |
| `pr_description` | `string`                    | yes      | Pull request description (markdown).                       |
| `pr_author`      | `string`                    | yes      | Display name of the PR author.                             |
| `pr_status`      | `string`                    | yes      | PR lifecycle status. See PR Status Values.                 |
| `pr_is_draft`    | `boolean`                   | yes      | Whether the PR is a draft / work-in-progress.              |
| `pr_closed_at`   | `string \| null`            | yes      | ISO 8601 UTC timestamp of PR closure/completion, or `null`.|
| `source_branch`  | `string`                    | yes      | Source / feature branch name.                              |
| `target_branch`  | `string`                    | yes      | Target / base branch name.                                 |
| `merge_status`   | `string \| null`            | yes      | Merge feasibility status, or `null`. See Merge Status Values.|
| `reviewers`      | `Reviewer[]`                | yes      | List of PR reviewers with their votes.                     |
| `labels`         | `string[]`                  | yes      | PR labels / tags.                                          |
| `work_items`     | `WorkItem[]`                | yes      | Linked work items / issues.                                |
| `iteration_id`   | `number \| null`            | yes      | Latest iteration ID the session was synced to, or `null`.  |
| `source_commit`  | `string \| null`            | yes      | Source branch commit SHA at last sync, or `null`.          |
| `target_commit`  | `string \| null`            | yes      | Target branch commit SHA at last sync, or `null`.          |
| `worktree_path`  | `string \| null`            | yes      | Filesystem path to the git worktree, or `null`.            |
| `git_strategy`   | `string`                    | yes      | `"worktree"`, `"checkout"`, or `"reused_main"`. See Git Strategy Values.|
| `created_at`     | `string`                    | yes      | ISO 8601 UTC timestamp of session creation.                |
| `updated_at`     | `string`                    | yes      | ISO 8601 UTC timestamp of last modification.               |
| `vote`           | `number \| null`            | yes      | Review vote value, or `null` if not voted. See Vote Values.|
| `files`          | `ChangedFile[]`             | yes      | List of files changed in the PR.                           |
| `threads`        | `CommentThread[]`           | yes      | Remote comment threads cached from the provider.           |
| `drafts`         | `DraftComment[]`            | yes      | Local draft comments not yet submitted.                    |

### String Formats

- **Timestamps** (`created_at`, `updated_at`, `pr_closed_at`, etc.): ISO 8601 UTC format `YYYY-MM-DDTHH:MM:SSZ`.
- **UUIDs** (draft `id`): Version 4 UUID, e.g. `"a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d"`.
- **Commit SHAs** (`source_commit`, `target_commit`): Full 40-character hex SHA.

### PR Status Values

| Value         | Description                            |
|---------------|----------------------------------------|
| `"active"`    | Open and reviewable.                   |
| `"completed"` | Merged / completed.                    |
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

### Vote Values

| Value | Meaning                  |
|-------|--------------------------|
| `10`  | Approved                 |
| `5`   | Approved with suggestions|
| `0`   | No vote / reset          |
| `-5`  | Wait for author          |
| `-10` | Rejected                 |
| `null`| Not yet voted            |

### Git Strategy Values

| Value            | Description                                                    |
|------------------|----------------------------------------------------------------|
| `"worktree"`     | A dedicated git worktree was created for the review.           |
| `"checkout"`     | The source branch was checked out in the main working tree.    |
| `"reused_main"`  | The main worktree was already on the correct branch; no worktree created.|

---

## `Reviewer` Object

Describes a PR reviewer and their current vote.

| Field         | Type             | Required | Description                                          |
|---------------|------------------|----------|------------------------------------------------------|
| `name`        | `string`         | yes      | Display name of the reviewer.                        |
| `id`          | `string \| null` | no       | Provider-assigned reviewer ID.                       |
| `unique_name` | `string \| null` | no       | Reviewer email or login.                             |
| `vote`        | `number \| null` | yes      | Review vote value (same scale as session `vote`), or `null`.|
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

A linked work item or issue from the provider.

| Field   | Type             | Required | Description                                          |
|---------|------------------|----------|------------------------------------------------------|
| `id`    | `number`         | yes      | Work item / issue ID.                                |
| `title` | `string \| null` | no       | Work item title (may not be available from all providers).|
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

Describes a single file changed in the PR.

| Field           | Type             | Required | Description                                          |
|-----------------|------------------|----------|------------------------------------------------------|
| `path`          | `string`         | yes      | Relative file path.                                  |
| `original_path` | `string \| null`| no       | Original path before rename. Present only for renames.|
| `change_type`   | `string`         | yes      | `"add"`, `"edit"`, `"delete"`, or `"rename"`.        |
| `additions`     | `number \| null` | no       | Lines added. May be absent (provider-dependent).     |
| `deletions`     | `number \| null` | no       | Lines deleted. May be absent (provider-dependent).   |

### Example

```json
{
  "path": "src/utils/helper.lua",
  "original_path": null,
  "change_type": "edit",
  "additions": 15,
  "deletions": 3
}
```

---

## `CommentThread` Object

A comment thread fetched from the provider and cached locally.

| Field             | Type             | Required | Description                                                             |
|-------------------|------------------|----------|-------------------------------------------------------------------------|
| `id`              | `number`         | yes      | Provider-assigned thread ID.                                            |
| `file_path`       | `string \| null` | yes      | Relative file path. `null` for PR-level (non-file-specific) threads.    |
| `line_start`      | `number \| null` | yes      | Start line number (1-indexed, right/source side). `null` if not applicable.|
| `line_end`        | `number \| null` | yes      | End line number (1-indexed, right/source side). `null` if not applicable.|
| `col_start`       | `number \| null` | yes      | Start column (1-indexed byte offset). `null` if offset is <= 1.        |
| `col_end`         | `number \| null` | yes      | End column (1-indexed byte offset). `null` if offset is <= 1.          |
| `left_line_start` | `number \| null` | no       | Start line on the base/target branch side (for comments on deleted code). `null` if not applicable.|
| `left_line_end`   | `number \| null` | no       | End line on the base/target branch side. `null` if not applicable.      |
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
  "col_start": null,
  "col_end": null,
  "left_line_start": null,
  "left_line_end": null,
  "status": "active",
  "is_deleted": false,
  "published_at": "2026-03-26T08:00:00Z",
  "updated_at": "2026-03-26T09:15:00Z",
  "comments": [
    {
      "id": 67890,
      "thread_id": 12345,
      "author": "Jane Smith",
      "author_id": "b2c3d4e5-f6a7-8901-bcde-f12345678901",
      "author_unique_name": "jane@example.com",
      "parent_comment_id": null,
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
| `author`            | `string`         | yes      | Comment author display name.                   |
| `author_id`         | `string \| null` | no       | Provider-assigned author ID.                   |
| `author_unique_name`| `string \| null` | no       | Author email or login.                         |
| `parent_comment_id` | `number \| null` | no       | Parent comment ID within the thread (for nested replies). `null` for top-level comments.|
| `body`              | `string`         | yes      | Comment content (markdown).                    |
| `created_at`        | `string`         | yes      | ISO 8601 UTC timestamp of creation.            |
| `updated_at`        | `string`         | yes      | ISO 8601 UTC timestamp of last edit.           |
| `is_deleted`        | `boolean`        | yes      | Whether the comment has been soft-deleted.      |

---

## `DraftComment` Object

A locally-created comment that has not yet been submitted to the provider.
Drafts follow a strict lifecycle: `draft` -> `pending` -> `submitted`.

| Field               | Type             | Required | Description                                                                  |
|---------------------|------------------|----------|------------------------------------------------------------------------------|
| `id`                | `string`         | yes      | Locally-generated UUID v4.                                                   |
| `file_path`         | `string`         | yes      | Relative file path the comment targets.                                      |
| `line_start`        | `number`         | yes      | Start line number (1-indexed).                                               |
| `line_end`          | `number \| null` | yes      | End line for multi-line range comments. `null` for single-line.              |
| `col_start`         | `number \| null` | yes      | Start column (1-indexed byte offset within `line_start`). `null` if not set. |
| `col_end`           | `number \| null` | yes      | End column (1-indexed byte offset within `line_end` or `line_start`). `null` if not set. |
| `body`              | `string`         | yes      | Comment content (markdown).                                                  |
| `status`            | `string`         | yes      | Draft lifecycle status. See Draft Status Values.                             |
| `author`            | `string`         | yes      | Who created the draft. See Draft Author Values.                              |
| `thread_id`         | `number \| null` | yes      | `null` for new standalone threads. Set to a remote thread ID when replying to an existing thread. |
| `parent_comment_id` | `number \| null` | yes      | For replies, the specific comment being replied to. `null` otherwise.        |
| `created_at`        | `string`         | yes      | ISO 8601 UTC timestamp.                                                      |
| `updated_at`        | `string`         | yes      | ISO 8601 UTC timestamp.                                                      |

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

```json
{
  "id": "a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d",
  "file_path": "src/main.lua",
  "line_start": 42,
  "line_end": null,
  "col_start": null,
  "col_end": null,
  "body": "This function should be refactored to reduce complexity.",
  "status": "draft",
  "author": "ai",
  "thread_id": null,
  "parent_comment_id": null,
  "created_at": "2026-03-27T11:00:00Z",
  "updated_at": "2026-03-27T11:30:00Z"
}
```

---

## Full Example

A complete session file with changed files, remote threads, reviewers, and draft comments:

```json
{
  "version": 2,
  "id": "my-org_my-project_my-repo_42",
  "pr_id": 42,
  "provider_type": "azdo",
  "org": "my-org",
  "project": "my-project",
  "repo": "my-repo",
  "pr_url": "https://dev.azure.com/my-org/my-project/_git/my-repo/pullrequest/42",
  "pr_title": "Add input validation to user registration",
  "pr_description": "This PR adds server-side validation for the user registration endpoint.",
  "pr_author": "John Doe",
  "pr_status": "active",
  "pr_is_draft": false,
  "pr_closed_at": null,
  "source_branch": "feature/user-validation",
  "target_branch": "main",
  "merge_status": "succeeded",
  "reviewers": [
    {
      "name": "Alice Smith",
      "id": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
      "unique_name": "alice@example.com",
      "vote": null,
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
  ],
  "iteration_id": 3,
  "source_commit": "abc123def456789012345678901234567890abcd",
  "target_commit": "def456abc789012345678901234567890abcd1234",
  "worktree_path": "/home/user/projects/my-repo/.power-review-worktrees/42",
  "git_strategy": "worktree",
  "created_at": "2026-03-27T10:00:00Z",
  "updated_at": "2026-03-27T12:45:00Z",
  "vote": null,
  "files": [
    {
      "path": "src/handlers/register.lua",
      "original_path": null,
      "change_type": "edit",
      "additions": 35,
      "deletions": 4
    },
    {
      "path": "src/validators/user.lua",
      "original_path": null,
      "change_type": "add",
      "additions": 87,
      "deletions": 0
    },
    {
      "path": "src/old_validator.lua",
      "original_path": null,
      "change_type": "delete",
      "additions": 0,
      "deletions": 52
    }
  ],
  "threads": [
    {
      "id": 100,
      "file_path": "src/handlers/register.lua",
      "line_start": 18,
      "line_end": 22,
      "col_start": null,
      "col_end": null,
      "left_line_start": null,
      "left_line_end": null,
      "status": "active",
      "is_deleted": false,
      "published_at": "2026-03-27T10:30:00Z",
      "updated_at": "2026-03-27T11:00:00Z",
      "comments": [
        {
          "id": 200,
          "thread_id": 100,
          "author": "Alice Smith",
          "author_id": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
          "author_unique_name": "alice@example.com",
          "parent_comment_id": null,
          "body": "Should we add rate limiting here?",
          "created_at": "2026-03-27T10:30:00Z",
          "updated_at": "2026-03-27T10:30:00Z",
          "is_deleted": false
        },
        {
          "id": 201,
          "thread_id": 100,
          "author": "John Doe",
          "author_id": "c3d4e5f6-a7b8-9012-cdef-3456789abcde",
          "author_unique_name": "john@example.com",
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
      "file_path": null,
      "line_start": null,
      "line_end": null,
      "col_start": null,
      "col_end": null,
      "left_line_start": null,
      "left_line_end": null,
      "status": "active",
      "is_deleted": false,
      "published_at": "2026-03-27T10:15:00Z",
      "updated_at": "2026-03-27T10:15:00Z",
      "comments": [
        {
          "id": 202,
          "thread_id": 101,
          "author": "Bob Jones",
          "author_id": "f6a7b8c9-d0e1-2345-6789-0abcdef12345",
          "author_unique_name": "bob@example.com",
          "parent_comment_id": null,
          "body": "Looks good overall. One minor comment on the handler file.",
          "created_at": "2026-03-27T10:15:00Z",
          "updated_at": "2026-03-27T10:15:00Z",
          "is_deleted": false
        }
      ]
    }
  ],
  "drafts": [
    {
      "id": "f47ac10b-58cc-4372-a567-0e02b2c3d479",
      "file_path": "src/validators/user.lua",
      "line_start": 15,
      "line_end": 28,
      "col_start": null,
      "col_end": null,
      "body": "This validation block could be simplified with a pattern match.",
      "status": "draft",
      "author": "user",
      "thread_id": null,
      "parent_comment_id": null,
      "created_at": "2026-03-27T12:00:00Z",
      "updated_at": "2026-03-27T12:00:00Z"
    },
    {
      "id": "9c4d8e2f-1a3b-4c5d-8e7f-6a5b4c3d2e1f",
      "file_path": "src/handlers/register.lua",
      "line_start": 18,
      "line_end": null,
      "col_start": null,
      "col_end": null,
      "body": "Agreed, rate limiting would be important for this endpoint.",
      "status": "pending",
      "author": "user",
      "thread_id": 100,
      "parent_comment_id": 200,
      "created_at": "2026-03-27T12:30:00Z",
      "updated_at": "2026-03-27T12:45:00Z"
    }
  ]
}
```

### Notes on the full example

- The `vote` is `null` -- the reviewer has not voted yet.
- The `pr_status` is `"active"` and `pr_is_draft` is `false` -- this is an open, non-draft PR.
- The `merge_status` is `"succeeded"` -- the PR can merge cleanly.
- The `reviewers` array shows Alice (required, no vote yet) and Bob (optional, approved with suggestions).
- The `labels` array contains two tags applied to the PR.
- The `work_items` array links to one Azure DevOps work item.
- The `iteration_id` is `3` with commit SHAs recorded -- this enables detecting new changes on next sync.
- The `files` array shows three types of changes: edit, add, and delete.
- The `threads` array contains one file-level thread (with a back-and-forth conversation including `parent_comment_id`) and one PR-level thread (`file_path` is `null`).
- Thread timestamps (`published_at`, `updated_at`) enable sorting by recency.
- Comment `author_id` and `author_unique_name` enable identifying users across sessions.
- The `drafts` array contains two drafts:
  - A new standalone comment (status `"draft"`, `thread_id` is `null`).
  - A reply to an existing thread (status `"pending"`, `thread_id` and `parent_comment_id` are set). This draft has been approved and is ready for submission.

---

## Schema Migration (v1 -> v2)

Sessions saved with schema v1 are automatically migrated on load. The following defaults are applied:

| New Field        | Default Value |
|------------------|---------------|
| `pr_status`      | `"active"`    |
| `pr_is_draft`    | `false`       |
| `pr_closed_at`   | `null`        |
| `merge_status`   | `null`        |
| `reviewers`      | `[]`          |
| `labels`         | `[]`          |
| `work_items`     | `[]`          |
| `iteration_id`   | `null`        |
| `source_commit`  | `null`        |
| `target_commit`  | `null`        |
| `threads`        | `[]` (if missing) |

The `version` field is updated to `2` after migration. A subsequent refresh (`:PowerReview refresh`) will populate the new fields from the provider.

---

## Refresh Semantics

When a session is refreshed (`:PowerReview refresh`):

- **PR metadata** is re-fetched: `pr_title`, `pr_description`, `pr_status`, `pr_is_draft`, `pr_closed_at`, `merge_status`, `reviewers`, `labels`, `work_items`.
- **Files** are fully replaced with the latest iteration's changed files. `iteration_id`, `source_commit`, and `target_commit` are updated.
- **Threads** are fully replaced with fresh data from the provider. There is no merge -- threads removed from the provider are also removed from the session.
- **Drafts** are preserved. They are stored separately and are never affected by refresh operations.

When only threads are synced (`:PowerReview sync`):

- Only **threads** are re-fetched and replaced.
- Files and PR metadata are not updated.
