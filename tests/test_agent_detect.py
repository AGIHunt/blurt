"""Finding and connecting agents (agents.py; docs/design/agent-setup.md §8): agents.json's shape, an app agent found by
its own config folder or its app (bundle ids / Windows program stems / Linux .desktop ids, parsed from fixtures),
the states Settings shows (connected / linked / found / missing), Connect into a folder that isn't there yet, the
SKILL_ROOT guard, the by-hand setup, custom agents, the card-drag targets and the agent-run environment (_common).

  uv run --with pytest pytest tests/test_agent_detect.py -q
"""
from __future__ import annotations

import json
import os
import struct
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "skills" / "blurt" / "scripts"
sys.path.insert(0, str(SCRIPTS))
import _common  # noqa: E402
import agents  # noqa: E402

REG = json.loads((SCRIPTS / "agents.json").read_text(encoding="utf-8"))
VERIFIED = {"run", "cli", "docs", "local", "unverified"}


@pytest.fixture()
def home(tmp_path, monkeypatch):
    h, bh = tmp_path / "home", tmp_path / "blurt-home"
    h.mkdir()
    bh.mkdir()
    for k in list(os.environ):
        if k.startswith(("CLAUDE", "CODEX_", "KIMI_", "GROK_")):
            monkeypatch.delenv(k, raising=False)
    monkeypatch.setenv("HOME", str(h))
    monkeypatch.setenv("BLURT_HOME", str(bh))
    monkeypatch.setenv("PATH", "/usr/bin:/bin")
    (bh / "config.json").write_text("{}")
    # no real apps: every lookup goes through the tables a test gives
    monkeypatch.setattr(agents, "mac_bundles", lambda dirs: {})
    monkeypatch.setattr(agents, "mdfind_bundles", lambda ids: {})
    monkeypatch.setattr(agents, "windows_found", lambda env: {})
    monkeypatch.setattr(agents, "linux_found", lambda env: {})
    return h


# ------------------------------------------------------------------ the data
def test_schema():
    ids = [a["id"] for a in REG["agents"]]
    assert len(ids) == len(set(ids))
    for a in REG["agents"]:
        assert a.get("name") and a.get("verified") in VERIFIED, a["id"]
        app = a.get("app") or {}
        assert set(app) <= {"macos", "windows", "linux"}, a["id"]
        for osk, v in app.items():
            for i in agents._as_list(v):
                if agents.is_path_id(i):
                    continue
                if osk == "macos":
                    assert "." in i and " " not in i, (a["id"], i)  # a bundle id
                else:
                    assert i == i.lower() and not i.endswith((".exe", ".desktop")), (a["id"], i)  # a stem / an id
        d = a.get("drop")
        assert d is None or d in ("composer", "terminal") or (isinstance(d, dict) and set(d.values()) <= {"composer", "terminal"})
        for k in ("app_verified", "skill_verified"):
            v = a.get(k)
            assert v is None or (isinstance(v, dict) and set(v.values()) <= VERIFIED) or v in VERIFIED, (a["id"], k)
        if a.get("headless") is False and a.get("connect") is not False:
            assert agents.connectable(a), a["id"]
        if a.get("headless") is False and (a.get("skill_dir") or a.get("mcp")):
            assert a.get("home"), f"{a['id']}: Connect writes into its home; say which folder that is"
        for k in ("install", "fix", "after", "edition"):
            if k in a:
                assert set(a[k]) == {"zh", "en"}, (a["id"], k)


def test_workbuddy_editions():
    d = agents.definitions({})
    cn, intl = d["workbuddy"], d["workbuddy-ai"]
    assert cn["home"] == "~/.workbuddy" and intl["home"] == "~/.workbuddy-ai"
    assert "codebuddy.cn/work" in cn["install"]["zh"] and "workbuddy.ai" in intl["install"]["en"]
    assert cn["skill_dir"].startswith("~/.workbuddy/") and intl["skill_dir"].startswith("~/.workbuddy-ai/")
    assert "信任" in cn["after"]["zh"] and "Trust" in intl["after"]["en"]


def test_subst_ignores_case_on_windows():
    env = {"PROGRAMFILES": "C:/Program Files", "LOCALAPPDATA": "C:/L"}
    assert agents._subst("${ProgramFiles}/x", env, nt=True) == "C:/Program Files/x"
    assert agents._subst("${LocalAppData:-D:/d}/y", env, nt=True) == "C:/L/y"
    assert agents._subst("${ProgramFiles}/x", env, nt=False) == "/x"


# ------------------------------------------------------------------ app lookups (pure parts)
def test_exe_stem():
    assert agents.exe_stem('"C:\\Program Files\\WorkBuddy\\WorkBuddy.exe",0') == "workbuddy"
    assert agents.exe_stem("C:\\Users\\u\\AppData\\Local\\Programs\\cursor\\Cursor.exe") == "cursor"
    assert agents.exe_stem("Trae CN.exe") == "trae cn"
    assert agents.exe_stem("C:\\x\\uninstall.ico") is None and agents.exe_stem("") is None


def _lnk(target: str, unicode: bool = True) -> bytes:
    """A minimal MS-SHLLINK file: header, no ID list, a LinkInfo with LocalBasePath (and its Unicode twin)."""
    head = struct.pack("<I16sI", 0x4C, b"\x01\x14\x02\x00" + b"\x00" * 12, 0x2) + b"\x00" * (0x4C - 24)
    ansi = target.encode("latin-1", "replace") + b"\0"
    hsize = 0x24 if unicode else 0x1C
    vol = b"\x10\x00\x00\x00" + b"\x00" * 12
    local_off = hsize + len(vol)
    uni = target.encode("utf-16-le") + b"\0\0"
    uni_off = local_off + len(ansi) + 1  # the common path suffix: one empty byte
    body = vol + ansi + b"\0" + (uni if unicode else b"")
    size = hsize + len(body)
    info = struct.pack("<IIIIIII", size, hsize, 0x1, hsize, local_off, 0, local_off + len(ansi))
    if unicode:
        info += struct.pack("<II", 0, uni_off)
    return head + info + body


def test_lnk_target():
    assert agents.lnk_target(_lnk("C:\\Program Files\\WorkBuddy\\WorkBuddy.exe")) == "C:\\Program Files\\WorkBuddy\\WorkBuddy.exe"
    assert agents.lnk_target(_lnk("C:\\Apps\\Kiro\\Kiro.exe", unicode=False)) == "C:\\Apps\\Kiro\\Kiro.exe"
    assert agents.lnk_target(b"not a shortcut") is None


def test_windows_stems_from_every_source():
    uninstall = [
        {"DisplayName": "WorkBuddy", "DisplayIcon": '"C:\\Program Files\\WorkBuddy\\WorkBuddy.exe",0'},
        {"DisplayName": "WorkBuddy AI", "InstallLocation": "C:\\Users\\u\\AppData\\Local\\Programs\\WorkBuddyAI"},
        {"DisplayName": "no icon"},
    ]
    listing = {"C:\\Users\\u\\AppData\\Local\\Programs\\WorkBuddyAI": ["WorkBuddy AI.exe", "Uninstall WorkBuddy AI.exe"]}
    found = agents.windows_stems(uninstall, ["Cursor.exe"], [("C:\\SM\\Trae CN.lnk", None),
                                                              ("C:\\SM\\Kiro.lnk", "C:\\Apps\\Kiro\\Kiro.exe")],
                                 ["C:\\Users\\u\\AppData\\Local\\Microsoft\\WinGet\\Links\\windsurf.exe"],
                                 listdir=lambda d: listing.get(d, []))
    assert {"workbuddy", "workbuddy ai", "cursor", "trae cn", "kiro", "windsurf"} <= set(found)
    assert found["workbuddy"].endswith("WorkBuddy.exe")


def test_desktop_entries():
    cursor = "[Desktop Entry]\nName=Cursor\nExec=/usr/share/cursor/cursor %F\nType=Application\nStartupWMClass=Cursor\n" \
             "[Desktop Action new-empty-window]\nExec=/usr/share/other\n"
    flat = "[Desktop Entry]\nName=Kiro\nExec=/usr/bin/flatpak run --branch=stable dev.kiro.Kiro @@u %U @@\nType=Application\n"
    snap = "[Desktop Entry]\nName=Windsurf\nExec=env BAMF_DESKTOP_FILE_HINT=x /snap/bin/windsurf %U\n"
    link = "[Desktop Entry]\nType=Link\nName=Docs\nURL=https://x\n"
    assert agents.desktop_entry(cursor)["program"] == "cursor"
    ids = agents.linux_ids({"/usr/share/applications/cursor.desktop": cursor,
                            "/var/lib/flatpak/exports/share/applications/dev.kiro.Kiro.desktop": flat,
                            "/var/lib/snapd/desktop/applications/windsurf_windsurf.desktop": snap,
                            "/usr/share/applications/docs.desktop": link})
    assert {"cursor", "kiro", "dev.kiro.kiro", "windsurf"} <= set(ids) and "docs" not in ids


def test_found_apps_by_id_and_path_and_cached(home, tmp_path, monkeypatch):
    table = {"com.example.a": "/Applications/A.app"}
    monkeypatch.setattr(agents, "os_key", lambda platform=None: "macos")
    monkeypatch.setattr(agents, "mac_bundles", lambda dirs: dict(table))
    app = tmp_path / "B.app"
    app.mkdir()
    defs = [{"id": "a", "app": {"macos": ["com.example.a"]}}, {"id": "b", "app": {"macos": ["com.example.none", str(app)]}},
            {"id": "c", "app": {"windows": ["c"]}}]
    assert agents.found_apps(defs, now=1000) == {"a": "/Applications/A.app", "b": str(app)}
    table.clear()
    assert agents.found_apps(defs, now=1000 + agents.APP_CACHE_TTL - 1)["a"] == "/Applications/A.app"  # kept
    assert agents.found_apps(defs, now=1000 + 5, fresh=True)["a"] is None  # Check Again looks again
    table["com.example.a"] = "/Applications/A.app"
    assert agents.found_apps(defs, now=1000 + agents.APP_CACHE_TTL + 10)["a"] == "/Applications/A.app"


# ------------------------------------------------------------------ states
def detect_one(aid: str, **kw) -> dict:
    return next(a for a in agents.detect(ids=[aid], login=False, version=False, **kw)["agents"] if a["id"] == aid)


def test_states_missing_found_linked_connected(home, monkeypatch, tmp_path):
    uv = tmp_path / "uv"
    uv.write_text("#!/bin/sh\n")
    uv.chmod(0o755)
    monkeypatch.setenv("PATH", f"{tmp_path}:/usr/bin:/bin")
    r = detect_one("workbuddy-ai")
    assert (r["conn"], r["found"], r["installed"], r["home"]) == ("missing", False, False, None)
    (home / ".workbuddy-ai").mkdir()  # the app has run once: its own folder is here
    r = detect_one("workbuddy-ai", fresh=True)
    assert r["conn"] == "found" and r["installed"] and r["home"] == str(home / ".workbuddy-ai") and not r["headless"]
    assert r["edition"] == "International" and r["connect"]
    out = agents.install("workbuddy-ai")
    assert out["applied"], out
    r = detect_one("workbuddy-ai")
    assert r["conn"] == "linked" and r["linked"] and r["last_seen"] is None
    agents.record_mcp_client("workbuddy-ai", "1.0", now=1_800_000_000)
    agents.record_mcp_client("codex-mcp-client", "0.1", now=1_800_000_100, via="app")  # the app's own run
    r = detect_one("workbuddy-ai")
    assert r["conn"] == "connected" and r["last_seen"] == 1_800_000_000
    assert detect_one("codex")["last_seen"] is None
    agents.record_mcp_client("codex-mcp-client", "0.2", now=1_800_000_200)
    assert detect_one("codex")["last_seen"] == 1_800_000_200
    # an organising run the app starts afterwards: Codex stays connected, used at the user's own time
    agents.record_mcp_client("codex-mcp-client", "0.2", now=1_800_000_300, via="app")
    r = detect_one("codex")
    assert r["last_seen"] == 1_800_000_200
    e = agents.mcp_clients()["codex-mcp-client"]
    assert (e["at"], e["app_at"], e.get("via")) == (1_800_000_200, 1_800_000_300, None)
    # and the user's next run doesn't forget the app's
    agents.record_mcp_client("codex-mcp-client", "0.3", now=1_800_000_400)
    e = agents.mcp_clients()["codex-mcp-client"]
    assert (e["at"], e["app_at"], e["version"]) == (1_800_000_400, 1_800_000_300, "0.3")


def test_an_older_app_entry_isnt_the_users(home):
    f = agents.mcp_clients_file()
    f.parent.mkdir(parents=True, exist_ok=True)
    f.write_text(json.dumps({"clients": {"codex-mcp-client": {"at": 5, "version": "0.1", "via": "app"}}}), encoding="utf-8")
    defs = agents.definitions({})
    assert agents.last_seen(defs) == {}
    agents.record_mcp_client("codex-mcp-client", "0.1", now=9, via="app")
    assert agents.mcp_clients()["codex-mcp-client"] == {"app_at": 9}
    assert agents.last_seen(defs) == {}


def test_app_agent_found_by_its_app(home, monkeypatch):
    monkeypatch.setattr(agents, "os_key", lambda platform=None: "windows")
    monkeypatch.setattr(agents, "windows_found", lambda env: {"WorkBuddy": "C:\\Program Files\\WorkBuddy\\WorkBuddy.exe"})
    r = detect_one("workbuddy", fresh=True)
    assert r["found"] and r["app"].endswith("WorkBuddy.exe") and r["conn"] == "found" and r["home"] is None


def test_client_names_map_to_agents():
    defs = agents.definitions({})
    assert agents.client_agent("claude-code", defs) == "claude"
    assert agents.client_agent("Cursor-VSCode", defs) == "cursor"
    assert agents.client_agent("WorkBuddy", defs) == "workbuddy"
    assert agents.client_agent("someone-else", defs) is None


def test_connect_anyway_writes_into_the_home(home, monkeypatch, tmp_path):
    """Not found (installed somewhere we don't look): Connect still writes into the agent's own folder."""
    uv = tmp_path / "uv"
    uv.write_text("#!/bin/sh\n")
    uv.chmod(0o755)
    monkeypatch.setenv("PATH", f"{tmp_path}:/usr/bin:/bin")
    out = agents.install("workbuddy")
    assert out["applied"]
    assert (home / ".workbuddy" / "skills" / "blurt" / "SKILL.md").is_file()
    cfg = json.loads((home / ".workbuddy" / "mcp.json").read_text())
    assert cfg["mcpServers"]["blurt"]["args"][-1] == str(agents.MCP_SERVER)


def test_empty_mcp_config_file_is_no_config(home, monkeypatch, tmp_path):
    (home / ".gemini" / "antigravity").mkdir(parents=True)
    (home / ".gemini" / "antigravity" / "mcp_config.json").write_text("")
    out = agents.install("antigravity", skill=False)
    assert out["applied"], out


def test_refuses_to_link_a_folder_without_skill_md(home, monkeypatch, tmp_path):
    bare = tmp_path / "install" / "resources"
    (bare / "scripts").mkdir(parents=True)
    monkeypatch.setattr(agents, "SKILL_ROOT", bare)
    out = agents.install("workbuddy", mcp=False)
    assert not out["applied"] and out["changes"][0]["action"] == "error" and "SKILL.md" in out["changes"][0]["error"]
    assert not (home / ".workbuddy" / "skills" / "blurt").exists()


def test_skill_root_prefers_a_folder_with_skill_md(home, tmp_path):
    scripts = tmp_path / "Program Files" / "Blurt" / "scripts"
    scripts.mkdir(parents=True)
    assert agents.skill_root(scripts) == scripts.parent  # nothing better: install() then refuses it
    app = Path(os.environ["BLURT_HOME"]) / "skill"
    (app / "scripts").mkdir(parents=True)
    (app / "SKILL.md").write_text("---\nname: blurt\n---\n")
    assert agents.skill_root(scripts) == app
    assert agents.skill_root(SCRIPTS) == SCRIPTS.parent  # a checkout keeps its own


# ------------------------------------------------------------------ by hand, custom agents
def test_manual(home):
    m = agents.manual("zh")
    j = json.loads(m["mcp_json"])["mcpServers"]["blurt"]
    assert j["command"] == m["command"] and j["args"] == ["run", "--script", m["server"]]
    assert Path(m["server"]).is_absolute() and Path(m["server"]).name == "mcp_server.py" and m["skill_ok"]
    assert m["skill"] in m["prompt"] and m["server"] in m["prompt"] and "hello" in m["prompt"]
    assert "hello" in agents.manual("en")["prompt"]
    # a Windows path survives JSON: json.dumps escapes its backslashes
    win = json.dumps({"command": "C:\\Users\\u\\.blurt\\bin\\uv.exe"})
    assert json.loads(win)["command"] == "C:\\Users\\u\\.blurt\\bin\\uv.exe"


def test_zip_skill(tmp_path):
    import zipfile
    out = agents.zip_skill(tmp_path / "blurt-skill")["path"]
    assert out.endswith(".zip")
    names = zipfile.ZipFile(out).namelist()
    assert "blurt/SKILL.md" in names and "blurt/scripts/agents.py" in names
    assert not any("__pycache__" in n or n.startswith("blurt/recorder/") or n.startswith("blurt/models/") for n in names)


def test_custom_agents(home):
    a = agents.add_custom("My Agent", home="~/.my-agent")
    assert a["id"] == "my-agent"
    b = agents.add_custom("My Agent")
    assert b["id"] == "my-agent-2"
    defs = agents.definitions()
    assert defs["my-agent"]["custom"] and not agents.is_headless(defs["my-agent"]) and agents.connectable(defs["my-agent"])
    rows = {r["id"]: r for r in agents.detect(login=False, version=False)["agents"]}
    assert rows["my-agent"]["custom"] and rows["my-agent"]["conn"] == "missing"
    (home / ".my-agent").mkdir()
    assert detect_one("my-agent")["conn"] == "found"
    assert agents.remove_custom("my-agent") and "my-agent" not in agents.definitions()
    assert not agents.remove_custom("claude")  # never a built-in


# ------------------------------------------------------------------ card-drag targets
def test_drop_targets_and_migration():
    t = {x["agent"]: x for x in agents.drop_targets({}, "windows")}
    assert t["workbuddy"]["drop"] == "composer" and t["cursor"]["drop"] == "terminal" and t["codex"]["ids"] == ["codex"]
    assert "claude" not in t  # claude.exe is the desktop app's chats and its Code tab in one window
    m = {x["agent"]: x for x in agents.drop_targets({}, "macos")}
    assert m["claude"]["ids"] == ["com.anthropic.claudefordesktop"] and m["claude"]["drop"] == "composer"
    assert all(x["on"] for x in t.values())
    legacy = {"record": {"agent_apps": {"cursor": False, "Zed": True}}}
    t = {x["agent"]: x for x in agents.drop_targets(legacy, "windows")}
    assert not t["cursor"]["on"] and t["zed"]["on"] and t["zed"]["custom"]
    patch = agents.migrate_agent_apps(legacy, "windows")["record"]
    assert patch["agent_apps"] is None and patch["agent_drop"] == {"cursor": False}
    (zid, zdef), = patch["agent_defs"].items()
    assert zdef["app"] == {"windows": ["Zed"]} and zdef["drop"] == "terminal" and zdef["connect"] is False
    after = {"record": {"agent_drop": patch["agent_drop"], "agent_defs": patch["agent_defs"]}}
    t2 = {x["agent"]: x for x in agents.drop_targets(after, "windows")}
    assert not t2["cursor"]["on"] and t2[zid]["on"] and t2[zid]["ids"] == ["zed"]


# ------------------------------------------------------------------ what an agent's run finds (_common)
def test_agent_runs_find_the_apps_tools_and_settings(home, monkeypatch):
    bh = Path(os.environ["BLURT_HOME"])
    (bh / "bin").mkdir()
    exe = "ffprobe.exe" if os.name == "nt" else "ffprobe"
    (bh / "bin" / exe).write_text("")
    (bh / "run").mkdir()
    (bh / "run" / "env.json").write_text(json.dumps({"env": {"UV_DEFAULT_INDEX": "https://mirror/simple/",
                                                             "HF_HOME": "/data/hf"}}))
    env = {"PATH": "/usr/bin", "HF_HOME": "/mine"}
    monkeypatch.setattr(_common, "IS_MAC", False)
    added = _common.apply_app_env(env)
    assert env["UV_DEFAULT_INDEX"] == "https://mirror/simple/" and env["HF_HOME"] == "/mine"  # the user's own wins
    assert env["PATH"].split(os.pathsep)[-1] == str(bh / "bin") and "HF_HOME" not in added
    monkeypatch.setattr(_common.shutil, "which", lambda n: None)
    assert _common.find_tool("ffprobe") == str(bh / "bin" / exe)
    assert _common.ffmpeg_bin("ffprobe") == str(bh / "bin" / exe)
