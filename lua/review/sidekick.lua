-- Sidekick-backed conversational review sessions.
local contract = require("review.claude.contract")
local util = require("review.util")
local worktree = require("review.worktree")

local M = {}
M.pollers = {}

-- The agent tool policy lives in review.claude.policy so both the Sidekick launch
-- below and the headless runner enforce the same thing.
local policy = require("review.claude.policy")

M._tool_policy = policy

--- Register (once per session) two review-specific Sidekick tools derived from the
--- user's own `claude` tool, differing only by the tool allow/deny policy.
--- Returns the tool name to launch, or "claude" if registration is not possible.
---@param allow_edits boolean
---@return string tool_name, boolean restricted
function M.ensure_tool(allow_edits)
  local mode = allow_edits and "edit" or "readonly"
  local name = "review_" .. mode
  local ok_cfg, cfg = pcall(require, "sidekick.config")
  local ok_tool, tool = pcall(require, "sidekick.cli.tool")
  if not ok_cfg or not ok_tool or type(cfg.cli) ~= "table" or type(cfg.cli.tools) ~= "table" then
    return "claude", false
  end
  if cfg.cli.tools[name] then
    return name, true
  end
  local ok_base, base = pcall(tool.get, "claude")
  if not ok_base or not base or type(base.cmd) ~= "table" or #base.cmd == 0 then
    return "claude", false
  end
  local allow, deny = policy.args(allow_edits)
  local cmd = vim.deepcopy(base.cmd)
  vim.list_extend(cmd, { "--allowedTools", allow, "--disallowedTools", deny })
  cfg.cli.tools[name] = vim.tbl_extend("force", vim.deepcopy(base.config or {}), {
    cmd = cmd,
    -- The process still *is* claude, so reuse claude's process matcher.
    is_proc = (base.config or {}).is_proc or "claude",
    -- Claude Code turns OFF transcript saving when it sees this marker, which it
    -- inherits whenever Neovim was itself started from an agent terminal. The
    -- transcript is the only reliable place to read a review result back from — the
    -- agent's TUI runs on the alternate screen, so its terminal buffer holds just
    -- the visible screen and any result longer than that is simply gone. Clear the
    -- marker for the child (sidekick treats `false` as "unset this variable").
    env = vim.tbl_extend("force", vim.deepcopy((base.config or {}).env or {}), {
      CLAUDE_CODE_CHILD_SESSION = false,
    }),
  })
  return name, true
end

---Why no transcript is available, in words a user can act on.
---
---Claude Code disables transcript saving when it detects it was started from inside
---another Claude session (`CLAUDE_CODE_CHILD_SESSION`), which is exactly what
---happens when Neovim is launched from an agent terminal. Sync then finds nothing
---and used to report only "empty result".
---@return string|nil reason
function M.transcript_unavailable_reason()
  local ok, model = pcall(require, "sidekick.review.model")
  if not ok or type(model.sessions) ~= "function" then
    return "sidekick.nvim does not expose a transcript model"
  end
  if (vim.env.CLAUDE_CODE_CHILD_SESSION or "") ~= "" then
    return "CLAUDE_CODE_CHILD_SESSION is set, so the agent did not save a transcript"
      .. " (this Neovim was started from inside another Claude session)"
  end
  return nil
end

---The agent's visible terminal output for a session, as a fallback when no
---transcript was persisted. Terminal cells are display-reflowed, so long JSON can
---arrive split; this is a last resort, not the primary path.
---@param session table
---@return string|nil
function M.terminal_text(session)
  local live = M.pollers[session.id]
  local terminal = live and live.terminal
  if not terminal then
    -- Fall back to any Sidekick terminal buffer still open for this tool.
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].filetype == "sidekick_terminal" then
        return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
      end
    end
    return nil
  end
  local buf = terminal.buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return nil end
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

--- Dialogs the agent shows before it will accept any input. A new worktree is a
--- directory the CLI has never seen, so an edit-enabled review hits the trust prompt
--- every single time.
local BLOCKING_PROMPTS = {
  { pattern = "Is this a project you created or one you trust", reason = "the agent is asking you to trust this worktree" },
  { pattern = "Do you want to proceed", reason = "the agent is waiting on a confirmation" },
  { pattern = "Enter to confirm", reason = "the agent is showing a confirmation dialog" },
  { pattern = "Select login method", reason = "the agent needs you to log in" },
  { pattern = "Invalid API key", reason = "the agent could not authenticate" },
}

---Why the agent cannot accept input yet, if it cannot.
---@param text string|nil
---@return string|nil reason
function M.blocking_reason(text)
  if not text or text == "" then return nil end
  -- Only the tail matters: an answered dialog stays in the scrollback forever.
  local tail = text:sub(-1200)
  for _, entry in ipairs(BLOCKING_PROMPTS) do
    if tail:find(entry.pattern, 1, true) then return entry.reason end
  end
  return nil
end

---Press Enter in the agent's terminal.
---
---`session:submit()` is the documented way, but it guards on `is_running()` and was
---observed to no-op for a live terminal-backed session — the prompt then sat in the
---input box forever. Writing the carriage return to the channel ourselves is what
---a keypress does anyway, so try both.
---@param state table sidekick cli state
---@return boolean
function M.press_enter(state)
  pcall(function() state.session:submit() end)
  local buf = state.terminal and state.terminal.buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return false end
  local chan = vim.bo[buf].channel
  if not chan or chan == 0 then return false end
  return pcall(vim.api.nvim_chan_send, chan, "\r")
end

---Make sure a submitted prompt actually left the input box, re-pressing Enter if
---the paste marker is still sitting there.
---@param state table sidekick cli state
---@param session table
---@param attempt integer
function M.confirm_submitted(state, session, attempt)
  if session.state ~= "running" then return end
  local buf = state.terminal and state.terminal.buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  local tail = table.concat(vim.api.nvim_buf_get_lines(buf, -25, -1, false), "\n")
  local still_queued = tail:find("Pasted text", 1, true)
    or tail:find("You are performing a code review", 1, true)
  if not still_queued then
    session.prompt_sent = true
    session.progress = "Prompt sent"
    return
  end
  if attempt > 5 then
    util.notify("the review prompt is still in the agent's input box — press Enter in the chat",
      vim.log.levels.WARN)
    return
  end
  M.press_enter(state)
  vim.defer_fn(function() M.confirm_submitted(state, session, attempt + 1) end, 900)
end

---Read the agent's exact persisted transcript instead of terminal cells. Terminal
---buffers contain display-width reflow and can therefore split/corrupt long JSON.
---@param source table
---@param cwd string
---@param model table|nil injectable transcript model for tests
---@return string|nil
function M.transcript_result(source, cwd, model, opts)
  opts = opts or {}
  local ok
  if not model then
    ok, model = pcall(require, "sidekick.review.model")
    if not ok then return nil end
  end
  local ok_sessions, sources = pcall(model.sessions, cwd)
  if not ok_sessions or type(sources) ~= "table" then return nil end
  local head = source:head_rev()
  for _, transcript_source in ipairs(sources) do
    local ok_build, transcript = pcall(model.build, transcript_source)
    if ok_build and transcript then
      for i = #(transcript.turns or {}), 1, -1 do
        local turn = transcript.turns[i]
        if (not opts.not_before or (tonumber(turn.ts) or 0) >= opts.not_before)
            and type(turn.prompt) == "string" and turn.prompt:find(head, 1, true) then
          local text = {}
          for _, block in ipairs(turn.blocks or {}) do
            if block.kind == "text" and type(block.text) == "string" then
              text[#text + 1] = block.text
            end
          end
          if #text > 0 then return table.concat(text, "\n") end
        end
      end
    end
  end
end

--- Threads to hand the agent. An explicit selection is honoured verbatim; a
--- whole-review request excludes resolved threads, because the contract tells the
--- agent to reply to EVERY thread it is given and a finished conversation does not
--- need another reply.
---@param store table
---@param roots table[]|nil explicit selection
---@return table[]
local function roots_with_replies(store, roots)
  local selected = roots
  if not selected then
    selected = vim.tbl_filter(function(root)
      return root.status ~= "resolved"
    end, store:all_threads())
  end
  local out = vim.deepcopy(selected)
  for _, root in ipairs(out) do
    root.replies = vim.deepcopy(store:replies(root.id))
  end
  return out
end

M._roots_with_replies = roots_with_replies

function M.prompt(source, store, opts)
  opts = opts or {}
  local threads = roots_with_replies(store, opts.threads)
  -- Diffview-native comments are the annotations users see as REVIEW #n. Include
  -- them in whole-review prompts so the agent can answer those exact threads.
  if not opts.threads then
    local ok, dv_review = pcall(require, "diffview.review")
    if ok and dv_review.agent_threads then
      vim.list_extend(threads, dv_review.agent_threads())
    end
  end
  return contract.system_prompt() .. "\n\n" .. contract.user_prompt({
    source = source,
    threads = threads,
    instruction = opts.instruction or "",
    auto_resolve = opts.auto_resolve or false,
    allow_edits = opts.allow_edits or false,
  })
end

---Apply findings to both the native Diffview annotations and review.nvim's store.
function M.apply_findings(store, source, session, findings)
  local runner_findings = vim.deepcopy(findings)
  local ok, dv_review = pcall(require, "diffview.review")
  if ok and dv_review.apply_agent_findings and not session.diffview_applied then
    local added, replied = dv_review.apply_agent_findings(findings)
    if added ~= nil then
      runner_findings.new_comments = {}
      runner_findings.thread_replies = vim.tbl_filter(function(reply)
        return not tostring(reply.comment_id or ""):match("^diffview:")
      end, runner_findings.thread_replies or {})
      for _, reply in ipairs(findings.thread_replies or {}) do
        if tostring(reply.comment_id or ""):match("^diffview:") then
          session.replied[#session.replied + 1] = reply.comment_id
        end
      end
      for _, comment in ipairs(findings.new_comments or {}) do
        session.findings[#session.findings + 1] = {
          diffview = true, file = comment.file, line = comment.line_start,
        }
      end
      session.diffview_applied = true
    end
  end
  require("review.claude.runner").apply_findings(store, source, session, runner_findings)
end

---Start a Sidekick CLI session pinned to the repository or an explicitly consented
---repository-local worktree, then send the final prompt.
function M.run(source, store, prompt, opts)
  opts = opts or {}
  local ok, cli = pcall(require, "sidekick.cli")
  if not ok or not cli.start then
    return nil, "sidekick.nvim with cli.start() is required"
  end
  local meta = source:metadata()
  local cwd = meta.repo_root
  local id = util.uuid()
  if opts.allow_edits then
    local err
    cwd, err = worktree.ensure(meta.repo_root, source:head_rev(), { key = id })
    if not cwd then
      return nil, err
    end
  end
  local tool_name, restricted = M.ensure_tool(opts.allow_edits)
  local state = cli.start({ name = opts.tool or tool_name, cwd = cwd, focus = opts.focus ~= false })
  if not state or not state.session then
    return nil, "could not start Sidekick session"
  end
  if not restricted then
    util.notify("agent tool policy could not be applied; this session is NOT restricted",
      vim.log.levels.WARN)
  end
  local session = {
    id = id, source_key = source:key(), state = "running", progress = "Starting agent",
    started_at = os.date("!%Y-%m-%dT%H:%M:%SZ"), cwd = cwd,
    allow_edits = opts.allow_edits or false, auto_resolve = opts.auto_resolve or false,
    replied = {}, findings = {}, log = {}, applied = false,
    sidekick_id = state.session.id, backend = "sidekick", retry_prompt = prompt,
    tool = tool_name, restricted = restricted,
    -- Recorded so the sessions view can say what this run was asked to do, and so a
    -- retry reproduces the same request rather than a bare review.
    instruction = opts.instruction or "",
    started_epoch = os.time(),
  }
  store.sessions[id] = session
  store:save()

  -- Send only once the agent can actually receive. Sending immediately typed the
  -- whole review prompt into whatever dialog happened to be up — most often the
  -- trust prompt for the freshly created worktree — and the prompt was simply lost
  -- while the session sat at "Starting agent" until it timed out.
  local function terminal_text()
    local buf = state.terminal and state.terminal.buf
    if not buf or not vim.api.nvim_buf_is_valid(buf) then return "" end
    return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  end

  local warned
  local function send_prompt(attempt)
    if session.state ~= "running" or session.prompt_sent then return end
    local blocked = M.blocking_reason(terminal_text())
    if blocked then
      if warned ~= blocked then
        warned = blocked
        session.progress = "Waiting: " .. blocked
        util.notify(blocked .. " — answer it in the chat and the review will be sent",
          vim.log.levels.WARN)
      end
      if attempt < 300 then
        vim.defer_fn(function() send_prompt(attempt + 1) end, 1000)
      else
        session.state, session.progress = "error", "Agent never became ready"
        session.error = blocked
        store.sessions[id] = session; store:save(); M.pollers[id] = nil
        if opts.on_done then opts.on_done(session) end
      end
      return
    end
    -- A long prompt arrives as one bracketed paste, which the agent's TUI shows as
    -- "[Pasted text #1 +N lines]" and is still debouncing when an immediate \r
    -- lands — so the prompt sat in the input box, unsent, and the session waited
    -- forever. Submit after a beat, then confirm it actually left the box.
    local sent, err = pcall(function()
      state.session:send(prompt)
      vim.defer_fn(function()
        M.press_enter(state)
        M.confirm_submitted(state, session, 1)
      end, 500)
    end)
    if not sent then
      session.state, session.progress = "error", "Could not send prompt to Sidekick"
      session.error, session.ended_at = tostring(err), os.date("!%Y-%m-%dT%H:%M:%SZ")
      store.sessions[id] = session; store:save(); M.pollers[id] = nil
      if opts.on_done then opts.on_done(session) end
      util.notify("Sidekick send failed: " .. tostring(err), vim.log.levels.ERROR)
      return
    end
    session.progress = "Prompt sent"
    if warned then util.notify("agent is ready; review prompt sent") end
  end

  vim.defer_fn(function() send_prompt(1) end, 400)

  -- Sidekick deliberately owns the interactive terminal. We watch its scrollback
  -- for the structured result contract and import it back into review.nvim.
  local ticks, last_progress = 0, session.progress
  local function tick()
    ticks = ticks + 1
    if session.state ~= "running" or not M.pollers[id] then return end
    local terminal = state.terminal
    local buf = terminal and terminal.buf
    local lines, text = {}, ""
    if buf and vim.api.nvim_buf_is_valid(buf) then
      lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      text = table.concat(lines, "\n")
    end
    local exact = M.transcript_result(source, cwd, nil, { not_before = session.started_epoch - 2 })
    local findings = require("review.claude.contract").extract_findings(exact or text)
    if findings and findings.reviewed_head_sha then
      M.apply_findings(store, source, session, findings)
      session.state = "done"
      session.progress = "Findings imported"
      session.ended_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
      store.sessions[id] = session
      store:save()
      M.pollers[id] = nil
      if opts.on_done then opts.on_done(session) end
      util.notify(string.format("Claude review imported · %d findings · %d replies",
        #(session.findings or {}), #(session.replied or {})))
      return
    end
    if #lines > 0 then
      for i = #lines, math.max(1, #lines - 12), -1 do
        local line = vim.trim(lines[i] or "")
        if line ~= "" then
          session.progress = line:sub(1, 100)
          break
        end
      end
      if session.progress ~= last_progress then
        session.log[#session.log + 1] = session.progress
        last_progress = session.progress
        if opts.on_progress then opts.on_progress(session) end
      end
    end
    -- The agent's TUI leaves no scrollback, so a result that scrolled past the
    -- viewport cannot be recovered from the buffer. If the transcript is also
    -- unavailable, say so once instead of polling until the timeout.
    if not exact and ticks == 20 and M.transcript_unavailable_reason() then
      session.progress = "No transcript; findings cannot be auto-imported"
      util.notify("this agent is not saving a transcript, so findings cannot be imported"
        .. " automatically — run :ReviewSync while the result is still on screen",
        vim.log.levels.WARN)
    end
    if terminal and not terminal:is_running() then
      local _, parse_err = require("review.claude.contract").extract_findings(exact or text)
      session.state, session.progress = "error", "Review finished, but findings could not be imported"
      session.error = parse_err or "no structured findings"
      session.ended_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
      store:save()
      M.pollers[id] = nil
      if opts.on_done then opts.on_done(session) end
      util.notify("Claude review was readable, but inline findings were not imported: "
        .. session.error .. " · open Review Sessions for the full response", vim.log.levels.ERROR)
      return
    end
    local timeout = require("review.config").get().claude.timeout_ms or 0
    if timeout > 0 and (os.time() - session.started_epoch) * 1000 >= timeout then
      session.state, session.progress = "timed_out", "Review timed out"
      session.ended_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
      store.sessions[id] = session; store:save(); M.pollers[id] = nil
      if opts.on_done then opts.on_done(session) end
      util.notify("Sidekick review timed out; the interactive terminal was left open", vim.log.levels.WARN)
      return
    end
    if ticks % 3 == 0 then store.sessions[id] = session; store:save() end
    vim.defer_fn(tick, 1500)
  end
  M.pollers[id] = { session = session, store = store, terminal = state.terminal }
  vim.defer_fn(tick, 1000)
  return session
end

function M.cancel(id, state)
  local live = M.pollers[id]
  if not live then return false end
  live.session.state = state or "cancelled"
  live.session.ended_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
  live.store.sessions[id] = live.session
  live.store:save()
  M.pollers[id] = nil
  return true
end

function M.kill_all()
  for _, id in ipairs(vim.tbl_keys(M.pollers)) do M.cancel(id) end
end

function M.toggle()
  local ok, cli = pcall(require, "sidekick.cli")
  if not ok then
    util.notify("sidekick.nvim is not available", vim.log.levels.ERROR)
    return
  end
  cli.toggle({ name = "claude", focus = true })
end

return M
