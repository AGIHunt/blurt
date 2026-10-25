"""Hand-offs beyond Blurt's terminal: the title a hand-off gives its conversation (Codex: thread/name/set through
`codex app-server`), Claude desktop as a target (the claude:// link, a job only the agent reports on) and moving a
running terminal session there (version / login gating). Fake CLIs only (p2_env); nothing opens a real app.

  uv run --with pytest pytest tests/test_agent_handover.py -q
"""
from __future__ import annotations

import json
import sys
import time
from pathlib import Path
from urllib.parse import parse_qs, quote, urlsplit

sys.path.insert(0, str(Path(__file__).parent))
from p2_env import SCRIPTS, needs_tmux, p2  # noqa: E402,F401

sys.path.insert(0, str(SCRIPTS))
import agents  # noqa: E402

CLAUDE_DESKTOP = agents.desktop_spec(agents.definitions({})["claude"])


def rpc_log(p2) -> list[dict]:
    f = p2.tmp / "rpc.jsonl"
    return [json.loads(ln) for ln in f.read_text().splitlines()] if f.exists() else []


# ------------------------------------------------------------------ Codex thread names
def test_thread_name_json_rpc_exchange(p2):
    p2.env.update(FAKE_RPC_LOG=str(p2.tmp / "rpc.jsonl"), CODEX_HOME=str(p2.tmp / "codex-home"))
    r = agents.set_thread_name("codex", "thr-1", "AW-12 · Login (Blurt hand-off)", cfg={}, env=p2.env, timeout=10)
    assert r == {"ok": True}
    sent = rpc_log(p2)
    # initialize (a request: clientInfo) → initialized (a notification: no id) → thread/name/set, nothing else
    assert [m["method"] for m in sent] == ["initialize", "initialized", "thread/name/set"]
    assert sent[0]["params"]["clientInfo"]["name"] == "blurt" and "id" in sent[0] and "id" not in sent[1]
    assert sent[2]["params"] == {"threadId": "thr-1", "name": "AW-12 · Login (Blurt hand-off)"}
    assert all("jsonrpc" not in m for m in sent)  # codex's dialect leaves it out
    assert {m["codex_home"] for m in sent} == {str(p2.tmp / "codex-home")}  # the session's own CODEX_HOME


def test_thread_name_errors_never_raise(p2):
    p2.env["FAKE_RPC_ERROR"] = "thread not found: thr-x"
    assert agents.set_thread_name("codex", "thr-x", "t", cfg={}, env=p2.env, timeout=10) == {
        "ok": False, "error": "thread not found: thr-x"}
    del p2.env["FAKE_RPC_ERROR"]
    p2.env["FAKE_RPC_HANG"] = "1"
    t0 = time.monotonic()
    r = agents.set_thread_name("codex", "thr-x", "t", cfg={}, env=p2.env, timeout=1.5)
    assert r == {"ok": False, "error": "timed out"} and time.monotonic() - t0 < 8  # the server is stopped, not waited on
    assert agents.set_thread_name("claude", "s", "t", cfg={}, env=p2.env)["error"] == "unsupported"
    p2.env["PATH"] = "/usr/bin:/bin"
    assert agents.set_thread_name("codex", "s", "t", cfg={}, env=p2.env)["error"] == "not installed"


@needs_tmux
def test_codex_session_thread_gets_the_title(p2):
    p2.env["FAKE_RPC_LOG"] = str(p2.tmp / "rpc.jsonl")
    proj = p2.project(p2.repo(), worktree=False)
    it = p2.item(proj["id"], title="Avatar upload returns 500")
    jid = p2.run("sessions.py", "dispatch", "--items", it["uid"], "--agent", "codex", "--lang", "en")["jobs"][0]["id"]
    title = f"{it['id']} · Avatar upload returns 500 (Blurt hand-off)"
    assert p2.job(jid)["agent"]["title"] == title
    prompt = (p2.home / "jobs" / f"{jid}.prompt.md").read_text()
    assert prompt.split("\n", 1)[0] == title  # the first line: what the session list shows before any rename
    # SessionStart reports the thread id → the hook starts name-thread in the background
    j = p2.wait(lambda: (lambda j: j if (j["agent"].get("thread_name") or {}).get("ok") else None)(p2.job(jid)),
                timeout=40, what="thread_name")
    assert j["agent"]["thread_name"]["name"] == title and j["agent"]["agent_session_id"] == "fake-thread"
    calls = [m for m in rpc_log(p2) if m["method"] == "thread/name/set"]
    assert [c["params"] for c in calls] == [{"threadId": "fake-thread", "name": title}]  # once
    p2.type(jid)
    p2.wait(lambda: p2.status(jid) == "turn_done")
    p2.type(jid)
    p2.wait(lambda: p2.status(jid) == "exited")


# ------------------------------------------------------------------ Claude desktop as the target
def test_desktop_url_and_prompt():
    folder = "/Users/me/Code/.app-worktrees/AW-12 中文"
    url = agents.desktop_url(CLAUDE_DESKTOP, folder, "AW-12 · Fix it (Blurt hand-off)\n\nRead & do: 100%")
    assert url.startswith("claude://code/new?folder=" + quote(folder, safe="") + "&q=")
    q = parse_qs(urlsplit(url).query)
    assert q == {"folder": [folder], "q": ["AW-12 · Fix it (Blurt hand-off)\n\nRead & do: 100%"]}
    assert " " not in url and "\n" not in url and "&q=" in url and url.count("&") == 1  # every value encoded
    work = {"title": "AW-12 · Fix it (Blurt hand-off)", "path": "/h/H-0001.md", "rule": "Don't push.", "lang": "en",
            "prompt": "AW-12 · Fix it (Blurt hand-off)\n\nRead /h/H-0001.md and handle the items in it.",
            "full": "# Atlas · AW-12\nDetails here\n\n## 1. AW-12 · Fix it\nuid u1 · issue"}
    small = agents.desktop_prompt(work, CLAUDE_DESKTOP, folder)
    assert small["inline"] is True and small["prompt"].split("\n", 1)[0] == work["title"]
    assert "## 1. AW-12 · Fix it" in small["prompt"] and 'state "fixing"' in small["prompt"] and "/h/H-0001.md" in small["prompt"]
    assert parse_qs(urlsplit(small["url"]).query)["q"] == [small["prompt"]]
    # too long for the link (max_url ≈ 14k): the short prompt that points at the note
    big = agents.desktop_prompt({**work, "full": "界面" * 3000}, CLAUDE_DESKTOP, folder)
    assert big["inline"] is False and big["prompt"] == work["prompt"] and len(big["url"]) <= CLAUDE_DESKTOP["max_url"]
    zh = agents.desktop_prompt({**work, "lang": "zh"}, CLAUDE_DESKTOP, folder)
    assert "state 填 \"fixing\"" in zh["prompt"]


def test_desktop_dispatch_is_a_job_only_the_agent_reports_on(p2):
    repo = p2.repo()
    proj = p2.project(repo, worktree=True)
    it = p2.item(proj["id"], title="Price page overflows")
    p2.env["FAKE_MCP"] = "0"
    dry = p2.run("sessions.py", "dispatch", "--items", it["uid"], "--agent", "claude", "--runner", "desktop", "--dry-run")
    assert dry["runner"] == "desktop" and dry["mcp"] is False  # no blurt MCP for Claude: the sheet says so
    p2.env["FAKE_MCP"] = "1"
    out = p2.run("sessions.py", "dispatch", "--items", it["uid"], "--agent", "claude", "--runner", "desktop", "--lang", "en")
    row = out["jobs"][0]
    jid, wt = row["id"], Path(row["worktree"])
    assert wt.is_dir() and row["branch"].startswith("blurt/")  # Blurt still makes the worktree
    q = parse_qs(urlsplit(row["url"]).query)
    assert row["url"].startswith("claude://code/new?") and q["folder"] == [row["cwd"]] and row["inline"] is True
    assert q["q"][0].split("\n", 1)[0] == f"{it['id']} · Price page overflows (Blurt hand-off)"
    assert "Price page overflows" in q["q"][0] and "commit your work there" in q["q"][0]  # the note inline, its rule
    assert p2.tmux("list-windows", "-a") == ""  # nothing started here: the app opens the link
    j = p2.job(jid)
    assert j["agent"]["runner"] == "desktop" and j["agent"]["status_source"] == "desktop" and j["state"] == "running"
    assert j["agent"]["desktop"] == {"inline": True, "url_chars": len(row["url"])} and j["agent"]["items_handed"] is True
    p2.run("sessions.py", "monitor", "--once", "--job", jid)
    item = p2.get(it["uid"])
    assert item["state"] == "handed_off" and item["work"]["job"] == jid  # only the agent says it started
    assert [r["job"] for r in p2.run("sessions.py", "list")["sessions"]] == [jid]
    # the agent reports (mark_fixed state fixing → in progress; fixed → to verify) and leaves a commit
    p2.run("items.py", "state", it["uid"], "--state", "in_progress", "--by", "agent")
    p2.run("sessions.py", "monitor", "--once", "--job", jid)
    assert p2.job(jid)["state"] == "running"
    (wt / "src" / "login.txt").write_text("button: blue\n")
    p2.git(wt, "commit", "-qam", "fix")
    p2.run("items.py", "state", it["uid"], "--state", "to_verify", "--by", "agent", "--claim", "fixed")
    p2.run("sessions.py", "monitor", "--once", "--job", jid)
    j = p2.job(jid)
    assert j["state"] == "done" and j["agent"]["status"] == "exited" and j["agent"]["changes"] == {"ahead": 1, "dirty": 0}
    merged = p2.run("sessions.py", "finish", jid, "--action", "merge")  # Review / Merge work on the worktree as usual
    assert merged["removed"] and (repo / "src" / "login.txt").read_text() == "button: blue\n"


def test_desktop_job_is_not_over_before_its_items_reach_it(p2):
    """A monitor pass between the job's creation and the items being handed to it (dogfood: the job ended at once)
    sees items still in To Do: that is not "none is still with it"."""
    proj = p2.project(p2.repo(), worktree=False)
    it = p2.item(proj["id"])
    jid = p2.run("sessions.py", "dispatch", "--items", it["uid"], "--agent", "claude", "--runner", "desktop")["jobs"][0]["id"]
    f = p2.home / "jobs" / f"{jid}.json"
    j = json.loads(f.read_text())
    del j["agent"]["items_handed"]  # as it is before set_work
    f.write_text(json.dumps(j))
    p2.run("items.py", "state", it["uid"], "--state", "todo", "--by", "user")
    p2.run("sessions.py", "monitor", "--once", "--job", jid)
    assert p2.job(jid)["state"] == "running"


def test_desktop_long_note_points_at_the_file(p2):
    proj = p2.project(p2.repo(), worktree=False)
    it = p2.item(proj["id"], title="Big one", details="细节" * 6000)
    row = p2.run("sessions.py", "dispatch", "--items", it["uid"], "--agent", "claude", "--runner", "desktop")["jobs"][0]
    q = parse_qs(urlsplit(row["url"]).query)["q"][0]
    assert row["inline"] is False and len(row["url"]) <= CLAUDE_DESKTOP["max_url"]
    assert q.split("\n")[2].startswith(f"Read {p2.home / 'handoff'}") and "细节" not in q


def test_desktop_needs_an_agent_with_a_desktop_app(p2):
    proj = p2.project(p2.repo(), worktree=False)
    it = p2.item(proj["id"])
    r = p2.run("sessions.py", "dispatch", "--items", it["uid"], "--agent", "codex", "--runner", "desktop", ok=False)
    assert r["code"] == "no_desktop" and p2.get(it["uid"])["state"] == "new"
    # the desktop app signs in on its own: a logged-out CLI refuses the terminal, not the desktop app
    p2.env["FAKE_AUTH_OUT"] = "1"
    assert p2.run("sessions.py", "dispatch", "--items", it["uid"], "--agent", "claude", ok=False)["code"] == "auth"
    row = p2.run("sessions.py", "dispatch", "--items", it["uid"], "--agent", "claude", "--runner", "desktop")["jobs"][0]
    assert row["url"].startswith("claude://code/new?") and p2.get(it["uid"])["state"] == "handed_off"


# ------------------------------------------------------------------ continue a terminal session in Claude desktop
def test_continue_gating(p2):
    def check(**env):
        e = {**p2.env, **env}
        return agents.desktop_continue_check("claude", cfg={}, env=e)
    assert check(FAKE_CLAUDE_VERSION="2.1.284", FAKE_AUTH_SUB="max")["reason"] == "version"
    assert check(FAKE_CLAUDE_VERSION="2.0.999", FAKE_AUTH_SUB="max")["reason"] == "version"
    assert check(FAKE_CLAUDE_VERSION="2.1.285")["reason"] == "login"  # an API key is not a subscription
    assert check(FAKE_CLAUDE_VERSION="2.1.285", FAKE_AUTH_SUB="max", FAKE_AUTH_OUT="1")["reason"] == "login"
    assert check(FAKE_CLAUDE_VERSION="2.1.285", FAKE_AUTH_SUB="pro") == {"available": True, "reason": None,
                                                                          "version": "2.1.285 (Claude Code)"}
    assert check(FAKE_CLAUDE_VERSION="2.10.0", FAKE_AUTH_SUB="max")["available"] is True  # numbers, not strings
    assert check(FAKE_CLAUDE_VERSION="next", FAKE_AUTH_SUB="max")["reason"] == "version"
    assert agents.desktop_continue_check("codex", cfg={}, env=p2.env)["reason"] == "unsupported"
    assert check(PATH="/usr/bin:/bin")["reason"] == "not_installed"
    assert p2.run("sessions.py", "desktop-check")["reason"] == "version"  # the CLI: 2.1.259 by default
    auth = CLAUDE_DESKTOP["continue"]["auth"]
    assert agents.subscription_login('{"loggedIn": true, "authMethod": "claude.ai"}', auth) is True
    assert agents.subscription_login('{"loggedIn": true, "subscriptionType": null, "authMethod": "api_key"}', auth) is False
    assert agents.subscription_login("Logged in", auth) is None
    assert agents.version_tuple("2.1.285 (Claude Code)") == (2, 1, 285) and agents.version_tuple("x") is None


@needs_tmux
def test_continue_in_desktop_hands_the_conversation_over(p2):
    p2.env.update(FAKE_DESKTOP_LOG=str(p2.tmp / "desktop.jsonl"), FAKE_CLAUDE_VERSION="2.1.290", FAKE_AUTH_SUB="max")
    proj = p2.project(p2.repo(), worktree=False)
    it = p2.item(proj["id"])
    jid = p2.run("sessions.py", "dispatch", "--items", it["uid"], "--agent", "claude")["jobs"][0]["id"]
    p2.wait(lambda: p2.status(jid) == "waiting_input", what="hooks live")
    win = p2.job(jid)["agent"]["tmux"]["window"]
    out = p2.run("sessions.py", "continue-desktop", jid)
    a = out["job"]["agent"]
    assert a["runner"] == "desktop" and a["status"] == "running" and a["status_source"] == "desktop"
    assert a["tmux"] is None and a["continued"]["from"] == "tmux" and a["continued"]["tmux"]["window"] == win
    assert out["job"]["state"] == "running"
    calls = [json.loads(ln) for ln in (p2.tmp / "desktop.jsonl").read_text().splitlines()]
    assert calls == [{"argv": ["--desktop", "--resume", "fake-claude-1"], "cwd": str(Path(a["cwd"]).resolve()),
                      "claudecode": None}]
    assert win not in p2.tmux("list-windows", "-a", "-F", "#{window_id}")  # the terminal agent is gone
    p2.run("sessions.py", "monitor", "--once", "--job", jid)
    j = p2.job(jid)
    assert j["state"] == "running" and j["agent"]["status"] == "running"  # its exit didn't end the job
    assert p2.get(it["uid"])["state"] == "in_progress"  # what it reported before stays


@needs_tmux
def test_continue_in_desktop_refusals(p2):
    proj = p2.project(p2.repo(), worktree=False)
    it = p2.item(proj["id"])
    jid = p2.run("sessions.py", "dispatch", "--items", it["uid"], "--agent", "claude")["jobs"][0]["id"]
    p2.wait(lambda: p2.status(jid) == "waiting_input")
    r = p2.run("sessions.py", "continue-desktop", jid, ok=False)  # 2.1.259: too old, nothing touched
    assert r["code"] == "desktop_version" and p2.job(jid)["agent"]["runner"] == "tmux"
    assert p2.tmux("list-windows", "-a", "-F", "#{pane_dead}").split() == ["0"]
    p2.env.update(FAKE_CLAUDE_VERSION="2.1.290")
    assert p2.run("sessions.py", "continue-desktop", jid, ok=False)["code"] == "desktop_login"
    # the desktop app fails to take it: the job says so (it can be restarted), never "running" for good
    p2.env.update(FAKE_AUTH_SUB="max", FAKE_DESKTOP_LOG=str(p2.tmp / "d.jsonl"), FAKE_DESKTOP_EXIT="2")
    r = p2.run("sessions.py", "continue-desktop", jid, ok=False)
    assert r["code"] == "desktop_failed" and "isn't installed" in r["error"]
    j = p2.job(jid)
    assert j["state"] == "failed" and j["agent"]["status"] == "error" and "isn't installed" in j["error"]["message"]
