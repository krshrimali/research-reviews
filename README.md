# prtui — a GitHub PR/branch review TUI

`prtui` is a fast, polished terminal UI (Rust + [ratatui](https://ratatui.rs)) for reviewing
GitHub Pull Requests **and** local branches, commenting on lines, and running **asynchronous
Claude reviews** — with Neovim-style keys and switchable themes.

## Two frontends, one review workflow

```bash
cd rtui
cargo build --release
./target/release/prtui          # PR/branch picker
./target/release/prtui .         # current branch
./target/release/prtui 482       # PR #482  (needs gh)
```

See [`rtui/README.md`](rtui/README.md) for the full feature list, key bindings, config, and
tests.

The repository also ships `review.nvim`, a Diffview + Sidekick frontend. Add this repository,
`diffview.nvim`, and `sidekick.nvim` to Neovim's runtime path, then:

```lua
require("review").setup()
```

Use `:Review` to pick a PR or branch. `<leader>p` opens the contextual action menu. Reviews
support stable old/new-line comments in split and unified diffs, GitHub thread replies and
resolution, manual refresh, an editable/copyable agent prompt, and conversational Claude
sessions through Sidekick. Edit-enabled sessions require explicit consent and use only a
private worktree under the reviewed repository's own `.git/prtui/worktrees` directory.

The file tree marks viewed files and shows each file's open thread count. The default
workspace keeps Diffview's file tree and diff visible alongside a responsive thread inbox,
which also lists PR-level comments and review summaries — everything not anchored to a
line — under `conversation`. The inbox supports `/` search, `f` status filters, `Space` multi-select,
`a` scoped Claude review, `I` GitHub import, `Q` quickfix export, and `p` draft publishing.
In the persistent review browser, press `Q` to send visible rows to quickfix;
`<Enter>` on a quickfix row opens that PR or branch review.
With no review open, `<leader>p` lists focused PR, local-branch, single-commit,
current-branch, and combined browsers. The PR browser remembers its state per repository;
`<Tab>` cycles open, closed, merged,
and all PRs, while `r` bypasses the short metadata cache. `:ReviewHealth` diagnoses
dependencies/configuration, `:ReviewProfile` shows recent command timings, and
`:ReviewHelp` is the searchable in-editor key and workflow reference.
Cold PR loads are asynchronous and show an in-buffer spinner; the header always names the
active OPEN/CLOSED/MERGED/ALL filter. GitHub thread import is idempotent and refreshes
moved/outdated thread metadata and nested replies.
Use `:ReviewSync` to recover the latest Claude findings from its exact transcript.
Diffview-native `REVIEW #n` comments are included in Claude requests; replies and new
findings return to the inline diff and the left Comments section.
In a diff, `[t`/`]t` navigate all threads and `[u`/`]u` navigate unresolved ones; both
land in the pane that actually holds the thread, so `<CR>` expands it straight away.
`R` replies, `gr` resolves and `gd` deletes the thread under the cursor.
`<localleader>v` marks the file viewed, and `go`/`gO` open the reviewed file in the
current/new tab — `o` and `O` keep their normal Vim meaning. Claude progress appears in
the winbar and structured replies/findings are imported back when the run completes.

## Reviewing and publishing

`<leader>p` → `p` (or `:ReviewPublish`) opens the submission preview. `e` cycles the
verdict COMMENT → APPROVE → REQUEST_CHANGES, `b` writes the review summary — kept with
the review until it is submitted — and `Ctrl-S` publishes. Multi-line comments publish as
ranges. A review larger than `publish_batch_limit` (20) is built one thread at a time
through GitHub's pending-review API, because a single request carrying dozens of comments
is rejected; if a submission errors, the plugin asks GitHub what actually landed before
reporting failure, so a retry cannot post everything twice. `:ReviewDedupe` merges threads
that ended up pointing at the same upstream comment.

`:ReviewBase [<target>]` opens a review against a base you choose at open time.

Diffview and review.nvim both know how to draw a thread inside the diff. `inline_owner`
decides which one does: `"auto"` (default) lets Diffview render the threads review.nvim
bridges to it and keeps local drafts for itself; `"review"` and `"diffview"` force it.

## Agent reviews

`:ReviewClaude` picks instructions and permissions. "Read-only review" is enforced on the
agent process itself with an explicit tool allowlist — neither mode can push or rewrite
history. Edit-enabled runs happen in a private worktree under the reviewed repository's
own `.git/prtui/worktrees`, and `:ReviewClean` refuses to remove one holding commits no
branch can reach.

The agent's results are read from its saved transcript; review.nvim keeps that transcript
enabled even when Neovim was started from inside another agent session, because the
agent's terminal keeps no scrollback and is not a usable fallback. If a run is still
waiting on a confirmation prompt, the review prompt is held until the agent can accept it.

## Config

Optional `~/.config/prtui/config.json`:

```json
{
  "theme": "dracula",
  "claude_bin": "claude",
  "base": "auto",
  "saved_instructions": {
    "Critical review": "Be a rigorous, skeptical reviewer…",
    "InfoSec review": "Review strictly for security…"
  }
}
```

## Repo layout

- `rtui/` — the current Rust/ratatui app (this is the product).
- `docs/` — the original design spec.
- `lua/review/`, `plugin/` — the Neovim review frontend.
- `legacy/` — archived earlier prototypes retained for reference.

## Status

Local review, inline comments, Claude reviews + follow-ups, GitHub publishing previews,
themes, commit navigation, and a Comments view are implemented and covered by tests.
