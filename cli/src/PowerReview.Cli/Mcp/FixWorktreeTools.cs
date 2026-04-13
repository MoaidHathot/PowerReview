using System.ComponentModel;
using ModelContextProtocol.Server;
using PowerReview.Core.Services;

namespace PowerReview.Cli.Mcp;

/// <summary>
/// MCP tools for managing the fix worktree — an isolated git working directory
/// where AI agents can make code changes without affecting the user's working directory.
/// </summary>
[McpServerToolType]
public sealed class FixWorktreeTools
{
    [McpServerTool, Description(
        "Prepare an isolated fix worktree for making code changes in response to PR comments. " +
        "The worktree is created from the PR's source branch. " +
        "Idempotent: if a worktree already exists, returns its path. " +
        "Call this before creating fix branches or making code changes.")]
    public static async Task<string> PrepareFixWorktree(
        FixWorktreeService fixWorktreeService,
        [Description("The pull request URL")] string prUrl,
        CancellationToken ct)
    {
        try
        {
            var sessionId = ToolHelpers.ResolveSessionId(prUrl);
            var result = await fixWorktreeService.PrepareAsync(sessionId, ct);

            return ToolHelpers.ToJson(new
            {
                worktree_path = result.WorktreePath,
                base_branch = result.BaseBranch,
                created = result.Created,
                note = result.Created
                    ? "Fix worktree created. Use CreateFixBranch to create a branch for each fix."
                    : "Fix worktree already exists. Use CreateFixBranch to create a branch for each fix.",
            });
        }
        catch (FixWorktreeServiceException ex)
        {
            return ToolHelpers.ToJson(new { error = ex.Message });
        }
    }

    [McpServerTool, Description(
        "Get the filesystem path to the fix worktree. " +
        "Returns the path where the AI agent should make code changes. " +
        "Returns an error if the worktree has not been prepared yet.")]
    public static string GetFixWorktreePath(
        FixWorktreeService fixWorktreeService,
        [Description("The pull request URL")] string prUrl)
    {
        try
        {
            var sessionId = ToolHelpers.ResolveSessionId(prUrl);
            var path = fixWorktreeService.GetWorktreePath(sessionId);

            if (path == null)
                return ToolHelpers.ToJson(new
                {
                    error = "No fix worktree exists. Call PrepareFixWorktree first.",
                });

            return ToolHelpers.ToJson(new { path });
        }
        catch (Exception ex)
        {
            return ToolHelpers.ToJson(new { error = ex.Message });
        }
    }

    [McpServerTool, Description(
        "Create a new fix branch in the worktree for a specific comment thread. " +
        "The branch is created from the PR's source branch and named 'powerreview/fix/thread-{threadId}'. " +
        "After creating the branch, make your code changes in the worktree path and commit them. " +
        "Then call CreateProposal to register the fix.")]
    public static async Task<string> CreateFixBranch(
        FixWorktreeService fixWorktreeService,
        [Description("The pull request URL")] string prUrl,
        [Description("The thread ID to create a fix branch for")] int threadId,
        CancellationToken ct)
    {
        try
        {
            var sessionId = ToolHelpers.ResolveSessionId(prUrl);
            var branchName = await fixWorktreeService.CreateFixBranchAsync(sessionId, threadId, ct);
            var worktreePath = fixWorktreeService.GetWorktreePath(sessionId);

            return ToolHelpers.ToJson(new
            {
                branch = branchName,
                worktree_path = worktreePath,
                thread_id = threadId,
                note = $"Fix branch created. Make your changes in '{worktreePath}', then: " +
                       "1) git add + git commit in the worktree, " +
                       "2) Call CreateProposal to register the fix.",
            });
        }
        catch (FixWorktreeServiceException ex)
        {
            return ToolHelpers.ToJson(new { error = ex.Message });
        }
    }
}
