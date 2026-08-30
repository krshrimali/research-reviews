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

-- :ReviewList — persistent review browser.
vim.api.nvim_create_user_command("ReviewList", function()
  review().open_list()
end, { desc = "Browse PRs/branches to review" })

vim.api.nvim_create_user_command("ReviewPRs", function() review().open_pull_requests() end,
  { desc = "Pick a pull request to review" })
vim.api.nvim_create_user_command("ReviewBranches", function() review().open_branches() end,
  { desc = "Pick a local branch to review" })
vim.api.nvim_create_user_command("ReviewCommits", function() review().open_commits() end,
  { desc = "Pick a commit to review" })
vim.api.nvim_create_user_command("ReviewCurrent", function() review().open_current() end,
  { desc = "Review the current branch against its base" })

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

vim.api.nvim_create_user_command("ReviewRefresh", function() review().refresh() end,
  { desc = "Refresh the active PR and its comments" })
vim.api.nvim_create_user_command("ReviewChat", function() review().toggle_chat() end,
  { desc = "Toggle the Sidekick review chat" })
vim.api.nvim_create_user_command("ReviewPrompt", function() review().copy_prompt() end,
  { desc = "Edit, copy, or run the review prompt" })
vim.api.nvim_create_user_command("ReviewImport", function() review().import_github_comments() end,
  { desc = "Import or refresh GitHub review comments" })
vim.api.nvim_create_user_command("ReviewSync", function() review().sync_claude_result() end,
  { desc = "Import the latest Claude findings from its transcript" })
vim.api.nvim_create_user_command("ReviewQuickfix", function() review().threads_to_quickfix() end,
  { desc = "Export review threads to quickfix" })

-- :ReviewClean — prune managed worktrees (keeps unpushed ones).
vim.api.nvim_create_user_command("ReviewClean", function()
  review().clean()
end, { desc = "Prune review worktrees" })

vim.api.nvim_create_user_command("ReviewHealth", function()
  vim.cmd("checkhealth review")
end, { desc = "Check review.nvim dependencies and configuration" })

vim.api.nvim_create_user_command("ReviewProfile", function()
  require("review.perf").open()
end, { desc = "Show recent review.nvim operation timings" })

vim.api.nvim_create_user_command("ReviewHelp", function()
  review().help()
end, { desc = "Open the review.nvim key and workflow reference" })
