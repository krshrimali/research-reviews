-- review.nvim :: JSON persistence with atomic writes.

local M = {}

--- Ensure a directory exists (mkdir -p semantics).
---@param dir string
function M.ensure_dir(dir)
  vim.fn.mkdir(dir, "p")
end

--- Read and decode a JSON file. Returns nil if missing or malformed.
---@param path string
---@return table|nil
function M.read(path)
  local fd = io.open(path, "r")
  if not fd then
    return nil
  end
  local content = fd:read("*a")
  fd:close()
  if not content or content == "" then
    return nil
  end
  local ok, decoded = pcall(vim.json.decode, content)
  if not ok then
    return nil
  end
  return decoded
end

--- Encode and write a table to JSON atomically (temp file + rename).
--- Returns ok, err.
---@param path string
---@param tbl table
---@return boolean ok, string|nil err
function M.write(path, tbl)
  local dir = vim.fn.fnamemodify(path, ":h")
  M.ensure_dir(dir)
  local ok, encoded = pcall(vim.json.encode, tbl)
  if not ok then
    return false, "encode failed: " .. tostring(encoded)
  end
  -- Unique-ish temp name without Math.random reliance on collisions mattering.
  local tmp = string.format("%s.tmp.%d.%d", path, vim.fn.getpid(), vim.loop.hrtime() % 1000000)
  local fd, oerr = io.open(tmp, "w")
  if not fd then
    return false, "open temp failed: " .. tostring(oerr)
  end
  fd:write(encoded)
  fd:close()
  -- os.rename is atomic within a filesystem.
  local rok, rerr = os.rename(tmp, path)
  if not rok then
    os.remove(tmp)
    return false, "rename failed: " .. tostring(rerr)
  end
  return true
end

return M
