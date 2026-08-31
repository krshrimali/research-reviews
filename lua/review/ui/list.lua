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
    raw = pr,
  }
end

-- A review source is durable navigation, not a transient completion operation.
-- This browser is an ordinary nofile buffer, so changing tabs, using normal-mode
-- motions, or leaving it open behind a Diffview never invalidates its callbacks.
local browser_states = { "open", "closed", "merged", "all" }
local browser_sources = { "both", "prs", "branches" }

--- Drop rows that do not belong in the requested state.
---
--- `gh pr list --state closed` includes merged PRs, so a CLOSED tab sitting next to
--- a MERGED tab listed the same rows twice and neither label meant anything.
---@param prs table[]
---@param state string
---@return table[]
local function filter_state(prs, state)
  if state ~= "closed" then return prs end
  return vim.tbl_filter(function(pr)
    return tostring(pr.state or ""):upper() ~= "MERGED"
  end, prs)
end

local function cycle(values, current)
  for i, value in ipairs(values) do
    if value == current then return values[(i % #values) + 1] end
  end
  return values[1]
end

local function browser_lines(model)
  local active = {}
  for _, value in ipairs(browser_states) do
    active[#active + 1] = value == model.state and ("[" .. value:upper() .. "]") or value
  end
  local lines = {
    "Review browser",
    model.static and ("[" .. model.source:upper() .. "]") or table.concat(active, "  "),
    string.format("Sources: %s%s", model.source, model.query ~= "" and ("  ·  Search: " .. model.query) or ""),
    model.static and "/ search · Q quickfix · <CR> open · q close"
      or "Tab state · S sources · / search · r refresh · Q quickfix · <CR> open · q close",
    string.rep("─", 72),
  }
  local map = {}
  if model.loading then
    lines[#lines + 1] = (model.spinner or "⠋") .. " Loading pull requests…"
  elseif model.error then
    lines[#lines + 1] = "Error: " .. model.error
    lines[#lines + 1] = "Press r to retry. Local sources remain available below."
  end
  local query = model.query:lower()
  for _, item in ipairs(model.items) do
    if query == "" or (item.search or item.label):lower():find(query, 1, true) then
      -- Full label, no truncation: the window wraps, so a long PR title spills onto
      -- a second screen row instead of being cut off. One buffer line per item still,
      -- so `map` and cursor movement are unaffected.
      lines[#lines + 1] = item.label
      map[#lines] = item
    end
  end
  if not model.loading and vim.tbl_isempty(map) then lines[#lines + 1] = "(no matching review sources)" end
  return lines, map
end

M._browser_lines = browser_lines
M._filter_state = filter_state

local function open_browser(cwd, opts, on_choose)
  opts = opts or {}
  local model = {
    -- A new browser is predictable: it always starts with active PRs. State
    -- changes made with Tab belong to this browser instance only.
    cwd = cwd, state = opts.state or "open",
    source = opts.source_name or (opts.prs_only and "prs" or opts.branches_only and "branches" or "both"),
    query = "", items = {}, map = {}, generation = 0, static = opts.items ~= nil,
  }
  vim.cmd("tabnew")
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(0, buf)
  vim.bo[buf].buftype, vim.bo[buf].bufhidden, vim.bo[buf].swapfile = "nofile", "wipe", false
  vim.bo[buf].filetype = "review-sources"
  util.wrap_window()
  vim.wo.cursorline = true
  util.name_buffer(buf, "review://sources/" .. util.hash(cwd) .. "/" .. model.source)

  local timer
  local function render()
    if not vim.api.nvim_buf_is_valid(buf) then return end
    local cursor = vim.api.nvim_win_get_cursor(0)
    local wins = vim.fn.win_findbuf(buf)
    if wins[1] and vim.api.nvim_win_is_valid(wins[1]) then
      local info = vim.fn.getwininfo(wins[1])[1] or {}
      model.width = vim.api.nvim_win_get_width(wins[1]) - (info.textoff or 0)
    end
    local lines, map = browser_lines(model)
    model.map = map
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    -- Land on the first RESULT row, never the title: <CR> on the header was a
    -- silent no-op, and a search left the cursor above its own results.
    local first_row = #lines
    for lnum in pairs(map) do first_row = math.min(first_row, lnum) end
    if vim.tbl_isempty(map) then first_row = math.min(#lines, 6) end
    if vim.api.nvim_get_current_buf() == buf then
      local want = math.max(first_row, math.min(cursor[1], #lines))
      if not map[want] and not vim.tbl_isempty(map) then want = first_row end
      pcall(vim.api.nvim_win_set_cursor, 0, { want, 0 })
    end
  end
  local function stop_spinner()
    if timer then timer:stop(); timer:close(); timer = nil end
  end
  local resize_id = vim.api.nvim_create_autocmd("VimResized", { callback = render })
  vim.api.nvim_create_autocmd("BufWipeout", { buffer = buf, once = true, callback = function()
    stop_spinner()
    pcall(vim.api.nvim_del_autocmd, resize_id)
  end })

  local function load(force)
    local started = vim.uv.hrtime()
    model.generation = model.generation + 1
    local generation = model.generation
    model.items, model.error = {}, nil
    if opts.items then
      vim.list_extend(model.items, opts.items)
      model.loading = false; render(); return
    end
    if model.source ~= "prs" then vim.list_extend(model.items, local_branches(cwd)) end
    if model.source == "branches" then model.loading = false; render(); return end
    local cached = not force and cache_get(cwd, { state = model.state, search = "" }) or nil
    if cached then
      for _, pr in ipairs(filter_state(cached, model.state)) do
        model.items[#model.items + 1] = pr_item(pr)
      end
      model.loading = false; render(); return
    end
    model.loading, model.spinner = true, "⠋"
    util.progress(string.format("Loading %s pull requests…", model.state))
    local frames, frame = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }, 1
    stop_spinner()
    timer = vim.uv.new_timer()
    timer:start(0, 90, vim.schedule_wrap(function()
      if not model.loading or not vim.api.nvim_buf_is_valid(buf) then stop_spinner(); return end
      frame = frame % #frames + 1; model.spinner = frames[frame]; render()
    end))
    render()
    local argv = { vim.env.PRTUI_GH_BIN or "gh" }
    vim.list_extend(argv, gh.list_prs_args({ state = model.state, limit = 100 }))
    vim.system(argv, { cwd = cwd, text = true }, function(result)
      vim.schedule(function()
        if generation ~= model.generation or not vim.api.nvim_buf_is_valid(buf) then return end
        model.loading = false; stop_spinner()
        if result.code ~= 0 then
          model.error = vim.trim(result.stderr or "GitHub request failed")
          util.notify("Pull request loading failed: " .. model.error, vim.log.levels.ERROR)
        else
          local ok, prs = pcall(vim.json.decode, result.stdout or "")
          if not ok or not vim.islist(prs) then model.error = "GitHub returned invalid JSON"
          else
            cache_store(cache_key(cwd, { state = model.state, search = "" }), prs)
            local shown = filter_state(prs, model.state)
            for _, pr in ipairs(shown) do model.items[#model.items + 1] = pr_item(pr) end
            util.notify(string.format("Loaded %d %s pull request%s · %.1fs", #shown, model.state,
              #shown == 1 and "" or "s", (vim.uv.hrtime() - started) / 1e9))
          end
        end
        render()
      end)
    end)
  end

  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, desc = desc })
  end
  map("<CR>", function()
    local item = model.map[vim.api.nvim_win_get_cursor(0)[1]]
    if item then on_choose(item) end
  end, "open review")
  map("<Tab>", function()
    if model.static then return end
    model.state = cycle(browser_states, model.state); load(false)
  end, "next PR state")
  map("<S-Tab>", function()
    if model.static then return end
    for _ = 1, #browser_states - 1 do model.state = cycle(browser_states, model.state) end
    load(false)
  end, "previous PR state")
  map("S", function()
    -- :ReviewPRs / :ReviewBranches open a deliberately scoped browser; letting S
    -- wander out of that scope also left the PR state tabs displayed above a list
    -- of local branches, where they mean nothing.
    if model.static or opts.prs_only or opts.branches_only then
      util.notify("this browser is scoped; use :ReviewList for PRs and branches together",
        vim.log.levels.INFO)
      return
    end
    model.source = cycle(browser_sources, model.source); load(false)
  end, "cycle source type")
  map("/", function()
    vim.ui.input({ prompt = "Review search: ", default = model.query }, function(value)
      if value ~= nil then model.query = vim.trim(value); render() end
    end)
  end, "search review sources")
  map("r", function() load(true) end, "refresh review sources")
  map("Q", function() M.to_quickfix(vim.tbl_values(model.map), cwd, on_choose) end, "send results to quickfix")
  map("q", function() vim.cmd("tabclose") end, "close review browser")
  load(false)
end

M.open_browser = open_browser

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
        local ok_decode, decoded = pcall(vim.json.decode, table.concat(chunks))
        if not ok_decode or not vim.islist(decoded) then
          ctx.async:schedule(function()
            util.notify("GitHub PR loading failed; press r to retry", vim.log.levels.ERROR)
          end)
          return
        end
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
  open_browser(cwd, { prs_only = true }, on_choose)
end

function M.open_branches(cwd, on_choose)
  local items = local_branches(cwd)
  if #items == 0 then util.notify("no local branches found", vim.log.levels.WARN); return end
  open_browser(cwd, { branches_only = true, items = items, source_name = "branches" }, on_choose)
end

function M.open_commits(cwd, on_choose)
  local items = commit_items(cwd, config.get().commit_picker_limit)
  if #items == 0 then util.notify("no commits found", vim.log.levels.WARN); return end
  open_browser(cwd, { items = items, branches_only = true, source_name = "commits" }, on_choose)
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
  if true then
    open_browser(cwd, opts, on_choose)
    return
  end
  -- Legacy picker implementation retained below for compatibility with callers that
  -- may still depend on its helpers; the public browser no longer enters this path.
  -- luacheck: ignore 511
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
