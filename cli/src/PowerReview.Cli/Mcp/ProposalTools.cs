using System.ComponentModel;
using ModelContextProtocol.Server;
using PowerReview.Core.Models;
using PowerReview.Core.Services;

namespace PowerReview.Cli.Mcp;

/// <summary>
/// MCP tools for managing proposed code fixes.
/// AI agents create proposals after making code changes on fix branches.
/// Approve/apply/reject operations are user-only and not exposed as MCP tools.
/// </summary>
[McpServerToolType]
public sealed class ProposalTools
{
    [McpServerTool, Description(
        "Register a proposed code fix after making changes on a fix branch. " +
        "The AI agent should have already: " +
        "1) Called PrepareFixWorktree to get the worktree, " +
        "2) Called CreateFixBranch to create a branch for the thread, " +
        "3) Made code changes and committed them in the worktree, " +
        "4) Optionally called ReplyToThread to create a linked reply draft. " +
        "The proposal starts as a draft that the user must approve before it can be applied.")]
    public static string CreateProposal(
        ProposalService proposalService,
        [Description("The pull request URL")] string prUrl,
        [Description("The remote thread ID this fix responds to")] int threadId,
        [Description("Name of the fix branch holding the committed changes (e.g. 'powerreview/fix/thread-42')")] string branchName,
        [Description("Human-readable description of what this fix does")] string description,
        [Description("Comma-separated list of file paths that were modified")] string? filesChanged = null,
        [Description("UUID of a linked reply draft. When the proposal is approved, the linked reply is auto-approved for submission.")] string? replyDraftId = null,
        [Description("Optional name identifying this agent (e.g. 'CodeFixer', 'SecurityReviewer')")] string? agentName = null)
    {
        try
        {
            var sessionId = ToolHelpers.ResolveSessionId(prUrl);

            var filesList = filesChanged?
                .Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
                .ToList();

            var (id, proposal) = proposalService.CreateProposal(sessionId, new CreateProposalRequest
            {
                ThreadId = threadId,
                BranchName = branchName,
                Description = description,
                FilesChanged = filesList,
                Author = DraftAuthor.Ai,
                AuthorName = agentName,
                ReplyDraftId = replyDraftId,
            });

            return ToolHelpers.ToJson(new
            {
                id,
                proposal,
                note = "Proposal created. The user must approve it before it can be applied to the PR branch.",
            });
        }
        catch (ProposalServiceException ex)
        {
            return ToolHelpers.ToJson(new { error = ex.Message });
        }
    }

    [McpServerTool, Description(
        "List all proposed code fixes and their statuses (draft, approved, applied, rejected). " +
        "Includes count summaries and full proposal details.")]
    public static string ListProposals(
        ProposalService proposalService,
        [Description("The pull request URL")] string prUrl)
    {
        try
        {
            var sessionId = ToolHelpers.ResolveSessionId(prUrl);
            var proposals = proposalService.GetProposals(sessionId);
            var counts = proposalService.GetProposalCounts(sessionId);

            return ToolHelpers.ToJson(new
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
            return ToolHelpers.ToJson(new { error = ex.Message });
        }
    }

    [McpServerTool, Description(
        "Get the code diff for a proposed fix. " +
        "Shows the changes between the fix branch and the PR source branch.")]
    public static async Task<string> GetProposalDiff(
        ProposalService proposalService,
        [Description("The pull request URL")] string prUrl,
        [Description("The proposal UUID to get the diff for")] string proposalId,
        CancellationToken ct)
    {
        try
        {
            var sessionId = ToolHelpers.ResolveSessionId(prUrl);
            var diff = await proposalService.GetProposalDiffAsync(sessionId, proposalId, ct);
            var result = proposalService.GetProposal(sessionId, proposalId);

            return ToolHelpers.ToJson(new
            {
                proposal_id = proposalId,
                description = result?.Proposal.Description,
                branch = result?.Proposal.BranchName,
                status = result?.Proposal.Status.ToString(),
                diff,
            });
        }
        catch (ProposalServiceException ex)
        {
            return ToolHelpers.ToJson(new { error = ex.Message });
        }
        catch (FixWorktreeServiceException ex)
        {
            return ToolHelpers.ToJson(new { error = ex.Message });
        }
    }
}
