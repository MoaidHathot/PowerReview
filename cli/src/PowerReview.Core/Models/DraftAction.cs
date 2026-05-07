using System.Text.Json.Serialization;

namespace PowerReview.Core.Models;

/// <summary>
/// A local draft review action that has not yet been applied to the remote provider.
/// Follows the same lifecycle as draft comments: Draft -> Pending -> Submitted.
/// </summary>
public sealed class DraftAction
{
    [JsonPropertyName("action_type")]
    public DraftActionType ActionType { get; set; }

    [JsonPropertyName("status")]
    public DraftStatus Status { get; set; } = DraftStatus.Draft;

    [JsonPropertyName("author")]
    public DraftAuthor Author { get; set; } = DraftAuthor.User;

    [JsonPropertyName("author_name")]
    public string? AuthorName { get; set; }

    [JsonPropertyName("thread_id")]
    public int ThreadId { get; set; }

    [JsonPropertyName("comment_id")]
    public int? CommentId { get; set; }

    [JsonPropertyName("from_thread_status")]
    public ThreadStatus? FromThreadStatus { get; set; }

    [JsonPropertyName("to_thread_status")]
    public ThreadStatus? ToThreadStatus { get; set; }

    [JsonPropertyName("reaction")]
    public CommentReaction? Reaction { get; set; }

    [JsonPropertyName("note")]
    public string? Note { get; set; }

    [JsonPropertyName("created_at")]
    public string CreatedAt { get; set; } = "";

    [JsonPropertyName("updated_at")]
    public string UpdatedAt { get; set; } = "";

    [JsonIgnore]
    public bool CanEdit => Status == DraftStatus.Draft;

    [JsonIgnore]
    public bool CanDelete => Status == DraftStatus.Draft;

    [JsonIgnore]
    public bool IsAiAuthored => Author == DraftAuthor.Ai;
}
