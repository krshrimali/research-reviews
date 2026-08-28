-- review.nvim :: inline comment markers + thread expansion via extmarks.
--
-- Markers are (re)applied to a diff buffer for a given file. Because diffview
-- recreates buffers on refresh (R2), callers reapply via autocmds. We anchor
-- markers by line number resolved from the store (already re-anchored on open).

local util = require("review.util")

local M = {}

M.ns = vim.api.nvim_create_namespace("review_markers")

-- Per-buffer expansion state: bufnr -> { [root_id]=true }
local expanded = {}

--- Build the virt_lines block for an expanded thread.
---@param store table
---@param root table
---@return table[] virt_lines (list of lists of [text, hl])
local function thread_virt_lines(store, root)
  local lines = {}
  local function add(text, hl)
    table.insert(lines, { { text, hl or "Comment" } })
  end
  local status = root.status ~= "draft" and (" [" .. root.status .. "]") or ""
  add(string.format("  ╭─ %s (%s)%s", root.author or "?", root.origin or "local", status), "Title")
  if root.reactions then
    local chips = {}
    for name, count in pairs(root.reactions) do chips[#chips + 1] = string.format("%s %d", name:lower(), count) end
    table.sort(chips)
    if #chips > 0 then add("  │ " .. table.concat(chips, " · "), "Special") end
  end
  local fenced = false
  for _, bodyline in ipairs(vim.split(root.body or "", "\n", { plain = true })) do
    if bodyline:match("^%s*```") then
      fenced = not fenced
      add("  │ " .. bodyline, "Comment")
    elseif fenced then
      local hl = bodyline:match("^%s*[/%-%-#]+") and "Comment" or "String"
      add("  │ " .. bodyline, hl)
    else
      add("  │ " .. bodyline)
    end
  end
  if root.kind == "suggestion" and root.suggestion_text then
    add("  │ suggestion:", "DiagnosticInfo")
    for _, s in ipairs(vim.split(root.suggestion_text, "\n", { plain = true })) do
      add("  │   " .. s, "DiffAdd")
    end
  end
  for _, reply in ipairs(store:replies(root.id)) do
    add(string.format("  ├─ %s (%s)", reply.author or "?", reply.origin or "local"), "Title")
    for _, bodyline in ipairs(vim.split(reply.body or "", "\n", { plain = true })) do
      add("  │ " .. bodyline)
    end
  end
  add("  ╰─ <CR> collapse  r resolve  d delete  R reply", "NonText")
  return lines
end

--- Render all markers for `file` into `bufnr` from `store`.
--- `side` selects which comments apply ("RIGHT" for working/head buffer).
---@param bufnr integer
---@param store table
---@param file string
---@param side string
function M.render(bufnr, store, file, side, winid)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local buf_expanded = expanded[bufnr] or {}
  for _, root in ipairs(store:threads_for_file(file)) do
    -- Skip anchors past the end of this buffer rather than stacking them on the last
    -- line (they belong to the other side or are outdated).
    if root.side == side and not root.hidden then
      local ok, dv = pcall(require, "diffview")
      local lnum = ok and dv.line_for and dv.line_for({ winid = winid, side = side, line = root.line_start or 1 })
        or root.line_start
      if lnum and lnum >= 1 and lnum <= line_count then
      local count = 1 + #store:replies(root.id)
      local icon = root.status == "resolved" and "✓" or (root.origin == "claude" and "★" or "💬")
      local label = string.format(" %s%d", icon, count)
      local hl = root.status == "resolved" and "DiffChange"
        or (root.status == "outdated" and "WarningMsg" or "DiffText")
      local opts = {
        virt_text = { { label, hl } },
        virt_text_pos = "eol",
        sign_text = root.status == "resolved" and "✓" or "▎",
        sign_hl_group = hl,
        priority = 200,
      }
      if buf_expanded[root.id] then
        opts.virt_lines = thread_virt_lines(store, root)
      end
      pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, lnum - 1, 0, opts)
      end
    end
  end
end

--- Toggle inline expansion of the thread anchored at the cursor line in `bufnr`.
--- Returns the root comment toggled, or nil.
---@param bufnr integer
---@param store table
---@param file string
---@param side string
---@return table|nil root
function M.toggle_at_cursor(bufnr, store, file, side, logical_line)
  local cursor = vim.api.nvim_win_get_cursor(0)
  local lnum = logical_line or cursor[1]
  for _, root in ipairs(store:threads_for_file(file)) do
    if root.side == side and root.line_start == lnum then
      expanded[bufnr] = expanded[bufnr] or {}
      expanded[bufnr][root.id] = not expanded[bufnr][root.id]
      M.render(bufnr, store, file, side)
      return root
    end
  end
  util.notify("no comment thread on this line", vim.log.levels.INFO)
  return nil
end

--- The root thread at the cursor line, if any.
---@param store table
---@param file string
---@param side string
---@return table|nil
function M.thread_at_cursor(store, file, side, logical_line)
  local lnum = logical_line or vim.api.nvim_win_get_cursor(0)[1]
  for _, root in ipairs(store:threads_for_file(file)) do
    if root.side == side and root.line_start == lnum then
      return root
    end
  end
  return nil
end

--- Forget expansion state for a buffer (on wipe).
---@param bufnr integer
function M.forget(bufnr)
  expanded[bufnr] = nil
end

return M
