"""Modal screens: compose a comment, dispatch a Claude review, help."""

from __future__ import annotations

from textual import on
from textual.app import ComposeResult
from textual.binding import Binding
from textual.containers import Vertical
from textual.screen import ModalScreen
from textual.widgets import Button, Checkbox, Input, Label, Select, Static, TextArea


class ComposeModal(ModalScreen[dict | None]):
    """Write a comment or suggestion. Returns {body, suggestion} or None."""

    BINDINGS = [
        Binding("escape", "cancel", "cancel"),
        Binding("ctrl+s", "submit", "submit"),
    ]

    def __init__(self, title: str, seed: str = "", suggestion: bool = False):
        super().__init__()
        self._title = title
        self._seed = seed
        self._suggestion = suggestion

    def compose(self) -> ComposeResult:
        with Vertical(id="compose-box"):
            yield Label(self._title, classes="modal-title")
            if self._seed:
                yield Static(self._seed, classes="hint")
            initial = "```suggestion\n\n```" if self._suggestion else ""
            ta = TextArea(initial, id="compose-text", language="markdown")
            yield ta
            yield Label("ctrl+s submit · esc cancel", classes="hint")

    def on_mount(self) -> None:
        self.query_one("#compose-text", TextArea).focus()

    def action_cancel(self) -> None:
        self.dismiss(None)

    def action_submit(self) -> None:
        text = self.query_one("#compose-text", TextArea).text.strip()
        if not text:
            self.dismiss(None)
            return
        suggestion = None
        import re
        blocks = re.findall(r"```suggestion\s*\n(.*?)```", text, re.DOTALL)
        if blocks and blocks[-1].strip():
            suggestion = blocks[-1].rstrip()
        self.dismiss({"body": text, "suggestion": suggestion})


class ClaudeModal(ModalScreen[dict | None]):
    """Configure and launch a Claude review."""

    BINDINGS = [Binding("escape", "cancel", "cancel")]

    def __init__(self, instructions: dict[str, str]):
        super().__init__()
        self._instructions = instructions

    def compose(self) -> ComposeResult:
        with Vertical(id="claude-box"):
            yield Label("★ Claude review", classes="modal-title")
            opts = [("(none)", "")] + [(k, k) for k in self._instructions]
            yield Label("Saved instruction:")
            yield Select(opts, value="", id="claude-profile", allow_blank=False)
            yield Label("Review direction:")
            yield Input(placeholder="e.g. focus on error handling", id="claude-direction")
            yield Checkbox("Allow edits (Claude may edit + commit in a worktree)", id="claude-edits")
            yield Checkbox("Auto-resolve threads Claude judges done", id="claude-resolve")
            yield Button("Run review  (enter)", variant="primary", id="claude-run")
            yield Label("esc cancel", classes="hint")

    def on_mount(self) -> None:
        self.query_one("#claude-direction", Input).focus()

    def action_cancel(self) -> None:
        self.dismiss(None)

    @on(Input.Submitted, "#claude-direction")
    @on(Button.Pressed, "#claude-run")
    def _run(self) -> None:
        profile = self.query_one("#claude-profile", Select).value or ""
        base = self._instructions.get(profile, "") if profile else ""
        direction = self.query_one("#claude-direction", Input).value.strip()
        instruction = (base + "\n" + direction).strip()
        self.dismiss({
            "instruction": instruction,
            "allow_edits": self.query_one("#claude-edits", Checkbox).value,
            "auto_resolve": self.query_one("#claude-resolve", Checkbox).value,
        })


HELP_TEXT = """\
[b]prtui — key bindings[/b]

  [b]Navigation[/b]              [b]Review[/b]
  j / k     down / up        c   comment on line
  g / G     top / bottom     s   suggest change
  l / enter open / select    r   reply to thread
  h         fold / collapse  x   resolve thread
  Tab       next pane        a   run Claude review
  1 2 3     jump to tab      A   Claude sessions
  / (list)  filter           o   open @ commit
                             R   refresh

  [b]General[/b]
  ?  help      q  back / quit      esc  close
"""


class HelpModal(ModalScreen[None]):
    BINDINGS = [Binding("escape,q,question_mark", "close", "close")]

    def compose(self) -> ComposeResult:
        with Vertical(id="help-box"):
            yield Static(HELP_TEXT)

    def action_close(self) -> None:
        self.dismiss(None)
