-- Tests for the Claude contract: stream-json parsing + findings extraction.
local contract = require("review.claude.contract")

describe("prompt construction", function()
  it("keeps conversations but replaces huge embedded diffs with a safe command", function()
    local source = {
      title = function() return "PR" end,
      head_rev = function() return "head123" end,
      base_rev = function() return "base123" end,
    }
    local prompt = contract.user_prompt({ source = source, threads = {
      { id = "c1", file = "a.lua", line_start = 4, side = "RIGHT", author = "alice", body = "root",
        replies = { { author = "bob", body = "follow up" } } },
    } })
    assert.is_truthy(prompt:find("follow up", 1, true))
    assert.is_truthy(prompt:find("git diff --no-ext-diff --no-textconv base123...head123 --", 1, true))
    assert.is_nil(prompt:find("```diff", 1, true))
  end)
end)

describe("parse_stream_line", function()
  it("extracts the session id from a system event", function()
    local ev = contract.parse_stream_line('{"type":"system","session_id":"abc"}')
    assert.equals("session", ev.kind)
    assert.equals("abc", ev.session_id)
  end)

  it("surfaces assistant text as progress", function()
    local line = '{"type":"assistant","message":{"content":[{"type":"text","text":"looking"}]}}'
    local ev = contract.parse_stream_line(line)
    assert.equals("progress", ev.kind)
    assert.equals("looking", ev.text)
  end)

  it("labels tool_use blocks", function()
    local line = '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read"}]}}'
    local ev = contract.parse_stream_line(line)
    assert.is_truthy(ev.text:find("Read"))
  end)

  it("captures the result", function()
    local ev = contract.parse_stream_line('{"type":"result","result":"done","is_error":false}')
    assert.equals("result", ev.kind)
    assert.equals("done", ev.text)
  end)

  it("ignores malformed lines", function()
    assert.is_nil(contract.parse_stream_line("not json"))
    assert.is_nil(contract.parse_stream_line(""))
  end)
end)

describe("extract_findings", function()
  it("parses a trailing json block", function()
    local text = [[Here is my review.

```json
{"verdict":"approve","summary":"lgtm","thread_replies":[],"new_comments":[]}
```]]
    local f, err = contract.extract_findings(text)
    assert.is_nil(err)
    assert.equals("approve", f.verdict)
  end)

  it("takes the LAST json block if several", function()
    local text = "```json\n{\"verdict\":\"comment\"}\n```\nmore\n```json\n{\"verdict\":\"request_changes\"}\n```"
    local f = contract.extract_findings(text)
    assert.equals("request_changes", f.verdict)
  end)

  it("errors on missing block", function()
    local f, err = contract.extract_findings("no json here")
    assert.is_nil(f)
    assert.is_truthy(err)
  end)
end)

describe("prompts", function()
  it("system prompt names the schema fields", function()
    local sp = contract.system_prompt()
    assert.is_truthy(sp:find("thread_replies"))
    assert.is_truthy(sp:find("reviewed_head_sha"))
  end)
end)
