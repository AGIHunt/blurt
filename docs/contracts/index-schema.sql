-- blurt index.db — schema v2 (contract K1 in docs/design/next-round.md, "index.db schema v2")
-- Location: $BLURT_HOME/index.db (default ~/.blurt/index.db).
-- Single writer: skills/blurt/scripts/index.py. Readers (read-only, WAL): macOS app (SQLite3 C API),
-- Tauri app (rusqlite), mcp_server.py, agents.py. The files stay the source of truth (items/*.md in each store,
-- batch.json / shots.jsonl / meta.json in each session; v1/v2 items.json for sessions not migrated yet): deleting
-- index.db loses nothing, `index.py scan` rebuilds it. index.py drops and rebuilds a db whose schema_version differs.
-- Requires SQLite >= 3.34 (FTS5 trigram). macOS 26 ships 3.51; Python 3.12+ from uv ships >= 3.45.

PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS meta (
  key   TEXT PRIMARY KEY,           -- 'schema_version' = '2', 'last_full_scan' = epoch seconds
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
  item_count  INTEGER NOT NULL DEFAULT 0,  -- items with source.session = dir and status != 'deleted'
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
  body                 TEXT NOT NULL DEFAULT '',  -- lens fields flattened: actual, expected, steps, why… joined by "\n"
  tags                 TEXT NOT NULL DEFAULT '',  -- space-joined
  status               TEXT NOT NULL,          -- draft | confirmed | deleted
  work_state           TEXT NOT NULL DEFAULT 'todo',  -- todo | handed_off | in_progress | to_verify | done | wontfix
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
CREATE INDEX IF NOT EXISTS items_proj    ON items(project_id, status, work_state);
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

INSERT OR IGNORE INTO meta(key, value) VALUES ('schema_version', '2');
