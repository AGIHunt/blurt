//! Projects = folders the user opened (contract K2). `$BLURT_HOME/projects.json` is read here directly (and watched);
//! every change goes through `projects.py` (`add` / `use` / `set`), its only writer.
//!
//! Captures go to the current project's store, or to the inbox store when the current project is `auto` (K2
//! "捕获时的归属"). Snaps and voice notes share one open shots batch per store (K7 "捕获的落盘").

use std::path::{Path, PathBuf};
use std::time::Duration;

use serde_json::{json, Value};

use crate::index::Index;
use crate::scripts::{self, Runner};
use crate::{l10n, paths, settings};

#[derive(Debug, Clone, Default)]
pub struct Registry {
    /// None = auto
    pub current: Option<String>,
    pub projects: Vec<Value>,
}

impl Registry {
    pub fn load() -> Self {
        Self::parse(&settings::read_json(&paths::projects_file()).unwrap_or_else(|| json!({})))
    }

    pub fn parse(v: &Value) -> Self {
        let current = v.get("current").and_then(Value::as_str).filter(|c| !c.is_empty() && *c != "auto").map(str::to_owned);
        let mut projects: Vec<Value> = v.get("projects").and_then(Value::as_array).cloned().unwrap_or_default();
        // pinned first, then the most recently used (ISO strings sort by time when they share a zone)
        projects.sort_by(|a, b| {
            let pin = |p: &Value| p.get("pinned").and_then(Value::as_bool).unwrap_or(false);
            let used = |p: &Value| p.get("last_used").and_then(Value::as_str).unwrap_or("").to_string();
            pin(b).cmp(&pin(a)).then(used(b).cmp(&used(a)))
        });
        Registry { current, projects }
    }

    pub fn project(&self, id: &str) -> Option<&Value> {
        self.projects.iter().find(|p| p.get("id").and_then(Value::as_str) == Some(id))
    }

    pub fn current_project(&self) -> Option<&Value> {
        self.current.as_deref().and_then(|id| self.project(id))
    }

    /// The store captures go to now: the current project's, or the inbox store.
    pub fn capture_store(&self) -> (Option<String>, PathBuf) {
        match self.current_project().and_then(|p| Some((p.get("id")?.as_str()?.to_string(), path_of(p)?))) {
            Some((id, path)) if path.is_dir() => (Some(id), paths::store_of(&path)),
            _ => (None, paths::inbox_store()),
        }
    }

    pub fn store_for(&self, id: &str) -> Option<PathBuf> {
        if id == "inbox" {
            return Some(paths::inbox_store());
        }
        self.project(id).and_then(path_of).map(|p| paths::store_of(&p))
    }

    /// Every store to watch and to let the asset protocol serve: the projects' and the inbox.
    pub fn stores(&self) -> Vec<PathBuf> {
        let mut v: Vec<PathBuf> = self.projects.iter().filter_map(path_of).map(|p| paths::store_of(&p)).collect();
        v.push(paths::inbox_store());
        v
    }

    /// Which project a store or session path belongs to (`inbox` for the inbox store).
    pub fn project_of_path(&self, p: &Path) -> Option<String> {
        if p.starts_with(paths::inbox_store()) {
            return Some("inbox".into());
        }
        self.projects
            .iter()
            .filter_map(|x| Some((x.get("id")?.as_str()?.to_string(), paths::store_of(&path_of(x)?))))
            .filter(|(_, s)| p.starts_with(s))
            .max_by_key(|(_, s)| s.components().count())
            .map(|(id, _)| id)
    }
}

fn path_of(p: &Value) -> Option<PathBuf> {
    p.get("path").and_then(Value::as_str).map(PathBuf::from)
}

/// The inbox pseudo-project (K2: not in the registry, fixed id / key, localised name).
pub fn inbox_row() -> Value {
    json!({"id": "inbox", "key": "IN", "slug": "inbox", "kind": "inbox",
           "name": if l10n::lang() == "zh-Hans" { "未归类" } else { "Unassigned" },
           "path": scripts::s(&paths::inbox_store()), "store": scripts::s(&paths::inbox_store()), "exists": true})
}

/// `projects_list` → {current: "auto" | id, projects: [Row], inbox: Row}; Row = the registry entry + {exists, store,
/// items, open_items, inbox, new, to_verify} (K3 counts from index.db v3; zero while the index is being built).
pub fn list(index: &Index) -> Value {
    let reg = Registry::load();
    let counts = index.project_counts().unwrap_or_default();
    let with_counts = |mut row: Value| {
        let id = row.get("id").and_then(Value::as_str).unwrap_or("").to_string();
        let c = counts.get(&id).cloned().unwrap_or_else(|| json!({}));
        for k in ["items", "open_items", "inbox", "new", "to_verify"] {
            row[k] = c.get(k).cloned().unwrap_or(json!(0));
        }
        row
    };
    let projects: Vec<Value> = reg
        .projects
        .iter()
        .map(|p| {
            let mut row = p.clone();
            let path = path_of(p).unwrap_or_default();
            row["exists"] = json!(path.is_dir());
            row["store"] = json!(scripts::s(&paths::store_of(&path)));
            row["kind"] = json!(if path.join(".git").exists() { "repo" } else { "folder" });
            with_counts(row)
        })
        .collect();
    json!({"current": reg.current.clone().unwrap_or_else(|| "auto".into()), "projects": projects, "inbox": with_counts(inbox_row())})
}

pub fn add(runner: &Runner, path: &str) -> Result<Value, String> {
    runner.run("projects.py", &["add".into(), path.into()], None, Duration::from_secs(30)).map_err(String::from)
}

pub fn use_project(runner: &Runner, id: &str) -> Result<Value, String> {
    runner.run("projects.py", &["use".into(), id.into()], None, Duration::from_secs(20)).map_err(String::from)
}

pub fn set(runner: &Runner, id: &str, patch: &Value) -> Result<Value, String> {
    runner.run("projects.py", &["set".into(), id.into(), "--json".into(), patch.to_string()], None, Duration::from_secs(20)).map_err(String::from)
}

/// `YYYYMMDD-HHMMSS`, local time (the session dir names every host uses).
pub fn timestamp() -> String {
    chrono::Local::now().format("%Y%m%d-%H%M%S").to_string()
}

/// ISO 8601 with the local offset (contract: every time on disk).
pub fn iso_now() -> String {
    chrono::Local::now().format("%Y-%m-%dT%H:%M:%S%:z").to_string()
}

/// A new recording session in the capture store: `<store>/sessions/<ts>`.
pub fn new_video_session(reg: &Registry) -> (Option<String>, PathBuf) {
    let (project, store) = reg.capture_store();
    (project, unique(store.join("sessions").join(timestamp())))
}

fn unique(p: PathBuf) -> PathBuf {
    if !p.exists() {
        return p;
    }
    (2..).map(|n| PathBuf::from(format!("{}-{n}", p.display()))).find(|c| !c.exists()).unwrap_or(p)
}

/// The open shots batch of the capture store (the newest `<ts>-shots` session nobody has processed yet), or a new one.
pub fn shots_session(reg: &Registry) -> (Option<String>, PathBuf) {
    let (project, store) = reg.capture_store();
    let dir = store.join("sessions");
    let open = std::fs::read_dir(&dir)
        .ok()
        .into_iter()
        .flatten()
        .filter_map(Result::ok)
        .map(|e| e.path())
        .filter(|p| p.file_name().is_some_and(|n| n.to_string_lossy().ends_with("-shots")) && is_open_batch(p))
        .max();
    (project, open.unwrap_or_else(|| unique(dir.join(format!("{}-shots", timestamp())))))
}

/// A shots session still collecting: no agent has written its items yet.
pub fn is_open_batch(p: &Path) -> bool {
    p.is_dir() && !["batch.json", "items.json", "items.ingested.json", "items.v2.json"].iter().any(|f| p.join(f).exists())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn registry_order_and_lookup() {
        let v = json!({"current": "b", "projects": [
            {"id": "a", "path": "/x/a", "last_used": "2026-10-20T10:00:00+08:00"},
            {"id": "b", "path": "/x/b", "last_used": "2026-10-22T10:00:00+08:00"},
            {"id": "c", "path": "/x/c", "pinned": true}]});
        let r = Registry::parse(&v);
        let ids: Vec<&str> = r.projects.iter().map(|p| p["id"].as_str().unwrap()).collect();
        assert_eq!(ids, ["c", "b", "a"]);
        assert_eq!(r.current.as_deref(), Some("b"));
        assert_eq!(r.store_for("a"), Some(PathBuf::from("/x/a/.blurt")));
        assert_eq!(r.project_of_path(Path::new("/x/a/.blurt/sessions/s1")).as_deref(), Some("a"));
        assert_eq!(Registry::parse(&json!({"current": "auto"})).current, None);
    }

    #[test]
    fn open_batches() {
        let d = tempfile::tempdir().unwrap();
        let s = d.path().join("20261022-101500-shots");
        std::fs::create_dir_all(&s).unwrap();
        assert!(is_open_batch(&s));
        std::fs::write(s.join("batch.json"), "{}").unwrap();
        assert!(!is_open_batch(&s));
        assert!(iso_now().len() >= 25, "{}", iso_now());
        assert_eq!(timestamp().len(), 15);
    }
}
