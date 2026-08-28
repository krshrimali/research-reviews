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

--- Generate a RFC-4122-ish v4 UUID using Neovim's PRNG.
--- Not cryptographic; used only as a local record id.
---@return string
function M.uuid()
  local template = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
  return (
    template:gsub("[xy]", function(c)
      local v = (c == "x") and math.random(0, 15) or math.random(8, 11)
      return string.format("%x", v)
    end)
  )
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

--- Notify helper that tags the source.
---@param msg string
---@param level integer|nil vim.log.levels.*
function M.notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "review.nvim" })
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
  if vim.fn.strchars(s) <= n then
    return s
  end
  return vim.fn.strcharpart(s, 0, math.max(0, n - 1)) .. "…"
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
