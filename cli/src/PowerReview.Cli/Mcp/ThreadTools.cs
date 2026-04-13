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
            var (id, draft) = sessionService.CreateDraft(sessionId, new CreateDraftRequest
            {
                Body = body,
                ThreadId = threadId,
                Author = DraftAuthor.Ai,
                AuthorName = agentName,
            });

            return ToolHelpers.ToJson(new
            {
                id,
                draft,
                note = "Draft reply created. The user must approve it before it can be submitted.",
            });
        }
        catch (SessionServiceException ex)
        {
            return ToolHelpers.ToJson(new { error = ex.Message });
        }
    }

    [McpServerTool, Description(
        "Update the status of a comment thread on the remote provider. " +
        "Use this to resolve threads that have been addressed, or reactivate them. " +
        "Valid statuses: active, fixed, wontfix, closed, bydesign, pending.")]
    public static async Task<string> UpdateThreadStatus(
        ReviewService reviewService,
        [Description("The pull request URL")] string prUrl,
        [Description("The remote thread ID to update")] int threadId,
        [Description("New thread status. One of: active, fixed, wontfix, closed, bydesign, pending")] string status,
        CancellationToken ct)
    {
        try
        {
            var threadStatus = status.ToLowerInvariant() switch
            {
                "active" => ThreadStatus.Active,
                "fixed" or "resolved" => ThreadStatus.Fixed,
                "wontfix" or "wont-fix" => ThreadStatus.WontFix,
                "closed" => ThreadStatus.Closed,
                "bydesign" or "by-design" => ThreadStatus.ByDesign,
                "pending" => ThreadStatus.Pending,
                _ => throw new ArgumentException($"Invalid thread status: '{status}'. Use: active, fixed, wontfix, closed, bydesign, pending"),
            };

            var result = await reviewService.UpdateThreadStatusAsync(prUrl, threadId, threadStatus, ct);
            return ToolHelpers.ToJson(new
            {
                thread_id = threadId,
                status,
                thread = result,
            });
        }
        catch (ReviewServiceException ex)
        {
            return ToolHelpers.ToJson(new { error = ex.Message });
        }
        catch (ArgumentException ex)
        {
            return ToolHelpers.ToJson(new { error = ex.Message });
        }
    }
}
