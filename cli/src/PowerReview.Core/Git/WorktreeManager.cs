namespace PowerReview.Core.Git;

/// <summary>
/// Manages git worktrees for PR review checkouts.
/// </summary>
public sealed class WorktreeManager
{
    private readonly string _repoRoot;
    private readonly string _worktreeDir;

    /// <summary>
    /// Create a WorktreeManager.
    /// </summary>
    /// <param name="repoRoot">Path to the main git repository.</param>
    /// <param name="worktreeDir">Subdirectory name for worktrees (default: ".power-review-worktrees").</param>
    public WorktreeManager(string repoRoot, string worktreeDir = ".power-review-worktrees")
    {
        _repoRoot = repoRoot;
        _worktreeDir = worktreeDir;
    }

    /// <summary>
    /// Result of creating a worktree.
    /// </summary>
    public sealed class CreateResult
    {
        /// <summary>Path to the worktree (or main repo if reused).</summary>
        public string WorktreePath { get; set; } = "";

        /// <summary>True if the main repo was already on the target branch.</summary>
        public bool ReusedMain { get; set; }
    }

    /// <summary>
    /// Create a worktree for reviewing a PR branch.
    /// If the main repo is already on the target branch, returns the main repo path.
    /// If a worktree already exists at the expected path, returns it.
    /// </summary>
    public async Task<CreateResult> CreateAsync(string branch, int prId, CancellationToken ct = default)
    {
        // Check if the main worktree is already on the target branch
        var currentBranch = await GitOperations.GetCurrentBranchAsync(_repoRoot, ct);
        if (currentBranch == branch)
        {
            return new CreateResult { WorktreePath = _repoRoot, ReusedMain = true };
        }

        var worktreePath = GetWorktreePath(prId);

        // Normalize path separators
        worktreePath = worktreePath.Replace('\\', '/');

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

    private string GetWorktreePath(int prId)
    {
        return Path.Combine(_repoRoot, _worktreeDir, prId.ToString());
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
