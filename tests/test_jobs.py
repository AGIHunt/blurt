"""jobs.py (contract K4): the owner writes the JSON, everyone else appends events, every reader folds them the same
way. Temp BLURT_HOME only.

  uv run --with pytest pytest tests/test_jobs.py -q
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

import pytest

SCRIPTS = Path(__file__).resolve().parents[1] / "skills" / "blurt" / "scripts"
sys.path.insert(0, str(SCRIPTS))
import jobs  # noqa: E402


@pytest.fixture()
def home(tmp_path, monkeypatch):
    monkeypatch.setenv("BLURT_HOME", str(tmp_path))
    monkeypatch.setenv("BLURT_TMUX_SOCKET", f"blurt-test-p2-jobs-{os.getpid()}")  # never the app's socket
    return tmp_path


def cli(*args, ok=True) -> dict:
    p = subprocess.run([sys.executable, str(SCRIPTS / "jobs.py"), *map(str, args)], capture_output=True, text=True,
                       env=os.environ.copy())
    out = json.loads(p.stdout.strip().splitlines()[-1])
    assert (p.returncode == 0) == ok, p.stderr
    return out


def test_ids_and_shape(home):
    j = jobs.create("process", project="p1", session="/s/20261022-101500", owner="app")
    assert re.fullmatch(r"j-\d{8}-\d{6}-[0-9a-hjkmnp-tv-z]{4}", j["id"])
    assert [s["id"] for s in j["steps"]] == ["prepare", "transcribe", "write", "frames"]  # no routing step: nothing moves items
    assert all(s["state"] == "pending" for s in j["steps"]) and j["state"] == "running" and j["events_offset"] == 0
    on_disk = json.loads((home / "jobs" / f"{j['id']}.json").read_text())
    assert on_disk == j and re.search(r"[+-]\d\d:\d\d$", j["created"])  # ISO 8601 with the offset
    for t, steps in jobs.STEPS.items():
        assert [s["id"] for s in jobs.create(t)["steps"]] == steps


def test_fold(home):
    j = jobs.create("agent", items=["u1"], agent={"id": "claude", "status": "running"})
    jid = j["id"]
    jobs.append(jid, {"source": "app", "event": "step", "step": {"id": "launch", "state": "running"}})
    jobs.append(jid, {"source": "app", "event": "step", "step": {"id": "launch", "state": "done"}})
    jobs.append(jid, {"source": "hook", "event": "Notification", "status": "waiting_input"})
    jobs.append(jid, {"source": "items", "event": "write", "items": ["u2", "u1"], "progress": 0.5})
    with open(home / "jobs" / f"{jid}.events.jsonl", "a") as f:
        f.write('{"t": "2026-10-22T10:00:00+08:00", "status": "exi')  # a line still being written
    eff = jobs.get(jid)
    launch = next(s for s in eff["steps"] if s["id"] == "launch")
    assert launch["state"] == "done" and launch["started"] and launch["ended"]
    assert eff["agent"]["status"] == "waiting_input" and eff["agent"]["status_source"] == "hook"
    assert eff["items"] == ["u1", "u2"] and eff["progress"] == 0.5 and eff["state"] == "running"
    assert json.loads((home / "jobs" / f"{jid}.json").read_text())["agent"]["status"] == "running"  # readers don't write
    # the owner merges: offset moves past complete lines only, and the result equals the fold
    merged = jobs.update(jid, lambda job: None)
    assert merged["agent"]["status"] == "waiting_input"
    raw = (home / "jobs" / f"{jid}.events.jsonl").read_bytes()
    assert merged["events_offset"] == raw.rfind(b"\n") + 1
    jobs.append(jid, {"source": "hook", "event": "SessionEnd", "status": "exited", "state": "done"})
    eff = jobs.get(jid)
    assert eff["state"] == "done" and eff["ended"]


def test_event_lines_stay_small(home):
    jid = jobs.create("agent")["id"]
    ev = jobs.append(jid, {"source": "hook", "event": "Notification", "detail": {"message": "x" * 10000}})
    line = (home / "jobs" / f"{jid}.events.jsonl").read_bytes().splitlines()[-1]
    assert len(line) < 4096 and len(ev["detail"]["message"]) == 200


def test_cli(home):
    out = cli("new", "--type", "voice", "--project", "inbox", "--title", "Voice note")
    jid = out["id"]
    assert Path(out["path"]).exists()
    cli("step", jid, "listen", "--state", "done")
    cli("step", jid, "transcribe", "--state", "running", "--progress", "0.3")
    cli("event", jid, "--json", '{"event": "x", "items": ["01ABC"]}')
    got = cli("get", jid)["job"]
    assert [(s["id"], s["state"]) for s in got["steps"]] == [("listen", "done"), ("transcribe", "running"), ("file", "pending")]
    assert got["items"] == ["01ABC"] and next(s for s in got["steps"] if s["id"] == "transcribe")["progress"] == 0.3
    cli("finish", jid, "--state", "failed", "--error-code", "model", "--message", "no model")
    got = cli("get", jid)["job"]
    # a reason reported by a non-owner is the job's reason (the app shows it), not lost in the event's detail
    assert got["state"] == "failed" and got["error"] == {"code": "model", "message": "no model", "hint_key": None}
    assert [j["id"] for j in cli("list")["jobs"]] == [jid] and cli("list", "--active")["jobs"] == []
    assert cli("list", "--type", "record")["jobs"] == []
    assert cli("get", "j-nope", ok=False)["code"] == "no_job"
    assert cli("step", jid, "x", "--state", "bogus", ok=False)["code"] == "bad_args"
    assert cli("get", "../etc", ok=False)["code"] == "bad_job"


def test_gc(home):
    old = time.time() - 20 * 86400
    keep_running = jobs.create("process")["id"]
    gone = jobs.create("record")["id"]
    live_agent = jobs.create("agent")["id"]
    for jid in (gone, live_agent):
        def end(j):
            jobs.finish(j, "done")
            j["ended"] = jobs.now_iso(old)
        jobs.update(jid, end)
        for suffix in (".log", ".diff", ".prompt.md"):
            (home / "jobs" / f"{jid}{suffix}").write_text("x")
    (home / "handoff").mkdir()
    (home / "handoff" / "H-0001.md").write_text("kept")
    orig = jobs.KEEP_LAST
    jobs.KEEP_LAST = 0
    try:
        assert jobs.gc(live_windows={live_agent}, referenced=set()) == [gone]  # its window is still open
        assert jobs.gc() == []  # no index.db to ask which jobs items point at: every agent job stays
        assert jobs.gc(referenced=set()) == [live_agent]  # asks sessions.py: no tmux server on this socket
    finally:
        jobs.KEEP_LAST = orig
    names = sorted(p.name for p in (home / "jobs").iterdir())
    assert not [n for n in names if n.startswith((gone, live_agent))] and f"{keep_running}.json" in names
    assert (home / "handoff" / "H-0001.md").exists()
    jobs.create("record")
    assert jobs.gc(live_windows=set()) == []  # within the newest 300


def test_gc_keeps_what_items_and_worktrees_still_need(home, tmp_path):
    old = time.time() - 20 * 86400
    wt = tmp_path / "wt"
    wt.mkdir()
    ids = {}
    def worktree(p):  # the shape sessions.py dispatch writes
        return {"path": str(p), "branch": "blurt/b", "base": "main", "base_sha": "0" * 40, "repo": str(tmp_path)}
    for name, agent in (("referenced", {}), ("worktree", {"worktree": worktree(wt), "finish": None}),
                        ("legacy", {"worktree": str(wt), "finish": None}),
                        ("merged", {"worktree": worktree(wt), "finish": {"action": "merge"}}),
                        ("wt_gone", {"worktree": worktree(tmp_path / "removed"), "finish": None}),
                        ("wt_none", {"worktree": None}), ("plain", {})):
        jid = jobs.create("agent")["id"]
        ids[name] = jid

        def end(j, agent=agent):
            jobs.finish(j, "done")
            j["ended"] = jobs.now_iso(old)
            j["agent"] = {**(j.get("agent") or {}), **agent}
        jobs.update(jid, end)
    orig = jobs.KEEP_LAST
    jobs.KEEP_LAST = 0
    try:
        removed = jobs.gc(live_windows=set(), referenced={ids["referenced"]})
    finally:
        jobs.KEEP_LAST = orig
    # an unfinished item's session and an unmerged worktree stay reachable; the rest goes
    assert sorted(removed) == sorted([ids["merged"], ids["wt_gone"], ids["wt_none"], ids["plain"]])
    for kept in ("referenced", "worktree", "legacy"):
        assert (home / "jobs" / f"{ids[kept]}.json").exists()


def test_gc_closes_old_dead_windows_instead_of_keeping_their_jobs_forever(home):
    """dogfood-2 #41: a final agent job's dead window (remain-on-exit, up to 50k lines of scrollback each) pinned the
    job in gc forever. Past 14 days the dead window is closed and the job goes; a running window still pins it."""
    old = time.time() - 20 * 86400
    dead, alive, young = (jobs.create("agent")["id"] for _ in range(3))
    for jid, when in ((dead, old), (alive, old), (young, time.time())):
        def end(j, when=when):
            jobs.finish(j, "done")
            j["ended"] = jobs.now_iso(when)
        jobs.update(jid, end)
    killed = []
    orig = jobs.KEEP_LAST
    jobs.KEEP_LAST = 0
    try:
        removed = jobs.gc(live_windows={alive}, referenced=set(), kill_window=killed.append,
                          dead_windows={dead: "@7", young: "@9"})
    finally:
        jobs.KEEP_LAST = orig
    assert removed == [dead] and killed == ["@7"]          # a young job keeps its dead window for reading
    assert (home / "jobs" / f"{alive}.json").exists() and (home / "jobs" / f"{young}.json").exists()


def test_referenced_jobs_reads_the_index(home, monkeypatch):
    import sqlite3
    import index
    assert jobs.referenced_jobs() is None  # no index.db yet: the caller keeps every agent job
    con = sqlite3.connect(":memory:")
    con.execute("CREATE TABLE items (uid TEXT, state TEXT, work_job TEXT)")
    con.executemany("INSERT INTO items VALUES (?, ?, ?)", [("a", "in_progress", "j-1"), ("b", "to_verify", "j-2"),
                                                           ("c", "done", "j-3"), ("d", "todo", None)])
    monkeypatch.setattr(index, "connect", lambda readonly=False: con)
    assert jobs.referenced_jobs() == {"j-1", "j-2"}
