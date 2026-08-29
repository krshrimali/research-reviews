-- review.nvim :: one commit reviewed against its first parent.

local git = require("review.util.git")
local util = require("review.util")

local Commit = {}
Commit.__index = Commit

local EMPTY_TREE = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

function Commit.new(cwd, rev)
  local root = git.root(cwd)
  if not root then return nil, "not inside a git repository" end
  local sha = git.rev_parse(rev or "HEAD", root)
  if not sha then return nil, "cannot resolve commit: " .. tostring(rev) end
  local parent = git.rev_parse(sha .. "^", root) or EMPTY_TREE
  local info = git.commit_info(sha, root)
  if not info then return nil, "cannot read commit: " .. tostring(rev) end
  return setmetatable({
    repo_root = root, rev = rev or sha, _head_sha = sha, _base_sha = parent, _commit = info,
  }, Commit)
end

function Commit:key()
  return string.format("commit:%s/%s", util.hash(self.repo_root), self._head_sha)
end
function Commit:repo_key() return self.repo_root end
function Commit:kind() return "commit" end
function Commit:caps()
  return { has_threads = false, has_reviewers = false, has_checks = false, can_submit = false }
end
function Commit:title()
  return string.format("%s · %s", self._commit.short, self._commit.subject)
end
function Commit:description() return self._commit.body or "" end
function Commit:author() return self._commit.author or "" end
function Commit:updated_at() return self._commit.date or "" end
function Commit:base_rev() return self._base_sha end
function Commit:head_rev() return self._head_sha end
function Commit:commits() return { self._commit } end
function Commit:files()
  if not self._files then
    self._files = git.changed_files(self._base_sha, self._head_sha, self.repo_root, { exact = true })
  end
  return self._files
end
function Commit:diffview_spec() return self._head_sha .. "^!" end
function Commit:reviewers() return {} end
function Commit:threads() return {} end
function Commit:checks() return {} end
function Commit:metadata()
  return {
    rev = self.rev, base_sha = self._base_sha, head_sha = self._head_sha, repo_root = self.repo_root,
  }
end

return Commit
