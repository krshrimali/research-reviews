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
local pr_cache = {}
local max_cache_entries = 64
local picker_state, save_picker_state
local picker_title

local function cache_key(cwd, opts)
  return table.concat({ cwd, opts.state or "open", opts.search or "", tostring(opts.limit or 100) }, "\0")
end

local function cache_store(key, value)
  pr_cache[key] = { at = os.time(), value = vim.deepcopy(value) }
  local keys = vim.tbl_keys(pr_cache)
  if #keys <= max_cache_entries then return end
  table.sort(keys, function(a, b) return pr_cache[a].at < pr_cache[b].at end)
  for i = 1, #keys - max_cache_entries do pr_cache[keys[i]] = nil end
end

local function cache_get(cwd, opts)
  local hit = pr_cache[cache_key(cwd, opts)]
  local ttl = config.get().picker_cache_ttl or 30
  if not opts.refresh and hit and os.time() - hit.at < ttl then return vim.deepcopy(hit.value) end
end

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

local function commit_items(cwd, limit)
  local items = {}
  for _, commit in ipairs(git.recent_commits(limit or 200, cwd)) do
    items[#items + 1] = {
      kind = "commit",
      arg = { kind = "commit", rev = commit.sha },
      label = string.format("●  %s  %s  @%s", commit.short,
        util.truncate(commit.subject, 64), commit.author or "?"),
      search = table.concat({ commit.sha, commit.short or "", commit.subject or "",
        commit.body or "", commit.author or "" }, " "),
    }
  end
  return items
end

M._commit_items = commit_items

--- PRs as picker items. `search` is passed to gh (fuzzy server-side filter).
---@param cwd string
---@param opts table
---@return table[] items
local function pr_item(pr)
  local labels = {}
  for _, label in ipairs(pr.labels or {}) do labels[#labels + 1] = label.name end
  return {
    kind = "pr",
    arg = pr.number,
    label = string.format("#%-5d %s  @%s  %s%s", pr.number,
      util.truncate(pr.title, 50), pr.author and pr.author.login or "?", pr.state or "",
      pr.reviewDecision and ("  " .. pr.reviewDecision) or ""),
    search = string.format("#%d %s %s %s", pr.number, pr.title,
      pr.author and pr.author.login or "", table.concat(labels, " ")),
  }
end

local function pr_items(cwd, opts)
  if not gh.available() then
    return {}
  end
  local key = cache_key(cwd, opts)
  local prs = cache_get(cwd, opts)
  if not prs then
    prs = gh.list_prs({ search = opts.search, limit = opts.limit or 100, state = opts.state }, cwd)
    cache_store(key, prs)
  end
  local items = {}
  for _, pr in ipairs(prs) do items[#items + 1] = pr_item(pr) end
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

---Always-visible, actionable quickfix picker. Filter rows mutate and rebuild the
---same list; result rows open reviews.
function M.open_quickfix(cwd, on_choose)
  local filters = { state = picker_state(cwd).state or "open", source = "both", search = "" }
  local render
  render = function(force_refresh)
    local opts = {
      state = filters.state,
      search = filters.search,
      refresh = force_refresh == true,
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
    vim.keymap.set("n", "<CR>", function()
      local info = vim.fn.getqflist({ idx = 0, items = 0 })
      local entry = info.items[info.idx]
      local data = entry and entry.user_data or {}
      if data.review_source then
        vim.cmd("cclose")
        on_choose(data.review_source)
      elseif data.review_filter then
        local row = data.review_filter
        if row.action == "state" then
          filters.state = row.value
          save_picker_state(cwd, filters)
        elseif row.action == "source" then filters.source = row.value
        elseif row.action == "clear" then filters.search = ""
        elseif row.action == "refresh" then render(true); return
        elseif row.action == "search" then
          vim.ui.input({ prompt = "Review search: ", default = filters.search }, function(value)
            if value ~= nil then filters.search = vim.trim(value); render() end
          end)
          return
        end
        render()
      end
    end, { buffer = buf, nowait = true, desc = "apply review filter or open review" })
    vim.keymap.set("n", "r", function() render(true) end,
      { buffer = buf, nowait = true, desc = "refresh review list" })
  end
  render()
end

--- Present items via the configured picker; call on_choose(item).
---@param items table[]
---@param on_choose fun(item:table)
local function next_state(state)
  local states = { "open", "closed", "merged", "all" }
  for i, value in ipairs(states) do
    if value == state then return states[(i % #states) + 1] end
  end
  return states[1]
end

M._next_state = next_state

picker_state = function(cwd)
  local state = require("review.state")
  local doc = state.load(cwd, "__picker__")
  return doc.meta.picker or {}
end

save_picker_state = function(cwd, opts)
  local state = require("review.state")
  local doc = state.load(cwd, "__picker__")
  doc.meta.picker = { state = opts.state or "open" }
  state.save(cwd, "__picker__", doc)
end

M._picker_state = picker_state
M._save_picker_state = save_picker_state
M._clear_cache = function() pr_cache = {} end

local function present(items, cwd, on_choose, opts)
  local pref = config.get().picker
  local function try_snacks()
    local ok, snacks = util.has("snacks")
    if not ok or not snacks.picker then
      return false
    end
    snacks.picker.pick({
      title = picker_title(opts),
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
        review_cycle_state = function(picker)
          picker:close()
          local next_opts = vim.tbl_extend("force", opts, { state = next_state(opts.state) })
          save_picker_state(cwd, next_opts)
          M.open(cwd, next_opts, on_choose)
        end,
        review_refresh = function(picker)
          picker:close()
          M.open(cwd, vim.tbl_extend("force", opts, { refresh = true }), on_choose)
        end,
      },
      win = {
        input = { keys = {
          ["<C-q>"] = { "review_qflist", mode = { "i", "n" } },
          ["<Tab>"] = { "review_cycle_state", mode = { "i", "n" } },
        } },
        list = { keys = {
          ["<C-q>"] = "review_qflist",
          ["<Tab>"] = "review_cycle_state",
          ["r"] = "review_refresh",
        } },
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
      prompt = "review (" .. (opts.state or "open") .. ")> ",
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
        ["tab"] = function()
          local next_opts = vim.tbl_extend("force", opts, { state = next_state(opts.state) })
          save_picker_state(cwd, next_opts)
          vim.schedule(function() M.open(cwd, next_opts, on_choose) end)
        end,
        ["ctrl-r"] = function()
          vim.schedule(function()
            M.open(cwd, vim.tbl_extend("force", opts, { refresh = true }), on_choose)
          end)
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

local function present_static(items, cwd, title, on_choose)
  local ok, snacks = util.has("snacks")
  if ok and snacks.picker then
    snacks.picker.pick({
      title = title .. " (Ctrl-Q quickfix)",
      items = vim.tbl_map(function(item) return { text = item.label, item = item } end, items),
      format = "text",
      actions = {
        review_qflist = function(picker)
          local selected = picker:selected()
          local rows = #selected > 0 and selected or picker:items()
          picker:close()
          M.to_quickfix(vim.tbl_map(function(row) return row.item end, rows), cwd, on_choose)
        end,
      },
      win = {
        input = { keys = { ["<C-q>"] = { "review_qflist", mode = { "i", "n" } } } },
        list = { keys = { ["<C-q>"] = "review_qflist" } },
      },
      confirm = function(picker, choice)
        picker:close()
        if choice and choice.item then on_choose(choice.item) end
      end,
    })
    return
  end
  local has_fzf, fzf = util.has("fzf-lua")
  if has_fzf then
    local labels, by_label = {}, {}
    for _, item in ipairs(items) do labels[#labels + 1], by_label[item.label] = item.label, item end
    fzf.fzf_exec(labels, {
      prompt = title .. "> ", fzf_opts = { ["--multi"] = true },
      actions = {
        ["default"] = function(selected)
          local item = selected and by_label[selected[1]]
          if item then on_choose(item) end
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
    return
  end
  vim.ui.select(items, { prompt = title, format_item = function(item) return item.label end }, function(item)
    if item then on_choose(item) end
  end)
end

local function source_label(opts)
  if opts.prs_only then return "pull requests" end
  return "pull requests + local branches"
end

picker_title = function(opts)
  return string.format("review · filter: %s · %s (Tab filter · r refresh · Ctrl-Q quickfix)",
    (opts.state or "open"):upper(), source_label(opts))
end

M._picker_title = picker_title

local function present_snacks_loading(cwd, opts, on_choose, snacks)
  local key = cache_key(cwd, opts)
  local gh_bin = vim.env.PRTUI_GH_BIN or "gh"
  local branches = opts.prs_only and {} or local_branches(cwd)
  snacks.picker.pick({
    title = picker_title(opts),
    finder = function(_, ctx)
      return function(cb)
        for _, item in ipairs(branches) do cb({ text = item.label, item = item }) end
        local collected = {}
        local chunks = {}
        require("snacks.picker.source.proc").proc({
          cmd = gh_bin,
          args = gh.list_prs_args(opts), cwd = cwd, raw = true,
        }, ctx)(function(row) chunks[#chunks + 1] = row.text end)
        local decoded = vim.json.decode(table.concat(chunks))
        assert(vim.islist(decoded), "gh pr list did not return a JSON array")
        local rendered = ctx.async:schedule(function()
          for _, pr in ipairs(decoded) do collected[#collected + 1] = pr end
          cache_store(key, collected)
          return vim.tbl_map(pr_item, decoded)
        end)
        for _, item in ipairs(rendered) do cb({ text = item.label, item = item }) end
      end
    end,
    format = "text",
    actions = {
      review_qflist = function(picker)
        local selected = picker:selected()
        local rows = #selected > 0 and selected or picker:items()
        picker:close()
        M.to_quickfix(vim.tbl_map(function(row) return row.item end, rows), cwd, on_choose)
      end,
      review_cycle_state = function(picker)
        picker:close()
        local next_opts = vim.tbl_extend("force", opts, { state = next_state(opts.state), refresh = nil })
        save_picker_state(cwd, next_opts)
        M.open(cwd, next_opts, on_choose)
      end,
      review_refresh = function(picker)
        picker:close()
        M.open(cwd, vim.tbl_extend("force", opts, { refresh = true }), on_choose)
      end,
    },
    win = {
      input = { keys = {
        ["<C-q>"] = { "review_qflist", mode = { "i", "n" } },
        ["<Tab>"] = { "review_cycle_state", mode = { "i", "n" } },
      } },
      list = { keys = {
        ["<C-q>"] = "review_qflist", ["<Tab>"] = "review_cycle_state", ["r"] = "review_refresh",
      } },
    },
    confirm = function(picker, choice)
      picker:close()
      if choice and choice.item then on_choose(choice.item) end
    end,
  })
end

function M.open_prs(cwd, on_choose)
  M.open(cwd, { prs_only = true }, on_choose)
end

function M.open_branches(cwd, on_choose)
  local items = local_branches(cwd)
  if #items == 0 then util.notify("no local branches found", vim.log.levels.WARN); return end
  present_static(items, cwd, "review: pick local branch", on_choose)
end

function M.open_commits(cwd, on_choose)
  local items = commit_items(cwd, config.get().commit_picker_limit)
  if #items == 0 then util.notify("no commits found", vim.log.levels.WARN); return end
  present_static(items, cwd, "review: pick commit", on_choose)
end

--- Open the picker.
---@param cwd string
---@param opts table|nil
---@param on_choose fun(item:table)
function M.open(cwd, opts, on_choose)
  cwd = cwd or vim.fn.getcwd()
  opts = opts or {}
  if opts.quickfix then
    M.open_quickfix(cwd, on_choose)
    return
  end
  if not opts.state then opts.state = picker_state(cwd).state or "open" end
  save_picker_state(cwd, opts)
  local has_snacks, snacks = util.has("snacks")
  local wants_prs = not opts.branches_only
  local cached = wants_prs and cache_get(cwd, opts) or nil
  if has_snacks and snacks.picker and wants_prs and not cached
      and vim.fn.executable(vim.env.PRTUI_GH_BIN or "gh") == 1 then
    opts.refresh = nil
    present_snacks_loading(cwd, opts, on_choose, snacks)
    return
  end
  local items = M.gather_items(cwd, opts)
  if #items == 0 then
    util.notify("no PRs or branches found", vim.log.levels.WARN)
    return
  end
  opts.refresh = nil -- refresh is a one-shot cache bypass, never sticky picker state
  present(items, cwd, on_choose, opts)
end

return M
