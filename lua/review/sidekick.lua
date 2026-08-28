-- Sidekick-backed conversational review sessions.
local contract = require("review.claude.contract")
local util = require("review.util")
local worktree = require("review.worktree")

local M = {}

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
  vim.schedule(function()
    local sent, err = pcall(function()
      state.session:send(prompt .. "\n")
      state.session:submit()
    end)
    if not sent then
      util.notify("Sidekick send failed: " .. tostring(err), vim.log.levels.ERROR)
    end
  end)
  return { state = "running", cwd = cwd, sidekick_id = state.session.id, prompt = prompt }
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
