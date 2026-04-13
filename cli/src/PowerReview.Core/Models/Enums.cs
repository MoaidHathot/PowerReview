using System.Text.Json.Serialization;

namespace PowerReview.Core.Models;

/// <summary>
/// Status of a draft comment in the review lifecycle.
/// </summary>
[JsonConverter(typeof(JsonStringEnumConverter<DraftStatus>))]
public enum DraftStatus
{
    /// <summary>Local draft, not yet approved for submission.</summary>
    Draft,

    /// <summary>Approved and ready for submission to the remote provider.</summary>
    Pending,

    /// <summary>Successfully submitted to the remote provider.</summary>
    Submitted,
}

/// <summary>
/// Who authored a draft comment.
/// </summary>
[JsonConverter(typeof(JsonStringEnumConverter<DraftAuthor>))]
public enum DraftAuthor
{
    /// <summary>Human user.</summary>
    User,

    /// <summary>AI agent (MCP, copilot, etc.).</summary>
    Ai,
}

/// <summary>
/// Type of change made to a file in a pull request.
/// </summary>
[JsonConverter(typeof(JsonStringEnumConverter<ChangeType>))]
public enum ChangeType
{
    Add,
    Edit,
    Delete,
    Rename,
}

/// <summary>
/// Status of a comment thread on the remote provider.
/// </summary>
[JsonConverter(typeof(JsonStringEnumConverter<ThreadStatus>))]
public enum ThreadStatus
{
    Active,
    Fixed,
    WontFix,
    Closed,
    ByDesign,
    Pending,
}

/// <summary>
/// PR review vote values. Numeric values match Azure DevOps convention.
/// </summary>
[JsonConverter(typeof(JsonStringEnumConverter<VoteValue>))]
public enum VoteValue
{
    Approve = 10,
    ApproveWithSuggestions = 5,
    NoVote = 0,
    WaitForAuthor = -5,
    Reject = -10,
}

/// <summary>
/// Status of a pull request.
/// </summary>
[JsonConverter(typeof(JsonStringEnumConverter<PullRequestStatus>))]
public enum PullRequestStatus
{
    Active,
    Completed,
    Abandoned,
}

/// <summary>
/// Merge status of a pull request.
/// </summary>
[JsonConverter(typeof(JsonStringEnumConverter<MergeStatus>))]
public enum MergeStatus
{
    Succeeded,
    Conflicts,
    Queued,
    NotSet,
    Failure,
}

/// <summary>
/// Git strategy for managing the review working directory.
/// </summary>
[JsonConverter(typeof(JsonStringEnumConverter<GitStrategy>))]
public enum GitStrategy
{
    Worktree,
    Clone,
    Cwd,
}

/// <summary>
/// Status of a proposed code fix in the review lifecycle.
/// </summary>
[JsonConverter(typeof(JsonStringEnumConverter<ProposalStatus>))]
public enum ProposalStatus
{
    /// <summary>Draft proposal, not yet approved.</summary>
    Draft,

    /// <summary>Approved by the user, ready to be applied.</summary>
    Approved,

    /// <summary>Successfully applied (merged into PR branch).</summary>
    Applied,

    /// <summary>Rejected by the user.</summary>
    Rejected,
}

/// <summary>
/// Supported PR hosting providers.
/// </summary>
[JsonConverter(typeof(JsonStringEnumConverter<ProviderType>))]
public enum ProviderType
{
    AzDo,
    GitHub,
}
