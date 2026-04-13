using System.ComponentModel;
using ModelContextProtocol.Server;
using PowerReview.Core.Git;
using PowerReview.Core.Models;
using PowerReview.Core.Services;

namespace PowerReview.Cli.Mcp;

/// <summary>
/// MCP tools for read-only review operations: session info, files, diff, threads,
/// working directory access, file reading, and repository file listing.
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
        "Get the full pull request description, title, metadata, reviewers, labels, and work items. " +
        "Returns the complete PR context useful for understanding what the PR is about.")]
    public static string GetPullRequestDescription(
        ReviewService reviewService,
        [Description("The pull request URL")] string prUrl)
    {
        var result = reviewService.GetSession(prUrl);
        if (result == null)
            return ToolHelpers.ToJson(new { error = "No session found for this PR." });

        var pr = result.Session.PullRequest;
        return ToolHelpers.ToJson(new
        {
            title = pr.Title,
            description = pr.Description,
            author = new { name = pr.Author.Name, id = pr.Author.Id },
            source_branch = pr.SourceBranch,
            target_branch = pr.TargetBranch,
            status = pr.Status.ToString(),
            is_draft = pr.IsDraft,
            merge_status = pr.MergeStatus?.ToString(),
            created_at = pr.CreatedAt,
            closed_at = pr.ClosedAt,
            reviewers = pr.Reviewers.Select(r => new
            {
                name = r.Name,
                vote = r.Vote,
                is_required = r.IsRequired,
            }),
            labels = pr.Labels,
            work_items = pr.WorkItems.Select(w => new
            {
                id = w.Id,
                title = w.Title,
                url = w.Url,
            }),
        });
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

    [McpServerTool, Description(
        "Get a summary of draft comment counts by status (draft, pending, submitted). " +
        "Useful for understanding the current state of the review before creating more drafts.")]
    public static string GetDraftCounts(
        SessionService sessionService,
        [Description("The pull request URL")] string prUrl)
    {
        try
        {
            var sessionId = ToolHelpers.ResolveSessionId(prUrl);
            var counts = sessionService.GetDraftCounts(sessionId);

            return ToolHelpers.ToJson(new
            {
                counts.Draft,
                counts.Pending,
                counts.Submitted,
                counts.Total,
            });
        }
        catch (Exception ex)
        {
            return ToolHelpers.ToJson(new { error = ex.Message });
        }
    }

    // ========================================================================
    // Working directory and file access tools
    // ========================================================================

    [McpServerTool, Description(
        "Get the filesystem path to the working directory for a PR review. " +
        "This is the git worktree (or repo checkout) where the full source code can be read. " +
        "Use this to locate the repository on disk for reading files beyond the PR diff.")]
    public static string GetWorkingDirectory(
        ReviewService reviewService,
        [Description("The pull request URL")] string prUrl)
    {
        var result = reviewService.GetSession(prUrl);
        if (result == null)
            return ToolHelpers.ToJson(new { error = "No session found for this PR. Run 'powerreview open --pr-url <url>' first." });

        var session = result.Session;
        var workingDir = session.Git.WorktreePath ?? session.Git.RepoPath;

        if (string.IsNullOrEmpty(workingDir))
            return ToolHelpers.ToJson(new { error = "No local git repository is available for this session. The review was opened without a repo path." });

        return ToolHelpers.ToJson(new
        {
            path = workingDir,
            strategy = session.Git.Strategy.ToString(),
            repo_path = session.Git.RepoPath,
        });
    }

    [McpServerTool, Description(
        "Read the contents of a file from the PR working directory. " +
        "The file does not need to be in the changed files list — you can read any file in the repository. " +
        "Useful for understanding context, checking callers, reviewing types/interfaces, or reading test files. " +
        "Supports optional offset and limit for reading sections of large files.")]
    public static string ReadFile(
        ReviewService reviewService,
        [Description("The pull request URL")] string prUrl,
        [Description("Relative file path within the repository (e.g., 'src/Services/UserService.cs')")] string filePath,
        [Description("Line number to start reading from (1-indexed, default: 1)")] int? offset = null,
        [Description("Maximum number of lines to return (default: all lines)")] int? limit = null)
    {
        var result = reviewService.GetSession(prUrl);
        if (result == null)
            return ToolHelpers.ToJson(new { error = "No session found for this PR." });

        var session = result.Session;
        var workingDir = session.Git.WorktreePath ?? session.Git.RepoPath;

        if (string.IsNullOrEmpty(workingDir))
            return ToolHelpers.ToJson(new { error = "No local git repository available for this session." });

        var readResult = WorktreeFileService.ReadFile(workingDir, filePath, offset ?? 1, limit);

        if (readResult.IsError)
            return ToolHelpers.ToJson(new { error = readResult.ErrorMessage });

        return ToolHelpers.ToJson(new
        {
            path = readResult.Path,
            content = readResult.Content,
            total_lines = readResult.TotalLines,
            offset = readResult.Offset,
            limit = readResult.Limit,
        });
    }

    [McpServerTool, Description(
        "List files in the PR repository working directory. " +
        "Can list all files or filter by subdirectory and/or glob pattern. " +
        "Useful for discovering project structure and finding related files beyond the PR diff. " +
        "Set recursive to true to list all files recursively.")]
    public static string ListRepositoryFiles(
        ReviewService reviewService,
        [Description("The pull request URL")] string prUrl,
        [Description("Optional: subdirectory path to list (e.g., 'src/Services'). Omit to list from root.")] string? directory = null,
        [Description("Optional: glob pattern to filter files (e.g., '*.cs', '*.ts'). Omit to list all files.")] string? pattern = null,
        [Description("Whether to list files recursively (default: false). When true, lists all files in subdirectories.")] bool recursive = false)
    {
        var result = reviewService.GetSession(prUrl);
        if (result == null)
            return ToolHelpers.ToJson(new { error = "No session found for this PR." });

        var session = result.Session;
        var workingDir = session.Git.WorktreePath ?? session.Git.RepoPath;

        if (string.IsNullOrEmpty(workingDir))
            return ToolHelpers.ToJson(new { error = "No local git repository available for this session." });

        var listResult = WorktreeFileService.ListFiles(workingDir, directory, pattern, recursive);

        if (listResult.IsError)
            return ToolHelpers.ToJson(new { error = listResult.ErrorMessage });

        return ToolHelpers.ToJson(new
        {
            base_path = listResult.BasePath,
            count = listResult.Entries.Count,
            entries = listResult.Entries.Select(e => new
            {
                name = e.Name,
                type = e.Type,
                path = e.Path,
            }),
        });
    }

    // ========================================================================
    // Sync and iteration tools
    // ========================================================================

    [McpServerTool, Description(
        "Sync comment threads from the remote provider (e.g., Azure DevOps). " +
        "Updates the local session with the latest threads and checks for new iterations. " +
        "Call this before reading threads to ensure you have the most up-to-date data.")]
    public static async Task<string> SyncThreads(
        ReviewService reviewService,
        [Description("The pull request URL")] string prUrl,
        CancellationToken ct)
    {
        try
        {
            var result = await reviewService.SyncAsync(prUrl, ct);
            return ToolHelpers.ToJson(new
            {
                synced = true,
                thread_count = result.ThreadCount,
                iteration_check = result.IterationCheck,
            });
        }
        catch (ReviewServiceException ex)
        {
            return ToolHelpers.ToJson(new { error = ex.Message });
        }
    }

    [McpServerTool, Description(
        "Check whether the PR author has pushed new commits since your last review. " +
        "If a new iteration is detected, performs a smart reset: identifies which files changed, " +
        "removes them from the reviewed list, and updates the review baseline. " +
        "Returns the list of files that changed between iterations.")]
    public static async Task<string> CheckIteration(
        ReviewService reviewService,
        [Description("The pull request URL")] string prUrl,
        CancellationToken ct)
    {
        try
        {
            var result = await reviewService.CheckIterationAsync(prUrl, ct);
            return ToolHelpers.ToJson(result);
        }
        catch (ReviewServiceException ex)
        {
            return ToolHelpers.ToJson(new { error = ex.Message });
        }
    }

    [McpServerTool, Description(
        "Get the diff between the previously reviewed iteration and the current iteration for a specific file. " +
        "This shows only what changed since you last reviewed, not the full PR diff. " +
        "Requires that a review baseline exists (files must have been marked as reviewed previously).")]
    public static async Task<string> GetIterationDiff(
        ReviewService reviewService,
        [Description("The pull request URL")] string prUrl,
        [Description("Relative file path to get the iteration diff for")] string filePath,
        CancellationToken ct)
    {
        try
        {
            var diff = await reviewService.GetIterationDiffAsync(prUrl, filePath, ct);
            return ToolHelpers.ToJson(new { file = filePath, diff });
        }
        catch (ReviewServiceException ex)
        {
            return ToolHelpers.ToJson(new { error = ex.Message });
        }
    }
}
