using System.Text.Json;
using PowerReview.Core.Models;

namespace PowerReview.Core.Tests;

public class ModelSerializationTests
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull,
        PropertyNameCaseInsensitive = true,
    };

    [Theory]
    [InlineData(DraftStatus.Draft, "\"Draft\"")]
    [InlineData(DraftStatus.Pending, "\"Pending\"")]
    [InlineData(DraftStatus.Submitted, "\"Submitted\"")]
    public void DraftStatus_SerializesAsString(DraftStatus value, string expected)
    {
        var json = JsonSerializer.Serialize(value, JsonOptions);
        Assert.Equal(expected, json);
    }

    [Theory]
    [InlineData("\"Draft\"", DraftStatus.Draft)]
    [InlineData("\"Pending\"", DraftStatus.Pending)]
    [InlineData("\"Submitted\"", DraftStatus.Submitted)]
    public void DraftStatus_DeserializesFromString(string json, DraftStatus expected)
    {
        var value = JsonSerializer.Deserialize<DraftStatus>(json, JsonOptions);
        Assert.Equal(expected, value);
    }

    [Theory]
    [InlineData(DraftAuthor.User, "\"User\"")]
    [InlineData(DraftAuthor.Ai, "\"Ai\"")]
    public void DraftAuthor_SerializesAsString(DraftAuthor value, string expected)
    {
        var json = JsonSerializer.Serialize(value, JsonOptions);
        Assert.Equal(expected, json);
    }

    [Theory]
    [InlineData(VoteValue.Approve, "\"Approve\"")]
    [InlineData(VoteValue.Reject, "\"Reject\"")]
    [InlineData(VoteValue.NoVote, "\"NoVote\"")]
    [InlineData(VoteValue.WaitForAuthor, "\"WaitForAuthor\"")]
    [InlineData(VoteValue.ApproveWithSuggestions, "\"ApproveWithSuggestions\"")]
    public void VoteValue_SerializesAsString(VoteValue value, string expected)
    {
        var json = JsonSerializer.Serialize(value, JsonOptions);
        Assert.Equal(expected, json);
    }

    [Fact]
    public void DraftComment_SerializesWithCorrectPropertyNames()
    {
        var draft = new DraftComment
        {
            FilePath = "src/main.cs",
            LineStart = 10,
            LineEnd = 15,
            ColStart = 5,
            ColEnd = 20,
            Body = "Fix this",
            Status = DraftStatus.Draft,
            Author = DraftAuthor.User,
            ThreadId = 42,
            ParentCommentId = 1,
            CreatedAt = "2024-01-01T00:00:00Z",
            UpdatedAt = "2024-01-01T00:00:00Z",
        };

        var json = JsonSerializer.Serialize(draft, JsonOptions);

        Assert.Contains("\"file_path\"", json);
        Assert.Contains("\"line_start\"", json);
        Assert.Contains("\"line_end\"", json);
        Assert.Contains("\"col_start\"", json);
        Assert.Contains("\"col_end\"", json);
        Assert.Contains("\"body\"", json);
        Assert.Contains("\"status\"", json);
        Assert.Contains("\"author\"", json);
        Assert.Contains("\"thread_id\"", json);
        Assert.Contains("\"parent_comment_id\"", json);
        Assert.Contains("\"created_at\"", json);
        Assert.Contains("\"updated_at\"", json);
    }

    [Fact]
    public void DraftComment_ComputedPropertiesNotSerialized()
    {
        var draft = new DraftComment
        {
            Status = DraftStatus.Draft,
            CreatedAt = "2024-01-01T00:00:00Z",
            UpdatedAt = "2024-01-01T00:00:00Z",
        };

        var json = JsonSerializer.Serialize(draft, JsonOptions);

        Assert.DoesNotContain("can_edit", json);
        Assert.DoesNotContain("can_delete", json);
        Assert.DoesNotContain("is_reply", json);
        Assert.DoesNotContain("is_ai_authored", json);
        Assert.DoesNotContain("CanEdit", json);
        Assert.DoesNotContain("CanDelete", json);
        Assert.DoesNotContain("IsReply", json);
        Assert.DoesNotContain("IsAiAuthored", json);
    }

    [Fact]
    public void DraftComment_ComputedProperties_Draft()
    {
        var draft = new DraftComment { Status = DraftStatus.Draft, Author = DraftAuthor.User };
        Assert.True(draft.CanEdit);
        Assert.True(draft.CanDelete);
        Assert.False(draft.IsReply);
        Assert.False(draft.IsAiAuthored);
    }

    [Fact]
    public void DraftComment_ComputedProperties_Pending()
    {
        var draft = new DraftComment { Status = DraftStatus.Pending };
        Assert.False(draft.CanEdit);
        Assert.False(draft.CanDelete);
    }

    [Fact]
    public void DraftComment_ComputedProperties_Reply()
    {
        var draft = new DraftComment { ThreadId = 1 };
        Assert.True(draft.IsReply);
    }

    [Fact]
    public void DraftComment_ComputedProperties_AiAuthored()
    {
        var draft = new DraftComment { Author = DraftAuthor.Ai };
        Assert.True(draft.IsAiAuthored);
    }

    [Fact]
    public void ReviewSession_RoundTrips()
    {
        var session = new ReviewSession
        {
            Id = "azdo_org_proj_repo_1",
            Provider = new ProviderInfo
            {
                Type = ProviderType.AzDo,
                Organization = "org",
                Project = "proj",
                Repository = "repo",
            },
            PullRequest = new PullRequestInfo
            {
                Id = 1,
                Title = "Test PR",
                SourceBranch = "feature",
                TargetBranch = "main",
            },
            Files = [new ChangedFile { Path = "a.cs", ChangeType = ChangeType.Edit }],
            Threads = new ThreadsInfo
            {
                SyncedAt = "2024-01-01T00:00:00Z",
                Items = [
                    new CommentThread
                    {
                        Id = 1,
                        FilePath = "a.cs",
                        LineStart = 5,
                        Status = ThreadStatus.Active,
                        Comments = [
                            new Comment { Id = 1, ThreadId = 1, Body = "comment body" }
                        ],
                    }
                ],
            },
            Drafts = new Dictionary<string, DraftComment>
            {
                ["d1"] = new DraftComment { Body = "draft 1", CreatedAt = "2024-01-01T00:00:00Z", UpdatedAt = "2024-01-01T00:00:00Z" },
            },
            Vote = VoteValue.Approve,
            CreatedAt = "2024-01-01T00:00:00Z",
            UpdatedAt = "2024-01-01T00:00:00Z",
        };

        var json = JsonSerializer.Serialize(session, JsonOptions);
        var deserialized = JsonSerializer.Deserialize<ReviewSession>(json, JsonOptions)!;

        Assert.Equal(session.Id, deserialized.Id);
        Assert.Equal(session.Version, deserialized.Version);
        Assert.Equal(session.Provider.Type, deserialized.Provider.Type);
        Assert.Equal(session.PullRequest.Title, deserialized.PullRequest.Title);
        Assert.Single(deserialized.Files);
        Assert.Equal(ChangeType.Edit, deserialized.Files[0].ChangeType);
        Assert.Single(deserialized.Threads.Items);
        Assert.Single(deserialized.Threads.Items[0].Comments);
        Assert.Single(deserialized.Drafts);
        Assert.Equal("draft 1", deserialized.Drafts["d1"].Body);
        Assert.Equal(VoteValue.Approve, deserialized.Vote);
    }

    [Fact]
    public void ReviewSession_NullableFieldsOmittedInJson()
    {
        var session = new ReviewSession
        {
            Id = "test",
            CreatedAt = "2024-01-01T00:00:00Z",
            UpdatedAt = "2024-01-01T00:00:00Z",
        };

        var json = JsonSerializer.Serialize(session, JsonOptions);

        Assert.DoesNotContain("\"vote\"", json);
    }

    [Fact]
    public void ChangedFile_ChangeType_Serializes()
    {
        var file = new ChangedFile { Path = "a.cs", ChangeType = ChangeType.Rename, OriginalPath = "b.cs" };
        var json = JsonSerializer.Serialize(file, JsonOptions);

        Assert.Contains("\"Rename\"", json);
        Assert.Contains("\"original_path\"", json);
    }

    [Fact]
    public void DraftComment_AuthorName_RoundTrips()
    {
        var draft = new DraftComment
        {
            Body = "test",
            Author = DraftAuthor.Ai,
            AuthorName = "SecurityReviewer",
            CreatedAt = "2024-01-01T00:00:00Z",
            UpdatedAt = "2024-01-01T00:00:00Z",
        };

        var json = JsonSerializer.Serialize(draft, JsonOptions);
        Assert.Contains("\"author_name\"", json);
        Assert.Contains("SecurityReviewer", json);

        var deserialized = JsonSerializer.Deserialize<DraftComment>(json, JsonOptions)!;
        Assert.Equal("SecurityReviewer", deserialized.AuthorName);
    }

    [Fact]
    public void DraftComment_AuthorName_OmittedWhenNull()
    {
        var draft = new DraftComment
        {
            Body = "test",
            Author = DraftAuthor.Ai,
            CreatedAt = "2024-01-01T00:00:00Z",
            UpdatedAt = "2024-01-01T00:00:00Z",
        };

        var json = JsonSerializer.Serialize(draft, JsonOptions);
        Assert.DoesNotContain("author_name", json);
    }
}
