-- review.nvim :: import GitHub review threads into the local store.
--
-- Idempotent: comments already present (matched by github_id) are refreshed from
-- upstream (github_id fields are upstream-authoritative, gap #8) without clobbering
-- local replies (which have no github_id).

local anchor = require("review.comments.anchor")
local util = require("review.util")

local M = {}

--- Index existing comments by github_id.
---@param store table
---@return table<string, table>
local function by_github_id(store)
  local idx = {}
  for _, c in pairs(store.comments) do
    if c.github_id then
      idx[c.github_id] = c
    end
  end
  return idx
end

--- Import (or refresh) all GitHub review threads into `store`.
---@param source table
---@param store table
---@return integer imported
function M.import(source, store)
  local threads = source:threads()
  if not threads or #threads == 0 then
    return 0
  end
  local meta = source:metadata()
  local existing = by_github_id(store)
  local now = os.date("!%Y-%m-%dT%H:%M:%SZ")
  local imported = 0

  for _, t in ipairs(threads) do
    local nodes = (t.comments and t.comments.nodes) or {}
    local root_local_id = nil
    for i, cm in ipairs(nodes) do
      local gid = cm.id
      local side = (t.diffSide == "LEFT") and "LEFT" or "RIGHT"
      local line = cm.line or cm.originalLine or t.line or t.originalLine or 1
      local path = cm.path or t.path
      local prev = existing[gid]
      if prev then
        -- Refresh upstream-authoritative fields only. Upstream can RESOLVE a thread,
        -- but a local resolve is never reverted by re-import (would lose user intent).
        prev.body = cm.body or prev.body
        if t.isResolved then
          prev.status = "resolved"
        end
        prev.updated_at = now
        if i == 1 then
          root_local_id = prev.id
        end
        store.comments[prev.id] = prev
      else
        local lines = anchor.file_lines(meta.repo_root, side == "LEFT" and source:base_rev() or nil, path) or {}
        local a = anchor.compute(lines, math.min(line, math.max(1, #lines)))
        local comment = {
          id = util.uuid(),
          source_key = store.source_key,
          file = path,
          side = side,
          head_sha = source:head_rev(),
          base_sha = source:base_rev(),
          line_start = line,
          line_end = line,
          anchor = a,
          rename_lineage = {},
          kind = (cm.body or ""):find("```suggestion") and "suggestion" or "normal",
          body = cm.body or "",
          origin = "github",
          status = t.isResolved and "resolved" or "draft",
          github_id = gid,
          in_reply_to = (i > 1) and root_local_id or nil,
          author = cm.author and cm.author.login or "github",
          created_at = cm.createdAt or now,
          updated_at = now,
          hidden = false,
        }
        store.comments[comment.id] = comment
        if i == 1 then
          root_local_id = comment.id
        end
        imported = imported + 1
      end
    end
  end
  store:save()
  return imported
end

return M
