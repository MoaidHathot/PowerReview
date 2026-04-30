namespace PowerReview.Core.Git;

/// <summary>
/// Manages git worktrees for PR review checkouts.
/// </summary>
public sealed class WorktreeManager
{
    /// <summary>Default subdirectory name for review worktrees (relative to repo root).</summary>
    public const string DefaultWorktreeDir = ".power-review-worktrees";

    private readonly string _repoRoot;
    private readonly string _worktreeDir;
    private readonly bool _alwaysSeparate;

    /// <summary>
    /// Create a WorktreeManager.
    /// </summary>
    /// <param name="repoRoot">Path to the main git repository.</param>
    /// <param name="worktreeDir">
    /// Either a relative path (joined with <paramref name="repoRoot"/>) or an
    /// absolute path used as the external base directory.
    /// </param>
    /// <param name="alwaysSeparate">
    /// If true, always create a separate linked worktree even when the main
    /// repo is already on the target branch. The main repo's HEAD will be
    /// detached as needed so the branch can be moved into the new worktree.
    /// </param>
    public WorktreeManager(string repoRoot, string worktreeDir = DefaultWorktreeDir, bool alwaysSeparate = false)
    {
        _repoRoot = repoRoot;
        _worktreeDir = string.IsNullOrEmpty(worktreeDir) ? DefaultWorktreeDir : worktreeDir;
        _alwaysSeparate = alwaysSeparate;
    }

    /// <summary>
    /// Result of creating a worktree.
    /// </summary>
    public sealed class CreateResult
    {
        /// <summary>Path to the worktree (or main repo if reused).</summary>
        public string WorktreePath { get; set; } = "";

        /// <summary>
        /// True if the main repo was reused as the worktree (only possible
        /// when <c>alwaysSeparate</c> is false).
        /// </summary>
        public bool ReusedMain { get; set; }
    }

    /// <summary>
    /// Create a worktree for reviewing a PR branch.
    /// If <c>alwaysSeparate</c> is false and the main repo is already on the
    /// target branch, returns the main repo path. Otherwise always creates a
    /// linked worktree (detaching the main repo's HEAD if needed so the
    /// branch can be checked out elsewhere).
    /// If a worktree already exists at the expected path, returns it.
    /// </summary>
    public async Task<CreateResult> CreateAsync(string branch, int prId, CancellationToken ct = default)
    {
        // Check if the main worktree is already on the target branch
        string? currentBranch = null;
        try
        {
            currentBranch = await GitOperations.GetCurrentBranchAsync(_repoRoot, ct);
        }
        catch
        {
            // Detached HEAD or unreadable; treat as "not on branch"
        }

        var alreadyOnBranch = currentBranch == branch;

        if (alreadyOnBranch && !_alwaysSeparate)
        {
            return new CreateResult { WorktreePath = _repoRoot, ReusedMain = true };
        }

        var worktreePath = ResolveWorktreePath(prId);

        // Ensure parent directory exists
        var parentDir = Path.GetDirectoryName(worktreePath);
        if (parentDir != null)
            Directory.CreateDirectory(parentDir);

        // Check if worktree already exists at this path
        var existing = await ListAsync(ct);
        if (existing.Any(w => NormalizePath(w.Path) == NormalizePath(worktreePath)))
        {
            return new CreateResult { WorktreePath = worktreePath };
        }

        // If the main repo currently has the target branch checked out, git will
        // refuse to add another worktree for the same branch. Detach the main
        // repo's HEAD so the branch is free to move into the linked worktree.
        if (alreadyOnBranch && _alwaysSeparate)
        {
            await GitOperations.TryRunAsync(
                ["checkout", "--detach"],
                _repoRoot,
                timeoutMs: 15_000,
                ct: ct);
        }

        // Try creating the worktree
        var (success, _, stderr) = await GitOperations.TryRunAsync(
            ["worktree", "add", worktreePath, branch],
            _repoRoot,
            timeoutMs: 30_000,
            ct: ct);

        if (success)
            return new CreateResult { WorktreePath = worktreePath };

        // If branch ref is invalid, try creating with remote tracking
        if (stderr.Contains("not a valid", StringComparison.OrdinalIgnoreCase) ||
            stderr.Contains("invalid reference", StringComparison.OrdinalIgnoreCase))
        {
            await GitOperations.RunAsync(
                ["worktree", "add", "--track", "-b", branch, worktreePath, $"origin/{branch}"],
                _repoRoot,
                timeoutMs: 30_000,
                ct: ct);

            return new CreateResult { WorktreePath = worktreePath };
        }

        throw new GitException($"Failed to create worktree: {stderr}");
    }

    /// <summary>
    /// Remove a worktree.
    /// </summary>
    public async Task RemoveAsync(string worktreePath, CancellationToken ct = default)
    {
        // Get the main repo root from the worktree
        string mainRoot;
        try
        {
            var commonDir = await GitOperations.RunAsync(
                ["rev-parse", "--git-common-dir"], worktreePath, 10_000, ct);
            mainRoot = Path.GetFullPath(Path.Combine(commonDir, ".."));
        }
        catch
        {
            mainRoot = _repoRoot;
        }

        var (success, _, _) = await GitOperations.TryRunAsync(
            ["worktree", "remove", "--force", worktreePath],
            mainRoot,
            timeoutMs: 15_000,
            ct: ct);

        if (!success)
        {
            // Fallback: delete directory and prune
            if (Directory.Exists(worktreePath))
            {
                try { Directory.Delete(worktreePath, recursive: true); } catch { /* best effort */ }
            }
            await GitOperations.TryRunAsync(["worktree", "prune"], mainRoot, 10_000, ct);
        }
    }

    /// <summary>
    /// List all worktrees for the repository.
    /// </summary>
    public async Task<List<WorktreeInfo>> ListAsync(CancellationToken ct = default)
    {
        var output = await GitOperations.RunAsync(
            ["worktree", "list", "--porcelain"], _repoRoot, 10_000, ct);

        var worktrees = new List<WorktreeInfo>();
        WorktreeInfo? current = null;

        foreach (var line in output.Split('\n', StringSplitOptions.None))
        {
            var trimmed = line.Trim();
            if (string.IsNullOrEmpty(trimmed))
            {
                if (current != null)
                {
                    worktrees.Add(current);
                    current = null;
                }
                continue;
            }

            if (trimmed.StartsWith("worktree "))
            {
                current = new WorktreeInfo { Path = trimmed["worktree ".Length..] };
            }
            else if (trimmed.StartsWith("HEAD ") && current != null)
            {
                current.Head = trimmed["HEAD ".Length..];
            }
            else if (trimmed.StartsWith("branch ") && current != null)
            {
                current.Branch = trimmed["branch ".Length..];
            }
            else if (trimmed == "bare" && current != null)
            {
                current.IsBare = true;
            }
        }

        // Don't forget the last entry
        if (current != null)
            worktrees.Add(current);

        return worktrees;
    }

    /// <summary>
    /// Resolve the on-disk path where the worktree for <paramref name="prId"/> will live.
    /// Public for diagnostics and tests.
    /// </summary>
    public string ResolveWorktreePath(int prId)
    {
        var (path, _) = ResolveWorktreePath(_repoRoot, _worktreeDir, prId);
        return path;
    }

    /// <summary>
    /// Compute the worktree path for a given repo + worktree-dir setting + PR id.
    /// </summary>
    /// <returns>
    /// A tuple of (path, isExternal). <c>isExternal</c> is true when
    /// <paramref name="worktreeDir"/> is an absolute path (worktrees live
    /// outside the repo, namespaced by repo identity).
    /// </returns>
    public static (string Path, bool IsExternal) ResolveWorktreePath(string repoRoot, string worktreeDir, int prId)
    {
        if (string.IsNullOrEmpty(worktreeDir))
            worktreeDir = DefaultWorktreeDir;

        if (Path.IsPathRooted(worktreeDir))
        {
            // External base directory: namespace by repo identity to avoid
            // collisions when multiple repos share the same base.
            var repoId = ComputeRepoId(repoRoot);
            var external = Path.Combine(worktreeDir, repoId, prId.ToString());
            return (external.Replace('\\', '/'), true);
        }

        var local = Path.Combine(repoRoot, worktreeDir, prId.ToString());
        return (local.Replace('\\', '/'), false);
    }

    /// <summary>
    /// Derive a stable, filesystem-safe identifier for a repo root path so
    /// that an external worktree base directory can host worktrees from
    /// multiple repos without collisions.
    /// </summary>
    public static string ComputeRepoId(string repoRoot)
    {
        if (string.IsNullOrEmpty(repoRoot))
            return "_";

        var full = Path.GetFullPath(repoRoot).Replace('\\', '/').TrimEnd('/');
        var name = Path.GetFileName(full);
        if (string.IsNullOrEmpty(name))
            name = "repo";

        // Short hash of the full path for uniqueness; keeps the human-readable
        // repo name as a prefix so the directory layout is still browseable.
        var hash = (uint)full.GetHashCode();
        return $"{Sanitize(name)}-{hash:x8}";
    }

    private static string Sanitize(string s)
    {
        var invalid = Path.GetInvalidFileNameChars();
        var chars = s.Select(c => invalid.Contains(c) || c == ' ' ? '_' : c).ToArray();
        return new string(chars);
    }

    private static string NormalizePath(string path)
    {
        return path.Replace('\\', '/').TrimEnd('/');
    }
}

/// <summary>
/// Information about a git worktree.
/// </summary>
public sealed class WorktreeInfo
{
    public string Path { get; set; } = "";
    public string? Head { get; set; }
    public string? Branch { get; set; }
    public bool IsBare { get; set; }
}
