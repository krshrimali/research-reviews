-- review.nvim :: compact, searchable in-editor reference.

local M = {}

function M.lines()
  return {
    "# review.nvim help",
    "",
    "The only global key to remember is `<leader>p`. It opens the actions that are",
    "valid in the current review context. With no review open it offers PR, branch,",
    "single-commit, current-branch, and combined review targets.",
    "",
    "## Review browser",
    "",
    "- Every newly opened browser starts on OPEN pull requests",
    "- `<CR>` open the selected PR or branch",
    "- `<Tab>` cycle open → closed → merged → all PRs",
    "- `S` cycles PRs / branches / both; `/` searches the visible rows",
    "- `r` refreshes and bypasses the metadata cache",
    "- `Q` exports the visible rows to quickfix",
    "- `:ReviewPRs`, `:ReviewBranches`, and `:ReviewCommits` open focused browsers",
    "- `:ReviewCurrent` reviews the current branch against its configured base",
    "- `:ReviewList` opens the combined persistent PR and local-branch browser",
    "",
    "## Diff and threads",
    "",
    "- `<CR>` expand or collapse the thread on this line",
    "- `]t` / `[t` next or previous thread",
    "- `]u` / `[u` next or previous unresolved thread",
    "- `o` open the file at the reviewed commit; `O` opens it in a new tab",
    "- `g1` Conversation · `g2` Timeline · `g3` Claude · `g4` Comments",
    "- `:ReviewWorkspace` opens the prtui-style five-view workspace; `5` returns to Diff",
    "- `<leader>p` comment, reply, resolve, delete, copy, or ask Claude",
    "",
    "## Comments panel",
    "",
    "- `<CR>` jump to a thread, `<Space>` select it",
    "- `a` send selected threads to Claude, `p` publish selected drafts",
    "- `f` cycle status filters, `/` search, `Q` export to quickfix",
    "- `r` resolve, `e` edit, `d` delete, `y` copy, `q` close",
    "",
    "## Claude reviews",
    "",
    "- `:ReviewClaude` choose instructions and permissions, then edit/run the prompt",
    "- `:ReviewChat` reopen the Sidekick chat and follow progress",
    "- `:ReviewSessions` inspect, cancel, retry, diff, or push completed sessions",
    "- `:ReviewSync` recover findings and replies from the latest transcript",
    "",
    "## Recovery and diagnostics",
    "",
    "- `:ReviewComments` reopen the comments panel",
    "- `:ReviewRefresh` refresh the active PR, checks, commits, and threads",
    "- `:ReviewImport` explicitly re-import GitHub comments",
    "- `:ReviewQuickfix` export all active threads",
    "- `:ReviewHealth` diagnose dependencies and configuration",
    "- `:ReviewProfile` inspect recent operation timings",
    "",
    "Press `q` to close this tab. Standard Neovim motions and search work normally.",
  }
end

function M.open()
  vim.cmd("tabnew")
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_name(buf, "review://help")
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "markdown"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, M.lines())
  vim.bo[buf].modifiable = false
  vim.wo.wrap = true
  vim.wo.linebreak = true
  vim.keymap.set("n", "q", "<cmd>tabclose<CR>", { buffer = buf, nowait = true, desc = "close review help" })
  pcall(vim.treesitter.start, buf, "markdown")
end

return M
