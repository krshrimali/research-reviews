"""prtui — a GitHub-style PR/branch review TUI with async Claude reviews."""

from __future__ import annotations

import os

from textual.app import App

from .data import source as source_mod
from .data.store import Store
from .screens.source_list import SourceListScreen

DEFAULT_CONFIG = {
    "claude_bin": "claude",
    "base": "auto",
    "saved_instructions": {
        "Critical review": (
            "Be a rigorous, skeptical reviewer. Prioritize correctness, edge cases, "
            "and failure modes over style. Push back on unclear code."
        ),
        "InfoSec review": (
            "Review strictly for security: injection, authz/authn, secrets, unsafe "
            "deserialization, path traversal, SSRF, crypto misuse, unsafe subprocess use."
        ),
    },
}


class ReviewApp(App):
    CSS_PATH = "styles.tcss"
    TITLE = "prtui"

    def __init__(self, cwd: str | None = None, initial: str | int | None = None,
                 config: dict | None = None):
        super().__init__()
        self.cwd = cwd or os.getcwd()
        self.initial = initial
        self.config = {**DEFAULT_CONFIG, **(config or {})}

    def on_mount(self) -> None:
        if self.initial is not None:
            # Open a specific source directly.
            try:
                src = source_mod.create(self.initial, self.cwd, base=self.config.get("base"))
            except Exception as exc:  # noqa: BLE001
                self.notify(f"cannot open: {exc}", severity="error")
                self.push_screen(SourceListScreen(self.cwd, self.config))
                return
            store = Store(src.key(), src.repo_root)
            if src.caps().has_threads:
                try:
                    from .data.github_sync import import_threads
                    import_threads(src, store)
                except Exception:  # noqa: BLE001
                    pass
            from .screens.review import ReviewScreen
            self.push_screen(ReviewScreen(src, store, self.config))
        else:
            self.push_screen(SourceListScreen(self.cwd, self.config))
