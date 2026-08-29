-- review.nvim :: LocalBranch source.
-- A branch reviewed against merge-base(HEAD, origin/<default>), or an explicit base.

local git = require("review.util.git")
local util = require("review.util")

---@class LocalBranch
---@field cwd string
---@field repo_root string
---@field branch string
---@field base_ref string
---@field _base_sha string
---@field _head_sha string
local LocalBranch = {}
LocalBranch.__index = LocalBranch

--- Construct a LocalBranch source rooted at `cwd`.
---@param cwd string
---@param opts table|nil { base=string|"auto", branch=string }
---@return LocalBranch|nil, string|nil err
function LocalBranch.new(cwd, opts)
  opts = opts or {}
  local root = git.root(cwd)
  if not root then
    return nil, "not inside a git repository"
  end
  local branch = opts.branch or git.current_branch(root) or "HEAD"
  local head_sha = git.rev_parse(branch, root)
  if not head_sha then
    return nil, "cannot resolve branch: " .. tostring(branch)
  end

  local base_ref, base_sha
  if opts.base and opts.base ~= "auto" then
    base_ref = opts.base
    base_sha = git.rev_parse(opts.base, root)
    if not base_sha then
      return nil, "cannot resolve base ref: " .. opts.base
    end
  else
    local default = git.default_branch(root)
    base_sha = git.merge_base(head_sha, default, root)
    if not base_sha then
      -- Fall back to the default branch tip if no common ancestor.
      base_sha = git.rev_parse(default, root) or head_sha
    end
    base_ref = base_sha
  end

  return setmetatable({
    cwd = root,
    repo_root = root,
    branch = branch,
    base_ref = base_ref,
    _base_sha = base_sha,
    _head_sha = head_sha,
  }, LocalBranch)
end

function LocalBranch:key()
  return string.format("local:%s/%s", util.hash(self.repo_root), self.branch)
end

function LocalBranch:repo_key()
  return self.repo_root
end

function LocalBranch:kind()
  return "branch"
end

function LocalBranch:caps()
  return { has_threads = false, has_reviewers = false, has_checks = false, can_submit = false }
end

function LocalBranch:title()
  return string.format("%s (local branch)", self.branch)
end

function LocalBranch:description()
  local commits = self:commits()
  return string.format("%d commit(s) ahead of base %s.", #commits, self.base_ref:sub(1, 12))
end

function LocalBranch:author()
  return git.rev_parse and (vim.env.USER or "you") or "you"
end

function LocalBranch:updated_at()
  local commits = self:commits()
  return commits[1] and commits[1].date or ""
end

function LocalBranch:base_rev()
  return self._base_sha
end

function LocalBranch:head_rev()
  return self._head_sha
end

function LocalBranch:commits()
  if not self._commits then
    self._commits = git.commits(self._base_sha, self._head_sha, self.repo_root)
  end
  return self._commits
end

function LocalBranch:files()
  if not self._files then
    self._files = git.changed_files(self._base_sha, self._head_sha, self.repo_root)
  end
  return self._files
end

--- The diffview rev spec for the whole review: base...head.
---@return string
function LocalBranch:diffview_spec()
  return string.format("%s...%s", self._base_sha, self._head_sha)
end

function LocalBranch:reviewers()
  return {}
end

function LocalBranch:threads()
  return {}
end

function LocalBranch:checks()
  return {}
end

function LocalBranch:metadata()
  return {
    branch = self.branch,
    base_ref = self.base_ref,
    base_sha = self._base_sha,
    head_sha = self._head_sha,
    repo_root = self.repo_root,
  }
end

return LocalBranch
