using System.Text.Json.Serialization;

namespace PowerReview.Core.Models;

/// <summary>
/// Result of submitting pending draft operations to the remote provider.
/// </summary>
public sealed class SubmitResult
{
    [JsonPropertyName("submitted")]
    public int Submitted { get; set; }

    [JsonPropertyName("failed")]
    public int Failed { get; set; }

    [JsonPropertyName("total")]
    public int Total { get; set; }

    [JsonPropertyName("comments_submitted")]
    public int CommentsSubmitted { get; set; }

    [JsonPropertyName("replies_submitted")]
    public int RepliesSubmitted { get; set; }

    [JsonPropertyName("thread_status_changes_submitted")]
    public int ThreadStatusChangesSubmitted { get; set; }

    [JsonPropertyName("comment_reactions_submitted")]
    public int CommentReactionsSubmitted { get; set; }

    [JsonPropertyName("comments_total")]
    public int CommentsTotal { get; set; }

    [JsonPropertyName("replies_total")]
    public int RepliesTotal { get; set; }

    [JsonPropertyName("thread_status_changes_total")]
    public int ThreadStatusChangesTotal { get; set; }

    [JsonPropertyName("comment_reactions_total")]
    public int CommentReactionsTotal { get; set; }

    [JsonPropertyName("errors")]
    public List<SubmitError> Errors { get; set; } = [];
}

/// <summary>
/// A single submission error for a draft operation.
/// </summary>
public sealed class SubmitError
{
    [JsonPropertyName("operation_id")]
    public string OperationId { get; set; } = "";

    [JsonPropertyName("operation_type")]
    public string OperationType { get; set; } = "comment";

    [JsonPropertyName("file_path")]
    public string FilePath { get; set; } = "";

    [JsonPropertyName("error")]
    public string Error { get; set; } = "";
}
