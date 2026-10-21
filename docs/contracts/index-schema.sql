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
  body          TEXT NOT NULL DEFAULT '',  -- lens fields flattened: actual, expected, steps, why, next… joined by "\n"
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
