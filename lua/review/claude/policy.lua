-- review.nvim :: the agent tool policy, in exactly one place.
--
-- These lists used to live in claude/runner.lua, which nothing calls any more, while
-- the Sidekick launch that actually starts the agent passed no policy at all — so
-- picking "Read-only review" restricted nothing. Both backends now read from here.
--
-- Claude's Bash patterns are prefix globs, so subcommands need a `:*` suffix.

local M = {}

--- Read-only review: inspect the repository, never change it.
M.readonly_allow = {
  "Read", "Grep", "Glob",
  "Bash(git log:*)", "Bash(git show:*)", "Bash(git diff:*)",
}

--- Additional tools when the reviewer explicitly consented to edits. Explicit
--- subcommands only, never a bare `Bash(git:*)` wildcard.
M.edit_allow = {
  "Edit", "Write", "MultiEdit",
  "Bash(git add:*)", "Bash(git commit:*)", "Bash(git status:*)", "Bash(git worktree:*)",
}

--- Denied in BOTH modes: never publish, never rewrite history.
M.always_deny = {
  "Bash(git push:*)", "Bash(git push)",
  "Bash(git reset:*)", "Bash(git rebase:*)", "Bash(git remote:*)",
}

--- Extra denials that make read-only actually read-only.
M.readonly_deny = {
  "Edit", "Write", "MultiEdit", "NotebookEdit",
  "Bash(git add:*)", "Bash(git commit:*)",
}

--- The allow/deny lists for a mode.
---@param allow_edits boolean
---@return string[] allow, string[] deny
function M.for_mode(allow_edits)
  local allow = vim.deepcopy(M.readonly_allow)
  local deny = vim.deepcopy(M.always_deny)
  if allow_edits then
    vim.list_extend(allow, M.edit_allow)
  else
    vim.list_extend(deny, M.readonly_deny)
  end
  return allow, deny
end

--- The same policy as the comma-joined strings the `claude` CLI expects.
---@param allow_edits boolean
---@return string allow, string deny
function M.args(allow_edits)
  local allow, deny = M.for_mode(allow_edits)
  return table.concat(allow, ","), table.concat(deny, ",")
end

return M
