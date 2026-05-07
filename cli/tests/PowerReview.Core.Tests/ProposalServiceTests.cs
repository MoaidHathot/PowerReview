using PowerReview.Core.Models;
using PowerReview.Core.Services;
using PowerReview.Core.Store;

namespace PowerReview.Core.Tests;

public class ProposalServiceTests : IDisposable
{
    private readonly string _tempDir;
    private readonly SessionStore _store;
    private readonly SessionService _sessionService;
    private readonly FixWorktreeService _fixWorktreeService;
    private readonly ProposalService _service;

    public ProposalServiceTests()
    {
        _tempDir = Path.Combine(Path.GetTempPath(), "powerreview-proposal-tests-" + Guid.NewGuid().ToString("N")[..8]);
        _store = new SessionStore(_tempDir);
        _sessionService = new SessionService(_store);
        var config = new Core.Configuration.PowerReviewConfig();
        _fixWorktreeService = new FixWorktreeService(_store, config);
        _service = new ProposalService(_store, _sessionService, _fixWorktreeService);
    }

    public void Dispose()
    {
        if (Directory.Exists(_tempDir))
            Directory.Delete(_tempDir, recursive: true);
    }

    private string CreateAndSaveSession(List<CommentThread>? threads = null)
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
            PullRequest = new PullRequestInfo
            {
                Id = 1,
                Title = "Test PR",
                SourceBranch = "feature/test",
                TargetBranch = "main",
            },
            Files = [new ChangedFile { Path = "src/main.cs" }],
            Threads = new ThreadsInfo
            {
                SyncedAt = now,
                Items = threads ?? [
                    new CommentThread
                    {
                        Id = 42,
                        FilePath = "src/main.cs",
                        LineStart = 10,
                        Status = ThreadStatus.Active,
                        Comments = [new Comment { Id = 1, ThreadId = 42, Body = "Fix this" }],
                    },
                    new CommentThread
                    {
                        Id = 55,
                        FilePath = "src/main.cs",
                        LineStart = 20,
                        Status = ThreadStatus.Active,
                        Comments = [new Comment { Id = 2, ThreadId = 55, Body = "Refactor this" }],
                    },
                ],
            },
            CreatedAt = now,
            UpdatedAt = now,
        };
        _store.Save(session);
        return session.Id;
    }

    // --- CreateProposal ---

    [Fact]
    public void CreateProposal_AddsToSession()
    {
        var sessionId = CreateAndSaveSession();

        var (id, proposal) = _service.CreateProposal(sessionId, new CreateProposalRequest
        {
            ThreadId = 42,
            BranchName = "powerreview/fix/thread-42",
            Description = "Fixed null check",
            FilesChanged = ["src/main.cs"],
        });

        Assert.NotNull(id);
        Assert.NotEmpty(id);
        Assert.Equal(42, proposal.ThreadId);
        Assert.Equal("powerreview/fix/thread-42", proposal.BranchName);
        Assert.Equal("Fixed null check", proposal.Description);
        Assert.Equal(ProposalStatus.Draft, proposal.Status);
        Assert.Equal(DraftAuthor.Ai, proposal.Author);
        Assert.Single(proposal.FilesChanged);
        Assert.Equal("src/main.cs", proposal.FilesChanged[0]);

        // Verify persisted
        var loaded = _store.Load(sessionId)!;
        Assert.Single(loaded.Proposals);
        Assert.True(loaded.Proposals.ContainsKey(id));
    }

    [Fact]
    public void CreateProposal_DefaultAuthorIsAi()
    {
        var sessionId = CreateAndSaveSession();

        var (_, proposal) = _service.CreateProposal(sessionId, new CreateProposalRequest
        {
            ThreadId = 42,
            BranchName = "powerreview/fix/thread-42",
            Description = "Fix",
        });

        Assert.Equal(DraftAuthor.Ai, proposal.Author);
        Assert.True(proposal.IsAiAuthored);
    }

    [Fact]
    public void CreateProposal_WithAuthorName()
    {
        var sessionId = CreateAndSaveSession();

        var (_, proposal) = _service.CreateProposal(sessionId, new CreateProposalRequest
        {
            ThreadId = 42,
            BranchName = "powerreview/fix/thread-42",
            Description = "Fix",
            AuthorName = "CodeFixer",
        });

        Assert.Equal("CodeFixer", proposal.AuthorName);
    }

    [Fact]
    public void CreateProposal_WithLinkedReplyDraft()
    {
        var sessionId = CreateAndSaveSession();

        // Create a reply draft first
        var (replyId, _) = _sessionService.CreateDraft(sessionId, new CreateDraftOperationRequest
        {
            ThreadId = 42,
            Body = "Fixed: null check added",
            Author = DraftAuthor.Ai,
        });

        var (_, proposal) = _service.CreateProposal(sessionId, new CreateProposalRequest
        {
            ThreadId = 42,
            BranchName = "powerreview/fix/thread-42",
            Description = "Added null check",
            ReplyDraftId = replyId,
        });

        Assert.Equal(replyId, proposal.ReplyDraftId);
    }

    [Fact]
    public void CreateProposal_EmptyBranch_Throws()
    {
        var sessionId = CreateAndSaveSession();

        var ex = Assert.Throws<ProposalServiceException>(() =>
            _service.CreateProposal(sessionId, new CreateProposalRequest
            {
                ThreadId = 42,
                BranchName = "",
                Description = "Fix",
            }));
        Assert.Contains("Branch name is required", ex.Message);
    }

    [Fact]
    public void CreateProposal_EmptyDescription_Throws()
    {
        var sessionId = CreateAndSaveSession();

        var ex = Assert.Throws<ProposalServiceException>(() =>
            _service.CreateProposal(sessionId, new CreateProposalRequest
            {
                ThreadId = 42,
                BranchName = "powerreview/fix/thread-42",
                Description = "",
            }));
        Assert.Contains("Description is required", ex.Message);
    }

    [Fact]
    public void CreateProposal_NonexistentThread_Throws()
    {
        var sessionId = CreateAndSaveSession();

        var ex = Assert.Throws<ProposalServiceException>(() =>
            _service.CreateProposal(sessionId, new CreateProposalRequest
            {
                ThreadId = 999, // doesn't exist
                BranchName = "powerreview/fix/thread-999",
                Description = "Fix",
            }));
        Assert.Contains("Thread 999 not found", ex.Message);
    }

    [Fact]
    public void CreateProposal_NonexistentLinkedDraft_Throws()
    {
        var sessionId = CreateAndSaveSession();

        var ex = Assert.Throws<ProposalServiceException>(() =>
            _service.CreateProposal(sessionId, new CreateProposalRequest
            {
                ThreadId = 42,
                BranchName = "powerreview/fix/thread-42",
                Description = "Fix",
                ReplyDraftId = "nonexistent-draft-id",
            }));
        Assert.Contains("Linked reply draft not found", ex.Message);
    }

    [Fact]
    public void CreateProposal_NonexistentSession_Throws()
    {
        Assert.Throws<ProposalServiceException>(() =>
            _service.CreateProposal("nonexistent", new CreateProposalRequest
            {
                ThreadId = 42,
                BranchName = "branch",
                Description = "Fix",
            }));
    }

    [Fact]
    public void CreateProposal_EmptyThreadsList_SkipsValidation()
    {
        // When no threads are synced, skip thread validation
        var sessionId = CreateAndSaveSession(threads: []);

        var (_, proposal) = _service.CreateProposal(sessionId, new CreateProposalRequest
        {
            ThreadId = 999,
            BranchName = "powerreview/fix/thread-999",
            Description = "Fix before sync",
        });

        Assert.Equal(999, proposal.ThreadId);
    }

    [Fact]
    public void CreateProposal_MultipleProposals()
    {
        var sessionId = CreateAndSaveSession();

        _service.CreateProposal(sessionId, new CreateProposalRequest
        {
            ThreadId = 42,
            BranchName = "powerreview/fix/thread-42",
            Description = "Fix 1",
        });
        _service.CreateProposal(sessionId, new CreateProposalRequest
        {
            ThreadId = 55,
            BranchName = "powerreview/fix/thread-55",
            Description = "Fix 2",
        });

        var loaded = _store.Load(sessionId)!;
        Assert.Equal(2, loaded.Proposals.Count);
    }

    [Fact]
    public void CreateProposal_NullFilesChanged_DefaultsToEmptyList()
    {
        var sessionId = CreateAndSaveSession();

        var (_, proposal) = _service.CreateProposal(sessionId, new CreateProposalRequest
        {
            ThreadId = 42,
            BranchName = "powerreview/fix/thread-42",
            Description = "Fix",
            FilesChanged = null,
        });

        Assert.Empty(proposal.FilesChanged);
    }

    // --- ApproveProposal ---

    [Fact]
    public void ApproveProposal_TransitionsToApproved()
    {
        var sessionId = CreateAndSaveSession();
        var (proposalId, _) = _service.CreateProposal(sessionId, new CreateProposalRequest
        {
            ThreadId = 42,
            BranchName = "powerreview/fix/thread-42",
            Description = "Fix",
        });

        var approved = _service.ApproveProposal(sessionId, proposalId);

        Assert.Equal(ProposalStatus.Approved, approved.Status);
        Assert.True(approved.CanApply);
        Assert.False(approved.CanApprove);
        Assert.False(approved.CanEdit);

        // Verify persisted
        var loaded = _store.Load(sessionId)!;
        Assert.Equal(ProposalStatus.Approved, loaded.Proposals[proposalId].Status);
    }

    [Fact]
    public void ApproveProposal_AutoApprovesLinkedReplyDraft()
    {
        var sessionId = CreateAndSaveSession();

        // Create reply draft
        var (replyId, _) = _sessionService.CreateDraft(sessionId, new CreateDraftOperationRequest
        {
            ThreadId = 42,
            Body = "Fixed: null check added",
            Author = DraftAuthor.Ai,
        });

        // Create proposal linked to the reply
        var (proposalId, _) = _service.CreateProposal(sessionId, new CreateProposalRequest
        {
            ThreadId = 42,
            BranchName = "powerreview/fix/thread-42",
            Description = "Added null check",
            ReplyDraftId = replyId,
        });

        // Approve the proposal
        _service.ApproveProposal(sessionId, proposalId);

        // Verify the linked draft was auto-approved
        var loaded = _store.Load(sessionId)!;
        Assert.Equal(DraftStatus.Pending, loaded.DraftOperations[replyId].Status);
    }

    [Fact]
    public void ApproveProposal_AlreadyApproved_Throws()
    {
        var sessionId = CreateAndSaveSession();
        var (proposalId, _) = _service.CreateProposal(sessionId, new CreateProposalRequest
        {
            ThreadId = 42,
            BranchName = "powerreview/fix/thread-42",
            Description = "Fix",
        });
        _service.ApproveProposal(sessionId, proposalId);

        var ex = Assert.Throws<ProposalServiceException>(() =>
            _service.ApproveProposal(sessionId, proposalId));
        Assert.Contains("Approved", ex.Message);
    }

    [Fact]
    public void ApproveProposal_NonexistentProposal_Throws()
    {
        var sessionId = CreateAndSaveSession();

        Assert.Throws<ProposalServiceException>(() =>
            _service.ApproveProposal(sessionId, "nonexistent-id"));
    }

    // --- RejectProposal ---

    [Fact]
    public void RejectProposal_TransitionsToRejected()
    {
        var sessionId = CreateAndSaveSession();
        var (proposalId, _) = _service.CreateProposal(sessionId, new CreateProposalRequest
        {
            ThreadId = 42,
            BranchName = "powerreview/fix/thread-42",
            Description = "Fix",
        });

        var rejected = _service.RejectProposal(sessionId, proposalId);

        Assert.Equal(ProposalStatus.Rejected, rejected.Status);
        Assert.False(rejected.CanApprove);
        Assert.False(rejected.CanApply);
        Assert.False(rejected.CanEdit);

        // Verify persisted
        var loaded = _store.Load(sessionId)!;
        Assert.Equal(ProposalStatus.Rejected, loaded.Proposals[proposalId].Status);
    }

    [Fact]
    public void RejectProposal_AlreadyApproved_Throws()
    {
        var sessionId = CreateAndSaveSession();
        var (proposalId, _) = _service.CreateProposal(sessionId, new CreateProposalRequest
        {
            ThreadId = 42,
            BranchName = "powerreview/fix/thread-42",
            Description = "Fix",
        });
        _service.ApproveProposal(sessionId, proposalId);

        var ex = Assert.Throws<ProposalServiceException>(() =>
            _service.RejectProposal(sessionId, proposalId));
        Assert.Contains("Approved", ex.Message);
    }

    [Fact]
    public void RejectProposal_NonexistentProposal_Throws()
    {
        var sessionId = CreateAndSaveSession();

        Assert.Throws<ProposalServiceException>(() =>
            _service.RejectProposal(sessionId, "nonexistent-id"));
    }

    // --- DeleteProposal ---

    [Fact]
    public void DeleteProposal_DraftStatus_RemovesFromSession()
    {
        var sessionId = CreateAndSaveSession();
        var (proposalId, _) = _service.CreateProposal(sessionId, new CreateProposalRequest
        {
            ThreadId = 42,
            BranchName = "powerreview/fix/thread-42",
            Description = "Fix",
        });

        _service.DeleteProposal(sessionId, proposalId);

        var loaded = _store.Load(sessionId)!;
        Assert.Empty(loaded.Proposals);
    }

    [Fact]
    public void DeleteProposal_RejectedStatus_RemovesFromSession()
    {
        var sessionId = CreateAndSaveSession();
        var (proposalId, _) = _service.CreateProposal(sessionId, new CreateProposalRequest
        {
            ThreadId = 42,
            BranchName = "powerreview/fix/thread-42",
            Description = "Fix",
        });
        _service.RejectProposal(sessionId, proposalId);

        _service.DeleteProposal(sessionId, proposalId);

        var loaded = _store.Load(sessionId)!;
        Assert.Empty(loaded.Proposals);
    }

    [Fact]
    public void DeleteProposal_ApprovedStatus_Throws()
    {
        var sessionId = CreateAndSaveSession();
        var (proposalId, _) = _service.CreateProposal(sessionId, new CreateProposalRequest
        {
            ThreadId = 42,
            BranchName = "powerreview/fix/thread-42",
            Description = "Fix",
        });
        _service.ApproveProposal(sessionId, proposalId);

        var ex = Assert.Throws<ProposalServiceException>(() =>
            _service.DeleteProposal(sessionId, proposalId));
        Assert.Contains("Approved", ex.Message);
    }

    [Fact]
    public void DeleteProposal_NonexistentProposal_Throws()
    {
        var sessionId = CreateAndSaveSession();

        Assert.Throws<ProposalServiceException>(() =>
            _service.DeleteProposal(sessionId, "nonexistent-id"));
    }

    // --- DeleteProposal author guard ---

    [Fact]
    public void DeleteProposal_AiCallerCanDeleteOwnProposal()
    {
        var sessionId = CreateAndSaveSession();
        var (proposalId, _) = _service.CreateProposal(sessionId, new CreateProposalRequest
        {
            ThreadId = 42,
            BranchName = "powerreview/fix/thread-42",
            Description = "Fix",
            Author = DraftAuthor.Ai,
        });

        _service.DeleteProposal(sessionId, proposalId, callerAuthor: DraftAuthor.Ai);

        var loaded = _store.Load(sessionId)!;
        Assert.Empty(loaded.Proposals);
    }

    [Fact]
    public void DeleteProposal_AiCallerCannotDeleteUserProposal()
    {
        var sessionId = CreateAndSaveSession();
        var (proposalId, _) = _service.CreateProposal(sessionId, new CreateProposalRequest
        {
            ThreadId = 42,
            BranchName = "powerreview/fix/thread-42",
            Description = "Fix",
            Author = DraftAuthor.User,
        });

        var ex = Assert.Throws<ProposalServiceException>(() =>
            _service.DeleteProposal(sessionId, proposalId, callerAuthor: DraftAuthor.Ai));
        Assert.Contains("author mismatch", ex.Message);
    }

    [Fact]
    public void DeleteProposal_NoCallerAuthor_AllowsDeletingAny()
    {
        var sessionId = CreateAndSaveSession();
        var (proposalId, _) = _service.CreateProposal(sessionId, new CreateProposalRequest
        {
            ThreadId = 42,
            BranchName = "powerreview/fix/thread-42",
            Description = "Fix",
            Author = DraftAuthor.Ai,
        });

        // No callerAuthor = no guard
        _service.DeleteProposal(sessionId, proposalId);

        var loaded = _store.Load(sessionId)!;
        Assert.Empty(loaded.Proposals);
    }

    // --- GetProposal ---

    [Fact]
    public void GetProposal_ExistingProposal_ReturnsProposal()
    {
        var sessionId = CreateAndSaveSession();
        var (proposalId, _) = _service.CreateProposal(sessionId, new CreateProposalRequest
        {
            ThreadId = 42,
            BranchName = "powerreview/fix/thread-42",
            Description = "Fix",
        });

        var result = _service.GetProposal(sessionId, proposalId);

        Assert.NotNull(result);
        Assert.Equal(proposalId, result.Value.Id);
        Assert.Equal("Fix", result.Value.Proposal.Description);
    }

    [Fact]
    public void GetProposal_NonexistentProposal_ReturnsNull()
    {
        var sessionId = CreateAndSaveSession();
        var result = _service.GetProposal(sessionId, "fake-id");
        Assert.Null(result);
    }

    [Fact]
    public void GetProposal_NonexistentSession_ReturnsNull()
    {
        var result = _service.GetProposal("nonexistent", "fake-id");
        Assert.Null(result);
    }

    // --- GetProposals ---

    [Fact]
    public void GetProposals_ReturnsAllProposals()
    {
        var sessionId = CreateAndSaveSession();
        _service.CreateProposal(sessionId, new CreateProposalRequest
        {
            ThreadId = 42,
            BranchName = "powerreview/fix/thread-42",
            Description = "Fix 1",
        });
        _service.CreateProposal(sessionId, new CreateProposalRequest
        {
            ThreadId = 55,
            BranchName = "powerreview/fix/thread-55",
            Description = "Fix 2",
        });

        var proposals = _service.GetProposals(sessionId);

        Assert.Equal(2, proposals.Count);
    }

    [Fact]
    public void GetProposals_NonexistentSession_ReturnsEmpty()
    {
        var proposals = _service.GetProposals("nonexistent");
        Assert.Empty(proposals);
    }

    // --- GetProposalCounts ---

    [Fact]
    public void GetProposalCounts_ReturnsCorrectCounts()
    {
        var sessionId = CreateAndSaveSession();

        // Create 3 proposals in different states
        _service.CreateProposal(sessionId, new CreateProposalRequest
        {
            ThreadId = 42,
            BranchName = "powerreview/fix/thread-42",
            Description = "Draft fix",
        });

        var (approvedId, _) = _service.CreateProposal(sessionId, new CreateProposalRequest
        {
            ThreadId = 55,
            BranchName = "powerreview/fix/thread-55",
            Description = "Approved fix",
        });
        _service.ApproveProposal(sessionId, approvedId);

        var counts = _service.GetProposalCounts(sessionId);

        Assert.Equal(2, counts.Total);
        Assert.Equal(1, counts.Draft);
        Assert.Equal(1, counts.Approved);
        Assert.Equal(0, counts.Applied);
        Assert.Equal(0, counts.Rejected);
    }

    [Fact]
    public void GetProposalCounts_NonexistentSession_ReturnsZeros()
    {
        var counts = _service.GetProposalCounts("nonexistent");
        Assert.Equal(0, counts.Total);
    }

    // --- Computed properties ---

    [Fact]
    public void ProposedFix_ComputedProperties_Draft()
    {
        var proposal = new ProposedFix { Status = ProposalStatus.Draft, Author = DraftAuthor.Ai };
        Assert.True(proposal.CanEdit);
        Assert.True(proposal.CanApprove);
        Assert.False(proposal.CanApply);
        Assert.True(proposal.IsAiAuthored);
    }

    [Fact]
    public void ProposedFix_ComputedProperties_Approved()
    {
        var proposal = new ProposedFix { Status = ProposalStatus.Approved };
        Assert.False(proposal.CanEdit);
        Assert.False(proposal.CanApprove);
        Assert.True(proposal.CanApply);
    }

    [Fact]
    public void ProposedFix_ComputedProperties_Applied()
    {
        var proposal = new ProposedFix { Status = ProposalStatus.Applied };
        Assert.False(proposal.CanEdit);
        Assert.False(proposal.CanApprove);
        Assert.False(proposal.CanApply);
    }

    [Fact]
    public void ProposedFix_ComputedProperties_Rejected()
    {
        var proposal = new ProposedFix { Status = ProposalStatus.Rejected };
        Assert.False(proposal.CanEdit);
        Assert.False(proposal.CanApprove);
        Assert.False(proposal.CanApply);
    }

    // --- Full lifecycle ---

    [Fact]
    public void FullLifecycle_CreateApproveReject()
    {
        var sessionId = CreateAndSaveSession();

        // Create
        var (proposalId, proposal) = _service.CreateProposal(sessionId, new CreateProposalRequest
        {
            ThreadId = 42,
            BranchName = "powerreview/fix/thread-42",
            Description = "Fix null check",
            FilesChanged = ["src/main.cs"],
        });
        Assert.Equal(ProposalStatus.Draft, proposal.Status);

        // Approve
        var approved = _service.ApproveProposal(sessionId, proposalId);
        Assert.Equal(ProposalStatus.Approved, approved.Status);

        // Cannot approve again
        Assert.Throws<ProposalServiceException>(() =>
            _service.ApproveProposal(sessionId, proposalId));

        // Cannot reject when approved
        Assert.Throws<ProposalServiceException>(() =>
            _service.RejectProposal(sessionId, proposalId));

        // Cannot delete when approved
        Assert.Throws<ProposalServiceException>(() =>
            _service.DeleteProposal(sessionId, proposalId));
    }

    [Fact]
    public void FullLifecycle_CreateRejectDelete()
    {
        var sessionId = CreateAndSaveSession();

        // Create
        var (proposalId, _) = _service.CreateProposal(sessionId, new CreateProposalRequest
        {
            ThreadId = 42,
            BranchName = "powerreview/fix/thread-42",
            Description = "Fix",
        });

        // Reject
        var rejected = _service.RejectProposal(sessionId, proposalId);
        Assert.Equal(ProposalStatus.Rejected, rejected.Status);

        // Delete rejected proposal
        _service.DeleteProposal(sessionId, proposalId);
        Assert.Empty(_store.Load(sessionId)!.Proposals);
    }

    // --- ApproveAllProposals ---

    [Fact]
    public void ApproveAllProposals_ApprovesAllDraftProposals()
    {
        var sessionId = CreateAndSaveSession();
        _service.CreateProposal(sessionId, new CreateProposalRequest
        {
            ThreadId = 42, BranchName = "powerreview/fix/thread-42", Description = "Fix 1",
        });
        _service.CreateProposal(sessionId, new CreateProposalRequest
        {
            ThreadId = 55, BranchName = "powerreview/fix/thread-55", Description = "Fix 2",
        });

        var count = _service.ApproveAllProposals(sessionId);

        Assert.Equal(2, count);
        var loaded = _store.Load(sessionId)!;
        Assert.All(loaded.Proposals.Values, p => Assert.Equal(ProposalStatus.Approved, p.Status));
    }

    [Fact]
    public void ApproveAllProposals_SkipsNonDraftProposals()
    {
        var sessionId = CreateAndSaveSession();
        var (id1, _) = _service.CreateProposal(sessionId, new CreateProposalRequest
        {
            ThreadId = 42, BranchName = "powerreview/fix/thread-42", Description = "Fix 1",
        });
        _service.CreateProposal(sessionId, new CreateProposalRequest
        {
            ThreadId = 55, BranchName = "powerreview/fix/thread-55", Description = "Fix 2",
        });

        // Approve one first
        _service.ApproveProposal(sessionId, id1);

        var count = _service.ApproveAllProposals(sessionId);

        Assert.Equal(1, count); // Only the second was Draft
    }

    [Fact]
    public void ApproveAllProposals_NoProposals_ReturnsZero()
    {
        var sessionId = CreateAndSaveSession();

        var count = _service.ApproveAllProposals(sessionId);

        Assert.Equal(0, count);
    }

    [Fact]
    public void ApproveAllProposals_AutoApprovesLinkedReplyDrafts()
    {
        var sessionId = CreateAndSaveSession();

        // Create reply draft
        var (replyId, _) = _sessionService.CreateDraft(sessionId, new CreateDraftOperationRequest
        {
            ThreadId = 42, Body = "Fixed", Author = DraftAuthor.Ai,
        });

        // Create proposal linked to reply
        _service.CreateProposal(sessionId, new CreateProposalRequest
        {
            ThreadId = 42, BranchName = "powerreview/fix/thread-42",
            Description = "Fix", ReplyDraftId = replyId,
        });

        _service.ApproveAllProposals(sessionId);

        var loaded = _store.Load(sessionId)!;
        Assert.Equal(DraftStatus.Pending, loaded.DraftOperations[replyId].Status);
    }

    // --- RejectAllProposals ---

    [Fact]
    public void RejectAllProposals_RejectsAllDraftProposals()
    {
        var sessionId = CreateAndSaveSession();
        _service.CreateProposal(sessionId, new CreateProposalRequest
        {
            ThreadId = 42, BranchName = "powerreview/fix/thread-42", Description = "Fix 1",
        });
        _service.CreateProposal(sessionId, new CreateProposalRequest
        {
            ThreadId = 55, BranchName = "powerreview/fix/thread-55", Description = "Fix 2",
        });

        var count = _service.RejectAllProposals(sessionId);

        Assert.Equal(2, count);
        var loaded = _store.Load(sessionId)!;
        Assert.All(loaded.Proposals.Values, p => Assert.Equal(ProposalStatus.Rejected, p.Status));
    }

    [Fact]
    public void RejectAllProposals_SkipsApprovedProposals()
    {
        var sessionId = CreateAndSaveSession();
        var (id1, _) = _service.CreateProposal(sessionId, new CreateProposalRequest
        {
            ThreadId = 42, BranchName = "powerreview/fix/thread-42", Description = "Fix 1",
        });
        _service.CreateProposal(sessionId, new CreateProposalRequest
        {
            ThreadId = 55, BranchName = "powerreview/fix/thread-55", Description = "Fix 2",
        });
        _service.ApproveProposal(sessionId, id1);

        var count = _service.RejectAllProposals(sessionId);

        Assert.Equal(1, count);
        var loaded = _store.Load(sessionId)!;
        Assert.Equal(ProposalStatus.Approved, loaded.Proposals[id1].Status);
    }

    [Fact]
    public void RejectAllProposals_NoProposals_ReturnsZero()
    {
        var sessionId = CreateAndSaveSession();

        var count = _service.RejectAllProposals(sessionId);

        Assert.Equal(0, count);
    }
}
