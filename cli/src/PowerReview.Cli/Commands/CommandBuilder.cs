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
        root.Subcommands.Add(BuildRefresh(services));
        root.Subcommands.Add(BuildClose(services));
        root.Subcommands.Add(BuildSessions(services));
        root.Subcommands.Add(BuildConfig(services));
        root.Subcommands.Add(BuildMarkReviewed(services));
        root.Subcommands.Add(BuildUnmarkReviewed(services));
        root.Subcommands.Add(BuildMarkAllReviewed(services));
        root.Subcommands.Add(BuildCheckIteration(services));
        root.Subcommands.Add(BuildIterationDiff(services));
        root.Subcommands.Add(BuildWorkingDir(services));
        root.Subcommands.Add(BuildReadFile(services));
        root.Subcommands.Add(BuildFileContent(services));
        root.Subcommands.Add(BuildUpdateDescription(services));
        root.Subcommands.Add(BuildFixWorktree(services));
        root.Subcommands.Add(BuildProposal(services));

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
                var result = await services.ReviewService.OpenAsync(url, repo, clone, ct);
                var sessionFilePath = services.Store.GetSessionPath(result.Session.Id);
                CliOutput.WriteJson(new { action = result.Action, session_file_path = sessionFilePath, session = result.Session });
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
        var format = new Option<string?>("--format")
        {
            Description = "Output format: patch (default) or metadata",
        };

        var cmd = new Command("diff", "Get the unified diff for a file in a PR session. No auth required.")
        {
            prUrl, file, format
        };

        cmd.SetAction(async (parseResult, ct) =>
        {
            var url = parseResult.GetValue(prUrl)!;
            var filePath = parseResult.GetValue(file)!;
            var outputFormat = (parseResult.GetValue(format) ?? "patch").Trim().ToLowerInvariant();

            if (outputFormat is not ("patch" or "metadata"))
                return CliOutput.WriteUsageError("Invalid diff format. Use: patch or metadata.");

            try
            {
                if (outputFormat == "metadata")
                {
                    var result = services.ReviewService.GetFileDiff(url, filePath);
                    if (result == null)
                        return CliOutput.WriteError("File not found in session.");
                    CliOutput.WriteJson(result);
                }
                else
                {
                    var result = await services.ReviewService.GetFileDiffWithPatchAsync(url, filePath, ct);
                    CliOutput.WriteJson(result);
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

    // --- comment (subcommands: create, edit, delete, delete-all, approve, approve-all, unapprove) ---

    private static Command BuildComment(ServiceFactory services)
    {
        var cmd = new Command("comment", "Manage draft comments. No auth required.");

        cmd.Subcommands.Add(BuildCommentCreate(services));
        cmd.Subcommands.Add(BuildCommentEdit(services));
        cmd.Subcommands.Add(BuildCommentDelete(services));
        cmd.Subcommands.Add(BuildCommentDeleteAll(services));
        cmd.Subcommands.Add(BuildCommentApprove(services));
        cmd.Subcommands.Add(BuildCommentApproveAll(services));
        cmd.Subcommands.Add(BuildCommentUnapprove(services));
        cmd.Subcommands.Add(BuildCommentUpdateRemote(services));
        cmd.Subcommands.Add(BuildCommentDeleteRemote(services));

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
        var authorName = new Option<string?>("--author-name") { Description = "Display name for the comment author (e.g. 'SecurityReviewer')" };
        var threadId = new Option<int?>("--thread-id") { Description = "Reply to existing thread (thread ID)" };
        var parentCommentId = new Option<int?>("--parent-comment-id") { Description = "Parent comment ID for nested replies" };

        var cmd = new Command("create", "Create a new draft comment")
        {
            prUrl, filePath, lineStart, lineEnd, colStart, colEnd,
            body, bodyStdin, author, authorName, threadId, parentCommentId
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
                    AuthorName = parseResult.GetValue(authorName),
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

    private static Command BuildCommentDeleteAll(ServiceFactory services)
    {
        var prUrl = PrUrlOption();
        var authorOpt = new Option<string?>("--author")
        {
            Description = "Filter by author: 'ai' or 'user'. Omit to delete all.",
        };

        var cmd = new Command("delete-all", "Delete all draft comments in 'draft' status. Optionally filter by author.")
        {
            prUrl, authorOpt
        };

        cmd.SetAction(parseResult =>
        {
            var url = parseResult.GetValue(prUrl)!;
            var authorStr = parseResult.GetValue(authorOpt);

            DraftAuthor? authorFilter = authorStr?.ToLowerInvariant() switch
            {
                "ai" => DraftAuthor.Ai,
                "user" => DraftAuthor.User,
                null => null,
                _ => null,
            };

            try
            {
                var sessionId = ResolveSessionId(services, url);
                var count = services.SessionService.DeleteAllDrafts(sessionId, authorFilter);
                CliOutput.WriteJson(new { deleted = count, author_filter = authorStr });
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

    private static Command BuildCommentUpdateRemote(ServiceFactory services)
    {
        var prUrl = PrUrlOption();
        var threadIdOpt = new Option<int>("--thread-id") { Description = "Remote thread ID", Required = true };
        var commentIdOpt = new Option<int>("--comment-id") { Description = "Remote comment ID", Required = true };
        var body = new Option<string?>("--body") { Description = "New comment body text" };
        var bodyStdin = new Option<bool>("--body-stdin") { Description = "Read new body from stdin" };

        var cmd = new Command("update-remote", "Update a published comment on the remote provider. Auth required.")
        {
            prUrl, threadIdOpt, commentIdOpt, body, bodyStdin
        };

        cmd.SetAction(async (parseResult, ct) =>
        {
            var url = parseResult.GetValue(prUrl)!;
            var threadId = parseResult.GetValue(threadIdOpt);
            var commentId = parseResult.GetValue(commentIdOpt);
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
                var result = await services.ReviewService.UpdateRemoteCommentAsync(url, threadId, commentId, newBody, ct);
                CliOutput.WriteJson(new { updated = true, thread_id = threadId, comment_id = commentId, comment = result });
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

    private static Command BuildCommentDeleteRemote(ServiceFactory services)
    {
        var prUrl = PrUrlOption();
        var threadIdOpt = new Option<int>("--thread-id") { Description = "Remote thread ID", Required = true };
        var commentIdOpt = new Option<int>("--comment-id") { Description = "Remote comment ID", Required = true };

        var cmd = new Command("delete-remote", "Delete a published comment from the remote provider. Auth required.")
        {
            prUrl, threadIdOpt, commentIdOpt
        };

        cmd.SetAction(async (parseResult, ct) =>
        {
            var url = parseResult.GetValue(prUrl)!;
            var threadId = parseResult.GetValue(threadIdOpt);
            var commentId = parseResult.GetValue(commentIdOpt);

            try
            {
                await services.ReviewService.DeleteRemoteCommentAsync(url, threadId, commentId, ct);
                CliOutput.WriteJson(new { deleted = true, thread_id = threadId, comment_id = commentId });
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

    // --- reply ---

    private static Command BuildReply(ServiceFactory services)
    {
        var prUrl = PrUrlOption();
        var threadIdOpt = new Option<int>("--thread-id") { Description = "Remote thread ID to reply to", Required = true };
        var body = new Option<string?>("--body") { Description = "Reply body text" };
        var bodyStdin = new Option<bool>("--body-stdin") { Description = "Read reply body from stdin" };
        var author = new Option<string?>("--author") { Description = "Author type: 'user' or 'ai' (default: user)" };
        var authorName = new Option<string?>("--author-name") { Description = "Display name for the comment author (e.g. 'SecurityReviewer')" };

        var cmd = new Command("reply", "Create a reply draft to an existing thread. No auth required.")
        {
            prUrl, threadIdOpt, body, bodyStdin, author, authorName
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
                    AuthorName = parseResult.GetValue(authorName),
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
                var result = await services.ReviewService.SyncAsync(url, ct);
                CliOutput.WriteJson(new
                {
                    synced = true,
                    thread_count = result.ThreadCount,
                    iteration_check = result.IterationCheck,
                });
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

    // --- refresh ---

    private static Command BuildRefresh(ServiceFactory services)
    {
        var prUrl = PrUrlOption();
        var cmd = new Command("refresh", "Refresh the session from the remote provider. Re-fetches PR metadata, files, and threads. Auth required.")
        {
            prUrl
        };

        cmd.SetAction(async (parseResult, ct) =>
        {
            var url = parseResult.GetValue(prUrl)!;
            try
            {
                var session = await services.ReviewService.RefreshAsync(url, ct);
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

    // --- mark-reviewed ---

    private static Command BuildMarkReviewed(ServiceFactory services)
    {
        var prUrl = PrUrlOption();
        var file = new Option<string>("--file")
        {
            Description = "File path to mark as reviewed",
            Required = true,
        };

        var cmd = new Command("mark-reviewed", "Mark a file as reviewed in the current iteration. No auth required.")
        {
            prUrl, file
        };

        cmd.SetAction(parseResult =>
        {
            var url = parseResult.GetValue(prUrl)!;
            var filePath = parseResult.GetValue(file)!;
            try
            {
                var review = services.ReviewService.MarkFileReviewed(url, filePath);
                CliOutput.WriteJson(new { marked = true, file = filePath, review });
            }
            catch (ReviewServiceException ex)
            {
                return CliOutput.WriteError(ex.Message);
            }
            return 0;
        });

        return cmd;
    }

    // --- unmark-reviewed ---

    private static Command BuildUnmarkReviewed(ServiceFactory services)
    {
        var prUrl = PrUrlOption();
        var file = new Option<string>("--file")
        {
            Description = "File path to unmark as reviewed",
            Required = true,
        };

        var cmd = new Command("unmark-reviewed", "Remove the reviewed mark from a file. No auth required.")
        {
            prUrl, file
        };

        cmd.SetAction(parseResult =>
        {
            var url = parseResult.GetValue(prUrl)!;
            var filePath = parseResult.GetValue(file)!;
            try
            {
                var review = services.ReviewService.UnmarkFileReviewed(url, filePath);
                CliOutput.WriteJson(new { unmarked = true, file = filePath, review });
            }
            catch (ReviewServiceException ex)
            {
                return CliOutput.WriteError(ex.Message);
            }
            return 0;
        });

        return cmd;
    }

    // --- mark-all-reviewed ---

    private static Command BuildMarkAllReviewed(ServiceFactory services)
    {
        var prUrl = PrUrlOption();

        var cmd = new Command("mark-all-reviewed", "Mark all changed files as reviewed. No auth required.")
        {
            prUrl
        };

        cmd.SetAction(parseResult =>
        {
            var url = parseResult.GetValue(prUrl)!;
            try
            {
                var review = services.ReviewService.MarkAllFilesReviewed(url);
                CliOutput.WriteJson(new { marked_all = true, review });
            }
            catch (ReviewServiceException ex)
            {
                return CliOutput.WriteError(ex.Message);
            }
            return 0;
        });

        return cmd;
    }

    // --- check-iteration ---

    private static Command BuildCheckIteration(ServiceFactory services)
    {
        var prUrl = PrUrlOption();

        var cmd = new Command("check-iteration", "Check for new iterations from the remote. Auth required.")
        {
            prUrl
        };

        cmd.SetAction(async (parseResult, ct) =>
        {
            var url = parseResult.GetValue(prUrl)!;
            try
            {
                var result = await services.ReviewService.CheckIterationAsync(url, ct);
                CliOutput.WriteJson(result);
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

    // --- iteration-diff ---

    private static Command BuildIterationDiff(ServiceFactory services)
    {
        var prUrl = PrUrlOption();
        var file = new Option<string>("--file")
        {
            Description = "File path to get iteration diff for",
            Required = true,
        };

        var cmd = new Command("iteration-diff", "Get diff between iterations for a file. No auth required.")
        {
            prUrl, file
        };

        cmd.SetAction(async (parseResult, ct) =>
        {
            var url = parseResult.GetValue(prUrl)!;
            var filePath = parseResult.GetValue(file)!;
            try
            {
                var diff = await services.ReviewService.GetIterationDiffAsync(url, filePath, ct);
                CliOutput.WriteJson(new { file = filePath, diff });
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

    // --- working-dir ---

    private static Command BuildWorkingDir(ServiceFactory services)
    {
        var prUrl = PrUrlOption();
        var cmd = new Command("working-dir", "Get the filesystem path to the working directory for a PR review. No auth required.")
        {
            prUrl
        };

        cmd.SetAction(parseResult =>
        {
            var url = parseResult.GetValue(prUrl)!;
            try
            {
                var result = services.ReviewService.GetSession(url);
                if (result == null)
                    return CliOutput.WriteError("No session found for this PR.");

                var session = result.Session;
                var workingDir = session.Git.WorktreePath ?? session.Git.RepoPath;

                if (string.IsNullOrEmpty(workingDir))
                    return CliOutput.WriteError("No local git repository available for this session.");

                CliOutput.WriteJson(new
                {
                    path = workingDir,
                    strategy = session.Git.Strategy.ToString(),
                    repo_path = session.Git.RepoPath,
                });
            }
            catch (ReviewServiceException ex)
            {
                return CliOutput.WriteError(ex.Message);
            }
            return 0;
        });

        return cmd;
    }

    // --- read-file ---

    private static Command BuildReadFile(ServiceFactory services)
    {
        var prUrl = PrUrlOption();
        var file = new Option<string>("--file")
        {
            Description = "Relative file path within the repository",
            Required = true,
        };
        var offset = new Option<int?>("--offset")
        {
            Description = "Line number to start reading from (1-indexed, default: 1)",
        };
        var limit = new Option<int?>("--limit")
        {
            Description = "Maximum number of lines to return (default: all)",
        };

        var cmd = new Command("read-file", "Read the contents of a file from the PR working directory. No auth required.")
        {
            prUrl, file, offset, limit
        };

        cmd.SetAction(parseResult =>
        {
            var url = parseResult.GetValue(prUrl)!;
            var filePath = parseResult.GetValue(file)!;
            var lineOffset = parseResult.GetValue(offset);
            var lineLimit = parseResult.GetValue(limit);

            try
            {
                var result = services.ReviewService.GetSession(url);
                if (result == null)
                    return CliOutput.WriteError("No session found for this PR.");

                var session = result.Session;
                var workingDir = session.Git.WorktreePath ?? session.Git.RepoPath;

                if (string.IsNullOrEmpty(workingDir))
                    return CliOutput.WriteError("No local git repository available for this session.");

                var readResult = WorktreeFileService.ReadFile(workingDir, filePath, lineOffset ?? 1, lineLimit);

                if (readResult.IsError)
                    return CliOutput.WriteError(readResult.ErrorMessage!);

                CliOutput.WriteJson(new
                {
                    path = readResult.Path,
                    content = readResult.Content,
                    total_lines = readResult.TotalLines,
                    offset = readResult.Offset,
                    limit = readResult.Limit,
                });
            }
            catch (ReviewServiceException ex)
            {
                return CliOutput.WriteError(ex.Message);
            }
            return 0;
        });

        return cmd;
    }

    // --- file-content ---

    private static Command BuildFileContent(ServiceFactory services)
    {
        var prUrl = PrUrlOption();
        var file = new Option<string>("--file")
        {
            Description = "Relative file path within the repository",
            Required = true,
        };
        var branch = new Option<string>("--branch")
        {
            Description = "Branch to read from (e.g. 'main', 'feature/xyz'). Uses the target branch by default.",
            Required = true,
        };

        var cmd = new Command("file-content", "Read the content of a file at a specific branch from the remote provider. Auth required.")
        {
            prUrl, file, branch
        };

        cmd.SetAction(async (parseResult, ct) =>
        {
            var url = parseResult.GetValue(prUrl)!;
            var filePath = parseResult.GetValue(file)!;
            var branchName = parseResult.GetValue(branch)!;

            try
            {
                var content = await services.ReviewService.GetFileContentAsync(url, filePath, branchName, ct);
                CliOutput.WriteJson(new { file = filePath, branch = branchName, content });
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

    // --- update-description ---

    private static Command BuildUpdateDescription(ServiceFactory services)
    {
        var prUrl = PrUrlOption();
        var body = new Option<string?>("--body") { Description = "New PR description body text" };
        var bodyStdin = new Option<bool>("--body-stdin") { Description = "Read description body from stdin" };

        var cmd = new Command("update-description", "Update the PR description on the remote provider. Auth required.")
        {
            prUrl, body, bodyStdin
        };

        cmd.SetAction(async (parseResult, ct) =>
        {
            var url = parseResult.GetValue(prUrl)!;
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
                await services.ReviewService.UpdateDescriptionAsync(url, newBody, ct);
                CliOutput.WriteJson(new { updated = true });
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

    // =========================================================================
    // fix-worktree commands
    // =========================================================================

    private static Command BuildFixWorktree(ServiceFactory services)
    {
        var cmd = new Command("fix-worktree", "Manage the fix worktree for AI agents to make code changes in response to PR comments.");

        cmd.Subcommands.Add(BuildFixWorktreePrepare(services));
        cmd.Subcommands.Add(BuildFixWorktreeCleanup(services));
        cmd.Subcommands.Add(BuildFixWorktreePath(services));
        cmd.Subcommands.Add(BuildFixWorktreeCreateBranch(services));

        return cmd;
    }

    private static Command BuildFixWorktreePrepare(ServiceFactory services)
    {
        var prUrl = PrUrlOption();
        var cmd = new Command("prepare", "Create a fix worktree for AI agents to work in. Idempotent — returns existing worktree if already created.")
        {
            prUrl
        };

        cmd.SetAction(async (parseResult, ct) =>
        {
            var url = parseResult.GetValue(prUrl)!;
            try
            {
                var sessionId = ResolveSessionId(services, url);
                var result = await services.FixWorktreeService.PrepareAsync(sessionId, ct);
                CliOutput.WriteJson(new
                {
                    worktree_path = result.WorktreePath,
                    base_branch = result.BaseBranch,
                    created = result.Created,
                });
            }
            catch (FixWorktreeServiceException ex)
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

    private static Command BuildFixWorktreeCleanup(ServiceFactory services)
    {
        var prUrl = PrUrlOption();
        var cmd = new Command("cleanup", "Remove the fix worktree and clean up all fix branches.")
        {
            prUrl
        };

        cmd.SetAction(async (parseResult, ct) =>
        {
            var url = parseResult.GetValue(prUrl)!;
            try
            {
                var sessionId = ResolveSessionId(services, url);
                await services.FixWorktreeService.CleanupAsync(sessionId, ct);
                CliOutput.WriteJson(new { cleaned = true });
            }
            catch (FixWorktreeServiceException ex)
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

    private static Command BuildFixWorktreePath(ServiceFactory services)
    {
        var prUrl = PrUrlOption();
        var cmd = new Command("path", "Get the fix worktree path for a PR. No auth required.")
        {
            prUrl
        };

        cmd.SetAction(parseResult =>
        {
            var url = parseResult.GetValue(prUrl)!;
            try
            {
                var sessionId = ResolveSessionId(services, url);
                var path = services.FixWorktreeService.GetWorktreePath(sessionId);

                if (path == null)
                    return CliOutput.WriteError("No fix worktree exists for this session. Run 'fix-worktree prepare' first.");

                CliOutput.WriteJson(new { path });
            }
            catch (Exception ex)
            {
                return CliOutput.WriteError(ex.Message);
            }
            return 0;
        });

        return cmd;
    }

    private static Command BuildFixWorktreeCreateBranch(ServiceFactory services)
    {
        var prUrl = PrUrlOption();
        var threadIdOpt = new Option<int>("--thread-id")
        {
            Description = "The thread ID to create a fix branch for",
            Required = true,
        };

        var cmd = new Command("create-branch", "Create a fix branch in the worktree for a specific comment thread.")
        {
            prUrl, threadIdOpt
        };

        cmd.SetAction(async (parseResult, ct) =>
        {
            var url = parseResult.GetValue(prUrl)!;
            var threadId = parseResult.GetValue(threadIdOpt);
            try
            {
                var sessionId = ResolveSessionId(services, url);
                var branchName = await services.FixWorktreeService.CreateFixBranchAsync(sessionId, threadId, ct);
                var worktreePath = services.FixWorktreeService.GetWorktreePath(sessionId);
                CliOutput.WriteJson(new
                {
                    branch = branchName,
                    worktree_path = worktreePath,
                    thread_id = threadId,
                });
            }
            catch (FixWorktreeServiceException ex)
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

    // =========================================================================
    // proposal commands
    // =========================================================================

    private static Command BuildProposal(ServiceFactory services)
    {
        var cmd = new Command("proposal", "Manage proposed code fixes from AI agents.");

        cmd.Subcommands.Add(BuildProposalCreate(services));
        cmd.Subcommands.Add(BuildProposalList(services));
        cmd.Subcommands.Add(BuildProposalDiff(services));
        cmd.Subcommands.Add(BuildProposalApprove(services));
        cmd.Subcommands.Add(BuildProposalApproveAll(services));
        cmd.Subcommands.Add(BuildProposalApply(services));
        cmd.Subcommands.Add(BuildProposalApplyAll(services));
        cmd.Subcommands.Add(BuildProposalReject(services));
        cmd.Subcommands.Add(BuildProposalDelete(services));

        return cmd;
    }

    private static Command BuildProposalCreate(ServiceFactory services)
    {
        var prUrl = PrUrlOption();
        var threadIdOpt = new Option<int>("--thread-id")
        {
            Description = "The remote thread ID this proposal responds to",
            Required = true,
        };
        var branchOpt = new Option<string>("--branch")
        {
            Description = "Name of the fix branch holding the changes",
            Required = true,
        };
        var descriptionOpt = new Option<string?>("--description")
        {
            Description = "Description of what the fix does",
        };
        var descriptionStdin = new Option<bool>("--description-stdin")
        {
            Description = "Read description from stdin",
        };
        var filesOpt = new Option<string?>("--files")
        {
            Description = "Comma-separated list of changed file paths",
        };
        var author = new Option<string?>("--author")
        {
            Description = "Author type: 'user' or 'ai' (default: ai)",
        };
        var authorName = new Option<string?>("--author-name")
        {
            Description = "Display name for the agent that created this proposal",
        };
        var replyDraftId = new Option<string?>("--reply-draft-id")
        {
            Description = "UUID of a linked reply draft to auto-approve on proposal approval",
        };

        var cmd = new Command("create", "Register a proposed code fix. The AI agent should have already committed changes to the fix branch.")
        {
            prUrl, threadIdOpt, branchOpt, descriptionOpt, descriptionStdin,
            filesOpt, author, authorName, replyDraftId
        };

        cmd.SetAction(parseResult =>
        {
            var url = parseResult.GetValue(prUrl)!;
            var useStdin = parseResult.GetValue(descriptionStdin);

            var desc = parseResult.GetValue(descriptionOpt);
            if (useStdin)
            {
                desc = Console.In.ReadToEnd().TrimEnd();
            }

            if (string.IsNullOrWhiteSpace(desc))
                return CliOutput.WriteUsageError("Provide --description or --description-stdin");

            var authorStr = parseResult.GetValue(author);
            DraftAuthor? draftAuthor = authorStr?.ToLowerInvariant() switch
            {
                "ai" => DraftAuthor.Ai,
                "user" => DraftAuthor.User,
                null => null,
                _ => DraftAuthor.Ai,
            };

            var filesStr = parseResult.GetValue(filesOpt);
            var filesList = filesStr?.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
                .ToList();

            try
            {
                var sessionId = ResolveSessionId(services, url);
                var (id, proposal) = services.ProposalService.CreateProposal(sessionId, new CreateProposalRequest
                {
                    ThreadId = parseResult.GetValue(threadIdOpt),
                    BranchName = parseResult.GetValue(branchOpt)!,
                    Description = desc!,
                    FilesChanged = filesList,
                    Author = draftAuthor,
                    AuthorName = parseResult.GetValue(authorName),
                    ReplyDraftId = parseResult.GetValue(replyDraftId),
                });

                CliOutput.WriteJson(new { id, proposal });
            }
            catch (ProposalServiceException ex)
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

    private static Command BuildProposalList(ServiceFactory services)
    {
        var prUrl = PrUrlOption();
        var cmd = new Command("list", "List all proposals and their statuses.")
        {
            prUrl
        };

        cmd.SetAction(parseResult =>
        {
            var url = parseResult.GetValue(prUrl)!;
            try
            {
                var sessionId = ResolveSessionId(services, url);
                var proposals = services.ProposalService.GetProposals(sessionId);
                var counts = services.ProposalService.GetProposalCounts(sessionId);

                CliOutput.WriteJson(new
                {
                    counts,
                    proposals = proposals.Select(kvp => new
                    {
                        id = kvp.Key,
                        proposal = kvp.Value,
                    }),
                });
            }
            catch (Exception ex)
            {
                return CliOutput.WriteError(ex.Message);
            }
            return 0;
        });

        return cmd;
    }

    private static Command BuildProposalDiff(ServiceFactory services)
    {
        var prUrl = PrUrlOption();
        var proposalId = new Option<string>("--proposal-id")
        {
            Description = "The proposal UUID to get the diff for",
            Required = true,
        };

        var cmd = new Command("diff", "View the code diff for a proposed fix.")
        {
            prUrl, proposalId
        };

        cmd.SetAction(async (parseResult, ct) =>
        {
            var url = parseResult.GetValue(prUrl)!;
            var id = parseResult.GetValue(proposalId)!;
            try
            {
                var sessionId = ResolveSessionId(services, url);
                var diff = await services.ProposalService.GetProposalDiffAsync(sessionId, id, ct);
                var proposal = services.ProposalService.GetProposal(sessionId, id);

                CliOutput.WriteJson(new
                {
                    proposal_id = id,
                    description = proposal?.Proposal.Description,
                    branch = proposal?.Proposal.BranchName,
                    status = proposal?.Proposal.Status.ToString(),
                    diff,
                });
            }
            catch (ProposalServiceException ex)
            {
                return CliOutput.WriteError(ex.Message);
            }
            catch (FixWorktreeServiceException ex)
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

    private static Command BuildProposalApprove(ServiceFactory services)
    {
        var prUrl = PrUrlOption();
        var proposalId = new Option<string>("--proposal-id")
        {
            Description = "The proposal UUID to approve",
            Required = true,
        };

        var cmd = new Command("approve", "Approve a proposed fix (draft -> approved). Linked reply drafts are auto-approved.")
        {
            prUrl, proposalId
        };

        cmd.SetAction(parseResult =>
        {
            var url = parseResult.GetValue(prUrl)!;
            var id = parseResult.GetValue(proposalId)!;
            try
            {
                var sessionId = ResolveSessionId(services, url);
                var proposal = services.ProposalService.ApproveProposal(sessionId, id);
                CliOutput.WriteJson(new { id, proposal });
            }
            catch (ProposalServiceException ex)
            {
                return CliOutput.WriteError(ex.Message);
            }
            return 0;
        });

        return cmd;
    }

    private static Command BuildProposalApproveAll(ServiceFactory services)
    {
        var prUrl = PrUrlOption();
        var cmd = new Command("approve-all", "Approve all draft proposals at once. Linked reply drafts are auto-approved.")
        {
            prUrl
        };

        cmd.SetAction(parseResult =>
        {
            var url = parseResult.GetValue(prUrl)!;
            try
            {
                var sessionId = ResolveSessionId(services, url);
                var count = services.ProposalService.ApproveAllProposals(sessionId);
                CliOutput.WriteJson(new { approved = count });
            }
            catch (ProposalServiceException ex)
            {
                return CliOutput.WriteError(ex.Message);
            }
            return 0;
        });

        return cmd;
    }

    private static Command BuildProposalApplyAll(ServiceFactory services)
    {
        var prUrl = PrUrlOption();
        var pushOpt = new Option<bool>("--push")
        {
            Description = "Push the changes to the remote after applying all proposals",
        };

        var cmd = new Command("apply-all", "Apply all approved proposals by cherry-picking changes into the PR branch.")
        {
            prUrl, pushOpt
        };

        cmd.SetAction(async (parseResult, ct) =>
        {
            var url = parseResult.GetValue(prUrl)!;
            var push = parseResult.GetValue(pushOpt);
            try
            {
                var sessionId = ResolveSessionId(services, url);
                var result = await services.ProposalService.ApplyAllProposalsAsync(sessionId, push, ct);
                CliOutput.WriteJson(new
                {
                    applied = result.Applied.Count,
                    failed = result.Failed.Count,
                    applied_ids = result.Applied,
                    failures = result.Failed,
                    pushed = push,
                });
            }
            catch (ProposalServiceException ex)
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

    private static Command BuildProposalApply(ServiceFactory services)
    {
        var prUrl = PrUrlOption();
        var proposalId = new Option<string>("--proposal-id")
        {
            Description = "The proposal UUID to apply",
            Required = true,
        };
        var pushOpt = new Option<bool>("--push")
        {
            Description = "Push the changes to the remote after applying",
        };

        var cmd = new Command("apply", "Apply an approved proposal by cherry-picking changes into the PR branch.")
        {
            prUrl, proposalId, pushOpt
        };

        cmd.SetAction(async (parseResult, ct) =>
        {
            var url = parseResult.GetValue(prUrl)!;
            var id = parseResult.GetValue(proposalId)!;
            var push = parseResult.GetValue(pushOpt);
            try
            {
                var sessionId = ResolveSessionId(services, url);
                var proposal = await services.ProposalService.ApplyProposalAsync(sessionId, id, push, ct);
                CliOutput.WriteJson(new
                {
                    id,
                    proposal,
                    applied = true,
                    pushed = push,
                });
            }
            catch (ProposalServiceException ex)
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

    private static Command BuildProposalReject(ServiceFactory services)
    {
        var prUrl = PrUrlOption();
        var proposalId = new Option<string>("--proposal-id")
        {
            Description = "The proposal UUID to reject",
            Required = true,
        };

        var cmd = new Command("reject", "Reject a proposed fix (draft -> rejected).")
        {
            prUrl, proposalId
        };

        cmd.SetAction(parseResult =>
        {
            var url = parseResult.GetValue(prUrl)!;
            var id = parseResult.GetValue(proposalId)!;
            try
            {
                var sessionId = ResolveSessionId(services, url);
                var proposal = services.ProposalService.RejectProposal(sessionId, id);
                CliOutput.WriteJson(new { id, proposal });
            }
            catch (ProposalServiceException ex)
            {
                return CliOutput.WriteError(ex.Message);
            }
            return 0;
        });

        return cmd;
    }

    private static Command BuildProposalDelete(ServiceFactory services)
    {
        var prUrl = PrUrlOption();
        var proposalId = new Option<string>("--proposal-id")
        {
            Description = "The proposal UUID to delete",
            Required = true,
        };

        var cmd = new Command("delete", "Delete a proposed fix (only draft or rejected proposals).")
        {
            prUrl, proposalId
        };

        cmd.SetAction(parseResult =>
        {
            var url = parseResult.GetValue(prUrl)!;
            var id = parseResult.GetValue(proposalId)!;
            try
            {
                var sessionId = ResolveSessionId(services, url);
                services.ProposalService.DeleteProposal(sessionId, id);
                CliOutput.WriteJson(new { deleted = true, id });
            }
            catch (ProposalServiceException ex)
            {
                return CliOutput.WriteError(ex.Message);
            }
            return 0;
        });

        return cmd;
    }
}
