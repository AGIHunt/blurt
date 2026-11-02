"""The app runner's screen (K5, no tmux: Windows). The app draws its agent's pty and writes the bottom lines to
$BLURT_HOME/run/screens/<job>.json (pty.rs ScreenWatch); the monitor reads them as it reads a tmux pane on the Mac:
a question the agent waits on, the trust hint, an error it shows, and the watchdog.

  uv run --with pytest pytest tests/test_app_screen.py -q
"""
from __future__ import annotations

import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from p2_env import p2  # noqa: E402,F401


def start(p2) -> str:
    proj = p2.project(p2.repo(), worktree=False)
    it = p2.item(proj["id"])
    out = p2.run("sessions.py", "dispatch", "--items", it["uid"], "--agent", "claude", "--runner", "app")
    return out["launch"][0]["job"]


def screen(p2, jid: str, *lines: str, idle: float = 0.0) -> None:
    d = p2.home / "run" / "screens"
    d.mkdir(parents=True, exist_ok=True)
    (d / f"{jid}.json").write_text(json.dumps({"job": jid, "activity": time.time() - idle, "lines": list(lines)}))


def test_the_trust_question_on_the_app_runner_screen_needs_you(p2):
    jid = start(p2)
    assert p2.status(jid) == "running"  # nothing on screen yet
    screen(p2, jid, "Welcome to Claude Code", "Do you trust the files in this folder?", "❯ 1. Yes, proceed",
           "  2. No, exit", "Enter to confirm · Esc to exit")
    assert p2.status(jid) == "waiting_input"
    a = p2.job(jid)["agent"]
    assert a["status_source"] == "tty" and a["waiting_hint"] == "trust"
    screen(p2, jid, "Welcome to Claude Code", "✻ Thinking…")  # answered: it prints again
    assert p2.status(jid) == "running" and "waiting_hint" not in p2.job(jid)["agent"]


def test_quitting_at_the_trust_question_on_the_app_runner_never_started(p2):
    """The answer was No (Claude's default on its trust question): the pty dies at the question. The job says it stopped
    there — the app titles it "stopped at its trust question" and offers Restart — and keeps what was on screen."""
    jid = start(p2)
    screen(p2, jid, "Do you trust the files in this folder?", "  1. Yes, proceed", "❯ 2. No, exit")
    assert p2.status(jid) == "waiting_input"
    ev = p2.run("sessions.py", "event", "--job", jid, "--event", "pane-dead", "--exit", "0")
    a = ev["job"]["agent"]
    assert a["stopped_at"] == "trust"
    assert a["last_output"][-1] == "❯ 2. No, exit"


def test_first_run_screens_wait_for_you(p2):
    jid = start(p2)
    screen(p2, jid, "Let's get started.", "Choose the text style that looks best with your terminal", "Dark mode")
    assert p2.status(jid) == "waiting_input"


def test_logged_out_on_the_app_runner_is_an_error(p2):
    jid = start(p2)
    screen(p2, jid, "Welcome to Claude Code", "Not logged in · Please run /login")
    assert p2.status(jid) == "error"
    j = p2.job(jid)
    assert j["error"]["code"] == "auth" and j["error"]["message"] == "Not logged in · Please run /login"


def test_a_still_screen_trips_the_watchdog(p2):
    p2.env["BLURT_SESSION_STALL"] = "1"
    jid = start(p2)
    time.sleep(1.2)
    screen(p2, jid, "Some notice nothing here knows", "Press any key", idle=5)
    assert p2.status(jid) == "waiting_input"
    a = p2.job(jid)["agent"]
    assert a["status_source"] == "watchdog" and a["last_output"][-1] == "Press any key"
