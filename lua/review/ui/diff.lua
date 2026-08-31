-- review.nvim :: diffview integration + comment overlay.
--
-- We drive diffview.nvim for rendering and file navigation, then overlay our comment
-- markers on its diff buffers, reapplying on refresh (R2). Comments are added from a
-- visual selection in a diff buffer.

local util = require("review.util")
local markers = require("review.ui.markers")
local compose = require("review.ui.compose")
local config = require("review.config")

local M = {}

--- lazy diffview handles
local function diffview()
  local ok, dv = util.has("diffview")
  if not ok then
    util.notify("diffview.nvim is required but not found", vim.log.levels.ERROR)
    return nil
  end
  return dv
end

--- The current diffview view (or nil).
local function current_view()
  local ok, lib = util.has("diffview.lib")
  if not ok then
    return nil
  end
  return lib.get_current_view()
end

--- Resolve {file, side, bufnr} for a SPECIFIC buffer by strictly matching it against
--- the current view's a/b diff buffers. Returns nil if `bufnr` is not one of them
--- (e.g. the file panel, the comments panel, or an unrelated buffer). This strictness
--- is what keeps markers/keymaps from leaking onto non-diff buffers.
---@param bufnr integer
---@return table|nil { file=string, side="LEFT"|"RIGHT", bufnr=integer }
function M.buffer_context(bufnr)
  local view = current_view()
  if not view or not view.cur_entry then
    return nil
  end
  local entry = view.cur_entry
  local file = entry.path or entry.oldpath
  local layout = entry.layout
  if not layout then
    return nil
  end
  local la = layout.a and layout.a.file
  local lb = layout.b and layout.b.file
  if la and la.bufnr == bufnr then
    return { file = file, side = "LEFT", bufnr = bufnr }
  end
  if lb and lb.bufnr == bufnr then
    return { file = file, side = "RIGHT", bufnr = bufnr }
  end
  return nil
end

--- The file the diff is currently showing, regardless of which window is focused.
---
--- `context()` answers only for the *current* buffer, so anything running from the
--- comments panel — which is not a diff buffer — could not tell which file was on
--- screen.
---@return string|nil
function M.current_file()
  local view = current_view()
  local entry = view and view.cur_entry
  if not entry then
    return nil
  end
  return entry.path or entry.oldpath
end

--- Context for the buffer in the current window (nil if it's not a diff buffer).
---@return table|nil
function M.context(line)
  local ctx = M.buffer_context(vim.api.nvim_get_current_buf())
  if not ctx then
    return nil
  end
  local ok, dv = pcall(require, "diffview")
  local loc = ok and dv.location_at and dv.location_at({ line = line }) or nil
  if loc then
    ctx.file = loc.path or ctx.file
    ctx.side = loc.side
    ctx.line = loc.side == "LEFT" and loc.old_line or loc.new_line
    ctx.old_line, ctx.new_line, ctx.kind = loc.old_line, loc.new_line, loc.kind
  else
    ctx.line = line or vim.api.nvim_win_get_cursor(0)[1]
  end
  return ctx
end

--- Reapply markers to all diff buffers of the current view for `store`.
---@param store table
function M.refresh_markers(store)
  local view = current_view()
  if not view then
    return
  end
  -- Render only into windows whose buffer is strictly one of the view's diff buffers.
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local bufnr = vim.api.nvim_win_get_buf(win)
    local ctx = M.buffer_context(bufnr)
    if ctx and ctx.file then
      markers.render(ctx.bufnr, store, ctx.file, ctx.side, win)
      local viewed, total = store:viewed_progress()
      local open = 0
      for _, root in ipairs(store:all_threads()) do if root.status ~= "resolved" then open = open + 1 end end
      local agent = ""
      for _, session in pairs(store.sessions or {}) do
        if session.state == "running" then agent = " │ Claude: " .. (session.progress or "working"); break end
      end
      vim.wo[win].winbar = string.format(" %%#Title#%s%%* %%= %d/%d viewed · %d open%s ",
        ctx.file, viewed, total, open, agent)
    end
  end
end

--- Add a comment from the current visual (or normal-line) selection.
---@param store table
---@param opts table|nil { suggestion=boolean }
function M.add_comment(store, opts)
  opts = opts or {}
  local ctx = M.context()
  if not ctx or not ctx.file then
    util.notify("place the cursor in a diff to comment", vim.log.levels.WARN)
    return
  end
  -- Visual range if we were called from visual mode; else current line.
  local vstart = vim.fn.getpos("'<")[2]
  local vend = vim.fn.getpos("'>")[2]
  local rendered_start, rendered_end
  if vstart > 0 and vend > 0 and vend >= vstart and vim.fn.mode():match("[vV]") == nil then
    rendered_start, rendered_end = vstart, vend
  else
    local cur = vim.api.nvim_win_get_cursor(0)[1]
    rendered_start, rendered_end = cur, cur
  end

  local first, last = M.context(rendered_start), M.context(rendered_end)
  if not first or not last or not first.line or not last.line or first.side ~= last.side then
    util.notify("selection must stay on one diff side and mapped hunk", vim.log.levels.WARN)
    return
  end
  ctx = first
  local line_start, line_end = math.min(first.line, last.line), math.max(first.line, last.line)

  -- Seed the composer with the selected lines.
  local seed = vim.api.nvim_buf_get_lines(ctx.bufnr, rendered_start - 1, rendered_end, false)

  compose.open({
    title = string.format("%s comment on %s:%d-%d (%s)",
      opts.suggestion and "Suggestion" or "New", ctx.file, line_start, line_end, ctx.side),
    seed = seed,
    suggestion = opts.suggestion,
    on_submit = function(body, is_suggestion, suggestion_text)
      store:add({
        file = ctx.file,
        side = ctx.side,
        line_start = line_start,
        line_end = line_end,
        body = body,
        kind = is_suggestion and "suggestion" or "normal",
        suggestion_text = suggestion_text,
      })
      M.refresh_markers(store)
      util.notify("comment added")
    end,
  })
end

--- Open the full-review diff for a source.
---@param source table
---@return boolean ok
function M.open(source)
  local dv = diffview()
  if not dv then
    return false
  end
  local spec = source:diffview_spec()
  local meta = source:metadata()
  -- Run diffview inside the repo root.
  local prev = vim.fn.getcwd()
  vim.cmd("lcd " .. vim.fn.fnameescape(meta.repo_root))
  dv.open(spec)
  vim.cmd("lcd " .. vim.fn.fnameescape(prev))
  if config.get().default_view == "unified" then
    pcall(vim.cmd, "DiffviewToggleFiles") -- no-op safety; unified handled below
  end
  return true
end

--- Open a single commit's diff in a new tab (sha^!).
---@param source table
---@param sha string
---@return boolean ok
function M.open_commit(source, sha)
  local dv = diffview()
  if not dv then
    return false
  end
  local meta = source:metadata()
  local prev = vim.fn.getcwd()
  vim.cmd("lcd " .. vim.fn.fnameescape(meta.repo_root))
  dv.open(sha .. "^!")
  vim.cmd("lcd " .. vim.fn.fnameescape(prev))
  util.notify("diff for commit " .. sha:sub(1, 8))
  return true
end

--- Toggle unified/split for the current view.
function M.toggle_view()
  -- diffview exposes :DiffviewToggleFiles for the panel; for layout we cycle its
  -- configured layout via its API when available.
  local ok = pcall(vim.cmd, "DiffviewToggleFiles")
  if not ok then
    util.notify("no active diffview", vim.log.levels.WARN)
  end
end

return M
