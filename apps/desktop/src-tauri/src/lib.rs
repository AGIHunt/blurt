//! Blurt for Windows and Linux (Tauri 2). docs/design/desktop-app.md §1.5, §2, §5 C8, §6 WP7.
//!
//! Rust side: read-only index.db (rusqlite), the skill's Python CLIs through uv for every write, tray, global
//! shortcuts, file watching, single instance, `blurt://` deep links, updater. The UI is web/apps/desktop (React).

pub mod agents;
pub mod capture;
pub mod hotkeys;
pub mod index;
pub mod paths;
pub mod review;
pub mod scripts;
pub mod settings;
pub mod watcher;

use std::sync::{Arc, Mutex, RwLock};
use std::time::Duration;

use serde_json::{json, Value};
use tauri::menu::{Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Emitter, Manager, RunEvent, WindowEvent, Wry};
use tauri_plugin_deep_link::DeepLinkExt;
use tauri_plugin_global_shortcut::ShortcutState;
use tauri_plugin_notification::NotificationExt;
use tauri_plugin_opener::OpenerExt;

use crate::capture::Control;
use crate::index::{Index, ItemQuery, SessionQuery};
use crate::scripts::Runner;

pub struct AppState {
    runner: RwLock<Runner>,
    pub capture: capture::Capture,
    pub runs: Arc<agents::Runs>,
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

pub fn zh() -> bool {
    std::env::var("BLURT_LANG").map(|l| l.starts_with("zh")).unwrap_or_else(|_| sys_locale::get_locale().is_some_and(|l| l.starts_with("zh")))
}

fn t(zh_s: &'static str, en: &'static str) -> &'static str {
    if zh() {
        zh_s
    } else {
        en
    }
}

pub fn show_main(app: &AppHandle) {
    if let Some(w) = app.get_webview_window("main") {
        let _ = w.unminimize();
        let _ = w.show();
        let _ = w.set_focus();
    }
}

pub fn notify(app: &AppHandle, title: &str, body: &str) {
    let _ = app.notification().builder().title(title).body(body).show();
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
        "snap" if recording => st.capture.control(Control::Snap),
        "snap" => Err(t("截图目前只能在录制中用：先 Alt+Shift+R 开始录制", "Snaps work during a recording for now: start one with the record shortcut").to_string()),
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
        let _ = item.set_text(if on { t("结束录制", "Finish recording") } else { t("录制", "Record") });
    }
}

/// blurt://item/<uid> · blurt://session/<abs path, url-encoded> · blurt://record · blurt://snap · blurt://open …
pub fn handle_url(app: &AppHandle, raw: &str) {
    let Ok(url) = tauri::Url::parse(raw) else { return };
    if url.scheme() != "blurt" {
        return;
    }
    let host = url.host_str().unwrap_or("").to_string();
    let rest = url.path().trim_start_matches('/');
    let rest = percent_decode(rest);
    match host.as_str() {
        "item" => {
            show_main(app);
            let _ = app.emit("nav", json!({"item": rest}));
        }
        "session" => {
            show_main(app);
            let _ = app.emit("nav", json!({"session": rest}));
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

// ------------------------------------------------------------------ commands (C8)

type R<T> = Result<T, String>;

#[tauri::command]
fn app_status(app: AppHandle, state: tauri::State<'_, AppState>) -> Value {
    let r = state.runner();
    let platform = if cfg!(windows) {
        "win"
    } else if cfg!(target_os = "macos") {
        "mac"
    } else {
        "gnome"
    };
    json!({
        "version": app.package_info().version.to_string(),
        "os": std::env::consts::OS,
        "platform": platform,
        "wayland": hotkeys::is_wayland(),
        "lang": if zh() { "zh" } else { "en" },
        "blurt_home": scripts::s(&paths::blurt_home()),
        "index_db": scripts::s(&paths::index_db()),
        "index_exists": paths::index_db().is_file(),
        "default_workspace": scripts::s(&paths::default_workspace()),
        "scripts": r.scripts.as_deref().map(scripts::s),
        "uv": r.uv.as_deref().map(scripts::s),
        "capture": state.capture.state(),
        "hotkey_mode": app.state::<hotkeys::Hotkeys>().mode.lock().unwrap().clone(),
        // test hook (smoke screenshots): open on this view — items | inbox | sessions | agents | settings | review:<dir>
        "start_view": std::env::var("BLURT_START_VIEW").ok(),
    })
}

#[tauri::command(async)]
fn index_query(state: tauri::State<'_, AppState>, q: ItemQuery) -> R<index::ItemPage> {
    state.index().items(&q)
}

#[tauri::command(async)]
fn index_sessions(state: tauri::State<'_, AppState>, q: Option<SessionQuery>) -> R<Vec<Value>> {
    state.index().sessions(&q.unwrap_or_default())
}

#[tauri::command(async)]
fn index_workspaces(state: tauri::State<'_, AppState>) -> R<Vec<Value>> {
    state.index().workspaces()
}

#[tauri::command(async)]
fn index_summary(state: tauri::State<'_, AppState>) -> R<Value> {
    state.index().summary()
}

#[tauri::command(async)]
fn index_item(state: tauri::State<'_, AppState>, uid: String) -> R<Option<Value>> {
    state.index().item(&uid)
}

#[tauri::command(async)]
fn index_rescan(app: AppHandle) {
    watcher::initial_scan(&app);
}

fn allow_session(app: &AppHandle, session: &str) {
    let _ = app.asset_protocol_scope().allow_directory(session, true);
}

#[tauri::command(async)]
fn review_load(app: AppHandle, session: String) -> R<Value> {
    allow_session(&app, &session);
    review::load(&session)
}

#[tauri::command(async)]
fn review_poll(session: String, etag: String) -> R<Value> {
    review::poll(&session, &etag)
}

#[tauri::command(async)]
fn review_ops(state: tauri::State<'_, AppState>, session: String, ops: Value, confirm: Option<bool>) -> R<Value> {
    review::ops(&state.runner(), &session, &ops, confirm.unwrap_or(false))
}

#[tauri::command(async)]
fn agents_detect(state: tauri::State<'_, AppState>) -> R<Value> {
    agents::detect(&state.runner())
}

#[tauri::command(async)]
fn agent_run(app: AppHandle, state: tauri::State<'_, AppState>, id: String, prompt: String, repo: String) -> R<String> {
    agents::run(&app, &state.runner(), &state.runs, &id, &prompt, &repo, vec![])
}

#[tauri::command]
fn agent_runs(state: tauri::State<'_, AppState>) -> Vec<agents::AgentRun> {
    state.runs.list.lock().unwrap().clone()
}

#[tauri::command]
fn agent_stop(state: tauri::State<'_, AppState>, run_id: String) -> bool {
    agents::stop(&state.runs, &run_id)
}

#[tauri::command(async)]
fn fix_with_agent(app: AppHandle, state: tauri::State<'_, AppState>, session: String, item_ids: Vec<String>, agent: Option<String>) -> R<Value> {
    agents::fix_with_agent(&app, &state.runner(), &state.runs, &session, &item_ids, agent)
}

#[tauri::command(async)]
fn process_session(app: AppHandle, state: tauri::State<'_, AppState>, session: String, agent: Option<String>) -> R<Value> {
    agents::process_session(&app, &state.runner(), &state.runs, &session, agent)
}

#[tauri::command(async)]
fn agent_prompt(state: tauri::State<'_, AppState>, uids: Vec<String>) -> R<Value> {
    agents::fix_prompt(&state.runner(), &uids, None)
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
    if patch.pointer("/record/workspaces").is_some() || patch.pointer("/record/workspace").is_some() {
        watcher::refresh(&app);
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
    let c = Control::parse(&cmd).ok_or_else(|| format!("unknown control {cmd}"))?;
    app.state::<AppState>().capture.control(c)
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
    let open = MenuItem::with_id(app, "open", t("打开 Blurt", "Open Blurt"), true, None::<&str>)?;
    let record = MenuItem::with_id(app, "record", t("录制", "Record"), true, None::<&str>)?;
    let snap = MenuItem::with_id(app, "snap", t("截图", "Snap"), true, None::<&str>)?;
    let quit = MenuItem::with_id(app, "quit", t("退出 Blurt", "Quit Blurt"), true, None::<&str>)?;
    let sep = PredefinedMenuItem::separator(app)?;
    let menu = Menu::with_items(app, &[&open, &record, &snap, &sep, &quit])?;
    *app.state::<AppState>().tray_record.lock().unwrap() = Some(record);
    let mut b = TrayIconBuilder::with_id("main").menu(&menu).tooltip("Blurt").show_menu_on_left_click(false);
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
        .plugin(tauri_plugin_updater::Builder::new().build())
        .plugin(
            tauri_plugin_global_shortcut::Builder::new()
                .with_handler(|app, sc, ev| {
                    if ev.state == ShortcutState::Pressed {
                        if let Some(a) = hotkeys::action_for(app, sc) {
                            hotkeys::fire(app, &a);
                        }
                    }
                })
                .build(),
        )
        .manage(hotkeys::Hotkeys::default())
        .manage(watcher::WatchState::default())
        .setup(|app| {
            let handle = app.handle().clone();
            app.manage(AppState {
                runner: RwLock::new(Runner::new(&handle)),
                capture: capture::Capture::default(),
                runs: Arc::new(agents::Runs::default()),
                tray_record: Mutex::new(None),
            });
            if let Err(e) = tray(&handle) {
                eprintln!("blurt: no tray: {e}"); // e.g. GNOME without the AppIndicator extension
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
            index_sessions,
            index_workspaces,
            index_summary,
            index_item,
            index_rescan,
            review_load,
            review_poll,
            review_ops,
            agents_detect,
            agent_run,
            agent_runs,
            agent_stop,
            agent_prompt,
            fix_with_agent,
            process_session,
            settings_get,
            settings_set,
            shortcut_set,
            asr_models,
            reveal,
            open_external,
            open_path,
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
