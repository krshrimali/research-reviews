-- review.nvim :: compact, searchable in-editor reference.

local M = {}

function M.lines()
  return {
    "# review.nvim help",
    "",
    "The only global key to remember is `<leader>p`. It opens the actions that are",
    "valid *here* — the menu hides anything this review target cannot do, so a local",
    "commit review never offers GitHub-only actions. With no review open it offers PR,",
    "branch, single-commit, current-branch, and combined review targets.",
    "",
    "## Review browser",
    "",
    "- Every newly opened browser starts on OPEN pull requests",
    "- `<CR>` open the PR or branch under the cursor (the cursor starts on the first row)",
    "- `<Tab>` cycle open → closed → merged → all; `closed` excludes merged PRs",
    "- `S` cycles PRs / branches / both (disabled in the scoped `:ReviewPRs` browser)",
    "- `/` searches the visible rows; `r` refreshes past the metadata cache",
    "- `Q` exports the visible rows to quickfix",
    "- `:ReviewPRs`, `:ReviewBranches`, and `:ReviewCommits` open focused browsers",
    "- `:ReviewCurrent` reviews the current branch against its configured base",
    "- `:ReviewList` opens the combined persistent PR and local-branch browser",
    "",
    "## Diff and threads",
    "",
    "- `<CR>` expand or collapse the thread on this line",
    "- `]t` / `[t` next or previous thread; `]u` / `[u` unresolved only",
    "  (navigation lands in the pane that holds the thread, so `<CR>` works next)",
    "- On a thread: `R` reply · `gr` resolve · `gd` delete",
    "- `<localleader>v` mark this file viewed / unread",
    "- `go` open the file at the reviewed commit; `gO` in a new tab",
    "  (`o` and `O` keep their normal Vim meaning)",
    "- `<leader>p` comment, suggest, reply, resolve, delete, copy, react, apply a",
    "  suggestion, publish, ask Claude, or prune worktrees",
    "",
    "## Workspace",
    "",
    "- `g1` Conversation · `g2` Timeline · `g3` Claude · `g4` Comments",
    "- Inside it: `1`-`4` switch view, `5` returns to the diff, `]` next view, `q` close",
    "- `<CR>` opens the commit (Timeline) or thread (Comments) under the cursor",
    "- `:ReviewWorkspace` opens it directly",
    "",
    "## Comments panel",
    "",
    "- `<CR>` jump to a thread, `<Space>` select it",
    "- `a` send selected threads to Claude, `p` publish, `I` import from GitHub",
    "- `f` cycle status filters, `s` scope to this file / the whole review",
    "- `/` search, `Q` export to quickfix",
    "- `R` reply, `r` resolve, `e` edit, `d` delete, `y` copy, `z` react",
    "- `A` apply the suggestion under the cursor to the working tree",
    "",
    "## Publishing",
    "",
    "- `<leader>p` → `p` opens the submission preview",
    "- `e` cycles the verdict: COMMENT → APPROVE → REQUEST_CHANGES",
    "- `b` writes the review summary (kept with the review until you publish)",
    "- `Ctrl-S` submits; `q` cancels. Nothing leaves the editor before `Ctrl-S`",
    "- Multi-line comments publish as ranges, not just their last line",
    "",
    "## Claude reviews",
    "",
    "- `:ReviewClaude` choose instructions and permissions, then edit/run the prompt",
    "- \"Read-only review\" really is read-only: the agent is launched with an explicit",
    "  tool allowlist and can never push or rewrite history in either mode",
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
    "- `:ReviewClean` prune review worktrees (never removes unpushed work)",
    "- `:ReviewHealth` diagnose dependencies and configuration",
    "- `:ReviewProfile` inspect recent operation timings",
    "",
    "Press `q` to close this tab. Standard Neovim motions and search work normally.",
  }
end

function M.open()
  vim.cmd("tabnew")
  local buf = vim.api.nvim_get_current_buf()
  require("review.util").name_buffer(buf, "review://help")
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
