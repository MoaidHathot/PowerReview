using System.Text.Json;
using PowerReview.Core.Models;
using PowerReview.Core.Store;

namespace PowerReview.Core.Tests;

public class SessionStoreTests : IDisposable
{
    private readonly string _tempDir;
    private readonly SessionStore _store;

    public SessionStoreTests()
    {
        _tempDir = Path.Combine(Path.GetTempPath(), "powerreview-tests-" + Guid.NewGuid().ToString("N")[..8]);
        _store = new SessionStore(_tempDir);
    }

    public void Dispose()
    {
        if (Directory.Exists(_tempDir))
            Directory.Delete(_tempDir, recursive: true);
    }

    private static ReviewSession CreateTestSession(string id = "test-session")
    {
        var now = DateTime.UtcNow.ToString("o");
        return new ReviewSession
        {
            Id = id,
            Provider = new ProviderInfo
            {
                Type = ProviderType.AzDo,
                Organization = "testorg",
                Project = "testproject",
                Repository = "testrepo",
            },
            PullRequest = new PullRequestInfo
            {
                Id = 42,
                Url = "https://dev.azure.com/testorg/testproject/_git/testrepo/pullrequest/42",
                Title = "Test PR",
                SourceBranch = "feature/test",
                TargetBranch = "main",
            },
            CreatedAt = now,
            UpdatedAt = now,
        };
    }

    [Fact]
    public void Save_CreatesFile()
    {
        var session = CreateTestSession();
        _store.Save(session);

        var path = _store.GetSessionPath("test-session");
        Assert.True(File.Exists(path));
    }

    [Fact]
    public void SaveAndLoad_RoundTrips()
    {
        var session = CreateTestSession();
        session.Drafts["draft-1"] = new DraftComment
        {
            FilePath = "src/main.cs",
            LineStart = 10,
            Body = "Fix this",
            Status = DraftStatus.Draft,
            Author = DraftAuthor.User,
            CreatedAt = DateTime.UtcNow.ToString("o"),
            UpdatedAt = DateTime.UtcNow.ToString("o"),
        };

        _store.Save(session);
        var loaded = _store.Load("test-session");

        Assert.NotNull(loaded);
        Assert.Equal("test-session", loaded.Id);
        Assert.Equal(3, loaded.Version);
        Assert.Equal(ProviderType.AzDo, loaded.Provider.Type);
        Assert.Equal("testorg", loaded.Provider.Organization);
        Assert.Equal(42, loaded.PullRequest.Id);
        Assert.Equal("Test PR", loaded.PullRequest.Title);
        Assert.Single(loaded.Drafts);
        Assert.True(loaded.Drafts.ContainsKey("draft-1"));
        Assert.Equal("Fix this", loaded.Drafts["draft-1"].Body);
    }

    [Fact]
    public void Load_NonexistentSession_ReturnsNull()
    {
        var result = _store.Load("does-not-exist");
        Assert.Null(result);
    }

    [Fact]
    public void Delete_ExistingSession_RemovesFile()
    {
        var session = CreateTestSession();
        _store.Save(session);

        var deleted = _store.Delete("test-session");
        Assert.True(deleted);
        Assert.False(File.Exists(_store.GetSessionPath("test-session")));
    }

    [Fact]
    public void Delete_NonexistentSession_ReturnsFalse()
    {
        var deleted = _store.Delete("nonexistent");
        Assert.False(deleted);
    }

    [Fact]
    public void List_ReturnsAllSessions()
    {
        _store.Save(CreateTestSession("session-1"));
        _store.Save(CreateTestSession("session-2"));

        var summaries = _store.List();
        Assert.Equal(2, summaries.Count);
        Assert.Contains(summaries, s => s.Id == "session-1");
        Assert.Contains(summaries, s => s.Id == "session-2");
    }

    [Fact]
    public void List_EmptyDir_ReturnsEmpty()
    {
        var summaries = _store.List();
        Assert.Empty(summaries);
    }

    [Fact]
    public void Clean_DeletesAllSessions()
    {
        _store.Save(CreateTestSession("s1"));
        _store.Save(CreateTestSession("s2"));
        _store.Save(CreateTestSession("s3"));

        var count = _store.Clean();
        Assert.Equal(3, count);
        Assert.Empty(_store.List());
    }

    [Fact]
    public void Save_UpdatesTimestamp()
    {
        var session = CreateTestSession();
        var originalTimestamp = session.UpdatedAt;

        // Small delay to ensure timestamp differs
        Thread.Sleep(10);
        _store.Save(session);

        Assert.NotEqual(originalTimestamp, session.UpdatedAt);
    }

    [Fact]
    public void GetSessionPath_ReturnsExpectedPath()
    {
        var path = _store.GetSessionPath("my-session");
        Assert.EndsWith("my-session.json", path);
        Assert.StartsWith(_tempDir, path);
    }

    [Fact]
    public void ComputeId_IsDeterministic()
    {
        var id1 = ReviewSession.ComputeId(ProviderType.AzDo, "org", "proj", "repo", 42);
        var id2 = ReviewSession.ComputeId(ProviderType.AzDo, "org", "proj", "repo", 42);
        Assert.Equal(id1, id2);
    }

    [Fact]
    public void ComputeId_IsLowercase()
    {
        var id = ReviewSession.ComputeId(ProviderType.AzDo, "MyOrg", "MyProject", "MyRepo", 1);
        Assert.Equal(id, id.ToLowerInvariant());
    }

    [Fact]
    public void ComputeId_SanitizesSpecialChars()
    {
        var id = ReviewSession.ComputeId(ProviderType.AzDo, "my org", "my project", "my repo", 1);
        Assert.DoesNotContain(" ", id);
        Assert.Matches("^[a-z0-9_-]+$", id);
    }
}
