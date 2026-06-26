using System.ComponentModel;
using ModelContextProtocol.Server;
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
                id = r.Id,
                unique_name = r.UniqueName,
                vote = r.Vote,
                vote_label = r.VoteLabel,
                is_required = r.IsRequired,
            }),
            labels = pr.Labels,
            work_items = pr.WorkItems.Select(w => new
            {
                id = w.Id,
                title = w.Title,
                url = w.Url,
                type = w.Type,
                state = w.State,
                tags = w.Tags,
                area_path = w.AreaPath,
                iteration_path = w.IterationPath,
            }),
            iteration = result.Session.Metadata.Iteration,
            metadata = result.Session.Metadata,
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
        try
        {
            var result = await reviewService.GetFileDiffWithPatchAsync(prUrl, filePath, ct);
            return ToolHelpers.ToJson(result);
        }
        catch (ReviewServiceException ex)
        {
            return ToolHelpers.ToJson(new { error = ex.Message });
        }
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
        var operations = sessionService.GetDraftOperations(sessionId, filePath);

        return ToolHelpers.ToJson(new
        {
            thread_count = threads.Count,
            draft_count = operations.Count,
            threads,
            draft_operations = operations.Select(kvp => new
            {
                id = kvp.Key,
                operation = kvp.Value,
            }),
        });
    }

    [McpServerTool, Description(
        "Get a summary of draft operation counts by status (draft, pending, submitted). " +
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
                counts.Comments,
                counts.Replies,
                counts.ThreadStatusChanges,
                counts.CommentReactions,
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
        "Also computes a reply-classification delta against the previous sync's snapshot " +
        "and returns a summary in `deltas`. Use `GetNewReplies` to fetch the full list " +
        "of new replies after this call. " +
        "Call this before reading threads to ensure you have the most up-to-date data.")]
    public static async Task<string> SyncThreads(
        ReviewService reviewService,
        [Description("The pull request URL")] string prUrl,
        CancellationToken ct)
    {
        return await McpError.GuardAsync(
            () => reviewService.SyncAsync(prUrl, ct),
            result => ToolHelpers.ToJson(new
            {
                synced = true,
                thread_count = result.ThreadCount,
                iteration_check = result.IterationCheck,
                // Counts only — call GetNewReplies to fetch the actual entries.
                // `null` deltas means this was the first sync after upgrade
                // ("silent priming"); no actionable replies were computed.
                deltas = result.Deltas == null ? null : new
                {
                    silent_priming = false,
                    reply_to_ai = result.Deltas.ReplyToAi.Count,
                    reply_to_human = result.Deltas.ReplyToHuman.Count,
                    reply_in_others_thread = result.Deltas.ReplyInOthersThread.Count,
                    new_thread_others = result.Deltas.NewThreadOthers.Count,
                },
                silent_priming = result.Deltas == null,
            }));
    }

    [McpServerTool, Description(
        "Get the new/edited comments since the previous sync, classified by who " +
        "they're addressed to. Always reads from the cached `last_deltas` " +
        "(populated by `SyncThreads`); does NOT hit the remote. " +
        "Scope values: " +
        "`to_ai` = replies on threads where AI participated (most relevant for AI follow-up); " +
        "`to_me` = `to_ai` + replies on threads the human user participated in (default); " +
        "`to_others` = replies and new threads with no local participation; " +
        "`all` = everything except self-echo; " +
        "`self_echo` = our own published drafts reflected back (debug). " +
        "Comments already covered by an `AcknowledgeReplies` watermark are suppressed.")]
    public static string GetNewReplies(
        ReviewService reviewService,
        [Description("The pull request URL")] string prUrl,
        [Description("Filter scope: to_ai, to_me (default), to_others, all, self_echo")] string? scope = null,
        [Description("Optional: limit to a single thread id")] int? threadId = null)
    {
        try
        {
            var result = reviewService.GetNewReplies(prUrl, scope ?? "to_me", threadId);
            return ToolHelpers.ToJson(result);
        }
        catch (ReviewServiceException ex)
        {
            return ToolHelpers.ToJson(new { error = ex.Message });
        }
    }

    [McpServerTool, Description(
        "Mark replies as acknowledged by advancing per-thread watermarks. " +
        "Comments with id <= through_comment_id on a given thread will be " +
        "suppressed from `GetNewReplies` and from the `deltas` summary on " +
        "subsequent syncs. Watermarks are monotonic — calling this with a " +
        "lower id than the existing watermark is a no-op for that thread. " +
        "Use this after the AI has either drafted a follow-up reply or has " +
        "explicitly decided to ignore the reply, so the same comment doesn't " +
        "keep appearing in `GetNewReplies` forever.")]
    public static string AcknowledgeReplies(
        SessionService sessionService,
        [Description("The pull request URL")] string prUrl,
        [Description("Pairs of thread id + through-comment id to acknowledge. " +
                     "Format: 'threadId:throughCommentId' separated by commas, " +
                     "e.g. '123:789,456:1011'. The `through_comment_id` is " +
                     "the highest comment id you have processed on that thread.")]
            string acks,
        [Description("Who is acknowledging: 'ai' (default for MCP) or 'human'")] string? ackedBy = null)
    {
        try
        {
            var sessionId = ToolHelpers.ResolveSessionId(prUrl);
            var parsed = ParseAckPairs(acks);
            if (parsed.Count == 0)
                return ToolHelpers.ToJson(new { error = "No valid ack pairs provided. Format: 'threadId:throughCommentId,threadId:throughCommentId'" });

            var changed = sessionService.AcknowledgeReplies(sessionId, parsed, ackedBy ?? "ai");
            return ToolHelpers.ToJson(new
            {
                acknowledged = changed,
                requested = parsed.Count,
                acked_by = ackedBy ?? "ai",
            });
        }
        catch (Exception ex)
        {
            return ToolHelpers.ToJson(new { error = ex.Message });
        }
    }

    /// <summary>
    /// Parse "threadId:throughCommentId,threadId:throughCommentId" into a list.
    /// Skips malformed pairs silently (best-effort parsing for the MCP wire
    /// format, which is a string for portability across MCP clients).
    /// </summary>
    private static List<(int ThreadId, int ThroughCommentId)> ParseAckPairs(string raw)
    {
        var result = new List<(int, int)>();
        if (string.IsNullOrWhiteSpace(raw)) return result;

        foreach (var pair in raw.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            var parts = pair.Split(':');
            if (parts.Length != 2) continue;
            if (!int.TryParse(parts[0].Trim(), out var threadId)) continue;
            if (!int.TryParse(parts[1].Trim(), out var through)) continue;
            result.Add((threadId, through));
        }
        return result;
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
        return await McpError.GuardAsync(
            () => reviewService.CheckIterationAsync(prUrl, ct),
            result => ToolHelpers.ToJson(result));
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
        return await McpError.GuardAsync(
            () => reviewService.GetIterationDiffAsync(prUrl, filePath, ct),
            diff => ToolHelpers.ToJson(new { file = filePath, diff }));
    }
}
