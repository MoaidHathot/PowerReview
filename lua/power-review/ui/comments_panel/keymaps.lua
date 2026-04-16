--- PowerReview.nvim comments panel — keymap handlers
local M = {}

local log = require("power-review.utils.log")
local window = require("power-review.ui.comments_panel.window")

--- Find the section at a given buffer line.
---@param sections PowerReview.PanelSection[]
---@param line number 1-indexed
---@return PowerReview.PanelSection|nil
local function section_at_line(sections, line)
  for _, section in ipairs(sections) do
    if section.buf_start and section.buf_end then
      if line >= section.buf_start and line <= section.buf_end then
        return section
      end
    end
  end
  return nil
end

--- Resolve a draft ID from a section under the cursor.
---@param section PowerReview.PanelSection|nil
---@param action_name string
---@param session PowerReview.ReviewSession|nil
---@param callback fun(draft_id: string)
local function resolve_draft_from_section(section, action_name, session, callback)
  if not section then
    log.info("Select a draft comment to %s", action_name)
    return
  end

  if section.type == "draft" and section.data.draft_id then
    callback(section.data.draft_id)
    return
  end

  if section.type == "thread" and section.data.reply_draft_ids and #section.data.reply_draft_ids > 0 then
    local ids = section.data.reply_draft_ids
    if #ids == 1 then
      callback(ids[1])
      return
    end

    local helpers = require("power-review.session_helpers")
    local items = {}
    for _, id in ipairs(ids) do
      local draft = session and helpers.get_draft(session, id)
      if draft then
        local preview = (draft.body or ""):sub(1, 60):gsub("\n", " ")
        table.insert(items, { id = id, label = string.format("[%s] %s", draft.status, preview) })
      end
    end

    vim.ui.select(items, {
      prompt = "Select reply draft to " .. action_name .. ":",
      format_item = function(item)
        return item.label
      end,
    }, function(choice)
      if choice then
        callback(choice.id)
      end
    end)
    return
  end

  log.info("Select a draft comment to %s", action_name)
end

--- Set up all keymaps on the panel split.
---@param split table NuiSplit
---@param session PowerReview.ReviewSession
---@param panel_module table Reference to the parent comments_panel module (for state access)
function M.setup(split, session, panel_module)
  -- Close
  split:map("n", "q", function()
    panel_module.close()
  end, { noremap = true })

  -- Enter: toggle collapse on collapsible sections, or open diff on leaf items
  split:map("n", "<CR>", function()
    local line = vim.api.nvim_win_get_cursor(0)[1]
    local section = section_at_line(panel_module._sections, line)
    if not section then
      return
    end

    if section.data.collapsible and line == section.buf_start then
      local key = section.data.collapse_key
      panel_module._collapsed[key] = not panel_module._collapsed[key]
      panel_module._render(panel_module._session or session)
      pcall(vim.api.nvim_win_set_cursor, 0, { math.min(line, vim.api.nvim_buf_line_count(0)), 0 })
      return
    end

    if section.data.file_path then
      window.open_diff_action(section, panel_module._session or session)
    end
  end, { noremap = true })

  -- o: open file (raw, no diff) to the left of the panel
  split:map("n", "o", function()
    local line = vim.api.nvim_win_get_cursor(0)[1]
    local section = section_at_line(panel_module._sections, line)
    if not section then
      return
    end
    if section.data.file_path then
      window.open_file_action(section, panel_module._session or session)
    end
  end, { noremap = true })

  -- gd: open diff view to the left of the panel
  split:map("n", "gd", function()
    local line = vim.api.nvim_win_get_cursor(0)[1]
    local section = section_at_line(panel_module._sections, line)
    if not section then
      return
    end
    if section.data.file_path then
      window.open_diff_action(section, panel_module._session or session)
    end
  end, { noremap = true })

  -- l: expand
  split:map("n", "l", function()
    local line = vim.api.nvim_win_get_cursor(0)[1]
    local section = section_at_line(panel_module._sections, line)
    if section and section.data.collapsible and panel_module._collapsed[section.data.collapse_key] then
      panel_module._collapsed[section.data.collapse_key] = false
      panel_module._render(panel_module._session or session)
      pcall(vim.api.nvim_win_set_cursor, 0, { math.min(line, vim.api.nvim_buf_line_count(0)), 0 })
    end
  end, { noremap = true })

  -- h: collapse
  split:map("n", "h", function()
    local line = vim.api.nvim_win_get_cursor(0)[1]
    local section = section_at_line(panel_module._sections, line)
    if section and section.data.collapsible and not panel_module._collapsed[section.data.collapse_key] then
      panel_module._collapsed[section.data.collapse_key] = true
      panel_module._render(panel_module._session or session)
      pcall(vim.api.nvim_win_set_cursor, 0, { math.min(line, vim.api.nvim_buf_line_count(0)), 0 })
    end
  end, { noremap = true })

  -- L: expand all
  split:map("n", "L", function()
    panel_module._collapsed = {}
    panel_module._render(panel_module._session or session)
  end, { noremap = true })

  -- H: collapse all
  split:map("n", "H", function()
    for _, section in ipairs(panel_module._sections) do
      if section.data.collapse_key then
        panel_module._collapsed[section.data.collapse_key] = true
      end
    end
    panel_module._render(panel_module._session or session)
  end, { noremap = true })

  -- a: add comment / reply to thread
  split:map("n", "a", function()
    local line = vim.api.nvim_win_get_cursor(0)[1]
    local section = section_at_line(panel_module._sections, line)
    if not section or not section.data.file_path then
      return
    end
    local comment_float = require("power-review.ui.comment_float")
    local editor_opts = {
      file_path = section.data.file_path,
      line = section.data.line_start or 1,
      session = panel_module._session or session,
    }
    if section.data.thread_id then
      editor_opts.thread_id = section.data.thread_id
    end
    comment_float.open_comment_editor(editor_opts)
  end, { noremap = true })

  -- e: edit draft
  split:map("n", "e", function()
    local line = vim.api.nvim_win_get_cursor(0)[1]
    local section = section_at_line(panel_module._sections, line)
    resolve_draft_from_section(section, "edit", panel_module._session or session, function(draft_id)
      local helpers = require("power-review.session_helpers")
      local cur_session = panel_module._session or session
      local draft = helpers.get_draft(cur_session, draft_id)
      if not draft then
        log.warn("Draft not found")
        return
      end

      local comment_float = require("power-review.ui.comment_float")
      comment_float.open_comment_editor({
        file_path = draft.file_path,
        line = draft.line_start,
        line_end = draft.line_end,
        col_start = draft.col_start,
        col_end = draft.col_end,
        session = cur_session,
        draft_id = draft.id,
        initial_body = draft.body,
      })
    end)
  end, { noremap = true })

  -- d: delete draft
  split:map("n", "d", function()
    local line = vim.api.nvim_win_get_cursor(0)[1]
    local section = section_at_line(panel_module._sections, line)
    resolve_draft_from_section(section, "delete", panel_module._session or session, function(draft_id)
      vim.ui.input({ prompt = "Delete draft? (y/n): " }, function(input)
        if input == "y" or input == "Y" then
          local pr = require("power-review")
          local ok_del, err = pr.api.delete_draft_comment(draft_id)
          if ok_del then
            log.info("Draft deleted")
            local cur_session = panel_module._session or session
            panel_module._render(cur_session)
          else
            log.error("Failed to delete: %s", err or "unknown")
          end
        end
      end)
    end)
  end, { noremap = true })

  -- A: approve draft
  split:map("n", "A", function()
    local line = vim.api.nvim_win_get_cursor(0)[1]
    local section = section_at_line(panel_module._sections, line)
    resolve_draft_from_section(section, "approve", panel_module._session or session, function(draft_id)
      local pr = require("power-review")
      local ok_appr, err = pr.api.approve_draft(draft_id)
      if ok_appr then
        log.info("Draft approved (now pending)")
        local cur_session = panel_module._session or session
        panel_module._render(cur_session)
      else
        log.error("Failed to approve: %s", err or "unknown")
      end
    end)
  end, { noremap = true })

  -- R: refresh
  split:map("n", "R", function()
    local pr = require("power-review")
    local current = pr.get_current_session()
    if current then
      panel_module._render(current)
      log.info("Comments panel refreshed")
    end
  end, { noremap = true })

  -- r: resolve/change thread status
  split:map("n", "r", function()
    local line = vim.api.nvim_win_get_cursor(0)[1]
    local section = section_at_line(panel_module._sections, line)
    if not section or not section.data.thread_id then
      log.info("No thread under cursor")
      return
    end

    local cur_session = panel_module._session or session
    if not cur_session or not cur_session.pr_url then
      log.error("No active session")
      return
    end

    local thread_id = section.data.thread_id
    local current_status = section.data.thread_status or "active"

    local status_options = { "active", "fixed", "wontfix", "closed", "bydesign", "pending" }
    vim.ui.select(status_options, {
      prompt = string.format("Thread #%d status (current: %s):", thread_id, current_status),
      format_item = function(item)
        local icons = {
          active = " Active",
          fixed = " Fixed / Resolved",
          wontfix = " Won't Fix",
          closed = " Closed",
          bydesign = "󰗡 By Design",
          pending = " Pending",
        }
        local marker = item == current_status and " (current)" or ""
        return (icons[item] or item) .. marker
      end,
    }, function(choice)
      if not choice or choice == current_status then
        return
      end

      local cli = require("power-review.cli")
      cli.update_thread_status(cur_session.pr_url, thread_id, choice, function(err, _result)
        if err then
          log.error("Failed to update thread status: %s", err)
          return
        end
        log.info("Thread #%d status changed to %s", thread_id, choice)
        vim.schedule(function()
          local pr = require("power-review")
          pr.api.sync_threads(function(sync_err)
            if sync_err then
              log.warn("Sync after status update failed: %s", sync_err)
            end
            local updated = pr.get_current_session()
            if updated then
              panel_module._render(updated)
            end
          end)
        end)
      end)
    end)
  end, { noremap = true })
end

return M
