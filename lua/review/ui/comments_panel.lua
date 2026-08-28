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
local function build(store, file)
  local lines, map = {}, {}
  table.insert(lines, "Comments: " .. (file or "(no file)"))
  table.insert(lines, string.rep("─", 24))
  local threads = file and store:threads_for_file(file) or {}
  if #threads == 0 then
    table.insert(lines, "(no comments on this file)")
  end
  for _, root in ipairs(threads) do
    local count = 1 + #store:replies(root.id)
    local icon = root.status == "resolved" and "✓"
      or (root.status == "outdated" and "⚠")
      or (root.origin == "claude" and "★" or "▸")
    local head = string.format("%s L%d (%d) %s", icon, root.line_start or 0, count, root.author or "")
    table.insert(lines, head)
    map[#lines] = root
    table.insert(lines, "   " .. util.truncate(root.body, 40))
    map[#lines] = root
  end
  table.insert(lines, "")
  table.insert(lines, "<CR> open  r resolve  d delete  q close")
  return lines, map
end

--- Render/refresh the panel content.
---@param store table
---@param file string
---@param side string
function M.render(store, file, side)
  if not state or not vim.api.nvim_buf_is_valid(state.buf) then
    return
  end
  state.store, state.file, state.side = store, file, side
  local lines, map = build(store, file)
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
  vim.bo[buf].filetype = "review-comments"
  vim.api.nvim_buf_set_name(buf, "review://comments-panel")

  vim.cmd("botright vsplit")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  vim.api.nvim_win_set_width(win, 40)
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].wrap = true

  state = { buf = buf, win = win, store = store, file = file, side = side, line_map = {}, on_jump = on_jump }

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
  map("d", function()
    local root = state.line_map[vim.api.nvim_win_get_cursor(0)[1]]
    if root then
      state.store:delete(root.id)
      M.render(state.store, state.file, state.side)
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
