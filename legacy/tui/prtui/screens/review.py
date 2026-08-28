"""The main review screen: files/commits sidebar + Conversation/Files/Claude tabs."""

from __future__ import annotations

from textual import on, work
from textual.app import ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal, Vertical
from textual.screen import Screen
from textual.widgets import Footer, Header, Markdown, Static, TabbedContent, TabPane

from ..data import claude, git
from ..widgets.diff_view import DiffTable
from ..widgets.render import claude_markdown, conversation_markdown
from ..widgets.vim import VimDataTable, VimScroll, VimTree
from .modals import ClaudeModal, ComposeModal, HelpModal


class ReviewScreen(Screen):
    BINDINGS = [
        Binding("tab", "next_tab", "next pane"),
        Binding("1", "show_tab('tab-conv')", "conversation"),
        Binding("2", "show_tab('tab-diff')", "files"),
        Binding("3", "show_tab('tab-claude')", "claude"),
        Binding("c", "comment", "comment"),
        Binding("s", "suggest", "suggest"),
        Binding("r", "reply", "reply"),
        Binding("x", "resolve", "resolve"),
        Binding("a", "claude_review", "Claude review"),
        Binding("A", "show_tab('tab-claude')", "Claude output"),
        Binding("o", "open_commit", "open @ commit"),
        Binding("R", "refresh", "refresh"),
        Binding("question_mark", "help", "help"),
        Binding("q", "back", "back"),
    ]

    def __init__(self, source, store, config):
        super().__init__()
        self.source = source
        self.store = store
        self.config = config
        self.current_file: str | None = None

    # --- layout --------------------------------------------------------------
    def compose(self) -> ComposeResult:
        yield Header(show_clock=False)
        with Horizontal(id="review-body"):
            with Vertical(id="sidebar"):
                yield Static("Files changed", classes="section-title")
                yield VimTree("changed", id="file-tree")
                yield Static("Commits", classes="section-title")
                yield VimDataTable(id="commit-list")
            with TabbedContent(id="main-tabs", initial="tab-conv"):
                with TabPane("Conversation", id="tab-conv"):
                    with VimScroll():
                        yield Markdown(id="conv-md")
                with TabPane("Files", id="tab-diff"):
                    yield DiffTable(id="diff-table")
                with TabPane("Claude", id="tab-claude"):
                    with VimScroll():
                        yield Markdown(id="claude-md")
        yield Footer()

    def on_mount(self) -> None:
        self.title = "prtui"
        self.sub_title = self.source.title()
        self._populate_sidebar()
        self._refresh_conversation()
        self._refresh_claude()
        files = self.source.files()
        if files:
            self.current_file = files[0].path
            self._load_diff()

    # --- population ----------------------------------------------------------
    def _populate_sidebar(self) -> None:
        tree = self.query_one("#file-tree", VimTree)
        tree.root.expand()
        tree.show_root = False
        for f in self.source.files():
            counts = []
            if f.additions:
                counts.append(f"+{f.additions}")
            if f.deletions:
                counts.append(f"-{f.deletions}")
            label = f.path
            if f.status == "renamed" and f.old_path:
                label = f"{f.old_path} → {f.path}"
            suffix = ("  " + " ".join(counts)) if counts else ""
            tree.root.add_leaf(label + suffix, data=f.path)

        table = self.query_one("#commit-list", VimDataTable)
        table.cursor_type = "row"
        table.add_columns("sha", "subject")
        for c in self.source.commits():
            table.add_row(c.short, c.subject, key=c.sha)

    def _comment_counts(self, file: str) -> dict[int, int]:
        counts: dict[int, int] = {}
        for root in self.store.threads_for_file(file):
            if root.side == "RIGHT":
                counts[root.line_start] = counts.get(root.line_start, 0) + 1 + len(self.store.replies(root.id))
        return counts

    def _load_diff(self) -> None:
        if not self.current_file:
            return
        diff = git.file_diff(self.source.base_sha, self.source.head_sha,
                             self.current_file, self.source.repo_root)
        table = self.query_one("#diff-table", DiffTable)
        table.load(diff, self._comment_counts(self.current_file))

    def _refresh_conversation(self) -> None:
        self.query_one("#conv-md", Markdown).update(conversation_markdown(self.source, self.store))

    def _latest_session(self):
        if not self.store.sessions:
            return None
        return max(self.store.sessions.values(), key=lambda s: s.started_at)

    def _refresh_claude(self) -> None:
        self.query_one("#claude-md", Markdown).update(
            claude_markdown(self._latest_session(), self.store))

    def _refresh_all(self) -> None:
        self._load_diff()
        self._refresh_conversation()
        self._refresh_claude()

    # --- events --------------------------------------------------------------
    @on(VimTree.NodeSelected, "#file-tree")
    def _file_selected(self, event: VimTree.NodeSelected) -> None:
        if event.node.data:
            self.current_file = event.node.data
            self._load_diff()
            self.action_show_tab("tab-diff")
            self.query_one("#diff-table", DiffTable).focus()

    @on(VimDataTable.RowSelected, "#commit-list")
    def _commit_selected(self, event: VimDataTable.RowSelected) -> None:
        sha = event.row_key.value
        if sha:
            self.app.push_screen(_CommitDiffScreen(self.source, sha))

    # --- tab helpers ---------------------------------------------------------
    def action_show_tab(self, tab_id: str) -> None:
        self.query_one("#main-tabs", TabbedContent).active = tab_id
        if tab_id == "tab-diff":
            self.query_one("#diff-table", DiffTable).focus()

    def action_next_tab(self) -> None:
        tabs = ["tab-conv", "tab-diff", "tab-claude"]
        tc = self.query_one("#main-tabs", TabbedContent)
        idx = tabs.index(tc.active) if tc.active in tabs else 0
        self.action_show_tab(tabs[(idx + 1) % len(tabs)])

    # --- comment actions -----------------------------------------------------
    def _diff_target(self) -> dict | None:
        target = self.query_one("#diff-table", DiffTable).current_target()
        if not target or not self.current_file:
            self.notify("Open a file's diff and put the cursor on a line first.",
                        severity="warning")
            return None
        return target

    def _thread_at(self, line: int, side: str):
        for root in self.store.threads_for_file(self.current_file or ""):
            if root.side == side and root.line_start == line:
                return root
        return None

    def action_comment(self, suggestion: bool = False) -> None:
        target = self._diff_target()
        if not target or target.get("new_ln") is None:
            if target:
                self.notify("Comment on an added/context line (RIGHT side).", severity="warning")
            return
        line = target["new_ln"]
        title = f"{'Suggestion' if suggestion else 'Comment'} — {self.current_file}:{line}"

        def done(result: dict | None) -> None:
            if result:
                self.store.add(self.current_file, "RIGHT", line, result["body"],
                               kind="suggestion" if result.get("suggestion") else "normal",
                               suggestion_text=result.get("suggestion"))
                self._refresh_all()
                self.notify("comment added")

        self.app.push_screen(ComposeModal(title, suggestion=suggestion), done)

    def action_suggest(self) -> None:
        self.action_comment(suggestion=True)

    def action_reply(self) -> None:
        target = self._diff_target()
        if not target:
            return
        root = self._thread_at(target.get("new_ln"), "RIGHT")
        if not root:
            self.notify("No thread on this line.", severity="warning")
            return

        def done(result: dict | None) -> None:
            if result:
                self.store.reply(root.id, result["body"], suggestion_text=result.get("suggestion"))
                self._refresh_all()

        self.app.push_screen(ComposeModal(f"Reply — {root.file}:{root.line_start}"), done)

    def action_resolve(self) -> None:
        target = self._diff_target()
        if not target:
            return
        root = self._thread_at(target.get("new_ln"), "RIGHT")
        if not root:
            self.notify("No thread on this line.", severity="warning")
            return
        self.store.set_resolved(root.id, root.status != "resolved")
        self._refresh_all()
        self.notify("resolved" if root.status != "resolved" else "unresolved")

    def action_open_commit(self) -> None:
        self.notify("Open @ commit: worktree checkout (see docs) — TODO in TUI.",
                    severity="information")

    # --- claude --------------------------------------------------------------
    def action_claude_review(self) -> None:
        def go(opts: dict | None) -> None:
            if opts is not None:
                self._run_claude(opts)

        self.app.push_screen(ClaudeModal(self.config.get("saved_instructions", {})), go)

    @work(exclusive=True, group="claude")
    async def _run_claude(self, opts: dict) -> None:
        self.notify("★ Claude review started (async)…")
        self.action_show_tab("tab-claude")

        def progress(_text: str) -> None:
            self._refresh_claude()

        session = await claude.run(
            self.store, self.source, opts["instruction"],
            claude_bin=self.config.get("claude_bin", "claude"),
            allow_edits=opts["allow_edits"], auto_resolve=opts["auto_resolve"],
            on_progress=progress,
        )
        self._refresh_all()
        sev = "error" if session.state == "error" else (
            "warning" if session.verdict == "request_changes" else "information")
        msg = session.error if session.state == "error" else f"Claude review done: {session.verdict}"
        self.notify(msg, severity=sev, title="prtui")

    # --- misc ----------------------------------------------------------------
    def action_refresh(self) -> None:
        self._refresh_all()
        self.notify("refreshed")

    def action_help(self) -> None:
        self.app.push_screen(HelpModal())

    def action_back(self) -> None:
        self.app.pop_screen()


class _CommitDiffScreen(Screen):
    """A single commit's diff in its own screen (q to go back)."""

    BINDINGS = [Binding("q,escape", "app.pop_screen", "back")]

    def __init__(self, source, sha: str):
        super().__init__()
        self.source = source
        self.sha = sha

    def compose(self) -> ComposeResult:
        yield Header(show_clock=False)
        yield DiffTable(id="commit-diff")
        yield Footer()

    def on_mount(self) -> None:
        self.sub_title = f"commit {self.sha[:8]}"
        from ..data import proc as _proc
        ok, out, _ = _proc.git(["show", self.sha], self.source.repo_root)
        self.query_one("#commit-diff", DiffTable).load(out if ok else "(unavailable)")
