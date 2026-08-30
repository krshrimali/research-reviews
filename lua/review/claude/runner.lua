-- review.nvim :: async Claude review runner.
--
-- Spawns `claude -p --output-format stream-json`, streams progress into the session
-- record, and on completion parses the findings contract and applies it to the store
-- idempotently (design gap #10). Tool access is gated (gap #5); edits run in a
-- worktree and are never pushed.

local proc = require("review.util.proc")
local contract = require("review.claude.contract")
local worktree = require("review.worktree")
local util = require("review.util")
local config = require("review.config")

local M = {}

-- Track live jobs so we can kill them on VimLeavePre (R5).
M.jobs = {}

-- One shared policy for every backend (see review.claude.policy).
local policy = require("review.claude.policy")

--- Apply a parsed findings table to the store. Idempotent per session.
---@param store table
---@param source table
---@param session table   -- SessionRecord (mutated)
---@param findings table
local function apply_findings(store, source, session, findings)
  if session.applied then
    return
  end
  session.verdict = findings.verdict
  session.summary = findings.summary
  session.findings = session.findings or {}

  -- Head-drift guard (gap #3): if head moved, warn; thread_replies still apply by id.
  local drifted = findings.reviewed_head_sha and findings.reviewed_head_sha ~= source:head_rev()
  if drifted then
    table.insert(session.findings, {
      general = true,
      note = "⚠ head advanced since review; new_comment line numbers may be approximate.",
    })
  end

  -- Thread replies (comment_id is a local uuid).
  for _, r in ipairs(findings.thread_replies or {}) do
    local target = store:get(r.comment_id)
    if target then
      store:reply(r.comment_id, r.reply, { origin = "claude", suggestion_text = r.suggestion })
      table.insert(session.replied, r.comment_id)
    else
      -- Unmatched id: never drop — becomes a general finding (gap #6).
      table.insert(session.findings, {
        general = true,
        note = string.format("reply to unknown comment_id %s: %s", tostring(r.comment_id), r.reply),
      })
    end
  end

  -- New Claude-authored comments.
  for _, nc in ipairs(findings.new_comments or {}) do
    if drifted then
      table.insert(session.findings, { general = true, note = string.format(
        "Outdated inline finding at %s:%s: %s", nc.file, nc.line_start, nc.body) })
    else
      local c = store:add({
      file = nc.file,
      side = nc.side or "RIGHT",
      line_start = nc.line_start or 1,
      line_end = nc.line_end or nc.line_start or 1,
      body = nc.body or "",
      kind = nc.suggestion and "suggestion" or "normal",
      suggestion_text = nc.suggestion,
      origin = "claude",
    })
      table.insert(session.findings, { comment_id = c.id, file = nc.file, line = nc.line_start })
    end
  end

  -- Auto-resolve (only honored if the run enabled it).
  if session.auto_resolve then
    for _, id in ipairs(findings.resolved or {}) do
      local root = store:get(id)
      if root then
        store:set_resolved(id, true)
        if root.github_thread_id and source:kind() == "pr" then
          local ok, err = require("review.util.gh").resolve_thread(root.github_thread_id, true,
            source:metadata().repo_root)
          if not ok then
            store:set_resolved(id, false)
            table.insert(session.findings, { general = true,
              note = "Could not resolve GitHub thread " .. id .. ": " .. tostring(err) })
          end
        end
      end
    end
  end

  session.commits = findings.commits or {}
  session.applied = true
  store.sessions[session.id] = session
  store:save()
end

---Public result bridge for Sidekick-backed interactive sessions.
M.apply_findings = apply_findings

--- Start a review. Returns the session record immediately; runs async.
---@param opts table {
---   store table, source table, instruction string,
---   auto_resolve boolean, allow_edits boolean,
---   included_threads table[]|nil,   -- root comments to include (default: all non-resolved)
---   on_progress fun(session, text)|nil, on_done fun(session)|nil }
---@return table session
function M.start(opts)
  local store, source = opts.store, opts.source
  local cfg = config.get().claude
  local session_id = util.uuid()

  -- Flatten included threads (roots + their replies) for the prompt.
  local roots = opts.included_threads
  if not roots then
    roots = {}
    for _, r in ipairs(store:all_threads()) do
      if r.status ~= "resolved" then
        table.insert(roots, r)
      end
    end
  end
  roots = vim.deepcopy(roots)
  for _, root in ipairs(roots) do root.replies = vim.deepcopy(store:replies(root.id)) end

  local diff = contract.build_diff(source)
  local user_prompt = contract.user_prompt({
    source = source,
    diff = diff,
    threads = roots,
    instruction = opts.instruction,
    auto_resolve = opts.auto_resolve,
    allow_edits = opts.allow_edits,
  })

  -- Working directory: a worktree at head when edits are allowed (isolation + safety).
  local meta = source:metadata()
  local cwd = meta.repo_root
  if opts.allow_edits then
    local wt, err = worktree.ensure(meta.repo_root, source:head_rev(), { key = session_id })
    if wt then
      cwd = wt
    else
      local message = "could not create isolated edit worktree: " .. tostring(err)
      util.notify(message, vim.log.levels.ERROR)
      return nil, message
    end
  end

  -- Build argv.
  local tools, denied = policy.for_mode(opts.allow_edits)
  local argv = {
    cfg.bin, "-p",
    "--output-format", "stream-json",
    "--verbose",
    "--session-id", session_id,
    "--append-system-prompt", contract.system_prompt(),
    "--allowedTools", table.concat(tools, ","),
    "--disallowedTools", table.concat(denied, ","),
    -- Never auto-accept anything not explicitly allowed above.
    "--permission-mode", opts.allow_edits and "acceptEdits" or "default",
  }
  if cfg.model then
    vim.list_extend(argv, { "--model", cfg.model })
  end
  vim.list_extend(argv, cfg.extra_args or {})

  local session = {
    id = session_id,
    source_key = source:key(),
    state = "running",
    instruction = opts.instruction,
    allow_edits = opts.allow_edits or false,
    auto_resolve = opts.auto_resolve or false,
    started_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    cwd = cwd,
    replied = {},
    findings = {},
    log = {},
    applied = false,
  }
  store.sessions[session_id] = session
  store:save()

  local result_text = ""
  local handle = proc.spawn(argv, {
    cwd = cwd,
    stdin = user_prompt,
    on_stdout = function(line)
      local ev = contract.parse_stream_line(line)
      if not ev then
        return
      end
      if ev.kind == "progress" and ev.text and ev.text ~= "" then
        table.insert(session.log, ev.text)
        if opts.on_progress then
          opts.on_progress(session, ev.text)
        end
      elseif ev.kind == "result" then
        result_text = ev.text or ""
      end
    end,
  }, function(ok, _, stderr, code)
    M.jobs[session_id] = nil
    session.ended_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
    if session.state == "cancelled" or session.state == "timed_out" then
      store.sessions[session_id] = session
      store:save()
      if opts.on_done then opts.on_done(session) end
      return
    end
    if not ok then
      session.state = "error"
      session.error = string.format("claude exited %d: %s", code, (stderr or ""):sub(1, 500))
      store.sessions[session_id] = session
      store:save()
      util.notify("Claude review failed: " .. session.error, vim.log.levels.ERROR)
      if opts.on_done then
        opts.on_done(session)
      end
      return
    end
    local findings, ferr = contract.extract_findings(result_text)
    if not findings then
      session.state = "error"
      session.error = "parse: " .. tostring(ferr)
      session.raw_result = result_text
      store.sessions[session_id] = session
      store:save()
      util.notify("Claude review parse error: " .. tostring(ferr), vim.log.levels.ERROR)
      if opts.on_done then
        opts.on_done(session)
      end
      return
    end
    apply_findings(store, source, session, findings)
    session.state = "done"
    store.sessions[session_id] = session
    store:save()
    util.notify(string.format("Review done: %s — %s",
      source:title(), findings.verdict or "commented"),
      findings.verdict == "request_changes" and vim.log.levels.WARN or vim.log.levels.INFO)
    if opts.on_done then
      opts.on_done(session)
    end
  end)

  M.jobs[session_id] = { handle = handle, session = session, store = store }
  local timeout = cfg.timeout_ms or 0
  if timeout > 0 then
    vim.defer_fn(function()
      if M.jobs[session_id] then M.kill(session_id, "timed_out") end
    end, timeout)
  end
  return session
end

--- Kill a running session.
---@param session_id string
function M.kill(session_id, state)
  local job = M.jobs[session_id]
  if job then
    job.session.state = state or "cancelled"
    job.session.ended_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
    job.session.error = nil
    job.store.sessions[session_id] = job.session
    job.store:save()
    pcall(function() job.handle:kill(15) end)
    M.jobs[session_id] = nil
    return true
  end
  return false
end

function M.retry(session, store, callbacks)
  callbacks = callbacks or {}
  return M.start({
    store = store,
    source = store.source,
    instruction = session.instruction or "",
    allow_edits = session.allow_edits,
    auto_resolve = session.auto_resolve,
    on_progress = callbacks.on_progress,
    on_done = callbacks.on_done,
  })
end

--- Kill all running jobs (VimLeavePre).
function M.kill_all()
  local ids = vim.tbl_keys(M.jobs)
  for _, id in ipairs(ids) do M.kill(id) end
end

return M
