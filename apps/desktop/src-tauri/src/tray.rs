//! The tray icon and its menu: the Mac's menu-bar menu (BlurtApp App/AppDelegate.swift `menuNeedsUpdate`,
//! SnapApp.swift `addSnapMenuItems` / `addWaitingMenuItems`), item for item, in its order. Windows conventions: a left
//! click opens the window, the right click opens this menu; the words in sentence case, as Windows 11's menus and the
//! island's (island.md 12.10); Windows menus have no badges or subtitles, so the counts go in the row's title as the
//! Mac does before macOS 14.4 ("Open Blurt · 9 new, 6 to verify"); a hotkey shows at the row's right end only while it
//! works; the one emphasis is the default item's bold. Audit: docs/design/windows-parity/settings.md.
//!
//!   recording   Recording · 1:23 (greyed; the Mac's menu-bar clock) — **Finish recording** · Save video only ·
//!               Pause / Resume · Start over · Discard recording — Snap · Live caption ✓   (no Quit, as on the Mac)
//!   idle        [**Download speech model for dictation…** | Speech model · x / y MB ▸] — Start recording · Snap ·
//!               Copy text from screen · Translate text from screen · Voice note (each with its key) — Open Blurt ·
//!               counts · Show cards · n · Dictation history… · running jobs — Project (greyed header) · X ▸
//!               (Unassigned and the projects as one checked group, Switch project…, Add project folder…) — Settings… ·
//!               [Check for updates… —] Quit Blurt
//!
//! Keys: only the capture verbs carry theirs (that is where the menu teaches them); Open Blurt, Show Cards and Switch
//! Project don't — a tray menu's accelerator does nothing while it's open, and Settings → Shortcuts lists them all.
//!
//! The popup: Windows' tray code opens it at the pointer, bottom-aligned, so it sat over the taskbar and hid the
//! icon it belongs to (and the clock). Blurt opens it itself (popup_above_taskbar): above the taskbar's edge, centred
//! on the icon, the icon's rectangle excluded — where Windows 11's own tray flyouts stand.
//!
//! The menu is built once and kept. A change of words, keys, counts, ticks or the download's "x / y" is made in place
//! on the live menu (muda edits the HMENU Windows shows, which is safe); only a change of rows (idle ↔ recording, a
//! job coming or going, the projects) builds a new one, and never while the menu is on screen: Windows would go on
//! showing a destroyed HMENU, an empty 6-px popup. That change waits until the menu closes. Every refresh is worked
//! out off the main thread and applied on it, so a listener can never re-enter a lock its emitter holds
//! (hotkeys::apply → emit → here).
//!
//! The icon: Peep in black or white for the taskbar's own theme (Windows' SystemUsesLightTheme, not the apps' theme:
//! Windows 10's default is a dark taskbar with light apps), followed live. While a take rolls it is the Mac's
//! menu-bar recording state: the red record dot (paused: the attention-coloured pause), and the time in the tooltip,
//! since Windows can't put the Mac's clock beside a tray icon.

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Mutex;
use std::time::Duration;

use serde_json::{json, Value};
use tauri::menu::{CheckMenuItem, IsMenuItem, Menu, MenuItem, PredefinedMenuItem, Submenu};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Emitter, Listener, Manager, Wry};

use crate::capture::Control;
use crate::projects::Registry;
use crate::{hotkeys, island, jobs, l10n, show_main, AppState};

/// One row of the menu as it should be.
#[derive(Clone, Debug, PartialEq)]
enum Node {
    Item { id: String, text: String, enabled: bool, key: Option<String> },
    Check { id: String, text: String, checked: bool },
    Sep,
    Sub { id: String, text: String, kids: Vec<Node> },
}

/// The rows' shape: what can't be changed in place.
fn shape(nodes: &[Node]) -> String {
    nodes
        .iter()
        .map(|n| match n {
            Node::Item { id, .. } => format!("i:{id}"),
            Node::Check { id, .. } => format!("c:{id}"),
            Node::Sep => "-".into(),
            Node::Sub { id, kids, .. } => format!("s:{id}[{}]", shape(kids)),
        })
        .collect::<Vec<_>>()
        .join(",")
}

enum Handle {
    Item(MenuItem<Wry>),
    Check(CheckMenuItem<Wry>),
    Sub(Submenu<Wry>),
}

struct Live {
    shape: String,
    rows: Vec<Node>,
    handles: HashMap<String, Handle>,
    /// the menu on the icon (its HMENU is what popup_above_taskbar shows)
    #[cfg_attr(not(windows), allow(dead_code))]
    menu: Menu<Wry>,
}

#[derive(Default)]
pub struct TrayState {
    /// a speech model coming down: (done MB, total MB) from `model-download` events
    download: Mutex<Option<(f64, f64)>>,
    live: Mutex<Option<Live>>,
    /// a refresh is on its way (it reads the newest state when it runs)
    queued: AtomicBool,
    /// plans in the order they were worked out: an older one never lands over a newer one
    planned: AtomicU64,
    applied: AtomicU64,
    /// the icon now on the taskbar: (black for a light taskbar, the take's state, its size in px)
    look: Mutex<Option<(bool, Take, u32)>>,
}

/// Make the icon (once, at launch). Err: the desktop has no tray (GNOME without the AppIndicator extension).
pub fn build(app: &AppHandle) -> tauri::Result<()> {
    app.manage(TrayState::default());
    let rows = plan(app);
    let (menu, handles) = make(app, &rows)?;
    let black = icon_black(app);
    *app.state::<TrayState>().look.lock().unwrap() = Some((black, Take::Idle, tray_px()));
    let mut b = TrayIconBuilder::with_id("main").menu(&menu).tooltip(l10n::t("tray.tooltip")).show_menu_on_left_click(false);
    match tauri::image::Image::from_bytes(icon_png(black, Take::Idle)) {
        Ok(icon) => b = b.icon(icon).icon_as_template(cfg!(target_os = "macos")),
        Err(_) => {
            if let Some(icon) = app.default_window_icon() {
                b = b.icon(icon.clone());
            }
        }
    }
    b.on_menu_event(|app, ev| chose(app, ev.id().as_ref()))
        .on_tray_icon_event(|tray, ev| match ev {
            TrayIconEvent::Click { button: MouseButton::Left, button_state: MouseButtonState::Up, .. } => show_main(tray.app_handle()),
            #[cfg(windows)]
            TrayIconEvent::Click { button: MouseButton::Right, button_state: MouseButtonState::Up, rect, .. } => popup_above_taskbar(tray.app_handle(), rect),
            // the pointer arriving: counts and keys brought up to date (in place; a new shape waits for a closed menu)
            TrayIconEvent::Enter { .. } => refresh_soon(tray.app_handle()),
            _ => {}
        })
        .build(app)?;
    // the right click's menu is opened here, above the taskbar (tray-icon's own opens it over the taskbar)
    #[cfg(windows)]
    let _ = app.run_on_main_thread(win_popup::take_right_click);
    *app.state::<TrayState>().live.lock().unwrap() = Some(Live { shape: shape(&rows), rows, handles, menu });
    // what the menu shows changed
    for ev in ["projects://changed", "jobs://changed", "index://changed", "hotkeys://changed"] {
        let h = app.clone();
        app.listen_any(ev, move |_| refresh_soon(&h));
    }
    let h = app.clone();
    app.listen_any("model-download", move |e| {
        let v: Value = serde_json::from_str(e.payload()).unwrap_or_default();
        let st = h.state::<TrayState>();
        *st.download.lock().unwrap() = (v["state"] == "running").then(|| (v["done_mb"].as_f64().unwrap_or(0.0), v["total_mb"].as_f64().unwrap_or(0.0)));
        refresh_soon(&h);
    });
    watch_taskbar(app);
    Ok(())
}

/// Bring the menu up to date: soon, from another thread, so it is safe from any listener or under any lock.
pub fn refresh(app: &AppHandle) {
    schedule(app, Duration::from_millis(30));
}

/// The same, gathering a burst of events (index rows, download lines) into one update.
fn refresh_soon(app: &AppHandle) {
    schedule(app, Duration::from_millis(150));
}

/// Trailing edge: while one is queued, later calls ride on it, since it reads the state when it runs.
fn schedule(app: &AppHandle, delay: Duration) {
    let Some(st) = app.try_state::<TrayState>() else { return };
    if st.queued.swap(true, Ordering::SeqCst) {
        return;
    }
    let h = app.clone();
    std::thread::spawn(move || {
        std::thread::sleep(delay);
        let st = h.state::<TrayState>();
        st.queued.store(false, Ordering::SeqCst);
        let n = st.planned.fetch_add(1, Ordering::SeqCst) + 1;
        let rows = plan(&h);
        let h2 = h.clone();
        let _ = h.run_on_main_thread(move || apply(&h2, n, rows));
    });
}

/// On the main thread: the plan onto the live menu.
fn apply(app: &AppHandle, n: u64, rows: Vec<Node>) {
    let st = app.state::<TrayState>();
    if st.applied.load(Ordering::SeqCst) > n {
        return; // a newer plan already landed
    }
    let Some(tray) = app.tray_by_id("main") else { return };
    let mut live = st.live.lock().unwrap();
    let same = live.as_ref().is_some_and(|l| l.shape == shape(&rows));
    if same {
        let l = live.as_mut().unwrap();
        if l.rows != rows {
            update(&l.handles, &l.rows, &rows);
            l.rows = rows;
        }
    } else if menu_on_screen() {
        // a new shape can't replace the menu Windows is showing: again once it has closed
        drop(live);
        schedule(app, Duration::from_millis(500));
        return;
    } else if let Ok((menu, handles)) = make(app, &rows) {
        let _ = tray.set_menu(Some(menu.clone()));
        *live = Some(Live { shape: shape(&rows), rows, handles, menu });
    }
    st.applied.fetch_max(n, Ordering::SeqCst);
    drop(live);
    retint(app); // a take started or ended (on_recording refreshes): the icon too
}

/// Words, keys, ticks and enabled states changed in place (same shape).
fn update(handles: &HashMap<String, Handle>, old: &[Node], new: &[Node]) {
    for (o, n) in old.iter().zip(new) {
        if o == n {
            continue;
        }
        match (n, o) {
            (Node::Item { id, text, enabled, key }, Node::Item { text: t0, enabled: e0, key: k0, .. }) => {
                if let Some(Handle::Item(m)) = handles.get(id) {
                    if key != k0 {
                        let _ = m.set_accelerator(key.as_deref());
                    }
                    if text != t0 || key != k0 {
                        let _ = m.set_text(text);
                    }
                    if enabled != e0 {
                        let _ = m.set_enabled(*enabled);
                    }
                }
            }
            (Node::Check { id, text, checked }, Node::Check { text: t0, checked: c0, .. }) => {
                if let Some(Handle::Check(m)) = handles.get(id) {
                    if text != t0 {
                        let _ = m.set_text(text);
                    }
                    if checked != c0 {
                        let _ = m.set_checked(*checked);
                    }
                }
            }
            (Node::Sub { id, text, kids }, Node::Sub { text: t0, kids: k0, .. }) => {
                if let Some(Handle::Sub(m)) = handles.get(id) {
                    if text != t0 {
                        let _ = m.set_text(text);
                    }
                }
                update(handles, k0, kids);
            }
            _ => {}
        }
    }
}

fn make(app: &AppHandle, rows: &[Node]) -> tauri::Result<(Menu<Wry>, HashMap<String, Handle>)> {
    let mut handles = HashMap::new();
    let items = make_rows(app, rows, &mut handles)?;
    let refs: Vec<&dyn IsMenuItem<Wry>> = items.iter().map(|b| b.as_ref()).collect();
    Ok((Menu::with_items(app, &refs)?, handles))
}

fn make_rows(app: &AppHandle, rows: &[Node], handles: &mut HashMap<String, Handle>) -> tauri::Result<Vec<Box<dyn IsMenuItem<Wry>>>> {
    let mut out: Vec<Box<dyn IsMenuItem<Wry>>> = Vec::new();
    for n in rows {
        match n {
            Node::Item { id, text, enabled, key } => {
                // an accelerator muda can't read must never take the row with it
                let m = match key {
                    Some(k) => MenuItem::with_id(app, id, text, *enabled, Some(k.as_str()))
                        .or_else(|_| MenuItem::with_id(app, id, text, *enabled, None::<&str>))?,
                    None => MenuItem::with_id(app, id, text, *enabled, None::<&str>)?,
                };
                handles.insert(id.clone(), Handle::Item(m.clone()));
                out.push(Box::new(m));
            }
            Node::Check { id, text, checked } => {
                let m = CheckMenuItem::with_id(app, id, text, true, *checked, None::<&str>)?;
                handles.insert(id.clone(), Handle::Check(m.clone()));
                out.push(Box::new(m));
            }
            Node::Sep => out.push(Box::new(PredefinedMenuItem::separator(app)?)),
            Node::Sub { id, text, kids } => {
                let k = make_rows(app, kids, handles)?;
                let refs: Vec<&dyn IsMenuItem<Wry>> = k.iter().map(|b| b.as_ref()).collect();
                let m = Submenu::with_id_and_items(app, id, text, true, &refs)?;
                handles.insert(id.clone(), Handle::Sub(m.clone()));
                out.push(Box::new(m));
            }
        }
    }
    Ok(out)
}

/// Whether a menu of this (the main) thread is on screen now.
#[cfg(windows)]
fn menu_on_screen() -> bool {
    use windows::Win32::System::Threading::GetCurrentThreadId;
    use windows::Win32::UI::WindowsAndMessaging::{GetGUIThreadInfo, GUITHREADINFO, GUI_INMENUMODE, GUI_POPUPMENUMODE};
    let mut info = GUITHREADINFO { cbSize: std::mem::size_of::<GUITHREADINFO>() as u32, ..Default::default() };
    unsafe { GetGUIThreadInfo(GetCurrentThreadId(), &mut info) }.is_ok() && (info.flags.0 & (GUI_INMENUMODE.0 | GUI_POPUPMENUMODE.0)) != 0
}

#[cfg(not(windows))]
fn menu_on_screen() -> bool {
    false
}

// ------------------------------------------------------------------ the popup

/// The right click's menu, opened by Blurt above the taskbar: its bottom on the taskbar's top edge (its top edge for a
/// taskbar at the top, its side for one at the left / right), centred on the icon, with the icon's rectangle excluded
/// so it never covers it — where Windows 11's tray flyouts stand. tray-icon's own popup (at the pointer, bottom-
/// aligned) stood on the taskbar and hid Blurt's own icon and the clock (round-1 gate, tray.menu-recording).
#[cfg(windows)]
fn popup_above_taskbar(app: &AppHandle, rect: tauri::Rect) {
    let Some(st) = app.try_state::<TrayState>() else { return };
    let (menu, bold, checks) = match st.live.lock().unwrap().as_ref() {
        Some(l) => (l.menu.clone(), default_row(&l.rows), l.rows.iter().any(|n| matches!(n, Node::Check { .. }))),
        None => return,
    };
    // counts and keys up to date before it shows (the Enter refresh may still be on its way)
    let Ok(hmenu) = tauri::menu::ContextMenu::hpopupmenu(&menu) else { return };
    let p = rect.position.to_physical::<i32>(1.0);
    let z = rect.size.to_physical::<i32>(1.0);
    win_popup::show(hmenu, (p.x, p.y, p.x + z.width, p.y + z.height), bold, checks);
}

#[cfg(windows)]
mod win_popup {
    use windows::core::BOOL;
    use windows::Win32::Foundation::{HWND, LPARAM, POINT, RECT, WPARAM};
    use windows::Win32::Graphics::Gdi::{GetMonitorInfoW, MonitorFromPoint, MONITORINFO, MONITOR_DEFAULTTONEAREST};
    use windows::Win32::System::Threading::GetCurrentThreadId;
    use windows::Win32::UI::WindowsAndMessaging::{
        EnumThreadWindows, GetClassNameW, PostMessageW, SendMessageW, SetForegroundWindow, SetMenuDefaultItem, SetMenuInfo,
        TrackPopupMenuEx, HMENU, MENUINFO, MENUINFO_STYLE, MIM_STYLE, MNS_NOCHECK, TPMPARAMS, TPM_BOTTOMALIGN, TPM_CENTERALIGN, TPM_LEFTALIGN, TPM_RIGHTALIGN, TPM_RIGHTBUTTON, TPM_TOPALIGN, TPM_VERTICAL,
        TRACK_POPUP_MENU_FLAGS, WM_NULL,
    };

    /// tray-icon's window (class "tray_icon_app") on this thread: it owns the menu (muda's subclass on it turns a pick
    /// into the menu event), so the popup is opened for it.
    fn tray_hwnd() -> Option<HWND> {
        unsafe extern "system" fn each(h: HWND, l: LPARAM) -> BOOL {
            let mut buf = [0u16; 64];
            let n = unsafe { GetClassNameW(h, &mut buf) } as usize;
            if String::from_utf16_lossy(&buf[..n]) == "tray_icon_app" {
                unsafe { *(l.0 as *mut isize) = h.0 as isize };
                return false.into();
            }
            true.into()
        }
        let mut found: isize = 0;
        unsafe {
            let _ = EnumThreadWindows(GetCurrentThreadId(), Some(each), LPARAM(&mut found as *mut isize as isize));
        }
        (found != 0).then(|| HWND(found as *mut _))
    }

    /// tray-icon opens the menu on a right click unless told not to (its WM_USER_SHOW_MENU_ON_RIGHT_CLICK = 6009):
    /// Blurt opens it itself.
    pub fn take_right_click() {
        if let Some(h) = tray_hwnd() {
            unsafe { SendMessageW(h, 6009, Some(WPARAM(0)), Some(LPARAM(0))) };
        }
    }

    /// `bold`: the row drawn as the default item; `checks`: whether a top-level row carries a check — without one the
    /// menu drops the check column (MNS_NOCHECK), so its labels start at the normal inset rather than after an empty
    /// gutter; the project submenu keeps its own (the style is set on this menu only).
    pub fn show(hmenu: isize, icon: (i32, i32, i32, i32), bold: Option<usize>, checks: bool) {
        let Some(owner) = tray_hwnd() else { return };
        let h = HMENU(hmenu as *mut _);
        unsafe {
            let _ = SetMenuDefaultItem(h, bold.map_or(u32::MAX, |i| i as u32), 1);
            let info = MENUINFO {
                cbSize: std::mem::size_of::<MENUINFO>() as u32,
                fMask: MIM_STYLE,
                dwStyle: if checks { MENUINFO_STYLE(0) } else { MNS_NOCHECK },
                ..Default::default()
            };
            let _ = SetMenuInfo(h, &info);
        }
        let (l, t, r, b) = icon;
        let centre = POINT { x: (l + r) / 2, y: (t + b) / 2 };
        let mut mi = MONITORINFO { cbSize: std::mem::size_of::<MONITORINFO>() as u32, ..Default::default() };
        let mon = unsafe { MonitorFromPoint(centre, MONITOR_DEFAULTTONEAREST) };
        let (work, full) = if unsafe { GetMonitorInfoW(mon, &mut mi) }.as_bool() { (mi.rcWork, mi.rcMonitor) } else { (RECT::default(), RECT::default()) };
        const GAP: i32 = 8;
        // which edge the taskbar is on: where the work area stops short of the monitor
        let (x, y, flags): (i32, i32, TRACK_POPUP_MENU_FLAGS) = if work.top > full.top {
            (centre.x, work.top.max(b) + GAP, TPM_TOPALIGN | TPM_CENTERALIGN)
        } else if work.left > full.left {
            (work.left.max(r) + GAP, centre.y, TPM_LEFTALIGN | TPM_BOTTOMALIGN)
        } else if work.right < full.right {
            (work.right.min(l) - GAP, centre.y, TPM_RIGHTALIGN | TPM_BOTTOMALIGN)
        } else {
            // bottom (or an auto-hidden taskbar: the icon's own top edge)
            let edge = if work.bottom < full.bottom { work.bottom.min(t) } else { t };
            (centre.x, edge - GAP, TPM_BOTTOMALIGN | TPM_CENTERALIGN)
        };
        let params = TPMPARAMS { cbSize: std::mem::size_of::<TPMPARAMS>() as u32, rcExclude: RECT { left: l, top: t, right: r, bottom: b } };
        unsafe {
            // the shell's rule for a notification-area menu: its owner in front, so a click elsewhere closes it, and a
            // benign message after it so the task switch completes
            let _ = SetForegroundWindow(owner);
            let _ = TrackPopupMenuEx(h, (flags | TPM_RIGHTBUTTON | TPM_VERTICAL).0, x, y, owner, Some(&params));
            let _ = PostMessageW(Some(owner), WM_NULL, WPARAM(0), LPARAM(0));
        }
    }
}

// ------------------------------------------------------------------ the icon

/// What the icon shows besides Peep: a take rolling or paused (after its countdown, as the Mac's sessionStart).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Take {
    Idle,
    Rolling,
    Paused,
}

/// The tray pictures (assets/brand/import_peep.py: Peep's mark fitted to each real size, the eye a hole in both tones;
/// the rec / paused glyphs in the token colours for a light or a dark taskbar). Windows: the one drawn for the
/// notification area's size now (16 / 20 / 24 / 32 px at 100 / 125 / 150 / 200 %), never a 64 px picture it shrinks;
/// elsewhere the 64 px ones.
fn icon_png(black: bool, take: Take) -> &'static [u8] {
    macro_rules! sized {
        ($stem:literal) => {
            match tray_px() {
                16 => &include_bytes!(concat!("../icons/", $stem, "-16.png"))[..],
                20 => &include_bytes!(concat!("../icons/", $stem, "-20.png"))[..],
                24 => &include_bytes!(concat!("../icons/", $stem, "-24.png"))[..],
                32 => &include_bytes!(concat!("../icons/", $stem, "-32.png"))[..],
                _ => &include_bytes!(concat!("../icons/", $stem, ".png"))[..],
            }
        };
    }
    match (take, black) {
        (Take::Idle, true) => sized!("tray-black"),
        (Take::Idle, false) => sized!("tray-white"),
        (Take::Rolling, true) => sized!("tray-rec-light"),
        (Take::Rolling, false) => sized!("tray-rec-dark"),
        (Take::Paused, true) => sized!("tray-paused-light"),
        (Take::Paused, false) => sized!("tray-paused-dark"),
    }
}

/// The notification area's icon size now (SM_CXSMICON at the system DPI), as one of the sizes drawn for it.
#[cfg(windows)]
fn tray_px() -> u32 {
    use windows::Win32::UI::WindowsAndMessaging::{GetSystemMetrics, SM_CXSMICON};
    // a DPI-aware process gets the system DPI's size: what the notification area draws at
    let px = unsafe { GetSystemMetrics(SM_CXSMICON) }.max(16) as u32;
    match px {
        0..=17 => 16,
        18..=21 => 20,
        22..=27 => 24,
        _ => 32,
    }
}

#[cfg(not(windows))]
fn tray_px() -> u32 {
    64
}

/// The take's state and its time so far (s).
fn take(app: &AppHandle) -> (Take, f64) {
    let Some(st) = app.try_state::<AppState>() else { return (Take::Idle, 0.0) };
    let cap = st.capture.state();
    let t = if cap["recording"] != true || cap["countdown"] == true {
        Take::Idle
    } else if cap["paused"] == true {
        Take::Paused
    } else {
        Take::Rolling
    };
    (t, cap["elapsed"].as_f64().unwrap_or(0.0))
}

/// Black Peep for a light taskbar, white for a dark one. The Mac's is a template image (black, tinted by the system);
/// Linux panels are dark by default.
fn icon_black(app: &AppHandle) -> bool {
    if cfg!(target_os = "macos") {
        return true;
    }
    if cfg!(target_os = "linux") {
        return false;
    }
    taskbar_light().unwrap_or_else(|| app.get_webview_window("main").and_then(|w| w.theme().ok()) == Some(tauri::Theme::Light))
}

/// HKCU\…\Themes\Personalize\SystemUsesLightTheme: the taskbar's theme (AppsUseLightTheme is the apps').
#[cfg(windows)]
fn taskbar_light() -> Option<bool> {
    use windows::core::w;
    use windows::Win32::System::Registry::{RegGetValueW, HKEY_CURRENT_USER, RRF_RT_REG_DWORD};
    let mut v: u32 = 0;
    let mut n = std::mem::size_of::<u32>() as u32;
    let r = unsafe {
        RegGetValueW(
            HKEY_CURRENT_USER,
            w!("Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize"),
            w!("SystemUsesLightTheme"),
            RRF_RT_REG_DWORD,
            None,
            Some(&mut v as *mut u32 as *mut _),
            Some(&mut n),
        )
    };
    r.is_ok().then_some(v != 0)
}

#[cfg(not(windows))]
fn taskbar_light() -> Option<bool> {
    None
}

/// The icon and tooltip brought up to date: the taskbar's theme (the main window's ThemeChanged, the poll), the take
/// (on_recording's refresh; once a second while it rolls, for the time) and the scale (a DPI change: its own size).
pub fn retint(app: &AppHandle) {
    let Some(st) = app.try_state::<TrayState>() else { return };
    let Some(tray) = app.tray_by_id("main") else { return };
    let (t, secs) = take(app);
    let look = (icon_black(app), t, tray_px());
    let was = st.look.lock().unwrap().replace(look);
    if was != Some(look) {
        if let Ok(icon) = tauri::image::Image::from_bytes(icon_png(look.0, t)) {
            let _ = tray.set_icon(Some(icon));
        }
    }
    match t {
        Take::Idle if was.is_some_and(|w| w.1 != Take::Idle) => crate::island::update_tray(app), // the counts again
        Take::Idle => {}
        _ => {
            let s = secs.max(0.0) as u64;
            let time = format!("{}:{:02}", s / 60, s % 60);
            let key = if t == Take::Paused { "tray.tooltip.paused" } else { "tray.tooltip.recording" };
            let _ = tray.set_tooltip(Some(l10n::tf(key, &[("time", time)])));
        }
    }
}

/// A taskbar-only switch (Personalisation → Colours → Custom) sends the app no theme change: one registry read every
/// few seconds catches it. While a take rolls: every second (its time in the tooltip; a pause from anywhere).
fn watch_taskbar(app: &AppHandle) {
    let h = app.clone();
    std::thread::spawn(move || loop {
        let rolling = h.try_state::<TrayState>().and_then(|s| *s.look.lock().unwrap()).is_some_and(|l| l.1 != Take::Idle);
        std::thread::sleep(Duration::from_secs(if rolling { 1 } else { 3 }));
        let look = (icon_black(&h), take(&h).0, tray_px());
        let was = h.try_state::<TrayState>().and_then(|s| *s.look.lock().unwrap());
        if was != Some(look) || look.1 != Take::Idle {
            // paused / resumed: the menu's Pause row says the other word; while it rolls, its status row's time
            if was.is_some_and(|w| w.1 != look.1) || look.1 != Take::Idle {
                refresh_soon(&h);
            }
            let h2 = h.clone();
            let _ = h.run_on_main_thread(move || retint(&h2));
        }
    });
}

// ------------------------------------------------------------------ the rows

/// The key at a row's right end, for an action whose hotkey works now (the Mac's `showHotkey`: a key that doesn't
/// work isn't shown). Windows: written into the row after a tab, as Settings writes it (Alt+Shift+R), since muda
/// would reorder an accelerator into Shift+Alt+R, and a tray menu's accelerator does nothing anyway. Elsewhere: muda's.
fn keyed(rows: &[Value], text: String, action: &str) -> (String, Option<String>) {
    let Some(row) = rows.iter().find(|r| r["action"] == action && r["result"] == "ok") else { return (text, None) };
    if cfg!(windows) {
        return match row["label"].as_str().filter(|l| !l.is_empty()) {
            Some(l) => (format!("{text}\t{l}"), None),
            None => (text, None),
        };
    }
    let Some(c) = row["spec"].as_str().and_then(hotkeys::parse) else { return (text, None) };
    let mut parts: Vec<String> = c
        .mods
        .iter()
        .map(|m| match m.as_str() {
            "ctrl" => "Ctrl",
            "opt" => "Alt",
            "shift" => "Shift",
            _ => "Super",
        }
        .to_string())
        .collect();
    parts.push(match c.key.as_str() {
        "Left" | "Right" | "Up" | "Down" => format!("Arrow{}", c.key),
        "Return" => "Enter".into(),
        k => k.to_string(),
    });
    (text, Some(parts.join("+")))
}

/// "164 / 716 MB", "0.4 / 1.6 GB": both in the total's unit (the done figure never flips MB → GB mid-way)
fn size_pair(done: f64, total: f64) -> (String, String) {
    if total >= 1000.0 {
        (format!("{:.1}", done / 1024.0), format!("{:.1} GB", total / 1024.0))
    } else {
        (format!("{}", done.round() as i64), format!("{} MB", total.round() as i64))
    }
}

/// "412 MB", "1.6 GB"
#[allow(dead_code)]
fn size(mb: f64) -> String {
    if mb >= 1000.0 {
        format!("{:.1} GB", mb / 1024.0)
    } else {
        format!("{} MB", mb.round() as i64)
    }
}

fn job_line(j: &Value) -> String {
    let what = l10n::t(&format!("job.type.{}", j["type"].as_str().unwrap_or("process")));
    let title = match j["title"].as_str().filter(|t| !t.is_empty()) {
        Some(t) => format!("{what} · {t}"),
        None => what,
    };
    let status = if j["state"] == "failed" {
        l10n::t("tray.job.failed")
    } else {
        let steps = j["steps"].as_array().cloned().unwrap_or_default();
        let step = steps.iter().find(|s| s["state"] == "running").or_else(|| steps.iter().find(|s| s["state"] == "pending"));
        match step.and_then(|s| s["id"].as_str()) {
            Some(id) => l10n::t(&format!("job.step.{id}")),
            None => l10n::t("tray.job.running"),
        }
    };
    format!("{title} · {status}")
}

/// The menu as it should be now (worked out off the main thread).
fn plan(app: &AppHandle) -> Vec<Node> {
    let st = app.state::<AppState>();
    let cap = st.capture.state();
    let hk = hotkeys::rows(app);
    let mut rows: Vec<Node> = Vec::new();
    let item = |id: &str, text: String, action: Option<&str>| {
        let (text, key) = match action {
            Some(a) => keyed(&hk, text, a),
            None => (text, None),
        };
        Node::Item { id: id.into(), text, enabled: true, key }
    };
    let dictation = cfg!(windows);

    if cap["recording"] == true {
        // a take is rolling. First a greyed line with its state and time — the Mac shows "● 1:23" beside its menu-bar
        // icon all the while, and the tooltip that carries it on Windows can't show while the menu is open (§1.17's
        // greyed "Choosing an area…" is the precedent); updated in place each second. Then its controls in the Mac's
        // order and group (Finish · Save video only · Pause · Start over · Discard — recording.md §5.6), Finish the
        // menu's default (bold) item, then a snap of it and the live caption. No Quit while a take rolls, as on the
        // Mac: it would end the take a fourth way.
        let paused = cap["paused"] == true;
        let s = cap["elapsed"].as_f64().unwrap_or(0.0).max(0.0) as u64;
        let time = format!("{}:{:02}", s / 60, s % 60);
        let status = l10n::tf(if paused { "tray.tooltip.paused" } else { "tray.tooltip.recording" }, &[("time", time)]);
        rows.push(Node::Item { id: "take_status".into(), text: status, enabled: false, key: None });
        rows.push(Node::Sep);
        rows.push(item("stop", l10n::t("tray.finish"), Some("stop")));
        rows.push(item("videoonly", l10n::t("tray.video_only"), None));
        rows.push(item("pause", l10n::t(if paused { "tray.resume" } else { "tray.pause" }), Some("pause")));
        rows.push(item("restart", l10n::t("tray.restart"), None));
        rows.push(item("discard", l10n::t("tray.discard"), None));
        rows.push(Node::Sep);
        rows.push(item("snap", l10n::t("tray.snap"), Some("snap")));
        let caption = crate::settings::read_config().pointer("/record/live_caption").and_then(Value::as_bool).unwrap_or(true);
        rows.push(Node::Check { id: "live_caption".into(), text: l10n::t("tray.live_caption"), checked: caption });
        return rows;
    } else if cap["picking"] == true {
        rows.push(Node::Item { id: "picking".into(), text: l10n::t("tray.selecting"), enabled: false, key: None });
    } else {
        // dictation has no speech model yet: the first row says so and leads to it (SpeechSetup.menuRow's .getModel)
        let download = *app.state::<TrayState>().download.lock().unwrap();
        if let Some((done, total)) = download {
            // a short title that keeps the menu its idle width ("Speech model · 164 / 716 MB"), both figures in the
            // total's unit so the row doesn't change width as the bytes tick; the submenu says what is going on and
            // names what Show and Stop act on
            let title = if total > 0.0 {
                let (d, t) = size_pair(done, total);
                l10n::tf("tray.models.row", &[("done", d), ("total", t)])
            } else {
                l10n::t("tray.models.downloading_start")
            };
            let pct = if total > 0.0 { ((done / total) * 100.0).floor().min(99.0) as i64 } else { 0 };
            let kids = vec![
                Node::Item { id: "models_status".into(), text: l10n::tf("tray.models.status", &[("pct", pct.to_string())]), enabled: false, key: None },
                Node::Sep,
                item("models", l10n::t("tray.models.show_download"), None),
                item("models_stop", l10n::t("tray.models.stop_download"), None),
            ];
            rows.push(Node::Sub { id: "sub:download".into(), text: title, kids });
            rows.push(Node::Sep);
        } else if dictation && *crate::dictation::commands::READY.lock().unwrap() == Some(false) && dictation_on() {
            rows.push(item("get_model", l10n::t("tray.get_model"), None));
            rows.push(Node::Sep);
        }
        // the skill and the app don't speak the same contract: said until it's fixed (Settings → General too)
        if let Some(m) = crate::housekeeping::mismatch(crate::housekeeping::skill_contract(st.runner().scripts.as_deref())) {
            rows.push(item("contract", l10n::t(&format!("tray.contract.{m}")), None));
            rows.push(Node::Sep);
        }
        // the capture verbs, each with its key
        rows.push(item("record", l10n::t("tray.record"), Some("record")));
        rows.push(item("snap", l10n::t("tray.snap"), Some("snap")));
        if cfg!(windows) {
            rows.push(item("text", l10n::t("tray.text"), Some("text")));
            rows.push(item("translate", l10n::t("tray.translate"), Some("translate")));
        }
        rows.push(item("voice", l10n::t("tray.voice"), Some("voice")));
        rows.push(Node::Sep);

        // what waits for you: one row opens Blurt — at the inbox, with its counts, when something needs you
        let summary = st.index().summary().unwrap_or_else(|_| json!({}));
        let (fresh, verify) = (summary["new"].as_i64().unwrap_or(0), summary["to_verify"].as_i64().unwrap_or(0));
        // "Open Blurt · 10 new, 2 to verify": one dot between the verb and its status, the counts joined as one
        let mut counts = Vec::new();
        if fresh > 0 {
            counts.push(l10n::tf("tray.inbox.new", &[("n", fresh.to_string())]));
        }
        if verify > 0 {
            counts.push(l10n::tf("tray.inbox.verify", &[("n", verify.to_string())]));
        }
        let open = match counts.is_empty() {
            true => l10n::t("tray.open"),
            false => format!("{} · {}", l10n::t("tray.open"), counts.join(&l10n::t("tray.counts_sep"))),
        };
        // one id with or without counts, so the words change in place; `chose` looks at the counts when clicked
        rows.push(item("open", open, None));
        // Show Cards (the island's cards come down), while any hang, with how many (the Mac's badge, written in the
        // title the way Open Blurt's counts are)
        let cards = crate::capture::load_cards().len();
        if cards > 0 {
            rows.push(item("cards", format!("{} · {cards}", l10n::t("tray.cards")), None));
        }
        if dictation {
            rows.push(item("dictation_history", l10n::t("tray.dictation_history"), None));
        }
        for j in jobs::list(true, 40).iter().take(5) {
            let id = format!("job:{}", j["id"].as_str().unwrap_or(""));
            rows.push(item(&id, job_line(j), None));
        }
        rows.push(Node::Sep);

        // the current project: where new captures go — Unassigned first, then the projects (recently used first)
        // (the Mac's menu: a greyed "Project" heading, then the row with the project's name and its submenu; in the
        // submenu Unassigned is the first choice of one checked group, then the two actions)
        let reg = Registry::load();
        let current = reg.current_project().and_then(|p| p["name"].as_str()).map(str::to_owned);
        let mut sub = vec![Node::Check { id: "project:".into(), text: l10n::t("tray.project.inbox"), checked: current.is_none() }];
        let mut projects = reg.projects.clone();
        projects.sort_by(|a, b| b["last_used"].as_str().unwrap_or("").cmp(a["last_used"].as_str().unwrap_or("")));
        for p in projects.iter().take(12) {
            let id = p["id"].as_str().unwrap_or("");
            let on = reg.current.as_deref() == Some(id);
            sub.push(Node::Check { id: format!("project:{id}"), text: p["name"].as_str().unwrap_or(id).to_string(), checked: on });
        }
        sub.push(Node::Sep);
        sub.push(item("switch_project", l10n::t("tray.switch_project"), None));
        sub.push(item("open_folder", l10n::t("tray.open_folder"), None));
        let name = current.unwrap_or_else(|| l10n::t("tray.project.inbox"));
        rows.push(Node::Item { id: "project_head".into(), text: l10n::t("tray.project.header"), enabled: false, key: None });
        rows.push(Node::Sub { id: "sub:project".into(), text: name, kids: sub });
        rows.push(Node::Sep);

        // the app: Settings, updates (only where this build can update itself). With no updater row, Settings and Quit
        // close the menu as one group (a Windows tray menu's usual end); with it, the Mac's split.
        rows.push(item("settings", l10n::t("tray.settings"), None));
        if updates_configured(app) {
            // a version found in the background and not installed yet: the row names it
            let found = app.try_state::<crate::housekeeping::Moments>().and_then(|m| m.update.lock().unwrap().clone());
            match found {
                Some(v) => rows.push(item("update_now", l10n::tf("tray.update_to", &[("version", v)]), None)),
                None => rows.push(item("updates", l10n::t("tray.updates"), None)),
            }
            rows.push(Node::Sep);
        }
        rows.push(item("quit", l10n::t("tray.quit"), None));
        return rows;
    }
    rows.push(Node::Sep);
    rows.push(item("quit", l10n::t("tray.quit"), None));
    rows
}

/// The row Windows draws bold (SetMenuDefaultItem, its tray menus' one emphasis): Finish while a take rolls, and the
/// speech-model row while dictation can't work without it. Its position in the top-level menu.
#[cfg_attr(not(windows), allow(dead_code))]
fn default_row(rows: &[Node]) -> Option<usize> {
    rows.iter().position(|n| matches!(n, Node::Item { id, .. } if id == "stop" || id == "get_model"))
}

fn dictation_on() -> bool {
    crate::settings::read_config().pointer("/record/dictation/enabled").and_then(Value::as_bool) != Some(false)
}

fn updates_configured(app: &AppHandle) -> bool {
    crate::housekeeping::updates_configured(app)
}

/// The main window at a place: {"view": "settings", "pane": "speech"}, {"view": "inbox"}, {"job": id}…
fn open_at(app: &AppHandle, nav: Value) {
    show_main(app);
    let _ = app.emit("nav", nav);
}

fn chose(app: &AppHandle, id: &str) {
    match id {
        "quit" => app.exit(0),
        "open" => {
            let s = app.state::<AppState>().index().summary().unwrap_or_else(|_| json!({}));
            if s["new"].as_i64().unwrap_or(0) + s["to_verify"].as_i64().unwrap_or(0) > 0 {
                open_at(app, json!({"view": "inbox"}))
            } else {
                show_main(app)
            }
        }
        "inbox" => open_at(app, json!({"view": "inbox"})),
        "dictation_history" => open_at(app, json!({"view": "dictation"})),
        "settings" => open_at(app, json!({"view": "settings"})),
        "updates" => open_at(app, json!({"view": "settings", "pane": "general", "check_updates": true})),
        "update_now" => crate::housekeeping::install_update(app.clone()),
        "contract" => crate::housekeeping::contract_help(app),
        // Show Download: where the download already shows — the Welcome's model step when the assistant is up
        "models" if crate::mainwin::welcome_shown() => show_main(app),
        "models" | "get_model" => open_at(app, json!({"view": "settings", "pane": "speech"})),
        "models_stop" => {
            crate::dictation::commands::model_download_cancel();
        }
        "switch_project" => crate::dispatch(app, "project"),
        "open_folder" => island::open_folder(app, true),
        "videoonly" | "restart" => {
            let cap = &app.state::<AppState>().capture;
            let r = if id == "restart" { cap.restart() } else { cap.control(Control::VideoOnly) };
            if let Err(e) = r {
                let _ = app.emit("capture://status", json!({"ev": "error", "msg": e}));
            }
        }
        "live_caption" => {
            let on = crate::settings::read_config().pointer("/record/live_caption").and_then(Value::as_bool).unwrap_or(true);
            let _ = crate::settings::merge(json!({"record": {"live_caption": !on}}));
            refresh(app);
        }
        "discard" => {
            if let Err(e) = app.state::<AppState>().capture.control(Control::Discard) {
                let _ = app.emit("capture://status", json!({"ev": "error", "msg": e}));
            }
        }
        _ if id.starts_with("job:") => open_at(app, json!({"job": &id[4..]})),
        _ if id.starts_with("project:") => {
            // "project:" = Unassigned; projects.py takes "auto" for no current project
            let pid = match &id[8..] {
                "" => "auto".to_string(),
                p => p.to_string(),
            };
            let h = app.clone();
            std::thread::spawn(move || {
                let runner = h.state::<AppState>().runner();
                if crate::projects::use_project(&runner, &pid).is_ok() {
                    island::refresh(&h);
                    let _ = h.emit("projects://changed", json!({}));
                }
                refresh(&h);
            });
        }
        other => crate::dispatch(app, other),
    }
}
