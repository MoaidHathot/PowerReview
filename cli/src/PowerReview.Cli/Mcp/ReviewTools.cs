using System.ComponentModel;
using ModelContextProtocol.Server;
using PowerReview.Core.Git;
using PowerReview.Core.Models;
using PowerReview.Core.Services;

namespace PowerReview.Cli.Mcp;

/// <summary>
/// MCP tools for read-only review operations: session info, files, diff, threads.
/// </summary>
[McpServerToolType]
public sealed class ReviewTools
{
    [McpServerTool, Description(
        "Get the current PR review session metadata including PR title, author, branches, " +
        "draft/file counts, and current vote status. Requires an active session " +
        "(run 'powerreview open' first).")]
    public static string GetReviewSession(
        ReviewService reviewService,
        [Description("The pull request URL")] string prUrl)
    {
        var result = reviewService.GetSession(prUrl);
        if (result == null)
            return ToolHelpers.ToJson(new { error = "No session found for this PR. Run 'powerreview open --pr-url <url>' first." });

        return ToolHelpers.ToJson(result.Session);
    }

    [McpServerTool, Description(
        "List all files changed in the pull request, including their change type " +
        "(add, edit, delete, rename) and paths.")]
    public static string ListChangedFiles(
        ReviewService reviewService,
        [Description("The pull request URL")] string prUrl)
    {
        var files = reviewService.GetFiles(prUrl);
        if (files == null)
            return ToolHelpers.ToJson(new { error = "No session found for this PR." });

        // Return a summary + raw data
        var summary = new
        {
            count = files.Count,
            files = files.Select(f => new
            {
                change_type = f.ChangeType.ToString().ToLowerInvariant(),
                path = f.Path,
                original_path = f.OriginalPath,
            }),
        };

        return ToolHelpers.ToJson(summary);
    }

    [McpServerTool, Description(
        "Get the git diff content for a specific file in the pull request. " +
        "Returns the unified diff showing all changes made to the file. " +
        "Requires a local git checkout (session must have a repo path).")]
    public static async Task<string> GetFileDiff(
        ReviewService reviewService,
        [Description("The pull request URL")] string prUrl,
        [Description("Relative file path within the repository")] string filePath,
        CancellationToken ct)
    {
        var sessionResult = reviewService.GetSession(prUrl);
        if (sessionResult == null)
            return ToolHelpers.ToJson(new { error = "No session found for this PR." });

        var session = sessionResult.Session;

        // Find the file in the changed files list
        var normalizedPath = filePath.Replace('\\', '/');
        var changedFile = session.Files
            .FirstOrDefault(f => f.Path.Replace('\\', '/').Equals(normalizedPath, StringComparison.OrdinalIgnoreCase));

        if (changedFile == null)
            return ToolHelpers.ToJson(new { error = $"File '{filePath}' not found in the changed files list." });

        // Determine the repo path to run git diff
        var repoPath = session.Git.WorktreePath ?? session.Git.RepoPath;
        if (string.IsNullOrEmpty(repoPath))
        {
            // No local repo — return file metadata only
            return ToolHelpers.ToJson(new
            {
                file = changedFile,
                diff = (string?)null,
                note = "No local git repository available. Only file metadata is returned.",
            });
        }

        // Run git diff
        var targetBranch = session.PullRequest.TargetBranch;
        string diff;
        try
        {
            // Try merge-base diff first (target...HEAD)
            var (success, stdout, _) = await GitOperations.TryRunAsync(
                ["diff", $"{targetBranch}...HEAD", "--", filePath],
                repoPath, ct: ct);

            if (success && !string.IsNullOrWhiteSpace(stdout))
            {
                diff = stdout;
            }
            else
            {
                // Fallback to direct diff
                diff = await GitOperations.RunAsync(
                    ["diff", targetBranch, "HEAD", "--", filePath],
                    repoPath, ct: ct);
            }
        }
        catch (GitException ex)
        {
            return ToolHelpers.ToJson(new
            {
                file = changedFile,
                diff = (string?)null,
                error = $"Failed to generate diff: {ex.Message}",
            });
        }

        return ToolHelpers.ToJson(new
        {
            file = changedFile,
            diff,
        });
    }

    [McpServerTool, Description(
        "List all comment threads (remote and local drafts) in the current review, " +
        "optionally filtered by file path.")]
    public static string ListCommentThreads(
        ReviewService reviewService,
        SessionService sessionService,
        [Description("The pull request URL")] string prUrl,
        [Description("Optional: filter threads to a specific file path. Omit to get all threads.")] string? filePath = null)
    {
        var threads = reviewService.GetThreads(prUrl, filePath);
        if (threads == null)
            return ToolHelpers.ToJson(new { error = "No session found for this PR." });

        // Also include draft comments for context
        var sessionId = ToolHelpers.ResolveSessionId(prUrl);
        var drafts = sessionService.GetDrafts(sessionId, filePath);

        return ToolHelpers.ToJson(new
        {
            thread_count = threads.Count,
            draft_count = drafts.Count,
            threads,
            drafts = drafts.Select(kvp => new
            {
                id = kvp.Key,
                draft = kvp.Value,
            }),
        });
    }
}
