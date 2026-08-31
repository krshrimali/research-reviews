-- review.nvim :: bottom-split comment/suggestion/reply composer.
--
-- Opens a scratch markdown buffer in a bottom split. `<CR><CR>` in normal mode or
-- `:w` submits; the buffer content (minus seeded quote lines) becomes the body.

local util = require("review.util")

local M = {}

--- Open a composer.
---@param opts table {
---   title=string, seed=string[]|nil, initial=string|nil, suggestion=boolean|nil,
---   on_submit=fun(body:string, is_suggestion:boolean, suggestion_text:string|nil),
--- }
function M.open(opts)
  opts = opts or {}
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "markdown"
  util.name_buffer(buf, "review://compose/" .. util.uuid():sub(1, 8))

  local header = {}
  table.insert(header, "<!-- " .. (opts.title or "Comment")
    .. " — write below; :w or <CR><CR> submits, q discards -->")
  if opts.seed then
    table.insert(header, "<!-- context:")
    for _, l in ipairs(opts.seed) do
      table.insert(header, "  " .. l)
    end
    table.insert(header, "-->")
  end
  local body_start = #header + 1
  if opts.suggestion then
    -- Pre-fill the fence with the selected source, the way GitHub does: a suggestion
    -- is an edit of those exact lines, so retyping them by hand is pure friction.
    local seeded = { "```suggestion" }
    vim.list_extend(seeded, opts.seed and vim.deepcopy(opts.seed) or { "" })
    table.insert(seeded, "```")
    vim.list_extend(header, seeded)
  else
    if opts.initial then
      vim.list_extend(header, vim.split(opts.initial, "\n", { plain = true }))
    else
      table.insert(header, "")
    end
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, header)

  vim.cmd("botright split")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  vim.api.nvim_win_set_height(win, math.max(8, math.floor(vim.o.lines * 0.25)))
  -- Land where the writing continues: inside the fence for a suggestion, at the END
  -- of an existing body when editing (typing at line 1 col 1 used to prepend).
  local line_count = vim.api.nvim_buf_line_count(buf)
  local cursor_line = math.min(body_start + 1, line_count)
  if opts.initial and not opts.suggestion then
    cursor_line = line_count
  end
  local cursor_col = #(vim.api.nvim_buf_get_lines(buf, cursor_line - 1, cursor_line, false)[1] or "")
  vim.api.nvim_win_set_cursor(win, { cursor_line, cursor_col })
  vim.cmd("startinsert!")

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

  --- Discard without submitting. The buffer is `acwrite` and modified, so plain `:q`
  --- fails with E37 and leaves a blocking hit-enter prompt — there was no way out
  --- short of knowing `:q!`.
  local function discard()
    submitted = true -- prevent a queued BufWriteCmd from firing after the close
    vim.bo[buf].modified = false
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    util.notify("comment discarded", vim.log.levels.INFO)
  end

  vim.keymap.set("n", "<CR><CR>", submit, { buffer = buf, desc = "submit review comment" })
  vim.keymap.set("n", "<localleader>s", submit, { buffer = buf, desc = "submit review comment" })
  vim.keymap.set("n", "q", discard, { buffer = buf, nowait = true, desc = "discard review comment" })
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    callback = function()
      vim.bo[buf].modified = false
      submit()
    end,
  })
end

return M
