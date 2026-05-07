using PowerReview.Cli.Mcp;
using PowerReview.Core.Configuration;
using PowerReview.Core.Models;
using PowerReview.Core.Services;
using PowerReview.Core.Store;
using System.Reflection;

namespace PowerReview.Core.Tests;

/// <summary>
/// Tests for MCP tool helper functions and draft tool safety constraints.
/// These test the MCP tool layer logic without requiring MCP transport.
/// </summary>
public class McpToolTests : IDisposable
{
    private readonly string _tempDir;
    private readonly SessionStore _store;
    private readonly SessionService _sessionService;
    private readonly ReviewService _reviewService;
    private readonly ProposalService _proposalService;

    public McpToolTests()
    {
        _tempDir = Path.Combine(Path.GetTempPath(), "powerreview-mcp-tests-" + Guid.NewGuid().ToString("N")[..8]);
        _store = new SessionStore(_tempDir);
        _sessionService = new SessionService(_store);
        var config = new PowerReviewConfig();
        var authResolver = new PowerReview.Core.Auth.AuthResolver(config.Auth);
        var fixWorktreeService = new FixWorktreeService(_store, config);
        _reviewService = new ReviewService(_store, _sessionService, config, authResolver, fixWorktreeService);
        _proposalService = new ProposalService(_store, _sessionService, fixWorktreeService);
    }

    public void Dispose()
    {
        if (Directory.Exists(_tempDir))
            Directory.Delete(_tempDir, recursive: true);
    }

    private ReviewSession CreateAndSaveTestSession()
    {
        var now = DateTime.UtcNow.ToString("o");
        var session = new ReviewSession
        {
            Id = "azdo_testorg_testproject_testrepo_42",
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
                Description = "This is a test PR description.",
                SourceBranch = "feature/test",
                TargetBranch = "main",
            },
            Files = [
                new ChangedFile { Path = "src/main.cs", ChangeType = ChangeType.Edit },
                new ChangedFile { Path = "src/utils.cs", ChangeType = ChangeType.Add },
            ],
            CreatedAt = now,
            UpdatedAt = now,
        };
        _store.Save(session);
        return session;
    }

    // =========================================================================
    // ToolHelpers.ResolveSessionId
    // =========================================================================

    [Fact]
    public void ResolveSessionId_ValidAzDoUrl_ReturnsCorrectId()
    {
        var id = ToolHelpers.ResolveSessionId("https://dev.azure.com/testorg/testproject/_git/testrepo/pullrequest/42");
        Assert.Equal("azdo_testorg_testproject_testrepo_42", id);
    }

    [Fact]
    public void ResolveSessionId_ValidGitHubUrl_ReturnsCorrectId()
    {
        var id = ToolHelpers.ResolveSessionId("https://github.com/owner/repo/pull/99");
        Assert.Equal("github_owner_repo_repo_99", id);
    }

    [Fact]
    public void ResolveSessionId_InvalidUrl_ThrowsArgumentException()
    {
        Assert.Throws<ArgumentException>(() => ToolHelpers.ResolveSessionId("not-a-valid-url"));
    }

    [Fact]
    public void ResolveSessionId_EmptyUrl_ThrowsArgumentException()
    {
        Assert.Throws<ArgumentException>(() => ToolHelpers.ResolveSessionId(""));
    }

    // =========================================================================
    // DraftTools: CreateComment enforces Author = Ai
    // =========================================================================

    [Fact]
    public void CreateComment_SetsAuthorToAi()
    {
        CreateAndSaveTestSession();

        var result = DraftTools.CreateComment(
            _sessionService,
            prUrl: "https://dev.azure.com/testorg/testproject/_git/testrepo/pullrequest/42",
            filePath: "src/main.cs",
            body: "This needs a null check.",
            lineStart: 10);

        // Parse the JSON result
        var json = System.Text.Json.JsonDocument.Parse(result);
        Assert.False(json.RootElement.TryGetProperty("error", out _), "Expected success but got error");
        Assert.True(json.RootElement.TryGetProperty("id", out _));

        // Verify the draft was created with AI author
        var sessionId = ToolHelpers.ResolveSessionId("https://dev.azure.com/testorg/testproject/_git/testrepo/pullrequest/42");
        var session = _store.Load(sessionId)!;
        var draft = session.Drafts.Values.First();
        Assert.Equal(DraftAuthor.Ai, draft.Author);
    }

    // =========================================================================
    // DraftTools: EditDraftComment resets Pending to Draft
    // =========================================================================

    [Fact]
    public void EditDraftComment_PendingDraft_ResetsBackToDraft()
    {
        CreateAndSaveTestSession();
        var sessionId = "azdo_testorg_testproject_testrepo_42";
        var prUrl = "https://dev.azure.com/testorg/testproject/_git/testrepo/pullrequest/42";

        // Create and approve a draft
        var (draftId, _) = _sessionService.CreateDraft(sessionId, new CreateDraftRequest
        {
            FilePath = "src/main.cs",
            LineStart = 5,
            Body = "Original body",
            Author = DraftAuthor.Ai,
        });
        _sessionService.ApproveDraft(sessionId, draftId);

        // Verify it's pending
        var beforeEdit = _sessionService.GetDraft(sessionId, draftId)!.Value;
        Assert.Equal(DraftStatus.Pending, beforeEdit.Draft.Status);

        // Edit it via MCP tool
        var result = DraftTools.EditDraftComment(
            _sessionService,
            prUrl: prUrl,
            draftId: draftId,
            newBody: "Updated body");

        // Parse the JSON result
        var json = System.Text.Json.JsonDocument.Parse(result);
        Assert.False(json.RootElement.TryGetProperty("error", out _), "Expected success but got error");

        // Verify it was reset to Draft
        var afterEdit = _sessionService.GetDraft(sessionId, draftId)!.Value;
        Assert.Equal(DraftStatus.Draft, afterEdit.Draft.Status);
        Assert.Equal("Updated body", afterEdit.Draft.Body);
    }

    // =========================================================================
    // DraftTools: DeleteDraftComment rejects non-AI-authored drafts
    // =========================================================================

    [Fact]
    public void DeleteDraftComment_UserAuthored_ReturnsError()
    {
        CreateAndSaveTestSession();
        var sessionId = "azdo_testorg_testproject_testrepo_42";
        var prUrl = "https://dev.azure.com/testorg/testproject/_git/testrepo/pullrequest/42";

        // Create a user-authored draft
        var (draftId, _) = _sessionService.CreateDraft(sessionId, new CreateDraftRequest
        {
            FilePath = "src/main.cs",
            LineStart = 5,
            Body = "User comment",
            Author = DraftAuthor.User,
        });

        // Try to delete via MCP tool (should fail - AI caller cannot delete user's draft)
        var result = DraftTools.DeleteDraftComment(
            _sessionService,
            prUrl: prUrl,
            draftId: draftId);

        var json = System.Text.Json.JsonDocument.Parse(result);
        Assert.True(json.RootElement.TryGetProperty("error", out _), "Expected error for user-authored draft");
    }

    [Fact]
    public void DeleteDraftComment_AiAuthored_Succeeds()
    {
        CreateAndSaveTestSession();
        var sessionId = "azdo_testorg_testproject_testrepo_42";
        var prUrl = "https://dev.azure.com/testorg/testproject/_git/testrepo/pullrequest/42";

        // Create an AI-authored draft
        var (draftId, _) = _sessionService.CreateDraft(sessionId, new CreateDraftRequest
        {
            FilePath = "src/main.cs",
            LineStart = 5,
            Body = "AI comment",
            Author = DraftAuthor.Ai,
        });

        // Delete via MCP tool (should succeed)
        var result = DraftTools.DeleteDraftComment(
            _sessionService,
            prUrl: prUrl,
            draftId: draftId);

        var json = System.Text.Json.JsonDocument.Parse(result);
        Assert.False(json.RootElement.TryGetProperty("error", out _), "Expected success but got error");

        // Verify it was deleted
        var draft = _sessionService.GetDraft(sessionId, draftId);
        Assert.Null(draft);
    }

    // =========================================================================
    // ThreadTools: ReplyToThread creates draft reply
    // =========================================================================

    [Fact]
    public void ReplyToThread_CreatesAiAuthoredReply()
    {
        CreateAndSaveTestSessionWithThreads();
        var prUrl = "https://dev.azure.com/testorg/testproject/_git/testrepo/pullrequest/42";
        var sessionId = "azdo_testorg_testproject_testrepo_42";

        var result = ThreadTools.ReplyToThread(
            _sessionService,
            prUrl: prUrl,
            threadId: 100,
            body: "Reply body",
            agentName: "TestAgent");

        var json = System.Text.Json.JsonDocument.Parse(result);
        Assert.False(json.RootElement.TryGetProperty("error", out _), "Expected success but got error");
        Assert.True(json.RootElement.TryGetProperty("id", out _));

        // Verify the draft is AI-authored reply
        var session = _store.Load(sessionId)!;
        var draft = session.Drafts.Values.First();
        Assert.Equal(DraftAuthor.Ai, draft.Author);
        Assert.Equal("TestAgent", draft.AuthorName);
        Assert.Equal(100, draft.ThreadId);
        Assert.Equal("src/main.cs", draft.FilePath);
        Assert.Equal(10, draft.LineStart);
    }

    [Fact]
    public void DraftThreadStatusChange_CreatesAiAuthoredDraftAction()
    {
        CreateAndSaveTestSessionWithThreads();
        var prUrl = "https://dev.azure.com/testorg/testproject/_git/testrepo/pullrequest/42";
        var sessionId = "azdo_testorg_testproject_testrepo_42";

        var result = ThreadTools.DraftThreadStatusChange(
            _sessionService,
            prUrl: prUrl,
            threadId: 100,
            status: "wontfix",
            reason: "agent agreed this was wrong",
            agentName: "TestAgent");

        var json = System.Text.Json.JsonDocument.Parse(result);
        Assert.False(json.RootElement.TryGetProperty("error", out _), "Expected success but got error");
        Assert.True(json.RootElement.TryGetProperty("id", out _));

        var session = _store.Load(sessionId)!;
        var action = session.DraftActions.Values.First();
        Assert.Equal(DraftActionType.ThreadStatusChange, action.ActionType);
        Assert.Equal(DraftAuthor.Ai, action.Author);
        Assert.Equal("TestAgent", action.AuthorName);
        Assert.Equal(100, action.ThreadId);
        Assert.Equal(ThreadStatus.WontFix, action.ToThreadStatus);
    }

    [Fact]
    public void DraftCommentReaction_CreatesAiAuthoredDraftAction()
    {
        CreateAndSaveTestSessionWithThreads();
        var prUrl = "https://dev.azure.com/testorg/testproject/_git/testrepo/pullrequest/42";
        var sessionId = "azdo_testorg_testproject_testrepo_42";

        var result = ThreadTools.DraftCommentReaction(
            _sessionService,
            prUrl: prUrl,
            threadId: 100,
            commentId: 1,
            reaction: "like",
            reason: "acknowledge correction",
            agentName: "TestAgent");

        var json = System.Text.Json.JsonDocument.Parse(result);
        Assert.False(json.RootElement.TryGetProperty("error", out _), "Expected success but got error");

        var session = _store.Load(sessionId)!;
        var action = session.DraftActions.Values.First();
        Assert.Equal(DraftActionType.CommentReaction, action.ActionType);
        Assert.Equal(CommentReaction.Like, action.Reaction);
        Assert.Equal(1, action.CommentId);
        Assert.Equal(DraftAuthor.Ai, action.Author);
    }

    [Fact]
    public void ThreadTools_DoesNotExposeDirectUpdateThreadStatusTool()
    {
        var method = typeof(ThreadTools).GetMethod("UpdateThreadStatus", BindingFlags.Public | BindingFlags.Static);
        Assert.Null(method);
    }

    // =========================================================================
    // ReviewTools: GetDraftCounts returns correct counts
    // =========================================================================

    [Fact]
    public void GetDraftCounts_ReturnsCorrectCounts()
    {
        CreateAndSaveTestSession();
        var prUrl = "https://dev.azure.com/testorg/testproject/_git/testrepo/pullrequest/42";
        var sessionId = "azdo_testorg_testproject_testrepo_42";

        // Create drafts in different states
        var (draftId1, _) = _sessionService.CreateDraft(sessionId, new CreateDraftRequest
        {
            FilePath = "src/main.cs", LineStart = 1, Body = "Draft 1", Author = DraftAuthor.Ai,
        });
        var (draftId2, _) = _sessionService.CreateDraft(sessionId, new CreateDraftRequest
        {
            FilePath = "src/main.cs", LineStart = 2, Body = "Draft 2", Author = DraftAuthor.Ai,
        });
        _sessionService.ApproveDraft(sessionId, draftId2);
        var (draftId3, _) = _sessionService.CreateDraft(sessionId, new CreateDraftRequest
        {
            FilePath = "src/main.cs", LineStart = 3, Body = "Draft 3", Author = DraftAuthor.User,
        });

        var result = ReviewTools.GetDraftCounts(_sessionService, prUrl);

        var json = System.Text.Json.JsonDocument.Parse(result);
        Assert.Equal(2, json.RootElement.GetProperty("draft").GetInt32());
        Assert.Equal(1, json.RootElement.GetProperty("pending").GetInt32());
        Assert.Equal(3, json.RootElement.GetProperty("total").GetInt32());
    }

    [Fact]
    public async Task GetFileDiff_WithoutLocalRepo_ReturnsError()
    {
        CreateAndSaveTestSession();
        var prUrl = "https://dev.azure.com/testorg/testproject/_git/testrepo/pullrequest/42";

        var result = await ReviewTools.GetFileDiff(_reviewService, prUrl, "src/main.cs", CancellationToken.None);

        var json = System.Text.Json.JsonDocument.Parse(result);
        Assert.True(json.RootElement.TryGetProperty("error", out var error));
        Assert.Contains("No local git repository", error.GetString());
    }

    // =========================================================================
    // ProposalTools: CreateProposal
    // =========================================================================

    [Fact]
    public void CreateProposal_SetsAuthorToAi()
    {
        CreateAndSaveTestSessionWithThreads();
        var prUrl = "https://dev.azure.com/testorg/testproject/_git/testrepo/pullrequest/42";
        var sessionId = "azdo_testorg_testproject_testrepo_42";

        var result = ProposalTools.CreateProposal(
            _proposalService,
            prUrl: prUrl,
            threadId: 100,
            branchName: "powerreview/fix/thread-100",
            description: "Fixed null check",
            filesChanged: "src/main.cs,src/utils.cs",
            agentName: "CodeFixer");

        var json = System.Text.Json.JsonDocument.Parse(result);
        Assert.False(json.RootElement.TryGetProperty("error", out _), "Expected success but got error");
        Assert.True(json.RootElement.TryGetProperty("id", out _));

        // Verify the proposal was created with AI author
        var session = _store.Load(sessionId)!;
        var proposal = session.Proposals.Values.First();
        Assert.Equal(DraftAuthor.Ai, proposal.Author);
        Assert.Equal("CodeFixer", proposal.AuthorName);
        Assert.Equal(100, proposal.ThreadId);
        Assert.Equal("powerreview/fix/thread-100", proposal.BranchName);
        Assert.Equal(2, proposal.FilesChanged.Count);
    }

    [Fact]
    public void CreateProposal_WithLinkedReply_StoresReplyDraftId()
    {
        CreateAndSaveTestSessionWithThreads();
        var prUrl = "https://dev.azure.com/testorg/testproject/_git/testrepo/pullrequest/42";
        var sessionId = "azdo_testorg_testproject_testrepo_42";

        // Create a reply draft first
        var (replyId, _) = _sessionService.CreateDraft(sessionId, new CreateDraftRequest
        {
            ThreadId = 100,
            Body = "Fixed: null check added",
            Author = DraftAuthor.Ai,
        });

        var result = ProposalTools.CreateProposal(
            _proposalService,
            prUrl: prUrl,
            threadId: 100,
            branchName: "powerreview/fix/thread-100",
            description: "Added null check",
            replyDraftId: replyId);

        var json = System.Text.Json.JsonDocument.Parse(result);
        Assert.False(json.RootElement.TryGetProperty("error", out _), "Expected success but got error");

        var session = _store.Load(sessionId)!;
        var proposal = session.Proposals.Values.First();
        Assert.Equal(replyId, proposal.ReplyDraftId);
    }

    [Fact]
    public void CreateProposal_MissingBranch_ReturnsError()
    {
        CreateAndSaveTestSessionWithThreads();
        var prUrl = "https://dev.azure.com/testorg/testproject/_git/testrepo/pullrequest/42";

        var result = ProposalTools.CreateProposal(
            _proposalService,
            prUrl: prUrl,
            threadId: 100,
            branchName: "",
            description: "Fix");

        var json = System.Text.Json.JsonDocument.Parse(result);
        Assert.True(json.RootElement.TryGetProperty("error", out _), "Expected error for empty branch");
    }

    // =========================================================================
    // ProposalTools: ListProposals
    // =========================================================================

    [Fact]
    public void ListProposals_ReturnsProposalsAndCounts()
    {
        CreateAndSaveTestSessionWithThreads();
        var prUrl = "https://dev.azure.com/testorg/testproject/_git/testrepo/pullrequest/42";
        var sessionId = "azdo_testorg_testproject_testrepo_42";

        // Create two proposals
        _proposalService.CreateProposal(sessionId, new CreateProposalRequest
        {
            ThreadId = 100,
            BranchName = "powerreview/fix/thread-100",
            Description = "Fix 1",
        });
        _proposalService.CreateProposal(sessionId, new CreateProposalRequest
        {
            ThreadId = 200,
            BranchName = "powerreview/fix/thread-200",
            Description = "Fix 2",
        });

        var result = ProposalTools.ListProposals(_proposalService, prUrl);

        var json = System.Text.Json.JsonDocument.Parse(result);
        Assert.False(json.RootElement.TryGetProperty("error", out _), "Expected success but got error");
        Assert.Equal(2, json.RootElement.GetProperty("counts").GetProperty("total").GetInt32());
        Assert.Equal(2, json.RootElement.GetProperty("counts").GetProperty("draft").GetInt32());
    }

    // =========================================================================
    // Helper to create sessions with threads
    // =========================================================================

    private ReviewSession CreateAndSaveTestSessionWithThreads()
    {
        var now = DateTime.UtcNow.ToString("o");
        var session = new ReviewSession
        {
            Id = "azdo_testorg_testproject_testrepo_42",
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
                Description = "This is a test PR description.",
                SourceBranch = "feature/test",
                TargetBranch = "main",
            },
            Files = [
                new ChangedFile { Path = "src/main.cs", ChangeType = ChangeType.Edit },
                new ChangedFile { Path = "src/utils.cs", ChangeType = ChangeType.Add },
            ],
            Threads = new ThreadsInfo
            {
                SyncedAt = now,
                Items = [
                    new CommentThread
                    {
                        Id = 100,
                        FilePath = "src/main.cs",
                        LineStart = 10,
                        Status = ThreadStatus.Active,
                        Comments = [new Comment { Id = 1, ThreadId = 100, Body = "Fix this" }],
                    },
                    new CommentThread
                    {
                        Id = 200,
                        FilePath = "src/utils.cs",
                        LineStart = 20,
                        Status = ThreadStatus.Active,
                        Comments = [new Comment { Id = 2, ThreadId = 200, Body = "Refactor this" }],
                    },
                ],
            },
            CreatedAt = now,
            UpdatedAt = now,
        };
        _store.Save(session);
        return session;
    }
}
