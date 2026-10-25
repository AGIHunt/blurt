"""sessions.py (K5) when a hand-off goes wrong — the v0.9 dogfood findings: an agent that dies at startup, Claude Code
at its trust dialog or logged out, a second dispatch of the same item, a sandboxed agent that can't commit, an empty
branch, and the way back (restart, take back). Real tmux on a private socket, the fake agents of p2_env.

  uv run --with pytest pytest tests/test_sessions_recovery.py -q
"""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from p2_env import needs_tmux, p2  # noqa: E402,F401

pytestmark = needs_tmux


def dispatch(p2, *refs, ok=True, **opts):
    args = ["dispatch", "--items", *refs]
    for k, v in opts.items():
        args += [f"--{k.replace('_', '-')}"] + ([] if v is True else [v])
    return p2.run("sessions.py", *args, ok=ok)


def test_an_agent_that_dies_at_startup_says_why_and_can_start_again(p2):
    """Codex died at startup ("timed out discarding buffered terminal input"): the window showed only tmux's "Pane is
    dead", the job had no reason, and nothing offered to start again."""
    flag = p2.tmp / "early"
    flag.write_text("timed out discarding buffered terminal input")
    p2.env["FAKE_EARLY_FILE"] = str(flag)
    proj = p2.project(p2.repo())
    it = p2.item(proj["id"])
    j = dispatch(p2, it["uid"], agent="codex")["jobs"][0]
    jid = j["id"]
    assert "check_for_update_on_startup=false" in p2.tmux("list-panes", "-a", "-F", "#{pane_start_command}")
    p2.wait(lambda: p2.status(jid) == "error", what="error")
    job = p2.wait(lambda: (lambda x: x if x.get("error") and x["agent"].get("closed") else None)(p2.job(jid)),
                  what="the reason")
    assert job["state"] == "failed" and job["error"]["code"] == "agent_exit"
    assert job["error"]["message"] == "Error: timed out discarding buffered terminal input"
    assert job["agent"]["last_output"][-1] == job["error"]["message"]
    assert not any("Pane is dead" in ln for ln in job["agent"]["last_output"])
    assert job["agent"]["changes"] == {"ahead": 0, "dirty": 0}  # nothing to review
    assert p2.get(it["uid"])["state"] == "handed_off"
    flag.unlink()  # the next start works
    out = p2.run("sessions.py", "restart", jid)
    (new,) = out["jobs"]
    assert out["restarted"] == jid and new["id"] != jid and new["branch"] == j["branch"]  # the old branch went first
    old = p2.job(jid)
    assert old["agent"]["finish"]["action"] == "restart" and old["agent"]["finish"]["result"]["jobs"] == [new["id"]]
    item = p2.get(it["uid"])
    assert item["state"] == "handed_off" and item["work"]["job"] == new["id"]
    p2.wait(lambda: p2.status(new["id"]) == "waiting_input", what="the new session runs")


def test_restart_refuses_a_session_that_left_changes(p2):
    proj = p2.project(p2.repo())
    it = p2.item(proj["id"])
    j = dispatch(p2, it["uid"], agent="claude")["jobs"][0]
    (Path(j["worktree"]) / "notes.md").write_text("draft\n")
    p2.run("sessions.py", "stop", j["id"], "--kill")
    out = p2.run("sessions.py", "restart", j["id"], ok=False)
    assert out["code"] == "has_changes" and out["dirty"] == 1 and Path(j["worktree"]).exists()


def test_claude_at_its_trust_prompt_needs_you(p2):
    """Claude Code fires no hook before its workspace-trust dialog is answered: the session said Running while it
    waited for the user."""
    p2.env["FAKE_TRUST"] = "1"
    proj = p2.project(p2.repo(), worktree=False)
    it = p2.item(proj["id"])
    jid = dispatch(p2, it["uid"], agent="claude")["jobs"][0]["id"]
    p2.wait(lambda: p2.status(jid) == "waiting_input" and p2.job(jid)["agent"]["status_source"] == "tty",
            what="the trust dialog, from the terminal")
    p2.type(jid)  # trusted: the hooks take over
    p2.wait(lambda: p2.job(jid)["agent"].get("status_source") == "hook", what="hooks")
    p2.wait(lambda: p2.status(jid) == "waiting_input", what="the permission prompt")


def test_claude_not_logged_in_is_an_error_not_running(p2):
    """A logged-out Claude Code showed 'Not logged in · Please run /login' and the session said Running for good."""
    p2.env["FAKE_LOGGED_OUT"] = "1"
    proj = p2.project(p2.repo(), worktree=False)
    it = p2.item(proj["id"])
    jid = dispatch(p2, it["uid"], agent="claude")["jobs"][0]["id"]
    p2.wait(lambda: p2.status(jid) == "error", what="error")
    j = p2.job(jid)
    assert j["state"] == "failed" and j["error"]["code"] == "auth"
    assert j["error"]["message"] == "Not logged in · Please run /login"
    assert p2.tmux("list-panes", "-a", "-F", "#{pane_dead}").strip() == "0"  # its window stays open to read
    # and it can be started again once the user has logged in
    p2.env.pop("FAKE_LOGGED_OUT")
    p2.tmux("kill-server")  # the fake reads its env from the tmux server's
    new = p2.run("sessions.py", "restart", jid)["jobs"][0]["id"]
    p2.wait(lambda: p2.status(new) == "waiting_input", what="the new session runs")


def test_the_same_item_is_not_dispatched_twice(p2):
    proj = p2.project(p2.repo(), worktree=False)
    it = p2.item(proj["id"])
    # the app runner: nothing reports before the app starts it, so the item stays handed off (as at a trust prompt)
    first = dispatch(p2, it["uid"], agent="claude", runner="app")["launch"][0]["job"]
    assert p2.get(it["uid"])["state"] == "handed_off"
    again = dispatch(p2, it["uid"], agent="claude", runner="app", ok=False)
    assert again["code"] == "already_dispatched" and again["job"] == first
    assert len(p2.run("jobs.py", "list")["jobs"]) == 1
    # once that session is over, the item can be handed off again
    p2.run("sessions.py", "event", "--job", first, "--event", "pane-dead", "--exit", "1")
    assert dispatch(p2, it["uid"], agent="claude", runner="app")["launch"]


def test_a_sandboxed_agent_leaves_changes_and_merge_commits_them(p2):
    """Codex can't commit in a linked worktree (its index is in the repository's .git, outside the sandbox), so
    every hand-off stopped at an approval prompt and Merge refused the uncommitted work."""
    repo = p2.repo()
    proj = p2.project(repo)
    it = p2.item(proj["id"], title="Make the login button blue")
    j = dispatch(p2, it["uid"], agent="codex", lang="en")["jobs"][0]
    note = (p2.home / "handoff" / f"{p2.job(j['id'])['agent']['handoff']}.md").read_text()
    assert "leave your changes uncommitted" in note and "Blurt commits them" in note
    assert "leave your changes uncommitted" in (p2.home / "jobs" / f"{j['id']}.prompt.md").read_text()
    w = Path(j["worktree"])
    (w / "src" / "login.txt").write_text("button: blue\n")
    p2.run("sessions.py", "stop", j["id"], "--kill")
    d = p2.run("sessions.py", "finish", j["id"], "--action", "diff")
    assert d["uncommitted"] == 1 and d["ahead"] == 0
    m = p2.run("sessions.py", "finish", j["id"], "--action", "merge")
    assert m["committed"] and (repo / "src" / "login.txt").read_text() == "button: blue\n"
    assert p2.git(repo, "log", "-1", "--format=%s", m["committed"]) == f"{it['id']} Make the login button blue (Blurt hand-off)"
    assert p2.get(it["uid"])["state"] == "to_verify"


def test_claude_keeps_committing_in_its_worktree(p2):
    proj = p2.project(p2.repo())
    it = p2.item(proj["id"])
    j = dispatch(p2, it["uid"], agent="claude", lang="en")["jobs"][0]
    note = (p2.home / "handoff" / f"{p2.job(j['id'])['agent']['handoff']}.md").read_text()
    assert "commit your work there" in note and "uncommitted" not in note


def test_an_empty_branch_is_never_pushed_or_merged(p2):
    repo = p2.repo()
    bare = p2.tmp / "origin.git"
    subprocess.run(["git", "init", "-q", "--bare", str(bare)], check=True)
    p2.git(repo, "remote", "add", "origin", str(bare))
    proj = p2.project(repo)
    it = p2.item(proj["id"])
    j = dispatch(p2, it["uid"], agent="claude")["jobs"][0]
    assert p2.run("sessions.py", "finish", j["id"], "--action", "pr", ok=False)["code"] == "running"
    p2.run("sessions.py", "stop", j["id"])
    assert p2.run("sessions.py", "finish", j["id"], "--action", "pr", ok=False)["code"] == "nothing"
    assert p2.run("sessions.py", "finish", j["id"], "--action", "merge", ok=False)["code"] == "nothing"
    assert not subprocess.run(["git", "-C", str(bare), "branch"], capture_output=True, text=True).stdout.strip()
    assert p2.get(it["uid"])["state"] in ("handed_off", "in_progress")  # nothing claimed
