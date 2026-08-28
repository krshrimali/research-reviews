"""Fuzzy PR / local-branch picker (the entry screen)."""

from __future__ import annotations

from textual import on, work
from textual.app import ComposeResult
from textual.binding import Binding
from textual.screen import Screen
from textual.widgets import Footer, Header, Input

from ..data import gh, git, source
from ..data.store import Store
from ..widgets.vim import VimDataTable


def _fuzzy(query: str, text: str) -> bool:
    """Case-insensitive subsequence match."""
    query, text = query.lower(), text.lower()
    it = iter(text)
    return all(ch in it for ch in query)


class SourceListScreen(Screen):
    BINDINGS = [
        Binding("q", "app.quit", "quit"),
        Binding("slash", "focus_filter", "filter"),
        Binding("escape", "unfocus_filter", "list", show=False),
        Binding("enter", "open", "open"),
    ]

    def __init__(self, cwd: str, config: dict):
        super().__init__()
        self.cwd = cwd
        self.config = config
        self.items: list[dict] = []

    def compose(self) -> ComposeResult:
        yield Header(show_clock=False)
        yield Input(placeholder="filter PRs / branches (fuzzy)…", id="list-filter")
        yield VimDataTable(id="source-table")
        yield Footer()

    def on_mount(self) -> None:
        self.title = "prtui"
        self.sub_title = "pick a PR or branch"
        table = self.query_one("#source-table", VimDataTable)
        table.cursor_type = "row"
        table.add_columns("kind", "id", "title", "meta")
        self.items = self._gather()
        self._show_rows(self.items)
        table.focus()

    def _gather(self) -> list[dict]:
        items: list[dict] = []
        if gh.available():
            for pr in gh.list_prs(cwd=self.cwd):
                author = (pr.get("author") or {}).get("login", "?")
                items.append({
                    "kind": "pr", "arg": pr["number"],
                    "id": f"#{pr['number']}", "title": pr.get("title", ""),
                    "meta": f"{author} · {pr.get('state', '')} · {pr.get('reviewDecision') or ''}".strip(" ·"),
                    "search": f"#{pr['number']} {pr.get('title','')} {author}",
                })
        cur = git.current_branch(self.cwd)
        from ..data import proc as _proc
        ok, out, _ = _proc.git(["for-each-ref", "--format=%(refname:short)", "refs/heads/"], self.cwd)
        if ok:
            for name in out.split():
                items.append({
                    "kind": "branch", "arg": name, "id": "⎇",
                    "title": name + (" (current)" if name == cur else ""),
                    "meta": "local branch", "search": f"branch {name}",
                })
        return items

    def _show_rows(self, items: list[dict]) -> None:
        table = self.query_one("#source-table", VimDataTable)
        table.clear()
        for i, it in enumerate(items):
            table.add_row(it["kind"], it["id"], it["title"], it["meta"], key=str(i))
        self._visible = items

    @on(Input.Changed, "#list-filter")
    def _filter(self, event: Input.Changed) -> None:
        q = event.value.strip()
        filtered = [it for it in self.items if not q or _fuzzy(q, it["search"])]
        self._show_rows(filtered)

    @on(Input.Submitted, "#list-filter")
    def _filter_submit(self) -> None:
        self.query_one("#source-table", VimDataTable).focus()

    def action_focus_filter(self) -> None:
        self.query_one("#list-filter", Input).focus()

    def action_unfocus_filter(self) -> None:
        self.query_one("#source-table", VimDataTable).focus()

    @on(VimDataTable.RowSelected, "#source-table")
    def _row_selected(self, event: VimDataTable.RowSelected) -> None:
        idx = int(event.row_key.value)
        if 0 <= idx < len(self._visible):
            self._open_item(self._visible[idx])

    def action_open(self) -> None:
        table = self.query_one("#source-table", VimDataTable)
        if table.row_count and 0 <= table.cursor_row < len(self._visible):
            self._open_item(self._visible[table.cursor_row])

    def _open_item(self, item: dict) -> None:
        self._open_worker(item)

    @work(exclusive=True, thread=True)
    def _open_worker(self, item: dict) -> None:
        try:
            src = source.create(item["arg"], self.cwd, base=self.config.get("base"))
        except Exception as exc:  # noqa: BLE001 - surface any data error to the user
            self.app.call_from_thread(self.notify, f"cannot open: {exc}", severity="error")
            return
        store = Store(src.key(), src.repo_root)
        if src.caps().has_threads:
            try:
                from ..data.github_sync import import_threads
                import_threads(src, store)
            except Exception:  # noqa: BLE001
                pass
        from .review import ReviewScreen
        self.app.call_from_thread(self.app.push_screen, ReviewScreen(src, store, self.config))
