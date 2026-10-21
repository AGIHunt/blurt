"""index.py (contract C3): scan counts, trigram + LIKE search, update speed, deletes, backlog, schema copy.

  uv run --with pytest pytest tests/test_index.py -q
"""
from __future__ import annotations

import hashlib
import json
import os
import shutil
import sqlite3
import subprocess
import sys
import time
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "skills" / "blurt" / "scripts"
FIXTURES = ROOT / "tests" / "fixtures"
sys.path.insert(0, str(SCRIPTS))
import index  # noqa: E402


def fixture_sessions() -> list[Path]:
    """WP1's shared fixtures (tests/fixtures/sessions/<name>/) when present, else WP2's own (tests/fixtures/index)."""
    shared = FIXTURES / "sessions"
    if shared.is_dir() and any(shared.iterdir()):
        return sorted(p for p in shared.iterdir() if p.is_dir())
    return []


@pytest.fixture()
def env(tmp_path, monkeypatch):
    """A fake HOME (with ~/Blurt/recordings), a repo workspace and $BLURT_HOME, from the fixtures."""
    home, repo, bh = tmp_path / "home", tmp_path / "repo", tmp_path / "blurt-home"
    shared = fixture_sessions()
    if shared:  # WP1 layout: flat session dirs → split them over the two workspaces
        for s in shared:
            dest = (home / "Blurt" / "recordings") if s.name.endswith("-shots") else (repo / ".blurt" / "sessions")
            shutil.copytree(s, dest / s.name)
    else:
        shutil.copytree(FIXTURES / "index" / "home", home)
        shutil.copytree(FIXTURES / "index" / "repo", repo)
    bh.mkdir()
    monkeypatch.setenv("HOME", str(home))
    monkeypatch.setenv("BLURT_HOME", str(bh))
    return {"home": home, "repo": repo, "bh": bh, "tmp": tmp_path}


def cli(*args) -> dict:
    p = subprocess.run([sys.executable, str(SCRIPTS / "index.py"), *map(str, args)], capture_output=True, text=True,
                       encoding="utf-8", env=os.environ.copy())
    assert p.returncode == 0, p.stderr + p.stdout
    return json.loads(p.stdout.strip().splitlines()[-1])


def expected_counts(env) -> dict:
    sessions = [d for r in (env["home"] / "Blurt" / "recordings", env["repo"] / ".blurt" / "sessions")
                for d in r.iterdir() if index.is_session(d)]
    items = 0
    for d in sessions:
        data = json.loads((d / "items.json").read_text()) if (d / "items.json").exists() else {"items": []}
        items += len(data["items"])
    return {"sessions": len(sessions), "items": items}


def test_schema_matches_contract():
    assert index.SCHEMA == (ROOT / "docs" / "contracts" / "index-schema.sql").read_text(encoding="utf-8")


def test_legacy_uid_formula():
    want = "L" + hashlib.sha1(b"20261019-093000/I-001").hexdigest()[:25]
    assert index.legacy_uid("20261019-093000", "I-001") == want and len(want) == 26


def test_scan_counts(env):
    out = cli("scan", "--root", env["repo"])
    exp = expected_counts(env)
    assert out["sessions"] == exp["sessions"] and out["items"] == exp["items"]
    assert out["workspaces"] == 2
    con = sqlite3.connect(index.db_path())
    kinds = dict(con.execute("SELECT kind, COUNT(*) FROM workspaces GROUP BY kind").fetchall())
    assert kinds == {"default": 1, "repo": 1}
    # the default workspace is ~/Blurt, named "Blurt"
    assert con.execute("SELECT path, name FROM workspaces WHERE kind='default'").fetchone() == \
        (str(index.real(env["home"] / "Blurt")), "Blurt")
    # a second scan finds the repo by itself (already indexed) and skips unchanged sessions
    again = cli("scan")
    assert (again["sessions"], again["items"]) == (out["sessions"], out["items"])


def test_session_columns(env):
    cli("scan", "--root", env["repo"])
    con = sqlite3.connect(index.db_path())
    con.row_factory = sqlite3.Row
    shots = con.execute("SELECT * FROM sessions WHERE mode = 'shots'").fetchone()
    assert shots is not None and shots["duration"] is None and shots["shot_count"] >= 1
    assert shots["processed"] == 1
    for r in con.execute("SELECT * FROM sessions"):
        assert r["created"] and r["dir"].startswith("/") and r["id"].startswith(r["workspace_id"] + ":")
        live = 0
        if (Path(r["dir"]) / "items.json").exists():
            live = sum(1 for i in json.loads((Path(r["dir"]) / "items.json").read_text())["items"]
                       if i.get("status") != "deleted")
        assert r["item_count"] == live


def test_search_trigram_and_like(env):
    cli("scan", "--root", env["repo"])
    tri = cli("search", "登录按")
    assert tri["total"] >= 1 and any("登录按钮" in r["title"] for r in tri["items"])
    assert all("[" in (r["snippet"] or "") for r in tri["items"])
    like = cli("search", "登录")
    assert like["total"] >= tri["total"] and any("登录按钮" in r["title"] for r in like["items"])
    assert set(like["items"][0]) == set(index.ITEM_ROW)
    # deleted items stay out unless asked for
    assert all(r["status"] != "deleted" for r in cli("search", "--limit", 500)["items"])
    if cli("search", "--status", "deleted")["total"]:
        assert all(r["status"] == "deleted" for r in cli("search", "--status", "deleted")["items"])
    # filters
    issues = cli("search", "--kind", "issue")
    assert issues["total"] >= 1 and all(r["kind"] == "issue" for r in issues["items"])
    fixed = cli("search", "--fix-state", "fixed")
    assert fixed["total"] >= 1 and all(r["fix_state"] == "fixed" for r in fixed["items"])
    never = cli("search", "--fix-state", "none")
    assert all(r["fix_state"] is None for r in never["items"])
    # paging + total
    page = cli("search", "--limit", 1, "--offset", 1)
    assert len(page["items"]) == 1 and page["total"] == cli("search")["total"]
    # FTS syntax in the query is just text
    assert cli("search", 'a"b OR (')["total"] == 0


def test_body_and_paths(env):
    cli("scan", "--root", env["repo"])
    con = sqlite3.connect(index.db_path())
    con.row_factory = sqlite3.Row
    r = con.execute("SELECT * FROM items WHERE title LIKE '%登录按钮%'").fetchone()
    assert r["primary_frame"] and Path(r["primary_frame"]).is_absolute() and Path(r["primary_frame"]).exists()
    assert r["frame_count"] >= 1 and r["updated"] > 0


def test_update_is_fast_and_tracks_changes(env):
    cli("scan", "--root", env["repo"])
    s = next(d for d in (env["repo"] / ".blurt" / "sessions").iterdir() if (d / "items.json").exists())
    data = json.loads((s / "items.json").read_text())
    data["items"][0]["title"] = "全新的标题 zebra"
    (s / "items.json").write_text(json.dumps(data, ensure_ascii=False))
    t0 = time.perf_counter()
    out = index.update_sessions([s])
    assert (time.perf_counter() - t0) * 1000 < 50, out
    assert out["updated"] == 1
    assert cli("search", "zebra")["total"] == 1
    assert cli("search", "全新")["total"] == 1
    # a deleted session dir loses its rows
    n = cli("search", "--session", str(s), "--status", "draft", "--status", "confirmed", "--status", "deleted")["total"]
    assert n >= 1
    shutil.rmtree(s)
    cli("update", s)
    assert cli("search", "zebra")["total"] == 0
    con = sqlite3.connect(index.db_path())
    assert con.execute("SELECT COUNT(*) FROM sessions WHERE dir = ?", (str(index.real(s)),)).fetchone()[0] == 0
    # FTS stays consistent with the content table
    con.execute("INSERT INTO items_fts(items_fts) VALUES ('integrity-check')")


def test_update_workspace_and_new_session(env):
    cli("scan", "--root", env["repo"])
    new = env["repo"] / ".blurt" / "sessions" / "20261022-080000"
    new.mkdir()
    (new / "items.json").write_text(json.dumps({"items": [{"id": "I-001", "kind": "note", "title": "brand new note"}]}))
    assert cli("update", "--workspace", env["repo"])["updated"] == 1
    assert cli("search", "brand new")["total"] == 1
    assert cli("update", "--workspace", env["repo"])["updated"] == 0  # unchanged → skipped


def test_readonly_reader_and_wal(env):
    cli("scan", "--root", env["repo"])
    con = index.connect(readonly=True)
    assert con.execute("PRAGMA journal_mode").fetchone()[0] == "wal"
    with pytest.raises(sqlite3.OperationalError):
        con.execute("DELETE FROM items")


def test_rebuild_from_scratch(env):
    first = cli("scan", "--root", env["repo"])
    index.db_path().unlink()
    for ext in ("-wal", "-shm"):
        Path(str(index.db_path()) + ext).unlink(missing_ok=True)
    again = cli("scan", "--root", env["repo"])
    assert (again["sessions"], again["items"]) == (first["sessions"], first["items"])


def test_backlog(env):
    out = cli("backlog", env["repo"])
    text = Path(out["path"]).read_text()
    assert out["items"] >= 1 and text.startswith("# Blurt backlog")
    assert "uid `" in text


def test_path():
    assert cli("path")["db"].endswith("index.db")
