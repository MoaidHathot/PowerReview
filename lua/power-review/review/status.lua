--- PowerReview.nvim review status/vote management
local M = {}

--- Vote value mapping
---@type table<string, PowerReview.ReviewVote>
M.votes = {
  approved = 10,
  approved_with_suggestions = 5,
  no_vote = 0,
  wait_for_author = -5,
  rejected = -10,
}

--- Human-readable vote labels
---@type table<string, string>
M.labels = {
  approved = "Approved",
  approved_with_suggestions = "Approved with suggestions",
  no_vote = "No vote",
  wait_for_author = "Wait for author",
  rejected = "Rejected",
}

--- Get vote choices for UI selection.
--- If current_vote is provided, marks the active choice.
---@param current_vote? PowerReview.ReviewVote
---@return table[] List of { label: string, value: number, key: string }
function M.get_vote_choices(current_vote)
  local choices = {
    { label = "Approved", value = 10, key = "approved" },
    { label = "Approved with suggestions", value = 5, key = "approved_with_suggestions" },
    { label = "No vote (reset)", value = 0, key = "no_vote" },
    { label = "Wait for author", value = -5, key = "wait_for_author" },
    { label = "Rejected", value = -10, key = "rejected" },
  }

  if current_vote ~= nil then
    for _, choice in ipairs(choices) do
      if choice.value == current_vote then
        choice.label = choice.label .. " (current)"
        choice.is_current = true
      end
    end
  end

  return choices
end

--- Get human-readable label for a vote value
---@param vote PowerReview.ReviewVote
---@return string
function M.vote_label(vote)
  for _, choice in ipairs(M.get_vote_choices()) do
    if choice.value == vote then
      return choice.label
    end
  end
  return "Unknown (" .. tostring(vote) .. ")"
end

return M
