--- PowerReview.nvim Azure DevOps provider
--- Implements the Provider interface for Azure DevOps REST API (api-version=7.1)
local M = {}

local http = require("power-review.utils.http")
local log = require("power-review.utils.log")
local url_util = require("power-review.utils.url")

--- AzDO API version
local API_VERSION = "7.1"

---@class PowerReview.AzDOProvider : PowerReview.Provider
---@field type "azdo"
---@field _org string
---@field _project string
---@field _repo string
---@field _auth_header string
---@field _base_url string

--- Create a new AzDO provider instance
---@param opts table { organization: string, project: string, repository: string, auth_header: string }
---@return PowerReview.AzDOProvider
function M.new(opts)
  local self = {}
  self.type = "azdo"
  self._org = opts.organization
  self._project = opts.project
  self._repo = opts.repository
  self._auth_header = opts.auth_header
  self._base_url = string.format(
    "https://dev.azure.com/%s/%s/_apis/git/repositories/%s",
    url_util.url_encode(self._org),
    url_util.url_encode(self._project),
    url_util.url_encode(self._repo)
  )

  setmetatable(self, { __index = M })
  return self
end

--- Build request headers with auth
---@param self PowerReview.AzDOProvider
---@return table<string, string>
function M:_headers()
  return {
    ["Authorization"] = self._auth_header,
    ["Accept"] = "application/json",
  }
end

--- Build a full API URL with api-version query parameter
---@param self PowerReview.AzDOProvider
---@param path string Path relative to the repo API base
---@param extra_params? table<string, string> Additional query parameters
---@return string
function M:_url(path, extra_params)
  local separator = "?"
  if path:find("?") then
    separator = "&"
  end
  local full_url = self._base_url .. path .. separator .. "api-version=" .. API_VERSION

  if extra_params then
    for k, v in pairs(extra_params) do
      full_url = full_url .. "&" .. url_util.url_encode(k) .. "=" .. url_util.url_encode(v)
    end
  end

  return full_url
end

--- Get pull request details
---@param self PowerReview.AzDOProvider
---@param pr_id number
---@param callback fun(err?: string, pr?: PowerReview.PR)
function M:get_pull_request(pr_id, callback)
  local api_url = self:_url("/pullrequests/" .. pr_id)

  http.get(api_url, self:_headers(), function(err, response)
    if err then
      callback(err)
      return
    end

    local data = response.json
    if not data then
      callback("Failed to parse PR response")
      return
    end

    -- Parse reviewers
    local reviewers = {}
    if data.reviewers then
      for _, r in ipairs(data.reviewers) do
        table.insert(reviewers, {
          name = r.displayName or "Unknown",
          id = r.id,
          unique_name = r.uniqueName,
          vote = r.vote ~= 0 and r.vote or nil,
          is_required = r.isRequired or false,
        })
      end
    end

    -- Parse labels
    local labels = {}
    if data.labels then
      for _, label in ipairs(data.labels) do
        if label.name then
          table.insert(labels, label.name)
        end
      end
    end

    -- Parse work item refs
    local work_items = {}
    if data.workItemRefs then
      for _, wi in ipairs(data.workItemRefs) do
        table.insert(work_items, {
          id = tonumber(wi.id) or 0,
          title = wi.title,
          url = wi.url,
        })
      end
    end

    ---@type PowerReview.PR
    local pr = {
      id = data.pullRequestId,
      title = data.title or "",
      description = data.description or "",
      author = (data.createdBy and data.createdBy.displayName) or "Unknown",
      author_id = data.createdBy and data.createdBy.id or nil,
      author_unique_name = data.createdBy and data.createdBy.uniqueName or nil,
      source_branch = M._strip_refs_prefix(data.sourceRefName or ""),
      target_branch = M._strip_refs_prefix(data.targetRefName or ""),
      status = M._parse_pr_status(data.status),
      url = data.url or "",
      created_at = data.creationDate or "",
      closed_at = data.closedDate,
      is_draft = data.isDraft or false,
      merge_status = M._parse_merge_status(data.mergeStatus),
      reviewers = reviewers,
      labels = labels,
      work_items = work_items,
      provider_type = "azdo",
      provider_data = data,
    }

    callback(nil, pr)
  end)
end

--- Get the list of changed files in the PR
--- Uses the iterations API to get accurate file changes.
---@param self PowerReview.AzDOProvider
---@param pr_id number
---@param callback fun(err?: string, files?: PowerReview.ChangedFile[])
function M:get_changed_files(pr_id, callback)
  -- First get iterations to find the latest one
  local iter_url = self:_url("/pullrequests/" .. pr_id .. "/iterations")

  http.get(iter_url, self:_headers(), function(err, response)
    if err then
      callback(err)
      return
    end

    local data = response.json
    if not data or not data.value or #data.value == 0 then
      callback("No iterations found for PR")
      return
    end

    -- Get the latest iteration
    local latest_iteration = data.value[#data.value]
    local iteration_id = latest_iteration.id

    -- Extract iteration metadata (commit SHAs)
    ---@type PowerReview.IterationMeta
    local iter_meta = {
      iteration_id = iteration_id,
      source_commit = latest_iteration.sourceRefCommit and latest_iteration.sourceRefCommit.commitId or nil,
      target_commit = latest_iteration.targetRefCommit and latest_iteration.targetRefCommit.commitId or nil,
    }

    -- Now get changes for this iteration
    local changes_url = self:_url(
      "/pullrequests/" .. pr_id .. "/iterations/" .. iteration_id .. "/changes"
    )

    http.get(changes_url, self:_headers(), function(changes_err, changes_response)
      if changes_err then
        callback(changes_err)
        return
      end

      local changes_data = changes_response.json
      if not changes_data or not changes_data.changeEntries then
        callback("No changes found in iteration")
        return
      end

      ---@type PowerReview.ChangedFile[]
      local files = {}

      for _, entry in ipairs(changes_data.changeEntries) do
        local change_type = M._map_change_type(entry.changeType)
        -- Skip tree (folder) entries, only include files (blob)
        if entry.item and entry.item.gitObjectType ~= "tree" then
          local file = {
            path = entry.item.path or "",
            original_path = entry.originalPath,
            change_type = change_type,
          }
          -- Remove leading slash from path if present
          if file.path:sub(1, 1) == "/" then
            file.path = file.path:sub(2)
          end
          if file.original_path and file.original_path:sub(1, 1) == "/" then
            file.original_path = file.original_path:sub(2)
          end
          table.insert(files, file)
        end
      end

      callback(nil, files, iter_meta)
    end)
  end)
end

--- Get all comment threads for a PR
---@param self PowerReview.AzDOProvider
---@param pr_id number
---@param callback fun(err?: string, threads?: PowerReview.CommentThread[])
function M:get_threads(pr_id, callback)
  local api_url = self:_url("/pullrequests/" .. pr_id .. "/threads")

  http.get(api_url, self:_headers(), function(err, response)
    if err then
      callback(err)
      return
    end

    local data = response.json
    if not data or not data.value then
      callback("Failed to parse threads response")
      return
    end

    ---@type PowerReview.CommentThread[]
    local threads = {}

    for _, raw_thread in ipairs(data.value) do
      -- Skip system threads (e.g., vote change notifications)
      if not M._is_system_thread(raw_thread) then
        local thread = M._parse_thread(raw_thread)
        table.insert(threads, thread)
      end
    end

    callback(nil, threads)
  end)
end

--- Create a new comment thread on a PR
---@param self PowerReview.AzDOProvider
---@param pr_id number
---@param thread table { file_path?: string, line_start?: number, line_end?: number, body: string, status?: string }
---@param callback fun(err?: string, thread?: PowerReview.CommentThread)
function M:create_thread(pr_id, thread, callback)
  local api_url = self:_url("/pullrequests/" .. pr_id .. "/threads")

  local request_body = {
    comments = {
      {
        parentCommentId = 0,
        content = thread.body,
        commentType = 1, -- text
      },
    },
    status = M._thread_status_to_api(thread.status or "active"),
  }

  -- Add thread context for file-level comments
  if thread.file_path then
    local file_path = thread.file_path
    -- Ensure leading slash for AzDO API
    if file_path:sub(1, 1) ~= "/" then
      file_path = "/" .. file_path
    end

    request_body.threadContext = {
      filePath = file_path,
    }

    if thread.line_start then
      request_body.threadContext.rightFileStart = {
        line = thread.line_start,
        offset = thread.col_start or 1,
      }
      request_body.threadContext.rightFileEnd = {
        line = thread.line_end or thread.line_start,
        offset = thread.col_end or 1,
      }
    end
  end

  http.post(api_url, request_body, self:_headers(), function(err, response)
    if err then
      callback(err)
      return
    end

    local data = response.json
    if not data then
      callback("Failed to parse create thread response")
      return
    end

    callback(nil, M._parse_thread(data))
  end)
end

--- Reply to an existing thread
---@param self PowerReview.AzDOProvider
---@param pr_id number
---@param thread_id number
---@param body string Comment body (markdown)
---@param callback fun(err?: string, comment?: PowerReview.Comment)
function M:reply_to_thread(pr_id, thread_id, body, callback)
  local api_url = self:_url(
    "/pullrequests/" .. pr_id .. "/threads/" .. thread_id .. "/comments"
  )

  local request_body = {
    content = body,
    commentType = 1,
  }

  http.post(api_url, request_body, self:_headers(), function(err, response)
    if err then
      callback(err)
      return
    end

    local data = response.json
    if not data then
      callback("Failed to parse reply response")
      return
    end

    callback(nil, M._parse_comment(data, thread_id))
  end)
end

--- Update an existing comment
---@param self PowerReview.AzDOProvider
---@param pr_id number
---@param thread_id number
---@param comment_id number
---@param body string New comment body
---@param callback fun(err?: string, comment?: PowerReview.Comment)
function M:update_comment(pr_id, thread_id, comment_id, body, callback)
  local api_url = self:_url(
    "/pullrequests/" .. pr_id .. "/threads/" .. thread_id .. "/comments/" .. comment_id
  )

  local request_body = {
    content = body,
  }

  http.patch(api_url, request_body, self:_headers(), function(err, response)
    if err then
      callback(err)
      return
    end

    local data = response.json
    if not data then
      callback("Failed to parse update response")
      return
    end

    callback(nil, M._parse_comment(data, thread_id))
  end)
end

--- Delete a comment
---@param self PowerReview.AzDOProvider
---@param pr_id number
---@param thread_id number
---@param comment_id number
---@param callback fun(err?: string, ok?: boolean)
function M:delete_comment(pr_id, thread_id, comment_id, callback)
  local api_url = self:_url(
    "/pullrequests/" .. pr_id .. "/threads/" .. thread_id .. "/comments/" .. comment_id
  )

  http.delete(api_url, self:_headers(), function(err, _response)
    if err then
      callback(err)
      return
    end
    callback(nil, true)
  end)
end

--- Set review vote for the current user
---@param self PowerReview.AzDOProvider
---@param pr_id number
---@param reviewer_id string The reviewer's ID (usually current user's ID)
---@param vote PowerReview.ReviewVote
---@param callback fun(err?: string, ok?: boolean)
function M:set_vote(pr_id, reviewer_id, vote, callback)
  local api_url = self:_url(
    "/pullrequests/" .. pr_id .. "/reviewers/" .. reviewer_id
  )

  local request_body = {
    vote = vote,
  }

  http.put(api_url, request_body, self:_headers(), function(err, _response)
    if err then
      callback(err)
      return
    end
    callback(nil, true)
  end)
end

--- Get file content at a specific version
---@param self PowerReview.AzDOProvider
---@param pr_id number
---@param file_path string
---@param version string Branch name or commit SHA
---@param callback fun(err?: string, content?: string)
function M:get_file_content(pr_id, file_path, version, callback)
  -- Ensure leading slash
  local path = file_path
  if path:sub(1, 1) ~= "/" then
    path = "/" .. path
  end

  local api_url = self:_url("/items", {
    path = path,
    ["versionDescriptor.version"] = version,
    ["versionDescriptor.versionType"] = "branch",
    ["$format"] = "text",
  })

  http.get(api_url, self:_headers(), function(err, response)
    if err then
      callback(err)
      return
    end
    callback(nil, response.body)
  end)
end

--- Get the current user's identity (needed for set_vote)
---@param self PowerReview.AzDOProvider
---@param pr_id number
---@param callback fun(err?: string, reviewer_id?: string)
function M:get_current_reviewer_id(pr_id, callback)
  -- Fetch the PR reviewers and find the one matching the current user
  -- Alternative: use the _apis/connectionData endpoint
  local connection_url = string.format(
    "https://dev.azure.com/%s/_apis/connectionData",
    url_util.url_encode(self._org)
  )
  -- Add api-version manually since this isn't a repo-scoped endpoint
  connection_url = connection_url .. "?api-version=" .. API_VERSION

  http.get(connection_url, self:_headers(), function(err, response)
    if err then
      callback(err)
      return
    end

    local data = response.json
    if not data or not data.authenticatedUser then
      callback("Failed to get current user identity")
      return
    end

    local user_id = data.authenticatedUser.id
    if not user_id then
      callback("Current user has no ID")
      return
    end

    callback(nil, user_id)
  end)
end

-- ===== Internal helpers =====

--- Strip refs/heads/ prefix from branch names
---@param ref string
---@return string
function M._strip_refs_prefix(ref)
  return (ref:gsub("^refs/heads/", ""))
end

--- Map AzDO change type to our enum
---@param azdo_type string|number
---@return PowerReview.FileChangeType
function M._map_change_type(azdo_type)
  -- AzDO uses string values or numeric enums
  local type_str = tostring(azdo_type):lower()
  if type_str == "add" or type_str == "1" then
    return "add"
  elseif type_str == "edit" or type_str == "2" then
    return "edit"
  elseif type_str == "delete" or type_str == "16" then
    return "delete"
  elseif type_str == "rename" or type_str == "8" then
    return "rename"
  else
    return "edit" -- default fallback
  end
end

--- Check if a thread is a system-generated thread (vote changes, status updates, etc.)
---@param raw_thread table
---@return boolean
function M._is_system_thread(raw_thread)
  if not raw_thread.comments or #raw_thread.comments == 0 then
    return true
  end
  -- System threads have commentType = "system" (or 2)
  local first_comment = raw_thread.comments[1]
  if first_comment.commentType == "system" or first_comment.commentType == 2 then
    return true
  end
  return false
end

--- Parse a raw AzDO thread into our CommentThread type
---@param raw table
---@return PowerReview.CommentThread
function M._parse_thread(raw)
  local file_path = nil
  local line_start = nil
  local line_end = nil
  local col_start = nil
  local col_end = nil
  local left_line_start = nil
  local left_line_end = nil

  if raw.threadContext then
    file_path = raw.threadContext.filePath
    -- Remove leading slash
    if file_path and file_path:sub(1, 1) == "/" then
      file_path = file_path:sub(2)
    end
    if raw.threadContext.rightFileStart then
      line_start = raw.threadContext.rightFileStart.line
      local offset = raw.threadContext.rightFileStart.offset
      if offset and offset > 1 then
        col_start = offset
      end
    end
    if raw.threadContext.rightFileEnd then
      line_end = raw.threadContext.rightFileEnd.line
      local offset = raw.threadContext.rightFileEnd.offset
      if offset and offset > 1 then
        col_end = offset
      end
    end
    -- Left-side (base/target branch) line context
    if raw.threadContext.leftFileStart then
      left_line_start = raw.threadContext.leftFileStart.line
    end
    if raw.threadContext.leftFileEnd then
      left_line_end = raw.threadContext.leftFileEnd.line
    end
  end

  local comments = {}
  if raw.comments then
    for _, raw_comment in ipairs(raw.comments) do
      table.insert(comments, M._parse_comment(raw_comment, raw.id))
    end
  end

  ---@type PowerReview.CommentThread
  return {
    id = raw.id,
    file_path = file_path,
    line_start = line_start,
    line_end = line_end,
    col_start = col_start,
    col_end = col_end,
    left_line_start = left_line_start,
    left_line_end = left_line_end,
    status = M._thread_status_from_api(raw.status),
    comments = comments,
    is_deleted = raw.isDeleted or false,
    published_at = raw.publishedDate,
    updated_at = raw.lastUpdatedDate,
  }
end

--- Parse a raw AzDO comment into our Comment type
---@param raw table
---@param thread_id number
---@return PowerReview.Comment
function M._parse_comment(raw, thread_id)
  local parent_id = raw.parentCommentId
  -- AzDO uses parentCommentId = 0 for top-level comments; normalize to nil
  if parent_id == 0 then
    parent_id = nil
  end

  ---@type PowerReview.Comment
  return {
    id = raw.id,
    thread_id = thread_id,
    author = (raw.author and raw.author.displayName) or "Unknown",
    author_id = raw.author and raw.author.id or nil,
    author_unique_name = raw.author and raw.author.uniqueName or nil,
    parent_comment_id = parent_id,
    body = raw.content or "",
    created_at = raw.publishedDate or "",
    updated_at = raw.lastUpdatedDate or raw.publishedDate or "",
    is_deleted = raw.isDeleted or false,
  }
end

--- Map our thread status to AzDO API status value
---@param status string
---@return number
function M._thread_status_to_api(status)
  local map = {
    active = 1,
    fixed = 2,
    wontfix = 3,
    closed = 4,
    bydesign = 5,
    pending = 6,
  }
  return map[status] or 1
end

--- Map AzDO API status value to our status string
---@param api_status number|string|nil
---@return string
function M._thread_status_from_api(api_status)
  if not api_status then
    return "active"
  end
  local num = tonumber(api_status)
  if num then
    local map = {
      [1] = "active",
      [2] = "fixed",
      [3] = "wontfix",
      [4] = "closed",
      [5] = "bydesign",
      [6] = "pending",
    }
    return map[num] or "active"
  end
  return tostring(api_status):lower()
end

--- Parse AzDO PR status string into our normalized PRStatus
---@param status string|nil
---@return PowerReview.PRStatus
function M._parse_pr_status(status)
  if not status then
    return "active"
  end
  local s = tostring(status):lower()
  if s == "active" then
    return "active"
  elseif s == "completed" then
    return "completed"
  elseif s == "abandoned" then
    return "abandoned"
  end
  return "active"
end

--- Parse AzDO merge status string into our normalized MergeStatus
---@param merge_status string|nil
---@return PowerReview.MergeStatus|nil
function M._parse_merge_status(merge_status)
  if not merge_status then
    return nil
  end
  local s = tostring(merge_status):lower()
  local map = {
    succeeded = "succeeded",
    conflicts = "conflicts",
    queued = "queued",
    notset = "notSet",
    failure = "failure",
  }
  return map[s]
end

return M
