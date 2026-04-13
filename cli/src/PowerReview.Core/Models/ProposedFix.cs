using System.Text.Json.Serialization;

namespace PowerReview.Core.Models;

/// <summary>
/// A proposed code fix that an AI agent has created in response to a PR comment.
/// The fix lives on a temporary branch and must be approved before being applied (merged)
/// into the PR's source branch.
/// Lifecycle: Draft -> Approved -> Applied (or Rejected).
/// </summary>
public sealed class ProposedFix
{
    /// <summary>
    /// The remote thread ID this proposal responds to.
    /// </summary>
    [JsonPropertyName("thread_id")]
    public int ThreadId { get; set; }

    /// <summary>
    /// Human-readable description of what this fix does.
    /// </summary>
    [JsonPropertyName("description")]
    public string Description { get; set; } = "";

    [JsonPropertyName("status")]
    public ProposalStatus Status { get; set; } = ProposalStatus.Draft;

    [JsonPropertyName("author")]
    public DraftAuthor Author { get; set; } = DraftAuthor.Ai;

    /// <summary>
    /// Optional display name identifying the agent that created this proposal.
    /// </summary>
    [JsonPropertyName("author_name")]
    public string? AuthorName { get; set; }

    /// <summary>
    /// Name of the temporary branch holding the fix commits.
    /// Convention: powerreview/fix/thread-{threadId}
    /// </summary>
    [JsonPropertyName("branch_name")]
    public string BranchName { get; set; } = "";

    /// <summary>
    /// List of file paths modified by this fix.
    /// </summary>
    [JsonPropertyName("files_changed")]
    public List<string> FilesChanged { get; set; } = [];

    /// <summary>
    /// Optional linked draft reply UUID. When the proposal is approved,
    /// the linked reply is auto-approved for submission.
    /// </summary>
    [JsonPropertyName("reply_draft_id")]
    public string? ReplyDraftId { get; set; }

    [JsonPropertyName("created_at")]
    public string CreatedAt { get; set; } = "";

    [JsonPropertyName("updated_at")]
    public string UpdatedAt { get; set; } = "";

    /// <summary>
    /// Whether this proposal can be edited (only in Draft status).
    /// </summary>
    [JsonIgnore]
    public bool CanEdit => Status == ProposalStatus.Draft;

    /// <summary>
    /// Whether this proposal can be approved (only in Draft status).
    /// </summary>
    [JsonIgnore]
    public bool CanApprove => Status == ProposalStatus.Draft;

    /// <summary>
    /// Whether this proposal can be applied (only in Approved status).
    /// </summary>
    [JsonIgnore]
    public bool CanApply => Status == ProposalStatus.Approved;

    /// <summary>
    /// Whether this proposal was authored by an AI agent.
    /// </summary>
    [JsonIgnore]
    public bool IsAiAuthored => Author == DraftAuthor.Ai;
}

/// <summary>
/// Information about the fix worktree created for AI agents to make code changes.
/// One worktree per PR, reused across all fixes for that PR.
/// </summary>
public sealed class FixWorktreeInfo
{
    /// <summary>
    /// Filesystem path to the worktree directory.
    /// </summary>
    [JsonPropertyName("path")]
    public string Path { get; set; } = "";

    /// <summary>
    /// The PR source branch this worktree was created from.
    /// </summary>
    [JsonPropertyName("base_branch")]
    public string BaseBranch { get; set; } = "";

    [JsonPropertyName("created_at")]
    public string CreatedAt { get; set; } = "";
}
