using System.Text.Json.Serialization;

namespace PowerReview.Core.Models;

/// <summary>
/// A local draft comment that has not yet been submitted to the remote provider.
/// Follows the lifecycle: Draft -> Pending -> Submitted.
/// </summary>
public sealed class DraftComment
{
    [JsonPropertyName("file_path")]
    public string FilePath { get; set; } = "";

    [JsonPropertyName("line_start")]
    public int LineStart { get; set; }

    [JsonPropertyName("line_end")]
    public int? LineEnd { get; set; }

    [JsonPropertyName("col_start")]
    public int? ColStart { get; set; }

    [JsonPropertyName("col_end")]
    public int? ColEnd { get; set; }

    [JsonPropertyName("body")]
    public string Body { get; set; } = "";

    [JsonPropertyName("status")]
    public DraftStatus Status { get; set; } = DraftStatus.Draft;

    [JsonPropertyName("author")]
    public DraftAuthor Author { get; set; } = DraftAuthor.User;

    /// <summary>
    /// If set, this draft is a reply to an existing remote thread.
    /// If null, this draft will create a new thread on submission.
    /// </summary>
    [JsonPropertyName("thread_id")]
    public int? ThreadId { get; set; }

    [JsonPropertyName("parent_comment_id")]
    public int? ParentCommentId { get; set; }

    [JsonPropertyName("created_at")]
    public string CreatedAt { get; set; } = "";

    [JsonPropertyName("updated_at")]
    public string UpdatedAt { get; set; } = "";

    /// <summary>
    /// Whether this draft can be edited (only in Draft status).
    /// </summary>
    [JsonIgnore]
    public bool CanEdit => Status == DraftStatus.Draft;

    /// <summary>
    /// Whether this draft can be deleted (only in Draft status).
    /// </summary>
    [JsonIgnore]
    public bool CanDelete => Status == DraftStatus.Draft;

    /// <summary>
    /// Whether this draft is a reply to an existing remote thread.
    /// </summary>
    [JsonIgnore]
    public bool IsReply => ThreadId.HasValue;

    /// <summary>
    /// Whether this draft was authored by an AI agent.
    /// </summary>
    [JsonIgnore]
    public bool IsAiAuthored => Author == DraftAuthor.Ai;
}
