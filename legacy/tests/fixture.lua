-- Build a throwaway git repo fixture for integration tests. Returns its path.
local proc = require("review.util.proc")

local M = {}

local function git(args, cwd)
  local ok, _, err = proc.git(args, cwd)
  assert(ok, "git " .. table.concat(args, " ") .. " failed: " .. (err or ""))
end

--- Create a fixture repo with a base commit on main and 2 commits on a feature branch.
---@return string dir
function M.create()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  git({ "init", "-q", "-b", "main" }, dir)
  git({ "config", "user.email", "t@t" }, dir)
  git({ "config", "user.name", "t" }, dir)

  local function write(path, content)
    local full = vim.fs.joinpath(dir, path)
    vim.fn.mkdir(vim.fn.fnamemodify(full, ":h"), "p")
    local fd = assert(io.open(full, "w"))
    fd:write(content)
    fd:close()
  end

  write("src/auth.lua", "local M = {}\nfunction M.get() return 1 end\nreturn M\n")
  git({ "add", "-A" }, dir)
  git({ "commit", "-qm", "base commit" }, dir)

  -- Simulate an origin so default_branch/merge-base resolve.
  git({ "branch", "-f", "origin-main-sim" }, dir) -- not a real remote; test uses explicit base

  git({ "checkout", "-q", "-b", "feature/x" }, dir)
  write("src/auth.lua", "local M = {}\nfunction M.get_or_refresh() return 2 end\nreturn M\n")
  write("src/cache.cpp", "int cache() { return 0; }\n")
  git({ "add", "-A" }, dir)
  git({ "commit", "-qm", "add refresh + cache" }, dir)

  write("README.md", "# hello\n")
  git({ "add", "-A" }, dir)
  git({ "commit", "-qm", "docs" }, dir)

  return dir
end

return M
