//! Blurt for Windows and Linux (Tauri 2) — the v0.7 model (docs/design/next-round.md "v0.7 契约"): projects are
//! folders, items are Markdown in each project's store, everything under way is a job, agents run in tmux windows
//! (or in the app's own ConPTY on Windows) shown in an embedded terminal, and a top-centre island holds capture.
//!
//! Rust side: read-only index.db (rusqlite), the skill's Python CLIs through uv for every write (`items.py`,
//! `projects.py`, `sessions.py`, `handoff.py`, `jobs.py`), jobs folded from their files, ptys, tray, global
//! shortcuts, file watching, single instance, `blurt://` deep links, updater. The UI is web/apps/desktop (React) and
//! web/apps/overlays (the island, picker and note bubble).

pub mod capture;
pub mod hotkeys;
pub mod index;
pub mod island;
pub mod items;
pub mod jobs;
pub mod l10n;
pub mod paths;
pub mod projects;
pub mod pty;
pub mod scripts;
pub mod sessions;
pub mod settings;
pub mod watcher;

use std::sync::{Mutex, RwLock};
use std::time::Duration;

use serde_json::{json, Value};
use tauri::menu::{Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Emitter, Listener, Manager, RunEvent, WindowEvent, Wry};
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
    tray_record: Mutex<Option<MenuItem<Wry>>>,
}

impl AppState {
    pub fn runner(&self) -> Runner {
        self.runner.read().unwrap().clone()
    }
    pub fn index(&self) -> Index {
        Index::new(paths::index_db())
    }
}

pub fn show_main(app: &AppHandle) {
    if let Some(w) = app.get_webview_window("main") {
        let _ = w.unminimize();
        let _ = w.show();
        let _ = w.set_focus();
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
        "pause" if recording => {
            let paused = st.capture.state()["paused"] == true;
            st.capture.control(if paused { Control::Resume } else { Control::Pause })
        }
        "marker" if recording => st.capture.control(Control::Marker),
        "stop" if recording => st.capture.control(Control::Stop),
        _ => Ok(()),
    };
    if let Err(e) = res {
        let _ = app.emit("capture://status", json!({"ev": "error", "msg": e}));
    }
}

/// Recording started / ended: hotkeys for pause / marker / stop come and go, the tray item flips.
pub fn on_recording(app: &AppHandle, on: bool) {
    hotkeys::apply(app, Some(on));
    if let Some(item) = app.state::<AppState>().tray_record.lock().unwrap().as_ref() {
        let _ = item.set_text(l10n::t(if on { "tray.finish" } else { "tray.record" }));
    }
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
        "" => show_main(app),
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

#[tauri::command]
fn app_status(app: AppHandle, state: tauri::State<'_, AppState>) -> Value {
    let r = state.runner();
    let tmux = !cfg!(windows) && scripts::agent_environment().get("PATH").is_some_and(|p| std::env::split_paths(p).any(|d| d.join("tmux").is_file()));
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
        "tmux": tmux,
        "capture": state.capture.state(),
        "hotkey_mode": app.state::<hotkeys::Hotkeys>().mode.lock().unwrap().clone(),
        // test hook (smoke screenshots): open on this view — inbox | items | project:<id> | sessions | settings | …
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
fn items_work(state: tauri::State<'_, AppState>, uids: Vec<String>, work: String, note: Option<String>) -> R<Value> {
    items::work(&state.runner(), &uids, &work, note.as_deref())
}

#[tauri::command(async)]
fn items_move(state: tauri::State<'_, AppState>, uids: Vec<String>, project: String) -> R<Value> {
    items::move_items(&state.runner(), &uids, &project)
}

#[tauri::command(async)]
fn jobs_list(active: Option<bool>) -> Vec<Value> {
    jobs::list(active.unwrap_or(false), 100)
}

#[tauri::command(async)]
fn agents_detect(state: tauri::State<'_, AppState>) -> R<Value> {
    sessions::detect(&state.runner())
}

#[tauri::command(async)]
fn sessions_dispatch(app: AppHandle, state: tauri::State<'_, AppState>, opts: sessions::DispatchOpts) -> R<Value> {
    let r = sessions::dispatch(&app, &state.runner(), &opts)?;
    items::bump();
    Ok(r)
}

#[tauri::command(async)]
fn sessions_list(app: AppHandle, state: tauri::State<'_, AppState>, all: Option<bool>) -> R<Value> {
    let mut r = sessions::list(&state.runner(), all.unwrap_or(false))?;
    r["owned"] = json!(pty::owned_jobs(&app)); // app-runner sessions end when Blurt quits (the UI says so)
    Ok(r)
}

#[tauri::command(async)]
fn sessions_finish(state: tauri::State<'_, AppState>, job: String, action: String) -> R<Value> {
    let r = sessions::finish(&state.runner(), &job, &action)?;
    items::bump();
    Ok(r)
}

#[tauri::command(async)]
fn sessions_stop(app: AppHandle, state: tauri::State<'_, AppState>, job: String, kill: Option<bool>) -> R<Value> {
    sessions::stop(&app, &state.runner(), &job, kill.unwrap_or(false))
}

#[tauri::command(async)]
fn sessions_open_external(state: tauri::State<'_, AppState>, job: String, terminal: Option<String>) -> R<Value> {
    sessions::open_external(&state.runner(), &job, terminal.as_deref())
}

#[tauri::command(async)]
fn sessions_send(state: tauri::State<'_, AppState>, job: String, text: String, enter: Option<bool>) -> R<Value> {
    sessions::send(&state.runner(), &job, &text, enter.unwrap_or(true))
}

#[tauri::command(async)]
fn pty_open(app: AppHandle, state: tauri::State<'_, AppState>, job: String, cols: Option<u16>, rows: Option<u16>) -> R<Value> {
    pty::open(&app, &state.runner(), &job, cols.unwrap_or(100), rows.unwrap_or(30))
}

#[tauri::command]
fn pty_write(app: AppHandle, pty_id: u32, data: String) -> R<()> {
    pty::write(&app, pty_id, &data)
}

#[tauri::command]
fn pty_resize(app: AppHandle, pty_id: u32, cols: u16, rows: u16) -> R<()> {
    pty::resize(&app, pty_id, cols, rows)
}

#[tauri::command]
fn pty_close(app: AppHandle, pty_id: u32) {
    pty::close(&app, pty_id);
}

/// K6: hand these items to the user's own agent — the sheet is written, the items are marked handed off, and the
/// instruction (or the full text) is on the clipboard. → {id, path, text}
#[tauri::command(async)]
fn handoff_create(app: AppHandle, state: tauri::State<'_, AppState>, uids: Vec<String>, full: Option<bool>) -> R<Value> {
    let r = sessions::handoff(&state.runner(), &uids, full.unwrap_or(false))?;
    if let Some(t) = r["text"].as_str() {
        app.clipboard().write_text(t.to_string()).map_err(|e| e.to_string())?;
    }
    Ok(r)
}

/// K7: file these captures of a shots batch into a project (None = the AI sorts them), then sort them.
#[tauri::command(async)]
fn process_captures(app: AppHandle, session: String, captures: Option<Vec<u64>>, project: Option<String>) -> R<String> {
    let by = project.as_ref().map(|_| "user");
    let r = sessions::process(&app, std::path::Path::new(&session), captures, project, by, None);
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
    if patch.get("lang").is_some() {
        island::refresh(&app);
    }
    Ok(cfg)
}

#[tauri::command]
fn shortcut_set(app: AppHandle, action: String, combo: String) -> Value {
    hotkeys::set(&app, &action, &combo)
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
    app.opener().open_path(&path, None::<&str>).map_err(|e| e.to_string())
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

#[tauri::command(async)]
async fn update_check(app: AppHandle) -> R<Value> {
    use tauri_plugin_updater::UpdaterExt;
    let key = app.config().plugins.0.get("updater").and_then(|u| u.get("pubkey")).and_then(Value::as_str).unwrap_or("");
    if key.is_empty() {
        return Ok(json!({"configured": false}));
    }
    let up = app.updater().map_err(|e| e.to_string())?;
    match up.check().await.map_err(|e| e.to_string())? {
        Some(u) => Ok(json!({"configured": true, "available": true, "version": u.version})),
        None => Ok(json!({"configured": true, "available": false})),
    }
}

// ------------------------------------------------------------------ app

fn tray(app: &AppHandle) -> tauri::Result<()> {
    let item = |id: &str, key: &str| MenuItem::with_id(app, id, l10n::t(key), true, None::<&str>);
    let open = item("open", "tray.open")?;
    let record = item("record", "tray.record")?;
    let snap = item("snap", "tray.snap")?;
    let voice = item("voice", "tray.voice")?;
    let quit = item("quit", "tray.quit")?;
    let sep = PredefinedMenuItem::separator(app)?;
    let sep2 = PredefinedMenuItem::separator(app)?;
    let menu = Menu::with_items(app, &[&open, &sep, &record, &snap, &voice, &sep2, &quit])?;
    *app.state::<AppState>().tray_record.lock().unwrap() = Some(record);
    let mut b = TrayIconBuilder::with_id("main").menu(&menu).tooltip(l10n::t("tray.tooltip")).show_menu_on_left_click(false);
    // monochrome, template-style (the `blurt` glyph; assets/icons/tools/build.py writes icons/tray*.png): black as a macOS template image; white on
    // Windows / Linux panels, which are dark by default — black when the system theme is light
    let light = app.get_webview_window("main").and_then(|w| w.theme().ok()) == Some(tauri::Theme::Light);
    let png: &[u8] = if cfg!(target_os = "macos") || (light && !cfg!(target_os = "linux")) {
        include_bytes!("../icons/tray-black.png")
    } else {
        include_bytes!("../icons/tray-white.png")
    };
    match tauri::image::Image::from_bytes(png) {
        Ok(icon) => b = b.icon(icon).icon_as_template(cfg!(target_os = "macos")),
        Err(_) => {
            if let Some(icon) = app.default_window_icon() {
                b = b.icon(icon.clone());
            }
        }
    }
    b.on_menu_event(|app, ev| match ev.id().as_ref() {
        "quit" => app.exit(0),
        other => dispatch(app, other),
    })
    .on_tray_icon_event(|tray, ev| {
        if let TrayIconEvent::Click { button: MouseButton::Left, button_state: MouseButtonState::Up, .. } = ev {
            show_main(tray.app_handle());
        }
    })
    .build(app)?;
    Ok(())
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

pub fn run() {
    linux_graphics_workarounds();
    let app = tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|app, _argv, _cwd| {
            // the deep-link feature forwards blurt:// URLs in argv to on_open_url
            show_main(app);
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
        .manage(hotkeys::Hotkeys::default())
        .manage(watcher::WatchState::default())
        .manage(pty::Ptys::default())
        .manage(island::Hub::default())
        .manage(sessions::Monitor::default())
        .setup(|app| {
            let handle = app.handle().clone();
            app.manage(AppState {
                runner: RwLock::new(Runner::new(&handle)),
                capture: capture::Capture::default(),
                docs: items::DocCache::default(),
                tray_record: Mutex::new(None),
            });
            if std::env::var_os("BLURT_NO_TRAY").is_none() {
                if let Err(e) = tray(&handle) {
                    eprintln!("blurt: no tray: {e}"); // e.g. GNOME without the AppIndicator extension
                }
            }
            hotkeys::apply(&handle, Some(false));
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
            sessions::start_monitor(&handle);
            island::init(&handle);
            test_channel(&handle);
            Ok(())
        })
        .on_window_event(|w, ev| {
            // closing the window keeps Blurt in the tray (hotkeys keep working); Quit is in the tray menu
            if let WindowEvent::CloseRequested { api, .. } = ev {
                if w.label() == "main" && std::env::var_os("BLURT_QUIT_ON_CLOSE").is_none() && w.app_handle().tray_by_id("main").is_some() {
                    api.prevent_close();
                    let _ = w.hide();
                }
            }
        })
        .invoke_handler(tauri::generate_handler![
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
            items_doc,
            items_poll,
            items_ops,
            items_work,
            items_move,
            jobs_list,
            agents_detect,
            sessions_dispatch,
            sessions_list,
            sessions_finish,
            sessions_stop,
            sessions_open_external,
            sessions_send,
            pty_open,
            pty_write,
            pty_resize,
            pty_close,
            handoff_create,
            process_captures,
            voice_start,
            voice_stop,
            settings_get,
            settings_set,
            shortcut_set,
            asr_models,
            reveal,
            open_external,
            open_path,
            clipboard_write,
            capture_start,
            capture_control,
            capture_state,
            update_check,
        ])
        .build(tauri::generate_context!())
        .expect("error while building Blurt");
    app.run(|app, ev| {
        if let RunEvent::Exit = ev {
            if app.state::<AppState>().capture.recording() {
                capture::stop_and_wait(app, Duration::from_secs(10)); // never lose a take on quit
            }
            pty::kill_all(app);
            sessions::stop_monitor(app);
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
}
