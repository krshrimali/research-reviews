"""Git queries for review data (commits, files, diffs, merge-base)."""

from __future__ import annotations

from dataclasses import dataclass, field

from . import proc

RS = "\x1e"  # record separator
US = "\x1f"  # unit separator


@dataclass
class Commit:
    sha: str
    short: str
    subject: str
    body: str
    author: str
    date: str


@dataclass
class ChangedFile:
    path: str
    status: str  # added|modified|deleted|renamed
    additions: int = 0
    deletions: int = 0
    old_path: str | None = None


def root(cwd: str | None = None) -> str | None:
    ok, out, _ = proc.git(["rev-parse", "--show-toplevel"], cwd)
    return out.strip() if ok else None


def is_repo(cwd: str | None = None) -> bool:
    ok, _, _ = proc.git(["rev-parse", "--is-inside-work-tree"], cwd)
    return ok


def current_branch(cwd: str | None = None) -> str | None:
    ok, out, _ = proc.git(["symbolic-ref", "--quiet", "--short", "HEAD"], cwd)
    return out.strip() if ok else None


def default_branch(cwd: str | None = None) -> str:
    ok, out, _ = proc.git(["symbolic-ref", "refs/remotes/origin/HEAD"], cwd)
    if ok:
        ref = out.strip()
        if ref.startswith("refs/remotes/"):
            return ref[len("refs/remotes/"):]
    for name in ("origin/main", "origin/master"):
        if proc.git(["rev-parse", "--verify", "--quiet", name], cwd)[0]:
            return name
    return "origin/main"


def rev_parse(rev: str, cwd: str | None = None) -> str | None:
    ok, out, _ = proc.git(["rev-parse", rev], cwd)
    return out.strip() if ok else None


def merge_base(a: str, b: str, cwd: str | None = None) -> str | None:
    ok, out, _ = proc.git(["merge-base", "--end-of-options", a, b], cwd)
    sha = out.strip()
    return sha or None if ok else None


def commits(base: str, head: str, cwd: str | None = None) -> list[Commit]:
    fmt = f"%H{US}%h{US}%s{US}%b{US}%an{US}%aI{RS}"
    ok, out, _ = proc.git(["log", f"--format={fmt}", f"{base}..{head}"], cwd)
    if not ok:
        return []
    result: list[Commit] = []
    for record in out.split(RS):
        rec = record.strip()
        if not rec:
            continue
        f = rec.split(US)
        if len(f) >= 6 and f[0]:
            result.append(Commit(f[0], f[1], f[2], f[3].strip(), f[4], f[5]))
    return result


def _numstat_newpath(path: str) -> str:
    """Normalize a numstat path, resolving `src/{old => new}.lua` brace renames."""
    if "=>" not in path:
        return path
    if "{" in path:
        import re
        return re.sub(r"\{.*?=>\s*(.*?)\}", r"\1", path).replace("//", "/")
    return path.split("=>")[-1].strip()


def changed_files(base: str, head: str, cwd: str | None = None) -> list[ChangedFile]:
    rng = f"{base}...{head}"
    ok, name_out, _ = proc.git(["diff", "--name-status", "-M", rng], cwd)
    if not ok:
        return []
    files: list[ChangedFile] = []
    by_path: dict[str, ChangedFile] = {}
    for line in name_out.splitlines():
        parts = line.split("\t")
        st = parts[0] if parts else ""
        if not st:
            continue
        if st.startswith("R"):
            entry = ChangedFile(path=parts[2], status="renamed", old_path=parts[1])
        elif st.startswith("A"):
            entry = ChangedFile(path=parts[1], status="added")
        elif st.startswith("D"):
            entry = ChangedFile(path=parts[1], status="deleted")
        else:
            entry = ChangedFile(path=parts[1], status="modified")
        files.append(entry)
        by_path[entry.path] = entry
    ok2, num_out, _ = proc.git(["diff", "--numstat", "-M", rng], cwd)
    if ok2:
        for line in num_out.splitlines():
            cols = line.split("\t")
            if len(cols) >= 3:
                add, dele, path = cols[0], cols[1], cols[2]
                e = by_path.get(_numstat_newpath(path)) or by_path.get(path)
                if e:
                    e.additions = int(add) if add.isdigit() else 0
                    e.deletions = int(dele) if dele.isdigit() else 0
    return files


def file_diff(base: str, head: str, path: str, cwd: str | None = None) -> str:
    """Unified diff for a single file across base...head."""
    ok, out, _ = proc.git(["diff", f"{base}...{head}", "--", path], cwd)
    return out if ok else ""


def full_diff(base: str, head: str, cwd: str | None = None) -> str:
    ok, out, _ = proc.git(["diff", f"{base}...{head}"], cwd)
    return out if ok else ""


def fetch(cwd: str | None = None) -> bool:
    return proc.git(["fetch", "--quiet", "origin"], cwd)[0]
