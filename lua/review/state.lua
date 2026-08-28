-- review.nvim :: persistent per-source state.
--
-- One JSON document per source-key, under stdpath('state')/review.nvim/<repo-hash>/.
-- Writes are reload-merge-then-atomic-write so two Neovim instances editing the
-- same source do not silently clobber each other (design gap #4).

local json = require("review.util.json")
local util = require("review.util")

local M = {}

M.SCHEMA_VERSION = 1

--- Root directory for all persisted state. Overridable via `REVIEW_STATE_DIR`
--- (env) or `state.set_root()` — used by tests and for custom setups.
local _root_override = nil

--- Override the state root directory.
---@param dir string|nil
function M.set_root(dir)
  _root_override = dir
end

---@return string
local function root()
  if _root_override then
    return _root_override
  end
  if vim.env.REVIEW_STATE_DIR and vim.env.REVIEW_STATE_DIR ~= "" then
    return vim.env.REVIEW_STATE_DIR
  end
  return vim.fs.joinpath(vim.fn.stdpath("state"), "review.nvim")
end

--- Absolute path of the document for a repo + source-key.
---@param repo_key string  stable repo identifier (e.g. owner/repo or path)
---@param source_key string
---@return string
function M.path(repo_key, source_key)
  local dir = vim.fs.joinpath(root(), util.hash(repo_key))
  return vim.fs.joinpath(dir, util.hash(source_key) .. ".json")
end

--- Fresh empty document.
---@param source_key string
---@return table
local function empty(source_key)
  return {
    schema_version = M.SCHEMA_VERSION,
    source_key = source_key,
    comments = {}, -- id -> Comment
    sessions = {}, -- id -> SessionRecord
    tombstones = {}, -- id -> deletion timestamp (so deletes survive merge)
    meta = {},
  }
end

--- Migrate an on-disk document to the current schema. Returns the doc.
---@param doc table
---@param source_key string
---@return table
local function migrate(doc, source_key)
  doc.schema_version = doc.schema_version or 0
  -- Future migrations branch on doc.schema_version here.
  doc.schema_version = M.SCHEMA_VERSION
  doc.source_key = doc.source_key or source_key
  doc.comments = doc.comments or {}
  doc.sessions = doc.sessions or {}
  doc.tombstones = doc.tombstones or {}
  doc.meta = doc.meta or {}
  return doc
end

--- Load a document (or an empty one).
---@param repo_key string
---@param source_key string
---@return table
function M.load(repo_key, source_key)
  local doc = json.read(M.path(repo_key, source_key))
  if not doc then
    return empty(source_key)
  end
  return migrate(doc, source_key)
end

--- Merge two documents by record id. `incoming` (in-memory) wins per-record on a
--- newer updated_at; records only on disk are preserved. Returns merged doc.
---@param disk table
---@param incoming table
---@return table
local function merge_docs(disk, incoming)
  -- Union of tombstones from both sides; a delete anywhere wins.
  local tombstones = vim.tbl_extend("force", disk.tombstones or {}, incoming.tombstones or {})

  local function merge_map(a, b)
    local out = vim.deepcopy(a or {})
    for id, rec in pairs(b or {}) do
      local existing = out[id]
      if not existing then
        out[id] = rec
      else
        local et = existing.updated_at or existing.started_at or ""
        local rt = rec.updated_at or rec.started_at or ""
        -- In-memory record wins ties and newer timestamps.
        if rt >= et then
          out[id] = rec
        end
      end
    end
    -- Drop any record that has been tombstoned (deletion is explicit, not inferred).
    for id in pairs(tombstones) do
      out[id] = nil
    end
    return out
  end
  return {
    schema_version = M.SCHEMA_VERSION,
    source_key = incoming.source_key,
    comments = merge_map(disk.comments, incoming.comments),
    sessions = merge_map(disk.sessions, incoming.sessions),
    tombstones = tombstones,
    meta = vim.tbl_deep_extend("force", disk.meta or {}, incoming.meta or {}),
  }
end

--- Persist a document, merging with whatever is currently on disk first.
--- Returns ok, err.
---@param repo_key string
---@param source_key string
---@param doc table
---@return boolean ok, string|nil err
function M.save(repo_key, source_key, doc)
  local path = M.path(repo_key, source_key)
  local disk = json.read(path)
  local final = doc
  if disk then
    final = merge_docs(migrate(disk, source_key), doc)
  end
  return json.write(path, final)
end

return M
