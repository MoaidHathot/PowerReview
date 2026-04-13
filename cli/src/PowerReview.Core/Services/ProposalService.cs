using PowerReview.Core.Git;
using PowerReview.Core.Models;
using PowerReview.Core.Store;

namespace PowerReview.Core.Services;

/// <summary>
/// Manages proposed code fix operations within a review session.
/// All mutations acquire a file lock, load the session, mutate, save, and release.
/// </summary>
public sealed class ProposalService
{
    private readonly SessionStore _store;
    private readonly SessionService _sessionService;
    private readonly FixWorktreeService _fixWorktreeService;

    public ProposalService(SessionStore store, SessionService sessionService, FixWorktreeService fixWorktreeService)
    {
        _store = store;
        _sessionService = sessionService;
        _fixWorktreeService = fixWorktreeService;
    }

    /// <summary>
    /// Create a new proposed fix and add it to the session.
    /// The AI agent should have already committed its changes to the specified fix branch.
    /// </summary>
    /// <returns>The created proposal's ID and the proposal itself.</returns>
    public (string Id, ProposedFix Proposal) CreateProposal(string sessionId, CreateProposalRequest request)
    {
        using var lck = _store.AcquireLock(sessionId);

        var session = LoadOrThrow(sessionId);

        if (string.IsNullOrWhiteSpace(request.BranchName))
            throw new ProposalServiceException("Branch name is required.");

        if (string.IsNullOrWhiteSpace(request.Description))
            throw new ProposalServiceException("Description is required.");

        // Check that the thread exists (if threads are synced)
        if (session.Threads.Items.Count > 0)
        {
            var threadExists = session.Threads.Items.Any(t => t.Id == request.ThreadId);
            if (!threadExists)
                throw new ProposalServiceException(
                    $"Thread {request.ThreadId} not found in the session. Sync threads first.");
        }

        // Validate linked reply draft if specified
        if (request.ReplyDraftId != null)
        {
            if (!session.Drafts.ContainsKey(request.ReplyDraftId))
                throw new ProposalServiceException(
                    $"Linked reply draft not found: {request.ReplyDraftId}");
        }

        var now = Timestamp();
        var id = Guid.NewGuid().ToString("D");

        var proposal = new ProposedFix
        {
            ThreadId = request.ThreadId,
            Description = request.Description,
            Status = ProposalStatus.Draft,
            Author = request.Author ?? DraftAuthor.Ai,
            AuthorName = request.AuthorName,
            BranchName = request.BranchName,
            FilesChanged = request.FilesChanged ?? [],
            ReplyDraftId = request.ReplyDraftId,
            CreatedAt = now,
            UpdatedAt = now,
        };

        session.Proposals[id] = proposal;
        _store.Save(session);

        return (id, proposal);
    }

    /// <summary>
    /// Approve a proposal, transitioning it from Draft to Approved.
    /// If a linked reply draft exists, it is auto-approved (Draft -> Pending).
    /// User-only operation.
    /// </summary>
    public ProposedFix ApproveProposal(string sessionId, string proposalId)
    {
        using var lck = _store.AcquireLock(sessionId);

        var session = LoadOrThrow(sessionId);

        if (!session.Proposals.TryGetValue(proposalId, out var proposal))
            throw new ProposalServiceException($"Proposal not found: {proposalId}");

        if (!proposal.CanApprove)
            throw new ProposalServiceException(
                $"Cannot approve proposal {proposalId}: status is '{proposal.Status}' (expected 'Draft')");

        proposal.Status = ProposalStatus.Approved;
        proposal.UpdatedAt = Timestamp();

        // Auto-approve linked reply draft
        if (proposal.ReplyDraftId != null
            && session.Drafts.TryGetValue(proposal.ReplyDraftId, out var linkedDraft)
            && linkedDraft.Status == DraftStatus.Draft)
        {
            linkedDraft.Status = DraftStatus.Pending;
            linkedDraft.UpdatedAt = Timestamp();
        }

        _store.Save(session);
        return proposal;
    }

    /// <summary>
    /// Reject a proposal, transitioning it from Draft to Rejected.
    /// User-only operation.
    /// </summary>
    public ProposedFix RejectProposal(string sessionId, string proposalId)
    {
        using var lck = _store.AcquireLock(sessionId);

        var session = LoadOrThrow(sessionId);

        if (!session.Proposals.TryGetValue(proposalId, out var proposal))
            throw new ProposalServiceException($"Proposal not found: {proposalId}");

        if (proposal.Status != ProposalStatus.Draft)
            throw new ProposalServiceException(
                $"Cannot reject proposal {proposalId}: status is '{proposal.Status}' (expected 'Draft')");

        proposal.Status = ProposalStatus.Rejected;
        proposal.UpdatedAt = Timestamp();
        _store.Save(session);

        return proposal;
    }

    /// <summary>
    /// Apply an approved proposal by cherry-picking the fix branch commits
    /// into the PR source branch, optionally pushing to remote.
    /// Transitions the proposal from Approved to Applied.
    /// User-only operation.
    /// </summary>
    public async Task<ProposedFix> ApplyProposalAsync(
        string sessionId, string proposalId, bool push = false, CancellationToken ct = default)
    {
        ProposedFix proposal;

        // First, read and validate (without holding the lock during git operations)
        {
            var session = LoadOrThrow(sessionId);

            if (!session.Proposals.TryGetValue(proposalId, out proposal!))
                throw new ProposalServiceException($"Proposal not found: {proposalId}");

            if (!proposal.CanApply)
                throw new ProposalServiceException(
                    $"Cannot apply proposal {proposalId}: status is '{proposal.Status}' (expected 'Approved')");
        }

        // We need the fix worktree to perform the merge
        var session2 = LoadOrThrow(sessionId);
        var worktreePath = session2.FixWorktree?.Path
            ?? throw new ProposalServiceException("No fix worktree exists. Cannot apply proposal.");

        if (!Directory.Exists(worktreePath))
            throw new ProposalServiceException(
                $"Fix worktree directory does not exist: {worktreePath}");

        var repoPath = session2.Git.RepoPath
            ?? throw new ProposalServiceException("No git repository path available.");

        var sourceBranch = session2.PullRequest.SourceBranch;

        // Perform the cherry-pick in the fix worktree
        // 1. Checkout the source branch in the worktree
        await GitOperations.RunAsync(
            ["checkout", sourceBranch],
            worktreePath, ct: ct);

        // 2. Try to pull latest from remote to avoid conflicts
        await GitOperations.TryRunAsync(
            ["pull", "origin", sourceBranch, "--ff-only"],
            worktreePath, ct: ct);

        // 3. Cherry-pick the fix branch's commits
        var branchName = proposal.BranchName;

        // Get the merge base to know which commits to cherry-pick
        var (mbSuccess, mergeBase, _) = await GitOperations.TryRunAsync(
            ["merge-base", sourceBranch, branchName],
            repoPath, ct: ct);

        if (mbSuccess && !string.IsNullOrWhiteSpace(mergeBase))
        {
            // Cherry-pick all commits from the fix branch that are not in source
            var (cpSuccess, _, cpStderr) = await GitOperations.TryRunAsync(
                ["cherry-pick", $"{mergeBase.Trim()}..{branchName}"],
                worktreePath, ct: ct);

            if (!cpSuccess)
                throw new ProposalServiceException(
                    $"Cherry-pick failed. You may need to resolve conflicts manually: {cpStderr}");
        }
        else
        {
            // Fallback: merge the fix branch
            var (mrgSuccess, _, mrgStderr) = await GitOperations.TryRunAsync(
                ["merge", branchName, "--no-edit"],
                worktreePath, ct: ct);

            if (!mrgSuccess)
                throw new ProposalServiceException(
                    $"Merge failed. You may need to resolve conflicts manually: {mrgStderr}");
        }

        // 4. Optionally push
        if (push)
        {
            var (pushSuccess, _, pushStderr) = await GitOperations.TryRunAsync(
                ["push", "origin", sourceBranch],
                worktreePath, ct: ct);

            if (!pushSuccess)
                throw new ProposalServiceException($"Push failed: {pushStderr}");
        }

        // 5. Clean up the fix branch
        await GitOperations.TryRunAsync(
            ["branch", "-D", branchName],
            repoPath, ct: ct);

        // 6. Update proposal status
        using var lck = _store.AcquireLock(sessionId);
        var finalSession = _store.Load(sessionId)
            ?? throw new ProposalServiceException($"Session disappeared during apply: {sessionId}");

        if (finalSession.Proposals.TryGetValue(proposalId, out var finalProposal))
        {
            finalProposal.Status = ProposalStatus.Applied;
            finalProposal.UpdatedAt = Timestamp();
        }

        _store.Save(finalSession);
        return finalProposal ?? proposal;
    }

    /// <summary>
    /// Delete a proposal from the session.
    /// Only Draft or Rejected proposals can be deleted.
    /// When callerAuthor is specified, enforces author matching.
    /// </summary>
    public void DeleteProposal(string sessionId, string proposalId, DraftAuthor? callerAuthor = null)
    {
        using var lck = _store.AcquireLock(sessionId);

        var session = LoadOrThrow(sessionId);

        if (!session.Proposals.TryGetValue(proposalId, out var proposal))
            throw new ProposalServiceException($"Proposal not found: {proposalId}");

        // Author guard
        if (callerAuthor.HasValue && proposal.Author != callerAuthor.Value)
            throw new ProposalServiceException(
                $"Cannot delete proposal {proposalId}: author mismatch (proposal author: '{proposal.Author}', caller: '{callerAuthor.Value}')");

        if (proposal.Status != ProposalStatus.Draft && proposal.Status != ProposalStatus.Rejected)
            throw new ProposalServiceException(
                $"Cannot delete proposal {proposalId}: status is '{proposal.Status}' (only 'Draft' or 'Rejected' proposals can be deleted)");

        session.Proposals.Remove(proposalId);
        _store.Save(session);
    }

    /// <summary>
    /// Get a specific proposal by ID.
    /// </summary>
    public (string Id, ProposedFix Proposal)? GetProposal(string sessionId, string proposalId)
    {
        var session = _store.Load(sessionId);
        if (session == null)
            return null;

        return session.Proposals.TryGetValue(proposalId, out var proposal)
            ? (proposalId, proposal)
            : null;
    }

    /// <summary>
    /// Get all proposals in the session.
    /// </summary>
    public Dictionary<string, ProposedFix> GetProposals(string sessionId)
    {
        var session = _store.Load(sessionId);
        return session?.Proposals ?? new Dictionary<string, ProposedFix>();
    }

    /// <summary>
    /// Get the diff for a specific proposal (between the fix branch and the PR source branch).
    /// </summary>
    public async Task<string> GetProposalDiffAsync(string sessionId, string proposalId, CancellationToken ct = default)
    {
        var session = LoadOrThrow(sessionId);

        if (!session.Proposals.TryGetValue(proposalId, out var proposal))
            throw new ProposalServiceException($"Proposal not found: {proposalId}");

        return await _fixWorktreeService.GetFixBranchDiffAsync(
            sessionId, proposal.BranchName, ct);
    }

    /// <summary>
    /// Get counts of proposals by status.
    /// </summary>
    public ProposalCounts GetProposalCounts(string sessionId)
    {
        var session = _store.Load(sessionId);
        if (session == null)
            return new ProposalCounts();

        var counts = new ProposalCounts();
        foreach (var proposal in session.Proposals.Values)
        {
            counts.Total++;
            switch (proposal.Status)
            {
                case ProposalStatus.Draft:
                    counts.Draft++;
                    break;
                case ProposalStatus.Approved:
                    counts.Approved++;
                    break;
                case ProposalStatus.Applied:
                    counts.Applied++;
                    break;
                case ProposalStatus.Rejected:
                    counts.Rejected++;
                    break;
            }
        }
        return counts;
    }

    private ReviewSession LoadOrThrow(string sessionId)
    {
        return _store.Load(sessionId)
            ?? throw new ProposalServiceException($"Session not found: {sessionId}");
    }

    private static string Timestamp() => DateTime.UtcNow.ToString("o");
}

/// <summary>
/// Request to create a new proposed fix.
/// </summary>
public sealed class CreateProposalRequest
{
    public int ThreadId { get; set; }
    public string Description { get; set; } = "";
    public string BranchName { get; set; } = "";
    public List<string>? FilesChanged { get; set; }
    public DraftAuthor? Author { get; set; }
    public string? AuthorName { get; set; }
    public string? ReplyDraftId { get; set; }
}

/// <summary>
/// Proposal count summary by status.
/// </summary>
public sealed class ProposalCounts
{
    public int Draft { get; set; }
    public int Approved { get; set; }
    public int Applied { get; set; }
    public int Rejected { get; set; }
    public int Total { get; set; }
}

/// <summary>
/// Exception thrown by ProposalService for business logic errors.
/// </summary>
public sealed class ProposalServiceException : Exception
{
    public ProposalServiceException(string message) : base(message) { }
    public ProposalServiceException(string message, Exception inner) : base(message, inner) { }
}
