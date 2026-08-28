-- review.nvim :: git query helpers built on util.proc (argv, shell=false).

local proc = require("review.util.proc")

local M = {}

--- Absolute path of the repo root containing `cwd`, or nil.
---@param cwd string|nil
---@return string|nil
function M.root(cwd)
  local ok, out = proc.git({ "rev-parse", "--show-toplevel" }, cwd)
  if not ok then
    return nil
  end
  return (out:gsub("%s+$", ""))
end

--- True if `cwd` is inside a git work tree.
---@param cwd string|nil
---@return boolean
function M.is_repo(cwd)
  local ok = proc.git({ "rev-parse", "--is-inside-work-tree" }, cwd)
  return ok
end

--- Current branch name (or nil if detached).
---@param cwd string|nil
---@return string|nil
function M.current_branch(cwd)
  local ok, out = proc.git({ "symbolic-ref", "--quiet", "--short", "HEAD" }, cwd)
  if not ok then
    return nil
  end
  return (out:gsub("%s+$", ""))
end

--- The remote's default branch ref, e.g. "origin/main". Falls back to origin/master.
---@param cwd string|nil
---@return string
function M.default_branch(cwd)
  local ok, out = proc.git({ "symbolic-ref", "refs/remotes/origin/HEAD" }, cwd)
  if ok then
    local ref = out:gsub("%s+$", "") -- refs/remotes/origin/main
    local short = ref:match("refs/remotes/(.+)$")
    if short then
      return short
    end
  end
  -- Fallback: probe common names.
  for _, name in ipairs({ "origin/main", "origin/master" }) do
    if proc.git({ "rev-parse", "--verify", "--quiet", name }, cwd) then
      return name
    end
  end
  return "origin/main"
end

--- merge-base of two revs, or nil.
---@param a string
---@param b string
---@param cwd string|nil
---@return string|nil
function M.merge_base(a, b, cwd)
  -- --end-of-options guards against a ref that begins with "-" (argument injection).
  local ok, out = proc.git({ "merge-base", "--end-of-options", a, b }, cwd)
  if not ok then
    return nil
  end
  local sha = out:gsub("%s+$", "")
  return sha ~= "" and sha or nil
end

--- Resolve a rev to a full sha, or nil.
---@param rev string
---@param cwd string|nil
---@return string|nil
function M.rev_parse(rev, cwd)
  local ok, out = proc.git({ "rev-parse", rev }, cwd)
  if not ok then
    return nil
  end
  return (out:gsub("%s+$", ""))
end

--- Commits in range base..head, recent→old.
---@param base string
---@param head string
---@param cwd string|nil
---@return table[] list of {sha, short, subject, body, author, date}
function M.commits(base, head, cwd)
  -- Records separated by \x1e (RS); fields by \x1f (US). Avoids newline clashes.
  local fmt = "%H%x1f%h%x1f%s%x1f%b%x1f%an%x1f%aI%x1e"
  local ok, out = proc.git({ "log", "--format=" .. fmt, base .. ".." .. head }, cwd)
  if not ok then
    return {}
  end
  local commits = {}
  for record in vim.gsplit(out, "\30", { trimempty = true }) do
    local rec = record:gsub("^%s+", "")
    if rec ~= "" then
      local f = vim.split(rec, "\31", { plain = true })
      if f[1] and f[1] ~= "" then
        table.insert(commits, {
          sha = f[1],
          short = f[2],
          subject = f[3] or "",
          body = (f[4] or ""):gsub("%s+$", ""),
          author = f[5] or "",
          date = f[6] or "",
        })
      end
    end
  end
  return commits
end

--- Changed files for diff base...head (three-dot: relative to merge-base).
---@param base string
---@param head string
---@param cwd string|nil
---@return table[] list of {path, old_path?, status, additions, deletions}
function M.changed_files(base, head, cwd)
  local range = base .. "..." .. head
  -- Name + status (handles renames): --name-status -M.
  local ok, name_out = proc.git({ "diff", "--name-status", "-M", range }, cwd)
  if not ok then
    return {}
  end
  local files = {}
  local by_path = {}
  for line in vim.gsplit(name_out, "\n", { trimempty = true }) do
    local parts = vim.split(line, "\t", { plain = true })
    local status = parts[1]
    if status then
      local entry
      if status:match("^R") then
        entry = { status = "renamed", old_path = parts[2], path = parts[3], additions = 0, deletions = 0 }
      elseif status:match("^A") then
        entry = { status = "added", path = parts[2], additions = 0, deletions = 0 }
      elseif status:match("^D") then
        entry = { status = "deleted", path = parts[2], additions = 0, deletions = 0 }
      else
        entry = { status = "modified", path = parts[2], additions = 0, deletions = 0 }
      end
      table.insert(files, entry)
      by_path[entry.path] = entry
    end
  end
  -- Merge in numeric add/del counts.
  local nok, num_out = proc.git({ "diff", "--numstat", "-M", range }, cwd)
  if nok then
    for line in vim.gsplit(num_out, "\n", { trimempty = true }) do
      local add, del, path = line:match("^(%S+)%s+(%S+)%s+(.+)$")
      if path then
        -- numstat renames look like "src/{old => new}.lua" or "old => new".
        -- Reconstruct the full new path by substituting the brace segment in place,
        -- then fall back to the no-brace "old => new" form.
        local newp = path
        if path:find("=>") then
          if path:find("{") then
            newp = path:gsub("{.-=>%s*(.-)}", "%1"):gsub("//", "/")
          else
            newp = path:match("=>%s*(.+)$") or path
          end
        end
        local e = by_path[newp] or by_path[path]
        if e then
          e.additions = tonumber(add) or 0
          e.deletions = tonumber(del) or 0
        end
      end
    end
  end
  return files
end

--- Fetch from origin (best-effort, sync). Returns ok.
---@param cwd string|nil
---@return boolean
function M.fetch(cwd)
  return (proc.git({ "fetch", "--quiet", "origin" }, cwd))
end

local function credential_helper()
  local gh = vim.env.PRTUI_GH_BIN or "gh"
  return "!" .. vim.fn.shellescape(gh) .. " auth git-credential"
end

---Fetch a PR without touching the configured origin transport or prompting for SSH keys.
---@param repo_url string
---@param number integer
---@param base_ref string
---@param cwd string
---@return boolean ok, string? err
function M.fetch_pr(repo_url, number, base_ref, cwd)
  local pr_ref = ("+refs/pull/%d/head:refs/prtui/pull/%d/head"):format(number, number)
  local base = ("+refs/heads/%s:refs/prtui/pull/%d/base"):format(base_ref, number)
  local ok, out, err = proc.run({
    "git", "-c", "credential.helper=", "-c", "credential.helper=" .. credential_helper(),
    "fetch", "--quiet", "--no-tags", repo_url, pr_ref, base,
  }, {
    cwd = cwd,
    timeout = 60000,
    env = { GIT_TERMINAL_PROMPT = "0", GIT_SSH_COMMAND = "ssh -o BatchMode=yes" },
  })
  return ok, ok and nil or (err ~= "" and err or out)
end

---@param repo_url string
---@param branch string
---@param cwd string
---@return boolean ok, string? err
function M.push_head(repo_url, branch, cwd)
  local ok, out, err = proc.run({
    "git", "-c", "credential.helper=", "-c", "credential.helper=" .. credential_helper(),
    "push", repo_url, "HEAD:refs/heads/" .. branch,
  }, {
    cwd = cwd,
    timeout = 60000,
    env = { GIT_TERMINAL_PROMPT = "0", GIT_SSH_COMMAND = "ssh -o BatchMode=yes" },
  })
  return ok, ok and nil or (err ~= "" and err or out)
end

return M
