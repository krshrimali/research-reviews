-- review.nvim :: prtui-inspired full-page read-only review views.

local util = require("review.util")
local M = {}
local ns = vim.api.nvim_create_namespace("review_workspace")

vim.api.nvim_set_hl(0, "ReviewWorkspaceTab", { default = true, link = "Comment" })
vim.api.nvim_set_hl(0, "ReviewWorkspaceTabActive", { default = true, link = "IncSearch" })
vim.api.nvim_set_hl(0, "ReviewWorkspaceSection", { default = true, link = "Title" })
vim.api.nvim_set_hl(0, "ReviewWorkspaceAuthor", { default = true, link = "DiagnosticInfo" })
vim.api.nvim_set_hl(0, "ReviewWorkspaceReaction", { default = true, link = "Special" })
vim.api.nvim_set_hl(0, "ReviewWorkspaceOutdated", { default = true, link = "DiagnosticWarn" })
vim.api.nvim_set_hl(0, "ReviewWorkspaceLink", { default = true, link = "Underlined" })

local modes = { "Conversation", "Timeline", "Claude", "Comments" }

local function reactions(value)
  local chips = {}
  for name, count in pairs(value or {}) do chips[#chips + 1] = ("%s %d"):format(name:lower(), count) end
  table.sort(chips)
  return #chips > 0 and ("[" .. table.concat(chips, "] [") .. "]") or nil
end

local function body(lines, text, indent)
  for _, line in ipairs(vim.split(util.normalize_markdown(text), "\n", { plain = true })) do
    lines[#lines + 1] = (indent or "") .. line
  end
end

local function header(lines, st)
  local tabs = {}
  for i, name in ipairs({ "Conversation", "Timeline", "Claude", "Comments", "Diff" }) do
    tabs[#tabs + 1] = st.mode == name and ("[" .. i .. " " .. name .. "]") or (i .. " " .. name)
  end
  lines[#lines + 1] = table.concat(tabs, "   ")
  lines[#lines + 1] = string.rep("─", math.min(100, vim.o.columns - 4))
  lines[#lines + 1] = "1–5 switch views · ] next view · <leader>pc / <leader>rC Claude review · <leader>p actions · q close"
  lines[#lines + 1] = st.source:title()
  lines[#lines + 1] = ("@%s · updated %s"):format(st.source:author(), util.relative_time(st.source:updated_at()))
  lines[#lines + 1] = ""
end

local function conversation(lines, st)
  lines[#lines + 1] = "## Description"
  body(lines, st.source:description(), "")
  lines[#lines + 1] = ""
  local general = st.source.conversation and st.source:conversation() or {}
  lines[#lines + 1] = ("## General PR conversation (%d) · not anchored to the diff"):format(#general)
  if #general == 0 then lines[#lines + 1] = "(none)" end
  for _, item in ipairs(general) do
    lines[#lines + 1] = ("### @%s · %s%s"):format(item.author, util.relative_time(item.created_at),
      item.state and (" · " .. item.state) or "")
    body(lines, item.body, "  ")
    local counts = {}
    for _, group in ipairs(item.reactions or {}) do
      local n = group.users and tonumber(group.users.totalCount) or 0
      if group.content and n > 0 then counts[group.content] = n end
    end
    local chips = reactions(counts); if chips then lines[#lines + 1] = "  " .. chips end
    if item.url then lines[#lines + 1] = "  " .. item.url end
    lines[#lines + 1] = ""
  end
  lines[#lines + 1] = ("## Inline review threads (%d)"):format(#st.store:all_threads())
  for _, root in ipairs(st.store:all_threads()) do
    local state = root.status == "outdated" and "OUTDATED" or root.status
    lines[#lines + 1] = ("### @%s · %s:%d · %s"):format(root.author, root.file, root.line_start or 1, state)
    body(lines, root.body, "  ")
    local chips = reactions(root.reactions); if chips then lines[#lines + 1] = "  " .. chips end
    for _, reply in ipairs(st.store:replies(root.id)) do
      lines[#lines + 1] = ("  ↳ @%s"):format(reply.author)
      body(lines, reply.body, "    ")
      local rc = reactions(reply.reactions); if rc then lines[#lines + 1] = "    " .. rc end
    end
    lines[#lines + 1] = ""
  end
end

local function timeline(lines, st)
  lines[#lines + 1] = "## Timeline"
  local events = {}
  for _, c in ipairs(st.source:commits()) do
    events[#events + 1] = { at = c.date or c.authored_at or "", text = ("commit %s · %s · @%s"):format(c.short, c.subject, c.author or "?") }
  end
  for _, item in ipairs(st.source.conversation and st.source:conversation() or {}) do
    events[#events + 1] = { at = item.created_at or "", text = ("%s · @%s"):format(item.kind, item.author), body = item.body }
  end
  for _, root in ipairs(st.store:all_threads()) do
    events[#events + 1] = { at = root.created_at or "", text = ("inline comment · @%s · %s:%d%s"):format(
      root.author, root.file, root.line_start or 1, root.status == "outdated" and " · OUTDATED" or ""), body = root.body }
  end
  table.sort(events, function(a, b) return a.at < b.at end)
  for _, event in ipairs(events) do
    lines[#lines + 1] = ("- %s · %s"):format(event.at ~= "" and event.at or "unknown time", event.text)
    if event.body and event.body ~= "" then body(lines, event.body, "    ") end
  end
end

local function claude(lines, st)
  lines[#lines + 1] = "## Claude reviews"
  local sessions = vim.tbl_values(st.store.sessions or {})
  table.sort(sessions, function(a, b) return (a.started_at or "") > (b.started_at or "") end)
  if #sessions == 0 then lines[#lines + 1] = "(no Claude review sessions yet)" end
  for _, session in ipairs(sessions) do
    lines[#lines + 1] = ("### %s · %s · %s"):format(session.verdict or session.state or "unknown",
      session.started_at or "", session.progress or "")
    body(lines, session.summary or "", "  ")
  end
end

local function comments(lines, st)
  st.line_map = {}
  local groups = { Unresolved = {}, Resolved = {}, Outdated = {} }
  for _, root in ipairs(st.store:all_threads()) do
    local name = root.status == "outdated" and "Outdated" or root.status == "resolved" and "Resolved" or "Unresolved"
    groups[name][#groups[name] + 1] = root
  end
  for _, name in ipairs({ "Unresolved", "Resolved", "Outdated" }) do
    lines[#lines + 1] = ("## %s (%d)"):format(name, #groups[name])
    if #groups[name] == 0 then lines[#lines + 1] = "(none)" end
    for _, root in ipairs(groups[name]) do
      lines[#lines + 1] = ("### @%s · %s:%d%s"):format(root.author, root.file, root.line_start or 1,
        name == "Outdated" and " · OUTDATED — no current diff anchor" or "")
      st.line_map[#lines] = root
      body(lines, root.body, "  ")
      local chips = reactions(root.reactions); if chips then lines[#lines + 1] = "  " .. chips end
      for _, reply in ipairs(st.store:replies(root.id)) do
        lines[#lines + 1] = ("  ↳ @%s"):format(reply.author); body(lines, reply.body, "    ")
      end
      lines[#lines + 1] = ""
    end
  end
end

local renderers = { Conversation = conversation, Timeline = timeline, Claude = claude, Comments = comments }

local function render(st)
  local lines = {}; header(lines, st); renderers[st.mode](lines, st)
  vim.bo[st.buf].modifiable = true
  vim.api.nvim_buf_set_lines(st.buf, 0, -1, false, lines)
  vim.bo[st.buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(st.buf, ns, 0, -1)
  for row, line in ipairs(lines) do
    local zero = row - 1
    if line:match("^##") then
      vim.api.nvim_buf_add_highlight(st.buf, ns, "ReviewWorkspaceSection", zero, 0, -1)
    end
    local from = 1
    while true do
      local a, b = line:find("@[%w_.-]+", from)
      if not a then break end
      vim.api.nvim_buf_add_highlight(st.buf, ns, "ReviewWorkspaceAuthor", zero, a - 1, b); from = b + 1
    end
    from = 1
    while true do
      local a, b = line:find("%[[%w_+-]+ %d+%]", from)
      if not a then break end
      vim.api.nvim_buf_add_highlight(st.buf, ns, "ReviewWorkspaceReaction", zero, a - 1, b); from = b + 1
    end
    from = 1
    while true do
      local a, b = line:find("https?://%S+", from)
      if not a then break end
      vim.api.nvim_buf_add_highlight(st.buf, ns, "ReviewWorkspaceLink", zero, a - 1, b); from = b + 1
    end
    local a, b = line:find("OUTDATED")
    if a then vim.api.nvim_buf_add_highlight(st.buf, ns, "ReviewWorkspaceOutdated", zero, a - 1, b) end
  end
  local from = 1
  while true do
    local a, b = lines[1]:find("%[?%d [A-Za-z]+%]?", from)
    if not a then break end
    local active = lines[1]:sub(a, a) == "["
    vim.api.nvim_buf_add_highlight(st.buf, ns, active and "ReviewWorkspaceTabActive" or "ReviewWorkspaceTab", 0, a - 1, b)
    from = b + 1
  end
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
end

function M.open(source, store, mode)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.cmd("tabnew"); vim.api.nvim_win_set_buf(0, buf)
  vim.api.nvim_buf_set_name(buf, "review://workspace/" .. util.hash(source:key()))
  vim.bo[buf].buftype, vim.bo[buf].bufhidden, vim.bo[buf].filetype = "nofile", "wipe", "markdown"
  vim.wo.wrap, vim.wo.linebreak, vim.wo.breakindent = true, true, true
  local st = { source = source, store = store, mode = mode or "Conversation", buf = buf }
  local function switch(index)
    if index == 5 then vim.cmd("tabclose"); return end
    st.mode = modes[index]; render(st)
  end
  for i = 1, 5 do vim.keymap.set("n", tostring(i), function() switch(i) end, { buffer = buf, nowait = true }) end
  vim.keymap.set("n", "]", function() switch((vim.tbl_contains(modes, st.mode) and (vim.fn.index(modes, st.mode) + 1) % 4 + 1) or 1) end,
    { buffer = buf, nowait = true })
  vim.keymap.set("n", "q", "<cmd>tabclose<cr>", { buffer = buf, nowait = true })
  vim.keymap.set("n", "<CR>", function()
    local root = st.mode == "Comments" and st.line_map and st.line_map[vim.api.nvim_win_get_cursor(0)[1]] or nil
    if not root then return end
    if root.status == "outdated" then
      util.notify("Outdated thread has no current diff anchor; its original location remains in Comments")
      return
    end
    vim.cmd("tabclose")
    vim.schedule(function()
      require("diffview").open_review_location({ path = root.file, side = root.side, line = root.line_start })
    end)
  end, { buffer = buf, nowait = true, desc = "Open comment on diff" })
  render(st); pcall(vim.treesitter.start, buf, "markdown")
  return st
end

return M
