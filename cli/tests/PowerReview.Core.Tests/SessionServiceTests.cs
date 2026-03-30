using PowerReview.Core.Models;
using PowerReview.Core.Services;
using PowerReview.Core.Store;

namespace PowerReview.Core.Tests;

public class SessionServiceTests : IDisposable
{
    private readonly string _tempDir;
    private readonly SessionStore _store;
    private readonly SessionService _service;

    public SessionServiceTests()
    {
        _tempDir = Path.Combine(Path.GetTempPath(), "powerreview-svc-tests-" + Guid.NewGuid().ToString("N")[..8]);
        _store = new SessionStore(_tempDir);
        _service = new SessionService(_store);
    }

    public void Dispose()
    {
        if (Directory.Exists(_tempDir))
            Directory.Delete(_tempDir, recursive: true);
    }

    private string CreateAndSaveSession()
    {
        var now = DateTime.UtcNow.ToString("o");
        var session = new ReviewSession
        {
            Id = "test-session",
            Provider = new ProviderInfo
            {
                Type = ProviderType.AzDo,
                Organization = "org",
                Project = "proj",
                Repository = "repo",
            },
            PullRequest = new PullRequestInfo { Id = 1, Title = "Test" },
            CreatedAt = now,
            UpdatedAt = now,
        };
        _store.Save(session);
        return session.Id;
    }

    // --- CreateDraft ---

    [Fact]
    public void CreateDraft_AddsToSession()
    {
        var sessionId = CreateAndSaveSession();

        var (id, draft) = _service.CreateDraft(sessionId, new CreateDraftRequest
        {
            FilePath = "src/main.cs",
            LineStart = 10,
            Body = "Fix this bug",
        });

        Assert.NotNull(id);
        Assert.NotEmpty(id);
        Assert.Equal("src/main.cs", draft.FilePath);
        Assert.Equal(10, draft.LineStart);
        Assert.Equal("Fix this bug", draft.Body);
        Assert.Equal(DraftStatus.Draft, draft.Status);
        Assert.Equal(DraftAuthor.User, draft.Author);

        // Verify persisted
        var loaded = _store.Load(sessionId)!;
        Assert.Single(loaded.Drafts);
        Assert.True(loaded.Drafts.ContainsKey(id));
    }

    [Fact]
    public void CreateDraft_DefaultValues()
    {
        var sessionId = CreateAndSaveSession();

        var (_, draft) = _service.CreateDraft(sessionId, new CreateDraftRequest());

        Assert.Equal("", draft.FilePath);
        Assert.Equal(0, draft.LineStart);
        Assert.Equal("", draft.Body);
        Assert.Equal(DraftStatus.Draft, draft.Status);
        Assert.Equal(DraftAuthor.User, draft.Author);
        Assert.Null(draft.ThreadId);
    }

    [Fact]
    public void CreateDraft_AiAuthor()
    {
        var sessionId = CreateAndSaveSession();

        var (_, draft) = _service.CreateDraft(sessionId, new CreateDraftRequest
        {
            Author = DraftAuthor.Ai,
            Body = "AI suggestion",
        });

        Assert.Equal(DraftAuthor.Ai, draft.Author);
        Assert.True(draft.IsAiAuthored);
    }

    [Fact]
    public void CreateDraft_Reply()
    {
        var sessionId = CreateAndSaveSession();

        var (_, draft) = _service.CreateDraft(sessionId, new CreateDraftRequest
        {
            ThreadId = 42,
            Body = "Reply text",
        });

        Assert.True(draft.IsReply);
        Assert.Equal(42, draft.ThreadId);
    }

    [Fact]
    public void CreateDraft_NonexistentSession_Throws()
    {
        Assert.Throws<SessionServiceException>(() =>
            _service.CreateDraft("nonexistent", new CreateDraftRequest()));
    }

    // --- EditDraft ---

    [Fact]
    public void EditDraft_UpdatesBody()
    {
        var sessionId = CreateAndSaveSession();
        var (draftId, _) = _service.CreateDraft(sessionId, new CreateDraftRequest { Body = "original" });

        var edited = _service.EditDraft(sessionId, draftId, "updated body");

        Assert.Equal("updated body", edited.Body);

        // Verify persisted
        var loaded = _store.Load(sessionId)!;
        Assert.Equal("updated body", loaded.Drafts[draftId].Body);
    }

    [Fact]
    public void EditDraft_PendingStatus_Throws()
    {
        var sessionId = CreateAndSaveSession();
        var (draftId, _) = _service.CreateDraft(sessionId, new CreateDraftRequest { Body = "test" });
        _service.ApproveDraft(sessionId, draftId);

        var ex = Assert.Throws<SessionServiceException>(() =>
            _service.EditDraft(sessionId, draftId, "new body"));
        Assert.Contains("Pending", ex.Message);
    }

    [Fact]
    public void EditDraft_NonexistentDraft_Throws()
    {
        var sessionId = CreateAndSaveSession();

        Assert.Throws<SessionServiceException>(() =>
            _service.EditDraft(sessionId, "fake-id", "body"));
    }

    // --- DeleteDraft ---

    [Fact]
    public void DeleteDraft_RemovesFromSession()
    {
        var sessionId = CreateAndSaveSession();
        var (draftId, _) = _service.CreateDraft(sessionId, new CreateDraftRequest { Body = "delete me" });

        _service.DeleteDraft(sessionId, draftId);

        var loaded = _store.Load(sessionId)!;
        Assert.Empty(loaded.Drafts);
    }

    [Fact]
    public void DeleteDraft_PendingStatus_Throws()
    {
        var sessionId = CreateAndSaveSession();
        var (draftId, _) = _service.CreateDraft(sessionId, new CreateDraftRequest { Body = "test" });
        _service.ApproveDraft(sessionId, draftId);

        Assert.Throws<SessionServiceException>(() =>
            _service.DeleteDraft(sessionId, draftId));
    }

    // --- ApproveDraft ---

    [Fact]
    public void ApproveDraft_TransitionsToPending()
    {
        var sessionId = CreateAndSaveSession();
        var (draftId, _) = _service.CreateDraft(sessionId, new CreateDraftRequest { Body = "approve me" });

        var approved = _service.ApproveDraft(sessionId, draftId);

        Assert.Equal(DraftStatus.Pending, approved.Status);
        Assert.False(approved.CanEdit);
        Assert.False(approved.CanDelete);
    }

    [Fact]
    public void ApproveDraft_AlreadyPending_Throws()
    {
        var sessionId = CreateAndSaveSession();
        var (draftId, _) = _service.CreateDraft(sessionId, new CreateDraftRequest { Body = "test" });
        _service.ApproveDraft(sessionId, draftId);

        Assert.Throws<SessionServiceException>(() =>
            _service.ApproveDraft(sessionId, draftId));
    }

    // --- UnapproveDraft ---

    [Fact]
    public void UnapproveDraft_TransitionsBackToDraft()
    {
        var sessionId = CreateAndSaveSession();
        var (draftId, _) = _service.CreateDraft(sessionId, new CreateDraftRequest { Body = "test" });
        _service.ApproveDraft(sessionId, draftId);

        var unapproved = _service.UnapproveDraft(sessionId, draftId);

        Assert.Equal(DraftStatus.Draft, unapproved.Status);
        Assert.True(unapproved.CanEdit);
        Assert.True(unapproved.CanDelete);
    }

    [Fact]
    public void UnapproveDraft_DraftStatus_Throws()
    {
        var sessionId = CreateAndSaveSession();
        var (draftId, _) = _service.CreateDraft(sessionId, new CreateDraftRequest { Body = "test" });

        Assert.Throws<SessionServiceException>(() =>
            _service.UnapproveDraft(sessionId, draftId));
    }

    // --- ApproveAllDrafts ---

    [Fact]
    public void ApproveAllDrafts_ApprovesOnlyDraftStatus()
    {
        var sessionId = CreateAndSaveSession();
        _service.CreateDraft(sessionId, new CreateDraftRequest { Body = "draft 1" });
        _service.CreateDraft(sessionId, new CreateDraftRequest { Body = "draft 2" });
        var (id3, _) = _service.CreateDraft(sessionId, new CreateDraftRequest { Body = "draft 3" });
        _service.ApproveDraft(sessionId, id3); // Already pending

        var count = _service.ApproveAllDrafts(sessionId);

        Assert.Equal(2, count);

        var loaded = _store.Load(sessionId)!;
        Assert.All(loaded.Drafts.Values, d => Assert.Equal(DraftStatus.Pending, d.Status));
    }

    [Fact]
    public void ApproveAllDrafts_NoDrafts_ReturnsZero()
    {
        var sessionId = CreateAndSaveSession();
        var count = _service.ApproveAllDrafts(sessionId);
        Assert.Equal(0, count);
    }

    // --- GetDraft ---

    [Fact]
    public void GetDraft_ExistingDraft_ReturnsDraft()
    {
        var sessionId = CreateAndSaveSession();
        var (draftId, _) = _service.CreateDraft(sessionId, new CreateDraftRequest { Body = "find me" });

        var result = _service.GetDraft(sessionId, draftId);

        Assert.NotNull(result);
        Assert.Equal(draftId, result.Value.Id);
        Assert.Equal("find me", result.Value.Draft.Body);
    }

    [Fact]
    public void GetDraft_NonexistentDraft_ReturnsNull()
    {
        var sessionId = CreateAndSaveSession();
        var result = _service.GetDraft(sessionId, "fake-id");
        Assert.Null(result);
    }

    // --- GetDrafts ---

    [Fact]
    public void GetDrafts_FilterByFile()
    {
        var sessionId = CreateAndSaveSession();
        _service.CreateDraft(sessionId, new CreateDraftRequest { FilePath = "a.cs", Body = "1" });
        _service.CreateDraft(sessionId, new CreateDraftRequest { FilePath = "b.cs", Body = "2" });
        _service.CreateDraft(sessionId, new CreateDraftRequest { FilePath = "a.cs", Body = "3" });

        var result = _service.GetDrafts(sessionId, "a.cs");

        Assert.Equal(2, result.Count);
        Assert.All(result.Values, d => Assert.Equal("a.cs", d.FilePath));
    }

    [Fact]
    public void GetDrafts_PathNormalization()
    {
        var sessionId = CreateAndSaveSession();
        _service.CreateDraft(sessionId, new CreateDraftRequest { FilePath = "src\\main.cs", Body = "1" });

        var result = _service.GetDrafts(sessionId, "src/main.cs");

        Assert.Single(result);
    }

    // --- GetDraftCounts ---

    [Fact]
    public void GetDraftCounts_ReturnsCorrectCounts()
    {
        var sessionId = CreateAndSaveSession();
        _service.CreateDraft(sessionId, new CreateDraftRequest { Body = "draft" });
        var (id2, _) = _service.CreateDraft(sessionId, new CreateDraftRequest { Body = "pending" });
        _service.ApproveDraft(sessionId, id2);

        var counts = _service.GetDraftCounts(sessionId);

        Assert.Equal(2, counts.Total);
        Assert.Equal(1, counts.Draft);
        Assert.Equal(1, counts.Pending);
        Assert.Equal(0, counts.Submitted);
    }

    // --- Full lifecycle ---

    [Fact]
    public void FullLifecycle_CreateEditApproveUnapproveDelete()
    {
        var sessionId = CreateAndSaveSession();

        // Create
        var (draftId, draft) = _service.CreateDraft(sessionId, new CreateDraftRequest
        {
            FilePath = "test.cs",
            LineStart = 5,
            Body = "initial",
        });
        Assert.Equal(DraftStatus.Draft, draft.Status);

        // Edit
        var edited = _service.EditDraft(sessionId, draftId, "edited body");
        Assert.Equal("edited body", edited.Body);

        // Approve
        var approved = _service.ApproveDraft(sessionId, draftId);
        Assert.Equal(DraftStatus.Pending, approved.Status);

        // Cannot edit when pending
        Assert.Throws<SessionServiceException>(() => _service.EditDraft(sessionId, draftId, "x"));

        // Unapprove
        var unapproved = _service.UnapproveDraft(sessionId, draftId);
        Assert.Equal(DraftStatus.Draft, unapproved.Status);

        // Can edit again
        _service.EditDraft(sessionId, draftId, "final body");

        // Delete
        _service.DeleteDraft(sessionId, draftId);
        Assert.Empty(_store.Load(sessionId)!.Drafts);
    }
}
