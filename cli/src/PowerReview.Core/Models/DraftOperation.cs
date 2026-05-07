using System.Text.Json.Serialization;

namespace PowerReview.Core.Models;

/// <summary>
/// A local approval-gated operation that has not yet been applied to the remote provider.
/// Follows the lifecycle: Draft -> Pending -> Submitted.
/// </summary>
public class DraftOperation
{
    [JsonPropertyName("operation_type")]
    public DraftOperationType OperationType { get; set; }

    [JsonPropertyName("status")]
    public DraftStatus Status { get; set; } = DraftStatus.Draft;

    [JsonPropertyName("author")]
    public DraftAuthor Author { get; set; } = DraftAuthor.User;

    [JsonPropertyName("author_name")]
    public string? AuthorName { get; set; }

    [JsonPropertyName("file_path")]
    public string FilePath { get; set; } = "";

    /// <summary>
    /// Null means a file-level comment (no specific line).
    /// </summary>
    [JsonPropertyName("line_start")]
    public int? LineStart { get; set; }

    [JsonPropertyName("line_end")]
    public int? LineEnd { get; set; }

    [JsonPropertyName("col_start")]
    public int? ColStart { get; set; }

    [JsonPropertyName("col_end")]
    public int? ColEnd { get; set; }

    [JsonPropertyName("body")]
    public string? Body { get; set; }

    [JsonPropertyName("thread_id")]
    public int? ThreadId { get; set; }

    [JsonPropertyName("parent_comment_id")]
    public int? ParentCommentId { get; set; }

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
    public bool CanEdit => Status == DraftStatus.Draft && OperationType is DraftOperationType.Comment or DraftOperationType.Reply;

    [JsonIgnore]
    public bool CanDelete => Status == DraftStatus.Draft;

    [JsonIgnore]
    public bool IsComment => OperationType is DraftOperationType.Comment or DraftOperationType.Reply;

    [JsonIgnore]
    public bool IsReply => OperationType == DraftOperationType.Reply || ThreadId.HasValue;

    [JsonIgnore]
    public bool IsAiAuthored => Author == DraftAuthor.Ai;
}
