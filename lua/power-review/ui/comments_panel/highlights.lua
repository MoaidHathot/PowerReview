--- PowerReview.nvim comments panel highlight definitions
local M = {}

M.HL = {
  FILE_HEADER = "PowerReviewCommentsFile",
  REMOTE_AUTHOR = "PowerReviewCommentsAuthor",
  REMOTE_BODY = "PowerReviewCommentsBody",
  DRAFT_BADGE = "PowerReviewCommentsDraft",
  AI_BADGE = "PowerReviewCommentsAI",
  PENDING_BADGE = "PowerReviewCommentsPending",
  SUBMITTED_BADGE = "PowerReviewCommentsSubmitted",
  LINE_NUM = "PowerReviewCommentsLineNum",
  SEPARATOR = "PowerReviewCommentsSeparator",
  TITLE = "PowerReviewCommentsTitle",
  EXPANDER = "PowerReviewCommentsExpander",
  STATUS_ACTIVE = "PowerReviewCommentsStatusActive",
  STATUS_RESOLVED = "PowerReviewCommentsStatusResolved",
  STATUS_WONTFIX = "PowerReviewCommentsStatusWontFix",
  STATUS_CLOSED = "PowerReviewCommentsStatusClosed",
  STATUS_BYDESIGN = "PowerReviewCommentsStatusByDesign",
  CODE_CONTEXT = "PowerReviewCommentsCodeContext",
  CODE_CONTEXT_BG = "PowerReviewCommentsCodeContextBg",
  REPLY_INDENT = "PowerReviewCommentsReplyIndent",
  TIMESTAMP = "PowerReviewCommentsTimestamp",
  COUNT_BADGE = "PowerReviewCommentsCountBadge",
  HELP_TEXT = "PowerReviewCommentsHelp",
  PANEL_BAR = "PowerReviewPanelBar",
}

local hl_created = false

function M.ensure()
  if hl_created then
    return
  end
  hl_created = true

  local links = {
    [M.HL.FILE_HEADER] = "Directory",
    [M.HL.REMOTE_AUTHOR] = "Title",
    [M.HL.REMOTE_BODY] = "Normal",
    [M.HL.DRAFT_BADGE] = "DiagnosticHint",
    [M.HL.AI_BADGE] = "DiagnosticWarn",
    [M.HL.PENDING_BADGE] = "DiagnosticInfo",
    [M.HL.SUBMITTED_BADGE] = "String",
    [M.HL.LINE_NUM] = "LineNr",
    [M.HL.SEPARATOR] = "Comment",
    [M.HL.TITLE] = "Title",
    [M.HL.EXPANDER] = "SpecialChar",
    [M.HL.STATUS_ACTIVE] = "DiagnosticWarn",
    [M.HL.STATUS_RESOLVED] = "DiagnosticOk",
    [M.HL.STATUS_WONTFIX] = "DiagnosticError",
    [M.HL.STATUS_CLOSED] = "Comment",
    [M.HL.STATUS_BYDESIGN] = "DiagnosticInfo",
    [M.HL.CODE_CONTEXT] = "Comment",
    [M.HL.CODE_CONTEXT_BG] = "CursorLine",
    [M.HL.REPLY_INDENT] = "NonText",
    [M.HL.TIMESTAMP] = "Comment",
    [M.HL.COUNT_BADGE] = "Special",
    [M.HL.HELP_TEXT] = "Comment",
    [M.HL.PANEL_BAR] = "StatusLine",
  }

  for hl_name, link_to in pairs(links) do
    local ok, existing = pcall(vim.api.nvim_get_hl, 0, { name = hl_name })
    if not ok or vim.tbl_isempty(existing) then
      vim.api.nvim_set_hl(0, hl_name, { link = link_to })
    end
  end
end

return M
