"""A user's click that fails must say so: no `Task { try? await … }` in the Mac app's action handlers (the error was
dropped and the button looked dead). Test hooks (SnapApp's commands) are exempt."""
from __future__ import annotations

import re
from pathlib import Path

APP = Path(__file__).resolve().parents[1] / "skills/blurt/recorder/macos/Sources/BlurtApp"
SWALLOW = re.compile(r"Task\s*\{\s*(?:@MainActor\s+in\s+)?try\?\s+await")
EXEMPT = {"App/SnapApp.swift"}  # test commands, not something a user clicks


def test_no_task_that_drops_its_error():
    hits = [f"{p.relative_to(APP)}:{n}" for p in sorted(APP.rglob("*.swift")) if str(p.relative_to(APP)) not in EXEMPT
            for n, line in enumerate(p.read_text(encoding="utf-8").splitlines(), 1) if SWALLOW.search(line)]
    assert hits == [], "say the error (a toast, the pane's alert) instead of `Task { try? await … }`: " + ", ".join(hits)
