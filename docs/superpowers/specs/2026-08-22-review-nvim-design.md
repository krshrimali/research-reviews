# review.nvim — Design Spec

Date: 2026-08-22
Status: Approved by user (autonomous completion requested)

## 1. Purpose

A Neovim plugin to review GitHub Pull Requests **and** local branches with the same
interface, add/manage review comments locally, import & respond to GitHub review
threads, and dispatch **asynchronous Claude reviews** that behave like a GitHub
reviewer (inline replies keyed to comment IDs, a summary verdict, optional
auto-resolve, and optional edits committed to a worktree). All state survives
Neovim restarts.

## 2. Load-bearing decisions (locked)

1. **Build on** `diffview.nvim` (diff engine, file panel, context — **required**) and the
   `gh` CLI's GraphQL API called **directly** via `vim.system` for GitHub data + submit.
   `octo.nvim` is **optional** (we reuse its named queries only if already loaded).
   Rationale (feasibility review R3): octo's `gh` wrapper is UI-coupled and gives little
   over calling `gh api graphql` ourselves. Dependencies: `diffview.nvim`, `gh`, `git`,
   `claude`.
2. **Claude engine**: headless `claude -p --output-format stream-json --session-id <uuid>`
   spawned per review; parse stream for progress + a final findings JSON.
3. **Local base**: `git merge-base HEAD origin/<default>`; commits = `base..HEAD`,
   diff = `base...HEAD`. Override via explicit ref.
4. **First build (MVP)**: A+B = the full human review tool. Spec C (Claude) builds on it.
5. **Diff fidelity**: primary rendering is diffview's whole-file diff (all context
   already visible), both split & unified (diffview native). GitHub-style
   collapse/expand-context (`[c` up / `]c` down / `zR` all) is implemented in
   **unified view only** — feasibility review R1 shows manual folds fight diffview's
   `foldmethod=diff` and desync `cursorbind`/`scrollbind` across split panes. In split
   view all context is shown (native), which already satisfies "see before/after".

## 3. Core abstraction: `Source`

A PR and a local branch are 99% identical. One interface, two implementations.
Everything upstream talks only to `Source`.

```
Source (interface)
  :key()                 -> stable id  ("gh:<owner>/<repo>#<n>" | "local:<repo>/<branch>")
  :kind()                -> "pr" | "branch"
  :title(), :description(), :author(), :updated_at()
  :commits()             -> [{sha, short, subject, body, author, date}] (recent→old)
  :files()               -> [{path, old_path?, status, additions, deletions}]
  :diff(file, base, head)-> hunks (delegated to diffview via revs)
  :base_rev(), :head_rev()
  :metadata()            -> kind-specific extras
  :caps()                -> {has_threads, has_reviewers, has_checks, can_submit}  (gap #7)
GitHubPR adds: :reviewers(), :threads(), :checks(), :submit_review(verdict, body, comments)
LocalBranch: base = merge-base vs origin/<default> (override supported); caps all false
```
The UI reads `:caps()` and hides PR-only sections for branches (gap #7). When a local
branch later becomes a PR, `state` supports **key-aliasing** so drafted comments/sessions
migrate from `local:<repo>/<branch>` to `gh:<owner>/<repo>#<n>` (gap #7).

`source/init.lua` factory: if arg looks like a PR number/URL → GitHubPR; if a branch
name or "." → LocalBranch; auto-detect from cwd repo state otherwise.

## 4. UI model (tabs + panels)

- **Overview tab** (main entry): PR/branch description, metadata (author, reviewers,
  updated, checks), a **commit list** (subjects ≤50 chars, `<Tab>` to unfold full
  message, sort toggle recent↔old), and **GitHub review threads** (reviewer → anchored
  diff snippet → comments, incl. code-suggestion rendering). Scrollable.
- **File panel** = diffview panel (side per user's diffview config). Shows changed
  files grouped by dir with `(+a, -d)` and renames `old → new`.
- **Diff view** = diffview split/unified. Our overlay adds comment markers.
- **Comment side-panel** (opt-in keymap, right split): per-file list of comment
  threads, showing first chars; `<CR>` on an entry expands that thread inline in the
  main diff and jumps to its anchor.
- **Compose** = bottom split scratch buffer (markdown); `:w`/`<CR><CR>` submits.
- Clicking a **commit** → new tab with that commit's diff. "Open file @ commit" →
  new tab rooted in a **worktree** checked out at that sha.

### Mock — Overview tab
```
┌ Files ────────┐┌ [1:Overview] [2:auth.lua@c3f1] ─────────────────────────────┐
│ src/          ││ #482  Add token refresh to auth layer          updated 2h ago │
│  auth.lua     ││ author @octocat   reviewers @alice @bob   ✓checks 4/4        │
│    +100 -30   ││ ───────────────────────────────────────────────────────────  │
│  cache.cpp +10││ Refreshes OAuth tokens before expiry. Adds retry w/ backoff.  │
│ rename:        ││                                                              │
│  a.lua→b.lua  ││ ▸ Commits (recent→old)            [s: sort] [<Tab>: unfold]   │
│               ││   c3f1a9  Add token refresh to auth layer                     │
│               ││   9b2e10  Wire retry/backoff into cache                       │
│               ││   ▾ 71dd02  Refactor client init                             │
│               ││       Longer body shown because unfolded…                     │
│               ││                                                              │
│               ││ ▸ Review threads (3)                                          │
│               ││   @alice  src/auth.lua:42                                     │
│               ││     ┆ - local t = get()      (diff snippet)                   │
│               ││     ┆ + local t = get_or_refresh()                            │
│               ││     └ "why not memoize here?"   [2 replies]  ○ unresolved     │
└───────────────┘└──────────────────────────────────────────────────────────────┘
```

### Mock — Diff with comment markers + side-panel
```
┌ Files ──────┐┌ auth.lua (split) ──────────────────────┐┌ Comments: auth.lua ─┐
│ auth.lua ●2 ││  40   local t = get()                   ││ ▸ L42 (●2) alice:   │
│ cache.cpp   ││  41 ⬒ ── 6 lines folded ── <zo expand>  ││    "why not memo…"   │
│             ││  42 │- local t = get()        💬2       ││ ▸ L58 (draft) you:  │
│             ││  43 │+ local t = get_or_refresh()       ││    "extract const…" │
│             ││  44   return t                          ││                     │
│             ││  ⌃ expand up   ⌄ expand down            ││ <CR>=open  d=del    │
└─────────────┘└────────────────────────────────────────┘└─ r=resolve  h=hide ┘
```
`💬2` = eye-candy virtual-text marker (thread w/ 2 comments); pressing it or `<CR>`
on the line expands the thread inline.

### Mock — PR/branch picker (fuzzy)
```
┌ Review: pick source ─────────────────────────────────────────┐
│ > refresh                                                     │  ← fuzzy query
│ ─────────────────────────────────────────────────────────── │
│  #482  Add token refresh…        @octocat  open   ✓4/4      │
│  #470  Refresh cache eviction    @alice     open   ✗1/4      │
│  ⎇ feature/token-refresh (local, 4 commits ahead)            │
│ ─────────────────────────────────────────────────────────── │
│ filters: <a>author <l>label <s>state <A>assignee <r>review   │
│          <t>title  <m>mine  <b>local-branches                │
└──────────────────────────────────────────────────────────────┘
```

### Mock — Claude review sessions (Spec C)
```
┌ Claude reviews ──────────────────────────────────────────────┐
│ ● #482  running   3m12s   replied 2/3 threads, +1 finding     │
│ ✓ #470  done      approved            (2h ago)               │
│ ⚠ ⎇ feat/x done   changes-requested   4 findings  (1d ago)   │
│ <CR> open session tab   x kill   i instruction   e allow-edits│
└──────────────────────────────────────────────────────────────┘
```

## 5. Data model & persistence

State dir: `stdpath('state')/review.nvim/<repo-hash>/<source-key>.json`.

```
Comment {
  id: uuid,                             -- the ONLY id Claude ever sees/returns (gap #6)
  source_key,
  file, side: "LEFT"|"RIGHT",
  head_sha, base_sha,                   -- the revs this comment was authored against
  line_start, line_end,                 -- 1-based in the side's file
  anchor: {                             -- robust re-location (gaps #1, #2, #9)
    line_text,                          -- exact content of line_start
    line_hash,                          -- hash(line_text) for fast compare
    context_before[3], context_after[3],
    occurrence,                         -- Nth identical match, disambiguates dupes
    diff_position?,                     -- {hunk_header, offset} GitHub-style
    blob_sha?                           -- for LEFT side: anchor to blob, not recomputed base
  },
  rename_lineage?: string[],            -- prior paths, so renames don't orphan (gap #2)
  kind: "normal"|"suggestion",
  suggestion_text?: string,             -- replacement code (also emitted as ```suggestion)
  body: markdown,
  origin: "local"|"github"|"claude",
  status: "draft"|"published"|"resolved"|"outdated",  -- outdated = anchor unmatched (gap #1)
  github_id?,                           -- upstream-authoritative fields keyed by this (gap #8)
  in_reply_to?: uuid,                   -- always a local uuid
  author, created_at, updated_at, hidden: bool
}
```
**Re-anchoring on open**: for each comment, rewrite `file` through the current
`old_path→path` rename map; then require a **unique** match of `line_text` +
surrounding context (respecting `occurrence`) in the target file. No unique match →
`status="outdated"` (shown GitHub-style), never silently re-anchored to a wrong line.
LEFT-side comments match against `blob_sha` content, not the recomputed merge-base.
Thread = comments sharing (file, line_start, root id) linked via in_reply_to.
SessionRecord { id, source_key, state, verdict?, instruction, allow_edits,
  auto_resolve, started_at, ended_at?, log_path, replied[], findings[] }
```

Persistence is write-through on every mutation (debounced). On `:Review` re-open of a
source, state is rehydrated: markers, threads, side-panel, and Claude sessions all
restore. Anchoring re-locates comments if line numbers drifted (context match; if
unmatched → shown as "outdated" in side-panel, GitHub-style).

## 6. Local comment system (Spec B)

- **Add**: visual-select lines in a diff → keymap → bottom-split composer. Buffer
  seeded with a fenced quote of the selected diff lines. Suggestion mode pre-fills a
  ```suggestion block.
- **View**: inline markers (virtual text `💬N` + sign) always on; side-panel opt-in.
  Hover/`<CR>` expands thread inline (foldtext-style virtual lines below the line).
- **Edit / delete / hide / resolve / copy**: keymaps in diff, side-panel, and inline
  thread. Copy yanks thread or single comment as markdown.
- **Threads**: reply creates child comment; rendered nested.
- **Import GitHub threads**: `github_sync.import()` pulls PR review threads via
  octo/gh GraphQL into local Comments with origin=github, preserving github_id,
  resolution state, and suggestions. Replying to an imported thread is stored locally
  and (in Spec C / publish step) can be pushed back.

## 7. Worktree-at-commit (Spec A)

`worktree.open(sha, file)`:
1. `git fetch` (best-effort, async).
2. Managed worktree root: `stdpath('cache')/review.nvim/worktrees/<repo-hash>/<sha>`.
3. If absent: `git worktree add --detach <path> <sha>`. Reuse if present.
4. Open `<path>/<file>` in a **new tab**; tab-local cwd set to the worktree so LSP,
   `gf`, and relative tools operate in that snapshot.
5. Worktrees are reference-counted and pruned on `:ReviewClean` / plugin teardown.
   **Safety (gap #12)**: refcounts are reconciled from `git worktree list` on startup
   (not just in-memory); pruning **refuses** any worktree holding commits not reachable
   from the branch/remote (never discards unpushed Claude edits).

## 8. Claude orchestration (Spec C — builds on A+B)

- **Submit flow**: user finishes drafting comments → `:ReviewClaude`. Prompt for a
  **major instruction** (like GitHub's review summary box) + choice of a **saved
  instruction** profile ("Critical review", "InfoSec review", …) stored in config/state.
- **Runner**: build a prompt containing: source metadata, the unified diff, the set of
  included threads/comments **with their local uuids**, and a strict output contract. Spawn
  `claude -p --output-format stream-json --session-id <uuid>`
  `--append-system-prompt <contract>`. Tool gating (gap #5): read-only by default. When
  **Allow edits** is on, grant an **explicit subcommand allowlist**, NOT a git wildcard:
  `Edit`,`Write`,`Bash(git add)`,`Bash(git commit)`,`Bash(git status)`,`Bash(git diff)`,
  `Bash(git worktree)`. Never `Bash(git *)` (bypassable to `push`/aliases) and never any
  push. Sandbox is defense-in-depth, not the only guard.
- **Contract (final JSON block)**: `comment_id` is always a **local uuid** (gap #6).
  Includes the reviewed `head_sha` so we can detect head-drift before applying (gap #3).
  `new_comments` carry `side` + anchor context so they are re-locatable later (gap #3).
  ```
  { "reviewed_head_sha": "<sha the diff was taken at>",
    "verdict": "approve"|"request_changes"|"comment",
    "summary": "...",
    "thread_replies": [ {"comment_id": "<uuid>", "reply": "...", "suggestion?": "..."} ],
    "new_comments":  [ {"file","line_start","line_end","side","body","suggestion?"} ],
    "resolved":      ["<uuid>", ...],              // only if auto_resolve
    "commits":       [ {"sha","subject","files":[...]} ] // only if allow_edits
  }
  ```
  **Apply rules**: if current head ≠ `reviewed_head_sha`, re-anchor/abort rather than
  place on shifted lines. A `comment_id` with no local match is NOT dropped — it becomes
  a synthetic top-level finding (gap #6). Apply is **idempotent**: the SessionRecord is
  marked `applied` and replies deduped by session id (gap #10). `resolved`/`commits`
  honored only when the matching opt-in was enabled.
- **Async & lifecycle**: runs via `vim.system`/`jobstart`; survives buffer switches,
  dies with the nvim process (job killed on VimLeave). Session buffer lists all runs;
  `<CR>` opens a tab showing the live/'captured log + parsed findings, with the
  correct worktree cwd if edits were made.
- **Result application**: `thread_replies` become child Comments (origin=claude) on the
  matching threads — **every** reply is viewable in the UI. `new_comments` become
  Claude-authored threads with markers. `resolved` flips status (opt-in). On
  completion: `vim.notify("PR #482 review done: request_changes")`.
- **Allow edits**: Claude works inside a dedicated worktree (fetch → `git worktree add`
  on the branch → edit → commit, **never push**). Each Claude commit is surfaced in the
  overview commit list so the user reviews them like any PR commit.

## 9. Config (defaults)

```lua
require("review").setup({
  panel_side = "auto",          -- follow diffview; or "left"/"right"
  default_view = "split",       -- "split"|"unified"
  local_base = "auto",          -- merge-base vs origin/HEAD; or explicit ref
  picker = "auto",              -- snacks|telescope|builtin
  keymaps = { open_list=, add_comment=, toggle_comments_panel=, expand_up=, ... },
  claude = {
    bin = "claude",
    saved_instructions = { ["Critical review"]="…", ["InfoSec review"]="…" },
    allow_edits = false, auto_resolve = false,
  },
})
```

## 10. Error handling

- Missing `gh`/`octo`/`diffview` → actionable `vim.notify` at setup, feature-gated.
- Not in a git repo / dirty worktree during worktree ops → refuse with guidance.
- `claude` non-zero exit or malformed final JSON → session marked `error`, raw log kept.
- All git/gh/claude calls run `shell=false` argv style (no string interpolation).
- Persistence writes are atomic (temp file + rename).

## 11. Testing

- **Unit** (plenary busted): Source factory, merge-base math, comment store CRUD +
  anchoring, contract parser, stream-json parser, state round-trip.
- **Headless UI** (`nvim --headless -l`): open list, render overview, open diff, add a
  comment, toggle panel, resolve, restart→rehydrate, worktree open, mock claude runner
  (a fake `claude` script emitting canned stream-json) → assert findings applied.
- Sub-agent bug sweeps after each phase.

## 12. Out of scope (YAGNI, for now)

Pushing to remote (sandbox-blocked anyway), multi-repo dashboards, non-GitHub forges,
CI log tailing beyond check status.

## 13. Design-review responses (two sub-agent reviews, 2026-08-22)

**Feasibility (Neovim/diffview/octo):**
- R1 fold-based expand fights `foldmethod=diff` → **unified-view-only** expand/collapse (§2.5).
- R2 diffview recreates buffers on refresh → reapply markers on `DiffviewDiffBufRead`/
  `view_opened` autocmds; durable markers on RIGHT buffer; anchor by content (§4, comments).
- R3 octo is UI-coupled → **call `gh api graphql` directly**; octo optional (§2.1).
- R4 LSP `root_dir` resolved at attach → force distinct client per worktree (`reuse_client=false`).
- R5 `vim.system` callbacks in fast context → `vim.schedule` before buffer/extmark ops
  (done in `util.proc.spawn`); track handle, `:kill()` on `VimLeavePre`.
- Confirmed: `diffview.open("base...HEAD")`, split & unified native, `virt_lines`,
  `sign_text`, atomic temp+rename. Panel driven via commands + `diffview.lib` introspection.

**Logic/data-model:** all 12 gaps folded in — stronger anchoring (§5), rename lineage,
head-drift version token + re-anchor on apply (§8), merge-on-write persistence (`state.lua`),
explicit git subcommand allowlist (§8), local-uuid contract namespace + synthetic finding
for unmatched ids (§8), capability flags + branch→PR key-aliasing (§3), imported-thread
`github_id`-authoritative reconciliation, idempotent apply (§8), schema_version (`state.lua`),
worktree prune safety (§7).
