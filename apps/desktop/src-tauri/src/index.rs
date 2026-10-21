//! Read-only access to `$BLURT_HOME/index.db` (contract C3). index.py is the only writer; we open with
//! `SQLITE_OPEN_READ_ONLY` per query (cheap, and a rebuilt file is picked up at once).
//!
//! Search follows index.py's docstring so every host returns the same rows: the query is split on whitespace, every
//! term must match; a term of ≥ 3 characters goes to FTS5 (trigram) as a quoted phrase, a shorter one becomes
//! `(title LIKE OR quote LIKE OR body LIKE)`. Status defaults to "everything but deleted"; fix_state "none" = NULL.

use std::path::{Path, PathBuf};

use rusqlite::{params_from_iter, types::Value as SqlValue, Connection, OpenFlags, Row};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

#[derive(Debug, Default, Deserialize, Clone)]
#[serde(default)]
pub struct ItemQuery {
    pub query: Option<String>,
    pub kind: Vec<String>,
    pub status: Vec<String>,
    pub fix_state: Vec<String>,
    pub severity: Vec<String>,
    /// workspace id, or its path
    pub workspace: Option<String>,
    /// session id, or its dir
    pub session: Option<String>,
    pub has_code_refs: Option<bool>,
    /// "updated" (default) | "created" | "t_start"
    pub sort: Option<String>,
    pub limit: Option<i64>,
    pub offset: Option<i64>,
}

#[derive(Debug, Default, Deserialize, Clone)]
#[serde(default)]
pub struct SessionQuery {
    pub workspace: Option<String>,
    /// "unprocessed" | "processing" | "unreviewed" | "reviewed" | "inbox" (= not processed, processing or unreviewed)
    pub state: Option<String>,
    pub limit: Option<i64>,
    pub offset: Option<i64>,
}

#[derive(Debug, Serialize)]
pub struct ItemPage {
    pub total: i64,
    pub items: Vec<Value>,
    /// true when index.db doesn't exist yet (the UI says "building the index…" / "install uv")
    pub missing: bool,
}

pub struct Index {
    pub path: PathBuf,
}

fn open(path: &Path) -> rusqlite::Result<Connection> {
    let c = Connection::open_with_flags(
        path,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX | OpenFlags::SQLITE_OPEN_URI,
    )?;
    c.busy_timeout(std::time::Duration::from_millis(2000))?;
    Ok(c)
}

fn row_json(row: &Row) -> rusqlite::Result<Value> {
    let st = row.as_ref();
    let mut m = serde_json::Map::new();
    for i in 0..st.column_count() {
        let name = st.column_name(i)?.to_string();
        let v: SqlValue = row.get(i)?;
        m.insert(
            name,
            match v {
                SqlValue::Null => Value::Null,
                SqlValue::Integer(n) => json!(n),
                SqlValue::Real(f) => json!(f),
                SqlValue::Text(s) => Value::String(s),
                SqlValue::Blob(_) => Value::Null,
            },
        );
    }
    Ok(Value::Object(m))
}

fn like_escape(t: &str) -> String {
    let mut s = String::from("%");
    for c in t.chars() {
        if matches!(c, '%' | '_' | '\\') {
            s.push('\\');
        }
        s.push(c);
    }
    s.push('%');
    s
}

fn in_list(col: &str, vals: &[String], args: &mut Vec<SqlValue>) -> String {
    let marks: Vec<&str> = vals.iter().map(|_| "?").collect();
    args.extend(vals.iter().map(|v| SqlValue::Text(v.clone())));
    format!("{col} IN ({})", marks.join(", "))
}

fn is_path(s: &str) -> bool {
    s.contains('/') || s.contains('\\')
}

/// The FROM / WHERE part shared by the page query and its count; returns (sql, args, uses_fts).
pub fn build_where(q: &ItemQuery) -> (String, Vec<SqlValue>, bool) {
    let terms: Vec<&str> = q.query.as_deref().unwrap_or("").split_whitespace().collect();
    let fts: Vec<String> = terms.iter().filter(|t| t.chars().count() >= 3).map(|t| format!("\"{}\"", t.replace('"', "\"\""))).collect();
    let short: Vec<&str> = terms.iter().copied().filter(|t| t.chars().count() < 3).collect();
    let mut args: Vec<SqlValue> = Vec::new();
    let mut from = String::from("items i JOIN sessions s ON s.id = i.session_id");
    let mut wh: Vec<String> = Vec::new();
    if !fts.is_empty() {
        from.push_str(" JOIN items_fts f ON f.rowid = i.rowid");
        wh.push("items_fts MATCH ?".into());
        args.push(SqlValue::Text(fts.join(" AND ")));
    }
    if q.status.is_empty() {
        wh.push("i.status != 'deleted'".into());
    } else {
        wh.push(in_list("i.status", &q.status, &mut args));
    }
    if !q.kind.is_empty() {
        wh.push(in_list("i.kind", &q.kind, &mut args));
    }
    if !q.severity.is_empty() {
        wh.push(in_list("i.severity", &q.severity, &mut args));
    }
    if !q.fix_state.is_empty() {
        let named: Vec<String> = q.fix_state.iter().filter(|f| f.as_str() != "none").cloned().collect();
        let mut ors = Vec::new();
        if q.fix_state.iter().any(|f| f == "none") {
            ors.push("i.fix_state IS NULL".to_string());
        }
        if !named.is_empty() {
            ors.push(in_list("i.fix_state", &named, &mut args));
        }
        wh.push(format!("({})", ors.join(" OR ")));
    }
    if let Some(w) = q.workspace.as_deref().filter(|w| !w.is_empty()) {
        if is_path(w) {
            wh.push("s.workspace_id = (SELECT id FROM workspaces WHERE path = ?)".into());
        } else {
            wh.push("s.workspace_id = ?".into());
        }
        args.push(SqlValue::Text(w.into()));
    }
    if let Some(sess) = q.session.as_deref().filter(|s| !s.is_empty()) {
        wh.push(if is_path(sess) { "s.dir = ?" } else { "s.id = ?" }.into());
        args.push(SqlValue::Text(sess.into()));
    }
    if let Some(b) = q.has_code_refs {
        wh.push(format!("i.has_code_refs = {}", i32::from(b)));
    }
    for t in short {
        wh.push("(i.title LIKE ? ESCAPE '\\' OR i.quote LIKE ? ESCAPE '\\' OR i.body LIKE ? ESCAPE '\\')".into());
        let p = like_escape(t);
        for _ in 0..3 {
            args.push(SqlValue::Text(p.clone()));
        }
    }
    (format!("FROM {from} WHERE {}", wh.join(" AND ")), args, !fts.is_empty())
}

const ITEM_COLS: &str = "i.uid, i.session_id, s.dir AS session_dir, i.item_id, i.kind, i.title, i.status, i.fix_state, \
     i.severity, i.primary_frame, i.updated, s.workspace_id, s.created, s.title AS session_title, i.quote, i.tags, \
     i.owner, i.module, i.t_start, i.frame_count, i.has_code_refs, i.user_edited, i.exported";

impl Index {
    pub fn new(path: PathBuf) -> Self {
        Index { path }
    }

    pub fn exists(&self) -> bool {
        self.path.is_file()
    }

    fn conn(&self) -> Result<Connection, String> {
        open(&self.path).map_err(|e| format!("index.db: {e}"))
    }

    pub fn items(&self, q: &ItemQuery) -> Result<ItemPage, String> {
        if !self.exists() {
            return Ok(ItemPage { total: 0, items: vec![], missing: true });
        }
        let c = self.conn()?;
        let (wh, args, fts) = build_where(q);
        let order = match q.sort.as_deref() {
            Some("created") => "s.created DESC, i.t_start",
            Some("t_start") => "i.t_start, s.created DESC",
            _ => "i.updated DESC",
        };
        let snippet = if fts { "snippet(items_fts, -1, '[', ']', '…', 12)" } else { "NULL" };
        let limit = q.limit.unwrap_or(50).clamp(1, 5000);
        let offset = q.offset.unwrap_or(0).max(0);
        let sql = format!("SELECT {ITEM_COLS}, {snippet} AS snippet {wh} ORDER BY {order} LIMIT {limit} OFFSET {offset}");
        let mut st = c.prepare(&sql).map_err(|e| format!("{e}: {sql}"))?;
        let items = st
            .query_map(params_from_iter(args.iter()), row_json)
            .and_then(|r| r.collect::<Result<Vec<_>, _>>())
            .map_err(|e| e.to_string())?;
        let total: i64 = c
            .query_row(&format!("SELECT COUNT(*) {wh}"), params_from_iter(args.iter()), |r| r.get(0))
            .map_err(|e| e.to_string())?;
        Ok(ItemPage { total, items, missing: false })
    }

    pub fn item(&self, uid: &str) -> Result<Option<Value>, String> {
        if !self.exists() {
            return Ok(None);
        }
        let c = self.conn()?;
        let sql = format!("SELECT {ITEM_COLS}, NULL AS snippet FROM items i JOIN sessions s ON s.id = i.session_id WHERE i.uid = ?1");
        match c.query_row(&sql, [uid], row_json) {
            Ok(v) => Ok(Some(v)),
            Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
            Err(e) => Err(e.to_string()),
        }
    }

    pub fn sessions(&self, q: &SessionQuery) -> Result<Vec<Value>, String> {
        if !self.exists() {
            return Ok(vec![]);
        }
        let c = self.conn()?;
        let mut wh = vec!["1 = 1".to_string()];
        let mut args: Vec<SqlValue> = vec![];
        if let Some(w) = q.workspace.as_deref().filter(|w| !w.is_empty()) {
            wh.push(if is_path(w) { "s.workspace_id = (SELECT id FROM workspaces WHERE path = ?)" } else { "s.workspace_id = ?" }.into());
            args.push(SqlValue::Text(w.into()));
        }
        match q.state.as_deref() {
            Some("unprocessed") => wh.push("s.processed = 0".into()),
            Some("processing") => wh.push("s.processing = 1".into()),
            Some("unreviewed") => wh.push("s.processed = 1 AND s.processing = 0 AND s.reviewed = 0".into()),
            Some("reviewed") => wh.push("s.reviewed = 1".into()),
            Some("inbox") => wh.push("(s.processed = 0 OR s.processing = 1 OR s.reviewed = 0)".into()),
            _ => {}
        }
        let limit = q.limit.unwrap_or(200).clamp(1, 5000);
        let offset = q.offset.unwrap_or(0).max(0);
        let sql = format!(
            "SELECT s.*, w.name AS workspace_name, w.path AS workspace_path, \
             (SELECT COUNT(*) FROM items i WHERE i.session_id = s.id AND i.fix_state = 'fixed') AS fixed_count \
             FROM sessions s JOIN workspaces w ON w.id = s.workspace_id WHERE {} ORDER BY s.created DESC LIMIT {limit} OFFSET {offset}",
            wh.join(" AND ")
        );
        let mut st = c.prepare(&sql).map_err(|e| e.to_string())?;
        let rows = st
            .query_map(params_from_iter(args.iter()), row_json)
            .and_then(|r| r.collect::<Result<Vec<_>, _>>())
            .map_err(|e| e.to_string())?;
        Ok(rows)
    }

    pub fn workspaces(&self) -> Result<Vec<Value>, String> {
        if !self.exists() {
            return Ok(vec![]);
        }
        let c = self.conn()?;
        let sql = "SELECT w.*, \
            (SELECT COUNT(*) FROM sessions s WHERE s.workspace_id = w.id) AS sessions, \
            (SELECT COUNT(*) FROM items i JOIN sessions s ON s.id = i.session_id WHERE s.workspace_id = w.id \
               AND i.status != 'deleted' AND (i.fix_state IS NULL OR i.fix_state IN ('fixing', 'reopened'))) AS open_items \
            FROM workspaces w ORDER BY (w.kind = 'default') DESC, w.name COLLATE NOCASE";
        let mut st = c.prepare(sql).map_err(|e| e.to_string())?;
        let rows = st.query_map([], row_json).and_then(|r| r.collect::<Result<Vec<_>, _>>()).map_err(|e| e.to_string())?;
        Ok(rows)
    }

    /// Sidebar badges: all items, inbox sessions, items an agent is working on.
    pub fn summary(&self) -> Result<Value, String> {
        if !self.exists() {
            return Ok(json!({"missing": true, "items": 0, "inbox": 0, "fixing": 0, "sessions": 0}));
        }
        let c = self.conn()?;
        let n = |sql: &str| -> Result<i64, String> { c.query_row(sql, [], |r| r.get(0)).map_err(|e| e.to_string()) };
        Ok(json!({
            "missing": false,
            "items": n("SELECT COUNT(*) FROM items WHERE status != 'deleted'")?,
            "sessions": n("SELECT COUNT(*) FROM sessions")?,
            "inbox": n("SELECT COUNT(*) FROM sessions WHERE processed = 0 OR processing = 1 OR reviewed = 0")?,
            "fixing": n("SELECT COUNT(*) FROM items WHERE fix_state = 'fixing'")?,
        }))
    }

    /// Dirs to watch / allow in the asset scope: every workspace's sessions root.
    pub fn workspace_paths(&self) -> Vec<PathBuf> {
        self.workspaces()
            .unwrap_or_default()
            .iter()
            .filter_map(|w| w.get("path").and_then(Value::as_str).map(PathBuf::from))
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SCHEMA: &str = include_str!("../../../../docs/contracts/index-schema.sql");

    fn fixture() -> (tempfile::TempDir, Index) {
        let d = tempfile::tempdir().unwrap();
        let p = d.path().join("index.db");
        let c = Connection::open(&p).unwrap();
        c.execute_batch(SCHEMA).unwrap();
        c.execute_batch(
            "INSERT INTO workspaces VALUES ('w1', '/r/my-saas', 'my-saas', 'repo', 1);
             INSERT INTO workspaces VALUES ('w0', '/h/Blurt', 'Blurt', 'default', 1);
             INSERT INTO sessions (id, workspace_id, dir, mode, title, created, item_count, processed, reviewed, indexed_at)
               VALUES ('w1:s1', 'w1', '/r/my-saas/.blurt/sessions/s1', 'video', '登录页走查', 100, 3, 1, 0, 1);
             INSERT INTO sessions (id, workspace_id, dir, mode, title, created, item_count, processed, reviewed, indexed_at)
               VALUES ('w0:s2', 'w0', '/h/Blurt/recordings/s2', 'shots', 'shots', 200, 1, 1, 1, 1);
             INSERT INTO items (uid, session_id, item_id, kind, title, quote, body, status, fix_state, updated)
               VALUES ('u1', 'w1:s1', 'I-001', 'issue', '登录按钮点击无响应', '这个登录按钮点了没反应', '', 'draft', NULL, 10);
             INSERT INTO items (uid, session_id, item_id, kind, title, quote, body, status, fix_state, updated)
               VALUES ('u2', 'w1:s1', 'I-002', 'issue', '头像上传 500', '', 'POST /api/avatar 返回 500', 'confirmed', 'fixed', 30);
             INSERT INTO items (uid, session_id, item_id, kind, title, quote, body, status, fix_state, updated)
               VALUES ('u3', 'w1:s1', 'I-003', 'idea', '学 Linear 的空状态', '', '', 'deleted', NULL, 20);
             INSERT INTO items (uid, session_id, item_id, kind, title, quote, body, status, fix_state, updated)
               VALUES ('u4', 'w0:s2', 'I-001', 'note', '50% 的 under_score', '', '', 'draft', 'fixing', 40);",
        )
        .unwrap();
        drop(c);
        (d, Index::new(p))
    }

    fn uids(p: &ItemPage) -> Vec<String> {
        p.items.iter().map(|v| v["uid"].as_str().unwrap().to_string()).collect()
    }

    #[test]
    fn filters_and_defaults() {
        let (_d, ix) = fixture();
        let all = ix.items(&ItemQuery::default()).unwrap();
        assert_eq!(all.total, 3); // deleted hidden
        assert_eq!(uids(&all), ["u4", "u2", "u1"]); // updated DESC
        assert_eq!(all.items[0]["session_dir"], "/h/Blurt/recordings/s2");
        let q = ItemQuery { status: vec!["deleted".into()], ..Default::default() };
        assert_eq!(uids(&ix.items(&q).unwrap()), ["u3"]);
        let q = ItemQuery { fix_state: vec!["none".into()], ..Default::default() };
        assert_eq!(uids(&ix.items(&q).unwrap()), ["u1"]);
        let q = ItemQuery { fix_state: vec!["none".into(), "fixed".into()], kind: vec!["issue".into()], ..Default::default() };
        assert_eq!(uids(&ix.items(&q).unwrap()), ["u2", "u1"]);
        let q = ItemQuery { workspace: Some("/h/Blurt".into()), ..Default::default() };
        assert_eq!(uids(&ix.items(&q).unwrap()), ["u4"]);
        let q = ItemQuery { session: Some("w1:s1".into()), limit: Some(1), offset: Some(1), ..Default::default() };
        let p = ix.items(&q).unwrap();
        assert_eq!((p.total, uids(&p)), (2, vec!["u1".to_string()]));
    }

    #[test]
    fn trigram_and_like_fallback() {
        let (_d, ix) = fixture();
        let q = |s: &str| ItemQuery { query: Some(s.into()), ..Default::default() };
        let p = ix.items(&q("登录按")).unwrap();
        assert_eq!(uids(&p), ["u1"]);
        assert!(p.items[0]["snippet"].as_str().unwrap().contains("[登录按]"));
        assert_eq!(uids(&ix.items(&q("登录")).unwrap()), ["u1"]); // 2 chars: LIKE
        assert_eq!(uids(&ix.items(&q("avatar")).unwrap()), ["u2"]); // body
        assert_eq!(uids(&ix.items(&q("登录 按钮")).unwrap()), ["u1"]); // AND of two short terms
        assert_eq!(uids(&ix.items(&q("登录按 avatar")).unwrap()), Vec::<String>::new());
        assert_eq!(uids(&ix.items(&q("%")).unwrap()), ["u4"]); // escaped
        assert_eq!(uids(&ix.items(&q("_")).unwrap()), ["u4"]);
        assert_eq!(uids(&ix.items(&q("\"quoted")).unwrap()), Vec::<String>::new()); // no FTS syntax error
    }

    #[test]
    fn sessions_workspaces_summary() {
        let (_d, ix) = fixture();
        let ws = ix.workspaces().unwrap();
        assert_eq!(ws[0]["kind"], "default");
        assert_eq!(ws[1]["open_items"], 1); // u1 open, u2 fixed, u3 deleted
        let inbox = ix.sessions(&SessionQuery { state: Some("inbox".into()), ..Default::default() }).unwrap();
        assert_eq!(inbox.len(), 1);
        assert_eq!(inbox[0]["workspace_name"], "my-saas");
        let s = ix.summary().unwrap();
        assert_eq!((s["items"].as_i64(), s["inbox"].as_i64(), s["fixing"].as_i64()), (Some(3), Some(1), Some(1)));
        assert_eq!(ix.item("u2").unwrap().unwrap()["item_id"], "I-002");
        assert!(ix.item("nope").unwrap().is_none());
    }

    #[test]
    fn missing_db_is_not_an_error() {
        let ix = Index::new(PathBuf::from("/nonexistent/index.db"));
        assert!(ix.items(&ItemQuery::default()).unwrap().missing);
        assert!(ix.sessions(&SessionQuery::default()).unwrap().is_empty());
    }
}
