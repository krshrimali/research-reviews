"""Import GitHub review threads into the local store (idempotent)."""

from __future__ import annotations

from .store import Comment, Store, _now


def import_threads(source, store: Store) -> int:
    """Import (or refresh) GitHub review threads. Returns number newly imported."""
    threads = source.threads()
    if not threads:
        return 0
    by_gid = {c.github_id: c for c in store.comments.values() if c.github_id}
    imported = 0
    for t in threads:
        nodes = ((t.get("comments") or {}).get("nodes")) or []
        root_id = None
        for i, cm in enumerate(nodes):
            gid = cm.get("id")
            side = "LEFT" if t.get("diffSide") == "LEFT" else "RIGHT"
            line = cm.get("line") or cm.get("originalLine") or t.get("line") or t.get("originalLine") or 1
            path = cm.get("path") or t.get("path") or ""
            prev = by_gid.get(gid)
            if prev:
                prev.body = cm.get("body", prev.body)
                if t.get("isResolved"):
                    prev.status = "resolved"  # never revert a local resolve
                prev.updated_at = _now()
                if i == 0:
                    root_id = prev.id
            else:
                import uuid as _uuid
                c = Comment(
                    id=str(_uuid.uuid4()), file=path, side=side,
                    line_start=line, line_end=line, body=cm.get("body", ""),
                    origin="github",
                    status="resolved" if t.get("isResolved") else "draft",
                    kind="suggestion" if "```suggestion" in (cm.get("body") or "") else "normal",
                    github_id=gid,
                    in_reply_to=root_id if i > 0 else None,
                    author=(cm.get("author") or {}).get("login", "github"),
                    created_at=cm.get("createdAt", _now()),
                )
                store.comments[c.id] = c
                if i == 0:
                    root_id = c.id
                imported += 1
    store.save()
    return imported
