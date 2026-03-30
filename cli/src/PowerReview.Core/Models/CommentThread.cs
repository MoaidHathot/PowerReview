using System.Text.Json.Serialization;

namespace PowerReview.Core.Models;

/// <summary>
/// A single comment within a thread on the remote provider.
/// </summary>
public sealed class Comment
{
    [JsonPropertyName("id")]
    public int Id { get; set; }

    [JsonPropertyName("thread_id")]
    public int ThreadId { get; set; }

    [JsonPropertyName("author")]
    public PersonIdentity Author { get; set; } = new();

    [JsonPropertyName("parent_comment_id")]
    public int? ParentCommentId { get; set; }

    [JsonPropertyName("body")]
    public string Body { get; set; } = "";

    [JsonPropertyName("created_at")]
    public string CreatedAt { get; set; } = "";

    [JsonPropertyName("updated_at")]
    public string UpdatedAt { get; set; } = "";

    [JsonPropertyName("is_deleted")]
    public bool IsDeleted { get; set; }
}

/// <summary>
/// A comment thread from the remote provider.
/// </summary>
public sealed class CommentThread
{
    [JsonPropertyName("id")]
    public int Id { get; set; }

    [JsonPropertyName("file_path")]
    public string? FilePath { get; set; }

    [JsonPropertyName("line_start")]
    public int? LineStart { get; set; }

    [JsonPropertyName("line_end")]
    public int? LineEnd { get; set; }

    [JsonPropertyName("col_start")]
    public int? ColStart { get; set; }

    [JsonPropertyName("col_end")]
    public int? ColEnd { get; set; }

    [JsonPropertyName("left_line_start")]
    public int? LeftLineStart { get; set; }

    [JsonPropertyName("left_line_end")]
    public int? LeftLineEnd { get; set; }

    [JsonPropertyName("status")]
    public ThreadStatus Status { get; set; } = ThreadStatus.Active;

    [JsonPropertyName("comments")]
    public List<Comment> Comments { get; set; } = [];

    [JsonPropertyName("is_deleted")]
    public bool IsDeleted { get; set; }

    [JsonPropertyName("published_at")]
    public string? PublishedAt { get; set; }

    [JsonPropertyName("updated_at")]
    public string? UpdatedAt { get; set; }
}
