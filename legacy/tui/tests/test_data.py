"""Plain-assert tests for the data layer. Run: .venv/bin/python tests/test_data.py"""

import asyncio
import os
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from prtui.data import claude, git, source, store  # noqa: E402

fails = 0


def check(cond, msg):
    global fails
    print(("  ok   " if cond else "  FAIL ") + msg)
    if not cond:
        fails += 1


def make_repo() -> str:
    d = tempfile.mkdtemp()
    def g(*a):
        subprocess.run(["git", *a], cwd=d, check=True, capture_output=True)
    g("init", "-q", "-b", "main")
    g("config", "user.email", "t@t")
    g("config", "user.name", "t")
    os.makedirs(os.path.join(d, "src"))
    with open(os.path.join(d, "src/auth.lua"), "w") as f:
        f.write("local M = {}\nfunction M.get() return 1 end\nreturn M\n")
    g("add", "-A"); g("commit", "-qm", "base")
    g("checkout", "-q", "-b", "feature/x")
    with open(os.path.join(d, "src/auth.lua"), "w") as f:
        f.write("local M = {}\nfunction M.get_or_refresh() return 2 end\nreturn M\n")
    with open(os.path.join(d, "src/cache.cpp"), "w") as f:
        f.write("int cache(){return 0;}\n")
    g("add", "-A"); g("commit", "-qm", "add refresh + cache")
    return d


def main():
    os.environ["PRTUI_STATE_DIR"] = tempfile.mkdtemp()
    d = make_repo()

    src = source.create(".", d, base="main")
    check(src.kind == "branch", "source is a branch")
    check(len(src.commits()) == 1, "one commit ahead")
    paths = {f.path for f in src.files()}
    check("src/auth.lua" in paths and "src/cache.cpp" in paths, "changed files detected")
    counts = {f.path: (f.additions, f.deletions) for f in src.files()}
    check(counts["src/cache.cpp"][0] >= 1, "additions counted")

    st = store.Store(src.key(), src.repo_root)
    c = st.add("src/auth.lua", "RIGHT", 2, "why rename?")
    st.reply(c.id, "a reply")
    check(len(st.replies(c.id)) == 1, "reply added")
    st2 = store.Store(src.key(), src.repo_root)
    check(len(st2.threads_for_file("src/auth.lua")) == 1, "comment persisted")
    st2.delete(c.id)
    st3 = store.Store(src.key(), src.repo_root)
    check(st3.get(c.id) is None, "deletion persists (tombstone)")

    # contract parsing
    txt = 'review\n```json\n{"verdict":"approve","summary":"ok","thread_replies":[]}\n```'
    f, err = claude.extract_findings(txt)
    check(err is None and f["verdict"] == "approve", "findings parsed")
    ev = claude.parse_stream_line('{"type":"result","result":"x"}')
    check(ev and ev["kind"] == "result", "stream result parsed")

    # end-to-end with fake claude
    fake = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fake_claude.sh")
    st4 = store.Store(src.key(), src.repo_root)
    root = st4.add("src/auth.lua", "RIGHT", 2, "why rename?")
    sess = asyncio.run(claude.run(st4, src, "Critical review", claude_bin=fake))
    check(sess.state == "done", "fake claude run completed")
    check(sess.verdict == "request_changes", "verdict captured")
    check(len(st4.replies(root.id)) == 1, "claude replied to thread")
    claude_new = [c for c in st4.comments.values() if c.origin == "claude" and not c.in_reply_to]
    check(len(claude_new) == 1, "claude added a new comment")

    # regression: large stderr must not deadlock spawn_stream
    from prtui.data import proc
    script = "import sys; sys.stderr.write('x'*300000); sys.stderr.flush(); sys.stdout.write('done\\n')"
    got = []
    code, err = asyncio.run(proc.spawn_stream(
        [sys.executable, "-c", script], on_line=got.append))
    check(got == ["done"] and len(err) >= 300000, "large stderr does not deadlock")

    # regression: null line_start in new_comments must not crash apply
    st5 = store.Store(src.key() + "x", src.repo_root)
    sess2 = claude.Session(id="s2")
    claude._apply(st5, src, sess2, {
        "verdict": "comment", "summary": "s",
        "new_comments": [{"file": "src/auth.lua", "line_start": None, "body": "b"}],
    })
    check(sess2.applied and any(c.origin == "claude" for c in st5.comments.values()),
          "null line_start coerced, apply succeeds")

    # regression: unknown persisted field is ignored on load
    import json as _json
    p = st5._path()
    doc = _json.loads(p.read_text())
    first = next(iter(doc["comments"].values()))
    first["bogus_field"] = 123
    p.write_text(_json.dumps(doc))
    st6 = store.Store(src.key() + "x", src.repo_root)
    check(len(st6.comments) >= 1, "schema drift (unknown field) tolerated on load")

    # regression: concurrent save merges both processes' comments
    a = store.Store(src.key() + "cc", src.repo_root)
    b = store.Store(src.key() + "cc", src.repo_root)
    ca = a.add("f", "RIGHT", 1, "from A")
    cb = b.add("f", "RIGHT", 2, "from B")  # b didn't see ca; save must not clobber it
    final = store.Store(src.key() + "cc", src.repo_root)
    check(final.get(ca.id) is not None and final.get(cb.id) is not None,
          "concurrent saves merge (no clobber)")

    print("\nDATA: ALL PASSED" if fails == 0 else f"\nDATA: {fails} FAILED")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
