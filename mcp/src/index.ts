#!/usr/bin/env node

/**
 * PowerReview MCP Server
 *
 * A Model Context Protocol server that connects to a running Neovim instance
 * with PowerReview.nvim loaded, enabling AI agents to review pull requests.
 *
 * Architecture (Option A: Neovim RPC):
 *   AI Agent <-> MCP Server (stdio) <-> Neovim (msgpack-RPC socket)
 *
 * The server:
 *   1. Reads server_info.json to find the Neovim socket
 *   2. Connects to Neovim via msgpack-RPC
 *   3. Exposes PowerReview API as MCP tools
 *   4. Communicates with AI agents via stdio transport
 *
 * Usage:
 *   npx power-review-mcp
 *   node mcp/dist/index.js
 *
 * Environment variables:
 *   NVIM_SOCKET_PATH / NVIM — Override the Neovim socket path
 *   POWER_REVIEW_SERVER_INFO — Override the server_info.json path
 */

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { createNvimClient, type NvimClient } from "./nvim-client.js";
import { registerTools } from "./tools.js";

// Use console.error for all logging — stdout is reserved for MCP JSON-RPC
const log = {
  info: (msg: string, ...args: unknown[]) =>
    console.error(`[power-review-mcp] INFO: ${msg}`, ...args),
  error: (msg: string, ...args: unknown[]) =>
    console.error(`[power-review-mcp] ERROR: ${msg}`, ...args),
  debug: (msg: string, ...args: unknown[]) => {
    if (process.env.DEBUG) {
      console.error(`[power-review-mcp] DEBUG: ${msg}`, ...args);
    }
  },
};

async function main(): Promise<void> {
  log.info("Starting power-review-mcp server...");

  // Step 1: Connect to Neovim
  let nvim: NvimClient;
  try {
    nvim = await createNvimClient();
    log.info("Connected to Neovim");
  } catch (err) {
    log.error("Failed to connect to Neovim:", err);
    log.error(
      "Ensure Neovim is running with PowerReview.nvim loaded and a review session is active."
    );
    log.error(
      "You can set NVIM_SOCKET_PATH or NVIM to the Neovim socket path."
    );
    process.exit(1);
  }

  // Step 2: Create MCP server
  const server = new McpServer({
    name: "power-review-mcp",
    version: "0.1.0",
  });

  // Step 3: Register all tools
  registerTools(server, nvim);
  log.info("Registered 8 MCP tools");

  // Step 4: Connect via stdio transport
  const transport = new StdioServerTransport();
  await server.connect(transport);
  log.info("MCP server running on stdio");

  // Handle graceful shutdown
  const cleanup = () => {
    log.info("Shutting down...");
    nvim.disconnect();
    process.exit(0);
  };

  process.on("SIGINT", cleanup);
  process.on("SIGTERM", cleanup);
  process.on("SIGHUP", cleanup);
}

main().catch((err) => {
  log.error("Fatal error:", err);
  process.exit(1);
});
