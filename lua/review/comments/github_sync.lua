-- review.nvim :: import GitHub review threads into the local store.
--
-- Idempotent: comments already present (matched by github_id) are refreshed from
-- upstream (github_id fields are upstream-authoritative, gap #8) without clobbering
-- local replies (which have no github_id).

local anchor = require("review.comments.anchor")
local util = require("review.util")

local M = {}

local function nullable(value)
  if value == vim.NIL then return nil end
  return value
end

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

local function reaction_counts(groups)
  local out = {}
  for _, group in ipairs(groups or {}) do
    local count = group.users and tonumber(group.users.totalCount) or 0
    if group.content and count > 0 then out[group.content] = count end
  end
  return out
end

--- Import (or refresh) all GitHub review threads into `store`.
---@param source table
---@param store table
---@return integer imported
function M.import(source, store)
  local threads, fetch_err = source:threads()
  if fetch_err then return 0, fetch_err end
  if not threads or #threads == 0 then
    return 0
  end
  local meta = source:metadata()
  local existing = by_github_id(store)
  local now = os.date("!%Y-%m-%dT%H:%M:%SZ")
  local imported, refreshed = 0, 0

  for _, t in ipairs(threads) do
    local nodes = (t.comments and t.comments.nodes) or {}
    local root_local_id = nil
    for i, cm in ipairs(nodes) do
      local gid = nullable(cm.id)
      local side = (t.diffSide == "LEFT") and "LEFT" or "RIGHT"
      local line = tonumber(nullable(cm.line) or nullable(cm.originalLine)
        or nullable(t.line) or nullable(t.originalLine)) or 1
      local path = nullable(cm.path) or nullable(t.path)
      if gid and path then
        local prev = existing[gid]
        if prev then
          refreshed = refreshed + 1
          -- Refresh upstream-authoritative fields only. Upstream can RESOLVE a thread,
          -- but a local resolve is never reverted by re-import (would lose user intent).
          prev.body = nullable(cm.body) or prev.body
          prev.file, prev.side = path, side
          prev.line_start, prev.line_end = line, line
          prev.author = nullable(cm.author) and nullable(cm.author.login) or prev.author
          prev.github_thread_id, prev.origin = t.id, "github"
          prev.reactions = reaction_counts(nullable(cm.reactionGroups) or {})
          if t.isResolved or prev.status == "resolved" then prev.status = "resolved"
          elseif t.isOutdated then prev.status = "outdated"
          else prev.status = "draft" end
          local rev = side == "LEFT" and source:base_rev() or source:head_rev()
          local lines = anchor.file_lines(meta.repo_root, rev, path) or {}
          prev.anchor = anchor.compute(lines, math.min(line, math.max(1, #lines)))
          if side == "LEFT" then prev.anchor.blob_sha = rev end
          prev.updated_at = now
          if i == 1 then root_local_id = prev.id end
          store.comments[prev.id] = prev
        else
          local rev = side == "LEFT" and source:base_rev() or source:head_rev()
          local lines = anchor.file_lines(meta.repo_root, rev, path) or {}
          local a = anchor.compute(lines, math.min(line, math.max(1, #lines)))
          if side == "LEFT" then a.blob_sha = rev end
          local comment = {
            id = util.uuid(), source_key = store.source_key, file = path, side = side,
            head_sha = source:head_rev(), base_sha = source:base_rev(),
            line_start = line, line_end = line, anchor = a, rename_lineage = {},
            kind = (nullable(cm.body) or ""):find("```suggestion") and "suggestion" or "normal",
            body = nullable(cm.body) or "", origin = "github",
            status = t.isResolved and "resolved" or (t.isOutdated and "outdated" or "draft"),
            github_id = gid, github_thread_id = t.id,
            in_reply_to = (i > 1) and root_local_id or nil,
            author = nullable(cm.author) and (nullable(cm.author.login) or "github") or "github",
            reactions = reaction_counts(nullable(cm.reactionGroups) or {}),
            created_at = nullable(cm.createdAt) or now, updated_at = now, hidden = false,
          }
          store.comments[comment.id] = comment
          if i == 1 then root_local_id = comment.id end
          imported = imported + 1
        end
      end
    end
  end
  store:save()
  return imported, nil, refreshed
end

return M
