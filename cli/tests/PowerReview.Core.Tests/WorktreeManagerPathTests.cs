using PowerReview.Core.Git;

namespace PowerReview.Core.Tests;

/// <summary>
/// Unit tests for the pure path-resolution helpers on WorktreeManager.
/// These do not invoke git and can run on any platform.
/// </summary>
public class WorktreeManagerPathTests
{
    [Fact]
    public void ResolveWorktreePath_Relative_JoinedWithRepoRoot()
    {
        var repoRoot = OperatingSystem.IsWindows() ? "C:\\repos\\my-repo" : "/repos/my-repo";

        var (path, isExternal) = WorktreeManager.ResolveWorktreePath(
            repoRoot, ".power-review-worktrees", 42);

        Assert.False(isExternal);
        Assert.Contains("my-repo", path);
        Assert.Contains(".power-review-worktrees", path);
        Assert.EndsWith("/42", path);
        // Always normalised to forward slashes
        Assert.DoesNotContain('\\', path);
    }

    [Fact]
    public void ResolveWorktreePath_EmptyDir_UsesDefault()
    {
        var repoRoot = OperatingSystem.IsWindows() ? "C:\\repos\\r" : "/repos/r";

        var (path, isExternal) = WorktreeManager.ResolveWorktreePath(repoRoot, "", 7);

        Assert.False(isExternal);
        Assert.Contains(WorktreeManager.DefaultWorktreeDir, path);
        Assert.EndsWith("/7", path);
    }

    [Fact]
    public void ResolveWorktreePath_Absolute_UsesExternalBaseAndNamespacesByRepo()
    {
        var repoRoot = OperatingSystem.IsWindows() ? "C:\\repos\\my-repo" : "/repos/my-repo";
        var external = OperatingSystem.IsWindows()
            ? "P:\\Work\\PowerReview\\Sessions"
            : "/work/powerreview/sessions";

        var (path, isExternal) = WorktreeManager.ResolveWorktreePath(repoRoot, external, 99);

        Assert.True(isExternal);
        // Path should start with the external base
        var normalisedExternal = external.Replace('\\', '/');
        Assert.StartsWith(normalisedExternal, path);
        // Path should be namespaced by the repo identity (contains the repo name)
        Assert.Contains("my-repo", path);
        Assert.EndsWith("/99", path);
    }

    [Fact]
    public void ResolveWorktreePath_Absolute_DifferentReposGetDistinctSubdirs()
    {
        var external = OperatingSystem.IsWindows()
            ? "P:\\Work\\PowerReview\\Sessions"
            : "/work/powerreview/sessions";

        var repoA = OperatingSystem.IsWindows() ? "C:\\repos\\alpha" : "/repos/alpha";
        var repoB = OperatingSystem.IsWindows() ? "C:\\repos\\beta" : "/repos/beta";

        var (pathA, _) = WorktreeManager.ResolveWorktreePath(repoA, external, 1);
        var (pathB, _) = WorktreeManager.ResolveWorktreePath(repoB, external, 1);

        Assert.NotEqual(pathA, pathB);
    }

    [Fact]
    public void ResolveWorktreePath_Absolute_SameRepoStableAcrossCalls()
    {
        var external = OperatingSystem.IsWindows()
            ? "P:\\Work\\PowerReview\\Sessions"
            : "/work/powerreview/sessions";
        var repo = OperatingSystem.IsWindows() ? "C:\\repos\\stable" : "/repos/stable";

        var (path1, _) = WorktreeManager.ResolveWorktreePath(repo, external, 5);
        var (path2, _) = WorktreeManager.ResolveWorktreePath(repo, external, 5);

        Assert.Equal(path1, path2);
    }

    [Fact]
    public void ComputeRepoId_IncludesSanitisedName()
    {
        var repoRoot = OperatingSystem.IsWindows() ? "C:\\repos\\my repo" : "/repos/my repo";

        var id = WorktreeManager.ComputeRepoId(repoRoot);

        // Spaces sanitised
        Assert.DoesNotContain(' ', id);
        Assert.Contains("my_repo", id);
        // Has a hash suffix
        Assert.Matches("-[0-9a-f]{8}$", id);
    }

    [Fact]
    public void ComputeRepoId_EmptyInput_ReturnsPlaceholder()
    {
        var id = WorktreeManager.ComputeRepoId("");
        Assert.Equal("_", id);
    }
}
