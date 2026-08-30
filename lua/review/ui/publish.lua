-- review.nvim :: GitHub review submission preview.
--
-- The preview is the last stop before anything leaves the editor, so it is also
-- where the review *verdict* and summary are chosen: a review tool that can only
-- ever post "COMMENT" cannot finish a review.

local util = require("review.util")

local M = {}

M.events = { "COMMENT", "APPROVE", "REQUEST_CHANGES" }

local EVENT_HELP = {
  COMMENT = "leaves feedback without an explicit verdict",
  APPROVE = "approves the pull request",
  REQUEST_CHANGES = "blocks the pull request until addressed",
}

--- The next event in the cycle.
---@param event string
---@return string
function M.next_event(event)
  for i, value in ipairs(M.events) do
    if value == event then return M.events[(i % #M.events) + 1] end
  end
  return M.events[1]
end

function M.lines(payload, drafts)
  local event = payload.event or "COMMENT"
  local body = payload.body or ""
  local lines = {
    "# Publish GitHub review", "",
    ("Verdict: `%s` — %s"):format(event, EVENT_HELP[event] or ""),
    ("Commit: `%s`"):format(payload.commit_id or ""),
    ("Comments: **%d**"):format(#drafts), "",
    "## Review summary", "",
  }
  if vim.trim(body) == "" then
    lines[#lines + 1] = "_(empty — press b to write one)_"
  else
    vim.list_extend(lines, vim.split(body, "\n", { plain = true }))
  end
  vim.list_extend(lines, { "", "## Inline comments", "" })
  for i, root in ipairs(drafts) do
    local first = root.line_start or 1
    local last = root.line_end or first
    local location = first == last and tostring(first) or ("%d-%d"):format(first, last)
    lines[#lines + 1] = ("### %d. `%s:%s` · %s"):format(i, root.file, location, root.side or "RIGHT")
    lines[#lines + 1] = ""
    vim.list_extend(lines, vim.split(root.body or "", "\n", { plain = true }))
    lines[#lines + 1] = ""
  end
  vim.list_extend(lines, {
    "---",
    "Ctrl-S publish · e cycle verdict · b edit summary · q/Esc cancel",
  })
  return lines
end

--- Open the preview.
---@param payload table   mutated in place as the verdict/summary change
---@param drafts table[]
---@param on_submit fun()
---@param opts table|nil  { on_change = fun(payload) }
function M.open(payload, drafts, on_submit, opts)
  opts = opts or {}
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype, vim.bo[buf].bufhidden, vim.bo[buf].filetype = "nofile", "wipe", "markdown"
  pcall(vim.api.nvim_buf_set_name, buf, "review://publish-preview")
  vim.cmd("botright split")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  vim.api.nvim_win_set_height(win, math.max(12, math.floor(vim.o.lines * 0.4)))
  vim.wo[win].wrap, vim.wo[win].linebreak = true, true

  local function render()
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, M.lines(payload, drafts))
    vim.bo[buf].modifiable = false
  end
  render()
  pcall(vim.treesitter.start, buf, "markdown")

  local closed = false
  local function close()
    if not closed and vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    closed = true
  end
  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, desc = desc })
  end

  map("q", close, "cancel publish")
  map("<Esc>", close, "cancel publish")
  map("e", function()
    payload.event = M.next_event(payload.event or "COMMENT")
    if opts.on_change then opts.on_change(payload) end
    render()
    util.notify("verdict: " .. payload.event)
  end, "cycle review verdict")
  map("b", function()
    require("review.ui.compose").open({
      title = "Review summary",
      initial = payload.body ~= "" and payload.body or nil,
      on_submit = function(body)
        payload.body = body
        if opts.on_change then opts.on_change(payload) end
        render()
      end,
    })
  end, "edit review summary")
  map("<C-s>", function()
    if closed then return end
    if payload.event == "REQUEST_CHANGES" and vim.trim(payload.body or "") == "" then
      util.notify("requesting changes needs a summary — press b", vim.log.levels.WARN)
      return
    end
    close()
    on_submit()
  end, "publish review to GitHub")
end

return M
