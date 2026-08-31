-- review.nvim :: public API + orchestration hub.

local config = require("review.config")
local util = require("review.util")

local M = {}

local function diffview_github_threads(store)
  local mapped = {}
  for _, root in ipairs(store:all_threads()) do
    if root.origin == "github" then
      local replies = {}
      for _, reply in ipairs(store:replies(root.id)) do
        replies[#replies + 1] = {
          author = reply.author, body = reply.body, suggestion = reply.suggestion_text,
          reactions = reply.reactions,
        }
      end
      mapped[#mapped + 1] = {
        path = root.file, side = root.side == "LEFT" and "a" or "b",
        lnum = root.line_start or 1, end_lnum = root.line_end or root.line_start or 1,
        text = root.body or "", origin = "github", author = root.author,
        resolved = root.status == "resolved", outdated = root.status == "outdated",
        reactions = root.reactions, thread_id = root.github_thread_id, replies = replies,
      }
    end
  end
  return mapped
end

M._diffview_github_threads = diffview_github_threads

local function sync_diffview_github_comments(current, attempts)
  if not current or M.current ~= current then return end
  local ok_lib, lib = pcall(require, "diffview.lib")
  local ok_review, review = pcall(require, "diffview.review")
  local view = ok_lib and lib.get_current_view() or nil
  if not view then
    if (attempts or 0) < 5 then
      vim.defer_fn(function() sync_diffview_github_comments(current, (attempts or 0) + 1) end, 80)
    end
    return
  end
  if ok_review and review.import_threads then
    local threads = diffview_github_threads(current.store)
    local ok_import = pcall(review.import_threads, view, threads, "github")
    -- Remember whether Diffview took ownership of these, so markers.render can skip
    -- drawing a second copy of every one of them on the same line.
    M.diffview_renders_github = ok_import and #threads > 0
    if ok_import then
      require("review.ui.diff").refresh_markers(current.store)
    end
  end
end

---@class ReviewContext
---@field source table
---@field store table
M.current = nil

--- Which review lives in which tabpage.
---
--- `M.current` is a single global, but a review lives in its own tab and a session
--- routinely has several open. Without this, switching back to an earlier review's
--- tab left every action — comment, resolve, publish — pointed at whichever review
--- was opened last.
---@type table<integer, ReviewContext>
M._reviews = {}

--- Remember that `context` is the review shown in `tab`.
---@param tab integer
---@param context ReviewContext
function M.bind_tab(tab, context)
  M._reviews[tab] = context
end

--- Point M.current at whatever review owns this tabpage, if any. Tabs that hold no
--- review (a worktree file, an unrelated buffer) leave the context alone.
---@param tab integer|nil
function M.focus_tab(tab)
  tab = tab or vim.api.nvim_get_current_tabpage()
  for known in pairs(M._reviews) do
    if not vim.api.nvim_tabpage_is_valid(known) then
      M._reviews[known] = nil
    end
  end
  local context = M._reviews[tab]
  if context then
    M.current = context
  end
end

--- Compute a rename map old_path -> new_path from the source's file list.
---@param source table
---@return table<string,string>
local function rename_map(source)
  local map = {}
  for _, f in ipairs(source:files()) do
    if f.status == "renamed" and f.old_path then
      map[f.old_path] = f.path
    end
  end
  return map
end

--- Set up buffer-local review keymaps + render markers on a diffview diff buffer.
---@param bufnr integer
function M._attach_diff_buffer(bufnr)
  if not M.current then
    return
  end
  local diff = require("review.ui.diff")
  local markers = require("review.ui.markers")
  -- Only attach to a genuine diff buffer of the current view. This prevents the
  -- review keymaps (and the <CR> override) from leaking onto the overview, the
  -- comments panel, or any unrelated buffer entered while a review is active.
  local attach_ctx = diff.buffer_context(bufnr)
  if not attach_ctx then
    return
  end
  local km = config.get().keymaps
  local store = M.current.store

  -- Just two buffer-local keys: the menu (everything) and the primary line action.
  pcall(vim.keymap.set, { "n", "v" }, km.menu, M.menu,
    { buffer = bufnr, nowait = true, desc = "review: actions menu" })
  pcall(vim.keymap.set, "n", km.primary, function()
    local ctx = diff.context()
    if not ctx then return end
    local root = markers.thread_at_cursor(store, ctx.file, ctx.side, ctx.line)
    -- When Diffview owns this thread's inline block (see markers.delegated), toggling
    -- our own expansion renders nothing — the key would silently do nothing. Hand off
    -- to Diffview's fold instead, so the primary key always means the same thing.
    if root and markers.delegated(root) then
      local ok, dv_review = pcall(require, "diffview.review")
      if ok and dv_review.toggle_comment_fold then
        dv_review.toggle_comment_fold()
        return
      end
    end
    markers.toggle_at_cursor(ctx.bufnr, store, ctx.file, ctx.side, ctx.line)
  end, { buffer = bufnr, nowait = true, desc = "review: expand/collapse thread" })
  pcall(vim.keymap.set, "n", "]t", function() M.navigate_thread(1, false) end,
    { buffer = bufnr, desc = "review: next thread" })
  pcall(vim.keymap.set, "n", "[t", function() M.navigate_thread(-1, false) end,
    { buffer = bufnr, desc = "review: previous thread" })
  pcall(vim.keymap.set, "n", "]u", function() M.navigate_thread(1, true) end,
    { buffer = bufnr, desc = "review: next unresolved thread" })
  pcall(vim.keymap.set, "n", "[u", function() M.navigate_thread(-1, true) end,
    { buffer = bufnr, desc = "review: previous unresolved thread" })
  pcall(vim.keymap.set, "n", "<localleader>v", M.toggle_viewed,
    { buffer = bufnr, desc = "review: toggle file viewed" })
  -- `o`/`O` are Vim's open-line-below/above. In a working-tree diff the right-hand
  -- buffer is the real file, so shadowing them replaced two reflexive editing keys
  -- with something else entirely; the reviewed-commit action lives on `go`/`gO`.
  pcall(vim.keymap.set, "n", "go", function() M.open_at_commit(false) end,
    { buffer = bufnr, desc = "review: open file at reviewed commit" })
  pcall(vim.keymap.set, "n", "gO", function() M.open_at_commit(true) end,
    { buffer = bufnr, desc = "review: open file at reviewed commit in new tab" })

  -- The keys the expanded-thread footer advertises. Buffer-local and thread-aware:
  -- with no thread under the cursor they fall through to their normal meaning.
  local function on_thread(fn, fallback)
    return function()
      local ctx = diff.context()
      local root = ctx and markers.thread_at_cursor(store, ctx.file, ctx.side, ctx.line)
      if root then return fn(root) end
      if fallback then
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(fallback, true, false, true), "n", false)
      end
    end
  end
  pcall(vim.keymap.set, "n", "R", on_thread(function(root) M.reply_thread(root) end, nil),
    { buffer = bufnr, nowait = true, desc = "review: reply to thread here" })
  pcall(vim.keymap.set, "n", "gr", on_thread(function(root) M.resolve_thread(root) end, nil),
    { buffer = bufnr, nowait = true, desc = "review: resolve thread here" })
  pcall(vim.keymap.set, "n", "gd", on_thread(function() M.delete_at_cursor() end, nil),
    { buffer = bufnr, nowait = true, desc = "review: delete thread here" })
  for i, mode in ipairs({ "Conversation", "Timeline", "Claude", "Comments" }) do
    pcall(vim.keymap.set, "n", "g" .. i, function() M.open_workspace(mode) end,
      { buffer = bufnr, desc = "review: " .. mode .. " view" })
  end
  local esc = vim.fn.maparg("<Esc>", "n", false, true)
  if esc and esc.buffer == 1 and tostring(esc.rhs or ""):match("close") then
    pcall(vim.keymap.del, "n", "<Esc>", { buffer = bufnr })
  end

  -- Render existing markers for this specific diff buffer.
  diff.refresh_markers(store)
end

--- The current diff context (file/side/bufnr), or nil + notify.
local function ctx_or_warn()
  local diff = require("review.ui.diff")
  local ctx = diff.context()
  if not ctx then
    util.notify("no diff context here", vim.log.levels.WARN)
  end
  return ctx
end

--- One place every mutation announces itself.
---
--- Markers, the winbar, the comments panel and the Diffview bridge each used to be
--- refreshed by whichever call site remembered to; adding a comment refreshed the
--- gutter but not the panel, marking a file viewed refreshed neither. Route every
--- change through here instead.
function M.notify_change()
  if not M.current then return end
  local ok_diff, diff = pcall(require, "review.ui.diff")
  if ok_diff then diff.refresh_markers(M.current.store) end
  local ok_panel, panel = pcall(require, "review.ui.comments_panel")
  if ok_panel and panel.is_open() then panel.refresh() end
  -- Redraw the file tree so its viewed ticks and thread counts stay in step.
  local ok_lib, lib = pcall(require, "diffview.lib")
  if ok_lib then
    local view = lib.get_current_view()
    if view and view.panel and view.panel.render and view.panel.redraw then
      pcall(function()
        view.panel:render()
        view.panel:redraw()
      end)
    end
  end
  sync_diffview_github_comments(M.current, 0)
end

--- Focus the window in the current tab whose diff buffer matches `side`, so the very
--- next keypress (`<CR>` to expand, `<leader>p` for actions) acts on the thread the
--- caller just navigated to. Diffview's own jump leaves the cursor in the LEFT pane
--- regardless of the requested side.
---@param side string|nil "LEFT"|"RIGHT"
---@param file string|nil  only focus once this file is the one on screen
---@return boolean focused
local function focus_side(side, file)
  local ok, diff = pcall(require, "review.ui.diff")
  if not ok then return false end
  local want = side == "LEFT" and "LEFT" or "RIGHT"
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local ctx = diff.buffer_context(vim.api.nvim_win_get_buf(win))
    if ctx and ctx.side == want and (not file or ctx.file == file) then
      vim.api.nvim_set_current_win(win)
      return true
    end
  end
  return false
end

M._focus_side = focus_side

--- Jump to a thread's anchor AND land in the pane that actually holds its marker.
---@param root table
function M.jump_to_thread(root)
  if not root then return end
  local ok, dv = pcall(require, "diffview")
  if not ok or not dv.open_review_location then return end
  -- Diffview's own jump can throw (an out-of-range cursor on the empty side of an
  -- added file, for one). Unguarded, that surfaces as a blocking hit-enter prompt
  -- and the navigation is simply lost; we place the cursor ourselves below anyway.
  local jumped, jump_err = pcall(dv.open_review_location,
    { path = root.file, side = root.side, line = root.line_start })
  if not jumped then
    require("review.perf").record("jump", "open_review_location", 0, false)
    vim.notify("diffview could not jump there; falling back: " .. tostring(jump_err),
      vim.log.levels.DEBUG)
  end
  -- Diffview swaps the entry's buffers asynchronously, so the window that will hold
  -- this thread may not exist yet. Retry briefly rather than focusing whatever pane
  -- happens to be current on the first tick.
  local function settle(attempt)
    if not M.current then return end
    if focus_side(root.side, root.file) then
      require("review.ui.diff").refresh_markers(M.current.store)
      -- Put the cursor on the thread's own line in that pane.
      local ctx = require("review.ui.diff").context()
      if ctx and root.line_start then
        local count = vim.api.nvim_buf_line_count(0)
        pcall(vim.api.nvim_win_set_cursor, 0, { math.min(root.line_start, count), 0 })
      end
      return
    end
    if attempt < 12 then
      vim.defer_fn(function() settle(attempt + 1) end, 40)
    end
  end
  vim.schedule(function() settle(1) end)
end

--- Reply to the thread under the cursor.
function M.reply_thread(root, on_done)
  local compose = require("review.ui.compose")
  if not M.current or not root then return end
  compose.open({
    title = "Reply",
    on_submit = function(body, is_sugg, sugg)
      local reply = M.current.store:reply(root.id, body, { suggestion_text = is_sugg and sugg or nil })
      if root.github_thread_id and M.current.source:kind() == "pr" then
        local started = vim.uv.hrtime()
        util.progress("Posting reply to GitHub…")
        local gid, err = require("review.util.gh").reply_thread(root.github_thread_id, body,
          M.current.source:metadata().repo_root)
        if gid then
          M.current.store:update(reply.id, { github_id = gid, origin = "github", status = "published" })
          util.notify(string.format("Reply posted to GitHub · %.1fs", (vim.uv.hrtime() - started) / 1e9))
        else
          util.notify("reply kept as draft: " .. tostring(err), vim.log.levels.WARN)
        end
      end
      M.notify_change()
      if on_done then on_done(reply) end
    end,
  })
end

function M.reply_at_cursor()
  local ctx = ctx_or_warn()
  if not ctx then return end
  local root = require("review.ui.markers").thread_at_cursor(M.current.store, ctx.file, ctx.side, ctx.line)
  if not root then util.notify("no thread on this line", vim.log.levels.INFO); return end
  M.reply_thread(root)
end

function M.resolve_thread(root, on_done)
  if not M.current or not root then return false end
  local resolved = root.status ~= "resolved"
  M.current.store:set_resolved(root.id, resolved)
  if root.github_thread_id and M.current.source:kind() == "pr" then
    local started = vim.uv.hrtime()
    util.progress((resolved and "Resolving" or "Reopening") .. " GitHub thread…")
    local ok, err = require("review.util.gh").resolve_thread(root.github_thread_id, resolved,
      M.current.source:metadata().repo_root)
    if not ok then
      M.current.store:set_resolved(root.id, not resolved)
      util.notify("GitHub resolve failed: " .. tostring(err), vim.log.levels.WARN)
      return false
    end
    util.notify(string.format("GitHub thread %s · %.1fs", resolved and "resolved" or "reopened",
      (vim.uv.hrtime() - started) / 1e9))
  else
    -- Local sources have no upstream to report on, but silence made resolving feel
    -- like nothing happened unless the sign was already on screen.
    local open = 0
    for _, other in ipairs(M.current.store:all_threads()) do
      if other.status ~= "resolved" then open = open + 1 end
    end
    util.notify(string.format("thread %s · %d open", resolved and "resolved" or "reopened", open))
  end
  M.notify_change()
  if on_done then on_done(root) end
  return true
end

--- Resolve/unresolve the thread under the cursor.
function M.resolve_at_cursor()
  local markers = require("review.ui.markers")
  local ctx = ctx_or_warn()
  if not ctx then
    return
  end
  local root = markers.thread_at_cursor(M.current.store, ctx.file, ctx.side, ctx.line)
  if not root then
    return
  end
  M.resolve_thread(root)
end

--- Delete the thread under the cursor (with confirm).
function M.delete_at_cursor()
  local markers = require("review.ui.markers")
  local ctx = ctx_or_warn()
  if not ctx then
    return
  end
  local root = markers.thread_at_cursor(M.current.store, ctx.file, ctx.side, ctx.line)
  if not root then
    return
  end
  require("review.ui.menu").confirm("Delete this thread?", "Delete", function()
    M.current.store:delete(root.id)
    M.notify_change()
  end)
end

--- Open the current diff file at the source head in a worktree tab.
function M.open_at_commit(new_tab)
  local ctx = ctx_or_warn()
  if not ctx then
    return
  end
  local meta = M.current.source:metadata()
  require("review.worktree").open(meta.repo_root, M.current.source:head_rev(), ctx.file, { tab = new_tab ~= false })
end

function M.toggle_viewed()
  local ctx = ctx_or_warn()
  if not ctx then return end
  local now = M.current.store:set_viewed(ctx.file, not M.current.store:is_viewed(ctx.file))
  local viewed, total = M.current.store:viewed_progress()
  M.notify_change()
  util.notify(string.format("%s · %d/%d files reviewed", now and "marked viewed" or "marked unread", viewed, total))
end

function M.navigate_thread(delta, unresolved_only)
  local roots = M.current and M.current.store:all_threads() or {}
  roots = vim.tbl_filter(function(root) return not unresolved_only or root.status ~= "resolved" end, roots)
  table.sort(roots, function(a, b)
    if a.file ~= b.file then return (a.file or "") < (b.file or "") end
    return (a.line_start or 0) < (b.line_start or 0)
  end)
  if #roots == 0 then util.notify("no matching threads", vim.log.levels.INFO); return end
  local ctx = require("review.ui.diff").context()
  local idx = delta > 0 and 0 or 1
  for i, root in ipairs(roots) do
    if ctx and root.file == ctx.file and (root.line_start or 0) >= (ctx.line or 0) then idx = i; break end
  end
  idx = ((idx - 1 + delta) % #roots) + 1
  M.jump_to_thread(roots[idx])
end

--- Toggle the comments side-panel for the current file.
function M.toggle_comments_panel(force_open)
  local diff = require("review.ui.diff")
  local panel = require("review.ui.comments_panel")
  local ctx = diff.context()
  local side = ctx and ctx.side or "RIGHT"
  local file = ctx and ctx.file or nil
  if force_open then
    panel.open(M.current.store, file, side, M.jump_to_thread)
  else
    -- An explicit toggle is the user's call: a later resize must not undo it.
    M._panel_hidden_by_resize = false
    panel.toggle(M.current.store, file, side, M.jump_to_thread)
  end
end

--- Add a comment (or suggestion) on the current line/selection.
---@param suggestion boolean|nil
function M.add_comment_here(suggestion)
  local ctx = ctx_or_warn()
  if not ctx then
    return
  end
  require("review.ui.diff").add_comment(M.current.store, { suggestion = suggestion })
end

--- Copy the thread under the cursor to the clipboard as markdown.
function M.copy_thread_at_cursor()
  local markers = require("review.ui.markers")
  local ctx = ctx_or_warn()
  if not ctx then
    return
  end
  local root = markers.thread_at_cursor(M.current.store, ctx.file, ctx.side, ctx.line)
  if not root then
    util.notify("no thread on this line", vim.log.levels.INFO)
    return
  end
  local lines = { string.format("%s:%d — %s", root.file, root.line_start or 0, root.author or "") }
  table.insert(lines, root.body)
  for _, r in ipairs(M.current.store:replies(root.id)) do
    table.insert(lines, string.format("↳ %s: %s", r.author or "", r.body))
  end
  local text = table.concat(lines, "\n")
  vim.fn.setreg("+", text)
  vim.fn.setreg('"', text)
  util.notify("thread copied")
end

--- Open the overview tab for the current review on demand.
function M.show_overview()
  M.open_workspace("Conversation")
end

function M.open_workspace(mode)
  if not M.current then
    return
  end
  local context = M.current
  require("review.ui.workspace").open(context.source, context.store, mode)
  M.bind_tab(vim.api.nvim_get_current_tabpage(), context)
end

--- Open the contextual action menu — the single key users learn.
function M.menu()
  local menu = require("review.ui.menu")
  -- No active review → choose the type of repository object to review.
  if not M.current then
    M.choose_source()
    return
  end

  local diff = require("review.ui.diff")
  local markers = require("review.ui.markers")
  local items = {}
  -- The menu is the whole discovery model, so it must not list actions that this
  -- source cannot perform: offering "Import GitHub comments" on a local commit only
  -- to answer "requires a PR" teaches users to distrust the menu.
  local caps = M.current.source:caps()
  local is_pr = M.current.source:kind() == "pr"

  local ctx = diff.context()
  if ctx then
    local thread = markers.thread_at_cursor(M.current.store, ctx.file, ctx.side, ctx.line)
    items[#items + 1] = { key = "c", label = "Comment on line / selection", fn = function() M.add_comment_here(false) end }
    items[#items + 1] = { key = "s", label = "Suggest change on line / selection", fn = function() M.add_comment_here(true) end }
    if thread then
      items[#items + 1] = { key = "r", label = "Reply to thread here", fn = M.reply_at_cursor }
      items[#items + 1] = {
        key = "x",
        label = (thread.status == "resolved") and "Unresolve thread" or "Resolve thread",
        fn = M.resolve_at_cursor,
      }
      items[#items + 1] = { key = "d", label = "Delete thread", fn = M.delete_at_cursor }
      items[#items + 1] = { key = "y", label = "Copy thread", fn = M.copy_thread_at_cursor }
      items[#items + 1] = { key = "A", label = "Ask Claude about this thread", fn = M.ask_claude_at_cursor }
      items[#items + 1] = { key = "z", label = "React to thread", fn = function() M.react_to_thread(thread) end }
      if thread.kind == "suggestion" or (thread.body or ""):find("```suggestion", 1, true) then
        items[#items + 1] = { key = "!", label = "Apply this suggestion to the working tree",
          fn = function() M.apply_suggestion(thread) end }
      end
    end
    items[#items + 1] = {
      key = "v",
      label = M.current.store:is_viewed(ctx.file) and "Mark file unread" or "Mark file viewed",
      fn = M.toggle_viewed,
    }
    items[#items + 1] = { key = "o", label = "Open file @ commit (worktree)", fn = M.open_at_commit }
  end

  -- Review-level actions.
  items[#items + 1] = { sep = "review" }
  items[#items + 1] = { key = "C", label = "Claude review (async)…", fn = M.claude_review }
  items[#items + 1] = { key = "a", label = "Open/toggle agent chat", fn = M.toggle_chat }
  items[#items + 1] = { key = "Y", label = "Edit, copy, or run final prompt", fn = M.copy_prompt }
  items[#items + 1] = { key = "S", label = "Sync latest Claude findings", fn = M.sync_claude_result }
  items[#items + 1] = { key = "R", label = "Claude review sessions", fn = M.claude_sessions }
  items[#items + 1] = {
    key = "f",
    label = is_pr and "Refresh PR, checks, and comments" or "Refresh commits and files",
    fn = M.refresh,
  }
  if caps.has_threads then
    items[#items + 1] = { key = "i", label = "Import GitHub comments", fn = M.import_github_comments }
  end
  if caps.can_submit then
    items[#items + 1] = { key = "p", label = "Publish review (verdict + drafts)…",
      fn = function() M.publish_threads() end }
  end
  items[#items + 1] = { key = "Q", label = "Export threads to quickfix", fn = M.threads_to_quickfix }
  items[#items + 1] = { key = "O", label = "Review workspace (Conversation / Timeline / Claude / Comments / Diff)", fn = M.show_overview }
  items[#items + 1] = { key = "P", label = "Toggle comments panel", fn = M.toggle_comments_panel }
  items[#items + 1] = { key = "L", label = "Choose another review target", fn = M.choose_source }
  items[#items + 1] = { key = "W", label = "Prune review worktrees", fn = M.clean }
  items[#items + 1] = { key = "?", label = "Help and key reference", fn = M.help }

  menu.open(items, { title = "Review · " .. util.truncate(M.current.source:title(), 48) })
end

function M.choose_source()
  require("review.ui.menu").open({
    { key = "p", label = "Pull request", fn = M.open_pull_requests },
    { key = "b", label = "Local branch", fn = M.open_branches },
    { key = "c", label = "Single commit", fn = M.open_commits },
    { key = "h", label = "Current branch against its base", fn = M.open_current },
    { key = "l", label = "Combined PR / branch browser", fn = M.open_list },
    { key = "?", label = "Help and key reference", fn = M.help },
  }, { title = "Review target" })
end

function M.help()
  require("review.ui.help").open()
end

--- Show per-file review state in Diffview's file panel.
---
--- Viewed state and thread counts were only visible in review.nvim's own windows,
--- while the file tree is where a reviewer actually decides what to open next.
--- Registered once; it reads M.current on every draw, so it follows the review.
local function register_file_decorator()
  local ok, dv_review = pcall(require, "diffview.review_api")
  if not ok or not dv_review.register_file_decorator then
    return false
  end
  dv_review.register_file_decorator("review.nvim", function(path)
    local current = M.current
    if not current then return nil end
    local store = current.store
    local parts = {}
    if store:is_viewed(path) then
      parts[#parts + 1] = { text = "\u{2713}", hl = "DiffviewFilePanelInsertions" }
    end
    local open, resolved = 0, 0
    for _, root in ipairs(store:threads_for_file(path)) do
      if root.status == "resolved" then resolved = resolved + 1 else open = open + 1 end
    end
    if open > 0 then
      parts[#parts + 1] = { text = "\u{1F4AC}" .. open, hl = "DiffviewFilePanelConflicts" }
    elseif resolved > 0 then
      parts[#parts + 1] = { text = "\u{2713}" .. resolved, hl = "DiffviewFilePanelInsertions" }
    end
    return parts
  end)
  return true
end

M._register_file_decorator = register_file_decorator

--- Open a review for a source argument (PR number/url, branch, or ".").
---@param arg string|integer|table|nil
---@param opts table|nil { base=string }
--- Finish opening a review once its Source exists.
---@param source table
---@param started integer  hrtime at the start of the open
local function realize_review(source, started)
  local Store = require("review.comments.store")
  local store = Store.for_source(source)
  store:reanchor(rename_map(source))

  local files = source:files()
  if #files == 0 then
    -- An empty review used to open two blank panes with no explanation at all.
    local hint = source:kind() == "branch"
      and " — the branch matches its base. Uncommitted work is not part of a branch review."
      or ""
    util.notify("Nothing to review in " .. source:title() .. hint, vim.log.levels.WARN)
    return
  end

  if config.get().workspace.dedicated_tab then vim.cmd("tabnew") end
  M.current = { source = source, store = store }
  M.bind_tab(vim.api.nvim_get_current_tabpage(), M.current)

  -- Every PR open performs a fresh, read-only GitHub thread fetch. Existing
  -- store entries are retained if GitHub is temporarily unavailable.
  local imported, refreshed = 0, 0
  if source:caps().has_threads then
    source._threads = nil
    local import_err
    imported, import_err, refreshed = require("review.comments.github_sync").import(source, store)
    if import_err then util.notify("GitHub comments were not imported: " .. tostring(import_err), vim.log.levels.WARN) end
  end

  -- The diff is the ONE default surface (diffview + inline comments). The workspace
  -- tab and comments panel are opt-in via the menu (<leader>p → O / P).
  require("review.ui.diff").open(source)
  vim.defer_fn(function() sync_diffview_github_comments(M.current, 0) end, 50)

  if config.get().workspace.comments and vim.o.columns >= config.get().workspace.comments_min_columns then
    vim.schedule(function()
      if M.current then M.toggle_comments_panel(true) end
    end)
  end

  util.notify(string.format("Review opened · %s · %d files · %d comments (%d new, %d updated) · %.1fs · <leader>p for actions",
    source:title(), #files, vim.tbl_count(store.comments), imported or 0, refreshed or 0,
    (vim.uv.hrtime() - started) / 1e9))
end

M._realize_review = realize_review

--- Open a review for a source argument (PR number/url, branch, or ".").
---@param arg string|integer|table|nil
---@param opts table|nil { base=string, cwd=string }
function M.open(arg, opts)
  opts = vim.tbl_extend("force", { base = config.get().local_base }, opts or {})
  local started = vim.uv.hrtime()
  local cwd = opts.cwd or vim.fn.getcwd()
  local Source = require("review.source")

  -- Building a PR Source shells out to `gh pr view` and `git fetch`, which on a cold
  -- cache blocked the editor for tens of seconds with no feedback. Yield first so the
  -- progress notice actually paints, and animate while the work runs.
  local heavy = type(arg) == "number" or (type(arg) == "string" and arg:match("%d"))
  if not heavy then
    util.progress("Opening review…")
    local source, err = Source.create(arg, cwd, opts)
    if not source then
      util.notify("cannot open review: " .. tostring(err), vim.log.levels.ERROR)
      return
    end
    realize_review(source, started)
    return
  end

  local spinner = util.spinner("Fetching pull request metadata and refs…")
  vim.defer_fn(function()
    local source, err = Source.create(arg, cwd, opts)
    spinner.stop()
    if not source then
      util.notify("cannot open review: " .. tostring(err), vim.log.levels.ERROR)
      return
    end
    realize_review(source, started)
  end, 30)
end

--- Open a review after asking which base to diff against (branch sources only).
---@param arg string|integer|table|nil
function M.open_with_base(arg)
  local cwd = vim.fn.getcwd()
  local git = require("review.util.git")
  local choices = { "auto (merge-base with " .. git.default_branch(cwd) .. ")" }
  local refs = {}
  -- `%(symref)` is non-empty for symbolic refs such as refs/remotes/origin/HEAD,
  -- whose short name is a bare remote ("origin") and is not a base anyone means.
  local ok, out = require("review.util.proc").git(
    { "for-each-ref", "--format=%(refname:short)\t%(symref)", "refs/heads/", "refs/remotes/" }, cwd)
  if ok then
    for line in vim.gsplit(out, "\n", { trimempty = true }) do
      local name, symref = line:match("^([^\t]*)\t?(.*)$")
      if name and name ~= "" and symref == "" and not name:match("/HEAD$") then
        refs[#refs + 1] = name
      end
    end
  end
  table.sort(refs)
  vim.list_extend(choices, refs)
  table.insert(choices, 2, "Enter a ref…")
  util.select(choices, { prompt = "Diff against which base?" }, function(choice)
    if not choice then return end
    if choice == "Enter a ref…" then
      vim.ui.input({ prompt = "Base ref: " }, function(value)
        if value and value ~= "" then M.open(arg, { base = value }) end
      end)
      return
    end
    M.open(arg, { base = choice:match("^auto") and "auto" or choice })
  end)
end

--- Open the fuzzy source picker.
function M.open_list()
  require("review.ui.list").open(vim.fn.getcwd(), {}, function(item)
    M.open(item.arg)
  end)
end

local function choose_with(open_picker)
  open_picker(vim.fn.getcwd(), function(item) M.open(item.arg) end)
end

function M.open_pull_requests()
  choose_with(require("review.ui.list").open_prs)
end

function M.open_branches()
  choose_with(require("review.ui.list").open_branches)
end

function M.open_commits()
  choose_with(require("review.ui.list").open_commits)
end

function M.open_current()
  M.open(".")
end

function M.refresh()
  if not M.current then return end
  if M._refreshing then util.notify("A review refresh is already running", vim.log.levels.INFO); return end
  M._refreshing = true
  local current, started = M.current, vim.uv.hrtime()
  local old = current.source
  local before_threads, before_head = #current.store:all_threads(), old:head_rev()
  local ctx = require("review.ui.diff").context()
  local arg
  if old:kind() == "pr" then arg = old.number
  elseif old:kind() == "commit" then arg = { kind = "commit", rev = old.rev }
  else arg = old.branch end
  local Source = require("review.source")
  util.progress("Refreshing metadata, commits, checks, and threads…")
  local old_meta = old:metadata()
  local refresh_base = old:kind() == "branch" and (old_meta.requested_base or "auto") or old.base_ref
  vim.defer_fn(function()
    local fresh, err = Source.create(arg, old_meta.repo_root, { base = refresh_base })
    M._refreshing = false
    if M.current ~= current then return end
    if not fresh then
      util.notify("Refresh failed: " .. tostring(err), vim.log.levels.ERROR)
      return
    end
    current.source, current.store.source = fresh, fresh
    if fresh:caps().has_threads then require("review.comments.github_sync").import(fresh, current.store) end
    current.store:reanchor(rename_map(fresh))
    require("review.ui.diff").refresh_markers(current.store)
    sync_diffview_github_comments(current, 0)
    if ctx then require("diffview").open_review_location({ path = ctx.file, side = ctx.side, line = ctx.line }) end
    local new_threads = #current.store:all_threads() - before_threads
    util.notify(string.format("Refreshed · head %s · %s%d new thread%s · %.1fs",
      before_head == fresh:head_rev() and "unchanged" or ("advanced to " .. fresh:head_rev():sub(1, 8)),
      new_threads >= 0 and "+" or "", new_threads, math.abs(new_threads) == 1 and "" or "s",
      (vim.uv.hrtime() - started) / 1e9))
  end, 20)
end

--- Repair a store that holds two local records for one upstream comment.
function M.dedupe_threads()
  if not M.current then util.notify("open a review first", vim.log.levels.WARN); return end
  local removed = M.current.store:dedupe_github()
  M.notify_change()
  util.notify(removed > 0
    and string.format("merged %d duplicate thread%s", removed, removed == 1 and "" or "s")
    or "no duplicate threads found")
end

function M.import_github_comments()
  if not M.current or M.current.source:kind() ~= "pr" then
    util.notify("GitHub comment import requires a PR", vim.log.levels.WARN); return
  end
  local current, started = M.current, vim.uv.hrtime()
  current.source._threads = nil
  util.progress("Importing GitHub review comments…")
  vim.defer_fn(function()
    if M.current ~= current then return end
    local imported, err, refreshed = require("review.comments.github_sync").import(current.source, current.store)
    if err then
      util.notify("GitHub comment import failed: " .. tostring(err), vim.log.levels.ERROR)
      return
    end
    require("review.ui.diff").refresh_markers(current.store)
    sync_diffview_github_comments(current, 0)
    if require("review.ui.comments_panel").is_open() then
      require("review.ui.comments_panel").render(current.store, nil, "RIGHT")
    end
    local elapsed = (vim.uv.hrtime() - started) / 1e9
    util.notify(string.format("GitHub comments imported · %d new · %d updated · %.1fs",
      imported, refreshed or 0, elapsed))
  end, 20)
end

---Recover/import the latest Claude result from its persisted Sidekick transcript.
---Useful when an older live poller saw terminal-reflowed JSON and could not parse it.
function M.sync_claude_result()
  if not M.current then util.notify("open a review first", vim.log.levels.WARN); return end
  local started = vim.uv.hrtime()
  util.progress("Synchronizing Claude transcript and inline findings…")
  local sessions = vim.tbl_values(M.current.store.sessions or {})
  table.sort(sessions, function(a, b) return (a.started_at or "") > (b.started_at or "") end)
  local session = sessions[1]
  if not session then util.notify("no Claude review session to synchronize", vim.log.levels.INFO); return end
  session.replied, session.findings = session.replied or {}, session.findings or {}
  local sidekick = require("review.sidekick")
  local source = "transcript"
  local text = sidekick.transcript_result(
    M.current.source, session.cwd or M.current.source:metadata().repo_root)
  if not text or text == "" then
    -- No persisted transcript. Say why, then try the terminal the agent is still
    -- sitting in rather than reporting a bare "empty result".
    local reason = sidekick.transcript_unavailable_reason()
    text = sidekick.terminal_text(session)
    source = "terminal"
    if not text or text == "" then
      util.notify("no Claude output to synchronize"
        .. (reason and (" — " .. reason) or " — the transcript is empty and no agent terminal is open"),
        vim.log.levels.ERROR)
      return
    end
    util.notify("no saved transcript"
      .. (reason and (" (" .. reason .. ")") or "")
      .. " — reading the agent terminal instead", vim.log.levels.WARN)
  end
  local findings, err = require("review.claude.contract").extract_findings(text)
  if not findings then
    util.notify(string.format("could not synchronize Claude findings from the %s: %s",
      source, tostring(err)), vim.log.levels.ERROR)
    return
  end
  require("review.sidekick").apply_findings(M.current.store, M.current.source, session, findings)
  session.state, session.progress = "done", "Findings imported from the " .. source
  session.error = nil
  M.current.store.sessions[session.id] = session
  M.current.store:save()
  require("review.ui.diff").refresh_markers(M.current.store)
  if session.diffview_applied then
    require("review.ui.comments_panel").close()
  else
    M.toggle_comments_panel(true)
  end
  util.notify(string.format("Claude review synchronized · %d findings · %d replies · %.1fs",
    #(session.findings or {}), #(session.replied or {}), (vim.uv.hrtime() - started) / 1e9))
end

function M.threads_to_quickfix(threads)
  if not M.current then return end
  threads = threads or M.current.store:all_threads()
  local repo_root = M.current.source:metadata().repo_root
  local items = {}
  for _, thread in ipairs(threads) do
    items[#items + 1] = {
      filename = vim.fs.joinpath(repo_root, thread.file), lnum = thread.line_start or 1,
      text = string.format("[%s/%s] %s: %s", thread.status or "draft", thread.origin or "local",
        thread.author or "?", (thread.body or ""):gsub("\n", " ")),
      user_data = { review_thread = thread },
    }
  end
  vim.fn.setqflist({}, "r", { title = "Review threads · " .. M.current.source:title(), items = items })
  vim.cmd("copen")
  local qfbuf = vim.api.nvim_get_current_buf()
  vim.keymap.set("n", "<CR>", function()
    local qf = vim.fn.getqflist({ idx = 0, items = 0 })
    local item = qf.items[qf.idx]
    local thread = item and item.user_data and item.user_data.review_thread
    if thread then
      vim.cmd("cclose")
      M.jump_to_thread(thread)
    end
  end, { buffer = qfbuf, desc = "open review thread in diff" })
end

local function open_final_prompt(instruction, allow_edits, threads)
  local sidekick = require("review.sidekick")
  local prompt = sidekick.prompt(M.current.source, M.current.store, {
    instruction = instruction, allow_edits = allow_edits,
    auto_resolve = config.get().claude.auto_resolve, threads = threads,
  })
  require("review.ui.prompt").open(prompt, { on_run = function(final)
    local session, err = sidekick.run(M.current.source, M.current.store, final, {
      allow_edits = allow_edits,
      instruction = instruction,
      auto_resolve = config.get().claude.auto_resolve,
      on_progress = function() require("review.ui.diff").refresh_markers(M.current.store) end,
      on_done = function(done)
        require("review.ui.diff").refresh_markers(M.current.store)
        if done.diffview_applied then
          require("review.ui.comments_panel").close()
        elseif done.applied and (#(done.findings or {}) > 0 or #(done.replied or {}) > 0) then
          M.toggle_comments_panel(true)
        elseif require("review.ui.comments_panel").is_open() then
          require("review.ui.comments_panel").render(M.current.store, nil, "RIGHT")
        end
      end,
    })
    if not session then
      util.notify("review session failed: " .. tostring(err), vim.log.levels.ERROR)
    else
      M.current.sidekick = session
      util.notify("review agent started · open Chat to follow progress")
    end
  end })
end

function M.ask_claude_at_cursor()
  local ctx = ctx_or_warn()
  if not ctx then return end
  local root = require("review.ui.markers").thread_at_cursor(
    M.current.store, ctx.file, ctx.side, ctx.line)
  if not root then
    util.notify("no thread on this line", vim.log.levels.INFO)
    return
  end
  open_final_prompt("Assess this review thread and address it directly.", false, { root })
end

function M.ask_claude_threads(threads)
  if not M.current or not threads or #threads == 0 then return end
  open_final_prompt(string.format("Assess and address these %d selected review threads.", #threads), false, threads)
end

function M.publish_threads(threads)
  if not M.current or M.current.source:kind() ~= "pr" then
    util.notify("publishing requires a GitHub PR", vim.log.levels.WARN); return
  end
  local store = M.current.store
  local drafts = vim.tbl_filter(function(root)
    return root.status == "draft" and not root.github_id and not root.in_reply_to
  end, threads or store:all_threads())
  local review = store:review_draft()
  if #drafts == 0 and vim.trim(review.body or "") == "" and (review.event or "COMMENT") == "COMMENT" then
    util.notify("nothing to publish: no drafts, no summary, no verdict", vim.log.levels.INFO)
    return
  end
  local comments = {}
  for _, root in ipairs(drafts) do
    local first = root.line_start or 1
    local last = root.line_end or first
    local side = root.side or "RIGHT"
    local comment = { path = root.file, line = math.max(first, last), side = side, body = root.body }
    -- GitHub anchors a multi-line comment with start_line/start_side; without them a
    -- deliberate 10-15 line selection silently posted on line 15 alone.
    if last > first then
      comment.start_line = first
      comment.start_side = side
    end
    comments[#comments + 1] = comment
  end
  local src, meta = M.current.source, M.current.source:metadata()
  local gh = require("review.util.gh")
  local self_review = gh.viewer(meta.repo_root) == src:author()
  local payload = {
    commit_id = src:head_rev(),
    event = review.event or "COMMENT",
    body = review.body or "",
    comments = comments,
    self_review = self_review,
  }
  --- Attach remote ids back to the local drafts by LOCATION, never by array index:
  --- GitHub does not promise the response preserves request order.
  ---@param current table
  ---@param remotes table[]
  ---@return integer matched
  local function attach_ids(current, remotes)
    local buckets = {}
    for _, remote in ipairs(remotes or {}) do
      local key = string.format("%s:%s:%s", remote.path or "",
        tostring(remote.line or remote.original_line or ""), remote.side or "RIGHT")
      buckets[key] = buckets[key] or {}
      table.insert(buckets[key], remote)
    end
    local matched = 0
    for _, root in ipairs(drafts) do
      local key = string.format("%s:%s:%s", root.file,
        tostring(root.line_end or root.line_start), root.side or "RIGHT")
      local bucket = buckets[key]
      local remote = bucket and table.remove(bucket, 1) or nil
      if remote then matched = matched + 1 end
      current.store:update(root.id, {
        status = "published", origin = "github",
        github_id = remote and (remote.node_id or tostring(remote.id)) or root.github_id,
      })
    end
    return matched
  end

  --- Build the review one thread at a time through GraphQL. A single REST call
  --- carrying dozens of comments is rejected with an opaque 500, so anything past a
  --- handful goes through the same pending-review flow GitHub's own UI uses.
  ---@param current table
  ---@param started integer
  local function publish_incrementally(current, started)
    local gh_api = require("review.util.gh")
    local pr_id = src._pr and src._pr.id
    if not pr_id then
      util.notify("this PR has no node id; refresh the review and try again", vim.log.levels.ERROR)
      return
    end
    local review_id, err = gh_api.start_pending_review(pr_id, meta.repo_root)
    if not review_id then
      util.notify("could not start the review: " .. tostring(err), vim.log.levels.ERROR)
      return
    end
    local index, failed = 0, {}
    local function finish()
      if #failed == #comments then
        gh_api.discard_pending_review(review_id, meta.repo_root)
        util.notify("no comments could be added; the pending review was discarded",
          vim.log.levels.ERROR)
        return
      end
      local ok, submit_err = gh_api.submit_pending_review(review_id, payload.event, payload.body,
        meta.repo_root)
      if not ok then
        util.notify(("review left pending on GitHub: %s"):format(tostring(submit_err)),
          vim.log.levels.ERROR)
        return
      end
      current.store:set_review_draft({ event = "COMMENT", body = "" })
      for _, root in ipairs(drafts) do
        current.store:update(root.id, { status = "published", origin = "github" })
      end
      util.notify(string.format("Published %s · %d comment%s%s · %.1fs", payload.event,
        #comments - #failed, (#comments - #failed) == 1 and "" or "s",
        #failed > 0 and (" · " .. #failed .. " rejected") or "",
        (vim.uv.hrtime() - started) / 1e9),
        #failed > 0 and vim.log.levels.WARN or nil)
      M.refresh()
    end
    -- One at a time, off the main loop, so the editor stays usable and GitHub's
    -- secondary rate limiter is not tripped by a burst.
    local function step()
      if M.current ~= current then return end
      index = index + 1
      if index > #comments then
        finish()
        return
      end
      util.progress(string.format("Publishing comment %d/%d…", index, #comments))
      local ok, add_err = gh_api.add_pending_thread(review_id, comments[index], meta.repo_root)
      if not ok then
        if gh_api.is_rate_limited(add_err) then
          util.notify("GitHub is rate limiting; retrying in 30s", vim.log.levels.WARN)
          index = index - 1
          vim.defer_fn(step, 30000)
          return
        end
        failed[#failed + 1] = index
      end
      vim.defer_fn(step, 120)
    end
    step()
  end

  require("review.ui.publish").open(payload, drafts, function()
    local current, started = M.current, vim.uv.hrtime()
    -- self_review is a preview hint, not part of GitHub's schema.
    local wire = vim.deepcopy(payload)
    wire.self_review = nil
    if #comments > config.get().publish_batch_limit then
      util.progress(string.format("Publishing %d comments one at a time…", #comments))
      publish_incrementally(current, started)
      return
    end
    util.progress(string.format("Publishing %s with %d comment%s…",
      payload.event, #drafts, #drafts == 1 and "" or "s"))
    vim.defer_fn(function()
      if M.current ~= current then return end
      local gh_api = require("review.util.gh")
      local result, err = gh_api.submit_review(
        meta.owner, meta.repo, meta.number, wire, meta.repo_root)
      if not result then
        -- GitHub can create the review and STILL answer with an error (a 500 after a
        -- large submission is the common case). Reporting a plain failure left every
        -- draft unpublished, and the obvious retry would post all of them twice — so
        -- ask GitHub what actually landed before believing the error.
        local landed, merged = M.reconcile_published(current, drafts)
        if landed > 0 then
          util.notify(string.format(
            "GitHub reported an error, but %d/%d comment%s did land — marked published%s, not retried",
            landed, #drafts, landed == 1 and "" or "s",
            merged > 0 and (" (" .. merged .. " merged with the imported copy)") or ""),
            vim.log.levels.WARN)
          current.store:set_review_draft({ event = "COMMENT", body = "" })
          M.refresh()
          return
        end
        util.notify("publish failed: " .. tostring(err), vim.log.levels.ERROR)
        return
      end
      local matched = attach_ids(current, type(result.comments) == "table" and result.comments or {})
      -- The submission is spent; the next review starts from a clean summary.
      current.store:set_review_draft({ event = "COMMENT", body = "" })
      local unmatched = #drafts - matched
      util.notify(string.format("Published %s · %d comment%s%s · %.1fs", payload.event, #drafts,
        #drafts == 1 and "" or "s",
        unmatched > 0 and (" · " .. unmatched .. " could not be matched back") or "",
        (vim.uv.hrtime() - started) / 1e9),
        unmatched > 0 and vim.log.levels.WARN or nil)
      M.refresh()
    end, 20)
  end, {
    self_review = self_review,
    on_change = function(updated)
      store:set_review_draft({ event = updated.event, body = updated.body })
    end,
  })
end

--- Ask GitHub which of `drafts` already exist upstream, and mark those published.
---
--- Used after a failed submit: the API is not reliably all-or-nothing, so the only
--- safe answer to "did that work?" is to look.
---@param current table
---@param drafts table[]
---@return integer landed
function M.reconcile_published(current, drafts)
  local meta = current.source:metadata()
  local remote = require("review.util.gh").list_review_comments(
    meta.owner, meta.repo, meta.number, meta.repo_root)
  if #remote == 0 then return 0 end
  local index = {}
  for _, comment in ipairs(remote) do
    -- Body is the discriminator: two drafts can share a location, but the text a
    -- reviewer wrote is what identifies their comment.
    index[vim.trim(comment.body or "")] = comment
  end
  -- Upstream ids already represented in the store, so a draft is not relabelled into
  -- a second local record for a comment the importer has already created.
  local claimed = {}
  for _, thread in ipairs(current.store:all_threads()) do
    if thread.github_id then claimed[thread.github_id] = thread.id end
  end
  local landed, merged = 0, 0
  for _, root in ipairs(drafts) do
    local match = index[vim.trim(root.body or "")]
    if match and not root.github_id then
      local gid = match.node_id or tostring(match.id)
      landed = landed + 1
      if claimed[gid] and claimed[gid] ~= root.id then
        -- The importer already holds this comment: the local draft is the same text
        -- twice over, so drop it rather than leaving a duplicate thread on the line.
        current.store:delete(root.id)
        merged = merged + 1
      else
        claimed[gid] = root.id
        current.store:update(root.id, {
          status = "published", origin = "github", github_id = gid,
        })
      end
    end
  end
  return landed, merged
end

--- Write a thread's suggestion into the working tree.
---
--- Suggestions could be authored and rendered but never applied, so an incoming
--- ```suggestion block was read-only advice. Writes to the working tree only; the
--- reviewed revision itself is never touched.
---@param root table
function M.apply_suggestion(root)
  if not M.current or not root then return end
  local text = root.suggestion_text
  if not text or text == "" then
    -- GitHub carries suggestions inside the comment body, not a dedicated field.
    text = (root.body or ""):match("```suggestion%s*\n(.-)```")
  end
  if not text or vim.trim(text) == "" then
    util.notify("this thread has no suggestion to apply", vim.log.levels.INFO); return
  end
  if root.side == "LEFT" then
    util.notify("suggestions apply to the new side only", vim.log.levels.WARN); return
  end
  local meta = M.current.source:metadata()
  local path = vim.fs.joinpath(meta.repo_root, root.file)
  if vim.fn.filereadable(path) == 0 then
    util.notify("file is not in the working tree: " .. root.file, vim.log.levels.WARN); return
  end
  local first = root.line_start or 1
  local last = root.line_end or first
  local replacement = vim.split(text:gsub("\n$", ""), "\n", { plain = true })
  require("review.ui.menu").confirm(
    string.format("Apply suggestion to %s:%d-%d?", root.file, first, last), "Apply", function()
      local lines = vim.fn.readfile(path)
      if last > #lines then
        util.notify("the file has changed; suggestion range is out of bounds", vim.log.levels.ERROR)
        return
      end
      local out = {}
      vim.list_extend(out, lines, 1, first - 1)
      vim.list_extend(out, replacement)
      vim.list_extend(out, lines, last + 1, #lines)
      vim.fn.writefile(out, path)
      vim.cmd("checktime")
      util.notify(string.format("applied suggestion to %s:%d-%d", root.file, first, last))
    end)
end

--- GitHub's ReactionContent enum, with the glyph a human actually recognises.
M.reactions = {
  { content = "THUMBS_UP", emoji = "\u{1F44D}", label = "thumbs up" },
  { content = "THUMBS_DOWN", emoji = "\u{1F44E}", label = "thumbs down" },
  { content = "LAUGH", emoji = "\u{1F604}", label = "laugh" },
  { content = "HOORAY", emoji = "\u{1F389}", label = "hooray" },
  { content = "CONFUSED", emoji = "\u{1F615}", label = "confused" },
  { content = "HEART", emoji = "\u{2764}", label = "heart" },
  { content = "ROCKET", emoji = "\u{1F680}", label = "rocket" },
  { content = "EYES", emoji = "\u{1F440}", label = "eyes" },
}

--- Add or REMOVE a reaction. This used to only ever increment, so pressing the key
--- twice invented a second reaction from the same person that GitHub would never
--- record; the picker also showed raw enum names and no current state.
---@param root table
function M.react_to_thread(root)
  if not root then return end
  local current = root.reactions or {}
  local items = {}
  for _, entry in ipairs(M.reactions) do
    local count = current[entry.content] or 0
    items[#items + 1] = vim.tbl_extend("force", entry, { count = count, mine = count > 0 })
  end
  util.select(items, {
    prompt = "React to thread (again to remove):",
    format_item = function(item)
      return string.format("%s %s%s", item.emoji, item.label,
        item.count > 0 and string.format("  · %d %s", item.count, "\u{2713}") or "")
    end,
  }, function(choice)
    if not choice then return end
    local add = not choice.mine
    if root.github_id then
      local ok, err = require("review.util.gh").react(root.github_id, choice.content, add,
        M.current.source:metadata().repo_root)
      if not ok then util.notify("reaction failed: " .. tostring(err), vim.log.levels.ERROR); return end
    end
    local reactions = vim.deepcopy(current)
    if add then
      reactions[choice.content] = (reactions[choice.content] or 0) + 1
    else
      reactions[choice.content] = nil
    end
    root.reactions = reactions
    M.current.store:update(root.id, { reactions = reactions })
    M.notify_change()
    util.notify(string.format("%s %s %s", add and "reacted" or "removed", choice.emoji, choice.label))
  end)
end

--- Kick off a Claude review of the current source.
function M.claude_review()
  if not M.current then
    util.notify("open a review first", vim.log.levels.WARN)
    return
  end
  local cfg = config.get().claude
  local names = vim.tbl_keys(cfg.saved_instructions or {})
  table.sort(names) -- pairs() order is arbitrary; a menu that reorders itself
                    -- between invocations never builds muscle memory
  table.insert(names, 1, "(none)")
  table.insert(names, 2, "Custom instructions…")
  util.select(names, { prompt = "Saved instruction profile:" }, function(choice)
    if not choice then return end
    local function permissions(instruction)
      util.select({ "Read-only review", "Allow edits in repository-local worktree" },
        { prompt = "Agent permissions:" }, function(permission)
        if permission then open_final_prompt(instruction, permission:match("^Allow") ~= nil) end
      end)
    end
    if choice == "Custom instructions…" then
      require("review.ui.compose").open({ title = "Custom review instructions", on_submit = function(body)
        permissions(body)
      end })
    else
      permissions(choice ~= "(none)" and cfg.saved_instructions[choice] or "")
    end
  end)
end

function M.copy_prompt()
  if M.current then open_final_prompt("", false) end
end

function M.toggle_chat()
  require("review.sidekick").toggle()
end

--- Show the Claude sessions list.
function M.claude_sessions()
  if not M.current then
    util.notify("open a review first", vim.log.levels.WARN)
    return
  end
  require("review.claude.session").list(M.current.store)
end

--- Prune managed worktrees for the current repo.
function M.clean()
  if not M.current then
    return
  end
  local meta = M.current.source:metadata()
  local removed, kept = require("review.worktree").prune(meta.repo_root)
  util.notify(string.format("worktrees: removed %d, kept %d (unpushed)", removed, kept))
end

--- Plugin setup.
---@param opts table|nil
function M.setup(opts)
  config.setup(opts)
  local km = config.get().keymaps

  -- The one global key: opens the contextual menu. Outside a review it offers
  -- "start a review"; inside one it shows the valid actions here.
  if km.menu then
    vim.keymap.set("n", km.menu, M.menu, { desc = "review: actions menu" })
  end

  register_file_decorator()

  local group = vim.api.nvim_create_augroup("ReviewNvim", { clear = true })

  -- Attach to diffview diff buffers when they enter a window (R2).
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = { "DiffviewDiffBufWinEnter", "DiffviewViewOpened" },
    callback = function(ev)
      vim.schedule(function()
        M._attach_diff_buffer(ev.buf or vim.api.nvim_get_current_buf())
      end)
    end,
  })
  -- Fallback for environments where the User events differ. _attach_diff_buffer
  -- self-guards (only attaches to genuine diff buffers), so this cannot leak.
  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = group,
    callback = function(ev)
      if M.current then
        M._attach_diff_buffer(ev.buf)
      end
    end,
  })

  -- The panel is hidden when the window gets too narrow to hold it — and brought
  -- back when there is room again. Closing without reopening meant one shrink lost
  -- the panel for the rest of the review, with nothing to say why.
  vim.api.nvim_create_autocmd("TabEnter", {
    group = group,
    callback = function()
      M.focus_tab()
    end,
  })

  vim.api.nvim_create_autocmd("VimResized", {
    group = group,
    callback = function()
      if not M.current then return end
      local panel = require("review.ui.comments_panel")
      local min = config.get().workspace.comments_min_columns
      if vim.o.columns < min then
        if panel.is_open() then
          M._panel_hidden_by_resize = true
          panel.close()
        end
      elseif M._panel_hidden_by_resize and not panel.is_open() then
        M._panel_hidden_by_resize = false
        M.toggle_comments_panel(true)
      end
    end,
  })

  -- Kill running Claude jobs on exit (R5).
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      require("review.claude.runner").kill_all()
      require("review.sidekick").kill_all()
    end,
  })
end

return M
