namespace PowerReview.Core.Git;

/// <summary>
/// Manages branch operations for PR review setup.
/// </summary>
public sealed class BranchManager
{
    private readonly string _repoRoot;

    public BranchManager(string repoRoot)
    {
        _repoRoot = repoRoot;
    }

    /// <summary>
    /// Fetch a branch from a remote.
    /// Non-fatal: returns false if fetch fails (branch may exist locally).
    /// </summary>
    public async Task<bool> FetchAsync(string branch, string remote = "origin", CancellationToken ct = default)
    {
        var (success, _, _) = await GitOperations.TryRunAsync(
            ["fetch", remote, branch], _repoRoot, 60_000, ct);
        return success;
    }

    /// <summary>
    /// Checkout a branch.
    /// If the branch doesn't exist locally, falls back to checking out a remote tracking branch.
    /// </summary>
    public async Task CheckoutAsync(string branch, CancellationToken ct = default)
    {
        var (success, _, stderr) = await GitOperations.TryRunAsync(
            ["checkout", branch], _repoRoot, 30_000, ct);

        if (success)
            return;

        // If branch not found locally, try creating a tracking branch
        if (stderr.Contains("did not match", StringComparison.OrdinalIgnoreCase) ||
            stderr.Contains("pathspec", StringComparison.OrdinalIgnoreCase))
        {
            await GitOperations.RunAsync(
                ["checkout", "--track", $"origin/{branch}"],
                _repoRoot, 30_000, ct);
            return;
        }

        throw new GitException($"Failed to checkout branch '{branch}': {stderr}");
    }

    /// <summary>
    /// Stash current changes if there are any.
    /// </summary>
    /// <returns>True if changes were stashed, false if working tree was clean.</returns>
    public async Task<bool> StashAsync(CancellationToken ct = default)
    {
        // Check if there are changes to stash
        var status = await GitOperations.RunAsync(
            ["status", "--porcelain"], _repoRoot, 10_000, ct);

        if (string.IsNullOrWhiteSpace(status))
            return false;

        await GitOperations.RunAsync(
            ["stash", "push", "-m", "PowerReview: auto-stash before review"],
            _repoRoot, 15_000, ct);
        return true;
    }

    /// <summary>
    /// Pop the most recent stash.
    /// </summary>
    public async Task StashPopAsync(CancellationToken ct = default)
    {
        await GitOperations.RunAsync(["stash", "pop"], _repoRoot, 15_000, ct);
    }

    /// <summary>
    /// Get the current branch name.
    /// </summary>
    public async Task<string> GetCurrentBranchAsync(CancellationToken ct = default)
    {
        return await GitOperations.GetCurrentBranchAsync(_repoRoot, ct);
    }

    /// <summary>
    /// Fetch a branch then checkout.
    /// </summary>
    public async Task FetchAndCheckoutAsync(string branch, string remote = "origin", CancellationToken ct = default)
    {
        await FetchAsync(branch, remote, ct);
        await CheckoutAsync(branch, ct);
    }
}
