-- index.db schema v2 as docs/design/next-round.md "v0.7 契约" K1 gives it: the Rust reader's unit tests build their
-- fixture db from this copy (docs/contracts/index-schema.sql is P1's, written by index.py).
PRAGMA foreign_keys = ON;
CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE projects (
  id TEXT PRIMARY KEY,
  path TEXT NOT NULL UNIQUE,
  store TEXT NOT NULL UNIQUE,
  name TEXT NOT NULL, key TEXT NOT NULL, slug TEXT NOT NULL,
  kind TEXT NOT NULL CHECK (kind IN ('inbox', 'folder', 'repo')),
  registered INTEGER NOT NULL DEFAULT 1,
  last_seen REAL
);
CREATE TABLE sessions (
  id TEXT PRIMARY KEY,
  project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  dir TEXT NOT NULL UNIQUE,
  mode TEXT NOT NULL CHECK (mode IN ('video', 'shots', 'voice')),
  title TEXT, author TEXT, created REAL, duration REAL,
  shot_count INTEGER NOT NULL DEFAULT 0,
  card_count INTEGER NOT NULL DEFAULT 0,
  item_count INTEGER NOT NULL DEFAULT 0,
  processed INTEGER NOT NULL DEFAULT 0, processing INTEGER NOT NULL DEFAULT 0, reviewed INTEGER NOT NULL DEFAULT 0,
  legacy INTEGER NOT NULL DEFAULT 0,
  items_mtime REAL, shots_mtime REAL, indexed_at REAL NOT NULL
);
CREATE TABLE items (
  uid TEXT PRIMARY KEY,
  project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  session_id TEXT REFERENCES sessions(id) ON DELETE SET NULL,
  path TEXT NOT NULL UNIQUE,
  item_id TEXT NOT NULL,
  kind TEXT NOT NULL, title TEXT NOT NULL DEFAULT '', quote TEXT NOT NULL DEFAULT '', body TEXT NOT NULL DEFAULT '',
  tags TEXT NOT NULL DEFAULT '',
  status TEXT NOT NULL,
  work_state TEXT NOT NULL DEFAULT 'todo',
  work_to TEXT, work_agent TEXT, work_job TEXT, work_claim TEXT,
  severity TEXT, owner TEXT, module TEXT, assignee TEXT, confidence TEXT,
  source_type TEXT, source_by TEXT, source_app TEXT, source_url TEXT,
  project_by TEXT, project_confidence REAL, suggested_project TEXT, suggested_confidence REAL,
  t_start REAL, primary_frame TEXT, frame_count INTEGER NOT NULL DEFAULT 0, has_code_refs INTEGER NOT NULL DEFAULT 0,
  exported TEXT NOT NULL DEFAULT '{}', user_edited INTEGER NOT NULL DEFAULT 0, parse_error TEXT,
  created REAL NOT NULL, updated REAL NOT NULL, mtime REAL,
  UNIQUE (project_id, item_id)
);
CREATE INDEX items_updated ON items(updated DESC);
CREATE INDEX items_proj ON items(project_id, status, work_state);
CREATE VIRTUAL TABLE items_fts USING fts5(title, quote, body, tags, content = 'items', content_rowid = 'rowid', tokenize = 'trigram');
CREATE TRIGGER items_ai AFTER INSERT ON items BEGIN
  INSERT INTO items_fts(rowid, title, quote, body, tags) VALUES (new.rowid, new.title, new.quote, new.body, new.tags);
END;
CREATE TRIGGER items_ad AFTER DELETE ON items BEGIN
  INSERT INTO items_fts(items_fts, rowid, title, quote, body, tags) VALUES ('delete', old.rowid, old.title, old.quote, old.body, old.tags);
END;
CREATE TRIGGER items_au AFTER UPDATE ON items BEGIN
  INSERT INTO items_fts(items_fts, rowid, title, quote, body, tags) VALUES ('delete', old.rowid, old.title, old.quote, old.body, old.tags);
  INSERT INTO items_fts(rowid, title, quote, body, tags) VALUES (new.rowid, new.title, new.quote, new.body, new.tags);
END;
INSERT INTO meta(key, value) VALUES ('schema_version', '2');
