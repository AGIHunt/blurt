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

#[path = "card_drop.rs"]
mod card_drop;
#[cfg(windows)]
#[path = "card_drag_win.rs"]
mod card_drag_win;
#[path = "drop_in.rs"]
pub(crate) mod drop_in;
#[cfg(windows)]
#[path = "island_drop_win.rs"]
mod island_drop_win;
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
            // drops from other apps come in through a small window of their own over the notch (drag-drop.md §3)
            #[cfg(windows)]
            island_drop_win::start(&app);
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

/// Settings → General → "Show the island when idle" (`app.island_idle`, the Mac's key). Off by default here, unlike the
/// Mac: the top of a Windows or GNOME screen is the apps' own (a maximized browser's tabs), not a menu bar, so a
/// resting pill there gets clicked by mistake. Off: what stands at rest (the cards' count, Peep thinking over an
/// organize) stays hidden and the top edge brings nothing out; the live things (a recording, dictation, a voice note,
/// a done moment, a toast) still show. The cards stay a click away in the tray's Show Cards and the main window.
pub fn shows_at_rest() -> bool {
    settings::read_config().pointer("/app/island_idle").and_then(Value::as_bool).unwrap_or(false)
}

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

/// Settings → Agents → Dragging Cards → Edit…: the sheet's rows, `[{id, name, ids, drop, on, custom}]` — every agent
/// whose app gets the picture's path and the note (card_drop::drop_rows: agents.json's and the user's own).
fn agent_rows(cfg: &Value) -> Value {
    let rows = card_drop::drop_rows(&card_drop::registry(), cfg.get("record"), card_drop::OS);
    json!(rows
        .into_iter()
        .map(|r| json!({"id": r.agent, "name": r.name, "ids": r.ids, "drop": r.drop, "on": r.on, "custom": r.custom}))
        .collect::<Vec<_>>())
}

#[tauri::command]
pub fn agent_apps_get() -> Value {
    agent_rows(&settings::read_config())
}

/// `op`: "on" / "off" (an agent switched: record.agent_drop), "add" (`id` = a program's stem: a custom agent), "remove"
/// (a custom agent). A v1.0.21 record.agent_apps moves over first (card_drop::migrate) → the sheet's rows.
#[tauri::command]
pub fn agent_apps_set(id: String, on: Option<bool>, op: Option<String>) -> Result<Value, String> {
    let reg = card_drop::registry();
    let op = op.unwrap_or_else(|| if on == Some(false) { "off".into() } else { "on".into() });
    let cfg = settings::update(|cfg| {
        if !cfg.is_object() {
            *cfg = json!({});
        }
        let rec = cfg.as_object_mut().unwrap().entry("record").or_insert_with(|| json!({}));
        if !rec.is_object() {
            *rec = json!({});
        }
        let rec = rec.as_object_mut().unwrap();
        match op.as_str() {
            "add" => {
                card_drop::add_program(rec, &reg, &id);
            }
            "remove" => {
                card_drop::migrate(rec, &reg, card_drop::OS); // a v1.0.21 addition is a custom agent from here on
                card_drop::remove_custom(rec, &id);
            }
            "off" => card_drop::set_on(rec, &reg, &id, false),
            _ => card_drop::set_on(rec, &reg, &id, true),
        }
    })?;
    Ok(agent_rows(&cfg))
}

/// Add Program…: the system's Open dialog for programs (.exe; a shortcut is followed to its program by the dialog)
/// → `{ids: [stem…]}` (card_drop::program_id), or `{cancel: true}`. The caller adds them (agent_apps_set "add").
#[tauri::command(async)]
pub fn agent_apps_pick(app: AppHandle, title: String) -> Value {
    let mut d = folder_dialog(&app).set_title(title).add_filter("Programs", &["exe", "lnk"]);
    // where per-user installs go (Cursor, Trae, Kiro, Windsurf…: %LOCALAPPDATA%\Programs)
    if let Some(dir) = dirs::data_local_dir().map(|d| d.join("Programs")).filter(|d| d.is_dir()) {
        d = d.set_directory(dir);
    }
    let Some(picked) = d.blocking_pick_files() else { return json!({"cancel": true}) };
    let mut ids: Vec<String> = picked.into_iter().filter_map(|f| f.into_path().ok()).filter_map(|p| card_drop::program_id(&p)).collect();
    ids.dedup();
    if ids.is_empty() {
        return json!({"cancel": true});
    }
    json!({"ids": ids})
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

/// No capture exclusion (Linux; Windows before 2004, blurt_capture::winver): while a take covers the top of the
/// screen, the island sits just below it.
pub fn keep_clear_of(app: &AppHandle, region: Option<Region>) {
    if blurt_capture::winver::capture_exclusion() {
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
    // capabilities.rs: with Recording off there are no items, jobs or projects here (no counts, no chip, no switcher)
    let off = crate::capabilities::off_now();
    let recording_on = !off.contains(&crate::capabilities::Capability::Recording);
    let active = if recording_on { jobs::list(true, 40) } else { vec![] };
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
        "project": if recording_on { reg.current_project().map(short) } else { None },
        // every project, a missing folder's too (said so, dimmed; choosing it asks where it is now: MissingFolder)
        "projects": if recording_on { reg.projects.iter().map(short).collect::<Vec<_>>() } else { vec![] },
        "toReview": if recording_on { summary["inbox"].as_i64().unwrap_or(0) } else { 0 }, // K3 "needs you": new + to verify
        // the capabilities that are off: their buttons and hints don't show
        "off": crate::capabilities::ids(&off),
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
        "idle": shows_at_rest(),
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
    if let Some(i) = island(app) {
        i.set_peek(shows_at_rest());
        send(app, state(app));
    }
    update_tray(app);
    crate::remote::dictation_changed(); // Blurt on the phone: dictation's phase, when it changed
}

pub fn refresh_cards(app: &AppHandle) {
    // Cards off (capabilities.rs): none show anywhere, and the main window's counts say none
    let cards = if crate::capabilities::on_now(crate::capabilities::Capability::Cards) { capture::load_card_values() } else { vec![] };
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
                    system_notify(app, "failed", &title, &l10n::t(&format!("error.{}", if code == "auth" || code == "no_agent" { "no_agent" } else { "unknown" })));
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

/// Hanging cards dropped on Blurt's main window (drag-drop.md §4), filed into `project` ("inbox": Unassigned) as the
/// user's choice — the sidebar's project row, or the list of a project: the same as dropping them on the island's
/// project row. `cards`: `[{session, n}]`.
pub fn cards_into_project(app: &AppHandle, cards: &[Value], project: &str) {
    let refs: Vec<(PathBuf, u64)> = cards.iter().flat_map(cards_of_action).collect();
    if refs.is_empty() {
        return refresh_cards(app);
    }
    file_cards(app, by_session(refs), Some(project.to_string()), Some("user"));
    refresh_cards(app);
}

/// Hanging cards dropped on an item of the main window's list: added to it (`items.py attach`: each card's picture
/// as a frame — copied — its note after the item's details), then the cards are taken (they leave their thread,
/// History keeps them). Returns the attach's result ({before, added}: the Undo restores `before` and puts the cards
/// back, `cards_put_back`).
pub fn cards_into_item(app: &AppHandle, runner: &crate::scripts::Runner, cards: &[Value], uid: &str) -> Result<Value, String> {
    let refs: Vec<(PathBuf, u64)> = cards.iter().flat_map(cards_of_action).collect();
    let mut frames = Vec::new();
    let mut files = Vec::new();
    let mut notes = Vec::new();
    for (session, n) in &refs {
        let Some(c) = capture::card_lines(session).into_iter().map(|l| l.card).find(|c| u64::from(c.n) == *n) else { continue };
        // a file card adds its file (the item's attachments), never its face
        match (handed(session, &c), c.reference.is_some()) {
            (Some(f), true) => files.push(f.to_string_lossy().into_owned()),
            (Some(f), false) => frames.push(f.to_string_lossy().into_owned()),
            _ => {}
        }
        if let Some(t) = card_drop::clean(c.text.as_deref()) {
            notes.push(t);
        }
    }
    let text = (!notes.is_empty()).then(|| notes.join("\n\n"));
    let r = crate::items::attach(runner, uid, &frames, &files, text.as_deref(), None);
    if r.is_ok() {
        for (session, n) in &refs {
            capture::take_card(session, *n);
        }
    }
    refresh_cards(app);
    refresh_history(app);
    r
}

/// Undo of `cards_into_item`: the cards hang again.
pub fn cards_put_back(app: &AppHandle, cards: &[Value]) {
    for (session, n) in cards.iter().flat_map(cards_of_action) {
        capture::put_back_card(&session, n);
    }
    refresh_cards(app);
    refresh_history(app);
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

/// What a card hands over (a drag, a copy's path line, Show in File Explorer, added to an item): a file card's own file
/// (shots.jsonl "ref" — never moved: drags are copies only), else its picture. None: a voice or text card, or a file
/// that is gone.
fn handed(session: &std::path::Path, c: &overlay::Card) -> Option<PathBuf> {
    match &c.reference {
        Some(r) => Some(PathBuf::from(r)).filter(|p| p.exists()),
        None => c.file.as_ref().map(|f| crate::paths::normalize(&session.join(f))).filter(|p| p.is_file()),
    }
}

/// Several cards on the clipboard as one item, in the order given (Copy All: newest first, as the row; a selection:
/// the order picked): their pictures and notes as HTML; the plain text — what a terminal pastes, Windows having no
/// smart paste — is a `"<path>" <note>` line per card when any has a picture (card_drop::copy_text, the Mac's
/// CardTransfer.terminalLines: Claude Code or Codex read each picture from its path, next to its own words), else
/// the notes.
fn copy_cards(app: &AppHandle, cards: &[(PathBuf, u64)]) {
    let mut html = String::new();
    let mut text = Vec::new();
    let mut lines = Vec::new();
    for (session, n) in cards {
        let Some(c) = capture::card_lines(session).into_iter().map(|l| l.card).find(|c| u64::from(c.n) == *n) else { continue };
        let face = c.file.as_ref().map(|f| crate::paths::normalize(&session.join(f)));
        if let Some(path) = &face {
            let url = tauri::Url::from_file_path(path).map(|u| u.to_string()).unwrap_or_default();
            html.push_str(&format!("<p><img src=\"{url}\"></p>"));
        }
        lines.push(card_drop::DragCard { file: handed(session, &c).or(face), note: c.text.clone() });
        if let Some(t) = c.text.filter(|t| !t.trim().is_empty()) {
            html.push_str(&format!("<p>{}</p>", t.replace('&', "&amp;").replace('<', "&lt;").replace('\n', "<br>")));
            text.push(t);
        }
    }
    let plain = card_drop::copy_text(&lines).unwrap_or_else(|| text.join("\n\n"));
    let _ = app.clipboard().write_html(html, Some(plain));
}

/// What the user did in the island.
pub fn on_action(app: &AppHandle, v: &Value) {
    let st = app.state::<AppState>();
    let action = v["action"].as_str().unwrap_or("");
    // the island's own capture buttons and switcher follow the capabilities as the keys do
    let gate = match action {
        "voice" => Some("voice"),
        "project.use" | "project.open" | "project.locate" => Some("project"),
        a @ ("record" | "snap") => Some(a),
        _ => None,
    };
    if gate.is_some_and(|a| !crate::capabilities::allows(a, &crate::capabilities::off_now(), st.capture.recording())) {
        return;
    }
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
        #[cfg(any(windows, target_os = "linux"))]
        "text.retry" => crate::screen_text::flow::retry(app),
        // Linux: GNOME asks about screenshots only with Blurt in front — Settings → Copy Text from Screen asks
        "text.allow" => {
            crate::show_main(app);
            let _ = app.emit("nav", json!({"view": "settings", "pane": "screentext/screentext.allow"}));
        }
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
        // the cards came down: a file card's file may have moved or gone since (its "Original file not found")
        "cards.check" => refresh_cards(app),
        // where the notch (and the open drawer) is, for the drop catcher; the drawer's row under another app's drag
        "drop.zone" => drop_in::zone_reported(app, v),
        "ext.row" => drop_in::row_reported(v),
        // Linux: the island page took another app's drop itself (WebKitGTK over what the island draws; island.ts
        // `linuxDrop`): what it read, and the drawer's row it was let go on
        "ext.drop" => {
            let d: drop_in::PageDrop = serde_json::from_value(v.clone()).unwrap_or_default();
            let landing = drop_in::landing(d.row.as_deref());
            let read = drop_in::page_drop(&d, |p| p.is_dir(), |p| std::fs::read_to_string(p).ok());
            crate::draglog::log(json!({"event": "drop_external", "via": "page", "row": d.row, "what": read.summary(),
                "taken": landing != drop_in::Landing::Refuse && !read.is_empty()}));
            let project = match landing {
                drop_in::Landing::Refuse => return,
                drop_in::Landing::Hang => None,
                drop_in::Landing::Project(p) => Some(p),
            };
            if read.is_empty() {
                return send(app, json!({"op": "toast", "kind": "line", "msg": "island.drop.nothing", "mark": "warning"}));
            }
            let app = app.clone();
            std::thread::spawn(move || {
                // no codecs or thumbnails of the system's here: png / jpg pictures as they are, others as file cards; a
                // file card's face is the plain sheet (the page writes the file's name on it)
                let faces = drop_in::Faces { decode: &|_| None, face: &|_| None, temporary: &drop_in::is_temporary };
                drop_in::hang(&app, &read, project, &faces);
            });
        }
        // the page's own drag events worth keeping (Linux: the island's drop, entered / left), never their words
        "ext.log" => crate::draglog::log(v.get("log").cloned().unwrap_or(Value::Null)),
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
            // a file card: its file's path (and the note), as a terminal or an agent reads it — the face is no picture
            if let Some(r) = &c.reference {
                let _ = app.clipboard().write_text(card_drop::terminal_line(std::path::Path::new(r), c.text.as_deref()));
                return;
            }
            let img = c.file.as_ref().and_then(|f| tauri::image::Image::from_path(session.join(f)).ok());
            let _ = match img {
                Some(i) => {
                    let r = app.clipboard().write_image(&i);
                    // the main window's Ctrl+V never pastes this back as a new picture (drag-drop.md §0.6)
                    drop_in::mark_ours(clipboard_seq(), (i.width(), i.height()));
                    r
                }
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
            if let Some(path) = find_card(v).and_then(|(s, c)| handed(&s, &c)) {
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
            let (n, sess, cards) = (v["n"].clone(), v["session"].clone(), v["cards"].clone());
            let answer = move |app: &AppHandle, result: &str| {
                send(app, json!({"op": "dragout", "n": n.clone(), "session": sess.clone(), "cards": cards.clone(), "result": result}))
            };
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
            // offered after a drop (`passive`): it opens without the keyboard and folds away untouched (note.ts)
            let passive = v["passive"] == true;
            // never over a note that is up (a snap's, another card's): an offer only replaces nothing
            if passive && app.get_webview_window(overlay::Kind::Note.label()).is_some() {
                return;
            }
            if passive {
                crate::draglog::log(json!({"event": "note_offer", "n": n}));
            }
            std::thread::spawn(move || capture::edit_note(&app, &session, n, under, passive));
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
                if let Err(code) = agents::process(&app, &session, captures, project, None, None) {
                    send(&app, json!({"op": "toast", "kind": "error", "code": if code == "no_agent" { "no_agent" } else { "unknown" }}));
                }
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
/// The copy and the .md are written next to the session, `<session>/out/<NNN>/` (card_drop::out_dir, as on the Mac):
/// an app or an agent may read them long after the drop (so an earlier drag's files stay too); housekeeping trashes
/// the folder with the card. Named by when the picture was taken ("截图-153012").
#[cfg_attr(not(windows), allow(dead_code))]
fn drag_files(session: &std::path::Path, card: &overlay::Card, picture: PathBuf, caption: Option<&str>) -> (Vec<PathBuf>, bool, bool) {
    let note = card.text.clone().filter(|t| !t.trim().is_empty());
    let dir = card_drop::out_dir(session, card.n);
    let taken = std::fs::metadata(&picture).and_then(|m| m.modified()).map(chrono::DateTime::<chrono::Local>::from).unwrap_or_else(|_| chrono::Local::now());
    let stamp = taken.format("%H%M%S").to_string();
    let zh = l10n::lang().starts_with("zh");
    let mut files = vec![picture];
    let mut captioned = false;
    if let (Some(data), Some(_)) = (caption.and_then(|c| c.strip_prefix("data:image/png;base64,")), note.as_ref()) {
        use base64::Engine as _;
        if let Ok(bytes) = base64::engine::general_purpose::STANDARD.decode(data) {
            let f = dir.join(format!("{}.png", card_drop::stem(zh, &stamp)));
            if std::fs::create_dir_all(&dir).is_ok() && std::fs::write(&f, bytes).is_ok() {
                files[0] = f;
                captioned = true;
            }
        }
    }
    let mut note_file = false;
    if let (true, Some(t)) = (record_flag("drag_note_file", false), note.as_ref()) {
        let f = dir.join(card_drop::note_name(zh, &stamp));
        if std::fs::create_dir_all(&dir).is_ok() && std::fs::write(&f, t).is_ok() {
            files.push(f);
            note_file = true;
        }
    }
    (files, captioned, note_file)
}

/// The cards a drag carries, while it is under way (Windows' own drag of island cards): Blurt's main window asks
/// (`cards_dragging`) as a drag of files enters it, so it can say what a drop will do before the drop tells it.
static DRAGGING: std::sync::Mutex<Option<Value>> = std::sync::Mutex::new(None);

/// The cards of the drag under way (`[{session, n}]`), if it is one of ours.
pub fn dragging_cards() -> Option<Value> {
    DRAGGING.lock().unwrap().clone()
}

/// Starts the system's drag of a card — or of the selection it is part of (`cards`, in the order picked) — with our
/// own OLE drag (card_drag_win.rs): pictures as files (one card: with the .md, or the captioned copy, per Settings →
/// General → Cards) — over a terminal or an agent app text instead, each picture's path then its note
/// (card_drop::terminal_text) — and voice cards' words as text; the drag image is the card as the island drew it
/// (`image`, a PNG data URL; `ox`/`oy` where the pointer holds it, physical px). Every drag carries which cards it
/// is, for Blurt's own main window. False when it can't start (not Windows, nothing to drag).
#[cfg(windows)]
fn drag_out(app: &AppHandle, v: &Value, answer: impl Fn(&AppHandle, &str) + Clone + Send + 'static) -> bool {
    use card_drag_win::{Landed, Lines, Payload};
    // the cards in the drag's order: the selection's (the order picked), else the one grabbed
    let cards: Vec<(PathBuf, overlay::Card)> = cards_of_action(v)
        .into_iter()
        .filter_map(|(s, n)| {
            let c = capture::card_lines(&s).into_iter().map(|l| l.card).find(|c| u64::from(c.n) == n)?;
            Some((s, c))
        })
        .collect();
    let Some((session, card)) = cards.first().cloned() else { return false };
    let several = cards.len() > 1;
    let mode = card_drag_mode();
    let picked: Vec<card_drop::DragCard> = cards
        .iter()
        .map(|(s, c)| card_drop::DragCard { file: handed(s, c), note: c.text.clone() })
        .collect();
    let (payload, captioned, note_file) = if several {
        // several: every picture; a terminal one line, an agent's composer a line per card; no .md, no caption
        let files: Vec<PathBuf> = picked.iter().filter_map(|c| c.file.clone()).collect();
        let terminal = card_drop::terminal_text(&picked, false).zip(card_drop::terminal_text(&picked, true)).map(|(line, lines)| Lines { line, lines });
        match (files.is_empty(), terminal) {
            (false, terminal) => (Payload::Files { files, terminal }, false, false),
            // only voice cards: their words, a line each (one line at a shell prompt)
            (true, Some(t)) => (Payload::Text { text: t.lines.clone(), terminal: Some(t) }, true, false),
            (true, None) => return false,
        }
    } else {
        match picked[0].file.clone() {
            // a file card: the file itself (never moved: the drag only offers a copy), its path and note to a terminal
            Some(path) if card.reference.is_some() => {
                let line = card_drop::terminal_line(&path, card.text.as_deref());
                (Payload::Files { files: vec![path], terminal: Some(Lines { line: line.clone(), lines: line }) }, false, false)
            }
            Some(path) => {
                let (files, captioned, note_file) = drag_files(&session, &card, path, v["caption"].as_str().filter(|_| mode == "caption"));
                // a terminal: the picture's path (the captioned copy when there is one) and the note, paired on one line
                let line = card_drop::terminal_line(&files[0], card.text.as_deref());
                (Payload::Files { files, terminal: Some(Lines { line: line.clone(), lines: line }) }, captioned, note_file)
            }
            // a voice card is its words (not ready yet: it stays, as on the Mac)
            None if card.file.is_some() => return false,
            None => match card.text.as_deref().map(card_drop::one_line).filter(|t| !t.is_empty()) {
                Some(t) => (Payload::Text { text: t, terminal: None }, true, false),
                None => return false,
            },
        }
    };
    let voice = matches!(payload, Payload::Text { .. });
    let refs: Vec<(String, u64)> = cards.iter().map(|(s, c)| (s.to_string_lossy().into_owned(), u64::from(c.n))).collect();
    let cards_json = card_drop::cards_json(&refs);
    let image = v["image"].as_str().and_then(|d| d.strip_prefix("data:image/png;base64,")).and_then(|d| {
        use base64::Engine as _;
        base64::engine::general_purpose::STANDARD.decode(d).ok()
    });
    let offset = (v["ox"].as_f64().unwrap_or(0.0) as i32, v["oy"].as_f64().unwrap_or(0.0) as i32);
    let app2 = app.clone();
    let _ = app.run_on_main_thread(move || {
        // click-through for the whole drag: the island (as big as the work area) must not be the window under the
        // pointer that the system asks to take the drop (it took all of the mouse while the card was dragged inside)
        if let Some(i) = island(&app2) {
            let _ = i.window().set_ignore_cursor_events(true);
        }
        let list: Value = serde_json::from_str(&cards_json).unwrap_or_default();
        *DRAGGING.lock().unwrap() = Some(list.clone());
        let dropped = card_drag_win::drag(&payload, Some(&cards_json), image.as_deref(), offset);
        *DRAGGING.lock().unwrap() = None;
        let Some(dropped) = dropped else {
            return answer(&app2, "cancel");
        };
        // Blurt's main window took them: it read which cards they are and files them, or adds them to an item
        // (`cards_into`), and refreshes the cards when done — nothing is taken or copied here
        if dropped.landed == Landed::Ours {
            answer(&app2, "dropped");
            let app3 = app2.clone();
            // in case the page never got as far as filing them: what still hangs comes back
            std::thread::spawn(move || {
                std::thread::sleep(std::time::Duration::from_secs(10));
                refresh_cards(&app3);
            });
            return;
        }
        // a terminal (or an agent app) got the pictures' paths and the notes as text: nothing more to do
        let terminal = dropped.landed == Landed::Terminal;
        // a note that couldn't go in goes on the clipboard (record.drag_copy_note, on; never with picture only): a file
        // drop can't paste it after the picture here. Several cards: the notes numbered by file (follow_up_notes).
        let note = if several { card_drop::follow_up_notes(&picked) } else { card.text.clone().filter(|t| !t.trim().is_empty()) };
        let copy = !voice && !terminal && note.is_some() && !captioned && mode != "picture" && record_flag("drag_copy_note", true);
        if let (true, Some(t)) = (copy, &note) {
            let _ = app2.clipboard().write_text(t.clone());
        }
        // Alt held as it was let go: a copy drag — the cards stay on their thread (the same group can go to a second
        // agent)
        if dropped.alt {
            return answer(&app2, "cancel");
        }
        // taken: they leave their thread together (their files stay, History keeps them 7 days); one Undo puts back all
        for (s, n) in &refs {
            capture::take_card(std::path::Path::new(s), *n);
        }
        let what = match (voice, captioned, note_file, copy) {
            _ if several && terminal => "paths",
            _ if several => if copy { "note" } else { "picture" },
            (true, ..) => "words",
            _ if terminal => if note.is_some() { "paths" } else { "picture" },
            (_, true, ..) => "text",
            (_, _, true, true) => "files_note",
            (_, _, true, false) => "files",
            (_, _, _, true) => "note",
            _ => "picture",
        };
        answer(&app2, "dropped");
        send(&app2, json!({"op": "toast", "kind": "taken", "what": what, "cards": list}));
        refresh_cards(&app2);
        refresh_history(&app2);
    });
    true
}

/// Linux: the cards' files as GTK's own drag (blurt_capture::linux_dnd, X11 DnD that mutter carries on to Wayland
/// apps): `text/uri-list` and their `'path' note` line, whichever the target takes. GTK doesn't say which app it is,
/// so there is no per-app payload: the notes go on the clipboard after a drop (record.drag_copy_note, as for Windows'
/// chat apps), unless it was a text-only drag. Dropped on Blurt's main window: that window files them (it read
/// which cards they are from `dragging_cards`).
#[cfg(target_os = "linux")]
fn drag_out(app: &AppHandle, v: &Value, answer: impl Fn(&AppHandle, &str) + Clone + Send + 'static) -> bool {
    use blurt_capture::linux_dnd;
    let cards: Vec<(PathBuf, overlay::Card)> = cards_of_action(v)
        .into_iter()
        .filter_map(|(s, n)| {
            let c = capture::card_lines(&s).into_iter().map(|l| l.card).find(|c| u64::from(c.n) == n)?;
            Some((s, c))
        })
        .collect();
    let Some((_, first)) = cards.first().cloned() else { return false };
    let several = cards.len() > 1;
    let picked: Vec<card_drop::DragCard> = cards.iter().map(|(s, c)| card_drop::DragCard { file: handed(s, c), note: c.text.clone() }).collect();
    let files: Vec<PathBuf> = picked.iter().filter_map(|c| c.file.clone()).collect();
    let text = card_drop::terminal_text(&picked, false)
        .or_else(|| first.text.as_deref().map(card_drop::one_line).filter(|t| !t.is_empty()))
        .unwrap_or_default();
    if files.is_empty() && text.is_empty() {
        return false;
    }
    let Some(isl) = island(app) else { return false };
    let note = if several { card_drop::follow_up_notes(&picked) } else { first.text.clone().filter(|t| !t.trim().is_empty()) };
    let icon = cards.iter().find_map(|(s, c)| c.file.as_ref().map(|f| s.join(f)).filter(|p| p.is_file()));
    let refs: Vec<(String, u64)> = cards.iter().map(|(s, c)| (s.to_string_lossy().into_owned(), u64::from(c.n))).collect();
    let list: Value = serde_json::from_str(&card_drop::cards_json(&refs)).unwrap_or_default();
    // the island takes no pointer from now on: under the pointer everywhere a moment ago, it would be the window the
    // drag finds to drop on
    isl.passthrough();
    *DRAGGING.lock().unwrap() = Some(list.clone());
    let app2 = app.clone();
    let _ = app.run_on_main_thread(move || {
        let ours = app2.get_webview_window("main").and_then(|w| w.gtk_window().ok());
        let Ok(source) = isl.window().gtk_window() else {
            *DRAGGING.lock().unwrap() = None;
            return answer(&app2, "cancel");
        };
        let app3 = app2.clone();
        let answer2 = answer.clone();
        let payload = linux_dnd::Payload { files: files.clone(), text, icon };
        let started = linux_dnd::drag(&source, payload, ours.as_ref(), move |end| {
            *DRAGGING.lock().unwrap() = None;
            if !end.taken {
                return answer2(&app3, "cancel");
            }
            answer2(&app3, "dropped");
            if end.ours {
                // the main window files them or adds them to an item (`cards_into`); what still hangs comes back
                let app4 = app3.clone();
                std::thread::spawn(move || {
                    std::thread::sleep(std::time::Duration::from_secs(10));
                    refresh_cards(&app4);
                });
                return;
            }
            let copy = !files.is_empty() && note.is_some() && record_flag("drag_copy_note", true);
            if let (true, Some(t)) = (copy, &note) {
                let _ = app3.clipboard().write_text(t.clone());
            }
            for (s, n) in &refs {
                capture::take_card(std::path::Path::new(s), *n);
            }
            let what = if files.is_empty() { "words" } else if copy { "note" } else { "picture" };
            send(&app3, json!({"op": "toast", "kind": "taken", "what": what, "cards": list}));
            refresh_cards(&app3);
            refresh_history(&app3);
        });
        if !started {
            *DRAGGING.lock().unwrap() = None;
            answer(&app2, "cancel");
        }
    });
    true
}

#[cfg(not(any(windows, target_os = "linux")))]
fn drag_out(_: &AppHandle, _: &Value, _: impl Fn(&AppHandle, &str) + Clone + Send + 'static) -> bool {
    false
}

/// The clipboard's sequence number (Windows: changes with every copy, by anyone); 0 where there is none.
#[cfg(windows)]
fn clipboard_seq() -> u32 {
    unsafe { windows::Win32::System::DataExchange::GetClipboardSequenceNumber() }
}
#[cfg(not(windows))]
fn clipboard_seq() -> u32 {
    0
}

/// What the system clipboard holds, read for the main window's Ctrl+V (drag-drop.md §0.6): files copied in Explorer /
/// Files, a picture, the text; whether it is a document's copy (rich text) or Blurt's own picture.
pub fn clipboard_read() -> drop_in::ClipRead {
    #[cfg(windows)]
    {
        island_drop_win::clipboard()
    }
    #[cfg(target_os = "linux")]
    {
        clipboard_linux()
    }
    #[cfg(not(any(windows, target_os = "linux")))]
    {
        drop_in::ClipRead::default()
    }
}

/// Linux: XWayland's clipboard (GNOME keeps it in step with the Wayland one) through arboard: the files a file manager
/// copied (text/uri-list), a picture, the text, the HTML. arboard can't ask for RTF: a copy that has text, HTML and a
/// picture together is a document's (LibreOffice, a web page's selection with its images) — its text is what was meant.
#[cfg(target_os = "linux")]
fn clipboard_linux() -> drop_in::ClipRead {
    let Ok(mut cb) = arboard::Clipboard::new() else { return drop_in::ClipRead::default() };
    let paths = cb.get().file_list().unwrap_or_default();
    let text = cb.get_text().ok().filter(|t| !t.trim().is_empty());
    let html = cb.get().html().ok().filter(|h| !h.trim().is_empty());
    let image = if paths.is_empty() { cb.get_image().ok() } else { None };
    let size = image.as_ref().map(|i| (i.width as u32, i.height as u32));
    let png = image.as_ref().and_then(|i| drop_in::png(i.width as u32, i.height as u32, &i.bytes));
    let ours = drop_in::is_ours(*drop_in::OURS.lock().unwrap(), 0, size);
    drop_in::ClipRead { paths, png, rich: text.is_some() && html.is_some() && size.is_some(), text, ours }
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
