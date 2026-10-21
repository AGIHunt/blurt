# /// script
# requires-python = ">=3.10"
# ///
"""The search index over every blurt session: $BLURT_HOME/index.db (SQLite, WAL). This script is its only writer;
the apps and mcp_server.py open it read-only. The files stay the source of truth — deleting index.db loses nothing,
`index.py scan` rebuilds it. Contract C3 (docs/design/desktop-app.md §5, schema docs/contracts/index-schema.sql).

  index.py path                         → {"db": "…/index.db"}
  index.py scan [--root DIR …] [--full] every recording root (~/Blurt/recordings, record.workspaces, workspaces
                                        already indexed, --root) → {"workspaces","sessions","items","ms"}
                                        unchanged sessions are skipped unless --full
  index.py update SESSION_DIR …         re-index those sessions (a deleted dir → its rows go) → {"updated","ms"}
  index.py update --workspace DIR       re-index the changed sessions under DIR/.blurt/sessions (no-op without it)
  index.py search [QUERY] [--kind K]… [--status S]… [--fix-state F]… [--workspace ID|DIR] [--session ID|DIR]
                  [--sort updated|created|t_start] [--limit 50] [--offset 0]   → {"total": n, "items": [ItemRow]}
  index.py backlog REPO                 writes REPO/.blurt/BACKLOG.md (open items) → {"path", "items"}

Every call prints one JSON line. Python API (items.py / mcp_server.py import it): update_sessions(dirs),
scan(roots), search(...), legacy_uid(name, id), db_path(), connect(readonly=True).

Search, for every host (macOS app, Tauri, mcp_server.py) — run the same queries:
  QUERY is split on whitespace; each term must match (AND). A term of ≥ 3 characters goes to FTS5 (trigram,
  so Chinese works without word segmentation) as a quoted phrase ("" doubles a quote); a 1–2 character term
  can't use trigram and becomes `(i.title LIKE ?1 OR i.quote LIKE ?1 OR i.body LIKE ?1)` with ?1 = '%term%'
  (LIKE escapes % _ \\ with ESCAPE '\\'). Status defaults to "everything but deleted"; --fix-state none = NULL.

    SELECT i.*, s.dir AS session_dir, snippet(items_fts, -1, '[', ']', '…', 12) AS snippet
    FROM items i JOIN items_fts f ON f.rowid = i.rowid JOIN sessions s ON s.id = i.session_id
    WHERE items_fts MATCH ?1 AND i.status != 'deleted' [AND i.kind IN (…)] [AND (i.title LIKE ?2 OR …)]
    ORDER BY i.updated DESC LIMIT ?3 OFFSET ?4
  -- without any ≥3-char term: same query without the items_fts join (snippet computed by the host, or NULL)
  -- --sort created: ORDER BY s.created DESC, i.t_start ;  --sort t_start: ORDER BY i.t_start, s.created DESC

ItemRow = {uid, session_id, session_dir, item_id, kind, title, status, fix_state, severity, primary_frame,
           updated, snippet}.
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
from _common import load_json  # noqa: E402

# Keep byte-identical to docs/contracts/index-schema.sql (tests/test_index.py checks it). The skill ships without docs/.
SCHEMA = """\
-- blurt index.db — schema v1 (contract C3 in docs/design/desktop-app.md §5)
-- Location: $BLURT_HOME/index.db (default ~/.blurt/index.db).
-- Single writer: skills/blurt/scripts/index.py. Readers (read-only, WAL): macOS app (SQLite3 C API),
-- Tauri app (rusqlite), mcp_server.py. The files (items.json, shots.jsonl, meta.json) stay the source of truth:
-- deleting index.db loses nothing; `index.py scan` rebuilds it.
-- Requires SQLite >= 3.34 (FTS5 trigram). macOS 26 ships 3.51; Python 3.12+ from uv ships >= 3.45.

PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS meta (
  key   TEXT PRIMARY KEY,           -- 'schema_version' = '1', 'last_full_scan' = epoch seconds
  value TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS workspaces (
  id        TEXT PRIMARY KEY,       -- first 12 hex chars of sha1(realpath(path))
  path      TEXT NOT NULL UNIQUE,   -- ~/Blurt or the repo root (sessions live in <path>/.blurt/sessions)
  name      TEXT NOT NULL,          -- basename, or "Blurt" for the default workspace
  kind      TEXT NOT NULL CHECK (kind IN ('default', 'repo')),
  last_seen REAL
);

CREATE TABLE IF NOT EXISTS sessions (
  id           TEXT PRIMARY KEY,    -- "<workspace_id>:<session dir name>"
  workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  dir          TEXT NOT NULL UNIQUE,-- absolute path of the session dir
  mode         TEXT NOT NULL CHECK (mode IN ('video', 'shots')),
  title        TEXT,
  author       TEXT,
  created      REAL,                -- epoch seconds (meta.json, else dir name timestamp)
  duration     REAL,                -- seconds; NULL for shots sessions
  shot_count   INTEGER NOT NULL DEFAULT 0,
  item_count   INTEGER NOT NULL DEFAULT 0,  -- items with status != 'deleted'
  processed    INTEGER NOT NULL DEFAULT 0,  -- items.json exists
  processing   INTEGER NOT NULL DEFAULT 0,  -- items.json "processing": true
  reviewed     INTEGER NOT NULL DEFAULT 0,  -- items.json "reviewed": true
  items_mtime  REAL,
  shots_mtime  REAL,
  indexed_at   REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS sessions_ws_created ON sessions(workspace_id, created DESC);

CREATE TABLE IF NOT EXISTS items (
  uid           TEXT PRIMARY KEY,   -- items.json item.uid; legacy items: "L" + sha1("<session dir name>/<item id>")[:25]
  session_id    TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  item_id       TEXT NOT NULL,      -- "I-001"
  kind          TEXT NOT NULL,      -- issue | idea | note | task | <custom lens>
  title         TEXT NOT NULL DEFAULT '',
  quote         TEXT NOT NULL DEFAULT '',
  body          TEXT NOT NULL DEFAULT '',  -- lens fields flattened: actual, expected, steps, why, next… joined by "\\n"
  tags          TEXT NOT NULL DEFAULT '',  -- space-joined
  status        TEXT NOT NULL,      -- draft | confirmed | deleted
  fix_state     TEXT,               -- NULL | fixing | fixed | wontfix | reopened
  severity      TEXT,
  owner         TEXT,
  module        TEXT,
  confidence    TEXT,
  t_start       REAL,
  primary_frame TEXT,               -- absolute path of frames[0].path, or NULL
  frame_count   INTEGER NOT NULL DEFAULT 0,
  has_code_refs INTEGER NOT NULL DEFAULT 0,
  exported      TEXT NOT NULL DEFAULT '{}',  -- JSON copy of item.exported
  user_edited   INTEGER NOT NULL DEFAULT 0,  -- item._user non-empty
  updated       REAL NOT NULL,      -- max(_user values, fix.at, items_mtime)
  UNIQUE (session_id, item_id)
);
CREATE INDEX IF NOT EXISTS items_updated   ON items(updated DESC);
CREATE INDEX IF NOT EXISTS items_kind_stat ON items(kind, status, fix_state);

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

INSERT OR IGNORE INTO meta(key, value) VALUES ('schema_version', '1');
"""

SESSION_MARKERS = ("meta.json", "items.json", "recording.mp4", "shots.jsonl")
# Item fields that have their own column (or aren't text): everything else that holds text goes into `body`.
NOT_BODY = {"id", "uid", "kind", "title", "quote", "tags", "status", "severity", "owner", "module", "confidence",
            "time", "frames", "clip", "exported", "_user", "fix", "fix_history", "merged_from", "t"}
ITEM_ROW = ("uid", "session_id", "session_dir", "item_id", "kind", "title", "status", "fix_state", "severity",
            "primary_frame", "updated", "snippet")


# ------------------------------------------------------------------ paths and identities
def blurt_home() -> Path:
    return Path(os.environ.get("BLURT_HOME") or Path.home() / ".blurt")


def db_path() -> Path:
    return blurt_home() / "index.db"


def default_workspace() -> Path:
    """The Blurt app's own workspace: ~/Blurt, whose sessions live in ~/Blurt/recordings (record.py inbox_dir)."""
    return Path.home() / "Blurt"


def real(p: Path | str) -> Path:
    return Path(os.path.realpath(os.path.expanduser(str(p))))


def workspace_id(path: Path | str) -> str:
    return hashlib.sha1(str(real(path)).encode("utf-8")).hexdigest()[:12]


def legacy_uid(session_name: str, item_id: str) -> str:
    """C1: the uid of an item written before uids existed (items.py ensure-uids writes the same value)."""
    return "L" + hashlib.sha1(f"{session_name}/{item_id}".encode("utf-8")).hexdigest()[:25]


def item_uid(session_name: str, item: dict) -> str:
    return item.get("uid") or legacy_uid(session_name, str(item.get("id")))


def sessions_dir(ws: Path, kind: str) -> Path:
    return ws / "recordings" if kind == "default" else ws / ".blurt" / "sessions"


def workspace_of(session: Path) -> tuple[Path, str]:
    """(workspace path, kind) for a session dir: ~/Blurt/recordings/<ts> → ~/Blurt; <repo>/.blurt/sessions/<ts> →
    <repo>; anything else → its parent directory (a loose folder of sessions)."""
    parent = session.parent
    if parent == real(default_workspace() / "recordings"):
        return parent.parent, "default"
    if parent.name == "sessions" and parent.parent.name == ".blurt":
        return parent.parent.parent, "repo"
    return parent, "repo"


def is_session(d: Path) -> bool:
    return d.is_dir() and not d.name.startswith(".") and any((d / m).exists() for m in SESSION_MARKERS)


# ------------------------------------------------------------------ db
def connect(readonly: bool = False, path: Path | None = None) -> sqlite3.Connection:
    path = path or db_path()
    if readonly:
        con = sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=5)
    else:
        path.parent.mkdir(parents=True, exist_ok=True)
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


# ------------------------------------------------------------------ reading a session
def _mtime(p: Path) -> float | None:
    try:
        return round(p.stat().st_mtime, 6)
    except OSError:
        return None


def _epoch(meta: dict, name: str, d: Path) -> float | None:
    s = meta.get("started_at")
    if isinstance(s, (int, float)):
        return float(s)
    if isinstance(s, str) and s:
        try:
            return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()
        except ValueError:
            pass
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


def item_row(item: dict, session_id: str, d: Path, items_mtime: float) -> dict:
    frames = [f for f in item.get("frames") or [] if isinstance(f, dict) and f.get("path")]
    tags = item.get("tags") or []
    fix = item.get("fix") if isinstance(item.get("fix"), dict) else {}
    user = item.get("_user") if isinstance(item.get("_user"), dict) else {}
    stamps = [v for v in user.values() if isinstance(v, (int, float))]
    if isinstance(fix.get("at"), (int, float)):
        stamps.append(fix["at"])
    t = item.get("time")
    t_start = t.get("start") if isinstance(t, dict) else (t if isinstance(t, (int, float)) else None)
    if t_start is None and frames and isinstance(frames[0].get("t"), (int, float)):
        t_start = frames[0]["t"]
    body = "\n".join(s for k, v in item.items() if k not in NOT_BODY and not k.startswith("_") for s in _flatten(v))
    return {
        "uid": item_uid(d.name, item), "session_id": session_id, "item_id": str(item.get("id")),
        "kind": str(item.get("kind") or "note"), "title": str(item.get("title") or ""),
        "quote": str(item.get("quote") or ""), "body": body,
        "tags": " ".join(tags) if isinstance(tags, list) else str(tags),
        "status": str(item.get("status") or "draft"), "fix_state": _text(fix.get("state")),
        "severity": _text(item.get("severity")), "owner": _text(item.get("owner")), "module": _text(item.get("module")),
        "confidence": _text(item.get("confidence")), "t_start": t_start if isinstance(t_start, (int, float)) else None,
        "primary_frame": str(real(d / frames[0]["path"])) if frames else None, "frame_count": len(frames),
        "has_code_refs": int(bool(item.get("code_refs"))),
        "exported": json.dumps(item.get("exported") or {}, ensure_ascii=False, sort_keys=True),
        "user_edited": int(bool(user)), "updated": max(stamps + [items_mtime or 0.0]),
    }


def _ensure_workspace(con, path: Path, kind: str, now: float) -> str:
    wid = workspace_id(path)
    name = "Blurt" if kind == "default" else (path.name or str(path))
    con.execute("INSERT INTO workspaces(id, path, name, kind, last_seen) VALUES (?,?,?,?,?) "
                "ON CONFLICT(id) DO UPDATE SET last_seen = excluded.last_seen", (wid, str(path), name, kind, now))
    return wid


def _drop_session(con, sid: str) -> None:
    con.execute("DELETE FROM items WHERE session_id = ?", (sid,))  # explicit: keeps items_fts in step via items_ad
    con.execute("DELETE FROM sessions WHERE id = ?", (sid,))


def index_session(con, d: Path, now: float, force: bool = True) -> dict:
    """(Re)index one session dir inside the caller's transaction. Returns {"items": n} / {"skipped": True} /
    {"removed": True}."""
    d = real(d)
    row = con.execute("SELECT id, items_mtime, shots_mtime, indexed_at FROM sessions WHERE dir = ?", (str(d),)).fetchone()
    if not is_session(d):
        if row:
            _drop_session(con, row["id"])
            return {"removed": True}
        return {"skipped": True}
    items_mtime, shots_mtime = _mtime(d / "items.json"), _mtime(d / "shots.jsonl")
    if (not force and row and row["items_mtime"] == items_mtime and row["shots_mtime"] == shots_mtime
            and (_mtime(d / "meta.json") or 0) <= row["indexed_at"]):
        return {"skipped": True}
    ws, kind = workspace_of(d)
    wid = _ensure_workspace(con, ws, kind, now)
    sid = f"{wid}:{d.name}"
    meta = load_json(d / "meta.json", {}) or {}
    try:
        data = load_json(d / "items.json")
    except ValueError:  # half-written by a non-atomic writer: keep the old rows, the next update catches up
        return {"skipped": True, "error": "items.json does not parse"}
    data = data if isinstance(data, dict) else None
    items = [i for i in (data or {}).get("items", []) if isinstance(i, dict) and i.get("id")]
    shots = read_shots(d)
    mode = "shots" if meta.get("mode") == "shots" or (not (d / "recording.mp4").exists() and
                                                       ((d / "shots.jsonl").exists() or d.name.endswith("-shots"))) else "video"
    shot_count = len(shots) if (d / "shots.jsonl").exists() else \
        len([p for p in (d / "shots").glob("[0-9]*.png") if not p.name.endswith(".marked.png")])
    title = (data or {}).get("title") or meta.get("title")
    if row and row["id"] != sid:  # moved to another workspace id (should not happen; be safe)
        _drop_session(con, row["id"])
    con.execute("DELETE FROM items WHERE session_id = ?", (sid,))
    con.execute(
        "INSERT INTO sessions(id, workspace_id, dir, mode, title, author, created, duration, shot_count, item_count, "
        "processed, processing, reviewed, items_mtime, shots_mtime, indexed_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?) "
        "ON CONFLICT(id) DO UPDATE SET workspace_id=excluded.workspace_id, dir=excluded.dir, mode=excluded.mode, "
        "title=excluded.title, author=excluded.author, created=excluded.created, duration=excluded.duration, "
        "shot_count=excluded.shot_count, item_count=excluded.item_count, processed=excluded.processed, "
        "processing=excluded.processing, reviewed=excluded.reviewed, items_mtime=excluded.items_mtime, "
        "shots_mtime=excluded.shots_mtime, indexed_at=excluded.indexed_at",
        (sid, wid, str(d), mode, title, _text(meta.get("author")), _epoch(meta, d.name, d),
         None if mode == "shots" else (meta.get("duration") if isinstance(meta.get("duration"), (int, float)) else None),
         shot_count, sum(1 for i in items if i.get("status") != "deleted"), int(data is not None),
         int(bool((data or {}).get("processing"))), int(bool((data or {}).get("reviewed"))),
         items_mtime, shots_mtime, now))
    n, dupes = 0, []
    for it in items:
        r = item_row(it, sid, d, items_mtime or now)
        other = con.execute("SELECT session_id FROM items WHERE uid = ?", (r["uid"],)).fetchone()
        if other:  # same uid in two sessions (a copied session dir): the one indexed first keeps it
            dupes.append(r["uid"])
            continue
        cols = [c for c in r if c != "session_dir"]
        con.execute(f"INSERT INTO items({', '.join(cols)}) VALUES ({', '.join('?' * len(cols))})", [r[c] for c in cols])
        n += 1
    return {"items": n, **({"duplicate_uids": dupes} if dupes else {})}


# ------------------------------------------------------------------ scan / update
def _config_workspaces() -> list[Path]:
    cfg = load_json(blurt_home() / "config.json", {}) or {}
    rec = cfg.get("record") if isinstance(cfg.get("record"), dict) else {}
    return [Path(os.path.expanduser(w)) for w in rec.get("workspaces") or [] if isinstance(w, str)]


def _root_workspace(root: Path) -> tuple[Path, str, Path]:
    """--root DIR may be a repo (with .blurt/sessions), ~/Blurt, a sessions dir, or a folder of session dirs."""
    root = real(root)
    if root == real(default_workspace()):
        return root, "default", root / "recordings"
    if (root / ".blurt" / "sessions").is_dir():
        return root, "repo", root / ".blurt" / "sessions"
    if root == real(default_workspace() / "recordings"):
        return root.parent, "default", root
    if root.name == "sessions" and root.parent.name == ".blurt":
        return root.parent.parent, "repo", root
    return root, "repo", root


def roots(extra: list[Path] | None = None, con=None) -> list[Path]:
    """Session containers to scan: ~/Blurt/recordings, record.workspaces, workspaces already in the db, --root."""
    out = [default_workspace() / "recordings"] + [w / ".blurt" / "sessions" for w in _config_workspaces()]
    if con is not None:
        for r in con.execute("SELECT path, kind FROM workspaces"):
            out.append(sessions_dir(Path(r["path"]), r["kind"]))
    for e in extra or []:
        out.append(_root_workspace(Path(e))[2])
    seen, res = set(), []
    for r in out:
        rr = real(r)
        if rr not in seen and rr.is_dir():
            seen.add(rr)
            res.append(rr)
    return res


def scan(extra: list[Path] | None = None, full: bool = False) -> dict:
    t0 = time.perf_counter()
    now = time.time()
    con = connect()
    try:
        containers = roots(extra, con)
        found: set[str] = set()
        with _Tx(con):
            for c in containers:
                for d in sorted(c.iterdir()):
                    if is_session(d):
                        found.add(str(real(d)))
                        index_session(con, d, now, force=full)
            for r in con.execute("SELECT id, dir FROM sessions").fetchall():
                if r["dir"] not in found and not is_session(Path(r["dir"])):
                    _drop_session(con, r["id"])
            # workspaces left without sessions drop out of the lists
            con.execute("DELETE FROM workspaces WHERE id NOT IN (SELECT DISTINCT workspace_id FROM sessions)")
            con.execute("INSERT INTO meta(key, value) VALUES ('last_full_scan', ?) "
                        "ON CONFLICT(key) DO UPDATE SET value = excluded.value", (str(round(now, 3)),))
        counts = {k: con.execute(f"SELECT COUNT(*) FROM {k}").fetchone()[0] for k in ("workspaces", "sessions", "items")}
    finally:
        con.close()
    return {**counts, "ms": round((time.perf_counter() - t0) * 1000, 1)}


def update_sessions(dirs, force: bool = True) -> dict:
    """Re-index these session dirs (items.py calls this after every write). Removed dirs lose their rows."""
    t0 = time.perf_counter()
    now = time.time()
    con = connect()
    n, extra = 0, {}
    try:
        with _Tx(con):
            for d in dirs:
                r = index_session(con, Path(d), now, force=force)
                n += 0 if r.get("skipped") else 1
                for k in ("duplicate_uids", "error"):
                    if r.get(k):
                        extra.setdefault(k, []).append(r[k] if k == "error" else r[k])
    finally:
        con.close()
    return {"updated": n, "ms": round((time.perf_counter() - t0) * 1000, 1), **extra}


def update_workspace(ws: Path) -> dict:
    ws_, kind, container = _root_workspace(ws)
    # only a real sessions dir (the hook passes any project root: no .blurt/sessions → nothing to do, no db created)
    if not container.is_dir() or container == real(ws) and kind == "repo":
        return {"updated": 0, "ms": 0.0}
    dirs = [d for d in container.iterdir() if is_session(d)]
    con = connect()
    try:  # sessions of this workspace that were deleted since
        gone = [r["dir"] for r in con.execute("SELECT dir FROM sessions WHERE workspace_id = ?", (workspace_id(ws_),))
                if not Path(r["dir"]).exists()]
    finally:
        con.close()
    return update_sessions(dirs + [Path(g) for g in gone], force=False)


def ensure_index() -> Path:
    """For readers: build the index once if it doesn't exist yet. Returns the db path."""
    p = db_path()
    need = not p.exists()
    if not need:
        try:
            con = connect(readonly=True)
            need = con.execute("SELECT value FROM meta WHERE key = 'last_full_scan'").fetchone() is None
            con.close()
        except sqlite3.Error:
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


def _resolve(con, table: str, value: str) -> str:
    """A workspace / session given as id or as a directory."""
    if con.execute(f"SELECT 1 FROM {table} WHERE id = ?", (value,)).fetchone():
        return value
    p = str(real(value))
    col = "path" if table == "workspaces" else "dir"
    r = con.execute(f"SELECT id FROM {table} WHERE {col} = ?", (p,)).fetchone()
    if r:
        return r["id"]
    if table == "workspaces":
        r = con.execute("SELECT id FROM workspaces WHERE name = ?", (value,)).fetchone()
        if r:
            return r["id"]
    return value


def search(query: str | None = None, kind=None, status=None, fix_state=None, workspace: str | None = None,
           session: str | None = None, sort: str = "updated", limit: int = 50, offset: int = 0, con=None) -> dict:
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
        if status:
            where.append(f"i.status IN ({','.join('?' * len(status))})")
            args += list(status)
        else:
            where.append("i.status != 'deleted'")
        if kind:
            where.append(f"i.kind IN ({','.join('?' * len(kind))})")
            args += list(kind)
        if fix_state:
            fs = [f for f in fix_state if f != "none"]
            parts = ([f"i.fix_state IN ({','.join('?' * len(fs))})"] if fs else []) + \
                    (["i.fix_state IS NULL"] if "none" in fix_state else [])
            where.append("(" + " OR ".join(parts) + ")")
            args += fs
        if workspace:
            where.append("s.workspace_id = ?")
            args.append(_resolve(con, "workspaces", workspace))
        if session:
            where.append("i.session_id = ?")
            args.append(_resolve(con, "sessions", session))
        join = "JOIN items_fts f ON f.rowid = i.rowid " if fts else ""
        snip = "snippet(items_fts, -1, '[', ']', '…', 12)" if fts else "NULL"
        order = {"updated": "i.updated DESC", "created": "s.created DESC, i.t_start",
                 "t_start": "i.t_start, s.created DESC"}.get(sort, "i.updated DESC")
        base = f"FROM items i {join}JOIN sessions s ON s.id = i.session_id WHERE {' AND '.join(where)}"
        total = con.execute(f"SELECT COUNT(*) {base}", args).fetchone()[0]
        rows = con.execute(f"SELECT i.*, s.dir AS session_dir, {snip} AS snippet {base} ORDER BY {order}, i.item_id "
                           f"LIMIT ? OFFSET ?", args + [int(limit), int(offset)]).fetchall()
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
    update_workspace(repo)
    con = connect(readonly=True)
    try:
        wid = workspace_id(repo)
        rows = con.execute(
            "SELECT i.*, s.dir AS session_dir, s.title AS session_title FROM items i JOIN sessions s ON s.id = i.session_id "
            "WHERE s.workspace_id = ? AND i.status != 'deleted' AND (i.fix_state IS NULL OR i.fix_state IN "
            "('fixing', 'reopened')) ORDER BY i.kind, s.created DESC, i.item_id", (wid,)).fetchall()
    finally:
        con.close()
    lines = ["# Blurt backlog", "",
             f"Open items recorded in this repo ({len(rows)}). Generated by `index.py backlog` — don't edit; change items "
             "with `items.py` or the blurt MCP tools.", ""]
    kind = None
    for r in rows:
        if r["kind"] != kind:
            kind = r["kind"]
            lines += ["", f"## {kind}", ""]
        extra = ", ".join(x for x in (r["severity"], r["fix_state"], r["status"]) if x)
        rel = os.path.relpath(r["session_dir"], repo)
        lines.append(f"- **{r['title'] or r['item_id']}** ({extra}) — `{rel}` {r['item_id']} · uid `{r['uid']}`")
    out = repo / ".blurt" / "BACKLOG.md"
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
    s.add_argument("--full", action="store_true", help="re-index unchanged sessions too")
    s = sub.add_parser("update")
    s.add_argument("sessions", nargs="*")
    s.add_argument("--workspace", metavar="DIR", help="re-index the changed sessions of this repo / workspace")
    s = sub.add_parser("search")
    s.add_argument("query", nargs="?", default="")
    s.add_argument("--kind", action="append")
    s.add_argument("--status", action="append")
    s.add_argument("--fix-state", action="append")
    s.add_argument("--workspace")
    s.add_argument("--session")
    s.add_argument("--sort", choices=["updated", "created", "t_start"], default="updated")
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
            if not a.sessions and not a.workspace:
                p.error("update needs SESSION_DIR … or --workspace DIR")
            out = update_sessions(a.sessions) if a.sessions else {"updated": 0, "ms": 0.0}
            if a.workspace:
                w = update_workspace(Path(a.workspace))
                out = {"updated": out["updated"] + w["updated"], "ms": round(out["ms"] + w["ms"], 1)}
        elif a.cmd == "search":
            ensure_index()
            out = search(a.query, a.kind, a.status, a.fix_state, a.workspace, a.session, a.sort, a.limit, a.offset)
        else:
            out = backlog(Path(a.repo))
    except sqlite3.Error as e:
        print(json.dumps({"ok": False, "error": f"sqlite: {e}"}, ensure_ascii=False), flush=True)
        sys.exit(1)
    print(json.dumps(out, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()
