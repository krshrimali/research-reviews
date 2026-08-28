-- review.nvim :: command registration. Guarded so it loads once.
if vim.g.loaded_review_nvim then
  return
end
vim.g.loaded_review_nvim = true

local function review()
  return require("review")
end

-- :Review [<pr-number|url|branch|.>]  — open a review (defaults to current branch).
vim.api.nvim_create_user_command("Review", function(opts)
  local arg = opts.args ~= "" and opts.args or nil
  review().open(arg)
end, { nargs = "?", desc = "Open a PR/branch review" })

-- :ReviewList — fuzzy picker.
vim.api.nvim_create_user_command("ReviewList", function()
  review().open_list()
end, { desc = "Pick a PR/branch to review" })

-- :ReviewClaude — dispatch an async Claude review.
vim.api.nvim_create_user_command("ReviewClaude", function()
  review().claude_review()
end, { desc = "Start an async Claude review" })

-- :ReviewSessions — list Claude review sessions.
vim.api.nvim_create_user_command("ReviewSessions", function()
  review().claude_sessions()
end, { desc = "List Claude review sessions" })

-- :ReviewComments — toggle the comments side-panel.
vim.api.nvim_create_user_command("ReviewComments", function()
  review().toggle_comments_panel()
end, { desc = "Toggle the comments side-panel" })

-- :ReviewClean — prune managed worktrees (keeps unpushed ones).
vim.api.nvim_create_user_command("ReviewClean", function()
  review().clean()
end, { desc = "Prune review worktrees" })
