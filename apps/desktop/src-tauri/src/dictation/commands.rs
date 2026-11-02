//! What Settings → Dictation and Settings → Cloud call (the Mac's Settings/DictationModels.swift, CloudServices
//! pane): dictation's speech models (`transcribe.py dictation-models`), one download at a time with its progress
//! (`transcribe.py setup --model-id`; stderr's "N/M MB" lines become `model-download` events), the model in use, and
//! the cloud services (cloud.rs) with a Test that makes one tiny request (`polish.py serve`'s `cloud_check`).

use std::io::{BufRead, BufReader};
use std::process::Stdio;
use std::sync::Mutex;
use std::time::Duration;

use serde_json::{json, Value};
use tauri::{AppHandle, Emitter, Manager};

use super::{cloud, server};
use crate::{scripts, settings, AppState};

type R<T> = Result<T, String>;

static DOWNLOADING: Mutex<Option<String>> = Mutex::new(None);
/// dictation's model is on this PC (None: not known yet) — the key says so at once instead of listening for nothing
pub static READY: Mutex<Option<bool>> = Mutex::new(None);

/// Ask `dictation-models` (a `uv run`, ~1 s) and remember whether a dictation can run.
pub fn refresh_ready(runner: &crate::scripts::Runner) {
    if let Ok(v) = runner.run(
        "transcribe.py",
        &["dictation-models".into()],
        None,
        Duration::from_secs(120),
    ) {
        *READY.lock().unwrap() = Some(v["ready"] == json!(true));
    }
}

pub fn downloading() -> bool {
    DOWNLOADING.lock().unwrap().is_some()
}

#[tauri::command(async)]
pub fn dictation_models(state: tauri::State<'_, AppState>) -> R<Value> {
    let mut v = state
        .runner()
        .run(
            "transcribe.py",
            &["dictation-models".into()],
            None,
            Duration::from_secs(90),
        )
        .map_err(String::from)?;
    *READY.lock().unwrap() = Some(v["ready"] == json!(true));
    v["downloading"] = json!(DOWNLOADING.lock().unwrap().clone());
    Ok(v)
}

/// Start downloading a speech model; progress arrives as `model-download` events {id, done_mb, total_mb, state}.
#[tauri::command]
pub fn model_download(app: AppHandle, id: String) -> R<()> {
    {
        let mut d = DOWNLOADING.lock().unwrap();
        if d.is_some() {
            return Err("a download is already running".into());
        }
        *d = Some(id.clone());
    }
    let runner = app.state::<AppState>().runner();
    let argv = match runner.argv(
        "transcribe.py",
        &[
            "setup".into(),
            "--model-id".into(),
            id.clone(),
            "--parent".into(),
            std::process::id().to_string(),
        ],
    ) {
        Ok(a) => a,
        Err(e) => {
            *DOWNLOADING.lock().unwrap() = None;
            return Err(e.message);
        }
    };
    std::thread::spawn(move || {
        let mut c = scripts::command(&argv);
        c.stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        let emit = |state: &str, done: f64, total: f64, msg: Option<String>| {
            let _ = app.emit("model-download", json!({"id": id, "state": state, "done_mb": done, "total_mb": total, "message": msg}));
        };
        emit("running", 0.0, 0.0, None);
        let ok = match c.spawn() {
            Ok(mut ch) => {
                if let Some(err) = ch.stderr.take() {
                    for line in BufReader::new(err).lines().map_while(Result::ok) {
                        // "  412/950 MB" (transcribe.progress_line)
                        if let Some((a, b)) = line
                            .trim()
                            .strip_suffix("MB")
                            .and_then(|x| x.trim().split_once('/'))
                        {
                            if let (Ok(d), Ok(t)) =
                                (a.trim().parse::<f64>(), b.trim().parse::<f64>())
                            {
                                emit("running", d, t, None);
                            }
                        }
                    }
                }
                let mut out = String::new();
                if let Some(mut o) = ch.stdout.take() {
                    use std::io::Read;
                    let _ = o.read_to_string(&mut out);
                }
                let st = ch.wait().map(|s| s.success()).unwrap_or(false);
                st && out
                    .lines()
                    .last()
                    .and_then(|l| serde_json::from_str::<Value>(l).ok())
                    .is_some_and(|v| v["ok"] == json!(true))
            }
            Err(_) => false,
        };
        *DOWNLOADING.lock().unwrap() = None;
        emit(if ok { "done" } else { "failed" }, 0.0, 0.0, None);
        if ok {
            refresh_ready(&app.state::<AppState>().runner());
            // the warm server holds the old pick: the next key-down starts one with this model
            let _ = server::call(
                server::ASR,
                &json!({"cmd": "exit"}),
                Duration::from_secs(2),
                None,
            );
        }
    });
    Ok(())
}

/// Use this model for dictation (None: Automatic).
#[tauri::command]
pub fn dictation_use(id: Option<String>) -> R<()> {
    settings::merge(json!({"record": {"dictation": {"asr_model": id}}}))?;
    let _ = server::call(
        server::ASR,
        &json!({"cmd": "exit"}),
        Duration::from_secs(2),
        None,
    );
    Ok(())
}

#[tauri::command]
pub fn cloud_summary() -> Value {
    cloud::summary()
}

#[tauri::command(async)]
pub fn cloud_connect(
    app: AppHandle,
    preset: String,
    key: String,
    base_url: Option<String>,
) -> R<Value> {
    // test before saving: a wrong key never becomes the one polish uses
    let test = cloud_check(&app, &preset, &key, base_url.as_deref())?;
    if test["ok"] != json!(true) {
        return Ok(test);
    }
    cloud::connect(&preset, &key, base_url.as_deref(), None)?;
    Ok(json!({"ok": true, "ms": test["ms"], "summary": cloud::summary()}))
}

#[tauri::command]
pub fn cloud_disconnect(id: String) -> R<Value> {
    cloud::disconnect(&id)?;
    Ok(cloud::summary())
}

fn cloud_check(app: &AppHandle, preset: &str, key: &str, base_url: Option<&str>) -> R<Value> {
    let model = cloud::measured_default(preset, "polish").ok_or("pick a model for this service")?;
    let mut c = json!({"provider": preset, "model": model, "key": key});
    if let Some(b) = base_url.filter(|b| !b.trim().is_empty()) {
        c["base_url"] = json!(b);
    }
    let runner = app.state::<AppState>().runner();
    server::ensure(&runner, server::POLISH, "polish.py", &[])?;
    if !server::wait_ready(server::POLISH, Duration::from_secs(30)) {
        return Err("polish server didn't start".into());
    }
    server::call(
        server::POLISH,
        &json!({"cmd": "cloud_check", "cloud": c}),
        Duration::from_secs(20),
        None,
    )
    .ok_or_else(|| "no answer".into())
}
