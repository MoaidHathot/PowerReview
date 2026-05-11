using System.Text.Json.Serialization;

namespace PowerReview.Core.Models;

/// <summary>
/// The complete review session persisted to disk.
/// This is the v7 session format — the source of truth for all review state.
/// </summary>
public sealed class ReviewSession
{
    public const int CurrentVersion = 8;

    [JsonPropertyName("version")]
    public int Version { get; set; } = CurrentVersion;

    [JsonPropertyName("id")]
    public string Id { get; set; } = "";

    [JsonPropertyName("provider")]
    public ProviderInfo Provider { get; set; } = new();

    /// <summary>
    /// Identity of the locally-authenticated user for this session.
    /// Populated on session open via the provider's "current user" endpoint.
    /// Used to classify incoming comments as authored by me vs. others.
    /// Null on legacy sessions until the next sync (or an explicit
    /// <c>identity --refresh</c>) populates it.
    /// </summary>
    [JsonPropertyName("local_identity")]
    public LocalIdentity? LocalIdentity { get; set; }

    [JsonPropertyName("pull_request")]
    public PullRequestInfo PullRequest { get; set; } = new();

    [JsonPropertyName("iteration")]
    public IterationMeta Iteration { get; set; } = new();

    /// <summary>
    /// Reviewer's progress state — tracks which files have been reviewed
    /// and which iteration was last reviewed against.
    /// </summary>
    [JsonPropertyName("review")]
    public ReviewState Review { get; set; } = new();

    [JsonPropertyName("git")]
    public GitInfo Git { get; set; } = new();

    [JsonPropertyName("files")]
    public List<ChangedFile> Files { get; set; } = [];

    [JsonPropertyName("threads")]
    public ThreadsInfo Threads { get; set; } = new();

    /// <summary>
    /// Approval-gated draft operations keyed by UUID. Operations can create comments,
    /// reply to threads, change thread status, or apply reactions.
    /// </summary>
    [JsonPropertyName("draft_operations")]
    public Dictionary<string, DraftOperation> DraftOperations { get; set; } = new();

    /// <summary>
    /// Proposed code fixes keyed by UUID. Each proposal represents an AI-suggested
    /// code change on a temporary branch, linked to a comment thread.
    /// </summary>
    [JsonPropertyName("proposals")]
    public Dictionary<string, ProposedFix> Proposals { get; set; } = new();

    /// <summary>
    /// Information about the fix worktree used by AI agents to make code changes.
    /// One worktree per PR, reused across all fixes.
    /// Null if no fix worktree has been created.
    /// </summary>
    [JsonPropertyName("fix_worktree")]
    public FixWorktreeInfo? FixWorktree { get; set; }

    /// <summary>
    /// Derived metadata summaries useful for UI and AI agents.
    /// Recomputed whenever the session is saved or loaded.
    /// </summary>
    [JsonPropertyName("metadata")]
    public ReviewMetadata Metadata { get; set; } = new();

    [JsonPropertyName("vote")]
    public VoteValue? Vote { get; set; }

    [JsonPropertyName("created_at")]
    public string CreatedAt { get; set; } = "";

    [JsonPropertyName("updated_at")]
    public string UpdatedAt { get; set; } = "";

    /// <summary>
    /// Generate a deterministic session ID from provider details.
    /// </summary>
    public static string ComputeId(ProviderType providerType, string org, string project, string repo, int prId)
    {
        var sanitized = $"{providerType}_{org}_{project}_{repo}_{prId}"
            .ToLowerInvariant();

        // Replace anything that's not alphanumeric, hyphen, or underscore
        return System.Text.RegularExpressions.Regex.Replace(sanitized, @"[^a-z0-9\-_]", "_");
    }

    public void NormalizeDraftOperations() { }
}

/// <summary>
/// Provider connection information.
/// </summary>
public sealed class ProviderInfo
{
    [JsonPropertyName("type")]
    public ProviderType Type { get; set; }

    [JsonPropertyName("organization")]
    public string Organization { get; set; } = "";

    [JsonPropertyName("project")]
    public string Project { get; set; } = "";

    [JsonPropertyName("repository")]
    public string Repository { get; set; } = "";
}

/// <summary>
/// Pull request metadata stored in the session.
/// </summary>
public sealed class PullRequestInfo
{
    [JsonPropertyName("id")]
    public int Id { get; set; }

    [JsonPropertyName("url")]
    public string Url { get; set; } = "";

    [JsonPropertyName("title")]
    public string Title { get; set; } = "";

    [JsonPropertyName("description")]
    public string Description { get; set; } = "";

    [JsonPropertyName("author")]
    public PersonIdentity Author { get; set; } = new();

    [JsonPropertyName("source_branch")]
    public string SourceBranch { get; set; } = "";

    [JsonPropertyName("target_branch")]
    public string TargetBranch { get; set; } = "";

    [JsonPropertyName("status")]
    public PullRequestStatus Status { get; set; } = PullRequestStatus.Active;

    [JsonPropertyName("is_draft")]
    public bool IsDraft { get; set; }

    [JsonPropertyName("merge_status")]
    public MergeStatus? MergeStatus { get; set; }

    [JsonPropertyName("created_at")]
    public string CreatedAt { get; set; } = "";

    [JsonPropertyName("closed_at")]
    public string? ClosedAt { get; set; }

    [JsonPropertyName("reviewers")]
    public List<Reviewer> Reviewers { get; set; } = [];

    [JsonPropertyName("labels")]
    public List<string> Labels { get; set; } = [];

    [JsonPropertyName("work_items")]
    public List<WorkItem> WorkItems { get; set; } = [];
}

/// <summary>
/// Git working directory information.
/// </summary>
public sealed class GitInfo
{
    [JsonPropertyName("repo_path")]
    public string? RepoPath { get; set; }

    [JsonPropertyName("worktree_path")]
    public string? WorktreePath { get; set; }

    [JsonPropertyName("strategy")]
    public GitStrategy Strategy { get; set; } = GitStrategy.Worktree;
}

/// <summary>
/// Container for remote threads with sync metadata.
/// </summary>
public sealed class ThreadsInfo
{
    /// <summary>
    /// When threads were last synced from the remote provider.
    /// Null means threads have never been synced.
    /// </summary>
    [JsonPropertyName("synced_at")]
    public string? SyncedAt { get; set; }

    [JsonPropertyName("items")]
    public List<CommentThread> Items { get; set; } = [];

    /// <summary>
    /// Compact snapshot of the previous sync's comments, used by
    /// <c>ReplyClassifier</c> to compute <see cref="LastDeltas"/> on the next sync.
    /// One entry per non-deleted comment, identified by thread+comment id and
    /// fingerprinted with the comment's <c>updated_at</c> so edits are detected
    /// in addition to brand-new comments.
    ///
    /// Empty list means "no prior snapshot" — the next sync will silently prime
    /// the snapshot without producing deltas (avoids flooding the user/AI with
    /// "everything is new" on first upgrade).
    /// </summary>
    [JsonPropertyName("previous_sync_snapshot")]
    public List<CommentSnapshotEntry> PreviousSyncSnapshot { get; set; } = [];

    /// <summary>
    /// Per-thread acknowledgement watermarks. A reply with <c>comment.id &lt;=
    /// through_comment_id</c> for its thread is considered "already handled" and
    /// is suppressed from <see cref="LastDeltas"/> on subsequent syncs.
    /// Keyed by thread id (as a string for JSON-friendliness).
    /// </summary>
    [JsonPropertyName("thread_acks")]
    public Dictionary<string, ThreadAckEntry> ThreadAcks { get; set; } = new();

    /// <summary>
    /// Classified deltas computed by <c>ReplyClassifier</c> on the most recent
    /// sync. Recomputed on every sync; consumers (MCP <c>SyncThreads</c> /
    /// <c>GetNewReplies</c>, the Lua watcher, the UI) read this to surface new
    /// replies without re-running the diff themselves.
    /// </summary>
    [JsonPropertyName("last_deltas")]
    public ReplyDeltas? LastDeltas { get; set; }
}

/// <summary>
/// Compact snapshot entry used to diff sync results. Kept small on purpose so
/// the session JSON doesn't bloat on PRs with many comments.
/// </summary>
public sealed class CommentSnapshotEntry
{
    [JsonPropertyName("t")]
    public int ThreadId { get; set; }

    [JsonPropertyName("c")]
    public int CommentId { get; set; }

    /// <summary>ISO timestamp of the comment's <c>updated_at</c> at snapshot time.</summary>
    [JsonPropertyName("u")]
    public string? UpdatedAt { get; set; }
}

/// <summary>
/// Acknowledgement watermark for a single thread.
/// </summary>
public sealed class ThreadAckEntry
{
    /// <summary>
    /// All comments with <c>id &lt;= ThroughCommentId</c> on this thread are
    /// considered acknowledged.
    /// </summary>
    [JsonPropertyName("through_comment_id")]
    public int ThroughCommentId { get; set; }

    /// <summary>ISO timestamp of when the ack was recorded.</summary>
    [JsonPropertyName("at")]
    public string At { get; set; } = "";

    /// <summary>Who acknowledged: "ai" or "human".</summary>
    [JsonPropertyName("acked_by")]
    public string AckedBy { get; set; } = "human";
}

/// <summary>
/// Output of <c>ReplyClassifier</c>: the set of new/edited comments seen on the
/// most recent sync, broken down by relationship to the local user / AI.
///
/// Comments authored by the local user or AI (<c>self_echo</c>) are intentionally
/// not surfaced anywhere — they're computed for completeness but consumers
/// should ignore them.
/// </summary>
public sealed class ReplyDeltas
{
    [JsonPropertyName("computed_at")]
    public string ComputedAt { get; set; } = "";

    /// <summary>
    /// New comments that arrived in a thread the AI participated in (i.e. there
    /// is at least one published draft authored by AI in the thread). Highest
    /// priority for AI-driven follow-ups.
    /// </summary>
    [JsonPropertyName("reply_to_ai")]
    public List<DeltaComment> ReplyToAi { get; set; } = [];

    /// <summary>
    /// New comments in a thread the local user (human) participated in but where
    /// the AI did not. The AI may still want to look at these depending on the
    /// requested scope.
    /// </summary>
    [JsonPropertyName("reply_to_human")]
    public List<DeltaComment> ReplyToHuman { get; set; } = [];

    /// <summary>
    /// New comments in threads where neither the local user nor the AI ever
    /// participated. Off by default in toast notifications; useful for full-PR
    /// awareness when explicitly requested.
    /// </summary>
    [JsonPropertyName("reply_in_others_thread")]
    public List<DeltaComment> ReplyInOthersThread { get; set; } = [];

    /// <summary>
    /// Brand-new threads (the thread id was not present in the previous
    /// snapshot) authored by someone other than the local user / AI.
    /// </summary>
    [JsonPropertyName("new_thread_others")]
    public List<DeltaComment> NewThreadOthers { get; set; } = [];

    /// <summary>
    /// New/edited comments authored by the local user or by AI (i.e. our own
    /// publish reflected back from the server). Surfaced for completeness;
    /// consumers should not treat these as actionable.
    /// </summary>
    [JsonPropertyName("self_echo")]
    public List<DeltaComment> SelfEcho { get; set; } = [];
}

/// <summary>
/// Single classified entry in <see cref="ReplyDeltas"/>. Self-contained so
/// consumers can render/dispatch without re-joining against
/// <see cref="ThreadsInfo.Items"/>.
/// </summary>
public sealed class DeltaComment
{
    [JsonPropertyName("thread_id")]
    public int ThreadId { get; set; }

    [JsonPropertyName("comment_id")]
    public int CommentId { get; set; }

    [JsonPropertyName("parent_comment_id")]
    public int? ParentCommentId { get; set; }

    /// <summary>"new" if this comment id is brand-new; "edited" if the id was already known but updated_at changed.</summary>
    [JsonPropertyName("change")]
    public string Change { get; set; } = "new";

    [JsonPropertyName("file_path")]
    public string? FilePath { get; set; }

    [JsonPropertyName("line_start")]
    public int? LineStart { get; set; }

    [JsonPropertyName("line_end")]
    public int? LineEnd { get; set; }

    [JsonPropertyName("author")]
    public PersonIdentity Author { get; set; } = new();

    [JsonPropertyName("created_at")]
    public string CreatedAt { get; set; } = "";

    [JsonPropertyName("updated_at")]
    public string UpdatedAt { get; set; } = "";

    /// <summary>
    /// Short preview of the comment body (first 200 chars, single-line) so AI
    /// consumers can decide whether to fetch the full thread without an extra
    /// round-trip.
    /// </summary>
    [JsonPropertyName("body_preview")]
    public string BodyPreview { get; set; } = "";

    /// <summary>True if the thread contains any AI-authored published draft.</summary>
    [JsonPropertyName("ai_participated")]
    public bool AiParticipated { get; set; }

    /// <summary>True if the thread contains any comment authored by the local user (id-matched).</summary>
    [JsonPropertyName("human_participated")]
    public bool HumanParticipated { get; set; }
}
