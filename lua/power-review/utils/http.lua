--- PowerReview.nvim HTTP client
--- Uses curl via vim.system for async HTTP requests.
local M = {}

local log = require("power-review.utils.log")

---@class PowerReview.HttpRequest
---@field url string
---@field method? string "GET" | "POST" | "PUT" | "PATCH" | "DELETE" (default "GET")
---@field headers? table<string, string>
---@field body? table|string JSON-serializable table or raw string
---@field timeout? number Timeout in milliseconds (default 30000)

---@class PowerReview.HttpResponse
---@field status number HTTP status code
---@field body string Raw response body
---@field json? table Parsed JSON body (nil if parsing fails)
---@field headers table<string, string> Response headers

--- Perform an async HTTP request
---@param opts PowerReview.HttpRequest
---@param callback fun(err?: string, response?: PowerReview.HttpResponse)
function M.request(opts, callback)
  local method = (opts.method or "GET"):upper()
  local url = opts.url
  local timeout = opts.timeout or 30000

  -- Build curl arguments
  local cmd = {
    "curl",
    "--silent",
    "--show-error",
    "--location", -- follow redirects
    "--max-time", tostring(math.floor(timeout / 1000)),
    "-X", method,
    "-w", "\n__HTTP_STATUS__%{http_code}",
  }

  -- Add headers
  if opts.headers then
    for key, value in pairs(opts.headers) do
      table.insert(cmd, "-H")
      table.insert(cmd, key .. ": " .. value)
    end
  end

  -- Add JSON content type for bodies
  if opts.body then
    table.insert(cmd, "-H")
    table.insert(cmd, "Content-Type: application/json")

    local body_str
    if type(opts.body) == "table" then
      body_str = vim.json.encode(opts.body)
    else
      body_str = opts.body
    end
    table.insert(cmd, "--data-raw")
    table.insert(cmd, body_str)
  end

  table.insert(cmd, url)

  log.debug("HTTP %s %s", method, url)

  vim.system(cmd, { text = true, timeout = timeout }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        local err_msg = result.stderr or ("curl exited with code " .. tostring(result.code))
        log.error("HTTP request failed: %s", err_msg)
        callback(err_msg)
        return
      end

      local stdout = result.stdout or ""

      -- Extract HTTP status code from the trailer we added with -w
      local status_code = nil
      local body = stdout

      local status_marker = "__HTTP_STATUS__"
      local marker_pos = stdout:find(status_marker, 1, true)
      if marker_pos then
        local status_str = stdout:sub(marker_pos + #status_marker)
        status_code = tonumber(status_str:match("(%d+)"))
        body = stdout:sub(1, marker_pos - 1)
        -- Remove trailing newline before the marker
        if body:sub(-1) == "\n" then
          body = body:sub(1, -2)
        end
      end

      status_code = status_code or 0

      -- Try to parse JSON
      local json = nil
      if #body > 0 then
        local ok, parsed = pcall(vim.json.decode, body)
        if ok then
          json = parsed
        end
      end

      local response = {
        status = status_code,
        body = body,
        json = json,
        headers = {},
      }

      log.debug("HTTP %s %s -> %d", method, url, status_code)

      if status_code >= 400 then
        local err_detail = ""
        if json and json.message then
          err_detail = json.message
        elseif json and json.Message then
          err_detail = json.Message
        else
          err_detail = body:sub(1, 200)
        end
        callback(string.format("HTTP %d: %s", status_code, err_detail), response)
      else
        callback(nil, response)
      end
    end)
  end)
end

--- Convenience: GET request
---@param url string
---@param headers? table<string, string>
---@param callback fun(err?: string, response?: PowerReview.HttpResponse)
function M.get(url, headers, callback)
  M.request({ url = url, method = "GET", headers = headers }, callback)
end

--- Convenience: POST request with JSON body
---@param url string
---@param body table
---@param headers? table<string, string>
---@param callback fun(err?: string, response?: PowerReview.HttpResponse)
function M.post(url, body, headers, callback)
  M.request({ url = url, method = "POST", body = body, headers = headers }, callback)
end

--- Convenience: PATCH request with JSON body
---@param url string
---@param body table
---@param headers? table<string, string>
---@param callback fun(err?: string, response?: PowerReview.HttpResponse)
function M.patch(url, body, headers, callback)
  M.request({ url = url, method = "PATCH", body = body, headers = headers }, callback)
end

--- Convenience: PUT request with JSON body
---@param url string
---@param body table
---@param headers? table<string, string>
---@param callback fun(err?: string, response?: PowerReview.HttpResponse)
function M.put(url, body, headers, callback)
  M.request({ url = url, method = "PUT", body = body, headers = headers }, callback)
end

--- Convenience: DELETE request
---@param url string
---@param headers? table<string, string>
---@param callback fun(err?: string, response?: PowerReview.HttpResponse)
function M.delete(url, headers, callback)
  M.request({ url = url, method = "DELETE", headers = headers }, callback)
end

return M
