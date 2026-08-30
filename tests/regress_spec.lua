-- Regression tests for bugs found in code review.
local fixture = require("tests.fixture")

local function setup()
  local dir = fixture.create()
  local Src = require("review.source")
  local source = assert(Src.create(".", dir, { base = "main" }))
  local store = require("review.comments.store").for_source(source)
  return dir, source, store
end

describe("deletion persistence (tombstones)", function()
  it("a deleted comment does not resurrect after reload", function()
    local _, source, store = setup()
    local c = store:add({ file = "src/auth.lua", side = "RIGHT", line_start = 2, body = "x" })
    store:reply(c.id, "r")
    store:delete(c.id)
    -- Reload from disk: neither root nor reply should return.
    local store2 = require("review.comments.store").for_source(source)
    assert.is_nil(store2:get(c.id))
    assert.equals(0, #store2:threads_for_file("src/auth.lua"))
    -- Adding another comment (which triggers save/merge) must not bring it back.
    store2:add({ file = "src/auth.lua", side = "RIGHT", line_start = 3, body = "y" })
    local store3 = require("review.comments.store").for_source(source)
    assert.is_nil(store3:get(c.id))
    assert.equals(1, #store3:threads_for_file("src/auth.lua"))
  end)
end)

describe("github_sync preserves local resolution", function()
  it("maps imported roots and nested replies into Diffview's comments tree", function()
    local _, _, store = setup()
    local root = store:add({ file = "src/auth.lua", side = "RIGHT", line_start = 2,
      body = "root", origin = "github", author = "alice", github_thread_id = "T0" })
    store:reply(root.id, "answer", { origin = "github", author = "bob" })
    local mapped = require("review")._diffview_github_threads(store)
    assert.equals(1, #mapped)
    assert.equals("src/auth.lua", mapped[1].path)
    assert.equals("b", mapped[1].side)
    assert.equals("alice", mapped[1].author)
    assert.equals(1, #mapped[1].replies)
    assert.equals("bob", mapped[1].replies[1].author)
  end)

  it("does not revert a locally-resolved thread on re-import", function()
    local _, source, store = setup()
    -- Fake source exposing an unresolved upstream thread.
    local node = {
      id = "T1",
      isResolved = false,
      path = "src/auth.lua",
      line = 2,
      diffSide = "RIGHT",
      comments = { nodes = { { id = "C1", author = { login = "alice" }, body = "hi", createdAt = "2026-01-01T00:00:00Z" } } },
    }
    local fake = {
      threads = function() return { node } end,
      metadata = function() return source:metadata() end,
      base_rev = function() return source:base_rev() end,
      head_rev = function() return source:head_rev() end,
    }
    local sync = require("review.comments.github_sync")
    assert.equals(1, sync.import(fake, store))
    -- Find the imported root and resolve it locally.
    local root
    for _, c in pairs(store.comments) do
      if c.github_id == "C1" then root = c end
    end
    assert.is_truthy(root)
    store:set_resolved(root.id, true)
    -- Re-import (upstream still unresolved) must NOT revert local resolution.
    sync.import(fake, store)
    assert.equals("resolved", store:get(root.id).status)
  end)

  it("imports reply chains idempotently and refreshes moved metadata", function()
    local _, source, store = setup()
    local node = {
      id = "T2", isResolved = false, isOutdated = false, path = "src/auth.lua", line = 2,
      diffSide = "RIGHT", comments = { nodes = {
        { id = "C2", author = { login = "alice" }, body = "root", path = vim.NIL,
          reactionGroups = { { content = "EYES", users = { totalCount = 2 } } },
          line = vim.NIL, originalLine = 2, createdAt = "2026-01-01T00:00:00Z" },
        { id = "C3", author = { login = "bob" }, body = "reply", createdAt = "2026-01-02T00:00:00Z" },
      } },
    }
    local fake = {
      threads = function() return { node } end,
      metadata = function() return source:metadata() end,
      base_rev = function() return source:base_rev() end,
      head_rev = function() return source:head_rev() end,
    }
    local sync = require("review.comments.github_sync")
    assert.equals(2, sync.import(fake, store))
    local reimported, import_err, refreshed = sync.import(fake, store)
    assert.equals(0, reimported)
    assert.is_nil(import_err)
    assert.equals(2, refreshed)
    assert.equals(1, #store:all_threads())
    local root = store:all_threads()[1]
    assert.equals(1, #store:replies(root.id))
    assert.equals("bob", store:replies(root.id)[1].author)
    assert.equals(2, root.reactions.EYES)
    node.line, node.isOutdated = 3, true
    node.comments.nodes[1].originalLine = vim.NIL
    node.comments.nodes[1].body = "updated root"
    assert.equals(0, sync.import(fake, store))
    root = store:get(root.id)
    assert.equals(3, root.line_start)
    assert.equals("updated root", root.body)
    assert.equals("outdated", root.status)
  end)

  it("returns upstream import failures to the caller", function()
    local _, source, store = setup()
    local fake = {
      threads = function() return {}, "corporate GitHub unavailable" end,
      metadata = function() return source:metadata() end,
    }
    local imported, err = require("review.comments.github_sync").import(fake, store)
    assert.equals(0, imported)
    assert.equals("corporate GitHub unavailable", err)
  end)
end)

describe("reanchor leaves LEFT-side file paths alone on rename", function()
  it("does not rewrite c.file for LEFT comments", function()
    local _, source, store = setup()
    local c = store:add({ file = "old.lua", side = "LEFT", line_start = 1, body = "z" })
    -- Force a rename map old.lua -> new.lua.
    store:reanchor({ ["old.lua"] = "new.lua" })
    assert.equals("old.lua", store:get(c.id).file)
  end)
end)
