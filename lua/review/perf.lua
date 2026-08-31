local M = { records = {}, max_records = 200 }

--- A readable, bounded label for an argv.
---
--- Truncating to the first three arguments made every `git diff --numstat <a> <b>`
--- row identical, so a profile with eleven of them could not tell you which one was
--- slow. Keep the whole command, shortening long revs to their short form.
---@param argv string[]
---@return string
function M.label(argv)
  local parts = {}
  for _, arg in ipairs(argv or {}) do
    arg = tostring(arg)
    if arg:match("^%x%x%x%x%x%x%x%x%x+$") then
      arg = arg:sub(1, 8)
    elseif arg:match("^%x+%.%.%.%x+$") then
      arg = arg:gsub("(%x%x%x%x%x%x%x%x)%x*", "%1")
    elseif #arg > 40 then
      arg = arg:sub(1, 37) .. "…"
    end
    parts[#parts + 1] = arg
  end
  local label = table.concat(parts, " ")
  return #label > 110 and (label:sub(1, 107) .. "…") or label
end

function M.record(kind, label, elapsed_ms, ok)
  M.records[#M.records + 1] = {
    at = os.date("%H:%M:%S"), kind = kind, label = label,
    elapsed_ms = math.floor(elapsed_ms * 10 + 0.5) / 10, ok = ok,
  }
  while #M.records > M.max_records do table.remove(M.records, 1) end
end

function M.report()
  local total, slowest, failures = 0, nil, 0
  for _, r in ipairs(M.records) do
    total = total + (r.elapsed_ms or 0)
    if not slowest or (r.elapsed_ms or 0) > (slowest.elapsed_ms or 0) then slowest = r end
    if r.ok == false then failures = failures + 1 end
  end
  local lines = { "# review.nvim performance", "" }
  if #M.records > 0 then
    lines[#lines + 1] = ("%d operations · %.0f ms total · %.1f ms average · %d failed"):format(
      #M.records, total, total / #M.records, failures)
    if slowest then
      lines[#lines + 1] = ("slowest: `%s` at %.1f ms"):format(slowest.label, slowest.elapsed_ms)
    end
    lines[#lines + 1] = ""
  end
  vim.list_extend(lines, { "Most recent operations first.", "",
    "| time | operation | duration | result |", "|---|---|---:|---|" })
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
  require("review.util").name_buffer(buf, "review://performance")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, M.report())
  vim.bo[buf].modifiable = false
  vim.cmd("tabnew")
  vim.api.nvim_win_set_buf(0, buf)
  require("review.util").wrap_window()
  vim.keymap.set("n", "q", "<cmd>tabclose<cr>", { buffer = buf, nowait = true })
end

return M
