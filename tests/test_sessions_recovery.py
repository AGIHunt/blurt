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
    # people get a sentence with what to do (too old: update it), never the raw line (dogfood-2 W41)
    assert "Codex" in job["error"]["reason"] and "update" in job["error"]["reason"].lower()
    # in both languages (the app shows its own, whatever the monitor guessed), with the update command
    assert job["error"]["reason_i18n"]["en"] == job["error"]["reason"]
    assert "版本太旧" in job["error"]["reason_i18n"]["zh"] and "npm i -g @openai/codex" in job["error"]["reason_i18n"]["zh"]
    assert job["error"]["fix"] == "npm i -g @openai/codex" and job["error"]["need"] == "0.164.0"
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
    assert p2.job(jid)["agent"]["waiting_hint"] == "trust"  # the app explains this question in one line
    assert p2.get(it["uid"])["state"] == "handed_off"  # a trust question is not work: not "in progress by" it
    p2.type(jid)  # trusted: the hooks take over
    p2.wait(lambda: p2.job(jid)["agent"].get("status_source") == "hook", what="hooks")
    p2.wait(lambda: p2.status(jid) == "waiting_input", what="the permission prompt")
    assert "waiting_hint" not in p2.job(jid)["agent"] and p2.get(it["uid"])["state"] == "in_progress"


def test_quitting_at_the_trust_question_is_not_a_session_that_worked(p2):
    """Dogfood: declining Claude's folder-trust question said the agent 'didn't report back', and the item's history
    said 'In progress by Claude Code' — from an agent that never started."""
    p2.env["FAKE_TRUST"] = "1"
    proj = p2.project(p2.repo())
    it = p2.item(proj["id"])
    jid = dispatch(p2, it["uid"], agent="claude")["jobs"][0]["id"]
    p2.wait(lambda: p2.status(jid) == "waiting_input" and p2.job(jid)["agent"].get("waiting_hint") == "trust",
            what="the trust question")
    p2.type(jid, "2")  # No, exit
    j = p2.wait(lambda: (lambda x: x if x["agent"].get("closed") else None)(p2.job(jid) if p2.status(jid) else None),
                what="the exit")
    assert j["agent"]["stopped_at"] == "trust" and not j["agent"].get("started")
    item = p2.get(it["uid"])
    assert item["state"] == "handed_off" and item["work"]["job"] == jid  # never "in progress by Claude Code"
    new = p2.run("sessions.py", "restart", jid)["jobs"][0]["id"]  # and it can simply start again
    assert p2.get(it["uid"])["work"]["job"] == new


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


def test_an_item_left_in_progress_by_an_ended_session_can_go_again(p2):
    """dogfood-2 W33: after "<Agent> couldn't start" or "the agent never reported", the item stays in progress (by
    design). Handing it off again said bad_transition, raw, with Start still enabled: now the ended session gives it
    back (history says so) and the new one takes it. Done items still ask to be reopened; a live session still wins."""
    p2.env["FAKE_EXIT"] = "3"
    proj = p2.project(p2.repo(), worktree=False)
    it = p2.item(proj["id"])
    first = dispatch(p2, it["uid"], agent="claude")["jobs"][0]["id"]
    p2.wait(lambda: p2.status(first) == "waiting_input")
    p2.type(first)
    p2.wait(lambda: p2.status(first) == "turn_done")
    # still going: not a second time, and the refusal names the item (the app's sentence uses it)
    busy = dispatch(p2, it["uid"], agent="claude", ok=False)
    assert busy["code"] == "already_dispatched" and busy["job"] == first and busy["id"] == it["id"]
    p2.type(first)
    p2.wait(lambda: p2.status(first) == "error", what="error")
    assert p2.get(it["uid"])["state"] == "in_progress"
    p2.env.pop("FAKE_EXIT")
    dry = dispatch(p2, it["uid"], agent="claude", dry_run=True)
    assert {"code": "taken_back", "items": [it["uid"]]} in dry["warnings"]
    assert p2.get(it["uid"])["state"] == "in_progress"            # a dry run changes nothing
    second = dispatch(p2, it["uid"], agent="claude")["jobs"][0]["id"]
    item = p2.get(it["uid"])
    assert item["state"] == "handed_off" and item["work"]["job"] == second
    assert [h.get("state") for h in item.get("work_history", [])][-2:] == ["in_progress", "todo"]  # given back, then on
    # done: reopen first
    p2.run("items.py", "state", it["uid"], "--state", "done", "--by", "user")
    assert dispatch(p2, it["uid"], agent="claude", ok=False)["code"] == "bad_transition"


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


def test_a_second_restart_of_the_same_session_touches_nothing(p2):
    """Review: a second Restart on the old job (a double click, the card and the banner before the list refreshed)
    removed the new session's worktree and branch — the new one reuses the old path and branch name."""
    flag = p2.tmp / "early"
    flag.write_text("timed out discarding buffered terminal input")
    p2.env["FAKE_EARLY_FILE"] = str(flag)
    proj = p2.project(p2.repo())
    it = p2.item(proj["id"])
    jid = dispatch(p2, it["uid"], agent="codex")["jobs"][0]["id"]
    p2.wait(lambda: p2.status(jid) == "error" and p2.job(jid)["agent"].get("closed"), what="failed at start")
    flag.unlink()
    (new,) = p2.run("sessions.py", "restart", jid)["jobs"]
    p2.wait(lambda: p2.status(new["id"]) == "waiting_input", what="the new session runs")
    again = p2.run("sessions.py", "restart", jid, ok=False)
    assert again["code"] == "finished" and again["jobs"] == [new["id"]]
    wt = Path(new["worktree"])
    assert wt.is_dir()
    repo = Path(p2.job(new["id"])["agent"]["worktree"]["repo"])
    assert new["branch"] in subprocess.run(["git", "-C", str(repo), "branch", "--list"], capture_output=True,
                                           text=True).stdout
    item = p2.get(it["uid"])
    assert item["state"] in ("handed_off", "in_progress") and item["work"]["job"] == new["id"]
    assert p2.status(new["id"]) == "waiting_input"


def test_a_logged_out_agent_is_refused_on_every_path(p2):
    """Review: only the app's panel blocked a logged-out agent; `sessions.py dispatch` (agents, MCP) started one that
    sat at its login screen."""
    p2.env["FAKE_AUTH_OUT"] = "1"
    proj = p2.project(p2.repo(), worktree=False)
    it = p2.item(proj["id"])
    out = dispatch(p2, it["uid"], agent="claude", ok=False)
    assert out["code"] == "auth" and out["agent"] == "claude" and "fix" in out
    assert p2.get(it["uid"])["state"] in ("new", "todo")
    assert not [j for j in p2.run("sessions.py", "list", "--all")["sessions"] if it["uid"] in j.get("items", [])]
    # the caller already checked (the app's panel): --force goes ahead
    jid = dispatch(p2, it["uid"], agent="claude", force=True)["jobs"][0]["id"]
    p2.wait(lambda: p2.status(jid) == "waiting_input", what="started")


def test_an_agent_that_says_nothing_is_not_running_for_good(p2):
    """work#32: no hook and a still window — a screen nothing recognises — said Running for good. After the
    watchdog's minute (shortened here) it needs you, and Restart is a way out even though its window is open."""
    p2.env["FAKE_SILENT"] = "1"
    p2.env["BLURT_SESSION_STALL"] = "2"
    proj = p2.project(p2.repo(), worktree=False)
    it = p2.item(proj["id"])
    jid = dispatch(p2, it["uid"], agent="claude")["jobs"][0]["id"]
    p2.wait(lambda: p2.status(jid) == "waiting_input", what="no response", timeout=20)
    job = p2.job(jid)
    assert job["agent"]["status_source"] == "watchdog"
    assert any("Something new to read" in ln for ln in job["agent"]["last_output"])
    del p2.env["FAKE_SILENT"]
    (new,) = p2.run("sessions.py", "restart", jid)["jobs"]
    assert p2.job(jid)["state"] == "cancelled"
    p2.wait(lambda: p2.status(new["id"]) == "waiting_input" and p2.job(new["id"])["agent"]["status_source"] == "hook",
            what="the new one works")


def test_restart_removes_its_own_worktree_after_an_earlier_session_on_the_same_path(p2):
    """Live run: an item discarded once, handed off again (the same freed path), failed, restarted — the earlier,
    discarded job still recorded the path, so the restart left the old worktree behind and the new one became -2."""
    proj = p2.project(p2.repo())
    it = p2.item(proj["id"])
    first = dispatch(p2, it["uid"], agent="claude")["jobs"][0]
    p2.run("sessions.py", "stop", first["id"], "--kill")
    p2.run("sessions.py", "finish", first["id"], "--action", "discard")
    flag = p2.tmp / "early"
    flag.write_text("timed out discarding buffered terminal input")
    p2.env["FAKE_EARLY_FILE"] = str(flag)
    second = dispatch(p2, it["uid"], agent="codex")["jobs"][0]
    assert second["worktree"] == first["worktree"]
    p2.wait(lambda: p2.status(second["id"]) == "error" and p2.job(second["id"])["agent"].get("closed"), what="failed")
    flag.unlink()
    (new,) = p2.run("sessions.py", "restart", second["id"])["jobs"]
    assert new["worktree"] == second["worktree"] and new["branch"] == second["branch"]  # the old one went first
    assert not Path(second["worktree"] + "-2").exists()


def test_merge_lands_only_what_the_review_showed(p2):
    """Dogfood (P1): End Session and Merge committed and merged whatever the worktree held by then — edits the agent
    made after the review loaded, or a turn cut short by Ctrl-C — without showing them. The review now says whether
    the agent is still in its window and carries a token of what it showed; merge refuses anything else."""
    repo = p2.repo()
    proj = p2.project(repo)
    it = p2.item(proj["id"])
    j = dispatch(p2, it["uid"], agent="claude")["jobs"][0]
    w = Path(j["worktree"])
    (w / "reviewed.txt").write_text("seen\n")
    d = p2.run("sessions.py", "finish", j["id"], "--action", "diff")
    assert d["alive"] is True and d["reviewed"]
    p2.run("sessions.py", "stop", j["id"])
    d = p2.run("sessions.py", "finish", j["id"], "--action", "diff")
    assert d["alive"] is False and d["agent_status"] is None
    assert p2.run("sessions.py", "finish", j["id"], "--action", "diff")["reviewed"] == d["reviewed"]  # stable
    (w / "late.txt").write_text("never reviewed\n")
    out = p2.run("sessions.py", "finish", j["id"], "--action", "merge", "--expect", d["reviewed"], ok=False)
    assert out["code"] == "changed" and not (repo / "late.txt").exists() and not (repo / "reviewed.txt").exists()
    assert p2.git(w, "status", "--porcelain")  # the real index was not touched: still uncommitted, nothing staged
    assert not p2.git(w, "diff", "--cached", "--name-only")
    d2 = p2.run("sessions.py", "finish", j["id"], "--action", "diff")
    assert d2["reviewed"] != d["reviewed"]
    p2.run("sessions.py", "finish", j["id"], "--action", "merge", "--expect", d2["reviewed"])
    assert (repo / "late.txt").exists() and (repo / "reviewed.txt").exists()


def test_an_outdated_codex_is_refused_before_anything_starts(p2):
    """Dogfood: Codex 0.157 was started anyway, failed 4 s later with no version or command, and Restart repeated
    the failure. Now the panel's dry run, Start and Restart all say it is too old, with the update command."""
    p2.env["FAKE_CODEX_VERSION"] = "0.157.0"
    proj = p2.project(p2.repo())
    it = p2.item(proj["id"])
    for extra in (("--dry-run",), ()):
        out = p2.run("sessions.py", "dispatch", "--items", it["uid"], "--agent", "codex", *extra, ok=False)
        assert out["code"] == "outdated" and out["version"] == "0.157.0" and out["need"] == "0.164.0"
        assert out["fix"] == "npm i -g @openai/codex" and out["agent"] == "codex"
    assert p2.get(it["uid"])["state"] == "new" and not p2.tmux("list-windows", "-a").strip()  # nothing was made
    p2.env["FAKE_CODEX_VERSION"] = "0.164.0"
    assert dispatch(p2, it["uid"], agent="codex", dry_run=True)["ok"]


def test_failure_reasons_follow_the_apps_language(p2):
    """Dogfood: an English Blurt on a Chinese Mac showed the one sentence that says what to do in Chinese: the
    monitor guessed the language from the global AppleLanguages. The app now passes BLURT_LANG to every script."""
    p2.env["BLURT_LANG"] = "zh"
    p2.env["FAKE_LOGGED_OUT"] = "1"
    proj = p2.project(p2.repo(), worktree=False)
    it = p2.item(proj["id"])
    jid = dispatch(p2, it["uid"], agent="claude", force=True)["jobs"][0]["id"]
    p2.wait(lambda: p2.status(jid) == "error", what="error")
    err = p2.job(jid)["error"]
    assert err["reason"] == err["reason_i18n"]["zh"] and "登录" in err["reason"]
    assert "login" in err["reason_i18n"]["en"]
