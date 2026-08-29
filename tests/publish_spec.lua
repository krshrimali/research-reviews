describe("review publish preview", function()
  it("shows the exact review and inline comments before submission", function()
    local lines = require("review.ui.publish").lines({
      event = "COMMENT", commit_id = "abc123", body = "Review body",
    }, { { file = "src/a.lua", line_start = 4, side = "RIGHT", body = "Fix this" } })
    local text = table.concat(lines, "\n")
    assert.is_truthy(text:find("abc123", 1, true))
    assert.is_truthy(text:find("src/a.lua:4", 1, true))
    assert.is_truthy(text:find("Fix this", 1, true))
    assert.is_truthy(text:find("Ctrl-S publish", 1, true))
  end)
end)
