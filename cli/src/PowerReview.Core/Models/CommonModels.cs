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
