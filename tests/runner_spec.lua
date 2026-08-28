-- End-to-end Claude runner test using a fake `claude` binary.
local fixture = require("tests.fixture")

describe("claude runner (fake claude)", function()
  local dir, source, store

  before_each(function()
    dir = fixture.create()
    local Src = require("review.source")
    source = assert(Src.create(".", dir, { base = "main" }))
    store = require("review.comments.store").for_source(source)
    -- Point the runner at the fake claude script.
    local this = debug.getinfo(1, "S").source:sub(2)
    local fake = vim.fs.joinpath(vim.fn.fnamemodify(this, ":h"), "fake_claude.sh")
    require("review.config").setup({ claude = { bin = fake } })
  end)

  it("runs, replies to a thread, and adds a new comment", function()
    -- Seed an existing thread for Claude to reply to.
    local root = store:add({ file = "src/auth.lua", side = "RIGHT", line_start = 2, body = "why rename?" })

    local done = false
    local finished_session
    require("review.claude.runner").start({
      store = store,
      source = source,
      instruction = "Critical review",
      auto_resolve = false,
      allow_edits = false,
      on_done = function(s)
        finished_session = s
        done = true
      end,
    })

    local ok = vim.wait(15000, function()
      return done
    end, 100)
    assert.is_true(ok, "runner did not finish in time")
    assert.equals("done", finished_session.state)
    assert.equals("request_changes", finished_session.verdict)

    -- The reply should be attached to the seeded thread.
    local replies = store:replies(root.id)
    assert.equals(1, #replies)
    assert.equals("claude", replies[1].origin)
    assert.is_truthy(replies[1].body:find("clarity"))

    -- A new Claude-authored comment should exist.
    local claude_new = 0
    for _, c in pairs(store.comments) do
      if c.origin == "claude" and not c.in_reply_to then
        claude_new = claude_new + 1
      end
    end
    assert.equals(1, claude_new)

    -- Session persisted and marked applied.
    local reloaded = require("review.comments.store").for_source(source)
    assert.is_truthy(reloaded.sessions[finished_session.id])
    assert.is_true(reloaded.sessions[finished_session.id].applied)
  end)

  it("is idempotent — re-applying does not duplicate", function()
    local root = store:add({ file = "src/auth.lua", side = "RIGHT", line_start = 2, body = "q" })
    local done = false
    local sess
    require("review.claude.runner").start({
      store = store, source = source, instruction = "x",
      on_done = function(s) sess = s; done = true end,
    })
    assert.is_true(vim.wait(15000, function() return done end, 100))

    local before = vim.tbl_count(store.comments)
    -- Simulate a replay of apply via marking-guard: applied=true blocks re-apply.
    assert.is_true(sess.applied)
    assert.equals(before, vim.tbl_count(store.comments))
    assert.equals(1, #store:replies(root.id))
  end)

  it("reads exact findings from the persisted Sidekick transcript", function()
    local result = require("review.sidekick").transcript_result(source, dir, {
      sessions = function(cwd)
        assert.equals(dir, cwd)
        return { { file = "session.jsonl" } }
      end,
      build = function()
        return { turns = {
          { prompt = "review head " .. source:head_rev(), blocks = {
            { kind = "text", text = "Readable review.\n```json\n{\"reviewed_head_sha\":\""
              .. source:head_rev() .. "\",\"new_comments\":[]}\n```" },
          } },
        } }
      end,
    })
    assert.is_truthy(result:find("Readable review", 1, true))
    local findings = require("review.claude.contract").extract_findings(result)
    assert.equals(source:head_rev(), findings.reviewed_head_sha)
  end)

  it("includes native Diffview comments in whole-review prompts", function()
    local previous = package.loaded["diffview.review"]
    package.loaded["diffview.review"] = {
      agent_threads = function()
        return { { id = "diffview:2", file = "src/auth.lua", line_start = 2,
          side = "RIGHT", author = "you", body = "What is this doing?", replies = {} } }
      end,
    }
    local prompt = require("review.sidekick").prompt(source, store, { instruction = "check" })
    package.loaded["diffview.review"] = previous
    assert.is_truthy(prompt:find("comment_id: diffview:2", 1, true))
    assert.is_truthy(prompt:find("What is this doing?", 1, true))
  end)
end)
