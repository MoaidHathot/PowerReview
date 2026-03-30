using System.Text.Json.Serialization;

namespace PowerReview.Core.Models;

/// <summary>
/// Result of submitting pending draft comments to the remote provider.
/// </summary>
public sealed class SubmitResult
{
    [JsonPropertyName("submitted")]
    public int Submitted { get; set; }

    [JsonPropertyName("failed")]
    public int Failed { get; set; }

    [JsonPropertyName("total")]
    public int Total { get; set; }

    [JsonPropertyName("errors")]
    public List<SubmitError> Errors { get; set; } = [];
}

/// <summary>
/// A single submission error for a draft comment.
/// </summary>
public sealed class SubmitError
{
    [JsonPropertyName("draft_id")]
    public string DraftId { get; set; } = "";

    [JsonPropertyName("file_path")]
    public string FilePath { get; set; } = "";

    [JsonPropertyName("error")]
    public string Error { get; set; } = "";
}
