-- Tests for comment anchoring re-location logic.
local anchor = require("review.comments.anchor")

describe("anchor.compute", function()
  it("captures line text, hash, and context", function()
    local lines = { "a", "b", "target", "c", "d" }
    local a = anchor.compute(lines, 3)
    assert.equals("target", a.line_text)
    assert.same({ "a", "b" }, a.context_before)
    assert.same({ "c", "d" }, a.context_after)
    assert.equals(1, a.occurrence)
  end)

  it("counts occurrence for duplicate lines", function()
    local lines = { "dup", "x", "dup", "y", "dup" }
    assert.equals(2, anchor.compute(lines, 3).occurrence)
    assert.equals(3, anchor.compute(lines, 5).occurrence)
  end)
end)

describe("anchor.relocate", function()
  it("finds an unmoved line", function()
    local lines = { "a", "b", "target", "c" }
    local a = anchor.compute(lines, 3)
    assert.equals(3, anchor.relocate(lines, a))
  end)

  it("follows a line that shifted down", function()
    local orig = { "a", "b", "target", "c" }
    local a = anchor.compute(orig, 3)
    local shifted = { "new1", "new2", "a", "b", "target", "c" }
    assert.equals(5, anchor.relocate(shifted, a))
  end)

  it("returns nil when the line is gone", function()
    local orig = { "a", "b", "target", "c" }
    local a = anchor.compute(orig, 3)
    local gone = { "a", "b", "c" }
    assert.is_nil(anchor.relocate(gone, a))
  end)

  it("disambiguates duplicates by context", function()
    local orig = { "before1", "dup", "after1", "x", "before2", "dup", "after2" }
    local a = anchor.compute(orig, 2) -- first dup, context before1/after1
    -- Both dups still present; context should pick index 2.
    assert.equals(2, anchor.relocate(orig, a))
  end)

  it("falls back to occurrence when context is identical", function()
    local orig = { "ctx", "dup", "ctx", "ctx", "dup", "ctx" }
    local a = anchor.compute(orig, 2) -- occurrence 1
    -- Context around both dups is identical (ctx/ctx); occurrence disambiguates.
    local loc = anchor.relocate(orig, a)
    assert.equals(2, loc)
  end)
end)
