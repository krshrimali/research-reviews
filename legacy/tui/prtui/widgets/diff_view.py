"""A cursorable diff widget: each row is a diff line; the cursor picks a line to
comment on. Built on a DataTable so j/k navigation and a line cursor come for free."""

from __future__ import annotations

from rich.text import Text
from textual.binding import Binding
from textual.widgets import DataTable


class DiffTable(DataTable):
    BINDINGS = [
        Binding("j", "cursor_down", "down", show=False),
        Binding("k", "cursor_up", "up", show=False),
        Binding("g", "scroll_top", "top", show=False),
        Binding("G", "scroll_bottom", "bottom", show=False),
    ]

    def __init__(self, **kwargs):
        super().__init__(cursor_type="row", zebra_stripes=False,
                         show_header=False, **kwargs)
        # row index -> {"new_ln": int|None, "side": "RIGHT"|"LEFT"|None}
        self.line_meta: list[dict] = []

    def on_mount(self) -> None:
        self.add_column("diff", width=None)

    def load(self, diff: str, comment_lines: dict[int, int] | None = None) -> None:
        comment_lines = comment_lines or {}
        self.clear()
        self.line_meta = []
        new_ln = 0
        if not diff.strip():
            self.add_row(Text("(no changes)", style="dim"))
            self.line_meta.append({"new_ln": None, "side": None})
            return
        for line in diff.splitlines():
            meta = {"new_ln": None, "side": None}
            gutter, style, marker = "    ", None, ""
            if line.startswith(("diff --git", "index ", "--- ", "+++ ")):
                style = "bold bright_black"
            elif line.startswith("@@"):
                style = "bold cyan"
                try:
                    seg = line.split("+", 1)[1]
                    new_ln = int(seg.split(",")[0].split(" ")[0]) - 1
                except (IndexError, ValueError):
                    pass
            elif line.startswith("+"):
                style, new_ln = "green", new_ln + 1
                gutter = f"{new_ln:>4}"
                meta = {"new_ln": new_ln, "side": "RIGHT"}
                if new_ln in comment_lines:
                    marker = f"  💬{comment_lines[new_ln]}"
            elif line.startswith("-"):
                style = "red"
                meta = {"new_ln": None, "side": "LEFT"}
            else:
                new_ln += 1
                gutter = f"{new_ln:>4}"
                meta = {"new_ln": new_ln, "side": "RIGHT"}
                if new_ln in comment_lines:
                    marker = f"  💬{comment_lines[new_ln]}"
            cell = Text(gutter + " ", style="bright_black")
            cell.append(line, style=style)
            if marker:
                cell.append(marker, style="bold yellow")
            self.add_row(cell)
            self.line_meta.append(meta)

    def current_target(self) -> dict | None:
        """The {new_ln, side} for the cursor row, or None."""
        if 0 <= self.cursor_row < len(self.line_meta):
            return self.line_meta[self.cursor_row]
        return None
