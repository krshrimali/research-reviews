"""Source abstraction: a PR and a local branch expose the same interface."""

from __future__ import annotations

import hashlib
import os
from dataclasses import dataclass, field

from . import gh, git


@dataclass
class Caps:
    has_threads: bool = False
    has_reviewers: bool = False
    has_checks: bool = False
    can_submit: bool = False


def _hash(s: str) -> str:
    return hashlib.blake2s(s.encode(), digest_size=4).hexdigest()


class Source:
    """Common interface. Subclasses fill in the data."""

    kind = "source"
    repo_root: str
    base_sha: str
    head_sha: str

    def key(self) -> str:  # pragma: no cover - overridden
        raise NotImplementedError

    def caps(self) -> Caps:
        return Caps()

    def title(self) -> str:
        return ""

    def description(self) -> str:
        return ""

    def author(self) -> str:
        return ""

    def updated_at(self) -> str:
        return ""

    def commits(self) -> list[git.Commit]:
        return []

    def files(self) -> list[git.ChangedFile]:
        return []

    def reviewers(self) -> list[str]:
        return []

    def threads(self) -> list[dict]:
        return []

    def checks(self) -> list[dict]:
        return []

    def diff_range(self) -> str:
        return f"{self.base_sha}...{self.head_sha}"


class LocalBranch(Source):
    kind = "branch"

    def __init__(self, cwd: str, base: str | None = None, branch: str | None = None):
        root = git.root(cwd)
        if not root:
            raise ValueError("not inside a git repository")
        self.repo_root = root
        self.branch = branch or git.current_branch(root) or "HEAD"
        head = git.rev_parse("HEAD", root)
        if not head:
            raise ValueError("cannot resolve HEAD")
        self.head_sha = head
        if base and base != "auto":
            resolved = git.rev_parse(base, root)
            if not resolved:
                raise ValueError(f"cannot resolve base ref: {base}")
            self.base_ref = base
            self.base_sha = resolved
        else:
            default = git.default_branch(root)
            self.base_sha = git.merge_base("HEAD", default, root) or git.rev_parse(default, root) or head
            self.base_ref = self.base_sha
        self._commits: list[git.Commit] | None = None
        self._files: list[git.ChangedFile] | None = None

    def key(self) -> str:
        return f"local:{_hash(self.repo_root)}/{self.branch}"

    def caps(self) -> Caps:
        return Caps()

    def title(self) -> str:
        return f"{self.branch} (local branch)"

    def description(self) -> str:
        return f"{len(self.commits())} commit(s) ahead of base {self.base_ref[:12]}."

    def author(self) -> str:
        return os.environ.get("USER", "you")

    def updated_at(self) -> str:
        cs = self.commits()
        return cs[0].date if cs else ""

    def commits(self) -> list[git.Commit]:
        if self._commits is None:
            self._commits = git.commits(self.base_sha, self.head_sha, self.repo_root)
        return self._commits

    def files(self) -> list[git.ChangedFile]:
        if self._files is None:
            self._files = git.changed_files(self.base_sha, self.head_sha, self.repo_root)
        return self._files


class GitHubPR(Source):
    kind = "pr"

    def __init__(self, number: int, cwd: str):
        root = git.root(cwd)
        if not root:
            raise ValueError("not inside a git repository")
        if not gh.available():
            raise ValueError("gh CLI not available")
        owner, repo = gh.owner_repo(root)
        if not owner:
            raise ValueError("cannot determine owner/repo")
        pr = gh.pr_view(number, root)
        if not pr:
            raise ValueError("gh pr view failed")
        git.fetch(root)
        self.repo_root = root
        self.number = number
        self.owner = owner
        self.repo = repo
        self._pr = pr
        self.head_sha = pr.get("headRefOid", "")
        self.base_sha = git.merge_base(pr.get("baseRefOid", ""), self.head_sha, root) or pr.get("baseRefOid", "")
        self._commits: list[git.Commit] | None = None
        self._files: list[git.ChangedFile] | None = None
        self._threads: list[dict] | None = None

    def key(self) -> str:
        return f"gh:{self.owner}/{self.repo}#{self.number}"

    def caps(self) -> Caps:
        return Caps(has_threads=True, has_reviewers=True, has_checks=True, can_submit=True)

    def title(self) -> str:
        return f"#{self.number} {self._pr.get('title', '')}"

    def description(self) -> str:
        return self._pr.get("body", "") or ""

    def author(self) -> str:
        a = self._pr.get("author") or {}
        return a.get("login", "unknown")

    def updated_at(self) -> str:
        return self._pr.get("updatedAt", "")

    def commits(self) -> list[git.Commit]:
        if self._commits is None:
            self._commits = git.commits(self.base_sha, self.head_sha, self.repo_root)
        return self._commits

    def files(self) -> list[git.ChangedFile]:
        if self._files is None:
            self._files = git.changed_files(self.base_sha, self.head_sha, self.repo_root)
        return self._files

    def reviewers(self) -> list[str]:
        out = []
        for r in self._pr.get("reviewRequests", []) or []:
            out.append(r.get("login") or r.get("name") or "team")
        for r in self._pr.get("reviews", []) or []:
            a = r.get("author") or {}
            if a.get("login"):
                out.append(f"{a['login']} ({r.get('state', '')})")
        return out

    def checks(self) -> list[dict]:
        out = []
        for c in self._pr.get("statusCheckRollup", []) or []:
            out.append({
                "name": c.get("name") or c.get("context") or "check",
                "state": c.get("state") or c.get("conclusion") or c.get("status") or "",
            })
        return out

    def review_decision(self) -> str:
        return self._pr.get("reviewDecision", "") or ""

    def threads(self) -> list[dict]:
        if self._threads is None:
            self._threads = gh.review_threads(self.owner, self.repo, self.number, self.repo_root)
        return self._threads


def create(arg: str | int | None, cwd: str, base: str | None = None) -> Source:
    """Factory: PR number/url -> GitHubPR; branch/"." -> LocalBranch."""
    import re
    if isinstance(arg, int):
        return GitHubPR(arg, cwd)
    if isinstance(arg, str):
        m = re.search(r"/pull/(\d+)", arg) or re.fullmatch(r"#?(\d+)", arg)
        if m:
            return GitHubPR(int(m.group(1)), cwd)
        if arg in ("", "."):
            return LocalBranch(cwd, base=base)
        return LocalBranch(cwd, base=base, branch=arg)
    return LocalBranch(cwd, base=base)
