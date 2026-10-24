"""sessions.py (contract K5): real tmux on a private socket, fake agent CLIs that fire the same hooks as Claude Code
and Codex, a scratch git repo for the worktree flows.

  uv run --with pytest pytest tests/test_sessions.py -q
"""
from __future__ import annotations

import json
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from p2_env import SCRIPTS, TMUX, needs_tmux, p2  # noqa: E402,F401

pytestmark = needs_tmux


def dispatch(p2, *refs, ok=True, **opts):
    args = ["dispatch", "--items", *refs]
    for k, v in opts.items():
        args += [f"--{k.replace('_', '-')}"] + ([] if v is True else [v])
    return p2.run("sessions.py", *args, ok=ok)


def test_claude_session_walks_every_status(p2):
    repo = p2.repo()
    proj = p2.project(repo, worktree=False)
    it = p2.item(proj["id"])
    out = dispatch(p2, it["id"], agent="claude", lang="en")
    assert [w["code"] for w in out["warnings"]] == ["draft_confirmed"]
    job = out["jobs"][0]
    jid = job["id"]
    assert job["window"] == it["id"] and job["cwd"] == str(repo.resolve()) and "worktree" not in job
    # one tmux session per project, one window per dispatch, found by @blurt_job
    assert p2.tmux("list-windows", "-a", "-F", "#{session_name} #{window_name} #{@blurt_job} #{@blurt_items}").split() \
        == [f"blurt-{proj['slug']}", it["id"], jid, it["uid"]]
    item = p2.get(it["uid"])
    assert item["state"] in ("handed_off", "in_progress")  # a new item handed off is kept by that move
    assert item["work"]["to"] == "session" and item["work"]["job"] == jid and item["work"]["handoff"].startswith("H-")
    settings = json.loads((p2.home / "jobs" / f"{jid}.claude-settings.json").read_text())
    assert set(settings["hooks"]) == {"SessionStart", "UserPromptSubmit", "PostToolUse", "Notification", "Stop",
                                      "SessionEnd"}
    assert settings["hooks"]["PostToolUse"][0]["matcher"] == "*"
    assert f"hook --job {jid} --agent claude" in settings["hooks"]["Stop"][0]["hooks"][0]["command"]
    # SessionStart → running, Notification(permission_prompt) → waiting_input
    p2.wait(lambda: p2.status(jid) == "waiting_input", what="waiting_input")
    j = p2.job(jid)
    assert j["agent"]["status_source"] == "hook" and j["agent"]["agent_session_id"] == "fake-claude-1"
    assert p2.get(it["uid"])["state"] == "in_progress"  # first running
    p2.type(jid)  # approve → PostToolUse → running, then Stop → turn_done (the idle_prompt changes nothing)
    p2.wait(lambda: p2.status(jid) == "turn_done", what="turn_done")
    events = [json.loads(ln) for ln in (p2.home / "jobs" / f"{jid}.events.jsonl").read_text().splitlines()]
    assert [e["status"] for e in events] == ["running", "waiting_input", "running", "turn_done"]  # no repeats
    p2.type(jid)  # → SessionEnd → exited, pane dead with exit 0
    p2.wait(lambda: p2.status(jid) == "exited", what="exited")
    j = p2.wait(lambda: (lambda j: j if j["agent"].get("exit") == 0 else None)(p2.job(jid)), what="exit code")
    assert j["state"] == "done" and [s["state"] for s in j["steps"]] == ["done", "done", "pending"]
    item = p2.get(it["uid"])
    assert item["state"] == "to_verify" and item["work"]["claim"] in (None, "")  # exited: to_verify, claim null
    rows = p2.run("sessions.py", "list")["sessions"]
    assert [r["job"] for r in rows] == [jid] and rows[0]["status"] == "exited" and rows[0]["exit"] == 0  # window kept


def test_agent_exit_code_means_error(p2):
    p2.env["FAKE_EXIT"] = "3"
    proj = p2.project(p2.repo(), worktree=False)
    it = p2.item(proj["id"])
    jid = dispatch(p2, it["uid"], agent="claude")["jobs"][0]["id"]
    p2.wait(lambda: p2.status(jid) == "waiting_input")
    p2.type(jid)
    p2.wait(lambda: p2.status(jid) == "turn_done")
    p2.type(jid)
    p2.wait(lambda: p2.status(jid) == "error", what="error")
    j = p2.job(jid)
    assert j["state"] == "failed" and j["agent"]["exit"] == 3


def test_codex_notify_and_hooks(p2):
    proj = p2.project(p2.repo(), worktree=False)
    it = p2.item(proj["id"])
    jid = dispatch(p2, it["uid"], agent="codex")["jobs"][0]["id"]
    argv = p2.tmux("list-panes", "-a", "-F", "#{pane_start_command}")
    assert "notify=" in argv and "hooks.PermissionRequest" in argv
    p2.wait(lambda: p2.status(jid) == "waiting_input", what="PermissionRequest")
    assert p2.job(jid)["agent"]["agent_session_id"] == "fake-thread"
    p2.type(jid)
    p2.wait(lambda: p2.status(jid) == "turn_done", what="Stop / notify")
    time.sleep(0.5)
    srcs = [(e["event"], e["status"]) for e in map(json.loads, (p2.home / "jobs" / f"{jid}.events.jsonl").read_text().splitlines())]
    assert srcs == [("SessionStart", "running"), ("PermissionRequest", "waiting_input"), ("PostToolUse", "running"),
                    ("Stop", "turn_done")]  # notify repeated turn_done and the side thread's notify was ignored
    p2.type(jid)
    p2.wait(lambda: p2.status(jid) == "exited")


def test_terminal_fallback_for_an_agent_without_hooks(p2):
    cfg = json.loads((p2.home / "config.json").read_text())
    cfg["record"]["agent_defs"] = {"plain": {"name": "Plain", "bins": ["plainagent"], "interactive": {
        "session": {"argv": ["{prompt}"]}, "waiting_patterns": [r"Allow this\? \[y/n\]"]}}}
    (p2.home / "config.json").write_text(json.dumps(cfg))
    proj = p2.project(p2.repo(), worktree=False)
    it = p2.item(proj["id"])
    jid = dispatch(p2, it["uid"], agent="plain")["jobs"][0]["id"]
    assert p2.status(jid) == "running"
    p2.wait(lambda: p2.status(jid) == "waiting_input", what="pattern")
    assert p2.job(jid)["agent"]["status_source"] == "tty"
    assert p2.get(it["uid"])["state"] == "in_progress"  # no hooks: an open window counts as running
    p2.type(jid, "y")
    p2.wait(lambda: p2.status(jid) == "running", what="new output")
    p2.wait(lambda: p2.status(jid) == "turn_done", timeout=20, what="8 s of quiet")
    p2.type(jid)
    p2.wait(lambda: p2.status(jid) == "exited")


def test_dry_run_warns_about_concurrent_edits(p2):
    repo = p2.repo()
    proj = p2.project(repo, worktree=False)
    a, b = p2.item(proj["id"]), p2.item(proj["id"], title="Second")
    first = dispatch(p2, a["uid"], agent="claude")["jobs"][0]["id"]
    dry = dispatch(p2, b["uid"], agent="claude", dry_run=True)
    assert dry["dry_run"] and dry["worktree"] is False
    assert {"code": "concurrent_edit", "jobs": [first]} in dry["warnings"]
    assert p2.get(b["uid"])["state"] == "new" and len(p2.run("jobs.py", "list")["jobs"]) == 1
    # with a worktree there is nothing to warn about
    wt = dispatch(p2, b["uid"], agent="claude", dry_run=True, worktree="on")
    assert not [w for w in wt["warnings"] if w["code"] == "concurrent_edit"] and wt["jobs"][0]["branch"].startswith("blurt/")
    # the warning never blocks
    second = dispatch(p2, b["uid"], agent="claude")
    assert {"code": "concurrent_edit", "jobs": [first]} in second["warnings"]
    names = p2.tmux("list-windows", "-t", f"blurt-{proj['slug']}", "-F", "#{window_name}").split()
    assert names == [a["id"], b["id"]]


def test_refusals(p2):
    proj = p2.project(p2.repo(), worktree=False)
    inbox_item = p2.run("items.py", "add", "--project", "inbox", "--json", json.dumps({"kind": "issue", "title": "x"}))
    assert dispatch(p2, inbox_item["uid"], agent="claude", ok=False)["code"] == "needs_project"
    it = p2.item(proj["id"])
    p2.run("items.py", "patch", it["uid"], "--set", "status=deleted", "--force")
    assert dispatch(p2, it["uid"], agent="claude", ok=False)["code"] == "deleted"
    assert dispatch(p2, "nope-1", agent="claude", ok=False)["_exit"] == 1
    plain = p2.tmp / "notes"
    plain.mkdir()
    proj2 = p2.project(plain)
    it2 = p2.item(proj2["id"])
    dry = dispatch(p2, it2["uid"], agent="claude", dry_run=True, worktree="on")
    assert {"code": "no_git"} in dry["warnings"] and dry["worktree"] is False


def test_parallel_worktrees_diff_merge_discard(p2):
    repo = p2.repo()
    proj = p2.project(repo)  # worktree: true is the default
    a = p2.item(proj["id"], title="Login button is grey")
    b = p2.item(proj["id"], title="登录页 typo")
    out = dispatch(p2, a["uid"], b["uid"], agent="claude", mode="parallel")
    ja, jb = out["jobs"]
    wroot = repo.parent / f".{repo.name}-worktrees"
    assert ja["worktree"] == str(wroot / a["id"]) and jb["worktree"] == str(wroot / b["id"])
    assert ja["branch"] == f"blurt/{a['id'].lower()}-login-button-is-grey" and jb["branch"] == f"blurt/{b['id'].lower()}-typo"
    assert ja["cwd"] == ja["worktree"] and Path(ja["worktree"], "src", "login.txt").exists()
    assert not [w for w in out["warnings"] if w["code"] == "concurrent_edit"]
    note = (p2.home / "handoff" / f"{p2.job(ja['id'])['agent']['handoff']}.md").read_text()
    assert ja["branch"] in note and "commit" in note
    # the agent works in A's worktree and commits; B's agent leaves an uncommitted change
    wa, wb = Path(ja["worktree"]), Path(jb["worktree"])
    (wa / "src" / "login.txt").write_text("button: blue\n")
    p2.git(wa, "commit", "-qam", "Make the login button blue")
    (wb / "notes.md").write_text("draft\n")
    for j in (ja, jb):
        p2.run("sessions.py", "stop", j["id"])
        assert p2.job(j["id"])["state"] == "cancelled"
    d = p2.run("sessions.py", "finish", ja["id"], "--action", "diff")
    assert d["branch"] == ja["branch"] and d["base"] == "main" and d["uncommitted"] == 0
    assert d["stat"] == [{"path": "src/login.txt", "added": 1, "deleted": 1}] and "button: blue" in Path(d["patch"]).read_text()
    db = p2.run("sessions.py", "finish", jb["id"], "--action", "diff")
    assert db["uncommitted"] == 1 and db["stat"][0]["path"] == "notes.md"
    assert p2.run("sessions.py", "finish", jb["id"], "--action", "merge", ok=False)["code"] == "uncommitted"
    m = p2.run("sessions.py", "finish", ja["id"], "--action", "merge")
    assert m["removed"] and not wa.exists() and (repo / "src" / "login.txt").read_text() == "button: blue\n"
    assert p2.git(repo, "log", "-1", "--format=%P").count(" ") == 1  # --no-ff: a merge commit
    assert ja["branch"] not in p2.git(repo, "branch", "--list")
    assert p2.get(a["uid"])["state"] == "to_verify" and m["items"] == []  # stopping already moved it
    disc = p2.run("sessions.py", "finish", jb["id"], "--action", "discard")
    assert disc["removed"] and not wb.exists() and jb["branch"] not in p2.git(repo, "branch", "--list")
    assert p2.git(repo, "worktree", "list").count("\n") == 0
    assert p2.job(ja["id"])["agent"]["finish"]["action"] == "merge"


def test_merge_conflict_leaves_everything_as_it_was(p2):
    repo = p2.repo()
    proj = p2.project(repo)
    it = p2.item(proj["id"])
    j = dispatch(p2, it["uid"], agent="claude")["jobs"][0]
    w = Path(j["worktree"])
    (w / "src" / "login.txt").write_text("button: blue\n")
    p2.git(w, "commit", "-qam", "blue")
    (repo / "src" / "login.txt").write_text("button: red\n")
    p2.git(repo, "commit", "-qam", "red")
    head = p2.git(repo, "rev-parse", "HEAD")
    p2.run("sessions.py", "stop", j["id"], "--kill")
    out = p2.run("sessions.py", "finish", j["id"], "--action", "merge", ok=False)
    assert out["code"] == "conflict"
    assert p2.git(repo, "rev-parse", "HEAD") == head and p2.git(repo, "status", "--porcelain") == ""
    assert w.exists() and (repo / "src" / "login.txt").read_text() == "button: red\n"


def test_pr_without_gh_gives_the_compare_url(p2):
    repo = p2.repo()
    bare = p2.tmp / "origin.git"
    subprocess.run(["git", "init", "-q", "--bare", str(bare)], check=True)
    p2.git(repo, "remote", "add", "origin", str(bare))
    proj = p2.project(repo)
    it = p2.item(proj["id"])
    j = dispatch(p2, it["uid"], agent="claude")["jobs"][0]
    w = Path(j["worktree"])
    (w / "src" / "login.txt").write_text("button: blue\n")
    p2.git(w, "commit", "-qam", "blue")
    p2.env["PATH"] = p2.env["PATH"].replace("/opt/homebrew/bin:", "")  # no gh
    p2.run("sessions.py", "stop", j["id"])
    out = p2.run("sessions.py", "finish", j["id"], "--action", "pr")
    assert out["pr"] is None and out["compare"] is None  # a local path has no web compare page
    assert j["branch"] in subprocess.run(["git", "-C", str(bare), "branch"], capture_output=True, text=True).stdout
    assert p2.get(it["uid"])["state"] == "to_verify"


def test_compare_url():
    sys.path.insert(0, str(SCRIPTS))
    import sessions
    assert sessions._compare_url("git@github.com:me/app.git", "main", "blurt/ba-1") == \
        "https://github.com/me/app/compare/main...blurt/ba-1?expand=1"
    assert sessions._compare_url("https://github.com/me/app", "main", "b") == "https://github.com/me/app/compare/main...b?expand=1"
    assert sessions.window_name(["BA-1", "BA-2", "BA-3", "BA-4", "BA-5"]) == "BA-1,BA-2,BA-3+2"
    assert sessions.ascii_slug("Login 按钮 is GREY!!") == "login-is-grey"


def test_attach_cmd_gives_each_terminal_its_own_view(p2):
    proj = p2.project(p2.repo(), worktree=False)
    a, b = p2.item(proj["id"]), p2.item(proj["id"], title="two")
    ja = dispatch(p2, a["uid"], agent="claude")["jobs"][0]["id"]
    jb = dispatch(p2, b["uid"], agent="claude")["jobs"][0]["id"]
    outer = p2.socket + "-outer"  # stands in for the embedded terminals
    try:
        for jid in (ja, jb):
            cmd = p2.run("sessions.py", "attach-cmd", jid)
            assert cmd["argv"][1:4] == ["-u", "-L", p2.socket]
            subprocess.run([TMUX, "-L", outer, "-f", "/dev/null", "new-session", "-d", "-x", "120", "-y", "30",
                            "env", "-u", "TMUX", *cmd["argv"]], check=True, env=p2.env)
        clients = p2.wait(lambda: (lambda s: s if s.count("\n") == 2 else None)(
            p2.tmux("list-clients", "-F", "#{client_session} #{window_name}")), what="two clients")
        shown = sorted(clients.split("\n")[:2])
        slug = f"blurt-{proj['slug']}"
        assert shown == [f"{slug}~1 {a['id']}", f"{slug}~2 {b['id']}"]  # each view shows its own window
        rows = {r["job"]: r for r in p2.run("sessions.py", "list")["sessions"]}
        assert rows[ja]["attached"] and rows[jb]["attached"]
        subprocess.run([TMUX, "-L", outer, "kill-server"], env=p2.env)
        p2.wait(lambda: "~" not in p2.tmux("list-sessions", "-F", "#{session_name}"), what="views gone")
        assert p2.tmux("list-sessions", "-F", "#{session_name}").split() == [slug]  # the real one stays
    finally:
        subprocess.run([TMUX, "-L", outer, "kill-server"], capture_output=True, env=p2.env)


def test_app_runner_returns_the_launch(p2):
    proj = p2.project(p2.repo(), worktree=False)
    it = p2.item(proj["id"])
    out = dispatch(p2, it["uid"], agent="claude", runner="app")
    (launch,) = out["launch"]
    jid = launch["job"]
    assert launch["argv"][0].endswith("/claude") and "--settings" in launch["argv"]
    assert launch["env"]["BLURT_JOB"] == jid and launch["env"]["BLURT_RUN_ID"] == jid
    assert launch["env"]["BLURT_PROJECT"] == proj["id"] and launch["cwd"] == str(Path(proj["path"]))
    assert p2.job(jid)["agent"]["runner"] == "app" and not p2.tmux("list-sessions")
    # the app runs it in its pty; the hooks report as usual, then the app reports the exit
    hook = [sys.executable, str(p2.scripts / "sessions.py"), "hook", "--job", jid, "--agent", "claude"]
    # quick, not instant: a fresh interpreter (~50 ms here) on a machine busy with a build can take a second; 3 s still
    # tells a hook that blocks (network, a lock) from one that returns
    subprocess.run(hook, input=json.dumps({"hook_event_name": "SessionStart", "session_id": "s"}), text=True,
                   env=p2.env, check=True)
    assert p2.status(jid) == "running"
    ev = p2.run("sessions.py", "event", "--job", jid, "--event", "pane-dead", "--exit", "0")
    assert ev["job"]["state"] == "done" and ev["job"]["agent"]["status"] == "exited"


def test_dispatch_model_reaches_the_command_line(p2):
    """The dispatch panel's model choice: the agent's own model flag before the prompt, recorded on the job."""
    proj = p2.project(p2.repo(), worktree=False)
    it = p2.item(proj["id"])
    assert dispatch(p2, it["uid"], agent="codex", runner="app", model="gpt-test-mini", dry_run=True)["model"] == "gpt-test-mini"
    (launch,) = dispatch(p2, it["uid"], agent="codex", runner="app", model="gpt-test-mini")["launch"]
    argv = launch["argv"]
    assert argv[argv.index("-m") + 1] == "gpt-test-mini" and argv.index("-m") < len(argv) - 1
    assert p2.job(launch["job"])["agent"]["model"] == "gpt-test-mini"
    it2 = p2.item(proj["id"])
    (launch,) = dispatch(p2, it2["uid"], agent="codex", runner="app", model="default")["launch"]
    assert "-m" not in launch["argv"] and p2.job(launch["job"])["agent"]["model"] is None


def test_hook_is_fast_silent_and_harmless(p2):
    proj = p2.project(p2.repo(), worktree=False)
    it = p2.item(proj["id"])
    jid = dispatch(p2, it["uid"], agent="claude", runner="app")["launch"][0]["job"]
    hook = [sys.executable, str(p2.scripts / "sessions.py"), "hook", "--job", jid, "--agent", "claude"]
    # quick, not instant: a fresh interpreter (~50 ms here) on a machine busy with a build can take a second; 3 s still
    # tells a hook that blocks (network, a lock) from one that returns
    for payload in ('{"hook_event_name": "Stop"}', "not json", "", '{"hook_event_name": "Unknown"}'):
        t = time.monotonic()
        p = subprocess.run(hook, input=payload, capture_output=True, text=True, env=p2.env, timeout=5)
        assert time.monotonic() - t < 3.0 and p.returncode == 0 and p.stdout == "", payload
    t = time.monotonic()
    p = subprocess.run([*hook[:4], "--job", "j-nope", "--agent", "codex", '{"type": "agent-turn-complete"}'],
                       capture_output=True, text=True, env=p2.env, timeout=5)
    assert time.monotonic() - t < 3.0 and p.returncode == 0 and p.stdout == ""
    log = (p2.home / "jobs" / f"{jid}.log").read_text()
    assert '"Stop"' in log


def test_doctor(p2):
    out = p2.run("sessions.py", "doctor")
    assert out["tmux"]["version"] >= "3.2" and out["socket"] == p2.socket
    rows = {a["id"]: a for a in out["agents"]}
    assert rows["claude"]["session"] and rows["claude"]["hooks"] == "claude" and rows["codex"]["hooks"] == "codex"
    assert rows["zcode"]["session"] is False
    conf = p2.home / "tmux.conf"
    proj = p2.project(p2.repo(), worktree=False)
    dispatch(p2, p2.item(proj["id"])["uid"], agent="claude")
    text = conf.read_text()
    for opt in ("status off", "mouse on", "history-limit 50000", "remain-on-exit on", "escape-time 10"):
        assert opt in text
    assert p2.tmux("show-options", "-gv", "remain-on-exit").strip() == "on"


def test_monitor_leaves_a_job_alone_until_its_window_exists(p2):
    """e2e v0.7: dispatch writes the job (running) before the worktree and the tmux window exist; the resident monitor
    saw a running job with no window, called it exited and finished it at once ("Session ended" as it started)."""
    p2.tmux("new-session", "-d", "-s", "other")  # the server is up, as it is once any session exists
    code = ("import sys; sys.path.insert(0, %r); import jobs; "
            "print(jobs.create('agent', project=None, owner='sessions.py', items=[], "
            "agent={'id': 'codex', 'mode': 'together', 'runner': 'tmux', 'tmux': None, 'status': 'running'})['id'])"
            % str(SCRIPTS))
    jid = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True, env=p2.env, check=True).stdout.strip()
    p2.run("sessions.py", "monitor", "--once")
    j = p2.job(jid)
    assert j["state"] == "running" and j["agent"]["status"] == "running"


def test_codex_tool_questions_show_as_waiting_even_with_hooks(p2):
    """e2e v0.7: Codex's hooks don't report an MCP tool's elicitation ("Allow Browser use to access …?"); with its hooks
    live the terminal wasn't looked at, so the session showed Working while it waited for the user."""
    p2.env["FAKE_ELICIT"] = "1"
    proj = p2.project(p2.repo(), worktree=False)
    it = p2.item(proj["id"])
    jid = dispatch(p2, it["uid"], agent="codex")["jobs"][0]["id"]
    p2.wait(lambda: p2.status(jid) == "waiting_input", what="PermissionRequest")
    p2.type(jid)
    p2.wait(lambda: p2.status(jid) == "waiting_input" and p2.job(jid)["agent"]["status_source"] == "tty",
            timeout=20, what="the tool's question, from the terminal")
    p2.type(jid)
    p2.wait(lambda: p2.status(jid) == "turn_done", timeout=20, what="Stop")
    p2.type(jid)
    p2.wait(lambda: p2.status(jid) == "exited")


def test_resident_monitor_ends_with_its_app(p2):
    """e2e v0.7: the app's `sessions.py monitor` outlived the app (killed, crashed or relaunched) and kept the lock,
    so a new app's monitor exited at once and the old code went on judging sessions."""
    app = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"])
    mon = subprocess.Popen([sys.executable, str(SCRIPTS / "sessions.py"), "monitor", "--interval", "0.2", "--parent",
                            str(app.pid)], stdout=subprocess.PIPE, text=True, env=p2.env)
    time.sleep(1.0)
    assert mon.poll() is None  # the app is there: it keeps watching
    app.kill(); app.wait()
    out, _ = mon.communicate(timeout=10)
    assert json.loads(out.strip().splitlines()[-1])["parent_gone"] == app.pid
