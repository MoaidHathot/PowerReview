--- PowerReview.nvim git operations coordinator
--- High-level interface that dispatches to worktree or checkout strategy.
local M = {}

local log = require("power-review.utils.log")
local worktree = require("power-review.git.worktree")
local branch = require("power-review.git.branch")

--- Setup the git environment for a PR review.
--- Based on the configured strategy (worktree or checkout), this will either:
--- 1. Create a worktree and return its path, OR
--- 2. Stash current changes and checkout the PR branch
---
---@param opts table { repo_root: string, source_branch: string, pr_id: number, strategy?: string }
---@param callback fun(err?: string, result?: table)
---   result: { worktree_path?: string, previous_branch?: string, stash_created?: boolean }
function M.setup_for_review(opts, callback)
  local config = require("power-review.config")
  local git_config = config.get_git_config()
  local strategy = opts.strategy or git_config.strategy or "worktree"

  local repo_root = opts.repo_root
  local source_branch = opts.source_branch
  local pr_id = opts.pr_id

  log.info("Setting up git for review (strategy: %s, branch: %s)", strategy, source_branch)

  -- First, fetch the branch from remote
  branch.fetch(repo_root, "origin", source_branch, function(fetch_err)
    if fetch_err then
      log.warn("Failed to fetch branch (may already exist locally): %s", fetch_err)
      -- Don't fail here; the branch might already exist locally
    end

    if strategy == "worktree" then
      M._setup_worktree(repo_root, source_branch, pr_id, callback)
    elseif strategy == "checkout" then
      M._setup_checkout(repo_root, source_branch, callback)
    else
      callback("Unknown git strategy: " .. strategy)
    end
  end)
end

--- Cleanup git state after a review is closed
---@param session PowerReview.ReviewSession
---@param callback fun(err?: string)
function M.cleanup(session, callback)
  if session.git_strategy == "reused_main" then
    -- We reused the main working tree (was already on the branch); nothing to clean up
    log.info("Review used main working tree; no git cleanup needed.")
    callback(nil)
  elseif session.git_strategy == "worktree" and session.worktree_path then
    worktree.remove(session.worktree_path, callback)
  elseif session.git_strategy == "checkout" then
    -- Restore previous branch if we saved it
    -- This info would be stored in the session or a separate state file
    -- For now, we just notify the user
    log.info("Review closed. You may want to switch back to your working branch.")
    callback(nil)
  else
    callback(nil)
  end
end

--- Get the git repository root for the current buffer
---@param callback fun(err?: string, root?: string)
function M.get_current_repo_root(callback)
  local current_file = vim.api.nvim_buf_get_name(0)
  if current_file == "" then
    current_file = vim.fn.getcwd()
  end
  branch.get_repo_root(current_file, callback)
end

--- Setup using worktree strategy.
--- If the main repo is already on the target branch, skips worktree creation.
--- If worktree creation fails, falls back to the checkout strategy.
---@param repo_root string
---@param source_branch string
---@param pr_id number
---@param callback fun(err?: string, result?: table)
function M._setup_worktree(repo_root, source_branch, pr_id, callback)
  worktree.create(repo_root, source_branch, pr_id, function(err, worktree_path, info)
    if not err and info and info.reused_main then
      -- Already on the correct branch in the main working tree
      log.info("Reusing main working tree (already on branch %s)", source_branch)
      callback(nil, {
        worktree_path = repo_root,
        reused_main = true,
      })
      return
    end

    if err then
      log.warn("Worktree creation failed: %s", err)
      log.info("Falling back to checkout strategy")
      M._setup_checkout(repo_root, source_branch, callback)
      return
    end

    callback(nil, {
      worktree_path = worktree_path,
    })
  end)
end

--- Setup using regular checkout strategy
---@param repo_root string
---@param source_branch string
---@param callback fun(err?: string, result?: table)
function M._setup_checkout(repo_root, source_branch, callback)
  -- First save the current branch
  branch.get_current_branch(repo_root, function(branch_err, current_branch)
    if branch_err then
      callback("Failed to get current branch: " .. branch_err)
      return
    end

    -- Stash any current changes
    branch.stash(repo_root, function(stash_err, stash_created)
      if stash_err then
        callback("Failed to stash changes: " .. stash_err)
        return
      end

      -- Checkout the PR branch
      branch.checkout(repo_root, source_branch, function(checkout_err)
        if checkout_err then
          -- Try to restore state on failure
          if stash_created then
            branch.stash_pop(repo_root, function() end)
          end
          callback("Failed to checkout PR branch: " .. checkout_err)
          return
        end

        callback(nil, {
          previous_branch = current_branch,
          stash_created = stash_created,
        })
      end)
    end)
  end)
end

return M
