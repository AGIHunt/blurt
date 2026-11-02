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
#[cfg_attr(not(windows), allow(dead_code))]
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
    #[cfg(windows)]
    {
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
        let p = super::engine::polish_text(
            &runner,
            &raw,
            old["app"].as_str().map(String::from),
            structured,
            false,
        );
        let e = retried(
            &old,
            &json!({"raw": raw, "text": p.text, "polished": p.polished, "model": p.model, "fell_back": p.fell_back,
                    "reason": p.reason, "asr_ms": asr_ms, "polish_ms": p.ms}),
        );
        run(&runner, &["restore"], Some(&json!({ "entries": [e.clone()] })))?;
        let _ = app.clipboard().write_text(e["text"].as_str().unwrap_or("").to_string());
        Ok(json!({"ok": true, "entry": with_audio_path(e)}))
    }
    #[cfg(not(windows))]
    {
        let _ = (app, id);
        Err("Retry isn't available on this system yet [unsupported]".into())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

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
