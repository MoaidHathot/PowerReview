using System.ComponentModel;
using ModelContextProtocol.Server;
using PowerReview.Core.Models;
using PowerReview.Core.Services;

namespace PowerReview.Cli.Mcp;

/// <summary>
/// MCP tools for interacting with existing comment threads.
/// </summary>
[McpServerToolType]
public sealed class ThreadTools
{
    [McpServerTool, Description(
        "Create a draft reply to an existing comment thread. " +
        "The reply starts as a draft that the user must approve before submission.")]
    public static string ReplyToThread(
        SessionService sessionService,
        [Description("The pull request URL")] string prUrl,
        [Description("The remote thread ID to reply to")] int threadId,
        [Description("Reply body in markdown format")] string body,
        [Description("Optional name identifying this agent (e.g. 'SecurityReviewer', 'StyleChecker'). Helps distinguish comments when multiple AI agents review the same PR.")] string? agentName = null)
    {
        try
        {
            var sessionId = ToolHelpers.ResolveSessionId(prUrl);
            var (id, operation) = sessionService.CreateDraftReply(sessionId, new CreateDraftOperationRequest
            {
                Body = body,
                ThreadId = threadId,
                Author = DraftAuthor.Ai,
                AuthorName = agentName,
            });

            return ToolHelpers.ToJson(new
            {
                id,
                operation,
                note = "Draft reply created. The user must approve it before it can be submitted.",
            });
        }
        catch (SessionServiceException ex)
        {
            return ToolHelpers.ToJson(new { error = ex.Message });
        }
    }

    [McpServerTool, Description(
        "Create a draft operation to update a comment thread status after user approval. " +
        "This does not update the remote provider directly. " +
        "Valid statuses: active, fixed, wontfix, closed, bydesign, pending.")]
    public static string DraftThreadStatusChange(
        SessionService sessionService,
        [Description("The pull request URL")] string prUrl,
        [Description("The remote thread ID to update after approval")] int threadId,
        [Description("Target thread status. One of: active, fixed, wontfix, closed, bydesign, pending")] string status,
        [Description("Optional rationale shown to the user before approval")] string? reason = null,
        [Description("Optional name identifying this agent")] string? agentName = null)
    {
        try
        {
            var threadStatus = ParseThreadStatus(status);
            var sessionId = ToolHelpers.ResolveSessionId(prUrl);
            var (id, operation) = sessionService.CreateDraftThreadStatusChange(sessionId, new CreateDraftOperationRequest
            {
                ThreadId = threadId,
                ToThreadStatus = threadStatus,
                Note = reason,
                Author = DraftAuthor.Ai,
                AuthorName = agentName,
            });

            return ToolHelpers.ToJson(new
            {
                id,
                operation,
                note = "Draft operation created. The user must approve it before submit applies it remotely.",
            });
        }
        catch (SessionServiceException ex)
        {
            return ToolHelpers.ToJson(new { error = ex.Message });
        }
        catch (ArgumentException ex)
        {
            return ToolHelpers.ToJson(new { error = ex.Message });
        }
    }

    [McpServerTool, Description(
        "Create a draft operation to react to a comment after user approval. " +
        "This does not update the remote provider directly. Currently supported reaction: like.")]
    public static string DraftCommentReaction(
        SessionService sessionService,
        [Description("The pull request URL")] string prUrl,
        [Description("The remote thread ID containing the comment")] int threadId,
        [Description("The remote comment ID to react to")] int commentId,
        [Description("Reaction to apply after approval. Supported: like")] string reaction,
        [Description("Optional rationale shown to the user before approval")] string? reason = null,
        [Description("Optional name identifying this agent")] string? agentName = null)
    {
        try
        {
            var parsedReaction = reaction.ToLowerInvariant() switch
            {
                "like" => CommentReaction.Like,
                _ => throw new ArgumentException($"Invalid reaction: '{reaction}'. Use: like"),
            };

            var sessionId = ToolHelpers.ResolveSessionId(prUrl);
            var (id, operation) = sessionService.CreateDraftCommentReaction(sessionId, new CreateDraftOperationRequest
            {
                ThreadId = threadId,
                CommentId = commentId,
                Reaction = parsedReaction,
                Note = reason,
                Author = DraftAuthor.Ai,
                AuthorName = agentName,
            });

            return ToolHelpers.ToJson(new
            {
                id,
                operation,
                note = "Draft operation created. The user must approve it before submit applies it remotely.",
            });
        }
        catch (SessionServiceException ex)
        {
            return ToolHelpers.ToJson(new { error = ex.Message });
        }
        catch (ArgumentException ex)
        {
            return ToolHelpers.ToJson(new { error = ex.Message });
        }
    }

    private static ThreadStatus ParseThreadStatus(string status)
    {
        return status.ToLowerInvariant() switch
        {
            "active" => ThreadStatus.Active,
            "fixed" or "resolved" => ThreadStatus.Fixed,
            "wontfix" or "wont-fix" => ThreadStatus.WontFix,
            "closed" => ThreadStatus.Closed,
            "bydesign" or "by-design" => ThreadStatus.ByDesign,
            "pending" => ThreadStatus.Pending,
            _ => throw new ArgumentException($"Invalid thread status: '{status}'. Use: active, fixed, wontfix, closed, bydesign, pending"),
        };
    }
}
