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

    private string CreateAndSaveSession(List<ChangedFile>? files = null)
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
            Files = files ?? [],
            CreatedAt = now,
            UpdatedAt = now,
        };
        _store.Save(session);
        return session.Id;
    }

    private string CreateAndSaveSessionWithThread()
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
            Files = [new ChangedFile { Path = "src/main.cs" }],
            Threads = new ThreadsInfo
            {
                SyncedAt = now,
                Items =
                [
                    new CommentThread
                    {
                        Id = 42,
                        FilePath = "src/main.cs",
                        LineStart = 10,
                        LineEnd = 12,
                        ColStart = 3,
                        ColEnd = 8,
                    },
                ],
            },
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
        var sessionId = CreateAndSaveSession([new ChangedFile { Path = "src/main.cs" }]);

        var (id, draft) = _service.CreateDraft(sessionId, new CreateDraftOperationRequest
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
        Assert.Single(loaded.DraftOperations);
        Assert.True(loaded.DraftOperations.ContainsKey(id));
    }

    [Fact]
    public void CreateDraft_DefaultValues()
    {
        var sessionId = CreateAndSaveSession();

        var (_, draft) = _service.CreateDraft(sessionId, new CreateDraftOperationRequest { Body = "comment" });

        Assert.Equal("", draft.FilePath);
        Assert.Null(draft.LineStart);
        Assert.Equal("comment", draft.Body);
        Assert.Equal(DraftStatus.Draft, draft.Status);
        Assert.Equal(DraftAuthor.User, draft.Author);
        Assert.Null(draft.AuthorName);
        Assert.Null(draft.ThreadId);
    }

    [Fact]
    public void CreateDraft_AiAuthor()
    {
        var sessionId = CreateAndSaveSession();

        var (_, draft) = _service.CreateDraft(sessionId, new CreateDraftOperationRequest
        {
            Author = DraftAuthor.Ai,
            Body = "AI suggestion",
        });

        Assert.Equal(DraftAuthor.Ai, draft.Author);
        Assert.True(draft.IsAiAuthored);
    }

    [Fact]
    public void CreateDraft_AuthorName_StoredOnDraft()
    {
        var sessionId = CreateAndSaveSession();

        var (_, draft) = _service.CreateDraft(sessionId, new CreateDraftOperationRequest
        {
            Author = DraftAuthor.Ai,
            AuthorName = "SecurityReviewer",
            Body = "Security issue found",
        });

        Assert.Equal(DraftAuthor.Ai, draft.Author);
        Assert.Equal("SecurityReviewer", draft.AuthorName);
    }

    [Fact]
    public void CreateDraft_AuthorName_NullWhenOmitted()
    {
        var sessionId = CreateAndSaveSession();

        var (_, draft) = _service.CreateDraft(sessionId, new CreateDraftOperationRequest
        {
            Author = DraftAuthor.Ai,
            Body = "No name provided",
        });

        Assert.Equal(DraftAuthor.Ai, draft.Author);
        Assert.Null(draft.AuthorName);
    }

    [Fact]
    public void CreateDraft_AuthorName_WorksWithUserAuthor()
    {
        var sessionId = CreateAndSaveSession();

        var (_, draft) = _service.CreateDraft(sessionId, new CreateDraftOperationRequest
        {
            Author = DraftAuthor.User,
            AuthorName = "John",
            Body = "User comment with name",
        });

        Assert.Equal(DraftAuthor.User, draft.Author);
        Assert.Equal("John", draft.AuthorName);
    }

    [Fact]
    public void CreateDraft_Reply()
    {
        var sessionId = CreateAndSaveSession();

        var (_, draft) = _service.CreateDraft(sessionId, new CreateDraftOperationRequest
        {
            ThreadId = 42,
            Body = "Reply text",
        });

        Assert.True(draft.IsReply);
        Assert.Equal(42, draft.ThreadId);
    }

    [Fact]
    public void CreateDraft_ReplyInheritsThreadLocation()
    {
        var sessionId = CreateAndSaveSessionWithThread();

        var (_, draft) = _service.CreateDraft(sessionId, new CreateDraftOperationRequest
        {
            ThreadId = 42,
            Body = "Reply text",
        });

        Assert.True(draft.IsReply);
        Assert.Equal("src/main.cs", draft.FilePath);
        Assert.Equal(10, draft.LineStart);
        Assert.Equal(12, draft.LineEnd);
        Assert.Equal(3, draft.ColStart);
        Assert.Equal(8, draft.ColEnd);
    }

    [Fact]
    public void CreateDraft_ReplyKeepsExplicitLocationWhenProvided()
    {
        var sessionId = CreateAndSaveSessionWithThread();

        var (_, draft) = _service.CreateDraft(sessionId, new CreateDraftOperationRequest
        {
            ThreadId = 42,
            FilePath = "custom/path.cs",
            LineStart = 99,
            Body = "Reply text",
        });

        Assert.Equal("custom/path.cs", draft.FilePath);
        Assert.Equal(99, draft.LineStart);
        Assert.Equal(12, draft.LineEnd);
    }

    [Fact]
    public void CreateDraft_NonexistentSession_Throws()
    {
        Assert.Throws<SessionServiceException>(() =>
            _service.CreateDraft("nonexistent", new CreateDraftOperationRequest()));
    }

    [Fact]
    public void CreateDraft_EmptyBody_Throws()
    {
        var sessionId = CreateAndSaveSession();

        var ex = Assert.Throws<SessionServiceException>(() =>
            _service.CreateDraft(sessionId, new CreateDraftOperationRequest { Body = "" }));
        Assert.Contains("body cannot be empty", ex.Message);
    }

    [Fact]
    public void CreateDraft_WhitespaceBody_Throws()
    {
        var sessionId = CreateAndSaveSession();

        var ex = Assert.Throws<SessionServiceException>(() =>
            _service.CreateDraft(sessionId, new CreateDraftOperationRequest { Body = "   " }));
        Assert.Contains("body cannot be empty", ex.Message);
    }

    [Fact]
    public void CreateDraft_NullBody_Throws()
    {
        var sessionId = CreateAndSaveSession();

        var ex = Assert.Throws<SessionServiceException>(() =>
            _service.CreateDraft(sessionId, new CreateDraftOperationRequest { Body = null }));
        Assert.Contains("body cannot be empty", ex.Message);
    }

    [Fact]
    public void CreateDraft_EmptyBodyOnReply_Allowed()
    {
        var sessionId = CreateAndSaveSession();

        // Replies skip body validation (the body might be intentionally empty for some workflows)
        var (_, draft) = _service.CreateDraft(sessionId, new CreateDraftOperationRequest
        {
            ThreadId = 42,
            Body = "",
        });
        Assert.Equal("", draft.Body);
    }

    [Fact]
    public void CreateDraft_FileNotInChangedFiles_Throws()
    {
        var sessionId = CreateAndSaveSession([
            new ChangedFile { Path = "src/real-file.cs" },
        ]);

        var ex = Assert.Throws<SessionServiceException>(() =>
            _service.CreateDraft(sessionId, new CreateDraftOperationRequest
            {
                FilePath = "src/nonexistent.cs",
                Body = "comment",
            }));
        Assert.Contains("not part of this PR", ex.Message);
    }

    [Fact]
    public void CreateDraft_FileInChangedFiles_Succeeds()
    {
        var sessionId = CreateAndSaveSession([
            new ChangedFile { Path = "src/real-file.cs" },
        ]);

        var (_, draft) = _service.CreateDraft(sessionId, new CreateDraftOperationRequest
        {
            FilePath = "src/real-file.cs",
            Body = "looks good",
        });

        Assert.Equal("src/real-file.cs", draft.FilePath);
    }

    [Fact]
    public void CreateDraft_FileMatchIsCaseInsensitive()
    {
        var sessionId = CreateAndSaveSession([
            new ChangedFile { Path = "src/MyFile.cs" },
        ]);

        var (_, draft) = _service.CreateDraft(sessionId, new CreateDraftOperationRequest
        {
            FilePath = "src/myfile.cs",
            Body = "case insensitive match",
        });

        Assert.Equal("src/myfile.cs", draft.FilePath);
    }

    [Fact]
    public void CreateDraft_FileMatchNormalizesSlashes()
    {
        var sessionId = CreateAndSaveSession([
            new ChangedFile { Path = "src/utils/helper.cs" },
        ]);

        var (_, draft) = _service.CreateDraft(sessionId, new CreateDraftOperationRequest
        {
            FilePath = "src\\utils\\helper.cs",
            Body = "backslash path",
        });

        Assert.Equal("src\\utils\\helper.cs", draft.FilePath);
    }

    [Fact]
    public void CreateDraft_NoFilePathSkipsFileValidation()
    {
        var sessionId = CreateAndSaveSession();

        // PR-level comment (no file) should work even with no files in the session
        var (_, draft) = _service.CreateDraft(sessionId, new CreateDraftOperationRequest
        {
            Body = "general PR comment",
        });

        Assert.Equal("", draft.FilePath);
    }

    [Fact]
    public void CreateDraft_ReplySkipsFileValidation()
    {
        var sessionId = CreateAndSaveSession();

        // Reply to a thread should work even with a file path not in changed files
        var (_, draft) = _service.CreateDraft(sessionId, new CreateDraftOperationRequest
        {
            ThreadId = 42,
            FilePath = "any/path.cs",
            Body = "reply text",
        });

        Assert.True(draft.IsReply);
    }

    [Fact]
    public void CreateDraft_EmptyFilesList_FileComment_Throws()
    {
        var sessionId = CreateAndSaveSession();

        var ex = Assert.Throws<SessionServiceException>(() =>
            _service.CreateDraft(sessionId, new CreateDraftOperationRequest
            {
                FilePath = "some/file.cs",
                Body = "comment on file",
            }));
        Assert.Contains("not part of this PR", ex.Message);
    }

    // --- EditDraft ---

    [Fact]
    public void EditDraft_UpdatesBody()
    {
        var sessionId = CreateAndSaveSession();
        var (draftId, _) = _service.CreateDraft(sessionId, new CreateDraftOperationRequest { Body = "original" });

        var edited = _service.EditDraft(sessionId, draftId, "updated body");

        Assert.Equal("updated body", edited.Body);

        // Verify persisted
        var loaded = _store.Load(sessionId)!;
        Assert.Equal("updated body", loaded.DraftOperations[draftId].Body);
    }

    [Fact]
    public void EditDraft_PendingStatus_Throws()
    {
        var sessionId = CreateAndSaveSession();
        var (draftId, _) = _service.CreateDraft(sessionId, new CreateDraftOperationRequest { Body = "test" });
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
        var (draftId, _) = _service.CreateDraft(sessionId, new CreateDraftOperationRequest { Body = "delete me" });

        _service.DeleteDraft(sessionId, draftId);

        var loaded = _store.Load(sessionId)!;
        Assert.Empty(loaded.DraftOperations);
    }

    [Fact]
    public void DeleteDraft_PendingStatus_Throws()
    {
        var sessionId = CreateAndSaveSession();
        var (draftId, _) = _service.CreateDraft(sessionId, new CreateDraftOperationRequest { Body = "test" });
        _service.ApproveDraft(sessionId, draftId);

        Assert.Throws<SessionServiceException>(() =>
            _service.DeleteDraft(sessionId, draftId));
    }

    // --- ApproveDraft ---

    [Fact]
    public void ApproveDraft_TransitionsToPending()
    {
        var sessionId = CreateAndSaveSession();
        var (draftId, _) = _service.CreateDraft(sessionId, new CreateDraftOperationRequest { Body = "approve me" });

        var approved = _service.ApproveDraft(sessionId, draftId);

        Assert.Equal(DraftStatus.Pending, approved.Status);
        Assert.False(approved.CanEdit);
        Assert.False(approved.CanDelete);
    }

    [Fact]
    public void ApproveDraft_AlreadyPending_Throws()
    {
        var sessionId = CreateAndSaveSession();
        var (draftId, _) = _service.CreateDraft(sessionId, new CreateDraftOperationRequest { Body = "test" });
        _service.ApproveDraft(sessionId, draftId);

        Assert.Throws<SessionServiceException>(() =>
            _service.ApproveDraft(sessionId, draftId));
    }

    // --- UnapproveDraft ---

    [Fact]
    public void UnapproveDraft_TransitionsBackToDraft()
    {
        var sessionId = CreateAndSaveSession();
        var (draftId, _) = _service.CreateDraft(sessionId, new CreateDraftOperationRequest { Body = "test" });
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
        var (draftId, _) = _service.CreateDraft(sessionId, new CreateDraftOperationRequest { Body = "test" });

        Assert.Throws<SessionServiceException>(() =>
            _service.UnapproveDraft(sessionId, draftId));
    }

    // --- ApproveAllDrafts ---

    [Fact]
    public void ApproveAllDrafts_ApprovesOnlyDraftStatus()
    {
        var sessionId = CreateAndSaveSession();
        _service.CreateDraft(sessionId, new CreateDraftOperationRequest { Body = "draft 1" });
        _service.CreateDraft(sessionId, new CreateDraftOperationRequest { Body = "draft 2" });
        var (id3, _) = _service.CreateDraft(sessionId, new CreateDraftOperationRequest { Body = "draft 3" });
        _service.ApproveDraft(sessionId, id3); // Already pending

        var count = _service.ApproveAllDrafts(sessionId);

        Assert.Equal(2, count);

        var loaded = _store.Load(sessionId)!;
        Assert.All(loaded.DraftOperations.Values, d => Assert.Equal(DraftStatus.Pending, d.Status));
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
        var (draftId, _) = _service.CreateDraft(sessionId, new CreateDraftOperationRequest { Body = "find me" });

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
        var sessionId = CreateAndSaveSession([
            new ChangedFile { Path = "a.cs" },
            new ChangedFile { Path = "b.cs" },
        ]);
        _service.CreateDraft(sessionId, new CreateDraftOperationRequest { FilePath = "a.cs", Body = "1" });
        _service.CreateDraft(sessionId, new CreateDraftOperationRequest { FilePath = "b.cs", Body = "2" });
        _service.CreateDraft(sessionId, new CreateDraftOperationRequest { FilePath = "a.cs", Body = "3" });

        var result = _service.GetDrafts(sessionId, "a.cs");

        Assert.Equal(2, result.Count);
        Assert.All(result.Values, d => Assert.Equal("a.cs", d.FilePath));
    }

    [Fact]
    public void GetDrafts_PathNormalization()
    {
        var sessionId = CreateAndSaveSession([new ChangedFile { Path = "src/main.cs" }]);
        _service.CreateDraft(sessionId, new CreateDraftOperationRequest { FilePath = "src\\main.cs", Body = "1" });

        var result = _service.GetDrafts(sessionId, "src/main.cs");

        Assert.Single(result);
    }

    // --- GetDraftCounts ---

    [Fact]
    public void GetDraftCounts_ReturnsCorrectCounts()
    {
        var sessionId = CreateAndSaveSession();
        _service.CreateDraft(sessionId, new CreateDraftOperationRequest { Body = "draft" });
        var (id2, _) = _service.CreateDraft(sessionId, new CreateDraftOperationRequest { Body = "pending" });
        _service.ApproveDraft(sessionId, id2);

        var counts = _service.GetDraftCounts(sessionId);

        Assert.Equal(2, counts.Total);
        Assert.Equal(1, counts.Draft);
        Assert.Equal(1, counts.Pending);
        Assert.Equal(0, counts.Submitted);
    }

    // --- EditDraft author guard ---

    [Fact]
    public void EditDraft_AiCallerCannotEditUserDraft()
    {
        var sessionId = CreateAndSaveSession();
        var (draftId, _) = _service.CreateDraft(sessionId, new CreateDraftOperationRequest
        {
            Body = "user draft",
            Author = DraftAuthor.User,
        });

        var ex = Assert.Throws<SessionServiceException>(() =>
            _service.EditDraft(sessionId, draftId, "ai edit", callerAuthor: DraftAuthor.Ai));
        Assert.Contains("author mismatch", ex.Message);
    }

    [Fact]
    public void EditDraft_UserCallerCannotEditAiDraft()
    {
        var sessionId = CreateAndSaveSession();
        var (draftId, _) = _service.CreateDraft(sessionId, new CreateDraftOperationRequest
        {
            Body = "ai draft",
            Author = DraftAuthor.Ai,
        });

        var ex = Assert.Throws<SessionServiceException>(() =>
            _service.EditDraft(sessionId, draftId, "user edit", callerAuthor: DraftAuthor.User));
        Assert.Contains("author mismatch", ex.Message);
    }

    [Fact]
    public void EditDraft_AiCallerCanEditOwnDraft()
    {
        var sessionId = CreateAndSaveSession();
        var (draftId, _) = _service.CreateDraft(sessionId, new CreateDraftOperationRequest
        {
            Body = "ai original",
            Author = DraftAuthor.Ai,
        });

        var edited = _service.EditDraft(sessionId, draftId, "ai updated", callerAuthor: DraftAuthor.Ai);
        Assert.Equal("ai updated", edited.Body);
    }

    [Fact]
    public void EditDraft_AiCallerEditsPendingDraft_ResetsToNewDraft()
    {
        var sessionId = CreateAndSaveSession();
        var (draftId, _) = _service.CreateDraft(sessionId, new CreateDraftOperationRequest
        {
            Body = "ai draft",
            Author = DraftAuthor.Ai,
        });
        _service.ApproveDraft(sessionId, draftId);

        // AI editing a Pending draft should reset status to Draft
        var edited = _service.EditDraft(sessionId, draftId, "revised body", callerAuthor: DraftAuthor.Ai);
        Assert.Equal(DraftStatus.Draft, edited.Status);
        Assert.Equal("revised body", edited.Body);
    }

    [Fact]
    public void EditDraft_NoCallerAuthor_AllowsEditingAnyDraft()
    {
        var sessionId = CreateAndSaveSession();
        var (draftId, _) = _service.CreateDraft(sessionId, new CreateDraftOperationRequest
        {
            Body = "ai draft",
            Author = DraftAuthor.Ai,
        });

        // No callerAuthor = no guard, allows editing any draft
        var edited = _service.EditDraft(sessionId, draftId, "edited without guard");
        Assert.Equal("edited without guard", edited.Body);
    }

    // --- DeleteDraft author guard ---

    [Fact]
    public void DeleteDraft_AiCallerCannotDeleteUserDraft()
    {
        var sessionId = CreateAndSaveSession();
        var (draftId, _) = _service.CreateDraft(sessionId, new CreateDraftOperationRequest
        {
            Body = "user draft",
            Author = DraftAuthor.User,
        });

        var ex = Assert.Throws<SessionServiceException>(() =>
            _service.DeleteDraft(sessionId, draftId, callerAuthor: DraftAuthor.Ai));
        Assert.Contains("author mismatch", ex.Message);
    }

    [Fact]
    public void DeleteDraft_UserCallerCannotDeleteAiDraft()
    {
        var sessionId = CreateAndSaveSession();
        var (draftId, _) = _service.CreateDraft(sessionId, new CreateDraftOperationRequest
        {
            Body = "ai draft",
            Author = DraftAuthor.Ai,
        });

        var ex = Assert.Throws<SessionServiceException>(() =>
            _service.DeleteDraft(sessionId, draftId, callerAuthor: DraftAuthor.User));
        Assert.Contains("author mismatch", ex.Message);
    }

    [Fact]
    public void DeleteDraft_AiCallerCanDeleteOwnDraft()
    {
        var sessionId = CreateAndSaveSession();
        var (draftId, _) = _service.CreateDraft(sessionId, new CreateDraftOperationRequest
        {
            Body = "ai draft",
            Author = DraftAuthor.Ai,
        });

        _service.DeleteDraft(sessionId, draftId, callerAuthor: DraftAuthor.Ai);

        var loaded = _store.Load(sessionId)!;
        Assert.Empty(loaded.DraftOperations);
    }

    [Fact]
    public void DeleteDraft_NoCallerAuthor_AllowsDeletingAnyDraft()
    {
        var sessionId = CreateAndSaveSession();
        var (draftId, _) = _service.CreateDraft(sessionId, new CreateDraftOperationRequest
        {
            Body = "ai draft",
            Author = DraftAuthor.Ai,
        });

        // No callerAuthor = no guard
        _service.DeleteDraft(sessionId, draftId);
        var loaded = _store.Load(sessionId)!;
        Assert.Empty(loaded.DraftOperations);
    }

    // --- GetDraftsByStatus ---

    [Fact]
    public void GetDraftsByStatus_FiltersDraftStatus()
    {
        var sessionId = CreateAndSaveSession();
        _service.CreateDraft(sessionId, new CreateDraftOperationRequest { Body = "draft1" });
        _service.CreateDraft(sessionId, new CreateDraftOperationRequest { Body = "draft2" });
        var (pendingId, _) = _service.CreateDraft(sessionId, new CreateDraftOperationRequest { Body = "pending1" });
        _service.ApproveDraft(sessionId, pendingId);

        var drafts = _service.GetDraftsByStatus(sessionId, DraftStatus.Draft);
        Assert.Equal(2, drafts.Count);
        Assert.All(drafts.Values, d => Assert.Equal(DraftStatus.Draft, d.Status));
    }

    [Fact]
    public void GetDraftsByStatus_FiltersPendingStatus()
    {
        var sessionId = CreateAndSaveSession();
        _service.CreateDraft(sessionId, new CreateDraftOperationRequest { Body = "draft1" });
        var (pendingId, _) = _service.CreateDraft(sessionId, new CreateDraftOperationRequest { Body = "pending1" });
        _service.ApproveDraft(sessionId, pendingId);

        var pending = _service.GetDraftsByStatus(sessionId, DraftStatus.Pending);
        Assert.Single(pending);
        Assert.All(pending.Values, d => Assert.Equal(DraftStatus.Pending, d.Status));
    }

    [Fact]
    public void GetDraftsByStatus_ReturnsEmptyForNonexistentSession()
    {
        var result = _service.GetDraftsByStatus("nonexistent", DraftStatus.Draft);
        Assert.Empty(result);
    }

    [Fact]
    public void GetDraftsByStatus_ReturnsEmptyWhenNoneMatch()
    {
        var sessionId = CreateAndSaveSession();
        _service.CreateDraft(sessionId, new CreateDraftOperationRequest { Body = "draft" });

        var result = _service.GetDraftsByStatus(sessionId, DraftStatus.Submitted);
        Assert.Empty(result);
    }

    // --- Draft actions ---

    [Fact]
    public void CreateDraftThreadStatusChange_CreatesDraftOperation()
    {
        var sessionId = CreateAndSaveSessionWithThread();

        var (id, action) = _service.CreateDraftThreadStatusChange(sessionId, new CreateDraftOperationRequest
        {
            ThreadId = 42,
            ToThreadStatus = ThreadStatus.WontFix,
            Note = "agent was wrong",
            Author = DraftAuthor.Ai,
            AuthorName = "Agent",
        });

        Assert.NotEmpty(id);
        Assert.Equal(DraftOperationType.ThreadStatusChange, action.OperationType);
        Assert.Equal(DraftStatus.Draft, action.Status);
        Assert.Equal(ThreadStatus.Active, action.FromThreadStatus);
        Assert.Equal(ThreadStatus.WontFix, action.ToThreadStatus);
        Assert.Equal("agent was wrong", action.Note);
        Assert.Equal(DraftAuthor.Ai, action.Author);

        var loaded = _store.Load(sessionId)!;
        Assert.True(loaded.DraftOperations.ContainsKey(id));
    }

    [Fact]
    public void CreateDraftOperationReaction_CreatesDraftOperation()
    {
        var sessionId = CreateAndSaveSessionWithThread();
        var session = _store.Load(sessionId)!;
        session.Threads.Items[0].Comments = [new Comment { Id = 7, ThreadId = 42, Body = "You are wrong" }];
        _store.Save(session);

        var (_, action) = _service.CreateDraftCommentReaction(sessionId, new CreateDraftOperationRequest
        {
            ThreadId = 42,
            CommentId = 7,
            Reaction = CommentReaction.Like,
            Author = DraftAuthor.Ai,
        });

        Assert.Equal(DraftOperationType.CommentReaction, action.OperationType);
        Assert.Equal(7, action.CommentId);
        Assert.Equal(CommentReaction.Like, action.Reaction);
        Assert.Equal(DraftStatus.Draft, action.Status);
    }

    [Fact]
    public void ApproveAndUnapproveDraftOperation_TransitionsStatus()
    {
        var sessionId = CreateAndSaveSessionWithThread();
        var (id, _) = _service.CreateDraftThreadStatusChange(sessionId, new CreateDraftOperationRequest
        {
            ThreadId = 42,
            ToThreadStatus = ThreadStatus.Fixed,
        });

        var approved = _service.ApproveDraft(sessionId, id);
        Assert.Equal(DraftStatus.Pending, approved.Status);

        var unapproved = _service.UnapproveDraft(sessionId, id);
        Assert.Equal(DraftStatus.Draft, unapproved.Status);
    }

    [Fact]
    public void DeleteDraftOperation_AuthorGuardPreventsAiDeletingUserAction()
    {
        var sessionId = CreateAndSaveSessionWithThread();
        var (id, _) = _service.CreateDraftThreadStatusChange(sessionId, new CreateDraftOperationRequest
        {
            ThreadId = 42,
            ToThreadStatus = ThreadStatus.Fixed,
            Author = DraftAuthor.User,
        });

        var ex = Assert.Throws<SessionServiceException>(() =>
            _service.DeleteDraft(sessionId, id, callerAuthor: DraftAuthor.Ai));
        Assert.Contains("author mismatch", ex.Message);
    }

    // --- MarkSubmitted ---

    [Fact]
    public void MarkSubmitted_TransitionsToSubmitted()
    {
        var sessionId = CreateAndSaveSession();
        var (draftId, _) = _service.CreateDraft(sessionId, new CreateDraftOperationRequest { Body = "test" });
        _service.ApproveDraft(sessionId, draftId);

        // MarkSubmitted is internal, but accessible within the same assembly for testing
        _service.MarkSubmitted(sessionId, draftId);

        var loaded = _store.Load(sessionId)!;
        Assert.Equal(DraftStatus.Submitted, loaded.DraftOperations[draftId].Status);
    }

    [Fact]
    public void MarkSubmitted_NonexistentDraft_Throws()
    {
        var sessionId = CreateAndSaveSession();

        Assert.Throws<SessionServiceException>(() =>
            _service.MarkSubmitted(sessionId, "nonexistent-id"));
    }

    // --- LoadSession ---

    [Fact]
    public void LoadSession_ExistingSession_ReturnsSession()
    {
        var sessionId = CreateAndSaveSession();
        var session = _service.LoadSession(sessionId);
        Assert.NotNull(session);
        Assert.Equal(sessionId, session.Id);
    }

    [Fact]
    public void LoadSession_NonexistentSession_ReturnsNull()
    {
        var session = _service.LoadSession("nonexistent");
        Assert.Null(session);
    }

    // --- GetSessionPath ---

    [Fact]
    public void GetSessionPath_ReturnsValidPath()
    {
        var sessionId = CreateAndSaveSession();
        var path = _service.GetSessionPath(sessionId);
        Assert.NotEmpty(path);
        Assert.Contains(sessionId, path);
    }

    // --- Full lifecycle ---

    [Fact]
    public void FullLifecycle_CreateEditApproveUnapproveDelete()
    {
        var sessionId = CreateAndSaveSession([new ChangedFile { Path = "test.cs" }]);

        // Create
        var (draftId, draft) = _service.CreateDraft(sessionId, new CreateDraftOperationRequest
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
        Assert.Empty(_store.Load(sessionId)!.DraftOperations);
    }

    // --- DeleteAllDrafts ---

    [Fact]
    public void DeleteAllDrafts_DeletesAllDraftStatus()
    {
        var sessionId = CreateAndSaveSession([new ChangedFile { Path = "src/main.cs" }]);
        _service.CreateDraft(sessionId, new CreateDraftOperationRequest
        {
            FilePath = "src/main.cs", Body = "Comment 1", Author = DraftAuthor.Ai,
        });
        _service.CreateDraft(sessionId, new CreateDraftOperationRequest
        {
            FilePath = "src/main.cs", Body = "Comment 2", Author = DraftAuthor.User,
        });

        var count = _service.DeleteAllDrafts(sessionId);

        Assert.Equal(2, count);
        Assert.Empty(_store.Load(sessionId)!.DraftOperations);
    }

    [Fact]
    public void DeleteAllDrafts_FilterByAiAuthor_OnlyDeletesAiDrafts()
    {
        var sessionId = CreateAndSaveSession([new ChangedFile { Path = "src/main.cs" }]);
        _service.CreateDraft(sessionId, new CreateDraftOperationRequest
        {
            FilePath = "src/main.cs", Body = "AI comment", Author = DraftAuthor.Ai,
        });
        _service.CreateDraft(sessionId, new CreateDraftOperationRequest
        {
            FilePath = "src/main.cs", Body = "User comment", Author = DraftAuthor.User,
        });

        var count = _service.DeleteAllDrafts(sessionId, DraftAuthor.Ai);

        Assert.Equal(1, count);
        var remaining = _store.Load(sessionId)!.DraftOperations;
        Assert.Single(remaining);
        Assert.Equal(DraftAuthor.User, remaining.Values.First().Author);
    }

    [Fact]
    public void DeleteAllDrafts_SkipsPendingDrafts()
    {
        var sessionId = CreateAndSaveSession([new ChangedFile { Path = "src/main.cs" }]);
        var (draftId, _) = _service.CreateDraft(sessionId, new CreateDraftOperationRequest
        {
            FilePath = "src/main.cs", Body = "Comment", Author = DraftAuthor.Ai,
        });
        _service.ApproveDraft(sessionId, draftId);

        var count = _service.DeleteAllDrafts(sessionId);

        Assert.Equal(0, count); // Pending status is not deletable
        Assert.Single(_store.Load(sessionId)!.DraftOperations);
    }

    [Fact]
    public void DeleteAllDrafts_NoDrafts_ReturnsZero()
    {
        var sessionId = CreateAndSaveSession();

        var count = _service.DeleteAllDrafts(sessionId);

        Assert.Equal(0, count);
    }
}
