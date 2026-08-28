-- review.nvim :: fuzzy PR / local-branch picker.
--
-- Gathers open PRs (via gh) and local branches, presents them through the best
-- available fuzzy picker (snacks -> fzf-lua -> vim.ui.select), and invokes a
-- callback with the chosen {kind, arg}.

local gh = require("review.util.gh")
local git = require("review.util.git")
local proc = require("review.util.proc")
local util = require("review.util")
local config = require("review.config")

local M = {}

--- Export PR/branch picker rows to quickfix. Quickfix's native file fields are not
--- enough for a logical review target, so retain the source item in `user_data` and
--- make <CR> invoke the same callback as the picker.
---@param items table[]
---@param cwd string
---@param on_choose fun(item:table)
function M.to_quickfix(items, cwd, on_choose)
  if not items or #items == 0 then
    util.notify("no PRs or branches selected", vim.log.levels.WARN)
    return
  end
  local qf = {}
  for _, item in ipairs(items) do
    qf[#qf + 1] = {
      filename = cwd,
      lnum = 1,
      text = item.label,
      user_data = { review_source = item },
    }
  end
  vim.fn.setqflist({}, "r", { title = "Review · PRs and branches", items = qf })
  vim.cmd("botright copen")
  local qfbuf = vim.api.nvim_get_current_buf()
  vim.keymap.set("n", "<CR>", function()
    local info = vim.fn.getqflist({ idx = 0, items = 0 })
    local entry = info.items[info.idx]
    local item = entry and entry.user_data and entry.user_data.review_source
    if item then
      vim.cmd("cclose")
      on_choose(item)
    end
  end, { buffer = qfbuf, nowait = true, desc = "open PR or branch review" })
  util.notify(string.format("sent %d review source%s to quickfix", #qf, #qf == 1 and "" or "s"))
end

--- Local branches other than the current one.
---@param cwd string
---@return table[] items
local function local_branches(cwd)
  local ok, out = proc.git({ "for-each-ref", "--format=%(refname:short)", "refs/heads/" }, cwd)
  local items = {}
  if not ok then
    return items
  end
  local cur = git.current_branch(cwd)
  for name in vim.gsplit(out, "\n", { trimempty = true }) do
    table.insert(items, {
      kind = "branch",
      arg = name,
      label = string.format("⎇  %s%s", name, name == cur and " (current)" or ""),
      search = "branch " .. name,
    })
  end
  return items
end

--- PRs as picker items. `search` is passed to gh (fuzzy server-side filter).
---@param cwd string
---@param opts table
---@return table[] items
local function pr_items(cwd, opts)
  if not gh.available() then
    return {}
  end
  local prs = gh.list_prs({ search = opts.search, limit = opts.limit or 100, state = opts.state }, cwd)
  local items = {}
  for _, pr in ipairs(prs) do
    local labels = {}
    for _, l in ipairs(pr.labels or {}) do
      table.insert(labels, l.name)
    end
    items[#items + 1] = {
      kind = "pr",
      arg = pr.number,
      label = string.format(
        "#%-5d %s  @%s  %s%s",
        pr.number,
        util.truncate(pr.title, 50),
        pr.author and pr.author.login or "?",
        pr.state or "",
        pr.reviewDecision and ("  " .. pr.reviewDecision) or ""
      ),
      search = string.format("#%d %s %s %s", pr.number, pr.title,
        pr.author and pr.author.login or "", table.concat(labels, " ")),
      preview = {
        title = pr.title, body = pr.body, author = pr.author and pr.author.login,
        state = pr.state, draft = pr.isDraft, updated = pr.updatedAt,
        head = pr.headRefName, base = pr.baseRefName, labels = labels,
        assignees = vim.tbl_map(function(a) return a.login end, pr.assignees or {}),
        review = pr.reviewDecision,
      },
    }
  end
  return items
end

--- Gather all pickable items.
---@param cwd string
---@param opts table|nil { search, state, limit, branches_only }
---@return table[]
function M.gather_items(cwd, opts)
  opts = opts or {}
  local items = {}
  if not opts.branches_only then
    vim.list_extend(items, pr_items(cwd, opts))
  end
  if not opts.prs_only then vim.list_extend(items, local_branches(cwd)) end
  return items
end

local function filter_rows(filters)
  local rows = {
    { action = "search", label = "⌕  Search: " .. (filters.search ~= "" and filters.search or "(none)") },
    { action = "clear", label = "×  Clear search" },
    { action = "refresh", label = "↻  Refresh results" },
  }
  for _, state in ipairs({ "open", "closed", "merged", "all" }) do
    rows[#rows + 1] = {
      action = "state", value = state,
      label = string.format("%s  State: %s", filters.state == state and "●" or "○", state),
    }
  end
  for _, source in ipairs({ "both", "prs", "branches" }) do
    rows[#rows + 1] = {
      action = "source", value = source,
      label = string.format("%s  Sources: %s", filters.source == source and "●" or "○", source),
    }
  end
  return rows
end

M._filter_rows = filter_rows

local function preview_lines(data, filters)
  if data.review_filter then
    local row = data.review_filter
    return { "# Review filter", "", row.label, "", "Press Enter to apply this filter.", "",
      ("Current state: `%s`"):format(filters.state),
      ("Current sources: `%s`"):format(filters.source),
      ("Current search: `%s`"):format(filters.search ~= "" and filters.search or "none") }
  end
  local item = data.review_source
  if not item then return { "# Review picker", "", "Select a filter or review." } end
  if item.kind == "branch" then
    return { "# " .. item.arg, "", "Local branch", "", "Press Enter to review this branch." }
  end
  local p = item.preview or {}
  local lines = {
    ("# #%s · %s"):format(item.arg, p.title or "Pull request"), "",
    ("**@%s** · `%s`%s"):format(p.author or "?", p.state or "?", p.draft and " · draft" or ""), "",
    ("`%s` → `%s`"):format(p.head or "?", p.base or "?"), "",
  }
  if p.review and p.review ~= "" then vim.list_extend(lines, { "Review: **" .. p.review .. "**", "" }) end
  if #(p.labels or {}) > 0 then vim.list_extend(lines, { "Labels: " .. table.concat(p.labels, ", "), "" }) end
  if #(p.assignees or {}) > 0 then vim.list_extend(lines, { "Assignees: @" .. table.concat(p.assignees, ", @"), "" }) end
  if p.updated and p.updated ~= "" then vim.list_extend(lines, { "Updated: " .. p.updated, "" }) end
  vim.list_extend(lines, { "## Description", "", p.body and p.body ~= "" and p.body or "_No description._" })
  return lines
end

M._preview_lines = preview_lines

---Always-visible, actionable quickfix picker. Filter rows mutate and rebuild the
---same list; result rows open reviews.
function M.open_quickfix(cwd, on_choose)
  local filters = { state = "open", source = "both", search = "" }
  local preview_buf, preview_win
  local function update_preview()
    if not preview_buf or not vim.api.nvim_buf_is_valid(preview_buf) then return end
    local info = vim.fn.getqflist({ idx = 0, items = 0 })
    local entry = info.items[info.idx]
    local data = entry and entry.user_data or {}
    vim.bo[preview_buf].modifiable = true
    vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, preview_lines(data, filters))
    vim.bo[preview_buf].modifiable = false
  end
  local render
  render = function()
    local opts = {
      state = filters.state,
      search = filters.search,
      branches_only = filters.source == "branches",
      prs_only = filters.source == "prs",
    }
    local results = M.gather_items(cwd, opts)
    local qf = {}
    for _, row in ipairs(filter_rows(filters)) do
      qf[#qf + 1] = {
        filename = cwd, lnum = 1, text = "[filter] " .. row.label,
        user_data = { review_filter = row },
      }
    end
    for _, item in ipairs(results) do
      qf[#qf + 1] = {
        filename = cwd, lnum = 1, text = item.label,
        user_data = { review_source = item },
      }
    end
    vim.fn.setqflist({}, "r", {
      title = string.format("Review · %s · %s", filters.state, filters.source), items = qf,
    })
    vim.cmd("botright copen")
    local buf = vim.api.nvim_get_current_buf()
    local qfwin = vim.api.nvim_get_current_win()
    if not preview_win or not vim.api.nvim_win_is_valid(preview_win) then
      preview_buf = vim.api.nvim_create_buf(false, true)
      vim.bo[preview_buf].buftype, vim.bo[preview_buf].bufhidden = "nofile", "wipe"
      vim.bo[preview_buf].filetype = "markdown"
      preview_win = vim.api.nvim_open_win(preview_buf, false, {
        split = "above", win = qfwin, height = math.max(8, math.floor(vim.o.lines * 0.32)),
      })
      vim.wo[preview_win].wrap, vim.wo[preview_win].linebreak = true, true
      vim.wo[preview_win].winfixheight = true
      pcall(vim.treesitter.start, preview_buf, "markdown")
      vim.api.nvim_create_autocmd("CursorMoved", {
        buffer = buf,
        callback = update_preview,
        desc = "Update review source preview",
      })
    end
    update_preview()
    vim.keymap.set("n", "<CR>", function()
      local info = vim.fn.getqflist({ idx = 0, items = 0 })
      local entry = info.items[info.idx]
      local data = entry and entry.user_data or {}
      if data.review_source then
        vim.cmd("cclose")
        on_choose(data.review_source)
      elseif data.review_filter then
        local row = data.review_filter
        if row.action == "state" then filters.state = row.value
        elseif row.action == "source" then filters.source = row.value
        elseif row.action == "clear" then filters.search = ""
        elseif row.action == "search" then
          vim.ui.input({ prompt = "Review search: ", default = filters.search }, function(value)
            if value ~= nil then filters.search = vim.trim(value); render() end
          end)
          return
        end
        render()
      end
    end, { buffer = buf, nowait = true, desc = "apply review filter or open review" })
    vim.keymap.set("n", "r", render, { buffer = buf, nowait = true, desc = "refresh review list" })
  end
  render()
end

--- Present items via the configured picker; call on_choose(item).
---@param items table[]
---@param on_choose fun(item:table)
local function present(items, cwd, on_choose)
  local pref = config.get().picker
  local function try_snacks()
    local ok, snacks = util.has("snacks")
    if not ok or not snacks.picker then
      return false
    end
    snacks.picker.pick({
      title = "review: pick PR / branch",
      items = vim.tbl_map(function(it)
        return { text = it.label, item = it }
      end, items),
      format = "text",
      actions = {
        review_qflist = function(picker)
          local selected = picker:selected()
          local rows = #selected > 0 and selected or picker:items()
          local sources = vim.tbl_map(function(row) return row.item end, rows)
          picker:close()
          M.to_quickfix(sources, cwd, on_choose)
        end,
      },
      win = {
        input = { keys = { ["<C-q>"] = { "review_qflist", mode = { "i", "n" } } } },
        list = { keys = { ["<C-q>"] = "review_qflist" } },
      },
      confirm = function(picker, choice)
        picker:close()
        if choice and choice.item then
          on_choose(choice.item)
        end
      end,
    })
    return true
  end
  local function try_fzf()
    local ok, fzf = util.has("fzf-lua")
    if not ok then
      return false
    end
    local labels = {}
    local by_label = {}
    for _, it in ipairs(items) do
      table.insert(labels, it.label)
      by_label[it.label] = it
    end
    fzf.fzf_exec(labels, {
      prompt = "review> ",
      fzf_opts = { ["--multi"] = true },
      actions = {
        ["default"] = function(selected)
          local it = selected and by_label[selected[1]]
          if it then
            on_choose(it)
          end
        end,
        ["ctrl-q"] = function(selected)
          local chosen = {}
          for _, label in ipairs(selected or {}) do
            if by_label[label] then chosen[#chosen + 1] = by_label[label] end
          end
          M.to_quickfix(chosen, cwd, on_choose)
        end,
      },
    })
    return true
  end

  if pref == "snacks" and try_snacks() then
    return
  end
  if pref == "fzf" and try_fzf() then
    return
  end
  if pref == "auto" then
    if try_snacks() then
      return
    end
    if try_fzf() then
      return
    end
  end
  -- Builtin fallback.
  vim.ui.select(items, {
    prompt = "review: pick PR / branch",
    format_item = function(it)
      return it.label
    end,
  }, function(it)
    if it then
      on_choose(it)
    end
  end)
end

--- Open the picker.
---@param cwd string
---@param opts table|nil
---@param on_choose fun(item:table)
function M.open(cwd, opts, on_choose)
  cwd = cwd or vim.fn.getcwd()
  if not opts or opts.quickfix ~= false then
    M.open_quickfix(cwd, on_choose)
    return
  end
  local items = M.gather_items(cwd, opts or {})
  if #items == 0 then
    util.notify("no PRs or branches found", vim.log.levels.WARN)
    return
  end
  present(items, cwd, on_choose)
end

return M
