"""Persistent comment + Claude-session store (JSON, atomic writes, tombstones)."""

from __future__ import annotations

import json
import os
import tempfile
import time
import uuid
from dataclasses import asdict, dataclass, field
from pathlib import Path

SCHEMA_VERSION = 1


def _state_root() -> Path:
    override = os.environ.get("PRTUI_STATE_DIR")
    if override:
        return Path(override)
    base = os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state")
    return Path(base) / "prtui"


def _now() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def _from_dict(cls, data: dict):
    """Build a dataclass, ignoring unknown keys (tolerates schema drift)."""
    if not isinstance(data, dict):
        return None
    fields = {f.name for f in __import__("dataclasses").fields(cls)}
    try:
        return cls(**{k: v for k, v in data.items() if k in fields})
    except TypeError:
        return None


@dataclass
class Comment:
    id: str
    file: str
    side: str  # LEFT|RIGHT
    line_start: int
    line_end: int
    body: str
    origin: str = "local"  # local|github|claude
    status: str = "draft"  # draft|published|resolved|outdated
    kind: str = "normal"  # normal|suggestion
    suggestion_text: str | None = None
    in_reply_to: str | None = None
    github_id: str | None = None
    author: str = "you"
    created_at: str = field(default_factory=_now)
    updated_at: str = field(default_factory=_now)
    hidden: bool = False


@dataclass
class Session:
    id: str
    state: str = "running"  # running|done|error
    verdict: str | None = None
    summary: str = ""
    instruction: str = ""
    allow_edits: bool = False
    auto_resolve: bool = False
    started_at: str = field(default_factory=_now)
    ended_at: str | None = None
    replied: list[str] = field(default_factory=list)
    findings: list[dict] = field(default_factory=list)
    commits: list[dict] = field(default_factory=list)
    log: list[str] = field(default_factory=list)
    error: str | None = None
    applied: bool = False


class Store:
    def __init__(self, source_key: str, repo_root: str):
        self.source_key = source_key
        self.repo_root = repo_root
        self.comments: dict[str, Comment] = {}
        self.sessions: dict[str, Session] = {}
        self.tombstones: dict[str, str] = {}
        self._load()

    # --- persistence ---------------------------------------------------------
    def _path(self) -> Path:
        import hashlib
        rk = hashlib.blake2s(self.repo_root.encode(), digest_size=4).hexdigest()
        sk = hashlib.blake2s(self.source_key.encode(), digest_size=4).hexdigest()
        return _state_root() / rk / f"{sk}.json"

    def _load(self) -> None:
        p = self._path()
        if not p.exists():
            return
        try:
            doc = json.loads(p.read_text())
        except (json.JSONDecodeError, OSError):
            return
        self.tombstones = doc.get("tombstones", {})
        for cid, c in (doc.get("comments") or {}).items():
            if cid not in self.tombstones:
                obj = _from_dict(Comment, c)
                if obj:
                    self.comments[cid] = obj
        for sid, s in (doc.get("sessions") or {}).items():
            obj = _from_dict(Session, s)
            if obj:
                self.sessions[sid] = obj

    def save(self) -> None:
        p = self._path()
        p.parent.mkdir(parents=True, exist_ok=True)
        # Reload-merge tombstones from disk so concurrent deletes survive.
        disk = {}
        if p.exists():
            try:
                disk = json.loads(p.read_text())
            except (json.JSONDecodeError, OSError):
                disk = {}
        merged_tombstones = {**disk.get("tombstones", {}), **self.tombstones}
        # Merge disk records another process may have written; in-memory wins on
        # conflict, tombstoned ids are dropped.
        comments = {cid: c for cid, c in (disk.get("comments") or {}).items()
                    if cid not in merged_tombstones}
        comments.update({cid: asdict(c) for cid, c in self.comments.items()
                         if cid not in merged_tombstones})
        sessions = dict(disk.get("sessions") or {})
        sessions.update({sid: asdict(s) for sid, s in self.sessions.items()})
        doc = {
            "schema_version": SCHEMA_VERSION,
            "source_key": self.source_key,
            "comments": comments,
            "sessions": sessions,
            "tombstones": merged_tombstones,
        }
        fd, tmp = tempfile.mkstemp(dir=str(p.parent), prefix=".tmp")
        with os.fdopen(fd, "w") as fh:
            json.dump(doc, fh)
        os.replace(tmp, str(p))

    # --- comment CRUD --------------------------------------------------------
    def add(self, file: str, side: str, line_start: int, body: str,
            line_end: int | None = None, origin: str = "local",
            kind: str = "normal", suggestion_text: str | None = None) -> Comment:
        c = Comment(
            id=str(uuid.uuid4()), file=file, side=side,
            line_start=line_start, line_end=line_end or line_start,
            body=body, origin=origin, kind=kind, suggestion_text=suggestion_text,
            author=os.environ.get("USER", "you"),
        )
        self.comments[c.id] = c
        self.save()
        return c

    def reply(self, parent_id: str, body: str, origin: str = "local",
              suggestion_text: str | None = None) -> Comment | None:
        parent = self.comments.get(parent_id)
        if not parent:
            return None
        root = self.root_of(parent_id)
        c = Comment(
            id=str(uuid.uuid4()), file=parent.file, side=parent.side,
            line_start=parent.line_start, line_end=parent.line_end, body=body,
            origin=origin, in_reply_to=root,
            kind="suggestion" if suggestion_text else "normal",
            suggestion_text=suggestion_text,
            author=os.environ.get("USER", "you"),
        )
        self.comments[c.id] = c
        self.save()
        return c

    def root_of(self, cid: str) -> str:
        c = self.comments.get(cid)
        return c.in_reply_to or cid if c else cid

    def delete(self, cid: str) -> bool:
        c = self.comments.get(cid)
        if not c:
            return False
        now = _now()
        if not c.in_reply_to:
            for other_id, other in list(self.comments.items()):
                if other.in_reply_to == cid:
                    del self.comments[other_id]
                    self.tombstones[other_id] = now
        del self.comments[cid]
        self.tombstones[cid] = now
        self.save()
        return True

    def set_resolved(self, cid: str, resolved: bool) -> None:
        root = self.root_of(cid)
        for c in self.comments.values():
            if c.id == root or c.in_reply_to == root:
                c.status = "resolved" if resolved else "draft"
                c.updated_at = _now()
        self.save()

    def threads_for_file(self, file: str) -> list[Comment]:
        roots = [c for c in self.comments.values() if c.file == file and not c.in_reply_to]
        roots.sort(key=lambda c: c.line_start)
        return roots

    def all_threads(self) -> list[Comment]:
        return [c for c in self.comments.values() if not c.in_reply_to]

    def replies(self, root_id: str) -> list[Comment]:
        out = [c for c in self.comments.values() if c.in_reply_to == root_id]
        out.sort(key=lambda c: c.created_at)
        return out

    def get(self, cid: str) -> Comment | None:
        return self.comments.get(cid)
