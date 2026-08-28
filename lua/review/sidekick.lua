-- Sidekick-backed conversational review sessions.
local contract = require("review.claude.contract")
local util = require("review.util")
local worktree = require("review.worktree")

local M = {}
M.pollers = {}

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
    if buf and vim.api.nvim_buf_is_valid(buf) then
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local text = table.concat(lines, "\n")
      local findings = require("review.claude.contract").extract_findings(text)
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
      if terminal and not terminal:is_running() then
        session.state, session.progress = "error", "Agent exited without structured findings"
        session.ended_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
        store:save()
        M.pollers[id] = nil
        if opts.on_done then opts.on_done(session) end
        return
      end
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
