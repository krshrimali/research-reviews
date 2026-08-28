"""Pure render helpers: unified diff -> Rich Text, and markdown builders."""

from __future__ import annotations

from rich.text import Text


def diff_to_text(diff: str, comment_lines: dict[int, int] | None = None) -> Text:
    """Render a unified diff with GitHub-like colors and a new-file line gutter.

    `comment_lines` maps new-file line number -> comment count, shown as a 💬 marker.
    """
    comment_lines = comment_lines or {}
    out = Text()
    new_ln = 0
    for line in diff.splitlines():
        marker = ""
        style = None
        gutter = "    "
        if line.startswith(("diff --git", "index ", "--- ", "+++ ")):
            style = "bold bright_black"
        elif line.startswith("@@"):
            style = "bold cyan"
            # parse the new-file start line from @@ -a,b +c,d @@
            try:
                seg = line.split("+", 1)[1]
                new_ln = int(seg.split(",")[0].split(" ")[0]) - 1
            except (IndexError, ValueError):
                pass
        elif line.startswith("+"):
            style = "green"
            new_ln += 1
            gutter = f"{new_ln:>4}"
            if new_ln in comment_lines:
                marker = f"  💬{comment_lines[new_ln]}"
        elif line.startswith("-"):
            style = "red"
        else:
            new_ln += 1
            gutter = f"{new_ln:>4}"
            if new_ln in comment_lines:
                marker = f"  💬{comment_lines[new_ln]}"
        out.append(gutter + " ", style="bright_black")
        out.append(line, style=style)
        if marker:
            out.append(marker, style="bold yellow")
        out.append("\n")
    if not diff.strip():
        out.append("(no changes)\n", style="dim")
    return out


def _rel(iso: str) -> str:
    return iso[:19].replace("T", " ") if iso else "unknown"


def conversation_markdown(source, store) -> str:
    caps = source.caps()
    lines = [f"# {source.title()}", ""]
    meta = [f"**{source.author()}**", _rel(source.updated_at())]
    if caps.has_checks:
        checks = source.checks()
        ok = sum(1 for c in checks if str(c.get("state", "")).lower() == "success")
        if checks:
            meta.append(f"checks {ok}/{len(checks)}")
    if caps.can_submit and hasattr(source, "review_decision"):
        dec = source.review_decision()
        if dec:
            meta.append(dec)
    lines.append(" · ".join(meta))
    if caps.has_reviewers:
        revs = source.reviewers()
        if revs:
            lines.append(f"reviewers: {', '.join(revs)}")
    lines += ["", "---", ""]
    desc = source.description().strip()
    lines.append(desc if desc else "_(no description)_")

    lines += ["", "## Commits", ""]
    for c in source.commits():
        lines.append(f"- `{c.short}` {c.subject}")

    # local + imported threads
    threads = store.all_threads()
    if threads:
        lines += ["", "## Comments", ""]
        for root in threads:
            badge = {"resolved": "✓", "outdated": "⚠"}.get(root.status, "○")
            star = "★ " if root.origin == "claude" else ""
            lines.append(f"**{star}{root.author}** · `{root.file}:{root.line_start}` {badge}")
            lines.append("")
            lines.append("> " + root.body.replace("\n", "\n> "))
            for r in store.replies(root.id):
                who = "★ " if r.origin == "claude" else ""
                lines.append(f">")
                lines.append(f"> ↳ **{who}{r.author}**: " + r.body.replace("\n", " "))
            lines.append("")
    return "\n".join(lines)


def claude_markdown(session, store) -> str:
    if session is None:
        return ("# Claude review\n\n_No review yet._\n\n"
                "Press **a** to run a Claude review of this PR/branch.")
    v = session.verdict or "—"
    icon = {"approve": "✅", "request_changes": "🛑", "comment": "💬"}.get(v, "•")
    lines = [f"# ★ Claude review — {icon} {v}", ""]
    if session.state == "running":
        lines.append("_running…_")
    if session.state == "error":
        lines += [f"**Error:** {session.error}", ""]
    if session.summary:
        lines += [session.summary, ""]

    if session.replied:
        lines += ["## Replies to threads", ""]
        for cid in session.replied:
            root = store.get(cid)
            if root:
                lines.append(f"- `{root.file}:{root.line_start}` — {root.body[:80]}")
                for r in store.replies(cid):
                    if r.origin == "claude":
                        lines.append(f"    ↳ {r.body}")
        lines.append("")

    new_findings = [f for f in session.findings if not f.get("general")]
    if new_findings:
        lines += ["## New comments", ""]
        for f in new_findings:
            c = store.get(f.get("comment_id", ""))
            if c:
                lines.append(f"### `{c.file}:{c.line_start}`")
                lines.append(c.body)
                if c.kind == "suggestion" and c.suggestion_text:
                    lines += ["", "```suggestion", c.suggestion_text, "```"]
                lines.append("")

    general = [f for f in session.findings if f.get("general")]
    if general:
        lines += ["## Notes", ""]
        for f in general:
            lines.append(f"- {f.get('note', '')}")
        lines.append("")

    if session.commits:
        lines += ["## Commits by Claude", ""]
        for c in session.commits:
            lines.append(f"- `{(c.get('sha') or '')[:8]}` {c.get('subject', '')}")
        lines.append("")

    if session.log:
        lines += ["---", "<details>", "", "**Progress log**", ""]
        for entry in session.log[-40:]:
            lines.append(f"    {entry}")
        lines.append("</details>")
    return "\n".join(lines)
