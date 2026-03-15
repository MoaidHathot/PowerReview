/**
 * PowerReview MCP — Tool definitions and handlers
 *
 * Defines all MCP tools that external AI agents can call to interact with
 * the PowerReview plugin running in Neovim.
 */

import { z } from "zod";
import type { NvimClient } from "./nvim-client.js";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";

// ============================================================================
// Type definitions for Lua API responses
// ============================================================================

interface ChangedFile {
  path: string;
  change_type: string;
  original_path?: string;
}

interface ReviewSession {
  id: string;
  pr_id: number;
  pr_title: string;
  pr_description: string;
  pr_author: string;
  pr_url: string;
  provider_type: string;
  source_branch: string;
  target_branch: string;
  draft_count: number;
  file_count: number;
  vote: number | null;
  vote_label: string;
}

interface DraftComment {
  id: string;
  file_path: string;
  line_start: number;
  line_end?: number;
  body: string;
  status: string;
  author: string;
  created_at: string;
  updated_at: string;
  thread_id?: number;
}

interface CommentThread {
  type: string;
  file_path: string;
  line_start: number;
  drafts?: DraftComment[];
}

// ============================================================================
// Tool registration
// ============================================================================

/**
 * Register all PowerReview tools on the MCP server.
 */
export function registerTools(server: McpServer, nvim: NvimClient): void {
  registerGetReviewSession(server, nvim);
  registerListChangedFiles(server, nvim);
  registerGetFileDiff(server, nvim);
  registerListCommentThreads(server, nvim);
  registerCreateComment(server, nvim);
  registerReplyToThread(server, nvim);
  registerEditDraftComment(server, nvim);
  registerDeleteDraftComment(server, nvim);
}

// ============================================================================
// get_review_session
// ============================================================================

function registerGetReviewSession(server: McpServer, nvim: NvimClient): void {
  server.tool(
    "get_review_session",
    "Get the current active PR review session metadata including PR title, author, branches, draft/file counts, and current vote status",
    {},
    async () => {
      const { result, error } = await nvim.callApi<ReviewSession>(
        "get_review_session"
      );

      if (error) {
        return {
          content: [{ type: "text" as const, text: `Error: ${error}` }],
          isError: true,
        };
      }

      return {
        content: [
          {
            type: "text" as const,
            text: JSON.stringify(result, null, 2),
          },
        ],
      };
    }
  );
}

// ============================================================================
// list_changed_files
// ============================================================================

function registerListChangedFiles(server: McpServer, nvim: NvimClient): void {
  server.tool(
    "list_changed_files",
    "List all files changed in the current pull request, including their change type (add, edit, delete, rename) and paths",
    {},
    async () => {
      const { result, error } = await nvim.callApi<ChangedFile[]>(
        "get_changed_files"
      );

      if (error) {
        return {
          content: [{ type: "text" as const, text: `Error: ${error}` }],
          isError: true,
        };
      }

      const files = result ?? [];
      const summary = files
        .map((f) => {
          const type = f.change_type.toUpperCase().charAt(0);
          const rename =
            f.original_path ? ` (was: ${f.original_path})` : "";
          return `${type} ${f.path}${rename}`;
        })
        .join("\n");

      return {
        content: [
          {
            type: "text" as const,
            text: `Changed files (${files.length}):\n${summary}\n\n` +
              `Full data:\n${JSON.stringify(files, null, 2)}`,
          },
        ],
      };
    }
  );
}

// ============================================================================
// get_file_diff
// ============================================================================

function registerGetFileDiff(server: McpServer, nvim: NvimClient): void {
  server.tool(
    "get_file_diff",
    "Get the git diff content for a specific file in the pull request. Returns the unified diff showing all changes made to the file.",
    { file_path: z.string().describe("Relative file path within the repository") },
    async ({ file_path }) => {
      // The Lua API get_file_diff currently delegates to codediff.
      // For MCP, we'll fetch the diff directly via git on the Neovim side.
      const luaCode = `
        local file_path = ...
        local pr = require('power-review')
        local session = pr.get_current_session()
        if not session then
          return vim.json.encode({ error = 'No active review session' })
        end

        local target = session.target_branch:gsub('^refs/heads/', '')
        local cwd = session.worktree_path or vim.fn.getcwd()
        local result = vim.system(
          { 'git', 'diff', target .. '...HEAD', '--', file_path },
          { cwd = cwd, text = true }
        ):wait()

        if result.code ~= 0 then
          -- Try without merge-base (target..HEAD)
          result = vim.system(
            { 'git', 'diff', target, 'HEAD', '--', file_path },
            { cwd = cwd, text = true }
          ):wait()
        end

        if result.code ~= 0 then
          return vim.json.encode({ error = 'git diff failed: ' .. (result.stderr or '') })
        end

        return vim.json.encode({ diff = result.stdout or '' })
      `;

      const raw = await nvim.execLua<string>(luaCode, [file_path]);
      try {
        const parsed = JSON.parse(raw);
        if (parsed.error) {
          return {
            content: [{ type: "text" as const, text: `Error: ${parsed.error}` }],
            isError: true,
          };
        }
        return {
          content: [
            {
              type: "text" as const,
              text: parsed.diff || "(no diff — file may be unchanged or binary)",
            },
          ],
        };
      } catch {
        return {
          content: [{ type: "text" as const, text: `Failed to parse diff response: ${raw}` }],
          isError: true,
        };
      }
    }
  );
}

// ============================================================================
// list_comment_threads
// ============================================================================

function registerListCommentThreads(server: McpServer, nvim: NvimClient): void {
  server.tool(
    "list_comment_threads",
    "List all comment threads (remote and local drafts) in the current review, optionally filtered by file path",
    {
      file_path: z
        .string()
        .optional()
        .describe(
          "Optional: filter threads to a specific file path. Omit to get all threads."
        ),
    },
    async ({ file_path }) => {
      const method = file_path ? "get_threads_for_file" : "get_all_threads";
      const args = file_path ? [file_path] : [];

      const { result, error } = await nvim.callApi<CommentThread[]>(
        method,
        ...args
      );

      if (error) {
        return {
          content: [{ type: "text" as const, text: `Error: ${error}` }],
          isError: true,
        };
      }

      const threads = result ?? [];
      return {
        content: [
          {
            type: "text" as const,
            text:
              `Comment threads (${threads.length}):\n` +
              JSON.stringify(threads, null, 2),
          },
        ],
      };
    }
  );
}

// ============================================================================
// create_comment
// ============================================================================

function registerCreateComment(server: McpServer, nvim: NvimClient): void {
  server.tool(
    "create_comment",
    "Create a new draft review comment on a specific file and line. The comment starts as a draft that the user must approve before submission.",
    {
      file_path: z.string().describe("Relative file path to comment on"),
      line_start: z.number().int().positive().describe("Line number to attach the comment to (1-indexed)"),
      line_end: z
        .number()
        .int()
        .positive()
        .optional()
        .describe("Optional end line for range comments (1-indexed)"),
      body: z.string().min(1).describe("Comment body in markdown format"),
    },
    async ({ file_path, line_start, line_end, body }) => {
      const opts: Record<string, unknown> = {
        file_path,
        line_start,
        body,
        author: "ai",
      };
      if (line_end !== undefined) {
        opts.line_end = line_end;
      }

      const { result, error } = await nvim.callApi<DraftComment>(
        "create_draft_comment",
        opts
      );

      if (error) {
        return {
          content: [{ type: "text" as const, text: `Error: ${error}` }],
          isError: true,
        };
      }

      const draft = result;
      return {
        content: [
          {
            type: "text" as const,
            text:
              `Draft comment created successfully.\n` +
              `ID: ${draft?.id}\n` +
              `File: ${draft?.file_path}:${draft?.line_start}` +
              (draft?.line_end ? `-${draft.line_end}` : "") +
              `\nStatus: ${draft?.status} (user must approve before submission)\n\n` +
              `Body:\n${draft?.body}`,
          },
        ],
      };
    }
  );
}

// ============================================================================
// reply_to_thread
// ============================================================================

function registerReplyToThread(server: McpServer, nvim: NvimClient): void {
  server.tool(
    "reply_to_thread",
    "Create a draft reply to an existing comment thread. The reply starts as a draft that the user must approve.",
    {
      thread_id: z.number().int().describe("The remote thread ID to reply to"),
      body: z.string().min(1).describe("Reply body in markdown format"),
      file_path: z
        .string()
        .optional()
        .describe("File path the thread belongs to (for sign placement)"),
      line_start: z
        .number()
        .int()
        .optional()
        .describe("Line number the thread is on (for sign placement)"),
    },
    async ({ thread_id, body, file_path, line_start }) => {
      const opts: Record<string, unknown> = {
        thread_id,
        body,
        author: "ai",
      };
      if (file_path) opts.file_path = file_path;
      if (line_start) opts.line_start = line_start;

      const { result, error } = await nvim.callApi<DraftComment>(
        "reply_to_thread",
        opts
      );

      if (error) {
        return {
          content: [{ type: "text" as const, text: `Error: ${error}` }],
          isError: true,
        };
      }

      return {
        content: [
          {
            type: "text" as const,
            text:
              `Draft reply created for thread #${thread_id}.\n` +
              `ID: ${result?.id}\n` +
              `Status: ${result?.status} (user must approve before submission)\n\n` +
              `Body:\n${result?.body}`,
          },
        ],
      };
    }
  );
}

// ============================================================================
// edit_draft_comment
// ============================================================================

function registerEditDraftComment(server: McpServer, nvim: NvimClient): void {
  server.tool(
    "edit_draft_comment",
    'Edit the body of an existing draft comment. Only works on comments with status "draft" — approved/submitted comments cannot be edited by AI.',
    {
      draft_id: z.string().describe("The draft comment UUID to edit"),
      new_body: z.string().min(1).describe("New comment body in markdown format"),
    },
    async ({ draft_id, new_body }) => {
      const { result, error } = await nvim.callApi<boolean>(
        "edit_draft_comment",
        draft_id,
        new_body
      );

      if (error) {
        return {
          content: [{ type: "text" as const, text: `Error: ${error}` }],
          isError: true,
        };
      }

      return {
        content: [
          {
            type: "text" as const,
            text: result
              ? `Draft ${draft_id} updated successfully.`
              : `Failed to update draft ${draft_id}.`,
          },
        ],
      };
    }
  );
}

// ============================================================================
// delete_draft_comment
// ============================================================================

function registerDeleteDraftComment(server: McpServer, nvim: NvimClient): void {
  server.tool(
    "delete_draft_comment",
    'Delete a draft comment. Only works on comments with status "draft" — approved/submitted comments cannot be deleted by AI.',
    {
      draft_id: z.string().describe("The draft comment UUID to delete"),
    },
    async ({ draft_id }) => {
      const { result, error } = await nvim.callApi<boolean>(
        "delete_draft_comment",
        draft_id
      );

      if (error) {
        return {
          content: [{ type: "text" as const, text: `Error: ${error}` }],
          isError: true,
        };
      }

      return {
        content: [
          {
            type: "text" as const,
            text: result
              ? `Draft ${draft_id} deleted successfully.`
              : `Failed to delete draft ${draft_id}.`,
          },
        ],
      };
    }
  );
}
