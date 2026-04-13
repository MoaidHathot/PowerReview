--- PowerReview.nvim fzf-lua pickers
--- Provides pickers for changed files, comments, and sessions using fzf-lua.
--- Usage: require("power-review.fzf_lua").changed_files()
---        require("power-review.fzf_lua").comments()
---        require("power-review.fzf_lua").sessions()
local M = {}

local comment_preview = require("power-review.ui.comment_preview")

--- Check if fzf-lua is available.
---@return boolean
function M.is_available()
  local ok = pcall(require, "fzf-lua")
  return ok
end

--- Strip refs/heads/ prefix from branch names.
---@param branch string
---@return string
local function normalize_branch(branch)
  return (branch:gsub("^refs/heads/", ""))
end

--- Get the working directory for diff operations.
---@param session PowerReview.ReviewSession
---@return string
local function get_diff_cwd(session)
  if session.worktree_path and vim.fn.isdirectory(session.worktree_path) == 1 then
    return session.worktree_path
  end
  return vim.fn.getcwd()
end

-- ============================================================================
-- Changed files picker
-- ============================================================================

--- Changed files picker.
--- Shows all changed files in the current review session with change type icons.
--- Preview shows the unified diff for the selected file.
--- <CR> opens the diff for the selected file.
---@param opts? table fzf-lua opts
function M.changed_files(opts)
  local pr = require("power-review")
  local session = pr.get_current_session()
  if not session then
    vim.notify("[PowerReview] No active review session", vim.log.levels.WARN)
    return
  end

  local fzf_lua = require("fzf-lua")
  local builtin = require("fzf-lua.previewer.builtin")

  opts = opts or {}

  local icon_map = { add = "A", edit = "M", delete = "D", rename = "R" }
  local diff_cwd = get_diff_cwd(session)
  local target = normalize_branch(session.target_branch)
  local source = normalize_branch(session.source_branch)
  local helpers = require("power-review.session_helpers")

  -- Build entries: display string -> file object mapping
  local entries = {}
  local entry_map = {}
  for _, file in ipairs(session.files) do
    local icon = icon_map[file.change_type] or "?"
    local stats = ""
    if file.additions and file.deletions then
      stats = string.format(" (+%d/-%d)", file.additions, file.deletions)
    end
    -- Review status prefix
    local review_status, review_icon = helpers.get_file_review_status(session, file.path)
    local review_prefix = ""
    if review_status == "reviewed" then
      review_prefix = review_icon .. " "
    elseif review_status == "changed" then
      review_prefix = review_icon .. " "
    end
    local display = string.format("%s[%s] %s%s", review_prefix, icon, file.path, stats)
    table.insert(entries, display)
    entry_map[display] = file
  end

  -- Custom previewer for file diffs
  local DiffPreviewer = builtin.base:extend()

  function DiffPreviewer:new(o, fzf_opts, fzf_win)
    DiffPreviewer.super.new(self, o, fzf_opts, fzf_win)
    setmetatable(self, DiffPreviewer)
    return self
  end

  function DiffPreviewer:populate_preview_buf(entry_str)
    local tmpbuf = self:get_tmp_buffer()
    local file = entry_map[entry_str]
    if not file then
      vim.api.nvim_buf_set_lines(tmpbuf, 0, -1, false, { "No file selected" })
      self:set_preview_buf(tmpbuf)
      return
    end

    -- Show loading
    vim.api.nvim_buf_set_lines(tmpbuf, 0, -1, false, { "Loading diff..." })
    self:set_preview_buf(tmpbuf)

    -- Run git diff async
    local git_cmd = { "git", "diff", target .. ".." .. source, "--", file.path }
    vim.system(git_cmd, { cwd = diff_cwd, text = true }, vim.schedule_wrap(function(result)
      if not vim.api.nvim_buf_is_valid(tmpbuf) then
        return
      end

      local diff_lines = {}
      if result.code == 0 and result.stdout and result.stdout ~= "" then
        for line in (result.stdout .. "\n"):gmatch("([^\n]*)\n") do
          table.insert(diff_lines, line)
        end
        while #diff_lines > 0 and diff_lines[#diff_lines] == "" do
          table.remove(diff_lines)
        end
      end

      if #diff_lines == 0 then
        if file.change_type == "add" then
          diff_lines = { "(New file -- no diff available)" }
        elseif file.change_type == "delete" then
          diff_lines = { "(Deleted file)" }
        else
          diff_lines = { "(No differences found)" }
        end
      end

      -- File metadata header
      local header = {}
      table.insert(header, string.format("File: %s  [%s]", file.path, file.change_type:upper()))
      if file.original_path then
        table.insert(header, "Renamed from: " .. file.original_path)
      end
      if file.additions and file.deletions then
        table.insert(header, string.format("Stats: +%d / -%d", file.additions, file.deletions))
      end

      local helpers = require("power-review.session_helpers")
      local drafts = helpers.get_drafts_for_file(session, file.path)
      if #drafts > 0 then
        table.insert(header, string.format("Drafts: %d comment(s)", #drafts))
      end

      table.insert(header, string.rep("-", 60))
      table.insert(header, "")

      local all_lines = {}
      vim.list_extend(all_lines, header)
      vim.list_extend(all_lines, diff_lines)

      if vim.api.nvim_buf_is_valid(tmpbuf) then
        vim.api.nvim_buf_set_lines(tmpbuf, 0, -1, false, all_lines)
        vim.api.nvim_set_option_value("filetype", "diff", { buf = tmpbuf })
        pcall(vim.treesitter.stop, tmpbuf)
      end
      self.win:update_preview_scrollbar()
    end))
  end

  function DiffPreviewer:gen_winopts()
    local new_winopts = {
      wrap = false,
      number = false,
    }
    return vim.tbl_extend("force", self.winopts, new_winopts)
  end

  -- Review progress for prompt
  local progress = helpers.get_review_progress(session)
  local progress_suffix = ""
  if progress.total > 0 then
    progress_suffix = string.format(" [%d/%d reviewed]", progress.reviewed, progress.total)
  end

  fzf_lua.fzf_exec(entries, vim.tbl_deep_extend("force", {
    prompt = string.format("Changed Files (PR #%d)%s> ", session.pr_id, progress_suffix),
    previewer = DiffPreviewer,
    actions = {
      ["default"] = function(selected)
        if selected and selected[1] then
          local file = entry_map[selected[1]]
          if file then
            local ui = require("power-review.ui")
            ui.open_file_diff(session, file.path)
          end
        end
      end,
      ["ctrl-v"] = function(selected)
        if selected and selected[1] then
          local file = entry_map[selected[1]]
          if file then
            local review_mod = require("power-review.review")
            review_mod.toggle_reviewed(file.path, function(err)
              if err then
                vim.notify("[PowerReview] " .. err, vim.log.levels.ERROR)
              else
                -- Reopen the picker with updated state
                vim.schedule(function()
                  M.changed_files(opts)
                end)
              end
            end)
          end
        end
      end,
    },
  }, opts))
end

-- ============================================================================
-- Comments picker
-- ============================================================================

--- Comments picker.
--- Shows all comments in the current review session: both remote threads and local drafts.
--- Preview shows the full thread with all replies, authors, timestamps.
--- <CR> navigates to the comment location (opens diff + jumps to line).
---@param opts? table fzf-lua opts
function M.comments(opts)
  local pr = require("power-review")
  local session = pr.get_current_session()
  if not session then
    vim.notify("[PowerReview] No active review session", vim.log.levels.WARN)
    return
  end

  local fzf_lua = require("fzf-lua")
  local builtin = require("fzf-lua.previewer.builtin")

  opts = opts or {}

  local review = require("power-review.review")
  local items = comment_preview.build_items(session, review.get_all_threads)

  if #items == 0 then
    vim.notify("[PowerReview] No comments in this review", vim.log.levels.INFO)
    return
  end

  -- Build entries
  local entries = {}
  local entry_map = {}
  for _, item in ipairs(items) do
    local display = comment_preview.format_display(item)
    table.insert(entries, display)
    entry_map[display] = item
  end

  -- Custom previewer for comment threads
  local CommentPreviewer = builtin.base:extend()

  function CommentPreviewer:new(o, fzf_opts, fzf_win)
    CommentPreviewer.super.new(self, o, fzf_opts, fzf_win)
    setmetatable(self, CommentPreviewer)
    return self
  end

  function CommentPreviewer:populate_preview_buf(entry_str)
    local tmpbuf = self:get_tmp_buffer()
    local item = entry_map[entry_str]
    if not item then
      vim.api.nvim_buf_set_lines(tmpbuf, 0, -1, false, { "No item selected" })
      self:set_preview_buf(tmpbuf)
      return
    end

    local preview_lines, preview_hls = comment_preview.build(item, session)
    vim.api.nvim_buf_set_lines(tmpbuf, 0, -1, false, preview_lines)

    -- Apply highlights
    local ns = vim.api.nvim_create_namespace("power_review_fzf_comment")
    vim.api.nvim_buf_clear_namespace(tmpbuf, ns, 0, -1)
    for _, hl in ipairs(preview_hls) do
      pcall(vim.api.nvim_buf_add_highlight, tmpbuf, ns, hl.hl_group, hl.line - 1, 0, -1)
    end

    vim.api.nvim_set_option_value("filetype", "markdown", { buf = tmpbuf })
    self:set_preview_buf(tmpbuf)
    self.win:update_preview_scrollbar()
  end

  function CommentPreviewer:gen_winopts()
    local new_winopts = {
      wrap = true,
      number = false,
    }
    return vim.tbl_extend("force", self.winopts, new_winopts)
  end

  fzf_lua.fzf_exec(entries, vim.tbl_deep_extend("force", {
    prompt = string.format("Comments (PR #%d)> ", session.pr_id),
    previewer = CommentPreviewer,
    actions = {
      ["default"] = function(selected)
        if selected and selected[1] then
          local item = entry_map[selected[1]]
          if item then
            local ui = require("power-review.ui")
            ui.open_file_diff(session, item.file_path, function()
              vim.schedule(function()
                pcall(vim.api.nvim_win_set_cursor, 0, { item.line_start, 0 })
              end)
            end)
          end
        end
      end,
    },
  }, opts))
end

-- ============================================================================
-- Sessions picker
-- ============================================================================

--- Sessions picker.
--- Shows all saved review sessions.
--- <CR> resumes the selected session.
---@param opts? table fzf-lua opts
function M.sessions(opts)
  local store = require("power-review.store")
  local summaries = store.list()

  if #summaries == 0 then
    vim.notify("[PowerReview] No saved review sessions", vim.log.levels.INFO)
    return
  end

  local fzf_lua = require("fzf-lua")
  local builtin = require("fzf-lua.previewer.builtin")

  opts = opts or {}

  local pr = require("power-review")
  local current = pr.get_current_session()
  local active_id = current and current.id or nil

  -- Build entries
  local entries = {}
  local entry_map = {}
  for _, s in ipairs(summaries) do
    local active_marker = (active_id and s.id == active_id) and " *" or ""
    local draft_label = s.draft_count > 0 and string.format(" [%d drafts]", s.draft_count) or ""
    local display = string.format(
      "[%s]%s PR #%d: %s%s",
      s.provider_type:upper(),
      active_marker,
      s.pr_id,
      s.pr_title,
      draft_label
    )
    table.insert(entries, display)
    entry_map[display] = s
  end

  -- Custom previewer for session details
  local SessionPreviewer = builtin.base:extend()

  function SessionPreviewer:new(o, fzf_opts, fzf_win)
    SessionPreviewer.super.new(self, o, fzf_opts, fzf_win)
    setmetatable(self, SessionPreviewer)
    return self
  end

  function SessionPreviewer:populate_preview_buf(entry_str)
    local tmpbuf = self:get_tmp_buffer()
    local s = entry_map[entry_str]
    if not s then
      vim.api.nvim_buf_set_lines(tmpbuf, 0, -1, false, { "No session selected" })
      self:set_preview_buf(tmpbuf)
      return
    end

    local is_active = active_id and s.id == active_id
    local lines = {}
    if is_active then
      table.insert(lines, "** ACTIVE SESSION **")
      table.insert(lines, "")
    end
    table.insert(lines, "PR #" .. tostring(s.pr_id) .. ": " .. s.pr_title)
    table.insert(lines, "")
    table.insert(lines, "Provider: " .. s.provider_type:upper())
    table.insert(lines, "Organization: " .. s.org)
    table.insert(lines, "Project: " .. s.project)
    table.insert(lines, "Repository: " .. s.repo)
    table.insert(lines, "")
    table.insert(lines, "Drafts: " .. tostring(s.draft_count))
    table.insert(lines, "URL: " .. (s.pr_url or ""))
    table.insert(lines, "")
    table.insert(lines, "Created: " .. s.created_at)
    table.insert(lines, "Updated: " .. s.updated_at)
    table.insert(lines, "Session ID: " .. s.id)

    vim.api.nvim_buf_set_lines(tmpbuf, 0, -1, false, lines)
    self:set_preview_buf(tmpbuf)
    self.win:update_preview_scrollbar()
  end

  function SessionPreviewer:gen_winopts()
    local new_winopts = {
      wrap = true,
      number = false,
    }
    return vim.tbl_extend("force", self.winopts, new_winopts)
  end

  fzf_lua.fzf_exec(entries, vim.tbl_deep_extend("force", {
    prompt = "Review Sessions> ",
    previewer = SessionPreviewer,
    actions = {
      ["default"] = function(selected)
        if selected and selected[1] then
          local s = entry_map[selected[1]]
          if s then
            local review_mod = require("power-review.review")
            review_mod.resume_session(s.id, function(err, resumed)
              if err then
                vim.notify("[PowerReview] " .. err, vim.log.levels.ERROR)
              else
                vim.notify("[PowerReview] Resumed: " .. resumed.pr_title, vim.log.levels.INFO)
              end
            end)
          end
        end
      end,
    },
  }, opts))
end

return M
