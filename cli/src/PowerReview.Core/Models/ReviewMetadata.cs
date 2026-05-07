using System.Text.Json.Serialization;

namespace PowerReview.Core.Models;

/// <summary>
/// Derived PR/session metadata useful for humans and AI agents.
/// </summary>
public sealed class ReviewMetadata
{
    [JsonPropertyName("reviewers")]
    public ReviewerMetadata Reviewers { get; set; } = new();

    [JsonPropertyName("files")]
    public FileMetadata Files { get; set; } = new();

    [JsonPropertyName("threads")]
    public ThreadMetadata Threads { get; set; } = new();

    [JsonPropertyName("draft_operations")]
    public DraftMetadata DraftOperations { get; set; } = new();

    [JsonPropertyName("work_items")]
    public WorkItemMetadata WorkItems { get; set; } = new();

    [JsonPropertyName("review")]
    public ReviewProgressMetadata Review { get; set; } = new();

    [JsonPropertyName("iteration")]
    public IterationMetadataSummary Iteration { get; set; } = new();

    [JsonPropertyName("state")]
    public PullRequestStateMetadata State { get; set; } = new();

    [JsonPropertyName("timestamps")]
    public SessionTimestampsMetadata Timestamps { get; set; } = new();

    public static ReviewMetadata FromSession(ReviewSession session)
    {
        session.NormalizeDraftOperations();
        var files = session.Files ?? [];
        var threads = session.Threads?.Items ?? [];
        var operations = session.DraftOperations?.Values.ToList() ?? [];
        var reviewers = session.PullRequest.Reviewers ?? [];
        var workItems = session.PullRequest.WorkItems ?? [];
        var review = session.Review ?? new ReviewState();
        var reviewedFiles = review.ReviewedFiles ?? [];
        var changedSinceReview = review.ChangedSinceReview ?? [];

        var reviewerCounts = reviewers
            .GroupBy(r => VoteLabel(r.Vote))
            .ToDictionary(g => g.Key, g => g.Count());

        var threadCounts = threads
            .GroupBy(t => t.Status.ToString().ToLowerInvariant())
            .ToDictionary(g => g.Key, g => g.Count());

        var draftCounts = operations
            .GroupBy(o => o.Status.ToString().ToLowerInvariant())
            .ToDictionary(g => g.Key, g => g.Count());

        var operationCounts = operations
            .GroupBy(o => o.OperationType.ToString().ToLowerInvariant())
            .ToDictionary(g => g.Key, g => g.Count());

        var changedFileCount = files.Count;
        var reviewedCount = reviewedFiles.Count;
        var changedCount = changedSinceReview.Count;
        var unreviewedCount = Math.Max(0, changedFileCount - reviewedCount - changedCount);

        return new ReviewMetadata
        {
            Reviewers = new ReviewerMetadata
            {
                Total = reviewers.Count,
                Required = reviewers.Count(r => r.IsRequired),
                Optional = reviewers.Count(r => !r.IsRequired),
                Approved = reviewerCounts.GetValueOrDefault("approved"),
                ApprovedWithSuggestions = reviewerCounts.GetValueOrDefault("approved_with_suggestions"),
                WaitingForAuthor = reviewerCounts.GetValueOrDefault("wait_for_author"),
                Rejected = reviewerCounts.GetValueOrDefault("rejected"),
                NoVote = reviewerCounts.GetValueOrDefault("no_vote"),
                RequiredPending = reviewers.Count(r => r.IsRequired && r.Vote is null or 0),
            },
            Files = new FileMetadata
            {
                Total = changedFileCount,
                Added = files.Count(f => f.ChangeType == ChangeType.Add),
                Edited = files.Count(f => f.ChangeType == ChangeType.Edit),
                Deleted = files.Count(f => f.ChangeType == ChangeType.Delete),
                Renamed = files.Count(f => f.ChangeType == ChangeType.Rename),
            },
            Threads = new ThreadMetadata
            {
                Total = threads.Count,
                Active = threadCounts.GetValueOrDefault("active"),
                Fixed = threadCounts.GetValueOrDefault("fixed"),
                WontFix = threadCounts.GetValueOrDefault("wontfix"),
                Closed = threadCounts.GetValueOrDefault("closed"),
                ByDesign = threadCounts.GetValueOrDefault("bydesign"),
                Pending = threadCounts.GetValueOrDefault("pending"),
                FileLevel = threads.Count(t => !string.IsNullOrEmpty(t.FilePath) && t.LineStart == null),
                LineLevel = threads.Count(t => !string.IsNullOrEmpty(t.FilePath) && t.LineStart != null),
                PrLevel = threads.Count(t => string.IsNullOrEmpty(t.FilePath)),
            },
            DraftOperations = new DraftMetadata
            {
                Total = operations.Count(o => o.IsComment || o.OperationType == 0),
                Draft = draftCounts.GetValueOrDefault("draft"),
                Pending = draftCounts.GetValueOrDefault("pending"),
                Submitted = draftCounts.GetValueOrDefault("submitted"),
                AiAuthored = operations.Count(o => o.Author == DraftAuthor.Ai),
                UserAuthored = operations.Count(o => o.Author == DraftAuthor.User),
                Comments = operationCounts.GetValueOrDefault("comment"),
                Replies = operationCounts.GetValueOrDefault("reply"),
                ThreadStatusChanges = operationCounts.GetValueOrDefault("threadstatuschange"),
                CommentReactions = operationCounts.GetValueOrDefault("commentreaction"),
            },
            WorkItems = new WorkItemMetadata
            {
                Total = workItems.Count,
                ByType = workItems
                    .Where(w => !string.IsNullOrWhiteSpace(w.Type))
                    .GroupBy(w => w.Type)
                    .ToDictionary(g => g.Key, g => g.Count()),
                ByState = workItems
                    .Where(w => !string.IsNullOrWhiteSpace(w.State))
                    .GroupBy(w => w.State)
                    .ToDictionary(g => g.Key, g => g.Count()),
            },
            Review = new ReviewProgressMetadata
            {
                ReviewedFiles = reviewedCount,
                ChangedSinceReview = changedCount,
                UnreviewedFiles = unreviewedCount,
                TotalFiles = changedFileCount,
            },
            Iteration = new IterationMetadataSummary
            {
                Id = session.Iteration.Id,
                SourceCommit = session.Iteration.SourceCommit,
                TargetCommit = session.Iteration.TargetCommit,
                ReviewedIterationId = review.ReviewedIterationId,
                ReviewedSourceCommit = review.ReviewedSourceCommit,
            },
            State = new PullRequestStateMetadata
            {
                Status = session.PullRequest.Status.ToString().ToLowerInvariant(),
                IsDraft = session.PullRequest.IsDraft,
                MergeStatus = session.PullRequest.MergeStatus?.ToString().ToLowerInvariant(),
                HasMergeConflicts = session.PullRequest.MergeStatus == MergeStatus.Conflicts,
                Vote = session.Vote?.ToString(),
                VoteLabel = VoteLabel(session.Vote.HasValue ? (int)session.Vote.Value : null),
            },
            Timestamps = new SessionTimestampsMetadata
            {
                CreatedAt = session.CreatedAt,
                UpdatedAt = session.UpdatedAt,
                ThreadsSyncedAt = session.Threads?.SyncedAt,
                PrCreatedAt = session.PullRequest.CreatedAt,
                PrClosedAt = session.PullRequest.ClosedAt,
            },
        };
    }

    private static string VoteLabel(int? vote)
    {
        return vote switch
        {
            10 => "approved",
            5 => "approved_with_suggestions",
            -5 => "wait_for_author",
            -10 => "rejected",
            _ => "no_vote",
        };
    }
}

public sealed class ReviewerMetadata
{
    [JsonPropertyName("total")]
    public int Total { get; set; }

    [JsonPropertyName("required")]
    public int Required { get; set; }

    [JsonPropertyName("optional")]
    public int Optional { get; set; }

    [JsonPropertyName("approved")]
    public int Approved { get; set; }

    [JsonPropertyName("approved_with_suggestions")]
    public int ApprovedWithSuggestions { get; set; }

    [JsonPropertyName("waiting_for_author")]
    public int WaitingForAuthor { get; set; }

    [JsonPropertyName("rejected")]
    public int Rejected { get; set; }

    [JsonPropertyName("no_vote")]
    public int NoVote { get; set; }

    [JsonPropertyName("required_pending")]
    public int RequiredPending { get; set; }
}

public sealed class FileMetadata
{
    [JsonPropertyName("total")]
    public int Total { get; set; }

    [JsonPropertyName("added")]
    public int Added { get; set; }

    [JsonPropertyName("edited")]
    public int Edited { get; set; }

    [JsonPropertyName("deleted")]
    public int Deleted { get; set; }

    [JsonPropertyName("renamed")]
    public int Renamed { get; set; }
}

public sealed class ThreadMetadata
{
    [JsonPropertyName("total")]
    public int Total { get; set; }

    [JsonPropertyName("active")]
    public int Active { get; set; }

    [JsonPropertyName("fixed")]
    public int Fixed { get; set; }

    [JsonPropertyName("wont_fix")]
    public int WontFix { get; set; }

    [JsonPropertyName("closed")]
    public int Closed { get; set; }

    [JsonPropertyName("by_design")]
    public int ByDesign { get; set; }

    [JsonPropertyName("pending")]
    public int Pending { get; set; }

    [JsonPropertyName("file_level")]
    public int FileLevel { get; set; }

    [JsonPropertyName("line_level")]
    public int LineLevel { get; set; }

    [JsonPropertyName("pr_level")]
    public int PrLevel { get; set; }
}

public sealed class DraftMetadata
{
    [JsonPropertyName("total")]
    public int Total { get; set; }

    [JsonPropertyName("draft")]
    public int Draft { get; set; }

    [JsonPropertyName("pending")]
    public int Pending { get; set; }

    [JsonPropertyName("submitted")]
    public int Submitted { get; set; }

    [JsonPropertyName("ai_authored")]
    public int AiAuthored { get; set; }

    [JsonPropertyName("user_authored")]
    public int UserAuthored { get; set; }

    [JsonPropertyName("comments")]
    public int Comments { get; set; }

    [JsonPropertyName("replies")]
    public int Replies { get; set; }

    [JsonPropertyName("thread_status_changes")]
    public int ThreadStatusChanges { get; set; }

    [JsonPropertyName("comment_reactions")]
    public int CommentReactions { get; set; }

}

public sealed class WorkItemMetadata
{
    [JsonPropertyName("total")]
    public int Total { get; set; }

    [JsonPropertyName("by_type")]
    public Dictionary<string, int> ByType { get; set; } = [];

    [JsonPropertyName("by_state")]
    public Dictionary<string, int> ByState { get; set; } = [];
}

public sealed class ReviewProgressMetadata
{
    [JsonPropertyName("reviewed_files")]
    public int ReviewedFiles { get; set; }

    [JsonPropertyName("changed_since_review")]
    public int ChangedSinceReview { get; set; }

    [JsonPropertyName("unreviewed_files")]
    public int UnreviewedFiles { get; set; }

    [JsonPropertyName("total_files")]
    public int TotalFiles { get; set; }
}

public sealed class IterationMetadataSummary
{
    [JsonPropertyName("id")]
    public int? Id { get; set; }

    [JsonPropertyName("source_commit")]
    public string? SourceCommit { get; set; }

    [JsonPropertyName("target_commit")]
    public string? TargetCommit { get; set; }

    [JsonPropertyName("reviewed_iteration_id")]
    public int? ReviewedIterationId { get; set; }

    [JsonPropertyName("reviewed_source_commit")]
    public string? ReviewedSourceCommit { get; set; }
}

public sealed class PullRequestStateMetadata
{
    [JsonPropertyName("status")]
    public string Status { get; set; } = "active";

    [JsonPropertyName("is_draft")]
    public bool IsDraft { get; set; }

    [JsonPropertyName("merge_status")]
    public string? MergeStatus { get; set; }

    [JsonPropertyName("has_merge_conflicts")]
    public bool HasMergeConflicts { get; set; }

    [JsonPropertyName("vote")]
    public string? Vote { get; set; }

    [JsonPropertyName("vote_label")]
    public string VoteLabel { get; set; } = "no_vote";
}

public sealed class SessionTimestampsMetadata
{
    [JsonPropertyName("created_at")]
    public string CreatedAt { get; set; } = "";

    [JsonPropertyName("updated_at")]
    public string UpdatedAt { get; set; } = "";

    [JsonPropertyName("threads_synced_at")]
    public string? ThreadsSyncedAt { get; set; }

    [JsonPropertyName("pr_created_at")]
    public string PrCreatedAt { get; set; } = "";

    [JsonPropertyName("pr_closed_at")]
    public string? PrClosedAt { get; set; }
}
