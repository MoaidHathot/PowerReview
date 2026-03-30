using PowerReview.Core.Models;

namespace PowerReview.Core.Providers;

/// <summary>
/// Interface for interacting with a PR hosting provider (Azure DevOps, GitHub, etc.).
/// All methods that contact the remote API are async.
/// </summary>
public interface IProvider
{
    /// <summary>
    /// The provider type identifier.
    /// </summary>
    ProviderType ProviderType { get; }

    /// <summary>
    /// Fetch pull request metadata.
    /// </summary>
    Task<PullRequest> GetPullRequestAsync(int prId, CancellationToken ct = default);

    /// <summary>
    /// Fetch the list of changed files in a pull request.
    /// Returns both the files and iteration metadata.
    /// </summary>
    Task<(List<ChangedFile> Files, IterationMeta Iteration)> GetChangedFilesAsync(int prId, CancellationToken ct = default);

    /// <summary>
    /// Fetch all non-system comment threads on a pull request.
    /// </summary>
    Task<List<CommentThread>> GetThreadsAsync(int prId, CancellationToken ct = default);

    /// <summary>
    /// Create a new comment thread on a pull request.
    /// </summary>
    Task<CommentThread> CreateThreadAsync(int prId, CreateThreadRequest request, CancellationToken ct = default);

    /// <summary>
    /// Reply to an existing comment thread.
    /// </summary>
    Task<Comment> ReplyToThreadAsync(int prId, int threadId, string body, CancellationToken ct = default);

    /// <summary>
    /// Update an existing comment's body.
    /// </summary>
    Task<Comment> UpdateCommentAsync(int prId, int threadId, int commentId, string body, CancellationToken ct = default);

    /// <summary>
    /// Delete a comment.
    /// </summary>
    Task DeleteCommentAsync(int prId, int threadId, int commentId, CancellationToken ct = default);

    /// <summary>
    /// Set the review vote for the current user.
    /// </summary>
    Task SetVoteAsync(int prId, string reviewerId, int vote, CancellationToken ct = default);

    /// <summary>
    /// Get the content of a file at a specific branch/ref.
    /// </summary>
    Task<string> GetFileContentAsync(string filePath, string branch, CancellationToken ct = default);

    /// <summary>
    /// Get the current authenticated user's reviewer ID.
    /// </summary>
    Task<string> GetCurrentReviewerIdAsync(CancellationToken ct = default);
}

/// <summary>
/// Request to create a new comment thread.
/// </summary>
public sealed class CreateThreadRequest
{
    public string? FilePath { get; set; }
    public int? LineStart { get; set; }
    public int? LineEnd { get; set; }
    public int? ColStart { get; set; }
    public int? ColEnd { get; set; }
    public string Body { get; set; } = "";
    public ThreadStatus Status { get; set; } = ThreadStatus.Active;
}
