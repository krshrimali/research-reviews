-- review.nvim :: worktree-at-commit manager.
--
-- Opens a file as it existed at a specific commit inside a managed git worktree,
-- so LSP / gf / relative tooling operate on that snapshot. Worktrees are reused,
-- reconciled from `git worktree list` on demand, and never pruned when they hold
-- unpushed commits (design gap #12).

local proc = require("review.util.proc")
local git = require("review.util.git")
local util = require("review.util")

local M = {}

--- Managed worktree root for a repo.
---@param repo_root string
---@return string
local function wt_root(repo_root)
  local ok, common = proc.git({ "rev-parse", "--git-common-dir" }, repo_root)
  if not ok or not common or vim.trim(common) == "" then
    return vim.fs.joinpath(repo_root, ".git", "prtui", "worktrees")
  end
  common = vim.trim(common)
  if not common:match("^/") then
    common = vim.fs.joinpath(repo_root, common)
  end
  return vim.fs.joinpath(vim.fs.normalize(common), "prtui", "worktrees")
end

--- Path of the worktree for a given sha.
---@param repo_root string
---@param sha string
---@return string
local function wt_path(repo_root, sha)
  return vim.fs.joinpath(wt_root(repo_root), sha:sub(1, 12))
end

--- List existing worktrees known to git for this repo. Returns map path->{sha,branch}.
---@param repo_root string
---@return table<string, table>
function M.list(repo_root)
  local ok, out = proc.git({ "worktree", "list", "--porcelain" }, repo_root)
  local result = {}
  if not ok then
    return result
  end
  local cur = {}
  for line in vim.gsplit(out, "\n", { trimempty = false }) do
    if line == "" then
      if cur.path then
        result[cur.path] = { sha = cur.sha, branch = cur.branch }
      end
      cur = {}
    else
      local k, v = line:match("^(%S+)%s*(.*)$")
      if k == "worktree" then
        cur.path = v
      elseif k == "HEAD" then
        cur.sha = v
      elseif k == "branch" then
        cur.branch = v
      end
    end
  end
  if cur.path then
    result[cur.path] = { sha = cur.sha, branch = cur.branch }
  end
  return result
end

--- Ensure a detached worktree exists at `sha`. Returns path, or nil, err.
---@param repo_root string
---@param sha string
---@return string|nil path, string|nil err
function M.ensure(repo_root, sha)
  local full = git.rev_parse(sha, repo_root)
  if not full then
    return nil, "unknown commit: " .. tostring(sha)
  end
  local path = wt_path(repo_root, full)
  -- Reuse if already registered at the right sha.
  local existing = M.list(repo_root)[path]
  if existing then
    return path
  end
  if vim.fn.isdirectory(path) == 1 then
    -- Directory exists but not registered (stale). Try to reattach via add --force.
    local ok, _, err = proc.git({ "worktree", "add", "--detach", "--force", path, full }, repo_root)
    if not ok then
      return nil, err
    end
    return path
  end
  local parent = vim.fn.fnamemodify(path, ":h")
  vim.fn.mkdir(parent, "p", 448) -- 0700: repository contents are never globally cached
  pcall(vim.uv.fs_chmod, parent, 448)
  local ok, _, err = proc.git({ "worktree", "add", "--detach", path, full }, repo_root)
  if not ok then
    return nil, err
  end
  return path
end

--- Open `file` at `sha` in a new tab rooted in the worktree.
---@param repo_root string
---@param sha string
---@param file string
---@return boolean ok, string|nil err
function M.open(repo_root, sha, file, opts)
  opts = opts or {}
  local path, err = M.ensure(repo_root, sha)
  if not path then
    util.notify("worktree: " .. tostring(err), vim.log.levels.ERROR)
    return false, err
  end
  local target = vim.fs.joinpath(path, file)
  if vim.fn.filereadable(target) == 0 then
    util.notify(string.format("file %s not present at %s", file, sha:sub(1, 8)), vim.log.levels.WARN)
    -- Still open the tab at the worktree root so the user can browse.
  end
  if opts.tab ~= false then vim.cmd("tabnew") end
  -- Tab-local cwd so LSP root detection / gf operate in the snapshot (R4).
  vim.cmd("tcd " .. vim.fn.fnameescape(path))
  if vim.fn.filereadable(target) == 1 then
    vim.cmd("edit " .. vim.fn.fnameescape(target))
  end
  vim.b.review_worktree = path
  vim.b.review_worktree_sha = sha
  util.notify(string.format("opened %s @ %s (worktree)", file, sha:sub(1, 8)))
  return true
end

--- True if a worktree holds work that would be LOST by removal: either commits not
--- reachable from any other ref, or uncommitted changes in the working tree/index.
---@param path string
---@return boolean
local function has_unsaved_work(path)
  -- Commits in this worktree's HEAD not reachable from any branch/remote.
  local ok, out = proc.git({ "log", "--oneline", "HEAD", "--not", "--all" }, path)
  if ok and out and out:gsub("%s+", "") ~= "" then
    return true
  end
  -- Uncommitted changes (staged or unstaged) — force-remove would discard these.
  local sok, sout = proc.git({ "status", "--porcelain" }, path)
  if sok and sout and sout:gsub("%s+", "") ~= "" then
    return true
  end
  return false
end

--- Prune managed worktrees. Refuses any with unmerged commits (gap #12).
---@param repo_root string
---@param opts table|nil { force=boolean }
---@return integer removed, integer kept
function M.prune(repo_root, opts)
  opts = opts or {}
  local removed, kept = 0, 0
  local managed_root = wt_root(repo_root)
  for path, _ in pairs(M.list(repo_root)) do
    if vim.startswith(path, managed_root) then
      if not opts.force and has_unsaved_work(path) then
        util.notify("keeping worktree with unsaved work: " .. path, vim.log.levels.WARN)
        kept = kept + 1
      else
        -- Only force when explicitly requested; otherwise a plain remove refuses to
        -- discard changes, giving a second layer of protection.
        local args = { "worktree", "remove", path }
        if opts.force then
          table.insert(args, 3, "--force")
        end
        local ok = proc.git(args, repo_root)
        if ok then
          removed = removed + 1
        else
          kept = kept + 1
        end
      end
    end
  end
  proc.git({ "worktree", "prune" }, repo_root)
  return removed, kept
end

return M
