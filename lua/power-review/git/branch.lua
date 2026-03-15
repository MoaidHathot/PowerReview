--- PowerReview.nvim git branch operations
--- Handles fetching remote branches and regular checkout strategy.
local M = {}

local log = require("power-review.utils.log")

--- Fetch a remote branch
---@param repo_root string
---@param remote string Remote name (usually "origin")
---@param branch string Branch name
---@param callback fun(err?: string)
function M.fetch(repo_root, remote, branch, callback)
  log.info("Fetching %s/%s", remote, branch)

  vim.system(
    { "git", "fetch", remote, branch },
    { text = true, cwd = repo_root, timeout = 60000 },
    function(result)
      vim.schedule(function()
        if result.code ~= 0 then
          callback("Failed to fetch branch: " .. (result.stderr or ""):sub(1, 300))
          return
        end
        log.info("Fetched %s/%s successfully", remote, branch)
        callback(nil)
      end)
    end
  )
end

--- Checkout a branch (regular checkout, no worktree)
---@param repo_root string
---@param branch string
---@param callback fun(err?: string)
function M.checkout(repo_root, branch, callback)
  log.info("Checking out branch %s", branch)

  vim.system(
    { "git", "checkout", branch },
    { text = true, cwd = repo_root, timeout = 30000 },
    function(result)
      vim.schedule(function()
        if result.code ~= 0 then
          local stderr = result.stderr or ""
          -- If local branch doesn't exist, try tracking remote
          if stderr:find("did not match any") or stderr:find("pathspec") then
            M._checkout_tracking(repo_root, branch, callback)
          else
            callback("Failed to checkout: " .. stderr:sub(1, 300))
          end
          return
        end
        log.info("Checked out %s", branch)
        callback(nil)
      end)
    end
  )
end

--- Checkout a branch tracking a remote (git checkout -b <branch> origin/<branch>)
---@param repo_root string
---@param branch string
---@param callback fun(err?: string)
function M._checkout_tracking(repo_root, branch, callback)
  vim.system(
    { "git", "checkout", "--track", "origin/" .. branch },
    { text = true, cwd = repo_root, timeout = 30000 },
    function(result)
      vim.schedule(function()
        if result.code ~= 0 then
          callback("Failed to checkout tracking branch: " .. (result.stderr or ""):sub(1, 300))
          return
        end
        log.info("Checked out %s (tracking origin/%s)", branch, branch)
        callback(nil)
      end)
    end
  )
end

--- Stash current changes before switching branches
---@param repo_root string
---@param callback fun(err?: string, stash_created?: boolean)
function M.stash(repo_root, callback)
  log.info("Stashing current changes")

  -- Check if there are changes to stash
  vim.system(
    { "git", "status", "--porcelain" },
    { text = true, cwd = repo_root, timeout = 10000 },
    function(result)
      vim.schedule(function()
        if result.code ~= 0 then
          callback("Failed to check git status: " .. (result.stderr or ""))
          return
        end

        local stdout = result.stdout or ""
        if stdout:gsub("%s+", "") == "" then
          -- No changes to stash
          log.debug("No changes to stash")
          callback(nil, false)
          return
        end

        -- Stash changes
        vim.system(
          { "git", "stash", "push", "-m", "PowerReview: auto-stash before review" },
          { text = true, cwd = repo_root, timeout = 15000 },
          function(stash_result)
            vim.schedule(function()
              if stash_result.code ~= 0 then
                callback("Failed to stash changes: " .. (stash_result.stderr or ""):sub(1, 200))
                return
              end
              log.info("Changes stashed successfully")
              callback(nil, true)
            end)
          end
        )
      end)
    end
  )
end

--- Pop the most recent stash
---@param repo_root string
---@param callback fun(err?: string)
function M.stash_pop(repo_root, callback)
  log.info("Popping stash")

  vim.system(
    { "git", "stash", "pop" },
    { text = true, cwd = repo_root, timeout = 15000 },
    function(result)
      vim.schedule(function()
        if result.code ~= 0 then
          callback("Failed to pop stash: " .. (result.stderr or ""):sub(1, 200))
          return
        end
        log.info("Stash popped successfully")
        callback(nil)
      end)
    end
  )
end

--- Get the current branch name
---@param repo_root string
---@param callback fun(err?: string, branch?: string)
function M.get_current_branch(repo_root, callback)
  vim.system(
    { "git", "rev-parse", "--abbrev-ref", "HEAD" },
    { text = true, cwd = repo_root, timeout = 10000 },
    function(result)
      vim.schedule(function()
        if result.code ~= 0 then
          callback("Failed to get current branch: " .. (result.stderr or ""))
          return
        end
        local branch = (result.stdout or ""):gsub("%s+$", "")
        callback(nil, branch)
      end)
    end
  )
end

--- Get the git repository root for a given path
---@param path string Any path inside the repo
---@param callback fun(err?: string, root?: string)
function M.get_repo_root(path, callback)
  local cwd = vim.fn.fnamemodify(path, ":p:h")
  -- Ensure cwd is a directory
  if vim.fn.isdirectory(cwd) ~= 1 then
    cwd = vim.fn.fnamemodify(cwd, ":h")
  end

  vim.system(
    { "git", "rev-parse", "--show-toplevel" },
    { text = true, cwd = cwd, timeout = 10000 },
    function(result)
      vim.schedule(function()
        if result.code ~= 0 then
          callback("Not a git repository: " .. cwd)
          return
        end
        local root = (result.stdout or ""):gsub("%s+$", "")
        callback(nil, root)
      end)
    end
  )
end

--- Fetch and checkout a remote branch (combined operation for checkout strategy)
---@param repo_root string
---@param remote string
---@param branch string
---@param callback fun(err?: string)
function M.fetch_and_checkout(repo_root, remote, branch, callback)
  M.fetch(repo_root, remote, branch, function(fetch_err)
    if fetch_err then
      callback(fetch_err)
      return
    end
    M.checkout(repo_root, branch, callback)
  end)
end

return M
