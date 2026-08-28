#!/usr/bin/env python3
"""Register review.nvim into ~/.config/nvim (lazy.nvim spec + which-key entry).

Run OUTSIDE the sandbox (it mounts ~ read-only). Idempotent and re-runnable: it
syncs your config to the current review.nvim binding.

Model: ONE key — <leader>p — opens a contextual action menu inside reviews (and
"start a review" outside one). Nothing else to memorize.

Migration: if a pristine `<file>.bak` exists (from an earlier run), the installer
starts from it so any older review.nvim block is dropped cleanly. Otherwise it
replaces the sentinel-delimited region if present, else inserts after an anchor.

    python3 scripts/install-into-nvim.py --dry-run   # preview
    python3 scripts/install-into-nvim.py             # apply
"""

from __future__ import annotations

import argparse
import os
import re
import sys

# Repo root = two levels up from this script (legacy/scripts/ -> legacy/ -> root),
# so the generated lazy spec points at wherever this checkout actually lives.
REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

NVIM = os.path.expanduser("~/.config/nvim")
PLUGINS = os.path.join(NVIM, "lua/user/plugins.lua")
WHICHKEY = os.path.join(NVIM, "lua/user/whichkey.lua")

BEGIN = "-- >>> review.nvim (managed by install-into-nvim.py)"
END = "-- <<< review.nvim (managed)"

PLUGINS_ANCHOR = (
    '        -- them in one place. The commands above still lazy-load the plugin.\n'
    '        config = function() require "user.diffview" end,\n'
    "    },\n"
)

PLUGINS_BLOCK = f"""
    {BEGIN}
    -- PR/branch review + async Claude reviews. ONE key: <leader>p opens a
    -- contextual action menu; there is nothing else to memorize.
    {{
        dir = "{REPO_ROOT}",
        dependencies = {{ "diffview.nvim" }},
        cmd = {{ "Review", "ReviewList", "ReviewClaude", "ReviewSessions", "ReviewComments", "ReviewClean" }},
        keys = {{ {{ "<leader>p", desc = "Review: actions menu" }} }},
        config = function() require("review").setup {{}} end,
    }},
    {END}
"""

WHICHKEY_ANCHOR = '  { "<leader>rB", desc = "Extract Block To File" },\n'

WHICHKEY_BLOCK = f"""
  {BEGIN}
  {{ "<leader>p", desc = "Review: actions menu (review.nvim)" }},
  {END}
"""


def strip_region(content: str) -> str:
    """Remove a previously-inserted sentinel region, if present."""
    pattern = re.compile(
        r"\n?[ \t]*" + re.escape(BEGIN) + r".*?" + re.escape(END) + r"\n",
        re.DOTALL,
    )
    return pattern.sub("\n", content)


def apply(path: str, anchor: str, block: str, dry: bool) -> str:
    if not os.path.exists(path):
        return f"SKIP  {path} (not found)"

    bak = path + ".bak"
    # Prefer the pristine backup as the base so any older block is dropped.
    if os.path.exists(bak):
        with open(bak, "r", encoding="utf-8") as fh:
            base = fh.read()
        base_note = "from .bak"
    else:
        with open(path, "r", encoding="utf-8") as fh:
            base = strip_region(fh.read())
        base_note = "in place"

    if anchor not in base:
        return f"ERROR {path}: anchor not found — insert manually (see docs)"

    new = base.replace(anchor, anchor + block, 1)

    if dry:
        return f"WOULD SYNC {path} ({base_note})"

    # Preserve the pristine backup; only create one if missing.
    if not os.path.exists(bak):
        with open(bak, "w", encoding="utf-8") as fh:
            fh.write(base)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(new)
    return f"SYNCED {path} ({base_note}; backup at {bak})"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()
    results = [
        apply(PLUGINS, PLUGINS_ANCHOR, PLUGINS_BLOCK, args.dry_run),
        apply(WHICHKEY, WHICHKEY_ANCHOR, WHICHKEY_BLOCK, args.dry_run),
    ]
    print("\n".join(results))
    print("\nRestart Neovim, then press <leader>p (or run :ReviewList) to start.")
    return 1 if any(r.startswith("ERROR") for r in results) else 0


if __name__ == "__main__":
    sys.exit(main())
