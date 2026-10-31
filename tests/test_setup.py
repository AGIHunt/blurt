"""scripts/setup.py (docs/design/agent-setup.md): the agent's model-setup CLI against a fake Blurt app on the control
socket — keys only on stdin (never an argument, never printed), the session token passed along, every command's
request, the app-not-running answers (status and recommend still work from config), the plan for typical Macs and
answers, the socket path rule shared with the app (tests/fixtures/agent_setup_socket.jsonl), the key pages kept equal
to the app's presets, sessions.py setup-session's prompt — and the MCP tools (setup_*) over stdio.

  uv run --with pytest pytest tests/test_setup.py -q
"""
from __future__ import annotations

import json
import os
import shutil
import socket
import subprocess
import sys
import textwrap
import threading
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "skills" / "blurt" / "scripts"
sys.path.insert(0, str(SCRIPTS))
import setup as setup_cli  # noqa: E402

KEY = "sk-test-0123456789abcdef"


class FakeApp:
    """The app's end of the socket: records each request, answers by op (or with what a test queued)."""

    def __init__(self, home: Path):
        self.home = home
        self.path = setup_cli.socket_path(home)
        Path(self.path).parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.requests: list[dict] = []
        self.answers: dict[str, list[dict]] = {}
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        if os.path.exists(self.path):
            os.unlink(self.path)
        self.sock.bind(self.path)
        os.chmod(self.path, 0o600)
        self.sock.listen(8)
        self.stopped = False
        self.thread = threading.Thread(target=self.loop, daemon=True)
        self.thread.start()

    def answer(self, op: str, *answers: dict) -> None:
        self.answers.setdefault(op, []).extend(answers)

    def loop(self) -> None:
        while not self.stopped:
            try:
                c, _ = self.sock.accept()
            except OSError:
                return
            with c:
                buf = b""
                while b"\n" not in buf:
                    chunk = c.recv(65536)
                    if not chunk:
                        break
                    buf += chunk
                req = json.loads(buf.split(b"\n", 1)[0])
                self.requests.append(req)
                q = self.answers.get(req["op"])
                out = q.pop(0) if q else self.default(req)
                c.sendall(json.dumps(out).encode() + b"\n")

    def default(self, req: dict) -> dict:
        op = req["op"]
        if op == "status":
            return {"ok": True, "app": "running", "mac": {"ram_gb": 16, "languages": ["zh-Hans-CN"], "region": "CN"},
                    "dictation": {"recommended_local": "qwen3-asr-1.7b-mlx", "models": []}, "services": [],
                    "options": {}, "downloads": []}
        if op == "connect":
            return {"ok": True, "service": req.get("preset"), "ms": 320}
        return {"ok": True, "op": op}

    def close(self) -> None:
        self.stopped = True
        self.sock.close()
        if os.path.exists(self.path):
            os.unlink(self.path)


@pytest.fixture()
def home(tmp_path, monkeypatch):
    h = tmp_path / "blurt-home"
    h.mkdir()
    monkeypatch.setenv("BLURT_HOME", str(h))
    monkeypatch.setenv("BLURT_SETUP_NO_PROBE", "1")
    monkeypatch.delenv("BLURT_SETUP_TOKEN", raising=False)
    return h


@pytest.fixture()
def app(home):
    a = FakeApp(home)
    yield a
    a.close()


def cli(home: Path, *args: str, stdin: str | None = None, env: dict | None = None) -> tuple[int, dict, str]:
    e = {**os.environ, "BLURT_HOME": str(home), "BLURT_SETUP_NO_PROBE": "1", **(env or {})}
    if not (env or {}).get("BLURT_SETUP_TOKEN"):
        e.pop("BLURT_SETUP_TOKEN", None)
    p = subprocess.run([sys.executable, str(SCRIPTS / "setup.py"), *args], input=stdin if stdin is not None else "",
                       capture_output=True, text=True, env=e, timeout=60)
    out = json.loads(p.stdout.strip().splitlines()[-1]) if p.stdout.strip() else {}
    return p.returncode, out, p.stdout + p.stderr


# ------------------------------------------------------------------ the socket path


def test_the_socket_path_is_the_apps_rule():
    for line in (ROOT / "tests" / "fixtures" / "agent_setup_socket.jsonl").read_text().splitlines():
        c = json.loads(line)
        assert setup_cli.socket_path(Path(c["home"]), c["uid"]) == c["socket"]
        assert len(c["socket"].encode()) <= setup_cli.MAX_SOCKET_PATH


# ------------------------------------------------------------------ keys


def test_connect_reads_the_key_from_stdin_and_never_prints_it(home, app):
    code, out, text = cli(home, "connect", "deepseek", stdin=KEY + "\n")
    assert code == 0 and out["ok"] and out["service"] == "deepseek"
    assert app.requests[-1] == {"op": "connect", "preset": "deepseek", "key": KEY}
    assert KEY not in text
    # a refusal doesn't say it back either
    app.answer("connect", {"ok": False, "code": "auth", "error": "the key was refused; check the key and its region"})
    code, out, text = cli(home, "connect", "dashscope", "--region", "global", stdin=json.dumps({"key": KEY}))
    assert code == 1 and out["code"] == "auth"
    assert app.requests[-1] == {"op": "connect", "preset": "dashscope", "region": "global", "key": KEY}
    assert KEY not in text


def test_a_key_is_never_an_argument(home, app):
    code, out, text = cli(home, "connect", "deepseek", KEY)
    assert code == 2 and out["code"] == "bad_args"
    assert KEY not in text and KEY not in json.dumps(app.requests)


def test_volcengine_takes_the_pair_as_json_on_stdin(home, app):
    code, out, _ = cli(home, "connect", "volcengine-speech", stdin=json.dumps({"app_id": "123456", "access_token": "tok"}))
    assert code == 0
    assert app.requests[-1] == {"op": "connect", "preset": "volcengine-speech", "app_id": "123456", "access_token": "tok"}
    code, out, _ = cli(home, "connect", "volcengine-speech", stdin="just-a-token")
    assert code == 1 and out["code"] == "bad_request"
    code, out, _ = cli(home, "connect", "deepseek", stdin="")
    assert code == 1 and out["code"] == "no_key"


def test_the_sessions_token_goes_with_every_request(home, app):
    cli(home, "use", "polish", "deepseek", env={"BLURT_SETUP_TOKEN": "t0ken"})
    assert app.requests[-1] == {"op": "use", "job": "polish", "option": "deepseek", "custom": False, "token": "t0ken"}
    cli(home, "use", "polish", "deepseek:deepseek-reasoner", "--custom")
    assert app.requests[-1] == {"op": "use", "job": "polish", "option": "deepseek:deepseek-reasoner", "custom": True}


def test_each_command_asks_the_app(home, app):
    assert cli(home, "test", "deepseek")[0] == 0
    assert app.requests[-1] == {"op": "test", "service": "deepseek"}
    assert cli(home, "verify", "--language", "zh")[0] == 0
    assert app.requests[-1] == {"op": "verify", "language": "zh"}
    assert cli(home, "download")[0] == 0
    assert app.requests[-1] == {"op": "download", "model": "recommended"}
    code, out, _ = cli(home, "status")
    assert code == 0 and out["source"] == "app" and app.requests[-1] == {"op": "status"}
    # a refusal from the app comes through as it is
    app.answer("use", {"ok": False, "code": "denied", "error": "the user didn't allow changes"})
    code, out, _ = cli(home, "use", "dictation", "cloud-polish")
    assert code == 1 and out["code"] == "denied"


def test_download_wait_follows_it_to_the_end(home, app):
    app.answer("download", {"ok": True, "started": ["qwen3-asr-1.7b-mlx"], "size_mb": 2468})
    app.answer("status", {"ok": True, "downloads": [{"id": "qwen3-asr-1.7b-mlx", "running": True}]},
               {"ok": True, "downloads": []})
    out = setup_cli.download("qwen3-asr-1.7b-mlx", wait=True, every=0.01)
    assert out == {"ok": True, "installed": ["qwen3-asr-1.7b-mlx"], "seconds": 0}
    app.answer("download", {"ok": True, "started": ["gemma4-e2b"]})
    app.answer("status", {"ok": True, "downloads": [], "download_failed": ["gemma4-e2b"]})
    assert setup_cli.download("gemma4-e2b", wait=True, every=0.01)["code"] == "download_failed"


# ------------------------------------------------------------------ without the app


def test_without_the_app_changes_say_open_blurt_and_status_reads_config(home):
    (home / "config.json").write_text(json.dumps({"record": {
        "cloud": {"v": 2, "services": [{"id": "deepseek", "preset": "deepseek"}], "jobs": {"translate": "local"}},
        "dictation": {"asr_model": "qwen3-asr-0.6b-mlx"}}}))
    for args in (["use", "polish", "deepseek"], ["test", "deepseek"], ["verify"], ["download"]):
        code, out, _ = cli(home, *args)
        assert code == 1 and out["code"] == "app_not_running" and out["fix"] == "open -a Blurt"
    code, out, _ = cli(home, "connect", "deepseek", stdin=KEY)
    assert code == 1 and out["code"] == "app_not_running"
    code, out, _ = cli(home, "status")
    assert code == 0 and out["source"] == "config"
    assert out["services"] == [{"id": "deepseek", "preset": "deepseek", "region": None, "key": None}]
    assert out["jobs"]["translate"] == {"choice": "local"} and out["jobs"]["polish"] == {"choice": "auto"}
    assert out["dictation"]["configured"] == "qwen3-asr-0.6b-mlx"
    assert [o["option"] for o in out["options"]["polish"]] == ["dashscope:deepseek-v4.1-flash", "deepseek:deepseek-flash"]
    assert {p["preset"] for p in out["providers"]} == {"deepseek", "dashscope", "volcengine-speech"}
    code, out, _ = cli(home, "recommend")
    assert code == 0 and out["source"] == "config" and out["steps"][-1] == "setup.py verify"


def test_a_stale_socket_file_is_not_running(home):
    p = Path(setup_cli.socket_path(home))
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text("")
    code, out, _ = cli(home, "test", "deepseek")
    assert out["code"] == "app_not_running"
    p.unlink()


# ------------------------------------------------------------------ the plan


def status(ram=16, langs=("zh-Hans-CN",), region="CN", local="qwen3-asr-1.7b-mlx", installed=(), keys=(), options=None):
    return {"ok": True, "source": "app", "mac": {"ram_gb": ram, "languages": list(langs), "region": region},
            "dictation": {"recommended_local": local,
                          "models": [{"id": m, "installed": m in installed, "size_mb": 2468} for m in
                                     ("qwen3-asr-1.7b-mlx", "qwen3-asr-0.6b-mlx")]},
            "services": [{"id": k, "preset": k, "key": True} for k in keys],
            "options": options or json.loads((SCRIPTS / "curated_models.json").read_text())["jobs"]}


def uses(p):
    return {u["job"]: u["option"] for u in p["use"]}


def test_the_default_plan_is_this_macs_model_and_deepseek_polish():
    p = setup_cli.plan(status())
    assert uses(p) == {"dictation": "cloud-polish", "polish": "deepseek:deepseek-flash",
                       "translate": "deepseek:deepseek-flash", "vision": "deepseek:deepseek-flash"}
    assert [c["preset"] for c in p["connect"]] == ["deepseek"]
    assert p["connect"][0]["key_page"] == "https://platform.deepseek.com/api_keys"
    assert p["download"] == [{"model": "qwen3-asr-1.7b-mlx", "size_mb": 2468}]
    assert p["alternatives"] == []          # the voice stays on the Mac unless the user says otherwise
    assert p["steps"] == ["setup.py connect deepseek", "setup.py download qwen3-asr-1.7b-mlx --wait",
                          "setup.py use dictation cloud-polish", "setup.py use polish deepseek:deepseek-flash",
                          "setup.py use translate deepseek:deepseek-flash", "setup.py use vision deepseek:deepseek-flash",
                          "setup.py verify"]


def test_free_keeps_everything_on_the_mac():
    p = setup_cli.plan(status(installed=("qwen3-asr-1.7b-mlx",)), budget="free")
    assert uses(p) == {"dictation": "qwen3-asr-1.7b-mlx", "polish": "local", "translate": "local", "vision": "local"}
    assert p["connect"] == [] and p["download"] == []
    p = setup_cli.plan(status(), text="local")
    assert uses(p)["polish"] == "local" and p["connect"] == []


def test_a_connected_model_studio_key_is_reused_in_its_region():
    p = setup_cli.plan(status(keys=("dashscope",), region="US", langs=("en-US",)))
    assert uses(p)["polish"] == "dashscope:deepseek-v4.1-flash"
    assert uses(p)["vision"] == "dashscope:qwen3.6-flash"
    assert p["connect"][0]["connected"] and p["connect"][0]["region"] == "global"
    assert not any(s.startswith("setup.py connect") for s in p["steps"])


def test_a_mac_without_a_local_model_hears_in_the_cloud_when_allowed():
    p = setup_cli.plan(status(ram=8, local="apple-speech", langs=("en-US",), region="US"), audio="cloud")
    assert uses(p)["dictation"] == "qwen3-asr-flash"
    assert [c["preset"] for c in p["connect"]] == ["dashscope"]      # one key for speech and text
    assert uses(p)["polish"] == "dashscope:deepseek-v4.1-flash"
    assert p["connect"][0]["key_page"].startswith("https://modelstudio.console.alibabacloud.com")
    p = setup_cli.plan(status(ram=8, local="apple-speech"), audio="local")
    assert uses(p)["dictation"] == "apple-speech"


def test_cloud_recognition_is_an_option_and_volcengine_only_for_chinese_speakers():
    p = setup_cli.plan(status(), audio="cloud")
    assert uses(p)["dictation"] == "cloud-polish"
    assert [a["dictation"] for a in p["alternatives"]] == ["qwen3-asr-flash", "volcengine-seedasr"]
    p = setup_cli.plan(status(langs=("de-DE",), region="DE"), audio="cloud")
    assert [a["dictation"] for a in p["alternatives"]] == ["qwen3-asr-flash"]
    assert any("de" in n for n in p["notes"])
    assert any("Japanese" in n for n in setup_cli.plan(status(langs=("ja-JP",), region="JP"))["notes"])


def test_the_key_pages_are_the_apps():
    swift = (ROOT / "skills/blurt/recorder/macos/Sources/BlurtCore/CloudServices.swift").read_text()
    for preset, pages in setup_cli.KEY_PAGES.items():
        for url in pages.values():
            assert f'key: "{url}"' in swift, (preset, url)


# ------------------------------------------------------------------ sessions.py setup-session


def test_the_setup_session_prompt_points_at_the_guide_and_the_cli(home):
    import sessions
    for lang in ("en", "zh"):
        title, prompt = sessions.setup_prompt(lang)
        assert prompt.startswith(title)
        assert str(SCRIPTS.parent / "reference" / "setup-models.md") in prompt
        assert str(SCRIPTS / "setup.py") in prompt
    assert (SCRIPTS.parent / "reference" / "setup-models.md").is_file()
    with pytest.raises(sessions.SessionError) as e:
        sessions.setup_session("nope", dry_run=True)
    assert e.value.code == "bad_agent"


# ------------------------------------------------------------------ MCP

MCP_CLIENT = textwrap.dedent('''
    import asyncio, json, os, sys
    from mcp import ClientSession, StdioServerParameters
    from mcp.client.stdio import stdio_client

    async def main():
        calls = json.loads(sys.argv[2])
        params = StdioServerParameters(command="uv", args=["run", "-q", "--script", sys.argv[1]], env=dict(os.environ))
        out = {}
        async with stdio_client(params) as (r, w):
            async with ClientSession(r, w) as s:
                await s.initialize()
                tools = await s.list_tools()
                out["_tools"] = {t.name: sorted(t.inputSchema.get("properties", {})) for t in tools.tools}
                for key, name, args in calls:
                    res = await s.call_tool(name, args)
                    sc = getattr(res, "structuredContent", None)
                    out[key] = {"is_error": bool(res.isError), "structured": sc,
                                "text": [c.text for c in res.content if c.type == "text"]}
        print(json.dumps(out))

    asyncio.run(main())
''')


@pytest.mark.skipif(not shutil.which("uv"), reason="needs uv")
def test_the_mcp_setup_tools_share_setup_py(home, app, tmp_path):
    e = {k: v for k, v in os.environ.items() if not k.startswith(("CLAUDE", "CODEX_", "MCP_"))}
    e.update(BLURT_HOME=str(home), BLURT_SETUP_NO_PROBE="1")
    e.pop("BLURT_SETUP_TOKEN", None)
    client = tmp_path / "client.py"
    client.write_text(MCP_CLIENT, encoding="utf-8")
    calls = [["status", "setup_status", {}],
             ["connect", "setup_connect", {"preset": "deepseek", "key": KEY}],
             ["test", "setup_test", {"service": "deepseek"}],
             ["use", "setup_use", {"job": "polish", "option": "deepseek"}],
             ["download", "setup_download", {}],
             ["verify", "setup_verify", {"language": "en"}],
             ["recommend", "setup_recommend", {"audio": "cloud"}],
             ["bad", "setup_recommend", {"audio": "loud"}]]
    p = subprocess.run(["uv", "run", "-q", "--no-project", "--with", "mcp>=1.20,<2", "python", str(client),
                        str(SCRIPTS / "mcp_server.py"), json.dumps(calls)], capture_output=True, text=True,
                       env=e, timeout=300, cwd=tmp_path)
    assert p.returncode == 0, p.stderr[-3000:]
    r = json.loads(p.stdout.strip().splitlines()[-1])
    assert {"setup_status", "setup_recommend", "setup_connect", "setup_test", "setup_use", "setup_download",
            "setup_verify"} <= set(r["_tools"])
    assert r["_tools"]["setup_connect"] == ["access_token", "app_id", "key", "preset", "region"]
    ops = [q["op"] for q in app.requests]
    assert ops[:2] == ["status", "connect"] and {"test", "use", "download", "verify"} <= set(ops)
    assert {"op": "connect", "preset": "deepseek", "key": KEY} in app.requests
    # the key goes to the app once, and nowhere else: not in any answer, not in the server's output
    assert KEY not in json.dumps({k: v for k, v in r.items() if k != "_tools"})
    assert KEY not in p.stderr
    def body(res):
        if isinstance(res.get("structured"), dict):
            sc = res["structured"]
            return sc["result"] if set(sc) == {"result"} else sc
        return json.loads(res["text"][0])
    assert body(r["status"])["source"] == "app"
    assert body(r["connect"]) == {"ok": True, "service": "deepseek", "ms": 320}
    rec = body(r["recommend"])
    assert rec["ok"] and any(a["dictation"] == "qwen3-asr-flash" for a in rec["alternatives"])
    assert r["bad"]["is_error"]
