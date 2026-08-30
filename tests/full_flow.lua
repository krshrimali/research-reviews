-- Standalone full-flow integration (run via `nvim -l`), since diffview needs the
-- real rtp loader that plenary's busted child doesn't fully provide.
local fixture = require("tests.fixture")

local failures = 0
local function check(cond, msg)
  if cond then
    print("  ok   " .. msg)
  else
    failures = failures + 1
    print("  FAIL " .. msg)
  end
end

local dir = fixture.create()
local review = require("review")
review.setup({ local_base = "main" })
review.open(".", { base = "main", cwd = dir })

check(review.current ~= nil, "review context set")
check(review.current and review.current.source:kind() == "branch", "source is a branch")

-- The prtui-style workspace is opt-in. Open it explicitly and confirm.
review.show_overview()
local found_overview = false
for _, b in ipairs(vim.api.nvim_list_bufs()) do
  if vim.api.nvim_buf_get_name(b):find("review://workspace") then
    found_overview = true
  end
end
check(found_overview, "review workspace opens on demand (show_overview)")
-- Return to the review tab: Diffview views are tab-local, so asking for the
-- "current" view from the overview tab correctly returns nil.
vim.cmd("tabprevious")

-- diffview opened.
local opened = vim.wait(4000, function()
  local ok, lib = pcall(require, "diffview.lib")
  if not ok then
    return false
  end
  local v = lib.get_current_view()
  return v ~= nil and v.cur_entry ~= nil
end, 50)
check(opened, "diffview view opened")

local diff = require("review.ui.diff")
-- Headless diffview leaves placeholder buffers in the windows and only realizes the
-- diff buffers on a real redraw. Drive a realized diff buffer directly (in a real UI
-- the buffer-local keymaps fire from exactly such a buffer). Put the view's realized
-- a-side (or b-side) buffer into the current window, then resolve context.
local lib = require("diffview.lib")
local entry = lib.get_current_view().cur_entry
local la = entry.layout and entry.layout.a and entry.layout.a.file
local lb = entry.layout and entry.layout.b and entry.layout.b.file
local realized = (la and la.bufnr and vim.api.nvim_buf_is_valid(la.bufnr) and la.bufnr)
  or (lb and lb.bufnr and vim.api.nvim_buf_is_valid(lb.bufnr) and lb.bufnr)
check(realized ~= nil, "a diff buffer is realized")
if realized then
  vim.api.nvim_win_set_buf(0, realized)
end
local ctx = diff.context()
check(ctx ~= nil and ctx.file ~= nil, "diff context resolves file/side")

if ctx then
  review.current.store:add({ file = ctx.file, side = ctx.side, line_start = 1, body = "flow comment" })
  diff.refresh_markers(review.current.store)
  local markers = require("review.ui.markers")
  local any = false
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local b = vim.api.nvim_win_get_buf(win)
    if #vim.api.nvim_buf_get_extmarks(b, markers.ns, 0, -1, {}) > 0 then
      any = true
    end
  end
  check(any, "comment marker renders on a diff buffer")
end

-- worktree open at head in a new tab.
local tabs_before = #vim.api.nvim_list_tabpages()
require("review.worktree").open(dir, review.current.source:head_rev(), ctx and ctx.file or "src/auth.lua")
check(#vim.api.nvim_list_tabpages() == tabs_before + 1, "worktree opens a new tab")

print(failures == 0 and "\nFULL FLOW: ALL PASSED" or ("\nFULL FLOW: " .. failures .. " FAILED"))
if failures > 0 then
  vim.cmd("cq")
end
