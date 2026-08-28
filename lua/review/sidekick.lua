-- Sidekick-backed conversational review sessions.
local contract = require("review.claude.contract")
local util = require("review.util")
local worktree = require("review.worktree")

local M = {}
M.pollers = {}

---Read the agent's exact persisted transcript instead of terminal cells. Terminal
---buffers contain display-width reflow and can therefore split/corrupt long JSON.
---@param source table
---@param cwd string
---@param model table|nil injectable transcript model for tests
---@return string|nil
function M.transcript_result(source, cwd, model)
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
        if type(turn.prompt) == "string" and turn.prompt:find(head, 1, true) then
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

local function roots_with_replies(store, roots)
  local out = vim.deepcopy(roots or store:all_threads())
  for _, root in ipairs(out) do
    root.replies = vim.deepcopy(store:replies(root.id))
  end
  return out
end

function M.prompt(source, store, opts)
  opts = opts or {}
  return contract.system_prompt() .. "\n\n" .. contract.user_prompt({
    source = source,
    threads = roots_with_replies(store, opts.threads),
    instruction = opts.instruction or "",
    auto_resolve = opts.auto_resolve or false,
    allow_edits = opts.allow_edits or false,
  })
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
  if opts.allow_edits then
    local err
    cwd, err = worktree.ensure(meta.repo_root, source:head_rev())
    if not cwd then
      return nil, err
    end
  end
  local state = cli.start({ name = opts.tool or "claude", cwd = cwd, focus = opts.focus ~= false })
  if not state or not state.session then
    return nil, "could not start Sidekick session"
  end
  local id = util.uuid()
  local session = {
    id = id, source_key = source:key(), state = "running", progress = "Starting agent",
    started_at = os.date("!%Y-%m-%dT%H:%M:%SZ"), cwd = cwd,
    allow_edits = opts.allow_edits or false, auto_resolve = opts.auto_resolve or false,
    replied = {}, findings = {}, log = {}, applied = false,
    sidekick_id = state.session.id,
  }
  store.sessions[id] = session
  store:save()

  vim.schedule(function()
    local sent, err = pcall(function()
      state.session:send(prompt .. "\n")
      state.session:submit()
    end)
    if not sent then
      util.notify("Sidekick send failed: " .. tostring(err), vim.log.levels.ERROR)
    end
  end)

  -- Sidekick deliberately owns the interactive terminal. We watch its scrollback
  -- for the structured result contract and import it back into review.nvim.
  local ticks, last_progress = 0, session.progress
  local function tick()
    ticks = ticks + 1
    if session.state ~= "running" then return end
    local terminal = state.terminal
    local buf = terminal and terminal.buf
    local lines, text = {}, ""
    if buf and vim.api.nvim_buf_is_valid(buf) then
      lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      text = table.concat(lines, "\n")
    end
    local exact = M.transcript_result(source, cwd)
    local findings = require("review.claude.contract").extract_findings(exact or text)
    if findings and findings.reviewed_head_sha then
      require("review.claude.runner").apply_findings(store, source, session, findings)
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
    if ticks % 3 == 0 then store.sessions[id] = session; store:save() end
    vim.defer_fn(tick, 1500)
  end
  M.pollers[id] = true
  vim.defer_fn(tick, 1000)
  return session
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
