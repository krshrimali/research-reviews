-- review.nvim :: command registration. Guarded so it loads once.
if vim.g.loaded_review_nvim then
  return
end
vim.g.loaded_review_nvim = true

local function review()
  return require("review")
end

local function later(fn)
  vim.schedule(function() fn(review()) end)
end

-- :Review [<pr-number|url|branch|.>]  — open a review (defaults to current branch).
vim.api.nvim_create_user_command("Review", function(opts)
  local arg = opts.args ~= "" and opts.args or nil
  later(function(r) r.open(arg) end)
end, { nargs = "?", desc = "Open a PR/branch review" })

-- :ReviewList — persistent review browser.
vim.api.nvim_create_user_command("ReviewList", function()
  later(function(r) r.open_list() end)
end, { desc = "Browse PRs/branches to review" })

vim.api.nvim_create_user_command("ReviewPRs", function() later(function(r) r.open_pull_requests() end) end,
  { desc = "Pick a pull request to review" })
vim.api.nvim_create_user_command("ReviewBranches", function() later(function(r) r.open_branches() end) end,
  { desc = "Pick a local branch to review" })
vim.api.nvim_create_user_command("ReviewCommits", function() later(function(r) r.open_commits() end) end,
  { desc = "Pick a commit to review" })
vim.api.nvim_create_user_command("ReviewCurrent", function() later(function(r) r.open_current() end) end,
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

vim.api.nvim_create_user_command("ReviewWorkspace", function()
  review().open_workspace("Conversation")
end, { desc = "Open Conversation, Timeline, Claude, Comments, and Diff views" })

vim.api.nvim_create_user_command("ReviewRefresh", function() later(function(r) r.refresh() end) end,
  { desc = "Refresh the active PR and its comments" })
vim.api.nvim_create_user_command("ReviewChat", function() review().toggle_chat() end,
  { desc = "Toggle the Sidekick review chat" })
vim.api.nvim_create_user_command("ReviewPrompt", function() review().copy_prompt() end,
  { desc = "Edit, copy, or run the review prompt" })
vim.api.nvim_create_user_command("ReviewImport", function() later(function(r) r.import_github_comments() end) end,
  { desc = "Import or refresh GitHub review comments" })
vim.api.nvim_create_user_command("ReviewSync", function() later(function(r) r.sync_claude_result() end) end,
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
