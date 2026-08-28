-- review.nvim :: public API + orchestration hub.

local config = require("review.config")
local util = require("review.util")

local M = {}

---@class ReviewContext
---@field source table
---@field store table
M.current = nil

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
    if ctx then
      markers.toggle_at_cursor(ctx.bufnr, store, ctx.file, ctx.side)
    end
  end, { buffer = bufnr, nowait = true, desc = "review: expand/collapse thread" })

  -- Render existing markers for this specific diff buffer.
  markers.render(attach_ctx.bufnr, store, attach_ctx.file, attach_ctx.side)
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

--- Reply to the thread under the cursor.
function M.reply_at_cursor()
  local markers = require("review.ui.markers")
  local compose = require("review.ui.compose")
  local ctx = ctx_or_warn()
  if not ctx then
    return
  end
  local root = markers.thread_at_cursor(M.current.store, ctx.file, ctx.side)
  if not root then
    util.notify("no thread on this line", vim.log.levels.INFO)
    return
  end
  compose.open({
    title = "Reply",
    on_submit = function(body, is_sugg, sugg)
      M.current.store:reply(root.id, body, { suggestion_text = is_sugg and sugg or nil })
      require("review.ui.diff").refresh_markers(M.current.store)
      if require("review.ui.comments_panel").is_open() then
        require("review.ui.comments_panel").render(M.current.store, ctx.file, ctx.side)
      end
    end,
  })
end

--- Resolve/unresolve the thread under the cursor.
function M.resolve_at_cursor()
  local markers = require("review.ui.markers")
  local ctx = ctx_or_warn()
  if not ctx then
    return
  end
  local root = markers.thread_at_cursor(M.current.store, ctx.file, ctx.side)
  if not root then
    return
  end
  M.current.store:set_resolved(root.id, root.status ~= "resolved")
  require("review.ui.diff").refresh_markers(M.current.store)
end

--- Delete the thread under the cursor (with confirm).
function M.delete_at_cursor()
  local markers = require("review.ui.markers")
  local ctx = ctx_or_warn()
  if not ctx then
    return
  end
  local root = markers.thread_at_cursor(M.current.store, ctx.file, ctx.side)
  if not root then
    return
  end
  if vim.fn.confirm("Delete this thread?", "&Yes\n&No", 2) == 1 then
    M.current.store:delete(root.id)
    require("review.ui.diff").refresh_markers(M.current.store)
  end
end

--- Open the current diff file at the source head in a worktree tab.
function M.open_at_commit()
  local ctx = ctx_or_warn()
  if not ctx then
    return
  end
  local meta = M.current.source:metadata()
  require("review.worktree").open(meta.repo_root, M.current.source:head_rev(), ctx.file)
end

--- Toggle the comments side-panel for the current file.
function M.toggle_comments_panel()
  local diff = require("review.ui.diff")
  local panel = require("review.ui.comments_panel")
  local ctx = diff.context()
  local file = ctx and ctx.file or nil
  local side = ctx and ctx.side or "RIGHT"
  panel.toggle(M.current.store, file, side, function(root)
    -- Jump into the diff window and expand the thread.
    diff.refresh_markers(M.current.store)
    util.notify(string.format("thread at %s:%d", root.file, root.line_start or 0))
  end)
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
  local root = markers.thread_at_cursor(M.current.store, ctx.file, ctx.side)
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
  if not M.current then
    return
  end
  local overview = require("review.ui.overview")
  vim.cmd("tabnew")
  local ov = overview.open(M.current.source, function(sha)
    require("review.ui.diff").open_commit(M.current.source, sha)
  end)
  vim.api.nvim_win_set_buf(0, ov.buf)
end

--- Open the contextual action menu — the single key users learn.
function M.menu()
  local menu = require("review.ui.menu")
  -- No active review → the only action is to start one.
  if not M.current then
    menu.open({
      { key = "l", label = "Start a review (pick PR / branch)", fn = M.open_list },
    }, { title = "Review" })
    return
  end

  local diff = require("review.ui.diff")
  local markers = require("review.ui.markers")
  local ft = vim.bo.filetype
  local items = {}

  local ctx = diff.context()
  if ctx then
    local thread = markers.thread_at_cursor(M.current.store, ctx.file, ctx.side)
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
    end
    items[#items + 1] = { key = "o", label = "Open file @ commit (worktree)", fn = M.open_at_commit }
  elseif ft == "review-overview" then
    -- Overview-specific hints (the buffer-local <CR>/s/<Tab> still work directly).
    items[#items + 1] = { key = "<CR>", label = "Open commit under cursor (also <CR>)", fn = function()
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "m", false)
    end }
  end

  -- Review-level actions, always available.
  items[#items + 1] = { sep = "review" }
  items[#items + 1] = { key = "C", label = "Claude review (async)…", fn = M.claude_review }
  items[#items + 1] = { key = "R", label = "Claude review sessions", fn = M.claude_sessions }
  items[#items + 1] = { key = "O", label = "Overview (description, commits, threads)", fn = M.show_overview }
  items[#items + 1] = { key = "P", label = "Toggle comments panel", fn = M.toggle_comments_panel }
  items[#items + 1] = { key = "L", label = "Switch to another PR / branch", fn = M.open_list }

  menu.open(items, { title = "Review · " .. M.current.source:title() })
end

--- Open a review for a source argument (PR number/url, branch, or ".").
---@param arg string|integer|nil
---@param opts table|nil { base=string }
function M.open(arg, opts)
  opts = opts or {}
  local Source = require("review.source")
  local source, err = Source.create(arg, opts.cwd or vim.fn.getcwd(), opts)
  if not source then
    util.notify("cannot open review: " .. tostring(err), vim.log.levels.ERROR)
    return
  end
  local Store = require("review.comments.store")
  local store = Store.for_source(source)
  store:reanchor(rename_map(source))

  M.current = { source = source, store = store }

  -- Import GitHub threads for PRs (best-effort).
  if source:caps().has_threads then
    pcall(function()
      require("review.comments.github_sync").import(source, store)
    end)
  end

  -- The diff is the ONE default surface (diffview + inline comments). The overview
  -- tab and comments panel are opt-in via the menu (<leader>p → O / P).
  require("review.ui.diff").open(source)

  util.notify(string.format("%s · %d comments · <leader>p for actions",
    source:title(), vim.tbl_count(store.comments)))
end

--- Open the fuzzy source picker.
function M.open_list()
  require("review.ui.list").open(vim.fn.getcwd(), {}, function(item)
    M.open(item.arg)
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
  table.insert(names, 1, "(none)")
  vim.ui.select(names, { prompt = "Saved instruction profile:" }, function(choice)
    local base = (choice and choice ~= "(none)") and cfg.saved_instructions[choice] or ""
    vim.ui.input({ prompt = "Review direction (major instruction): " }, function(extra)
      local instruction = util.trim((base .. "\n" .. (extra or "")))
      require("review.claude.runner").start({
        store = M.current.store,
        source = M.current.source,
        instruction = instruction,
        auto_resolve = cfg.auto_resolve,
        allow_edits = cfg.allow_edits,
        on_done = function()
          require("review.ui.diff").refresh_markers(M.current.store)
        end,
      })
      util.notify("Claude review started (async)")
    end)
  end)
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

  -- Kill running Claude jobs on exit (R5).
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      require("review.claude.runner").kill_all()
    end,
  })
end

return M
