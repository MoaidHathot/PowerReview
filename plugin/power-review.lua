--- PowerReview.nvim plugin auto-load
--- Registers commands and autocommands on Neovim startup.

if vim.g.loaded_power_review then
  return
end
vim.g.loaded_power_review = true

-- Require minimum Neovim version (vim.system, extmark signs, treesitter APIs)
local version_err = require("power-review.utils.version").check()
if version_err then
  vim.notify(version_err, vim.log.levels.ERROR)
  return
end

-- ============================================================================
-- Shared helpers for command handlers
-- ============================================================================

--- Resolve a file path from args or current buffer.
---@param args string[] Command arguments
---@param arg_index number Index of the file path argument
---@return string|nil file_path
local function resolve_file_path(args, arg_index)
  local file_path = args[arg_index]
  if file_path then
    return file_path
  end
  local signs_mod = require("power-review.ui.signs")
  local bufnr = vim.api.nvim_get_current_buf()
  local info = signs_mod._attached_bufs[bufnr]
  if info then
    return info.file_path
  end
  -- Fallback: try path resolution against the review session
  local pr = require("power-review")
  local session = pr.get_current_session()
  if session then
    return signs_mod._resolve_review_file_path(bufnr, session)
  end
  return nil
end

--- Standard review start callback for :PowerReview open and URL auto-detect.
---@param err? string
---@param session? table
local function on_review_started(err, session)
  if err then
    vim.notify("[PowerReview] " .. err, vim.log.levels.ERROR)
  elseif session then
    vim.notify("[PowerReview] Review started: " .. session.pr_title, vim.log.levels.INFO)
  end
end

-- ============================================================================
-- Command handler functions (extracted from the dispatch table for clarity)
-- ============================================================================

--- Handle :PowerReview open [url]
local function handle_open(args)
  local review = require("power-review.review")
  local url = args[2]
  review.open_or_resume(url, on_review_started)
end

--- Handle :PowerReview submit
local function handle_submit()
  local pr = require("power-review")
  local session = pr.get_current_session()
  if not session then
    vim.notify("[PowerReview] No active review session", vim.log.levels.WARN)
    return
  end

  local helpers = require("power-review.session_helpers")
  local counts = helpers.get_draft_counts(session)

  if counts.pending == 0 then
    if counts.draft > 0 then
      vim.notify(
        string.format(
          "[PowerReview] No pending comments to submit. %d draft(s) need approval first. Use :PowerReview approve_all",
          counts.draft
        ),
        vim.log.levels.WARN
      )
    else
      vim.notify("[PowerReview] No comments to submit", vim.log.levels.INFO)
    end
    return
  end

  vim.ui.input({
    prompt = string.format("Submit %d pending comment(s) to remote? (y/n): ", counts.pending),
  }, function(input)
    if input ~= "y" and input ~= "Y" then
      vim.notify("[PowerReview] Submit cancelled", vim.log.levels.INFO)
      return
    end

    vim.notify(string.format("[PowerReview] Submitting %d comment(s)...", counts.pending), vim.log.levels.INFO)

    local function progress_cb(status, pending_count)
      vim.schedule(function()
        vim.notify(
          string.format("[PowerReview] %s %d comment(s)...", status, pending_count),
          vim.log.levels.INFO
        )
      end)
    end

    pr.api.submit_pending(function(err, result)
      vim.schedule(function()
        if not result then
          vim.notify("[PowerReview] " .. (err or "Submit failed"), vim.log.levels.ERROR)
          return
        end

        if result.failed == 0 then
          vim.notify(
            string.format("[PowerReview] Successfully submitted %d/%d comment(s)", result.submitted, result.total),
            vim.log.levels.INFO
          )
        else
          vim.notify(
            string.format("[PowerReview] Submitted %d/%d, %d FAILED", result.submitted, result.total, result.failed),
            vim.log.levels.WARN
          )

          for _, f in ipairs(result.errors) do
            vim.notify("[PowerReview]   " .. f.error, vim.log.levels.ERROR)
          end

          vim.ui.input({ prompt = "Retry failed submissions? (y/n): " }, function(retry_input)
            if retry_input == "y" or retry_input == "Y" then
              pr.api.retry_failed_submissions(result.errors, function(_retry_err, retry_result)
                vim.schedule(function()
                  if retry_result and retry_result.failed == 0 then
                    vim.notify(
                      string.format("[PowerReview] Retry: all %d submitted successfully", retry_result.submitted),
                      vim.log.levels.INFO
                    )
                  else
                    vim.notify(
                      string.format(
                        "[PowerReview] Retry: %d submitted, %d still failed",
                        retry_result and retry_result.submitted or 0,
                        retry_result and retry_result.failed or 0
                      ),
                      vim.log.levels.WARN
                    )
                  end
                  require("power-review.ui").refresh_neotree()
                end)
              end)
            end
          end)
        end

        require("power-review.ui").refresh_neotree()
      end)
    end, progress_cb)
  end)
end

--- Handle :PowerReview approve [id]
local function handle_approve(args)
  local pr = require("power-review")
  local draft_id = args[2]
  if draft_id then
    local ok_appr, err = pr.api.approve_draft(draft_id)
    if ok_appr then
      vim.notify("[PowerReview] Draft approved (now pending)", vim.log.levels.INFO)
      require("power-review.ui").refresh_neotree()
    else
      vim.notify("[PowerReview] " .. (err or "Failed to approve"), vim.log.levels.ERROR)
    end
  else
    require("power-review.ui").approve_comment_at_cursor()
  end
end

--- Handle :PowerReview approve_all
local function handle_approve_all()
  local pr = require("power-review")
  local helpers = require("power-review.session_helpers")
  local session = pr.get_current_session()
  local counts = helpers.get_draft_counts(session)
  if counts.draft == 0 then
    vim.notify("[PowerReview] No drafts to approve", vim.log.levels.INFO)
    return
  end
  vim.ui.input({
    prompt = string.format("Approve all %d draft(s)? (y/n): ", counts.draft),
  }, function(input)
    if input == "y" or input == "Y" then
      local count = pr.api.approve_all_drafts()
      vim.notify(string.format("[PowerReview] Approved %d draft(s)", count), vim.log.levels.INFO)
      require("power-review.ui").refresh_neotree()
    end
  end)
end

--- Handle :PowerReview resolve_thread <thread_id> <status>
local function handle_resolve_thread(args)
  local pr = require("power-review")
  local session = pr.get_current_session()
  local thread_id = args[2] and tonumber(args[2])
  local status = args[3]
  if thread_id and status then
    local cli = require("power-review.cli")
    cli.update_thread_status(session.pr_url, thread_id, status, function(err)
      if err then
        vim.notify("[PowerReview] " .. err, vim.log.levels.ERROR)
      else
        vim.notify(string.format("[PowerReview] Thread #%d -> %s", thread_id, status), vim.log.levels.INFO)
        require("power-review.review").sync_threads(function() end)
      end
    end)
  else
    vim.notify("[PowerReview] Usage: :PowerReview resolve_thread <thread_id> <status>", vim.log.levels.WARN)
    vim.notify("  Status: active, fixed, wontfix, closed, bydesign, pending", vim.log.levels.INFO)
  end
end

--- Handle :PowerReview unmark_reviewed [file_path]
local function handle_unmark_reviewed(args)
  local file_path = resolve_file_path(args, 2)
  if not file_path then
    vim.notify("[PowerReview] Usage: :PowerReview unmark_reviewed [file_path]", vim.log.levels.WARN)
    return
  end
  require("power-review.review").unmark_reviewed(file_path, function(err)
    if err then
      vim.notify("[PowerReview] " .. err, vim.log.levels.ERROR)
    else
      vim.notify("[PowerReview] Unmarked as reviewed: " .. file_path, vim.log.levels.INFO)
    end
  end)
end

--- Handle :PowerReview iteration_diff [file_path]
local function handle_iteration_diff(args)
  local file_path = resolve_file_path(args, 2)
  if not file_path then
    vim.notify("[PowerReview] Usage: :PowerReview iteration_diff [file_path]", vim.log.levels.WARN)
    return
  end
  require("power-review.review").iteration_diff(file_path, function(err)
    if err then
      vim.notify("[PowerReview] " .. err, vim.log.levels.ERROR)
    end
  end)
end

-- ============================================================================
-- Command dispatch table
-- ============================================================================

--- Each entry: { handler, requires_session }
--- handler receives (args, cmd_opts)
---@type table<string, { handler: fun(args: string[], cmd_opts?: table), requires_session: boolean }>
local commands = {
  open = {
    handler = function(args)
      handle_open(args)
    end,
    requires_session = false,
  },
  list = {
    handler = function()
      local store = require("power-review.store")
      local sessions = store.list()
      if #sessions == 0 then
        vim.notify("[PowerReview] No saved review sessions", vim.log.levels.INFO)
        return
      end
      for _, s in ipairs(sessions) do
        vim.notify(
          string.format(
            "  [%s] PR #%d: %s (%d drafts) - %s",
            s.provider_type, s.pr_id, s.pr_title, s.draft_count, s.id
          ),
          vim.log.levels.INFO
        )
      end
    end,
    requires_session = false,
  },
  delete = {
    handler = function(args)
      local store = require("power-review.store")
      local session_id = args[2]
      if session_id then
        local ok, err = store.delete(session_id)
        if ok then
          vim.notify("[PowerReview] Session deleted: " .. session_id, vim.log.levels.INFO)
        else
          vim.notify("[PowerReview] " .. (err or "Failed to delete session"), vim.log.levels.ERROR)
        end
      else
        local sessions = store.list()
        if #sessions == 0 then
          vim.notify("[PowerReview] No saved review sessions", vim.log.levels.INFO)
          return
        end
        vim.ui.select(sessions, {
          prompt = "Delete review session:",
          format_item = function(s)
            return string.format("[%s] PR #%d: %s", s.provider_type, s.pr_id, s.pr_title)
          end,
        }, function(selected)
          if not selected then
            return
          end
          local ok, err = store.delete(selected.id)
          if ok then
            vim.notify("[PowerReview] Session deleted: " .. selected.id, vim.log.levels.INFO)
          else
            vim.notify("[PowerReview] " .. (err or "Failed to delete"), vim.log.levels.ERROR)
          end
        end)
      end
    end,
    requires_session = false,
  },
  clean = {
    handler = function()
      vim.ui.input({ prompt = "Delete ALL review sessions? (yes/no): " }, function(input)
        if input == "yes" then
          require("power-review.store").clean()
          vim.notify("[PowerReview] All sessions deleted", vim.log.levels.INFO)
        end
      end)
    end,
    requires_session = false,
  },
  files = {
    handler = function()
      require("power-review.ui").toggle_files()
    end,
    requires_session = false,
  },
  comments = {
    handler = function()
      require("power-review.ui").toggle_comments()
    end,
    requires_session = false,
  },
  comment = {
    handler = function(_args, cmd_opts)
      local ui = require("power-review.ui")
      local visual = cmd_opts and cmd_opts.range > 0
      ui.add_comment({ visual = visual })
    end,
    requires_session = true,
  },
  thread = {
    handler = function()
      require("power-review.ui").open_thread_at_cursor()
    end,
    requires_session = true,
  },
  submit = {
    handler = function()
      handle_submit()
    end,
    requires_session = false, -- handle_submit does its own session check with richer logic
  },
  sessions = {
    handler = function()
      require("power-review.ui").toggle_sessions()
    end,
    requires_session = false,
  },
  drafts = {
    handler = function()
      require("power-review.ui").toggle_drafts()
    end,
    requires_session = true,
  },
  approve = {
    handler = function(args)
      handle_approve(args)
    end,
    requires_session = true,
  },
  approve_all = {
    handler = function()
      handle_approve_all()
    end,
    requires_session = true,
  },
  vote = {
    handler = function()
      require("power-review.ui").set_vote()
    end,
    requires_session = true,
  },
  refresh = {
    handler = function()
      require("power-review.review").refresh_session(function(err)
        if err then
          vim.notify("[PowerReview] " .. err, vim.log.levels.ERROR)
        else
          vim.notify("[PowerReview] Session refreshed", vim.log.levels.INFO)
        end
      end)
    end,
    requires_session = false, -- refresh_session does its own session check
  },
  sync = {
    handler = function()
      require("power-review.review").sync_threads(function(err, thread_count)
        if err then
          vim.notify("[PowerReview] " .. err, vim.log.levels.ERROR)
        else
          vim.notify(
            string.format("[PowerReview] Synced %d remote thread(s)", thread_count or 0),
            vim.log.levels.INFO
          )
        end
      end)
    end,
    requires_session = false, -- sync_threads does its own session check
  },
  close = {
    handler = function()
      require("power-review.review").close_review(function(err)
        if err then
          vim.notify("[PowerReview] " .. err, vim.log.levels.ERROR)
        else
          vim.notify("[PowerReview] Review closed", vim.log.levels.INFO)
        end
      end)
    end,
    requires_session = false, -- close_review does its own session check
  },
  diff = {
    handler = function(args)
      local pr = require("power-review")
      local session = pr.get_current_session()
      if not session then
        vim.notify("[PowerReview] No active review session", vim.log.levels.WARN)
        return
      end
      local ui = require("power-review.ui")
      local file_path = args[2]
      if file_path then
        ui.open_file_diff(session, file_path)
      else
        ui.open_diff_explorer(session)
      end
    end,
    requires_session = false, -- diff does its own session check for richer error messaging
  },
  next = {
    handler = function()
      require("power-review.ui").goto_next_comment()
    end,
    requires_session = false,
  },
  prev = {
    handler = function()
      require("power-review.ui").goto_prev_comment()
    end,
    requires_session = false,
  },
  resolve_thread = {
    handler = function(args)
      handle_resolve_thread(args)
    end,
    requires_session = true,
  },
  toggle_notifications = {
    handler = function()
      local notifications = require("power-review.notifications")
      local new_state = notifications.toggle()
      vim.notify(
        string.format("[PowerReview] Notifications %s", new_state and "enabled" or "disabled"),
        vim.log.levels.INFO
      )
    end,
    requires_session = false,
  },
  show_description = {
    handler = function()
      require("power-review.ui").toggle_description()
    end,
    requires_session = false,
  },
  mark_reviewed = {
    handler = function(args)
      local file_path = resolve_file_path(args, 2)
      if not file_path then
        vim.notify("[PowerReview] Usage: :PowerReview mark_reviewed [file_path]", vim.log.levels.WARN)
        return
      end
      -- When called with an explicit file path, mark as reviewed.
      -- When called without (from keymap), toggle reviewed status.
      if args[2] then
        require("power-review.review").mark_reviewed(file_path, function(err)
          if err then
            vim.notify("[PowerReview] " .. err, vim.log.levels.ERROR)
          else
            vim.notify("[PowerReview] Marked as reviewed: " .. file_path, vim.log.levels.INFO)
          end
        end)
      else
        require("power-review.review").toggle_reviewed(file_path, function(err)
          if err then
            vim.notify("[PowerReview] " .. err, vim.log.levels.ERROR)
          end
        end)
      end
    end,
    requires_session = true,
  },
  unmark_reviewed = {
    handler = function(args)
      handle_unmark_reviewed(args)
    end,
    requires_session = true,
  },
  mark_all_reviewed = {
    handler = function()
      require("power-review.review").mark_all_reviewed(function(err)
        if err then
          vim.notify("[PowerReview] " .. err, vim.log.levels.ERROR)
        else
          vim.notify("[PowerReview] All files marked as reviewed", vim.log.levels.INFO)
        end
      end)
    end,
    requires_session = true,
  },
  check_iteration = {
    handler = function()
      require("power-review.review").check_iteration(function(err)
        if err then
          vim.notify("[PowerReview] " .. err, vim.log.levels.ERROR)
        end
      end)
    end,
    requires_session = true,
  },
  iteration_diff = {
    handler = function(args)
      handle_iteration_diff(args)
    end,
    requires_session = true,
  },
}

-- Sorted list of subcommand names for tab completion
local subcommand_names = {}
for name, _ in pairs(commands) do
  table.insert(subcommand_names, name)
end
table.sort(subcommand_names)

-- ============================================================================
-- Register the main :PowerReview command
-- ============================================================================

vim.api.nvim_create_user_command("PowerReview", function(cmd_opts)
  local args = cmd_opts.fargs
  local subcommand = args[1]

  if not subcommand then
    vim.notify("[PowerReview] Usage: :PowerReview <subcommand|url>", vim.log.levels.WARN)
    vim.notify("  Subcommands: " .. table.concat(subcommand_names, ", "), vim.log.levels.INFO)
    return
  end

  -- If the first arg looks like a URL, treat as :PowerReview open <url>
  if subcommand:match("^https?://") then
    local review = require("power-review.review")
    review.start_review(subcommand, on_review_started)
    return
  end

  local cmd = commands[subcommand]
  if not cmd then
    vim.notify("[PowerReview] Unknown subcommand: " .. subcommand, vim.log.levels.WARN)
    return
  end

  -- Session guard for commands that require an active session
  if cmd.requires_session then
    local pr = require("power-review")
    if not pr.get_current_session() then
      vim.notify("[PowerReview] No active review session", vim.log.levels.WARN)
      return
    end
  end

  cmd.handler(args, cmd_opts)
end, {
  nargs = "*",
  range = true,
  complete = function(arg_lead)
    local matches = {}
    for _, name in ipairs(subcommand_names) do
      if name:find(arg_lead, 1, true) == 1 then
        table.insert(matches, name)
      end
    end
    return matches
  end,
})
