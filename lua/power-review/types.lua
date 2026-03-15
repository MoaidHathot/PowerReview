--- Type annotations for PowerReview.nvim
--- These are LuaCATS annotations used by lua-language-server for type checking.
--- No runtime code here.

---@alias PowerReview.ProviderType "azdo" | "github"
---@alias PowerReview.GitStrategy "worktree" | "checkout"
---@alias PowerReview.DraftStatus "draft" | "pending" | "submitted"
---@alias PowerReview.DraftAuthor "user" | "ai"
---@alias PowerReview.FileChangeType "add" | "edit" | "delete" | "rename"

--- Azure DevOps vote values
---@alias PowerReview.ReviewVote
---| 10  # Approved
---| 5   # Approved with suggestions
---| 0   # No vote
---| -5  # Wait for author
---| -10 # Rejected

---@class PowerReview.RepoConfig
---@field provider PowerReview.ProviderType
---@field azdo? PowerReview.AzDORepoConfig
---@field github? PowerReview.GitHubRepoConfig

---@class PowerReview.AzDORepoConfig
---@field organization string
---@field project string
---@field repository string

---@class PowerReview.GitHubRepoConfig
---@field owner string
---@field repo string

---@class PowerReview.PR
---@field id number
---@field title string
---@field description string
---@field author string
---@field source_branch string
---@field target_branch string
---@field status string
---@field url string
---@field created_at string
---@field provider_type PowerReview.ProviderType
---@field provider_data table Raw provider-specific data

---@class PowerReview.ChangedFile
---@field path string Relative file path
---@field original_path? string Original path for renames
---@field change_type PowerReview.FileChangeType
---@field additions? number
---@field deletions? number

---@class PowerReview.Comment
---@field id number Provider comment ID
---@field thread_id number Provider thread ID
---@field author string
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
---@field status string "active" | "resolved" | "closed" etc.
---@field comments PowerReview.Comment[]
---@field is_deleted boolean

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
---@field thread_id? number nil for new threads, set for replies to remote threads
---@field parent_comment_id? number For replies, the comment being replied to
---@field created_at string ISO timestamp
---@field updated_at string ISO timestamp

---@class PowerReview.ReviewSession
---@field version number Schema version
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
---@field source_branch string
---@field target_branch string
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
---@field provider_type PowerReview.ProviderType
---@field org string
---@field project string
---@field repo string
---@field draft_count number
---@field created_at string
---@field updated_at string

---@class PowerReview.Provider
---@field type PowerReview.ProviderType
---@field get_pull_request fun(self: PowerReview.Provider, pr_id: number, callback: fun(err?: string, pr?: PowerReview.PR))
---@field get_changed_files fun(self: PowerReview.Provider, pr_id: number, callback: fun(err?: string, files?: PowerReview.ChangedFile[]))
---@field get_threads fun(self: PowerReview.Provider, pr_id: number, callback: fun(err?: string, threads?: PowerReview.CommentThread[]))
---@field create_thread fun(self: PowerReview.Provider, pr_id: number, thread: table, callback: fun(err?: string, thread?: PowerReview.CommentThread))
---@field reply_to_thread fun(self: PowerReview.Provider, pr_id: number, thread_id: number, body: string, callback: fun(err?: string, comment?: PowerReview.Comment))
---@field update_comment fun(self: PowerReview.Provider, pr_id: number, thread_id: number, comment_id: number, body: string, callback: fun(err?: string, comment?: PowerReview.Comment))
---@field delete_comment fun(self: PowerReview.Provider, pr_id: number, thread_id: number, comment_id: number, callback: fun(err?: string, ok?: boolean))
---@field set_vote fun(self: PowerReview.Provider, pr_id: number, reviewer_id: string, vote: PowerReview.ReviewVote, callback: fun(err?: string, ok?: boolean))
---@field get_file_content fun(self: PowerReview.Provider, pr_id: number, file_path: string, version: string, callback: fun(err?: string, content?: string))

return {}
