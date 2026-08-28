"""Subprocess helpers — argv-style only (shell=False), never string-interpolated."""

from __future__ import annotations

import asyncio
import subprocess
from typing import Awaitable, Callable, Sequence


def run(argv: Sequence[str], cwd: str | None = None, stdin: str | None = None,
        timeout: float = 30.0) -> tuple[bool, str, str]:
    """Run a command synchronously. Returns (ok, stdout, stderr)."""
    if not argv:
        raise ValueError("run: empty argv")
    try:
        proc = subprocess.run(
            list(argv),
            cwd=cwd,
            input=stdin,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:  # pragma: no cover - env dep
        return False, "", str(exc)
    return proc.returncode == 0, proc.stdout, proc.stderr


def git(args: Sequence[str], cwd: str | None = None) -> tuple[bool, str, str]:
    """Run a git subcommand argv-style."""
    return run(["git", *args], cwd=cwd)


async def spawn_stream(
    argv: Sequence[str],
    on_line: Callable[[str], None],
    cwd: str | None = None,
    stdin: str | None = None,
) -> tuple[int, str]:
    """Spawn a process, stream stdout line-by-line to `on_line`. Returns (code, stderr).

    Cancellation of the awaiting task terminates the child.
    """
    proc = await asyncio.create_subprocess_exec(
        *argv,
        cwd=cwd,
        stdin=asyncio.subprocess.PIPE if stdin is not None else None,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    if stdin is not None and proc.stdin is not None:
        proc.stdin.write(stdin.encode())
        proc.stdin.close()

    assert proc.stdout is not None and proc.stderr is not None
    # Drain stderr concurrently — otherwise a child that fills the stderr pipe
    # (e.g. `claude -p --verbose`) blocks on write, never closes stdout, and we
    # deadlock waiting on stdout that never arrives.
    stderr_task = asyncio.create_task(proc.stderr.read())
    try:
        async for raw in proc.stdout:
            on_line(raw.decode(errors="replace").rstrip("\n"))
        err = await stderr_task
        await proc.wait()
    except asyncio.CancelledError:
        stderr_task.cancel()
        try:
            proc.terminate()
        except ProcessLookupError:
            pass
        try:
            await proc.wait()
        except Exception:  # noqa: BLE001 - best-effort reap during teardown
            pass
        raise
    return proc.returncode or 0, err.decode(errors="replace")
