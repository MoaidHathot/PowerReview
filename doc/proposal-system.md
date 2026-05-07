# Incoming Comment Response System

When someone comments on your pull request, AI agents can automatically read those comments and respond with draft replies, proposed code fixes, or explanations. Everything stays in draft until you approve it -- no changes reach your branch or the remote provider without your explicit approval.

This document covers the full system: architecture, setup, AI agent workflow, user workflow, CLI command reference, and ActionView integration.

## Architecture

```
                          External Trigger
                      (scheduler, webhook, manual)
                                |
                                v
                     +-------------------+
                     |    AI Agent       |
                     | (Claude, Copilot) |
                     +--------+----------+
                              |
                    MCP (stdio) or CLI
                              |
                              v
                     +-------------------+        +------------------+
                     |  PowerReview CLI  |------->| Azure DevOps API |
                     |  & MCP Server    |<-------| (sync threads)   |
                     +--------+----------+        +------------------+
                              |
                   +----------+----------+
                   |                     |
                   v                     v
          +----------------+    +------------------+
          | Session File   |    | Fix Worktree     |
          | (JSON on disk) |    | (git worktree)   |
          +-------+--------+    +------------------+
                  |                 isolated code
                  |                 changes on
                  |                 temp branches
                  v
          +----------------+
          | User reviews   |
          | via ActionView |
          | or CLI         |
          +----------------+
                  |
          approve / reject
                  |
                  v
          +------------------+
          | Apply: cherry-   |
          | pick into PR     |
          | branch + push    |
          +------------------+
```

### Components

| Component | Role |
|-----------|------|
| **External trigger** | Detects new comments on your PRs. Your own mechanism (scheduler, webhook, manual). Not part of PowerReview. |
| **AI agent** | Reads comments via MCP, decides action, creates draft replies and/or code fixes. |
| **PowerReview CLI/MCP** | Manages sessions, threads, drafts, proposals. Syncs with AzDO. All business logic lives here. |
| **Session file** | JSON on disk. Contains PR metadata, threads, drafts, and proposals. Watched by Neovim for live UI updates. |
| **Fix worktree** | Isolated git working directory at `{repo}/.power-review-fixes/{pr_id}`. AI makes code changes here without touching your working directory. One worktree per PR, reused across all fixes. |
| **ActionView** | Your platform for viewing diffs and executing CLI commands. Calls PowerReview CLI to list/diff/approve/apply proposals. |

### Data flow

1. **Incoming**: AzDO -> `powerreview sync` -> session file (threads updated)
2. **AI processing**: AI reads threads via MCP -> creates draft replies and/or proposals -> session file updated
3. **Code changes**: AI writes code in fix worktree -> commits to temp branch (`powerreview/fix/thread-{id}`)
4. **User review**: User runs `proposal list` / `proposal diff` via ActionView or CLI
5. **Approval**: User runs `proposal approve` + `proposal apply --push` -> cherry-pick into PR branch -> push
6. **Reply submission**: User runs `submit` -> approved draft replies are posted to AzDO

---

## Setup

### Prerequisites

- .NET 10 SDK installed
- PowerReview CLI installed (`dotnet tool install -g PowerReview`)
- CLI configured with authentication (see [README.md](../README.md#authentication))
- A git repository clone of your PR's repo on disk

### Opening a session for your own PR

The same `open` command works for both reviewing others' PRs and managing your own:

```bash
powerreview open --pr-url https://dev.azure.com/org/project/_git/repo/pullrequest/42 --repo-path /path/to/repo
```

This creates a session file and syncs threads from AzDO.

### Syncing threads

Before the AI agent can read comments, threads must be synced:

```bash
powerreview sync --pr-url <url>
```

Or via MCP: `SyncThreads(prUrl)`.

---

## How It Works

### AI agent side

The AI agent connects to PowerReview via MCP (`powerreview mcp`) and follows this workflow. The full AI instructions are in [`skills/responding-to-comments/SKILL.md`](../skills/responding-to-comments/SKILL.md).

#### Decision framework

For each incoming comment, the agent decides one of three actions:

| Action | When to use | What the agent does |
|--------|------------|---------------------|
| **Reply** | Question, clarification, acknowledgment | Calls `ReplyToThread` to create a draft reply |
| **Code fix** | Reviewer identified a real code issue | Creates a fix branch, makes changes, commits, registers a proposal |
| **Won't fix** | Valid point but intentional or out of scope | Calls `ReplyToThread` with an explanation |

#### Code fix sequence (6 steps)

```
1. PrepareFixWorktree(prUrl)          -> get worktree path
2. CreateFixBranch(prUrl, threadId)   -> create branch in worktree
3. <make code changes in worktree>    -> edit files, git add, git commit
4. ReplyToThread(prUrl, threadId, body) -> draft reply (optional)
5. CreateProposal(prUrl, threadId,    -> register the proposal
     branchName, description,
     filesChanged, replyDraftId)
```

The proposal is created as a draft. The user must approve and apply it.

### User side

After the AI agent has processed comments, you review its work:

```
1. List proposals       -> see what the AI suggested
2. View diffs           -> inspect the actual code changes
3. Approve or reject    -> make your decision
4. Apply (if approved)  -> cherry-pick into PR branch, optionally push
5. Submit replies       -> post approved draft replies to AzDO
```

### Proposal lifecycle

```
Draft ──> Approved ──> Applied
  │
  └──> Rejected
```

| Status | Meaning | Can do |
|--------|---------|--------|
| **Draft** | AI-created, awaiting your review | View diff, approve, reject, delete |
| **Approved** | You approved it, ready to apply | Apply (merge into PR branch), view diff |
| **Applied** | Cherry-picked into PR branch | Done. Branch cleanup happens automatically. |
| **Rejected** | You decided against it | Delete |

When you approve a proposal that has a linked reply draft (`reply_draft_id`), the reply is automatically moved from `Draft` to `Pending` status, ready for submission.

---

## CLI Command Reference

All commands output JSON to stdout. Exit code 0 = success, 1 = error.

### fix-worktree subcommands

#### `fix-worktree prepare`

Create the fix worktree for a PR. Idempotent -- returns the existing worktree if already created.

```bash
powerreview fix-worktree prepare --pr-url <url>
```

**Output:**

```json
{
  "worktree_path": "/home/user/repo/.power-review-fixes/42",
  "base_branch": "feature/my-feature",
  "created": true
}
```

When the worktree already exists, `created` is `false`.

**Errors:**
- No git repository path in the session
- PR source branch not set
- Git worktree creation failures

---

#### `fix-worktree cleanup`

Remove the fix worktree and delete all `powerreview/fix/*` branches.

```bash
powerreview fix-worktree cleanup --pr-url <url>
```

**Output:**

```json
{
  "cleaned": true
}
```

---

#### `fix-worktree path`

Get the fix worktree path without creating it. No git or network operations.

```bash
powerreview fix-worktree path --pr-url <url>
```

**Output:**

```json
{
  "path": "/home/user/repo/.power-review-fixes/42"
}
```

**Error:** `"No fix worktree exists for this session."` if not yet prepared.

---

#### `fix-worktree create-branch`

Create a fix branch in the worktree for a specific comment thread.

```bash
powerreview fix-worktree create-branch --pr-url <url> --thread-id 42
```

| Flag | Required | Description |
|------|----------|-------------|
| `--pr-url` | yes | Pull request URL |
| `--thread-id` | yes | Thread ID to create a branch for |

**Output:**

```json
{
  "branch": "powerreview/fix/thread-42",
  "worktree_path": "/home/user/repo/.power-review-fixes/42",
  "thread_id": 42
}
```

If the branch already exists, it is checked out and returned.

---

### proposal subcommands

#### `proposal create`

Register a proposed code fix. The AI agent should have already committed changes to the fix branch.

```bash
powerreview proposal create \
  --pr-url <url> \
  --thread-id 42 \
  --branch powerreview/fix/thread-42 \
  --description "Added null check for user input" \
  --files "src/main.cs,src/utils.cs" \
  --author ai \
  --author-name CodeFixer \
  --reply-draft-id <uuid>
```

| Flag | Required | Description |
|------|----------|-------------|
| `--pr-url` | yes | Pull request URL |
| `--thread-id` | yes | Remote thread ID this fix responds to |
| `--branch` | yes | Name of the fix branch holding changes |
| `--description` | yes* | Description of what the fix does |
| `--description-stdin` | no | Read description from stdin instead of `--description` |
| `--files` | no | Comma-separated list of changed file paths |
| `--author` | no | `user` or `ai` (default: `ai`) |
| `--author-name` | no | Display name for the agent |
| `--reply-draft-id` | no | UUID of a linked reply draft |

*Either `--description` or `--description-stdin` is required.

**Output:**

```json
{
  "id": "b2c3d4e5-f6a7-4b8c-9d0e-1f2a3b4c5d6e",
  "proposal": {
    "thread_id": 42,
    "description": "Added null check for user input",
    "status": "Draft",
    "author": "Ai",
    "author_name": "CodeFixer",
    "branch_name": "powerreview/fix/thread-42",
    "files_changed": ["src/main.cs", "src/utils.cs"],
    "reply_draft_id": "a1b2c3d4-...",
    "created_at": "2026-04-13T10:00:00Z",
    "updated_at": "2026-04-13T10:00:00Z"
  }
}
```

---

#### `proposal list`

List all proposals and their statuses.

```bash
powerreview proposal list --pr-url <url>
```

**Output:**

```json
{
  "counts": {
    "draft": 2,
    "approved": 1,
    "applied": 0,
    "rejected": 0,
    "total": 3
  },
  "proposals": [
    {
      "id": "uuid-1",
      "proposal": {
        "thread_id": 42,
        "description": "Added null check",
        "status": "Draft",
        "author": "Ai",
        "branch_name": "powerreview/fix/thread-42",
        "files_changed": ["src/main.cs"],
        "created_at": "2026-04-13T10:00:00Z",
        "updated_at": "2026-04-13T10:00:00Z"
      }
    },
    {
      "id": "uuid-2",
      "proposal": {
        "thread_id": 55,
        "description": "Refactored validation logic",
        "status": "Approved",
        "author": "Ai",
        "branch_name": "powerreview/fix/thread-55",
        "files_changed": ["src/validators.cs"],
        "created_at": "2026-04-13T10:05:00Z",
        "updated_at": "2026-04-13T10:10:00Z"
      }
    }
  ]
}
```

---

#### `proposal diff`

View the code diff for a proposed fix. Shows changes between the fix branch and the PR source branch.

```bash
powerreview proposal diff --pr-url <url> --proposal-id <uuid>
```

| Flag | Required | Description |
|------|----------|-------------|
| `--pr-url` | yes | Pull request URL |
| `--proposal-id` | yes | Proposal UUID |

**Output:**

```json
{
  "proposal_id": "uuid-1",
  "description": "Added null check for user input",
  "branch": "powerreview/fix/thread-42",
  "status": "Draft",
  "diff": "diff --git a/src/main.cs b/src/main.cs\nindex abc123..def456 100644\n--- a/src/main.cs\n+++ b/src/main.cs\n@@ -40,6 +40,9 @@ public class UserService\n     public void Register(string name)\n     {\n+        if (string.IsNullOrEmpty(name))\n+            throw new ArgumentNullException(nameof(name));\n+\n         _repo.Save(new User(name));\n     }\n }"
}
```

The `diff` field contains the full unified diff. This is what ActionView should render.

---

#### `proposal approve`

Approve a proposal (Draft -> Approved). If a linked reply draft exists, it is auto-approved (Draft -> Pending).

```bash
powerreview proposal approve --pr-url <url> --proposal-id <uuid>
```

| Flag | Required | Description |
|------|----------|-------------|
| `--pr-url` | yes | Pull request URL |
| `--proposal-id` | yes | Proposal UUID |

**Output:**

```json
{
  "id": "uuid-1",
  "proposal": {
    "thread_id": 42,
    "status": "Approved",
    "..."
  }
}
```

**Errors:**
- `"Cannot approve proposal: status is 'Approved'"` -- already approved
- `"Proposal not found"` -- invalid UUID

---

#### `proposal apply`

Apply an approved proposal by cherry-picking the fix branch commits into the PR source branch. Optionally pushes to remote.

```bash
powerreview proposal apply --pr-url <url> --proposal-id <uuid> --push
```

| Flag | Required | Description |
|------|----------|-------------|
| `--pr-url` | yes | Pull request URL |
| `--proposal-id` | yes | Proposal UUID |
| `--push` | no | Push changes to the remote after applying |

**Output:**

```json
{
  "id": "uuid-1",
  "proposal": {
    "thread_id": 42,
    "status": "Applied",
    "..."
  },
  "applied": true,
  "pushed": true
}
```

**What happens:**
1. Checks out the PR source branch in the fix worktree
2. Pulls latest from remote (fast-forward only)
3. Cherry-picks the fix branch commits
4. Pushes to remote (if `--push` specified)
5. Deletes the fix branch
6. Updates proposal status to Applied

**Errors:**
- `"Cannot apply proposal: status is 'Draft'"` -- must approve first
- `"Cherry-pick failed. You may need to resolve conflicts manually."` -- merge conflict
- `"Push failed"` -- remote push error

---

#### `proposal reject`

Reject a proposal (Draft -> Rejected).

```bash
powerreview proposal reject --pr-url <url> --proposal-id <uuid>
```

**Output:**

```json
{
  "id": "uuid-1",
  "proposal": {
    "thread_id": 42,
    "status": "Rejected",
    "..."
  }
}
```

---

#### `proposal delete`

Delete a proposal from the session. Only Draft or Rejected proposals can be deleted.

```bash
powerreview proposal delete --pr-url <url> --proposal-id <uuid>
```

**Output:**

```json
{
  "deleted": true,
  "id": "uuid-1"
}
```

**Errors:**
- `"Cannot delete proposal: status is 'Approved'"` -- only Draft or Rejected can be deleted
- `"author mismatch"` -- AI caller trying to delete a user-authored proposal

---

## ActionView Integration

ActionView can call any of the CLI commands above and render the results. Here are the key integrations:

### Listing pending proposals

```bash
powerreview proposal list --pr-url <url>
```

Parse the `counts` object for a summary badge. Iterate `proposals` to render a list with status indicators.

### Viewing a proposal diff

```bash
powerreview proposal diff --pr-url <url> --proposal-id <uuid>
```

The `diff` field contains a standard unified diff. Render it as you would any git diff. The `description` field provides a human-readable summary to display above the diff.

### Approve + Apply workflow

Wire these as a sequence of buttons or a single "Approve & Apply" action:

```bash
# Step 1: Approve
powerreview proposal approve --pr-url <url> --proposal-id <uuid>

# Step 2: Apply and push
powerreview proposal apply --pr-url <url> --proposal-id <uuid> --push

# Step 3: Submit the linked reply to AzDO
powerreview submit --pr-url <url>
```

### Quick reject

```bash
powerreview proposal reject --pr-url <url> --proposal-id <uuid>
```

### JSON output contract

All commands return JSON to stdout with:
- Success: the relevant data (varies by command)
- Error: `{ "error": "message" }`
- Exit code: 0 (success), 1 (error), 2 (usage error)

---

## Walkthrough

End-to-end example: a reviewer comments "add null check on line 42 of src/main.cs" on your PR.

### 1. Open the session

```bash
powerreview open \
  --pr-url https://dev.azure.com/myorg/myproject/_git/myrepo/pullrequest/42 \
  --repo-path /home/user/projects/myrepo
```

### 2. AI agent processes comments

The AI agent (triggered by your external mechanism) connects via MCP and runs:

```
SyncThreads(prUrl)                     # fetch latest threads
ListCommentThreads(prUrl)              # read all comments
# Agent finds thread 100: "add null check on line 42"
# Agent decides: this needs a code fix

PrepareFixWorktree(prUrl)              # create isolated worktree
# Returns: { worktree_path: "/home/user/projects/myrepo/.power-review-fixes/42" }

CreateFixBranch(prUrl, threadId=100)   # create branch for this fix
# Returns: { branch: "powerreview/fix/thread-100" }

# Agent makes code changes in the worktree:
#   - Reads src/main.cs via ReadFile
#   - Edits the file to add the null check
#   - Runs: git add . && git commit -m "Add null check for user input"
#     (in the worktree directory)

ReplyToThread(prUrl, threadId=100,
  body="Fixed: added null check for user input on line 42.")
# Returns: { id: "reply-uuid-123" }

CreateProposal(prUrl, threadId=100,
  branchName="powerreview/fix/thread-100",
  description="Added null check for user input as requested",
  filesChanged="src/main.cs",
  replyDraftId="reply-uuid-123")
# Returns: { id: "proposal-uuid-456" }
```

### 3. You review proposals

```bash
# See what the AI suggested
powerreview proposal list \
  --pr-url https://dev.azure.com/myorg/myproject/_git/myrepo/pullrequest/42
```

Output:
```json
{
  "counts": { "draft": 1, "approved": 0, "applied": 0, "rejected": 0, "total": 1 },
  "proposals": [{
    "id": "proposal-uuid-456",
    "proposal": {
      "thread_id": 100,
      "description": "Added null check for user input as requested",
      "status": "Draft",
      "branch_name": "powerreview/fix/thread-100",
      "files_changed": ["src/main.cs"]
    }
  }]
}
```

```bash
# View the actual code diff
powerreview proposal diff \
  --pr-url https://dev.azure.com/myorg/myproject/_git/myrepo/pullrequest/42 \
  --proposal-id proposal-uuid-456
```

Output:
```json
{
  "proposal_id": "proposal-uuid-456",
  "description": "Added null check for user input as requested",
  "branch": "powerreview/fix/thread-100",
  "status": "Draft",
  "diff": "diff --git a/src/main.cs b/src/main.cs\n..."
}
```

### 4. Approve and apply

```bash
# Approve the proposal (also auto-approves the linked reply draft)
powerreview proposal approve \
  --pr-url https://dev.azure.com/myorg/myproject/_git/myrepo/pullrequest/42 \
  --proposal-id proposal-uuid-456

# Apply: cherry-pick into PR branch and push
powerreview proposal apply \
  --pr-url https://dev.azure.com/myorg/myproject/_git/myrepo/pullrequest/42 \
  --proposal-id proposal-uuid-456 \
  --push
```

### 5. Submit the reply to AzDO

```bash
# Post the approved reply ("Fixed: added null check...") to AzDO
powerreview submit \
  --pr-url https://dev.azure.com/myorg/myproject/_git/myrepo/pullrequest/42
```

The reviewer sees your reply on the thread, and the PR branch now contains the fix.

---

## Safety & Constraints

1. **All proposals start as drafts.** Nothing reaches your branch until you explicitly approve and apply.
2. **Code changes are isolated.** The fix worktree (`{repo}/.power-review-fixes/{pr_id}`) is a separate git checkout. Your working directory is never touched.
3. **Approve/apply/reject are user-only.** These operations are CLI commands, not MCP tools. AI agents cannot approve their own proposals.
4. **AI can only modify its own proposals.** Author guards prevent AI from deleting user-created proposals.
5. **Cherry-pick conflicts require manual resolution.** If the fix branch conflicts with the current source branch, `proposal apply` fails with an error message. You resolve it manually in the worktree.
6. **Linked replies auto-approve.** When you approve a proposal with a `reply_draft_id`, the linked reply moves from Draft to Pending automatically. It still needs `submit` to be posted to AzDO.
7. **Multiple proposals per PR.** Each fix gets its own branch (`powerreview/fix/thread-{id}`). Proposals are independent -- you can approve one and reject another.

---

## Related Documentation

| Document | What it covers |
|----------|----------------|
| [`skills/responding-to-comments/SKILL.md`](../skills/responding-to-comments/SKILL.md) | AI agent instructions for the comment response workflow |
| [`skills/reviewing-prs/references/TOOLS.md`](../skills/reviewing-prs/references/TOOLS.md) | Complete MCP tool API reference (all parameters, returns, errors) |
| [`doc/session-schema.md`](session-schema.md) | Session file JSON schema (v6) including ProposedFix, FixWorktreeInfo, and metadata summaries |
| [`README.md`](../README.md) | Project overview, installation, configuration |
