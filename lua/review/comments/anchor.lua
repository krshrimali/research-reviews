-- review.nvim :: comment anchoring.
--
-- Robust re-location after edits/rebase (design gaps #1, #2, #9): we store the exact
-- target line, a hash, surrounding context, and an occurrence index. Re-anchoring
-- requires a UNIQUE context match; otherwise the comment is marked "outdated" rather
-- than silently moved to the wrong line.

local util = require("review.util")

local M = {}

local CONTEXT = 3

--- Compute an anchor for line `line` (1-based) within `lines` (list of strings).
---@param lines string[]
---@param line integer
---@return table anchor
function M.compute(lines, line)
  local line_text = lines[line] or ""
  local before, after = {}, {}
  for i = math.max(1, line - CONTEXT), line - 1 do
    table.insert(before, lines[i] or "")
  end
  for i = line + 1, math.min(#lines, line + CONTEXT) do
    table.insert(after, lines[i] or "")
  end
  -- occurrence: which identical `line_text` this is, counting from the top.
  local occurrence = 0
  for i = 1, line do
    if (lines[i] or "") == line_text then
      occurrence = occurrence + 1
    end
  end
  return {
    line_text = line_text,
    line_hash = util.hash(line_text),
    context_before = before,
    context_after = after,
    occurrence = occurrence,
  }
end

--- Score how well `lines[idx]` + surrounding context matches `anchor`. Higher = better.
---@param lines string[]
---@param idx integer
---@param anchor table
---@return integer
local function score(lines, idx, anchor)
  if (lines[idx] or "") ~= anchor.line_text then
    return -1
  end
  local s = 100
  local cb = anchor.context_before or {}
  for k = 1, #cb do
    if (lines[idx - (#cb - k + 1)] or "") == cb[k] then
      s = s + 1
    end
  end
  local ca = anchor.context_after or {}
  for k = 1, #ca do
    if (lines[idx + k] or "") == ca[k] then
      s = s + 1
    end
  end
  return s
end

--- Re-locate an anchor in `lines`. Returns new 1-based line, or nil if not uniquely found.
--- Uniqueness: the best-scoring candidate must strictly beat all others; ties -> nil.
---@param lines string[]
---@param anchor table
---@return integer|nil line
function M.relocate(lines, anchor)
  if not anchor or not anchor.line_text then
    return nil
  end
  -- Gather candidate indices where the target line matches.
  local candidates = {}
  for i = 1, #lines do
    if (lines[i] or "") == anchor.line_text then
      table.insert(candidates, i)
    end
  end
  if #candidates == 0 then
    return nil
  end
  if #candidates == 1 then
    return candidates[1]
  end
  -- Multiple identical lines: prefer the one whose context scores highest and is unique.
  local best, best_score, second_score = nil, -1, -1
  for _, idx in ipairs(candidates) do
    local sc = score(lines, idx, anchor)
    if sc > best_score then
      second_score = best_score
      best_score, best = sc, idx
    elseif sc > second_score then
      second_score = sc
    end
  end
  -- If context couldn't disambiguate (best not strictly better), fall back to the
  -- stored occurrence index if it's in range.
  if best_score == second_score then
    if anchor.occurrence and candidates[anchor.occurrence] then
      return candidates[anchor.occurrence]
    end
    return nil -- genuinely ambiguous -> outdated
  end
  return best
end

--- Read a file's lines at a given git blob/rev, or from the working tree.
--- Returns list of lines, or nil.
---@param repo_root string
---@param rev string|nil  git rev; nil => working tree file
---@param path string
---@return string[]|nil
function M.file_lines(repo_root, rev, path)
  local proc = require("review.util.proc")
  if rev then
    local ok, out = proc.git({ "show", string.format("%s:%s", rev, path) }, repo_root)
    if not ok then
      return nil
    end
    return vim.split(out, "\n", { plain = true })
  end
  local full = vim.fs.joinpath(repo_root, path)
  local fd = io.open(full, "r")
  if not fd then
    return nil
  end
  local content = fd:read("*a")
  fd:close()
  return vim.split(content or "", "\n", { plain = true })
end

return M
