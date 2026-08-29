local list = require("review.ui.list")

describe("review source quickfix", function()
  it("cycles picker states in the documented order", function()
    assert.equals("closed", list._next_state("open"))
    assert.equals("merged", list._next_state("closed"))
    assert.equals("all", list._next_state("merged"))
    assert.equals("open", list._next_state("all"))
  end)

  it("shows the active PR filter in the picker title", function()
    local merged = list._picker_title({ state = "merged", prs_only = true })
    assert.is_truthy(merged:find("filter: MERGED", 1, true))
    assert.is_truthy(merged:find("pull requests", 1, true))
    local combined = list._picker_title({ state = "closed" })
    assert.is_truthy(combined:find("filter: CLOSED", 1, true))
    assert.is_truthy(combined:find("local branches", 1, true))
  end)

  it("persists picker state per repository", function()
    local state = require("review.state")
    local root = vim.fn.tempname()
    state.set_root(root)
    list._save_picker_state("/repo/a", { state = "merged" })
    list._save_picker_state("/repo/b", { state = "closed" })
    assert.equals("merged", list._picker_state("/repo/a").state)
    assert.equals("closed", list._picker_state("/repo/b").state)
    state.set_root(nil)
  end)

  it("caches PR metadata until an explicit refresh", function()
    local gh = require("review.util.gh")
    local available, list_prs = gh.available, gh.list_prs
    local calls = 0
    gh.available = function() return true end
    gh.list_prs = function()
      calls = calls + 1
      return { { number = 1, title = "One", author = { login = "me" }, labels = {} } }
    end
    list._clear_cache()
    list.gather_items("/repo/cache", { state = "open", prs_only = true })
    list.gather_items("/repo/cache", { state = "open", prs_only = true })
    assert.equals(1, calls)
    list.gather_items("/repo/cache", { state = "open", prs_only = true, refresh = true })
    assert.equals(2, calls)
    gh.available, gh.list_prs = available, list_prs
  end)

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


  it("builds searchable commit picker rows", function()
    local fixture = require("tests.fixture")
    local dir = fixture.create()
    local items = list._commit_items(dir, 20)
    assert.is_true(#items >= 3)
    assert.equals("commit", items[1].kind)
    assert.equals("commit", items[1].arg.kind)
    assert.is_truthy(items[1].arg.rev:match("^[0-9a-f]+$"))
    assert.is_truthy(items[1].search:find("docs", 1, true))
  end)
end)
