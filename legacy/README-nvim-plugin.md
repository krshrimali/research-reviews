# review.nvim

Review GitHub Pull Requests **and** local branches inside Neovim, annotate them with
comments, import & respond to GitHub review threads, and dispatch **asynchronous Claude
reviews** that reply to threads by id, add inline findings, and (opt-in) commit edits in
an isolated worktree. All state survives Neovim restarts.

Built on [`diffview.nvim`](https://github.com/sindrets/diffview.nvim) for diff rendering
and the `gh` CLI for GitHub data. A PR and a local branch share one `Source` interface —
they differ only in the GitHub-only extras (threads, reviewers, checks, submit).

## Requirements

- Neovim ≥ 0.10 (developed on 0.12)
- `diffview.nvim` (required)
- `git`
- `gh` CLI (only for PR mode; local-branch mode needs just git)
- `claude` CLI (only for Claude reviews)
- Optional picker: `snacks.nvim` or `fzf-lua` (falls back to `vim.ui.select`)

## Install (lazy.nvim)

```lua
{
  dir = "/path/to/nvim-research",   -- or your clone path
  dependencies = { "sindrets/diffview.nvim" },
  config = function()
    require("review").setup({
      -- see Configuration below
    })
  end,
}
```

## Commands

| Command | Action |
|---|---|
| `:ReviewList` | Fuzzy-pick a PR or local branch to review |
| `:Review [<n>\|<url>\|<branch>\|.]` | Open a review directly (default: current branch) |
| `:ReviewComments` | Toggle the comments side-panel for the current file |
| `:ReviewClaude` | Start an async Claude review (prompts for instruction profile + direction) |
| `:ReviewSessions` | List Claude review sessions; `<CR>` opens a session tab |
| `:ReviewClean` | Prune managed worktrees (never removes ones with unpushed commits) |

## Keymaps — one key

The whole plugin is driven by **one key: `<leader>p`** (recognition over recall).

- Outside a review → "start a review (pick PR/branch)".
- Inside a review → a contextual menu of just the actions valid at the cursor, each with
  a single-letter accelerator: `c` comment · `s` suggest · `r` reply · `x` resolve ·
  `d` delete · `y` copy · `o` open @ commit · `C` Claude review · `R` sessions ·
  `O` overview · `P` comments panel · `L` switch PR/branch. Thread actions (`r/x/d/y`)
  appear only when the cursor is on a thread.

Fast path: `<CR>` expands/collapses the thread on the current line (in a diff) or opens
the commit under the cursor (in the overview). Overview also has `s` (sort) / `<Tab>`
(unfold message). Everything else is in the menu — nothing else to memorize.

## The two-review-mode model

```
                    ┌──────────────── Source (interface) ───────────────┐
                    │ title description author commits[] files[] diff()  │
                    │ base_rev head_rev caps()                           │
                    └────────────────────────────────────────────────────┘
                              ▲                              ▲
              ┌───────────────┴──────┐          ┌───────────┴──────────────┐
              │ GitHubPR             │          │ LocalBranch              │
              │  +threads/reviewers/ │          │  base = merge-base vs    │
              │   checks/submit      │          │  origin/<default>        │
              │  data via gh CLI     │          │  (override: explicit ref)│
              └──────────────────────┘          └──────────────────────────┘
```

## UI mocks (final design)

### Overview tab
```
┌ Files ────────┐┌ [1:Overview] [2:auth.lua@c3f1] ─────────────────────────────┐
│ src/          ││ #482  Add token refresh to auth layer          updated 2h ago │
│  auth.lua     ││ author @octocat   reviewers @alice @bob   checks 4/4         │
│    +100 -30   ││ ── Description ─────────────────────────────────────────────  │
│  cache.cpp +10││ Refreshes OAuth tokens before expiry. Adds retry w/ backoff.  │
│ rename:        ││                                                              │
│  a.lua→b.lua  ││ ── Commits (recent→old)  [s sort] [<Tab> unfold] ──          │
│               ││   ▸ c3f1a9  Add token refresh to auth layer                   │
│               ││   ▸ 9b2e10  Wire retry/backoff into cache                     │
│               ││   ▾ 71dd02  Refactor client init                            │
│               ││       (full commit body shown while unfolded)                 │
│               ││                                                              │
│               ││ ── Review threads (3) ──                                      │
│               ││   @alice  src/auth.lua:42   ○ unresolved                     │
│               ││       │ why not memoize here?                                 │
└───────────────┘└──────────────────────────────────────────────────────────────┘
```

### Diff with comment markers + side-panel
```
┌ Files ──────┐┌ auth.lua (split) ──────────────────────┐┌ Comments: auth.lua ─┐
│ auth.lua ▎  ││  40   local t = get()                   ││ ▸ L42 (2) alice     │
│ cache.cpp   ││  42 - local t = get()          💬2      ││    why not memoize…  │
│             ││  43 + local t = get_or_refresh()        ││ ★ L58 (1) claude    │
│             ││  44   return t                          ││    cache the token…  │
│             ││   ╭─ alice (github)                     ││                     │
│             ││   │ why not memoize here?               ││ <CR> open  r resolve│
│             ││   ╰─ <CR> collapse  r resolve  R reply  ││ d delete  q close   │
└─────────────┘└────────────────────────────────────────┘└─────────────────────┘
```
`💬N` = thread with N comments (eol virtual text) · `★` = Claude-authored ·
`✓` = resolved · `⚠` = outdated anchor. `<CR>` on the anchor line expands the thread
inline as virtual lines.

### Compose (bottom split)
```
├────────────────────────────────────────────────────────────────────────────┤
│ <!-- New comment on src/auth.lua:42-43 (RIGHT) — :w or <CR><CR> to submit -->│
│ <!-- context:                                                               │
│   - local t = get()                                                         │
│   + local t = get_or_refresh() -->                                          │
│ This should also handle the 401 refresh path.▏                              │
└──────────────────────────────────────────────────────────────────────────────┘
```

### Claude review sessions
```
┌ Claude reviews ──────────────────────────────────────────────┐
│ ● running                         just now                    │
│ ✓ done       approve              2h ago                      │
│ ⚠ done       request_changes      1d ago                      │
│ <CR> open   x kill   q close                                  │
└──────────────────────────────────────────────────────────────┘
```

## Claude review contract

The runner spawns `claude -p --output-format stream-json --session-id <uuid>`, streams
progress, and parses a final JSON block. `comment_id` values are always **local uuids**.
The reviewed head sha is echoed so head-drift is detected before applying. Tool access is
read-only by default; **Allow edits** grants an *explicit* git-subcommand allowlist
(never a `git *` wildcard, never `push`) and runs in an isolated worktree.

```json
{ "reviewed_head_sha": "…", "verdict": "approve|request_changes|comment",
  "summary": "…",
  "thread_replies": [ { "comment_id": "<uuid>", "reply": "…", "suggestion?": "…" } ],
  "new_comments":  [ { "file","line_start","line_end","side","body","suggestion?" } ],
  "resolved":      [ "<uuid>" ],
  "commits":       [ { "sha","subject","files":[…] } ] }
```

## Configuration

```lua
require("review").setup({
  panel_side = "auto",        -- follow diffview
  default_view = "split",     -- "split" | "unified"
  local_base = "auto",        -- merge-base vs origin/HEAD, or an explicit ref
  picker = "auto",            -- "snacks" | "fzf" | "builtin"
  fold_context = 3,
  keymaps = { --[[ see :h or config.lua ]] },
  claude = {
    bin = "claude",
    saved_instructions = {
      ["Critical review"] = "…",
      ["InfoSec review"]  = "…",
    },
    allow_edits = false,      -- opt-in: Claude may edit + commit in a worktree
    auto_resolve = false,     -- opt-in: Claude may resolve threads
    model = nil,
  },
})
```

## State & persistence

State lives under `stdpath('state')/review.nvim/<repo-hash>/<source-key>.json`
(override with `REVIEW_STATE_DIR`). Writes are reload-merge + atomic-rename so two
Neovim instances don't clobber each other. Comments re-anchor on open via line content
+ context; ones that can't be uniquely located are marked `outdated` rather than moved.

## Tests

```bash
./tests/run.sh
```

Runs pure-logic specs under plenary (anchor, source, contract, runner, UI) plus a
standalone diffview-backed full-flow integration.

## Design

See `docs/superpowers/specs/2026-08-22-review-nvim-design.md` for the full spec and the
two design-review passes it incorporates.
