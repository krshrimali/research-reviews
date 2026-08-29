# prtui (Rust) — a GitHub PR review UI in your terminal

A fast, polished terminal UI (Rust + [ratatui](https://ratatui.rs)) to review GitHub PRs
and local branches, comment on diff lines, and run **async Claude reviews** rendered as a
clean, readable view. lazygit-style panels, GitHub-accurate colors, Neovim keys.

This is the third iteration (after a Neovim plugin and a Textual TUI). It's a single
static binary with no runtime dependencies.

## Build & run

```bash
cd rtui
cargo build --release          # offline; crates are cached locally
./target/release/prtui         # opens the PR / branch PICKER (fuzzy list)
./target/release/prtui .        # jump straight into the current branch
./target/release/prtui 482      # jump straight into PR #482  (needs gh)
./target/release/prtui my-branch --base develop
```

**Picker:** launching with no argument opens a fuzzy-filterable list of open **PRs**
(fetched via `gh` in the background so startup never blocks) and **local branches**.
`j`/`k` move, `/` (or `i`) search, `enter` opens, and `tab` cycles
**open → closed → merged → all** PRs. `r` refreshes, `t` changes theme, and `q` quits.
From inside a review, press `P` to return to the picker.

Search combines **GitHub-style qualifiers** with **fuzzy** free text, matched across all
metadata (title, number, author, labels, head/base branch, assignees, state, review):

```
is:pr is:draft author:alice label:bug review:required branch:feature  tok ref
```

Qualifiers: `is:pr` `is:branch` `is:draft` `is:open|closed|merged` · `author:` · `label:`
· `review:` (approved/changes_requested/review_required) · `branch:` · `assignee:`.
Free text is fzf-style ranked (contiguous + word-boundary bonuses) with matched
characters highlighted; results sort by score then recency.

Requirements: `git` always, `gh` for PR mode, `claude` for Claude reviews.

## Layout (lazygit-style)

```
┌ Files (1) 3 ─────────┐┌ feature/token-refresh ───────── Diff  Conversation  Claude ┐
│ ● src/auth.lua +3 -2 ││   42 │ - const t = get()                                    │
│ + src/cache.cpp +3   ││   42 │ + const t = getOrRefresh()                      ▸2   │
├ Commits (2) 2 ───────┤│   43 │   return t                                          │
│ 43aa Add token refr… ││ @@ hunk headers in blue, adds green, dels red             │
└──────────────────────┘└───────────────────────────────────────────────────────── ┘
 prtui  j/k move · tab pane · c comment · a Claude · ? help · q quit
```

Three focusable panels — **Files (1)**, **Commits (2)**, **Main (3)** — and the Main
panel has five tabs: **Diff**, **Conversation**, **Timeline**, **Claude**, **Comments**.

## Keys (Neovim-style)

| Key | Action | Key | Action |
|-----|--------|-----|--------|
| `j`/`k` | move down/up | `space` | expand/collapse thread on line |
| `enter` | (diff) expand thread | `V`/`v` | visual-line select |
| `n`/`N` | next / prev comment | `4` | Comments view |
| `d`/`e`/`y` | delete / edit / copy thread | `H` | hide / unhide thread |
| `S` | publish review to GitHub | `/` | search within the diff |
| `o` | open file @ commit ($EDITOR) | `X` | PR actions menu (merge/close/…) |
| `O` | open active info view in Neovim/$EDITOR | `\` | toggle split (side-by-side) diff |
| `E` | react to the thread (chips) | `A` | apply suggestion in worktree |

Selecting a commit in the Commits panel (`enter`) shows that commit's diff read-only;
select a file to return to the PR/branch diff.
| `^d`/`^u` | half-page down/up | `c` | comment on line/selection |
| `^f`/`^b` | full-page down/up | `s` | suggest change |
| `g`/`G` | top/bottom | `r` | reply to thread |
| `tab` / `1`/`2`/`3` | focus panel | `x` | resolve thread |
| `[` / `]` | cycle Main tab | `a` | run Claude review |
| `l`/`enter` | open file / focus | `t` | cycle color theme |
| `P` | back to picker | `?` / `q` | help / quit |
| `:` | command palette | `F` | cycle current-view filter |
| `D` | thread detail drawer | `5` / `6` | Timeline / Claude tabs |
| `R` | manually refresh PR/branch data | | |

The **Comments inbox** supports selective review work. Use `m` to select a thread, `M`
to select all visible threads, and `u` to clear the selection. `A` previews an assessment
of the selected threads and sends only actionable items to Claude. `/` searches across
body, author, file, label, and workflow state; `F` cycles all, unresolved, resolved,
Claude, clarification, committed, unpushed, and selected filters. `C`, `Z`, and `T` mark
a thread as needing clarification, deferred, or a follow-up task. `L`, `!`, and `W` cycle
its label, priority, and next-action owner. `U`/`I` jump to unresolved/actionable work,
`R` retries the selected thread, and `backspace` returns to the previous location.

The footer is contextual: it shows actions for the focused panel and active view. Tabs
carry accelerators and badges, the sidebar automatically hides on narrow terminals, and
the last tab/file/cursor/scroll/collapsed-directory state is restored per review.

Press `R` outside the Comments inbox to refresh the current PR or branch in the
background. For PRs this refreshes metadata, checks, review threads, commits, files, and
diffs without blocking input. In Comments, `R` retains its thread-retry action.

## Performance diagnostics

prtui redraws only after visible state changes, debounces UI-state persistence, caches raw
diffs and syntax tokens, prefetches file diffs in cancellable background generations, and
limits token highlighting to the visible diff neighborhood. Set `PRTUI_PERF=1` to record
frame, Git, refresh, and persistence timings in `/tmp/prtui-perf-<pid>.log`; override the
destination with `PRTUI_PERF_LOG`.

Press uppercase `O` from any main tab to open its complete content in Neovim (or
`$EDITOR`). **Diff** opens the complete current file/commit patch as a `.diff` buffer;
Conversation, Timeline, Claude, and Comments open as searchable Markdown. Lowercase `o`
remains the source-file action.

**Diff:** built-in syntax highlighting (offline; keywords/strings/**comments in italic**/numbers) — applied everywhere code appears: the unified diff, both sides of the split view (including context lines), and fenced ` ```code``` ` blocks inside review comments and the PR description. `+`/`-` expand/collapse context lines (git -U<n>).

**Outdated comments (GitHub-style):** each comment snapshots the code of the line it was written against. On every reload the tool reconciles it against the current diff: if that code **moved**, the comment moves with it; if the code **changed/disappeared**, the comment is marked **Outdated** — removed from the inline diff and grouped under an "Outdated" section in the Comments view (and flagged `⊘ Outdated` in Conversation) showing the original code it referenced. Imported GitHub threads honor the server's own `isOutdated` flag. Press `\` to toggle a **split (side-by-side)** view — old on the left, new on the right, cells wrapped so nothing is clipped. Modified lines get **word-diff** emphasis: only the words that actually changed are highlighted (in both unified and split views), computed offline via a small LCS.

**Files tree:** the Files panel is a **collapsible directory tree** — `l`/`enter` on a directory row toggles it (with a recursive file count), on a file row opens its diff. `m` marks a file "viewed".

**Timeline:** a read-only **activity feed** tab (commits pushed + reviews submitted) in chronological order, with `✓`/`✗`/`◆` verdict markers.

**Reactions:** press `E` on a thread to open a reaction picker (`+1`, `-1`, `laugh`, `hooray`, `confused`, `heart`, `rocket`, `eyes`); reactions render as ASCII chips like `[+1 2]` and, for imported GitHub comments, are posted back via the `addReaction` GraphQL mutation.

**Existing PR conversation:** opening a PR imports its GitHub review threads — they show on
the diff with a `◆N` marker (blue), inline, and in the Conversation / Comments views. Reply
(`r`) posts back to the thread and resolve (`x`) resolves it on GitHub. Marker legend:
`◆` GitHub · `★` Claude · `▸` local.

**Inline threads:** a commented diff line shows a `★N`/`▸N` marker; press `space` (or
`enter`) on it to expand the full thread (root + replies) inline, and again to collapse
— opt-in per line, so the diff stays clean by default.

**Publish to GitHub (`S`, PR only):** opens a preview of the verdict + summary + every
comment that will be posted — each toggleable and editable. **Nothing is posted until you
`ctrl+s`.** On submit it creates a PR review via `gh` and flips those comments to
`published`. `esc` cancels with drafts intact.

**PR actions (`X`, PR only):** a confirm-gated menu of `gh pr` operations — merge (squash),
close, reopen, mark ready for review, convert to draft. Pick with the shown accelerator
key; each asks `y/n` before running so nothing outward-facing happens by accident.

**Checks / CI:** the Conversation view shows a **Checks** panel from the PR's
`statusCheckRollup` — `✓` success (green), `✗` failure (red), `•` pending (yellow) — with a
`N/M passing` rollup, mirrored in the tab header.

**Markdown:** comment and PR-description bodies render light inline markdown — `**bold**`,
`*italic*`, `` `code` ``, `[links](url)`, headings and bullet lists — so they read like GitHub.

**Themes:** press `t` to cycle (github-dark, github-light, dracula, gruvbox-dark) — every
component recolors. **Claude line comments** show as a purple `★` marker on the diff
(human threads show `▸`). **Follow-up reviews:** reply to a thread with `r`, then press `a`
again — Claude sees the reply and responds to it.

In the **Claude** form: `↑/↓` picks an instruction profile, `enter` inserts a newline in
the direction, and `ctrl+s` runs the review. `ctrl+e` enables edits, `ctrl+r` enables
auto-resolve, `ctrl+w` addresses selected/all comments, and `ctrl+p` explicitly requests
a push after validation. Edit-enabled reviews first refresh the PR/branch and always use
an isolated writable worktree at the refreshed head; completed edits are committed but
are not pushed unless `ctrl+p` is enabled. In a sandbox or on push failure, the completion
summary retains the commit and worktree path.

Automatic worktrees are created only inside the repository's own Git metadata at
`.git/prtui/worktrees/` (or the repository's Git common directory for linked worktrees),
with a private parent directory. prtui never copies a checkout into a global cache or
another external directory. Existing worktrees from older versions are not deleted
automatically.
Run `prtui --cleanup-worktrees --cwd /path/to/repository` to remove only prtui-managed
worktrees older than 30 days. No checkout outside that repository is inspected or removed.

GitHub Enterprise hosts and repository URL prefixes are discovered through `gh`. For forked
pull requests, fetches use the base repository while implementation pushes target the fork's
head repository. Set `gh_bin` in the configuration when the authenticated corporate `gh`
binary or wrapper is not named `gh`; the same executable is used for Git credentials.

After Claude commits an implementation, that commit immediately becomes the UI's preview
head: Files, Diff, and Commits show the result even before it is pushed. A non-blocking result
drawer leaves the diff navigable and offers `p` to push in the background, `b` to safely
fast-forward/update the local branch, `o` to open the repository-local worktree, and `i` to
toggle between the reviewed and implementation diffs. `z` or `esc` closes the drawer; `z`
reopens it without losing the result. A successful PR push triggers a background refresh.

`ctrl+y` copies the complete assembled prompt—including review context and every included
thread conversation. To keep prompts compact, the patch is not pasted; the prompt tells
the agent to run an exact `git diff <base>...HEAD` command in the checkout. `ctrl+o` opens
that final prompt in `$EDITOR`; after the editor exits, the revised prompt opens in a
preview where `ctrl+s` runs it, `y`/`c` copies it, and `e`/`o` edits it again.
Compose: `ctrl+s` submit, `esc` cancel.

While composing or editing a comment, `ctrl+o` opens the draft in `$EDITOR` and reloads
it into the compose window when the editor exits. Claude reviews stream initialization,
tool activity, and intermediate text into the status bar and the Claude tab's Progress
section while they run.

Address mode records the assessment, commit, worktree, validation results, and push state
on each thread. It refuses a dirty checkout, verifies that the result descends from the
reviewed head, blocks configured protected paths, and runs configured validation before
pushing. The completion summary reports whether the work was pushed, left committed in a
sandbox, rejected by validation, or failed to push.

Optional safeguards live in `~/.config/prtui/config.json`:

```json
{
  "address_test_commands": ["cargo test --all-targets", "cargo clippy --all-targets"],
  "protected_paths": ["vendor/", "generated/"],
  "commit_strategy": "single"
}
```

`commit_strategy` may be `single` or `per-thread`; it is included in Claude's explicit
implementation policy. Without validation commands, prtui still performs ancestry and
protected-path checks before any push.

## Claude review

Press `a`, choose a saved profile ("Critical review" / "InfoSec review") + a direction.
The review runs in a background thread (`claude -p --output-format stream-json`); progress
streams into the Claude tab and the status bar shows a live badge. Results render as:
verdict, summary, each threaded reply mapped to `file:line`, new inline comments (with
`suggestion` blocks), notes, and a progress log. Tool access is read-only by default;
**allow edits** grants an explicit git-subcommand allowlist and never pushes.

## State

Comments + sessions persist under `$PRTUI_STATE_DIR` (or `~/.local/state/prtui`), keyed
by repo + source, with atomic writes, merge-on-save, and deletion tombstones.

## Tests & screenshots

```bash
cargo test                                  # data layer + fake-claude end-to-end
cargo build && ./target/debug/shot <repo> <out_dir> --base main   # emit SVG screenshots
```

The `shot` binary renders each screen headless to an SVG (via a `TestBackend` →
`buffer_to_svg` exporter) for visual verification without a live terminal.

## Notes

- Crates build **offline** from the local cargo cache (`~/.cargo`); `.cargo/config.toml`
  sets `net.offline = true` because the sandbox blocks `crates.io`.
- Truecolor palette; degrades on 256-color terminals. Icons are ASCII/box-drawing (no
  emoji), so no glyph tofu.
