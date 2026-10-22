"""mcp_server.py (contract C4, v0.7 behaviour in K1) through the official MCP Python client over stdio: all 7 tools,
images in get_item, writes through items.py, mark_fixed ending at to-verify, v0.6 sessions migrated on first touch. The server runs as agents launch it (`uv run --script mcp_server.py`); the client runs
in its own `uv run --with mcp` interpreter, so this test needs uv (skipped without it).

  uv run --with pytest --with pillow pytest tests/test_mcp.py -q
"""
from __future__ import annotations

import base64
import io
import json
import os
import shutil
import subprocess
import sys
import textwrap
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "skills" / "blurt" / "scripts"
sys.path.insert(0, str(Path(__file__).parent))
from test_index import copy_fixtures  # noqa: E402

pytestmark = pytest.mark.skipif(not shutil.which("uv"), reason="needs uv")

CLIENT = textwrap.dedent('''
    import asyncio, json, os, sys
    from mcp import ClientSession, StdioServerParameters
    from mcp.client.stdio import stdio_client

    def dump(res):
        out = {"is_error": bool(res.isError), "content": []}
        for c in res.content:
            if c.type == "text":
                out["content"].append({"type": "text", "text": c.text})
            elif c.type == "image":
                out["content"].append({"type": "image", "mimeType": c.mimeType, "data": c.data})
        if getattr(res, "structuredContent", None) is not None:
            out["structured"] = res.structuredContent
        return out

    async def main():
        calls = json.loads(sys.argv[2])
        params = StdioServerParameters(command="uv", args=["run", "-q", "--script", sys.argv[1]], env=dict(os.environ))
        results = {}
        async with stdio_client(params) as (r, w):
            async with ClientSession(r, w) as s:
                init = await s.initialize()
                tools = await s.list_tools()
                results["_server"] = init.serverInfo.name
                results["_tools"] = {t.name: {"description": t.description, "params": sorted(t.inputSchema.get("properties", {}))}
                                     for t in tools.tools}
                for key, name, args in calls:
                    if isinstance(args, dict) and "$uid" in json.dumps(args):  # fill the uid found by an earlier call
                        args = json.loads(json.dumps(args).replace("$uid", results["_uid"]))
                    res = await s.call_tool(name, args)
                    results[key] = dump(res)
                    if key == "search":
                        rows = json.loads(res.content[0].text) if res.content else []
                        rows = rows if isinstance(rows, list) else [rows]
                        results["_uid"] = (res.structuredContent or {}).get("result", rows)[0]["uid"]
        print(json.dumps(results, ensure_ascii=False))

    asyncio.run(main())
''')


@pytest.fixture()
def env(tmp_path):
    home, repo, bh = tmp_path / "home", tmp_path / "repo", tmp_path / "blurt-home"
    copy_fixtures(home, repo)
    bh.mkdir()
    # a big frame, to check the ≤ 1280 px downscale
    from PIL import Image
    big = repo / ".blurt" / "sessions" / "20261019-093000" / "frames" / "I-001-1.jpg"
    Image.new("RGB", (2400, 1500), (200, 40, 40)).save(big, quality=70)
    e = {k: v for k, v in os.environ.items() if not k.startswith(("CLAUDE", "CODEX_", "MCP_"))}
    # uv keeps its cache and Pythons under HOME: point it at the real ones before HOME moves
    for var, cmd in (("UV_CACHE_DIR", ["uv", "cache", "dir"]), ("UV_PYTHON_INSTALL_DIR", ["uv", "python", "dir"])):
        e.setdefault(var, subprocess.run(cmd, capture_output=True, text=True).stdout.strip())
    e.update(HOME=str(home), BLURT_HOME=str(bh), BLURT_WORKSPACE=str(home / "Blurt"), BLURT_AGENT="claude",
             BLURT_NO_ROUTE="1")
    for k in ("BLURT_NO_INDEX", "BLURT_JOB", "BLURT_RUN_ID", "BLURT_PROJECT"):
        e.pop(k, None)
    (bh / "config.json").write_text('{"record": {"install_app": false}, "lang": "en"}')
    # the index knows the repo (as after the app bound it, or a scan with --root)
    subprocess.run([sys.executable, str(SCRIPTS / "index.py"), "scan", "--root", str(repo)], check=True, env=e,
                   capture_output=True)
    return {"home": home, "repo": repo, "bh": bh, "env": e, "tmp": tmp_path}


def run_client(env, calls) -> dict:
    client = env["tmp"] / "client.py"
    client.write_text(CLIENT, encoding="utf-8")
    p = subprocess.run(["uv", "run", "-q", "--no-project", "--with", "mcp>=1.20,<2", "python", str(client),
                        str(SCRIPTS / "mcp_server.py"), json.dumps(calls)], capture_output=True, text=True,
                       encoding="utf-8", env=env["env"], timeout=300, cwd=env["tmp"])
    assert p.returncode == 0, p.stderr[-3000:]
    return json.loads(p.stdout.strip().splitlines()[-1])


def text_json(res):
    assert not res["is_error"], res
    if "structured" in res:
        s = res["structured"]
        return s["result"] if isinstance(s, dict) and set(s) == {"result"} else s
    texts = [c["text"] for c in res["content"] if c["type"] == "text"]
    return json.loads(texts[0]) if len(texts) == 1 else [json.loads(t) for t in texts]


def test_all_tools_over_stdio(env):
    """As a user upgrading from v0.6: the index shows the old sessions; touching an item migrates its session."""
    calls = [
        ["projects", "list_projects", {}],
        ["sessions", "list_sessions", {"limit": 10}],
        ["sessions_reviewed", "list_sessions", {"state": "reviewed"}],
        ["search", "search_items", {"query": "登录按"}],
        ["search_like", "search_items", {"query": "登录", "kind": ["issue"]}],
        ["fixed", "search_items", {"fix_state": ["fixed"]}],
        ["working", "search_items", {"work_state": ["in_progress"]}],
        ["needs_you", "search_items", {"state": ["new", "to_verify"], "limit": 100}],
        ["item", "get_item", {"uid": "$uid"}],
        ["item_noframes", "get_item", {"uid": "$uid", "include_frames": False}],
        ["transcript", "get_transcript", {"session": str(env["repo"] / ".blurt/sessions/20261019-093000")}],
        ["transcript_shots", "get_transcript", {"session": str(env["home"] / "Blurt/recordings/20261020-141500-shots")}],
        ["update", "update_item", {"uid": "$uid", "set": {"module": "auth/login", "owner": "Ana"}}],
        ["update_user", "update_item", {"uid": "$uid", "set": {"title": "x", "severity": "low"}}],
        ["fixing", "mark_fixed", {"uid": "$uid", "state": "fixing"}],
        ["fix", "mark_fixed", {"uid": "$uid", "state": "fixed", "note": "handler wired up", "commit": "abc1234"}],
        ["after", "search_items", {"query": "登录按", "work_state": ["to_verify"]}],
        ["after_v2", "search_items", {"query": "登录按", "fix_state": ["fixed"]}],
        ["projects_after", "list_projects", {}],
        ["bad_uid", "get_item", {"uid": "nope"}],
        ["bad_state", "mark_fixed", {"uid": "$uid", "state": "done"}],
    ]
    r = run_client(env, calls)
    assert r["_server"] == "blurt"
    assert set(r["_tools"]) == {"list_projects", "list_sessions", "search_items", "get_item", "get_transcript",
                                "update_item", "mark_fixed"}
    assert r["_tools"]["update_item"]["params"] == ["set", "uid", "unset"]
    assert r["_tools"]["mark_fixed"]["params"] == ["agent", "commit", "note", "pr", "state", "uid"]
    assert "work_state" in r["_tools"]["search_items"]["params"] and "state" in r["_tools"]["search_items"]["params"]
    for name in ("update_item", "mark_fixed"):
        assert "never write the item files" in r["_tools"][name]["description"]
    assert "the user confirms" in r["_tools"]["mark_fixed"]["description"]

    projects = text_json(r["projects"])
    assert {p["kind"] for p in projects} == {"inbox", "folder"}
    assert all({"id", "name", "key", "path", "kind", "open_items", "unassigned"} == set(p) for p in projects)
    assert next(p for p in projects if p["id"] == "inbox")["unassigned"] == 2
    sessions = text_json(r["sessions"])
    assert len(sessions) == 3 and {"id", "project_id", "dir", "mode", "title", "created", "item_count", "processed",
                                   "reviewed"} == set(sessions[0])
    assert all(s["reviewed"] for s in text_json(r["sessions_reviewed"]))

    hits = text_json(r["search"])
    assert hits and "登录按钮" in hits[0]["title"]
    assert any("登录按钮" in h["title"] for h in text_json(r["search_like"]))
    assert [h["state"] for h in text_json(r["fixed"])] == ["to_verify"]  # v2's "fixed": an agent's claim
    assert [h["state"] for h in text_json(r["working"])] == ["in_progress"]
    assert {h["state"] for h in text_json(r["needs_you"])} <= {"new", "to_verify"}

    item = r["item"]
    assert not item["is_error"]
    doc = json.loads(item["content"][0]["text"])
    assert doc["item"]["uid"] == r["_uid"] and Path(doc["session"]).is_absolute()
    assert doc["item"]["path"].endswith(".md") and Path(doc["item"]["path"]).is_file()  # migrated on first touch
    assert doc["item"]["id"].startswith("REP-") and doc["item"]["project"] != "inbox"
    assert all(Path(f["path"]).is_absolute() and Path(f["path"]).exists() for f in doc["item"]["frames"])
    images = [c for c in item["content"] if c["type"] == "image"]
    assert 1 <= len(images) <= 3 and all(c["mimeType"] == "image/jpeg" for c in images)
    from PIL import Image
    im = Image.open(io.BytesIO(base64.b64decode(images[0]["data"])))
    assert im.format == "JPEG" and max(im.size) == 1280
    assert not [c for c in r["item_noframes"]["content"] if c["type"] == "image"]

    segs = text_json(r["transcript"])
    assert segs and {"start", "end", "text"} <= set(segs[0])
    assert isinstance(text_json(r["transcript_shots"]), list)

    upd = text_json(r["update"])
    assert upd["ok"] and set(upd["written"]) == {"module", "owner"}
    kept = text_json(r["update_user"])
    assert kept["ok"] and sorted(kept.get("kept_user")) == ["severity", "title"]  # the user edited it on the review page

    assert text_json(r["fixing"])["state"] == "in_progress"
    fx = text_json(r["fix"])
    assert fx["ok"] and fx["state"] == "to_verify" and fx["work"]["claim"] == "fixed"  # not done: the user is
    assert fx["work"]["agent"] == "claude" and fx["work"]["commit"] == "abc1234" and fx["work"]["by"] == "agent"
    assert text_json(r["after"]) and text_json(r["after"])[0]["uid"] == r["_uid"]  # index followed the write
    assert text_json(r["after_v2"])[0]["uid"] == r["_uid"]
    repo_row = next(p for p in text_json(r["projects_after"]) if p["kind"] == "folder")
    assert repo_row["open_items"] == 5  # live items still to do or in progress (not to verify, not wontfix)
    assert r["bad_uid"]["is_error"] and r["bad_state"]["is_error"]

    # the write landed in the item's file, through items.py
    sys.path.insert(0, str(SCRIPTS))
    import store as st
    it = st.read_item(Path(doc["item"]["path"]))
    assert it["module"] == "auth/login" and it["title"] != "x" and it["state"] == "to_verify"
    assert it["work_history"][-1]["state"] == "in_progress" and it["schema"] == 3
    assert (env["repo"] / ".blurt/sessions/20261019-093000/items.v2.json").is_file()


def test_builds_index_on_first_use(env):
    """No index.db yet → the server scans before answering."""
    for f in env["bh"].glob("index.db*"):
        f.unlink()
    r = run_client(env, [["projects", "list_projects", {}]])
    assert any(p["kind"] == "inbox" for p in text_json(r["projects"]))
    assert (env["bh"] / "index.db").exists()
