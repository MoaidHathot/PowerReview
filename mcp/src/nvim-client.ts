/**
 * PowerReview MCP — Neovim RPC client
 *
 * Connects to a running Neovim instance via msgpack-RPC socket and provides
 * typed wrappers around the PowerReview Lua API.
 */

import { attach, type NeovimClient } from "neovim";
import type { VimValue } from "neovim/lib/types/VimValue.js";
import { readFileSync, existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

export interface ServerInfo {
  socket: string;
  pid: number;
  session_active: boolean;
  pr_id?: number;
  updated_at: string;
}

/**
 * Resolve the path to the server_info.json file.
 * Follows the same logic as the Lua side: stdpath("data")/power-review/server_info.json
 *
 * On Windows: ~/AppData/Local/nvim-data/power-review/server_info.json
 * On Unix:    ~/.local/share/nvim/power-review/server_info.json
 */
function getServerInfoPath(): string {
  // Allow override via env var
  const envPath = process.env.POWER_REVIEW_SERVER_INFO;
  if (envPath) return envPath;

  const home = homedir();
  if (process.platform === "win32") {
    return join(
      home,
      "AppData",
      "Local",
      "nvim-data",
      "power-review",
      "server_info.json"
    );
  }
  return join(home, ".local", "share", "nvim", "power-review", "server_info.json");
}

/**
 * Read the server info written by the Neovim plugin.
 */
export function readServerInfo(): ServerInfo | null {
  // Allow socket override via env var (for direct connection without server_info.json)
  const envSocket = process.env.NVIM_SOCKET_PATH || process.env.NVIM;
  if (envSocket) {
    return {
      socket: envSocket,
      pid: 0,
      session_active: true,
      updated_at: new Date().toISOString(),
    };
  }

  const infoPath = getServerInfoPath();
  if (!existsSync(infoPath)) {
    return null;
  }

  try {
    const raw = readFileSync(infoPath, "utf-8");
    return JSON.parse(raw) as ServerInfo;
  } catch {
    return null;
  }
}

/**
 * Wrapper around the Neovim RPC connection that provides typed access
 * to the PowerReview Lua API.
 */
export class NvimClient {
  private nvim: NeovimClient | null = null;
  private socketPath: string;

  constructor(socketPath: string) {
    this.socketPath = socketPath;
  }

  /**
   * Connect to the Neovim instance.
   */
  async connect(): Promise<void> {
    if (this.nvim) return;

    this.nvim = attach({
      socket: this.socketPath,
    });

    // Verify the connection works
    try {
      const version = await this.nvim.commandOutput("version");
      if (!version) {
        throw new Error("Empty version response");
      }
    } catch (err) {
      this.nvim = null;
      throw new Error(
        `Failed to connect to Neovim at ${this.socketPath}: ${err}`
      );
    }
  }

  /**
   * Disconnect from Neovim.
   */
  disconnect(): void {
    if (this.nvim) {
      this.nvim.quit();
      this.nvim = null;
    }
  }

  /**
   * Check if connected.
   */
  isConnected(): boolean {
    return this.nvim !== null;
  }

  /**
   * Execute a Lua expression in Neovim and return the JSON-encoded result.
   * The Lua code should return a value; it will be JSON-encoded on the Neovim side.
   */
  async execLua<T = unknown>(luaCode: string, args: VimValue[] = []): Promise<T> {
    if (!this.nvim) {
      throw new Error("Not connected to Neovim");
    }
    const result = await this.nvim.executeLua(luaCode, args);
    return result as T;
  }

  /**
   * Call a PowerReview API function and return the result.
   * Handles the Lua -> JSON -> TypeScript serialization.
   *
   * The Lua API functions return (result, error) tuples.
   * We encode them as JSON on the Neovim side and parse here.
   */
  async callApi<T = unknown>(
    method: string,
    ...args: unknown[]
  ): Promise<{ result: T | null; error: string | null }> {
    const argsJson = JSON.stringify(args);
    const luaCode = `
      local args = vim.json.decode(...)
      local api = require('power-review').api
      local fn = api['${method}']
      if not fn then
        return vim.json.encode({ result = vim.NIL, error = 'Unknown API method: ${method}' })
      end
      local results = { fn(unpack(args)) }
      return vim.json.encode({ result = results[1], error = results[2] })
    `;
    const raw = await this.execLua<string>(luaCode, [argsJson]);
    try {
      const parsed = JSON.parse(raw);
      return {
        result: parsed.result === null ? null : (parsed.result as T),
        error: parsed.error ?? null,
      };
    } catch {
      return { result: null, error: `Failed to parse API response: ${raw}` };
    }
  }

  /**
   * Call a PowerReview API function that uses a callback pattern.
   * These functions take a callback(err, result) as their last argument.
   *
   * We use a correlation ID + Lua coroutine wrapper to make it synchronous
   * from the RPC perspective.
   */
  async callApiAsync<T = unknown>(
    method: string,
    ...args: unknown[]
  ): Promise<{ result: T | null; error: string | null }> {
    const argsJson = JSON.stringify(args);
    const luaCode = `
      local args = vim.json.decode(...)
      local api = require('power-review').api
      local fn = api['${method}']
      if not fn then
        return vim.json.encode({ result = vim.NIL, error = 'Unknown API method: ${method}' })
      end
      -- For async API calls, we use a blocking pattern with vim.wait
      local done = false
      local cb_result = nil
      local cb_error = nil
      local cb = function(err, result)
        cb_error = err
        cb_result = result
        done = true
      end
      table.insert(args, cb)
      fn(unpack(args))
      -- Wait up to 30 seconds for the callback
      vim.wait(30000, function() return done end, 100)
      if not done then
        return vim.json.encode({ result = vim.NIL, error = 'API call timed out after 30s' })
      end
      return vim.json.encode({ result = cb_result, error = cb_error })
    `;
    const raw = await this.execLua<string>(luaCode, [argsJson]);
    try {
      const parsed = JSON.parse(raw);
      return {
        result: parsed.result === null ? null : (parsed.result as T),
        error: parsed.error ?? null,
      };
    } catch {
      return { result: null, error: `Failed to parse async API response: ${raw}` };
    }
  }

  /**
   * Get the raw Neovim client for direct access if needed.
   */
  getRawClient(): NeovimClient | null {
    return this.nvim;
  }
}

/**
 * Create and connect a NvimClient using auto-discovered server info.
 */
export async function createNvimClient(): Promise<NvimClient> {
  const info = readServerInfo();
  if (!info) {
    throw new Error(
      "Cannot find PowerReview server info. " +
      "Ensure Neovim is running with PowerReview.nvim loaded. " +
      "Set NVIM_SOCKET_PATH or NVIM env var to connect directly."
    );
  }

  if (!info.socket) {
    throw new Error(
      "Neovim socket path is empty in server info. " +
      "Ensure Neovim was started with --listen or has a valid servername."
    );
  }

  const client = new NvimClient(info.socket);
  await client.connect();
  return client;
}
