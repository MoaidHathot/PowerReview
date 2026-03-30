using System.Diagnostics;
using System.Text;

namespace PowerReview.Core.Git;

/// <summary>
/// Runs git commands as subprocesses.
/// </summary>
public static class GitOperations
{
    /// <summary>
    /// Run a git command and return stdout.
    /// </summary>
    /// <param name="args">Git arguments (e.g. "status", "--porcelain").</param>
    /// <param name="workingDirectory">Working directory for the command.</param>
    /// <param name="timeoutMs">Timeout in milliseconds.</param>
    /// <returns>Trimmed stdout output.</returns>
    /// <exception cref="GitException">If the command fails.</exception>
    public static async Task<string> RunAsync(
        IEnumerable<string> args,
        string workingDirectory,
        int timeoutMs = 30_000,
        CancellationToken ct = default)
    {
        var argsList = args.ToList();
        var psi = new ProcessStartInfo
        {
            FileName = "git",
            WorkingDirectory = workingDirectory,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
        };

        foreach (var arg in argsList)
            psi.ArgumentList.Add(arg);

        using var process = new Process { StartInfo = psi };

        try
        {
            process.Start();
        }
        catch (System.ComponentModel.Win32Exception)
        {
            throw new GitException("Git is not installed or not in PATH.");
        }

        var stdout = new StringBuilder();
        var stderr = new StringBuilder();

        var stdoutTask = Task.Run(async () =>
        {
            string? line;
            while ((line = await process.StandardOutput.ReadLineAsync(ct)) != null)
            {
                if (stdout.Length > 0) stdout.AppendLine();
                stdout.Append(line);
            }
        }, ct);

        var stderrTask = Task.Run(async () =>
        {
            string? line;
            while ((line = await process.StandardError.ReadLineAsync(ct)) != null)
            {
                if (stderr.Length > 0) stderr.AppendLine();
                stderr.Append(line);
            }
        }, ct);

        using var timeoutCts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        timeoutCts.CancelAfter(timeoutMs);

        try
        {
            await process.WaitForExitAsync(timeoutCts.Token);
            await Task.WhenAll(stdoutTask, stderrTask);
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested)
        {
            try { process.Kill(entireProcessTree: true); } catch { /* best effort */ }
            throw new GitException($"Git command timed out after {timeoutMs}ms: git {string.Join(' ', argsList)}");
        }

        if (process.ExitCode != 0)
        {
            throw new GitException(
                $"Git command failed (exit {process.ExitCode}): git {string.Join(' ', argsList)}\n{stderr}");
        }

        return stdout.ToString().Trim();
    }

    /// <summary>
    /// Run a git command, returning success/failure without throwing.
    /// </summary>
    public static async Task<(bool Success, string Stdout, string Stderr)> TryRunAsync(
        IEnumerable<string> args,
        string workingDirectory,
        int timeoutMs = 30_000,
        CancellationToken ct = default)
    {
        try
        {
            var output = await RunAsync(args, workingDirectory, timeoutMs, ct);
            return (true, output, "");
        }
        catch (GitException ex)
        {
            return (false, "", ex.Message);
        }
    }

    /// <summary>
    /// Get the root of the git repository containing the given path.
    /// </summary>
    public static async Task<string> GetRepoRootAsync(string path, CancellationToken ct = default)
    {
        return await RunAsync(["rev-parse", "--show-toplevel"], path, 10_000, ct);
    }

    /// <summary>
    /// Get the current branch name.
    /// </summary>
    public static async Task<string> GetCurrentBranchAsync(string repoPath, CancellationToken ct = default)
    {
        return await RunAsync(["rev-parse", "--abbrev-ref", "HEAD"], repoPath, 10_000, ct);
    }

    /// <summary>
    /// Check if a path is inside a git repository.
    /// </summary>
    public static async Task<bool> IsGitRepoAsync(string path, CancellationToken ct = default)
    {
        var (success, _, _) = await TryRunAsync(["rev-parse", "--is-inside-work-tree"], path, 10_000, ct);
        return success;
    }
}

/// <summary>
/// Exception thrown when a git operation fails.
/// </summary>
public class GitException : Exception
{
    public GitException(string message) : base(message) { }
    public GitException(string message, Exception inner) : base(message, inner) { }
}
