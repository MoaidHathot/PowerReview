using PowerReview.Core.Configuration;
using PowerReview.Core.Git;
using PowerReview.Core.Models;
using PowerReview.Core.Store;

namespace PowerReview.Core.Services;

/// <summary>
/// Manages the fix worktree used by AI agents to create code changes
/// in response to PR comments, without affecting the user's working directory.
/// One worktree per PR, reused across all fixes for that PR.
/// </summary>
public sealed class FixWorktreeService
{
    private readonly SessionStore _store;
    private readonly PowerReviewConfig _config;

    /// <summary>
    /// Default subdirectory name for fix worktrees (relative to the repo
    /// root). Used when <see cref="GitConfig.WorktreeDir"/> is a relative path.
    /// </summary>
    private const string DefaultFixWorktreeDir = ".power-review-fixes";

    public FixWorktreeService(SessionStore store, PowerReviewConfig config)
    {
        _store = store;
        _config = config;
    }

    /// <summary>
    /// Resolve the fix worktree directory honoring an absolute
    /// <c>git.worktree_dir</c>. When configured externally, fix worktrees go
    /// to <c>{abs}/.fixes</c>; otherwise the in-repo default is used.
    /// </summary>
    private string ResolveFixWorktreeDir()
    {
        var configured = _config.Git.WorktreeDir;
        if (!string.IsNullOrEmpty(configured) && Path.IsPathRooted(configured))
        {
            return Path.Combine(configured, ".fixes");
        }
        return DefaultFixWorktreeDir;
    }

    /// <summary>
    /// Prepare a fix worktree for the given session.
    /// Idempotent: if a worktree already exists, returns its path.
    /// Creates a worktree from the PR's source branch.
    /// </summary>
    /// <returns>The worktree path and whether it was newly created.</returns>
    public async Task<FixWorktreePrepareResult> PrepareAsync(string sessionId, CancellationToken ct = default)
    {
        using var lck = _store.AcquireLock(sessionId);

        var session = LoadOrThrow(sessionId);

        // If fix worktree already exists, validate and return it
        if (session.FixWorktree != null)
        {
            if (Directory.Exists(session.FixWorktree.Path))
            {
                return new FixWorktreePrepareResult
                {
                    WorktreePath = session.FixWorktree.Path,
                    BaseBranch = session.FixWorktree.BaseBranch,
                    Created = false,
                };
            }

            // Worktree directory was deleted externally — clean up and recreate
            session.FixWorktree = null;
        }

        // We need a repo path to create worktrees from
        var repoPath = session.Git.RepoPath
            ?? throw new FixWorktreeServiceException(
                "No git repository path available. The session must have been opened with a local repo.");

        var sourceBranch = session.PullRequest.SourceBranch;
        if (string.IsNullOrEmpty(sourceBranch))
            throw new FixWorktreeServiceException("PR source branch is not set.");

        // Fetch the latest source branch
        var branchManager = new BranchManager(repoPath);
        await branchManager.FetchAsync(sourceBranch, "origin", ct);

        // Resolve the fix worktree path (honors absolute worktree_dir for external isolation)
        var fixDir = ResolveFixWorktreeDir();
        var (worktreePath, _) = WorktreeManager.ResolveWorktreePath(
            repoPath, fixDir, session.PullRequest.Id);

        // Create the worktree
        var worktreeManager = new WorktreeManager(repoPath, fixDir);
        var result = await worktreeManager.CreateAsync(sourceBranch, session.PullRequest.Id, ct);

        // If reused main, we can't use the main repo for fixes — that defeats the purpose
        if (result.ReusedMain)
        {
            // Force create a separate worktree by using a detached branch
            var fixBaseBranch = $"powerreview/fix-base/{session.PullRequest.Id}";
            var (success, _, stderr) = await GitOperations.TryRunAsync(
                ["branch", fixBaseBranch, $"origin/{sourceBranch}"],
                repoPath, ct: ct);

            if (!success && !stderr.Contains("already exists", StringComparison.OrdinalIgnoreCase))
            {
                // Try without origin/ prefix
                (success, _, stderr) = await GitOperations.TryRunAsync(
                    ["branch", fixBaseBranch, sourceBranch],
                    repoPath, ct: ct);

                if (!success && !stderr.Contains("already exists", StringComparison.OrdinalIgnoreCase))
                    throw new FixWorktreeServiceException($"Failed to create fix base branch: {stderr}");
            }

            // Ensure parent directory exists
            var parentDir = Path.GetDirectoryName(worktreePath);
            if (parentDir != null)
                Directory.CreateDirectory(parentDir);

            await GitOperations.RunAsync(
                ["worktree", "add", worktreePath, fixBaseBranch],
                repoPath, timeoutMs: 30_000, ct: ct);
        }

        var actualWorktreePath = result.ReusedMain ? worktreePath : result.WorktreePath;

        // Record in session
        session.FixWorktree = new FixWorktreeInfo
        {
            Path = actualWorktreePath,
            BaseBranch = sourceBranch,
            CreatedAt = Timestamp(),
        };
        _store.Save(session);

        return new FixWorktreePrepareResult
        {
            WorktreePath = actualWorktreePath,
            BaseBranch = sourceBranch,
            Created = true,
        };
    }

    /// <summary>
    /// Get the fix worktree path for a session, or null if not created.
    /// </summary>
    public string? GetWorktreePath(string sessionId)
    {
        var session = _store.Load(sessionId);
        return session?.FixWorktree?.Path;
    }

    /// <summary>
    /// Create a new fix branch in the worktree for a specific thread.
    /// The branch is created from the PR's source branch (or origin/source_branch).
    /// </summary>
    /// <returns>The branch name created.</returns>
    public async Task<string> CreateFixBranchAsync(string sessionId, int threadId, CancellationToken ct = default)
    {
        var session = LoadOrThrow(sessionId);

        if (session.FixWorktree == null)
            throw new FixWorktreeServiceException(
                "No fix worktree exists. Call PrepareAsync first.");

        var worktreePath = session.FixWorktree.Path;
        if (!Directory.Exists(worktreePath))
            throw new FixWorktreeServiceException(
                $"Fix worktree directory does not exist: {worktreePath}. Call PrepareAsync to recreate.");

        var branchName = $"powerreview/fix/thread-{threadId}";

        // Check if branch already exists
        var (exists, _, _) = await GitOperations.TryRunAsync(
            ["rev-parse", "--verify", branchName],
            worktreePath, ct: ct);

        if (exists)
        {
            // Branch exists, just checkout
            await GitOperations.RunAsync(
                ["checkout", branchName],
                worktreePath, ct: ct);

            return branchName;
        }

        // Create new branch from the source branch
        var sourceBranch = session.FixWorktree.BaseBranch;

        // Try origin/sourceBranch first, fall back to sourceBranch
        var (success, _1, stderr) = await GitOperations.TryRunAsync(
            ["checkout", "-b", branchName, $"origin/{sourceBranch}"],
            worktreePath, ct: ct);

        if (!success)
        {
            (success, _, stderr) = await GitOperations.TryRunAsync(
                ["checkout", "-b", branchName, sourceBranch],
                worktreePath, ct: ct);

            if (!success)
                throw new FixWorktreeServiceException(
                    $"Failed to create fix branch '{branchName}': {stderr}");
        }

        return branchName;
    }

    /// <summary>
    /// Remove the fix worktree and clean up all fix branches.
    /// </summary>
    public async Task CleanupAsync(string sessionId, CancellationToken ct = default)
    {
        using var lck = _store.AcquireLock(sessionId);

        var session = LoadOrThrow(sessionId);

        if (session.FixWorktree == null)
            return; // Nothing to clean up

        var worktreePath = session.FixWorktree.Path;
        var repoPath = session.Git.RepoPath ?? ".";

        // Remove the worktree
        if (Directory.Exists(worktreePath))
        {
            var worktreeManager = new WorktreeManager(repoPath, ResolveFixWorktreeDir());
            try
            {
                await worktreeManager.RemoveAsync(worktreePath, ct);
            }
            catch
            {
                // Best effort — try direct delete
                try { Directory.Delete(worktreePath, recursive: true); } catch { /* best effort */ }
                await GitOperations.TryRunAsync(["worktree", "prune"], repoPath, 10_000, ct);
            }
        }

        // Clean up fix branches
        var (success, stdout, _) = await GitOperations.TryRunAsync(
            ["branch", "--list", "powerreview/fix/*"],
            repoPath, ct: ct);

        if (success && !string.IsNullOrWhiteSpace(stdout))
        {
            foreach (var branch in stdout.Split('\n', StringSplitOptions.RemoveEmptyEntries))
            {
                var trimmed = branch.Trim().TrimStart('*').Trim();
                if (!string.IsNullOrEmpty(trimmed))
                {
                    await GitOperations.TryRunAsync(
                        ["branch", "-D", trimmed],
                        repoPath, ct: ct);
                }
            }
        }

        // Clean up fix-base branch
        var fixBaseBranch = $"powerreview/fix-base/{session.PullRequest.Id}";
        await GitOperations.TryRunAsync(
            ["branch", "-D", fixBaseBranch],
            repoPath, ct: ct);

        // Clear fix worktree from session
        session.FixWorktree = null;
        _store.Save(session);
    }

    /// <summary>
    /// Get the diff between a fix branch and the PR source branch.
    /// </summary>
    public async Task<string> GetFixBranchDiffAsync(string sessionId, string branchName, CancellationToken ct = default)
    {
        var session = LoadOrThrow(sessionId);

        if (session.FixWorktree == null)
            throw new FixWorktreeServiceException("No fix worktree exists.");

        var repoPath = session.Git.RepoPath
            ?? throw new FixWorktreeServiceException("No git repository path available.");

        var sourceBranch = session.FixWorktree.BaseBranch;

        // Try origin/source first for the base comparison
        var (success, diff, stderr) = await GitOperations.TryRunAsync(
            ["diff", $"origin/{sourceBranch}...{branchName}"],
            repoPath, ct: ct);

        if (!success)
        {
            // Fall back to local branch
            (success, diff, stderr) = await GitOperations.TryRunAsync(
                ["diff", $"{sourceBranch}...{branchName}"],
                repoPath, ct: ct);

            if (!success)
                throw new FixWorktreeServiceException($"Failed to get diff: {stderr}");
        }

        return diff;
    }

    private ReviewSession LoadOrThrow(string sessionId)
    {
        return _store.Load(sessionId)
            ?? throw new FixWorktreeServiceException($"Session not found: {sessionId}");
    }

    private static string Timestamp() => DateTime.UtcNow.ToString("o");
}

/// <summary>
/// Result of preparing a fix worktree.
/// </summary>
public sealed class FixWorktreePrepareResult
{
    /// <summary>Filesystem path to the fix worktree.</summary>
    public string WorktreePath { get; set; } = "";

    /// <summary>The base branch the worktree was created from.</summary>
    public string BaseBranch { get; set; } = "";

    /// <summary>True if the worktree was newly created, false if it already existed.</summary>
    public bool Created { get; set; }
}

/// <summary>
/// Exception thrown by FixWorktreeService for business logic errors.
/// </summary>
public sealed class FixWorktreeServiceException : Exception
{
    public FixWorktreeServiceException(string message) : base(message) { }
    public FixWorktreeServiceException(string message, Exception inner) : base(message, inner) { }
}
