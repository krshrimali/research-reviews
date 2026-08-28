-- Smoke test: load every module + run setup.
local mods = {
  "review", "review.config", "review.state", "review.util", "review.util.proc",
  "review.util.json", "review.util.git", "review.util.gh", "review.worktree",
  "review.source", "review.source.local_branch", "review.source.github_pr",
  "review.comments.anchor", "review.comments.store", "review.comments.github_sync",
  "review.ui.markers", "review.ui.menu", "review.ui.compose", "review.ui.overview", "review.ui.diff",
  "review.ui.comments_panel", "review.ui.list",
  "review.claude.contract", "review.claude.runner", "review.claude.session",
}
local ok_all = true
for _, m in ipairs(mods) do
  local ok, err = pcall(require, m)
  if not ok then
    ok_all = false
    print("FAIL " .. m .. ": " .. tostring(err))
  end
end
if ok_all then
  print("ALL " .. #mods .. " MODULES LOADED OK")
end
local ok, err = pcall(function()
  require("review").setup({})
end)
print(ok and "setup() OK" or ("setup FAIL: " .. tostring(err)))
