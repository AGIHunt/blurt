//! Read-only access to `$BLURT_HOME/index.db`, schema v3 (contract K1; v3 = K3's one `state` column instead of
//! `status` + `work_state`). index.py is the only
//! writer; we open with `SQLITE_OPEN_READ_ONLY` per query (cheap, and a rebuilt file is picked up at once). A db of
//! another schema version reads as missing: the startup scan rebuilds it.
//!
//! Search follows C3 so every host returns the same rows: the query is split on whitespace, every term must match;
//! a term of ≥ 3 characters goes to FTS5 (trigram) as a quoted phrase, a shorter one becomes
//! `(title LIKE OR quote LIKE OR body LIKE)`. The state defaults to "everything but discarded".

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use rusqlite::{params_from_iter, types::Value as SqlValue, Connection, OpenFlags, Row};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

pub const SCHEMA: &str = "3";

/// K3 (tests/fixtures/lifecycle.json): the eight states and the groups every count uses.
pub const STATES: [&str; 8] = ["new", "todo", "handed_off", "in_progress", "to_verify", "done", "wontfix", "discarded"];
/// "Needs you": the inbox, the badges, the island
pub const INBOX: [&str; 2] = ["new", "to_verify"];
pub const OPEN: [&str; 4] = ["new", "todo", "handed_off", "in_progress"];

/// The pre-v0.7 filters as states: status draft → new, confirmed → kept (to do … won't do), deleted → discarded;
/// work todo → new + to do, the other work states as they are.
fn compat_states(key: &str, v: &str) -> Vec<&'static str> {
    match (key, v) {
        ("status", "draft") => vec!["new"],
        ("status", "confirmed") => vec!["todo", "handed_off", "in_progress", "to_verify", "done", "wontfix"],
        ("status", "deleted") => vec!["discarded"],
        ("work", "todo") => vec!["new", "todo"],
        ("work", w) => STATES.iter().copied().filter(|s| *s == w && *s != "new" && *s != "discarded").collect(),
        _ => vec![],
    }
}

fn sql_set(states: &[&str]) -> String {
    states.iter().map(|s| format!("'{s}'")).collect::<Vec<_>>().join(", ")
}

#[derive(Debug, Default, Deserialize, Clone)]
#[serde(default)]
pub struct ItemQuery {
    pub query: Option<String>,
    pub kind: Vec<String>,
    /// K3: new | todo | handed_off | in_progress | to_verify | done | wontfix | discarded (none = all but discarded)
    pub state: Vec<String>,
    /// pre-v0.7 names, mapped to states (`compat_states`); several filters narrow each other
    pub status: Vec<String>,
    pub work: Vec<String>,
    pub severity: Vec<String>,
    /// project id, its path, or "inbox"
    pub project: Option<String>,
    /// session id, or its dir
    pub session: Option<String>,
    pub source_type: Vec<String>,
    pub has_code_refs: Option<bool>,
    /// "updated" (default) | "created" | "t_start" | "title"
    pub sort: Option<String>,
    pub limit: Option<i64>,
    pub offset: Option<i64>,
}

#[derive(Debug, Default, Deserialize, Clone)]
#[serde(default)]
pub struct SessionQuery {
    pub project: Option<String>,
    /// "to_review" (sorted, not reviewed) | "processing" | "unprocessed" | "reviewed"
    pub state: Option<String>,
    pub limit: Option<i64>,
}

#[derive(Debug, Serialize)]
pub struct ItemPage {
    pub total: i64,
    pub items: Vec<Value>,
    /// true when index.db doesn't exist (yet) or is another schema (the UI says "building the index…")
    pub missing: bool,
}

pub struct Index {
    pub path: PathBuf,
}

fn open(path: &Path) -> rusqlite::Result<Connection> {
    let c = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX | OpenFlags::SQLITE_OPEN_URI)?;
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
    let mut from = String::from("items i JOIN projects p ON p.id = i.project_id LEFT JOIN sessions s ON s.id = i.session_id");
    let mut wh: Vec<String> = Vec::new();
    if !fts.is_empty() {
        from.push_str(" JOIN items_fts f ON f.rowid = i.rowid");
        wh.push("items_fts MATCH ?".into());
        args.push(SqlValue::Text(fts.join(" AND ")));
    }
    // the explicit states, narrowed by the old status / work filters when those are given
    let mut want: Option<Vec<String>> = (!q.state.is_empty()).then(|| q.state.clone());
    for (key, vals) in [("status", &q.status), ("work", &q.work)] {
        if vals.is_empty() {
            continue;
        }
        let these: Vec<String> = vals.iter().flat_map(|v| compat_states(key, v)).map(String::from).collect();
        want = Some(match want {
            Some(w) => w.into_iter().filter(|s| these.contains(s)).collect(),
            None => these,
        });
    }
    match want {
        None => wh.push("i.state != 'discarded'".into()),
        Some(w) if w.is_empty() => wh.push("0".into()),
        Some(w) => wh.push(in_list("i.state", &w, &mut args)),
    }
    if !q.kind.is_empty() {
        wh.push(in_list("i.kind", &q.kind, &mut args));
    }
    if !q.severity.is_empty() {
        wh.push(in_list("i.severity", &q.severity, &mut args));
    }
    if !q.source_type.is_empty() {
        wh.push(in_list("i.source_type", &q.source_type, &mut args));
    }
    if let Some(pr) = q.project.as_deref().filter(|w| !w.is_empty()) {
        wh.push(if is_path(pr) { "p.path = ?" } else { "i.project_id = ?" }.into());
        args.push(SqlValue::Text(pr.into()));
    }
    if let Some(sess) = q.session.as_deref().filter(|s| !s.is_empty()) {
        wh.push(if is_path(sess) { "s.dir = ?" } else { "i.session_id = ?" }.into());
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

/// ItemRow v3 (K1) plus what the list shows besides (quote, frames, the project's routing).
const ITEM_COLS: &str = "i.uid, i.project_id, p.name AS project_name, p.key AS project_key, i.session_id, s.dir AS session_dir, \
     i.path, i.item_id, i.kind, i.title, i.state, i.work_to, i.work_agent, i.severity, i.primary_frame, \
     i.created, i.updated, i.suggested_project, i.suggested_confidence, i.project_by, i.quote, i.t_start, i.frame_count, \
     i.source_type, i.has_code_refs, i.parse_error";

impl Index {
    pub fn new(path: PathBuf) -> Self {
        Index { path }
    }

    /// The file exists and is schema v3.
    pub fn ready(&self) -> bool {
        self.path.is_file()
            && open(&self.path)
                .and_then(|c| c.query_row("SELECT value FROM meta WHERE key = 'schema_version'", [], |r| r.get::<_, String>(0)))
                .is_ok_and(|v| v == SCHEMA)
    }

    fn conn(&self) -> Result<Connection, String> {
        open(&self.path).map_err(|e| format!("index.db: {e}"))
    }

    fn rows(&self, sql: &str, args: &[SqlValue]) -> Result<Vec<Value>, String> {
        let c = self.conn()?;
        let mut st = c.prepare(sql).map_err(|e| format!("{e}: {sql}"))?;
        let rows = st.query_map(params_from_iter(args.iter()), row_json).and_then(|r| r.collect::<Result<Vec<_>, _>>()).map_err(|e| e.to_string());
        rows
    }

    pub fn items(&self, q: &ItemQuery) -> Result<ItemPage, String> {
        if !self.ready() {
            return Ok(ItemPage { total: 0, items: vec![], missing: true });
        }
        let (wh, args, fts) = build_where(q);
        let order = match q.sort.as_deref() {
            Some("created") => "i.created DESC",
            Some("t_start") => "s.created DESC, i.t_start",
            Some("title") => "i.title COLLATE NOCASE",
            _ => "i.updated DESC",
        };
        let snippet = if fts { "snippet(items_fts, -1, '[', ']', '…', 12)" } else { "NULL" };
        let limit = q.limit.unwrap_or(50).clamp(1, 5000);
        let offset = q.offset.unwrap_or(0).max(0);
        let items = self.rows(&format!("SELECT {ITEM_COLS}, {snippet} AS snippet {wh} ORDER BY {order} LIMIT {limit} OFFSET {offset}"), &args)?;
        let total: i64 = self
            .conn()?
            .query_row(&format!("SELECT COUNT(*) {wh}"), params_from_iter(args.iter()), |r| r.get(0))
            .map_err(|e| e.to_string())?;
        Ok(ItemPage { total, items, missing: false })
    }

    pub fn item(&self, uid: &str) -> Result<Option<Value>, String> {
        if !self.ready() {
            return Ok(None);
        }
        let sql = format!(
            "SELECT {ITEM_COLS}, NULL AS snippet FROM items i JOIN projects p ON p.id = i.project_id \
             LEFT JOIN sessions s ON s.id = i.session_id WHERE i.uid = ?1"
        );
        Ok(self.rows(&sql, &[SqlValue::Text(uid.into())])?.into_iter().next())
    }

    /// Capture sessions ("batches") with their project and how many of their items are still new.
    pub fn sessions(&self, q: &SessionQuery) -> Result<Vec<Value>, String> {
        if !self.ready() {
            return Ok(vec![]);
        }
        let mut wh = vec!["s.legacy = 0".to_string()];
        let mut args: Vec<SqlValue> = vec![];
        if let Some(pr) = q.project.as_deref().filter(|w| !w.is_empty()) {
            wh.push(if is_path(pr) { "p.path = ?" } else { "s.project_id = ?" }.into());
            args.push(SqlValue::Text(pr.into()));
        }
        match q.state.as_deref() {
            Some("to_review") => wh.push("s.processed = 1 AND s.processing = 0 AND s.reviewed = 0 AND s.item_count > 0".into()),
            Some("processing") => wh.push("s.processing = 1".into()),
            Some("unprocessed") => wh.push("s.processed = 0 AND s.processing = 0".into()),
            Some("reviewed") => wh.push("s.reviewed = 1".into()),
            _ => {}
        }
        let limit = q.limit.unwrap_or(200).clamp(1, 5000);
        let sql = format!(
            "SELECT s.*, p.name AS project_name, p.key AS project_key, p.path AS project_path, \
             (SELECT COUNT(*) FROM items i WHERE i.session_id = s.id AND i.state = 'new') AS new_count \
             FROM sessions s JOIN projects p ON p.id = s.project_id WHERE {} ORDER BY s.created DESC LIMIT {limit}",
            wh.join(" AND ")
        );
        self.rows(&sql, &args)
    }

    /// project id → {items, open_items, inbox, new, to_verify} over items that aren't discarded (K3 groups).
    pub fn project_counts(&self) -> Result<HashMap<String, Value>, String> {
        if !self.ready() {
            return Ok(HashMap::new());
        }
        let rows = self.rows(
            &format!(
                "SELECT project_id AS id, COUNT(*) AS items, SUM(state IN ({open})) AS open_items, \
                   SUM(state IN ({inbox})) AS inbox, SUM(state = 'new') AS new, SUM(state = 'to_verify') AS to_verify \
                 FROM items WHERE state != 'discarded' GROUP BY project_id",
                open = sql_set(&OPEN),
                inbox = sql_set(&INBOX)
            ),
            &[],
        )?;
        Ok(rows.into_iter().filter_map(|r| Some((r.get("id")?.as_str()?.to_string(), r))).collect())
    }

    /// Sidebar / island / tray badges. `inbox` = "needs you" (new + to verify, K3); `active` = with an agent.
    pub fn summary(&self) -> Result<Value, String> {
        if !self.ready() {
            return Ok(json!({"missing": true, "items": 0, "inbox": 0, "new": 0, "to_verify": 0, "active": 0, "open": 0, "unassigned": 0, "batches": 0}));
        }
        let c = self.conn()?;
        let n = |sql: &str| -> Result<i64, String> { c.query_row(sql, [], |r| r.get(0)).map_err(|e| e.to_string()) };
        let live = "FROM items WHERE state != 'discarded'";
        Ok(json!({
            "missing": false,
            "items": n(&format!("SELECT COUNT(*) {live}"))?,
            "inbox": n(&format!("SELECT COUNT(*) {live} AND state IN ({})", sql_set(&INBOX)))?,
            "new": n(&format!("SELECT COUNT(*) {live} AND state = 'new'"))?,
            "to_verify": n(&format!("SELECT COUNT(*) {live} AND state = 'to_verify'"))?,
            "active": n(&format!("SELECT COUNT(*) {live} AND state IN ('handed_off', 'in_progress')"))?,
            "open": n(&format!("SELECT COUNT(*) {live} AND state IN ({})", sql_set(&OPEN)))?,
            "unassigned": n(&format!("SELECT COUNT(*) {live} AND project_id = 'inbox'"))?,
            "batches": n("SELECT COUNT(*) FROM sessions WHERE legacy = 0 AND processed = 1 AND processing = 0 AND reviewed = 0 AND item_count > 0")?,
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SCHEMA_SQL: &str = include_str!("../tests/index-v3.sql");

    fn fixture() -> (tempfile::TempDir, Index) {
        let d = tempfile::tempdir().unwrap();
        let p = d.path().join("index.db");
        let c = Connection::open(&p).unwrap();
        c.execute_batch(SCHEMA_SQL).unwrap();
        c.execute_batch(
            "INSERT INTO projects VALUES ('p1', '/r/my-saas', '/r/my-saas/.blurt', 'my-saas', 'MS', 'my-saas', 'repo', 1, 1);
             INSERT INTO projects VALUES ('inbox', '/h/Blurt/inbox', '/h/Blurt/inbox', 'Unassigned', 'IN', 'inbox', 'inbox', 1, 1);
             INSERT INTO sessions (id, project_id, dir, mode, title, created, item_count, processed, reviewed, indexed_at)
               VALUES ('p1:s1', 'p1', '/r/my-saas/.blurt/sessions/s1', 'video', '登录页走查', 100, 3, 1, 0, 1);
             INSERT INTO sessions (id, project_id, dir, mode, title, created, item_count, processed, reviewed, indexed_at)
               VALUES ('inbox:s2', 'inbox', '/h/Blurt/inbox/sessions/s2-shots', 'shots', 'shots', 200, 1, 1, 1, 1);
             INSERT INTO items (uid, project_id, session_id, path, item_id, kind, title, quote, body, state, created, updated)
               VALUES ('u1', 'p1', 'p1:s1', '/r/my-saas/.blurt/items/MS-1.md', 'MS-1', 'issue', '登录按钮点击无响应', '这个登录按钮点了没反应', '', 'new', 1, 10);
             INSERT INTO items (uid, project_id, session_id, path, item_id, kind, title, quote, body, state, work_agent, created, updated)
               VALUES ('u2', 'p1', 'p1:s1', '/r/my-saas/.blurt/items/MS-2.md', 'MS-2', 'issue', '头像上传 500', '', 'POST /api/avatar 返回 500', 'to_verify', 'claude', 2, 30);
             INSERT INTO items (uid, project_id, session_id, path, item_id, kind, title, quote, body, state, created, updated)
               VALUES ('u3', 'p1', 'p1:s1', '/r/my-saas/.blurt/items/MS-3.md', 'MS-3', 'idea', '学 Linear 的空状态', '', '', 'discarded', 3, 20);
             INSERT INTO items (uid, project_id, session_id, path, item_id, kind, title, quote, body, state, created, updated)
               VALUES ('u4', 'inbox', 'inbox:s2', '/h/Blurt/inbox/items/IN-1.md', 'IN-1', 'note', '50% 的 under_score', '', '', 'in_progress', 4, 40);
             INSERT INTO items (uid, project_id, session_id, path, item_id, kind, title, quote, body, state, created, updated)
               VALUES ('u5', 'p1', NULL, '/r/my-saas/.blurt/items/MS-4.md', 'MS-4', 'task', '不做了的', '', '', 'wontfix', 5, 5);",
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
        assert_eq!(all.total, 4); // discarded hidden
        assert_eq!(uids(&all), ["u4", "u2", "u1", "u5"]); // updated DESC
        assert_eq!(all.items[1]["state"], "to_verify");
        assert!(all.items[1].get("status").is_none() && all.items[1].get("work_state").is_none());
        assert_eq!(all.items[0]["project_key"], "IN");
        assert_eq!(all.items[0]["session_dir"], "/h/Blurt/inbox/sessions/s2-shots");
        let st = |v: &[&str]| ItemQuery { state: v.iter().map(|s| s.to_string()).collect(), ..Default::default() };
        assert_eq!(uids(&ix.items(&st(&["discarded"])).unwrap()), ["u3"]);
        assert_eq!(uids(&ix.items(&st(&["new", "to_verify"])).unwrap()), ["u2", "u1"]); // needs you
        // the old filters, as states
        let q = ItemQuery { status: vec!["deleted".into()], ..Default::default() };
        assert_eq!(uids(&ix.items(&q).unwrap()), ["u3"]);
        let q = ItemQuery { status: vec!["confirmed".into()], ..Default::default() };
        assert_eq!(uids(&ix.items(&q).unwrap()), ["u4", "u2", "u5"]);
        let q = ItemQuery { work: vec!["todo".into(), "to_verify".into()], kind: vec!["issue".into()], ..Default::default() };
        assert_eq!(uids(&ix.items(&q).unwrap()), ["u2", "u1"]);
        let q = ItemQuery { status: vec!["draft".into()], work: vec!["to_verify".into()], ..Default::default() };
        assert_eq!(ix.items(&q).unwrap().total, 0); // they narrow each other
        let q = ItemQuery { project: Some("inbox".into()), ..Default::default() };
        assert_eq!(uids(&ix.items(&q).unwrap()), ["u4"]);
        let q = ItemQuery { project: Some("/r/my-saas".into()), sort: Some("created".into()), ..Default::default() };
        assert_eq!(uids(&ix.items(&q).unwrap()), ["u5", "u2", "u1"]);
        let q = ItemQuery { session: Some("p1:s1".into()), limit: Some(1), offset: Some(1), ..Default::default() };
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
        assert_eq!(uids(&ix.items(&q("登录 按钮")).unwrap()), ["u1"]);
        assert_eq!(uids(&ix.items(&q("%")).unwrap()), ["u4"]); // escaped
        assert_eq!(uids(&ix.items(&q("\"quoted")).unwrap()), Vec::<String>::new()); // no FTS syntax error
    }

    #[test]
    fn sessions_counts_summary() {
        let (_d, ix) = fixture();
        let s = ix.sessions(&SessionQuery { state: Some("to_review".into()), ..Default::default() }).unwrap();
        assert_eq!(s.len(), 1);
        assert_eq!((s[0]["project_name"].as_str(), s[0]["new_count"].as_i64()), (Some("my-saas"), Some(1)));
        let c = ix.project_counts().unwrap();
        let p1 = &c["p1"];
        assert_eq!([&p1["items"], &p1["open_items"], &p1["inbox"], &p1["new"], &p1["to_verify"]].map(|v| v.as_i64().unwrap()), [3, 1, 2, 1, 1]);
        let sm = ix.summary().unwrap();
        let k = |key: &str| sm[key].as_i64().unwrap();
        assert_eq!(["items", "inbox", "new", "to_verify", "active", "open", "unassigned", "batches"].map(k), [4, 2, 1, 1, 1, 2, 1, 1]);
        assert_eq!(ix.item("u2").unwrap().unwrap()["work_agent"], "claude");
        assert!(ix.item("nope").unwrap().is_none());
    }

    #[test]
    fn missing_or_old_db_reads_as_missing() {
        let ix = Index::new(PathBuf::from("/nonexistent/index.db"));
        assert!(ix.items(&ItemQuery::default()).unwrap().missing);
        let d = tempfile::tempdir().unwrap();
        let p = d.path().join("index.db");
        Connection::open(&p).unwrap().execute_batch("CREATE TABLE meta (key TEXT, value TEXT); INSERT INTO meta VALUES ('schema_version', '1');").unwrap();
        assert!(Index::new(p).items(&ItemQuery::default()).unwrap().missing);
    }
}
