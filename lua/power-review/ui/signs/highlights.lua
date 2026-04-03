--- PowerReview.nvim signs — highlight group definitions
local M = {}

local config = require("power-review.config")

--- Highlight groups used for comment signs
M.groups = {
  remote = "PowerReviewSignRemote",
  draft = "PowerReviewSignDraft",
  ai_draft = "PowerReviewSignAIDraft",
  remote_line = "PowerReviewLineRemote",
  draft_line = "PowerReviewLineDraft",
  ai_draft_line = "PowerReviewLineAIDraft",
  col_highlight = "PowerReviewColHighlight",
  col_highlight_draft = "PowerReviewColHighlightDraft",
  virt_author = "PowerReviewVirtAuthor",
  virt_body = "PowerReviewVirtBody",
  virt_thread_status = "PowerReviewVirtThreadStatus",
  flash = "PowerReviewFlash",
  flash_col = "PowerReviewFlashCol",
}

--- Define default highlight groups (linked to sensible defaults).
--- Users can override these in their colorscheme.
function M.setup()
  local colors = config.get().ui.colors or {}

  -- Sign text highlights
  vim.api.nvim_set_hl(0, M.groups.remote, { default = true, link = "DiagnosticSignInfo" })
  vim.api.nvim_set_hl(0, M.groups.draft, { default = true, link = "DiagnosticSignHint" })
  vim.api.nvim_set_hl(0, M.groups.ai_draft, { default = true, link = "DiagnosticSignWarn" })

  -- Line highlights (subtle background tint)
  vim.api.nvim_set_hl(0, M.groups.remote_line, { default = true, link = "DiagnosticVirtualTextInfo" })
  vim.api.nvim_set_hl(0, M.groups.draft_line, { default = true, link = "DiagnosticVirtualTextHint" })
  vim.api.nvim_set_hl(0, M.groups.ai_draft_line, { default = true, link = "DiagnosticVirtualTextWarn" })

  -- Column-level span highlights (underline to mark the exact code the comment targets)
  vim.api.nvim_set_hl(0, M.groups.col_highlight, {
    default = true, undercurl = true, sp = colors.comment_undercurl or "#61afef",
  })
  vim.api.nvim_set_hl(0, M.groups.col_highlight_draft, {
    default = true, undercurl = true, sp = colors.draft_undercurl or "#98c379",
  })

  -- Virtual text sub-highlights
  vim.api.nvim_set_hl(0, M.groups.virt_author, { default = true, link = "Title" })
  vim.api.nvim_set_hl(0, M.groups.virt_body, { default = true, link = "Comment" })
  vim.api.nvim_set_hl(0, M.groups.virt_thread_status, { default = true, link = "DiagnosticInfo" })
end

return M
