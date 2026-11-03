"""index.py, schema v2 (contract K1 "index.db schema v2"): projects / sessions / items rows from stores and v0.6
sessions, trigram + LIKE search in Chinese and English, the filters, incremental updates, deletes, backlog.

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
import store as st  # noqa: E402


def copy_fixtures(home: Path, repo: Path) -> None:
    """The shared fixtures (tests/fixtures/sessions/<name>/) as v0.6 left them: the shots batch in the app's folder
    (~/Blurt/recordings), the video sessions in a repo (<repo>/.blurt/sessions)."""
    for s in sorted(p for p in (FIXTURES / "sessions").iterdir() if p.is_dir()):
        dest = (home / "Blurt" / "recordings") if s.name.endswith("-shots") else (repo / ".blurt" / "sessions")
        shutil.copytree(s, dest / s.name)


@pytest.fixture()
def env(tmp_path, monkeypatch):
    """A fake HOME (with ~/Blurt/recordings), a repo and $BLURT_HOME, from the fixtures."""
    tmp_path = Path(os.path.realpath(tmp_path))
    home, repo, bh = tmp_path / "home", tmp_path / "repo", tmp_path / "blurt-home"
    copy_fixtures(home, repo)
    bh.mkdir()
    (bh / "config.json").write_text('{"record": {"install_app": false}, "lang": "en"}')
    monkeypatch.setenv("HOME", str(home))
    monkeypatch.setenv("BLURT_HOME", str(bh))
    monkeypatch.setenv("BLURT_WORKSPACE", str(home / "Blurt"))
    for k in ("BLURT_NO_INDEX", "BLURT_AGENT", "BLURT_JOB", "BLURT_RUN_ID", "BLURT_PROJECT"):
        monkeypatch.delenv(k, raising=False)
    st._MAPS.clear()
    return {"home": home, "repo": repo, "bh": bh, "tmp": tmp_path}


def cli(*args, script="index.py") -> dict:
    p = subprocess.run([sys.executable, str(SCRIPTS / script), *map(str, args)], capture_output=True, text=True,
                       encoding="utf-8", env=os.environ.copy())
    assert p.returncode == 0, p.stderr + p.stdout
    return json.loads(p.stdout.strip().splitlines()[-1])


def migrated(env) -> dict:
    """Register the repo and migrate everything: the v0.7 state."""
    cli("add", env["repo"], script="projects.py")
    cli("migrate", "--all", script="items.py")
    return cli("scan")


def db():
    con = sqlite3.connect(index.db_path())
    con.row_factory = sqlite3.Row
    return con


def test_schema_matches_contract():
    assert index.SCHEMA == (ROOT / "docs" / "contracts" / "index-schema.sql").read_text(encoding="utf-8")


def test_legacy_uid_formula():
    want = "L" + hashlib.sha1(b"20261019-093000/I-001").hexdigest()[:25]
    assert index.legacy_uid("20261019-093000", "I-001") == want and len(want) == 26


def test_v1_index_is_rebuilt(env):
    con = sqlite3.connect(index.db_path())
    con.executescript("CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT); INSERT INTO meta VALUES "
                      "('schema_version', '1'); CREATE TABLE workspaces (id TEXT);")
    con.close()
    cli("scan", "--root", env["repo"])
    con = db()
    assert con.execute("SELECT value FROM meta WHERE key = 'schema_version'").fetchone()[0] == "3"
    assert not con.execute("SELECT 1 FROM sqlite_master WHERE name = 'workspaces'").fetchone()


def test_scan_before_migration_shows_v06_sessions(env):
    out = cli("scan", "--root", env["repo"])
    assert (out["projects"], out["sessions"], out["items"]) == (2, 3, 11)
    con = db()
    rows = {r["id"]: dict(r) for r in con.execute("SELECT * FROM projects")}
    assert rows["inbox"]["kind"] == "inbox" and rows["inbox"]["key"] == "IN"
    repo = next(r for r in rows.values() if r["id"] != "inbox")
    assert (repo["path"], repo["store"], repo["registered"], repo["key"]) == \
        (str(env["repo"]), str(env["repo"] / ".blurt"), 0, "REP")
    assert all(r["legacy"] == 1 for r in con.execute("SELECT legacy FROM sessions"))
    assert all("#I-" in r["path"] for r in con.execute("SELECT path FROM items"))
    shots = con.execute("SELECT * FROM sessions WHERE mode = 'shots'").fetchone()
    assert shots["project_id"] == "inbox" and shots["duration"] is None and shots["shot_count"] == 2
    assert {r["dir"]: r["item_count"] for r in con.execute("SELECT dir, item_count FROM sessions")} == {
        str(env["repo"] / ".blurt/sessions/20261019-093000"): 3, str(env["repo"] / ".blurt/sessions/20261021-101500"): 5,
        str(env["home"] / "Blurt/recordings/20261020-141500-shots"): 2}
    # status + v2 fix show as one state already (K3), before any file is migrated
    assert dict(con.execute("SELECT state, COUNT(*) FROM items GROUP BY state").fetchall()) == \
        {"todo": 3, "discarded": 1, "new": 4, "to_verify": 1, "in_progress": 1, "wontfix": 1}
    # the inbox ("needs you") is new + to verify: the draft the user marked won't do is not in it
    assert con.execute("SELECT COUNT(*) FROM items WHERE state IN ('new', 'to_verify')").fetchone()[0] == 5
    again = cli("scan")  # the repo is remembered (registered = 0) and unchanged files are skipped
    assert (again["sessions"], again["items"]) == (3, 11)


def test_scan_after_migration(env):
    out = migrated(env)
    assert (out["projects"], out["sessions"], out["items"]) == (2, 3, 11)
    con = db()
    assert con.execute("SELECT COUNT(*) FROM sessions WHERE legacy = 1").fetchone()[0] == 0
    r = con.execute("SELECT * FROM projects WHERE id != 'inbox'").fetchone()
    assert (r["registered"], r["key"], r["kind"], r["slug"]) == (1, "REP", "folder", "repo")
    it = con.execute("SELECT * FROM items WHERE uid = '01KAQ6N2W8C3D4E5F6G7H8J9KM'").fetchone()
    assert it["item_id"] == "REP-5" and it["path"].endswith(".md") and Path(it["path"]).is_file()
    assert (it["state"], it["work_claim"], it["work_agent"], it["work_to"]) == ("to_verify", "fixed", "claude",
                                                                                "session")
    assert (it["source_type"], it["source_by"], it["project_by"]) == ("recording", "Tester", "migrate")
    assert it["session_id"].endswith(":20261021-101500") and it["user_edited"] == 1 and it["frame_count"] == 2
    assert Path(it["primary_frame"]).is_absolute() and Path(it["primary_frame"]).is_file()
    assert it["created"] < it["updated"] and it["has_code_refs"] == 1
    assert "multipart" not in it["body"] and "POST /api/avatar" in it["body"]  # lens text, not the work note
    shots = con.execute("SELECT * FROM sessions WHERE mode = 'shots'").fetchone()
    assert shots["processed"] == 1 and shots["legacy"] == 0 and shots["item_count"] == 2


def test_search_trigram_like_and_filters(env):
    migrated(env)
    tri = cli("search", "登录按")
    assert tri["total"] >= 1 and any("登录按钮" in r["title"] for r in tri["items"])
    assert all("[" in (r["snippet"] or "") for r in tri["items"])
    like = cli("search", "登录")
    assert like["total"] >= tri["total"] and set(like["items"][0]) == set(index.ITEM_ROW)
    assert like["items"][0]["project_key"] == "REP" and like["items"][0]["item_id"].startswith("REP-")
    assert cli("search", "POST api/avatar")["total"] == 1  # English, through the body
    assert cli("search", "avatar")["items"][0]["uid"] == "01KAQ6N2W8C3D4E5F6G7H8J9KM"
    assert all(r["state"] != "discarded" for r in cli("search", "--limit", 500)["items"])
    assert [r["state"] for r in cli("search", "--state", "discarded")["items"]] == ["discarded"]
    assert cli("search", "--status", "deleted")["items"] == cli("search", "--state", "discarded")["items"]
    inbox_states = {r["state"] for r in cli("search", "--state", "new", "--state", "to_verify", "--limit", 500)["items"]}
    assert inbox_states == {"new", "to_verify"}
    issues = cli("search", "--kind", "issue")
    assert issues["total"] >= 1 and all(r["kind"] == "issue" for r in issues["items"])
    assert [r["state"] for r in cli("search", "--work", "in_progress")["items"]] == ["in_progress"]
    fixed = cli("search", "--fix-state", "fixed")  # the v2 name: an agent's "fixed" claim, or done
    assert [r["item_id"] for r in fixed["items"]] == ["REP-5"]
    assert [r["state"] for r in cli("search", "--fix-state", "wontfix")["items"]] == ["wontfix"]
    assert {r["state"] for r in cli("search", "--fix-state", "none")["items"]} == {"new", "todo"}
    inbox = cli("search", "--project", "inbox")
    assert inbox["total"] == 2 and all(r["project_id"] == "inbox" for r in inbox["items"])
    for ref in ("REP", "repo", str(env["repo"])):
        assert cli("search", "--project", ref)["total"] == 8, ref  # the 9 repo items but the deleted one
    assert cli("search", "--workspace", "REP")["total"] == 8  # the old flag
    assert cli("search", "--source-type", "snap")["total"] == 2
    s = env["repo"] / ".blurt" / "sessions" / "20261021-101500"
    assert cli("search", "--session", s)["total"] == 5
    titles = [r["title"] for r in cli("search", "--sort", "title", "--project", "inbox")["items"]]
    assert titles == sorted(titles)
    page = cli("search", "--limit", 1, "--offset", 1)
    assert len(page["items"]) == 1 and page["total"] == cli("search")["total"]
    assert cli("search", 'a"b OR (')["total"] == 0  # FTS syntax in the query is just text


def test_search_by_item_id(env):
    """The id printed on every row finds that item (any case), first — and an old id still finds a moved item."""
    migrated(env)
    rep5 = cli("search", "REP-5")
    assert rep5["items"][0]["item_id"] == "REP-5"
    assert cli("search", "rep-5")["items"][0]["item_id"] == "REP-5"
    assert cli("search", "REP-5", "--project", "REP")["items"][0]["item_id"] == "REP-5"
    assert cli("search", "REP-999")["total"] == 0
    assert index.is_item_id("AW-11") and index.is_item_id("ba-3") and index.is_item_id("IOS-12")
    assert not index.is_item_id("-3") and not index.is_item_id("AW-") and not index.is_item_id("3D-1") \
        and not index.is_item_id("UTF-8x") and not index.is_item_id("登录-1")
    # moved to the inbox: a new id there, and its old one finds it too
    uid = rep5["items"][0]["uid"]
    subprocess.run([sys.executable, str(ROOT / "skills/blurt/scripts/items.py"), "move", uid, "--project", "inbox"],
                   check=True, capture_output=True)
    moved = cli("search", "REP-5")["items"]
    assert [r["uid"] for r in moved] == [uid] and moved[0]["item_id"].startswith("IN-")


def cpu_ms(f):
    """→ (f(), the CPU milliseconds it took). Wall-clock time here was flaky: SQLite's commit waits for the disk, and a
    disk busy with something else (a `swift build` just before the suite, other agents) made a 5 ms update take
    75–1400 ms. What these tests promise is that an update is incremental — little work — not how busy the disk is."""
    t0 = time.process_time()
    out = f()
    return out, (time.process_time() - t0) * 1000


def test_updates_are_fast_and_track_changes(env):
    migrated(env)
    md = next((env["repo"] / ".blurt" / "items").glob("REP-7-*.md"))
    item = st.read_item(md)
    st.write_item(md, {**item, "title": "全新的标题 zebra"})
    out, ms = cpu_ms(lambda: index.update_paths([md]))
    assert ms < 50, (ms, out)
    assert out["updated"] == 1
    assert cli("search", "zebra")["total"] == 1 and cli("search", "全新")["total"] == 1
    md.unlink()  # a file that went away loses its row
    cli("update", md)
    assert cli("search", "zebra")["total"] == 0
    # a new file
    st.write_item(env["repo"] / ".blurt" / "items" / "REP-99-x.md",
                  {"id": "REP-99", "uid": "01JB7ZK3Q4M8W2E5R6T9Y0ABC9", "kind": "note", "title": "brand new walrus",
                   "created": "2026-10-22T10:00:00+08:00"})
    assert cli("update", env["repo"] / ".blurt")["updated"] == 1  # a store dir
    assert cli("search", "walrus")["total"] == 1
    # a session dir that is deleted loses its row; its items stay (they live in the store), without a session
    s = env["repo"] / ".blurt" / "sessions" / "20261019-093000"
    shutil.rmtree(s)
    cli("update", s)
    con = db()
    assert con.execute("SELECT COUNT(*) FROM sessions WHERE dir = ?", (str(s),)).fetchone()[0] == 0
    assert con.execute("SELECT COUNT(*) FROM items WHERE item_id = 'REP-1' AND session_id IS NULL").fetchone()[0] == 1
    con.execute("INSERT INTO items_fts(items_fts) VALUES ('integrity-check')")  # FTS consistent with the table


def test_cards_and_unparseable_files(env):
    migrated(env)
    s = env["home"] / "Blurt" / "inbox" / "sessions" / "20261022-090000-shots"
    (s / "shots").mkdir(parents=True)
    lines = [{"n": 1, "file": "shots/001.png", "project": None}, {"n": 2, "file": "shots/002.png", "project": None},
             {"n": 3, "type": "voice", "file": None, "voice": "shots/003.wav", "project": None},
             {"n": 2, "project": "inbox", "assigned_by": "user"}, {"n": 1, "deleted": True}]
    (s / "shots.jsonl").write_text("".join(json.dumps(x) + "\n" for x in lines))
    (s / "meta.json").write_text('{"mode": "shots"}')
    cli("update", s)
    row = db().execute("SELECT * FROM sessions WHERE dir = ?", (str(s),)).fetchone()
    assert (row["card_count"], row["shot_count"], row["processed"], row["project_id"]) == (1, 2, 0, "inbox")
    bad = env["home"] / "Blurt" / "inbox" / "items" / "IN-9-bad.md"
    bad.write_text("---\nuid: 01JB7ZK3Q4M8W2E5R6T9Y0ABD1\nid: IN-9\ntitle: half\nx: {broken\n---\n")
    cli("update", bad)
    r = db().execute("SELECT * FROM items WHERE path = ?", (str(bad),)).fetchone()
    # the lines that still parse give its identity: found by its uid, listed under its own id
    assert r["parse_error"] and r["item_id"] == "IN-9" and r["uid"] == "01JB7ZK3Q4M8W2E5R6T9Y0ABD1"


def _retitle(path: Path, title: str) -> None:
    lines = path.read_text(encoding="utf-8").split("\n")
    k = next(i for i, ln in enumerate(lines) if ln.startswith("title:"))
    lines[k] = f"title: {json.dumps(title)}"
    path.write_text("\n".join(lines), encoding="utf-8")


def _break(path: Path) -> None:
    """Hand-edit one front-matter line of an item file into something that doesn't parse."""
    lines = path.read_text(encoding="utf-8").split("\n")
    k = next(i for i, ln in enumerate(lines) if ln.startswith("kind:"))
    lines[k] = "kind: [broken"
    path.write_text("\n".join(lines), encoding="utf-8")


def test_one_broken_file_never_stops_a_scan_or_an_update(env):
    """dogfood-2 W56: a previously indexed item broken by hand made every scan and every batch update fail
    (UNIQUE items.path, the whole transaction rolled back), so other edits never reached the lists."""
    migrated(env)
    files = sorted((env["repo"] / ".blurt" / "items").glob("*.md"))
    assert len(files) >= 3
    broken, a, b = files[0], files[1], files[2]
    uid = st.read_header(broken)["uid"]
    _break(broken)
    _retitle(a, "edited on disk A")
    _retitle(b, "edited on disk B")
    r = cli("update", a, broken, b)
    assert r["updated"] == 3 and "skipped" not in r
    con = db()
    titles = {x["path"]: x["title"] for x in con.execute("SELECT path, title FROM items")}
    assert titles[str(a)] == "edited on disk A" and titles[str(b)] == "edited on disk B"
    row = con.execute("SELECT * FROM items WHERE path = ?", (str(broken),)).fetchone()
    assert row["uid"] == uid and row["parse_error"]                      # the same row, marked unreadable in place
    _retitle(a, "again A")
    s = cli("scan")
    assert s["unreadable"] == [{"uid": uid, "id": row["item_id"], "path": str(broken)}] and "skipped" not in s
    assert db().execute("SELECT title FROM items WHERE path = ?", (str(a),)).fetchone()[0] == "again A"
    # the app addresses items by uid: a broken one says it can't be read (never "not found"), and a detail's doc
    # lists it as unreadable instead of leaving it out
    p = subprocess.run([sys.executable, str(SCRIPTS / "items.py"), "state", uid, "--action", "done"],
                       capture_output=True, text=True, env=os.environ.copy())
    assert json.loads(p.stdout.strip().splitlines()[-1])["code"] == "unparseable"
    doc = cli("doc", "--project", row["project_id"], "--item", uid, script="items.py")["doc"]
    assert [u["uid"] for u in doc["_unreadable"]] == [uid] and uid not in [i["uid"] for i in doc["items"]]


def test_a_broken_kind_line_keeps_the_kind_the_list_showed(env):
    """Review of fix 2: a hand-broken idea showed a note icon in the list (its kind line was the broken one)."""
    migrated(env)
    con = db()
    row = next(r for r in con.execute("SELECT path, kind, state FROM items WHERE kind != 'note'"))
    f = Path(row["path"])
    _break(f)
    cli("update", f)
    after = db().execute("SELECT kind, state, parse_error FROM items WHERE path = ?", (str(f),)).fetchone()
    assert after["parse_error"] and (after["kind"], after["state"]) == (row["kind"], row["state"])


def test_a_file_whose_uid_changed_replaces_its_row(env):
    """Review of fix 2: a readable file at an indexed path with another uid than its row (a uid edited by hand, a
    checkout that put another item at the same name) hit UNIQUE items.path and was skipped on every scan."""
    migrated(env)
    f = sorted((env["repo"] / ".blurt" / "items").glob("*.md"))[0]
    uid = st.read_header(f)["uid"]
    new = "01JB7ZK3Q4M8W2E5R6T9Y0ZZZZ"
    f.write_text(f.read_text(encoding="utf-8").replace(uid, new), encoding="utf-8")
    r = cli("update", f)
    assert r["updated"] == 1 and "skipped" not in r
    rows = db().execute("SELECT uid, parse_error FROM items WHERE path = ?", (str(f),)).fetchall()
    assert [(x["uid"], x["parse_error"]) for x in rows] == [(new, None)]
    s = cli("scan", "--full")
    assert "skipped" not in s and not db().execute("SELECT 1 FROM items WHERE uid = ?", (uid,)).fetchone()


def test_a_file_indexed_broken_without_a_uid_then_fixed(env):
    """A file first indexed while its uid line didn't parse gets a stand-in uid; once fixed, its real uid takes
    the row over instead of the file being skipped from then on."""
    migrated(env)
    items = env["repo"] / ".blurt" / "items"
    src = sorted(items.glob("*.md"))[0]
    h = st.read_header(src)
    real_uid = "01JB7ZK3Q4M8W2E5R6T9Y0AAAA"
    text = src.read_text(encoding="utf-8").replace(h["uid"], real_uid).replace(f"id: {h['id']}", "id: NEW-99")
    f = items / "NEW-99-copied.md"
    good = text
    f.write_text("\n".join("uid: [broken" if ln.startswith("uid:") else ln for ln in text.split("\n")),
                 encoding="utf-8")
    cli("update", f)
    row = db().execute("SELECT uid, parse_error FROM items WHERE path = ?", (str(f),)).fetchone()
    assert row["uid"].startswith("X") and row["parse_error"]
    f.write_text(good, encoding="utf-8")
    r = cli("update", f)
    assert "skipped" not in r
    rows = db().execute("SELECT uid, parse_error FROM items WHERE path = ?", (str(f),)).fetchall()
    assert [(x["uid"], x["parse_error"]) for x in rows] == [(real_uid, None)]


def test_a_file_that_throws_is_skipped_and_reported(env, monkeypatch):
    """Whatever else goes wrong with one file is rolled back alone (SAVEPOINT) and listed, never the whole batch."""
    migrated(env)
    files = sorted((env["repo"] / ".blurt" / "items").glob("*.md"))
    real_index_file = index.index_file

    def flaky(con, p, *a, **kw):
        if Path(p) == files[0]:
            raise RuntimeError("boom")
        return real_index_file(con, p, *a, **kw)
    monkeypatch.setattr(index, "index_file", flaky)
    _retitle(files[1], "still indexed")
    r = index.update_paths([files[0], files[1]])
    assert r["skipped"][0]["path"] == str(files[0]) and "boom" in r["skipped"][0]["error"]
    assert db().execute("SELECT title FROM items WHERE path = ?", (str(files[1]),)).fetchone()[0] == "still indexed"


def test_readonly_reader_and_wal(env):
    cli("scan", "--root", env["repo"])
    con = index.connect(readonly=True)
    assert con.execute("PRAGMA journal_mode").fetchone()[0] == "wal"
    with pytest.raises(sqlite3.OperationalError):
        con.execute("DELETE FROM items")


def test_rebuild_from_scratch(env):
    first = migrated(env)
    for ext in ("", "-wal", "-shm"):
        Path(str(index.db_path()) + ext).unlink(missing_ok=True)
    again = cli("scan")  # the projects come from projects.json: no --root needed
    assert (again["projects"], again["sessions"], again["items"]) == (first["projects"], first["sessions"], first["items"])


def test_backlog(env):
    migrated(env)
    out = cli("backlog", env["repo"])
    text = Path(out["path"]).read_text()
    assert out["path"] == str(env["repo"] / ".blurt" / "BACKLOG.md")
    assert out["items"] == 6 and text.startswith("# Blurt backlog")  # todo + in progress, not to_verify / wontfix
    assert "uid `" in text and "REP-" in text


def test_items_py_write_updates_index(env):
    """An items.py write re-indexes what it wrote, in-process, in < 50 ms."""
    migrated(env)
    p = subprocess.run([sys.executable, str(SCRIPTS / "items.py"), "patch", "01KAQ6N2W8C3D4E5F6G7H8J9KP", "--set",
                        "title=键盘快捷键 walrus"], capture_output=True, text=True, encoding="utf-8", env=os.environ.copy())
    assert p.returncode == 0, p.stderr
    hit = cli("search", "walrus")
    assert hit["total"] == 1 and hit["items"][0]["item_id"] == "REP-7"
    p = subprocess.run([sys.executable, str(SCRIPTS / "items.py"), "work", "REP-7", "--state", "to_verify", "--claim",
                        "fixed", "--agent", "codex"], capture_output=True, text=True, encoding="utf-8",
                       env=os.environ.copy())
    assert p.returncode == 0, p.stderr
    assert cli("search", "walrus", "--work", "to_verify")["total"] == 1
    md = Path(hit["items"][0]["path"])
    times = [cpu_ms(lambda: index.update_paths([md]))[1] for _ in range(5)]
    print("reindex cpu ms", [round(t, 1) for t in times])
    assert sorted(times)[2] < 50, times


def test_update_workspace_without_a_store_is_a_noop(env):
    """The plugin's SessionEnd hook passes any project root: nothing to index → no index.db appears."""
    plain = env["tmp"] / "plain-project"
    (plain / "src").mkdir(parents=True)
    (plain / "src" / "meta.json").write_text("{}")  # looks like a session marker; must not be indexed
    assert cli("update", "--workspace", plain)["updated"] == 0
    assert not index.db_path().exists()
    assert cli("update", "--workspace", env["repo"])["updated"] >= 2  # the repo has a .blurt


def test_path():
    assert cli("path")["db"].endswith("index.db")


def _models() -> list[dict]:
    p = subprocess.run([sys.executable, str(SCRIPTS / "transcribe.py"), "models"], capture_output=True, text=True,
                       encoding="utf-8", env=os.environ.copy())
    assert p.returncode == 0, p.stderr
    return json.loads(p.stdout)["models"]


def test_transcribe_models_lists_catalog(env, monkeypatch):
    """WP2 also owns `transcribe.py models`: installed / downloadable ASR models for the apps' settings."""
    # a Mac without macOS 26's recogniser (it would be the configured one otherwise: the order the suite ran in hid it)
    monkeypatch.setenv("BLURT_NO_APPLE_SPEECH", "1")
    rows = {m["backend"]: m for m in _models()}
    assert {"sensevoice", "mlx-whisper", "faster-whisper", "openai", "dashscope", "vad"} <= set(rows)
    sv = rows["sensevoice"]
    assert sv["installed"] is False and sv["approx"] is True and sv["size_mb"] > 100 and "zh" in sv["languages"]
    assert sv["configured"] is True  # the default backend
    (env["bh"] / "models" / "sensevoice").mkdir(parents=True)
    for f in ("model.int8.onnx", "tokens.txt"):
        (env["bh"] / "models" / "sensevoice" / f).write_bytes(b"x" * 1024)
    sv = next(m for m in _models() if m["backend"] == "sensevoice")
    assert sv["installed"] is True and sv["approx"] is False
