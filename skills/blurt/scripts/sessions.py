# /// script
# requires-python = ">=3.10"
# ///
"""Agent sessions (contract K5): Claude Code, Codex… running interactively on some items, in tmux on Blurt's own
socket (one tmux session per project, one window per dispatch), or in the app's own pty when there is no tmux.

  sessions.py dispatch --items REF … [--agent ID] [--mode together|parallel] [--worktree on|off|auto]
                       [--runner tmux|app|auto] [--dry-run] [--lang en|zh]
  sessions.py list [--project ID] [--all]
  sessions.py attach-cmd JOB                 → {"ok","argv","env"}: a grouped view on the job's window
  sessions.py open-external JOB [--terminal auto|terminal|iterm|ghostty|wezterm|kitty|gnome-terminal|konsole|wt]
  sessions.py send JOB --text T [--enter]
  sessions.py stop JOB [--kill]
  sessions.py finish JOB --action diff|merge|pr|discard|keep [--keep-branch]
  sessions.py hook --job J --agent A         an agent's hooks call this (stdin or last argv = their JSON)
  sessions.py event --job J --event pane-dead --exit N     the app runner reports an exit
  sessions.py monitor [--once] [--interval 1.0] [--job J]
  sessions.py doctor

Every call prints one JSON line ({"ok": false, "code": …} on errors; exit 1, 3 = locked, 4 = tmux missing). The
socket is $BLURT_TMUX_SOCKET (default "blurt"), never the user's own tmux server. See reference/sessions.md.
"""
from __future__ import annotations

import argparse
import functools
import json
import os
import re
import shutil
import subprocess
import sys
import time
import unicodedata
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPTS))
import jobs  # noqa: E402

MIN_TMUX = (3, 2)
EXIT_DEP = 4
IDLE_TURN_DONE = 8.0
TTY_BOTTOM = 6  # waiting_patterns are looked for in the last non-empty lines of the window
LIVE = ("running", "waiting_input", "turn_done")
STATUS_STATE = {"exited": "done", "error": "failed"}
TERMINALS = ("terminal", "iterm", "ghostty", "wezterm", "kitty", "gnome-terminal", "konsole", "wt")


class SessionError(Exception):
    def __init__(self, code: str, message: str, exit_code: int = 1, **extra):
        super().__init__(message)
        self.code, self.exit_code, self.extra = code, exit_code, extra


# ------------------------------------------------------------------ tmux
def socket_name() -> str:
    return os.environ.get("BLURT_TMUX_SOCKET") or "blurt"


def tmux_path() -> str | None:
    found = shutil.which("tmux")
    if found:
        return found
    for p in ("/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"):  # apps started from Finder/Dock
        if os.access(p, os.X_OK):
            return p
    return None


def tmux_version(path: str) -> tuple[int, int] | None:
    try:
        out = subprocess.run([path, "-V"], capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    m = re.search(r"(\d+)\.(\d+)", out)
    return (int(m.group(1)), int(m.group(2))) if m else None


@functools.lru_cache(maxsize=1)
def tmux_info() -> dict | None:
    """{"path", "version"} when a usable tmux (≥ 3.2) is installed."""
    p = tmux_path()
    v = tmux_version(p) if p else None
    return {"path": p, "version": f"{v[0]}.{v[1]}"} if v and v >= MIN_TMUX else None


def _clean_env() -> dict:
    import agents
    env = agents.clean_env()
    if not any("UTF-8" in (env.get(k) or "").upper() for k in ("LC_ALL", "LC_CTYPE", "LANG")):
        env["LC_CTYPE"] = "en_US.UTF-8" if sys.platform == "darwin" else "C.UTF-8"
    env.pop("TMUX", None)
    env.pop("TMUX_PANE", None)
    return env


def conf_path() -> Path:
    return jobs.home() / "tmux.conf"


def write_conf() -> Path:
    term = "tmux-256color"
    try:
        if subprocess.run(["infocmp", term], capture_output=True, timeout=5).returncode != 0:
            term = "screen-256color"
    except (OSError, subprocess.SubprocessError):
        term = "screen-256color"
    text = "\n".join([
        "# Written by Blurt (sessions.py) for its own tmux socket; changes are overwritten.",
        "set -g status off", "set -g mouse on", "set -g history-limit 50000", "set -s escape-time 10",
        "set -g focus-events on", "set -s set-clipboard on", "set -s extended-keys on",
        f'set -g default-terminal "{term}"', "set -g remain-on-exit on",
        "set -g allow-rename off", "setw -g automatic-rename off", "set -g renumber-windows off", ""])
    p = conf_path()
    p.parent.mkdir(parents=True, exist_ok=True)
    if not p.exists() or p.read_text(encoding="utf-8") != text:
        p.write_text(text, encoding="utf-8")
    return p


def tmux_base() -> list[str]:
    info = tmux_info()
    if not info:
        raise SessionError("no_tmux", "tmux 3.2 or newer is not installed", EXIT_DEP)
    return [info["path"], "-u", "-L", socket_name(), "-f", str(conf_path())]


def tmux(*args: str, check: bool = True, input: str | None = None, timeout: float = 15) -> subprocess.CompletedProcess:
    try:
        p = subprocess.run([*tmux_base(), *args], capture_output=True, text=True, encoding="utf-8", errors="replace",
                           input=input, env=_clean_env(), timeout=timeout,
                           stdin=None if input is not None else subprocess.DEVNULL)
    except (OSError, subprocess.SubprocessError) as e:
        raise SessionError("tmux", f"tmux {args[0]}: {e}") from None
    if check and p.returncode != 0:
        raise SessionError("tmux", f"tmux {' '.join(args[:2])}: {p.stderr.strip() or p.returncode}")
    return p


PANE_FMT = "|".join(["#{@blurt_job}", "#{session_name}", "#{window_id}", "#{window_name}", "#{pane_id}", "#{pane_dead}",
                     "#{pane_dead_status}", "#{window_activity}", "#{window_active_clients}"])


def panes() -> dict[str, dict]:
    """Job id → its window, for every window on our socket that has a job. {} when the server isn't running."""
    if not tmux_info():
        return {}
    p = tmux("list-panes", "-a", "-F", PANE_FMT, check=False)
    out: dict[str, dict] = {}
    for line in p.stdout.splitlines() if p.returncode == 0 else []:
        f = line.split("|")
        if len(f) != 9 or not f[0]:
            continue
        job, session, wid, name, pane, dead, dead_status, activity, clients = f
        if job in out and "~" in session:  # a grouped view (attach-cmd) lists the window again
            continue
        out[job] = {"session": session, "window": wid, "name": name, "pane": pane, "dead": dead == "1",
                    "exit": int(dead_status) if dead == "1" and dead_status.lstrip("-").isdigit() else None,
                    "activity": float(activity or 0), "clients": int(clients or 0)}
    if out:  # attached = some client shows this window, in any session of the group
        c = tmux("list-clients", "-F", "#{client_session}|#{window_id}", check=False)
        shown = {ln.split("|")[1] for ln in c.stdout.splitlines() if "|" in ln} if c.returncode == 0 else set()
        for w in out.values():
            w["attached"] = w["window"] in shown
    return out


def live_jobs() -> list[str]:
    """Job ids that still have a tmux window (dead or alive)."""
    return list(panes())


# ------------------------------------------------------------------ git
_GIT_LOCATION = {"GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY", "GIT_COMMON_DIR", "GIT_PREFIX",
                 "GIT_ALTERNATE_OBJECT_DIRECTORIES"}


def git(cwd: Path, *args: str, check: bool = True, timeout: float = 120) -> subprocess.CompletedProcess:
    env = {k: v for k, v in os.environ.items() if k not in _GIT_LOCATION}  # e.g. called from inside a git hook
    env["GIT_TERMINAL_PROMPT"] = "0"
    try:
        p = subprocess.run(["git", "-C", str(cwd), *args], capture_output=True, text=True, encoding="utf-8",
                           errors="replace", env=env, timeout=timeout, stdin=subprocess.DEVNULL)
    except (OSError, subprocess.SubprocessError) as e:
        raise SessionError("git", f"git {args[0]}: {e}") from None
    if check and p.returncode != 0:
        raise SessionError("git", f"git {' '.join(args[:2])}: {(p.stderr or p.stdout).strip()[-400:]}")
    return p


def repo_root(path: Path) -> Path | None:
    if not shutil.which("git"):
        return None
    p = git(path, "rev-parse", "--show-toplevel", check=False)
    return Path(p.stdout.strip()).resolve() if p.returncode == 0 and p.stdout.strip() else None


def ascii_slug(text: str, n: int = 24) -> str:
    s = unicodedata.normalize("NFKD", text or "").encode("ascii", "ignore").decode().lower()
    s = re.sub(r"[^a-z0-9]+", "-", s).strip("-")
    if len(s) <= n:
        return s
    cut = s[:n + 1].rsplit("-", 1)[0]  # whole words when there's a break in the second half
    return (cut if len(cut) > n // 2 else s[:n]).rstrip("-")


def window_name(ids: list[str]) -> str:
    name = ",".join(ids[:3]) + (f"+{len(ids) - 3}" if len(ids) > 3 else "")
    return name[:40]


def free_branch(root: Path, base: str) -> str:
    name, n = base, 1
    while git(root, "show-ref", "--verify", "--quiet", f"refs/heads/{name}", check=False).returncode == 0:
        n += 1
        name = f"{base}-{n}"
    return name


def free_path(base: Path) -> Path:
    p, n = base, 1
    while p.exists():
        n += 1
        p = base.with_name(f"{base.name}-{n}")
    return p


def worktree_root(project: dict, root: Path) -> Path:
    custom = project.get("worktree_root")
    return Path(custom).expanduser().resolve() if custom else root.parent / f".{root.name}-worktrees"


# ------------------------------------------------------------------ jobs of type agent
def agent_jobs() -> list[dict]:
    return [j for j in jobs.all_jobs() if j.get("type") == "agent"]


def is_alive(job: dict, wins: dict[str, dict]) -> bool:
    a = job.get("agent") or {}
    if a.get("runner") == "tmux":
        w = wins.get(job["id"])
        return bool(w) and not w["dead"]
    return job.get("state") == "running"


def _owner_extras(job: dict, ev: dict) -> None:
    """What the owner keeps from events beyond the shared fold."""
    a = job.setdefault("agent", {})
    d = ev.get("detail") if isinstance(ev.get("detail"), dict) else {}
    if d.get("agent_session_id") and not a.get("agent_session_id"):
        a["agent_session_id"] = d["agent_session_id"]
    if ev.get("source") == "hook" and ev.get("event") != "agent-turn-complete":
        a["hooks_live"] = True
    if "exit" in d:
        a["exit"] = d["exit"]


def _set_status(job: dict, status: str, source: str, exit_code: int | None = None) -> None:
    a = job.setdefault("agent", {})
    if a.get("status") != status:
        a["status"], a["status_at"], a["status_source"] = status, jobs.now_iso(), source
    if exit_code is not None:
        a["exit"] = exit_code
    if status in STATUS_STATE and job.get("state") in ("running", "queued"):
        jobs.finish(job, STATUS_STATE[status])
    elif status == "error" and job.get("state") == "done":  # SessionEnd said exited, the exit code says otherwise
        job["state"] = "failed"


def _step(job: dict, sid: str, state: str) -> None:
    jobs._apply_step(job, {"id": sid, "state": state}, jobs.now_iso())


def _items_in(uids: list[str], states: tuple[str, ...]) -> list[str]:
    import handoff
    out = []
    for u in uids:
        try:
            it = handoff.item(u)
        except handoff.CliError:
            continue
        if ((it.get("work") or {}).get("state") or "todo") in states:
            out.append(u)
    return out


def _advance_items(job: dict, running: bool) -> None:
    """K3 for a session: first running → handed_off items become in_progress; exited → in_progress ones go to
    to_verify (claim null). Each happens once per job (agent.started / agent.closed). running = the agent is known
    to be up (a hook or the terminal said so, or it has no hooks and its window is alive)."""
    import handoff
    a = job.get("agent") or {}
    uids = job.get("items") or []
    common = {"agent": a.get("id"), "job": job["id"], "by": "app"}
    try:
        if a.get("status") in LIVE and not a.get("started") and running:
            todo = _items_in(uids, ("handed_off",))
            if todo:
                handoff.set_work(todo, "in_progress", **common)
            a["started"] = True
        if a.get("status") in ("exited", "error") and not a.get("closed"):
            doing = _items_in(uids, ("in_progress",))
            if doing:
                handoff.set_work(doing, "to_verify", **common)
            a["closed"] = True
    except handoff.CliError as e:
        a["items_error"] = {"code": e.code, "message": str(e)[:300]}


def _hooks_kind(a: dict) -> str | None:
    import agents
    defn = agents.definitions(agents.config(a.get("cwd"))).get(a.get("id")) or {}
    return (agents.session_spec(defn) or {}).get("hooks")


def _tty_fallback(job: dict, w: dict, now: float) -> None:
    """Status from the terminal, for agents whose hooks aren't reporting (K5)."""
    import agents
    a = job["agent"]
    defn = agents.definitions(agents.config(a.get("cwd"))).get(a.get("id")) or {}
    hooks = (agents.session_spec(defn) or {}).get("hooks")
    if hooks == "claude" or (hooks and a.get("hooks_live")):
        return
    patterns = agents.waiting_patterns(defn)
    since = jobs.parse_iso(a.get("status_at")) or 0
    text = ""
    if patterns:
        p = tmux("capture-pane", "-p", "-J", "-S", "-15", "-t", w["pane"], check=False)
        lines = [ln for ln in (p.stdout if p.returncode == 0 else "").splitlines() if ln.strip()]
        text = "\n".join(lines[-TTY_BOTTOM:])  # a prompt that has scrolled up was answered
    hit = any(re.search(pat, text, re.I | re.M) for pat in patterns) if text else False
    status = a.get("status")
    if hit:
        if status != "waiting_input":
            _set_status(job, "waiting_input", "tty")
    elif status == "waiting_input" and a.get("status_source") == "tty" and w["activity"] > since:
        _set_status(job, "running", "tty")
    elif hooks is None:  # nothing reports a finished turn: 8 s without output
        if status == "running" and now - w["activity"] >= IDLE_TURN_DONE and now - since >= IDLE_TURN_DONE:
            _set_status(job, "turn_done", "tty")
        elif status == "turn_done" and a.get("status_source") == "tty" and w["activity"] > since:
            _set_status(job, "running", "tty")


def sync(only: list[str] | None = None) -> list[dict]:
    """One monitor pass: fold events, look at the windows, move items along (K3). Returns the jobs it wrote."""
    wins = panes()
    now = time.time()
    changed = []
    for j in agent_jobs():
        a = j.get("agent") or {}
        w = wins.get(j["id"])
        pending = j.get("state") in ("running", "queued") or (a.get("status") in STATUS_STATE and not a.get("closed")) \
            or (w is not None and w["dead"] and a.get("exit") is None)
        if (only and j["id"] not in only) or (not only and not pending):
            continue
        try:
            with jobs.lock(j["id"], timeout=3):
                job = jobs.read(j["id"])
                before = json.dumps(job, sort_keys=True)
                jobs.absorb(job, _owner_extras)
                a = job.setdefault("agent", {})
                w = wins.get(job["id"]) if a.get("runner") == "tmux" else None
                active = job.get("state") in ("running", "queued")
                if a.get("runner") == "tmux":
                    if w is None:
                        if active and tmux_info():  # the window was closed
                            _set_status(job, "exited", "tmux")
                    elif w["dead"]:
                        if active or a.get("exit") is None:
                            _set_status(job, "exited" if (w["exit"] or 0) == 0 else "error", "tmux", w["exit"])
                    elif active:
                        _tty_fallback(job, w, now)
                if a.get("status") in LIVE and job.get("state") == "running":
                    _step(job, "launch", "done")
                    _step(job, "work", "running")
                if job.get("state") in jobs.FINAL:
                    _step(job, "launch", "done")
                    _step(job, "work", "done" if job["state"] != "failed" else "failed")
                up = a.get("status_source") not in (None, "app") or (
                    w is not None and not w["dead"] and _hooks_kind(a) is None)
                _advance_items(job, up)
                if json.dumps(job, sort_keys=True) != before:
                    job["updated"] = jobs.now_iso()
                    jobs._write_json(jobs.path(job["id"]), job)
                    changed.append(job)
        except jobs.JobError:
            continue
    return changed


def monitor(once: bool, interval: float, only: list[str] | None = None) -> dict:
    if once:
        return {"ok": True, "changed": [j["id"] for j in sync(only)]}
    run = jobs.home() / "run"
    try:
        with jobs.file_lock(run / "monitor.lock", timeout=0.2):
            while True:
                sync(only)
                time.sleep(interval)
    except jobs.JobError:
        return {"ok": True, "already_running": True}


def spawn_sync(job: str) -> None:
    """Run one monitor pass for this job in the background (from a hook, which must return at once)."""
    kw: dict = {"stdin": subprocess.DEVNULL, "stdout": subprocess.DEVNULL, "stderr": subprocess.DEVNULL,
                "close_fds": True}
    if os.name == "nt":
        kw["creationflags"] = 0x00000008 | 0x00000200  # DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP
    else:
        kw["start_new_session"] = True
    try:
        subprocess.Popen([sys.executable, str(Path(__file__).resolve()), "monitor", "--once", "--job", job], **kw)
    except OSError:
        pass


# ------------------------------------------------------------------ hooks
CLAUDE_STATUS = {"SessionStart": "running", "UserPromptSubmit": "running", "PostToolUse": "running",
                 "Stop": "turn_done", "SessionEnd": "exited"}
CODEX_STATUS = {"SessionStart": "running", "UserPromptSubmit": "running", "PostToolUse": "running",
                "PermissionRequest": "waiting_input", "Stop": "turn_done", "SessionEnd": "exited",
                "agent-turn-complete": "turn_done"}


def hook_status(agent: str, payload: dict) -> tuple[str, str | None]:
    """(event name, K5 status or None = no change)."""
    name = payload.get("hook_event_name") or payload.get("type") or ""
    if name == "Notification":
        kind = payload.get("notification_type")
        return name, "waiting_input" if kind in (None, "", "permission_prompt", "elicitation_dialog") else None
    table = CODEX_STATUS if agent == "codex" else CLAUDE_STATUS
    return name, table.get(name)


def hook(job_id: str | None, agent: str, arg: str | None) -> None:
    """Never prints, never fails, returns quickly: an agent waits for its hooks."""
    try:
        raw = arg if arg else ("" if sys.stdin is None or sys.stdin.isatty() else sys.stdin.read(1 << 20))
        payload = json.loads(raw) if raw and raw.strip() else {}
        if not isinstance(payload, dict):
            return
        job_id = job_id or os.environ.get("BLURT_JOB")
        if not job_id or not jobs.path(job_id).exists():
            return
        name, status = hook_status(agent, payload)
        with open(jobs.path(job_id, ".log"), "a", encoding="utf-8") as f:
            f.write(json.dumps({"t": jobs.now_iso(), "hook": agent, "payload": payload}, ensure_ascii=False)[:16000] + "\n")
        job = jobs.read(job_id)
        pending, _ = jobs._events_after(job_id, int(job.get("events_offset") or 0))
        known = (job.get("agent") or {}).get("agent_session_id") or next(
            (e["detail"]["agent_session_id"] for e in pending if isinstance(e.get("detail"), dict)
             and e["detail"].get("agent_session_id")), None)
        for e in pending:
            jobs.apply_event(job, e)
        a = job.get("agent") or {}
        sid = payload.get("session_id") or payload.get("thread-id")
        if name == "agent-turn-complete" and known and sid and sid != known:
            return  # Codex also notifies for side threads (titles…)
        new_sid = sid if sid and not known and name != "agent-turn-complete" else None
        if status is None or (status == a.get("status") and not new_sid):
            return
        if job.get("state") in jobs.FINAL and status not in ("exited", "error"):
            return
        detail = {"agent_session_id": new_sid}
        if payload.get("notification_type"):
            detail["notification_type"] = payload["notification_type"]
        if isinstance(payload.get("message"), str):
            detail["message"] = payload["message"][:200]
        jobs.append(job_id, {"source": "hook", "event": name, "status": status, "state": STATUS_STATE.get(status),
                             "detail": {k: v for k, v in detail.items() if v} or None})
        if (status in LIVE and not a.get("started")) or status in STATUS_STATE:
            spawn_sync(job_id)
    except Exception:  # noqa: BLE001 — a hook must never get in the agent's way
        return


def app_event(job_id: str, event: str, exit_code: int | None) -> dict:
    if event != "pane-dead":
        raise SessionError("bad_args", "the only event is pane-dead")
    status = "exited" if (exit_code or 0) == 0 else "error"
    jobs.append(job_id, {"source": "app", "event": "pane-dead", "status": status, "state": STATUS_STATE[status],
                         "detail": {"exit": exit_code}})
    sync([job_id])
    return {"ok": True, "job": jobs.get(job_id)}


# ------------------------------------------------------------------ dispatch
def _config() -> dict:
    try:
        return json.loads((jobs.home() / "config.json").read_text(encoding="utf-8-sig")) or {}
    except (OSError, ValueError):
        return {}


def pick_agent(want: str | None, project: dict) -> str:
    import agents
    cfg = agents.config(project.get("path"))
    defs = agents.definitions(cfg)
    for cand in (want, project.get("default_agent"), (cfg.get("record") or {}).get("default_agent")):
        if cand:
            if cand not in defs or not agents.session_spec(defs[cand]):
                raise SessionError("bad_agent", f"{cand} can't run as a session")
            return cand
    det = agents.detect(version=False, repo=project.get("path"))
    rows = [r for r in det["agents"] if r["installed"] and agents.session_spec(defs.get(r["id"], {}))]
    for want_state in ("ready", "configured", "unknown"):
        r = next((r for r in rows if r["state"] == want_state), None)
        if r:
            return r["id"]
    raise SessionError("no_agent", "no agent that can run a session is installed and logged in")


def plan(refs: list[str], agent: str | None, mode: str, worktree: str, runner: str) -> dict:
    import handoff
    if not refs:
        raise SessionError("bad_args", "no items")
    items, seen = [], set()
    for r in refs:
        try:
            it = handoff.item(r)
        except handoff.CliError as e:
            raise SessionError(e.code, str(e)) from None
        if it["uid"] not in seen:
            seen.add(it["uid"])
            items.append(it)
    pids = {it.get("project") for it in items}
    if len(pids) != 1:
        raise SessionError("mixed_projects", "the items belong to different projects", items=[i["uid"] for i in items])
    pid = pids.pop()
    if not pid or pid == "inbox":
        raise SessionError("needs_project", "unassigned items: move them into a project first",
                           items=[i["uid"] for i in items])
    gone = [i["uid"] for i in items if i.get("status") == "deleted"]
    if gone:
        raise SessionError("deleted", "dropped items can't be handed to an agent", items=gone)
    busy = [i["uid"] for i in items if ((i.get("work") or {}).get("state") or "todo") not in ("todo", "handed_off")]
    if busy:
        raise SessionError("bad_transition", "some items are already being worked on or done — reopen them first",
                           items=busy)
    try:
        project = handoff.project(pid)
    except handoff.CliError as e:
        raise SessionError(e.code, str(e)) from None
    if not project or not project.get("path") or not Path(project["path"]).is_dir():
        raise SessionError("needs_project", f"project {pid} has no folder on this computer")
    folder = Path(project["path"]).resolve()
    agent_id = pick_agent(agent, project)
    warnings: list[dict] = []
    have_tmux = tmux_info() is not None
    if runner == "tmux" and not have_tmux:
        raise SessionError("no_tmux", "tmux 3.2 or newer is not installed", EXIT_DEP)
    use_runner = runner if runner != "auto" else ("tmux" if have_tmux and os.name != "nt" else "app")
    if runner == "auto" and use_runner == "app" and os.name != "nt":
        warnings.append({"code": "no_tmux"})
    root = repo_root(folder)
    want_wt = {"on": True, "off": False}.get(worktree, bool(project.get("worktree", True)))
    if mode == "parallel":
        want_wt = True
    if want_wt and root is None:
        if worktree == "on" or mode == "parallel":
            warnings.append({"code": "no_git"})
        want_wt = False
    groups = [[it] for it in items] if mode == "parallel" else [items]
    out = []
    for g in groups:
        ids = [it.get("id") or it["uid"] for it in g]
        entry = {"project": pid, "window": window_name(ids), "items": [it["uid"] for it in g], "cwd": str(folder),
                 "_items": g}
        if want_wt:
            base = free_path(worktree_root(project, root) / ids[0])
            slug = ascii_slug(g[0].get("title") or "")
            br = free_branch(root, f"blurt/{ids[0].lower()}" + (f"-{slug}" if slug else ""))
            rel = folder.relative_to(root) if folder != root else Path()
            entry.update(worktree=str(base), branch=br, cwd=str(base / rel), _root=str(root))
        out.append(entry)
    # editing the project folder directly while another session does the same: say so, never block
    wins = panes()
    direct = [j["id"] for j in agent_jobs() if j.get("project") == pid and not (j.get("agent") or {}).get("worktree")
              and is_alive(j, wins)]
    if not want_wt and (direct or len(out) > 1):
        warnings.append({"code": "concurrent_edit", "jobs": direct})
    drafts = [it["uid"] for it in items if it.get("status") == "draft"]
    if drafts:
        warnings.append({"code": "draft_confirmed", "items": drafts})
    return {"project": project, "agent": agent_id, "mode": mode, "runner": use_runner, "worktree": want_wt,
            "jobs": out, "warnings": warnings, "root": str(root) if root else None}


def _public(entry: dict) -> dict:
    return {k: v for k, v in entry.items() if not k.startswith("_")}


def _session_env(job_id: str, agent: str, project: str) -> dict:
    env = {"BLURT_JOB": job_id, "BLURT_RUN_ID": job_id, "BLURT_AGENT": agent, "BLURT_PROJECT": project,
           "BLURT_HOME": str(jobs.home())}
    if os.environ.get("BLURT_WORKSPACE"):
        env["BLURT_WORKSPACE"] = os.environ["BLURT_WORKSPACE"]
    return env


def _new_window(session: str, name: str, cwd: str, env: dict, argv: list[str]) -> str:
    write_conf()
    e_args = [x for k, v in env.items() for x in ("-e", f"{k}={v}")]
    exists = tmux("has-session", "-t", f"={session}", check=False).returncode == 0
    if exists:
        p = tmux("new-window", "-d", "-P", "-F", "#{window_id}", "-t", f"={session}:", "-n", name, "-c", cwd,
                 *e_args, "--", *argv)
    else:
        p = tmux("new-session", "-d", "-P", "-F", "#{window_id}", "-s", session, "-n", name, "-c", cwd,
                 "-x", "200", "-y", "50", *e_args, "--", *argv)
    return p.stdout.strip().splitlines()[-1]


def dispatch(refs: list[str], agent: str | None = None, mode: str = "together", worktree: str = "auto",
             runner: str = "auto", dry_run: bool = False, lang: str | None = None) -> dict:
    import agents
    import handoff
    pl = plan(refs, agent, mode, worktree, runner)
    project = pl["project"]
    if dry_run:
        return {"ok": True, "dry_run": True, "agent": pl["agent"], "mode": mode, "runner": pl["runner"],
                "worktree": pl["worktree"], "jobs": [_public(e) for e in pl["jobs"]], "warnings": pl["warnings"]}
    mcp = None
    out_jobs, launch = [], []
    warnings = list(pl["warnings"])
    for e in pl["jobs"]:
        jid = jobs.new_id()
        agent_obj = {"id": pl["agent"], "mode": mode, "runner": pl["runner"], "tmux": None, "cwd": e["cwd"],
                     "worktree": None, "status": "running", "status_at": jobs.now_iso(), "status_source": "app",
                     "exit": None, "handoff": None, "agent_session_id": None, "finish": None}
        title = e["_items"][0].get("title") if len(e["_items"]) == 1 else None
        jobs.create("agent", project=project["id"], owner="sessions.py", items=e["items"], title=title,
                          agent=agent_obj, job_id=jid)
        try:
            if e.get("worktree"):
                root = Path(e["_root"])
                base_branch = git(root, "rev-parse", "--abbrev-ref", "HEAD").stdout.strip()
                base_sha = git(root, "rev-parse", "HEAD").stdout.strip()
                Path(e["worktree"]).parent.mkdir(parents=True, exist_ok=True)
                git(root, "worktree", "add", "-b", e["branch"], e["worktree"], base_sha)
                agent_obj["worktree"] = {"path": e["worktree"], "branch": e["branch"], "base": base_branch,
                                         "base_sha": base_sha, "repo": str(root)}
            elif pl["root"]:
                agent_obj["base_sha"] = git(Path(pl["root"]), "rev-parse", "HEAD", check=False).stdout.strip() or None
            pr = agents.prompt_work([], "session", bool(e.get("worktree")), lang=lang, branch=e.get("branch"),
                                    items=e["_items"])
            agent_obj["handoff"] = pr["handoff"]
            jobs.path(jid, ".prompt.md").write_text(pr["prompt"] + "\n", encoding="utf-8")
            if mcp is None:
                defn = agents.definitions(agents.config(project["path"])).get(pl["agent"]) or {}
                mcp = agents.mcp_installed(defn) is False
            cmd = agents.session_command(pl["agent"], pr["prompt"], e["cwd"], job=jid, mcp=mcp,
                                         settings=jobs.path(jid, ".claude-settings.json"))
            env = _session_env(jid, pl["agent"], project["id"])
            if pl["runner"] == "tmux":
                session = f"blurt-{project.get('slug') or project['id']}"
                wid = _new_window(session, e["window"], e["cwd"], env, cmd["argv"])
                tmux("set-option", "-w", "-t", wid, "@blurt_job", jid)
                tmux("set-option", "-w", "-t", wid, "@blurt_items", " ".join(e["items"]))
                tmux("set-option", "-w", "-t", wid, "@blurt_agent", pl["agent"])
                agent_obj["tmux"] = {"socket": socket_name(), "session": session, "window": wid, "name": e["window"]}
                if cmd["paste"]:
                    _spawn_paste(jid, cmd["paste"])
            else:
                launch.append({"job": jid, "argv": cmd["argv"], "env": env, "cwd": e["cwd"],
                               "paste": cmd["paste"], "patterns": cmd["patterns"]})
        except (SessionError, ValueError, handoff.CliError, OSError) as err:
            code = getattr(err, "code", None) or "io"
            if agent_obj.get("worktree"):
                git(Path(e["_root"]), "worktree", "remove", "--force", e["worktree"], check=False)
                git(Path(e["_root"]), "branch", "-D", e["branch"], check=False)
                agent_obj["worktree"] = None

            def failed(j, err=err, code=code):
                j["agent"] = agent_obj
                jobs.finish(j, "failed", {"code": code if code in jobs.ERROR_CODES else "unknown",
                                          "message": str(err)[:500], "hint_key": None})
                _step(j, "launch", "failed")
            jobs.update(jid, failed)
            raise SessionError(code, str(err), getattr(err, "exit_code", 1), job=jid) from None

        def launched(j):
            j["agent"] = agent_obj
            _step(j, "launch", "running" if pl["runner"] == "app" else "done")
            if pl["runner"] == "tmux":
                _step(j, "work", "running")
        jobs.update(jid, launched)
        try:  # the items: handed to this session; drafts become kept (the user chose to act on them)
            drafts = [it["uid"] for it in e["_items"] if it.get("status") == "draft"]
            for u in drafts:
                handoff.cli(handoff.ITEMS_PY, "patch", u, "--set", "status=confirmed")
            handoff.set_work(e["items"], "handed_off", to="session", agent=pl["agent"], job=jid,
                             handoff=agent_obj["handoff"], by="app")
        except handoff.CliError as err:
            warnings.append({"code": "items_not_updated", "items": e["items"], "message": str(err)[:300]})
        row = {"id": jid, "project": project["id"], "window": e["window"], "cwd": e["cwd"], "items": e["items"],
               "handoff": agent_obj["handoff"]}
        if e.get("worktree"):
            row.update(worktree=e["worktree"], branch=e["branch"])
        out_jobs.append(row)
    res = {"ok": True, "jobs": out_jobs, "warnings": warnings}
    if launch:
        res["launch"] = launch
    return res


def _spawn_paste(job: str, text: str) -> None:
    kw: dict = {"stdin": subprocess.DEVNULL, "stdout": subprocess.DEVNULL, "stderr": subprocess.DEVNULL,
                "close_fds": True, "start_new_session": True}
    try:
        subprocess.Popen([sys.executable, str(Path(__file__).resolve()), "send", job, "--text", text, "--enter",
                          "--after", "3"], **kw)
    except OSError:
        pass


# ------------------------------------------------------------------ list / attach / send / stop
def _job(job_id: str) -> dict:
    try:
        j = jobs.get(job_id)
    except jobs.JobError as e:
        raise SessionError(e.code, str(e)) from None
    if j.get("type") != "agent":
        raise SessionError("bad_job", f"{job_id} is not an agent session")
    return j


def _window(job: dict) -> dict:
    a = job.get("agent") or {}
    if a.get("runner") != "tmux":
        raise SessionError("app_runner", "this session runs in the app's own terminal")
    w = panes().get(job["id"])
    if not w:
        raise SessionError("gone", "the session's window is closed")
    return w


def list_sessions(project: str | None = None, all_: bool = False) -> dict:
    sync()
    wins = panes()
    rows = []
    for j in agent_jobs():
        if project and j.get("project") != project:
            continue
        a = j.get("agent") or {}
        w = wins.get(j["id"])
        if not all_ and not (w or (a.get("runner") == "app" and j.get("state") == "running")):
            continue
        wt = a.get("worktree") or {}
        rows.append({"job": j["id"], "project": j.get("project"), "agent": a.get("id"), "items": j.get("items", []),
                     "window": (a.get("tmux") or {}).get("name"), "tmux": a.get("tmux"), "runner": a.get("runner"),
                     "status": a.get("status"), "status_at": a.get("status_at"), "state": j.get("state"),
                     "worktree": wt.get("path"), "branch": wt.get("branch"), "cwd": a.get("cwd"),
                     "handoff": a.get("handoff"), "started": j.get("started"), "ended": j.get("ended"),
                     "exit": a.get("exit"), "attached": bool(w and w.get("attached")), "open": bool(w)})
    return {"ok": True, "sessions": rows}


def attach_cmd(job_id: str, status: bool = False) -> dict:
    """A grouped view session on the job's tmux session, showing its window: each embedded terminal gets its own,
    so two panes show different windows without fighting over the current one. The view is made here and the argv
    only attaches to it (no tmux command chaining for launchers to mangle); it goes away when its terminal does
    (destroy-unattached), and views nobody attached to within a minute are cleared on the next call."""
    job = _job(job_id)
    w = _window(job)
    session = w["session"].split("~")[0]
    p = tmux("list-sessions", "-F", "#{session_name}|#{session_attached}|#{session_created}", check=False)
    taken = set()
    for line in p.stdout.splitlines():
        name, _, rest = line.partition("|")
        m = re.fullmatch(re.escape(session) + r"~(\d+)", name)
        if not m:
            continue
        attached, _, created = rest.partition("|")
        if attached == "0" and time.time() - float(created or 0) > 60:
            tmux("kill-session", "-t", name, check=False)
        else:
            taken.add(int(m.group(1)))
    view = f"{session}~{max(taken, default=0) + 1}"
    tmux("new-session", "-d", "-t", f"={session}", "-s", view)
    # destroy-unattached right away would end the view before its terminal attaches: arm it on attach
    tmux("set-hook", "-t", view, "client-attached", f"set-option -t '{view}' destroy-unattached on")
    tmux("set-option", "-t", view, "status", "on" if status else "off")
    tmux("select-window", "-t", f"={view}:{w['window']}")
    env = {"TERM": os.environ.get("TERM") or "xterm-256color"}
    return {"ok": True, "argv": [*tmux_base(), "attach-session", "-t", f"={view}"], "env": env, "session": view,
            "window": w["window"]}


def _osascript_quote(s: str) -> str:
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def open_external(job_id: str, terminal: str = "auto") -> dict:
    import shlex
    cmd = attach_cmd(job_id, status=True)
    line = " ".join(shlex.quote(a) for a in cmd["argv"])
    term = terminal
    if term == "auto":
        if sys.platform == "darwin":
            apps = {"ghostty": "/Applications/Ghostty.app", "iterm": "/Applications/iTerm.app",
                    "wezterm": "/Applications/WezTerm.app", "kitty": "/Applications/kitty.app"}
            term = next((k for k, v in apps.items() if Path(v).exists()), "terminal")
        elif os.name == "nt":
            term = "wt"
        else:
            term = next((t for t in ("gnome-terminal", "konsole", "wezterm", "kitty") if shutil.which(t)), "")
            if not term:
                raise SessionError("no_terminal", "no supported terminal app found")
    if term == "terminal":
        argv = ["osascript", "-e", f"tell application \"Terminal\" to do script {_osascript_quote(line)}",
                "-e", "tell application \"Terminal\" to activate"]
    elif term == "iterm":
        argv = ["osascript", "-e", "tell application \"iTerm\" to create window with default profile command "
                + _osascript_quote(line), "-e", "tell application \"iTerm\" to activate"]
    elif term in ("ghostty", "wezterm", "kitty") and sys.platform == "darwin":
        app = {"ghostty": "Ghostty", "wezterm": "WezTerm", "kitty": "kitty"}[term]
        args = {"ghostty": ["-e", *cmd["argv"]], "wezterm": ["start", "--", *cmd["argv"]], "kitty": cmd["argv"]}[term]
        argv = ["open", "-na", app, "--args", *args]
    elif term == "wezterm":
        argv = ["wezterm", "start", "--", *cmd["argv"]]
    elif term == "kitty":
        argv = ["kitty", *cmd["argv"]]
    elif term == "gnome-terminal":
        argv = ["gnome-terminal", "--", *cmd["argv"]]
    elif term == "konsole":
        argv = ["konsole", "-e", *cmd["argv"]]
    else:
        raise SessionError("no_terminal", f"{term} can't attach to a tmux session here")
    try:
        p = subprocess.run(argv, capture_output=True, text=True, timeout=20, stdin=subprocess.DEVNULL)
    except (OSError, subprocess.SubprocessError) as e:
        raise SessionError("no_terminal", f"{term}: {e}") from None
    if p.returncode != 0:
        raise SessionError("no_terminal", f"{term}: {(p.stderr or p.stdout).strip()[-300:]}")
    return {"ok": True, "terminal": term, "session": cmd["session"]}


def send(job_id: str, text: str, enter: bool = False, after: float = 0) -> dict:
    if after:
        time.sleep(after)
    job = _job(job_id)
    w = _window(job)
    if w["dead"]:
        raise SessionError("gone", "the agent in this window has exited")
    buf = f"blurt-{job_id}"
    tmux("load-buffer", "-b", buf, "-", input=text)
    tmux("paste-buffer", "-p", "-d", "-b", buf, "-t", w["pane"])
    if enter:
        time.sleep(0.2)
        tmux("send-keys", "-t", w["pane"], "Enter")
    return {"ok": True}


def stop(job_id: str, kill: bool = False) -> dict:
    job = _job(job_id)
    a = job.get("agent") or {}
    if a.get("runner") == "tmux":
        w = panes().get(job_id)
        if w and not w["dead"]:
            tmux("send-keys", "-t", w["pane"], "C-c", check=False)
            time.sleep(0.4)
            tmux("send-keys", "-t", w["pane"], "C-c", check=False)
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline:
                w2 = panes().get(job_id)
                if not w2 or w2["dead"]:
                    break
                time.sleep(0.2)
        if w and kill:
            tmux("kill-window", "-t", w["window"], check=False)

    def cancelled(j):  # the user stopped it, even when the agent's own exit hook got there first
        if j.get("state") in ("running", "queued", "done") and not (j.get("agent") or {}).get("finish"):
            _set_status(j, "exited", "app")
            j["state"] = "cancelled"
            j["ended"] = j.get("ended") or jobs.now_iso()
            if next((s["state"] for s in j.get("steps", []) if s["id"] == "work"), None) != "done":
                _step(j, "work", "skipped")
    jobs.update(job_id, cancelled)
    sync([job_id])
    return {"ok": True, "job": jobs.get(job_id)}


# ------------------------------------------------------------------ finish: diff / merge / pr / discard / keep
def _numstat(cwd: Path, base: str) -> list[dict]:
    rows = []
    for line in git(cwd, "diff", "--numstat", base, check=False).stdout.splitlines():
        f = line.split("\t")
        if len(f) == 3:
            rows.append({"path": f[2], "added": int(f[0]) if f[0].isdigit() else None,
                         "deleted": int(f[1]) if f[1].isdigit() else None})
    return rows


def diff(job: dict) -> dict:
    a = job.get("agent") or {}
    wt = a.get("worktree")
    cwd = Path(wt["path"]) if wt else Path(a.get("cwd") or ".")
    base = (wt or {}).get("base_sha") or a.get("base_sha")
    if not base:
        raise SessionError("no_git", "this session didn't start in a git repository")
    if not cwd.is_dir():
        raise SessionError("gone", f"{cwd} no longer exists")
    stat = _numstat(cwd, base)
    patch = git(cwd, "diff", "--binary", base, check=False).stdout
    untracked = [f for f in git(cwd, "ls-files", "--others", "--exclude-standard", "-z", check=False).stdout.split("\0") if f]
    for f in untracked:
        patch += git(cwd, "diff", "--binary", "--no-index", "--", os.devnull, f, check=False).stdout
        try:
            with open(cwd / f, "rb") as fh:
                lines = sum(1 for _ in fh)
        except OSError:
            lines = None
        stat.append({"path": f, "added": lines, "deleted": 0})
    out = jobs.path(job["id"], ".diff")
    out.write_text(patch, encoding="utf-8")
    uncommitted = len([ln for ln in git(cwd, "status", "--porcelain", check=False).stdout.splitlines() if ln.strip()])
    return {"base": (wt or {}).get("base") or base, "branch": (wt or {}).get("branch"), "stat": stat,
            "patch": str(out), "uncommitted": uncommitted}


def _compare_url(remote: str, base: str, branch: str) -> str | None:
    m = re.match(r"(?:git@|ssh://git@)([^:/]+)[:/](.+?)(?:\.git)?/?$", remote) or \
        re.match(r"https?://(?:[^@/]+@)?([^/]+)/(.+?)(?:\.git)?/?$", remote)
    if not m:
        return None
    return f"https://{m.group(1)}/{m.group(2)}/compare/{base}...{branch}?expand=1"


def finish(job_id: str, action: str, keep_branch: bool = False) -> dict:
    import handoff
    job = _job(job_id)
    a = job.get("agent") or {}
    wt = a.get("worktree")
    if action == "diff":
        return {"ok": True, **diff(job)}
    if action != "keep" and not wt:
        raise SessionError("no_worktree", "this session worked in the project folder directly — nothing to "
                                          f"{action}")
    result: dict = {}
    main = Path(wt["repo"]) if wt else None
    if action in ("merge", "pr") and not Path(wt["path"]).is_dir():
        raise SessionError("gone", "the worktree is gone")
    if action == "merge":
        live = panes().get(job_id)
        if live and not live["dead"]:
            raise SessionError("running", "the agent is still running in this worktree — stop it first")
        dirty = [ln for ln in git(Path(wt["path"]), "status", "--porcelain").stdout.splitlines() if ln.strip()]
        if dirty:
            raise SessionError("uncommitted", f"{len(dirty)} uncommitted change(s) in the worktree", count=len(dirty))
        head = git(main, "rev-parse", "--abbrev-ref", "HEAD").stdout.strip()
        if head != wt["base"]:
            raise SessionError("wrong_branch", f"the project folder is on {head}, not {wt['base']}", branch=head)
        if [ln for ln in git(main, "status", "--porcelain", "--untracked-files=no").stdout.splitlines() if ln.strip()]:
            raise SessionError("dirty", "the project folder has uncommitted changes")
        ahead = int(git(main, "rev-list", "--count", f"{wt['base_sha']}..{wt['branch']}").stdout.strip() or 0)
        if ahead == 0:
            raise SessionError("nothing", "the session's branch has no commits to merge")
        m = git(main, "merge", "--no-ff", "--no-edit", wt["branch"], check=False)
        if m.returncode != 0:
            git(main, "merge", "--abort", check=False)
            raise SessionError("conflict", "merging would conflict; nothing was changed",
                               detail=(m.stdout + m.stderr).strip()[-600:])
        result["commit"] = git(main, "rev-parse", "HEAD").stdout.strip()
        if live:
            tmux("kill-window", "-t", live["window"], check=False)
        git(main, "worktree", "remove", wt["path"], check=False)
        if not keep_branch:
            git(main, "branch", "-d", wt["branch"], check=False)
        result["removed"] = not Path(wt["path"]).exists()
    elif action == "pr":
        dirty = [ln for ln in git(Path(wt["path"]), "status", "--porcelain").stdout.splitlines() if ln.strip()]
        if dirty:
            raise SessionError("uncommitted", f"{len(dirty)} uncommitted change(s) in the worktree", count=len(dirty))
        remote = git(main, "remote", "get-url", "origin", check=False).stdout.strip()
        if not remote:
            raise SessionError("no_remote", "the repository has no origin remote")
        push = git(Path(wt["path"]), "push", "-u", "origin", wt["branch"], check=False, timeout=300)
        if push.returncode != 0:
            raise SessionError("push", "git push failed", detail=(push.stderr or push.stdout).strip()[-600:])
        gh = shutil.which("gh")
        url = None
        if gh:
            try:
                p = subprocess.run([gh, "pr", "create", "--fill", "--head", wt["branch"], "--base", wt["base"]],
                                   cwd=wt["path"], capture_output=True, text=True, timeout=120, stdin=subprocess.DEVNULL)
                found = re.findall(r"https://\S+", p.stdout + p.stderr)
                url = found[-1] if found else None
            except (OSError, subprocess.SubprocessError):
                url = None
        result.update(pr=url, compare=None if url else _compare_url(remote, wt["base"], wt["branch"]))
    elif action == "discard":
        live = panes().get(job_id)
        if live:
            if not live["dead"]:
                stop(job_id, kill=False)
            tmux("kill-window", "-t", live["window"], check=False)
        git(main, "worktree", "remove", "--force", wt["path"], check=False)
        if not keep_branch:
            git(main, "branch", "-D", wt["branch"], check=False)
        result["removed"] = not Path(wt["path"]).exists()
    moved = []
    if action in ("merge", "pr"):
        moved = _items_in(job.get("items") or [], ("handed_off", "in_progress"))
        if moved:
            try:
                handoff.set_work(moved, "to_verify", agent=a.get("id"), job=job_id, by="app",
                                 commit=result.get("commit"), pr=result.get("pr"))
            except handoff.CliError as e:
                result["items_error"] = {"code": e.code, "message": str(e)[:300]}
                moved = []

    def done(j):
        j.setdefault("agent", {})["finish"] = {"action": action, "at": jobs.now_iso(), "result": result}
        _step(j, "finish", "done")
        if action in ("merge", "discard") and j.get("state") in ("running", "queued"):
            _set_status(j, "exited", "app")
    jobs.update(job_id, done)
    return {"ok": True, "action": action, "items": moved, **result}


def doctor() -> dict:
    import agents
    defs = agents.definitions(agents.config())
    return {"ok": True, "tmux": tmux_info(), "socket": socket_name(),
            "agents": [{"id": k, "session": agents.session_spec(d) is not None,
                        "hooks": (agents.session_spec(d) or {}).get("hooks"),
                        "installed": agents.find_bin(d) is not None} for k, d in defs.items()]}


# ------------------------------------------------------------------ CLI
def emit(obj: dict) -> None:
    print(json.dumps(obj, ensure_ascii=False), flush=True)


def fail(code: str, msg: str, exit_code: int = 1, **extra):
    emit({"ok": False, "error": msg, "code": code, **extra})
    print(f"ERROR: {msg}", file=sys.stderr, flush=True)
    sys.exit(exit_code)


class _Parser(argparse.ArgumentParser):
    def error(self, message):
        fail("bad_args", message)


def main(argv: list[str] | None = None) -> None:
    argv = sys.argv[1:] if argv is None else argv
    if argv[:1] == ["hook"]:  # fast path: no argparse surprises, nothing on stdout, exit 0
        opts, rest, it = {}, [], iter(argv[1:])
        for x in it:
            if x in ("--job", "--agent"):
                opts[x] = next(it, None)
            else:
                rest.append(x)
        hook(opts.get("--job"), opts.get("--agent") or "claude", rest[-1] if rest else None)
        return
    p = _Parser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True, parser_class=_Parser)
    s = sub.add_parser("dispatch")
    s.add_argument("--items", nargs="+", required=True, metavar="REF")
    s.add_argument("--agent")
    s.add_argument("--mode", choices=["together", "parallel"], default="together")
    s.add_argument("--worktree", choices=["on", "off", "auto"], default="auto")
    s.add_argument("--runner", choices=["tmux", "app", "auto"], default="auto")
    s.add_argument("--dry-run", action="store_true")
    s.add_argument("--lang", choices=["en", "zh", "zh-Hans"])
    s = sub.add_parser("list")
    s.add_argument("--project")
    s.add_argument("--all", action="store_true")
    s = sub.add_parser("attach-cmd")
    s.add_argument("job")
    s = sub.add_parser("open-external")
    s.add_argument("job")
    s.add_argument("--terminal", choices=("auto", *TERMINALS), default="auto")
    s = sub.add_parser("send")
    s.add_argument("job")
    s.add_argument("--text", required=True)
    s.add_argument("--enter", action="store_true")
    s.add_argument("--after", type=float, default=0, help=argparse.SUPPRESS)
    s = sub.add_parser("stop")
    s.add_argument("job")
    s.add_argument("--kill", action="store_true")
    s = sub.add_parser("finish")
    s.add_argument("job")
    s.add_argument("--action", required=True, choices=["diff", "merge", "pr", "discard", "keep"])
    s.add_argument("--keep-branch", action="store_true")
    s = sub.add_parser("event")
    s.add_argument("--job", required=True)
    s.add_argument("--event", required=True)
    s.add_argument("--exit", type=int)
    s = sub.add_parser("monitor")
    s.add_argument("--once", action="store_true")
    s.add_argument("--interval", type=float, default=1.0)
    s.add_argument("--job", action="append")
    sub.add_parser("doctor")
    a = p.parse_args(argv)
    try:
        if a.cmd == "dispatch":
            emit(dispatch(a.items, a.agent, a.mode, a.worktree, a.runner, a.dry_run, a.lang))
        elif a.cmd == "list":
            emit(list_sessions(a.project, a.all))
        elif a.cmd == "attach-cmd":
            emit(attach_cmd(a.job))
        elif a.cmd == "open-external":
            emit(open_external(a.job, a.terminal))
        elif a.cmd == "send":
            emit(send(a.job, a.text, a.enter, a.after))
        elif a.cmd == "stop":
            emit(stop(a.job, a.kill))
        elif a.cmd == "finish":
            emit(finish(a.job, a.action, a.keep_branch))
        elif a.cmd == "event":
            emit(app_event(a.job, a.event, a.exit))
        elif a.cmd == "monitor":
            emit(monitor(a.once, a.interval, a.job))
        elif a.cmd == "doctor":
            emit(doctor())
    except SessionError as e:
        fail(e.code, str(e), e.exit_code, **e.extra)
    except jobs.JobError as e:
        fail(e.code, str(e), 3 if e.code == "locked" else 1)


if __name__ == "__main__":
    main()
