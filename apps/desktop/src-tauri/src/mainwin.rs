//! The main window's own native parts (docs/design/windows-parity/main-window.md):
//! - its frame (size, position, maximized) kept in `$BLURT_HOME/ui/main-window.json` under `frame`, as the Mac keeps its
//!   window state there, and put back at launch when it still lands on a screen;
//! - rows dragged out to other apps: Windows' own file drag (OLE, the `drag` crate, as the island's cards), so Explorer
//!   copies the files, a chat app takes the picture and a terminal pastes the paths.

use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::Duration;

use serde_json::{json, Value};
use tauri::{AppHandle, LogicalSize, Manager, PhysicalPosition, PhysicalSize, WebviewWindow};

use crate::paths;

fn state_file() -> PathBuf {
    paths::blurt_home().join("ui").join("main-window.json")
}

/// The saved frame, if any: {x, y, w, h, maximized}.
pub fn saved_frame() -> Option<Value> {
    frame_at(&state_file())
}

fn frame_at(p: &std::path::Path) -> Option<Value> {
    let v: Value = serde_json::from_str(&std::fs::read_to_string(p).ok()?).ok()?;
    v.get("frame").filter(|f| f["w"].as_f64().unwrap_or(0.0) >= 400.0 && f["h"].as_f64().unwrap_or(0.0) >= 300.0).cloned()
}

fn write_frame(frame: Value) {
    write_frame_at(&state_file(), frame);
}

fn write_frame_at(p: &std::path::Path, frame: Value) {
    let p = p.to_path_buf();
    let mut v: Value = std::fs::read_to_string(&p).ok().and_then(|s| serde_json::from_str(&s).ok()).unwrap_or_else(|| json!({}));
    if !v.is_object() {
        v = json!({});
    }
    v["frame"] = frame;
    if let Some(d) = p.parent() {
        let _ = std::fs::create_dir_all(d);
    }
    let tmp = p.with_extension("json.tmp");
    if std::fs::write(&tmp, v.to_string()).is_ok() {
        let _ = std::fs::rename(&tmp, &p);
    }
}

/// The smallest the window may be (tauri.conf.json minWidth / minHeight, logical px): a programmatic set_size isn't
/// held to it.
const MIN: (f64, f64) = (960.0, 520.0);

/// A screen in physical px: (x, y, w, h) of its work area and its scale.
type Screen = ((i32, i32, u32, u32), f64);

fn screens(w: &WebviewWindow) -> Vec<Screen> {
    w.available_monitors()
        .unwrap_or_default()
        .iter()
        .map(|m| {
            let a = m.work_area();
            ((a.position.x, a.position.y, a.size.width, a.size.height), m.scale_factor())
        })
        .collect()
}

/// Where a saved frame goes back: on the screen that holds its title bar (else the first screen, centred), its size
/// in that screen's pixels, at least the window's minimum, at most the work area, and all of it inside the work area.
/// Frames saved before 2026-11 hold physical px (no `scale`): read at the target screen's scale.
/// `chrome`: the window's frame around its page (title bar, borders; logical px) — the size saved and set is the page's,
/// the frame must fit on the screen too. Returns (x, y) of the frame and (w, h) of the page, physical, and whether it
/// fits (else the window is maximized).
fn place(f: &Value, screens: &[Screen], chrome: (f64, f64)) -> Option<((i32, i32, u32, u32), bool)> {
    let (x, y) = (f["x"].as_i64().unwrap_or(0) as i32, f["y"].as_i64().unwrap_or(0) as i32);
    let (fw, fh) = (f["w"].as_f64().unwrap_or(1280.0), f["h"].as_f64().unwrap_or(800.0));
    let logical = f["scale"].as_f64().is_some();
    let hit = |&&((sx, sy, sw, sh), s): &&Screen| {
        let width = if logical { fw * s } else { fw };
        let (cx, cy) = (x + (width / 2.0) as i32, y + (16.0 * s) as i32);
        cx >= sx && cx < sx + sw as i32 && cy >= sy && cy < sy + sh as i32
    };
    let (found, screen) = match screens.iter().find(hit) {
        Some(s) => (true, *s),
        None => (false, *screens.first()?),
    };
    let ((sx, sy, sw, sh), s) = screen;
    let (cw, ch) = ((chrome.0 * s).round(), (chrome.1 * s).round());
    let (room_w, room_h) = ((sw as f64 - cw).max(0.0), (sh as f64 - ch).max(0.0));
    let (mut w, mut h) = if logical { (fw * s, fh * s) } else { (fw, fh) };
    let (min_w, min_h) = (MIN.0 * s, MIN.1 * s);
    let fits = min_w <= room_w && min_h <= room_h;
    w = w.max(min_w).min(room_w);
    h = h.max(min_h).min(room_h);
    let (w, h) = (w.round() as u32, h.round() as u32);
    let (ow, oh) = (w + cw as u32, h + ch as u32);
    let (x, y) = if found {
        (x.clamp(sx, sx + sw.saturating_sub(ow) as i32), y.clamp(sy, sy + sh.saturating_sub(oh) as i32))
    } else {
        (sx + (sw.saturating_sub(ow) / 2) as i32, sy + (sh.saturating_sub(oh) / 2) as i32)
    };
    Some(((x, y, w, h), fits))
}

/// The window's frame around its page (logical px). Windows 11's frame includes the invisible resize borders, so a
/// window flush with the work area keeps its edges on it.
fn chrome(w: &WebviewWindow) -> (f64, f64) {
    let k = w.scale_factor().unwrap_or(1.0);
    match (w.outer_size(), w.inner_size()) {
        (Ok(o), Ok(i)) => (o.width.saturating_sub(i.width) as f64 / k, o.height.saturating_sub(i.height) as f64 / k),
        _ => (0.0, 0.0),
    }
}

/// At launch: the last frame back on the main window.
pub fn restore(app: &AppHandle) {
    let Some(w) = app.get_webview_window("main") else { return };
    let Some(f) = saved_frame() else {
        clear_of_island(&w); // the first size, centred (tauri.conf.json): on a short screen its caption reaches the top
        return;
    };
    let Some(((x, y, width, height), fits)) = place(&f, &screens(&w), chrome(&w)) else { return };
    // position first: on another screen's scale Windows resizes the window as it arrives, then the size lands
    let _ = w.set_position(PhysicalPosition::new(x, y));
    let _ = w.set_size(PhysicalSize::new(width, height));
    if f["maximized"].as_bool() == Some(true) || !fits {
        let _ = w.maximize();
    } else {
        clear_of_island(&w);
    }
}

/// A frame saved with its caption under the island (the top edge of the screen, across its centre — round-2 gate:
/// island.launch, main.window, installer.after) comes back nudged down below the island's strip while it fits; one
/// that doesn't reach the screen's centre stays where it was.
fn clear_of_island(w: &WebviewWindow) {
    let (Ok(Some(m)), Ok(pos), Ok(size)) = (w.current_monitor(), w.outer_position(), w.outer_size()) else { return };
    let (a, k) = (m.work_area(), m.scale_factor());
    let mid = m.position().x + m.size().width as i32 / 2;
    let half = (160.0 * k) as i32; // the island's widest resting capsule and its shadow, about the centre
    let across = pos.x < mid + half && pos.x + size.width as i32 > mid - half;
    let top = a.position.y + (ISLAND_CLEAR * k) as i32;
    let room = a.position.y + a.size.height as i32 - size.height as i32;
    if across && pos.y < top && room > pos.y {
        let _ = w.set_position(PhysicalPosition::new(pos.x, top.min(room)));
    }
}

static GEN: AtomicU64 = AtomicU64::new(0);

/// The setup assistant shows: the window is the assistant's own size (the Mac's is a window of its own, 840×560;
/// here 880×600 with Windows' larger text), not resizable, and its frame isn't saved meanwhile.
static WELCOME: AtomicBool = AtomicBool::new(false);
const WELCOME_SIZE: (f64, f64) = (880.0, 600.0);

/// The assistant's size, no larger than the screen's work area (logical px).
fn welcome_size(w: &WebviewWindow) -> LogicalSize<f64> {
    let (mut lw, mut lh) = WELCOME_SIZE;
    if let Ok(Some(m)) = w.current_monitor() {
        let (a, k, c) = (m.work_area(), m.scale_factor(), chrome(w));
        lw = lw.min(a.size.width as f64 / k - c.0);
        lh = lh.min(a.size.height as f64 / k - c.1);
    }
    LogicalSize::new(lw, lh)
}

/// The island's strip at the top centre of the screen (island.rs: a 30 px capsule 6 px down, its bubble under it) in
/// logical px: a centred window keeps its title bar below it when the screen has the room, so the island never sits on
/// the assistant's heading or the window's caption (round-1 gate: welcome.2-dictation-heard, main.window).
const ISLAND_CLEAR: f64 = 48.0;

/// Centre the window, then nudge it down below the island's strip while it still fits in the work area.
fn center_below_island(w: &WebviewWindow) {
    let _ = w.center();
    let (Ok(Some(m)), Ok(pos), Ok(size)) = (w.current_monitor(), w.outer_position(), w.outer_size()) else { return };
    let (a, k) = (m.work_area(), m.scale_factor());
    let top = a.position.y + (ISLAND_CLEAR * k) as i32;
    let room = a.position.y + a.size.height as i32 - size.height as i32;
    if pos.y < top {
        let _ = w.set_position(PhysicalPosition::new(pos.x, top.min(room).max(a.position.y)));
    }
}

/// The main window as the setup assistant (`on`), or back to the user's own frame.
pub fn welcome_frame(app: &AppHandle, on: bool) {
    let Some(w) = app.get_webview_window("main") else { return };
    if WELCOME.swap(on, Ordering::SeqCst) == on {
        return;
    }
    if on {
        let _ = w.unmaximize();
        let _ = w.set_min_size(None::<LogicalSize<f64>>);
        let _ = w.set_size(welcome_size(&w));
        center_below_island(&w);
        let _ = w.set_resizable(false);
        let _ = w.set_maximizable(false);
    } else {
        let _ = w.set_resizable(true);
        let _ = w.set_maximizable(true);
        let _ = w.set_min_size(Some(LogicalSize::new(MIN.0, MIN.1)));
        if saved_frame().is_some() {
            restore(app);
        } else {
            // the window's first size (tauri.conf.json), within the screen
            let mut size = LogicalSize::<f64>::new(1280.0, 800.0);
            if let Ok(Some(m)) = w.current_monitor() {
                let (a, k, c) = (m.work_area(), m.scale_factor(), chrome(&w));
                size.width = size.width.min(a.size.width as f64 / k - c.0).max(MIN.0);
                size.height = size.height.min(a.size.height as f64 / k - c.1).max(MIN.1);
            }
            let _ = w.set_size(size);
            center_below_island(&w);
        }
    }
}

/// The setup assistant is on screen in the main window (the tray's Show Download goes there).
pub fn welcome_shown() -> bool {
    WELCOME.load(Ordering::SeqCst)
}

/// The page shows (`on`) or leaves the setup assistant.
#[tauri::command]
pub fn welcome_window(app: AppHandle, on: bool) {
    welcome_frame(&app, on);
}

/// The window moved or was resized: its frame saved a moment later (once a drag of its edge settles). A minimized
/// window keeps the last frame it had; a maximized one keeps its normal frame and says it was maximized.
pub fn changed(w: &tauri::Window) {
    if w.label() != "main" || WELCOME.load(Ordering::SeqCst) {
        return;
    }
    let g = GEN.fetch_add(1, Ordering::SeqCst) + 1;
    let app = w.app_handle().clone();
    std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(600));
        if GEN.load(Ordering::SeqCst) != g {
            return;
        }
        let Some(w) = app.get_webview_window("main") else { return };
        if WELCOME.load(Ordering::SeqCst) || w.is_minimized().unwrap_or(false) || !w.is_visible().unwrap_or(false) {
            return;
        }
        let maximized = w.is_maximized().unwrap_or(false);
        let prev = saved_frame();
        let (pos, size) = (w.outer_position().ok(), w.inner_size().ok());
        let frame = match (maximized, prev, pos, size) {
            (true, Some(mut p), ..) => {
                p["maximized"] = json!(true);
                p
            }
            // the size in logical px with the scale it was saved at, so another scale (150 %, another screen) gets the
            // same window back rather than the same pixels
            (_, _, Some(p), Some(s)) => {
                let k = w.scale_factor().unwrap_or(1.0);
                let (lw, lh) = (s.width as f64 / k, s.height as f64 / k);
                json!({"x": p.x, "y": p.y, "w": lw.round(), "h": lh.round(), "scale": k, "maximized": maximized})
            }
            _ => return,
        };
        write_frame(frame);
    });
}

/// Rows dragged out of the list: Windows' own drag of their files (the first picture, else the .md). Ok(false) when it
/// can't start here (another system, no files, BLURT_ROW_DRAGOUT=0): the page keeps its in-window drag then.
#[tauri::command(async)]
pub fn items_drag_out(app: AppHandle, state: tauri::State<'_, crate::AppState>, uids: Vec<String>) -> Result<bool, String> {
    let rows: Vec<Value> = uids.iter().filter_map(|u| state.index().item(u).ok().flatten()).collect();
    let files = crate::items::drag_files(&rows);
    if files.is_empty() || !drag_out_available() {
        return Ok(false);
    }
    start(&app, files)
}

/// Whether rows drag out as files here (Windows; BLURT_ROW_DRAGOUT=0 turns it off).
#[tauri::command]
pub fn items_drag_out_available() -> bool {
    drag_out_available()
}

fn drag_out_available() -> bool {
    cfg!(windows) && std::env::var("BLURT_ROW_DRAGOUT").map_or(true, |v| v != "0")
}

#[cfg(windows)]
fn start(app: &AppHandle, files: Vec<PathBuf>) -> Result<bool, String> {
    use tauri::Emitter;
    let image = files
        .iter()
        .find(|f| f.extension().and_then(|e| e.to_str()).is_some_and(|e| ["png", "jpg", "jpeg", "gif", "bmp", "webp"].contains(&e.to_lowercase().as_str())))
        .map(|f| drag::Image::File(f.clone()))
        .unwrap_or_else(|| drag::Image::Raw(include_bytes!("../icons/32x32.png").to_vec()));
    let app2 = app.clone();
    app.run_on_main_thread(move || {
        let Some(w) = app2.get_webview_window("main") else { return };
        let app3 = app2.clone();
        let done = move |r: drag::DragResult, _: drag::CursorPosition| {
            let result = if matches!(r, drag::DragResult::Dropped) { "dropped" } else { "cancel" };
            let _ = app3.emit("mainwin://dragout", json!({"result": result}));
        };
        if drag::start_drag(&w, drag::DragItem::Files(files), image, done, drag::Options::default()).is_err() {
            let _ = app2.emit("mainwin://dragout", json!({"result": "cancel"}));
        }
    })
    .map_err(|e| e.to_string())?;
    Ok(true)
}

#[cfg(not(windows))]
fn start(_: &AppHandle, _: Vec<PathBuf>) -> Result<bool, String> {
    Ok(false)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn frame_round_trip_keeps_other_keys() {
        let d = tempfile::tempdir().unwrap();
        let f = d.path().join("ui/main-window.json");
        std::fs::create_dir_all(d.path().join("ui")).unwrap();
        std::fs::write(&f, r#"{"scope":"inbox"}"#).unwrap();
        write_frame_at(&f, json!({"x": 10, "y": 20, "w": 1300, "h": 820, "maximized": false}));
        let v: Value = serde_json::from_str(&std::fs::read_to_string(&f).unwrap()).unwrap();
        assert_eq!(v["scope"], "inbox");
        assert_eq!(frame_at(&f).unwrap()["w"], 1300);
        write_frame_at(&f, json!({"x": 0, "y": 0, "w": 100, "h": 100}));
        assert!(frame_at(&f).is_none(), "a frame too small to use is ignored");
    }

    #[test]
    fn frames_come_back_inside_the_screen_and_above_the_minimum() {
        // 1920×1080 at 150 %: work area 1920×1032
        let s150 = [((0, 0, 1920, 1032), 1.5)];
        // saved at 100 % as 937×558 logical: back as 1440×837 physical (960×558 logical, the minimum width)
        let f = json!({"x": 100, "y": 50, "w": 937, "h": 558, "scale": 1.0});
        assert_eq!(place(&f, &s150, (0.0, 0.0)), Some(((100, 50, 1440, 837), true)));
        // a big frame from a 2560×1600 screen: no larger than the work area, pulled inside it
        let f = json!({"x": 300, "y": 200, "w": 2400, "h": 1500, "scale": 1.0});
        assert_eq!(place(&f, &s150, (0.0, 0.0)), Some(((0, 0, 1920, 1032), true)));
        // an old physical frame (no scale) larger than the screen
        let f = json!({"x": 0, "y": 0, "w": 1942, "h": 1106});
        assert_eq!(place(&f, &s150, (0.0, 0.0)), Some(((0, 0, 1920, 1032), true)));
        // off every screen (a monitor unplugged): centred on the first
        let f = json!({"x": 5000, "y": 0, "w": 1000, "h": 600, "scale": 1.0});
        assert_eq!(place(&f, &[((0, 0, 1920, 1040), 1.0)], (0.0, 0.0)), Some(((460, 220, 1000, 600), true)));
        // a screen smaller than the minimum: the window fills it and is maximized
        let f = json!({"x": 0, "y": 0, "w": 1280, "h": 800, "scale": 1.0});
        assert_eq!(place(&f, &[((0, 0, 1024, 728), 1.5)], (0.0, 0.0)), Some(((0, 0, 1024, 728), false)));
        // the frame counts: a page as big as it can be leaves room for the title bar and borders (Windows 11: 14 + 37
        // logical) — 1942×1064 on a 1920×1032 work area was the dogfood's
        let f = json!({"x": 150, "y": 120, "w": 1384, "h": 781, "scale": 1.0});
        assert_eq!(place(&f, &s150, (14.0, 37.0)), Some(((0, 0, 1899, 976), true)));
    }
}
