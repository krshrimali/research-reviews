"""Widget subclasses with Neovim-style keybindings (j/k/g/G/h/l)."""

from __future__ import annotations

from textual.binding import Binding
from textual.containers import VerticalScroll
from textual.widgets import DataTable, Tree


class VimTree(Tree):
    BINDINGS = [
        Binding("j", "cursor_down", "down", show=False),
        Binding("k", "cursor_up", "up", show=False),
        Binding("l", "select_cursor", "open", show=False),
        Binding("h", "toggle_node", "fold", show=False),
        Binding("g", "scroll_home", "top", show=False),
        Binding("G", "scroll_end", "bottom", show=False),
    ]


class VimDataTable(DataTable):
    BINDINGS = [
        Binding("j", "cursor_down", "down", show=False),
        Binding("k", "cursor_up", "up", show=False),
        Binding("g", "scroll_top", "top", show=False),
        Binding("G", "scroll_bottom", "bottom", show=False),
        Binding("l", "select_cursor", "open", show=False),
    ]


class VimScroll(VerticalScroll, can_focus=True):
    BINDINGS = [
        Binding("j", "scroll_down", "down", show=False),
        Binding("k", "scroll_up", "up", show=False),
        Binding("g", "scroll_home", "top", show=False),
        Binding("G", "scroll_end", "bottom", show=False),
        Binding("ctrl+d", "page_down", "page down", show=False),
        Binding("ctrl+u", "page_up", "page up", show=False),
    ]
