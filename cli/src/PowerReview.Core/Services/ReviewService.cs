using PowerReview.Core.Auth;
using PowerReview.Core.Configuration;
using PowerReview.Core.Git;
using PowerReview.Core.Models;
using PowerReview.Core.Providers;
using PowerReview.Core.Store;

namespace PowerReview.Core.Services;

/// <summary>
/// Orchestrates the review lifecycle: open, submit, sync, vote, close, refresh.
/// This is the top-level service that coordinates providers, git, auth, and session persistence.
/// </summary>
public sealed class ReviewService
{
    private readonly SessionStore _store;
    private readonly SessionService _sessionService;
    private readonly PowerReviewConfig _config;
    private readonly AuthResolver _authResolver;

    public ReviewService(
        SessionStore store,
        SessionService sessionService,
        PowerReviewConfig config,
        AuthResolver authResolver)
    {
        _store = store;
        _sessionService = sessionService;
        _config = config;
        _authResolver = authResolver;
    }

    /// <summary>
    /// Open a review for a pull request. Fetches PR metadata, files, threads,
    /// sets up git worktree/checkout, and creates or resumes a session.
    /// </summary>
    /// <param name="prUrl">The pull request URL.</param>
    /// <param name="repoPath">Optional path to an existing local repo (required for "cwd" strategy).</param>
    /// <param name="ct">Cancellation token.</param>
    /// <returns>The opened (or resumed) review session.</returns>
    public async Task<ReviewSession> OpenAsync(string prUrl, string? repoPath = null, CancellationToken ct = default)
    {
        // Step 1: Parse the URL
        var parsed = UrlParser.Parse(prUrl)
            ?? throw new ReviewServiceException($"Could not parse PR URL: {prUrl}");

        // Step 2: Authenticate
        var authHeader = await _authResolver.GetAuthHeaderAsync(parsed.ProviderType, ct);

        // Step 3: Create provider
        var provider = ProviderFactory.Create(
            parsed.ProviderType,
            parsed.Organization,
            parsed.Project,
            parsed.Repository,
            authHeader,
            _config.Providers.AzDo.ApiVersion);

        // Step 4: Fetch PR metadata
        var pr = await provider.GetPullRequestAsync(parsed.PrId, ct);

        // Step 5: Fetch changed files
        var (files, iteration) = await provider.GetChangedFilesAsync(parsed.PrId, ct);

        // Step 6: Fetch threads (non-critical)
        List<CommentThread> threads;
        try
        {
            threads = await provider.GetThreadsAsync(parsed.PrId, ct);
        }
        catch
        {
            threads = [];
        }

        // Step 7: Compute session ID and check for existing session
        var sessionId = ReviewSession.ComputeId(
            parsed.ProviderType,
            parsed.Organization,
            parsed.Project,
            parsed.Repository,
            parsed.PrId);

        var existing = _store.Load(sessionId);

        // Step 8: Git setup
        string? resolvedRepoPath = repoPath;
        string? worktreePath = null;
        var strategy = _config.Git.Strategy;

        if (resolvedRepoPath != null)
        {
            // Verify it's a git repo
            if (!await GitOperations.IsGitRepoAsync(resolvedRepoPath, ct))
                throw new ReviewServiceException($"Path is not a git repository: {resolvedRepoPath}");

            resolvedRepoPath = await GitOperations.GetRepoRootAsync(resolvedRepoPath, ct);
        }

        if (strategy != GitStrategy.Cwd || resolvedRepoPath != null)
        {
            var gitResult = await SetupGitAsync(pr, parsed, resolvedRepoPath, strategy, ct);
            resolvedRepoPath = gitResult.RepoPath;
            worktreePath = gitResult.WorktreePath;
        }

        // Step 9: Build the session
        var now = Timestamp();
        var session = new ReviewSession
        {
            Id = sessionId,
            Version = ReviewSession.CurrentVersion,
            Provider = new ProviderInfo
            {
                Type = parsed.ProviderType,
                Organization = parsed.Organization,
                Project = parsed.Project,
                Repository = parsed.Repository,
            },
            PullRequest = new PullRequestInfo
            {
                Id = pr.Id,
                Url = prUrl,
                Title = pr.Title,
                Description = pr.Description,
                Author = pr.Author,
                SourceBranch = pr.SourceBranch,
                TargetBranch = pr.TargetBranch,
                Status = pr.Status,
                IsDraft = pr.IsDraft,
                MergeStatus = pr.MergeStatus,
                CreatedAt = pr.CreatedAt,
                ClosedAt = pr.ClosedAt,
                Reviewers = pr.Reviewers,
                Labels = pr.Labels,
                WorkItems = pr.WorkItems,
            },
            Iteration = iteration,
            Git = new GitInfo
            {
                RepoPath = resolvedRepoPath,
                WorktreePath = worktreePath,
                Strategy = strategy,
            },
            Files = files,
            Threads = new ThreadsInfo
            {
                SyncedAt = now,
                Items = threads,
            },
            CreatedAt = existing?.CreatedAt ?? now,
            UpdatedAt = now,
        };

        // Step 10: Preserve drafts from existing session
        if (existing?.Drafts.Count > 0)
        {
            session.Drafts = existing.Drafts;
        }

        // Preserve vote from existing session
        if (existing?.Vote != null)
        {
            session.Vote = existing.Vote;
        }

        // Step 11: Save session
        _store.Save(session);

        return session;
    }

    /// <summary>
    /// Submit all pending draft comments to the remote provider.
    /// </summary>
    public async Task<SubmitResult> SubmitAsync(string prUrl, CancellationToken ct = default)
    {
        var (session, provider) = await ResolveSessionAndProviderAsync(prUrl, ct);

        // Get all pending drafts
        var pendingDrafts = session.Drafts
            .Where(kvp => kvp.Value.Status == DraftStatus.Pending)
            .ToList();

        var result = new SubmitResult
        {
            Total = pendingDrafts.Count,
        };

        if (pendingDrafts.Count == 0)
            return result;

        // Submit each draft (sequentially to avoid race conditions on thread creation)
        foreach (var (draftId, draft) in pendingDrafts)
        {
            try
            {
                if (draft.IsReply && draft.ThreadId.HasValue)
                {
                    // Reply to existing thread
                    await provider.ReplyToThreadAsync(
                        session.PullRequest.Id,
                        draft.ThreadId.Value,
                        draft.Body,
                        ct);
                }
                else
                {
                    // Create new thread
                    await provider.CreateThreadAsync(
                        session.PullRequest.Id,
                        new CreateThreadRequest
                        {
                            FilePath = draft.FilePath,
                            LineStart = draft.LineStart,
                            LineEnd = draft.LineEnd,
                            ColStart = draft.ColStart,
                            ColEnd = draft.ColEnd,
                            Body = draft.Body,
                            Status = ThreadStatus.Active,
                        },
                        ct);
                }

                // Mark as submitted
                _sessionService.MarkSubmitted(session.Id, draftId);
                result.Submitted++;
            }
            catch (Exception ex)
            {
                result.Failed++;
                result.Errors.Add(new SubmitError
                {
                    DraftId = draftId,
                    FilePath = draft.FilePath,
                    Error = ex.Message,
                });
            }
        }

        return result;
    }

    /// <summary>
    /// Sync threads from the remote provider, updating the session.
    /// </summary>
    public async Task<int> SyncAsync(string prUrl, CancellationToken ct = default)
    {
        var (session, provider) = await ResolveSessionAndProviderAsync(prUrl, ct);

        var threads = await provider.GetThreadsAsync(session.PullRequest.Id, ct);

        using var _ = _store.AcquireLock(session.Id);
        // Reload to avoid stale data
        session = _store.Load(session.Id)
            ?? throw new ReviewServiceException($"Session disappeared during sync: {session.Id}");

        session.Threads = new ThreadsInfo
        {
            SyncedAt = Timestamp(),
            Items = threads,
        };
        _store.Save(session);

        return threads.Count;
    }

    /// <summary>
    /// Set the review vote for the current user.
    /// </summary>
    public async Task VoteAsync(string prUrl, VoteValue vote, CancellationToken ct = default)
    {
        var (session, provider) = await ResolveSessionAndProviderAsync(prUrl, ct);

        // Get reviewer ID
        var reviewerId = await provider.GetCurrentReviewerIdAsync(ct);

        // Set vote
        await provider.SetVoteAsync(session.PullRequest.Id, reviewerId, (int)vote, ct);

        // Persist vote in session
        using var _ = _store.AcquireLock(session.Id);
        session = _store.Load(session.Id)
            ?? throw new ReviewServiceException($"Session disappeared during vote: {session.Id}");

        session.Vote = vote;
        _store.Save(session);
    }

    /// <summary>
    /// Close a review session. Optionally cleans up git worktree.
    /// The session file is preserved on disk for future resume.
    /// </summary>
    public async Task CloseAsync(string prUrl, CancellationToken ct = default)
    {
        var parsed = UrlParser.Parse(prUrl)
            ?? throw new ReviewServiceException($"Could not parse PR URL: {prUrl}");

        var sessionId = ReviewSession.ComputeId(
            parsed.ProviderType,
            parsed.Organization,
            parsed.Project,
            parsed.Repository,
            parsed.PrId);

        var session = _store.Load(sessionId);
        if (session == null)
            return; // Nothing to close

        // Git cleanup (conditional)
        if (_config.Git.CleanupOnClose && session.Git.WorktreePath != null && session.Git.Strategy == GitStrategy.Worktree)
        {
            var repoRoot = session.Git.RepoPath ?? ".";
            var worktreeManager = new WorktreeManager(repoRoot, _config.Git.WorktreeDir);
            try
            {
                await worktreeManager.RemoveAsync(session.Git.WorktreePath, ct);
            }
            catch
            {
                // Worktree cleanup is best-effort
            }

            // Clear worktree path from session
            using var _ = _store.AcquireLock(sessionId);
            session = _store.Load(sessionId);
            if (session != null)
            {
                session.Git.WorktreePath = null;
                _store.Save(session);
            }
        }
        // Session file is preserved on disk — not deleted
    }

    /// <summary>
    /// Refresh a session by re-fetching PR metadata, files, and threads from the remote.
    /// </summary>
    public async Task<ReviewSession> RefreshAsync(string prUrl, CancellationToken ct = default)
    {
        var (session, provider) = await ResolveSessionAndProviderAsync(prUrl, ct);

        // Refresh PR metadata (non-critical)
        try
        {
            var pr = await provider.GetPullRequestAsync(session.PullRequest.Id, ct);
            session.PullRequest.Title = pr.Title;
            session.PullRequest.Description = pr.Description;
            session.PullRequest.Status = pr.Status;
            session.PullRequest.IsDraft = pr.IsDraft;
            session.PullRequest.MergeStatus = pr.MergeStatus;
            session.PullRequest.ClosedAt = pr.ClosedAt;
            session.PullRequest.Reviewers = pr.Reviewers;
            session.PullRequest.Labels = pr.Labels;
            session.PullRequest.WorkItems = pr.WorkItems;
        }
        catch
        {
            // PR metadata refresh is non-critical
        }

        // Refresh changed files (critical)
        var (files, iteration) = await provider.GetChangedFilesAsync(session.PullRequest.Id, ct);
        session.Files = files;
        session.Iteration = iteration;

        // Refresh threads (non-critical)
        try
        {
            var threads = await provider.GetThreadsAsync(session.PullRequest.Id, ct);
            session.Threads = new ThreadsInfo
            {
                SyncedAt = Timestamp(),
                Items = threads,
            };
        }
        catch
        {
            // Thread refresh is non-critical
        }

        _store.Save(session);
        return session;
    }

    /// <summary>
    /// Get session info for a PR URL. Returns the session if it exists, null otherwise.
    /// Supports --if-modified-since and --path-only semantics via return value.
    /// </summary>
    public SessionQueryResult? GetSession(string prUrl, string? ifModifiedSince = null)
    {
        var parsed = UrlParser.Parse(prUrl)
            ?? throw new ReviewServiceException($"Could not parse PR URL: {prUrl}");

        var sessionId = ReviewSession.ComputeId(
            parsed.ProviderType,
            parsed.Organization,
            parsed.Project,
            parsed.Repository,
            parsed.PrId);

        var path = _store.GetSessionPath(sessionId);
        var session = _store.Load(sessionId);

        if (session == null)
            return null;

        // Check if-modified-since
        if (ifModifiedSince != null)
        {
            if (string.Compare(session.UpdatedAt, ifModifiedSince, StringComparison.Ordinal) <= 0)
                return null; // Not modified
        }

        return new SessionQueryResult
        {
            Session = session,
            Path = path,
        };
    }

    /// <summary>
    /// Get session files list for a PR URL.
    /// </summary>
    public List<ChangedFile>? GetFiles(string prUrl)
    {
        var result = GetSession(prUrl);
        return result?.Session.Files;
    }

    /// <summary>
    /// Get diff info for a specific file in a PR session.
    /// Returns the file's changed file entry. Actual diff content generation
    /// depends on having a local git checkout.
    /// </summary>
    public ChangedFile? GetFileDiff(string prUrl, string filePath)
    {
        var result = GetSession(prUrl);
        if (result == null) return null;

        var normalized = filePath.Replace('\\', '/');
        return result.Session.Files
            .FirstOrDefault(f => f.Path.Replace('\\', '/').Equals(normalized, StringComparison.OrdinalIgnoreCase));
    }

    /// <summary>
    /// Get threads for a PR session, optionally filtered by file.
    /// </summary>
    public List<CommentThread>? GetThreads(string prUrl, string? filePath = null)
    {
        var result = GetSession(prUrl);
        if (result == null) return null;

        var threads = result.Session.Threads.Items;

        if (filePath != null)
        {
            var normalized = filePath.Replace('\\', '/');
            threads = threads
                .Where(t => t.FilePath != null &&
                    t.FilePath.Replace('\\', '/').Equals(normalized, StringComparison.OrdinalIgnoreCase))
                .ToList();
        }

        return threads;
    }

    // --- Private helpers ---

    /// <summary>
    /// Resolve a PR URL to its session and an authenticated provider.
    /// Used by operations that need both.
    /// </summary>
    private async Task<(ReviewSession Session, IProvider Provider)> ResolveSessionAndProviderAsync(
        string prUrl, CancellationToken ct)
    {
        var parsed = UrlParser.Parse(prUrl)
            ?? throw new ReviewServiceException($"Could not parse PR URL: {prUrl}");

        var sessionId = ReviewSession.ComputeId(
            parsed.ProviderType,
            parsed.Organization,
            parsed.Project,
            parsed.Repository,
            parsed.PrId);

        var session = _store.Load(sessionId)
            ?? throw new ReviewServiceException(
                $"No session found for PR {prUrl}. Run 'powerreview open --pr-url {prUrl}' first.");

        // Authenticate
        var authHeader = await _authResolver.GetAuthHeaderAsync(parsed.ProviderType, ct);

        var provider = ProviderFactory.Create(
            parsed.ProviderType,
            parsed.Organization,
            parsed.Project,
            parsed.Repository,
            authHeader,
            _config.Providers.AzDo.ApiVersion);

        return (session, provider);
    }

    /// <summary>
    /// Set up the git working directory for the review.
    /// </summary>
    private async Task<GitSetupResult> SetupGitAsync(
        PullRequest pr,
        ParsedUrl parsed,
        string? repoPath,
        GitStrategy strategy,
        CancellationToken ct)
    {
        string? resolvedRepoPath = repoPath;
        string? worktreePath = null;

        if (strategy == GitStrategy.Cwd)
        {
            if (resolvedRepoPath == null)
                throw new ReviewServiceException(
                    "Git strategy is 'cwd' but no --repo-path was provided. " +
                    "Provide --repo-path or change git.strategy in config.");
            // For cwd strategy, just verify the repo exists — no worktree or checkout
            return new GitSetupResult { RepoPath = resolvedRepoPath, WorktreePath = null };
        }

        // We need a repo to work with
        if (resolvedRepoPath == null)
            throw new ReviewServiceException(
                "No repository path available. Provide --repo-path to specify where the repo is.");

        var branchManager = new BranchManager(resolvedRepoPath);

        // Fetch the source branch (non-fatal)
        await branchManager.FetchAsync(pr.SourceBranch, "origin", ct);

        if (strategy == GitStrategy.Worktree)
        {
            var worktreeManager = new WorktreeManager(resolvedRepoPath, _config.Git.WorktreeDir);
            var result = await worktreeManager.CreateAsync(pr.SourceBranch, parsed.PrId, ct);
            worktreePath = result.ReusedMain ? null : result.WorktreePath;

            if (result.ReusedMain)
            {
                // Already on the right branch in the main repo
                resolvedRepoPath = result.WorktreePath;
            }
        }
        else if (strategy == GitStrategy.Clone)
        {
            // Clone strategy: stash, checkout
            await branchManager.StashAsync(ct);
            try
            {
                await branchManager.CheckoutAsync(pr.SourceBranch, ct);
            }
            catch
            {
                // If checkout fails, try to pop stash to restore
                try { await branchManager.StashPopAsync(ct); } catch { /* best effort */ }
                throw;
            }
        }

        return new GitSetupResult { RepoPath = resolvedRepoPath, WorktreePath = worktreePath };
    }

    private sealed class GitSetupResult
    {
        public string? RepoPath { get; set; }
        public string? WorktreePath { get; set; }
    }

    private static string Timestamp() => DateTime.UtcNow.ToString("o");
}

/// <summary>
/// Result of querying for a session.
/// </summary>
public sealed class SessionQueryResult
{
    /// <summary>The review session.</summary>
    public ReviewSession Session { get; set; } = null!;

    /// <summary>Full filesystem path to the session JSON file.</summary>
    public string Path { get; set; } = "";
}

/// <summary>
/// Exception thrown by ReviewService for business logic errors.
/// </summary>
public sealed class ReviewServiceException : Exception
{
    public ReviewServiceException(string message) : base(message) { }
    public ReviewServiceException(string message, Exception inner) : base(message, inner) { }
}
