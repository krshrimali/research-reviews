-- Tests for the compose buffer body extraction.
local compose = require("review.ui.compose")

-- Drive a compose buffer: seed content, then submit via :write (BufWriteCmd).
local function run(setup_lines, opts)
  local captured = {}
  opts = vim.tbl_extend("force", {
    title = "T",
    on_submit = function(body, is_sugg, sugg)
      captured.body = body
      captured.is_sugg = is_sugg
      captured.sugg = sugg
    end,
  }, opts or {})
  compose.open(opts)
  local buf = vim.api.nvim_get_current_buf()
  -- Replace the editable body region: keep header, append user lines at the end.
  local existing = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  -- Find where the header ends (first non-comment, non-fence editable line): we just
  -- append user content after the current content to emulate typing in the body.
  vim.api.nvim_buf_set_lines(buf, #existing, #existing, false, setup_lines)
  vim.cmd("silent write")
  return captured
end

describe("compose body extraction", function()
  it("keeps a plain multi-line body verbatim", function()
    local c = run({ "First line.", "Second line." }, {})
    assert.is_truthy(c.body:find("First line."))
    assert.is_truthy(c.body:find("Second line."))
  end)

  it("does NOT drop lines that begin with two spaces (indented code)", function()
    local c = run({ "Look at this:", "  indented_code()" }, {})
    assert.is_truthy(c.body:find("indented_code"), "indented body line must be preserved")
  end)

  it("extracts a suggestion block", function()
    -- Not seed mode: provide the whole suggestion block as body content.
    local c = run({ "```suggestion", "return get_or_refresh()", "```" }, {})
    assert.is_true(c.is_sugg)
    assert.is_truthy(c.sugg and c.sugg:find("get_or_refresh"))
  end)

  it("does not strip the word inside a body that mentions <!--", function()
    local c = run({ "use the <!-- literal marker" }, {})
    -- A line STARTING with <!-- is header; this one starts with 'use', keep it.
    assert.is_truthy(c.body:find("literal marker"))
  end)
end)
