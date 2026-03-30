using System.Text.Json.Serialization;

namespace PowerReview.Core.Models;

/// <summary>
/// The complete review session persisted to disk.
/// This is the v3 session format — the source of truth for all review state.
/// </summary>
public sealed class ReviewSession
{
    public const int CurrentVersion = 3;

    [JsonPropertyName("version")]
    public int Version { get; set; } = CurrentVersion;

    [JsonPropertyName("id")]
    public string Id { get; set; } = "";

    [JsonPropertyName("provider")]
    public ProviderInfo Provider { get; set; } = new();

    [JsonPropertyName("pull_request")]
    public PullRequestInfo PullRequest { get; set; } = new();

    [JsonPropertyName("iteration")]
    public IterationMeta Iteration { get; set; } = new();

    [JsonPropertyName("git")]
    public GitInfo Git { get; set; } = new();

    [JsonPropertyName("files")]
    public List<ChangedFile> Files { get; set; } = [];

    [JsonPropertyName("threads")]
    public ThreadsInfo Threads { get; set; } = new();

    /// <summary>
    /// Draft comments keyed by UUID. Map for O(1) lookups.
    /// </summary>
    [JsonPropertyName("drafts")]
    public Dictionary<string, DraftComment> Drafts { get; set; } = new();

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
}
