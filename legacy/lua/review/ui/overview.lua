-- review.nvim :: the Overview buffer.
--
-- Renders source metadata, a foldable commit list (subjects <=50 chars, <Tab>
-- unfolds full body), and (for PRs) GitHub review threads. Lines carry actions
-- dispatched by <CR>. Commit rows open that commit's diff in a new tab.

local util = require("review.util")
local config = require("review.config")

local M = {}

M.ns = vim.api.nvim_create_namespace("review_overview")

---@class OverviewState
---@field source table
---@field buf integer
---@field sort_desc boolean         -- true = recent->old
---@field unfolded table<string,boolean>  -- commit sha -> body shown
---@field line_actions table<integer, table>
---@field on_open_commit fun(sha:string)

--- Build render lines + per-line actions for the current state.
---@param st OverviewState
---@return string[] lines, table<integer,table> actions, table[] highlights
local function build(st)
  local src = st.source
  local caps = src:caps()
  local lines, actions, hls = {}, {}, {}
  local function push(text, action, hl)
    table.insert(lines, text)
    local idx = #lines
    if action then
      actions[idx] = action
    end
    if hl then
      table.insert(hls, { line = idx - 1, hl = hl })
    end
    return idx
  end

  push(src:title(), nil, "Title")
  local meta = string.format(
    "author @%s   updated %s%s",
    src:author(),
    util.relative_time(src:updated_at()),
    caps.can_submit and ("   decision: " .. (src.review_decision and src:review_decision() or "none")) or ""
  )
  push(meta, nil, "Comment")
  if caps.has_reviewers then
    local revs = src:reviewers()
    if #revs > 0 then
      push("reviewers: " .. table.concat(revs, ", "), nil, "Comment")
    end
  end
  if caps.has_checks then
    local checks = src:checks()
    if #checks > 0 then
      local ok = 0
      for _, c in ipairs(checks) do
        if c.state == "SUCCESS" or c.state == "success" then
          ok = ok + 1
        end
      end
      push(string.format("checks: %d/%d passing", ok, #checks), nil, "Comment")
    end
  end
  push("")

  -- Description.
  push("── Description " .. string.rep("─", 40), nil, "NonText")
  local desc = src:description()
  if desc == "" then
    push("(no description)", nil, "Comment")
  else
    for _, l in ipairs(vim.split(desc, "\n", { plain = true })) do
      push(l)
    end
  end
  push("")

  -- Commits.
  local commits = vim.deepcopy(src:commits())
  if not st.sort_desc then
    -- reverse to old->recent
    local rev = {}
    for i = #commits, 1, -1 do
      table.insert(rev, commits[i])
    end
    commits = rev
  end
  push(
    string.format("── Commits (%s)  [%s sort] [%s unfold] ", st.sort_desc and "recent→old" or "old→recent",
      config.get().keymaps.sort_commits, config.get().keymaps.unfold_commit),
    nil,
    "NonText"
  )
  for _, c in ipairs(commits) do
    local fold = st.unfolded[c.sha] and "▾" or "▸"
    push(
      string.format("  %s %s  %s", fold, c.short, util.truncate(c.subject, 50)),
      { type = "commit", sha = c.sha },
      "Identifier"
    )
    if st.unfolded[c.sha] and c.body ~= "" then
      for _, bl in ipairs(vim.split(c.body, "\n", { plain = true })) do
        push("        " .. bl, { type = "commit", sha = c.sha }, "Comment")
      end
    end
  end
  push("")

  -- GitHub review threads.
  if caps.has_threads then
    local threads = src:threads()
    push(string.format("── Review threads (%d) ", #threads) .. string.rep("─", 30), nil, "NonText")
    for _, t in ipairs(threads) do
      local first = (t.comments and t.comments.nodes and t.comments.nodes[1]) or {}
      local author = first.author and first.author.login or "?"
      local statusmark = t.isResolved and "✓ resolved" or "○ unresolved"
      push(
        string.format("  @%s  %s:%s   %s", author, t.path or "?", tostring(t.line or t.originalLine or "?"), statusmark),
        { type = "thread", id = t.id },
        "Title"
      )
      for _, cm in ipairs((t.comments and t.comments.nodes) or {}) do
        for _, bl in ipairs(vim.split(cm.body or "", "\n", { plain = true })) do
          push("      │ " .. bl, nil, "Comment")
        end
      end
      push("")
    end
  end

  return lines, actions, hls
end

--- Re-render into the buffer.
---@param st OverviewState
function M.render(st)
  local lines, actions, hls = build(st)
  st.line_actions = actions
  vim.bo[st.buf].modifiable = true
  vim.api.nvim_buf_set_lines(st.buf, 0, -1, false, lines)
  vim.bo[st.buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(st.buf, M.ns, 0, -1)
  for _, h in ipairs(hls) do
    pcall(vim.api.nvim_buf_set_extmark, st.buf, M.ns, h.line, 0, {
      end_row = h.line,
      hl_eol = false,
      line_hl_group = nil,
      hl_group = h.hl,
      end_col = #(lines[h.line + 1] or ""),
    })
  end
end

--- Open the overview buffer for a source. Returns the state table.
---@param source table
---@param on_open_commit fun(sha:string)
---@return OverviewState
function M.open(source, on_open_commit)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].filetype = "review-overview"
  vim.api.nvim_buf_set_name(buf, "review://overview/" .. util.hash(source:key()))

  local st = {
    source = source,
    buf = buf,
    sort_desc = true,
    unfolded = {},
    line_actions = {},
    on_open_commit = on_open_commit,
  }

  local km = config.get().keymaps
  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = buf, desc = desc, nowait = true })
  end

  map("<CR>", function()
    local a = st.line_actions[vim.api.nvim_win_get_cursor(0)[1]]
    if a and a.type == "commit" then
      st.on_open_commit(a.sha)
    end
  end, "open commit diff")

  map(km.unfold_commit, function()
    local a = st.line_actions[vim.api.nvim_win_get_cursor(0)[1]]
    if a and a.type == "commit" then
      st.unfolded[a.sha] = not st.unfolded[a.sha]
      M.render(st)
    end
  end, "unfold commit message")

  map(km.sort_commits, function()
    st.sort_desc = not st.sort_desc
    M.render(st)
  end, "toggle commit sort")

  M.render(st)
  return st
end

return M
