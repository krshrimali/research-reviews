local M = { records = {}, max_records = 200 }

function M.record(kind, label, elapsed_ms, ok)
  M.records[#M.records + 1] = {
    at = os.date("%H:%M:%S"), kind = kind, label = label,
    elapsed_ms = math.floor(elapsed_ms * 10 + 0.5) / 10, ok = ok,
  }
  while #M.records > M.max_records do table.remove(M.records, 1) end
end

function M.report()
  local lines = { "# review.nvim performance", "", "Most recent operations first.", "",
    "| time | operation | duration | result |", "|---|---|---:|---|" }
  for i = #M.records, 1, -1 do
    local r = M.records[i]
    lines[#lines + 1] = ("| %s | `%s` | %.1f ms | %s |"):format(
      r.at, r.label:gsub("|", "\\|"), r.elapsed_ms, r.ok == false and "error" or "ok")
  end
  if #M.records == 0 then lines[#lines + 1] = "| — | no recorded operations | — | — |" end
  return lines
end

function M.open()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype, vim.bo[buf].bufhidden, vim.bo[buf].filetype = "nofile", "wipe", "markdown"
  vim.api.nvim_buf_set_name(buf, "review://performance")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, M.report())
  vim.bo[buf].modifiable = false
  vim.cmd("tabnew")
  vim.api.nvim_win_set_buf(0, buf)
  vim.keymap.set("n", "q", "<cmd>tabclose<cr>", { buffer = buf, nowait = true })
end

return M
