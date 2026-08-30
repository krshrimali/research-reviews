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
      markers.toggle_at_cursor(ctx.bufnr, store, ctx.file, ctx.side, ctx.line)
    end
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
  pcall(vim.keymap.set, "n", "o", function() M.open_at_commit(false) end,
    { buffer = bufnr, desc = "review: open file at reviewed commit" })
  pcall(vim.keymap.set, "n", "O", function() M.open_at_commit(true) end,
    { buffer = bufnr, desc = "review: open file at reviewed commit in new tab" })
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

--- Reply to the thread under the cursor.
function M.reply_thread(root, on_done)
  local compose = require("review.ui.compose")
  if not M.current or not root then return end
  compose.open({
    title = "Reply",
    on_submit = function(body, is_sugg, sugg)
      local reply = M.current.store:reply(root.id, body, { suggestion_text = is_sugg and sugg or nil })
      if root.github_thread_id and M.current.source:kind() == "pr" then
        local gid, err = require("review.util.gh").reply_thread(root.github_thread_id, body,
          M.current.source:metadata().repo_root)
        if gid then
          M.current.store:update(reply.id, { github_id = gid, origin = "github", status = "published" })
        else
          util.notify("reply kept as draft: " .. tostring(err), vim.log.levels.WARN)
        end
      end
      require("review.ui.diff").refresh_markers(M.current.store)
      if require("review.ui.comments_panel").is_open() then
        require("review.ui.comments_panel").refresh()
      end
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
    local ok, err = require("review.util.gh").resolve_thread(root.github_thread_id, resolved,
      M.current.source:metadata().repo_root)
    if not ok then
      M.current.store:set_resolved(root.id, not resolved)
      util.notify("GitHub resolve failed: " .. tostring(err), vim.log.levels.WARN)
      return false
    end
  end
  require("review.ui.diff").refresh_markers(M.current.store)
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
  if vim.fn.confirm("Delete this thread?", "&Yes\n&No", 2) == 1 then
    M.current.store:delete(root.id)
    require("review.ui.diff").refresh_markers(M.current.store)
  end
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
  local root = roots[idx]
  require("diffview").open_review_location({ path = root.file, side = root.side, line = root.line_start })
end

--- Toggle the comments side-panel for the current file.
function M.toggle_comments_panel(force_open)
  local diff = require("review.ui.diff")
  local panel = require("review.ui.comments_panel")
  local ctx = diff.context()
  local side = ctx and ctx.side or "RIGHT"
  local function jump(root)
    local ok, dv = pcall(require, "diffview")
    if ok and dv.open_review_location then
      dv.open_review_location({ path = root.file, side = root.side, line = root.line_start })
    end
    diff.refresh_markers(M.current.store)
  end
  if force_open then panel.open(M.current.store, nil, side, jump) else panel.toggle(M.current.store, nil, side, jump) end
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
  -- No active review → choose the type of repository object to review.
  if not M.current then
    M.choose_source()
    return
  end

  local diff = require("review.ui.diff")
  local markers = require("review.ui.markers")
  local ft = vim.bo.filetype
  local items = {}

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
  items[#items + 1] = { key = "a", label = "Open/toggle agent chat", fn = M.toggle_chat }
  items[#items + 1] = { key = "Y", label = "Edit, copy, or run final prompt", fn = M.copy_prompt }
  items[#items + 1] = { key = "f", label = "Refresh PR and comments", fn = M.refresh }
  items[#items + 1] = { key = "i", label = "Import GitHub comments", fn = M.import_github_comments }
  items[#items + 1] = { key = "S", label = "Sync latest Claude findings", fn = M.sync_claude_result }
  items[#items + 1] = { key = "Q", label = "Export threads to quickfix", fn = M.threads_to_quickfix }
  items[#items + 1] = { key = "R", label = "Claude review sessions", fn = M.claude_sessions }
  items[#items + 1] = { key = "O", label = "Overview (description, commits, threads)", fn = M.show_overview }
  items[#items + 1] = { key = "P", label = "Toggle comments panel", fn = M.toggle_comments_panel }
  items[#items + 1] = { key = "L", label = "Choose another review target", fn = M.choose_source }
  items[#items + 1] = { key = "?", label = "Help and key reference", fn = M.help }

  menu.open(items, { title = "Review · " .. M.current.source:title() })
end

function M.choose_source()
  require("review.ui.menu").open({
    { key = "p", label = "Pull request", fn = M.open_pull_requests },
    { key = "b", label = "Local branch", fn = M.open_branches },
    { key = "c", label = "Single commit", fn = M.open_commits },
    { key = "h", label = "Current branch against its base", fn = M.open_current },
    { key = "l", label = "Combined PR / branch picker", fn = M.open_list },
    { key = "?", label = "Help and key reference", fn = M.help },
  }, { title = "Review target" })
end

function M.help()
  require("review.ui.help").open()
end

--- Open a review for a source argument (PR number/url, branch, or ".").
---@param arg string|integer|table|nil
---@param opts table|nil { base=string }
function M.open(arg, opts)
  opts = vim.tbl_extend("force", { base = config.get().local_base }, opts or {})
  local Source = require("review.source")
  local source, err = Source.create(arg, opts.cwd or vim.fn.getcwd(), opts)
  if not source then
    util.notify("cannot open review: " .. tostring(err), vim.log.levels.ERROR)
    return
  end
  local Store = require("review.comments.store")
  local store = Store.for_source(source)
  store:reanchor(rename_map(source))

  if config.get().workspace.dedicated_tab then vim.cmd("tabnew") end
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

  if config.get().workspace.comments and vim.o.columns >= config.get().workspace.comments_min_columns then
    vim.schedule(function()
      if M.current then M.toggle_comments_panel(true) end
    end)
  end

  util.notify(string.format("%s · %d comments · <leader>p for actions",
    source:title(), vim.tbl_count(store.comments)))
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
  local old = M.current.source
  local before_threads, before_head = #M.current.store:all_threads(), old:head_rev()
  local ctx = require("review.ui.diff").context()
  local arg
  if old:kind() == "pr" then arg = old.number
  elseif old:kind() == "commit" then arg = { kind = "commit", rev = old.rev }
  else arg = old.branch end
  local Source = require("review.source")
  util.notify("refreshing metadata, commits, checks, and threads…")
  local old_meta = old:metadata()
  local refresh_base = old:kind() == "branch" and (old_meta.requested_base or "auto") or old.base_ref
  local fresh, err = Source.create(arg, old_meta.repo_root, { base = refresh_base })
  if not fresh then
    util.notify("refresh failed: " .. tostring(err), vim.log.levels.ERROR)
    return
  end
  M.current.source, M.current.store.source = fresh, fresh
  if fresh:caps().has_threads then require("review.comments.github_sync").import(fresh, M.current.store) end
  M.current.store:reanchor(rename_map(fresh))
  require("review.ui.diff").refresh_markers(M.current.store)
  if ctx then require("diffview").open_review_location({ path = ctx.file, side = ctx.side, line = ctx.line }) end
  local new_threads = #M.current.store:all_threads() - before_threads
  util.notify(string.format("refreshed · head %s · %s%d new thread%s", before_head == fresh:head_rev()
    and "unchanged" or ("advanced to " .. fresh:head_rev():sub(1, 8)), new_threads >= 0 and "+" or "",
    new_threads, math.abs(new_threads) == 1 and "" or "s"))
end

function M.import_github_comments()
  if not M.current or M.current.source:kind() ~= "pr" then
    util.notify("GitHub comment import requires a PR", vim.log.levels.WARN); return
  end
  M.current.source._threads = nil
  util.notify("importing GitHub review threads…")
  vim.cmd("redraw")
  local imported, err = require("review.comments.github_sync").import(M.current.source, M.current.store)
  if err then
    util.notify("GitHub comment import failed: " .. tostring(err), vim.log.levels.ERROR)
    return
  end
  require("review.ui.diff").refresh_markers(M.current.store)
  if require("review.ui.comments_panel").is_open() then
    require("review.ui.comments_panel").render(M.current.store, nil, "RIGHT")
  end
  util.notify(string.format("GitHub comments imported · %d new", imported))
end

---Recover/import the latest Claude result from its persisted Sidekick transcript.
---Useful when an older live poller saw terminal-reflowed JSON and could not parse it.
function M.sync_claude_result()
  if not M.current then util.notify("open a review first", vim.log.levels.WARN); return end
  local sessions = vim.tbl_values(M.current.store.sessions or {})
  table.sort(sessions, function(a, b) return (a.started_at or "") > (b.started_at or "") end)
  local session = sessions[1]
  if not session then util.notify("no Claude review session to synchronize", vim.log.levels.INFO); return end
  session.replied, session.findings = session.replied or {}, session.findings or {}
  local text = require("review.sidekick").transcript_result(
    M.current.source, session.cwd or M.current.source:metadata().repo_root)
  local findings, err = require("review.claude.contract").extract_findings(text)
  if not findings then
    util.notify("could not synchronize Claude findings: " .. tostring(err), vim.log.levels.ERROR)
    return
  end
  require("review.sidekick").apply_findings(M.current.store, M.current.source, session, findings)
  session.state, session.progress = "done", "Findings imported from transcript"
  session.error = nil
  M.current.store.sessions[session.id] = session
  M.current.store:save()
  require("review.ui.diff").refresh_markers(M.current.store)
  if session.diffview_applied then
    require("review.ui.comments_panel").close()
  else
    M.toggle_comments_panel(true)
  end
  util.notify(string.format("Claude review synchronized · %d findings · %d replies",
    #(session.findings or {}), #(session.replied or {})))
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
      require("diffview").open_review_location({ path = thread.file, side = thread.side, line = thread.line_start })
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
  local drafts = vim.tbl_filter(function(root)
    return root.status == "draft" and not root.github_id and not root.in_reply_to
  end, threads or M.current.store:all_threads())
  if #drafts == 0 then util.notify("no publishable drafts", vim.log.levels.INFO); return end
  local comments = {}
  for _, root in ipairs(drafts) do
    comments[#comments + 1] = { path = root.file, line = root.line_end or root.line_start,
      side = root.side or "RIGHT", body = root.body }
  end
  local src, meta = M.current.source, M.current.source:metadata()
  local payload = {
    commit_id = src:head_rev(), event = "COMMENT", body = "Review submitted from review.nvim", comments = comments,
  }
  require("review.ui.publish").open(payload, drafts, function()
    local result, err = require("review.util.gh").submit_review(
      meta.owner, meta.repo, meta.number, payload, meta.repo_root)
    if not result then util.notify("publish failed: " .. tostring(err), vim.log.levels.ERROR); return end
    for i, root in ipairs(drafts) do
      local remote = type(result.comments) == "table" and result.comments[i] or nil
      M.current.store:update(root.id, {
        status = "published", origin = "github",
        github_id = remote and (remote.node_id or tostring(remote.id)) or root.github_id,
      })
    end
    M.refresh()
    util.notify(string.format("published %d review comments", #drafts))
  end)
end

function M.react_to_thread(root)
  if not root then return end
  local choices = { "THUMBS_UP", "THUMBS_DOWN", "LAUGH", "HOORAY", "CONFUSED", "HEART", "ROCKET", "EYES" }
  vim.ui.select(choices, { prompt = "React to thread:" }, function(reaction)
    if not reaction then return end
    if root.github_id then
      local ok, err = require("review.util.gh").react(root.github_id, reaction, true,
        M.current.source:metadata().repo_root)
      if not ok then util.notify("reaction failed: " .. tostring(err), vim.log.levels.ERROR); return end
    end
    root.reactions = root.reactions or {}
    root.reactions[reaction] = (root.reactions[reaction] or 0) + 1
    M.current.store:update(root.id, { reactions = root.reactions })
    require("review.ui.diff").refresh_markers(M.current.store)
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
  table.insert(names, 2, "Custom instructions…")
  vim.ui.select(names, { prompt = "Saved instruction profile:" }, function(choice)
    if not choice then return end
    local function permissions(instruction)
      vim.ui.select({ "Read-only review", "Allow edits in repository-local worktree" },
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

  vim.api.nvim_create_autocmd("VimResized", {
    group = group,
    callback = function()
      if M.current and vim.o.columns < config.get().workspace.comments_min_columns then
        require("review.ui.comments_panel").close()
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
