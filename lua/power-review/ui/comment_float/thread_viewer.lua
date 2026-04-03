--- PowerReview.nvim comment float — thread viewer popup
--- Displays existing comment threads and drafts at a given line in a nui.nvim popup.
local M = {}

local log = require("power-review.utils.log")
local config = require("power-review.config")

--- Build content lines and highlights for the thread viewer.
---@param threads table[] Remote threads at this line
---@param drafts PowerReview.DraftComment[] Local drafts at this line
---@param file_path string
---@param line number
---@return string[] lines, table[] highlights
function M.build_thread_content(threads, drafts, file_path, line)
  local lines = {}
  local hls = {}

  -- Thread status icons
  local status_icons = {
    active = "",
    fixed = "",
    wontfix = "",
    closed = "",
    bydesign = "",
    pending = "",
  }

  -- Remote threads
  for _, thread in ipairs(threads) do
    -- Thread status header line
    local thread_status = thread.status or "active"
    local status_icon = status_icons[thread_status:lower()] or ""
    local status_line = string.format("── Thread #%s  %s %s ──", tostring(thread.id or "?"), status_icon, thread_status)
    table.insert(lines, status_line)
    local status_hl = thread_status:lower() == "active" and "DiagnosticInfo" or "Comment"
    table.insert(hls, {
      group = status_hl,
      line = #lines - 1,
      col_start = 0,
      col_end = #status_line,
    })

    if thread.comments then
      for ci, comment in ipairs(thread.comments) do
        local prefix = ci == 1 and ">> " or "   "
        local header = string.format("%s%s  (%s)", prefix, comment.author or "unknown", comment.created_at or "")
        table.insert(lines, header)
        table.insert(hls, {
          group = "Title",
          line = #lines - 1,
          col_start = 0,
          col_end = #header,
        })

        -- Comment body (may be multiline)
        for _, body_line in ipairs(vim.split(comment.body or "", "\n")) do
          table.insert(lines, "   " .. body_line)
        end
        table.insert(lines, "")
      end
    end
  end

  -- Local drafts
  for _, draft in ipairs(drafts) do
    local status_badge = string.format("[%s]", draft.status:upper())
    local author_label = draft.author == "ai" and (draft.author_name and " (AI: " .. draft.author_name .. ")" or " (AI)") or ""
    local header = string.format("%s%s %s", status_badge, author_label, draft.created_at or "")
    table.insert(lines, header)

    local hl_group = draft.author == "ai" and "DiagnosticWarn" or "DiagnosticHint"
    table.insert(hls, {
      group = hl_group,
      line = #lines - 1,
      col_start = 0,
      col_end = #status_badge,
    })

    for _, body_line in ipairs(vim.split(draft.body or "", "\n")) do
      table.insert(lines, "   " .. body_line)
    end
    table.insert(lines, "")
  end

  -- Remove trailing empty line
  if #lines > 0 and lines[#lines] == "" then
    table.remove(lines)
  end

  return lines, hls
end

--- Open a floating window showing comment threads at the cursor line.
--- Shows remote comments + local drafts, with option to reply or create new.
---@param opts? table { bufnr?: number, line?: number }
---@param float_module table Reference to the parent comment_float module (for close/open_comment_editor)
function M.open(opts, float_module)
  opts = opts or {}
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local line = opts.line or vim.api.nvim_win_get_cursor(0)[1]

  local pr = require("power-review")
  local session = pr.get_current_session()
  if not session then
    log.warn("No active review session")
    return
  end

  -- Get file path from signs module
  local signs = require("power-review.ui.signs")
  local info = signs._attached_bufs[bufnr]
  local file_path
  if info then
    file_path = info.file_path
  else
    -- Try to resolve from buffer name
    file_path = float_module._resolve_file_path(bufnr, session)
  end

  if not file_path then
    log.warn("Cannot determine file path for this buffer")
    return
  end

  -- Gather indicators at this line
  local indicators = signs.get_indicators_at_line(bufnr, line)

  -- Also get drafts directly (indicators might not include all if signs aren't attached)
  local helpers = require("power-review.session_helpers")
  local drafts = helpers.get_drafts_for_file(session, file_path)
  local line_drafts = {}
  for _, d in ipairs(drafts) do
    if d.line_start == line then
      table.insert(line_drafts, d)
    end
  end

  -- Get remote threads for this line
  local review = require("power-review.review")
  local threads = review.get_threads_for_file(session, file_path)
  local line_threads = {}
  for _, t in ipairs(threads) do
    if t.line_start == line and t.type ~= "draft" then
      table.insert(line_threads, t)
    end
  end

  -- Build content lines for the popup
  local content_lines, content_hls = M.build_thread_content(line_threads, line_drafts, file_path, line)

  if #content_lines == 0 then
    -- No existing comments; open the editor directly
    float_module.open_comment_editor({
      file_path = file_path,
      line = line,
      session = session,
    })
    return
  end

  -- Close any existing popup
  float_module.close()

  -- Create the popup
  local ok_nui, Popup = pcall(require, "nui.popup")
  if not ok_nui then
    -- Fallback: show in vim.notify
    for _, l in ipairs(content_lines) do
      log.info(l)
    end
    return
  end

  local event = require("nui.utils.autocmd").event
  local ui_cfg = config.get_ui_config()
  local float_cfg = ui_cfg.comments.float

  local popup = Popup({
    enter = true,
    focusable = true,
    relative = "cursor",
    position = {
      row = 1,
      col = 0,
    },
    size = {
      width = math.min(float_cfg.width, vim.o.columns - 4),
      height = math.min(#content_lines + 2, float_cfg.height, vim.o.lines - 4),
    },
    border = {
      style = "rounded",
      text = {
        top = string.format(" %s:%d ", file_path, line),
        top_align = "left",
        bottom = " q:close  a:reply  e:edit  d:del  A:approve  U:unapprove  r:resolve ",
        bottom_align = "center",
      },
    },
    buf_options = {
      modifiable = false,
      readonly = true,
      filetype = "markdown",
    },
    win_options = {
      winhighlight = "Normal:NormalFloat,FloatBorder:FloatBorder",
      wrap = true,
      linebreak = true,
      cursorline = true,
    },
  })

  popup:mount()

  -- Set content
  vim.bo[popup.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(popup.bufnr, 0, -1, false, content_lines)
  vim.bo[popup.bufnr].modifiable = false

  -- Apply highlights
  local ns = vim.api.nvim_create_namespace("power_review_float")
  for _, hl in ipairs(content_hls) do
    pcall(vim.api.nvim_buf_add_highlight, popup.bufnr, ns, hl.group, hl.line, hl.col_start, hl.col_end)
  end

  -- Store context for keybinding actions
  local ctx = {
    file_path = file_path,
    line = line,
    session = session,
    line_drafts = line_drafts,
    line_threads = line_threads,
  }

  -- Keymaps
  popup:map("n", "q", function()
    float_module.close()
  end, { noremap = true })

  popup:map("n", "<Esc>", function()
    float_module.close()
  end, { noremap = true })

  -- Reply / new comment
  popup:map("n", "a", function()
    float_module.close()
    float_module.open_comment_editor({
      file_path = ctx.file_path,
      line = ctx.line,
      session = ctx.session,
      -- If there's a remote thread, reply to it
      thread_id = ctx.line_threads[1] and ctx.line_threads[1].id or nil,
    })
  end, { noremap = true })

  -- Edit draft on this line (if multiple, user picks)
  popup:map("n", "e", function()
    if #ctx.line_drafts == 0 then
      log.info("No draft comments to edit on this line")
      return
    end

    local function do_edit(draft)
      float_module.close()
      float_module.open_comment_editor({
        file_path = ctx.file_path,
        line = ctx.line,
        line_end = draft.line_end,
        session = ctx.session,
        draft_id = draft.id,
        initial_body = draft.body,
      })
    end

    if #ctx.line_drafts == 1 then
      do_edit(ctx.line_drafts[1])
    else
      float_module.close()
      vim.ui.select(ctx.line_drafts, {
        prompt = "Select draft to edit:",
        format_item = function(d)
          local preview = d.body:gsub("\n", " "):sub(1, 60)
          local author_label = d.author == "ai" and (d.author_name and " (AI: " .. d.author_name .. ")" or " (AI)") or ""
          return string.format("[%s]%s %s", d.status:upper(), author_label, preview)
        end,
      }, function(selected)
        if selected then
          do_edit(selected)
        end
      end)
    end
  end, { noremap = true })

  -- Delete draft on this line (if multiple, user picks)
  popup:map("n", "d", function()
    if #ctx.line_drafts == 0 then
      log.info("No draft comments to delete on this line")
      return
    end

    local function do_delete(draft)
      vim.ui.input({ prompt = "Delete draft? (y/n): " }, function(input)
        if input == "y" or input == "Y" then
          local ok_del, err = require("power-review").api.delete_draft_comment(draft.id)
          if ok_del then
            log.info("Draft deleted")
            float_module.close()
          else
            log.error("Failed to delete draft: %s", err or "unknown")
          end
        end
      end)
    end

    if #ctx.line_drafts == 1 then
      do_delete(ctx.line_drafts[1])
    else
      float_module.close()
      vim.ui.select(ctx.line_drafts, {
        prompt = "Select draft to delete:",
        format_item = function(d)
          local preview = d.body:gsub("\n", " "):sub(1, 60)
          return string.format("[%s] %s", d.status:upper(), preview)
        end,
      }, function(selected)
        if selected then
          do_delete(selected)
        end
      end)
    end
  end, { noremap = true })

  -- Approve draft (draft -> pending)
  popup:map("n", "A", function()
    local approvable = {}
    for _, d in ipairs(ctx.line_drafts) do
      if d.status == "draft" then
        table.insert(approvable, d)
      end
    end

    if #approvable == 0 then
      log.info("No draft comments to approve on this line")
      return
    end

    local function do_approve(draft)
      local ok_appr, err = require("power-review").api.approve_draft(draft.id)
      if ok_appr then
        log.info("Draft approved (pending)")
        float_module.close()
      else
        log.error("Failed to approve draft: %s", err or "unknown")
      end
    end

    if #approvable == 1 then
      do_approve(approvable[1])
    else
      float_module.close()
      vim.ui.select(approvable, {
        prompt = "Select draft to approve:",
        format_item = function(d)
          local preview = d.body:gsub("\n", " "):sub(1, 60)
          local author_label = d.author == "ai" and (d.author_name and " (AI: " .. d.author_name .. ")" or " (AI)") or ""
          return string.format("[%s]%s %s", d.status:upper(), author_label, preview)
        end,
      }, function(selected)
        if selected then
          do_approve(selected)
        end
      end)
    end
  end, { noremap = true })

  -- Unapprove draft (pending -> draft)
  popup:map("n", "U", function()
    local unapprovable = {}
    for _, d in ipairs(ctx.line_drafts) do
      if d.status == "pending" then
        table.insert(unapprovable, d)
      end
    end

    if #unapprovable == 0 then
      log.info("No pending comments to unapprove on this line")
      return
    end

    local function do_unapprove(draft)
      local ok_u, err = require("power-review").api.unapprove_draft(draft.id)
      if ok_u then
        log.info("Draft unapproved (back to draft)")
        float_module.close()
      else
        log.error("Failed to unapprove: %s", err or "unknown")
      end
    end

    if #unapprovable == 1 then
      do_unapprove(unapprovable[1])
    else
      float_module.close()
      vim.ui.select(unapprovable, {
        prompt = "Select draft to unapprove:",
        format_item = function(d)
          local preview = d.body:gsub("\n", " "):sub(1, 60)
          return string.format("[PENDING] %s", preview)
        end,
      }, function(selected)
        if selected then
          do_unapprove(selected)
        end
      end)
    end
  end, { noremap = true })

  -- Resolve / change thread status
  popup:map("n", "r", function()
    if #ctx.line_threads == 0 then
      log.info("No remote threads on this line to resolve")
      return
    end

    local function do_resolve(thread)
      local statuses = { "active", "fixed", "wontfix", "closed", "bydesign", "pending" }
      local icons = {
        active = "",
        fixed = "",
        wontfix = "",
        closed = "",
        bydesign = "",
        pending = "",
      }
      vim.ui.select(statuses, {
        prompt = string.format("Set thread #%s status:", tostring(thread.id)),
        format_item = function(s)
          local icon = icons[s] or ""
          local current = (thread.status or "active"):lower() == s and " (current)" or ""
          return string.format("%s %s%s", icon, s, current)
        end,
      }, function(selected)
        if not selected then
          return
        end
        if (thread.status or "active"):lower() == selected then
          log.info("Thread status unchanged")
          return
        end
        local cli = require("power-review.cli")
        cli.update_thread_status(ctx.session.pr_url, thread.id, selected, function(err, _result)
          vim.schedule(function()
            if err then
              log.error("Failed to update thread status: %s", err)
            else
              log.info("Thread #%s -> %s", tostring(thread.id), selected)
              float_module.close()
              -- Sync to refresh thread data
              local review_mod = require("power-review.review")
              review_mod.sync_threads(function() end)
            end
          end)
        end)
      end)
    end

    if #ctx.line_threads == 1 then
      do_resolve(ctx.line_threads[1])
    else
      float_module.close()
      vim.ui.select(ctx.line_threads, {
        prompt = "Select thread to resolve:",
        format_item = function(t)
          local first_body = ""
          if t.comments and t.comments[1] then
            first_body = (t.comments[1].body or ""):gsub("\n", " "):sub(1, 50)
          end
          return string.format("Thread #%s [%s]: %s", tostring(t.id), t.status or "active", first_body)
        end,
      }, function(selected)
        if selected then
          do_resolve(selected)
        end
      end)
    end
  end, { noremap = true })

  -- Auto-close on BufLeave
  popup:on(event.BufLeave, function()
    float_module.close()
  end)

  float_module._popup = popup
end

return M
