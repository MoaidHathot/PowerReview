using System.CommandLine;
using System.Text.Json;
using PowerReview.Core.Configuration;
using PowerReview.Core.Models;
using PowerReview.Core.Services;

namespace PowerReview.Cli.Commands;

/// <summary>
/// Builds all CLI commands for the powerreview tool.
/// </summary>
internal static class CommandBuilder
{
    internal static RootCommand Build(ServiceFactory services)
    {
        var root = new RootCommand("PowerReview — PR review management CLI tool");

        root.Subcommands.Add(BuildOpen(services));
        root.Subcommands.Add(BuildSession(services));
        root.Subcommands.Add(BuildFiles(services));
        root.Subcommands.Add(BuildDiff(services));
        root.Subcommands.Add(BuildThreads(services));
        root.Subcommands.Add(BuildThreadStatus(services));
        root.Subcommands.Add(BuildComment(services));
        root.Subcommands.Add(BuildReply(services));
        root.Subcommands.Add(BuildSubmit(services));
        root.Subcommands.Add(BuildVote(services));
        root.Subcommands.Add(BuildSync(services));
        root.Subcommands.Add(BuildClose(services));
        root.Subcommands.Add(BuildSessions(services));
        root.Subcommands.Add(BuildConfig(services));

        return root;
    }

    // --- Shared options ---

    private static Option<string> PrUrlOption(bool required = true) => new("--pr-url")
    {
        Description = "The pull request URL",
        Required = required,
    };

    private static Option<string> SessionIdOption() => new("--session-id")
    {
        Description = "The session ID (alternative to --pr-url)",
    };

    // --- open ---

    private static Command BuildOpen(ServiceFactory services)
    {
        var prUrl = PrUrlOption();
        var repoPath = new Option<string?>("--repo-path")
        {
            Description = "Path to an existing local git repository",
        };
        var autoClone = new Option<bool>("--auto-clone")
        {
            Description = "Automatically clone the repository if the repo path doesn't exist",
        };

        var cmd = new Command("open", "Open a review for a pull request. Fetches PR data, sets up git, creates/resumes session.")
        {
            prUrl, repoPath, autoClone
        };

        cmd.SetAction(async (parseResult, ct) =>
        {
            var url = parseResult.GetValue(prUrl)!;
            var repo = parseResult.GetValue(repoPath);
            var clone = parseResult.GetValue(autoClone);

            try
            {
                var session = await services.ReviewService.OpenAsync(url, repo, clone, ct);
                var sessionFilePath = services.Store.GetSessionPath(session.Id);
                CliOutput.WriteJson(new { session_file_path = sessionFilePath, session });
            }
            catch (ReviewServiceException ex)
            {
                return CliOutput.WriteError(ex.Message);
            }
            catch (Exception ex)
            {
                return CliOutput.WriteError(ex.Message);
            }
            return 0;
        });

        return cmd;
    }

    // --- session ---

    private static Command BuildSession(ServiceFactory services)
    {
        var prUrl = PrUrlOption();
        var ifModifiedSince = new Option<string?>("--if-modified-since")
        {
            Description = "Only return session if updated after this ISO timestamp",
        };
        var pathOnly = new Option<bool>("--path-only")
        {
            Description = "Only output the session file path",
        };

        var cmd = new Command("session", "Get session info for a PR. No auth required.")
        {
            prUrl, ifModifiedSince, pathOnly
        };

        cmd.SetAction(parseResult =>
        {
            var url = parseResult.GetValue(prUrl)!;
            var since = parseResult.GetValue(ifModifiedSince);
            var onlyPath = parseResult.GetValue(pathOnly);

            try
            {
                var result = services.ReviewService.GetSession(url, since);
                if (result == null)
                {
                    // Not found or not modified — empty output, exit 0
                    CliOutput.WriteJson(new { found = false });
                    return 0;
                }

                if (onlyPath)
                {
                    CliOutput.WriteJson(new { path = result.Path });
                }
                else
                {
                    CliOutput.WriteJson(result.Session);
                }
            }
            catch (ReviewServiceException ex)
            {
                return CliOutput.WriteError(ex.Message);
            }
            return 0;
        });

        return cmd;
    }

    // --- files ---

    private static Command BuildFiles(ServiceFactory services)
    {
        var prUrl = PrUrlOption();
        var cmd = new Command("files", "List changed files in a PR session. No auth required.")
        {
            prUrl
        };

        cmd.SetAction(parseResult =>
        {
            var url = parseResult.GetValue(prUrl)!;
            try
            {
                var files = services.ReviewService.GetFiles(url);
                if (files == null)
                    return CliOutput.WriteError("No session found for this PR.");
                CliOutput.WriteJson(files);
            }
            catch (ReviewServiceException ex)
            {
                return CliOutput.WriteError(ex.Message);
            }
            return 0;
        });

        return cmd;
    }

    // --- diff ---

    private static Command BuildDiff(ServiceFactory services)
    {
        var prUrl = PrUrlOption();
        var file = new Option<string>("--file")
        {
            Description = "File path to get diff info for",
            Required = true,
        };

        var cmd = new Command("diff", "Get diff info for a file in a PR session. No auth required.")
        {
            prUrl, file
        };

        cmd.SetAction(parseResult =>
        {
            var url = parseResult.GetValue(prUrl)!;
            var filePath = parseResult.GetValue(file)!;
            try
            {
                var result = services.ReviewService.GetFileDiff(url, filePath);
                if (result == null)
                    return CliOutput.WriteError("File not found in session.");
                CliOutput.WriteJson(result);
            }
            catch (ReviewServiceException ex)
            {
                return CliOutput.WriteError(ex.Message);
            }
            return 0;
        });

        return cmd;
    }

    // --- threads ---

    private static Command BuildThreads(ServiceFactory services)
    {
        var prUrl = PrUrlOption();
        var file = new Option<string?>("--file")
        {
            Description = "Filter threads by file path",
        };

        var cmd = new Command("threads", "List comment threads in a PR session. No auth required.")
        {
            prUrl, file
        };

        cmd.SetAction(parseResult =>
        {
            var url = parseResult.GetValue(prUrl)!;
            var filePath = parseResult.GetValue(file);
            try
            {
                var threads = services.ReviewService.GetThreads(url, filePath);
                if (threads == null)
                    return CliOutput.WriteError("No session found for this PR.");
                CliOutput.WriteJson(threads);
            }
            catch (ReviewServiceException ex)
            {
                return CliOutput.WriteError(ex.Message);
            }
            return 0;
        });

        return cmd;
    }

    // --- thread-status ---

    private static Command BuildThreadStatus(ServiceFactory services)
    {
        var prUrl = PrUrlOption();
        var threadIdOpt = new Option<int>("--thread-id")
        {
            Description = "The remote thread ID to update",
            Required = true,
        };
        var statusOpt = new Option<string>("--status")
        {
            Description = "New thread status: active, fixed, wontfix, closed, bydesign, pending",
            Required = true,
        };

        var cmd = new Command("thread-status", "Update the status of a comment thread. Auth required.")
        {
            prUrl, threadIdOpt, statusOpt
        };

        cmd.SetAction(async (parseResult, ct) =>
        {
            var url = parseResult.GetValue(prUrl)!;
            var threadId = parseResult.GetValue(threadIdOpt);
            var statusStr = parseResult.GetValue(statusOpt)!;

            var threadStatus = ParseThreadStatus(statusStr);
            if (threadStatus == null)
                return CliOutput.WriteUsageError(
                    $"Invalid thread status: '{statusStr}'. Use: active, fixed, wontfix, closed, bydesign, pending");

            try
            {
                var result = await services.ReviewService.UpdateThreadStatusAsync(url, threadId, threadStatus.Value, ct);
                CliOutput.WriteJson(new { thread_id = threadId, status = statusStr, thread = result });
            }
            catch (ReviewServiceException ex)
            {
                return CliOutput.WriteError(ex.Message);
            }
            catch (Exception ex)
            {
                return CliOutput.WriteError(ex.Message);
            }
            return 0;
        });

        return cmd;
    }

    // --- comment (subcommands: create, edit, delete, approve, approve-all, unapprove) ---

    private static Command BuildComment(ServiceFactory services)
    {
        var cmd = new Command("comment", "Manage draft comments. No auth required.");

        cmd.Subcommands.Add(BuildCommentCreate(services));
        cmd.Subcommands.Add(BuildCommentEdit(services));
        cmd.Subcommands.Add(BuildCommentDelete(services));
        cmd.Subcommands.Add(BuildCommentApprove(services));
        cmd.Subcommands.Add(BuildCommentApproveAll(services));
        cmd.Subcommands.Add(BuildCommentUnapprove(services));

        return cmd;
    }

    private static Command BuildCommentCreate(ServiceFactory services)
    {
        var prUrl = PrUrlOption();
        var filePath = new Option<string?>("--file") { Description = "File path for the comment" };
        var lineStart = new Option<int?>("--line-start") { Description = "Starting line number" };
        var lineEnd = new Option<int?>("--line-end") { Description = "Ending line number (for range comments)" };
        var colStart = new Option<int?>("--col-start") { Description = "Starting column" };
        var colEnd = new Option<int?>("--col-end") { Description = "Ending column" };
        var body = new Option<string?>("--body") { Description = "Comment body text" };
        var bodyStdin = new Option<bool>("--body-stdin") { Description = "Read comment body from stdin" };
        var author = new Option<string?>("--author") { Description = "Author type: 'user' or 'ai' (default: user)" };
        var threadId = new Option<int?>("--thread-id") { Description = "Reply to existing thread (thread ID)" };
        var parentCommentId = new Option<int?>("--parent-comment-id") { Description = "Parent comment ID for nested replies" };

        var cmd = new Command("create", "Create a new draft comment")
        {
            prUrl, filePath, lineStart, lineEnd, colStart, colEnd,
            body, bodyStdin, author, threadId, parentCommentId
        };

        cmd.SetAction(parseResult =>
        {
            var url = parseResult.GetValue(prUrl)!;
            var useStdin = parseResult.GetValue(bodyStdin);

            var commentBody = parseResult.GetValue(body);
            if (useStdin)
            {
                commentBody = Console.In.ReadToEnd().TrimEnd();
            }

            var authorStr = parseResult.GetValue(author);
            DraftAuthor? draftAuthor = authorStr?.ToLowerInvariant() switch
            {
                "ai" => DraftAuthor.Ai,
                "user" => DraftAuthor.User,
                null => null,
                _ => DraftAuthor.User,
            };

            try
            {
                var sessionId = ResolveSessionId(services, url);
                var (id, draft) = services.SessionService.CreateDraft(sessionId, new CreateDraftRequest
                {
                    FilePath = parseResult.GetValue(filePath),
                    LineStart = parseResult.GetValue(lineStart),
                    LineEnd = parseResult.GetValue(lineEnd),
                    ColStart = parseResult.GetValue(colStart),
                    ColEnd = parseResult.GetValue(colEnd),
                    Body = commentBody,
                    Author = draftAuthor,
                    ThreadId = parseResult.GetValue(threadId),
                    ParentCommentId = parseResult.GetValue(parentCommentId),
                });

                CliOutput.WriteJson(new { id, draft });
            }
            catch (SessionServiceException ex)
            {
                return CliOutput.WriteError(ex.Message);
            }
            catch (ReviewServiceException ex)
            {
                return CliOutput.WriteError(ex.Message);
            }
            return 0;
        });

        return cmd;
    }

    private static Command BuildCommentEdit(ServiceFactory services)
    {
        var prUrl = PrUrlOption();
        var draftId = new Option<string>("--draft-id") { Description = "Draft comment ID", Required = true };
        var body = new Option<string?>("--body") { Description = "New comment body text" };
        var bodyStdin = new Option<bool>("--body-stdin") { Description = "Read new body from stdin" };

        var cmd = new Command("edit", "Edit an existing draft comment's body")
        {
            prUrl, draftId, body, bodyStdin
        };

        cmd.SetAction(parseResult =>
        {
            var url = parseResult.GetValue(prUrl)!;
            var id = parseResult.GetValue(draftId)!;
            var useStdin = parseResult.GetValue(bodyStdin);

            var newBody = parseResult.GetValue(body);
            if (useStdin)
            {
                newBody = Console.In.ReadToEnd().TrimEnd();
            }

            if (newBody == null)
                return CliOutput.WriteUsageError("Provide --body or --body-stdin");

            try
            {
                var sessionId = ResolveSessionId(services, url);
                var draft = services.SessionService.EditDraft(sessionId, id, newBody);
                CliOutput.WriteJson(new { id, draft });
            }
            catch (SessionServiceException ex)
            {
                return CliOutput.WriteError(ex.Message);
            }
            return 0;
        });

        return cmd;
    }

    private static Command BuildCommentDelete(ServiceFactory services)
    {
        var prUrl = PrUrlOption();
        var draftId = new Option<string>("--draft-id") { Description = "Draft comment ID", Required = true };

        var cmd = new Command("delete", "Delete a draft comment")
        {
            prUrl, draftId
        };

        cmd.SetAction(parseResult =>
        {
            var url = parseResult.GetValue(prUrl)!;
            var id = parseResult.GetValue(draftId)!;

            try
            {
                var sessionId = ResolveSessionId(services, url);
                services.SessionService.DeleteDraft(sessionId, id);
                CliOutput.WriteJson(new { deleted = true, id });
            }
            catch (SessionServiceException ex)
            {
                return CliOutput.WriteError(ex.Message);
            }
            return 0;
        });

        return cmd;
    }

    private static Command BuildCommentApprove(ServiceFactory services)
    {
        var prUrl = PrUrlOption();
        var draftId = new Option<string>("--draft-id") { Description = "Draft comment ID", Required = true };

        var cmd = new Command("approve", "Approve a draft comment (draft -> pending)")
        {
            prUrl, draftId
        };

        cmd.SetAction(parseResult =>
        {
            var url = parseResult.GetValue(prUrl)!;
            var id = parseResult.GetValue(draftId)!;

            try
            {
                var sessionId = ResolveSessionId(services, url);
                var draft = services.SessionService.ApproveDraft(sessionId, id);
                CliOutput.WriteJson(new { id, draft });
            }
            catch (SessionServiceException ex)
            {
                return CliOutput.WriteError(ex.Message);
            }
            return 0;
        });

        return cmd;
    }

    private static Command BuildCommentApproveAll(ServiceFactory services)
    {
        var prUrl = PrUrlOption();

        var cmd = new Command("approve-all", "Approve all draft comments (draft -> pending)")
        {
            prUrl
        };

        cmd.SetAction(parseResult =>
        {
            var url = parseResult.GetValue(prUrl)!;

            try
            {
                var sessionId = ResolveSessionId(services, url);
                var count = services.SessionService.ApproveAllDrafts(sessionId);
                CliOutput.WriteJson(new { approved = count });
            }
            catch (SessionServiceException ex)
            {
                return CliOutput.WriteError(ex.Message);
            }
            return 0;
        });

        return cmd;
    }

    private static Command BuildCommentUnapprove(ServiceFactory services)
    {
        var prUrl = PrUrlOption();
        var draftId = new Option<string>("--draft-id") { Description = "Draft comment ID", Required = true };

        var cmd = new Command("unapprove", "Unapprove a draft comment (pending -> draft)")
        {
            prUrl, draftId
        };

        cmd.SetAction(parseResult =>
        {
            var url = parseResult.GetValue(prUrl)!;
            var id = parseResult.GetValue(draftId)!;

            try
            {
                var sessionId = ResolveSessionId(services, url);
                var draft = services.SessionService.UnapproveDraft(sessionId, id);
                CliOutput.WriteJson(new { id, draft });
            }
            catch (SessionServiceException ex)
            {
                return CliOutput.WriteError(ex.Message);
            }
            return 0;
        });

        return cmd;
    }

    // --- reply ---

    private static Command BuildReply(ServiceFactory services)
    {
        var prUrl = PrUrlOption();
        var threadIdOpt = new Option<int>("--thread-id") { Description = "Remote thread ID to reply to", Required = true };
        var body = new Option<string?>("--body") { Description = "Reply body text" };
        var bodyStdin = new Option<bool>("--body-stdin") { Description = "Read reply body from stdin" };
        var author = new Option<string?>("--author") { Description = "Author type: 'user' or 'ai' (default: user)" };

        var cmd = new Command("reply", "Create a reply draft to an existing thread. No auth required.")
        {
            prUrl, threadIdOpt, body, bodyStdin, author
        };

        cmd.SetAction(parseResult =>
        {
            var url = parseResult.GetValue(prUrl)!;
            var tid = parseResult.GetValue(threadIdOpt);
            var useStdin = parseResult.GetValue(bodyStdin);

            var replyBody = parseResult.GetValue(body);
            if (useStdin)
            {
                replyBody = Console.In.ReadToEnd().TrimEnd();
            }

            var authorStr = parseResult.GetValue(author);
            DraftAuthor? draftAuthor = authorStr?.ToLowerInvariant() switch
            {
                "ai" => DraftAuthor.Ai,
                "user" => DraftAuthor.User,
                null => null,
                _ => DraftAuthor.User,
            };

            try
            {
                var sessionId = ResolveSessionId(services, url);
                var (id, draft) = services.SessionService.CreateDraft(sessionId, new CreateDraftRequest
                {
                    Body = replyBody,
                    ThreadId = tid,
                    Author = draftAuthor,
                });

                CliOutput.WriteJson(new { id, draft });
            }
            catch (SessionServiceException ex)
            {
                return CliOutput.WriteError(ex.Message);
            }
            return 0;
        });

        return cmd;
    }

    // --- submit ---

    private static Command BuildSubmit(ServiceFactory services)
    {
        var prUrl = PrUrlOption();
        var cmd = new Command("submit", "Submit all pending draft comments to the remote provider. Auth required.")
        {
            prUrl
        };

        cmd.SetAction(async (parseResult, ct) =>
        {
            var url = parseResult.GetValue(prUrl)!;
            try
            {
                var result = await services.ReviewService.SubmitAsync(url, ct);
                CliOutput.WriteJson(result);
                return result.Failed > 0 ? 1 : 0;
            }
            catch (ReviewServiceException ex)
            {
                return CliOutput.WriteError(ex.Message);
            }
            catch (Exception ex)
            {
                return CliOutput.WriteError(ex.Message);
            }
        });

        return cmd;
    }

    // --- vote ---

    private static Command BuildVote(ServiceFactory services)
    {
        var prUrl = PrUrlOption();
        var value = new Option<string>("--value")
        {
            Description = "Vote value: approve, approve-with-suggestions, no-vote, wait-for-author, reject",
            Required = true,
        };

        var cmd = new Command("vote", "Set your review vote on the PR. Auth required.")
        {
            prUrl, value
        };

        cmd.SetAction(async (parseResult, ct) =>
        {
            var url = parseResult.GetValue(prUrl)!;
            var voteStr = parseResult.GetValue(value)!;

            var voteValue = ParseVoteValue(voteStr);
            if (voteValue == null)
                return CliOutput.WriteUsageError(
                    $"Invalid vote value: '{voteStr}'. Use: approve, approve-with-suggestions, no-vote, wait-for-author, reject");

            try
            {
                await services.ReviewService.VoteAsync(url, voteValue.Value, ct);
                CliOutput.WriteJson(new { voted = true, vote = voteStr });
            }
            catch (ReviewServiceException ex)
            {
                return CliOutput.WriteError(ex.Message);
            }
            catch (Exception ex)
            {
                return CliOutput.WriteError(ex.Message);
            }
            return 0;
        });

        return cmd;
    }

    // --- sync ---

    private static Command BuildSync(ServiceFactory services)
    {
        var prUrl = PrUrlOption();
        var cmd = new Command("sync", "Sync threads from the remote provider. Auth required.")
        {
            prUrl
        };

        cmd.SetAction(async (parseResult, ct) =>
        {
            var url = parseResult.GetValue(prUrl)!;
            try
            {
                var count = await services.ReviewService.SyncAsync(url, ct);
                CliOutput.WriteJson(new { synced = true, thread_count = count });
            }
            catch (ReviewServiceException ex)
            {
                return CliOutput.WriteError(ex.Message);
            }
            catch (Exception ex)
            {
                return CliOutput.WriteError(ex.Message);
            }
            return 0;
        });

        return cmd;
    }

    // --- close ---

    private static Command BuildClose(ServiceFactory services)
    {
        var prUrl = PrUrlOption();
        var cmd = new Command("close", "Close a review session. Cleans up git worktree if configured. No auth required.")
        {
            prUrl
        };

        cmd.SetAction(async (parseResult, ct) =>
        {
            var url = parseResult.GetValue(prUrl)!;
            try
            {
                await services.ReviewService.CloseAsync(url, ct);
                CliOutput.WriteJson(new { closed = true });
            }
            catch (ReviewServiceException ex)
            {
                return CliOutput.WriteError(ex.Message);
            }
            catch (Exception ex)
            {
                return CliOutput.WriteError(ex.Message);
            }
            return 0;
        });

        return cmd;
    }

    // --- sessions (subcommands: list, delete, clean) ---

    private static Command BuildSessions(ServiceFactory services)
    {
        var cmd = new Command("sessions", "Manage saved sessions");

        cmd.Subcommands.Add(BuildSessionsList(services));
        cmd.Subcommands.Add(BuildSessionsDelete(services));
        cmd.Subcommands.Add(BuildSessionsClean(services));

        return cmd;
    }

    private static Command BuildSessionsList(ServiceFactory services)
    {
        var cmd = new Command("list", "List all saved sessions");

        cmd.SetAction(_ =>
        {
            var summaries = services.Store.List();
            CliOutput.WriteJson(summaries);
            return 0;
        });

        return cmd;
    }

    private static Command BuildSessionsDelete(ServiceFactory services)
    {
        var sessionId = new Option<string>("--session-id")
        {
            Description = "Session ID to delete",
            Required = true,
        };

        var cmd = new Command("delete", "Delete a specific session")
        {
            sessionId
        };

        cmd.SetAction(parseResult =>
        {
            var id = parseResult.GetValue(sessionId)!;
            var deleted = services.Store.Delete(id);
            CliOutput.WriteJson(new { deleted, session_id = id });
            return 0;
        });

        return cmd;
    }

    private static Command BuildSessionsClean(ServiceFactory services)
    {
        var cmd = new Command("clean", "Delete all saved sessions");

        cmd.SetAction(_ =>
        {
            var count = services.Store.Clean();
            CliOutput.WriteJson(new { cleaned = count });
            return 0;
        });

        return cmd;
    }

    // --- config ---

    private static Command BuildConfig(ServiceFactory services)
    {
        var pathOnly = new Option<bool>("--path-only")
        {
            Description = "Only output the config file path",
        };

        var cmd = new Command("config", "Show configuration. No auth required.")
        {
            pathOnly
        };

        cmd.SetAction(parseResult =>
        {
            var onlyPath = parseResult.GetValue(pathOnly);
            if (onlyPath)
            {
                CliOutput.WriteJson(new { path = ConfigLoader.GetConfigFilePath() });
            }
            else
            {
                CliOutput.WriteJson(services.Config);
            }
            return 0;
        });

        return cmd;
    }

    // --- Helpers ---

    /// <summary>
    /// Resolve a PR URL to a session ID.
    /// </summary>
    private static string ResolveSessionId(ServiceFactory services, string prUrl)
    {
        var parsed = UrlParser.Parse(prUrl)
            ?? throw new ReviewServiceException($"Could not parse PR URL: {prUrl}");

        return Core.Models.ReviewSession.ComputeId(
            parsed.ProviderType,
            parsed.Organization,
            parsed.Project,
            parsed.Repository,
            parsed.PrId);
    }

    private static VoteValue? ParseVoteValue(string value)
    {
        return value.ToLowerInvariant() switch
        {
            "approve" or "approved" => VoteValue.Approve,
            "approve-with-suggestions" or "approved-with-suggestions" => VoteValue.ApproveWithSuggestions,
            "no-vote" or "novote" or "none" or "reset" => VoteValue.NoVote,
            "wait-for-author" or "wait" => VoteValue.WaitForAuthor,
            "reject" or "rejected" => VoteValue.Reject,
            _ => null,
        };
    }

    private static ThreadStatus? ParseThreadStatus(string value)
    {
        return value.ToLowerInvariant() switch
        {
            "active" => ThreadStatus.Active,
            "fixed" or "resolved" => ThreadStatus.Fixed,
            "wontfix" or "wont-fix" or "won't fix" => ThreadStatus.WontFix,
            "closed" => ThreadStatus.Closed,
            "bydesign" or "by-design" => ThreadStatus.ByDesign,
            "pending" => ThreadStatus.Pending,
            _ => null,
        };
    }
}
