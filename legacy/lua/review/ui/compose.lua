-- review.nvim :: bottom-split comment/suggestion/reply composer.
--
-- Opens a scratch markdown buffer in a bottom split. `<CR><CR>` in normal mode or
-- `:w` submits; the buffer content (minus seeded quote lines) becomes the body.

local util = require("review.util")

local M = {}

--- Open a composer.
---@param opts table {
---   title=string, seed=string[]|nil, suggestion=boolean|nil,
---   on_submit=fun(body:string, is_suggestion:boolean, suggestion_text:string|nil),
--- }
function M.open(opts)
  opts = opts or {}
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "markdown"
  vim.api.nvim_buf_set_name(buf, "review://compose/" .. util.uuid():sub(1, 8))

  local header = {}
  table.insert(header, "<!-- " .. (opts.title or "Comment") .. " — write below; :w or <CR><CR> to submit -->")
  if opts.seed then
    table.insert(header, "<!-- context:")
    for _, l in ipairs(opts.seed) do
      table.insert(header, "  " .. l)
    end
    table.insert(header, "-->")
  end
  local body_start = #header + 1
  if opts.suggestion then
    vim.list_extend(header, { "```suggestion", "", "```" })
  else
    table.insert(header, "")
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, header)

  vim.cmd("botright split")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  vim.api.nvim_win_set_height(win, math.max(8, math.floor(vim.o.lines * 0.25)))
  vim.api.nvim_win_set_cursor(win, { math.min(body_start + 1, vim.api.nvim_buf_line_count(buf)), 0 })
  vim.cmd("startinsert")

  local submitted = false
  local function submit()
    if submitted then
      return
    end
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    -- Drop the HTML-comment header block(s); keep everything else verbatim (including
    -- body lines that happen to be indented or contain ``` fences).
    local body_lines = {}
    local in_comment = false
    for _, l in ipairs(lines) do
      if in_comment then
        if l:find("%-%->") then
          in_comment = false
        end
      elseif l:match("^%s*<!%-%-") then
        -- Start of a comment; if it doesn't close on the same line, keep skipping.
        if not l:find("%-%->") then
          in_comment = true
        end
      else
        table.insert(body_lines, l)
      end
    end
    local text = util.trim(table.concat(body_lines, "\n"))
    if text == "" then
      util.notify("empty comment discarded", vim.log.levels.INFO)
    else
      -- Extract the LAST ```suggestion block (the seeded template may leave an empty
      -- one first); only treat it as a suggestion if it has real content.
      local suggestion
      for block in text:gmatch("```suggestion%s*\n(.-)```") do
        suggestion = block
      end
      if suggestion then
        suggestion = suggestion:gsub("%s+$", "")
      end
      local is_suggestion = suggestion ~= nil and util.trim(suggestion) ~= ""
      submitted = true
      opts.on_submit(text, is_suggestion, is_suggestion and suggestion or nil)
    end
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  vim.keymap.set("n", "<CR><CR>", submit, { buffer = buf, desc = "submit review comment" })
  vim.keymap.set("n", "<localleader>s", submit, { buffer = buf, desc = "submit review comment" })
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    callback = function()
      vim.bo[buf].modified = false
      submit()
    end,
  })
end

return M
