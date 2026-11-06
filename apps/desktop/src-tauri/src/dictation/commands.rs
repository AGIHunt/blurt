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
/// The download's progress (MB done, MB in all): the island's "still downloading (412 MB / 950 MB)".
pub static PROGRESS: Mutex<Option<(f64, f64)>> = Mutex::new(None);
/// dictation's model is on this PC (None: not known yet) — the key says so at once instead of listening for nothing
pub static READY: Mutex<Option<bool>> = Mutex::new(None);

/// `dictation-models`' last answer: what Download… gets, whether a weaker model ran, whether the pick is a cloud one.
pub static MODELS: Mutex<Option<Value>> = Mutex::new(None);

fn remember_models(v: &Value) {
    *READY.lock().unwrap() = Some(v["ready"] == json!(true));
    *MODELS.lock().unwrap() = Some(v.clone());
}

/// Ask `dictation-models` (a `uv run`, ~1 s) and remember whether a dictation can run. The cloud speech keys go with
/// it (a cloud model is ready only with its key: cloud.rs `speech_env`).
pub fn refresh_ready(runner: &crate::scripts::Runner) {
    if let Ok(v) = runner.run_env(
        "transcribe.py",
        &["dictation-models".into()],
        None,
        Duration::from_secs(120),
        &cloud::speech_env(),
    ) {
        remember_models(&v);
    }
}

/// Set one `record.dictation` key, keeping the others (the merge is two levels deep: the whole object goes back).
pub fn set_dictation(key: &str, value: Value) -> R<()> {
    let mut d = settings::read_config()
        .pointer("/record/dictation")
        .cloned()
        .filter(Value::is_object)
        .unwrap_or(json!({}));
    if value.is_null() {
        d.as_object_mut().map(|o| o.remove(key));
    } else {
        d[key] = value;
    }
    settings::merge(json!({"record": {"dictation": d}})).map(|_| ())
}

pub fn downloading() -> bool {
    DOWNLOADING.lock().unwrap().is_some()
}

/// The model coming down now (the agent-setup endpoint's `status`).
pub fn downloading_id() -> Option<String> {
    DOWNLOADING.lock().unwrap().clone()
}

/// The download's process while it runs (Stop kills it and everything it started).
static DL_PROC: Mutex<Option<std::process::Child>> = Mutex::new(None);

/// Stop the download (the tray's and Settings' Stop; the Mac's ModelDownloads.stop): its process tree ends and what
/// it left half-written goes (`*.part`, Hugging Face's `*.incomplete`, a model's `.<dir>.tar.bz2`), so nothing
/// half-there passes for a model. → whether one was running.
#[tauri::command]
pub fn model_download_cancel() -> bool {
    let Some(mut c) = DL_PROC.lock().unwrap().take() else { return false };
    scripts::kill_tree(&mut c);
    clean_partial(&crate::paths::blurt_home().join("models"));
    true
}

fn clean_partial(dir: &std::path::Path) {
    for e in std::fs::read_dir(dir).into_iter().flatten().filter_map(Result::ok) {
        let p = e.path();
        let name = e.file_name().to_string_lossy().into_owned();
        if p.is_dir() {
            clean_partial(&p);
        } else if name.ends_with(".part") || name.ends_with(".incomplete") || (name.starts_with('.') && name.ends_with(".tar.bz2")) {
            let _ = std::fs::remove_file(&p);
        }
    }
}

#[tauri::command(async)]
pub fn dictation_models(state: tauri::State<'_, AppState>) -> R<Value> {
    let mut v = state
        .runner()
        .run_env(
            "transcribe.py",
            &["dictation-models".into()],
            None,
            Duration::from_secs(90),
            &cloud::speech_env(),
        )
        .map_err(String::from)?;
    remember_models(&v);
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
    // the size Download… promised (the catalogue's size_mb): the bar counts up to it even when the archive itself is
    // smaller, so "x / y" never names a second size (the Mac's max(p.total, sizeMB))
    let promised = MODELS
        .lock()
        .unwrap()
        .as_ref()
        .and_then(|v| v["models"].as_array().cloned())
        .and_then(|ms| ms.iter().find(|m| m["id"] == json!(id)).and_then(|m| m["size_mb"].as_f64()))
        .unwrap_or(0.0);
    std::thread::spawn(move || {
        // its own process group (Unix) / a tree taskkill ends (Windows): Stop ends uv and the Python under it
        let mut c = scripts::daemon_command(&argv);
        c.stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        let emit = |state: &str, done: f64, total: f64, msg: Option<String>| {
            let total = if total > 0.0 { total.max(promised) } else { total };
            *PROGRESS.lock().unwrap() = (state == "running" && total > 0.0).then_some((done, total));
            let _ = app.emit("model-download", json!({"id": id, "state": state, "done_mb": done, "total_mb": total, "message": msg}));
        };
        // the download's last words on stderr (what failed: no uv, offline …): the log and the failed event say them
        let mut last_err = String::new();
        emit("running", 0.0, 0.0, None);
        let ok = match c.spawn() {
            Ok(mut ch) => {
                let err_pipe = ch.stderr.take();
                let out_pipe = ch.stdout.take();
                *DL_PROC.lock().unwrap() = Some(ch);
                if let Some(err) = err_pipe {
                    for line in BufReader::new(err).lines().map_while(Result::ok) {
                        if !line.trim().is_empty() && !line.trim().ends_with("MB") {
                            last_err = line.trim().chars().take(300).collect();
                        }
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
                if let Some(mut o) = out_pipe {
                    use std::io::Read;
                    let _ = o.read_to_string(&mut out);
                }
                // Stop took the process (and waited for it): a stopped download isn't a failed one
                let Some(mut ch) = DL_PROC.lock().unwrap().take() else {
                    *DOWNLOADING.lock().unwrap() = None;
                    emit("stopped", 0.0, 0.0, None);
                    return;
                };
                let st = ch.wait().map(|s| s.success()).unwrap_or(false);
                st && out
                    .lines()
                    .last()
                    .and_then(|l| serde_json::from_str::<Value>(l).ok())
                    .is_some_and(|v| v["ok"] == json!(true))
            }
            Err(e) => {
                last_err = e.to_string();
                false
            }
        };
        *DOWNLOADING.lock().unwrap() = None;
        if !ok {
            eprintln!("blurt: speech model download failed: {last_err}");
            // the island says so, with Retry (a take's "Download…" must not just go quiet)
            #[cfg(dict)]
            super::engine::model_failed();
        }
        emit(if ok { "done" } else { "failed" }, 0.0, 0.0, (!ok && !last_err.is_empty()).then(|| last_err.clone()));
        if ok {
            refresh_ready(&app.state::<AppState>().runner());
            // a take that failed for want of it gets Retry on the island
            #[cfg(dict)]
            super::engine::model_arrived();
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
    // the merge is two levels deep: record.dictation as a whole, or its other settings (key, mode, …) would go
    let mut d = settings::read_config()
        .pointer("/record/dictation")
        .cloned()
        .filter(Value::is_object)
        .unwrap_or(json!({}));
    match id {
        Some(i) => d["asr_model"] = json!(i),
        None => {
            d.as_object_mut().map(|o| o.remove("asr_model"));
        }
    }
    settings::merge(json!({"record": {"dictation": d}}))?;
    let _ = server::call(
        server::ASR,
        &json!({"cmd": "exit"}),
        Duration::from_secs(2),
        None,
    );
    Ok(())
}

/// The speech server holds the cloud speech keys it started with: the next key-down starts one with the new ones.
fn restart_asr() {
    let _ = server::call(server::ASR, &json!({"cmd": "exit"}), Duration::from_secs(2), None);
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
    restart_asr();
    Ok(json!({"ok": true, "ms": test["ms"], "summary": cloud::summary()}))
}

#[tauri::command]
pub fn cloud_disconnect(id: String) -> R<Value> {
    cloud::disconnect(&id)?;
    restart_asr();
    Ok(cloud::summary())
}

pub(crate) fn cloud_check(app: &AppHandle, preset: &str, key: &str, base_url: Option<&str>) -> R<Value> {
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

/// The dictation key seen by Blurt's own window (App.tsx): "AltRight" / "AltLeft" (engine.rs `forward_key`).
#[tauri::command]
pub fn dictation_key_forward(code: String, down: bool) {
    #[cfg(dict)]
    {
        let vk = match code.as_str() {
            "AltRight" => 0xA5,
            "AltLeft" => 0xA4,
            _ => return,
        };
        super::engine::forward_key(vk, down);
    }
    #[cfg(not(dict))]
    let _ = (code, down);
}

// ------------------------------------------------------------------ the word list, the microphone

fn vocab_path() -> std::path::PathBuf {
    crate::paths::blurt_home().join("dictation").join("vocabulary.json")
}

fn vocab_doc() -> Value {
    std::fs::read_to_string(vocab_path())
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .filter(Value::is_object)
        .unwrap_or(json!({}))
}

/// The word list (Settings → Dictation → Words): every term but the removed ones, suggestions marked by `state`.
#[tauri::command]
pub fn dictation_words() -> Value {
    json!({"terms": super::words::listed(&vocab_doc())})
}

/// Edit the word list: `op` add (`term` may be "a, b, c") | remove | rename (`to`) | accept | reject | restore |
/// suggest.
#[tauri::command]
pub fn dictation_words_edit(op: String, term: String, to: Option<String>) -> R<Value> {
    use super::words;
    let mut d = vocab_doc();
    let changed = match op.as_str() {
        "add" => words::add(&mut d, &term, &chrono::Local::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, false)) > 0,
        "remove" => words::remove(&mut d, &term),
        "rename" => words::rename(&mut d, &term, to.as_deref().unwrap_or("")),
        "accept" | "restore" => words::set_state(&mut d, &term, "active"),
        "reject" => words::set_state(&mut d, &term, "rejected"),
        // Undo of Add / Ignore on a word waiting for review: it waits again
        "suggest" => words::set_state(&mut d, &term, "suggested"),
        _ => return Err(format!("unknown op {op}")),
    };
    if changed {
        let p = vocab_path();
        if let Some(dir) = p.parent() {
            std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
        }
        let tmp = p.with_extension("json.tmp");
        std::fs::write(&tmp, serde_json::to_string_pretty(&d).map_err(|e| e.to_string())?).map_err(|e| e.to_string())?;
        std::fs::rename(&tmp, &p).map_err(|e| e.to_string())?;
    }
    Ok(json!({"changed": changed, "terms": words::listed(&d)}))
}

/// An app's icon as Windows shows it (the Dictation page's rows; the Mac shows the app's icon there), a PNG data URL, or
/// null (a letter tile then). `exe`: the executable's path as the history keeps it (`exe_path`), or only its file name
/// for an older entry — then a running process of that name lends its path. Cached per executable.
#[tauri::command(async)]
pub fn app_icon(exe: String) -> Option<String> {
    #[cfg(windows)]
    {
        super::insert_win::icon_png(&exe).map(|b| {
            use base64::Engine;
            format!("data:image/png;base64,{}", base64::engine::general_purpose::STANDARD.encode(b))
        })
    }
    #[cfg(not(windows))]
    {
        let _ = exe;
        None
    }
}

/// The microphones dictation can listen with (Settings → Dictation → Microphone): {default, devices}. The choice is
/// `record.dictation.mic` (a device's name; unset: the system's default input).
#[tauri::command(async)]
pub fn dictation_mics() -> Value {
    #[cfg(windows)]
    {
        use cpal::traits::{DeviceTrait, HostTrait};
        let host = cpal::default_host();
        let default = host.default_input_device().and_then(|d| d.name().ok());
        let devices: Vec<String> = host
            .input_devices()
            .map(|it| it.filter_map(|d| d.name().ok()).collect())
            .unwrap_or_default();
        json!({"default": default, "devices": devices})
    }
    #[cfg(not(windows))]
    json!({"default": null, "devices": []})
}
