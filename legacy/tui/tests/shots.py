"""Drive the app headless and export SVG screenshots of each view."""

import asyncio
import os
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from prtui.app import ReviewApp  # noqa: E402
from prtui.data import claude, source, store  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))


def make_repo() -> str:
    d = tempfile.mkdtemp()
    def g(*a):
        subprocess.run(["git", *a], cwd=d, check=True, capture_output=True)
    g("init", "-q", "-b", "main"); g("config", "user.email", "t@t"); g("config", "user.name", "t")
    os.makedirs(os.path.join(d, "src"))
    open(os.path.join(d, "src/auth.lua"), "w").write(
        "local M = {}\n\nfunction M.get()\n  return token\nend\n\nreturn M\n")
    g("add", "-A"); g("commit", "-qm", "base commit")
    g("checkout", "-q", "-b", "feature/token-refresh")
    open(os.path.join(d, "src/auth.lua"), "w").write(
        "local M = {}\n\nfunction M.get_or_refresh()\n  local t = fetch()\n  return t\nend\n\nreturn M\n")
    open(os.path.join(d, "src/cache.cpp"), "w").write("int cache() {\n  return 0;\n}\n")
    g("add", "-A"); g("commit", "-qm", "Add token refresh to auth layer")
    open(os.path.join(d, "README.md"), "w").write("# demo\n")
    g("add", "-A"); g("commit", "-qm", "docs: add readme")
    return d


async def main() -> None:
    os.environ["PRTUI_STATE_DIR"] = tempfile.mkdtemp()
    d = make_repo()

    # Seed a store: a human comment + a completed Claude review (via fake claude).
    src = source.create(".", d, base="main")
    st = store.Store(src.key(), src.repo_root)
    st.add("src/auth.lua", "RIGHT", 3, "Should this handle the 401 refresh path too?")
    await claude.run(st, src, "Critical review",
                     claude_bin=os.path.join(HERE, "fake_claude.sh"))

    config = {"claude_bin": os.path.join(HERE, "fake_claude.sh"), "base": "main"}

    # Source-list screen (guards against shadowing Textual internals like _render).
    list_app = ReviewApp(cwd=d, initial=None, config=config)
    async with list_app.run_test(size=(110, 30)) as pilot:
        await pilot.pause()
        list_app.save_screenshot("/tmp/shot_list.svg")

    app = ReviewApp(cwd=d, initial=".", config=config)
    async with app.run_test(size=(110, 34)) as pilot:
        await pilot.pause()
        app.save_screenshot("/tmp/shot_conversation.svg")
        # Files tab
        await pilot.press("2")
        await pilot.pause()
        app.save_screenshot("/tmp/shot_files.svg")
        # Claude tab
        await pilot.press("3")
        await pilot.pause()
        app.save_screenshot("/tmp/shot_claude.svg")
        # Help overlay
        await pilot.press("question_mark")
        await pilot.pause()
        app.save_screenshot("/tmp/shot_help.svg")

    for n in ("list", "conversation", "files", "claude", "help"):
        p = f"/tmp/shot_{n}.svg"
        print(n, os.path.getsize(p) if os.path.exists(p) else "MISSING")


if __name__ == "__main__":
    asyncio.run(main())
