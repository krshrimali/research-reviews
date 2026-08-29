-- Integration tests: git parsing, LocalBranch source, comment store round-trip.
local fixture = require("tests.fixture")
local git = require("review.util.git")

describe("LocalBranch source (explicit base)", function()
  local dir, source

  before_each(function()
    dir = fixture.create()
    local Src = require("review.source")
    local err
    source, err = Src.create(".", dir, { base = "main" })
    assert(source, err)
  end)

  it("resolves base and head", function()
    assert.equals("branch", source:kind())
    assert.is_truthy(source:base_rev())
    assert.is_truthy(source:head_rev())
    assert.are_not.equals(source:base_rev(), source:head_rev())
  end)

  it("lists commits recent->old", function()
    local commits = source:commits()
    assert.equals(2, #commits)
    assert.equals("docs", commits[1].subject)
    assert.equals("add refresh + cache", commits[2].subject)
  end)

  it("lists changed files with counts", function()
    local files = source:files()
    local by_path = {}
    for _, f in ipairs(files) do
      by_path[f.path] = f
    end
    assert.is_truthy(by_path["src/auth.lua"])
    assert.is_truthy(by_path["src/cache.cpp"])
    assert.is_truthy(by_path["README.md"])
    assert.equals("added", by_path["src/cache.cpp"].status)
    assert.is_true(by_path["src/auth.lua"].additions >= 1)
  end)

  it("reports caps with no PR features", function()
    local caps = source:caps()
    assert.is_false(caps.has_threads)
    assert.is_false(caps.can_submit)
  end)

  it("builds a diffview spec base...head", function()
    local spec = source:diffview_spec()
    assert.is_truthy(spec:find("%.%.%."))
  end)

  it("reviews the selected branch even when it is not checked out", function()
    local main = assert(require("review.source").create("main", dir, { base = "main" }))
    assert.equals(git.rev_parse("main", dir), main:head_rev())
    assert.are_not.equals(git.rev_parse("HEAD", dir), main:head_rev())
  end)
end)

describe("Commit source", function()
  it("reviews exactly the selected commit against its first parent", function()
    local dir = fixture.create()
    local selected = assert(git.rev_parse("HEAD^", dir))
    local source = assert(require("review.source").create({ kind = "commit", rev = selected }, dir))
    assert.equals("commit", source:kind())
    assert.equals(selected, source:head_rev())
    assert.equals(git.rev_parse(selected .. "^", dir), source:base_rev())
    assert.equals(1, #source:commits())
    assert.equals("add refresh + cache", source:commits()[1].subject)
    assert.is_truthy(source:title():find("add refresh", 1, true))
    assert.is_truthy(source:diffview_spec():find("^!", 1, true))
  end)

  it("can review the repository's root commit", function()
    local dir = fixture.create()
    local root = assert(git.rev_parse("main", dir))
    local source = assert(require("review.source").create({ kind = "commit", rev = root }, dir))
    assert.equals("commit", source:kind())
    assert.is_true(#source:files() >= 1)
  end)
end)

describe("comment store round-trip", function()
  local dir, source, Store

  before_each(function()
    dir = fixture.create()
    local Src = require("review.source")
    source = assert(Src.create(".", dir, { base = "main" }))
    Store = require("review.comments.store")
  end)

  it("adds, retrieves, and persists a comment", function()
    local store = Store.for_source(source)
    local c = store:add({
      file = "src/auth.lua",
      side = "RIGHT",
      line_start = 2,
      body = "why rename this?",
    })
    assert.is_truthy(c.id)
    assert.equals("draft", c.status)
    assert.is_truthy(c.anchor.line_text)

    -- Reload a fresh store: comment should persist.
    local store2 = Store.for_source(source)
    local threads = store2:threads_for_file("src/auth.lua")
    assert.equals(1, #threads)
    assert.equals("why rename this?", threads[1].body)
  end)

  it("supports replies forming a thread", function()
    local store = Store.for_source(source)
    local root = store:add({ file = "src/auth.lua", side = "RIGHT", line_start = 2, body = "root" })
    store:reply(root.id, "a reply")
    local replies = store:replies(root.id)
    assert.equals(1, #replies)
    assert.equals("a reply", replies[1].body)
    assert.equals(root.id, replies[1].in_reply_to)
  end)

  it("attributes agent-authored roots and replies to Claude", function()
    local store = Store.for_source(source)
    local root = store:add({
      file = "src/auth.lua", side = "RIGHT", line_start = 2, body = "finding", origin = "claude",
    })
    local reply = store:reply(root.id, "answer", { origin = "claude" })
    assert.equals("claude", root.author)
    assert.equals("claude", reply.author)
  end)

  it("resolves and deletes threads", function()
    local store = Store.for_source(source)
    local root = store:add({ file = "src/auth.lua", side = "RIGHT", line_start = 2, body = "x" })
    store:reply(root.id, "r")
    store:set_resolved(root.id, true)
    assert.equals("resolved", store:get(root.id).status)
    store:delete(root.id)
    assert.is_nil(store:get(root.id))
    assert.equals(0, #store:replies(root.id)) -- replies removed with root
  end)
end)
