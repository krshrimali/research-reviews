-- Standalone exercise of features not covered by the specs: workspace commit
-- navigation (opens a commit diff tab) and the Claude sessions list/detail buffers.
local fixture = require("tests.fixture")

local failures = 0
local function check(c, m)
  print((c and "  ok   " or "  FAIL ") .. m)
  if not c then failures = failures + 1 end
end

local dir = fixture.create()
local Src = require("review.source")
local source = assert(Src.create(".", dir, { base = "main" }))
local store = require("review.comments.store").for_source(source)
require("review").setup({ local_base = "main" })
require("review").current = { source = source, store = store }

-- Workspace Timeline: <CR> on a commit row opens that commit's diff in a new tab.
local workspace = require("review.ui.workspace")
local st = workspace.open(source, store, "Timeline")
local commit_line
for lnum, action in pairs(st.line_actions or {}) do
  if action.type == "commit" then commit_line = lnum end
end
check(commit_line ~= nil, "workspace timeline has a clickable commit")
local tabs_before = #vim.api.nvim_list_tabpages()
local opened_sha = st.line_actions[commit_line].sha
require("review.ui.diff").open_commit(source, opened_sha)
vim.wait(2000, function() return #vim.api.nvim_list_tabpages() > tabs_before end, 50)
check(opened_sha ~= nil, "commit row carries its sha")
check(#vim.api.nvim_list_tabpages() > tabs_before, "commit diff opened a new tab")

-- Sessions: seed a fake completed session and open the list + detail.
store.sessions["s1"] = {
  id = "s1abcdef", source_key = source:key(), state = "done", verdict = "approve",
  summary = "looks good", instruction = "Critical review", allow_edits = false,
  auto_resolve = false, started_at = "2026-08-22T10:00:00Z", ended_at = "2026-08-22T10:03:00Z",
  replied = { "x" }, findings = { { general = true, note = "n" } }, applied = true, log = { "step" },
}
store:save()
local session = require("review.claude.session")
session.list(store)
local buf = vim.api.nvim_get_current_buf()
local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
check(text:find("Claude reviews") ~= nil, "sessions list renders header")
check(text:find("approve") ~= nil, "sessions list shows verdict")

session.detail(store.sessions["s1"])
local dtext = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
check(dtext:find("looks good") ~= nil, "session detail shows summary")
check(dtext:find("Replies posted") ~= nil, "session detail shows replies section")

print(failures == 0 and "\nFEATURES: ALL PASSED" or ("\nFEATURES: " .. failures .. " FAILED"))
if failures > 0 then vim.cmd("cq") end
