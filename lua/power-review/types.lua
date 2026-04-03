--- Type annotations for PowerReview.nvim
--- These are LuaCATS annotations used by lua-language-server for type checking.
--- No runtime code here.

---@alias PowerReview.ProviderType "azdo" | "github"
---@alias PowerReview.GitStrategy "worktree" | "checkout" | "reused_main"
---@alias PowerReview.DraftStatus "draft" | "pending" | "submitted"
---@alias PowerReview.DraftAuthor "user" | "ai"
---@alias PowerReview.FileChangeType "add" | "edit" | "delete" | "rename"

--- Review vote values (numeric, matching Azure DevOps convention)
---@alias PowerReview.ReviewVote
---| 10  # Approved
---| 5   # Approved with suggestions
---| 0   # No vote
---| -5  # Wait for author
---| -10 # Rejected

--- Thread status values
---@alias PowerReview.ThreadStatus
---| "active"   # Open, unresolved
---| "fixed"    # Resolved as fixed
---| "wontfix"  # Resolved as won't fix
---| "closed"   # Closed
---| "bydesign" # Resolved as by design
---| "pending"  # Pending resolution

--- PR status values (provider-normalized)
---@alias PowerReview.PRStatus
---| "active"    # Open and reviewable
---| "completed" # Merged / completed
---| "abandoned" # Closed without merging

--- Merge status values
---@alias PowerReview.MergeStatus
---| "succeeded"  # Merge will succeed
---| "conflicts"  # Merge has conflicts
---| "queued"     # Merge is queued
---| "notSet"     # Not evaluated
---| "failure"    # Merge failed

---@class PowerReview.Reviewer
---@field name string Display name of the reviewer
---@field id? string Provider-assigned reviewer ID
---@field unique_name? string Email or login (e.g., user@example.com)
---@field vote number|nil Review vote value, or nil if not voted
---@field is_required boolean Whether the reviewer is required

---@class PowerReview.WorkItem
---@field id number Work item / issue ID
---@field title? string Work item title (may not be available from all providers)
---@field url? string Web URL to the work item

---@class PowerReview.SubmitResult
---@field submitted number Count of successfully submitted drafts
---@field failed number Count of failed submissions
---@field total number Total drafts attempted
---@field errors { draft: PowerReview.DraftComment, error: string }[]

---@class PowerReview.IterationMeta
---@field iteration_id number Latest iteration ID
---@field source_commit? string Source branch commit SHA
---@field target_commit? string Target branch commit SHA

---@class PowerReview.ReviewState
---@field reviewed_iteration_id? number Iteration ID the reviewer last reviewed against
---@field reviewed_source_commit? string Source commit SHA at time of last review
---@field reviewed_files string[] File paths marked as reviewed in the current iteration
---@field changed_since_review string[] File paths with changes since the last reviewed iteration

---@class PowerReview.ChangedFile
---@field path string Relative file path
---@field original_path? string Original path for renames
---@field change_type PowerReview.FileChangeType
---@field additions? number
---@field deletions? number

---@class PowerReview.Comment
---@field id number Provider comment ID
---@field thread_id number Provider thread ID
---@field author string Display name
---@field author_id? string Provider-assigned author ID
---@field author_unique_name? string Author email or login
---@field parent_comment_id? number Parent comment ID within the thread (for nested replies)
---@field body string Markdown content
---@field created_at string ISO timestamp
---@field updated_at string ISO timestamp
---@field is_deleted boolean

---@class PowerReview.CommentThread
---@field id number Provider thread ID
---@field file_path? string nil for PR-level threads
---@field line_start? number
---@field line_end? number
---@field col_start? number 1-indexed start column offset
---@field col_end? number 1-indexed end column offset
---@field left_line_start? number Base/target branch start line (for comments on deleted code)
---@field left_line_end? number Base/target branch end line
---@field status PowerReview.ThreadStatus
---@field comments PowerReview.Comment[]
---@field is_deleted boolean
---@field published_at? string ISO timestamp of thread creation
---@field updated_at? string ISO timestamp of last thread update

---@class PowerReview.DraftComment
---@field id string Local UUID
---@field file_path string Relative file path
---@field line_start number 1-indexed line number
---@field line_end? number End line for range comments
---@field col_start? number 1-indexed start column (byte offset within line_start)
---@field col_end? number 1-indexed end column (byte offset within line_end or line_start)
---@field body string Markdown content
---@field status PowerReview.DraftStatus
---@field author PowerReview.DraftAuthor
---@field author_name? string Display name of the agent or person (e.g. "SecurityReviewer")
---@field thread_id? number nil for new threads, set for replies to remote threads
---@field parent_comment_id? number For replies, the comment being replied to
---@field created_at string ISO timestamp
---@field updated_at string ISO timestamp

---@class PowerReview.ReviewSession
---@field version number Schema version (adapted to flat shape from CLI v3)
---@field id string Session identifier (org_project_repo_prId)
---@field pr_id number
---@field provider_type PowerReview.ProviderType
---@field org string Organization (AzDO) or owner (GitHub)
---@field project string Project (AzDO) or repo (GitHub)
---@field repo string Repository name
---@field pr_url string Original PR URL
---@field pr_title string
---@field pr_description string
---@field pr_author string
---@field pr_status? PowerReview.PRStatus PR status (active, completed, abandoned)
---@field pr_is_draft? boolean Whether the PR is a draft
---@field pr_closed_at? string ISO timestamp of PR closure/completion
---@field source_branch string
---@field target_branch string
---@field merge_status? PowerReview.MergeStatus Merge feasibility status
---@field reviewers? PowerReview.Reviewer[] List of PR reviewers with their votes
---@field labels? string[] PR labels/tags
---@field work_items? PowerReview.WorkItem[] Linked work items/issues
---@field iteration_id? number Latest iteration ID the session was synced to
---@field source_commit? string Source branch commit SHA at last sync
---@field target_commit? string Target branch commit SHA at last sync
---@field reviewed_iteration_id? number Iteration ID the reviewer last reviewed against
---@field reviewed_source_commit? string Source commit SHA at time of last review
---@field reviewed_files string[] File paths marked as reviewed
---@field changed_since_review string[] File paths with changes since last reviewed iteration
---@field worktree_path? string Path to worktree if using worktree strategy
---@field git_strategy PowerReview.GitStrategy
---@field created_at string ISO timestamp
---@field updated_at string ISO timestamp
---@field vote? PowerReview.ReviewVote
---@field drafts PowerReview.DraftComment[]
---@field threads PowerReview.CommentThread[]
---@field files PowerReview.ChangedFile[]

---@class PowerReview.SessionSummary
---@field id string
---@field pr_id number
---@field pr_title string
---@field pr_url string
---@field pr_status? PowerReview.PRStatus
---@field provider_type PowerReview.ProviderType
---@field org string
---@field project string
---@field repo string
---@field draft_count number
---@field created_at string
---@field updated_at string

return {}
