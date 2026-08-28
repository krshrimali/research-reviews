-- Editable final-prompt surface. Nothing leaves Neovim until the user chooses run.
local util = require("review.util")
local M = {}
local state

function M.open(text, opts)
  opts = opts or {}
  if state and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_close(state.win, true)
    state = nil
    return
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype, vim.bo[buf].bufhidden, vim.bo[buf].filetype = "acwrite", "wipe", "markdown"
  vim.api.nvim_buf_set_name(buf, "review://prompt/" .. util.uuid():sub(1, 8))
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(text, "\n", { plain = true }))
  vim.cmd("botright split")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  vim.api.nvim_win_set_height(win, math.max(12, math.floor(vim.o.lines * 0.35)))
  vim.wo[win].winbar = " Final review prompt · edit freely · :write run · y copy · q close "
  state = { buf = buf, win = win }
  local function current()
    return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  end
  local function copy()
    local value = current()
    vim.fn.setreg("+", value)
    vim.fn.setreg('"', value)
    util.notify("review prompt copied")
  end
  local function run()
    vim.bo[buf].modified = false
    opts.on_run(current())
  end
  vim.keymap.set("n", "y", copy, { buffer = buf, desc = "copy final review prompt" })
  vim.keymap.set("n", "<localleader>r", run, { buffer = buf, desc = "run final review prompt" })
  vim.keymap.set("n", "q", function()
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    state = nil
  end, { buffer = buf, desc = "close review prompt" })
  vim.api.nvim_create_autocmd("BufWriteCmd", { buffer = buf, callback = run })
  util.notify("Edit prompt; :write runs it, y copies it")
end

return M
