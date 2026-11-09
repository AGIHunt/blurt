"""Shared setup for the job / hand-off / bundle tests (P2): a private BLURT_HOME and BLURT_WORKSPACE, and the real
storage CLIs (items.py / projects.py). Never the user's ~/.blurt or real agents.

  from p2_env import p2  # the fixture
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import time
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "skills" / "blurt" / "scripts"


class P2:
    def __init__(self, tmp: Path):
        self.tmp = tmp
        self.home, self.ws, self.bin = tmp / "blurt-home", tmp / "ws", tmp / "bin"
        for d in (self.home, self.ws, self.bin, tmp / "userhome"):
            d.mkdir(parents=True, exist_ok=True)
        (self.home / "config.json").write_text(json.dumps({"record": {"install_app": False}, "lang": "en"}))
        self.scripts = SCRIPTS
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(("CLAUDE", "CODEX_", "ANTHROPIC_", "BLURT_"))}
        self.env.update(BLURT_HOME=str(self.home), BLURT_WORKSPACE=str(self.ws),
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

    def wait(self, fn, timeout: float = 30, what: str = "condition"):
        deadline = time.monotonic() + timeout
        last = None
        while time.monotonic() < deadline:
            last = fn()
            if last:
                return last
            time.sleep(0.2)
        raise AssertionError(f"timed out waiting for {what}: {last!r}")


@pytest.fixture()
def p2(tmp_path):
    return P2(tmp_path)
