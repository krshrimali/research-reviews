# Registering review.nvim in ~/.config/nvim

> The sandbox mounts `~` **read-only**, so apply this **outside** the sandbox.

## One command

```bash
python3 /path/to/nvim-research/scripts/install-into-nvim.py --dry-run  # preview
python3 /path/to/nvim-research/scripts/install-into-nvim.py            # apply
```

Idempotent and re-runnable. If you applied an earlier version, it starts from the
pristine `*.bak` it saved, so the old multi-keymap block is dropped cleanly. Restart
Neovim afterwards.

## The model: one menu plus optional fast paths

`<leader>p` is the only required key (leader = `,`, so `,p`). The installed config also
provides direct mappings without duplicating any existing mapping:

- `,pc` Claude review
- `,ph` Claude chat
- `,pr` refresh
- `,pe` edit/copy/run prompt
- `,pt` thread inbox
- `,ps` agent sessions
- `,pl` pick PR/branch
- `,px` clean safe worktrees
- `,pi` import GitHub comments
- `,pq` export clickable threads to quickfix

- **Outside a review:** `<leader>p` → "Start a review (pick PR / branch)".
- **Inside a review:** `<leader>p` opens a **contextual menu** of just the actions valid
  where your cursor is — each with a single-letter accelerator:

```
┌ Review · #482 Add token refresh ──────┐
│  c  Comment on line / selection       │
│  s  Suggest change on line/selection  │
│  r  Reply to thread here              │   (r/x/d/y appear only when the
│  x  Resolve thread                    │    cursor is on a thread)
│  d  Delete thread                     │
│  y  Copy thread                       │
│  o  Open file @ commit (worktree)     │
│ ── review ──                          │
│  C  Claude review (Sidekick)…         │
│  a  Agent chat                        │
│  Y  Edit/copy/run final prompt        │
│  f  Refresh PR and comments           │
│  R  Claude review sessions            │
│  O  Overview (desc, commits, threads) │
│  P  Toggle comments panel             │
│  L  Switch to another PR / branch     │
└───────────────────────────────────────┘
```

Fast path: `<CR>` on a line expands/collapses its comment thread (in a diff) or opens
the commit under the cursor (in the overview). That's it — everything else lives in the
menu.

## Conflict analysis (leader = `,`)

`<leader>r` = Rename/Refactor, `<leader>g` = Git, `<leader>v` / `<leader>R` taken.
review.nvim uses only the unused `<leader>p` ("PR") — zero conflicts. No `:Review*`
command clashes.

## What it registers

- **lazy spec** (`lua/user/plugins.lua`): `dir = "/path/to/nvim-research"`,
  `dependencies = { "diffview.nvim" }` (your fork), lazy-loaded on `<leader>p` and the
  `:Review*` commands.
- **which-key** (`lua/user/whichkey.lua`): a single `<leader>p` → "Review: actions menu".

## Manual alternative

```lua
-- lua/user/plugins.lua  (add near the diffview block)
{
    dir = "/path/to/nvim-research",
    dependencies = { "diffview.nvim" },
    cmd = { "Review", "ReviewList", "ReviewClaude", "ReviewSessions", "ReviewComments", "ReviewClean" },
    keys = { { "<leader>p", desc = "Review: actions menu" } },
    config = function() require("review").setup {} end,
},

-- lua/user/whichkey.lua  (inside which_key.add { ... })
{ "<leader>p", desc = "Review: actions menu (review.nvim)" },
```

## Note

Your diffview fork already has PR-review commands (`DiffviewPR`, `DiffviewReview`, …)
under `<leader>gd`/`<leader>gP`. review.nvim is a separate, complementary plugin.

## Keep the lazy.nvim command list in step

review.nvim is lazy-loaded by command, so any command missing from the `cmd` list in
your plugin spec will report `E492: Not an editor command` until something else loads
the plugin first. The current set is:

```lua
cmd = {
  "Review", "ReviewList", "ReviewPRs", "ReviewBranches", "ReviewCommits",
  "ReviewCurrent", "ReviewBase", "ReviewClaude", "ReviewSessions",
  "ReviewComments", "ReviewWorkspace", "ReviewRefresh", "ReviewChat",
  "ReviewPrompt", "ReviewImport", "ReviewSync", "ReviewQuickfix",
  "ReviewPublish", "ReviewDedupe", "ReviewClean", "ReviewHealth",
  "ReviewProfile", "ReviewHelp",
},
```

`ReviewBase`, `ReviewPublish` and `ReviewDedupe` are the newest; add them when you
update, or drop `cmd` entirely and load the plugin eagerly.
