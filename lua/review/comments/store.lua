-- review.nvim :: comment store — CRUD, threads, persistence, re-anchoring.
--
-- One Store instance per open Source. Backed by state.lua (merge-on-write).

local state = require("review.state")
local anchor = require("review.comments.anchor")
local util = require("review.util")

---@class Store
---@field source table
---@field repo_key string
---@field source_key string
---@field comments table<string, table>
---@field sessions table<string, table>
local Store = {}
Store.__index = Store

--- Load (or create) the store for a source.
---@param source table
---@return Store
function Store.for_source(source)
  local repo_key = source:repo_key()
  local source_key = source:key()
  local doc = state.load(repo_key, source_key)
  local self = setmetatable({
    source = source,
    repo_key = repo_key,
    source_key = source_key,
    comments = doc.comments or {},
    sessions = doc.sessions or {},
    tombstones = doc.tombstones or {},
    viewed = (doc.meta and doc.meta.viewed) or {},
    review = (doc.meta and doc.meta.review) or { event = "COMMENT", body = "" },
  }, Store)
  -- Defensively drop any tombstoned records that lingered on disk.
  for id in pairs(self.tombstones) do
    self.comments[id] = nil
  end
  return self
end

--- Persist current state (merge-on-write).
function Store:save()
  local ok, err = state.save(self.repo_key, self.source_key, {
    schema_version = state.SCHEMA_VERSION,
    source_key = self.source_key,
    comments = self.comments,
    sessions = self.sessions,
    tombstones = self.tombstones,
    meta = { viewed = self.viewed, review = self.review },
  })
  if not ok then
    util.notify("failed to persist comments: " .. tostring(err), vim.log.levels.ERROR)
  end
  return ok
end

--- The pending review submission (event + summary body). Persisted with the store so
--- a summary drafted over several sittings survives restarts.
---@return table { event=string, body=string }
function Store:review_draft()
  self.review = self.review or { event = "COMMENT", body = "" }
  self.review.event = self.review.event or "COMMENT"
  self.review.body = self.review.body or ""
  return self.review
end

---@param fields table { event?=string, body?=string }
function Store:set_review_draft(fields)
  local draft = self:review_draft()
  for key, value in pairs(fields or {}) do
    draft[key] = value
  end
  self:save()
  return draft
end

function Store:is_viewed(file)
  return self.viewed[file] == self.source:head_rev()
end

function Store:set_viewed(file, value)
  self.viewed[file] = value == false and nil or self.source:head_rev()
  self:save()
  return self:is_viewed(file)
end

function Store:viewed_progress()
  local files, viewed = self.source:files(), 0
  for _, file in ipairs(files) do if self:is_viewed(file.path) then viewed = viewed + 1 end end
  return viewed, #files
end

--- The status a non-resolved, non-outdated comment should carry. Anything with an
--- upstream id is already published; only local-only records are drafts.
---@param c table
---@return string
local function open_status(c)
  return c.github_id and "published" or "draft"
end

--- Add a new root comment.
---@param fields table { file, side, line_start, line_end, body, kind?, suggestion_text?, origin?, head_sha?, base_sha? }
---@return table comment
function Store:add(fields)
  local now = os.date("!%Y-%m-%dT%H:%M:%SZ")
  local meta = self.source:metadata()
  local side = fields.side or "RIGHT"
  local rev = (side == "LEFT") and self.source:base_rev() or self.source:head_rev()
  -- Always anchor against the reviewed revision. The selected branch or commit may
  -- not be checked out in the user's working tree.
  local lines = anchor.file_lines(meta.repo_root, rev, fields.file) or {}
  local a = anchor.compute(lines, fields.line_start)
  if side == "LEFT" then
    a.blob_sha = rev
  end
  local comment = {
    id = util.uuid(),
    source_key = self.source_key,
    file = fields.file,
    side = side,
    head_sha = fields.head_sha or self.source:head_rev(),
    base_sha = fields.base_sha or self.source:base_rev(),
    line_start = fields.line_start,
    line_end = fields.line_end or fields.line_start,
    anchor = a,
    rename_lineage = {},
    kind = fields.kind or "normal",
    suggestion_text = fields.suggestion_text,
    body = fields.body or "",
    origin = fields.origin or "local",
    status = "draft",
    in_reply_to = nil,
    author = fields.author or (fields.origin == "claude" and "claude") or vim.env.USER or "you",
    created_at = now,
    updated_at = now,
    hidden = false,
  }
  self.comments[comment.id] = comment
  self:save()
  return comment
end

--- Reply to an existing comment (creates a child in the same thread/location).
---@param parent_id string
---@param body string
---@param opts table|nil { origin?, suggestion_text?, author? }
---@return table|nil comment, string|nil err
function Store:reply(parent_id, body, opts)
  opts = opts or {}
  local parent = self.comments[parent_id]
  if not parent then
    return nil, "no such comment: " .. tostring(parent_id)
  end
  local now = os.date("!%Y-%m-%dT%H:%M:%SZ")
  local comment = vim.deepcopy(parent)
  comment.id = util.uuid()
  comment.in_reply_to = self:root_of(parent_id)
  comment.body = body
  comment.origin = opts.origin or "local"
  comment.status = "draft"
  comment.suggestion_text = opts.suggestion_text
  comment.kind = opts.suggestion_text and "suggestion" or "normal"
  comment.github_id = nil
  comment.author = opts.author or (opts.origin == "claude" and "claude") or vim.env.USER or "you"
  comment.created_at = now
  comment.updated_at = now
  self.comments[comment.id] = comment
  self:save()
  return comment
end

--- The root id of a thread containing `id`.
---@param id string
---@return string
function Store:root_of(id)
  local c = self.comments[id]
  if not c then
    return id
  end
  return c.in_reply_to or id
end

--- Update fields of a comment.
---@param id string
---@param fields table
---@return boolean
function Store:update(id, fields)
  local c = self.comments[id]
  if not c then
    return false
  end
  for k, v in pairs(fields) do
    c[k] = v
  end
  c.updated_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
  self:save()
  return true
end

--- Delete a comment (and its direct replies if it's a root).
---@param id string
---@return boolean
function Store:delete(id)
  local c = self.comments[id]
  if not c then
    return false
  end
  local now = os.date("!%Y-%m-%dT%H:%M:%SZ")
  if not c.in_reply_to then
    -- root: remove whole thread (tombstone each so deletes survive merge)
    for cid, other in pairs(self.comments) do
      if other.in_reply_to == id then
        self.comments[cid] = nil
        self.tombstones[cid] = now
      end
    end
  end
  self.comments[id] = nil
  self.tombstones[id] = now
  self:save()
  return true
end

--- Toggle/resolve a thread by root id.
---@param id string
---@param resolved boolean
function Store:set_resolved(id, resolved)
  local root = self:root_of(id)
  for _, c in pairs(self.comments) do
    if c.id == root or c.in_reply_to == root then
      c.status = resolved and "resolved" or open_status(c)
      c.updated_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
    end
  end
  self:save()
end

--- Hide/unhide a thread.
---@param id string
---@param hidden boolean
function Store:set_hidden(id, hidden)
  local root = self:root_of(id)
  for _, c in pairs(self.comments) do
    if c.id == root or c.in_reply_to == root then
      c.hidden = hidden
    end
  end
  self:save()
end

--- All root comments (threads) for a file, sorted by line.
---@param file string
---@return table[] roots
function Store:threads_for_file(file)
  local roots = {}
  for _, c in pairs(self.comments) do
    if c.file == file and not c.in_reply_to then
      table.insert(roots, c)
    end
  end
  table.sort(roots, function(a, b)
    return (a.line_start or 0) < (b.line_start or 0)
  end)
  return roots
end

--- Replies for a root id, chronological.
---@param root_id string
---@return table[]
function Store:replies(root_id)
  local out = {}
  for _, c in pairs(self.comments) do
    if c.in_reply_to == root_id then
      table.insert(out, c)
    end
  end
  table.sort(out, function(a, b)
    return (a.created_at or "") < (b.created_at or "")
  end)
  return out
end

--- All root comments across the source.
---@return table[]
function Store:all_threads()
  local roots = {}
  for _, c in pairs(self.comments) do
    if not c.in_reply_to then
      table.insert(roots, c)
    end
  end
  return roots
end

function Store:get(id)
  return self.comments[id]
end

--- Re-anchor every comment against current file content, applying rename map.
--- Marks comments "outdated" when their anchor can't be uniquely relocated.
---@param rename_map table<string,string>|nil  old_path -> new_path
function Store:reanchor(rename_map)
  local meta = self.source:metadata()
  rename_map = rename_map or {}
  for _, c in pairs(self.comments) do
    -- Only re-anchor root comments; replies inherit the root's location for display
    -- (markers/side-panel key off roots), so relocating them independently is wasted
    -- work and would let a reply's line drift from its root.
    if c.status ~= "resolved" and not c.in_reply_to then
      -- Apply rename lineage — RIGHT side only. LEFT anchors point at the base blob
      -- under the OLD path, so renaming their file would break `git show base:path`.
      if c.side ~= "LEFT" then
        local newp = rename_map[c.file]
        if newp and newp ~= c.file then
          c.rename_lineage = c.rename_lineage or {}
          table.insert(c.rename_lineage, c.file)
          c.file = newp
        end
      end
      local rev = (c.side == "LEFT") and (c.anchor and c.anchor.blob_sha or c.base_sha) or nil
      local lines = anchor.file_lines(meta.repo_root, rev, c.file)
      if lines then
        local loc = anchor.relocate(lines, c.anchor)
        if loc then
          local delta = loc - c.line_start
          c.line_start = loc
          c.line_end = c.line_end + delta
          if c.status == "outdated" then
            c.status = open_status(c)
          end
        else
          c.status = "outdated"
        end
      end
    end
  end
  self:save()
end

return Store
