using System.Text.Json;
using System.Text.Json.Serialization;

namespace PowerReview.Core.Providers.AzureDevOps;

/// <summary>
/// Raw Azure DevOps REST API response models.
/// These map 1:1 to the JSON responses from the AzDO API.
/// </summary>
internal static class AzDoApiModels
{
    /// <summary>
    /// Generic list response wrapper ({ value: [...] }).
    /// </summary>
    internal sealed class ListResponse<T>
    {
        [JsonPropertyName("value")]
        public List<T>? Value { get; set; }

        [JsonPropertyName("count")]
        public int Count { get; set; }
    }

    // =========================================================================
    // Pull Request
    // =========================================================================

    internal sealed class PullRequestResponse
    {
        [JsonPropertyName("pullRequestId")]
        public int PullRequestId { get; set; }

        [JsonPropertyName("title")]
        public string? Title { get; set; }

        [JsonPropertyName("description")]
        public string? Description { get; set; }

        [JsonPropertyName("createdBy")]
        public IdentityRef? CreatedBy { get; set; }

        [JsonPropertyName("sourceRefName")]
        public string? SourceRefName { get; set; }

        [JsonPropertyName("targetRefName")]
        public string? TargetRefName { get; set; }

        [JsonPropertyName("status")]
        public string? Status { get; set; }

        [JsonPropertyName("url")]
        public string? Url { get; set; }

        [JsonPropertyName("creationDate")]
        public string? CreationDate { get; set; }

        [JsonPropertyName("closedDate")]
        public string? ClosedDate { get; set; }

        [JsonPropertyName("isDraft")]
        public bool IsDraft { get; set; }

        [JsonPropertyName("mergeStatus")]
        public string? MergeStatus { get; set; }

        [JsonPropertyName("reviewers")]
        public List<ReviewerResponse>? Reviewers { get; set; }

        [JsonPropertyName("labels")]
        public List<LabelResponse>? Labels { get; set; }
    }

    internal sealed class ReviewerResponse
    {
        [JsonPropertyName("displayName")]
        public string? DisplayName { get; set; }

        [JsonPropertyName("id")]
        public string? Id { get; set; }

        [JsonPropertyName("uniqueName")]
        public string? UniqueName { get; set; }

        [JsonPropertyName("vote")]
        public int Vote { get; set; }

        [JsonPropertyName("isRequired")]
        public bool IsRequired { get; set; }
    }

    internal sealed class LabelResponse
    {
        [JsonPropertyName("name")]
        public string? Name { get; set; }
    }

    // =========================================================================
    // Iterations
    // =========================================================================

    internal sealed class IterationResponse
    {
        [JsonPropertyName("id")]
        public int Id { get; set; }

        [JsonPropertyName("sourceRefCommit")]
        public CommitRef? SourceRefCommit { get; set; }

        [JsonPropertyName("targetRefCommit")]
        public CommitRef? TargetRefCommit { get; set; }
    }

    internal sealed class CommitRef
    {
        [JsonPropertyName("commitId")]
        public string? CommitId { get; set; }
    }

    internal sealed class IterationChangesResponse
    {
        [JsonPropertyName("changeEntries")]
        public List<ChangeEntry>? ChangeEntries { get; set; }
    }

    internal sealed class ChangeEntry
    {
        [JsonPropertyName("changeType")]
        [JsonConverter(typeof(JsonStringOrNumberConverter))]
        public object? ChangeType { get; set; }

        [JsonPropertyName("item")]
        public ChangeItem? Item { get; set; }

        [JsonPropertyName("originalPath")]
        public string? OriginalPath { get; set; }
    }

    internal sealed class ChangeItem
    {
        [JsonPropertyName("path")]
        public string? Path { get; set; }

        [JsonPropertyName("originalPath")]
        public string? OriginalPath { get; set; }

        [JsonPropertyName("gitObjectType")]
        public string? GitObjectType { get; set; }
    }

    // =========================================================================
    // Threads & Comments
    // =========================================================================

    internal sealed class ThreadResponse
    {
        [JsonPropertyName("id")]
        public int Id { get; set; }

        [JsonPropertyName("status")]
        [JsonConverter(typeof(JsonStringOrNumberConverter))]
        public object? Status { get; set; }

        [JsonPropertyName("threadContext")]
        public ThreadContextResponse? ThreadContext { get; set; }

        [JsonPropertyName("comments")]
        public List<CommentResponse>? Comments { get; set; }

        [JsonPropertyName("isDeleted")]
        public bool IsDeleted { get; set; }

        [JsonPropertyName("publishedDate")]
        public string? PublishedDate { get; set; }

        [JsonPropertyName("lastUpdatedDate")]
        public string? LastUpdatedDate { get; set; }
    }

    internal sealed class ThreadContextResponse
    {
        [JsonPropertyName("filePath")]
        public string? FilePath { get; set; }

        [JsonPropertyName("rightFileStart")]
        public FilePosition? RightFileStart { get; set; }

        [JsonPropertyName("rightFileEnd")]
        public FilePosition? RightFileEnd { get; set; }

        [JsonPropertyName("leftFileStart")]
        public FilePosition? LeftFileStart { get; set; }

        [JsonPropertyName("leftFileEnd")]
        public FilePosition? LeftFileEnd { get; set; }
    }

    internal sealed class FilePosition
    {
        [JsonPropertyName("line")]
        public int Line { get; set; }

        [JsonPropertyName("offset")]
        public int Offset { get; set; }
    }

    internal sealed class CommentResponse
    {
        [JsonPropertyName("id")]
        public int Id { get; set; }

        [JsonPropertyName("author")]
        public IdentityRef? Author { get; set; }

        [JsonPropertyName("parentCommentId")]
        public int ParentCommentId { get; set; }

        [JsonPropertyName("content")]
        public string? Content { get; set; }

        [JsonPropertyName("commentType")]
        [JsonConverter(typeof(JsonStringOrNumberConverter))]
        public object? CommentType { get; set; }

        [JsonPropertyName("publishedDate")]
        public string? PublishedDate { get; set; }

        [JsonPropertyName("lastUpdatedDate")]
        public string? LastUpdatedDate { get; set; }

        [JsonPropertyName("isDeleted")]
        public bool IsDeleted { get; set; }

        [JsonPropertyName("usersLiked")]
        public List<IdentityRef>? UsersLiked { get; set; }
    }

    // =========================================================================
    // Connection Data (for reviewer ID)
    // =========================================================================

    internal sealed class ConnectionDataResponse
    {
        [JsonPropertyName("authenticatedUser")]
        public AuthenticatedUser? AuthenticatedUser { get; set; }
    }

    internal sealed class AuthenticatedUser
    {
        [JsonPropertyName("id")]
        public string? Id { get; set; }
    }

    // =========================================================================
    // Shared
    // =========================================================================

    internal sealed class IdentityRef
    {
        [JsonPropertyName("displayName")]
        public string? DisplayName { get; set; }

        [JsonPropertyName("id")]
        public string? Id { get; set; }

        [JsonPropertyName("uniqueName")]
        public string? UniqueName { get; set; }
    }

    // --- Work Items ---

    /// <summary>
    /// Response from GET _apis/git/pullRequests/{id}/workitems
    /// </summary>
    internal sealed class WorkItemRefResponse
    {
        [JsonPropertyName("id")]
        public string? Id { get; set; }

        [JsonPropertyName("url")]
        public string? Url { get; set; }
    }

    /// <summary>
    /// Response from GET _apis/wit/workitems?ids=...
    /// </summary>
    internal sealed class WorkItemDetailResponse
    {
        [JsonPropertyName("id")]
        public int Id { get; set; }

        [JsonPropertyName("fields")]
        public WorkItemFields? Fields { get; set; }

        [JsonPropertyName("_links")]
        public WorkItemLinks? Links { get; set; }
    }

    internal sealed class WorkItemFields
    {
        [JsonPropertyName("System.Title")]
        public string? Title { get; set; }

        [JsonPropertyName("System.WorkItemType")]
        public string? WorkItemType { get; set; }

        [JsonPropertyName("System.State")]
        public string? State { get; set; }

        [JsonPropertyName("System.Tags")]
        public string? Tags { get; set; }

        [JsonPropertyName("System.AreaPath")]
        public string? AreaPath { get; set; }

        [JsonPropertyName("System.IterationPath")]
        public string? IterationPath { get; set; }
    }

    internal sealed class WorkItemLinks
    {
        [JsonPropertyName("html")]
        public WorkItemLinkRef? Html { get; set; }
    }

    internal sealed class WorkItemLinkRef
    {
        [JsonPropertyName("href")]
        public string? Href { get; set; }
    }
}

/// <summary>
/// JSON converter that handles fields that can be either a string or a number.
/// AzDO API sometimes returns enums as numbers and sometimes as strings.
/// </summary>
internal sealed class JsonStringOrNumberConverter : JsonConverter<object>
{
    public override object? Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        return reader.TokenType switch
        {
            JsonTokenType.String => reader.GetString(),
            JsonTokenType.Number => reader.GetInt32().ToString(),
            _ => null,
        };
    }

    public override void Write(Utf8JsonWriter writer, object value, JsonSerializerOptions options)
    {
        writer.WriteStringValue(value?.ToString());
    }
}
