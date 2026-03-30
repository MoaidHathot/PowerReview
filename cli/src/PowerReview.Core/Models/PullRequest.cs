using System.Text.Json.Serialization;

namespace PowerReview.Core.Models;

/// <summary>
/// Pull request metadata from the remote provider.
/// </summary>
public sealed class PullRequest
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

    [JsonPropertyName("provider_type")]
    public ProviderType ProviderType { get; set; }
}
