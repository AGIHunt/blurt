//! What drags and drops did, kept on disk (the Mac's BlurtCore DragLog, same file and format): drops from other apps on
//! the island and the main window, the main window's pastes. `<BLURT_HOME>/logs/card-drag.log`, one JSON object per
//! line with its local time (`at`), the last ~512 KB (one older file, `.1`). Never the words: fields that may carry
//! what a card or a paste says are left out. So "it did nothing" can be looked up afterwards (drag-drop.md §0.4).

use serde_json::{Map, Value};
use std::io::Write;
use std::sync::Mutex;

pub const FILE_NAME: &str = "card-drag.log";
pub const MAX_BYTES: u64 = 512 * 1024;

/// The events kept (the Mac's DragLog.events, the drop and paste ones; the rest are the Mac's own drag-out probes).
pub const EVENTS: &[&str] = &[
    "drop_watch", "drop_external", "drop_hang", "main_drop_over", "main_drop", "detail_drop_over", "detail_drop",
    "item_drop_add", "main_paste", "item_add_files", "note_offer",
];

/// Fields that may carry what a card or a paste says.
const TEXT_FIELDS: &[&str] = &["text", "said", "note", "words", "typed"];

static LOCK: Mutex<()> = Mutex::new(());

/// The line kept for `obj` (None: not a drop or paste event): the text fields left out, `at` added.
pub fn line(obj: &Value, at: &str) -> Option<String> {
    let o = obj.as_object()?;
    let e = o.get("event")?.as_str()?;
    if !EVENTS.contains(&e) {
        return None;
    }
    let mut out: Map<String, Value> = o.iter().filter(|(k, _)| !TEXT_FIELDS.contains(&k.as_str())).map(|(k, v)| (k.clone(), v.clone())).collect();
    out.insert("at".into(), Value::String(at.to_string()));
    serde_json::to_string(&Value::Object(out)).ok()
}

/// Appends `obj` to the log (best effort: a full disk or a read-only home loses the line, never the drop).
pub fn log(obj: Value) {
    let at = chrono::Local::now().format("%Y-%m-%dT%H:%M:%S%.3f%:z").to_string();
    let Some(l) = line(&obj, &at) else { return };
    let dir = crate::paths::blurt_home().join("logs");
    let _g = LOCK.lock().unwrap();
    let _ = std::fs::create_dir_all(&dir);
    let file = dir.join(FILE_NAME);
    if std::fs::metadata(&file).map(|m| m.len() > MAX_BYTES).unwrap_or(false) {
        let _ = std::fs::rename(&file, dir.join(format!("{FILE_NAME}.1")));
    }
    if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(&file) {
        let _ = writeln!(f, "{l}");
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn keeps_drop_events_without_their_words() {
        let l = line(&json!({"event": "main_paste", "to": "item", "images": 1, "text": "secret words"}), "2026-11-15T22:00:00.000+08:00").unwrap();
        let v: Value = serde_json::from_str(&l).unwrap();
        assert_eq!(v["to"], "item");
        assert_eq!(v["images"], 1);
        assert!(v.get("text").is_none());
        assert_eq!(v["at"], "2026-11-15T22:00:00.000+08:00");
        assert!(line(&json!({"event": "something_else"}), "x").is_none());
        assert!(line(&json!({"no": "event"}), "x").is_none());
    }
}
