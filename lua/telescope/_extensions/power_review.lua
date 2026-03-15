--- Telescope extension for PowerReview.nvim
--- Enables :Telescope power_review changed_files
--- Enables :Telescope power_review comments
--- Enables :Telescope power_review sessions
local pr_telescope = require("power-review.telescope")

return require("telescope").register_extension({
  exports = {
    changed_files = pr_telescope.changed_files,
    comments = pr_telescope.comments,
    sessions = pr_telescope.sessions,
  },
})
