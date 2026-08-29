local M = {}

function M.lines(payload, drafts)
  local lines = {
    "# Publish GitHub review", "",
    ("Event: `%s`"):format(payload.event or "COMMENT"),
    ("Commit: `%s`"):format(payload.commit_id or ""),
    ("Comments: **%d**"):format(#drafts), "",
    "## Review body", "", payload.body or "", "",
    "## Inline comments", "",
  }
  for i, root in ipairs(drafts) do
    lines[#lines + 1] = ("### %d. `%s:%d` · %s"):format(
      i, root.file, root.line_end or root.line_start or 1, root.side or "RIGHT")
    lines[#lines + 1] = ""
    vim.list_extend(lines, vim.split(root.body or "", "\n", { plain = true }))
    lines[#lines + 1] = ""
  end
  vim.list_extend(lines, { "---", "Ctrl-S publish · q/Esc cancel" })
  return lines
end

function M.open(payload, drafts, on_submit)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype, vim.bo[buf].bufhidden, vim.bo[buf].filetype = "nofile", "wipe", "markdown"
  vim.api.nvim_buf_set_name(buf, "review://publish-preview")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, M.lines(payload, drafts))
  vim.bo[buf].modifiable = false
  vim.cmd("botright split")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  vim.api.nvim_win_set_height(win, math.max(12, math.floor(vim.o.lines * 0.4)))
  vim.wo[win].wrap, vim.wo[win].linebreak = true, true
  pcall(vim.treesitter.start, buf, "markdown")
  local closed = false
  local function close()
    if not closed and vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    closed = true
  end
  vim.keymap.set("n", "q", close, { buffer = buf, nowait = true })
  vim.keymap.set("n", "<Esc>", close, { buffer = buf, nowait = true })
  vim.keymap.set("n", "<C-s>", function()
    if closed then return end
    close()
    on_submit()
  end, { buffer = buf, nowait = true, desc = "publish review to GitHub" })
end

return M
