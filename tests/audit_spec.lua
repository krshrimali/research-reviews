-- Regressions for the issues found by driving the plugin through a live Neovim.
-- Each test names the behaviour that was broken, not the function that was changed.
local fixture = require("tests.fixture")

local function new_source()
  local dir = fixture.create()
  local Src = require("review.source")
  local source = assert(Src.create(".", dir, { base = "main" }))
  local store = require("review.comments.store").for_source(source)
  return dir, source, store
end

describe("comment ids", function()
  it("are unique within a process", function()
    local util = require("review.util")
    local seen = {}
    for _ = 1, 500 do
      local id = util.uuid()
      assert.is_nil(seen[id], "duplicate uuid: " .. id)
      seen[id] = true
    end
  end)

  it("are RFC-4122 v4 shaped", function()
    local id = require("review.util").uuid()
    assert.is_truthy(id:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-4%x%x%x%-[89ab]%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$"),
      "not a v4 uuid: " .. id)
  end)

  it("differ between independent Neovim processes", function()
    -- The real failure: math.random is not seeded, so every editor minted the SAME
    -- ids in the same order and the merge-on-write store silently dropped comments.
    local function first_id()
      local res = vim.system({
        "nvim", "--headless", "-i", "NONE", "-u", "tests/minimal_init.lua",
        "-c", 'lua io.write(require("review.util").uuid())', "-c", "qa!",
      }, { text = true }):wait(20000)
      return vim.trim(res.stdout or "")
    end
    local a, b = first_id(), first_id()
    assert.is_true(#a == 36, "expected a uuid, got: " .. a)
    assert.are_not.equal(a, b)
  end)
end)

describe("agent tool policy", function()
  it("denies writes and pushes in read-only mode", function()
    local allow, deny = require("review.claude.policy").args(false)
    assert.is_truthy(deny:find("Bash(git push:*)", 1, true))
    assert.is_truthy(deny:find("Write", 1, true))
    assert.is_truthy(deny:find("Edit", 1, true))
    assert.is_falsy(allow:find("Write", 1, true))
  end)

  it("permits edits but never push or history rewrites in edit mode", function()
    local allow, deny = require("review.claude.policy").args(true)
    assert.is_truthy(allow:find("Edit", 1, true))
    assert.is_truthy(allow:find("Bash(git commit:*)", 1, true))
    assert.is_truthy(deny:find("Bash(git push:*)", 1, true))
    assert.is_truthy(deny:find("Bash(git rebase:*)", 1, true))
    assert.is_falsy(deny:find("Edit", 1, true))
  end)
end)

describe("publish payload", function()
  it("keeps a multi-line comment's range instead of only its last line", function()
    local publish = require("review.ui.publish")
    local text = table.concat(publish.lines(
      { event = "APPROVE", commit_id = "abc", body = "ship it" },
      { { file = "a.lua", line_start = 10, line_end = 15, side = "RIGHT", body = "range" } }), "\n")
    assert.is_truthy(text:find("a.lua:10-15", 1, true))
    assert.is_truthy(text:find("APPROVE", 1, true))
    assert.is_truthy(text:find("ship it", 1, true))
  end)

  it("cycles the verdict rather than hardcoding COMMENT", function()
    local publish = require("review.ui.publish")
    assert.equals("APPROVE", publish.next_event("COMMENT"))
    assert.equals("REQUEST_CHANGES", publish.next_event("APPROVE"))
    assert.equals("COMMENT", publish.next_event("REQUEST_CHANGES"))
  end)

  it("persists the summary and verdict with the review", function()
    local _, _, store = new_source()
    store:set_review_draft({ event = "REQUEST_CHANGES", body = "needs tests" })
    local reloaded = require("review.comments.store").for_source(store.source)
    assert.equals("REQUEST_CHANGES", reloaded:review_draft().event)
    assert.equals("needs tests", reloaded:review_draft().body)
  end)
end)

describe("comment status", function()
  it("does not call an upstream GitHub comment a local draft", function()
    local _, _, store = new_source()
    local root = store:add({ file = "src/auth.lua", side = "RIGHT", line_start = 2, body = "mine" })
    store:update(root.id, { github_id = "GH1", origin = "github", status = "published" })
    -- Unresolving a published thread must return it to "published", not "draft":
    -- the panel counts drafts to tell you what is still unsent.
    store:set_resolved(root.id, true)
    assert.equals("resolved", store:get(root.id).status)
    store:set_resolved(root.id, false)
    assert.equals("published", store:get(root.id).status)

    local local_only = store:add({ file = "src/auth.lua", side = "RIGHT", line_start = 3, body = "draft" })
    store:set_resolved(local_only.id, true)
    store:set_resolved(local_only.id, false)
    assert.equals("draft", store:get(local_only.id).status)
  end)
end)

describe("review browser", function()
  it("keeps merged pull requests out of the closed tab", function()
    local list = require("review.ui.list")
    local rows = { { state = "CLOSED" }, { state = "MERGED" }, { state = "CLOSED" } }
    assert.equals(2, #list._filter_state(rows, "closed"))
    assert.equals(3, #list._filter_state(rows, "all"))
    assert.equals(3, #list._filter_state(rows, "merged"))
  end)
end)

describe("comments panel", function()
  it("collapses single-child directories into one path row", function()
    local _, _, store = new_source()
    store:add({ file = "src/deep/nested/thing.lua", side = "RIGHT", line_start = 1, body = "x" })
    local text = table.concat(require("review.ui.comments_panel")._build(store, nil, "all", "", {}), "\n")
    assert.is_truthy(text:find("▾ src/deep/nested/thing.lua", 1, true))
    assert.is_falsy(text:find("▾ nested/", 1, true))
  end)

  it("counts only local drafts as drafts", function()
    local _, _, store = new_source()
    local mine = store:add({ file = "src/auth.lua", side = "RIGHT", line_start = 1, body = "mine" })
    local theirs = store:add({ file = "src/auth.lua", side = "RIGHT", line_start = 2, body = "theirs" })
    store:update(theirs.id, { github_id = "GH2", origin = "github", status = "published" })
    local text = table.concat(require("review.ui.comments_panel")._build(store, nil, "all", "", {}), "\n")
    assert.is_truthy(text:find("1 local draft", 1, true))
    assert.is_truthy(store:get(mine.id))
  end)

  it("surfaces a running agent where its findings will land", function()
    local _, _, store = new_source()
    store.sessions["s1"] = { id = "s1abcdef0", state = "running", progress = "reading the diff" }
    local text = table.concat(require("review.ui.comments_panel")._build(store, nil, "all", "", {}), "\n")
    assert.is_truthy(text:find("agent s1abcdef", 1, true))
    assert.is_truthy(text:find("reading the diff", 1, true))
  end)
end)

describe("agent prompt", function()
  it("does not ask the agent to reply to resolved threads", function()
    local _, source, store = new_source()
    local open = store:add({ file = "src/auth.lua", side = "RIGHT", line_start = 1, body = "still open" })
    local done = store:add({ file = "src/auth.lua", side = "RIGHT", line_start = 2, body = "already handled" })
    store:set_resolved(done.id, true)
    local prompt = require("review.sidekick").prompt(source, store, {})
    assert.is_truthy(prompt:find(open.id, 1, true))
    assert.is_falsy(prompt:find(done.id, 1, true))
  end)

  it("still honours an explicit selection, resolved or not", function()
    local _, source, store = new_source()
    local done = store:add({ file = "src/auth.lua", side = "RIGHT", line_start = 2, body = "handled" })
    store:set_resolved(done.id, true)
    local prompt = require("review.sidekick").prompt(source, store, { threads = { store:get(done.id) } })
    assert.is_truthy(prompt:find(done.id, 1, true))
  end)
end)

describe("performance report", function()
  it("keeps the whole command so identical-looking rows can be told apart", function()
    local perf = require("review.perf")
    local label = perf.label({ "git", "diff", "--numstat", "-M", string.rep("a", 40) })
    assert.is_truthy(label:find("--numstat", 1, true))
    assert.is_truthy(label:find("-M", 1, true))
    assert.is_true(#label < 60)
  end)
end)

describe("GitHub error reporting", function()
  local gh = require("review.util.gh")

  it("surfaces the reason, not just the status line", function()
    local body = '{"message":"Unprocessable Entity","errors":["Review Can not request changes on your own pull request"]}'
    assert.equals("Review Can not request changes on your own pull request",
      gh.error_message(body, "gh: Unprocessable Entity (HTTP 422)"))
  end)

  it("handles structured error objects and falls back to the message", function()
    assert.equals("path is invalid",
      gh.error_message('{"errors":[{"message":"path is invalid"}]}', "boom"))
    assert.equals("Not Found", gh.error_message('{"message":"Not Found"}', "boom"))
  end)

  it("falls back to stderr when the body is not JSON", function()
    assert.equals("gh: connection refused", gh.error_message("<html>", "gh: connection refused"))
  end)

  it("recognises throttling so a publish can back off instead of failing", function()
    assert.is_true(gh.is_rate_limited("You have exceeded a secondary rate limit"))
    assert.is_true(gh.is_rate_limited("API rate limit exceeded"))
    assert.is_false(gh.is_rate_limited("Validation failed"))
  end)
end)

describe("pull request metadata", function()
  it("lists each reviewer once, at their latest state", function()
    local PR = require("review.source.github_pr")
    local pr = setmetatable({ _pr = {
      reviewRequests = { { login = "alice" } },
      reviews = {
        { author = { login = "bob" }, state = "COMMENTED" },
        { author = { login = "bob" }, state = "APPROVED" },
        { author = { login = "alice" }, state = "CHANGES_REQUESTED" },
      },
    } }, PR)
    assert.same({ "alice (CHANGES_REQUESTED)", "bob (APPROVED)" }, pr:reviewers())
  end)
end)

describe("duplicate threads", function()
  it("collapses two local records that point at one upstream comment", function()
    local dir = fixture.create()
    local source = assert(require("review.source").create(".", dir, { base = "main" }))
    local store = require("review.comments.store").for_source(source)

    local imported = store:add({ file = "src/auth.lua", side = "RIGHT", line_start = 1, body = "same text" })
    store:update(imported.id, { github_id = "GH9", github_thread_id = "T9", origin = "github" })
    local stray = store:add({ file = "src/auth.lua", side = "RIGHT", line_start = 1, body = "same text" })
    store:update(stray.id, { github_id = "GH9", origin = "github" })

    assert.equals(2, #store:all_threads())
    assert.equals(1, store:dedupe_github())
    assert.equals(1, #store:all_threads())
    -- The importer's record survives: it is the one with upstream provenance.
    assert.is_truthy(store:get(imported.id))
    assert.is_nil(store:get(stray.id))
  end)

  it("leaves distinct comments alone", function()
    local dir = fixture.create()
    local source = assert(require("review.source").create(".", dir, { base = "main" }))
    local store = require("review.comments.store").for_source(source)
    local a = store:add({ file = "src/auth.lua", side = "RIGHT", line_start = 1, body = "a" })
    local b = store:add({ file = "src/auth.lua", side = "RIGHT", line_start = 2, body = "b" })
    store:update(a.id, { github_id = "GH1" })
    store:update(b.id, { github_id = "GH2" })
    assert.equals(0, store:dedupe_github())
    assert.equals(2, #store:all_threads())
  end)
end)

describe("inline rendering ownership", function()
  local markers = require("review.ui.markers")
  local config = require("review.config")

  after_each(function()
    config.setup({}) -- back to defaults
    require("review").diffview_renders_github = false
  end)

  it("lets Diffview draw the threads it was handed, so nothing renders twice", function()
    config.setup({ inline_owner = "auto" })
    require("review").diffview_renders_github = true
    assert.is_true(markers.delegated({ origin = "github" }))
    -- Local drafts were never bridged, so they stay ours to draw.
    assert.is_false(markers.delegated({ origin = "local" }))
  end)

  it("draws everything itself when the bridge is not active", function()
    config.setup({ inline_owner = "auto" })
    require("review").diffview_renders_github = false
    assert.is_false(markers.delegated({ origin = "github" }))
  end)

  it("honours an explicit owner", function()
    config.setup({ inline_owner = "review" })
    require("review").diffview_renders_github = true
    assert.is_false(markers.delegated({ origin = "github" }))
    config.setup({ inline_owner = "diffview" })
    assert.is_true(markers.delegated({ origin = "local" }))
  end)
end)

describe("publish preview", function()
  it("warns when reviewing your own pull request", function()
    local text = table.concat(require("review.ui.publish").lines(
      { event = "APPROVE", commit_id = "abc", body = "", self_review = true },
      { { file = "a.lua", line_start = 1, side = "RIGHT", body = "x" } }), "\n")
    assert.is_truthy(text:find("only accepts COMMENT", 1, true))
    -- The footer must survive: a nil in the middle of a table constructor used to
    -- leave #lines undefined and swallow everything appended after it.
    assert.is_truthy(text:find("Ctrl-S publish", 1, true))
  end)
end)
