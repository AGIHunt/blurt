//! What Alt+Shift+C and Alt+Shift+T read (the Mac's BlurtCore ScreenTextHistory, 2026-11-16; docs/design/screen-text.md
//! §1g): one line per result in ~/.blurt/screen-text/history.jsonl — when, read or translated, the text that went on
//! the clipboard, the original for a translation, the language asked for, the app in front, what became of it (pasted
//! / unconfirmed / copied). Newest first on the main window's Text & Translation page and in Home's timeline. Kept for
//! record.screen_text.history_days: 7, 30 (the default, omitted), -1 forever, 0 not at all (Settings → Text &
//! Translation → History). No picture is kept, only text.
//!
//! The file is the Mac's, line for line (sorted keys, `t` ISO 8601 UTC with milliseconds, "/" escaped as
//! JSONSerialization does): {"app","bundle","id","outcome","source","t","target","text","translated"}; a deletion is
//! {"op":"delete","ids":[…]}, a better reading of the same picture {"op":"text","id","text"}.

use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use chrono::{DateTime, SecondsFormat, Utc};
use serde_json::{json, Map, Value};
use tauri::{AppHandle, Emitter};

pub const DEFAULT_DAYS: i64 = 30;
/// The main window's pages reload on it (the page, Home's timeline, Settings' count).
pub const CHANGED: &str = "screen-text://changed";

#[derive(Clone, Debug, PartialEq)]
pub struct Entry {
    pub id: String,
    pub time: DateTime<Utc>,
    /// Alt+Shift+T's: `text` is the translation, `source` what was on the screen
    pub translated: bool,
    pub text: String,
    pub source: Option<String>,
    /// the language asked for ("zh", "en", "auto:zh|en"); translations only
    pub target: Option<String>,
    /// the app in front, by the name Windows / the desktop shows
    pub app: Option<String>,
    /// the Mac's bundle id; here the executable ("WINWORD.EXE"), so an entry names its app the same way across runs
    pub bundle: Option<String>,
    /// pasted | unconfirmed | copied (paste_policy::screen_text::Outcome::as_str)
    pub outcome: Option<String>,
}

impl Entry {
    pub fn new(translated: bool, text: &str) -> Entry {
        Entry {
            id: new_id(),
            time: Utc::now(),
            translated,
            text: text.to_string(),
            source: None,
            target: None,
            app: None,
            bundle: None,
            outcome: None,
        }
    }

    pub fn json(&self) -> Value {
        let mut o = Map::new();
        o.insert("id".into(), json!(self.id));
        o.insert("t".into(), json!(iso(&self.time)));
        o.insert("translated".into(), json!(self.translated));
        o.insert("text".into(), json!(self.text));
        for (k, v) in [("source", &self.source), ("target", &self.target), ("app", &self.app), ("bundle", &self.bundle), ("outcome", &self.outcome)] {
            if let Some(s) = v {
                o.insert(k.into(), json!(s));
            }
        }
        Value::Object(o)
    }

    pub fn from_json(o: &Value) -> Option<Entry> {
        let s = |k: &str| o[k].as_str().map(str::to_string);
        Some(Entry {
            id: s("id")?,
            time: DateTime::parse_from_rfc3339(o["t"].as_str()?).ok()?.with_timezone(&Utc),
            translated: o["translated"].as_bool().unwrap_or(false),
            text: s("text")?,
            source: s("source"),
            target: s("target"),
            app: s("app"),
            bundle: s("bundle"),
            outcome: s("outcome"),
        })
    }

    /// What the main window gets: `time` in epoch seconds.
    pub fn for_page(&self) -> Value {
        json!({"id": self.id, "time": self.time.timestamp_millis() as f64 / 1000.0, "translated": self.translated,
               "text": self.text, "source": self.source, "target": self.target, "app": self.app, "outcome": self.outcome})
    }
}

/// ISO 8601 in UTC with milliseconds (the Mac's ISO8601DateFormatter with .withFractionalSeconds reads only that).
fn iso(t: &DateTime<Utc>) -> String {
    t.to_rfc3339_opts(SecondsFormat::Millis, true)
}

/// "s-20261116-101530-4f2a": the local time and four hex digits (the Mac's ScreenTextHistory.newID).
pub fn new_id() -> String {
    use std::sync::atomic::{AtomicU64, Ordering};
    static N: AtomicU64 = AtomicU64::new(0);
    let nanos = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.subsec_nanos() as u64);
    let mix = (nanos ^ (std::process::id() as u64).rotate_left(17) ^ N.fetch_add(1, Ordering::Relaxed).wrapping_mul(0x9E37_79B9)) & 0xffff;
    format!("s-{}-{mix:04x}", chrono::Local::now().format("%Y%m%d-%H%M%S"))
}

/// One line as the Mac writes it: sorted keys (serde_json's map is ordered), "/" as "\/" (JSONSerialization's default).
fn line(v: &Value) -> String {
    serde_json::to_string(v).unwrap_or_default().replace('/', "\\/")
}

pub fn path() -> PathBuf {
    crate::paths::blurt_home().join("screen-text").join("history.jsonl")
}

/// record.screen_text.history_days (7, 30 — the default —, -1 forever, 0 not kept).
pub fn days(cfg: &Value) -> i64 {
    cfg.pointer("/record/screen_text/history_days").and_then(Value::as_i64).unwrap_or(DEFAULT_DAYS)
}

static LOCK: Mutex<()> = Mutex::new(());

/// The history in one file (the app's: `path()`; tests: their own).
pub struct Store {
    pub path: PathBuf,
}

impl Store {
    pub fn new(path: PathBuf) -> Store {
        Store { path }
    }

    /// `days` 0: nothing is written.
    pub fn append(&self, e: &Entry, days: i64) {
        if days != 0 {
            self.append_line(&e.json());
        }
    }

    pub fn delete(&self, ids: &[String]) {
        if !ids.is_empty() {
            self.append_line(&json!({"op": "delete", "ids": ids}));
        }
    }

    /// A better reading replaced the text on the clipboard (Alt+Shift+C's second reading): the entry says what is there now.
    pub fn update(&self, id: &str, text: &str) {
        self.append_line(&json!({"op": "text", "id": id, "text": text}));
    }

    pub fn clear(&self) {
        let _g = LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let _ = std::fs::remove_file(&self.path);
    }

    fn append_line(&self, v: &Value) {
        let _g = LOCK.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(d) = self.path.parent() {
            let _ = std::fs::create_dir_all(d);
        }
        let Ok(mut f) = open_private(&self.path, true) else { return };
        let _ = writeln!(f, "{}", line(v));
    }

    /// Newest first, deletions and later readings applied.
    pub fn load(&self) -> Vec<Entry> {
        let Ok(raw) = std::fs::read_to_string(&self.path) else { return vec![] };
        let mut out: Vec<Entry> = vec![];
        for l in raw.lines() {
            let Ok(o) = serde_json::from_str::<Value>(l) else { continue };
            match o["op"].as_str() {
                Some("delete") => {
                    let gone: Vec<&str> = o["ids"].as_array().map(|a| a.iter().filter_map(Value::as_str).collect()).unwrap_or_default();
                    out.retain(|e| !gone.contains(&e.id.as_str()));
                }
                Some("text") => {
                    if let (Some(id), Some(t)) = (o["id"].as_str(), o["text"].as_str()) {
                        if let Some(e) = out.iter_mut().find(|e| e.id == id) {
                            e.text = t.to_string();
                        }
                    }
                }
                _ => {
                    if let Some(e) = Entry::from_json(&o) {
                        out.push(e);
                    }
                }
            }
        }
        out.sort_by(|a, b| b.time.cmp(&a.time));
        out
    }

    /// Rewrites the file without entries older than `days` (0: none kept, -1: all kept) and without the op lines.
    /// Returns how many went.
    pub fn prune(&self, days: i64, now: DateTime<Utc>) -> usize {
        if !self.path.exists() {
            return 0;
        }
        let all = self.load();
        let keep: Vec<&Entry> = match days {
            d if d < 0 => all.iter().collect(),
            0 => vec![],
            d => all.iter().filter(|e| e.time >= now - chrono::Duration::days(d)).collect(),
        };
        let lines = std::fs::read_to_string(&self.path).map_or(0, |s| s.lines().count());
        if keep.len() == all.len() && lines == all.len() {
            return 0;
        }
        let _g = LOCK.lock().unwrap_or_else(|e| e.into_inner());
        if keep.is_empty() {
            let _ = std::fs::remove_file(&self.path);
        } else {
            let body: String = keep.iter().rev().map(|e| line(&e.json()) + "\n").collect();
            let tmp = self.path.with_extension("jsonl.tmp");
            let ok = open_private(&tmp, false).and_then(|mut f| f.write_all(body.as_bytes())).is_ok();
            if ok {
                let _ = std::fs::rename(&tmp, &self.path);
            } else {
                let _ = std::fs::remove_file(&tmp);
            }
        }
        all.len() - keep.len()
    }
}

/// What was on the screen is private: 0600 where there are modes.
fn open_private(p: &Path, append: bool) -> std::io::Result<std::fs::File> {
    let mut o = std::fs::OpenOptions::new();
    o.create(true);
    if append {
        o.append(true);
    } else {
        o.write(true).truncate(true);
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        o.mode(0o600);
    }
    o.open(p)
}

pub fn shared() -> Store {
    Store::new(path())
}

/// The result into the history (nothing when it keeps nothing) → its id.
pub fn remember(app: &AppHandle, e: Entry) -> Option<String> {
    let d = days(&crate::settings::read_config());
    if d == 0 {
        return None;
    }
    shared().append(&e, d);
    let _ = app.emit(CHANGED, json!({}));
    Some(e.id)
}

// ------------------------------------------------------------------ the main window's commands

/// The page's list (pruned to what Settings keeps first: a change of record.screen_text.history_days applies the next
/// time Settings, the page or Home reads it), how long it keeps, how many.
#[tauri::command(async)]
pub fn screen_text_history() -> Value {
    let d = days(&crate::settings::read_config());
    let s = shared();
    s.prune(d, Utc::now());
    let entries: Vec<Value> = s.load().iter().map(Entry::for_page).collect();
    json!({"entries": entries, "days": d, "count": entries.len()})
}

#[tauri::command(async)]
pub fn screen_text_history_delete(app: AppHandle, ids: Vec<String>) {
    shared().delete(&ids);
    let _ = app.emit(CHANGED, json!({}));
}

#[tauri::command(async)]
pub fn screen_text_history_clear(app: AppHandle) {
    shared().clear();
    let _ = app.emit(CHANGED, json!({}));
}

#[cfg(test)]
mod tests {
    use super::*;

    fn store() -> (tempfile::TempDir, Store) {
        let d = tempfile::tempdir().unwrap();
        let s = Store::new(d.path().join("screen-text").join("history.jsonl"));
        (d, s)
    }

    fn at(e: Entry, secs_ago: i64) -> Entry {
        Entry { time: Utc::now() - chrono::Duration::seconds(secs_ago), ..e }
    }

    #[test]
    fn append_load_newest_first_update_and_delete() {
        let (_d, h) = store();
        h.append(&at(Entry { id: "a".into(), ..Entry::new(false, "draft") }, 60), 30);
        let b = Entry { id: "b".into(), source: Some("Hello".into()), target: Some("zh".into()), app: Some("Edge".into()), ..Entry::new(true, "你好") };
        h.append(&b, 30);
        assert_eq!(h.load().iter().map(|e| e.id.as_str()).collect::<Vec<_>>(), ["b", "a"]);
        h.update("a", "draft, read again");
        assert_eq!(h.load()[1].text, "draft, read again");
        h.delete(&["b".into()]);
        let left = h.load();
        assert_eq!(left.len(), 1);
        assert_eq!(left[0].id, "a");
        assert!(!left[0].translated);
    }

    #[test]
    fn not_kept_writes_nothing() {
        let (_d, h) = store();
        h.append(&Entry::new(false, "x"), 0);
        assert!(!h.path.exists());
        assert!(h.load().is_empty());
    }

    #[test]
    fn prune_by_days_forever_and_off() {
        let (_d, h) = store();
        h.append(&at(Entry { id: "old".into(), ..Entry::new(false, "old") }, 10 * 86400), 30);
        h.append(&at(Entry { id: "new".into(), ..Entry::new(false, "new") }, 60), 30);
        h.delete(&["nothing".into()]);
        assert_eq!(h.prune(-1, Utc::now()), 0);
        // the op line is gone, nothing else
        assert_eq!(std::fs::read_to_string(&h.path).unwrap().lines().count(), 2);
        assert_eq!(h.prune(7, Utc::now()), 1);
        assert_eq!(h.load().iter().map(|e| e.id.as_str()).collect::<Vec<_>>(), ["new"]);
        assert_eq!(h.prune(0, Utc::now()), 1);
        assert!(!h.path.exists());
    }

    #[test]
    fn the_file_is_the_macs_line_for_line() {
        let (_d, h) = store();
        // as the Mac's JSONSerialization (.sortedKeys) writes it: "/" escaped, milliseconds, Z
        let mac = r#"{"app":"Safari","bundle":"com.apple.Safari","id":"s-20261116-101530-4f2a","outcome":"pasted","source":"See https:\/\/blurt.work","t":"2026-11-16T02:15:30.123Z","target":"zh","text":"见 https:\/\/blurt.work","translated":true}"#;
        std::fs::create_dir_all(h.path.parent().unwrap()).unwrap();
        std::fs::write(&h.path, format!("{mac}\n")).unwrap();
        let e = h.load().remove(0);
        assert_eq!(e.source.as_deref(), Some("See https://blurt.work"));
        assert_eq!(e.outcome.as_deref(), Some("pasted"));
        assert_eq!(line(&e.json()), mac);
        assert!(new_id().starts_with("s-") && new_id().len() == "s-20261116-101530-4f2a".len());
    }

    #[cfg(unix)]
    #[test]
    fn what_was_on_the_screen_is_private() {
        use std::os::unix::fs::PermissionsExt;
        let (_d, h) = store();
        h.append(&Entry::new(false, "secret"), 30);
        assert_eq!(std::fs::metadata(&h.path).unwrap().permissions().mode() & 0o777, 0o600);
    }

    #[test]
    fn days_default_to_thirty() {
        assert_eq!(days(&json!({})), 30);
        assert_eq!(days(&json!({"record": {"screen_text": {"history_days": -1}}})), -1);
        assert_eq!(days(&json!({"record": {"screen_text": {"history_days": 0}}})), 0);
    }
}
