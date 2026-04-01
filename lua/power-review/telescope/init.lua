--- PowerReview.nvim Telescope extension
--- Provides pickers for changed files, comments, and sessions.
--- Usage: require("power-review.telescope").changed_files()
---        require("power-review.telescope").comments()
---        require("power-review.telescope").sessions()
local M = {}

local comment_preview = require("power-review.ui.comment_preview")

--- Check if telescope is available
---@return boolean
function M.is_available()
  local ok = pcall(require, "telescope")
  return ok
end

--- Strip refs/heads/ prefix from branch names (common in AzDO responses)
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

--- Changed files picker.
--- Shows all changed files in the current review session with change type icons.
--- The preview pane shows the unified diff for the selected file.
--- <CR> opens the diff for the selected file.
---@param opts? table Telescope picker opts
function M.changed_files(opts)
  local pr = require("power-review")
  local session = pr.get_current_session()
  if not session then
    vim.notify("[PowerReview] No active review session", vim.log.levels.WARN)
    return
  end

  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  local previewers = require("telescope.previewers")

  opts = opts or {}

  local icon_map = { add = "A", edit = "M", delete = "D", rename = "R" }

  -- Pre-compute diff cwd and target branch for preview
  local diff_cwd = get_diff_cwd(session)
  local target = normalize_branch(session.target_branch)
  local source = normalize_branch(session.source_branch)

  pickers.new(opts, {
    prompt_title = string.format("Changed Files (PR #%d)", session.pr_id),
    finder = finders.new_table({
      results = session.files,
      entry_maker = function(file)
        local icon = icon_map[file.change_type] or "?"
        local stats = ""
        if file.additions and file.deletions then
          stats = string.format(" (+%d/-%d)", file.additions, file.deletions)
        end
        local display = string.format("[%s] %s%s", icon, file.path, stats)
        local ordinal = file.path

        return {
          value = file,
          display = display,
          ordinal = ordinal,
          path = file.path,
          change_type = file.change_type,
        }
      end,
    }),
    sorter = conf.generic_sorter(opts),
    previewer = previewers.new_buffer_previewer({
      title = "Diff",
      define_preview = function(self, entry)
        local file = entry.value
        local bufnr = self.state.bufnr

        -- Show a loading indicator first
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "Loading diff..." })

        -- Run git diff asynchronously to avoid blocking the UI
        local git_cmd = { "git", "diff", target .. ".." .. source, "--", file.path }
        vim.system(git_cmd, { cwd = diff_cwd, text = true }, vim.schedule_wrap(function(result)
          -- Check that the buffer is still valid (user may have moved to another entry)
          if not vim.api.nvim_buf_is_valid(bufnr) then
            return
          end

          local diff_lines = {}

          if result.code == 0 and result.stdout and result.stdout ~= "" then
            for line in (result.stdout .. "\n"):gmatch("([^\n]*)\n") do
              table.insert(diff_lines, line)
            end
            -- Trim trailing empty lines
            while #diff_lines > 0 and diff_lines[#diff_lines] == "" do
              table.remove(diff_lines)
            end
          end

          if #diff_lines == 0 then
            -- No diff from git diff — file may be new (added) or deleted
            -- Try to show the file content instead
            if file.change_type == "add" then
              local show_cmd = { "git", "show", source .. ":" .. file.path }
              local show_result = vim.system(show_cmd, { cwd = diff_cwd, text = true }):wait()
              if show_result.code == 0 and show_result.stdout then
                table.insert(diff_lines, "--- /dev/null")
                table.insert(diff_lines, "+++ b/" .. file.path)
                table.insert(diff_lines, "  (new file)")
                table.insert(diff_lines, "")
                for line in (show_result.stdout .. "\n"):gmatch("([^\n]*)\n") do
                  table.insert(diff_lines, "+" .. line)
                end
              else
                diff_lines = { "(No diff available — new file content could not be read)" }
              end
            elseif file.change_type == "delete" then
              local show_cmd = { "git", "show", target .. ":" .. file.path }
              local show_result = vim.system(show_cmd, { cwd = diff_cwd, text = true }):wait()
              if show_result.code == 0 and show_result.stdout then
                table.insert(diff_lines, "--- a/" .. file.path)
                table.insert(diff_lines, "+++ /dev/null")
                table.insert(diff_lines, "  (deleted file)")
                table.insert(diff_lines, "")
                for line in (show_result.stdout .. "\n"):gmatch("([^\n]*)\n") do
                  table.insert(diff_lines, "-" .. line)
                end
              else
                diff_lines = { "(No diff available — deleted file content could not be read)" }
              end
            else
              diff_lines = { "(No differences found)" }
            end
          end

          -- Add file metadata header
          local header = {}
          table.insert(header, string.format("File: %s  [%s]", file.path, file.change_type:upper()))
          if file.original_path then
            table.insert(header, "Renamed from: " .. file.original_path)
          end
          if file.additions and file.deletions then
            table.insert(header, string.format("Stats: +%d / -%d", file.additions, file.deletions))
          end

          -- Show draft comment count if any
          local helpers = require("power-review.session_helpers")
          local drafts = helpers.get_drafts_for_file(session, file.path)
          if #drafts > 0 then
            table.insert(header, string.format("Drafts: %d comment(s)", #drafts))
          end

          table.insert(header, string.rep("─", 60))
          table.insert(header, "")

          -- Combine header + diff
          local all_lines = {}
          vim.list_extend(all_lines, header)
          vim.list_extend(all_lines, diff_lines)

          if not vim.api.nvim_buf_is_valid(bufnr) then
            return
          end

          vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, all_lines)

          -- Apply diff syntax highlighting (use Vim's built-in syntax, not treesitter,
          -- because treesitter's diff parser overrides the familiar green/red coloring)
          vim.api.nvim_set_option_value("filetype", "diff", { buf = bufnr })
          pcall(vim.treesitter.stop, bufnr)

          -- Also apply highlight to the header lines (before the diff content)
          local ns = vim.api.nvim_create_namespace("power_review_telescope_diff")
          vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
          for i = 1, #header do
            if i == 1 then
              pcall(vim.api.nvim_buf_add_highlight, bufnr, ns, "Title", i - 1, 0, -1)
            elseif header[i]:match("^─") then
              pcall(vim.api.nvim_buf_add_highlight, bufnr, ns, "Comment", i - 1, 0, -1)
            elseif header[i]:match("^Drafts:") then
              pcall(vim.api.nvim_buf_add_highlight, bufnr, ns, "DiagnosticHint", i - 1, 0, -1)
            else
              pcall(vim.api.nvim_buf_add_highlight, bufnr, ns, "Comment", i - 1, 0, -1)
            end
          end

          -- ── Virtual text annotations for lines with comments ──
          -- Build a mapping from source-side line numbers to buffer line indices
          -- by parsing @@ hunk headers in the diff output.
          local header_count = #header
          local src_line_to_buf = {} ---@type table<number, number[]>
          local current_src_line = nil
          for buf_idx, diff_line in ipairs(diff_lines) do
            local _, _, new_start = diff_line:find("^@@ %-%d+,?%d* %+(%d+),?%d* @@")
            if new_start then
              current_src_line = tonumber(new_start)
            elseif current_src_line then
              if diff_line:sub(1, 1) == "-" then
                -- Deleted line: does not advance source line counter
              elseif diff_line:sub(1, 1) == "+" then
                -- Added line in source
                if not src_line_to_buf[current_src_line] then
                  src_line_to_buf[current_src_line] = {}
                end
                table.insert(src_line_to_buf[current_src_line], header_count + buf_idx)
                current_src_line = current_src_line + 1
              else
                -- Context line (unchanged)
                if not src_line_to_buf[current_src_line] then
                  src_line_to_buf[current_src_line] = {}
                end
                table.insert(src_line_to_buf[current_src_line], header_count + buf_idx)
                current_src_line = current_src_line + 1
              end
            end
          end

          -- Collect comments per source line (remote threads + drafts) with content previews
          ---@type table<number, { threads: table[], drafts: table[] }>
          local line_comments = {}
          local helpers_vt = require("power-review.session_helpers")

          local file_threads = helpers_vt.get_threads_for_file(session, file.path)
          for _, thread in ipairs(file_threads) do
            if thread.line_start then
              if not line_comments[thread.line_start] then
                line_comments[thread.line_start] = { threads = {}, drafts = {} }
              end
              -- Extract first comment's body and author
              local first_comment = thread.comments and thread.comments[1]
              local body = first_comment and first_comment.body or ""
              local author = first_comment and first_comment.author or ""
              local reply_count = thread.comments and math.max(0, #thread.comments - 1) or 0
              table.insert(line_comments[thread.line_start].threads, {
                body = body,
                author = author,
                reply_count = reply_count,
                status = thread.status or "active",
              })
            end
          end

          local file_drafts_vt = helpers_vt.get_drafts_for_file(session, file.path)
          for _, draft in ipairs(file_drafts_vt) do
            if draft.line_start then
              if not line_comments[draft.line_start] then
                line_comments[draft.line_start] = { threads = {}, drafts = {} }
              end
              table.insert(line_comments[draft.line_start].drafts, {
                body = draft.body or "",
                author = draft.author or "user",
                status = draft.status or "draft",
              })
            end
          end

          -- Place virtual text on matching buffer lines — showing comment content
          for src_line, info in pairs(line_comments) do
            local buf_indices = src_line_to_buf[src_line]
            if buf_indices and #buf_indices > 0 then
              local chunks = {} ---@type table[] {text, hl_group}

              -- Show first remote thread with content preview
              for i, t in ipairs(info.threads) do
                if i > 2 then break end -- limit to first 2 threads
                local first_line = (t.body:match("^([^\n]*)") or ""):gsub("^%s+", "")
                if #first_line > 60 then
                  first_line = first_line:sub(1, 57) .. "..."
                end
                local status_icon = t.status == "active" and " " or " "
                table.insert(chunks, { "  " .. status_icon, "DiagnosticInfo" })
                if t.author ~= "" then
                  table.insert(chunks, { t.author .. ": ", "Comment" })
                end
                if first_line ~= "" then
                  table.insert(chunks, { first_line, "DiagnosticInfo" })
                end
                if t.reply_count > 0 then
                  table.insert(chunks, { string.format(" (+%d)", t.reply_count), "Comment" })
                end
              end

              -- Show remaining thread count if > 2
              if #info.threads > 2 then
                table.insert(chunks, { string.format("  ...+%d more", #info.threads - 2), "Comment" })
              end

              -- Show first draft with content preview
              for i, d in ipairs(info.drafts) do
                if i > 2 then break end
                local first_line = (d.body:match("^([^\n]*)") or ""):gsub("^%s+", "")
                if #first_line > 60 then
                  first_line = first_line:sub(1, 57) .. "..."
                end
                local label = d.author == "ai" and "  [AI Draft] " or "  [Draft] "
                table.insert(chunks, { label, "DiagnosticWarn" })
                if first_line ~= "" then
                  table.insert(chunks, { first_line, "DiagnosticWarn" })
                end
              end

              -- Show remaining draft count if > 2
              if #info.drafts > 2 then
                table.insert(chunks, { string.format("  ...+%d more", #info.drafts - 2), "Comment" })
              end

              -- Annotate the first matching buffer line (0-indexed)
              if #chunks > 0 then
                local buf_line_0 = buf_indices[1] - 1
                if buf_line_0 >= 0 and buf_line_0 < #all_lines then
                  pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, buf_line_0, 0, {
                    virt_text = chunks,
                    virt_text_pos = "eol",
                  })
                end
              end
            end
          end
        end))
      end,
    }),
    attach_mappings = function(prompt_bufnr, _map)
      actions.select_default:replace(function()
        actions.close(prompt_bufnr)
        local selection = action_state.get_selected_entry()
        if selection then
          local ui = require("power-review.ui")
          ui.open_file_diff(session, selection.value.path)
        end
      end)
      return true
    end,
  }):find()
end

--- Build rich preview lines + highlights for a comment item (delegates to shared module).
---@param item table The comment item from the picker
---@param session PowerReview.ReviewSession
---@return string[] lines, table[] highlights
local function build_comment_preview_fn(item, session)
  return comment_preview.build(item, session)
end

--- Comments picker.
--- Shows all comments in the current review session: both remote threads and local drafts.
--- The preview pane shows the full thread with all replies, authors, timestamps.
--- <CR> navigates to the comment location (opens diff + jumps to line).
---@param opts? table Telescope picker opts
function M.comments(opts)
  local pr = require("power-review")
  local session = pr.get_current_session()
  if not session then
    vim.notify("[PowerReview] No active review session", vim.log.levels.WARN)
    return
  end

  local review = require("power-review.review")
  local items = comment_preview.build_items(session, review.get_all_threads)

  if #items == 0 then
    vim.notify("[PowerReview] No comments in this review", vim.log.levels.INFO)
    return
  end

  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  local previewers = require("telescope.previewers")

  opts = opts or {}

  pickers.new(opts, {
    prompt_title = string.format("Comments (PR #%d)", session.pr_id),
    finder = finders.new_table({
      results = items,
      entry_maker = function(item)
        local display = comment_preview.format_display(item)

        return {
          value = item,
          display = display,
          ordinal = item.file_path .. ":" .. tostring(item.line_start) .. " " .. item.author .. " " .. item.body,
        }
      end,
    }),
    sorter = conf.generic_sorter(opts),
    previewer = previewers.new_buffer_previewer({
      title = "Thread",
      define_preview = function(self, entry)
        local item = entry.value
        local preview_lines, preview_hls = build_comment_preview_fn(item, session)

        vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, preview_lines)

        -- Apply highlights
        local ns = vim.api.nvim_create_namespace("power_review_telescope_comment")
        vim.api.nvim_buf_clear_namespace(self.state.bufnr, ns, 0, -1)
        for _, hl in ipairs(preview_hls) do
          pcall(vim.api.nvim_buf_add_highlight, self.state.bufnr, ns, hl.hl_group, hl.line - 1, 0, -1)
        end

        -- Enable markdown treesitter for body content rendering
        vim.api.nvim_set_option_value("filetype", "markdown", { buf = self.state.bufnr })
      end,
    }),
    attach_mappings = function(prompt_bufnr, _map)
      actions.select_default:replace(function()
        actions.close(prompt_bufnr)
        local selection = action_state.get_selected_entry()
        if selection then
          local item = selection.value
          local ui = require("power-review.ui")
          ui.open_file_diff(session, item.file_path, function()
            vim.schedule(function()
              pcall(vim.api.nvim_win_set_cursor, 0, { item.line_start, 0 })
            end)
          end)
        end
      end)
      return true
    end,
  }):find()
end

--- Sessions picker.
--- Shows all saved review sessions.
--- <CR> resumes the selected session.
---@param opts? table Telescope picker opts
function M.sessions(opts)
  local store = require("power-review.store")
  local summaries = store.list()

  if #summaries == 0 then
    vim.notify("[PowerReview] No saved review sessions", vim.log.levels.INFO)
    return
  end

  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  local previewers = require("telescope.previewers")

  local pr = require("power-review")
  local current = pr.get_current_session()
  local active_id = current and current.id or nil

  opts = opts or {}

  pickers.new(opts, {
    prompt_title = "Review Sessions",
    finder = finders.new_table({
      results = summaries,
      entry_maker = function(s)
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

        return {
          value = s,
          display = display,
          ordinal = s.pr_title .. " " .. tostring(s.pr_id) .. " " .. s.repo,
        }
      end,
    }),
    sorter = conf.generic_sorter(opts),
    previewer = previewers.new_buffer_previewer({
      title = "Session Details",
      define_preview = function(self, entry)
        local s = entry.value
        local is_active = active_id and s.id == active_id
        local lines = {
          is_active and "** ACTIVE SESSION **" or "",
          "PR #" .. tostring(s.pr_id) .. ": " .. s.pr_title,
          "",
          "Provider: " .. s.provider_type:upper(),
          "Organization: " .. s.org,
          "Project: " .. s.project,
          "Repository: " .. s.repo,
          "",
          "Drafts: " .. tostring(s.draft_count),
          "URL: " .. (s.pr_url or ""),
          "",
          "Created: " .. s.created_at,
          "Updated: " .. s.updated_at,
          "Session ID: " .. s.id,
        }
        -- Filter out empty leading line
        if lines[1] == "" then
          table.remove(lines, 1)
        end
        vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
      end,
    }),
    attach_mappings = function(prompt_bufnr, _map)
      actions.select_default:replace(function()
        actions.close(prompt_bufnr)
        local selection = action_state.get_selected_entry()
        if selection then
          local review = require("power-review.review")
          review.resume_session(selection.value.id, function(err, resumed)
            if err then
              vim.notify("[PowerReview] " .. err, vim.log.levels.ERROR)
            else
              vim.notify("[PowerReview] Resumed: " .. resumed.pr_title, vim.log.levels.INFO)
            end
          end)
        end
      end)
      return true
    end,
  }):find()
end

--- Register as a Telescope extension (optional).
--- Users can call :Telescope power_review changed_files, etc.
---@return table
function M.register_extension()
  return require("telescope").register_extension({
    exports = {
      changed_files = M.changed_files,
      comments = M.comments,
      sessions = M.sessions,
    },
  })
end

return M
