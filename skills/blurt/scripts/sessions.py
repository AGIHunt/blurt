# /// script
# requires-python = ">=3.10"
# ///
"""Agent sessions (contract K5): Claude Code, Codex… running interactively on some items, in tmux on Blurt's own
socket (one tmux session per project, one window per dispatch), or in the app's own pty when there is no tmux.

  sessions.py dispatch --items REF … [--agent ID] [--mode together|parallel] [--worktree on|off|auto]
                       [--runner tmux|app|auto] [--dry-run] [--lang en|zh] [--model M]
                       --model: the agent's model (agents.py models ID), passed with its model_args; omitted /
                       "default" = whatever the CLI is set to
  sessions.py list [--project ID] [--all]
  sessions.py attach-cmd JOB                 → {"ok","argv","env"}: a grouped view on the job's window
  sessions.py open-external JOB [--terminal auto|terminal|iterm|ghostty|wezterm|kitty|gnome-terminal|konsole|wt]
  sessions.py send JOB --text T [--enter]
  sessions.py stop JOB [--kill]
  sessions.py finish JOB --action diff|merge|pr|discard|keep [--keep-branch]
                       merge / pr commit what the agent left uncommitted in its worktree first ("Commit and Merge":
                       a sandboxed agent can't commit there); discard takes the items back to To Do
  sessions.py restart JOB                    the same items, agent and model in a fresh session (the old one ended
                                             without changes: its window, worktree and branch go)
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
TAIL_LINES = 15  # what a dead window last showed, kept on the job (agent.last_output) and shown by the app
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
    # focus-events off: the ESC[I an attaching terminal sends was the only input reaching an agent while it starts
    # (Codex drains its input then, and timed out on it); escape-time 50: an Esc and the key after it stay apart.
    # default-size 80x24: a window starts small and grows when the app's terminal attaches — starting at 200x50 and
    # shrinking to the pane pushed the agent's last lines into history, where the app's terminal doesn't show them.
    # remain-on-exit keeps a dead window readable; the empty format (tmux ≥ 3.3) drops tmux's "Pane is dead" line —
    # the app says how the session ended.
    lines = ["# Written by Blurt (sessions.py) for its own tmux socket; changes are overwritten.",
             "set -g status off", "set -g mouse on", "set -g history-limit 50000", "set -s escape-time 50",
             "set -g focus-events off", "set -s set-clipboard on", "set -s extended-keys on",
             f'set -g default-terminal "{term}"', "set -g default-size 80x24", "set -g remain-on-exit on",
             "set -g allow-rename off", "setw -g automatic-rename off", "set -g renumber-windows off"]
    v = tuple(int(x) for x in ((tmux_info() or {}).get("version") or "0.0").split("."))
    if v >= (3, 3):
        lines.append('set -g remain-on-exit-format ""')
    text = "\n".join(lines + [""])
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


def git(cwd: Path, *args: str, check: bool = True, timeout: float = 120,
        env_extra: dict | None = None) -> subprocess.CompletedProcess:
    env = {k: v for k, v in os.environ.items() if k not in _GIT_LOCATION}  # e.g. called from inside a git hook
    env["GIT_TERMINAL_PROMPT"] = "0"
    env.update(env_extra or {})
    try:
        p = subprocess.run(["git", "-C", str(cwd), *args], capture_output=True, text=True, encoding="utf-8",
                           errors="replace", env=env, timeout=timeout, stdin=subprocess.DEVNULL)
    except (OSError, subprocess.SubprocessError) as e:
        raise SessionError("git", f"git {args[0]}: {e}") from None
    if check and p.returncode != 0:
        raise SessionError("git", f"git {' '.join(args[:2])}: {(p.stderr or p.stdout).strip()[-400:]}")
    return p


def add_worktree(root: Path, branch: str, path: str, base_sha: str) -> None:
    """`git worktree add` that a broken Git LFS remote can't stop: the checkout skips LFS downloads (files stay as
    pointers), then `git lfs pull` fills them in the background, best effort. A plain checkout would fail outright
    when one LFS object is missing on the server ("Object does not exist on the server")."""
    try:
        git(root, "worktree", "add", "-b", branch, path, base_sha, env_extra={"GIT_LFS_SKIP_SMUDGE": "1"})
    except SessionError:
        # leave nothing half-made behind: the directory and the new branch
        git(root, "worktree", "remove", "--force", path, check=False)
        git(root, "branch", "-D", branch, check=False)
        raise
    attrs = Path(path) / ".gitattributes"
    if shutil.which("git-lfs") and attrs.exists() and "filter=lfs" in attrs.read_text(errors="replace"):
        try:
            subprocess.Popen(["git", "-C", path, "lfs", "pull"], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL, start_new_session=True,
                             env={**{k: v for k, v in os.environ.items() if k not in _GIT_LOCATION},
                                  "GIT_TERMINAL_PROMPT": "0"})
        except OSError:
            pass


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
        if it.get("state") in states:
            out.append(u)
    return out


def _advance_items(job: dict, running: bool) -> None:
    """K3 for a session: first running → handed_off items become in_progress (once per job: agent.started). An
    exit moves nothing: only the agent says an item is done (items.py state --state to_verify --claim …, MCP
    mark_fixed), so one that exited or crashed without saying so leaves its items in progress and the app says the
    session ended without reporting back (agent.closed marks that the exit was seen). running = the agent is known to
    be up (a hook or the terminal said so, or it has no hooks and its window is alive)."""
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
            a["closed"] = True
            wt = a.get("worktree")
            if wt and Path(wt.get("path") or "").is_dir():
                a["changes"] = changes(wt)  # "Ready to review" only when there is something to review
    except handoff.CliError as e:
        a["items_error"] = {"code": e.code, "message": str(e)[:300]}


def changes(wt: dict) -> dict:
    """What a worktree session left: commits on its branch since it started, and uncommitted paths."""
    path = Path(wt["path"])
    ahead = git(path, "rev-list", "--count", f"{wt['base_sha']}..HEAD", check=False).stdout.strip()
    dirty = [ln for ln in git(path, "status", "--porcelain", check=False).stdout.splitlines() if ln.strip()]
    return {"ahead": int(ahead) if ahead.isdigit() else 0, "dirty": len(dirty)}


def pane_tail(pane: str, n: int = TAIL_LINES) -> list[str]:
    """The last non-empty lines a window shows (its history included): what an agent said before it exited."""
    p = tmux("capture-pane", "-p", "-J", "-S", "-200", "-t", pane, check=False)
    lines = [ln.rstrip() for ln in (p.stdout if p.returncode == 0 else "").splitlines()]
    return [ln for ln in lines if ln.strip() and not ln.startswith("Pane is dead (")][-n:]


def exit_error(tail: list[str], exit_code: int | None) -> dict:
    """job.error of an agent that ended with a non-zero exit (or can't start): the class its last words fit (login,
    quota…), else agent_exit; the message is its last line, the detail the tail."""
    import agents
    text = "\n".join(tail)
    cls = agents.classify(text)
    last = next((ln.strip() for ln in reversed(tail) if ln.strip()), "")
    return {"code": cls if cls in jobs.ERROR_CODES else "agent_exit",
            "message": (last or f"exit {exit_code}")[:300], "hint_key": None, "detail": text[-2000:] or None}


def _hooks_kind(a: dict) -> str | None:
    import agents
    defn = agents.definitions(agents.config(a.get("cwd"))).get(a.get("id")) or {}
    return (agents.session_spec(defn) or {}).get("hooks")


def _tty_fallback(job: dict, w: dict, now: float) -> None:
    """Status from the terminal, for agents whose hooks aren't reporting (K5). Claude Code's hooks report everything
    once they are live, but none fires before its workspace-trust dialog is answered, nor when it refuses to start
    ("Not logged in · Please run /login"): until its first hook, its window is read like any other."""
    import agents
    a = job["agent"]
    defn = agents.definitions(agents.config(a.get("cwd"))).get(a.get("id")) or {}
    hooks = (agents.session_spec(defn) or {}).get("hooks")
    if hooks == "claude" and a.get("hooks_live"):
        return
    # Codex's hooks report turns and command approvals, not the questions its tools ask (an MCP tool's "Allow
    # Browser use to access …?" elicitation): those still come from the terminal while its hooks are live
    patterns = agents.waiting_patterns(defn)
    errors = [] if a.get("hooks_live") else agents.error_patterns(defn)
    since = jobs.parse_iso(a.get("status_at")) or 0
    text = ""
    if patterns or errors:
        p = tmux("capture-pane", "-p", "-J", "-S", "-15", "-t", w["pane"], check=False)
        lines = [ln for ln in (p.stdout if p.returncode == 0 else "").splitlines() if ln.strip()]
        text = "\n".join(lines[-TTY_BOTTOM:])  # a prompt that has scrolled up was answered
    bad = next((ln for ln in text.splitlines() if any(re.search(pat, ln, re.I) for pat in errors)), None)
    if bad:  # it can't work: an error in its own words, never "Running" for good (the window stays open to read)
        a["last_output"] = text.splitlines()[-TAIL_LINES:]
        if a.get("status") != "error":
            _set_status(job, "error", "tty")
            job["error"] = {**exit_error([bad.strip()], None), "detail": text[-2000:]}
        return
    hit = any(re.search(pat, text, re.I | re.M) for pat in patterns) if text else False
    if hit and hooks and a.get("hooks_live") and a.get("status_source") != "tty" and w["activity"] <= since:
        hit = False  # drawn before the hooks' latest word (an approval they already reported): not a new question
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
                other = (a.get("tmux") or {}).get("socket") not in (None, socket_name())
                if a.get("runner") == "tmux" and not other:  # a job on another tmux server isn't ours to judge
                    if w is None:
                        # the window was closed — once there was one: dispatch writes the job before the worktree
                        # and the window exist (agent.tmux stays null until then)
                        if active and a.get("tmux") and tmux_info():
                            _set_status(job, "exited", "tmux")
                    elif w["dead"]:
                        if active or a.get("exit") is None:
                            # what it said last stays on the job: the app shows it, and it is a failure's reason
                            if "last_output" not in a:
                                a["last_output"] = pane_tail(w["pane"])
                            failed = (w["exit"] or 0) != 0
                            _set_status(job, "error" if failed else "exited", "tmux", w["exit"])
                            if failed and not job.get("error"):
                                job["error"] = exit_error(a["last_output"], w["exit"])
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


def _pid_alive(pid: int) -> bool:
    if os.name == "nt":
        import ctypes  # noqa: PLC0415
        k = ctypes.windll.kernel32  # type: ignore[attr-defined]
        h = k.OpenProcess(0x1000, False, pid)  # PROCESS_QUERY_LIMITED_INFORMATION
        if not h:
            return False
        code = ctypes.c_ulong()
        ok = k.GetExitCodeProcess(h, ctypes.byref(code))
        k.CloseHandle(h)
        return bool(ok) and code.value == 259  # STILL_ACTIVE
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def monitor(once: bool, interval: float, only: list[str] | None = None, parent: int | None = None) -> dict:
    """`parent`: the app's pid — the resident monitor ends with it (a crash, a kill, an update), so it never outlives
    the app holding the lock with old code."""
    if once:
        return {"ok": True, "changed": [j["id"] for j in sync(only)]}
    run = jobs.home() / "run"
    try:
        with jobs.file_lock(run / "monitor.lock", timeout=0.2):
            while parent is None or _pid_alive(parent):
                sync(only)
                time.sleep(interval)
            return {"ok": True, "parent_gone": parent}
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
    gone = [i["uid"] for i in items if i.get("state") == "discarded"]
    if gone:
        raise SessionError("deleted", "discarded items can't be handed to an agent", items=gone)
    busy = [i["uid"] for i in items if i.get("state") not in ("new", "todo", "handed_off")]
    if busy:
        raise SessionError("bad_transition", "some items are already being worked on or done — reopen them first",
                           items=busy)
    wins = panes()
    for i in items:  # handed off to a session that is still going (an agent at its first prompt): not a second time
        jid = (i.get("work") or {}).get("job") if i.get("state") == "handed_off" else None
        try:
            other = jobs.get(jid) if jid else None
        except jobs.JobError:
            other = None
        if other and other.get("type") == "agent" and other.get("state") in ("running", "queued") and is_alive(other, wins):
            raise SessionError("already_dispatched", f"{i.get('id') or i['uid']} is already with a session",
                               job=jid, items=[i["uid"]])
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
    direct = [j["id"] for j in agent_jobs() if j.get("project") == pid and not (j.get("agent") or {}).get("worktree")
              and is_alive(j, wins)]
    if not want_wt and (direct or len(out) > 1):
        warnings.append({"code": "concurrent_edit", "jobs": direct})
    drafts = [it["uid"] for it in items if it.get("state") == "new"]  # handing them off is keeping them
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
                 "-x", "80", "-y", "24", *e_args, "--", *argv)
    return p.stdout.strip().splitlines()[-1]


def dispatch(refs: list[str], agent: str | None = None, mode: str = "together", worktree: str = "auto",
             runner: str = "auto", dry_run: bool = False, lang: str | None = None, model: str | None = None) -> dict:
    if dry_run:
        pl = plan(refs, agent, mode, worktree, runner)
        return {"ok": True, "dry_run": True, "agent": pl["agent"], "model": model, "mode": mode, "runner": pl["runner"],
                "worktree": pl["worktree"], "jobs": [_public(e) for e in pl["jobs"]], "warnings": pl["warnings"]}
    # one dispatch at a time, from the check to the items marked handed off: two clicks (or the app and an agent)
    # never start two sessions on one item
    with jobs.file_lock(jobs.home() / "run" / "dispatch.lock", timeout=60):
        return _dispatch(plan(refs, agent, mode, worktree, runner), mode, lang, model)


def _dispatch(pl: dict, mode: str, lang: str | None, model: str | None) -> dict:
    import agents
    import handoff
    project = pl["project"]
    defn = agents.definitions(agents.config(project["path"])).get(pl["agent"]) or {}
    sandboxed = bool((agents.session_spec(defn) or {}).get("sandboxed"))
    mcp = None
    out_jobs, launch = [], []
    warnings = list(pl["warnings"])
    for e in pl["jobs"]:
        jid = jobs.new_id()
        agent_obj = {"id": pl["agent"], "model": model, "mode": mode, "runner": pl["runner"], "tmux": None, "cwd": e["cwd"],
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
                add_worktree(root, e["branch"], e["worktree"], base_sha)
                agent_obj["worktree"] = {"path": e["worktree"], "branch": e["branch"], "base": base_branch,
                                         "base_sha": base_sha, "repo": str(root)}
            elif pl["root"]:
                agent_obj["base_sha"] = git(Path(pl["root"]), "rev-parse", "HEAD", check=False).stdout.strip() or None
            pr = agents.prompt_work([], "session", bool(e.get("worktree")), lang=lang, branch=e.get("branch"),
                                    items=e["_items"], sandboxed=sandboxed)
            agent_obj["handoff"] = pr["handoff"]
            jobs.path(jid, ".prompt.md").write_text(pr["prompt"] + "\n", encoding="utf-8")
            if mcp is None:
                mcp = agents.mcp_installed(defn) is False
            cmd = agents.session_command(pl["agent"], pr["prompt"], e["cwd"], job=jid, mcp=mcp, model=model,
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
                agent_obj.update(status="error", status_at=jobs.now_iso(), status_source="app")  # never "running"
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
        try:  # the items: handed to this session (new ones too: handing off is keeping them, K3)
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
    ahead = changes(wt)["ahead"] if wt else 0
    return {"base": (wt or {}).get("base") or base, "branch": (wt or {}).get("branch"), "stat": stat,
            "patch": str(out), "uncommitted": uncommitted, "ahead": ahead}


def _compare_url(remote: str, base: str, branch: str) -> str | None:
    m = re.match(r"(?:git@|ssh://git@)([^:/]+)[:/](.+?)(?:\.git)?/?$", remote) or \
        re.match(r"https?://(?:[^@/]+@)?([^/]+)/(.+?)(?:\.git)?/?$", remote)
    if not m:
        return None
    return f"https://{m.group(1)}/{m.group(2)}/compare/{base}...{branch}?expand=1"


def commit_message(job: dict) -> str:
    """"BA-12 Login button does nothing (Blurt hand-off)"; several items: their ids, then the first title."""
    import handoff
    labels = []
    for u in job.get("items") or []:
        try:
            it = handoff.item(u)
        except handoff.CliError:
            continue
        labels.append((it.get("id") or u[:8], (it.get("title") or "").strip()))
    if not labels:
        return f"{job.get('title') or 'Agent session'} (Blurt hand-off)"
    ids = ", ".join(i for i, _ in labels[:4]) + (f" +{len(labels) - 4}" if len(labels) > 4 else "")
    title = labels[0][1] if len(labels) == 1 else ""
    return " ".join(x for x in (ids, title, "(Blurt hand-off)") if x)[:200]


def _commit_left_over(job: dict, wt: dict) -> str | None:
    """Commit what the agent left uncommitted on its own branch (a sandboxed agent can't commit in a linked worktree:
    its index lives in the repository's .git, outside the sandbox). Runs here, outside any sandbox; the user's git
    hooks apply. → the new commit, or None when there was nothing to commit."""
    path = Path(wt["path"])
    if not [ln for ln in git(path, "status", "--porcelain").stdout.splitlines() if ln.strip()]:
        return None
    git(path, "add", "-A")
    c = git(path, "commit", "-q", "-m", commit_message(job), check=False)
    if c.returncode != 0:
        raise SessionError("commit", "committing the session's changes failed",
                           detail=(c.stderr or c.stdout).strip()[-600:])
    return git(path, "rev-parse", "HEAD").stdout.strip()


def _take_back(job_id: str, uids: list[str]) -> list[str]:
    """The user gave up on this session (discard, restart): its items still with it go back to To Do. Items handed
    to another session since are left alone."""
    import handoff
    mine = []
    for u in uids:
        try:
            it = handoff.item(u)
        except handoff.CliError:
            continue
        if it.get("state") in ("handed_off", "in_progress") and (it.get("work") or {}).get("job") == job_id:
            mine.append(u)
    if mine:
        handoff.set_work(mine, "todo", by="user")
    return mine


def finish(job_id: str, action: str, keep_branch: bool = False) -> dict:
    import handoff
    job = _job(job_id)
    a = job.get("agent") or {}
    wt = a.get("worktree")
    if action == "diff":
        res = diff(job)
        if wt:  # the sheet and the session list agree on whether there is anything to review
            jobs.update(job_id, lambda j: j.setdefault("agent", {}).update(
                changes={"ahead": res["ahead"], "dirty": res["uncommitted"]}))
        return {"ok": True, **res}
    if action != "keep" and not wt:
        raise SessionError("no_worktree", "this session worked in the project folder directly — nothing to "
                                          f"{action}")
    result: dict = {}
    main = Path(wt["repo"]) if wt else None
    if action in ("merge", "pr") and not Path(wt["path"]).is_dir():
        raise SessionError("gone", "the worktree is gone")
    live = panes().get(job_id)
    if action in ("merge", "pr"):
        if live and not live["dead"]:
            raise SessionError("running", "the agent is still running in this worktree — stop it first")
        ch = changes(wt)
        if ch["ahead"] == 0 and ch["dirty"] == 0:
            raise SessionError("nothing", "the session's branch has no changes")
    if action == "merge":
        head = git(main, "rev-parse", "--abbrev-ref", "HEAD").stdout.strip()
        if head != wt["base"]:
            raise SessionError("wrong_branch", f"the project folder is on {head}, not {wt['base']}", branch=head)
        if [ln for ln in git(main, "status", "--porcelain", "--untracked-files=no").stdout.splitlines() if ln.strip()]:
            raise SessionError("dirty", "the project folder has uncommitted changes")
        result["committed"] = _commit_left_over(job, wt)
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
        remote = git(main, "remote", "get-url", "origin", check=False).stdout.strip()
        if not remote:
            raise SessionError("no_remote", "the repository has no origin remote")
        result["committed"] = _commit_left_over(job, wt)
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
    elif action == "discard":  # nothing of it is left: its items are To Do again, not "in progress" for good
        try:
            result["taken_back"] = _take_back(job_id, job.get("items") or [])
        except handoff.CliError as e:
            result["items_error"] = {"code": e.code, "message": str(e)[:300]}

    def done(j):
        j.setdefault("agent", {})["finish"] = {"action": action, "at": jobs.now_iso(), "result": result}
        _step(j, "finish", "done")
        if action in ("merge", "discard") and j.get("state") in ("running", "queued"):
            _set_status(j, "exited", "app")
    jobs.update(job_id, done)
    return {"ok": True, "action": action, "items": moved, **result}


def restart(job_id: str, lang: str | None = None) -> dict:
    """Start the session again: the same items, agent, model and worktree choice, in a fresh window (and worktree).
    For a session that ended without changes — it failed to start, or stopped at once; one that left changes is
    reviewed first (code has_changes). The old one's window, worktree and branch go; its items go back to To Do and
    straight on to the new session."""
    import handoff
    job = _job(job_id)
    a = job.get("agent") or {}
    wins = panes()
    if job.get("state") in ("running", "queued") and is_alive(job, wins) and a.get("status") != "error":
        raise SessionError("running", "the session is still running — stop it first")
    wt = a.get("worktree")
    if wt and Path(wt.get("path") or "").is_dir():
        ch = changes(wt)
        if ch["ahead"] or ch["dirty"]:
            raise SessionError("has_changes", "the session left changes — review them first", **ch)
    try:
        _take_back(job_id, job.get("items") or [])
    except handoff.CliError as e:
        raise SessionError(e.code, str(e)) from None
    w = wins.get(job_id)
    if w:
        tmux("kill-window", "-t", w["window"], check=False)
    if wt:
        root = Path(wt["repo"])
        git(root, "worktree", "remove", "--force", wt["path"], check=False)
        git(root, "branch", "-D", wt["branch"], check=False)
    again = _items_in(job.get("items") or [], ("new", "todo"))
    if not again:
        raise SessionError("nothing", "the session's items have moved on")

    def ended(j):
        if j.get("state") in ("running", "queued"):
            _set_status(j, "exited", "app")
            j["state"] = "cancelled"
        j.setdefault("agent", {})["finish"] = {"action": "restart", "at": jobs.now_iso(), "result": {}}
    jobs.update(job_id, ended)
    out = dispatch(again, agent=a.get("id"), mode="together", worktree="on" if wt else "off",
                   runner=a.get("runner") or "auto", lang=lang, model=a.get("model"))
    new = [r["id"] for r in out.get("jobs", [])]
    jobs.update(job_id, lambda j: j["agent"]["finish"]["result"].update(jobs=new))
    return {**out, "restarted": job_id}


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
    s.add_argument("--model", help="the agent's model (agents.py models ID); default = the CLI's own setting")
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
    s = sub.add_parser("restart")
    s.add_argument("job")
    s.add_argument("--lang", choices=["en", "zh", "zh-Hans"])
    s = sub.add_parser("event")
    s.add_argument("--job", required=True)
    s.add_argument("--event", required=True)
    s.add_argument("--exit", type=int)
    s = sub.add_parser("monitor")
    s.add_argument("--once", action="store_true")
    s.add_argument("--interval", type=float, default=1.0)
    s.add_argument("--job", action="append")
    s.add_argument("--parent", type=int, help="exit when this process (the app) is gone")
    sub.add_parser("doctor")
    a = p.parse_args(argv)
    try:
        if a.cmd == "dispatch":
            emit(dispatch(a.items, a.agent, a.mode, a.worktree, a.runner, a.dry_run, a.lang,
                          None if a.model in (None, "", "default") else a.model))
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
        elif a.cmd == "restart":
            emit(restart(a.job, a.lang))
        elif a.cmd == "event":
            emit(app_event(a.job, a.event, a.exit))
        elif a.cmd == "monitor":
            emit(monitor(a.once, a.interval, a.job, a.parent))
        elif a.cmd == "doctor":
            emit(doctor())
    except SessionError as e:
        fail(e.code, str(e), e.exit_code, **e.extra)
    except jobs.JobError as e:
        fail(e.code, str(e), 3 if e.code == "locked" else 1)


if __name__ == "__main__":
    main()
