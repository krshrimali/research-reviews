-- review.nvim :: configuration defaults + user merge.

local util = require("review.util")

local M = {}

---@type table
M.defaults = {
  -- Where the file/diff panels live. "auto" follows diffview's own config.
  panel_side = "auto", -- "auto" | "left" | "right"
  default_view = "split", -- "split" | "unified"

  -- Local-branch diff base. "auto" => merge-base vs origin/HEAD.
  -- Any other string is treated as an explicit base ref.
  local_base = "auto",

  -- Fuzzy picker backend for the source list.
  picker = "auto", -- "auto" | "snacks" | "telescope" | "builtin"
  picker_cache_ttl = 30, -- seconds; explicit refresh bypasses the cache
  commit_picker_limit = 200,

  -- Number of context lines kept visible around a hunk when folded.
  fold_context = 3,

  workspace = {
    dedicated_tab = true,
    comments = true,
    comments_width = 42,
    comments_min_columns = 120,
  },

  -- Minimal keymap surface: ONE key opens a contextual action menu; the menu
  -- teaches everything else (recognition over recall). `primary` is the fast-path
  -- action on the current line. The two overview-local keys stay because they're
  -- intuitive in that read-only buffer.
  keymaps = {
    menu = "<leader>p", -- the one key to remember (global + inside reviews)
    primary = "<CR>", -- expand thread / open commit under cursor
    sort_commits = "s", -- overview buffer-local
    unfold_commit = "<Tab>", -- overview buffer-local
  },

  claude = {
    bin = "claude",
    -- Named instruction profiles selectable at review time.
    saved_instructions = {
      ["Critical review"] = "Be a rigorous, skeptical reviewer. Prioritize correctness, "
        .. "edge cases, and failure modes over style. Push back on unclear code.",
      ["InfoSec review"] = "Review strictly for security: injection, authz/authn, secrets, "
        .. "unsafe deserialization, path traversal, SSRF, crypto misuse, and unsafe subprocess use.",
    },
    allow_edits = false, -- opt-in: lets Claude edit + commit in a worktree
    auto_resolve = false, -- opt-in: lets Claude flip resolved on threads
    model = nil, -- nil => claude CLI default
    extra_args = {}, -- appended to the claude argv
    timeout_ms = 30 * 60 * 1000, -- cancel a wedged review after 30 minutes
  },
}

---@type table
M.options = vim.deepcopy(M.defaults)

--- Merge user opts over defaults. Returns the resolved options.
---@param opts table|nil
---@return table
function M.setup(opts)
  M.options = util.merge(M.defaults, opts)
  return M.options
end

--- Accessor used across modules.
---@return table
function M.get()
  return M.options
end

return M
