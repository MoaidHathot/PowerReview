--- PowerReview.nvim JSON persistence backend
local M = {}

local log = require("power-review.utils.log")

--- Get the base storage directory
---@return string
function M.get_store_dir()
  local data_dir = vim.fn.stdpath("data")
  return data_dir .. "/power-review/sessions"
end

--- Ensure the store directory exists
function M._ensure_dir()
  local dir = M.get_store_dir()
  if vim.fn.isdirectory(dir) ~= 1 then
    vim.fn.mkdir(dir, "p")
  end
end

--- Write data to a JSON file
---@param filename string Filename (without path)
---@param data table Data to serialize
---@return boolean success, string|nil error
function M.write(filename, data)
  M._ensure_dir()
  local path = M.get_store_dir() .. "/" .. filename

  local ok, json_str = pcall(vim.json.encode, data)
  if not ok then
    return false, "Failed to encode JSON: " .. tostring(json_str)
  end

  -- Write atomically: write to temp file, then rename
  local tmp_path = path .. ".tmp"
  local file, err = io.open(tmp_path, "w")
  if not file then
    return false, "Failed to open file for writing: " .. (err or tmp_path)
  end

  file:write(json_str)
  file:close()

  -- Rename tmp to final
  local rename_ok, rename_err = os.rename(tmp_path, path)
  if not rename_ok then
    -- On Windows, os.rename fails if target exists; try removing first
    os.remove(path)
    rename_ok, rename_err = os.rename(tmp_path, path)
    if not rename_ok then
      os.remove(tmp_path)
      return false, "Failed to write session file: " .. (rename_err or "")
    end
  end

  log.debug("Saved session to %s", path)
  return true, nil
end

--- Read data from a JSON file
---@param filename string Filename (without path)
---@return table|nil data, string|nil error
function M.read(filename)
  local path = M.get_store_dir() .. "/" .. filename

  local file, err = io.open(path, "r")
  if not file then
    return nil, "File not found: " .. (err or path)
  end

  local content = file:read("*all")
  file:close()

  if not content or content == "" then
    return nil, "Empty file: " .. path
  end

  local ok, data = pcall(vim.json.decode, content)
  if not ok then
    return nil, "Failed to parse JSON: " .. tostring(data)
  end

  return data, nil
end

--- Delete a JSON file
---@param filename string Filename (without path)
---@return boolean success, string|nil error
function M.delete(filename)
  local path = M.get_store_dir() .. "/" .. filename
  local ok = os.remove(path)
  if not ok then
    return false, "Failed to delete file: " .. path
  end
  log.debug("Deleted session file: %s", path)
  return true, nil
end

--- List all JSON files in the store directory
---@return string[] filenames
function M.list_files()
  M._ensure_dir()
  local dir = M.get_store_dir()
  local files = {}

  -- Use vim.fn.glob to list .json files
  local pattern = dir .. "/*.json"
  local matches = vim.fn.glob(pattern, false, true)

  for _, full_path in ipairs(matches) do
    local filename = vim.fn.fnamemodify(full_path, ":t")
    table.insert(files, filename)
  end

  return files
end

return M
