"""agents.py WP2 commands (contract C5): detect, command, install (--dry-run and real, into temp dirs only),
repo-level order, and the K5 session commands. Uses fake agent CLIs on PATH — never the real ones, never the user's config.

  uv run --with pytest pytest tests/test_agents.py -q
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
from pathlib import Path
from urllib.parse import parse_qs, urlparse

import pytest

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "skills" / "blurt" / "scripts"
sys.path.insert(0, str(SCRIPTS))
sys.path.insert(0, str(Path(__file__).parent))
import agents  # noqa: E402

pytestmark = pytest.mark.skipif(os.name == "nt", reason="fake CLIs are sh scripts")

FAKE = {
    # claude: logged out, like this Mac
    "claude": """
case "$1" in
  --version) echo "2.1.259 (Claude Code)";;
  auth) echo '{"loggedIn": false, "authMethod": "none"}'; exit 1;;
  mcp) if [ "$2" = get ]; then [ -f "$HOME/.claude-mcp-blurt" ] && exit 0 || exit 1; fi
       shift 2; echo "$@" > "$HOME/.claude-mcp-blurt"; echo "Added stdio MCP server blurt";;
esac""",
    # codex: logged in; `mcp add` writes into $CODEX_HOME (the regression: CODEX_HOME must reach it)
    "codex": """
case "$1" in
  --version) echo "codex-cli 0.157.0";;
  login) echo "Logged in using ChatGPT" >&2;;
  mcp) if [ "$2" = get ]; then grep -q blurt "${CODEX_HOME:-$HOME/.codex}/config.toml" 2>/dev/null && exit 0 || exit 1; fi
       mkdir -p "${CODEX_HOME:-$HOME/.codex}"; shift 2; echo "[mcp_servers.blurt] $*" >> "${CODEX_HOME:-$HOME/.codex}/config.toml"
       echo "Added global MCP server 'blurt'.";;
esac""",
    "kimi": """
case "$1" in
  --version) echo "0.36.0";;
  provider) echo "managed:kimi-code  models=3";;
esac""",
}


@pytest.fixture()
def env(tmp_path, monkeypatch):
    home, bh, bin_ = tmp_path / "home", tmp_path / "blurt-home", tmp_path / "bin"
    for d in (home, bh, bin_):
        d.mkdir()
    for name, body in FAKE.items():
        f = bin_ / name
        f.write_text("#!/bin/sh\n" + body.strip() + "\n")
        f.chmod(0o755)
    (home / ".kimi-code" / "credentials").mkdir(parents=True)
    (home / ".kimi-code" / "credentials" / "kimi-code.json").write_text(
        json.dumps({"access_token": "", "refresh_token": "", "expires_at": 0}))
    for k in list(os.environ):
        if k.startswith(("CLAUDE", "CODEX_", "KIMI_")):
            monkeypatch.delenv(k, raising=False)
    monkeypatch.setenv("HOME", str(home))
    monkeypatch.setenv("BLURT_HOME", str(bh))
    monkeypatch.setenv("PATH", f"{bin_}:/usr/bin:/bin")
    monkeypatch.setenv("CODEX_HOME", str(tmp_path / "codex-home"))
    monkeypatch.setenv("KIMI_CODE_HOME", str(tmp_path / "kimi-home"))
    return {"home": home, "bh": bh, "tmp": tmp_path}


def cli(*args, ok=True) -> dict:
    p = subprocess.run([sys.executable, str(SCRIPTS / "agents.py"), *map(str, args)], capture_output=True, text=True,
                       encoding="utf-8", env=os.environ.copy())
    if ok:
        assert p.returncode == 0, p.stderr + p.stdout
    return json.loads(p.stdout.strip().splitlines()[-1])


def test_every_agent_has_the_c5_fields():
    reg = agents.registry()
    ids = [a["id"] for a in reg["agents"]]
    assert ids[:3] == ["claude", "codex", "kimi"] and ids[-1] == "zcode"
    for a in reg["agents"]:
        assert {"id", "name", "bins", "verified"} <= set(a), a["id"]
        assert agents.interactive_kind(a), a["id"]
        if agents.is_headless(a):
            assert "{prompt}" in a["run"] and a.get("events", {}).get("format"), a["id"]
            assert a.get("skill_dir") and a.get("mcp"), a["id"]
    assert not agents.is_headless(next(a for a in reg["agents"] if a["id"] == "zcode"))


def test_detect_matches_fake_clis(env):
    out = cli("detect")
    rows = {r["id"]: r for r in out["agents"]}
    ids = [r["id"] for r in out["agents"]]
    assert out["order"] == agents.agent_order({}) and ids[:len(out["order"])] == out["order"]
    assert "zcode" not in out["order"] and ids[-1] == "zcode"  # app-only: listed after the order, never picked
    assert agents.agent_order({"record": {"agents": ["zcode", "codex"]}}) == ["codex"]
    assert rows["claude"]["login"] == "logged_out" and rows["claude"]["state"] == "logged_out"
    assert rows["claude"]["version"] == "2.1.259 (Claude Code)"
    assert rows["codex"]["login"] == "ok" and rows["codex"]["state"] == "ready"
    assert rows["kimi"]["state"] == "logged_out"  # creds_json: empty tokens beat "models=3"
    assert rows["opencode"]["installed"] is False and rows["opencode"]["login"] == "n/a"
    assert out["pick"] == "codex"
    for r in out["agents"]:  # app-ux's check() keys stay, WP2 adds the rest
        assert {"id", "name", "path", "state", "why", "fix", "installed", "version", "login", "headless",
                "interactive"} <= set(r)
    fast = cli("detect", "--no-login", "--no-version", "--ids", "codex,claude")
    assert [r["id"] for r in fast["agents"]] == ["codex", "claude"] and fast["agents"][0]["version"] is None


def test_detect_pick_follows_the_configured_order_not_ids(env):
    # Settings → Agents asks for every id in registry order; the pick is still the configured order's first usable
    (env["bh"] / "config.json").write_text(json.dumps({"record": {"agents": ["codex", "claude"]}}))
    out = cli("detect", "--no-login", "--no-version", "--ids", "claude,codex,kimi")
    assert [r["id"] for r in out["agents"]] == ["claude", "codex", "kimi"] and out["pick"] == "codex"


def test_detect_ignores_agent_session_vars(env, monkeypatch):
    monkeypatch.setenv("CLAUDE_CODE_SIMPLE", "1")
    assert "CLAUDE_CODE_SIMPLE" not in agents.clean_env()
    assert agents.clean_env()["CODEX_HOME"] == os.environ["CODEX_HOME"]  # a config location, not a leak


def test_order_repo_override(env, tmp_path):
    repo = tmp_path / "repo"
    (repo / ".blurt").mkdir(parents=True)
    (repo / ".blurt" / "config.json").write_text(json.dumps({"record": {"agents": ["kimi", "codex"]}}))
    assert cli("order", "--json", "--repo", repo)["order"] == ["kimi", "codex"]
    assert cli("order", "--json")["order"] == agents.agent_order({})
    assert cli("detect", "--repo", repo, "--no-version")["pick"] == "codex"  # kimi logged out → next


def test_command_headless(env, tmp_path):
    out = cli("command", "codex", "headless", "--prompt", "fix it; rm -rf / 'quoted'", "--repo", tmp_path,
              "--var", "run_id=r-1")
    assert out["argv"][0].endswith("/codex") and out["argv"][1] == "exec"
    assert "fix it; rm -rf / 'quoted'" in out["argv"]  # one argv element, never a shell string
    assert out["argv"][-1] == "--json" and out["events"] == "codex-jsonl"
    # the blurt MCP server rides along, fully defined (-c on an unregistered server breaks codex) and pre-approved
    sets = [out["argv"][i + 1] for i, a in enumerate(out["argv"]) if a == "-c"]
    assert 'mcp_servers.blurt.default_tools_approval_mode="approve"' in sets
    assert 'mcp_servers.blurt.command="uv"' in sets and any(str(agents.MCP_SERVER) in x for x in sets)
    assert any(x.startswith("mcp_servers.blurt.env_vars=") and "BLURT_HOME" in x and "BLURT_RUN_ID" in x for x in sets)
    import tomllib
    for x in sets:  # each -c value is valid TOML
        tomllib.loads(x)
    no_mcp = cli("command", "codex", "headless", "--prompt", "p", "--repo", tmp_path, "--no-mcp")
    assert not [x for i, x in enumerate(no_mcp["argv"]) if no_mcp["argv"][i - 1] == "-c" and x.startswith("mcp_servers")]
    assert out["cwd"] == str(tmp_path.resolve()) and out["env"] == {"BLURT_AGENT": "codex", "BLURT_RUN_ID": "r-1"}
    # unattended on recording-derived text: never full access; codex writes only its cwd + Blurt's folders + uv's cache
    a = out["argv"]
    assert "danger-full-access" not in a and a[a.index("--sandbox") + 1] == "workspace-write"
    added = [a[i + 1] for i, x in enumerate(a) if x == "--add-dir"]
    uv_cache = os.environ.get("UV_CACHE_DIR") or str(Path(os.environ.get("XDG_CACHE_HOME") or env["home"] / ".cache") / "uv")
    assert added[:2] == [str(env["bh"]), uv_cache] and len(added) == 3  # + the inbox store (no projects here)
    assert "sandbox_workspace_write.network_access=true" in sets  # uv resolves the scripts' dependencies
    c = cli("command", "claude", "headless", "--prompt", "p", "--repo", tmp_path)
    assert c["argv"][1:3] == ["-p", "p"] and c["argv"][-3:] == ["--output-format", "stream-json", "--verbose"]
    assert "mcp__blurt" in c["argv"]  # allowed in -p mode
    assert "Bash" not in c["argv"] and "Bash(uv run:*)" in c["argv"]  # the skill's scripts, not any command
    for d in agents.definitions().values():  # no agent runs unattended in a yolo / full-access mode
        assert not {"--yolo", "danger-full-access", "--dangerously-skip-permissions", "bypassPermissions"} & set(d.get("run") or [])
    plain = cli("command", "claude", "headless", "--prompt", "p", "--repo", tmp_path, "--no-events")
    assert plain["events"] is None and "--output-format" not in plain["argv"]
    k = cli("command", "kimi", "headless", "--prompt", "p", "--repo", tmp_path)
    assert k["argv"][1:3] == ["-p", "p"] and k["events"] == "kimi-stream-json"
    bad = cli("command", "zcode", "headless", "--prompt", "p", "--repo", tmp_path, ok=False)
    assert bad["ok"] is False


def test_command_interactive(env, tmp_path):
    u = cli("command", "claude", "interactive", "--prompt", "修 登录 & bug", "--repo", tmp_path)
    q = parse_qs(urlparse(u["url"]).query)
    assert u["url"].startswith("claude-cli://open?") and q["q"] == ["修 登录 & bug"] and q["cwd"] == [str(tmp_path.resolve())]
    long = cli("command", "claude", "interactive", "--prompt", "x" * 6000, "--repo", tmp_path)
    assert long["prompt_file"] and Path(long["prompt_file"]).read_text() == "x" * 6000
    assert len(parse_qs(urlparse(long["url"]).query)["q"][0]) < 5000
    t = cli("command", "codex", "interactive", "--prompt", "hello", "--repo", tmp_path)
    assert t["terminal"] and t["argv"][1:] == ["hello"]
    k = cli("command", "kimi", "interactive", "--prompt", "hello", "--repo", tmp_path)
    assert k["terminal"] and k["argv"][1:] == [] and k["clipboard"] == "hello"
    z = cli("command", "zcode", "interactive", "--prompt", "hello", "--repo", tmp_path)
    assert z["clipboard"] == "hello" and z["argv"] is None


def test_install_dry_run_and_real(env, tmp_path):
    skill_link = env["home"] / ".claude" / "skills" / "blurt"
    dry = cli("install", "claude", "--dry-run")
    assert dry["applied"] is False
    acts = {c["action"] for c in dry["changes"]}
    assert acts == {"symlink", "run"} and not skill_link.exists()
    sym = next(c for c in dry["changes"] if c["action"] == "symlink")
    assert sym["path"] == str(skill_link) and sym["target"] == str(agents.SKILL_ROOT)
    run = next(c for c in dry["changes"] if c["action"] == "run")
    assert run["argv"][1:] == ["mcp", "add", "--scope", "user", "blurt", "--", "uv", "run", "--script",
                               str(agents.MCP_SERVER)]
    real = cli("install", "claude")
    assert real["applied"] and skill_link.resolve() == agents.SKILL_ROOT.resolve()
    again = cli("install", "claude")
    assert {c["action"] for c in again["changes"]} == {"exists"}


def test_install_codex_uses_codex_home(env):
    """Regression: CODEX_HOME must reach `codex mcp add` (a stripped CODEX_HOME writes the user's ~/.codex)."""
    out = cli("install", "codex", "--mcp")
    assert out["applied"]
    cfg = Path(os.environ["CODEX_HOME"]) / "config.toml"
    assert cfg.exists() and "mcp_server.py" in cfg.read_text()
    assert not (env["home"] / ".codex").exists()
    assert {c["action"] for c in cli("install", "codex", "--mcp")["changes"]} == {"exists"}


def test_install_kimi_json_merge(env):
    path = Path(os.environ["KIMI_CODE_HOME"]) / "mcp.json"
    path.parent.mkdir(parents=True)
    path.write_text(json.dumps({"mcpServers": {"other": {"command": "x"}}}))
    dry = cli("install", "kimi", "--mcp", "--dry-run")
    assert dry["changes"][0]["action"] == "json_merge" and dry["changes"][0]["path"] == str(path)
    assert "blurt" not in json.loads(path.read_text())["mcpServers"]
    cli("install", "kimi", "--mcp")
    data = json.loads(path.read_text())
    assert data["mcpServers"]["other"] == {"command": "x"}
    assert data["mcpServers"]["blurt"] == {"command": "uv", "args": ["run", "--script", str(agents.MCP_SERVER)]}
    assert cli("install", "kimi", "--mcp")["changes"][0]["action"] == "exists"


def test_install_never_overwrites_another_skill(env, tmp_path):
    other = tmp_path / "other-skill"
    other.mkdir()
    link = env["home"] / ".agents" / "skills" / "blurt"
    link.parent.mkdir(parents=True)
    link.symlink_to(other)
    out = cli("install", "codex", "--skill")
    assert out["changes"][0]["action"] == "conflict" and out["applied"] is False
    assert link.resolve() == other.resolve()


def test_session_command(env, tmp_path):
    """K5: interactive sessions get per-session hooks; the blurt MCP server only when it isn't installed."""
    import tomllib
    st = tmp_path / "j-1.claude-settings.json"
    c = agents.session_command("claude", "Read H-0001.md", tmp_path, job="j-1", settings=st, mcp=False)
    assert c["argv"][0].endswith("/claude") and c["argv"][1:] == ["--settings", str(st), "--", "Read H-0001.md"]
    assert c["hooks"] == "claude" and c["paste"] is None
    hooks = json.loads(st.read_text())["hooks"]
    assert list(hooks) == list(agents.CLAUDE_HOOKS) and hooks["PostToolUse"][0]["matcher"] == "*"
    cmd = hooks["Stop"][0]["hooks"][0]
    assert cmd["type"] == "command" and cmd["timeout"] == 5
    assert cmd["command"].endswith(f"'{agents.SESSIONS_PY}' hook --job j-1 --agent claude")
    # not installed (the fake's `mcp get blurt` fails) → --mcp-config with the whole server
    c = agents.session_command("claude", "p", tmp_path, job="j-1", settings=st)
    i = c["argv"].index("--mcp-config")
    assert json.loads(c["argv"][i + 1])["mcpServers"]["blurt"]["args"][-1] == str(agents.MCP_SERVER)
    assert c["argv"][-2:] == ["--", "p"]  # --mcp-config takes several values: the prompt must not become one
    x = agents.session_command("codex", "p", tmp_path, job="j-2", mcp=True)
    sets = [x["argv"][i + 1] for i, a in enumerate(x["argv"]) if a == "-c"]
    for v in sets:
        tomllib.loads(v)  # every -c value is valid TOML
    notify = tomllib.loads(sets[0])["notify"]
    assert notify[1:] == [str(agents.SESSIONS_PY), "hook", "--job", "j-2", "--agent", "codex"]
    hk = {k: v for v in sets if v.startswith("hooks.") for k, v in tomllib.loads(v)["hooks"].items()}
    assert list(hk) == list(agents.CODEX_HOOKS)
    # the same command for every session (Codex asks the user to trust each distinct hook once): job from $BLURT_JOB
    assert {h["hooks"][0]["command"] for g in hk.values() for h in g} == {agents.hook_command("codex", None)}
    assert any(v.startswith("mcp_servers.blurt.command") for v in sets) and x["argv"][-1] == "p"
    assert x["patterns"] and agents.session_command("codex", "p", tmp_path, job="j-3", mcp=False)["argv"].count("-c") == 7
    k = agents.session_command("kimi", "long prompt", tmp_path, job="j-4", mcp=False)
    assert k["argv"][1:] == [] and k["paste"] == "long prompt" and k["hooks"] is None
    for bad in ("zcode", "opencode", "nope"):  # no session / not installed / unknown
        with pytest.raises(ValueError):
            agents.session_command(bad, "p", tmp_path, job="j-5")


def test_hook_python_is_not_a_cache_venv():
    assert Path(agents.hook_python()).exists()
