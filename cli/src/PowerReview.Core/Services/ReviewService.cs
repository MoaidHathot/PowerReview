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
    private readonly FixWorktreeService? _fixWorktreeService;

    public ReviewService(
        SessionStore store,
        SessionService sessionService,
        PowerReviewConfig config,
        AuthResolver authResolver,
        FixWorktreeService? fixWorktreeService = null)
    {
        _store = store;
        _sessionService = sessionService;
        _config = config;
        _authResolver = authResolver;
        _fixWorktreeService = fixWorktreeService;
    }

    /// <summary>
    /// Open a review for a pull request. Fetches PR metadata, files, threads,
    /// sets up git worktree/checkout, and creates or resumes a session.
    /// </summary>
    /// <param name="prUrl">The pull request URL.</param>
    /// <param name="repoPath">Optional path to an existing local repo (required for "cwd" strategy).</param>
    /// <param name="autoClone">If true, clone the repo automatically when the repo path doesn't exist.</param>
    /// <param name="ct">Cancellation token.</param>
    /// <returns>The opened (or resumed) review session.</returns>
    public async Task<ReviewSession> OpenAsync(string prUrl, string? repoPath = null, bool autoClone = false, CancellationToken ct = default)
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
        string? resolvedRepoPath = repoPath ?? _config.Git.RepoBasePath;
        string? worktreePath = null;
        var strategy = _config.Git.Strategy;
        bool shouldAutoClone = autoClone || _config.Git.AutoClone;

        if (resolvedRepoPath != null)
        {
            bool isGitRepo = Directory.Exists(resolvedRepoPath)
                && await GitOperations.IsGitRepoAsync(resolvedRepoPath, ct);

            if (!isGitRepo)
            {
                if (shouldAutoClone)
                {
                    // Auto-clone the repo to the configured path
                    var cloneUrl = UrlParser.BuildCloneUrl(parsed);
                    resolvedRepoPath = await GitOperations.CloneAsync(cloneUrl, resolvedRepoPath, ct: ct);
                }
                else
                {
                    // Path is not a git repo — fall back to API-only review
                    resolvedRepoPath = null;
                }
            }
            else
            {
                resolvedRepoPath = await GitOperations.GetRepoRootAsync(resolvedRepoPath, ct);
            }
        }

        if (resolvedRepoPath != null && (strategy != GitStrategy.Cwd || resolvedRepoPath != null))
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

        // Preserve review state from existing session
        if (existing?.Review != null)
        {
            session.Review = existing.Review;
        }

        // Preserve proposals and fix worktree from existing session
        if (existing?.Proposals?.Count > 0)
        {
            session.Proposals = existing.Proposals;
        }
        if (existing?.FixWorktree != null)
        {
            session.FixWorktree = existing.FixWorktree;
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
    /// Also checks for new iterations and applies smart reset if detected.
    /// </summary>
    public async Task<SyncResult> SyncAsync(string prUrl, CancellationToken ct = default)
    {
        var (session, provider) = await ResolveSessionAndProviderAsync(prUrl, ct);

        var threads = await provider.GetThreadsAsync(session.PullRequest.Id, ct);

        // Check for new iteration (non-critical)
        IterationCheckResult? iterationCheck = null;
        try
        {
            var (files, latestIteration) = await provider.GetChangedFilesAsync(session.PullRequest.Id, ct);

            if (latestIteration.Id != null && latestIteration.Id != session.Iteration.Id)
            {
                iterationCheck = new IterationCheckResult
                {
                    OldIterationId = session.Review.ReviewedIterationId ?? session.Iteration.Id,
                    NewIterationId = latestIteration.Id,
                    HasNewIteration = true,
                };

                using var syncLock = _store.AcquireLock(session.Id);
                session = _store.Load(session.Id)
                    ?? throw new ReviewServiceException($"Session disappeared during sync: {session.Id}");

                var oldSourceCommit = session.Review.ReviewedSourceCommit ?? session.Iteration.SourceCommit;

                session.Files = files;
                session.Iteration = latestIteration;

                if (session.Review.ReviewedIterationId != null)
                {
                    await ApplySmartResetAsync(session, oldSourceCommit, latestIteration.SourceCommit);
                }

                session.Threads = new ThreadsInfo
                {
                    SyncedAt = Timestamp(),
                    Items = threads,
                };
                _store.Save(session);

                iterationCheck.ChangedFiles = session.Review.ChangedSinceReview.ToList();
                iterationCheck.Review = session.Review;

                return new SyncResult
                {
                    ThreadCount = threads.Count,
                    IterationCheck = iterationCheck,
                };
            }
        }
        catch
        {
            // Iteration check during sync is non-critical
        }

        // No new iteration — just update threads
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

        return new SyncResult
        {
            ThreadCount = threads.Count,
            IterationCheck = iterationCheck,
        };
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
    /// Update the status of a comment thread on the remote provider.
    /// Also updates the local session cache.
    /// </summary>
    public async Task<CommentThread> UpdateThreadStatusAsync(string prUrl, int threadId, ThreadStatus status, CancellationToken ct = default)
    {
        var (session, provider) = await ResolveSessionAndProviderAsync(prUrl, ct);

        var updatedThread = await provider.UpdateThreadStatusAsync(session.PullRequest.Id, threadId, status, ct);

        // Update local session cache
        using var _ = _store.AcquireLock(session.Id);
        session = _store.Load(session.Id)
            ?? throw new ReviewServiceException($"Session disappeared during thread status update: {session.Id}");

        var existing = session.Threads.Items.FirstOrDefault(t => t.Id == threadId);
        if (existing != null)
        {
            existing.Status = status;
        }
        session.UpdatedAt = Timestamp();
        _store.Save(session);

        return updatedThread;
    }

    /// <summary>
    /// Update a published comment on the remote provider.
    /// </summary>
    public async Task<Comment> UpdateRemoteCommentAsync(string prUrl, int threadId, int commentId, string newBody, CancellationToken ct = default)
    {
        var (session, provider) = await ResolveSessionAndProviderAsync(prUrl, ct);
        var result = await provider.UpdateCommentAsync(session.PullRequest.Id, threadId, commentId, newBody, ct);

        // Sync the updated thread back to session cache
        using var _ = _store.AcquireLock(session.Id);
        session = _store.Load(session.Id)
            ?? throw new ReviewServiceException($"Session disappeared during remote comment update: {session.Id}");

        var existingThread = session.Threads.Items.FirstOrDefault(t => t.Id == threadId);
        if (existingThread != null)
        {
            var existingComment = existingThread.Comments.FirstOrDefault(c => c.Id == commentId);
            if (existingComment != null)
            {
                existingComment.Body = newBody;
            }
        }
        session.UpdatedAt = Timestamp();
        _store.Save(session);

        return result;
    }

    /// <summary>
    /// Delete a published comment from the remote provider.
    /// </summary>
    public async Task DeleteRemoteCommentAsync(string prUrl, int threadId, int commentId, CancellationToken ct = default)
    {
        var (session, provider) = await ResolveSessionAndProviderAsync(prUrl, ct);
        await provider.DeleteCommentAsync(session.PullRequest.Id, threadId, commentId, ct);

        // Mark the comment as deleted in session cache
        using var _ = _store.AcquireLock(session.Id);
        session = _store.Load(session.Id)
            ?? throw new ReviewServiceException($"Session disappeared during remote comment deletion: {session.Id}");

        var existingThread = session.Threads.Items.FirstOrDefault(t => t.Id == threadId);
        if (existingThread != null)
        {
            var existingComment = existingThread.Comments.FirstOrDefault(c => c.Id == commentId);
            if (existingComment != null)
            {
                existingComment.IsDeleted = true;
            }
        }
        session.UpdatedAt = Timestamp();
        _store.Save(session);
    }

    /// <summary>
    /// Get the content of a file at a specific branch from the remote provider.
    /// </summary>
    public async Task<string> GetFileContentAsync(string prUrl, string filePath, string branch, CancellationToken ct = default)
    {
        var (session, provider) = await ResolveSessionAndProviderAsync(prUrl, ct);
        return await provider.GetFileContentAsync(filePath, branch, ct);
    }

    /// <summary>
    /// Update the PR description on the remote provider.
    /// </summary>
    public async Task UpdateDescriptionAsync(string prUrl, string newDescription, CancellationToken ct = default)
    {
        var (session, provider) = await ResolveSessionAndProviderAsync(prUrl, ct);
        await provider.UpdatePullRequestDescriptionAsync(session.PullRequest.Id, newDescription, ct);

        // Update local session cache
        using var _ = _store.AcquireLock(session.Id);
        session = _store.Load(session.Id)
            ?? throw new ReviewServiceException($"Session disappeared during description update: {session.Id}");
        session.PullRequest.Description = newDescription;
        session.UpdatedAt = Timestamp();
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
            var worktreeManager = new WorktreeManager(
                repoRoot,
                _config.Git.WorktreeDir,
                _config.Git.AlwaysSeparateWorktree);
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

        // Fix worktree cleanup (best-effort)
        if (session?.FixWorktree != null && _fixWorktreeService != null)
        {
            try
            {
                await _fixWorktreeService.CleanupAsync(sessionId, ct);
            }
            catch
            {
                // Fix worktree cleanup is best-effort
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

        // Check for new iteration and apply smart reset if needed
        var oldIterationId = session.Iteration.Id;
        var oldSourceCommit = session.Review.ReviewedSourceCommit ?? session.Iteration.SourceCommit;

        session.Files = files;
        session.Iteration = iteration;

        // If iteration changed and the reviewer had a reviewed baseline, apply smart reset
        if (iteration.Id != null && iteration.Id != oldIterationId
            && session.Review.ReviewedIterationId != null)
        {
            await ApplySmartResetAsync(session, oldSourceCommit, iteration.SourceCommit);
        }

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

    // =========================================================================
    // Iteration tracking
    // =========================================================================

    /// <summary>
    /// Mark a file as reviewed. On the first call for a session, stamps the
    /// current iteration as the reviewed baseline.
    /// </summary>
    public ReviewState MarkFileReviewed(string prUrl, string filePath)
    {
        var session = ResolveSession(prUrl);

        using var _ = _store.AcquireLock(session.Id);
        session = _store.Load(session.Id)
            ?? throw new ReviewServiceException($"Session disappeared: {session.Id}");

        // Stamp the reviewed iteration on first review action
        if (session.Review.ReviewedIterationId == null && session.Iteration.Id != null)
        {
            session.Review.ReviewedIterationId = session.Iteration.Id;
            session.Review.ReviewedSourceCommit = session.Iteration.SourceCommit;
        }

        var normalized = filePath.Replace('\\', '/');

        if (!session.Review.ReviewedFiles.Any(f => f.Replace('\\', '/').Equals(normalized, StringComparison.OrdinalIgnoreCase)))
        {
            session.Review.ReviewedFiles.Add(filePath);
        }

        // Remove from changed_since_review if present (file has been re-reviewed)
        session.Review.ChangedSinceReview.RemoveAll(f =>
            f.Replace('\\', '/').Equals(normalized, StringComparison.OrdinalIgnoreCase));

        _store.Save(session);
        return session.Review;
    }

    /// <summary>
    /// Unmark a file as reviewed.
    /// </summary>
    public ReviewState UnmarkFileReviewed(string prUrl, string filePath)
    {
        var session = ResolveSession(prUrl);

        using var _ = _store.AcquireLock(session.Id);
        session = _store.Load(session.Id)
            ?? throw new ReviewServiceException($"Session disappeared: {session.Id}");

        var normalized = filePath.Replace('\\', '/');
        session.Review.ReviewedFiles.RemoveAll(f =>
            f.Replace('\\', '/').Equals(normalized, StringComparison.OrdinalIgnoreCase));

        _store.Save(session);
        return session.Review;
    }

    /// <summary>
    /// Mark all current files as reviewed.
    /// </summary>
    public ReviewState MarkAllFilesReviewed(string prUrl)
    {
        var session = ResolveSession(prUrl);

        using var _ = _store.AcquireLock(session.Id);
        session = _store.Load(session.Id)
            ?? throw new ReviewServiceException($"Session disappeared: {session.Id}");

        // Stamp the reviewed iteration on first review action
        if (session.Review.ReviewedIterationId == null && session.Iteration.Id != null)
        {
            session.Review.ReviewedIterationId = session.Iteration.Id;
            session.Review.ReviewedSourceCommit = session.Iteration.SourceCommit;
        }

        session.Review.ReviewedFiles = session.Files.Select(f => f.Path).ToList();
        session.Review.ChangedSinceReview.Clear();

        _store.Save(session);
        return session.Review;
    }

    /// <summary>
    /// Check whether a new iteration is available from the remote.
    /// If a new iteration is detected, performs a smart reset:
    /// - Computes which files changed via git diff
    /// - Removes changed files from reviewed_files
    /// - Updates changed_since_review
    /// - Updates the reviewed iteration baseline
    /// </summary>
    public async Task<IterationCheckResult> CheckIterationAsync(string prUrl, CancellationToken ct = default)
    {
        var (session, provider) = await ResolveSessionAndProviderAsync(prUrl, ct);

        // Fetch the latest iteration from the remote
        var (files, latestIteration) = await provider.GetChangedFilesAsync(session.PullRequest.Id, ct);

        var result = new IterationCheckResult
        {
            OldIterationId = session.Review.ReviewedIterationId ?? session.Iteration.Id,
            NewIterationId = latestIteration.Id,
            HasNewIteration = false,
        };

        // Compare with current session iteration
        if (latestIteration.Id == null || latestIteration.Id == session.Iteration.Id)
        {
            // No change — still on the same iteration
            return result;
        }

        result.HasNewIteration = true;

        // Update the session with the new files and iteration
        using var _ = _store.AcquireLock(session.Id);
        session = _store.Load(session.Id)
            ?? throw new ReviewServiceException($"Session disappeared: {session.Id}");

        var oldSourceCommit = session.Review.ReviewedSourceCommit ?? session.Iteration.SourceCommit;
        var newSourceCommit = latestIteration.SourceCommit;

        // Perform smart reset
        await ApplySmartResetAsync(session, oldSourceCommit, newSourceCommit);

        // Update session iteration to latest
        session.Iteration = latestIteration;
        session.Files = files;

        _store.Save(session);

        result.ChangedFiles = session.Review.ChangedSinceReview.ToList();
        result.Review = session.Review;

        return result;
    }

    /// <summary>
    /// Get the diff content between two iteration commits for a specific file.
    /// Uses git diff with commit SHAs.
    /// </summary>
    public async Task<string> GetIterationDiffAsync(string prUrl, string filePath, CancellationToken ct = default)
    {
        var session = ResolveSession(prUrl);

        var oldCommit = session.Review.ReviewedSourceCommit;
        var newCommit = session.Iteration.SourceCommit;

        if (string.IsNullOrEmpty(oldCommit))
            throw new ReviewServiceException("No previous iteration to compare against. Mark files as reviewed first.");

        if (string.IsNullOrEmpty(newCommit))
            throw new ReviewServiceException("No current iteration commit available.");

        if (oldCommit == newCommit)
            throw new ReviewServiceException("No changes between iterations — same commit.");

        var repoPath = session.Git.WorktreePath ?? session.Git.RepoPath
            ?? throw new ReviewServiceException("No git repository available for diff.");

        var (success, diff, stderr) = await GitOperations.TryRunAsync(
            ["diff", oldCommit, newCommit, "--", filePath.Replace('\\', '/')],
            repoPath,
            ct: ct);

        if (!success)
            throw new ReviewServiceException($"Git diff failed: {stderr}");

        return diff;
    }

    /// <summary>
    /// Apply the smart reset logic when a new iteration is detected.
    /// - Computes which files changed between the old and new source commits
    /// - Removes changed files from reviewed_files
    /// - Stores changed files in changed_since_review
    /// - Updates the reviewed iteration baseline
    /// </summary>
    private async Task ApplySmartResetAsync(ReviewSession session, string? oldSourceCommit, string? newSourceCommit)
    {
        var changedFiles = new List<string>();

        // Try git-based diff to find which files changed between iterations
        if (!string.IsNullOrEmpty(oldSourceCommit) && !string.IsNullOrEmpty(newSourceCommit)
            && oldSourceCommit != newSourceCommit)
        {
            var repoPath = session.Git.WorktreePath ?? session.Git.RepoPath;
            if (repoPath != null)
            {
                var (success, stdout, _) = await GitOperations.TryRunAsync(
                    ["diff", "--name-only", oldSourceCommit, newSourceCommit],
                    repoPath);

                if (success && !string.IsNullOrWhiteSpace(stdout))
                {
                    changedFiles = stdout.Split('\n', StringSplitOptions.RemoveEmptyEntries)
                        .Select(f => f.Trim())
                        .ToList();
                }
            }
        }

        if (changedFiles.Count > 0)
        {
            // Smart reset: only remove reviewed status for files that actually changed
            var changedSet = new HashSet<string>(
                changedFiles.Select(f => f.Replace('\\', '/')),
                StringComparer.OrdinalIgnoreCase);

            session.Review.ReviewedFiles.RemoveAll(f =>
                changedSet.Contains(f.Replace('\\', '/')));

            session.Review.ChangedSinceReview = changedFiles;
        }
        else
        {
            // If we couldn't determine changes (no git, same commit, etc.),
            // preserve the reviewed state as-is and clear changed list
            session.Review.ChangedSinceReview.Clear();
        }

        // Update the reviewed baseline to the new iteration
        session.Review.ReviewedIterationId = session.Iteration.Id;
        session.Review.ReviewedSourceCommit = newSourceCommit ?? session.Iteration.SourceCommit;
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
    /// Resolve a PR URL to its session (no auth needed).
    /// </summary>
    private ReviewSession ResolveSession(string prUrl)
    {
        var parsed = UrlParser.Parse(prUrl)
            ?? throw new ReviewServiceException($"Could not parse PR URL: {prUrl}");

        var sessionId = ReviewSession.ComputeId(
            parsed.ProviderType,
            parsed.Organization,
            parsed.Project,
            parsed.Repository,
            parsed.PrId);

        return _store.Load(sessionId)
            ?? throw new ReviewServiceException(
                $"No session found for PR {prUrl}. Run 'powerreview open --pr-url {prUrl}' first.");
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
                    "Git strategy is 'Cwd' but no valid repository was found. " +
                    "Either provide --repo-path pointing to a local clone, " +
                    "set git.repo_base_path in config, or change git.strategy.");
            // For cwd strategy, just verify the repo exists — no worktree or checkout
            return new GitSetupResult { RepoPath = resolvedRepoPath, WorktreePath = null };
        }

        // We need a repo to work with
        if (resolvedRepoPath == null)
            throw new ReviewServiceException(
                "No valid repository path available for git setup. " +
                "Provide --repo-path pointing to an existing local clone, " +
                "set git.repo_base_path in config to a cloned repo path, " +
                "or use --auto-clone / git.auto_clone to clone automatically.");

        var branchManager = new BranchManager(resolvedRepoPath);

        // Fetch the source branch (non-fatal)
        await branchManager.FetchAsync(pr.SourceBranch, "origin", ct);

        if (strategy == GitStrategy.Worktree)
        {
            var worktreeManager = new WorktreeManager(
                resolvedRepoPath,
                _config.Git.WorktreeDir,
                _config.Git.AlwaysSeparateWorktree);
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

/// <summary>
/// Result of checking for new iterations.
/// </summary>
public sealed class IterationCheckResult
{
    /// <summary>The iteration ID the reviewer was previously reviewing.</summary>
    public int? OldIterationId { get; set; }

    /// <summary>The latest iteration ID from the remote.</summary>
    public int? NewIterationId { get; set; }

    /// <summary>Whether a new iteration was detected.</summary>
    public bool HasNewIteration { get; set; }

    /// <summary>Files that changed between the old and new iterations.</summary>
    public List<string> ChangedFiles { get; set; } = [];

    /// <summary>The updated review state after applying the smart reset.</summary>
    public ReviewState? Review { get; set; }
}

/// <summary>
/// Result of a sync operation, including optional iteration check.
/// </summary>
public sealed class SyncResult
{
    /// <summary>Number of threads synced from the remote.</summary>
    public int ThreadCount { get; set; }

    /// <summary>Iteration check result, if a new iteration was detected during sync.</summary>
    public IterationCheckResult? IterationCheck { get; set; }
}
