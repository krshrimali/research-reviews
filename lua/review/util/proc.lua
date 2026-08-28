-- review.nvim :: process execution helpers
-- All commands are argv-style (no shell), satisfying shell=false safety.

local M = {}

--- Run a command synchronously. Returns ok, stdout, stderr, code.
--- argv MUST be a list of strings; never interpolate untrusted data into a shell.
---@param argv string[]
---@param opts table|nil { cwd=string, stdin=string, timeout=integer(ms), env=table<string,string> }
---@return boolean ok, string stdout, string stderr, integer code
function M.run(argv, opts)
  opts = opts or {}
  assert(type(argv) == "table" and #argv > 0, "proc.run: argv must be a non-empty list")
  local res = vim
    .system(argv, {
      cwd = opts.cwd,
      stdin = opts.stdin,
      env = opts.env,
      text = true,
    })
    :wait(opts.timeout or 30000)
  local out = res.stdout or ""
  local err = res.stderr or ""
  return res.code == 0, out, err, res.code
end

--- Run asynchronously. Calls on_exit(ok, stdout, stderr, code) on the main loop.
--- Returns the vim.SystemObj (has :kill(sig)) so callers can cancel.
---@param argv string[]
---@param opts table|nil { cwd, stdin, on_stdout=fun(line), env }
---@param on_exit fun(ok:boolean, stdout:string, stderr:string, code:integer)
---@return vim.SystemObj
function M.spawn(argv, opts, on_exit)
  opts = opts or {}
  local stdout_cb
  if opts.on_stdout then
    -- Stream line-buffered stdout to the callback.
    local buffer = ""
    stdout_cb = function(_, data)
      if not data then
        return
      end
      buffer = buffer .. data
      while true do
        local nl = buffer:find("\n")
        if not nl then
          break
        end
        local line = buffer:sub(1, nl - 1)
        buffer = buffer:sub(nl + 1)
        vim.schedule(function()
          opts.on_stdout(line)
        end)
      end
    end
  end

  return vim.system(argv, {
    cwd = opts.cwd,
    stdin = opts.stdin,
    env = opts.env,
    text = true,
    stdout = stdout_cb,
  }, function(res)
    vim.schedule(function()
      on_exit(res.code == 0, res.stdout or "", res.stderr or "", res.code)
    end)
  end)
end

--- Convenience: run a git command in a repo dir.
---@param args string[] git subcommand + args (without leading "git")
---@param cwd string|nil
---@return boolean ok, string stdout, string stderr
function M.git(args, cwd)
  local argv = { "git" }
  vim.list_extend(argv, args)
  local ok, out, err = M.run(argv, { cwd = cwd })
  return ok, out, err
end

return M
