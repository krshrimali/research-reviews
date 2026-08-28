local list = require("review.ui.list")

describe("review source quickfix", function()
  it("provides actionable state, source, search, and refresh filters", function()
    local rows = list._filter_rows({ state = "open", source = "both", search = "author:me" })
    local labels = vim.tbl_map(function(row) return row.label end, rows)
    local text = table.concat(labels, "\n")
    assert.is_truthy(text:find("Search: author:me", 1, true))
    assert.is_truthy(text:find("State: open", 1, true))
    assert.is_truthy(text:find("State: merged", 1, true))
    assert.is_truthy(text:find("Sources: branches", 1, true))
    assert.is_truthy(text:find("Refresh results", 1, true))
  end)

  it("formats PR metadata and description for preview", function()
    local lines = list._preview_lines({ review_source = {
      kind = "pr", arg = 42, preview = { title = "Fix auth", author = "octocat",
        state = "OPEN", head = "fix", base = "main", labels = { "bug" }, body = "Details" },
    } }, { state = "open", source = "both", search = "" })
    local text = table.concat(lines, "\n")
    assert.is_truthy(text:find("# #42 · Fix auth", 1, true))
    assert.is_truthy(text:find("@octocat", 1, true))
    assert.is_truthy(text:find("Details", 1, true))
  end)

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
