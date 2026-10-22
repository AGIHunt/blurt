//! The island on Windows / Linux (contract K7): a top-centre floating pill — the same component as the macOS notch
//! island, with lighter motion. It shows the current project, recording / voice / sorting state, the jobs under way,
//! agent sessions that need you and the review count, and holds the unfiled captures as cards under it.
//!
//! The window and its click-through live in `blurt_capture::overlay::island`; this module feeds it (`state` and
//! `cards` ops) and acts on what the user does there. It also applies K4's reminder rules: never open anything by
//! itself, a quiet line in the island, a system notification only when Blurt isn't in front.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use blurt_capture::overlay::{self, Island};
use blurt_capture::Region;
use serde_json::{json, Value};
use tauri::{AppHandle, Emitter, Manager, Wry};
use tauri_plugin_clipboard_manager::ClipboardExt;
use tauri_plugin_dialog::DialogExt;
use tauri_plugin_notification::NotificationExt;
use tauri_plugin_opener::OpenerExt;

use crate::capture::{self, Control};
use crate::jobs::{self, Notice};
use crate::projects::{self, Registry};
use crate::{hotkeys, l10n, paths, sessions, settings, AppState};

#[derive(Default)]
pub struct Hub {
    island: Mutex<Option<Arc<Island<Wry>>>>,
    /// last system notification per kind (K4: the same kind within 10 s is one notification)
    last_notified: Mutex<HashMap<&'static str, Instant>>,
}

fn island(app: &AppHandle) -> Option<Arc<Island<Wry>>> {
    app.state::<Hub>().island.lock().unwrap().clone().filter(|i| i.alive())
}

/// Opens the island (from a worker thread: overlay windows must not be created on the main thread).
pub fn init(app: &AppHandle) {
    if std::env::var_os("BLURT_NO_ISLAND").is_some() {
        return;
    }
    let app = app.clone();
    std::thread::spawn(move || match overlay::island(&app, &capture::overlay_config()) {
        Ok(i) => {
            let a2 = app.clone();
            i.on_action(move |v| on_action(&a2, &v));
            *app.state::<Hub>().island.lock().unwrap() = Some(i);
            refresh(&app);
            refresh_cards(&app);
        }
        Err(e) => eprintln!("blurt: no island window: {e}"),
    });
}

pub fn send(app: &AppHandle, op: Value) {
    if let Some(i) = island(app) {
        i.send(op);
    }
}

pub fn rect(app: &AppHandle) -> Option<Region> {
    island(app).map(|i| i.rect())
}

/// Linux has no capture exclusion: while a take covers the top of the screen, the island sits just below it.
pub fn keep_clear_of(app: &AppHandle, region: Option<Region>) {
    if !cfg!(target_os = "linux") {
        return;
    }
    let Some(i) = island(app) else { return };
    let top = i.rect();
    let band = Region::new(top.x, top.y, top.w, 64);
    match region.filter(|r| r.intersect(&band).is_some()) {
        Some(r) => i.place(Some(r.bottom() + 8)),
        None => i.place(None),
    }
}

fn hotkey_labels(app: &AppHandle) -> Value {
    let rows = hotkeys::rows(app);
    let label = |a: &str| rows.iter().find(|r| r["action"] == a).and_then(|r| r["label"].as_str()).unwrap_or("").to_string();
    json!({"record": label("record"), "snap": label("snap"), "voice": label("voice"), "project": label("project")})
}

fn current_step(j: &Value) -> Option<String> {
    let steps = j["steps"].as_array()?;
    steps
        .iter()
        .find(|s| s["state"] == "running")
        .or_else(|| steps.iter().find(|s| s["state"] == "pending"))
        .and_then(|s| s["id"].as_str().map(str::to_owned))
}

/// The island's whole state (web/apps/overlays/src/island.ts `IslandState`).
pub fn state(app: &AppHandle) -> Value {
    let st = app.state::<AppState>();
    let reg = Registry::load();
    let summary = st.index().summary().unwrap_or_else(|_| json!({}));
    let cap = st.capture.state();
    let active = jobs::list(true, 40);
    let short = |p: &Value| json!({"id": p["id"], "name": p["name"], "key": p["key"]});
    let jobs_view: Vec<Value> = active
        .iter()
        .filter(|j| !matches!(j["type"].as_str(), Some("agent" | "record" | "voice")))
        .take(3)
        .map(|j| json!({"id": j["id"], "type": j["type"], "title": j["title"], "step": current_step(j), "progress": j["progress"]}))
        .collect();
    let sessions_view: Vec<Value> = active
        .iter()
        .filter(|j| j["type"] == "agent" && matches!(j.pointer("/agent/status").and_then(Value::as_str), Some("waiting_input" | "turn_done" | "error")))
        .map(|j| json!({"job": j["id"], "agent": j.pointer("/agent/id"), "status": j.pointer("/agent/status"), "items": jobs::window_items(j)}))
        .collect();
    let now = chrono::Utc::now().timestamp_millis() as f64 / 1000.0;
    json!({"op": "state", "state": {
        "project": reg.current_project().map(short),
        "projects": reg.projects.iter().filter(|p| p["path"].as_str().is_some_and(|x| std::path::Path::new(x).is_dir())).map(short).collect::<Vec<_>>(),
        "toReview": summary["to_review"].as_i64().unwrap_or(0),
        "recording": if cap["recording"] == true {
            json!({"elapsed": cap["elapsed"], "paused": cap["paused"], "shots": cap["shots"], "at": now})
        } else { Value::Null },
        "voice": cap["voice"].as_object().map(|v| json!({"elapsed": v["elapsed"], "at": now})),
        "hatching": active.iter().filter(|j| j["type"] == "process").count(),
        "jobs": jobs_view,
        "sessions": sessions_view,
        "hotkeys": hotkey_labels(app),
        "lang": l10n::lang(),
    }})
}

pub fn refresh(app: &AppHandle) {
    if island(app).is_some() {
        send(app, state(app));
    }
    update_tray(app);
}

pub fn refresh_cards(app: &AppHandle) {
    send(app, json!({"op": "cards", "cards": capture::load_cards()}));
}

fn update_tray(app: &AppHandle) {
    let n = app.state::<AppState>().index().summary().ok().and_then(|s| s["to_review"].as_i64()).unwrap_or(0);
    if let Some(t) = app.tray_by_id("main") {
        let tip = if n > 0 { l10n::plural("tray.tooltip.review", n, &[]) } else { l10n::t("tray.tooltip") };
        let _ = t.set_tooltip(Some(tip));
    }
}

fn in_front(app: &AppHandle) -> bool {
    app.get_webview_window("main").and_then(|w| w.is_focused().ok()).unwrap_or(false)
}

fn system_notify(app: &AppHandle, kind: &'static str, title: &str, body: &str) {
    {
        let hub = app.state::<Hub>();
        let mut last = hub.last_notified.lock().unwrap();
        if last.get(kind).is_some_and(|t| t.elapsed() < Duration::from_secs(10)) {
            return;
        }
        last.insert(kind, Instant::now());
    }
    let _ = app.notification().builder().title(title).body(body).silent().show();
}

fn agent_name(id: &str) -> String {
    match id {
        "claude" => "Claude Code".into(),
        "codex" => "Codex".into(),
        "kimi" => "Kimi Code".into(),
        "opencode" => "OpenCode".into(),
        other => other.to_string(),
    }
}

/// K4's reminders for what the jobs watcher saw change.
pub fn notices(app: &AppHandle, list: Vec<Notice>) {
    let cfg = settings::read_config();
    let on = |k: &str| cfg.pointer(&format!("/notify/{k}")).and_then(Value::as_bool).unwrap_or(true);
    let recording = app.state::<AppState>().capture.recording();
    for n in list {
        match n {
            Notice::Sorted { job, title, items, long } => {
                send(app, json!({"op": "toast", "kind": "sorted", "n": items, "job": job}));
                if !recording && !in_front(app) && long && on("done") {
                    let t = title.unwrap_or_else(|| l10n::t("job.type.process"));
                    let body = if items == 0 { l10n::t("notify.sorted.empty") } else { l10n::plural("notify.sorted.body", items as i64, &[]) };
                    system_notify(app, "sorted", &l10n::tf("notify.sorted", &[("title", t)]), &body);
                }
            }
            Notice::Failed { job, kind, code, .. } => {
                if recording {
                    continue; // K4: nothing while recording
                }
                send(app, json!({"op": "toast", "kind": "failed", "code": code, "job": job, "type": kind}));
                if !in_front(app) {
                    let title = l10n::tf("notify.failed", &[("title", l10n::t(&format!("job.type.{kind}")))]);
                    system_notify(app, "failed", &title, &l10n::t(&format!("error.{}", if code == "auth" { "no_agent" } else { "unknown" })));
                }
            }
            Notice::Agent { job, agent, status, items } => {
                send(app, json!({"op": "attention", "job": job, "status": status}));
                if !recording && !in_front(app) && on("agent") && status != "exited" {
                    let key = if status == "waiting_input" { "notify.agent.waiting" } else { "notify.agent.turn_done" };
                    system_notify(app, "agent", &l10n::tf(key, &[("agent", agent_name(&agent))]), &items.join(", "));
                }
            }
        }
    }
    refresh(app);
}

fn session_of(v: &Value) -> Option<PathBuf> {
    v["session"].as_str().map(PathBuf::from).filter(|p| p.starts_with(paths::inbox_store()))
}

/// What the user did in the island.
pub fn on_action(app: &AppHandle, v: &Value) {
    let st = app.state::<AppState>();
    let action = v["action"].as_str().unwrap_or("");
    match action {
        "record" => capture::toggle(app),
        "pause" | "resume" | "stop" | "discard" => {
            if let Some(c) = Control::parse(action) {
                let _ = st.capture.control(c);
            }
        }
        "snap" => capture::snap_with_note(app),
        "voice" => capture::voice_start(app, false),
        "voice.stop" => capture::voice_stop(app, false),
        "voice.cancel" => capture::voice_stop(app, true),
        "keyboard" => {
            if let Some(i) = island(app) {
                i.set_keyboard(v["on"] == true);
            }
        }
        "project.use" => {
            let id = v["id"].as_str().unwrap_or("auto").to_string();
            let (app, runner) = (app.clone(), st.runner());
            std::thread::spawn(move || {
                if let Err(e) = projects::use_project(&runner, &id) {
                    eprintln!("blurt: projects.py use: {e}");
                }
                refresh(&app);
            });
        }
        "project.open" => open_folder(app, true),
        "card.assign" | "card.inbox" => {
            let (Some(session), Some(n)) = (session_of(v), v["n"].as_u64()) else { return };
            let project = if action == "card.inbox" { "inbox".to_string() } else { v["project"].as_str().unwrap_or("inbox").to_string() };
            let app = app.clone();
            std::thread::spawn(move || {
                if let Err(code) = sessions::process(&app, &session, Some(vec![n]), Some(project), Some("user"), None) {
                    send(&app, json!({"op": "toast", "kind": "error", "code": code}));
                }
                refresh_cards(&app);
                refresh(&app);
            });
        }
        "card.ai_sort" => {
            let app = app.clone();
            std::thread::spawn(move || {
                let mut by_session: HashMap<PathBuf, Vec<u64>> = HashMap::new();
                for c in capture::load_cards() {
                    if let Some(s) = c.session.as_ref() {
                        by_session.entry(PathBuf::from(s)).or_default().push(u64::from(c.n));
                    }
                }
                for (s, ns) in by_session {
                    if let Err(code) = sessions::process(&app, &s, Some(ns), None, None, None) {
                        send(&app, json!({"op": "toast", "kind": "error", "code": code}));
                        break;
                    }
                }
                refresh_cards(&app);
                refresh(&app);
            });
        }
        "card.remove" => {
            if let (Some(session), Some(n)) = (session_of(v), v["n"].as_u64()) {
                capture::remove_card(&session, n);
                refresh_cards(app);
            }
        }
        "card.copy" => {
            let Some(session) = session_of(v) else { return };
            let n = v["n"].as_u64().unwrap_or(0) as u32;
            let card = capture::cards_of(&session).into_iter().find(|c| c.n == n);
            if let Some(c) = card {
                let img = c.file.as_ref().and_then(|f| tauri::image::Image::from_path(session.join(f)).ok());
                let _ = match img {
                    Some(i) => app.clipboard().write_image(&i),
                    None => app.clipboard().write_text(c.text.unwrap_or_default()),
                };
            }
        }
        "card.note" => {
            let Some(session) = session_of(v) else { return };
            let n = v["n"].as_u64().unwrap_or(0) as u32;
            let Some(card) = capture::cards_of(&session).into_iter().find(|c| c.n == n) else { return };
            let app = app.clone();
            std::thread::spawn(move || {
                let a2 = app.clone();
                let near = rect(&app).map(|r| Region::new(r.x + r.w as i32 / 2 - 1, r.y + 64, 2, 2));
                let _ = overlay::note(&app, &capture::overlay_config(), &card, near, move |text| {
                    if let Some(t) = text {
                        if let Ok(mut f) = std::fs::OpenOptions::new().append(true).open(session.join("shots.jsonl")) {
                            use std::io::Write;
                            let _ = writeln!(f, "{}", json!({"n": n, "text": t}));
                        }
                        refresh_cards(&a2);
                    }
                });
            });
        }
        "open.inbox" => {
            crate::show_main(app);
            let _ = app.emit("nav", json!({"view": "inbox"}));
        }
        "open.session" => {
            crate::show_main(app);
            let _ = app.emit("nav", json!({"job": v["job"]}));
        }
        "open.main" => crate::show_main(app),
        "log" => {
            if let Some(j) = v["job"].as_str() {
                let _ = app.opener().open_path(paths::jobs_dir().join(format!("{j}.log")).to_string_lossy(), None::<&str>);
            }
        }
        "retry" => {
            let Some(j) = v["job"].as_str().and_then(jobs::load) else { return };
            let Some(session) = j["session"].as_str().map(PathBuf::from) else { return };
            let captures: Option<Vec<u64>> = j["captures"].as_array().map(|a| a.iter().filter_map(Value::as_u64).collect()).filter(|c: &Vec<u64>| !c.is_empty());
            let project = j["project"].as_str().map(str::to_owned);
            let app = app.clone();
            std::thread::spawn(move || {
                let _ = sessions::process(&app, &session, captures, project, None, None);
                refresh(&app);
            });
        }
        _ => {}
    }
}

/// "Open Folder…" (K2): the system folder picker, then `projects.py add`; `make_current` from the switcher.
pub fn open_folder(app: &AppHandle, make_current: bool) {
    let app = app.clone();
    std::thread::spawn(move || {
        let Some(dir) = app.dialog().file().blocking_pick_folder() else { return };
        let Ok(path) = dir.into_path() else { return };
        let runner = app.state::<AppState>().runner();
        match projects::add(&runner, &path.to_string_lossy()) {
            Ok(r) => {
                if let (true, Some(id)) = (make_current, r.pointer("/project/id").and_then(Value::as_str)) {
                    let _ = projects::use_project(&runner, id);
                }
                crate::watcher::refresh(&app);
                let _ = app.emit("projects://changed", json!({}));
            }
            Err(e) => eprintln!("blurt: projects.py add: {e}"),
        }
        refresh(&app);
    });
}
