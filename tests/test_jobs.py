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
    j = jobs.create("process", items=["u1"])
    jid = j["id"]
    jobs.append(jid, {"source": "app", "event": "step", "step": {"id": "prepare", "state": "running"}})
    jobs.append(jid, {"source": "app", "event": "step", "step": {"id": "prepare", "state": "done"}})
    jobs.append(jid, {"source": "items", "event": "write", "items": ["u2", "u1"], "progress": 0.5})
    with open(home / "jobs" / f"{jid}.events.jsonl", "a") as f:
        f.write('{"t": "2026-10-22T10:00:00+08:00", "progress": 0.')  # a line still being written
    eff = jobs.get(jid)
    prepare = next(s for s in eff["steps"] if s["id"] == "prepare")
    assert prepare["state"] == "done" and prepare["started"] and prepare["ended"]
    assert eff["items"] == ["u1", "u2"] and eff["progress"] == 0.5 and eff["state"] == "running"
    assert json.loads((home / "jobs" / f"{jid}.json").read_text())["progress"] is None  # readers don't write
    # the owner merges: offset moves past complete lines only, and the result equals the fold
    merged = jobs.update(jid, lambda job: None)
    assert merged["progress"] == 0.5
    raw = (home / "jobs" / f"{jid}.events.jsonl").read_bytes()
    assert merged["events_offset"] == raw.rfind(b"\n") + 1
    jobs.append(jid, {"source": "app", "event": "finish", "state": "done"})
    eff = jobs.get(jid)
    assert eff["state"] == "done" and eff["ended"]


def test_event_lines_stay_small(home):
    jid = jobs.create("process")["id"]
    ev = jobs.append(jid, {"source": "app", "event": "note", "detail": {"message": "x" * 10000}})
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


def legacy_agent_job(home, ended: float, state: str = "done") -> str:
    """A job of the removed agent sessions, as v1.0 wrote it."""
    jid = jobs.new_id(ended)
    j = {"schema": 1, "id": jid, "type": "agent", "state": state, "owner": "app", "project": None, "session": None,
         "parent": None, "title": None, "items": ["u1"], "captures": [],
         "steps": [{"id": s, "state": "done", "progress": None, "started": None, "ended": None}
                   for s in ("launch", "work", "finish")],
         "progress": None, "created": jobs.now_iso(ended), "started": jobs.now_iso(ended),
         "ended": jobs.now_iso(ended) if state in jobs.FINAL else None, "updated": jobs.now_iso(ended),
         "events_offset": 0, "error": None,
         "agent": {"id": "claude", "runner": "tmux", "status": "running", "worktree": {"path": "/nowhere"}}}
    (home / "jobs").mkdir(exist_ok=True)
    (home / "jobs" / f"{jid}.json").write_text(json.dumps(j))
    for suffix in (".claude-settings.json", ".diff", ".prompt.md", ".log"):
        (home / "jobs" / f"{jid}{suffix}").write_text("x")
    return jid


def test_gc(home):
    old = time.time() - 20 * 86400
    keep_running = jobs.create("process")["id"]
    gone = jobs.create("record")["id"]

    def end(j):
        jobs.finish(j, "done")
        j["ended"] = jobs.now_iso(old)
    jobs.update(gone, end)
    for suffix in (".log", ".prompt.md"):
        (home / "jobs" / f"{gone}{suffix}").write_text("x")
    young = jobs.create("record")["id"]
    jobs.update(young, lambda j: jobs.finish(j, "done"))
    (home / "handoff").mkdir()
    (home / "handoff" / "H-0001.md").write_text("kept")
    orig = jobs.KEEP_LAST
    jobs.KEEP_LAST = 0
    try:
        assert jobs.gc() == [gone]
    finally:
        jobs.KEEP_LAST = orig
    names = sorted(p.name for p in (home / "jobs").iterdir())
    assert not [n for n in names if n.startswith(gone)] and f"{keep_running}.json" in names and f"{young}.json" in names
    assert (home / "handoff" / "H-0001.md").exists()
    jobs.create("record")
    assert jobs.gc() == []  # within the newest 300


def test_old_agent_session_jobs(home):
    """The in-app agent sessions are gone; their jobs may still be on disk. Nothing crashes on them: list and watch
    skip them, get still reads one, gc removes them (any state, any age) with their files, and nothing makes one."""
    done = legacy_agent_job(home, time.time() - 3600)
    running = legacy_agent_job(home, time.time() - 60, state="running")  # its session died with the old app
    mine = jobs.create("process")["id"]
    assert [j["id"] for j in jobs.list_jobs()] == [mine]
    assert [j["id"] for j in cli("list")["jobs"]] == [mine] and cli("list", "--active")["jobs"] == [cli("get", mine)["job"]]
    assert cli("get", done)["job"]["type"] == "agent"
    assert cli("list", "--type", "agent", ok=False)["code"] == "bad_args"
    assert cli("new", "--type", "agent", ok=False)["code"] == "bad_args"
    with pytest.raises(jobs.JobError):
        jobs.create("agent")
    assert sorted(cli("gc")["removed"]) == sorted([done, running])
    assert sorted(p.name for p in (home / "jobs").iterdir() if not p.name.startswith(".")) == [f"{mine}.json"]


def test_watch_skips_old_agent_session_jobs(home):
    legacy_agent_job(home, time.time() - 60)
    mine = jobs.create("voice")["id"]
    p = subprocess.Popen([sys.executable, str(SCRIPTS / "jobs.py"), "watch", "--interval", "0.1"], stdout=subprocess.PIPE,
                         text=True, env=os.environ.copy())
    try:
        first = json.loads(p.stdout.readline())
    finally:
        p.kill()
        p.wait()
    assert first["id"] == mine
