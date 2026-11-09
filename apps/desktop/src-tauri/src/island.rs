//! The island on Windows / Linux (contract K7): a top-centre floating pill — the same component as the macOS notch
//! island, with lighter motion. It shows the current project, recording / voice / sorting state, the jobs under way
//! and the review count, and holds the unfiled captures as cards under it.
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

#[cfg(windows)]
#[path = "card_drag_win.rs"]
mod card_drag_win;
use crate::jobs::{self, Notice};
use crate::projects::{self, Registry};
use crate::{agents, hotkeys, l10n, paths, settings, AppState};

#[derive(Default)]
pub struct Hub {
    island: Mutex<Option<Arc<Island<Wry>>>>,
    /// the page's "below everything" edge (CSS px): the island's bottom, or the hanging cards' while they are down
    below: Mutex<f64>,
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
            refresh_history(&app);
            collect_system_shots(&app);
            launch_nudge(&app);
        }
        Err(e) => eprintln!("blurt: no island window: {e}"),
    });
}

/// No speech model at launch: the island says so once, after its hello (Mac Dictation.nudge("launch"): about once a
/// day, never while the setup assistant shows; round-2 gate island.idle-no-model) — the same ⚠ line the dictation key
/// gives ("Speech model not installed · Download (950 MB)"), passive, 8 s. At rest the island stays quiet after it.
#[cfg(dict)]
fn launch_nudge(app: &AppHandle) {
    use crate::dictation::commands::READY;
    const EVERY: f64 = 20.0 * 3600.0;
    let app = app.clone();
    std::thread::spawn(move || {
        std::thread::sleep(std::time::Duration::from_millis(4500)); // the hello is 0.5 + 2.8 s
        for _ in 0..60 {
            if READY.lock().unwrap().is_some() {
                break;
            }
            std::thread::sleep(std::time::Duration::from_secs(1));
        }
        let cfg = crate::settings::read_config();
        let on = cfg.pointer("/record/dictation/enabled").and_then(Value::as_bool) != Some(false);
        let last = cfg.pointer("/app/dictation_nudged_at").and_then(Value::as_f64).unwrap_or(0.0);
        let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or(0.0);
        let test = std::env::var_os("BLURT_TEST_EVAL").is_some();
        if *READY.lock().unwrap() != Some(false) || !on || crate::mainwin::welcome_shown() || crate::onboarding::needed() || (!test && now - last < EVERY) {
            return;
        }
        let _ = crate::settings::merge(json!({"app": {"dictation_nudged_at": now}}));
        crate::dictation::engine::say_no_model(&app, "dictation.toast.no_model", 8000);
    });
}

#[cfg(not(dict))]
fn launch_nudge(_: &AppHandle) {}

/// A `record.*` switch of Settings → General → Cards (the Mac's keys, same defaults).
fn record_flag(key: &str, default: bool) -> bool {
    settings::read_config().pointer(&format!("/record/{key}")).and_then(Value::as_bool).unwrap_or(default)
}

/// What a card dragged into another app carries (the Mac's CardDragMode, from its three settings): the note burned in
/// under the picture wins, then "picture, then the note", else the picture alone.
fn card_drag_mode() -> &'static str {
    if record_flag("drag_caption", false) {
        "caption"
    } else if record_flag("smart_paste", true) {
        "paste"
    } else {
        "picture"
    }
}

/// The shutter as a snap is taken (record.snap_sound, off): the island plays it. The snap flow calls this the moment
/// the frame is on disk; a recording's snaps play it from their status line.
pub fn shutter(app: &AppHandle) {
    if record_flag("snap_sound", false) {
        send(app, json!({"op": "shutter"}));
    }
}

/// Where the system keeps the screenshots it takes: Win+Shift+S (Snipping Tool) and Win+PrtScn save to
/// Pictures\Screenshots, as GNOME does on Linux.
fn system_screenshot_folder() -> Option<PathBuf> {
    let pictures = dirs::picture_dir().or_else(|| dirs::home_dir().map(|h| h.join("Pictures")))?;
    Some(pictures.join("Screenshots"))
}

/// Settings → General → "Add Windows screenshots as cards" (record.collect_system_shots, off; the Mac's Snapper
/// collector): every 1.5 s, a picture new in the system's screenshot folder since the switch went on becomes a capture
/// — a card, or filed into the current project as a snap would be. Not while recording. The file stays where it was.
fn collect_system_shots(app: &AppHandle) {
    let app = app.clone();
    std::thread::spawn(move || {
        let mut seen: Option<(PathBuf, std::collections::HashSet<std::ffi::OsString>, std::time::SystemTime)> = None;
        let mut sizes: HashMap<PathBuf, u64> = HashMap::new();
        loop {
            std::thread::sleep(Duration::from_millis(1500));
            let Some(folder) = system_screenshot_folder().filter(|_| record_flag("collect_system_shots", false)) else {
                seen = None;
                continue;
            };
            let names = || std::fs::read_dir(&folder).into_iter().flatten().filter_map(Result::ok).map(|e| e.file_name());
            if seen.as_ref().is_none_or(|(f, ..)| *f != folder) {
                // switched on (or the folder moved): what is there already is old news
                seen = Some((folder.clone(), names().collect(), std::time::SystemTime::now()));
                continue;
            }
            if app.state::<AppState>().capture.recording() {
                continue;
            }
            let (_, known, since) = seen.as_mut().unwrap();
            for name in names().collect::<Vec<_>>() {
                if known.contains(&name) {
                    continue;
                }
                let path = folder.join(&name);
                let ext = path.extension().map(|e| e.to_string_lossy().to_lowercase()).unwrap_or_default();
                let Ok(meta) = std::fs::metadata(&path) else { continue };
                let fresh = meta.modified().is_ok_and(|m| m >= *since);
                if !matches!(ext.as_str(), "png" | "jpg" | "jpeg") || !fresh || name.to_string_lossy().starts_with('.') {
                    known.insert(name);
                    continue;
                }
                // still being written: wait until its size holds for one scan
                if sizes.insert(path.clone(), meta.len()) != Some(meta.len()) || meta.len() == 0 {
                    continue;
                }
                known.insert(name);
                sizes.remove(&path);
                let reg = Registry::load();
                let (project, session) = projects::shots_session(&reg);
                let _ = app.asset_protocol_scope().allow_directory(&session, true);
                if let Some(card) = capture::import_system_shot(&session, project.as_deref(), &path) {
                    capture::captured(&app, &session, project, card);
                }
            }
        }
    });
}

pub fn send(app: &AppHandle, op: Value) {
    if let Some(i) = island(app) {
        i.send(op);
    }
}

/// A picker, a snap's note or a take starting is up: the island steps back (dimmed, no new lines over it; the ones
/// that wait come after) — the Mac's picker covers its island.
pub fn busy(app: &AppHandle, on: bool) {
    send(app, serde_json::json!({"op": "busy", "on": on}));
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
    json!({"record": label("record"), "snap": label("snap"), "voice": label("voice"), "project": label("project"), "pen": label("pen")})
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
    let short = |p: &Value| {
        let exists = p["path"].as_str().is_some_and(|x| std::path::Path::new(x).is_dir());
        json!({"id": p["id"], "name": p["name"], "key": p["key"], "exists": exists})
    };
    let jobs_view: Vec<Value> = active
        .iter()
        .filter(|j| !matches!(j["type"].as_str(), Some("agent" | "record" | "voice")))
        .take(3)
        .map(|j| json!({"id": j["id"], "type": j["type"], "title": j["title"], "step": current_step(j), "progress": j["progress"]}))
        .collect();
    let now = chrono::Utc::now().timestamp_millis() as f64 / 1000.0;
    json!({"op": "state", "state": {
        "project": reg.current_project().map(short),
        // every project, a missing folder's too (said so, dimmed; choosing it asks where it is now: MissingFolder)
        "projects": reg.projects.iter().map(short).collect::<Vec<_>>(),
        "toReview": summary["inbox"].as_i64().unwrap_or(0), // K3 "needs you": new + to verify
        // the 3-2-1 isn't recording yet (the Mac's island takes the take once it rolls: recording.md §3.7)
        "recording": if cap["recording"] == true && cap["countdown"] != true {
            json!({"elapsed": cap["elapsed"], "paused": cap["paused"], "shots": cap["shots"], "pen": cap["pen"], "at": now})
        } else { Value::Null },
        // how it ends (held, at a pause, by the key / Done) for the island's hint; whatever else the voice note says
        // about itself (Structured, its cap) rides along
        "voice": cap["voice"].as_object().map(|v| {
            let mut o = v.clone();
            o.insert("at".into(), json!(now));
            Value::Object(o)
        }),
        "dictation": dictation_state(),
        "hatching": active.iter().filter(|j| j["type"] == "process").count(),
        "jobs": jobs_view,
        "hotkeys": hotkey_labels(app),
        // Settings → General → Cards, as the island needs them (the shutter on a recording's snaps, a drag's caption)
        "cardPrefs": {"snapSound": record_flag("snap_sound", false), "drag": card_drag_mode()},
        "lang": l10n::lang(),
    }})
}

#[cfg(dict)]
fn dictation_state() -> Value {
    crate::dictation::engine::island_state()
}

#[cfg(not(dict))]
fn dictation_state() -> Value {
    Value::Null
}

pub fn refresh(app: &AppHandle) {
    if island(app).is_some() {
        send(app, state(app));
    }
    update_tray(app);
}

pub fn refresh_cards(app: &AppHandle) {
    let cards = capture::load_card_values();
    // the main window's Inbox notice ("3 captures are waiting for a project") follows the count
    let _ = app.emit("cards://changed", json!({"count": cards.len()}));
    send(app, json!({"op": "cards", "cards": cards}));
}

/// How many captures hang waiting for a project (the main window's Inbox notice, the Mac's CapturesBanner).
#[tauri::command]
pub fn cards_waiting() -> usize {
    capture::load_cards().len()
}

/// The notice's "Choose projects…" (the Mac's Island.revealCards): the island opens with every card down; they stay
/// until the pointer has come and gone (or 10 s if it never comes), and each one gets its project there.
#[tauri::command]
pub fn cards_reveal(app: AppHandle) {
    send(&app, json!({"op": "reveal", "open": true}));
}

/// The Cards panel's History: cards used in other apps in the last 7 days.
pub fn refresh_history(app: &AppHandle) {
    send(app, json!({"op": "history", "cards": capture::load_history()}));
}

/// "Show Cards" (the hotkey, the tray): the Cards panel opens with the keyboard — on Current, or on History when
/// nothing hangs — and closes when it is open (the Mac's CardsPanelRules.toggle).
pub fn toggle_cards_panel(app: &AppHandle) {
    refresh_history(app);
    send(app, json!({"op": "panel", "toggle": true}));
}

pub(crate) fn update_tray(app: &AppHandle) {
    let n = app.state::<AppState>().index().summary().ok().and_then(|s| s["inbox"].as_i64()).unwrap_or(0);
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
        }
    }
    refresh(app);
}

fn session_of(v: &Value) -> Option<PathBuf> {
    // the inbox store's batches, or a project's (a snap its note sent to Unassigned hangs from there: capture::load_cards)
    v["session"]
        .as_str()
        .map(PathBuf::from)
        .filter(|p| p.starts_with(paths::inbox_store()) || Registry::load().stores().iter().any(|s| p.starts_with(s)))
}

fn by_session(cards: Vec<(PathBuf, u64)>) -> Vec<(PathBuf, Vec<u64>)> {
    let mut out: Vec<(PathBuf, Vec<u64>)> = Vec::new();
    for (s, n) in cards {
        match out.iter_mut().find(|(x, _)| *x == s) {
            Some((_, ns)) => ns.push(n),
            None => out.push((s, vec![n])),
        }
    }
    out
}

/// Files cards (grouped by batch): into `project` ("inbox": Unassigned) as the user's choice, or — None — organized
/// into Unassigned with a project suggested for each.
fn file_cards(app: &AppHandle, batches: Vec<(PathBuf, Vec<u64>)>, project: Option<String>, by: Option<&'static str>) {
    if batches.is_empty() {
        return;
    }
    // a project chosen: filed at once, no agent (the Mac's Snapper.assign → file: captures.py)
    if let Some(p) = &project {
        for (session, ns) in batches {
            capture::file_now(app, &session, ns, p, by);
        }
        return;
    }
    let app = app.clone();
    std::thread::spawn(move || {
        for (session, ns) in batches {
            if let Err(code) = agents::process(&app, &session, Some(ns), project.clone(), by, None) {
                send(&app, json!({"op": "toast", "kind": "error", "code": code}));
                break;
            }
        }
        refresh_cards(&app);
        refresh(&app);
    });
}

/// A rect of the island page (CSS px) on the screen (physical px).
fn css_to_screen(app: &AppHandle, r: &Value) -> Option<Region> {
    let i = island(app)?;
    let at = i.rect();
    let k = i.window().scale_factor().ok()?;
    let f = |key: &str| r[key].as_f64();
    let (x, y, w, h) = (f("x")?, f("y")?, f("w")?, f("h")?);
    Some(Region::new(at.x + (x * k).round() as i32, at.y + (y * k).round() as i32, (w * k).round().max(1.0) as u32, (h * k).round().max(1.0) as u32))
}

/// A rect on the screen (physical px) in the island page's CSS px — e.g. where a snap was taken, for its card to fly
/// from (the snap flow sends it with the `card` op as `from`). None while there is no island.
pub fn screen_to_css(app: &AppHandle, r: Region) -> Option<Value> {
    let i = island(app)?;
    let at = i.rect();
    let k = i.window().scale_factor().ok()?;
    Some(json!({"x": (r.x - at.x) as f64 / k, "y": (r.y - at.y) as f64 / k, "w": r.w as f64 / k, "h": r.h as f64 / k}))
}

/// Where something that opens under the island goes (a Translate card, a live-text panel of another window): under
/// the island and — while they are down — under the hanging cards, as the page last reported (physical px, screen y).
pub fn below_cards(app: &AppHandle) -> Option<i32> {
    let i = island(app)?;
    let k = i.window().scale_factor().ok()?;
    let css = *app.state::<Hub>().below.lock().unwrap();
    Some(i.rect().y + (css.max(36.0) * k).round() as i32)
}

/// The cards an action names: `cards: [{n, session}]`, else the one `{n, session}`.
fn cards_of_action(v: &Value) -> Vec<(PathBuf, u64)> {
    let one = |c: &Value| Some((session_of(c)?, c["n"].as_u64()?));
    match v["cards"].as_array() {
        Some(list) if !list.is_empty() => list.iter().filter_map(one).collect(),
        _ => one(v).into_iter().collect(),
    }
}

/// The card an action names — hanging or in History.
fn find_card(v: &Value) -> Option<(PathBuf, overlay::Card)> {
    let session = session_of(v)?;
    let n = v["n"].as_u64()? as u32;
    let card = capture::card_lines(&session).into_iter().map(|l| l.card).find(|c| c.n == n)?;
    Some((session, card))
}

/// Several cards on the clipboard as one item, newest first (the Mac's Copy All): their pictures and notes as HTML,
/// the notes alone as the plain text.
fn copy_cards(app: &AppHandle, cards: &[(PathBuf, u64)]) {
    let mut html = String::new();
    let mut text = Vec::new();
    for (session, n) in cards {
        let Some(c) = capture::card_lines(session).into_iter().map(|l| l.card).find(|c| u64::from(c.n) == *n) else { continue };
        if let Some(f) = &c.file {
            let path = crate::paths::normalize(&session.join(f));
            let url = tauri::Url::from_file_path(&path).map(|u| u.to_string()).unwrap_or_default();
            html.push_str(&format!("<p><img src=\"{url}\"></p>"));
        }
        if let Some(t) = c.text.filter(|t| !t.trim().is_empty()) {
            html.push_str(&format!("<p>{}</p>", t.replace('&', "&amp;").replace('<', "&lt;").replace('\n', "<br>")));
            text.push(t);
        }
    }
    let _ = app.clipboard().write_html(html, Some(text.join("\n\n")));
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
        // "Snap discarded · Undo" (Esc in a snap's note)
        "snap.undo" => capture::snap_undo(app),
        // a failed translation's Try Again (Copy Text from Screen)
        #[cfg(windows)]
        "text.retry" => crate::screen_text::flow::retry(app),
        "voice" => capture::voice_start(app, false),
        "voice.stop" => capture::voice_stop(app, false),
        "voice.cancel" => capture::voice_stop(app, true),
        "keyboard" => {
            let on = v["on"] == true;
            // the keyboard is lent to the island (the switcher, the Cards panel, Discard's question) and given back to
            // the window that had it, so Ctrl+V after "copy and close" pastes where the user was
            #[cfg(windows)]
            if on {
                card_drag_win::remember_foreground();
            }
            if let Some(i) = island(app) {
                i.set_keyboard(on);
            }
            #[cfg(windows)]
            if !on {
                card_drag_win::restore_foreground();
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
        "project.locate" => locate(app, v["id"].as_str().unwrap_or(""), v["use"] == true),
        "cards.history" => refresh_history(app),
        "cards.edge" => {
            if let Some(b) = v["bottom"].as_f64() {
                *app.state::<Hub>().below.lock().unwrap() = b;
            }
        }
        // one card or a Ctrl-click selection (`cards`): one run per batch
        "card.assign" | "card.inbox" => {
            let project = if action == "card.inbox" { "inbox".to_string() } else { v["project"].as_str().unwrap_or("inbox").to_string() };
            file_cards(app, by_session(cards_of_action(v)), Some(project), Some("user"));
        }
        "card.ai_sort" => {
            // every card: into the current project when there is one (the Mac's Organize with a project), else into
            // Unassigned with a suggested project each — one agent run for all
            let project = v["project"].as_str().map(str::to_owned);
            let app = app.clone();
            std::thread::spawn(move || {
                let mut by_session: HashMap<PathBuf, Vec<u64>> = HashMap::new();
                for c in capture::load_cards() {
                    if let Some(s) = c.session.as_ref() {
                        by_session.entry(PathBuf::from(s)).or_default().push(u64::from(c.n));
                    }
                }
                for (s, ns) in by_session {
                    if let Err(code) = agents::process(&app, &s, Some(ns), project.clone(), None, None) {
                        send(&app, json!({"op": "toast", "kind": "error", "code": code}));
                        break;
                    }
                }
                refresh_cards(&app);
                refresh(&app);
            });
        }
        // Delete never asks: the island says "Deleted · Undo" for 5 s (the files stay)
        "card.remove" => {
            for (session, n) in cards_of_action(v) {
                capture::remove_card(&session, n);
            }
            refresh_cards(app);
            refresh_history(app);
        }
        "card.restore" => {
            for (session, n) in cards_of_action(v) {
                capture::restore_card(&session, n);
            }
            refresh_cards(app);
            refresh_history(app);
        }
        "card.putback" => {
            for (session, n) in cards_of_action(v) {
                capture::put_back_card(&session, n);
            }
            refresh_cards(app);
            refresh_history(app);
        }
        "card.copy" => {
            let Some((session, c)) = find_card(v) else { return };
            let img = c.file.as_ref().and_then(|f| tauri::image::Image::from_path(session.join(f)).ok());
            let _ = match img {
                Some(i) => app.clipboard().write_image(&i),
                None => app.clipboard().write_text(c.text.unwrap_or_default()),
            };
        }
        "card.copy_text" => {
            if let Some((_, c)) = find_card(v) {
                let _ = app.clipboard().write_text(c.text.unwrap_or_default());
            }
        }
        "card.copy_all" => copy_cards(app, &cards_of_action(v)),
        "card.reveal" => {
            if let Some((session, Some(f))) = find_card(v).map(|(s, c)| (s.clone(), c.file)) {
                let path = crate::paths::normalize(&session.join(f));
                let _ = app.opener().reveal_item_in_dir(path);
            }
        }
        // this card only: into Unassigned with a suggested project (the drop drawer's Organize, the card's menu)
        "card.organize" => file_cards(app, by_session(cards_of_action(v)), None, None),
        // Discard's "Start Over": the take goes, a new one starts on the same area once the old one has stopped
        // (the same area again, no picker: capture.rs `restart`, recording.md §5.4)
        "restart" => {
            let _ = st.capture.restart();
        }
        // Save Video Only (the ··· menu); a take's line buttons: Show in File Explorer, Record Again (recording.md)
        "videoonly" => {
            let _ = st.capture.control(Control::VideoOnly);
        }
        "pen" => capture::toggle_pen(app),
        a if a.starts_with("rec.") => capture::rec_action(app, a),
        // a screenshot card dragged out of the island's zone: Windows' own drag of its file takes over (the Mac's
        // CardDrag). Dropped in another app, the card has been used: it leaves its thread ("taken", its files stay)
        // and its note — which a file drop can't carry — goes on the clipboard; cancelled, it comes back. The page
        // always gets an answer (`dragout`), also when the drag can't start here.
        "card.dragout" => {
            let (n, sess) = (v["n"].clone(), v["session"].clone());
            let answer = move |app: &AppHandle, result: &str| send(app, json!({"op": "dragout", "n": n.clone(), "session": sess.clone(), "result": result}));
            if !drag_out(app, v, answer.clone()) {
                answer(app, "cancel");
            }
        }
        "card.note" => {
            let Some(session) = session_of(v) else { return };
            let n = v["n"].as_u64().unwrap_or(0) as u32;
            if !capture::cards_of(&session).iter().any(|c| c.n == n) {
                return;
            }
            // the full note bubble: the picture with its pen, the words, the type, the place, Record Again
            let app = app.clone();
            // under that card, as the Mac's NoteBubble opens from it (the page's rect, CSS px of the island window)
            let under = v.get("rect").and_then(|r| css_to_screen(&app, r));
            std::thread::spawn(move || capture::edit_note(&app, &session, n, under));
        }
        "open.inbox" => {
            crate::show_main(app);
            let _ = app.emit("nav", json!({"view": "inbox"}));
        }
        "open.job" => {
            crate::show_main(app);
            let _ = app.emit("nav", json!({"job": v["job"]}));
        }
        "open.main" => crate::show_main(app),
        // the launch lines' buttons (housekeeping.rs: Update…, How to Update, Change…, keep the carried-over project)
        a if a.starts_with("app.") => crate::housekeeping::island_action(app, a, v),
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
                let _ = agents::process(&app, &session, captures, project, None, None);
                refresh(&app);
            });
        }
        // dictation's buttons ("Cancelled · Undo", Retry, Copy) and a discarded voice note's Undo / Keep
        #[cfg(dict)]
        a if a.starts_with("dictation.") => crate::dictation::engine::island_action(a),
        #[cfg(dict)]
        a if a.starts_with("voice.undo:") => capture::voice_undo(app, a),
        // the voice note's Structured chip (as Shift double-tapped)
        #[cfg(dict)]
        "voice.structured" => crate::dictation::voice::toggle_structured(),
        _ => {}
    }
}

/// What goes with a card's picture into another app (Settings → General → Cards): the picture itself — or a copy
/// with the note under it, drawn by the island (`caption`, a PNG data URL) — and with record.drag_note_file the note
/// as a small Markdown file. Returns the files, whether the picture carries the note, and whether the .md went too.
#[cfg_attr(not(windows), allow(dead_code))]
fn drag_files(card: &overlay::Card, picture: PathBuf, caption: Option<&str>) -> (Vec<PathBuf>, bool, bool) {
    let note = card.text.clone().filter(|t| !t.trim().is_empty());
    let dir = std::env::temp_dir().join("blurt-drag");
    let _ = std::fs::create_dir_all(&dir);
    let stamp = chrono::Local::now().format("%H%M%S").to_string();
    let zh = l10n::lang().starts_with("zh");
    let mut files = vec![picture];
    let mut captioned = false;
    if let (Some(data), Some(_)) = (caption.and_then(|c| c.strip_prefix("data:image/png;base64,")), note.as_ref()) {
        use base64::Engine as _;
        if let Ok(bytes) = base64::engine::general_purpose::STANDARD.decode(data) {
            let f = dir.join(format!("{}-{stamp}.png", if zh { "截图" } else { "Screenshot" }));
            if std::fs::write(&f, bytes).is_ok() {
                files[0] = f;
                captioned = true;
            }
        }
    }
    let mut note_file = false;
    if let (true, Some(t)) = (record_flag("drag_note_file", false), note.as_ref()) {
        let f = dir.join(if zh { format!("截图-{stamp}-备注.md") } else { format!("Screenshot-{stamp}-note.md") });
        if std::fs::write(&f, t).is_ok() {
            files.push(f);
            note_file = true;
        }
    }
    (files, captioned, note_file)
}

/// Starts the system's drag of a card (our own OLE drag, card_drag_win.rs): a snap's picture as a file (with the
/// .md, or the captioned copy, per Settings → General → Cards), a voice card's words as text; the drag image is the
/// card as the island drew it (`image`, a PNG data URL; `ox`/`oy` where the pointer holds it, physical px). False when
/// it can't start (not Windows, nothing to drag).
#[cfg(windows)]
fn drag_out(app: &AppHandle, v: &Value, answer: impl Fn(&AppHandle, &str) + Clone + Send + 'static) -> bool {
    use card_drag_win::Payload;
    let Some((session, card)) = find_card(v) else { return false };
    let mode = card_drag_mode();
    let (payload, captioned, note_file) = match card.file.clone() {
        Some(file) => {
            let path = crate::paths::normalize(&session.join(file));
            if !path.is_file() {
                return false;
            }
            let (files, captioned, note_file) = drag_files(&card, path, v["caption"].as_str().filter(|_| mode == "caption"));
            (Payload::Files(files), captioned, note_file)
        }
        // a voice card is its words (not ready yet: it stays, as on the Mac)
        None => match card.text.as_deref().map(card_drag_win::drag_text).filter(|t| !t.is_empty()) {
            Some(t) => (Payload::Text(t), true, false),
            None => return false,
        },
    };
    let voice = matches!(payload, Payload::Text(_));
    let image = v["image"].as_str().and_then(|d| d.strip_prefix("data:image/png;base64,")).and_then(|d| {
        use base64::Engine as _;
        base64::engine::general_purpose::STANDARD.decode(d).ok()
    });
    let offset = (v["ox"].as_f64().unwrap_or(0.0) as i32, v["oy"].as_f64().unwrap_or(0.0) as i32);
    let (app2, n) = (app.clone(), u64::from(card.n));
    let _ = app.run_on_main_thread(move || {
        // click-through for the whole drag: the island (as big as the work area) must not be the window under the
        // pointer that the system asks to take the drop (it took all of the mouse while the card was dragged inside)
        if let Some(i) = island(&app2) {
            let _ = i.window().set_ignore_cursor_events(true);
        }
        if !card_drag_win::drag(&payload, image.as_deref(), offset) {
            return answer(&app2, "cancel");
        }
        // taken: it leaves its thread (its files stay, History keeps it 7 days)
        capture::take_card(&session, n);
        // a note that couldn't go in goes on the clipboard (record.drag_copy_note, on; never with picture only): a file
        // drop can't paste it after the picture here
        let note = card.text.clone().filter(|t| !t.trim().is_empty());
        let copy = !voice && note.is_some() && !captioned && mode != "picture" && record_flag("drag_copy_note", true);
        if let (true, Some(t)) = (copy, &note) {
            let _ = app2.clipboard().write_text(t.clone());
        }
        let what = match (voice, captioned, note_file, copy) {
            (true, ..) => "words",
            (_, true, ..) => "text",
            (_, _, true, true) => "files_note",
            (_, _, true, false) => "files",
            (_, _, _, true) => "note",
            _ => "picture",
        };
        answer(&app2, "dropped");
        send(&app2, json!({"op": "toast", "kind": "taken", "what": what, "cards": [{"n": n, "session": session.to_string_lossy()}]}));
        refresh_cards(&app2);
        refresh_history(&app2);
    });
    true
}

#[cfg(not(windows))]
fn drag_out(_: &AppHandle, _: &Value, _: impl Fn(&AppHandle, &str) + Clone + Send + 'static) -> bool {
    false
}

/// Locate… (the Mac's MissingFolder.locate): where is the folder of project `id` now? Only a folder holding this
/// project's own store (`.blurt/store.json` naming it) is taken — `projects.py add` then reconnects it, so its id, key
/// and items stay; any other folder is refused. Found, it stays current if it was (`make_current`: the switcher's
/// choice, it becomes current), and its cards kept back meanwhile stay cards to file by hand.
fn locate(app: &AppHandle, id: &str, make_current: bool) {
    let reg = Registry::load();
    let Some(p) = reg.project(id).cloned() else { return };
    let (id, name) = (id.to_string(), p["name"].as_str().unwrap_or("").to_string());
    let was_current = reg.current.as_deref() == Some(id.as_str());
    let app = app.clone();
    std::thread::spawn(move || {
        // start where it was: the nearest folder of its old path that is still there
        let mut start = p["path"].as_str().map(PathBuf::from);
        while let Some(d) = start.clone() {
            if d.is_dir() {
                break;
            }
            start = d.parent().map(PathBuf::from);
        }
        let mut dialog = folder_dialog(&app).set_title(l10n::tf("island.locate.message", &[("name", name.clone())]));
        if let Some(d) = start {
            dialog = dialog.set_directory(d);
        }
        let Some(dir) = dialog.blocking_pick_folder() else { return };
        let Ok(path) = dir.into_path() else { return };
        let store = std::fs::read_to_string(path.join(".blurt").join("store.json")).ok().and_then(|s| serde_json::from_str::<Value>(&s).ok());
        if store.as_ref().and_then(|s| s["project"].as_str()) != Some(id.as_str()) {
            send(&app, json!({"op": "toast", "kind": "line", "msg": "island.locate.not_this", "vars": {"name": name}, "mark": "warning"}));
            return;
        }
        let runner = app.state::<AppState>().runner();
        match projects::add(&runner, &path.to_string_lossy()) {
            Ok(r) => {
                let found = r.pointer("/project/id").and_then(Value::as_str).unwrap_or(&id).to_string();
                if was_current || make_current {
                    let _ = projects::use_project(&runner, &found);
                }
                crate::watcher::refresh(&app);
                let _ = app.emit("projects://changed", json!({}));
                send(&app, json!({"op": "toast", "kind": "line", "msg": "island.locate.found", "vars": {"name": name}, "mark": "check"}));
            }
            Err(e) => {
                eprintln!("blurt: projects.py add (locate): {e}");
                send(&app, json!({"op": "toast", "kind": "line", "msg": "island.locate.failed", "mark": "warning"}));
            }
        }
        refresh(&app);
    });
}

/// The folder picker, over the main window when it shows (centred on it, owned by it) — else on its own, where the
/// system puts it.
pub fn folder_dialog(app: &AppHandle) -> tauri_plugin_dialog::FileDialogBuilder<tauri::Wry> {
    let d = app.dialog().file();
    match app.get_webview_window("main").filter(|w| w.is_visible().unwrap_or(false) && !w.is_minimized().unwrap_or(false)) {
        Some(w) => d.set_parent(&w),
        None => d,
    }
}

/// "Open Folder…" (K2): the system folder picker, then `projects.py add`; `make_current` from the switcher.
pub fn open_folder(app: &AppHandle, make_current: bool) {
    let app = app.clone();
    std::thread::spawn(move || {
        let Some(dir) = folder_dialog(&app).blocking_pick_folder() else { return };
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
