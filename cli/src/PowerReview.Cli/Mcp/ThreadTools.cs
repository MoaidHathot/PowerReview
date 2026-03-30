using System.ComponentModel;
using ModelContextProtocol.Server;
using PowerReview.Core.Models;
using PowerReview.Core.Services;

namespace PowerReview.Cli.Mcp;

/// <summary>
/// MCP tools for replying to existing comment threads.
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
        [Description("Reply body in markdown format")] string body)
    {
        try
        {
            var sessionId = ToolHelpers.ResolveSessionId(prUrl);
            var (id, draft) = sessionService.CreateDraft(sessionId, new CreateDraftRequest
            {
                Body = body,
                ThreadId = threadId,
                Author = DraftAuthor.Ai,
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
}
