-- review.nvim :: Claude sessions list + detail view.

local util = require("review.util")
local runner = require("review.claude.runner")

local M = {}

--- Icon for a session state.
---@param s table
---@return string
local function icon(s)
  if s.state == "running" then
    return "●"
  elseif s.state == "cancelled" or s.state == "timed_out" then
    return "■"
  elseif s.state == "error" then
    return "✗"
  elseif s.verdict == "request_changes" then
    return "⚠"
  else
    return "✓"
  end
end

--- Render a sessions list buffer for a store. <CR> opens detail.
---@param store table
function M.list(store)
  local sessions = {}
  for _, s in pairs(store.sessions or {}) do
    table.insert(sessions, s)
  end
  table.sort(sessions, function(a, b)
    return (a.started_at or "") > (b.started_at or "")
  end)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].filetype = "review-sessions"
  util.name_buffer(buf, "review://sessions/" .. util.hash(store.source_key))

  local lines, map = { "Claude reviews", string.rep("─", 40) }, {}
  if #sessions == 0 then
    table.insert(lines, "(no reviews yet)")
  end
  for _, s in ipairs(sessions) do
    local line = string.format(
      "%s %s  %s  %s",
      icon(s),
      s.state,
      s.verdict or "",
      s.state == "running" and (s.progress or "working") or util.relative_time(s.ended_at or s.started_at)
    )
    table.insert(lines, line)
    map[#lines] = s
  end
  table.insert(lines, "")
  table.insert(lines, "<CR> open  x cancel  R retry  q close")

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  vim.cmd("tabnew")
  vim.api.nvim_win_set_buf(0, buf)

  local function map_key(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true })
  end
  map_key("<CR>", function()
    local s = map[vim.api.nvim_win_get_cursor(0)[1]]
    if s then
      M.detail(s, store)
    end
  end)
  map_key("x", function()
    local s = map[vim.api.nvim_win_get_cursor(0)[1]]
    if s and s.state == "running" then
      local killed = runner.kill(s.id) or require("review.sidekick").cancel(s.id)
      if killed then util.notify("cancelled session " .. s.id:sub(1, 8)) end
    end
  end)
  map_key("R", function()
    local s = map[vim.api.nvim_win_get_cursor(0)[1]]
    if s and s.state ~= "running" then
      local retried, err
      if s.backend == "sidekick" and s.retry_prompt then
        retried, err = require("review.sidekick").run(store.source, store, s.retry_prompt, {
          allow_edits = s.allow_edits, auto_resolve = s.auto_resolve })
      else
        retried, err = runner.retry(s, store)
      end
      if retried then util.notify("retry started as " .. retried.id:sub(1, 8))
      else util.notify("retry failed: " .. tostring(err), vim.log.levels.ERROR) end
    end
  end)
  map_key("q", function()
    vim.cmd("tabclose")
  end)
end

--- Open a detail tab for one session.
---@param s table
function M.detail(s, store)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].filetype = "markdown"
  util.name_buffer(buf, "review://session/" .. s.id:sub(1, 8))

  local lines = {
    "# Claude review " .. s.id:sub(1, 8),
    "",
    "- state: " .. s.state,
    "- verdict: " .. tostring(s.verdict),
    "- instruction: " .. tostring(s.instruction),
    "- allow_edits: " .. tostring(s.allow_edits) .. "   auto_resolve: " .. tostring(s.auto_resolve),
    "- started: " .. tostring(s.started_at) .. "   ended: " .. tostring(s.ended_at),
    "",
    "## Summary",
    tostring(s.summary or "(none)"),
    "",
    "## Replies posted (" .. #(s.replied or {}) .. ")",
  }
  for _, id in ipairs(s.replied or {}) do
    table.insert(lines, "- replied to " .. id)
  end
  table.insert(lines, "")
  table.insert(lines, "## Findings / new comments")
  for _, f in ipairs(s.findings or {}) do
    if f.general then
      table.insert(lines, "- " .. tostring(f.note))
    else
      table.insert(lines, string.format("- %s:%s (comment %s)", f.file, tostring(f.line), (f.comment_id or ""):sub(1, 8)))
    end
  end
  if s.commits and #s.commits > 0 then
    table.insert(lines, "")
    table.insert(lines, "## Commits by Claude")
    for _, c in ipairs(s.commits) do
      table.insert(lines, string.format("- %s %s", (c.sha or ""):sub(1, 8), c.subject or ""))
    end
  end
  if s.cwd and vim.fn.isdirectory(s.cwd) == 1 then
    local ok, out = require("review.util.proc").git({ "log", "--oneline", "--max-count=5",
      store.source:head_rev() .. "..HEAD" }, s.cwd)
    if ok and vim.trim(out) ~= "" then
      table.insert(lines, "")
      table.insert(lines, "## Pending implementation commits")
      for _, line in ipairs(vim.split(vim.trim(out), "\n", { plain = true })) do table.insert(lines, "- " .. line) end
    end
  end
  if s.error then
    table.insert(lines, "")
    table.insert(lines, "## Error")
    table.insert(lines, s.error)
  end
  if s.log and #s.log > 0 then
    table.insert(lines, "")
    table.insert(lines, "## Progress log")
    for _, l in ipairs(s.log) do
      for _, sub in ipairs(vim.split(l, "\n", { plain = true })) do
        table.insert(lines, "  " .. sub)
      end
    end
  end
  table.insert(lines, "")
  table.insert(lines, "---")
  table.insert(lines, "R retry · v view implementation diff · o open worktree · p push with confirmation · q close")

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  vim.cmd("tabnew")
  vim.api.nvim_win_set_buf(0, buf)
  -- If the session made edits, root the tab in its worktree (R4).
  if s.cwd and vim.fn.isdirectory(s.cwd) == 1 then
    pcall(vim.cmd, "tcd " .. vim.fn.fnameescape(s.cwd))
  end
  vim.keymap.set("n", "q", function()
    vim.cmd("tabclose")
  end, { buffer = buf, nowait = true })
  vim.keymap.set("n", "R", function()
    if s.state == "running" then return end
    local retried, err = runner.retry(s, store)
    if retried then util.notify("retry started as " .. retried.id:sub(1, 8))
    else util.notify("retry failed: " .. tostring(err), vim.log.levels.ERROR) end
  end, { buffer = buf, desc = "retry Claude review" })
  vim.keymap.set("n", "v", function()
    if not s.cwd then return end
    local old = vim.fn.getcwd()
    vim.cmd("lcd " .. vim.fn.fnameescape(s.cwd))
    require("diffview").open(store.source:head_rev() .. "...HEAD")
    vim.cmd("lcd " .. vim.fn.fnameescape(old))
  end, { buffer = buf, desc = "view implementation diff" })
  vim.keymap.set("n", "o", function()
    if not s.cwd then return end
    vim.cmd("tabnew"); vim.cmd("tcd " .. vim.fn.fnameescape(s.cwd)); vim.cmd("edit .")
  end, { buffer = buf, desc = "open implementation worktree" })
  vim.keymap.set("n", "p", function()
    if store.source:kind() ~= "pr" or not s.cwd then
      util.notify("push is available only for PR edit sessions", vim.log.levels.WARN); return
    end
    if vim.fn.confirm("Push implementation commits to the PR branch?", "&Push\n&Cancel", 2) ~= 1 then return end
    local meta = store.source:metadata()
    local ok, err = require("review.util.git").push_head(meta.head_url, meta.head_ref, s.cwd)
    if ok then util.notify("implementation pushed to " .. meta.head_ref); require("review").refresh()
    else util.notify("push failed: " .. tostring(err), vim.log.levels.ERROR) end
  end, { buffer = buf, desc = "push implementation commit" })
end

return M
