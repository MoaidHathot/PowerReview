using System.ComponentModel;
using ModelContextProtocol.Server;
using PowerReview.Core.Models;
using PowerReview.Core.Services;

namespace PowerReview.Cli.Mcp;

/// <summary>
/// MCP tools for managing draft comments: create, edit, delete.
/// All comment-creating tools default the author to "ai".
/// </summary>
[McpServerToolType]
public sealed class DraftTools
{
    [McpServerTool, Description(
        "Create a new draft review comment on a specific file and line. " +
        "The comment starts as a draft that the user must approve before submission. " +
        "Only approved (pending) drafts will be submitted to the remote provider.")]
    public static string CreateComment(
        SessionService sessionService,
        [Description("The pull request URL")] string prUrl,
        [Description("Relative file path to comment on")] string filePath,
        [Description("Line number to attach the comment to (1-indexed)")] int lineStart,
        [Description("Comment body in markdown format")] string body,
        [Description("Optional end line for range comments (1-indexed)")] int? lineEnd = null)
    {
        try
        {
            var sessionId = ToolHelpers.ResolveSessionId(prUrl);
            var (id, draft) = sessionService.CreateDraft(sessionId, new CreateDraftRequest
            {
                FilePath = filePath,
                LineStart = lineStart,
                LineEnd = lineEnd,
                Body = body,
                Author = DraftAuthor.Ai,
            });

            return ToolHelpers.ToJson(new
            {
                id,
                draft,
                note = "Draft created. The user must approve it before it can be submitted.",
            });
        }
        catch (SessionServiceException ex)
        {
            return ToolHelpers.ToJson(new { error = ex.Message });
        }
    }

    [McpServerTool, Description(
        "Edit the body of an existing draft comment. " +
        "Only works on comments with status 'Draft' -- approved/submitted comments cannot be edited by AI.")]
    public static string EditDraftComment(
        SessionService sessionService,
        [Description("The pull request URL")] string prUrl,
        [Description("The draft comment UUID to edit")] string draftId,
        [Description("New comment body in markdown format")] string newBody)
    {
        try
        {
            var sessionId = ToolHelpers.ResolveSessionId(prUrl);
            var draft = sessionService.EditDraft(sessionId, draftId, newBody);

            return ToolHelpers.ToJson(new { id = draftId, draft });
        }
        catch (SessionServiceException ex)
        {
            return ToolHelpers.ToJson(new { error = ex.Message });
        }
    }

    [McpServerTool, Description(
        "Delete a draft comment. " +
        "Only works on comments with status 'Draft' -- approved/submitted comments cannot be deleted by AI.")]
    public static string DeleteDraftComment(
        SessionService sessionService,
        [Description("The pull request URL")] string prUrl,
        [Description("The draft comment UUID to delete")] string draftId)
    {
        try
        {
            var sessionId = ToolHelpers.ResolveSessionId(prUrl);
            sessionService.DeleteDraft(sessionId, draftId);

            return ToolHelpers.ToJson(new { deleted = true, id = draftId });
        }
        catch (SessionServiceException ex)
        {
            return ToolHelpers.ToJson(new { error = ex.Message });
        }
    }
}
