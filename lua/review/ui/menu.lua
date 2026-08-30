-- review.nvim :: contextual action menu.
--
-- A small floating menu that shows only the actions valid at the cursor, each with a
-- single-key accelerator that fires immediately (no <CR>). This is the whole point of
-- the "one key to learn" model: you press <leader>p and recognize the action instead
-- of memorizing a dozen keymaps.

local M = {}

--- Show a menu. `items` is an ordered list of:
---   { key = "c", label = "Comment on these lines", fn = function() ... end }
---   { sep = "review" }                       -- a separator/section label
--- Pressing an item's key closes the menu and runs its fn. q / <Esc> cancel.
---@param items table[]
---@param opts table|nil { title = string }
function M.open(items, opts)
  opts = opts or {}
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "review-menu"

  local title = opts.title or "Review actions"
  local lines = {}
  local width = #title + 2
  local key_lines = {} -- rendered line index (0-based) -> item, for highlighting

  for _, it in ipairs(items) do
    if it.sep then
      table.insert(lines, "── " .. it.sep .. " " .. string.rep("─", math.max(1, 20 - #it.sep)))
    else
      local text = string.format("  %s  %s", it.key, it.label)
      table.insert(lines, text)
      key_lines[#lines - 1] = it
      width = math.max(width, #text + 2)
    end
  end

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "cursor",
    row = 1,
    col = 0,
    width = math.min(width, vim.o.columns - 4),
    height = #lines,
    style = "minimal",
    border = "rounded",
    title = " " .. title .. " ",
    title_pos = "left",
  })
  vim.wo[win].cursorline = true

  -- Highlight the accelerator key on each action line.
  local ns = vim.api.nvim_create_namespace("review_menu")
  for lnum, _ in pairs(key_lines) do
    pcall(vim.api.nvim_buf_set_extmark, buf, ns, lnum, 2, {
      end_col = 3,
      hl_group = "Special",
    })
  end

  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  -- One buffer-local map per accelerator → close, then run on the next tick so the
  -- action can open its own float/split cleanly.
  for _, it in pairs(key_lines) do
    vim.keymap.set("n", it.key, function()
      close()
      vim.schedule(it.fn)
    end, { buffer = buf, nowait = true })
  end
  for _, k in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", k, close, { buffer = buf, nowait = true })
  end
  -- Also allow <CR> on a highlighted line to trigger it.
  vim.keymap.set("n", "<CR>", function()
    local it = key_lines[vim.api.nvim_win_get_cursor(0)[1] - 1]
    if it then
      close()
      vim.schedule(it.fn)
    end
  end, { buffer = buf, nowait = true })
end

--- Confirm a destructive action without blocking the editor.
---
--- `vim.fn.confirm` freezes the whole UI on a modal prompt and cannot be driven by
--- the same recognition-over-recall model as the rest of the plugin, so destructive
--- actions reuse this float instead. Cancel is the default: `q`/`<Esc>` just close.
---@param question string
---@param verb string   the affirmative label, e.g. "Delete"
---@param on_confirm fun()
function M.confirm(question, verb, on_confirm)
  local key = verb:sub(1, 1):lower()
  M.open({
    { key = key, label = verb, fn = on_confirm },
    { key = "c", label = "Cancel", fn = function() end },
  }, { title = question })
end

return M
