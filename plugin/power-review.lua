--- PowerReview.nvim plugin auto-load
--- Registers commands and autocommands on Neovim startup.

if vim.g.loaded_power_review then
  return
end
vim.g.loaded_power_review = true

-- Require Neovim >= 0.10.0 for vim.system and modern extmarks
if vim.fn.has("nvim-0.10.0") ~= 1 then
  vim.notify("[PowerReview] Requires Neovim >= 0.10.0", vim.log.levels.ERROR)
  return
end

--- Register the main :PowerReview command
vim.api.nvim_create_user_command("PowerReview", function(cmd_opts)
  local args = cmd_opts.fargs
  local subcommand = args[1]

  if not subcommand then
    vim.notify("[PowerReview] Usage: :PowerReview <subcommand|url>", vim.log.levels.WARN)
    vim.notify(
      "  Subcommands: open <url>, list, delete, clean, files, comments, comment, thread, diff [file], next, prev, submit, vote, refresh, sync, close, sessions",
      vim.log.levels.INFO
    )
    return
  end

  local review = require("power-review.review")
  local store = require("power-review.store")
  local pr = require("power-review")

  -- If the first arg looks like a URL, treat as :PowerReview open <url>
  if subcommand:match("^https?://") then
    review.start_review(subcommand, function(err, session)
      if err then
        vim.notify("[PowerReview] " .. err, vim.log.levels.ERROR)
        return
      end
      vim.notify("[PowerReview] Review started: " .. session.pr_title, vim.log.levels.INFO)
    end)
    return
  end

  if subcommand == "open" then
    local url = args[2]
    if url then
      review.start_review(url, function(err, session)
        if err then
          vim.notify("[PowerReview] " .. err, vim.log.levels.ERROR)
          return
        end
        vim.notify("[PowerReview] Review started: " .. session.pr_title, vim.log.levels.INFO)
      end)
    else
      local function prompt_for_url()
        vim.ui.input({ prompt = "PR URL: " }, function(input_url)
          if input_url and input_url ~= "" then
            review.start_review(input_url, function(err, session)
              if err then
                vim.notify("[PowerReview] " .. err, vim.log.levels.ERROR)
                return
              end
              vim.notify("[PowerReview] Review started: " .. session.pr_title, vim.log.levels.INFO)
            end)
          end
        end)
      end

      local sessions = store.list()
      if #sessions == 0 then
        prompt_for_url()
        return
      end

      -- Add a "New review..." option at the top
      local choices = { { id = "__new__", label = " Enter a new PR URL..." } }
      for _, s in ipairs(sessions) do
        table.insert(choices, s)
      end

      vim.ui.select(choices, {
        prompt = "Select review session or start new:",
        format_item = function(item)
          if item.id == "__new__" then
            return item.label
          end
          return string.format("[%s] PR #%d: %s (%d drafts)", item.provider_type, item.pr_id, item.pr_title, item.draft_count)
        end,
      }, function(selected)
        if not selected then
          return
        end
        if selected.id == "__new__" then
          prompt_for_url()
          return
        end
        review.resume_session(selected.id, function(err)
          if err then
            vim.notify("[PowerReview] " .. err, vim.log.levels.ERROR)
          end
        end)
      end)
    end

  elseif subcommand == "list" then
    local sessions = store.list()
    if #sessions == 0 then
      vim.notify("[PowerReview] No saved review sessions", vim.log.levels.INFO)
      return
    end
    for _, s in ipairs(sessions) do
      vim.notify(
        string.format("  [%s] PR #%d: %s (%d drafts) - %s", s.provider_type, s.pr_id, s.pr_title, s.draft_count, s.id),
        vim.log.levels.INFO
      )
    end

  elseif subcommand == "delete" then
    local session_id = args[2]
    if session_id then
      local ok, err = store.delete(session_id)
      if ok then
        vim.notify("[PowerReview] Session deleted: " .. session_id, vim.log.levels.INFO)
      else
        vim.notify("[PowerReview] " .. (err or "Failed to delete session"), vim.log.levels.ERROR)
      end
    else
      -- Delete with picker
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

  elseif subcommand == "clean" then
    vim.ui.input({ prompt = "Delete ALL review sessions? (yes/no): " }, function(input)
      if input == "yes" then
        store.clean()
        vim.notify("[PowerReview] All sessions deleted", vim.log.levels.INFO)
      end
    end)

  elseif subcommand == "files" then
    local ui = require("power-review.ui")
    ui.toggle_files()

  elseif subcommand == "comments" then
    local ui = require("power-review.ui")
    ui.toggle_comments()

  elseif subcommand == "comment" then
    if not pr.get_current_session() then
      vim.notify("[PowerReview] No active review session", vim.log.levels.WARN)
      return
    end
    local ui = require("power-review.ui")
    -- Check if called from visual mode (range will be set)
    local visual = cmd_opts.range > 0
    ui.add_comment({ visual = visual })

  elseif subcommand == "thread" then
    if not pr.get_current_session() then
      vim.notify("[PowerReview] No active review session", vim.log.levels.WARN)
      return
    end
    local ui = require("power-review.ui")
    ui.open_thread_at_cursor()

  elseif subcommand == "submit" then
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
          string.format("[PowerReview] No pending comments to submit. %d draft(s) need approval first. Use :PowerReview approve_all", counts.draft),
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

      local function progress_cb(current, total, draft_item)
        vim.schedule(function()
          vim.notify(
            string.format("[PowerReview] Submitting %d/%d: %s:%d", current, total, draft_item.file_path, draft_item.line_start),
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

            -- Show errors
            for _, f in ipairs(result.errors) do
              vim.notify("[PowerReview]   " .. f.error, vim.log.levels.ERROR)
            end

            -- Offer retry
            vim.ui.input({ prompt = "Retry failed submissions? (y/n): " }, function(retry_input)
              if retry_input == "y" or retry_input == "Y" then
                pr.api.retry_failed_submissions(result.errors, function(retry_err, retry_result)
                  vim.schedule(function()
                    if retry_result and retry_result.failed == 0 then
                      vim.notify(
                        string.format("[PowerReview] Retry: all %d submitted successfully", retry_result.submitted),
                        vim.log.levels.INFO
                      )
                    else
                      vim.notify(
                        string.format("[PowerReview] Retry: %d submitted, %d still failed",
                          retry_result and retry_result.submitted or 0,
                          retry_result and retry_result.failed or 0),
                        vim.log.levels.WARN
                      )
                    end
                    -- Refresh UI
                    require("power-review.ui").refresh_neotree()
                  end)
                end)
              end
            end)
          end

          -- Refresh UI
          require("power-review.ui").refresh_neotree()
        end)
      end, progress_cb)
    end)

  elseif subcommand == "sessions" then
    local ui = require("power-review.ui")
    ui.toggle_sessions()

  elseif subcommand == "drafts" then
    if not pr.get_current_session() then
      vim.notify("[PowerReview] No active review session", vim.log.levels.WARN)
      return
    end
    local ui = require("power-review.ui")
    ui.toggle_drafts()

  elseif subcommand == "approve" then
    -- Approve a specific draft or the draft at cursor
    if not pr.get_current_session() then
      vim.notify("[PowerReview] No active review session", vim.log.levels.WARN)
      return
    end
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
      -- Approve draft at cursor
      local ui = require("power-review.ui")
      ui.approve_comment_at_cursor()
    end

  elseif subcommand == "approve_all" then
    if not pr.get_current_session() then
      vim.notify("[PowerReview] No active review session", vim.log.levels.WARN)
      return
    end
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

  elseif subcommand == "vote" then
    local session = pr.get_current_session()
    if not session then
      vim.notify("[PowerReview] No active review session", vim.log.levels.WARN)
      return
    end

    local helpers = require("power-review.session_helpers")
    local current_vote = session.vote
    local current_label = current_vote and helpers.vote_label(current_vote) or "None"

    vim.notify("[PowerReview] Current vote: " .. current_label, vim.log.levels.INFO)

    local choices = helpers.get_vote_choices(current_vote)
    vim.ui.select(choices, {
      prompt = "Set review vote (current: " .. current_label .. "):",
      format_item = function(c)
        return c.label
      end,
    }, function(selected)
      if not selected then
        return
      end

      -- Skip if same as current
      if selected.is_current then
        vim.notify("[PowerReview] Vote unchanged: " .. selected.label, vim.log.levels.INFO)
        return
      end

      -- Confirmation for destructive votes (reject, wait)
      local needs_confirm = selected.value == -10 or selected.value == -5
      local function do_vote()
        pr.api.set_vote(selected.value, function(err)
          if err then
            vim.notify("[PowerReview] " .. err, vim.log.levels.ERROR)
          else
            vim.notify("[PowerReview] Vote set: " .. selected.label, vim.log.levels.INFO)
          end
        end)
      end

      if needs_confirm then
        vim.ui.input({
          prompt = string.format("Confirm vote '%s'? (y/n): ", selected.label),
        }, function(input)
          if input == "y" or input == "Y" then
            do_vote()
          else
            vim.notify("[PowerReview] Vote cancelled", vim.log.levels.INFO)
          end
        end)
      else
        do_vote()
      end
    end)

  elseif subcommand == "refresh" then
    review.refresh_session(function(err)
      if err then
        vim.notify("[PowerReview] " .. err, vim.log.levels.ERROR)
      else
        vim.notify("[PowerReview] Session refreshed", vim.log.levels.INFO)
      end
    end)

  elseif subcommand == "sync" then
    -- Sync remote comment threads only (lighter than full refresh)
    review.sync_threads(function(err, thread_count)
      if err then
        vim.notify("[PowerReview] " .. err, vim.log.levels.ERROR)
      else
        vim.notify(
          string.format("[PowerReview] Synced %d remote thread(s)", thread_count or 0),
          vim.log.levels.INFO
        )
      end
    end)

  elseif subcommand == "close" then
    review.close_review(function(err)
      if err then
        vim.notify("[PowerReview] " .. err, vim.log.levels.ERROR)
      else
        vim.notify("[PowerReview] Review closed", vim.log.levels.INFO)
      end
    end)

  elseif subcommand == "diff" then
    -- Open diff for a specific file, or the explorer
    local file_path = args[2]
    local ui = require("power-review.ui")
    local session = pr.get_current_session()
    if not session then
      vim.notify("[PowerReview] No active review session", vim.log.levels.WARN)
      return
    end
    if file_path then
      ui.open_file_diff(session, file_path)
    else
      ui.open_diff_explorer(session)
    end

  elseif subcommand == "next" then
    local ui = require("power-review.ui")
    ui.goto_next_comment()

  elseif subcommand == "prev" then
    local ui = require("power-review.ui")
    ui.goto_prev_comment()

  else
    vim.notify("[PowerReview] Unknown subcommand: " .. subcommand, vim.log.levels.WARN)
  end
end, {
  nargs = "*",
  range = true,
  complete = function(arg_lead, cmd_line, cursor_pos)
    local subcommands = {
      "open", "list", "delete", "clean",
      "files", "comments", "comment", "thread", "diff",
      "next", "prev",
      "submit", "vote", "refresh", "sync", "close",
      "approve", "approve_all", "drafts", "sessions",
    }
    local matches = {}
    for _, cmd in ipairs(subcommands) do
      if cmd:find(arg_lead, 1, true) == 1 then
        table.insert(matches, cmd)
      end
    end
    return matches
  end,
})
