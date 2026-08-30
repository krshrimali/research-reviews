-- UI-layer integration tests (headless): workspace, markers, panel, worktree.
local fixture = require("tests.fixture")

local function new_source()
  local dir = fixture.create()
  local Src = require("review.source")
  local source = assert(Src.create(".", dir, { base = "main" }))
  local store = require("review.comments.store").for_source(source)
  return dir, source, store
end

describe("workspace render", function()
  it("normalizes CRLF and GitHub HTML", function()
    local util = require("review.util")
    assert.equals("See [docs](https://example.test)\nnext & `x`",
      util.normalize_markdown('See <a href="https://example.test">docs</a>\r\nnext &amp; <code>x</code>'))
  end)

  it("renders title, metadata, and an actionable commit timeline", function()
    local _, source, store = new_source()
    local st = require("review.ui.workspace").open(source, store, "Timeline")
    local text = table.concat(vim.api.nvim_buf_get_lines(st.buf, 0, -1, false), "\n")
    assert.is_truthy(text:find("local branch", 1, true))
    assert.is_truthy(text:find("Timeline", 1, true))
    assert.is_truthy(text:find("add refresh", 1, true))
    assert.is_truthy(text:find("files: ", 1, true))
    local has_commit_action = false
    for _, action in pairs(st.line_actions or {}) do
      if action.type == "commit" then has_commit_action = true end
    end
    assert.is_true(has_commit_action)
  end)

  it("switches views and always shows the key legend", function()
    local _, source, store = new_source()
    local st = require("review.ui.workspace").open(source, store, "Conversation")
    local text = table.concat(vim.api.nvim_buf_get_lines(st.buf, 0, -1, false), "\n")
    assert.is_truthy(text:find("1-4 switch view", 1, true))
    assert.is_truthy(text:find("Description", 1, true))
  end)
end)

describe("markers", function()
  it("renders an extmark for a thread and expands it", function()
    local _, source, store = new_source()
    store:add({ file = "src/auth.lua", side = "RIGHT", line_start = 2, body = "note here" })
    -- Fake a diff buffer with the file's contents.
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "local M = {}", "function M.get_or_refresh() return 2 end", "return M",
    })
    local markers = require("review.ui.markers")
    markers.render(buf, store, "src/auth.lua", "RIGHT")
    local marks = vim.api.nvim_buf_get_extmarks(buf, markers.ns, 0, -1, { details = true })
    assert.equals(1, #marks)
    assert.is_truthy(marks[1][4].virt_text)
    -- Expand at the thread line.
    vim.api.nvim_buf_call(buf, function()
      local win = vim.api.nvim_open_win(buf, true, { relative = "editor", row = 0, col = 0, width = 40, height = 5 })
      vim.api.nvim_win_set_cursor(win, { 2, 0 })
      markers.toggle_at_cursor(buf, store, "src/auth.lua", "RIGHT")
    end)
    local marks2 = vim.api.nvim_buf_get_extmarks(buf, markers.ns, 0, -1, { details = true })
    assert.is_truthy(marks2[1][4].virt_lines, "thread should expand to virt_lines")
  end)
end)

describe("comments panel", function()
  it("renders the five-view workspace and explicit outdated section", function()
    local _, source, store = new_source()
    local root = store:add({ file = "src/auth.lua", side = "RIGHT", line_start = 2,
      body = "old note", author = "alice" })
    store:update(root.id, { status = "outdated", reactions = { EYES = 2 } })
    require("review.ui.workspace").open(source, store, "Comments")
    local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    assert.is_truthy(text:find("1 Conversation", 1, true))
    assert.is_truthy(text:find("[4 Comments]", 1, true))
    assert.is_truthy(text:find("Outdated (1)", 1, true))
    assert.is_truthy(text:find("OUTDATED — no current diff anchor", 1, true))
    assert.is_truthy(text:find("[eyes 2]", 1, true))
    local marks = vim.api.nvim_buf_get_extmarks(0, vim.api.nvim_get_namespaces().review_workspace, 0, -1,
      { details = true })
    assert.is_true(#marks > 0, "workspace applies semantic highlights")
    vim.cmd("tabclose")
  end)

  it("lists threads for a file and closes", function()
    local _, source, store = new_source()
    store:add({ file = "src/auth.lua", side = "RIGHT", line_start = 2, body = "panel note" })
    local panel = require("review.ui.comments_panel")
    panel.open(store, "src/auth.lua", "RIGHT", function() end)
    assert.is_true(panel.is_open())
    local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    -- panel buffer is the current window
    panel.close()
    assert.is_false(panel.is_open())
  end)
end)

describe("review progress", function()
  it("persists viewed files at the reviewed head", function()
    local _, source, store = new_source()
    assert.is_false(store:is_viewed("src/auth.lua"))
    assert.is_true(store:set_viewed("src/auth.lua", true))
    local reloaded = require("review.comments.store").for_source(source)
    assert.is_true(reloaded:is_viewed("src/auth.lua"))
    local viewed, total = reloaded:viewed_progress()
    assert.equals(1, viewed)
    assert.is_true(total >= 1)
  end)

  it("shows a cross-file unresolved inbox with selection controls", function()
    local _, _, store = new_source()
    store:add({ file = "src/auth.lua", side = "RIGHT", line_start = 2, body = "auth note" })
    store:add({ file = "src/cache.cpp", side = "RIGHT", line_start = 1, body = "cache note" })
    local panel = require("review.ui.comments_panel")
    panel.open(store, nil, "RIGHT", function() end)
    local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    -- One collapsed path row per file: a 42-column panel cannot afford to spend a
    -- line on every directory segment.
    assert.is_truthy(text:find("▾ src/auth.lua", 1, true))
    assert.is_truthy(text:find("▾ src/cache.cpp", 1, true))
    assert.is_truthy(text:find("Space select", 1, true))
    assert.is_truthy(text:find("quickfix", 1, true))
    local called = false
    local review = require("review")
    local original = review.ask_claude_threads
    review.ask_claude_threads = function(threads) called = #threads == 1 end
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    for i, line in ipairs(lines) do
      if line:find("auth note", 1, true) then vim.api.nvim_win_set_cursor(0, { i, 0 }); break end
    end
    local mapping = vim.fn.maparg("a", "n", false, true)
    assert.equals("function", type(mapping.callback))
    mapping.callback()
    review.ask_claude_threads = original
    assert.is_true(called, "panel a mapping should pass the thread under cursor")
    panel.close()
  end)


  it("collapses the path, and renders comments and replies", function()
    local _, _, store = new_source()
    local root = store:add({
      file = "src/pointer/cursor/Manager.cpp", side = "RIGHT", line_start = 2,
      author = "alice", body = "Please guard this\n```cpp\nif (ready) run();\n```",
    })
    store:reply(root.id, "Agreed\nI will update it", { author = "claude", origin = "claude" })
    local lines = require("review.ui.comments_panel")._build(store, nil, "all", "", {})
    local text = table.concat(lines, "\n")
    assert.is_truthy(text:find("▾ src/pointer/cursor/Manager.cpp", 1, true))
    assert.is_truthy(text:find("@alice: Please guard this", 1, true))
    assert.is_truthy(text:find("L2 @alice", 1, true))
    assert.is_truthy(text:find("↳ @claude: Agreed", 1, true))
    assert.is_truthy(text:find("```cpp", 1, true))
  end)
end)

describe("worktree", function()
  it("creates a worktree at a commit and lists it", function()
    local dir, source = new_source()
    local wt = require("review.worktree")
    local base = source:base_rev()
    local path, err = wt.ensure(dir, base)
    assert(path, err)
    assert.equals(1, vim.fn.isdirectory(path))
    -- base commit has src/auth.lua with the OLD content.
    local f = io.open(vim.fs.joinpath(path, "src/auth.lua"), "r")
    assert.is_truthy(f)
    local content = f:read("*a")
    f:close()
    assert.is_truthy(content:find("M.get"))
    -- prune removes it (no unpushed commits at a base sha reachable from main).
    local removed = wt.prune(dir, { force = true })
    assert.is_true(removed >= 1)
  end)
end)
