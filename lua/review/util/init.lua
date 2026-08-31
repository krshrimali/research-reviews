-- review.nvim :: small shared utilities
-- Kept dependency-free so every other module can require it safely.

local M = {}

--- Deep-extend defaults with user opts (opts win). Never mutates inputs.
---@param defaults table
---@param opts table|nil
---@return table
function M.merge(defaults, opts)
  return vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
end

--- Random bytes for id generation. `vim.uv.random` is the only source here that is
--- actually independent per process; LuaJIT's `math.random` is NOT seeded by Neovim,
--- so two editors would otherwise mint the *same* comment ids in the same order and
--- silently clobber each other through the merge-on-write store.
---@param count integer
---@return integer[]
local function random_bytes(count)
  local ok, bytes = pcall(function()
    return { string.byte(vim.uv.random(count), 1, count) }
  end)
  if ok and bytes and #bytes == count then
    return bytes
  end
  -- Fallback: seed once from a per-process entropy mix, then use math.random.
  if not M._seeded then
    local seed = (vim.uv.hrtime() % 2147483647)
      + (vim.uv.os_getpid() * 2654435761) % 2147483647
    math.randomseed(seed % 2147483647)
    M._seeded = true
  end
  local out = {}
  for i = 1, count do
    out[i] = math.random(0, 255)
  end
  return out
end

M._random_bytes = random_bytes

--- Generate a RFC-4122 v4 UUID. Not cryptographic, but it MUST be unique across
--- concurrent Neovim instances: comment ids are the merge key of the shared store.
---@return string
function M.uuid()
  local bytes = random_bytes(16)
  bytes[7] = 0x40 + (bytes[7] % 0x10) -- version 4
  bytes[9] = 0x80 + (bytes[9] % 0x40) -- variant 10xx
  local hex = {}
  for i = 1, 16 do
    hex[i] = string.format("%02x", bytes[i])
  end
  return table.concat({
    table.concat(hex, "", 1, 4),
    table.concat(hex, "", 5, 6),
    table.concat(hex, "", 7, 8),
    table.concat(hex, "", 9, 10),
    table.concat(hex, "", 11, 16),
  }, "-")
end

--- Short, filesystem-safe hash of a string (for repo/source keys).
---@param s string
---@return string
function M.hash(s)
  -- fnv-1a 32-bit; collisions are irrelevant for local dir naming.
  local h = 2166136261
  for i = 1, #s do
    h = bit.bxor(h, s:byte(i))
    h = (h * 16777619) % 4294967296
  end
  return string.format("%08x", h)
end

local notice = {}

local function show_notice(msg, level, timeout)
  vim.schedule(function()
    if #vim.api.nvim_list_uis() == 0 then return end
    if notice.win and vim.api.nvim_win_is_valid(notice.win) then
      vim.api.nvim_win_close(notice.win, true)
    end
    local text = "review.nvim · " .. (msg or ""):gsub("[\r\n]+", " ")
    local width = math.min(math.max(28, vim.fn.strdisplaywidth(text)), math.max(28, vim.o.columns - 6))
    text = M.truncate(text, width)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype, vim.bo[buf].bufhidden = "nofile", "wipe"
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { text })
    local hl = level == vim.log.levels.ERROR and "ErrorMsg"
      or level == vim.log.levels.WARN and "WarningMsg" or "NormalFloat"
    notice.buf = buf
    notice.win = vim.api.nvim_open_win(buf, false, {
      relative = "editor", row = math.max(0, vim.o.lines - 5),
      col = math.max(0, vim.o.columns - width - 3), width = width, height = 1,
      style = "minimal", border = "rounded", focusable = false, noautocmd = true, zindex = 250,
    })
    vim.wo[notice.win].winhl = "Normal:" .. hl .. ",FloatBorder:" .. hl
    vim.defer_fn(function()
      if notice.buf == buf and notice.win and vim.api.nvim_win_is_valid(notice.win) then
        vim.api.nvim_win_close(notice.win, true)
      end
    end, timeout or 3500)
  end)
end

---@param msg string
---@param level integer|nil vim.log.levels.*
function M.notify(msg, level)
  M.last_notification = msg
  show_notice(msg, level, level == vim.log.levels.ERROR and 6500 or 3500)
end

---@param msg string
function M.progress(msg)
  show_notice(msg, vim.log.levels.INFO, 10000)
end

--- An animated, self-dismissing progress notice for a long blocking call.
--- Returns a handle with `stop()`; safe to stop twice.
---@param msg string
---@return table
function M.spinner(msg)
  local frames = { "\u{280B}", "\u{2819}", "\u{2839}", "\u{2838}", "\u{283C}",
    "\u{2834}", "\u{2826}", "\u{2827}", "\u{2807}", "\u{280F}" }
  local frame = 0
  local timer = vim.uv.new_timer()
  local handle = { stopped = false }
  local function tick()
    frame = frame % #frames + 1
    show_notice(frames[frame] .. " " .. msg, vim.log.levels.INFO, 2000)
  end
  tick()
  if timer then
    timer:start(120, 120, vim.schedule_wrap(function()
      if handle.stopped then return end
      tick()
    end))
  end
  function handle.stop()
    if handle.stopped then return end
    handle.stopped = true
    if timer then
      timer:stop()
      if not timer:is_closing() then timer:close() end
    end
  end
  return handle
end

--- `vim.ui.select` for lists that are not files.
---
--- Snacks' default previewer assumes every item has a `file` and renders
--- "error: Item has no `file`" beside a list of reaction names. Ask it for no
--- preview; every other backend ignores the extra key.
---@param items any[]
---@param opts table
---@param on_choice fun(item:any, idx:integer|nil)
function M.select(items, opts, on_choice)
  opts = vim.tbl_extend("keep", opts or {}, {
    -- Only the preview: overriding `layout` too would discard the picker's own
    -- height fitting for short lists.
    snacks = { preview = "none" },
  })
  vim.ui.select(items, opts, on_choice)
end

--- Give a scratch buffer a stable `review://` name.
---
--- Neovim refuses a name another buffer already holds (E95), so any surface with a
--- fixed name — the help tab, the profile, the workspace — threw the second time it
--- was opened. The stale buffer is wiped first; it is always one of ours.
---@param buf integer
---@param name string
---@return boolean named
function M.name_buffer(buf, name)
  for _, other in ipairs(vim.api.nvim_list_bufs()) do
    if other ~= buf and vim.api.nvim_buf_is_valid(other)
        and vim.api.nvim_buf_get_name(other) == name then
      pcall(vim.api.nvim_buf_delete, other, { force = true })
    end
  end
  return (pcall(vim.api.nvim_buf_set_name, buf, name))
end

--- Make a window show all of its content instead of cutting it off.
---
--- Every surface here is prose or wrapped-width UI, never a column-aligned table, so
--- soft wrapping is always the right answer. Set explicitly rather than inherited:
--- a window inherits the *global* 'wrap', so one `set nowrap` anywhere silently
--- truncated the review's own panels.
---@param win integer|nil  defaults to the current window
function M.wrap_window(win)
  win = win or vim.api.nvim_get_current_win()
  if not vim.api.nvim_win_is_valid(win) then
    return
  end
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true -- break on words, not mid-token
  vim.wo[win].breakindent = true -- keep a wrapped line under its own indent
  -- Deliberately no 'showbreak': breakindent already marks a continuation, and a
  -- marker costs two columns of a 42-column panel while making wrapped prose read
  -- like a new entry.
end

--- Return true and the module if `require(name)` succeeds, else false, err.
---@param name string
---@return boolean ok, any mod_or_err
function M.has(name)
  local ok, mod = pcall(require, name)
  return ok, mod
end

--- Trim surrounding whitespace.
---@param s string
---@return string
function M.trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Truncate to n chars with an ellipsis; single-line.
---@param s string
---@param n integer
---@return string
function M.truncate(s, n)
  s = (s or ""):gsub("[\r\n]+", " ")
  if n <= 0 then return "" end
  local offsets, i = {}, 1
  while i <= #s do
    offsets[#offsets + 1] = i
    local byte = s:byte(i)
    i = i + (byte < 0x80 and 1 or byte < 0xE0 and 2 or byte < 0xF0 and 3 or 4)
  end
  if #offsets <= n then return s end
  if n == 1 then return "…" end
  return s:sub(1, offsets[n] - 1) .. "…"
end

---Normalize GitHub's supported inline HTML into readable Markdown. This also
---removes CR characters returned by APIs that preserve Windows line endings.
---@param text string|nil
---@return string
function M.normalize_markdown(text)
  text = tostring(text or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
  text = text:gsub("<[bB][rR]%s*/?>", "\n")
  text = text:gsub("<[sS][uU][mM][mM][aA][rR][yY][^>]*>(.-)</[sS][uU][mM][mM][aA][rR][yY]>", "**%1**")
  text = text:gsub("<[aA]%s+[^>]-[hH][rR][eE][fF]%s*=%s*\"([^\"]+)\"[^>]*>(.-)</[aA]>", "[%2](%1)")
  text = text:gsub("<[aA]%s+[^>]-[hH][rR][eE][fF]%s*=%s*'([^']+)'[^>]*>(.-)</[aA]>", "[%2](%1)")
  text = text:gsub("<[cC][oO][dD][eE][^>]*>(.-)</[cC][oO][dD][eE]>", "`%1`")
  text = text:gsub("<[lL][iI][^>]*>", "\n- "):gsub("</[lL][iI]>", "")
  text = text:gsub("</?[uU][lL][^>]*>", "\n"):gsub("</?[oO][lL][^>]*>", "\n")
  text = text:gsub("</?[dD][eE][tT][aA][iI][lL][sS][^>]*>", "\n")
  text = text:gsub("</?[pP][^>]*>", "\n"):gsub("<[^>]+>", "")
  local entities = { amp = "&", lt = "<", gt = ">", quot = '"', apos = "'", ['#39'] = "'" }
  text = text:gsub("&([%w#]+);", function(name) return entities[name] or ("&" .. name .. ";") end)
  return M.trim(text:gsub("\n\n\n+", "\n\n"))
end

--- ISO-8601 -> "2h ago" style relative time. Falls back to the raw string.
---@param iso string|nil
---@return string
function M.relative_time(iso)
  if not iso or iso == "" then
    return "unknown"
  end
  local y, mo, d, h, mi, s =
    iso:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
  if not y then
    return iso
  end
  local t = os.time({
    year = tonumber(y),
    month = tonumber(mo),
    day = tonumber(d),
    hour = tonumber(h),
    min = tonumber(mi),
    sec = tonumber(s),
  })
  -- os.time treats the table as local time; good enough for a relative label.
  local diff = os.time() - t
  if diff < 0 then
    diff = 0
  end
  local units = {
    { 31536000, "y" },
    { 2592000, "mo" },
    { 86400, "d" },
    { 3600, "h" },
    { 60, "m" },
  }
  for _, u in ipairs(units) do
    if diff >= u[1] then
      return string.format("%d%s ago", math.floor(diff / u[1]), u[2])
    end
  end
  return "just now"
end

return M
