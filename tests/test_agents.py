"""agents.py WP2 commands (contract C5): detect, command, install (--dry-run and real, into temp dirs only),
repo-level order. Uses fake agent CLIs on PATH — never the real ones, never the user's config.

  uv run --with pytest pytest tests/test_agents.py -q
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

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
  mcp) f="$HOME/.claude-mcp-blurt"
       case "$2" in
         get) [ -f "$f" ] && cat "$f" && exit 0 || exit 1;;
         remove) rm -f "$f"; exit 0;;
       esac
       # like the real one: no add over an existing entry
       if [ -f "$f" ]; then echo "MCP server blurt already exists in user config" >&2; exit 1; fi
       shift 2; echo "$@" > "$f"; echo "Added stdio MCP server blurt";;
esac""",
    # codex: logged in; `mcp add` writes into $CODEX_HOME (the regression: CODEX_HOME must reach it)
    "codex": """
case "$1" in
  --version) echo "codex-cli 0.157.0";;
  login) if [ -f "$HOME/.codex-logged-out" ]; then echo "Not logged in"; exit 1; fi; echo "Logged in using ChatGPT" >&2;;
  mcp) d="${CODEX_HOME:-$HOME/.codex}"
       if [ "$2" = get ]; then  # --json like the real one: {"transport": {"command", "args"}} from the last add
         [ -f "$d/blurt.json" ] || { echo "Error: No MCP server named 'blurt' found." >&2; exit 1; }
         cat "$d/blurt.json"; exit 0
       fi
       mkdir -p "$d"; shift 4; cmd="$1"; shift  # mcp add blurt -- CMD ARGS… (overwrites, like the real one)
       echo "[mcp_servers.blurt] $cmd $*" >> "$d/config.toml"
       a=""; for x in "$@"; do a="$a${a:+, }\\"$x\\""; done
       printf '{"name": "blurt", "transport": {"type": "stdio", "command": "%s", "args": [%s]}}\n' "$cmd" "$a" > "$d/blurt.json"
       echo "Added global MCP server 'blurt'.";;
esac""",
    "kimi": """
case "$1" in
  --version) echo "0.36.0";;
  provider) echo "managed:kimi-code  models=3";;
esac""",
    # grok: `grok models` says whether it is signed in (no tokens spent); a marker file signs it out
    "grok": """
case "$1" in
  --version) echo "grok 1.0.70 (f50904eaee6c)";;
  models) if [ -f "$HOME/.grok-offline" ]; then echo "error sending request for url (https://api.x.ai/v1/models)" >&2; exit 1; fi
          if [ -f "$HOME/.grok-signed-out" ]; then echo "Not logged in. Run grok login to sign in." >&2; exit 1; fi
          printf 'You are logged in with grok.com.\\n\\nDefault model: grok-4.7\\n';;
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
        if k.startswith(("CLAUDE", "CODEX_", "KIMI_", "GROK_", "XAI_")):
            monkeypatch.delenv(k, raising=False)
    monkeypatch.setenv("HOME", str(home))
    monkeypatch.setenv("BLURT_HOME", str(bh))
    monkeypatch.setenv("PATH", f"{bin_}:/usr/bin:/bin")
    monkeypatch.setenv("CODEX_HOME", str(tmp_path / "codex-home"))
    monkeypatch.setenv("KIMI_CODE_HOME", str(tmp_path / "kimi-home"))
    monkeypatch.setenv("GROK_HOME", str(tmp_path / "grok-home"))
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
        assert "interactive" not in a, a["id"]  # Blurt starts no interactive agent: the user hands items to their own
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
        assert {"id", "name", "path", "state", "why", "fix", "installed", "version", "login", "headless"} <= set(r)
        assert "interactive" not in r and "session" not in r
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
    # a project's .blurt/ is writable to the sandboxed organizing run: it may reorder agents, never define one
    (repo / ".blurt" / "config.json").write_text(json.dumps({"record": {"agents": ["kimi", "codex"], "agent_defs": {
        "codex": {"bins": ["sh"], "run": ["-c", "touch pwned"]}, "evil": {"bins": ["sh"], "run": ["-c", "{prompt}"]}}}}))
    assert cli("order", "--json", "--repo", repo)["order"] == ["kimi", "codex"]
    defs = agents.definitions(agents.config(repo))
    assert "evil" not in defs and defs["codex"]["run"] == agents.registry()["agents"][1]["run"]
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
    assert f"mcp_servers.blurt.command={json.dumps(agents.uv_path())}" in sets and any(str(agents.MCP_SERVER) in x for x in sets)
    assert any(x.startswith("mcp_servers.blurt.env_vars=") and "BLURT_HOME" in x and "BLURT_RUN_ID" in x for x in sets)
    import tomllib
    for x in sets:  # each -c value is valid TOML
        tomllib.loads(x)
    no_mcp = cli("command", "codex", "headless", "--prompt", "p", "--repo", tmp_path, "--no-mcp")
    assert not [x for i, x in enumerate(no_mcp["argv"]) if no_mcp["argv"][i - 1] == "-c" and x.startswith("mcp_servers")]
    uv_box = env["bh"] / "sandbox" / "uv-cache"  # its own uv cache; the shared one stays read-only to it
    assert out["cwd"] == str(tmp_path.resolve()) and out["env"] == {
        "BLURT_AGENT": "codex", "BLURT_RUN_ID": "r-1", "UV_CACHE_DIR": str(uv_box), "BLURT_NO_INDEX": "1"}
    assert uv_box.is_dir() and out["scripts"] == str(SCRIPTS)
    # unattended on recording-derived text: never full access; a plain run (routing) writes only its cwd
    a = out["argv"]
    assert "danger-full-access" not in a and a[a.index("--sandbox") + 1] == "workspace-write"
    assert "--add-dir" not in a
    assert "sandbox_workspace_write.network_access=true" in sets  # uv resolves the scripts' dependencies
    # an organizing run: + the item stores and its uv cache — never $BLURT_HOME (config.json, jobs, hooks) or ~/.cache/uv
    store = tmp_path / "proj" / ".blurt"
    store.mkdir(parents=True)
    import store as st
    st.inbox_root().mkdir(parents=True, exist_ok=True)
    (env["bh"] / "projects.json").write_text(json.dumps({"schema": 1, "projects": [
        {"id": "p1", "name": "proj", "key": "PR", "path": str(tmp_path / "proj")},
        {"id": "p2", "name": "moved", "key": "MV", "path": str(tmp_path / "moved")}]}))
    p = cli("command", "codex", "headless", "--prompt", "p", "--repo", tmp_path, "--processing")["argv"]
    added = [p[i + 1] for i, x in enumerate(p) if x == "--add-dir"]
    assert added == [str(st.inbox_root()), str(store), str(uv_box)]  # the moved project: nothing
    assert not [d for d in added if d == str(env["bh"]) or Path(d) in Path(env["bh"]).parents or d.endswith("/.cache/uv")]
    c = cli("command", "claude", "headless", "--prompt", "p", "--repo", tmp_path)
    assert c["argv"][1:3] == ["-p", "p"] and c["argv"][-3:] == ["--output-format", "stream-json", "--verbose"]
    assert "mcp__blurt" in c["argv"]  # allowed in -p mode
    # shell: only the skill's own scripts, each by its absolute path (no `uv run sh -c …`, no `uv run --with …`)
    shell = [x for x in c["argv"] if x.startswith("Bash")]
    assert f"Bash(uv run {SCRIPTS}/items.py:*)" in shell and f"Bash(uv run {SCRIPTS}/projects.py list:*)" in shell
    assert all(x.startswith(f"Bash(uv run {SCRIPTS}/") and ".py" in x for x in shell)
    assert not {"Write", "Edit", "Bash"} & set(c["argv"]) and c["env"] == {"BLURT_AGENT": "claude"}  # edits: cwd only
    g = cli("command", "gemini", "headless", "--prompt", "p", "--repo", tmp_path)["argv"]
    gs = [x for x in g if x.startswith("run_shell_command")]
    assert gs and all(x.startswith(f"run_shell_command(uv run {SCRIPTS}/") for x in gs) and "--yolo" not in g
    for d in agents.definitions().values():  # no agent runs unattended in a yolo / full-access mode
        assert not {"--yolo", "danger-full-access", "--dangerously-skip-permissions", "bypassPermissions"} & set(d.get("run") or [])
    plain = cli("command", "claude", "headless", "--prompt", "p", "--repo", tmp_path, "--no-events")
    assert plain["events"] is None and "--output-format" not in plain["argv"]
    k = cli("command", "kimi", "headless", "--prompt", "p", "--repo", tmp_path)
    assert k["argv"][1:3] == ["-p", "p"] and k["events"] == "kimi-stream-json"
    bad = cli("command", "zcode", "headless", "--prompt", "p", "--repo", tmp_path, ok=False)
    assert bad["ok"] is False


def test_grok(env, tmp_path):
    """Grok (xAI's CLI): signed in or not from `grok models` (no tokens), a least-privilege unattended run, its models
    from its own cache (a map, no cheap one) and its default from [models] default in config.toml."""
    rows = {r["id"]: r for r in cli("detect", "--ids", "grok")["agents"]}
    assert rows["grok"]["state"] == "ready" and rows["grok"]["version"].startswith("grok 1.0.70")
    (env["home"] / ".grok-signed-out").write_text("")
    assert cli("detect", "--ids", "grok")["agents"][0]["state"] == "logged_out"
    a = cli("command", "grok", "headless", "--prompt", "p", "--repo", tmp_path)["argv"]
    assert a[1:3] == ["-p", "p"] and a[a.index("--permission-mode") + 1] == "dontAsk"   # nothing it isn't allowed
    allowed = [a[i + 1] for i, x in enumerate(a) if x == "--allow"]
    assert "Edit(./**)" in allowed and not {"Bash", "Edit", "*", "Write"} & set(allowed)
    assert all(x.startswith(f"Bash(uv run {SCRIPTS}/") for x in allowed if x.startswith("Bash"))
    assert "--always-approve" not in a and a[-2:] == ["--output-format", "streaming-json"]
    # grok searches and fetches the web without asking in every mode, dontAsk included: an unattended run gets neither
    assert "--disable-web-search" in a and "--no-auto-update" in a
    gh = Path(os.environ["GROK_HOME"])
    gh.mkdir()
    # `grok models` needs the network: offline (or too slow) it says neither way, so auth.json decides
    (env["home"] / ".grok-signed-out").unlink()
    (env["home"] / ".grok-offline").write_text("")
    assert cli("detect", "--ids", "grok")["agents"][0]["state"] == "logged_out"      # no credentials on disk
    (gh / "auth.json").write_text("{}")
    assert cli("detect", "--ids", "grok")["agents"][0]["state"] == "configured"      # under $GROK_HOME, not ~/.grok
    (env["home"] / ".grok-offline").unlink()
    assert cli("detect", "--ids", "grok")["agents"][0]["state"] == "ready"
    grok = next(d for d in agents.registry()["agents"] if d["id"] == "grok")
    genv = {"GROK_HOME": str(gh)}
    assert agents.parse_status(grok, None, "", genv, env["home"]) == "configured"     # timed out, signed in before
    (gh / "auth.json").unlink()
    assert agents.parse_status(grok, None, "", genv, env["home"]) == "unknown"        # timed out, nothing to go on
    (gh / "models_cache.json").write_text(json.dumps({"models": {
        "grok-4.7": {"info": {"id": "grok-4.7", "name": "Grok 4.7", "description": "latest", "hidden": False}},
        "grok-4.7-build-fast": {"info": {"id": "grok-4.7-build-fast", "name": "Grok 4.7 Fast",
                                          "description": "Fast variant. 2x the price.", "hidden": False}},
        "grok-old": {"info": {"id": "grok-old", "name": "Old", "hidden": True}}}}))
    (gh / "config.toml").write_text('[cli]\ninstaller = "internal"\n\n[models]\ndefault = "grok-4.6"\n')
    m = cli("models", "grok")
    assert [x["id"] for x in m["models"]] == ["grok-4.7", "grok-4.7-build-fast"] and m["cheapest"] is None
    assert m["cli_default"] == "grok-4.6" and m["processing"]["cards"] == {"model": None, "effort": "low"}
    p = cli("command", "grok", "headless", "--prompt", "p", "--repo", tmp_path, "--processing", "cards")["argv"]
    assert "-m" not in p and p[p.index("--effort") + 1] == "low"   # "cheapest" with none known: grok's own default
    assert agents._toml_top(gh / "config.toml", "installer") is None    # a table's key is not a top-level one
    (gh / "config.toml").write_text('model = "x"\nmodels.default = "grok-4.5"\n')
    assert agents._toml_top(gh / "config.toml", "models.default") == "grok-4.5"
    assert agents._toml_top(gh / "config.toml", "model") == "x"


def test_command_is_headless_only(env, tmp_path):
    r = subprocess.run([sys.executable, str(SCRIPTS / "agents.py"), "command", "claude", "interactive", "--prompt", "p",
                        "--repo", str(tmp_path)], capture_output=True, text=True, env=os.environ.copy())
    assert r.returncode != 0 and "invalid choice" in r.stderr
    with pytest.raises(ValueError):
        agents.command("claude", "interactive", "p", tmp_path)
    with pytest.raises(ValueError):
        agents.command("zcode", "headless", "p", tmp_path)  # connect only
    h = cli("command", "claude", "headless", "--prompt", "p", "--repo", tmp_path)
    assert h["mode"] == "headless" and h["argv"][1:3] == ["-p", "p"]
    assert not {"url", "terminal", "clipboard", "open_app", "prompt_file"} & set(h)


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


@pytest.mark.parametrize("agent, skill_dir, mcp_json", [
    ("workbuddy", ".workbuddy/skills", ".workbuddy/mcp.json"),
    ("cursor", ".agents/skills", ".cursor/mcp.json"),
    ("codebuddy", ".codebuddy/skills", ".codebuddy/mcp.json"),
])
def test_install_connect_only_agents(env, tmp_path, agent, skill_dir, mcp_json):
    """CodeBuddy Code, WorkBuddy and Cursor: connect only (skill + MCP), never run unattended."""
    uv = env["tmp"] / "bin" / "uv"
    uv.write_text("#!/bin/sh\n")
    uv.chmod(0o755)
    d = agents.definitions({})[agent]
    assert not agents.is_headless(d)
    path = env["home"] / mcp_json
    path.parent.mkdir(parents=True)
    path.write_text(json.dumps({"mcpServers": {"other": {"url": "https://example.com/mcp", "disabled": True}}}))
    dry = cli("install", agent, "--dry-run")
    assert [c["action"] for c in dry["changes"]] == ["symlink", "json_merge"] and dry["applied"] is False
    assert not (env["home"] / skill_dir / "blurt").exists()
    out = cli("install", agent)
    assert out["applied"]
    assert (env["home"] / skill_dir / "blurt").resolve() == agents.SKILL_ROOT.resolve()
    data = json.loads(path.read_text())
    assert data["mcpServers"]["other"] == {"url": "https://example.com/mcp", "disabled": True}
    assert data["mcpServers"]["blurt"] == {"command": str(uv),  # uv by its full path: the agent starts the server
                                           "args": ["run", "--script", str(agents.MCP_SERVER)]}
    assert {c["action"] for c in cli("install", agent)["changes"]} == {"exists"}


def test_install_never_overwrites_another_skill(env, tmp_path):
    other = tmp_path / "other-skill"
    other.mkdir()
    link = env["home"] / ".agents" / "skills" / "blurt"
    link.parent.mkdir(parents=True)
    link.symlink_to(other)
    out = cli("install", "codex", "--skill")
    assert out["changes"][0]["action"] == "conflict" and out["applied"] is False
    assert link.resolve() == other.resolve()


def _fake_uv(env) -> Path:
    uv = env["tmp"] / "bin" / "uv"
    uv.write_text("#!/bin/sh\n")
    uv.chmod(0o755)
    return uv


def test_codex_on_another_model_provider_is_configured(env):
    """Codex pointed at a third-party provider in $CODEX_HOME/config.toml (cc-switch & co.) has no ChatGPT login:
    `codex login status` says "Not logged in", but it runs. It is usable ("configured"), not "log in first"."""
    (env["home"] / ".codex-logged-out").write_text("")
    codex_home = Path(os.environ["CODEX_HOME"])
    codex_home.mkdir()
    cfg = codex_home / "config.toml"
    state = lambda: {r["id"]: r for r in cli("detect", "--ids", "codex")["agents"]}["codex"]  # noqa: E731
    assert state()["state"] == "logged_out" and "codex login" in state()["fix"]   # no config: the login is it
    cfg.write_text('model_provider = "deepseek"\nmodel = "deepseek-chat"\n\n'
                   '[model_providers.deepseek]\nname = "DeepSeek"\nbase_url = "https://api.deepseek.com/v1"\n'
                   'env_key = "DEEPSEEK_API_KEY"\n')
    r = state()
    assert r["state"] == "configured" and r["fix"] == "" and cli("detect", "--ids", "codex")["pick"] == "codex"
    cfg.write_text('model_provider = "openai"\n')                                 # OpenAI's own: the login counts
    assert state()["state"] == "logged_out"
    # a profile's own model_provider wins over the top-level one (codex's rule)
    cfg.write_text('profile = "work"\nmodel_provider = "openai"\n\n[profiles.work]\nmodel_provider = "kimi"\n')
    assert state()["state"] == "configured"
    cfg.write_text('profile = "home"\nmodel_provider = "kimi"\n\n[profiles.home]\nmodel_provider = "openai"\n')
    assert state()["state"] == "logged_out"
    cfg.write_text("model_provider = 'litellm'\n")                                # a TOML literal string
    assert state()["state"] == "configured"
    cfg.write_text('model_provider = "x\n')                                       # not TOML: nothing to go on
    assert state()["state"] == "logged_out"
    # only under $CODEX_HOME, never the user's ~/.codex when CODEX_HOME points elsewhere
    codex = next(d for d in agents.registry()["agents"] if d["id"] == "codex")
    cfg.write_text('model_provider = "deepseek"\n')
    assert agents.other_provider(codex, {"CODEX_HOME": str(codex_home)}, env["home"]) == "deepseek"
    assert agents.other_provider(codex, {}, env["home"]) is None


def test_codex_on_another_provider_keeps_its_own_model(env, tmp_path):
    """models_cache.json lists OpenAI's models: on another provider a cards run must not pass OpenAI's cheap one."""
    codex_home = Path(os.environ["CODEX_HOME"])
    codex_home.mkdir()
    (codex_home / "models_cache.json").write_text(json.dumps({"models": [
        {"slug": "gpt-big", "priority": 1, "description": "Frontier"},
        {"slug": "gpt-mini", "priority": 2, "description": "Smaller, cheaper, fast"}]}))
    (codex_home / "config.toml").write_text('model = "gpt-big"\n')
    assert cli("models", "codex")["cheapest"] == "gpt-mini"
    (codex_home / "config.toml").write_text('model_provider = "deepseek"\nmodel = "deepseek-chat"\n')
    m = cli("models", "codex")
    assert m["models"] == [] and m["cheapest"] is None and m["cli_default"] == "deepseek-chat"
    p = cli("command", "codex", "headless", "--prompt", "p", "--repo", tmp_path, "--processing", "cards")["argv"]
    assert "-m" not in p


def test_every_mcp_entry_starts_uv_by_its_full_path(env, tmp_path):
    """Every agent starts the blurt MCP server itself, often without our PATH (Windows / Linux: the app's uv is in
    $BLURT_HOME/bin, on no one else's PATH): no entry may say a bare `uv`."""
    for d in agents.registry()["agents"]:
        m = d.get("mcp") or {}
        text = json.dumps(m.get("args") or (m.get("json") or {}).get("value") or [])
        assert '"uv"' not in text, d["id"]
        assert '"uv"' not in json.dumps(d.get("headless_mcp") or {}) and '\\"uv\\"' not in json.dumps(d.get("headless_mcp") or {})
    # no uv on PATH: the app's own copy in $BLURT_HOME/bin
    assert agents.uv_path({"PATH": "/nonexistent"}) == "uv"
    (env["bh"] / "bin").mkdir()
    own = env["bh"] / "bin" / "uv"
    own.write_text("#!/bin/sh\n")
    own.chmod(0o755)
    assert agents.uv_path({"PATH": "/nonexistent"}) == str(own)
    run = next(c for c in cli("install", "codex", "--mcp", "--dry-run")["changes"] if c["action"] == "run")
    assert run["argv"][run["argv"].index("--") + 1] == str(own)
    a = cli("command", "codex", "headless", "--prompt", "p", "--repo", tmp_path)["argv"]
    assert f"mcp_servers.blurt.command={json.dumps(str(own))}" in a
    # a Windows path in codex's -c: valid TOML, backslashes kept
    import tomllib
    win = "C:\\Users\\Ann Lee\\.blurt\\bin\\uv.exe"
    hm = next(d for d in agents.registry()["agents"] if d["id"] == "codex")["headless_mcp"]["args"]
    filled = agents._fill(hm, {"uv_json": json.dumps(win), "mcp_server_json": json.dumps("C:\\s\\mcp_server.py")})
    assert tomllib.loads(filled[1])["mcp_servers"]["blurt"]["command"] == win


def test_install_rewrites_a_stale_mcp_entry(env):
    """An entry registered before (a bare `uv`, which Windows can't start) is written again with uv's full path;
    one that already says what we'd write is left alone. Codex `mcp add` overwrites; claude needs `mcp remove` first."""
    uv = _fake_uv(env)
    codex_home = Path(os.environ["CODEX_HOME"])
    codex_home.mkdir()
    (codex_home / "blurt.json").write_text(json.dumps(
        {"name": "blurt", "transport": {"command": "uv", "args": ["run", "--script", str(agents.MCP_SERVER)]}}))
    dry = cli("install", "codex", "--mcp", "--dry-run")["changes"]
    assert [c["action"] for c in dry] == ["run"] and dry[0]["replaces"] == "stale"
    out = cli("install", "codex", "--mcp")
    assert out["applied"] and json.loads((codex_home / "blurt.json").read_text())["transport"]["command"] == str(uv)
    assert [c["action"] for c in cli("install", "codex", "--mcp")["changes"]] == ["exists"]
    (env["home"] / ".claude-mcp-blurt").write_text(f"--scope user blurt -- uv run --script {agents.MCP_SERVER}\n")
    out = cli("install", "claude", "--mcp")
    assert out["applied"] and out["changes"][0]["replaces"] == "stale"
    assert str(uv) in (env["home"] / ".claude-mcp-blurt").read_text()
    assert [c["action"] for c in cli("install", "claude", "--mcp")["changes"]] == ["exists"]
    assert agents._names_all('{"transport": {"command": "C:\\\\b\\\\uv.exe", "args": ["run"]}}', ["C:\\b\\uv.exe"])
    assert not agents._names_all('{"transport": {"command": "uv"}}', ["/x/uv"])
    assert agents._names_all("Command: /x/uv\nArgs: run --script /s/m.py", ["/x/uv", "/s/m.py"])


def test_install_skill_copy_fallback(env, tmp_path, monkeypatch):
    """Where neither a symlink nor a junction can be made (Windows without one): a marked copy, which the next install
    brings up to date and reports as there — never a copy of something else."""
    target = tmp_path / "skills" / "blurt"
    target.parent.mkdir()
    assert agents._link_dir(target, agents.SKILL_ROOT, copy=True) == "copy"
    assert (target / "SKILL.md").read_bytes() == (agents.SKILL_ROOT / "SKILL.md").read_bytes()
    assert not list(target.rglob("__pycache__")) and agents._our_copy(target)
    (target / "SKILL.md").write_text("old")
    cfg = {"record": {"agent_defs": {"t": {"skill_dir": str(target.parent)}}}}
    dry = agents.install("t", mcp=False, dry_run=True, cfg=cfg)["changes"][0]
    assert dry["action"] == "exists" and dry["kind"] == "copy" and (target / "SKILL.md").read_text() == "old"
    ch = agents.install("t", mcp=False, cfg=cfg)
    assert ch["applied"] and ch["changes"][0]["refreshed"] is True
    assert (target / "SKILL.md").read_bytes() == (agents.SKILL_ROOT / "SKILL.md").read_bytes()
    (target / agents.COPY_MARK).write_text("/somewhere/else")                     # a copy of another skill: not ours
    assert agents.install("t", mcp=False, cfg=cfg)["changes"][0]["action"] == "conflict"


@pytest.mark.skipif(sys.platform != "darwin" or not shutil.which("codex"), reason="codex's own macOS seatbelt")
def test_codex_sandbox_keeps_blurt_home_read_only(tmp_path, monkeypatch):
    """The organizing run's writable roots under codex's real sandbox (`codex sandbox`, no model call, a scratch
    CODEX_HOME): the item stores and the session yes; $BLURT_HOME's config.json, its jobs' hook settings and the
    project's code no — a write there would run outside the sandbox later."""
    bh, ws, proj = tmp_path / "home", tmp_path / "ws", tmp_path / "proj"
    for d in (bh / "jobs", ws / "inbox" / "sessions" / "s1", proj / ".blurt" / "items", proj / "src", tmp_path / "codex"):
        d.mkdir(parents=True)
    (bh / "config.json").write_text("{}")
    (bh / "jobs" / "j-1.claude-settings.json").write_text("{}")
    (bh / "projects.json").write_text(json.dumps({"schema": 1, "projects": [{"id": "p1", "name": "p", "key": "PR", "path": str(proj)}]}))
    for k, v in {"BLURT_HOME": bh, "BLURT_WORKSPACE": ws, "CODEX_HOME": tmp_path / "codex"}.items():
        monkeypatch.setenv(k, str(v))
    roots = agents.writable_dirs()
    session = ws / "inbox" / "sessions" / "s1"
    probes = {"session": session / "items.json", "inbox": ws / "inbox" / "items" / "x.md", "store": proj / ".blurt" / "items" / "x.md",
              "uv": agents.sandbox_uv_cache() / "x", "config": bh / "config.json", "hooks": bh / "jobs" / "j-1.claude-settings.json",
              "home": bh / "x", "code": proj / "src" / "x"}
    (ws / "inbox" / "items").mkdir()
    agents.sandbox_uv_cache().mkdir(parents=True)
    script = "; ".join(f"(echo x >> '{p}') 2>/dev/null && echo {k}=w || echo {k}=r" for k, p in probes.items())
    p = subprocess.run(["codex", "sandbox", "-c", 'sandbox_mode="workspace-write"', "-c", "sandbox_workspace_write.exclude_slash_tmp=true",
                        "-c", "sandbox_workspace_write.exclude_tmpdir_env_var=true",
                        "-c", f"sandbox_workspace_write.writable_roots={json.dumps(roots)}", "--", "/bin/sh", "-c", script],
                       cwd=session, capture_output=True, text=True, timeout=60)
    got = dict(line.split("=") for line in p.stdout.split() if "=" in line)
    assert got == {"session": "w", "inbox": "w", "store": "w", "uv": "w", "config": "r", "hooks": "r", "home": "r", "code": "r"}, p.stderr


def test_shim_target_is_the_native_program_not_node():
    """npm .cmd shims (texts from a Windows VM, npm 10 / Node 22): Claude Code's runs its claude.exe; Codex's runs
    codex.js with the node.exe next to it when there is one (portable Node, nvm-windows). That node.exe is not codex."""
    head = "@ECHO off\r\nGOTO start\r\n:find_dp0\r\nSET dp0=%~dp0\r\nEXIT /b\r\n:start\r\nSETLOCAL\r\nCALL :find_dp0\r\n"
    claude = head + '"%dp0%\\node_modules\\@anthropic-ai\\claude-code\\bin\\claude.exe"   %*\r\n'
    codex = head + ('\r\nIF EXIST "%dp0%\\node.exe" (\r\n  SET "_prog=%dp0%\\node.exe"\r\n) ELSE (\r\n  SET "_prog=node"\r\n'
                    '  SET PATHEXT=%PATHEXT:;.JS;=;%\r\n)\r\n\r\nendLocal & goto #_undefined_# 2>NUL || title %COMSPEC% & '
                    '"%_prog%"  "%dp0%\\node_modules\\@openai\\codex\\bin\\codex.js" %*\r\n')
    assert agents.shim_target(claude) == "node_modules\\@anthropic-ai\\claude-code\\bin\\claude.exe"
    assert agents.shim_target(codex) is None
