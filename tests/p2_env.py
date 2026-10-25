"""Shared setup for the session / job / hand-off tests (P2): a private BLURT_HOME, BLURT_WORKSPACE and tmux socket,
fake agent CLIs on PATH, and the real storage CLIs (items.py / projects.py). Never the user's ~/.blurt, tmux server,
or real agents.

  from p2_env import p2  # the fixture
"""
from __future__ import annotations

import json
import os
import secrets
import shutil
import subprocess
import sys
import time
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "skills" / "blurt" / "scripts"
TMUX = shutil.which("tmux") or "tmux"


# The fakes fire the same hooks, with the same JSON, as the real CLIs (payloads recorded from Claude Code 2.1 and
# Codex 0.157), one step per line typed into their window.
FAKE_CLAUDE = r'''
import json, os, subprocess, sys
a = sys.argv[1:]
if a[:2] == ["auth", "status"]:  # FAKE_AUTH_OUT: what `claude auth status --json` says with no login
    print(json.dumps({"loggedIn": not os.environ.get("FAKE_AUTH_OUT")})); sys.exit(0)
if a[:2] == ["mcp", "get"]:
    sys.exit(0 if os.environ.get("FAKE_MCP", "1") == "1" else 1)
if a[:1] == ["--version"]:
    print("2.1.259 (Claude Code)"); sys.exit(0)
if os.environ.get("FAKE_LOGGED_OUT"):  # what Claude Code 2.1 draws when it has no login: no hook fires, it stays open
    print("Not logged in · Please run /login", flush=True)
    input(); sys.exit(0)
settings = json.load(open(a[a.index("--settings") + 1]))["hooks"]
def fire(ev, **kw):
    for group in settings.get(ev, []):
        for h in group["hooks"]:
            subprocess.run(h["command"], shell=True, input=json.dumps({"session_id": "fake-claude-1", "cwd": os.getcwd(),
                           "hook_event_name": ev, **kw}), text=True, timeout=h.get("timeout", 5))
print("fake claude in", os.getcwd(), "job", os.environ.get("BLURT_JOB"), flush=True)
if os.environ.get("FAKE_SILENT"):  # a screen nothing recognises (an update notice…): no hook, nothing more drawn
    print("Something new to read before we start", flush=True)
    input(); sys.exit(0)
if os.environ.get("FAKE_TRUST"):  # the workspace-trust dialog: no hook fires before it is answered
    print("Do you trust the files in this folder?", flush=True)
    print(" ❯ 1. Yes, proceed", flush=True)
    print("   2. No, exit", flush=True)
    print(" Enter to confirm · Esc to exit", flush=True)
    input()
fire("SessionStart", source="startup")
fire("UserPromptSubmit", prompt=a[-1])
print("Claude needs your permission to use Bash", flush=True)
fire("Notification", message="Claude needs your permission to use Bash", notification_type="permission_prompt")
input()
fire("PostToolUse", tool_name="Bash")
fire("PostToolUse", tool_name="Bash")
print("done with this turn", flush=True)
fire("Stop", stop_hook_active=False)
fire("Notification", message="Claude is waiting for your input", notification_type="idle_prompt")
input()
fire("SessionEnd", reason="prompt_input_exit")
sys.exit(int(os.environ.get("FAKE_EXIT", "0")))
'''

FAKE_CODEX = r'''
import json, os, re, subprocess, sys
a = sys.argv[1:]
if a[:2] == ["login", "status"]:
    print("Logged in using ChatGPT", file=sys.stderr); sys.exit(0)
if a[:2] == ["mcp", "get"]:
    sys.exit(0)
if a[:1] == ["--version"]:
    print("codex-cli 0.157.0"); sys.exit(0)
notify, hooks = None, {}
for i, x in enumerate(a):
    if x == "-c":
        v = a[i + 1]
        if v.startswith("notify="):
            notify = json.loads(v[len("notify="):])
        m = re.match(r"hooks\.(\w+)=", v)
        if m:
            hooks[m.group(1)] = [json.loads(c) for c in re.findall(r'command=("(?:[^"\\]|\\.)*")', v)]
def fire(ev, **kw):
    for c in hooks.get(ev, []):
        subprocess.run(c, shell=True, input=json.dumps({"session_id": "fake-thread", "hook_event_name": ev, **kw}),
                       text=True, timeout=5)
def turn(thread):
    subprocess.run(notify + [json.dumps({"type": "agent-turn-complete", "thread-id": thread, "turn-id": "t1",
                                         "cwd": os.getcwd(), "client": "codex-tui"})], timeout=5)
early = os.environ.get("FAKE_EARLY_FILE")  # dies at startup with a reason, as Codex 0.157 did on its update screen
if early and os.path.exists(early):
    print("fake codex", flush=True)
    print("Error: " + open(early).read().strip(), flush=True)
    sys.exit(1)
print("fake codex", flush=True)
fire("SessionStart", source="startup")
fire("UserPromptSubmit", prompt=a[-1])
print("Would you like to run the following command?", flush=True)
fire("PermissionRequest", tool_name="Bash", tool_input={"command": "touch x"})
input()
fire("PostToolUse", tool_name="Bash")
if os.environ.get("FAKE_ELICIT"):  # an MCP tool asks (no hook reports it), as Codex 0.157 draws it
    import time; time.sleep(1.5)
    print("Allow Browser use to access http://127.0.0.1:8766?", flush=True)
    print("  enter to submit | esc to cancel", flush=True)
    input()
    print("browsing…", flush=True)
    time.sleep(1.5)
fire("Stop", stop_hook_active=False)
turn("fake-thread")
turn("side-thread-title")
input()
fire("SessionEnd", reason="exit")
'''

FAKE_PLAIN = r'''
import sys, time
print("plain agent starting", flush=True)
time.sleep(1.5)
print("Allow this? [y/n]", flush=True)
input()
print("ok, working", flush=True)
for i in range(8):
    time.sleep(0.5)
    print("step", i, flush=True)
input()
'''


def write_bin(d: Path, name: str, body: str) -> None:
    f = d / name
    f.write_text(f"#!{sys.executable}\n" + body.lstrip(), encoding="utf-8")
    f.chmod(0o755)


class P2:
    def __init__(self, tmp: Path):
        self.tmp = tmp
        self.home, self.ws, self.bin = tmp / "blurt-home", tmp / "ws", tmp / "bin"
        for d in (self.home, self.ws, self.bin, tmp / "userhome"):
            d.mkdir(parents=True, exist_ok=True)
        (self.home / "config.json").write_text(json.dumps({"record": {"install_app": False}, "lang": "en"}))
        write_bin(self.bin, "claude", FAKE_CLAUDE)
        write_bin(self.bin, "codex", FAKE_CODEX)
        write_bin(self.bin, "plainagent", FAKE_PLAIN)
        self.scripts = SCRIPTS
        self.socket = f"blurt-test-p2-{secrets.token_hex(3)}"
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(("CLAUDE", "CODEX_", "ANTHROPIC_", "BLURT_"))}
        self.env.update(BLURT_HOME=str(self.home), BLURT_WORKSPACE=str(self.ws), BLURT_TMUX_SOCKET=self.socket,
                        HOME=str(tmp / "userhome"), PATH=f"{self.bin}:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
                        LANG="en_US.UTF-8")

    def run(self, script: str, *args, ok: bool = True, input: str | None = None, timeout: float = 60,
            cwd: Path | None = None) -> dict:
        p = subprocess.run([sys.executable, str(self.scripts / script), *map(str, args)], capture_output=True,
                           text=True, encoding="utf-8", env=self.env, input=input, timeout=timeout, cwd=cwd)
        lines = [ln for ln in p.stdout.splitlines() if ln.startswith("{")]
        out = json.loads(lines[-1]) if lines else {"_stdout": p.stdout, "_stderr": p.stderr}
        if ok:
            assert p.returncode == 0 and out.get("ok") is not False, p.stderr + p.stdout
        out["_exit"] = p.returncode
        return out

    def git(self, repo: Path, *args) -> str:
        return subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True, text=True,
                              env=self.env).stdout.strip()

    def repo(self, name: str = "app", git: bool = True) -> Path:
        r = self.tmp / name
        (r / "src").mkdir(parents=True)
        (r / "src" / "login.txt").write_text("button: grey\n")
        if git:
            self.git(r, "init", "-q", "-b", "main")
            self.git(r, "config", "user.email", "test@example.com")
            self.git(r, "config", "user.name", "Test")
            self.git(r, "add", ".")
            self.git(r, "commit", "-q", "-m", "init")
        return r

    def project(self, path: Path, **settings) -> dict:
        proj = self.run("projects.py", "add", path)["project"]
        if settings:
            proj = self.run("projects.py", "set", proj["id"], "--json", json.dumps(settings))["project"]
        return proj

    def item(self, project: str, **fields) -> dict:
        body = {"kind": "issue", "title": "The login button does nothing", "quote": "I click login and nothing happens",
                "language": "en", **fields}
        return self.run("items.py", "add", "--project", project, "--json", json.dumps(body, ensure_ascii=False))

    def get(self, ref: str) -> dict:
        item = self.run("items.py", "get", ref)["item"]
        item.setdefault("work", {"state": "todo"})  # K1: no work key = todo
        return item

    def job(self, jid: str) -> dict:
        return self.run("jobs.py", "get", jid)["job"]

    def tmux(self, *args) -> str:
        return subprocess.run([TMUX, "-L", self.socket, *args], capture_output=True, text=True,
                              env=self.env).stdout

    def type(self, jid: str, text: str = "") -> None:
        """Type a line into the job's window (the fakes step on Enter)."""
        if text:
            self.run("sessions.py", "send", jid, "--text", text)
        win = self.job(jid)["agent"]["tmux"]["window"]
        self.tmux("send-keys", "-t", win, "Enter")

    def wait(self, fn, timeout: float = 30, what: str = "condition"):  # generous: hooks run `uv` under load
        deadline = time.monotonic() + timeout
        last = None
        while time.monotonic() < deadline:
            last = fn()
            if last:
                return last
            time.sleep(0.2)
        raise AssertionError(f"timed out waiting for {what}: {last!r}")

    def status(self, jid: str, sync: bool = True) -> str:
        if sync:
            self.run("sessions.py", "monitor", "--once", "--job", jid)
        return self.job(jid)["agent"]["status"]

    def close(self):
        for sock in (self.socket, self.socket + "-outer"):
            subprocess.run([TMUX, "-L", sock, "kill-server"], capture_output=True, env=self.env)
            tmpdir = Path(os.environ.get("TMUX_TMPDIR") or "/tmp") / f"tmux-{os.getuid()}"
            (tmpdir / sock).unlink(missing_ok=True)  # kill-server leaves the socket file


needs_tmux = pytest.mark.skipif(not shutil.which("tmux") or os.name == "nt", reason="needs tmux")


@pytest.fixture()
def p2(tmp_path):
    env = P2(tmp_path)
    yield env
    env.close()
