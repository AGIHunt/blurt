//! The Dictation page (the Mac's MainWindow/DictationPage.swift over BlurtCore/DictationHistory.swift): every
//! dictation in `$BLURT_HOME/dictation/history.jsonl`, read and edited through `dictation.py` (list · delete ·
//! restore · correct · clear · item · prune) — one place for the file's rules and its lock, the same lines the Mac app
//! writes — and Retry: the kept recording heard again by the warm speech server, polished as a take is (engine.rs),
//! written back as the same entry and copied (from the history there is no app to type into).
//!
//! The commands (web/apps/desktop/src/api.ts):
//!  • `dictation_history` → {entries: [entry + "audio_path" when its recording is there], retention_days, enabled,
//!    ready (dictation's model is on this PC; null: not known yet), can_retry}. The first call of a run prunes
//!    (record.dictation.retention_days) — the Mac does at launch.
//!  • `dictation_history_edit {edit}` — the history's edit lines: {"op":"delete","ids"} → {deleted: [entries]} ·
//!    {"op":"restore","entries"} (Undo) · {"op":"correct","id","text"|null} · {"op":"clear"}.
//!  • `dictation_history_item {id, project?, lang?}` → {item: {id, uid, title, kind, project, path} | {id, uid, already}}.
//!  • `dictation_retry {id}` → {entry} (Windows; elsewhere an `unsupported` error).

use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use serde_json::{json, Value};
use tauri::{AppHandle, Emitter, Manager};

use crate::{paths, scripts::Runner, settings, AppState};

type R<T> = Result<T, String>;

/// the history was pruned in this run
static PRUNED: AtomicBool = AtomicBool::new(false);

fn dir() -> PathBuf {
    paths::blurt_home().join("dictation")
}

/// A take landed in the history (or changed there): the page reloads (`dictation://changed`).
pub fn changed(app: &AppHandle) {
    let _ = app.emit("dictation://changed", json!({}));
}

/// One line appended to history.jsonl (O_APPEND: a line lands whole) — a take written by the engine.
pub fn append_line(row: &Value) {
    use std::io::Write;
    let d = dir();
    let _ = std::fs::create_dir_all(&d);
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(d.join("history.jsonl"))
    {
        let _ = writeln!(f, "{row}");
    }
}

/// The reason a take the user cancelled (Esc) is kept under (engine.rs `cancel`): meant, so it is offered only on the
/// Dictation page — never in the tray or on Home.
pub const CANCELLED_REASON: &str = "asr_failed:cancelled";

/// Retry from the history works on this system (the Dictation page's, the tray's, Home's: `dictation_retry`).
pub const CAN_RETRY: bool = cfg!(windows);

/// The history's entries as they stand (dictation.py `load`'s rules: delete / clear / correct lines applied), newest
/// first — read from the file itself, since the tray's menu is worked out often and a `uv run` each time is too slow.
pub fn entries_in(raw: &str) -> Vec<Value> {
    let mut by_id: std::collections::HashMap<String, Value> = std::collections::HashMap::new();
    for ln in raw.lines() {
        let Ok(o) = serde_json::from_str::<Value>(ln) else { continue };
        match o["op"].as_str() {
            Some("delete") => {
                for i in o["ids"].as_array().into_iter().flatten().filter_map(Value::as_str) {
                    by_id.remove(i);
                }
            }
            Some("clear") => by_id.clear(),
            Some("correct") => {
                if let Some(e) = o["id"].as_str().and_then(|i| by_id.get_mut(i)) {
                    match o["text"].as_str() {
                        Some(t) => e["corrected"] = json!(t),
                        None => {
                            e.as_object_mut().map(|m| m.remove("corrected"));
                        }
                    }
                }
            }
            Some(_) => {}
            None => {
                if let (Some(id), true) = (o["id"].as_str(), o["raw"].is_string()) {
                    by_id.insert(id.to_string(), o.clone());
                }
            }
        }
    }
    let mut es: Vec<Value> = by_id.into_values().collect();
    es.sort_by(|a, b| b["t"].as_str().unwrap_or("").cmp(a["t"].as_str().unwrap_or("")));
    es
}

fn entries() -> Vec<Value> {
    std::fs::read_to_string(dir().join("history.jsonl")).map(|r| entries_in(&r)).unwrap_or_default()
}

/// The text as it went out: the user's correction, else the text typed (polished, heard).
fn final_text(e: &Value) -> Option<String> {
    ["corrected", "text", "polished", "raw"]
        .iter()
        .find_map(|k| e[*k].as_str().filter(|t| !t.trim().is_empty()))
        .map(str::to_owned)
}

/// The last thing dictated, as it went out, for the tray's Copy last dictation. None: nothing with text.
pub fn last_text() -> Option<String> {
    entries().iter().find_map(final_text)
}

pub fn last_text_in(raw: &str) -> Option<String> {
    entries_in(raw).iter().find_map(final_text)
}

/// Recognition failed (no text) and the user didn't cancel it: the speech model failed, was too slow, the app quit
/// before the text came (the Mac's DictationRetry.failed).
pub fn failed(e: &Value) -> bool {
    let reason = e["reason"].as_str().unwrap_or("");
    e["text"].as_str().unwrap_or("").is_empty() && reason.starts_with("asr_failed") && reason != CANCELLED_REASON
}

/// Its recording is still on disk.
pub fn audio_kept(e: &Value) -> bool {
    e["audio"].as_str().is_some_and(|a| {
        let p = std::path::Path::new(a);
        if p.is_absolute() { p.is_file() } else { dir().join(a).is_file() }
    })
}

/// The tray's row for the last dictation (the Mac's DictationRetry.MenuRow).
#[derive(Clone, Debug, PartialEq)]
pub enum MenuRow {
    /// copy this text (the newest dictation with text)
    Copy(String),
    /// retry this entry (the newest, failed, its recording kept)
    Retry(Value),
}

/// `entries` newest first; `audio_kept`: its recording is still on disk; `can_retry`: Retry works here. A cancelled
/// or recording-less failed take leaves Copy of the last text.
pub fn menu_row(entries: &[Value], audio_kept: impl Fn(&Value) -> bool, can_retry: bool) -> Option<MenuRow> {
    if let Some(first) = entries.first().filter(|f| can_retry && failed(f) && audio_kept(f)) {
        return Some(MenuRow::Retry(first.clone()));
    }
    entries.iter().find_map(final_text).map(MenuRow::Copy)
}

/// The tray's row now.
pub fn menu_row_now() -> Option<MenuRow> {
    menu_row(&entries(), audio_kept, CAN_RETRY)
}

/// "14:02 · 0:12" (en: "2:02 PM · 0:12"; another day: "Nov 15 2:02 PM"): when a take was, and how long — the tray's
/// Retry row says which take it is.
pub fn when_and_length(e: &Value, now: chrono::DateTime<chrono::Local>, zh: bool) -> String {
    let secs = e["duration"].as_f64().unwrap_or(0.0).max(0.0).round() as u64;
    let length = format!("{}:{:02}", secs / 60, secs % 60);
    let Some(t) = e["t"].as_str().and_then(|t| chrono::DateTime::parse_from_rfc3339(t).ok()) else { return length };
    let t = t.with_timezone(&chrono::Local);
    let time = match (zh, t.date_naive() == now.date_naive()) {
        (true, true) => t.format("%H:%M").to_string(),
        (true, false) => t.format("%-m月%-d日 %H:%M").to_string(),
        (false, true) => t.format("%-I:%M %p").to_string(),
        (false, false) => t.format("%b %-d %-I:%M %p").to_string(),
    };
    format!("{time} · {length}")
}

fn run(runner: &Runner, args: &[&str], stdin: Option<&Value>) -> R<Value> {
    let a: Vec<String> = args.iter().map(|s| s.to_string()).collect();
    let body = stdin.map(|v| v.to_string().into_bytes());
    runner
        .run("dictation.py", &a, body.as_deref(), Duration::from_secs(60))
        .map_err(String::from)
}

fn retention_days(cfg: &Value) -> u64 {
    cfg.pointer("/record/dictation/retention_days")
        .and_then(Value::as_u64)
        .unwrap_or(30)
}

/// What the page reads besides the file: where the recording is (for playback, through the asset protocol).
fn with_audio_path(mut e: Value) -> Value {
    if let Some(a) = e.get("audio").and_then(Value::as_str) {
        let p = if std::path::Path::new(a).is_absolute() {
            PathBuf::from(a)
        } else {
            dir().join(a)
        };
        if p.is_file() {
            e["audio_path"] = json!(p.to_string_lossy());
        }
    }
    e
}

/// An entry as the file keeps it (without what the page added).
fn as_stored(mut e: Value) -> Value {
    if let Some(o) = e.as_object_mut() {
        o.remove("audio_path");
    }
    e
}

#[tauri::command(async)]
pub fn dictation_history(app: AppHandle) -> R<Value> {
    let runner = app.state::<AppState>().runner();
    if !PRUNED.swap(true, Ordering::SeqCst) {
        let _ = run(&runner, &["prune"], None);
    }
    let v = run(&runner, &["list"], None)?;
    let _ = app
        .asset_protocol_scope()
        .allow_directory(dir().join("audio"), false);
    let entries: Vec<Value> = v["entries"]
        .as_array()
        .cloned()
        .unwrap_or_default()
        .into_iter()
        .map(with_audio_path)
        .collect();
    let cfg = settings::read_config();
    Ok(json!({
        "entries": entries,
        "retention_days": retention_days(&cfg),
        "enabled": cfg.pointer("/record/dictation/enabled").and_then(Value::as_bool).unwrap_or(true),
        "ready": *super::commands::READY.lock().unwrap(),
        "can_retry": cfg!(windows),
    }))
}

#[tauri::command(async)]
pub fn dictation_history_edit(app: AppHandle, edit: Value) -> R<Value> {
    let runner = app.state::<AppState>().runner();
    match edit["op"].as_str() {
        Some("delete") => {
            let ids: Vec<&str> = edit["ids"]
                .as_array()
                .map(|a| a.iter().filter_map(Value::as_str).collect())
                .unwrap_or_default();
            if ids.is_empty() {
                return Ok(json!({"ok": true, "deleted": []}));
            }
            let mut args = vec!["delete"];
            args.extend(ids);
            run(&runner, &args, None)
        }
        Some("restore") => {
            let entries: Vec<Value> = edit["entries"]
                .as_array()
                .cloned()
                .unwrap_or_default()
                .into_iter()
                .map(as_stored)
                .collect();
            run(&runner, &["restore"], Some(&json!({ "entries": entries })))
        }
        Some("correct") => {
            let id = edit["id"].as_str().ok_or("correct: no id")?;
            match edit["text"].as_str() {
                Some(t) => run(&runner, &["correct", id, "--text", t], None),
                None => run(&runner, &["correct", id], None),
            }
        }
        Some("clear") => run(&runner, &["clear"], None),
        other => Err(format!("unknown history edit {other:?}")),
    }
}

/// Turn into Item: `dictation.py item ID --project <the current project, else Unassigned> --lang`.
#[tauri::command(async)]
pub fn dictation_history_item(
    app: AppHandle,
    id: String,
    project: Option<String>,
    lang: Option<String>,
) -> R<Value> {
    let runner = app.state::<AppState>().runner();
    let project = project
        .filter(|p| !p.is_empty() && p != "auto")
        .unwrap_or_else(|| "inbox".into());
    let mut args = vec!["item", id.as_str(), "--project", project.as_str()];
    let lang = lang.map(|l| if l.starts_with("zh") { "zh".to_string() } else { "en".to_string() });
    if let Some(l) = &lang {
        args.extend(["--lang", l.as_str()]);
    }
    run(&runner, &args, None)
}

/// The take as it should read after Retry (`heard`: raw, text, polished, model, fell_back, reason, timings): heard
/// again, polished again, copied — the Mac's retry from the history.
#[cfg_attr(not(dict), allow(dead_code))]
fn retried(old: &Value, heard: &Value) -> Value {
    let mut e = as_stored(old.clone());
    if let (Some(o), Some(h)) = (e.as_object_mut(), heard.as_object()) {
        o.remove("corrected"); // a correction of the text that was there before
        for (k, v) in h {
            o.insert(k.clone(), v.clone());
        }
        o.insert("insert".into(), json!("copied"));
    }
    e
}

/// Retry: the whole recording heard again with today's settings, polished, written back and copied.
#[tauri::command(async)]
pub fn dictation_retry(app: AppHandle, id: String) -> R<Value> {
    retry(&app, &id)
}

#[cfg(dict)]
fn retry(app: &AppHandle, id: &str) -> R<Value> {
    use std::time::Instant;
    use tauri_plugin_clipboard_manager::ClipboardExt;
    let runner = app.state::<AppState>().runner();
    let list = run(&runner, &["list"], None)?;
    let old = list["entries"]
        .as_array()
        .and_then(|a| a.iter().find(|e| e["id"] == json!(id)))
        .cloned()
        .ok_or_else(|| format!("no dictation {id} [not_found]"))?;
    let wav = old["audio"]
        .as_str()
        .map(|a| dir().join(a))
        .filter(|p| p.is_file())
        .ok_or("The recording no longer exists [retry_gone]")?;
    let t0 = Instant::now();
    let raw = super::engine::recognise(&runner, &wav, "", Some("dictation"))
        .map_err(|code| format!("not recognized [{code}]"))?;
    if raw.trim().is_empty() {
        return Err("nothing was heard [nothing]".into());
    }
    let asr_ms = t0.elapsed().as_millis() as u64;
    let structured = old["style"].as_str() == Some("structured");
    let p = super::engine::polish_text(&runner, &raw, old["app"].as_str().map(String::from), structured, false);
    let e = retried(
        &old,
        &json!({"raw": raw, "text": p.text, "polished": p.polished, "model": p.model, "fell_back": p.fell_back,
                "reason": p.reason, "asr_ms": asr_ms, "polish_ms": p.ms}),
    );
    run(&runner, &["restore"], Some(&json!({ "entries": [e.clone()] })))?;
    let _ = app.clipboard().write_text(e["text"].as_str().unwrap_or("").to_string());
    changed(app); // the tray's Retry row, Home's row
    Ok(json!({"ok": true, "entry": with_audio_path(e)}))
}

#[cfg(not(dict))]
fn retry(_app: &AppHandle, _id: &str) -> R<Value> {
    Err("Retry isn't available on this system yet [unsupported]".into())
}

/// The tray's Retry last dictation (and the Mac's menu-bar row): the recording heard again, the text onto the clipboard
/// only — by then the user may be anywhere, so it is never pasted — and the usual "Copied" line. The island says it is
/// at work meanwhile; a take that fails again says so and keeps its row in the tray.
pub fn retry_from_tray(app: &AppHandle, id: String) {
    use crate::island;
    const KEY: &str = "dictation.retry_last";
    let line = |msg: &str, mark: Option<&str>, ms: u64| {
        let mut op = json!({"op": "toast", "kind": "dictation", "msg": msg, "key": KEY, "ms": ms});
        if let Some(m) = mark {
            op["mark"] = json!(m);
        }
        island::send(app, op);
    };
    // the take's own failure line and its Retry: this is that Retry
    island::send(app, json!({"op": "toast_drop", "keys": [super::flow::toast_keys::failed(&id)]}));
    line("island.dictation.transcribing", Some("spinner"), 60_000);
    match retry(app, &id) {
        Ok(_) => line("dictation.toast.copied", Some("check"), 2400),
        Err(e) if e.contains("[retry_gone]") => line("dictation.toast.retry_gone", Some("warning"), 3000),
        Err(_) => line("dictation.toast.asr_failed", Some("warning"), 5000),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn last_text_applies_the_edit_lines() {
        let raw = [
            r#"{"id":"a","t":"2026-11-16T10:00:00Z","raw":"one","text":"One."}"#,
            r#"{"id":"b","t":"2026-11-16T11:00:00Z","raw":"two","text":"Two."}"#,
            r#"{"id":"c","t":"2026-11-16T12:00:00Z","raw":"","text":""}"#,
            r#"{"op":"correct","id":"b","text":"Two!"}"#,
        ]
        .join("\n");
        assert_eq!(last_text_in(&raw).as_deref(), Some("Two!"));
        let raw = format!("{raw}\n{}", r#"{"op":"delete","ids":["b"]}"#);
        assert_eq!(last_text_in(&raw).as_deref(), Some("One."));
        let raw = format!("{raw}\n{}", r#"{"op":"clear"}"#);
        assert_eq!(last_text_in(&raw), None);
    }

    fn ok(id: &str, t: &str, text: &str) -> Value {
        json!({"id": id, "t": t, "raw": text, "text": text, "reason": null, "insert": "pasted", "duration": 2.0})
    }
    fn failed_take(id: &str, t: &str, reason: &str) -> Value {
        json!({"id": id, "t": t, "raw": "", "text": "", "reason": reason, "insert": "none", "duration": 12.4,
               "audio": format!("audio/{id}.wav")})
    }
    fn id(r: Option<MenuRow>) -> Option<String> {
        r.map(|r| match r {
            MenuRow::Copy(t) => format!("copy:{t}"),
            MenuRow::Retry(e) => format!("retry:{}", e["id"].as_str().unwrap()),
        })
    }

    #[test]
    fn a_failed_take_is_not_a_cancelled_one() {
        assert!(failed(&failed_take("f", "", "asr_failed:timeout")));
        assert!(failed(&failed_take("i", "", "asr_failed:interrupted")));
        assert!(failed(&failed_take("m", "", "asr_failed:model_missing")));
        assert!(!failed(&failed_take("c", "", CANCELLED_REASON)));
        assert!(!failed(&ok("a", "", "hello")));
        assert!(!failed(&json!({"id": "x", "raw": "", "text": "", "reason": "nothing"})));
    }

    #[test]
    fn the_tray_retries_the_last_take_when_it_failed() {
        let kept = |_: &Value| true;
        let gone = |_: &Value| false;
        let es = [failed_take("f", "2026-11-16T14:02:00+08:00", "asr_failed:timeout"), ok("a", "2026-11-16T14:00:00+08:00", "hello")];
        assert_eq!(id(menu_row(&es, kept, true)), Some("retry:f".into()));
        // its recording gone, or Retry not on this system: Copy of the last text, as before
        assert_eq!(id(menu_row(&es, gone, true)), Some("copy:hello".into()));
        assert_eq!(id(menu_row(&es, kept, false)), Some("copy:hello".into()));
        // a cancelled take was meant: never offered in the tray
        let es = [failed_take("c", "2026-11-16T14:02:00+08:00", CANCELLED_REASON), ok("a", "2026-11-16T14:00:00+08:00", "hello")];
        assert_eq!(id(menu_row(&es, kept, true)), Some("copy:hello".into()));
        assert_eq!(id(menu_row(&es[..1], kept, true)), None);
        assert_eq!(id(menu_row(&[], kept, true)), None);
        // only the newest: an older failure under a newer dictation is the Dictation page's
        let es = [ok("a", "2026-11-16T14:05:00+08:00", "hello"), failed_take("f", "2026-11-16T14:02:00+08:00", "asr_failed:timeout")];
        assert_eq!(id(menu_row(&es, kept, true)), Some("copy:hello".into()));
    }

    #[test]
    fn entries_are_newest_first_with_the_edits_applied() {
        let raw = [
            r#"{"id":"a","t":"2026-11-16T10:00:00Z","raw":"one","text":"One."}"#,
            r#"{"id":"f","t":"2026-11-16T12:00:00Z","raw":"","text":"","reason":"asr_failed:timeout"}"#,
            r#"{"id":"b","t":"2026-11-16T11:00:00Z","raw":"two","text":"Two."}"#,
        ]
        .join("\n");
        let ids: Vec<_> = entries_in(&raw).iter().map(|e| e["id"].as_str().unwrap().to_string()).collect();
        assert_eq!(ids, ["f", "b", "a"]);
        let raw = format!("{raw}\n{}", r#"{"op":"delete","ids":["f"]}"#);
        assert_eq!(entries_in(&raw)[0]["id"], json!("b"));
    }

    #[test]
    fn the_retry_row_says_when_and_how_long() {
        use chrono::TimeZone;
        let now = chrono::Local.with_ymd_and_hms(2026, 11, 16, 15, 0, 0).unwrap();
        let at = chrono::Local.with_ymd_and_hms(2026, 11, 16, 14, 2, 0).unwrap();
        let e = json!({"t": at.to_rfc3339(), "duration": 12.4});
        assert_eq!(when_and_length(&e, now, true), "14:02 · 0:12");
        assert_eq!(when_and_length(&e, now, false), "2:02 PM · 0:12");
        let e = json!({"t": (at - chrono::Duration::days(1)).to_rfc3339(), "duration": 75.0});
        assert_eq!(when_and_length(&e, now, true), "11月15日 14:02 · 1:15");
        assert_eq!(when_and_length(&e, now, false), "Nov 15 2:02 PM · 1:15");
        assert_eq!(when_and_length(&json!({"duration": 3.0}), now, false), "0:03");
    }

    #[test]
    fn retried_entry_is_copied_and_drops_the_old_correction() {
        let old = json!({"id": "d-1", "t": "2026-11-02T10:00:00+08:00", "raw": "", "text": "", "corrected": "x",
                         "reason": "asr_failed:asr_slow", "insert": "none", "audio": "audio/d-1.wav",
                         "audio_path": "C:\\x\\d-1.wav", "item": "BA-1", "item_uid": "01X"});
        let e = retried(&old, &json!({"raw": "um hello", "text": "Hello.", "polished": "Hello.", "reason": null}));
        assert_eq!(e["text"], json!("Hello."));
        assert_eq!(e["raw"], json!("um hello"));
        assert_eq!(e["insert"], json!("copied"));
        assert_eq!(e["reason"], Value::Null);
        assert!(e.get("corrected").is_none());
        assert!(e.get("audio_path").is_none());
        assert_eq!(e["item"], json!("BA-1")); // restore writes its item link again
    }

    #[test]
    fn retention_defaults_to_30_days() {
        assert_eq!(retention_days(&json!({})), 30);
        assert_eq!(retention_days(&json!({"record": {"dictation": {"retention_days": 7}}})), 7);
    }
}
