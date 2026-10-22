# /// script
# requires-python = ">=3.10"
# ///
"""The search index over every blurt item: $BLURT_HOME/index.db (SQLite, WAL). This script is its only writer;
the apps, mcp_server.py and agents.py open it read-only. The files stay the source of truth — deleting index.db loses
nothing, `index.py scan` rebuilds it. Schema v3: docs/contracts/index-schema.sql (contracts K1 + K3, next-round.md).

  index.py path                        → {"db": "…/index.db"}
  index.py scan [--root DIR …] [--full]   projects.json's projects, the inbox, ~/Blurt/recordings (v0.6), projects
                                       found earlier, --root → {"projects","sessions","items","ms"}
                                       (unchanged files are skipped unless --full)
  index.py update PATH …               re-index .md files, store dirs or session dirs (gone → their rows go)
  index.py update --workspace DIR      re-index DIR's store (<DIR>/.blurt) if it has one (no-op otherwise)
  index.py search [QUERY] [--kind K]… [--state S]… [--project ID|DIR|NAME|inbox]
                  [--session ID|DIR] [--source-type T] [--sort updated|created|t_start|title] [--limit 50]
                  [--offset 0]          → {"total": n, "items": [ItemRow]}   (--workspace = --project; the old
                                       --status / --work / --fix-state filters still work, mapped to states)
  index.py backlog REPO                writes REPO/.blurt/BACKLOG.md (open items) → {"path", "items"}

Every call prints one JSON line. Python API: update_paths(paths), scan(roots, full), search(...), ensure_index(),
connect(readonly=True), db_path(), legacy_uid(name, id), read_shots(dir).

Search, for every host (macOS app, Tauri, mcp_server.py) — run the same queries:
  QUERY is split on whitespace; each term must match (AND). A term of ≥ 3 characters goes to FTS5 (trigram,
  so Chinese works without word segmentation) as a quoted phrase ("" doubles a quote); a 1–2 character term
  can't use trigram and becomes `(i.title LIKE ?1 OR i.quote LIKE ?1 OR i.body LIKE ?1)` with ?1 = '%term%'
  (LIKE escapes % _ \\ with ESCAPE '\\'). State defaults to "everything but discarded"; the inbox ("needs you")
  is state IN ('new', 'to_verify') in every app.

    SELECT i.*, p.name AS project_name, p.key AS project_key, s.dir AS session_dir,
           snippet(items_fts, -1, '[', ']', '…', 12) AS snippet
    FROM items i JOIN items_fts f ON f.rowid = i.rowid JOIN projects p ON p.id = i.project_id
    LEFT JOIN sessions s ON s.id = i.session_id
    WHERE items_fts MATCH ?1 AND i.state != 'discarded' [AND i.kind IN (…)] [AND i.state IN (…)] …
    ORDER BY i.updated DESC, i.item_id LIMIT ? OFFSET ?
  -- without any ≥3-char term: same query without the items_fts join (snippet computed by the host, or NULL)
  -- --sort created: i.created DESC ; t_start: i.t_start, i.created DESC ; title: i.title COLLATE NOCASE

ItemRow = {uid, project_id, project_name, project_key, session_id, session_dir, path, item_id, kind, title, state,
           work_to, work_agent, severity, primary_frame, created, updated, snippet, suggested_project}.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sqlite3
import sys
import time
from datetime import datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from _common import (OPEN_STATES, blurt_home, blurt_workspace, legacy_filter_states, legacy_uid,  # noqa: E402,F401
                     load_json, project_id, real, state_of, to_epoch, work_from_fix)
import store as st  # noqa: E402

# Keep byte-identical to docs/contracts/index-schema.sql (tests/test_index.py checks it). The skill ships without docs/.
SCHEMA = """\
-- blurt index.db — schema v3 (contracts K1 + K3 in docs/design/next-round.md; v3 = one `state` per item)
-- Location: $BLURT_HOME/index.db (default ~/.blurt/index.db).
-- Single writer: skills/blurt/scripts/index.py. Readers (read-only, WAL): macOS app (SQLite3 C API),
-- Tauri app (rusqlite), mcp_server.py, agents.py. The files stay the source of truth (items/*.md in each store,
-- batch.json / shots.jsonl / meta.json in each session; v1/v2 items.json for sessions not migrated yet): deleting
-- index.db loses nothing, `index.py scan` rebuilds it. index.py drops and rebuilds a db whose schema_version differs.
-- Requires SQLite >= 3.34 (FTS5 trigram). macOS 26 ships 3.51; Python 3.12+ from uv ships >= 3.45.

PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS meta (
  key   TEXT PRIMARY KEY,           -- 'schema_version' = '3', 'last_full_scan' = epoch seconds
  value TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS projects (
  id         TEXT PRIMARY KEY,      -- K2 project id (sha1(realpath(folder))[:12]); the inbox is 'inbox'
  path       TEXT NOT NULL UNIQUE,  -- the project folder (inbox: the inbox store itself)
  store      TEXT NOT NULL UNIQUE,  -- <path>/.blurt (inbox: same as path)
  name       TEXT NOT NULL,
  key        TEXT NOT NULL,         -- item id prefix: "BA" → BA-12; the inbox is IN
  slug       TEXT NOT NULL,
  kind       TEXT NOT NULL CHECK (kind IN ('inbox', 'folder', 'repo')),
  registered INTEGER NOT NULL DEFAULT 1,   -- 0 = found on disk (--root, an old workspace), not in projects.json
  last_seen  REAL
);

CREATE TABLE IF NOT EXISTS sessions (
  id          TEXT PRIMARY KEY,     -- "<project_id>:<session dir name>"
  project_id  TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,  -- the store the session dir is in
  dir         TEXT NOT NULL UNIQUE, -- absolute path of the session dir
  mode        TEXT NOT NULL CHECK (mode IN ('video', 'shots', 'voice')),
  title       TEXT,
  author      TEXT,
  created     REAL,                 -- epoch seconds (meta.json, else dir name timestamp)
  duration    REAL,                 -- seconds; NULL for shots / voice sessions
  shot_count  INTEGER NOT NULL DEFAULT 0,
  card_count  INTEGER NOT NULL DEFAULT 0,  -- captures with no project and not processed yet (the cards, K7)
  item_count  INTEGER NOT NULL DEFAULT 0,  -- items with source.session = dir and state != 'discarded'
  processed   INTEGER NOT NULL DEFAULT 0,  -- batch.json (or a v1/v2 items.json) exists
  processing  INTEGER NOT NULL DEFAULT 0,  -- batch "processing": true
  reviewed    INTEGER NOT NULL DEFAULT 0,  -- batch "reviewed": true
  legacy      INTEGER NOT NULL DEFAULT 0,  -- a v1/v2 session not migrated yet (items.json, no batch.json): read-only
  items_mtime REAL,                 -- batch.json (legacy: items.json)
  shots_mtime REAL,
  indexed_at  REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS sessions_proj_created ON sessions(project_id, created DESC);

CREATE TABLE IF NOT EXISTS items (
  uid                  TEXT PRIMARY KEY,
  project_id           TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  session_id           TEXT REFERENCES sessions(id) ON DELETE SET NULL,
  path                 TEXT NOT NULL UNIQUE,   -- the .md (absolute); legacy: "<items.json absolute path>#<id>"
  item_id              TEXT NOT NULL,          -- "BA-12" (legacy: "I-001")
  kind                 TEXT NOT NULL,          -- issue | idea | note | task | <custom lens>
  title                TEXT NOT NULL DEFAULT '',
  quote                TEXT NOT NULL DEFAULT '',
  body                 TEXT NOT NULL DEFAULT '',  -- lens fields flattened: actual, expected, steps, why… joined by "\\n"
  tags                 TEXT NOT NULL DEFAULT '',  -- space-joined
  state                TEXT NOT NULL,          -- new | todo | handed_off | in_progress | to_verify | done | wontfix
                                               -- | discarded (K3); the inbox = new + to_verify
  work_to              TEXT,                   -- session | external
  work_agent           TEXT,
  work_job             TEXT,
  work_claim           TEXT,                   -- fixed | wontfix (to_verify only)
  severity             TEXT,
  owner                TEXT,
  module               TEXT,
  assignee             TEXT,
  confidence           TEXT,
  source_type          TEXT,                   -- recording | snap | voice | url | import | service
  source_by            TEXT,
  source_app           TEXT,
  source_url           TEXT,
  project_by           TEXT,                   -- capture | ai | user | migrate
  project_confidence   REAL,
  suggested_project    TEXT,                   -- project id the AI suggested (below the threshold)
  suggested_confidence REAL,
  t_start              REAL,
  primary_frame        TEXT,                   -- absolute path of frames[0].path, or NULL
  frame_count          INTEGER NOT NULL DEFAULT 0,
  has_code_refs        INTEGER NOT NULL DEFAULT 0,
  exported             TEXT NOT NULL DEFAULT '{}',  -- JSON copy of item.exported
  user_edited          INTEGER NOT NULL DEFAULT 0,  -- item._user non-empty
  parse_error          TEXT,                   -- the file can't be read back (items.py won't write it)
  created              REAL NOT NULL,          -- epoch seconds
  updated              REAL NOT NULL,          -- epoch seconds (front-matter updated, else the file's mtime)
  mtime                REAL,                   -- the file's mtime when indexed
  UNIQUE (project_id, item_id)
);
CREATE INDEX IF NOT EXISTS items_updated ON items(updated DESC);
CREATE INDEX IF NOT EXISTS items_proj    ON items(project_id, state);
CREATE INDEX IF NOT EXISTS items_session ON items(session_id);

-- Full text. trigram handles Chinese/Japanese (no word segmentation needed); queries shorter than 3 characters
-- can't use trigram, so readers fall back to `title LIKE '%q%' OR quote LIKE '%q%' OR body LIKE '%q%'`.
CREATE VIRTUAL TABLE IF NOT EXISTS items_fts USING fts5(
  title, quote, body, tags,
  content = 'items', content_rowid = 'rowid', tokenize = 'trigram'
);
CREATE TRIGGER IF NOT EXISTS items_ai AFTER INSERT ON items BEGIN
  INSERT INTO items_fts(rowid, title, quote, body, tags) VALUES (new.rowid, new.title, new.quote, new.body, new.tags);
END;
CREATE TRIGGER IF NOT EXISTS items_ad AFTER DELETE ON items BEGIN
  INSERT INTO items_fts(items_fts, rowid, title, quote, body, tags) VALUES ('delete', old.rowid, old.title, old.quote, old.body, old.tags);
END;
CREATE TRIGGER IF NOT EXISTS items_au AFTER UPDATE ON items BEGIN
  INSERT INTO items_fts(items_fts, rowid, title, quote, body, tags) VALUES ('delete', old.rowid, old.title, old.quote, old.body, old.tags);
  INSERT INTO items_fts(rowid, title, quote, body, tags) VALUES (new.rowid, new.title, new.quote, new.body, new.tags);
END;

INSERT OR IGNORE INTO meta(key, value) VALUES ('schema_version', '3');
"""
SCHEMA_VERSION = "3"

SESSION_MARKERS = ("meta.json", "items.json", "batch.json", "recording.mp4", "shots.jsonl")
# Item fields that have their own column (or aren't text): everything else that holds text goes into `body`.
NOT_BODY = {"schema", "id", "uid", "kind", "title", "quote", "tags", "state", "restore_to", "status", "severity",
            "owner", "module",
            "confidence", "time", "frames", "clip", "exported", "_user", "fix", "fix_history", "work", "work_history",
            "merged_from", "merged_into", "aliases", "t", "project", "project_by", "project_confidence",
            "suggested_project", "created", "updated", "source", "language", "assignee", "code_refs"}
ITEM_ROW = ("uid", "project_id", "project_name", "project_key", "session_id", "session_dir", "path", "item_id", "kind",
            "title", "state", "work_to", "work_agent", "severity", "primary_frame", "created", "updated", "snippet",
            "suggested_project")


# ------------------------------------------------------------------ paths
def db_path() -> Path:
    return blurt_home() / "index.db"


def item_uid(session_name: str, item: dict) -> str:
    return item.get("uid") or legacy_uid(session_name, str(item.get("id")))


def is_session(d: Path) -> bool:
    return d.is_dir() and not d.name.startswith(".") and any((d / m).exists() for m in SESSION_MARKERS)


# ------------------------------------------------------------------ db
def _drop_db(path: Path) -> None:
    for ext in ("", "-wal", "-shm"):
        try:
            Path(str(path) + ext).unlink()
        except FileNotFoundError:
            pass


def connect(readonly: bool = False, path: Path | None = None) -> sqlite3.Connection:
    path = path or db_path()
    if readonly:
        con = sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=5)
    else:
        path.parent.mkdir(parents=True, exist_ok=True)
        if path.exists():  # another schema (v1): the index is a cache, rebuild it
            try:
                c = sqlite3.connect(path, timeout=10)
                try:
                    v = c.execute("SELECT value FROM meta WHERE key = 'schema_version'").fetchone()
                finally:
                    c.close()
            except sqlite3.DatabaseError:
                v = None
            if not v or v[0] != SCHEMA_VERSION:
                _drop_db(path)
        con = sqlite3.connect(path, timeout=10, isolation_level=None)
        con.execute("PRAGMA busy_timeout = 10000")
        con.executescript(SCHEMA)
    con.row_factory = sqlite3.Row
    con.execute("PRAGMA foreign_keys = ON")
    return con


class _Tx:
    def __init__(self, con):
        self.con = con

    def __enter__(self):
        self.con.execute("BEGIN IMMEDIATE")
        return self.con

    def __exit__(self, et, ev, tb):
        self.con.execute("COMMIT" if et is None else "ROLLBACK")


# ------------------------------------------------------------------ projects
def _registry() -> dict[str, dict]:
    import projects  # noqa: PLC0415
    return {e["id"]: e for e in projects.entries()}


def _ensure_project(con, s: st.Store, now: float, reg: dict) -> str:
    """The projects row of a store (registered or found on disk)."""
    pid = s.project_id
    if s.is_inbox:
        import projects  # noqa: PLC0415
        e, kind, registered = projects.inbox_entry(), "inbox", 1
        path = str(s.root)
    else:
        path = str(s.project_dir)
        e = reg.get(pid)
        registered = int(e is not None)
        if e is None:
            import projects  # noqa: PLC0415
            name = s.project_dir.name or path
            e = {"name": name, "key": s.meta.get("key") or projects.default_key(name, set()),
                 "slug": projects.default_slug(name, pid, set())}
        kind = "repo" if (s.project_dir / ".git").exists() or st.git_toplevel(s.project_dir) else "folder"
    con.execute("DELETE FROM projects WHERE (path = ? OR store = ?) AND id != ?", (path, str(s.root), pid))
    con.execute("INSERT INTO projects(id, path, store, name, key, slug, kind, registered, last_seen) "
                "VALUES (?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET path=excluded.path, store=excluded.store, "
                "name=excluded.name, key=excluded.key, slug=excluded.slug, kind=excluded.kind, "
                "registered=excluded.registered, last_seen=excluded.last_seen",
                (pid, path, str(s.root), e.get("name") or pid, e.get("key") or "P", e.get("slug") or pid, kind,
                 registered, now))
    return pid


# ------------------------------------------------------------------ reading files
def _mtime(p: Path) -> float | None:
    try:
        return round(p.stat().st_mtime, 6)
    except OSError:
        return None


def _epoch(meta: dict, name: str, d: Path) -> float | None:
    t = to_epoch(meta.get("started_at"))
    if t is not None:
        return t
    m = re.match(r"(\d{8}-\d{6})", name)
    if m:
        try:
            return datetime.strptime(m.group(1), "%Y%m%d-%H%M%S").timestamp()
        except ValueError:
            pass
    return _mtime(d)


def read_shots(d: Path) -> list[dict]:
    """shots.jsonl, one line per change; the later line for the same n wins; deleted shots dropped."""
    by_n: dict = {}
    try:
        lines = (d / "shots.jsonl").read_text(encoding="utf-8").splitlines()
    except OSError:
        return []
    for line in lines:
        try:
            o = json.loads(line)
        except ValueError:
            continue
        if isinstance(o, dict) and "n" in o:
            by_n.setdefault(o["n"], {}).update(o)
    return [o for _, o in sorted(by_n.items(), key=lambda kv: str(kv[0]).zfill(8)) if not o.get("deleted")]


def _flatten(v) -> list[str]:
    if isinstance(v, str):
        return [v] if v.strip() else []
    if isinstance(v, list):
        return [s for x in v for s in _flatten(x)]
    if isinstance(v, dict):
        return [s for x in v.values() for s in _flatten(x)]
    return []


def _text(v) -> str | None:
    if v is None or isinstance(v, (dict, list)):
        return None
    return str(v)


def _num(v) -> float | None:
    return float(v) if isinstance(v, (int, float)) and not isinstance(v, bool) else None


def item_row(item: dict, base: Path, pid: str, session_id: str | None, path: str, mtime: float | None) -> dict:
    """Columns of an items row. base: what relative frame paths are relative to (the store, or a legacy session)."""
    frames = [f for f in item.get("frames") or [] if isinstance(f, dict) and isinstance(f.get("path"), str)]
    tags = item.get("tags") or []
    work = item.get("work") if isinstance(item.get("work"), dict) else \
        (work_from_fix(item["fix"]) if isinstance(item.get("fix"), dict) else {})
    user = item.get("_user") if isinstance(item.get("_user"), dict) else {}
    src = item.get("source") if isinstance(item.get("source"), dict) else {}
    sug = item.get("suggested_project") if isinstance(item.get("suggested_project"), dict) else {}
    t = item.get("time")
    t_start = t.get("start") if isinstance(t, dict) else _num(t)
    if t_start is None and frames:
        t_start = frames[0].get("t")
    body = "\n".join(s for k, v in item.items() if k not in NOT_BODY and not k.startswith("_") for s in _flatten(v))
    stamps = [x for x in user.values() if isinstance(x, (int, float))]
    created = to_epoch(item.get("created")) or mtime or time.time()
    updated = to_epoch(item.get("updated")) or max(stamps + [to_epoch(work.get("at")) or 0, mtime or 0]) or created
    fp = frames[0]["path"] if frames else None
    return {
        "uid": str(item.get("uid")), "project_id": pid, "session_id": session_id, "path": path,
        "item_id": str(item.get("id")), "kind": str(item.get("kind") or "note"), "title": str(item.get("title") or ""),
        "quote": str(item.get("quote") or ""), "body": body,
        "tags": " ".join(map(str, tags)) if isinstance(tags, list) else str(tags),
        "state": state_of(item),
        "work_to": _text(work.get("to")), "work_agent": _text(work.get("agent")), "work_job": _text(work.get("job")),
        "work_claim": _text(work.get("claim")),
        "severity": _text(item.get("severity")), "owner": _text(item.get("owner")), "module": _text(item.get("module")),
        "assignee": _text(item.get("assignee")), "confidence": _text(item.get("confidence")),
        "source_type": _text(src.get("type")), "source_by": _text(src.get("by")), "source_app": _text(src.get("app")),
        "source_url": _text(src.get("url")), "project_by": _text(item.get("project_by")),
        "project_confidence": _num(item.get("project_confidence")), "suggested_project": _text(sug.get("id")),
        "suggested_confidence": _num(sug.get("confidence")), "t_start": _num(t_start),
        "primary_frame": (fp if os.path.isabs(fp) else str(real(base / fp))) if fp else None,
        "frame_count": len(frames), "has_code_refs": int(bool(item.get("code_refs"))),
        "exported": json.dumps(item.get("exported") or {}, ensure_ascii=False, sort_keys=True),
        "user_edited": int(bool(user)), "parse_error": None, "created": created, "updated": updated, "mtime": mtime,
    }


def _insert_item(con, r: dict) -> bool:
    other = con.execute("SELECT path FROM items WHERE uid = ?", (r["uid"],)).fetchone()
    if other and other["path"] != r["path"]:
        if not Path(other["path"].split("#")[0]).exists():
            con.execute("DELETE FROM items WHERE uid = ?", (r["uid"],))
        else:
            return False  # the same uid twice (a copied folder): the one indexed first keeps it
    clash = con.execute("SELECT uid FROM items WHERE project_id = ? AND item_id = ? AND uid != ?",
                        (r["project_id"], r["item_id"], r["uid"])).fetchone()
    if clash:  # two files claim one id (copied by hand): keep both findable
        r = {**r, "item_id": f"{r['item_id']}~{r['uid'][-4:]}"}
    cols = list(r)
    con.execute(f"INSERT INTO items({', '.join(cols)}) VALUES ({', '.join('?' * len(cols))}) ON CONFLICT(uid) DO UPDATE "
                f"SET {', '.join(f'{c}=excluded.{c}' for c in cols if c != 'uid')}", [r[c] for c in cols])
    return True


def _session_id_for(con, d, now: float, reg: dict) -> str | None:
    if not d:
        return None
    d = str(real(d))
    r = con.execute("SELECT id FROM sessions WHERE dir = ?", (d,)).fetchone()
    if r:
        return r["id"]
    if is_session(Path(d)):
        index_session(con, Path(d), now, reg)
        r = con.execute("SELECT id FROM sessions WHERE dir = ?", (d,)).fetchone()
        return r["id"] if r else None
    return None


def index_file(con, p: Path, now: float, reg: dict, s: st.Store | None = None, force: bool = True) -> str:
    """(Re)index one .md. Returns "skipped" | "indexed" | "removed"."""
    p = real(p)
    if not p.is_file():
        n = con.execute("DELETE FROM items WHERE path = ?", (str(p),)).rowcount
        return "removed" if n else "skipped"
    mtime = _mtime(p)
    if not force:
        r = con.execute("SELECT mtime FROM items WHERE path = ?", (str(p),)).fetchone()
        if r and r["mtime"] == mtime:
            return "skipped"
    s = s or st.store_of_item(p)
    pid = _ensure_project(con, s, now, reg)
    try:
        item = st.read_item(p)
    except (st.Unparseable, OSError) as e:
        h = st.read_header(p)
        uid = h.get("uid") if isinstance(h.get("uid"), str) else "X" + hashlib.sha1(str(p).encode()).hexdigest()[:25]
        r = {**item_row({"uid": uid, "id": h.get("id") or p.stem, "title": h.get("title") or p.stem,
                         "kind": h.get("kind")}, s.root, pid, None, str(p), mtime), "parse_error": str(e)[:300]}
        _insert_item(con, r)
        return "indexed"
    src = item.get("source") if isinstance(item.get("source"), dict) else {}
    sid = _session_id_for(con, src.get("session"), now, reg)
    _insert_item(con, item_row(item, s.root, pid, sid, str(p), mtime))
    return "indexed"


def _mode(d: Path, meta: dict) -> str:
    if meta.get("mode") == "voice" or d.name.endswith("-voice"):
        return "voice"
    if meta.get("mode") == "shots" or (not (d / "recording.mp4").exists() and
                                       ((d / "shots.jsonl").exists() or d.name.endswith("-shots"))):
        return "shots"
    return "video"


def _session_store(d: Path) -> st.Store:
    return st.store_of_session(d)


def index_session(con, d: Path, now: float, reg: dict, force: bool = True) -> dict:
    """(Re)index one session dir (and, for a v1/v2 session not migrated yet, its items.json items)."""
    d = real(d)
    row = con.execute("SELECT id, items_mtime, shots_mtime, indexed_at FROM sessions WHERE dir = ?", (str(d),)).fetchone()
    if not is_session(d):
        if row:
            con.execute("DELETE FROM items WHERE path LIKE ? ESCAPE '\\'", (_like_prefix(str(d) + os.sep),))
            con.execute("DELETE FROM sessions WHERE id = ?", (row["id"],))
            return {"removed": True}
        return {"skipped": True}
    batch_f, legacy_f = d / "batch.json", d / "items.json"
    legacy = not batch_f.exists() and legacy_f.exists()
    items_mtime, shots_mtime = _mtime(batch_f if batch_f.exists() else legacy_f), _mtime(d / "shots.jsonl")
    if (not force and row and row["items_mtime"] == items_mtime and row["shots_mtime"] == shots_mtime
            and (_mtime(d / "meta.json") or 0) <= row["indexed_at"]):
        return {"skipped": True}
    s = _session_store(d)
    pid = _ensure_project(con, s, now, reg)
    sid = f"{pid}:{d.name}"
    meta = load_json(d / "meta.json", {}) or {}
    try:
        data = load_json(batch_f) if batch_f.exists() else load_json(legacy_f)
    except ValueError:  # half-written by a non-atomic writer: keep the old rows, the next update catches up
        return {"skipped": True, "error": f"{d.name}: does not parse"}
    data = data if isinstance(data, dict) else None
    shots = read_shots(d)
    mode = _mode(d, meta)
    shot_count = len(shots) if (d / "shots.jsonl").exists() else \
        len([p for p in (d / "shots").glob("[0-9]*.png") if not p.name.endswith(".marked.png")])
    cards = sum(1 for o in shots if "project" in o and o.get("project") is None)
    title = (data or {}).get("title") or meta.get("title")
    if row and row["id"] != sid:
        con.execute("UPDATE items SET session_id = NULL WHERE session_id = ?", (row["id"],))
        con.execute("DELETE FROM sessions WHERE id = ?", (row["id"],))
    con.execute(
        "INSERT INTO sessions(id, project_id, dir, mode, title, author, created, duration, shot_count, card_count, "
        "item_count, processed, processing, reviewed, legacy, items_mtime, shots_mtime, indexed_at) "
        "VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET project_id=excluded.project_id, "
        "dir=excluded.dir, mode=excluded.mode, title=excluded.title, author=excluded.author, created=excluded.created, "
        "duration=excluded.duration, shot_count=excluded.shot_count, card_count=excluded.card_count, "
        "processed=excluded.processed, processing=excluded.processing, reviewed=excluded.reviewed, "
        "legacy=excluded.legacy, items_mtime=excluded.items_mtime, shots_mtime=excluded.shots_mtime, "
        "indexed_at=excluded.indexed_at",
        (sid, pid, str(d), mode, title, _text(meta.get("author")), _epoch(meta, d.name, d),
         _num(meta.get("duration")) if mode == "video" else None, shot_count, cards, 0, int(data is not None),
         int(bool((data or {}).get("processing"))), int(bool((data or {}).get("reviewed"))), int(legacy),
         items_mtime, shots_mtime, now))
    prefix = str(legacy_f) + "#"
    con.execute("DELETE FROM items WHERE path LIKE ? ESCAPE '\\'", (_like_prefix(prefix),))
    n = 0
    if legacy and data:
        gone = set((data.get("_removed") or {}))
        for it in data.get("items") or []:
            if not isinstance(it, dict) or not it.get("id") or it["id"] in gone:
                continue
            it = {**it, "uid": item_uid(d.name, it)}
            r = item_row(it, d, pid, sid, prefix + str(it["id"]), items_mtime)
            r["created"] = _epoch(meta, d.name, d) or r["created"]
            n += int(_insert_item(con, r))
    _count(con, [sid])
    return {"items": n}


def _like_prefix(s: str) -> str:
    return s.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_") + "%"


def _count(con, sids=None) -> None:
    sql = ("UPDATE sessions SET item_count = (SELECT COUNT(*) FROM items i WHERE i.session_id = sessions.id "
           "AND i.state != 'discarded')")
    if sids is None:
        con.execute(sql)
    else:
        for sid in sids:
            con.execute(sql + " WHERE id = ?", (sid,))


def index_store(con, s: st.Store, now: float, reg: dict, force: bool = False) -> dict:
    """Every session and item file of a store; rows of files that went away are dropped."""
    pid = _ensure_project(con, s, now, reg)
    sessions = []
    if s.sessions_dir.is_dir():
        for d in sorted(s.sessions_dir.iterdir()):
            if is_session(d):
                index_session(con, d, now, reg, force=force)
                sessions.append(str(real(d)))
    files = s.files()
    for p in files:
        index_file(con, p, now, reg, s, force=force)
    keep = {str(real(p)) for p in files}
    for r in con.execute("SELECT path FROM items WHERE project_id = ? AND path NOT LIKE '%#%'", (pid,)).fetchall():
        if r["path"] not in keep and Path(r["path"]).parent == s.items_dir:
            con.execute("DELETE FROM items WHERE path = ?", (r["path"],))
    return {"sessions": sessions, "items": len(files)}


# ------------------------------------------------------------------ scan / update
def _stores(extra: list[Path] | None, con) -> tuple[list[st.Store], list[Path]]:
    """Stores to scan, and folders of v0.6 sessions outside any store."""
    import projects  # noqa: PLC0415
    stores = [st.inbox_store()] + [projects.store_of(e) for e in projects.entries()]
    loose = [st.legacy_recordings()]
    if con is not None:
        for r in con.execute("SELECT store FROM projects WHERE registered = 0"):
            stores.append(st.Store(r["store"]))
    for e in extra or []:
        e = real(e)
        if e == real(blurt_workspace()):
            loose.append(e / "recordings")
        elif (e / ".blurt").is_dir():
            stores.append(st.Store(e / ".blurt"))
        elif (e / "store.json").exists() or e.name == ".blurt":
            stores.append(st.Store(e))
        elif e.name == "sessions":
            stores.append(st.Store(e.parent))
        else:
            loose.append(e)
    out, seen = [], set()
    for s in stores:
        if s.root not in seen and (s.root.is_dir()):
            seen.add(s.root)
            out.append(s)
    return out, [p for p in dict.fromkeys(real(x) for x in loose) if p.is_dir()]


def scan(extra: list[Path] | None = None, full: bool = False) -> dict:
    t0 = time.perf_counter()
    now = time.time()
    con = connect()
    reg = _registry()
    try:
        stores, loose = _stores(extra, con)
        found: set[str] = set()
        with _Tx(con):
            for s in stores:
                found.update(index_store(con, s, now, reg, force=full)["sessions"])
            for c in loose:
                for d in sorted(c.iterdir()):
                    if is_session(d):
                        found.add(str(real(d)))
                        index_session(con, d, now, reg, force=full)
            for r in con.execute("SELECT id, dir FROM sessions").fetchall():
                if r["dir"] not in found and not is_session(Path(r["dir"])):
                    con.execute("DELETE FROM sessions WHERE id = ?", (r["id"],))
            for r in con.execute("SELECT uid, path FROM items").fetchall():
                if not Path(r["path"].split("#")[0]).exists():
                    con.execute("DELETE FROM items WHERE uid = ?", (r["uid"],))
            # projects found on disk that no longer hold anything drop out of the lists
            con.execute("DELETE FROM projects WHERE registered = 0 AND id NOT IN (SELECT project_id FROM sessions) "
                        "AND id NOT IN (SELECT project_id FROM items)")
            con.execute("DELETE FROM projects WHERE registered = 1 AND id != 'inbox' AND id NOT IN (" +
                        ",".join("?" * len(reg)) + ")" if reg else
                        "DELETE FROM projects WHERE registered = 1 AND id != 'inbox'", list(reg))
            _count(con)
            con.execute("INSERT INTO meta(key, value) VALUES ('last_full_scan', ?) "
                        "ON CONFLICT(key) DO UPDATE SET value = excluded.value", (str(round(now, 3)),))
        counts = {k: con.execute(f"SELECT COUNT(*) FROM {k}").fetchone()[0] for k in ("projects", "sessions", "items")}
    finally:
        con.close()
    return {**counts, "ms": round((time.perf_counter() - t0) * 1000, 1)}


def update_paths(paths, force: bool = True) -> dict:
    """Re-index these paths (items.py calls this after every write): .md files, store dirs, session dirs, a
    session's items.json / batch.json. Paths that are gone lose their rows."""
    t0 = time.perf_counter()
    now = time.time()
    con = connect()
    reg = _registry()
    n, extra = 0, {}
    try:
        with _Tx(con):
            for p in paths:
                p = Path(p)
                if p.name in ("items.json", "batch.json", "shots.jsonl", "meta.json"):
                    p = p.parent
                if p.suffix == ".md":
                    n += int(index_file(con, p, now, reg) != "skipped")
                elif (p / "store.json").exists() or (p / "items").is_dir() and not is_session(p):
                    index_store(con, st.Store(p), now, reg, force=force)
                    n += 1
                else:
                    r = index_session(con, p, now, reg, force=force)
                    n += 0 if r.get("skipped") else 1
                    if r.get("error"):
                        extra.setdefault("error", []).append(r["error"])
    finally:
        con.close()
    return {"updated": n, "ms": round((time.perf_counter() - t0) * 1000, 1), **extra}


def update_sessions(dirs, force: bool = True) -> dict:
    """v2 name of update_paths (session dirs)."""
    return update_paths(dirs, force)


def update_workspace(folder: Path) -> dict:
    """A project folder (the plugin's SessionEnd hook passes any project root): re-index its store if it has one;
    nothing to index → no index.db appears."""
    s = st.Store(real(folder) / ".blurt") if real(folder).name != ".blurt" else st.Store(folder)
    if not (s.exists or s.sessions_dir.is_dir()):
        return {"updated": 0, "ms": 0.0}
    t0 = time.perf_counter()
    con = connect()
    try:
        with _Tx(con):
            r = index_store(con, s, time.time(), _registry(), force=False)
    finally:
        con.close()
    return {"updated": len(r["sessions"]) + r["items"], "ms": round((time.perf_counter() - t0) * 1000, 1)}


def ensure_index() -> Path:
    """For readers: build the index once if it doesn't exist yet (or has another schema). Returns the db path."""
    p = db_path()
    need = not p.exists()
    if not need:
        try:
            con = connect(readonly=True)
            try:
                need = con.execute("SELECT value FROM meta WHERE key = 'schema_version'").fetchone()[0] != SCHEMA_VERSION \
                    or con.execute("SELECT value FROM meta WHERE key = 'last_full_scan'").fetchone() is None
            finally:
                con.close()
        except (sqlite3.Error, TypeError):
            need = True
    if need:
        scan()
    return p


# ------------------------------------------------------------------ search
def _like(term: str) -> str:
    return "%" + term.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_") + "%"


def _snippet(row, terms: list[str], width: int = 40) -> str | None:
    for col in ("title", "quote", "body"):
        text = row[col] or ""
        for t in terms:
            k = text.lower().find(t.lower())
            if k >= 0:
                a, b = max(0, k - width // 2), min(len(text), k + len(t) + width // 2)
                return ("…" if a else "") + text[a:k] + "[" + text[k:k + len(t)] + "]" + text[k + len(t):b] + \
                    ("…" if b < len(text) else "")
    return None


def resolve_project(con, value: str) -> str:
    """A project given as id, folder, store, name, key or slug ('inbox' included)."""
    if not value:
        return value
    if con.execute("SELECT 1 FROM projects WHERE id = ?", (value,)).fetchone():
        return value
    p = str(real(value))
    for sql, arg in (("SELECT id FROM projects WHERE path = ? OR store = ?", (p, p)),
                     ("SELECT id FROM projects WHERE name = ? OR key = ? OR slug = ?", (value, value, value))):
        r = con.execute(sql, arg).fetchone()
        if r:
            return r["id"]
    return value


def resolve_session(con, value: str) -> str:
    if con.execute("SELECT 1 FROM sessions WHERE id = ?", (value,)).fetchone():
        return value
    r = con.execute("SELECT id FROM sessions WHERE dir = ?", (str(real(value)),)).fetchone()
    return r["id"] if r else value


def search(query: str | None = None, kind=None, status=None, work=None, project: str | None = None,
           session: str | None = None, sort: str = "updated", limit: int = 50, offset: int = 0, con=None,
           fix_state=None, source_type=None, state=None) -> dict:
    """state: [K3 states] (none = all but discarded); status / work / fix_state are the old names, mapped to states
    and narrowing each other and `state`."""
    own = con is None
    con = con or connect(readonly=True)
    try:
        terms = [t for t in (query or "").split() if t]
        fts = [t for t in terms if len(t) >= 3]
        short = [t for t in terms if len(t) < 3]
        where, args = [], []
        if fts:
            where.append("items_fts MATCH ?")
            args.append(" AND ".join('"' + t.replace('"', '""') + '"' for t in fts))
        for t in short:
            where.append("(i.title LIKE ? ESCAPE '\\' OR i.quote LIKE ? ESCAPE '\\' OR i.body LIKE ? ESCAPE '\\')")
            args += [_like(t)] * 3
        states = legacy_filter_states(status or (), work or (), fix_state or ())
        if state:
            states = [x for x in state if states is None or x in states]
        if states is None:
            where.append("i.state != 'discarded'")
        else:
            where.append(f"i.state IN ({','.join('?' * len(states))})" if states else "0")
            args += list(states)
        for col, vals in (("i.kind", kind), ("i.source_type", source_type)):
            if vals:
                where.append(f"{col} IN ({','.join('?' * len(vals))})")
                args += list(vals)
        claims = {f for f in fix_state or () if f in ("fixed", "wontfix")}
        if claims and not {"fixing", "reopened", "none"} & set(fix_state):  # v2: fixed = claimed fixed, or done
            where.append("(i.state != 'to_verify' OR i.work_claim IN (" + ",".join("?" * len(claims)) + "))")
            args += sorted(claims)
        if project:
            where.append("i.project_id = ?")
            args.append(resolve_project(con, project))
        if session:
            where.append("i.session_id = ?")
            args.append(resolve_session(con, session))
        join = "JOIN items_fts f ON f.rowid = i.rowid " if fts else ""
        snip = "snippet(items_fts, -1, '[', ']', '…', 12)" if fts else "NULL"
        order = {"updated": "i.updated DESC", "created": "i.created DESC", "t_start": "i.t_start, i.created DESC",
                 "title": "i.title COLLATE NOCASE"}.get(sort, "i.updated DESC")
        base = (f"FROM items i {join}JOIN projects p ON p.id = i.project_id LEFT JOIN sessions s ON s.id = i.session_id "
                f"WHERE {' AND '.join(where)}")
        total = con.execute(f"SELECT COUNT(*) {base}", args).fetchone()[0]
        rows = con.execute(f"SELECT i.*, p.name AS project_name, p.key AS project_key, s.dir AS session_dir, "
                           f"{snip} AS snippet {base} ORDER BY {order}, i.item_id LIMIT ? OFFSET ?",
                           args + [int(limit), int(offset)]).fetchall()
        out = []
        for r in rows:
            row = {k: r[k] for k in ITEM_ROW}
            if row["snippet"] is None and terms:
                row["snippet"] = _snippet(r, terms)
            out.append(row)
        return {"total": total, "items": out}
    finally:
        if own:
            con.close()


# ------------------------------------------------------------------ backlog
def backlog(repo: Path) -> dict:
    repo = real(repo)
    s = st.Store(repo / ".blurt")
    update_workspace(repo)
    pid = s.project_id
    rows = []
    if db_path().exists():
        con = connect(readonly=True)
        try:
            rows = con.execute(
                f"SELECT * FROM items WHERE project_id = ? AND state IN ({','.join('?' * len(OPEN_STATES))}) "
                f"ORDER BY kind, created DESC, item_id", (pid, *OPEN_STATES)).fetchall()
        finally:
            con.close()
    lines = ["# Blurt backlog", "",
             f"Open items of this project ({len(rows)}). Generated by `index.py backlog` — don't edit; change items "
             "with `items.py` or the blurt MCP tools.", ""]
    kind = None
    for r in rows:
        if r["kind"] != kind:
            kind = r["kind"]
            lines += ["", f"## {kind}", ""]
        extra = ", ".join(x for x in (r["severity"], r["state"]) if x)
        rel = os.path.relpath(r["path"].split("#")[0], repo)
        lines.append(f"- **{r['item_id']} {r['title']}** ({extra}) — `{rel}` · uid `{r['uid']}`")
    out = s.root / "BACKLOG.md"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")
    return {"path": str(out), "items": len(rows)}


# ------------------------------------------------------------------ cli
def main(argv=None) -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("path")
    s = sub.add_parser("scan")
    s.add_argument("--root", action="append", default=[])
    s.add_argument("--full", action="store_true", help="re-index unchanged files too")
    s = sub.add_parser("update")
    s.add_argument("paths", nargs="*")
    s.add_argument("--workspace", metavar="DIR", help="re-index this project folder's store")
    s = sub.add_parser("search")
    s.add_argument("query", nargs="?", default="")
    s.add_argument("--kind", action="append")
    s.add_argument("--state", action="append")
    s.add_argument("--status", action="append", help=argparse.SUPPRESS)  # old names, mapped to states
    s.add_argument("--work", action="append", help=argparse.SUPPRESS)
    s.add_argument("--fix-state", action="append", help=argparse.SUPPRESS)
    s.add_argument("--project", "--workspace", dest="project")
    s.add_argument("--session")
    s.add_argument("--source-type", action="append")
    s.add_argument("--sort", choices=["updated", "created", "t_start", "title"], default="updated")
    s.add_argument("--limit", type=int, default=50)
    s.add_argument("--offset", type=int, default=0)
    s = sub.add_parser("backlog")
    s.add_argument("repo")
    a = p.parse_args(argv)
    try:
        if a.cmd == "path":
            out = {"db": str(db_path())}
        elif a.cmd == "scan":
            out = scan([Path(r) for r in a.root], full=a.full)
        elif a.cmd == "update":
            if not a.paths and not a.workspace:
                p.error("update needs PATH … or --workspace DIR")
            out = update_paths(a.paths) if a.paths else {"updated": 0, "ms": 0.0}
            if a.workspace:
                w = update_workspace(Path(a.workspace))
                out = {"updated": out["updated"] + w["updated"], "ms": round(out["ms"] + w["ms"], 1)}
        elif a.cmd == "search":
            ensure_index()
            out = search(a.query, a.kind, a.status, a.work, a.project, a.session, a.sort, a.limit, a.offset,
                         fix_state=a.fix_state, source_type=a.source_type, state=a.state)
        else:
            out = backlog(Path(a.repo))
    except sqlite3.Error as e:
        print(json.dumps({"ok": False, "error": f"sqlite: {e}", "code": "sqlite"}, ensure_ascii=False), flush=True)
        sys.exit(1)
    print(json.dumps(out, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()
