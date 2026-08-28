"""Entry point: python -m prtui [<pr|branch|.>] [--base REF] [--cwd DIR]."""

from __future__ import annotations

import argparse
import os

from .app import ReviewApp


def main() -> None:
    ap = argparse.ArgumentParser(prog="prtui", description="GitHub-style PR/branch review TUI")
    ap.add_argument("target", nargs="?", default=None,
                    help="PR number/URL, branch name, or '.' (current branch). "
                         "Omit to pick from a list.")
    ap.add_argument("--base", default="auto", help="base ref for local-branch diffs")
    ap.add_argument("--cwd", default=None, help="repository directory")
    ap.add_argument("--claude-bin", default="claude", help="path to the claude CLI")
    args = ap.parse_args()

    initial: str | int | None = args.target
    if isinstance(args.target, str) and args.target.isdigit():
        initial = int(args.target)

    config = {"base": args.base, "claude_bin": args.claude_bin}
    ReviewApp(cwd=args.cwd or os.getcwd(), initial=initial, config=config).run()


if __name__ == "__main__":
    main()
