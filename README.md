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

Local review, inline comments, Claude reviews + follow-ups, themes, and a Comments view are
implemented and covered by tests. In progress (see `docs/`): publishing reviews back to GitHub,
richer comment management, and commit-level navigation.
