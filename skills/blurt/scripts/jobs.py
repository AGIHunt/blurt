# /// script
# requires-python = ">=3.10"
# ///
"""Everything that is happening — a recording, a screenshot batch, voice input, processing, routing, an agent
session — is a job (contract K4). One JSON file per job, written only by its owner; everyone else appends events.

  jobs.py new --type T [--project P] [--session S] [--parent J] [--title T] [--owner O]   → {"ok","id","path"}
  jobs.py step J STEP --state pending|running|done|failed|skipped [--progress X]
  jobs.py event J --json '{"event": "…", "status"?, "state"?, "step"?, "items"?, "progress"?, "detail"?}'
  jobs.py finish J --state done|failed|cancelled [--error-code C --message M [--hint-key K]]
  jobs.py get J                                     → {"ok","job": <effective state>}
  jobs.py list [--active] [--type T] [--project P] [--limit 50]   → {"ok","jobs":[…]} (newest first)
  jobs.py watch [--interval 0.5]                    one line of effective state per changed job, until killed
  jobs.py gc                                        → {"ok","removed":[ids]} (never an agent job an unfinished
                                                    item points at, or whose worktree waits to be finished)

Files, in $BLURT_HOME/jobs/: <id>.json (the job; owner only, atomic replace, under <id>.lock when several owner
processes may write it), <id>.events.jsonl (everyone else: one O_APPEND line each, < 4 KB), <id>.log (raw output),
and a session's <id>.claude-settings.json / <id>.diff / <id>.prompt.md.

Effective state = the JSON plus every event after "events_offset", in order: a step replaces the step with its id,
"status" sets agent.status / status_at / status_source, "state" and "progress" replace, "items" are unioned. The
Swift (JobStore) and Rust readers apply the same rule, so a job is current even while its owner isn't running.

`step` / `event` / `finish` from this CLI are appends (any process may call them); the owner's own processes use
the library (create / update / absorb), which writes the JSON.
"""
from __future__ import annotations

import argparse
import contextlib
import json
import os
import secrets
import sys
import time
from datetime import datetime
from pathlib import Path

TYPES = ("record", "snap", "voice", "process", "route", "agent")
STATES = ("queued", "running", "done", "failed", "cancelled")
STEP_STATES = ("pending", "running", "done", "failed", "skipped")
STEPS = {"record": ["capture", "finalize"], "snap": ["capture"], "voice": ["listen", "transcribe", "file"],
         "process": ["prepare", "transcribe", "write", "frames", "route"], "route": ["route"],
         "agent": ["launch", "work", "finish"]}
ERROR_CODES = ("auth", "quota", "network", "model", "skill", "tmux", "git", "conflict", "io", "unknown")
FINAL = ("done", "failed", "cancelled")
ATTACHED = (".json", ".events.jsonl", ".log", ".lock", ".claude-settings.json", ".diff", ".prompt.md")
MAX_LINE = 4000
KEEP_DAYS, KEEP_LAST = 14, 300
_B32 = "0123456789abcdefghjkmnpqrstvwxyz"


class JobError(Exception):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code


def home() -> Path:
    return Path(os.environ.get("BLURT_HOME") or Path.home() / ".blurt")


def jobs_dir() -> Path:
    d = home() / "jobs"
    d.mkdir(parents=True, exist_ok=True)
    return d


def now_iso(t: float | None = None) -> str:
    return datetime.fromtimestamp(time.time() if t is None else t).astimezone().isoformat(timespec="seconds")


def parse_iso(s: str | None) -> float | None:
    try:
        return datetime.fromisoformat(s).timestamp() if s else None
    except (TypeError, ValueError):
        return None


def new_id(t: float | None = None) -> str:
    t = time.time() if t is None else t
    return f"j-{time.strftime('%Y%m%d-%H%M%S', time.localtime(t))}-" + "".join(secrets.choice(_B32) for _ in range(4))


def path(job_id: str, suffix: str = ".json") -> Path:
    if not job_id or "/" in job_id or "\\" in job_id or job_id.startswith("."):
        raise JobError("bad_job", f"bad job id {job_id!r}")
    return jobs_dir() / f"{job_id}{suffix}"


def _write_json(p: Path, data: dict) -> None:
    tmp = p.with_name(f".{p.name}.{os.getpid()}.tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    for attempt in range(20):  # Windows: replace fails while a reader has the file open
        try:
            os.replace(tmp, p)
            return
        except PermissionError:
            if attempt == 19:
                raise
            time.sleep(0.05)


def read(job_id: str) -> dict:
    try:
        return json.loads(path(job_id).read_text(encoding="utf-8"))
    except FileNotFoundError:
        raise JobError("no_job", f"no job {job_id}") from None
    except ValueError as e:
        raise JobError("io", f"{path(job_id)}: {e}") from None


@contextlib.contextmanager
def file_lock(p: Path, timeout: float = 10.0):
    """An exclusive lock on a file, shared across processes (flock / msvcrt)."""
    p.parent.mkdir(parents=True, exist_ok=True)
    fh = open(p, "a+b")
    try:
        deadline = time.monotonic() + timeout
        while True:
            try:
                if os.name == "nt":
                    import msvcrt
                    fh.seek(0)
                    msvcrt.locking(fh.fileno(), msvcrt.LK_NBLCK, 1)
                else:
                    import fcntl
                    fcntl.flock(fh.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except OSError:
                if time.monotonic() > deadline:
                    raise JobError("locked", f"{p} stayed locked for {timeout:.0f} s") from None
                time.sleep(0.02)
        yield
    finally:
        fh.close()  # closing releases flock / msvcrt locks


def lock(job_id: str, timeout: float = 10.0):
    """The owner lock: sessions.py's subcommands (dispatch, monitor, finish, stop…) all write the same job."""
    return file_lock(path(job_id, ".lock"), timeout)


def create(type: str, *, project: str | None = None, session: str | None = None, parent: str | None = None,
           title: str | None = None, owner: str = "app", items: list[str] | None = None, captures: list[int] | None = None,
           state: str = "running", agent: dict | None = None, job_id: str | None = None) -> dict:
    if type not in TYPES:
        raise JobError("bad_type", f"type must be one of {', '.join(TYPES)}")
    t = time.time()
    job_id = job_id or new_id(t)
    ts = now_iso(t)
    job = {"schema": 1, "id": job_id, "type": type, "state": state, "owner": owner, "project": project,
           "session": str(session) if session else None, "parent": parent, "title": title,
           "items": list(items or []), "captures": list(captures or []),
           "steps": [{"id": s, "state": "pending", "progress": None, "started": None, "ended": None} for s in STEPS[type]],
           "progress": None, "created": ts, "started": ts if state == "running" else None, "ended": None, "updated": ts,
           "events_offset": 0, "error": None}
    if type == "agent":
        job["agent"] = agent or {}
    p = path(job_id)
    if p.exists():
        raise JobError("exists", f"job {job_id} exists")
    _write_json(p, job)
    return job


def _apply_step(job: dict, step: dict, at: str) -> None:
    sid = step.get("id")
    if not sid:
        return
    steps = job.setdefault("steps", [])
    cur = next((s for s in steps if s.get("id") == sid), None)
    if cur is None:
        cur = {"id": sid, "state": "pending", "progress": None, "started": None, "ended": None}
        steps.append(cur)
    st = step.get("state", cur.get("state"))
    if st == "running" and not cur.get("started"):
        cur["started"] = at
    if st in ("done", "failed", "skipped") and not cur.get("ended"):
        cur["ended"] = at
    cur["state"] = st
    if "progress" in step:
        cur["progress"] = step["progress"]


def apply_event(job: dict, ev: dict) -> None:
    """One event onto a job (the K4 fold rule)."""
    at = ev.get("t") or now_iso()
    if isinstance(ev.get("step"), dict):
        _apply_step(job, ev["step"], at)
    if ev.get("status"):
        a = job.setdefault("agent", {})
        a["status"], a["status_at"], a["status_source"] = ev["status"], at, ev.get("source")
    if ev.get("state") in STATES:
        job["state"] = ev["state"]
        if ev["state"] in FINAL and not job.get("ended"):
            job["ended"] = at
    if "progress" in ev:
        job["progress"] = ev["progress"]
    if ev.get("items"):
        job["items"] = list(dict.fromkeys([*job.get("items", []), *ev["items"]]))
    if at > (job.get("updated") or ""):
        job["updated"] = at


def _events_after(job_id: str, offset: int) -> tuple[list[dict], int]:
    try:
        with open(path(job_id, ".events.jsonl"), "rb") as f:
            f.seek(offset)
            raw = f.read()
    except FileNotFoundError:
        return [], offset
    end = raw.rfind(b"\n") + 1  # a line still being written is not ours yet
    evs = []
    for line in raw[:end].splitlines():
        try:
            ev = json.loads(line)
            if isinstance(ev, dict):
                evs.append(ev)
        except ValueError:
            continue
    return evs, offset + end


def effective(job: dict) -> dict:
    """The job with its unmerged events folded in (does not write)."""
    job = json.loads(json.dumps(job))
    evs, _ = _events_after(job["id"], int(job.get("events_offset") or 0))
    for ev in evs:
        apply_event(job, ev)
    return job


def get(job_id: str) -> dict:
    return effective(read(job_id))


def append(job_id: str, ev: dict) -> dict:
    """Report progress on a job someone else owns: one line, appended atomically."""
    if not path(job_id).exists():
        raise JobError("no_job", f"no job {job_id}")
    ev = {"t": now_iso(), **{k: v for k, v in ev.items() if v is not None}}
    line = json.dumps(ev, ensure_ascii=False, separators=(",", ":"))
    if len(line.encode("utf-8")) > MAX_LINE:
        d = ev.get("detail")
        if isinstance(d, dict):
            ev["detail"] = {k: (v[:200] if isinstance(v, str) else v) for k, v in d.items()}
            line = json.dumps(ev, ensure_ascii=False, separators=(",", ":"))
        if len(line.encode("utf-8")) > MAX_LINE:
            ev.pop("detail", None)
            line = json.dumps(ev, ensure_ascii=False, separators=(",", ":"))
    p = path(job_id, ".events.jsonl")
    fd = os.open(p, os.O_RDWR | os.O_APPEND | os.O_CREAT, 0o644)
    try:
        size = os.fstat(fd).st_size
        torn = size > 0 and os.pread(fd, 1, size - 1) != b"\n" if hasattr(os, "pread") else False
        os.write(fd, (("\n" if torn else "") + line + "\n").encode("utf-8"))  # a crashed writer's half line stays alone
    finally:
        os.close(fd)
    return ev


def update(job_id: str, fn) -> dict:
    """Owner write: read, fold in pending events (so they're not lost), fn(job), stamp, replace. Under the lock."""
    with lock(job_id):
        job = read(job_id)
        absorb(job)
        fn(job)
        job["updated"] = now_iso()
        _write_json(path(job_id), job)
        return job


def absorb(job: dict, on_event=None) -> list[dict]:
    """Owner side: fold the pending events into `job` (in memory) and move events_offset past them. on_event(job, ev)
    sees each one first, for owner-only bookkeeping the public fold doesn't cover."""
    evs, off = _events_after(job["id"], int(job.get("events_offset") or 0))
    for ev in evs:
        if on_event:
            on_event(job, ev)
        apply_event(job, ev)
        err = (ev.get("detail") or {}).get("error") if isinstance(ev.get("detail"), dict) else None
        if ev.get("event") == "finish" and isinstance(err, dict):
            job["error"] = err  # not part of the shared fold: readers see it once the owner has merged
    job["events_offset"] = off
    return evs


def step(job_id: str, sid: str, state: str, progress: float | None = None) -> dict:
    if state not in STEP_STATES:
        raise JobError("bad_state", f"step state must be one of {', '.join(STEP_STATES)}")
    s = {"id": sid, "state": state}
    if progress is not None:
        s["progress"] = progress
    return append(job_id, {"source": "app", "event": "step", "step": s})


def finish_event(job_id: str, state: str, error: dict | None = None) -> dict:
    if state not in FINAL:
        raise JobError("bad_state", "finish state must be done, failed or cancelled")
    return append(job_id, {"source": "app", "event": "finish", "state": state,
                           "detail": {"error": error} if error else None})


def finish(job: dict, state: str, error: dict | None = None) -> None:
    """Owner: end a job in memory."""
    job["state"] = state
    job["ended"] = job.get("ended") or now_iso()
    if error:
        job["error"] = error


def all_jobs() -> list[dict]:
    out = []
    for p in jobs_dir().glob("j-*.json"):
        if p.name.count(".") != 1:  # <id>.json only, not <id>.claude-settings.json
            continue
        try:
            out.append(effective(json.loads(p.read_text(encoding="utf-8"))))
        except (OSError, ValueError, KeyError):
            continue
    out.sort(key=lambda j: (j.get("created") or "", j["id"]), reverse=True)
    return out


def list_jobs(active: bool = False, type: str | None = None, project: str | None = None, limit: int = 50) -> list[dict]:
    rows = [j for j in all_jobs() if (not active or j.get("state") in ("queued", "running"))
            and (not type or j.get("type") == type) and (not project or j.get("project") == project)]
    return rows[:limit] if limit else rows


def referenced_jobs() -> set[str] | None:
    """Job ids that unfinished items still point at (work.job of an item handed off, in progress or to verify), from
    index.db; None when the index can't be read."""
    try:
        sys.path.insert(0, str(Path(__file__).resolve().parent))
        import index
        con = index.connect(readonly=True)
        try:
            rows = con.execute("SELECT DISTINCT work_job FROM items WHERE work_job IS NOT NULL"
                               " AND state IN ('handed_off', 'in_progress', 'to_verify')").fetchall()
        finally:
            con.close()
    except Exception:  # noqa: BLE001 — no index yet / another schema: keep every agent job
        return None
    return {r[0] for r in rows}


def _keeps_work(j: dict) -> bool:
    """An agent's worktree that still exists and was never merged, turned into a PR or discarded: the job is the
    only way back to it (Review changes), so it stays."""
    a = j.get("agent") or {}
    wt = a.get("worktree")
    wt = wt.get("path") if isinstance(wt, dict) else wt  # sessions.py stores {path, branch, base, …}
    if not wt or not isinstance(wt, str) or a.get("finish"):
        return False
    try:
        return Path(wt).is_dir()
    except OSError:
        return False


def gc(live_windows: set[str] | None = None, now: float | None = None, referenced: set[str] | None = None) -> list[str]:
    """Remove jobs that ended more than 14 days ago and aren't among the newest 300. Never an agent job whose tmux
    window is still there (live_windows = job ids that have one; None = ask sessions.py), whose worktree waits to be
    finished, or that an unfinished item still points at (referenced; None = ask index.db). Hand-off notes stay."""
    if live_windows is None:
        try:
            sys.path.insert(0, str(Path(__file__).resolve().parent))
            import sessions
            live_windows = set(sessions.live_jobs())
        except Exception:  # noqa: BLE001 — no tmux / not importable: keep every agent job
            live_windows = None
    if referenced is None:
        referenced = referenced_jobs()
    now = time.time() if now is None else now
    jobs = all_jobs()
    keep = {j["id"] for j in jobs[:KEEP_LAST]}
    removed = []
    for j in jobs:
        if j["id"] in keep or j.get("state") not in FINAL:
            continue
        ended = parse_iso(j.get("ended")) or parse_iso(j.get("updated"))
        if ended is None or now - ended < KEEP_DAYS * 86400:
            continue
        if j.get("type") == "agent" and (live_windows is None or j["id"] in live_windows or referenced is None
                                         or j["id"] in referenced or _keeps_work(j)):
            continue
        for suffix in ATTACHED:
            with contextlib.suppress(OSError):
                path(j["id"], suffix).unlink()
        removed.append(j["id"])
    return removed


def watch(interval: float = 0.5) -> None:
    seen: dict[str, tuple] = {}
    while True:
        for p in jobs_dir().glob("j-*.json"):
            if p.name.count(".") != 1:
                continue
            jid = p.stem
            ev = path(jid, ".events.jsonl")
            try:
                sig = (p.stat().st_mtime_ns, ev.stat().st_mtime_ns if ev.exists() else 0)
            except OSError:
                continue
            if seen.get(jid) != sig:
                seen[jid] = sig
                try:
                    print(json.dumps(get(jid), ensure_ascii=False), flush=True)
                except JobError:
                    pass
        time.sleep(interval)


# ------------------------------------------------------------------ CLI
def emit(obj: dict) -> None:
    print(json.dumps(obj, ensure_ascii=False), flush=True)


def fail(code: str, msg: str, exit_code: int = 1):
    emit({"ok": False, "error": msg, "code": code})
    print(f"ERROR: {msg}", file=sys.stderr, flush=True)
    sys.exit(exit_code)


class _Parser(argparse.ArgumentParser):
    def error(self, message):  # argparse exits 2; the contract says 1 for bad arguments
        fail("bad_args", message)


def main(argv: list[str] | None = None) -> None:
    p = _Parser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True, parser_class=_Parser)
    s = sub.add_parser("new")
    s.add_argument("--type", required=True, choices=TYPES)
    s.add_argument("--project")
    s.add_argument("--session")
    s.add_argument("--parent")
    s.add_argument("--title")
    s.add_argument("--owner", default="app")
    s = sub.add_parser("step")
    s.add_argument("job")
    s.add_argument("step")
    s.add_argument("--state", required=True, choices=STEP_STATES)
    s.add_argument("--progress", type=float)
    s = sub.add_parser("event")
    s.add_argument("job")
    s.add_argument("--json", required=True)
    s = sub.add_parser("finish")
    s.add_argument("job")
    s.add_argument("--state", required=True, choices=FINAL)
    s.add_argument("--error-code", choices=ERROR_CODES)
    s.add_argument("--message")
    s.add_argument("--hint-key")
    s = sub.add_parser("get")
    s.add_argument("job")
    s = sub.add_parser("list")
    s.add_argument("--active", action="store_true")
    s.add_argument("--type", choices=TYPES)
    s.add_argument("--project")
    s.add_argument("--limit", type=int, default=50)
    s = sub.add_parser("watch")
    s.add_argument("--interval", type=float, default=0.5)
    sub.add_parser("gc")
    a = p.parse_args(argv)
    try:
        if a.cmd == "new":
            j = create(a.type, project=a.project, session=a.session, parent=a.parent, title=a.title, owner=a.owner)
            emit({"ok": True, "id": j["id"], "path": str(path(j["id"]))})
        elif a.cmd == "step":
            emit({"ok": True, "event": step(a.job, a.step, a.state, a.progress)})
        elif a.cmd == "event":
            try:
                ev = json.loads(a.json)
            except ValueError as e:
                fail("bad_args", f"--json: {e}")
            if not isinstance(ev, dict):
                fail("bad_args", "--json must be an object")
            ev.setdefault("source", "app")
            emit({"ok": True, "event": append(a.job, ev)})
        elif a.cmd == "finish":
            err = {"code": a.error_code or "unknown", "message": a.message or "", "hint_key": a.hint_key} \
                if a.error_code or a.message else None
            emit({"ok": True, "event": finish_event(a.job, a.state, err)})
        elif a.cmd == "get":
            emit({"ok": True, "job": get(a.job)})
        elif a.cmd == "list":
            emit({"ok": True, "jobs": list_jobs(a.active, a.type, a.project, a.limit)})
        elif a.cmd == "watch":
            with contextlib.suppress(KeyboardInterrupt, BrokenPipeError):
                watch(a.interval)
        elif a.cmd == "gc":
            emit({"ok": True, "removed": gc()})
    except JobError as e:
        fail(e.code, str(e), 3 if e.code == "locked" else 1)


if __name__ == "__main__":
    main()
