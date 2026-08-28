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
  vim.list_extend(items, local_branches(cwd))
  return items
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
  local items = M.gather_items(cwd, opts or {})
  if #items == 0 then
    util.notify("no PRs or branches found", vim.log.levels.WARN)
    return
  end
  present(items, cwd, on_choose)
end

return M
