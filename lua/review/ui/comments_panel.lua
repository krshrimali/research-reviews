-- review.nvim :: opt-in comments side-panel (right split).
--
-- Lists comment threads for the current file (first chars shown). <CR> jumps to the
-- thread's anchor in the diff and expands it inline.

local util = require("review.util")

local M = {}

M.ns = vim.api.nvim_create_namespace("review_panel")

---@class Panel
---@field buf integer
---@field win integer
---@field store table
---@field file string
---@field side string
---@field line_map table<integer, table>  -- line -> root comment
---@field on_jump fun(root:table)

local state = nil

--- Build lines for the panel.
---@param store table
---@param file string
---@return string[], table<integer,table>
local filters = { "unresolved", "all", "claude", "draft", "outdated", "resolved" }

local function matches(root, filter, query)
  if filter == "unresolved" and root.status == "resolved" then return false end
  if filter == "claude" and root.origin ~= "claude" then return false end
  if filter == "draft" and root.status ~= "draft" then return false end
  if filter == "outdated" and root.status ~= "outdated" then return false end
  if filter == "resolved" and root.status ~= "resolved" then return false end
  if query and query ~= "" then
    local haystack = table.concat({ root.file or "", root.author or "", root.body or "", root.origin or "" }, " "):lower()
    if not haystack:find(query:lower(), 1, true) then return false end
  end
  return true
end

local function add_body(lines, map, root, prefix, body)
  local body_lines = vim.split(body or "", "\n", { plain = true })
  for i = 2, math.min(#body_lines, 6) do
    table.insert(lines, prefix .. body_lines[i]); map[#lines] = root
  end
  if #body_lines > 6 then
    table.insert(lines, string.format("%s… %d more lines", prefix, #body_lines - 6)); map[#lines] = root
  end
end

local function tree_insert(tree, root)
  local parts = vim.split(root.file or "(unknown)", "/", { plain = true, trimempty = true })
  local node = tree
  for i = 1, math.max(0, #parts - 1) do
    local part = parts[i]
    node.dirs[part] = node.dirs[part] or { dirs = {}, files = {} }
    node = node.dirs[part]
  end
  local file_name = parts[#parts] or "(unknown)"
  node.files[file_name] = node.files[file_name] or {}
  table.insert(node.files[file_name], root)
end

local function sorted_keys(tbl)
  local keys = vim.tbl_keys(tbl)
  table.sort(keys)
  return keys
end

local function render_tree(node, depth, lines, map, store, selected)
  local indent = string.rep("  ", depth)
  for _, dirname in ipairs(sorted_keys(node.dirs)) do
    table.insert(lines, indent .. "▾ " .. dirname .. "/")
    render_tree(node.dirs[dirname], depth + 1, lines, map, store, selected)
  end
  for _, filename in ipairs(sorted_keys(node.files)) do
    table.insert(lines, indent .. "▾ " .. filename)
    for _, root in ipairs(node.files[filename]) do
      local count = 1 + #store:replies(root.id)
      local icon = root.status == "resolved" and "✓"
        or (root.status == "outdated" and "⚠")
        or (root.origin == "claude" and "★" or "●")
      local checked = selected[root.id] and "[x]" or "[ ]"
      local reaction_count = 0
      for _, n in pairs(root.reactions or {}) do reaction_count = reaction_count + n end
      local body = vim.split(root.body or "", "\n", { plain = true })
      local suffix = count > 1 and string.format(" · %d messages", count) or ""
      if reaction_count > 0 then suffix = suffix .. " · ♥" .. reaction_count end
      local prefix = indent .. "  "
      table.insert(lines, string.format("%s%s %s @%s: %s%s", prefix, checked, icon,
        root.author or "unknown", body[1] or "", suffix))
      map[#lines] = root
      add_body(lines, map, root, prefix .. "    ", root.body)
      for _, reply in ipairs(store:replies(root.id)) do
        local reply_body = vim.split(reply.body or "", "\n", { plain = true })
        table.insert(lines, string.format("%s    ↳ @%s: %s", prefix, reply.author or "unknown", reply_body[1] or ""))
        map[#lines] = root
        add_body(lines, map, root, prefix .. "      ", reply.body)
      end
    end
  end
end

local function build(store, file, filter, query, selected)
  local lines, map = {}, {}
  local all = file and store:threads_for_file(file) or store:all_threads()
  local open, drafts = 0, 0
  for _, root in ipairs(all) do
    if root.status ~= "resolved" then open = open + 1 end
    if root.status == "draft" then drafts = drafts + 1 end
  end
  table.insert(lines, string.format("Threads · %d open · %d drafts", open, drafts))
  table.insert(lines, string.format("filter: %s%s", filter, query ~= "" and (" · /" .. query) or ""))
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
  local tree = { dirs = {}, files = {} }
  for _, root in ipairs(threads) do tree_insert(tree, root) end
  render_tree(tree, 0, lines, map, store, selected)
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
  table.insert(lines, "f filter · / search · Q quickfix · r resolve · e edit · d delete · y copy · q close")
  return lines, map
end


M._build = build

--- Render/refresh the panel content.
---@param store table
---@param file string
---@param side string
function M.render(store, file, side)
  if not state or not vim.api.nvim_buf_is_valid(state.buf) then
    return
  end
  state.store, state.file, state.side = store, file, side
  local lines, map = build(store, file, state.filter, state.query, state.selected)
  state.line_map = map
  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  vim.bo[state.buf].modifiable = false
end

--- Open (or focus) the panel for a file.
---@param store table
---@param file string
---@param side string
---@param on_jump fun(root:table)
function M.open(store, file, side, on_jump)
  if state and vim.api.nvim_win_is_valid(state.win) then
    M.render(store, file, side)
    return
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "review-comments"
  vim.api.nvim_buf_set_name(buf, "review://comments-panel")

  vim.cmd("botright vsplit")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  vim.api.nvim_win_set_width(win, require("review.config").get().workspace.comments_width)
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].wrap = true

  state = { buf = buf, win = win, store = store, file = file, side = side, line_map = {},
    on_jump = on_jump, filter = "unresolved", query = "", selected = {} }
  pcall(vim.treesitter.start, buf, "markdown")

  local function map(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true })
  end
  map("<CR>", function()
    local root = state.line_map[vim.api.nvim_win_get_cursor(0)[1]]
    if root and state.on_jump then
      state.on_jump(root)
    end
  end)
  map("r", function()
    local root = state.line_map[vim.api.nvim_win_get_cursor(0)[1]]
    if root then
      state.store:set_resolved(root.id, root.status ~= "resolved")
      M.render(state.store, state.file, state.side)
    end
  end)
  map("<Space>", function()
    local root = state.line_map[vim.api.nvim_win_get_cursor(0)[1]]
    if root then state.selected[root.id] = not state.selected[root.id] or nil; M.render(state.store, state.file, state.side) end
  end)
  map("f", function()
    local idx = 1
    for i, value in ipairs(filters) do if value == state.filter then idx = i break end end
    state.filter = filters[(idx % #filters) + 1]
    M.render(state.store, state.file, state.side)
  end)
  map("/", function()
    vim.ui.input({ prompt = "Filter threads: ", default = state.query }, function(value)
      if value ~= nil then state.query = value; M.render(state.store, state.file, state.side) end
    end)
  end)
  map("a", function()
    local roots = {}
    for id in pairs(state.selected) do local root = state.store:get(id); if root then roots[#roots + 1] = root end end
    local under = state.line_map[vim.api.nvim_win_get_cursor(0)[1]]
    if #roots == 0 and under then roots = { under } end
    if #roots > 0 then require("review").ask_claude_threads(roots) end
  end)
  map("p", function()
    local roots = {}
    for id in pairs(state.selected) do local root = state.store:get(id); if root then roots[#roots + 1] = root end end
    if #roots == 0 then roots = state.store:all_threads() end
    require("review").publish_threads(roots)
  end)
  map("z", function()
    require("review").react_to_thread(state.line_map[vim.api.nvim_win_get_cursor(0)[1]])
  end)
  map("I", function() require("review").import_github_comments() end)
  map("Q", function()
    local roots = {}
    for _, root in pairs(state.line_map) do roots[root.id] = root end
    require("review").threads_to_quickfix(vim.tbl_values(roots))
  end)
  map("d", function()
    local root = state.line_map[vim.api.nvim_win_get_cursor(0)[1]]
    if root then
      state.store:delete(root.id)
      M.render(state.store, state.file, state.side)
    end
  end)
  map("e", function()
    local root = state.line_map[vim.api.nvim_win_get_cursor(0)[1]]
    if root then
      require("review.ui.compose").open({ title = "Edit thread", initial = root.body, on_submit = function(body)
        state.store:update(root.id, { body = body }); M.render(state.store, state.file, state.side)
      end })
    end
  end)
  map("y", function()
    local root = state.line_map[vim.api.nvim_win_get_cursor(0)[1]]
    if root then
      local out = { string.format("%s:%d", root.file, root.line_start or 0), root.body }
      for _, reply in ipairs(state.store:replies(root.id)) do out[#out + 1] = string.format("%s: %s", reply.author, reply.body) end
      local value = table.concat(out, "\n")
      vim.fn.setreg("+", value); vim.fn.setreg('"', value); util.notify("thread copied")
    end
  end)
  map("q", M.close)

  M.render(store, file, side)
end

--- Close the panel.
function M.close()
  if state and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_close(state.win, true)
  end
  state = nil
end

--- Toggle the panel.
---@param store table
---@param file string
---@param side string
---@param on_jump fun(root:table)
function M.toggle(store, file, side, on_jump)
  if state and vim.api.nvim_win_is_valid(state.win) then
    M.close()
  else
    M.open(store, file, side, on_jump)
  end
end

--- True if the panel is open.
---@return boolean
function M.is_open()
  return state ~= nil and vim.api.nvim_win_is_valid(state.win)
end

return M
