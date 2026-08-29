-- review.nvim :: Source factory. Detects PR vs local branch and constructs the
-- appropriate implementation. Everything upstream depends only on this interface.

local LocalBranch = require("review.source.local_branch")
local GitHubPR = require("review.source.github_pr")
local Commit = require("review.source.commit")

local M = {}

M.LocalBranch = LocalBranch
M.GitHubPR = GitHubPR
M.Commit = Commit

--- Build a source from a user argument.
---   number | "#123" | PR URL  -> GitHubPR
---   "." | "" | branch name    -> LocalBranch
---   { kind="commit", rev=sha } -> Commit
---@param arg string|integer|table|nil
---@param cwd string
---@param opts table|nil { base=string }
---@return table|nil source, string|nil err
function M.create(arg, cwd, opts)
  cwd = cwd or vim.fn.getcwd()
  opts = opts or {}

  if type(arg) == "table" and arg.kind == "commit" then
    return Commit.new(cwd, arg.rev)
  end

  if type(arg) == "number" then
    return GitHubPR.new(arg, cwd)
  end

  if type(arg) == "string" then
    -- PR URL: .../pull/123
    local num = arg:match("/pull/(%d+)")
    if num then
      return GitHubPR.new(tonumber(num), cwd)
    end
    -- "#123" or bare "123"
    num = arg:match("^#?(%d+)$")
    if num then
      return GitHubPR.new(tonumber(num), cwd)
    end
    if arg == "" or arg == "." then
      return LocalBranch.new(cwd, opts)
    end
    -- Otherwise treat as a branch name.
    return LocalBranch.new(cwd, vim.tbl_extend("force", opts, { branch = arg }))
  end

  -- Default: current local branch.
  return LocalBranch.new(cwd, opts)
end

return M
