--- PowerReview.nvim git worktree operations
local M = {}

local log = require("power-review.utils.log")

--- Create a git worktree for a PR review branch.
--- If the main repo is already on the target branch, skips worktree creation
--- and returns the repo root directly (with result.reused_main = true).
---@param repo_root string Absolute path to the main repository root
---@param branch string The branch to create the worktree for
---@param pr_id number|string Used to name the worktree directory
---@param callback fun(err?: string, worktree_path?: string, info?: table)
function M.create(repo_root, branch, pr_id, callback)
  local branch_mod = require("power-review.git.branch")

  -- Check if the main working tree is already on the target branch
  branch_mod.get_current_branch(repo_root, function(branch_err, current_branch)
    if not branch_err and current_branch and current_branch == branch then
      log.info("Main working tree is already on branch '%s', skipping worktree creation", branch)
      callback(nil, repo_root, { reused_main = true })
      return
    end

    -- Proceed with normal worktree creation
    M._do_create(repo_root, branch, pr_id, callback)
  end)
end

--- Internal: actually create the worktree (after branch check)
---@param repo_root string
---@param branch string
---@param pr_id number|string
---@param callback fun(err?: string, worktree_path?: string, info?: table)
function M._do_create(repo_root, branch, pr_id, callback)
  local config = require("power-review.config")
  local git_config = config.get_git_config()
  local worktree_base = git_config.worktree_dir or ".power-review-worktrees"

  local worktree_path = repo_root .. "/" .. worktree_base .. "/" .. tostring(pr_id)

  -- Normalize path separators
  worktree_path = worktree_path:gsub("\\", "/")

  log.info("Creating worktree at %s for branch %s", worktree_path, branch)

  -- Create parent directory if needed
  vim.fn.mkdir(vim.fn.fnamemodify(worktree_path, ":h"), "p")

  -- First, check if worktree already exists
  M.list(repo_root, function(err, worktrees)
    if err then
      -- Not fatal, proceed with creation attempt
      log.debug("Could not list worktrees: %s", err)
    else
      for _, wt in ipairs(worktrees or {}) do
        if wt.path:gsub("\\", "/") == worktree_path then
          log.info("Worktree already exists at %s", worktree_path)
          callback(nil, worktree_path)
          return
        end
      end
    end

    -- Create the worktree
    vim.system(
      { "git", "worktree", "add", worktree_path, branch },
      { text = true, cwd = repo_root, timeout = 30000 },
      function(result)
        vim.schedule(function()
          if result.code ~= 0 then
            local stderr = result.stderr or ""
            -- If branch doesn't exist locally, try creating from remote
            if stderr:find("not a valid reference") or stderr:find("invalid reference") then
              M._create_with_remote_branch(repo_root, worktree_path, branch, callback)
            else
              callback("Failed to create worktree: " .. stderr:sub(1, 300))
            end
            return
          end

          log.info("Worktree created at %s", worktree_path)
          callback(nil, worktree_path)
        end)
      end
    )
  end)
end

--- Create a worktree tracking a remote branch that might not exist locally
---@param repo_root string
---@param worktree_path string
---@param branch string
---@param callback fun(err?: string, worktree_path?: string)
function M._create_with_remote_branch(repo_root, worktree_path, branch, callback)
  -- Try to create with explicit remote tracking
  local remote_ref = "origin/" .. branch

  vim.system(
    { "git", "worktree", "add", "--track", "-b", branch, worktree_path, remote_ref },
    { text = true, cwd = repo_root, timeout = 30000 },
    function(result)
      vim.schedule(function()
        if result.code ~= 0 then
          callback("Failed to create worktree from remote: " .. (result.stderr or ""):sub(1, 300))
          return
        end

        log.info("Worktree created at %s (tracking %s)", worktree_path, remote_ref)
        callback(nil, worktree_path)
      end)
    end
  )
end

--- Remove a git worktree
---@param worktree_path string Absolute path to the worktree
---@param callback fun(err?: string)
function M.remove(worktree_path, callback)
  log.info("Removing worktree at %s", worktree_path)

  -- Find the main repo root from the worktree
  vim.system(
    { "git", "rev-parse", "--git-common-dir" },
    { text = true, cwd = worktree_path, timeout = 10000 },
    function(result)
      vim.schedule(function()
        local repo_root
        if result.code == 0 and result.stdout then
          -- git-common-dir returns the .git dir of the main repo
          local git_dir = result.stdout:gsub("%s+$", "")
          repo_root = vim.fn.fnamemodify(git_dir, ":h")
        end

        -- Use force remove since review worktrees might have untracked files
        local cmd_cwd = repo_root or worktree_path
        vim.system(
          { "git", "worktree", "remove", "--force", worktree_path },
          { text = true, cwd = cmd_cwd, timeout = 15000 },
          function(rm_result)
            vim.schedule(function()
              if rm_result.code ~= 0 then
                -- Try to just delete the directory if git worktree remove fails
                log.warn("git worktree remove failed, trying directory cleanup: %s", (rm_result.stderr or ""):sub(1, 200))
                local ok = pcall(function()
                  vim.fn.delete(worktree_path, "rf")
                end)
                if ok then
                  -- Also try to prune stale worktree entries
                  if repo_root then
                    vim.system(
                      { "git", "worktree", "prune" },
                      { text = true, cwd = repo_root },
                      function() end
                    )
                  end
                  callback(nil)
                else
                  callback("Failed to remove worktree directory: " .. worktree_path)
                end
                return
              end

              log.info("Worktree removed: %s", worktree_path)
              callback(nil)
            end)
          end
        )
      end)
    end
  )
end

--- List existing worktrees for a repository
---@param repo_root string
---@param callback fun(err?: string, worktrees?: table[])
function M.list(repo_root, callback)
  vim.system(
    { "git", "worktree", "list", "--porcelain" },
    { text = true, cwd = repo_root, timeout = 10000 },
    function(result)
      vim.schedule(function()
        if result.code ~= 0 then
          callback("Failed to list worktrees: " .. (result.stderr or ""))
          return
        end

        local worktrees = {}
        local current = {}

        for line in (result.stdout or ""):gmatch("[^\n]+") do
          if line:match("^worktree ") then
            if current.path then
              table.insert(worktrees, current)
            end
            current = { path = line:match("^worktree (.+)") }
          elseif line:match("^HEAD ") then
            current.head = line:match("^HEAD (.+)")
          elseif line:match("^branch ") then
            current.branch = line:match("^branch (.+)")
          elseif line == "bare" then
            current.bare = true
          end
        end

        if current.path then
          table.insert(worktrees, current)
        end

        callback(nil, worktrees)
      end)
    end
  )
end

return M
