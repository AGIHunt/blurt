//! Blurt for Windows and Linux (Tauri 2) — the v0.7 model (docs/design/next-round.md "v0.7 契约"): projects are
//! folders, items are Markdown in each project's store, everything under way is a job, work goes to the user's own
//! agent as a copied hand-off note, captures are sorted by an agent run headless, and a top-centre island holds capture.
//!
//! Rust side: read-only index.db (rusqlite), the skill's Python CLIs through uv for every write (`items.py`,
//! `projects.py`, `handoff.py`, `agents.py`, `jobs.py`), jobs folded from their files, tray, global
//! shortcuts, file watching, single instance, `blurt://` deep links, updater. The UI is web/apps/desktop (React) and
//! web/apps/overlays (the island, picker and note bubble).

pub mod agents;
pub mod capture;
pub mod control;
pub mod dictation;
pub mod folder_drop;
pub mod hotkeys;
pub mod housekeeping;
pub mod index;
pub mod island;
pub mod items;
pub mod jobs;
pub mod mainwin;
pub mod l10n;
pub mod onboarding;
pub mod paths;
pub mod projects;
pub mod remote; // Blurt on the phone: this computer as its host (crates/blurt-remote)
pub mod screen_text;
pub mod scripts;
pub mod settings;
pub mod setup;
pub mod tray;
pub mod watcher;

use std::sync::RwLock;
use std::time::Duration;

use serde_json::{json, Value};
use tauri::{AppHandle, Emitter, Listener, Manager, RunEvent, WindowEvent};
use tauri_plugin_clipboard_manager::ClipboardExt;
use tauri_plugin_deep_link::DeepLinkExt;
use tauri_plugin_global_shortcut::ShortcutState;
use tauri_plugin_opener::OpenerExt;

use crate::capture::Control;
use crate::index::{Index, ItemQuery, SessionQuery};
use crate::scripts::Runner;

pub struct AppState {
    runner: RwLock<Runner>,
    pub capture: capture::Capture,
    pub docs: items::DocCache,
}

impl AppState {
    pub fn runner(&self) -> Runner {
        self.runner.read().unwrap().clone()
    }
    pub fn index(&self) -> Index {
        Index::new(paths::index_db())
    }
    /// uv was just installed (setup.rs): look for it again
    pub fn refresh_runner(&self, app: &AppHandle) {
        *self.runner.write().unwrap() = Runner::new(app);
    }
}

pub fn show_main(app: &AppHandle) {
    if let Some(w) = app.get_webview_window("main") {
        // a window hidden behind tao's back (another process's ShowWindow) still counts as shown to it, and show()
        // would do nothing: hide first so the show really happens
        if !w.is_visible().unwrap_or(true) {
            let _ = w.hide();
        }
        let _ = w.unminimize();
        let _ = w.show();
        let _ = w.set_focus();
    }
}

/// The main window's title in the UI language (口喷鸡 / Blurt), as the Mac's window is named.
pub fn retitle(app: &AppHandle) {
    if let Some(w) = app.get_webview_window("main") {
        let _ = w.set_title(&l10n::t("tray.tooltip")); // the app's name: 口喷鸡 / Blurt
    }
}

/// One place for what a hotkey / tray item / deep link does.
pub fn dispatch(app: &AppHandle, action: &str) {
    let st = app.state::<AppState>();
    let recording = st.capture.recording();
    let res = match action {
        "record" => {
            capture::toggle(app);
            Ok(())
        }
        "menu" | "open" => {
            show_main(app);
            Ok(())
        }
        "snap" => {
            capture::snap(app);
            Ok(())
        }
        "voice" => {
            capture::voice_start(app, false);
            Ok(())
        }
        "project" => {
            island::send(app, json!({"op": "switcher", "open": true}));
            Ok(())
        }
        // the Mac's Show Cards (⌥H): the Cards panel opens with the keyboard (Current, or History when nothing hangs),
        // or closes when it is open
        "cards" => {
            island::toggle_cards_panel(app);
            Ok(())
        }
        // reformat the last dictation (Alt+Shift+L)
        #[cfg(dict)]
        "reformat" => {
            dictation::engine::reformat_last();
            Ok(())
        }
        #[cfg(any(windows, target_os = "linux"))]
        "text" | "translate" => {
            screen_text::start(app, action == "translate");
            Ok(())
        }
        "pause" if recording => {
            let paused = st.capture.state()["paused"] == true;
            st.capture.control(if paused { Control::Resume } else { Control::Pause })
        }
        "marker" if recording => st.capture.control(Control::Marker),
        "stop" if recording => st.capture.control(Control::Stop),
        // the recording pen latched on / off; Esc while it is on puts it down (recording.md §4.6)
        "pen" if recording => {
            capture::toggle_pen(app);
            Ok(())
        }
        "penesc" => {
            capture::set_pen(app, Some(false));
            Ok(())
        }
        _ => Ok(()),
    };
    if let Err(e) = res {
        let _ = app.emit("capture://status", json!({"ev": "error", "msg": e}));
    }
}

/// Recording started / ended: hotkeys for pause / marker / stop come and go, the tray menu turns into the recording's.
pub fn on_recording(app: &AppHandle, on: bool) {
    hotkeys::apply(app, Some(on));
    tray::refresh(app);
}

/// blurt://item/<uid> · blurt://session/<abs path, url-encoded> · blurt://job/<id> · blurt://record · blurt://open …
pub fn handle_url(app: &AppHandle, raw: &str) {
    let Ok(url) = tauri::Url::parse(raw) else { return };
    if url.scheme() != "blurt" {
        return;
    }
    let host = url.host_str().unwrap_or("").to_string();
    let rest = percent_decode(url.path().trim_start_matches('/'));
    match host.as_str() {
        "item" | "session" | "job" | "project" if !rest.is_empty() => {
            show_main(app);
            let _ = app.emit("nav", json!({ host: rest }));
        }
        // blurt://settings[/<pane>[/<row>]] (the Mac's SettingsController.show(pane:))
        "settings" => {
            show_main(app);
            let _ = app.emit("nav", json!({"view": "settings", "pane": rest}));
        }
        "" => show_main(app),
        // the setup assistant again (the Mac's URLRouter "onboarding")
        "onboarding" => {
            show_main(app);
            let _ = app.emit("nav", json!({"view": "welcome"}));
        }
        // a link from anywhere (a web page, a document) asks first on the island, unless Blurt is in front (the Mac's
        // confirmFromURL; recording.md §1.2). Linux: Wayland's system shortcuts are these links, so they go straight on
        "record" | "snap"
            if cfg!(windows)
                && !app.get_webview_window("main").and_then(|w| w.is_focused().ok()).unwrap_or(false)
                && !app.state::<AppState>().capture.recording() =>
        {
            capture::confirm_from_url(app, &host)
        }
        other => dispatch(app, other),
    }
}

fn percent_decode(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%' && i + 2 < b.len() {
            if let Ok(v) = u8::from_str_radix(&s[i + 1..i + 3], 16) {
                out.push(v);
                i += 3;
                continue;
            }
        }
        out.push(b[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

// ------------------------------------------------------------------ commands (names fixed by the v0.7 contract)

type R<T> = Result<T, String>;

fn platform() -> &'static str {
    if cfg!(windows) {
        "win"
    } else if cfg!(target_os = "macos") {
        "mac"
    } else {
        "gnome"
    }
}

fn dictation_keys() -> &'static str {
    #[cfg(all(dict, target_os = "linux"))]
    return if dictation::keys::evdev_available() { "evdev" } else { "portal" };
    #[allow(unreachable_code)]
    "hook"
}

/// Linux: GNOME's screenshot question for Copy Text from Screen, asked with Blurt's window in front (Settings' Allow…;
/// screen_text/grab_linux.rs). Elsewhere nothing to ask.
#[tauri::command(async)]
fn screen_text_allow(app: AppHandle) -> Value {
    #[cfg(target_os = "linux")]
    return match screen_text::grab_linux::allow(&app) {
        Ok(()) => json!({"ok": true}),
        Err(e) => json!({"ok": false, "code": if e == "denied" { "denied" } else { "failed" }, "error": e}),
    };
    #[allow(unreachable_code)]
    {
        let _ = app;
        json!({"ok": true})
    }
}

/// Copy Text from Screen may take its pictures (Linux: allowed in GNOME's question, as far as Blurt knows).
#[tauri::command]
fn screen_text_allowed() -> bool {
    #[cfg(target_os = "linux")]
    return screen_text::grab_linux::allowed();
    #[allow(unreachable_code)]
    true
}

#[tauri::command]
fn app_status(app: AppHandle, state: tauri::State<'_, AppState>) -> Value {
    let r = state.runner();
    json!({
        "version": app.package_info().version.to_string(),
        "os": std::env::consts::OS,
        "platform": platform(),
        "wayland": hotkeys::is_wayland(),
        "lang": l10n::lang(),
        "blurt_home": scripts::s(&paths::blurt_home()),
        "inbox_store": scripts::s(&paths::inbox_store()),
        "handoff_dir": scripts::s(&paths::handoff_dir()),
        "index_ready": state.index().ready(),
        "scripts": r.scripts.as_deref().map(scripts::s),
        "uv": r.uv.as_deref().map(scripts::s),
        "capture": state.capture.state(),
        "hotkey_mode": app.state::<hotkeys::Hotkeys>().mode.lock().unwrap().clone(),
        // what this build has (Settings shows a pane or a row only for what is built): dictation and voice notes on
        // Windows and Linux (`cfg(dict)`), Copy Text from Screen on both (Linux: the Screenshot portal)
        "features": {"dictation": cfg!(dict), "screen_text": cfg!(any(windows, target_os = "linux"))},
        // the dictation key the GlobalShortcuts portal bound (Linux without /dev/input), else null
        "dictation_key": hotkeys::dictate_label(),
        // where the dictation key comes from: "hook" (Windows: right / either Alt), "evdev" (Linux, the input group:
        // the same choice), "portal" (Linux otherwise: one shortcut, set in GNOME's dialog)
        "dictation_keys": dictation_keys(),
        // test hook (smoke screenshots): open on this view — inbox | items | project:<id> | settings | …
        "start_view": std::env::var("BLURT_START_VIEW").ok(),
    })
}

#[tauri::command(async)]
fn index_query(state: tauri::State<'_, AppState>, q: ItemQuery) -> R<index::ItemPage> {
    state.index().items(&q)
}

#[tauri::command(async)]
fn index_item(state: tauri::State<'_, AppState>, uid: String) -> R<Option<Value>> {
    state.index().item(&uid)
}

#[tauri::command(async)]
fn index_sessions(state: tauri::State<'_, AppState>, q: Option<SessionQuery>) -> R<Vec<Value>> {
    state.index().sessions(&q.unwrap_or_default())
}

#[tauri::command(async)]
fn index_summary(state: tauri::State<'_, AppState>) -> R<Value> {
    state.index().summary()
}

#[tauri::command(async)]
fn index_rescan(app: AppHandle) {
    watcher::initial_scan(&app);
}

#[tauri::command(async)]
fn projects_list(state: tauri::State<'_, AppState>) -> Value {
    projects::list(&state.index())
}

#[tauri::command(async)]
fn projects_add(app: AppHandle, state: tauri::State<'_, AppState>, path: String) -> R<Value> {
    let r = projects::add(&state.runner(), &path)?;
    watcher::refresh(&app);
    island::refresh(&app);
    Ok(r)
}

#[tauri::command(async)]
fn projects_use(app: AppHandle, state: tauri::State<'_, AppState>, id: String) -> R<Value> {
    let r = projects::use_project(&state.runner(), &id)?;
    island::refresh(&app);
    Ok(r)
}

#[tauri::command(async)]
fn projects_set(state: tauri::State<'_, AppState>, id: String, patch: Value) -> R<Value> {
    projects::set(&state.runner(), &id, &patch)
}

#[tauri::command]
fn projects_open_folder(app: AppHandle, make_current: Option<bool>) {
    island::open_folder(&app, make_current.unwrap_or(false));
}

/// Locate… for a project whose folder is gone: the folder dialog (opened next to where it was), then only that
/// project's own folder is taken (projects::locate_pick) → {pick: same|other|empty|cancel}.
#[tauri::command(async)]
fn projects_locate(app: AppHandle, state: tauri::State<'_, AppState>, id: String, title: String, near: Option<String>) -> R<Value> {
    let mut d = island::folder_dialog(&app).set_title(title);
    if let Some(up) = near.as_deref().map(std::path::Path::new).and_then(|p| p.ancestors().skip(1).find(|a| a.is_dir())) {
        d = d.set_directory(up);
    }
    let Some(dir) = d.blocking_pick_folder() else { return Ok(json!({"pick": "cancel"})) };
    let path = dir.into_path().map_err(|e| e.to_string())?;
    let pick = projects::locate_pick(&path, &id);
    if pick == "same" {
        projects::add(&state.runner(), &path.to_string_lossy())?;
        watcher::refresh(&app);
        let _ = app.emit("projects://changed", json!({}));
        island::refresh(&app);
    }
    Ok(json!({"pick": pick}))
}

#[tauri::command(async)]
fn items_doc(state: tauri::State<'_, AppState>, scope: Value) -> R<Value> {
    items::doc(&state.runner(), &state.docs, &scope)
}

#[tauri::command(async)]
fn items_poll(state: tauri::State<'_, AppState>, scope: Value, etag: String) -> R<Value> {
    items::poll(&state.runner(), &state.docs, &scope, &etag)
}

#[tauri::command(async)]
fn items_ops(state: tauri::State<'_, AppState>, scope: Value, ops: Value, confirm: Option<bool>) -> R<Value> {
    items::ops(&state.runner(), &state.docs, &scope, &ops, confirm.unwrap_or(false))
}

#[tauri::command(async)]
fn items_state(state: tauri::State<'_, AppState>, uids: Vec<String>, action: String, note: Option<String>) -> R<Value> {
    items::state(&state.runner(), &uids, &action, note.as_deref())
}

#[tauri::command(async)]
fn items_move(state: tauri::State<'_, AppState>, uids: Vec<String>, project: String) -> R<Value> {
    items::move_items(&state.runner(), &uids, &project)
}

// The main window's other writes (docs/design/windows-parity/main-window.md): Ctrl+Z after a state change, New Item,
// Export Hand-off Bundle…, Remove from Blurt and its undo.
#[tauri::command(async)]
fn items_undo_state(state: tauri::State<'_, AppState>, uids: Vec<String>, to: String) -> R<Value> {
    items::undo_state(&state.runner(), &uids, &to)
}

#[tauri::command(async)]
fn items_add(state: tauri::State<'_, AppState>, project: String, item: Value) -> R<Value> {
    items::add(&state.runner(), &project, &item)
}

/// The Save dialog (with the Mac's file name), then the bundle; Ok(None) when the dialog was cancelled.
#[tauri::command(async)]
fn items_export_bundle(app: AppHandle, state: tauri::State<'_, AppState>, uids: Vec<String>, name: String, lang: String) -> R<Option<Value>> {
    let Some(f) = tauri_plugin_dialog::DialogExt::dialog(&app).file().set_file_name(&name).add_filter("Zip", &["zip"]).blocking_save_file() else { return Ok(None) };
    let path = f.into_path().map_err(|e| e.to_string())?;
    items::export_bundle(&state.runner(), &uids, &path.to_string_lossy(), &lang).map(Some)
}

/// New Item's Add Image…: pictures picked in the system's Open dialog (their paths; nothing is copied yet).
#[tauri::command(async)]
fn pick_images(app: AppHandle) -> Vec<String> {
    tauri_plugin_dialog::DialogExt::dialog(&app)
        .file()
        .add_filter("Images", &["png", "jpg", "jpeg", "gif", "webp", "heic", "bmp"])
        .blocking_pick_files()
        .unwrap_or_default()
        .into_iter()
        .filter_map(|f| f.into_path().ok())
        // the sheet shows each as a thumbnail through the asset protocol: let it read these files (and only these)
        .inspect(|p| {
            let _ = app.asset_protocol_scope().allow_file(p);
        })
        .map(|p| p.to_string_lossy().into_owned())
        .collect()
}

#[tauri::command(async)]
fn projects_remove(app: AppHandle, state: tauri::State<'_, AppState>, id: String) -> R<Value> {
    let r = projects::remove(&state.runner(), &id)?;
    watcher::refresh(&app);
    island::refresh(&app);
    let _ = app.emit("projects://changed", json!({}));
    Ok(r)
}

#[tauri::command(async)]
fn projects_restore(app: AppHandle, state: tauri::State<'_, AppState>, removed: Value) -> R<Value> {
    let r = projects::restore(&state.runner(), &removed)?;
    watcher::refresh(&app);
    island::refresh(&app);
    let _ = app.emit("projects://changed", json!({}));
    Ok(r)
}

/// Fill In Details with AI (items.rs `enrich`): Ok(the job's id).
#[tauri::command(async)]
fn items_enrich(app: AppHandle, uids: Vec<String>, project: Option<String>) -> R<String> {
    items::enrich(&app, &uids, project.as_deref())
}

/// A picture pasted or dropped into the main window, as bytes (the request's body; its name in the `x-name` header):
/// written to a temporary file for New Item. Ok(its path).
#[tauri::command(async)]
fn save_temp_image(app: AppHandle, request: tauri::ipc::Request<'_>) -> R<String> {
    let tauri::ipc::InvokeBody::Raw(bytes) = request.body() else { return Err("expected the picture's bytes".into()) };
    let name = request.headers().get("x-name").and_then(|v| v.to_str().ok()).unwrap_or("pasted.png");
    let p = items::save_temp_image(name, bytes)?;
    // its thumbnail in the sheet loads through the asset protocol (the temp folder is outside its scope: a pasted
    // picture showed as a broken image)
    let _ = app.asset_protocol_scope().allow_file(&p);
    Ok(p)
}

#[tauri::command(async)]
fn jobs_list(active: Option<bool>) -> Vec<Value> {
    jobs::list(active.unwrap_or(false), 100)
}

#[tauri::command(async)]
fn agents_models(state: tauri::State<'_, AppState>, agent: String) -> R<Value> {
    agents::models(&state.runner(), &agent)
}

/// `login` false: no sign-in probes (fast); `ids`: only these agents.
#[tauri::command(async)]
fn agents_detect(state: tauri::State<'_, AppState>, login: Option<bool>, ids: Option<Vec<String>>) -> R<Value> {
    agents::detect_with(&state.runner(), login.unwrap_or(true), ids.as_deref())
}

/// K6: hand these items to the user's own agent — the sheet is written, the items are marked handed off, and the
/// instruction (or the full text) is on the clipboard. → {id, path, text}
#[tauri::command(async)]
fn handoff_create(app: AppHandle, state: tauri::State<'_, AppState>, uids: Vec<String>, full: Option<bool>) -> R<Value> {
    let r = agents::handoff(&state.runner(), &uids, full.unwrap_or(false))?;
    if let Some(t) = r["text"].as_str() {
        app.clipboard().write_text(t.to_string()).map_err(|e| e.to_string())?;
    }
    Ok(r)
}

/// K7: file these captures of a shots batch into a project (None = the AI sorts them), then sort them.
#[tauri::command(async)]
fn process_captures(app: AppHandle, session: String, captures: Option<Vec<u64>>, project: Option<String>) -> R<String> {
    // captures filed into a chosen project become its items at once (`captures.py file`, the Mac's Snapper.file): no
    // agent, no tokens; only "let the AI sort them" (no project) or a whole recording goes to the organising agent
    if let (Some(p), Some(ns)) = (project.as_deref(), captures.as_ref().filter(|c| !c.is_empty())) {
        capture::file_now(&app, std::path::Path::new(&session), ns.clone(), p, Some("user"));
        return Ok(String::new());
    }
    let by = project.as_ref().map(|_| "user");
    let r = agents::process(&app, std::path::Path::new(&session), captures, project, by, None);
    island::refresh_cards(&app);
    r
}

#[tauri::command(async)]
fn voice_start(app: AppHandle) {
    capture::voice_start(&app, false);
}

#[tauri::command(async)]
fn voice_stop(app: AppHandle, cancel: Option<bool>) {
    capture::voice_stop(&app, cancel.unwrap_or(false));
}

#[tauri::command]
fn settings_get(app: AppHandle) -> Value {
    let cfg = settings::read_config();
    json!({
        "config": cfg,
        "hotkeys": hotkeys::rows(&app),
        "hotkey_mode": app.state::<hotkeys::Hotkeys>().mode.lock().unwrap().clone(),
        "wayland": hotkeys::is_wayland(),
        "export_targets": settings::export_targets(&cfg),
        "config_path": scripts::s(&paths::config_file()),
    })
}

#[tauri::command]
fn settings_set(app: AppHandle, patch: Value) -> R<Value> {
    let cfg = settings::merge(patch.clone())?;
    if patch.pointer("/record/hotkeys").is_some() {
        hotkeys::apply(&app, None);
    }
    if patch.pointer("/app/island_idle").is_some() {
        island::refresh(&app); // the resting pill goes or comes back at once
    }
    if patch.get("lang").is_some() {
        retitle(&app);
        island::refresh(&app);
        tray::refresh(&app); // the menu's words follow at once
    }
    Ok(cfg)
}

#[tauri::command]
fn shortcut_set(app: AppHandle, action: String, combo: String) -> Value {
    hotkeys::set(&app, &action, &combo)
}

/// A shortcut field starts / stops recording keys: Blurt's own hotkeys stand down meanwhile (hotkeys::suspend).
#[tauri::command]
fn shortcuts_suspend(app: AppHandle, on: bool) {
    hotkeys::suspend(&app, on);
}

/// Restore Defaults: every key back in one write.
#[tauri::command]
fn shortcuts_reset(app: AppHandle) -> R<Vec<Value>> {
    hotkeys::reset(&app)
}

#[tauri::command(async)]
fn asr_models(state: tauri::State<'_, AppState>) -> R<Value> {
    state.runner().run("transcribe.py", &["models".into()], None, Duration::from_secs(60)).map_err(String::from)
}

#[tauri::command]
fn reveal(app: AppHandle, path: String) -> R<()> {
    app.opener().reveal_item_in_dir(&path).map_err(|e| e.to_string())
}

#[tauri::command]
fn open_external(app: AppHandle, url: String) -> R<()> {
    let ok = ["http://", "https://", "vscode://", "cursor://", "zed://", "claude-cli://", "file://"].iter().any(|p| url.starts_with(p));
    if !ok {
        return Err(format!("not opening {url}"));
    }
    app.opener().open_url(&url, None::<&str>).map_err(|e| e.to_string())
}

#[tauri::command]
fn open_path(app: AppHandle, path: String) -> R<()> {
    // Windows: a file no app is registered for opens in Notepad, not the "Open with" chooser
    #[cfg(windows)]
    if !has_handler(&path) {
        return std::process::Command::new("notepad.exe").arg(&path).spawn().map(|_| ()).map_err(|e| e.to_string());
    }
    app.opener().open_path(&path, None::<&str>).map_err(|e| e.to_string())
}

/// Windows: does an app open this kind of file? Opening one no app is registered for shows the "Open with" chooser
/// (dogfood WW51): open_path opens it in Notepad instead. Folders always open (Explorer).
#[cfg(windows)]
fn has_handler(path: &str) -> bool {
    use windows::core::{HSTRING, PCWSTR};
    use windows::Win32::UI::Shell::{AssocQueryStringW, ASSOCF_INIT_IGNOREUNKNOWN, ASSOCSTR_EXECUTABLE};
    let p = std::path::Path::new(path);
    if p.is_dir() {
        return true;
    }
    let Some(ext) = p.extension().and_then(|e| e.to_str()) else { return false };
    let ext = HSTRING::from(format!(".{ext}"));
    let mut len = 0u32;
    // only the length is asked for: S_FALSE with it when an app is registered, an error when none is
    let hr = unsafe { AssocQueryStringW(ASSOCF_INIT_IGNOREUNKNOWN, ASSOCSTR_EXECUTABLE, &ext, PCWSTR::null(), None, &mut len) };
    hr.is_ok() && len > 0
}

/// The detail's ⤓ (the review page's host.download, the Mac's WebHostController.download): a copy of a frame or
/// recording in the user's Downloads, "name 2.png" when the name is taken. Media files only. Answers the file name.
#[tauri::command]
fn save_to_downloads(app: AppHandle, path: String) -> R<String> {
    let src = std::path::PathBuf::from(&path);
    let ext = src.extension().and_then(|e| e.to_str()).unwrap_or("").to_ascii_lowercase();
    if !DOWNLOADABLE.contains(&ext.as_str()) || !src.is_file() {
        return Err(format!("not saving {path}"));
    }
    let dir = app.path().download_dir().map_err(|e| e.to_string())?;
    let dest = unique_dest(&dir, &src, |p| p.exists());
    std::fs::copy(&src, &dest).map_err(|e| e.to_string())?;
    Ok(dest.file_name().and_then(|n| n.to_str()).unwrap_or("").to_string())
}

const DOWNLOADABLE: &[&str] = &["png", "jpg", "jpeg", "gif", "webp", "heic", "mp4", "mov", "webm", "m4a", "wav", "mp3"];

/// `dir/name.ext`, else `dir/name 2.ext`, `name 3.ext` … (the Mac's naming)
fn unique_dest(dir: &std::path::Path, src: &std::path::Path, exists: impl Fn(&std::path::Path) -> bool) -> std::path::PathBuf {
    let name = src.file_name().and_then(|n| n.to_str()).unwrap_or("file");
    let mut dest = dir.join(name);
    let stem = src.file_stem().and_then(|n| n.to_str()).unwrap_or("file");
    let ext = src.extension().and_then(|n| n.to_str());
    let mut n = 2;
    while exists(&dest) {
        dest = dir.join(match ext {
            Some(e) => format!("{stem} {n}.{e}"),
            None => format!("{stem} {n}"),
        });
        n += 1;
    }
    dest
}

#[tauri::command]
fn clipboard_write(app: AppHandle, text: String) -> R<()> {
    app.clipboard().write_text(text).map_err(|e| e.to_string())
}

#[derive(serde::Deserialize, Default)]
#[serde(default)]
struct StartOpts {
    session: Option<String>,
    /// [x, y, w, h] physical px of the desktop; none + pick = the area picker
    region: Option<[i64; 4]>,
    pick: Option<bool>,
}

#[tauri::command]
async fn capture_start(app: AppHandle, opts: Option<StartOpts>) -> R<String> {
    let o = opts.unwrap_or_default();
    // the picker blocks and overlay windows must not be created on the main thread (blurt_capture)
    tauri::async_runtime::spawn_blocking(move || {
        let region = o.region.map(|[x, y, w, h]| blurt_capture::Region::new(x as i32, y as i32, w as u32, h as u32));
        app.state::<AppState>().capture.start(&app, o.session.map(std::path::PathBuf::from), region, o.pick.unwrap_or(true))
    })
    .await
    .map_err(|e| e.to_string())?
}

#[tauri::command(async)]
fn capture_control(app: AppHandle, cmd: String) -> R<()> {
    match cmd.as_str() {
        "snap" if !app.state::<AppState>().capture.recording() => {
            capture::snap(&app);
            Ok(())
        }
        _ => {
            let c = Control::parse(&cmd).ok_or_else(|| format!("unknown control {cmd}"))?;
            app.state::<AppState>().capture.control(c)
        }
    }
}

#[tauri::command]
fn capture_state(state: tauri::State<'_, AppState>) -> Value {
    state.capture.state()
}

// update_check / update_install: housekeeping.rs (the background check and the feed's mirror order live there)

// ------------------------------------------------------------------ app

// the tray icon and its menu: tray.rs

/// GNOME on Wayland: the whole app runs under XWayland (docs/design/linux-port.md §Overlays). Native Wayland gives a
/// window no position and no keep-above — the island and the cards would sit in the middle of the screen under other
/// windows. Portals, AT-SPI and PipeWire don't care which backend a window uses. An explicit GDK_BACKEND wins.
fn linux_xwayland() {
    if cfg!(target_os = "linux") && std::env::var_os("GDK_BACKEND").is_none() && crate::hotkeys::is_wayland() {
        std::env::set_var("GDK_BACKEND", "x11");
    }
}

/// Linux: the scripts run where Blurt runs, and uv reads the working directory (a project's .venv, a pyproject):
/// started from a terminal inside some project, or a folder it can't read, every script failed. Blurt's own folder.
fn linux_working_dir() {
    if cfg!(target_os = "linux") {
        let home = crate::paths::blurt_home();
        let _ = std::fs::create_dir_all(&home);
        let _ = std::env::set_current_dir(&home);
    }
}

/// WebKitGTK on NVIDIA renders black with the DMA-BUF renderer (§6 WP7 risk): off when NVIDIA's driver is loaded or
/// the user asks (config app.disable_dmabuf / env BLURT_DISABLE_DMABUF=1); an explicit WEBKIT_* setting wins.
fn linux_graphics_workarounds() {
    if !cfg!(target_os = "linux") || std::env::var_os("WEBKIT_DISABLE_DMABUF_RENDERER").is_some() {
        return;
    }
    let cfg = settings::read_config();
    let want = cfg.pointer("/app/disable_dmabuf").and_then(Value::as_bool);
    let env = std::env::var("BLURT_DISABLE_DMABUF").ok().map(|v| v == "1");
    let nvidia = std::path::Path::new("/proc/driver/nvidia/version").exists();
    if env.or(want).unwrap_or(nvidia) {
        std::env::set_var("WEBKIT_DISABLE_DMABUF_RENDERER", "1");
    }
}

/// Tests only: `BLURT_TEST_EVAL=<file>` — whenever the file changes, its first line names a window (`main`,
/// `blurt-overlay-island`, …) and the rest is JavaScript evaluated there. Scripted smoke runs drive the UI through
/// the DOM this way, without touching the real mouse or keyboard.
fn test_channel(app: &AppHandle) {
    let Some(file) = std::env::var_os("BLURT_TEST_EVAL").map(std::path::PathBuf::from) else { return };
    // what a script reports back (`emit('blurt://test-result', …)` from any page) lands in <file>.out, one JSON per line
    let out = file.with_extension("out");
    app.listen_any("blurt://test-result", move |e| {
        if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(&out) {
            use std::io::Write as _;
            let _ = writeln!(f, "{}", e.payload());
        }
    });
    let app = app.clone();
    std::thread::spawn(move || {
        let mut seen = std::fs::metadata(&file).and_then(|m| m.modified()).ok();
        loop {
            std::thread::sleep(Duration::from_millis(300));
            let m = std::fs::metadata(&file).and_then(|m| m.modified()).ok();
            if m.is_none() || m == seen {
                continue;
            }
            seen = m;
            let Ok(text) = std::fs::read_to_string(&file) else { continue };
            let (label, js) = text.split_once('\n').unwrap_or((text.as_str(), ""));
            if let Some(w) = app.get_webview_window(label.trim()) {
                let _ = w.eval(js);
            }
        }
    });
}

/// A web page that should feel like the app: WebView2's browser keys (F5 / Ctrl+R reload, Ctrl+P print, Ctrl+F find,
/// Alt+← back) do nothing — the page still gets the keydown, so the app's own Ctrl+F keeps working — and on the
/// overlays (picker, island, cards, note) the browser's Back / Refresh menu never opens. The main window keeps its
/// menu for text fields (main.tsx turns it off everywhere else).
#[cfg(windows)]
fn browser_ui_off(wv: &tauri::Webview) {
    let overlay = wv.label() != "main";
    let _ = wv.with_webview(move |p| unsafe {
        use webview2_com::Microsoft::Web::WebView2::Win32::ICoreWebView2Settings3;
        use windows::core::Interface;
        let Ok(core) = p.controller().CoreWebView2() else { return };
        let Ok(settings) = core.Settings() else { return };
        if overlay {
            let _ = settings.SetAreDefaultContextMenusEnabled(false);
        }
        if let Ok(s3) = settings.cast::<ICoreWebView2Settings3>() {
            let _ = s3.SetAreBrowserAcceleratorKeysEnabled(false);
        }
    });
}

pub fn run() {
    linux_graphics_workarounds();
    linux_xwayland();
    linux_working_dir();
    let app = tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|app, argv, _cwd| {
            // the deep-link feature forwards blurt:// URLs in argv to on_open_url, and handle_url shows the window for
            // the links that need it — a record / snap link asks on the island and keeps the window out of the way
            if !argv.iter().any(|a| a.starts_with("blurt:")) {
                show_main(app);
            }
        }))
        .plugin(tauri_plugin_deep_link::init())
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_notification::init())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_clipboard_manager::init())
        .plugin(tauri_plugin_updater::Builder::new().build())
        .plugin(
            tauri_plugin_global_shortcut::Builder::new()
                .with_handler(|app, sc, ev| {
                    let Some(a) = hotkeys::action_for(app, sc) else { return };
                    match ev.state {
                        ShortcutState::Pressed => hotkeys::fire(app, &a),
                        // K7: the voice key held past 0.35 s is push-to-talk — letting go ends the note
                        ShortcutState::Released if a == "voice" => capture::voice_released(app),
                        ShortcutState::Released => {}
                    }
                })
                .build(),
        )
        .on_page_load(|_wv, _| {
            #[cfg(windows)]
            browser_ui_off(_wv);
        })
        .manage(hotkeys::Hotkeys::default())
        .manage(watcher::WatchState::default())
        .manage(island::Hub::default())
        .setup(|app| {
            let handle = app.handle().clone();
            hotkeys::mark_main_thread(); // hotkeys::apply runs here, whoever calls it
            retitle(&handle);
            app.manage(AppState {
                runner: RwLock::new(Runner::new(&handle)),
                capture: capture::Capture::default(),
                docs: items::DocCache::default(),
            });
            if std::env::var_os("BLURT_NO_TRAY").is_none() {
                if let Err(e) = tray::build(&handle) {
                    eprintln!("blurt: no tray: {e}"); // e.g. GNOME without the AppIndicator extension
                }
            }
            mainwin::restore(&handle); // the main window's last frame (mainwin.rs)
            folder_drop::install(&handle); // folders dropped from Explorer onto the sidebar (folder_drop.rs)
            // the first run opens on the setup assistant: the window is its size from the start, not after a jump
            if onboarding::needed() {
                mainwin::welcome_frame(&handle, true);
            }
            // a login launch (onboarding.rs "Open Blurt at login") starts in the tray
            if onboarding::launched_at_login() && handle.tray_by_id("main").is_some() {
                if let Some(w) = handle.get_webview_window("main") {
                    let _ = w.hide();
                }
            }
            hotkeys::apply(&handle, Some(false));
            #[cfg(target_os = "linux")]
            screen_text::grab_linux::init(&handle);
            #[cfg(any(windows, target_os = "linux"))]
            if cfg!(debug_assertions) || std::env::var_os("APPIMAGE").is_some() {
                let _ = app.deep_link().register_all();
            }
            {
                let h = handle.clone();
                app.deep_link().on_open_url(move |ev| {
                    for u in ev.urls() {
                        handle_url(&h, u.as_str());
                    }
                });
            }
            if let Ok(Some(urls)) = app.deep_link().get_current() {
                for u in urls {
                    handle_url(&handle, u.as_str());
                }
            }
            watcher::start(&handle);
            if std::env::var_os("BLURT_NO_SCAN").is_none() {
                watcher::initial_scan(&handle);
            }
            island::init(&handle);
            onboarding::init(&handle); // before setup: it hears setup's uv events
            if std::env::var_os("BLURT_NO_SETUP").is_none() {
                setup::start(&handle);
            }
            #[cfg(dict)]
            if std::env::var_os("BLURT_NO_DICTATION").is_none() {
                if let Err(e) = dictation::engine::start(&handle) {
                    eprintln!("blurt: dictation key not available: {e}");
                }
            }
            remote::start(&handle); // Blurt on the phone: idle until a code shows or a phone is paired
            housekeeping::start(&handle); // launch messages, housekeeping, the update check
            control::start(&handle); // Set Up with Agent…'s endpoint (agent-setup.md; run/control.json)
            test_channel(&handle);
            Ok(())
        })
        .on_window_event(|w, ev| {
            if matches!(ev, WindowEvent::Moved(_) | WindowEvent::Resized(_) | WindowEvent::ScaleFactorChanged { .. }) {
                mainwin::changed(w);
            }
            // a shortcut field that lost the keyboard stops recording: Blurt's hotkeys come back
            if matches!(ev, WindowEvent::Focused(false)) && w.label() == "main" && hotkeys::suspended(w.app_handle()) {
                hotkeys::suspend(w.app_handle(), false);
            }
            if matches!(ev, WindowEvent::ThemeChanged(_)) {
                tray::retint(w.app_handle());
            }
            // closing the window keeps Blurt in the tray (hotkeys keep working); Quit is in the tray menu
            if let WindowEvent::CloseRequested { api, .. } = ev {
                if w.label() == "main" && std::env::var_os("BLURT_QUIT_ON_CLOSE").is_none() && w.app_handle().tray_by_id("main").is_some() {
                    api.prevent_close();
                    let _ = w.hide();
                }
            }
        })
        .invoke_handler(tauri::generate_handler![
            island::cards_waiting,
            island::cards_reveal,
            dictation::commands::dictation_models,
            dictation::commands::model_download,
            dictation::commands::model_download_cancel,
            dictation::commands::dictation_use,
            dictation::commands::dictation_dashscope_model,
            screen_text_allow,
            screen_text_allowed,
            dictation::commands::dictation_key_forward,
            dictation::commands::dictation_words,
            dictation::commands::dictation_words_edit,
            dictation::commands::dictation_mics,
            dictation::commands::app_icon,
            dictation::commands::cloud_summary,
            dictation::commands::cloud_connect,
            dictation::commands::cloud_disconnect,
            dictation::history::dictation_history,
            dictation::history::dictation_history_edit,
            dictation::history::dictation_history_item,
            dictation::history::dictation_retry,
            onboarding::onboarding_get,
            onboarding::onboarding_step,
            onboarding::onboarding_finish,
            onboarding::onboarding_retry_setup,
            onboarding::onboarding_mic,
            onboarding::onboarding_mic_settings,
            onboarding::login_item_get,
            onboarding::login_item_set,
            app_status,
            index_query,
            index_item,
            index_sessions,
            index_summary,
            index_rescan,
            projects_list,
            projects_add,
            projects_use,
            projects_set,
            projects_open_folder,
            projects_locate,
            items_doc,
            items_poll,
            items_ops,
            items_state,
            items_move,
            items_undo_state,
            items_add,
            items_export_bundle,
            pick_images,
            projects_remove,
            projects_restore,
            items_enrich,
            save_temp_image,
            mainwin::items_drag_out,
            mainwin::welcome_window,
            mainwin::items_drag_out_available,
            jobs_list,
            agents_detect,
            agents_models,
            handoff_create,
            process_captures,
            voice_start,
            voice_stop,
            settings_get,
            settings_set,
            shortcut_set,
            shortcuts_suspend,
            shortcuts_reset,
            asr_models,
            reveal,
            open_external,
            open_path,
            save_to_downloads,
            clipboard_write,
            capture_start,
            capture_control,
            capture_state,
            housekeeping::update_check,
            housekeeping::update_install,
            housekeeping::update_state,
            housekeeping::app_contract,
            housekeeping::app_contract_help,
            housekeeping::storage_scan,
            housekeeping::storage_trash,
            housekeeping::videos_trash,
            housekeeping::videos_auto_set,
            housekeeping::cloud_curated,
            housekeeping::cloud_job_set,
            housekeeping::cloud_connect_speech,
            housekeeping::cloud_speech_app_id,
            housekeeping::voiceprint_status,
            housekeeping::voiceprint_prepare,
            housekeeping::voiceprint_start,
            housekeeping::voiceprint_stop,
            housekeeping::voiceprint_clear,
            housekeeping::asr_auto_apply,
            housekeeping::agents_registry,
            housekeeping::agents_install,
            housekeeping::agents_test,
            housekeeping::feedback_send,
            control::agent_setup_instruction,
            control::agent_setup_state,
            control::agent_setup_stop,
            control::agent_setup_dismiss,
            control::agent_setup_answer,
            // Blurt on the phone: Settings → Phone (docs/design/remote-protocol.md §The desktop app)
            remote::remote_status,
            remote::remote_show_pairing,
            remote::remote_answer_pairing,
            remote::remote_remove_device,
            remote::remote_set_relay,
            remote::remote_check_relay,
            remote::remote_set_screen_allowed,
            remote::remote_relay_instructions,
            remote::remote_allow_firewall,
        ])
        .build(tauri::generate_context!())
        .expect("error while building Blurt");
    app.run(|app, ev| {
        if let RunEvent::Exit = ev {
            if app.state::<AppState>().capture.recording() {
                capture::stop_and_wait(app, Duration::from_secs(10)); // never lose a take on quit
            }
            remote::stop(); // Blurt on the phone: nothing held down, the session closed
            agents::end_organising(); // an organising agent ends with the app, its job marked stopped
            control::stop();
        }
    });
}

#[cfg(test)]
mod tests {
    #[test]
    fn decode() {
        assert_eq!(super::percent_decode("%2Fr%2Fmy%20saas"), "/r/my saas");
        assert_eq!(super::percent_decode("01KAQ6"), "01KAQ6");
        assert_eq!(super::percent_decode("50%"), "50%");
    }

    #[test]
    fn downloads_name() {
        use std::path::Path;
        let taken = ["/d/frame.png", "/d/frame 2.png"];
        let d = super::unique_dest(Path::new("/d"), Path::new("/s/frame.png"), |p| taken.iter().any(|t| Path::new(t) == p));
        assert_eq!(d, Path::new("/d/frame 3.png"));
        assert_eq!(super::unique_dest(Path::new("/d"), Path::new("/s/clip.mp4"), |_| false), Path::new("/d/clip.mp4"));
    }
}
