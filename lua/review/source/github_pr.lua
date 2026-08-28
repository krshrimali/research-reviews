-- review.nvim :: GitHubPR source. Wraps the `gh` client; diff still comes from git
-- locally (diffview needs local revs), so we ensure the PR head is fetched.

local gh = require("review.util.gh")
local git = require("review.util.git")

---@class GitHubPR
local GitHubPR = {}
GitHubPR.__index = GitHubPR

--- Construct from a PR number in the repo at `cwd`.
---@param number integer
---@param cwd string
---@return GitHubPR|nil, string|nil err
function GitHubPR.new(number, cwd)
  local root = git.root(cwd)
  if not root then
    return nil, "not inside a git repository"
  end
  if not gh.available() then
    return nil, "gh CLI not available"
  end
  local identity = gh.repo_identity(root)
  if not identity then
    return nil, "cannot determine owner/repo"
  end
  local pr, err = gh.pr_view(number, root)
  if not pr then
    return nil, err or "gh pr view failed"
  end
  -- Ensure PR head/base commits exist locally for diffview.
  local fetched, fetch_err = git.fetch_pr(identity.url, number, pr.baseRefName or "main", root)
  if not fetched and not git.rev_parse(pr.headRefOid or "", root) then
    return nil, "cannot fetch PR without prompting: " .. tostring(fetch_err)
  end
  local head_owner = pr.headRepositoryOwner and pr.headRepositoryOwner.login or identity.owner
  local head_repo = pr.headRepository and pr.headRepository.name or identity.repo
  local head_url = pr.headRepository and pr.headRepository.url
  head_url = head_url and (head_url:gsub("/$", "") .. ".git")
    or ((identity.url:match("^(https?://[^/]+)") or ("https://" .. identity.host))
      .. "/" .. head_owner .. "/" .. head_repo .. ".git")
  local self = setmetatable({
    number = number,
    owner = identity.owner,
    repo = identity.repo,
    host = identity.host,
    repo_url = identity.url,
    head_owner = head_owner,
    head_repo = head_repo,
    head_url = head_url,
    head_ref = pr.headRefName,
    repo_root = root,
    _pr = pr,
    _base_sha = pr.baseRefOid,
    _head_sha = pr.headRefOid,
  }, GitHubPR)
  return self
end

function GitHubPR:key()
  return string.format("gh:%s/%s/%s#%d", self.host, self.owner, self.repo, self.number)
end

function GitHubPR:repo_key()
  return self.repo_root
end

function GitHubPR:kind()
  return "pr"
end

function GitHubPR:caps()
  return { has_threads = true, has_reviewers = true, has_checks = true, can_submit = true }
end

function GitHubPR:title()
  return string.format("#%d %s", self.number, self._pr.title or "")
end

function GitHubPR:description()
  return self._pr.body or ""
end

function GitHubPR:author()
  return self._pr.author and self._pr.author.login or "unknown"
end

function GitHubPR:updated_at()
  return self._pr.updatedAt or ""
end

function GitHubPR:base_rev()
  return self._base_sha
end

function GitHubPR:head_rev()
  return self._head_sha
end

function GitHubPR:commits()
  if self._commits then
    return self._commits
  end
  -- Prefer local git log for uniform commit records; base...head merge-base semantics.
  local base = git.merge_base(self._base_sha, self._head_sha, self.repo_root) or self._base_sha
  self._commits = git.commits(base, self._head_sha, self.repo_root)
  self._effective_base = base
  return self._commits
end

function GitHubPR:files()
  if self._files then
    return self._files
  end
  self:commits() -- populate _effective_base
  self._files = git.changed_files(self._effective_base or self._base_sha, self._head_sha, self.repo_root)
  return self._files
end

function GitHubPR:diffview_spec()
  self:commits()
  return string.format("%s...%s", self._effective_base or self._base_sha, self._head_sha)
end

function GitHubPR:reviewers()
  local out = {}
  for _, r in ipairs(self._pr.reviewRequests or {}) do
    table.insert(out, r.login or (r.name or "team"))
  end
  for _, r in ipairs(self._pr.reviews or {}) do
    if r.author then
      table.insert(out, r.author.login .. " (" .. (r.state or "") .. ")")
    end
  end
  return out
end

--- Review threads normalized from GitHub GraphQL.
---@return table[]
function GitHubPR:threads()
  if self._threads then
    return self._threads
  end
  local nodes = gh.review_threads(self.owner, self.repo, self.number, self.repo_root)
  self._threads = nodes or {}
  return self._threads
end

function GitHubPR:checks()
  local out = {}
  for _, c in ipairs(self._pr.statusCheckRollup or {}) do
    table.insert(out, {
      name = c.name or c.context or "check",
      state = c.state or c.conclusion or c.status or "",
    })
  end
  return out
end

function GitHubPR:review_decision()
  return self._pr.reviewDecision or ""
end

function GitHubPR:metadata()
  return {
    number = self.number,
    owner = self.owner,
    repo = self.repo,
    host = self.host,
    repo_url = self.repo_url,
    head_owner = self.head_owner,
    head_repo = self.head_repo,
    head_url = self.head_url,
    head_ref = self.head_ref,
    base_sha = self._base_sha,
    head_sha = self._head_sha,
    repo_root = self.repo_root,
    review_decision = self._pr.reviewDecision,
    labels = self._pr.labels,
    assignees = self._pr.assignees,
  }
end

return GitHubPR
