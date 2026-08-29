-- Tests for the contextual action menu.
local menu = require("review.ui.menu")

describe("menu.open", function()
  it("renders items with accelerators and a separator", function()
    local fired = nil
    menu.open({
      { key = "c", label = "Comment here", fn = function() fired = "c" end },
      { sep = "review" },
      { key = "C", label = "Claude review", fn = function() fired = "C" end },
    }, { title = "T" })
    local buf = vim.api.nvim_get_current_buf()
    local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    assert.is_truthy(text:find("Comment here"))
    assert.is_truthy(text:find("review"))
    assert.is_truthy(text:find("Claude review"))

    -- The accelerator 'c' must be a buffer-local mapping that fires its fn.
    local maps = vim.api.nvim_buf_get_keymap(buf, "n")
    local has_c = false
    for _, m in ipairs(maps) do
      if m.lhs == "c" then has_c = true end
    end
    assert.is_true(has_c, "accelerator 'c' should be mapped")

    -- Invoke the mapping's callback and confirm dispatch (schedule → run).
    for _, m in ipairs(maps) do
      if m.lhs == "c" and m.callback then
        m.callback()
      end
    end
    vim.wait(200, function() return fired ~= nil end, 10)
    assert.equals("c", fired)
  end)

  it("closes on q without firing anything", function()
    menu.open({ { key = "a", label = "A", fn = function() error("should not fire") end } }, {})
    local win = vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_get_current_buf()
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
      if m.lhs == "q" and m.callback then m.callback() end
    end
    assert.is_false(vim.api.nvim_win_is_valid(win))
  end)
end)

describe("review target menu", function()
  it("lists PR, branch, commit, current, and combined choices", function()
    local review = require("review")
    review.current = nil
    review.choose_source()
    local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    assert.is_truthy(text:find("Pull request", 1, true))
    assert.is_truthy(text:find("Local branch", 1, true))
    assert.is_truthy(text:find("Single commit", 1, true))
    assert.is_truthy(text:find("Current branch", 1, true))
    assert.is_truthy(text:find("Combined PR / branch", 1, true))
    vim.cmd("close")
  end)
end)
