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
        "Create a new draft review comment on a specific file and line, or a file-level comment (no specific line). " +
        "The comment starts as a draft that the user must approve before submission. " +
        "Only approved (pending) drafts will be submitted to the remote provider.")]
    public static string CreateComment(
        SessionService sessionService,
        [Description("The pull request URL")] string prUrl,
        [Description("Relative file path to comment on")] string filePath,
        [Description("Comment body in markdown format")] string body,
        [Description("Line number to attach the comment to (1-indexed). Omit for file-level comments.")] int? lineStart = null,
        [Description("Optional end line for range comments (1-indexed)")] int? lineEnd = null,
        [Description("Optional starting column (character offset) within the start line for highlighting a specific word or expression")] int? colStart = null,
        [Description("Optional ending column (character offset) within the end line")] int? colEnd = null,
        [Description("Optional name identifying this agent (e.g. 'SecurityReviewer', 'StyleChecker'). Helps distinguish comments when multiple AI agents review the same PR.")] string? agentName = null)
    {
        try
        {
            var sessionId = ToolHelpers.ResolveSessionId(prUrl);
            var (id, operation) = sessionService.CreateDraftComment(sessionId, new CreateDraftOperationRequest
            {
                FilePath = filePath,
                LineStart = lineStart,
                LineEnd = lineEnd,
                ColStart = colStart,
                ColEnd = colEnd,
                Body = body,
                Author = DraftAuthor.Ai,
                AuthorName = agentName,
            });

            return ToolHelpers.ToJson(new
            {
                id,
                operation,
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
        "Only works on AI-authored comments in 'Draft' status. " +
        "If the draft was already approved (Pending), editing resets it back to Draft requiring re-approval.")]
    public static string EditDraftComment(
        SessionService sessionService,
        [Description("The pull request URL")] string prUrl,
        [Description("The draft comment UUID to edit")] string draftId,
        [Description("New comment body in markdown format")] string newBody)
    {
        try
        {
            var sessionId = ToolHelpers.ResolveSessionId(prUrl);
            var operation = sessionService.EditDraft(sessionId, draftId, newBody, callerAuthor: DraftAuthor.Ai);

            return ToolHelpers.ToJson(new
            {
                id = draftId,
                operation,
                note = operation.Status == DraftStatus.Draft
                    ? "Draft edited. If it was previously approved, it has been reset to Draft and needs re-approval."
                    : null,
            });
        }
        catch (SessionServiceException ex)
        {
            return ToolHelpers.ToJson(new { error = ex.Message });
        }
    }

    [McpServerTool, Description(
        "Delete a draft comment. " +
        "Only works on AI-authored comments in 'Draft' status. " +
        "User-authored and approved/submitted comments cannot be deleted by AI.")]
    public static string DeleteDraftComment(
        SessionService sessionService,
        [Description("The pull request URL")] string prUrl,
        [Description("The draft comment UUID to delete")] string draftId)
    {
        try
        {
            var sessionId = ToolHelpers.ResolveSessionId(prUrl);
            sessionService.DeleteDraft(sessionId, draftId, callerAuthor: DraftAuthor.Ai);

            return ToolHelpers.ToJson(new { deleted = true, id = draftId });
        }
        catch (SessionServiceException ex)
        {
            return ToolHelpers.ToJson(new { error = ex.Message });
        }
    }
}
