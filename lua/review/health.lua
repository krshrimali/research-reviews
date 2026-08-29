local M = {}

local function executable(name, required)
  if vim.fn.executable(name) == 1 then
    vim.health.ok(("`%s` is available"):format(name))
  elseif required then
    vim.health.error(("`%s` is missing"):format(name))
  else
    vim.health.warn(("`%s` is missing; its optional feature is disabled"):format(name))
  end
end

local function module(name, label)
  if pcall(require, name) then vim.health.ok(label .. " is available")
  else vim.health.error(label .. " is not on Neovim's runtime path") end
end

function M.check()
  vim.health.start("review.nvim")
  executable("git", true)
  executable(vim.env.PRTUI_GH_BIN or "gh", false)
  executable(require("review.config").get().claude.bin or "claude", false)
  module("diffview", "diffview.nvim")
  module("sidekick", "sidekick.nvim")

  local version = vim.version()
  if vim.version.ge(version, { 0, 10, 0 }) then
    vim.health.ok(("Neovim %d.%d.%d is supported"):format(version.major, version.minor, version.patch))
  else
    vim.health.error("Neovim 0.10 or newer is required")
  end

  local editor = vim.env.EDITOR
  if editor and editor ~= "" then vim.health.ok("$EDITOR is set to `" .. editor .. "`")
  else vim.health.warn("$EDITOR is unset; editor actions fall back to `vi`") end

  local gh = require("review.util.gh")
  if gh.available() then
    local identity = gh.repo_identity(vim.fn.getcwd())
    if identity then
      vim.health.ok(("GitHub repository detected: %s/%s on %s"):format(
        identity.owner, identity.repo, identity.host or "unknown host"))
    else
      vim.health.warn("`gh` is available, but the current directory is not an authenticated GitHub repository")
    end
  end

  local cfg = require("review.config").get()
  if cfg.workspace.comments_min_columns < 80 then
    vim.health.warn("workspace.comments_min_columns is very small; the diff may become cramped")
  else
    vim.health.ok("responsive comments-panel threshold is configured")
  end
  vim.health.ok("edit worktrees stay inside the reviewed repository's private `.git/prtui/worktrees`")
end

return M
