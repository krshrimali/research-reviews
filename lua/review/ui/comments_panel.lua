-- review.nvim :: opt-in comments side-panel (right split).
--
-- Lists comment threads for the current file (first chars shown). <CR> jumps to the
-- thread's anchor in the diff and expands it inline.
--
-- Panel state is per TABPAGE. A review lives in its own tab, so a module-global
-- panel meant a second review silently reused (and then closed) the first review's
-- window in a different tab.

local util = require("review.util")

local M = {}

M.ns = vim.api.nvim_create_namespace("review_panel")

---@class Panel
---@field buf integer
---@field win integer
---@field tab integer
---@field store table
---@field file string|nil   -- nil => whole review; set => this file only
---@field side string
---@field scope string      -- "review" | "file"
---@field line_map table<integer, table>  -- line -> root comment
---@field on_jump fun(root:table)

---@type table<integer, Panel>
local states = {}

--- The panel belonging to a tabpage (default: the current one), if it is still alive.
---@param tab integer|nil
---@return Panel|nil
local function get_state(tab)
  tab = tab or vim.api.nvim_get_current_tabpage()
  local st = states[tab]
  if not st then
    return nil
  end
  if not vim.api.nvim_win_is_valid(st.win) or not vim.api.nvim_buf_is_valid(st.buf) then
    states[tab] = nil
    return nil
  end
  return st
end

M._get_state = get_state
M._states = states

--- Build lines for the panel.
---@param store table
---@param file string
---@return string[], table<integer,table>
local filters = { "unresolved", "all", "claude", "draft", "outdated", "resolved" }

local function matches(root, filter, query)
  if filter == "unresolved" and root.status == "resolved" then return false end
  if filter == "claude" and root.origin ~= "claude" then return false end
  if filter == "draft" and (root.status ~= "draft" or root.github_id) then return false end
  if filter == "outdated" and root.status ~= "outdated" then return false end
  if filter == "resolved" and root.status ~= "resolved" then return false end
  if query and query ~= "" then
    local haystack = table.concat({ root.file or "", root.author or "", root.body or "", root.origin or "" }, " "):lower()
    if not haystack:find(query:lower(), 1, true) then return false end
  end
  return true
end

local function add_body(lines, map, root, prefix, body)
  local body_lines = vim.split(util.normalize_markdown(body), "\n", { plain = true })
  for i = 2, math.min(#body_lines, 6) do
    table.insert(lines, prefix .. body_lines[i]); map[#lines] = root
  end
  if #body_lines > 6 then
    table.insert(lines, string.format("%s… %d more lines", prefix, #body_lines - 6)); map[#lines] = root
  end
end

--- Group threads by file, ordered by path. The panel is ~40 columns wide, so a
--- nested directory tree spent most of its lines on chrome; one collapsed path row
--- per file conveys the same structure in a single line.
---@param threads table[]
---@return table[] groups  { path=string, roots=table[] }
local function group_by_file(threads)
  local order, by_path = {}, {}
  for _, root in ipairs(threads) do
    local path = root.file or "(unknown)"
    if not by_path[path] then
      by_path[path] = {}
      order[#order + 1] = path
    end
    table.insert(by_path[path], root)
  end
  table.sort(order)
  local groups = {}
  for _, path in ipairs(order) do
    groups[#groups + 1] = { path = path, roots = by_path[path] }
  end
  return groups
end

M._group_by_file = group_by_file

local function render_groups(groups, lines, map, store, selected)
  for _, group in ipairs(groups) do
    table.insert(lines, "▾ " .. group.path)
    for _, root in ipairs(group.roots) do
      local count = 1 + #store:replies(root.id)
      local icon = root.status == "resolved" and "✓"
        or (root.status == "outdated" and "⚠")
        or (root.origin == "claude" and "★" or "●")
      local checked = selected[root.id] and "[x]" or "[ ]"
      local reaction_count = 0
      for _, n in pairs(root.reactions or {}) do reaction_count = reaction_count + n end
      local body = vim.split(util.normalize_markdown(root.body), "\n", { plain = true })
      local suffix = count > 1 and string.format(" · %d messages", count) or ""
      if reaction_count > 0 then suffix = suffix .. " · ♥" .. reaction_count end
      if root.status == "outdated" then suffix = suffix .. " · OUTDATED" end
      if root.kind == "suggestion" then suffix = suffix .. " · SUGGESTION" end
      local prefix = "  "
      table.insert(lines, string.format("%s%s %s L%d @%s: %s%s", prefix, checked, icon,
        root.line_start or 0, root.author or "unknown", body[1] or "", suffix))
      map[#lines] = root
      add_body(lines, map, root, prefix .. "    ", root.body)
      if reaction_count > 0 then
        local chips = {}
        for name, n in pairs(root.reactions or {}) do chips[#chips + 1] = string.format("%s %d", name:lower(), n) end
        table.sort(chips)
        table.insert(lines, prefix .. "    [" .. table.concat(chips, "] [") .. "]"); map[#lines] = root
      end
      for _, reply in ipairs(store:replies(root.id)) do
        local reply_body = vim.split(util.normalize_markdown(reply.body), "\n", { plain = true })
        table.insert(lines, string.format("%s    ↳ @%s: %s", prefix, reply.author or "unknown", reply_body[1] or ""))
        map[#lines] = root
        add_body(lines, map, root, prefix .. "      ", reply.body)
      end
    end
  end
end

--- PR-level comments and review summaries — everything that is NOT anchored to a
--- diff line. These were only visible in the workspace, so a conversation happening
--- on the pull request itself was invisible from the surface you actually work in.
---@param store table
---@param query string
---@return table[]
local function conversation_items(store, query)
  local source = store.source
  if not source or type(source.conversation) ~= "function" then
    return {}
  end
  local ok, items = pcall(source.conversation, source)
  if not ok or type(items) ~= "table" then
    return {}
  end
  if query and query ~= "" then
    items = vim.tbl_filter(function(item)
      local haystack = ((item.author or "") .. " " .. (item.body or "")):lower()
      return haystack:find(query:lower(), 1, true) ~= nil
    end, items)
  end
  return items
end

M._conversation_items = conversation_items

--- Render the non-inline conversation.
local function render_conversation(items, lines, map)
  if #items == 0 then
    return
  end
  lines[#lines + 1] = ("▾ conversation (%d) · not on a line"):format(#items)
  for _, item in ipairs(items) do
    local kind = item.kind == "review" and (item.state or "review") or "comment"
    lines[#lines + 1] = ("  ◆ @%s · %s"):format(item.author or "unknown", kind:lower())
    map[#lines] = { conversation = item }
    local body = vim.split(util.normalize_markdown(item.body), "\n", { plain = true })
    for index = 1, math.min(#body, 4) do
      if vim.trim(body[index]) ~= "" then
        lines[#lines + 1] = "      " .. body[index]
        map[#lines] = { conversation = item }
      end
    end
    if #body > 4 then
      lines[#lines + 1] = ("      … %d more lines"):format(#body - 4)
      map[#lines] = { conversation = item }
    end
  end
  lines[#lines + 1] = ""
end

--- Running-agent status, so the panel where findings will land also says one is coming.
---@param store table
---@return string|nil
local function agent_status(store)
  for _, session in pairs(store.sessions or {}) do
    if session.state == "running" then
      return string.format("★ agent %s · %s", (session.id or ""):sub(1, 8),
        util.truncate(session.progress or "working", 30))
    end
  end
  return nil
end

M._agent_status = agent_status

local function build(store, file, filter, query, selected)
  local lines, map = {}, {}
  local all = file and store:threads_for_file(file) or store:all_threads()
  local open, drafts = 0, 0
  for _, root in ipairs(all) do
    if root.status ~= "resolved" then open = open + 1 end
    if root.status == "draft" and not root.github_id then drafts = drafts + 1 end
  end
  table.insert(lines, string.format("Threads · %d open · %d local draft%s", open, drafts,
    drafts == 1 and "" or "s"))
  table.insert(lines, string.format("scope: %s · filter: %s%s", file and "this file" or "review",
    filter, query ~= "" and (" · /" .. query) or ""))
  local agent = agent_status(store)
  if agent then table.insert(lines, agent) end
  table.insert(lines, string.rep("─", 38))
  local threads = {}
  for _, root in ipairs(all) do if matches(root, filter, query) then threads[#threads + 1] = root end end
  table.sort(threads, function(a, b)
    if a.file ~= b.file then return (a.file or "") < (b.file or "") end
    return (a.line_start or 0) < (b.line_start or 0)
  end)
  if #threads == 0 then
    table.insert(lines, "(no matching threads)")
  end
  render_groups(group_by_file(threads), lines, map, store, selected)
  -- Conversation last: inline threads are the working set, this is context.
  if not file then
    lines[#lines + 1] = ""
    render_conversation(conversation_items(store, query), lines, map)
  end
  local general = {}
  for _, session in pairs(store.sessions or {}) do
    for _, finding in ipairs(session.findings or {}) do
      if finding.general then general[#general + 1] = finding.note end
    end
  end
  if #general > 0 then
    table.insert(lines, ""); table.insert(lines, "General Claude findings")
    for _, note in ipairs(general) do table.insert(lines, "  ★ " .. note) end
  end
  table.insert(lines, "")
  table.insert(lines, "<CR> open · Space select · a ask Claude · p publish · I import")
  table.insert(lines, "f filter · s scope · / search · Q quickfix · R reply · r resolve")
  table.insert(lines, "A apply suggestion · e edit · d delete · y copy · z react · q close")
  return lines, map
end

M._build = build

--- Render one panel's content from its own state.
---@param st Panel
local function render_state(st)
  if not vim.api.nvim_buf_is_valid(st.buf) then
    return
  end
  local lines, map = build(st.store, st.file, st.filter, st.query, st.selected)
  st.line_map = map
  vim.bo[st.buf].modifiable = true
  vim.api.nvim_buf_set_lines(st.buf, 0, -1, false, lines)
  vim.bo[st.buf].modifiable = false
end

M._render_state = render_state

--- Render/refresh the current tab's panel.
---@param store table
---@param file string|nil
---@param side string
function M.render(store, file, side)
  local st = get_state()
  if not st then
    return
  end
  st.store, st.side = store, side
  -- An explicit file argument updates what "this file" means; `nil` means "whatever
  -- the panel already tracks", so a redraw never silently widens a scoped panel.
  if file ~= nil then
    st.scoped_file = file
  end
  st.file = st.scope == "file" and st.scoped_file or nil
  render_state(st)
end

--- Open (or focus) the panel for a file.
---@param store table
---@param file string|nil
---@param side string
---@param on_jump fun(root:table)
function M.open(store, file, side, on_jump)
  local tab = vim.api.nvim_get_current_tabpage()
  if get_state(tab) then
    M.render(store, file, side)
    return
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "review-comments"
  util.name_buffer(buf, "review://comments-panel/" .. tab)

  vim.cmd("botright vsplit")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  vim.api.nvim_win_set_width(win, require("review.config").get().workspace.comments_width)
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].wrap = true
  vim.wo[win].cursorline = true

  local st = {
    buf = buf, win = win, tab = tab, store = store, file = nil, scoped_file = file,
    side = side, scope = "review", line_map = {}, on_jump = on_jump,
    filter = "unresolved", query = "", selected = {},
  }
  states[tab] = st
  pcall(vim.treesitter.start, buf, "markdown")

  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf, once = true,
    callback = function() states[tab] = nil end,
  })

  local function under_cursor()
    return st.line_map[vim.api.nvim_win_get_cursor(0)[1]]
  end
  --- The thread under the cursor, or nil when the row is a conversation entry.
  local function thread_under_cursor()
    local row = under_cursor()
    if not row or row.conversation then return nil end
    return row
  end
  local function selected_roots()
    local roots = {}
    for id in pairs(st.selected) do
      local root = st.store:get(id)
      if root then roots[#roots + 1] = root end
    end
    return roots
  end
  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, desc = desc })
  end

  map("<CR>", function()
    local row = under_cursor()
    if not row then return end
    if row.conversation then
      -- Not anchored to a line, so there is nowhere in the diff to jump to; open
      -- the full conversation view instead.
      require("review").open_workspace("Conversation")
      return
    end
    if st.on_jump then st.on_jump(row) end
  end, "jump to thread, or open the conversation")
  map("r", function()
    local root = thread_under_cursor()
    if root then require("review").resolve_thread(root) end
  end, "resolve / unresolve")
  map("R", function()
    local root = thread_under_cursor()
    if root then require("review").reply_thread(root) end
  end, "reply")
  map("<Space>", function()
    local root = thread_under_cursor()
    if root then
      st.selected[root.id] = not st.selected[root.id] or nil
      render_state(st)
    end
  end, "select")
  map("f", function()
    local idx = 1
    for i, value in ipairs(filters) do if value == st.filter then idx = i break end end
    st.filter = filters[(idx % #filters) + 1]
    render_state(st)
  end, "cycle filter")
  map("s", function()
    if st.scope == "review" then
      -- Not context(): this key only exists inside the panel, which is never a diff
      -- buffer, so asking about the *current* buffer always answered nil and the
      -- scope toggle could not fire at all.
      local target = require("review.ui.diff").current_file() or st.scoped_file
      if not target then
        util.notify("no file in the diff to scope to", vim.log.levels.INFO)
        return
      end
      st.scoped_file, st.scope, st.file = target, "file", target
    else
      st.scope, st.file = "review", nil
    end
    render_state(st)
  end, "toggle scope: whole review / this file")
  map("/", function()
    vim.ui.input({ prompt = "Filter threads: ", default = st.query }, function(value)
      if value ~= nil then st.query = value; render_state(st) end
    end)
  end, "search")
  map("a", function()
    local roots = selected_roots()
    local under = thread_under_cursor()
    if #roots == 0 and under then roots = { under } end
    if #roots > 0 then require("review").ask_claude_threads(roots) end
  end, "ask Claude about threads")
  map("p", function()
    local roots = selected_roots()
    if #roots == 0 then roots = st.store:all_threads() end
    require("review").publish_threads(roots)
  end, "publish drafts")
  map("z", function() require("review").react_to_thread(thread_under_cursor()) end, "react")
  map("I", function() require("review").import_github_comments() end, "import GitHub comments")
  map("A", function()
    local root = thread_under_cursor()
    if root then require("review").apply_suggestion(root) end
  end, "apply suggestion to the working tree")
  map("Q", function()
    local roots = {}
    for _, row in pairs(st.line_map) do
      if not row.conversation then roots[row.id] = row end
    end
    require("review").threads_to_quickfix(vim.tbl_values(roots))
  end, "export to quickfix")
  map("d", function()
    local root = thread_under_cursor()
    if not root then return end
    require("review.ui.menu").confirm("Delete this local thread?", "Delete", function()
      st.store:delete(root.id)
      require("review").notify_change()
    end)
  end, "delete thread")
  map("e", function()
    local root = thread_under_cursor()
    if not root then return end
    if root.github_id then
      util.notify("Published GitHub comments cannot be edited locally", vim.log.levels.WARN)
      return
    end
    require("review.ui.compose").open({ title = "Edit thread", initial = root.body, on_submit = function(body)
      st.store:update(root.id, { body = body })
      require("review").notify_change()
    end })
  end, "edit thread")
  map("y", function()
    local root = thread_under_cursor()
    if not root then return end
    local out = { string.format("%s:%d", root.file, root.line_start or 0), root.body }
    for _, reply in ipairs(st.store:replies(root.id)) do
      out[#out + 1] = string.format("%s: %s", reply.author, reply.body)
    end
    local value = table.concat(out, "\n")
    vim.fn.setreg("+", value); vim.fn.setreg('"', value); util.notify("thread copied")
  end, "copy thread")
  map("q", M.close, "close panel")

  render_state(st)
end

--- Re-render the current tab's panel from its own store.
function M.refresh()
  local st = get_state()
  if st then render_state(st) end
end

--- Close the current tab's panel.
function M.close()
  local tab = vim.api.nvim_get_current_tabpage()
  local st = states[tab]
  if st and vim.api.nvim_win_is_valid(st.win) then
    vim.api.nvim_win_close(st.win, true)
  end
  states[tab] = nil
end

--- Toggle the panel.
---@param store table
---@param file string|nil
---@param side string
---@param on_jump fun(root:table)
function M.toggle(store, file, side, on_jump)
  if get_state() then
    M.close()
  else
    M.open(store, file, side, on_jump)
  end
end

--- True if the CURRENT tab has a live panel.
---@return boolean
function M.is_open()
  return get_state() ~= nil
end

return M
