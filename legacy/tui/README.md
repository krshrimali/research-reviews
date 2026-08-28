# prtui — a GitHub PR review UI in your terminal

A standalone TUI (built on [Textual](https://textual.textualize.io/)) to review GitHub
PRs **and** local branches, comment on lines, and run **async Claude reviews** whose
output is rendered as a proper, scrollable, GitHub-style view — not dumped as raw text.

Neovim-style keys throughout (`j/k`, `g/G`, `h/l`, `/`, `Tab`, `q`).

## Why this exists

The earlier Neovim-plugin version made the Claude review output hard to read. A dedicated
TUI with rich markdown/diff widgets fixes that: the **Claude** tab shows the verdict,
summary, each threaded reply mapped to `file:line`, new inline comments, and a progress
log — all navigable.

## Install & run

```bash
cd tui
python3 -m venv .venv
./.venv/bin/pip install -r requirements.txt

# pick from a list of PRs + local branches:
./.venv/bin/python -m prtui

# or open one directly:
./.venv/bin/python -m prtui .                 # current branch (vs merge-base w/ origin/HEAD)
./.venv/bin/python -m prtui 482               # PR #482
./.venv/bin/python -m prtui my-feature-branch # a named local branch
./.venv/bin/python -m prtui . --base develop  # explicit base ref
```

Requirements: `git` (always), `gh` (for PR mode), `claude` (for Claude reviews).

## Layout

```
┌ prtui — #482 Add token refresh ─────────────── [Conversation] [Files] [Claude] ┐
│ Files changed         │  # Add token refresh to auth layer                      │
│  README.md      +1    │  octocat · 2026-08-22 · checks 4/4 · request_changes   │
│  src/auth.lua   +3 -2 │  ───────────────────────────────────────────────       │
│  src/cache.cpp  +3    │  Refreshes OAuth tokens before expiry…                  │
│                       │  ## Commits                                             │
│ Commits               │  · d1f0716 Add token refresh to auth layer             │
│  9fbd749 docs         │  ## Comments                                            │
│  d1f0716 Add token…   │  octocat · src/auth.lua:3 ○  Should this handle 401?   │
└───────────────────────┴─────────────────────────────────────────────────────  ┘
 j/k move · l open · Tab pane · 1/2/3 tab · c comment · a Claude review · ? help · q quit
```

Three tabs: **Conversation** (description, commits, threads), **Files** (cursorable diff
— put the cursor on a line and `c` to comment), **Claude** (the rendered review output).

## Keys

| Key | Action | Key | Action |
|-----|--------|-----|--------|
| `j`/`k` | down/up | `c` | comment on line |
| `g`/`G` | top/bottom | `s` | suggest change |
| `l`/`enter` | open/select | `r` | reply to thread |
| `h` | fold | `x` | resolve thread |
| `Tab` | next pane | `a` | run Claude review |
| `1`/`2`/`3` | jump to tab | `A` | Claude output |
| `/` | filter (list) | `o` | open @ commit |
| `?` | help | `q` | back / quit |

## Claude review

Press `a`, pick a saved instruction profile ("Critical review", "InfoSec review", …) +
a free-text direction, and optionally enable **Allow edits** / **Auto-resolve**. The
review runs asynchronously (`claude -p --output-format stream-json`); progress streams
into the Claude tab and a notification fires on completion with the verdict. Tool access
is read-only by default; edits use an explicit git-subcommand allowlist and never push.

## State

Comments and sessions persist under `$PRTUI_STATE_DIR` (or `~/.local/state/prtui`) keyed
by repo + source, with atomic writes and deletion tombstones.

## Tests

```bash
./tests/run.sh          # data layer + headless UI render/screenshots
```
