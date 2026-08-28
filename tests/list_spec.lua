local list = require("review.ui.list")

describe("review source quickfix", function()
  it("retains source metadata and opens the selected review", function()
    local cwd = vim.fn.getcwd()
    local items = {
      { kind = "pr", arg = 42, label = "#42 Fix auth" },
      { kind = "branch", arg = "feature/cache", label = "feature/cache" },
    }
    local opened
    list.to_quickfix(items, cwd, function(item) opened = item end)

    local info = vim.fn.getqflist({ title = 0, items = 0 })
    assert.equals("Review · PRs and branches", info.title)
    assert.equals(2, #info.items)
    assert.equals(42, info.items[1].user_data.review_source.arg)
    assert.equals("feature/cache", info.items[2].user_data.review_source.arg)

    vim.fn.setqflist({}, "a", { idx = 2 })
    local buf = vim.api.nvim_get_current_buf()
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
      if map.lhs == "<CR>" and map.callback then map.callback() end
    end
    assert.is_not_nil(opened)
    assert.equals("branch", opened.kind)
    assert.equals("feature/cache", opened.arg)
  end)
end)
