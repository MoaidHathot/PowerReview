using System.Text.Json.Serialization;

namespace PowerReview.Core.Models;

/// <summary>
/// Identity of a person (PR author, commenter, reviewer).
/// </summary>
public sealed class PersonIdentity
{
    [JsonPropertyName("name")]
    public string Name { get; set; } = "";

    [JsonPropertyName("id")]
    public string? Id { get; set; }

    [JsonPropertyName("unique_name")]
    public string? UniqueName { get; set; }
}

/// <summary>
/// A reviewer on a pull request.
/// </summary>
public sealed class Reviewer
{
    [JsonPropertyName("name")]
    public string Name { get; set; } = "";

    [JsonPropertyName("id")]
    public string? Id { get; set; }

    [JsonPropertyName("unique_name")]
    public string? UniqueName { get; set; }

    [JsonPropertyName("vote")]
    public int? Vote { get; set; }

    [JsonPropertyName("is_required")]
    public bool IsRequired { get; set; }

    [JsonPropertyName("vote_label")]
    public string VoteLabel => Vote switch
    {
        10 => "approved",
        5 => "approved_with_suggestions",
        -5 => "wait_for_author",
        -10 => "rejected",
        _ => "no_vote",
    };
}

/// <summary>
/// A work item linked to a pull request.
/// </summary>
public sealed class WorkItem
{
    [JsonPropertyName("id")]
    public int Id { get; set; }

    [JsonPropertyName("title")]
    public string Title { get; set; } = "";

    [JsonPropertyName("url")]
    public string Url { get; set; } = "";

    [JsonPropertyName("type")]
    public string Type { get; set; } = "";

    [JsonPropertyName("state")]
    public string State { get; set; } = "";

    [JsonPropertyName("tags")]
    public List<string> Tags { get; set; } = [];

    [JsonPropertyName("area_path")]
    public string AreaPath { get; set; } = "";

    [JsonPropertyName("iteration_path")]
    public string IterationPath { get; set; } = "";
}

/// <summary>
/// A file changed in a pull request.
/// </summary>
public sealed class ChangedFile
{
    [JsonPropertyName("path")]
    public string Path { get; set; } = "";

    [JsonPropertyName("change_type")]
    public ChangeType ChangeType { get; set; }

    [JsonPropertyName("original_path")]
    public string? OriginalPath { get; set; }
}

/// <summary>
/// Iteration metadata from the provider (AzDO-specific currently).
/// </summary>
public sealed class IterationMeta
{
    [JsonPropertyName("id")]
    public int? Id { get; set; }

    [JsonPropertyName("source_commit")]
    public string? SourceCommit { get; set; }

    [JsonPropertyName("target_commit")]
    public string? TargetCommit { get; set; }
}

/// <summary>
/// Tracks the reviewer's progress through iterations.
/// Persisted in the session to survive across Neovim restarts.
/// </summary>
public sealed class ReviewState
{
    /// <summary>
    /// The iteration ID the reviewer last reviewed against.
    /// Null means no review pass has been started yet.
    /// </summary>
    [JsonPropertyName("reviewed_iteration_id")]
    public int? ReviewedIterationId { get; set; }

    /// <summary>
    /// Source branch commit SHA at the time of the last review.
    /// Used for git-based diff between iterations.
    /// </summary>
    [JsonPropertyName("reviewed_source_commit")]
    public string? ReviewedSourceCommit { get; set; }

    /// <summary>
    /// File paths the reviewer has explicitly marked as reviewed in the current iteration.
    /// </summary>
    [JsonPropertyName("reviewed_files")]
    public List<string> ReviewedFiles { get; set; } = [];

    /// <summary>
    /// File paths that have changes since the last reviewed iteration.
    /// Computed when a new iteration is detected via git diff --name-only.
    /// </summary>
    [JsonPropertyName("changed_since_review")]
    public List<string> ChangedSinceReview { get; set; } = [];
}
