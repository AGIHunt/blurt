//! The recording's chrome that isn't the island (the Mac's Chrome.swift; docs/design/windows-parity/recording.md
//! §3–4): the 3-2-1 over the area about to be recorded and the frame around the recorded area. Both are pages of
//! `overlays/rec.html`, in windows labelled `blurt-overlay-*` (the overlays capability), content-protected so the
//! recording never sees them (Windows: WDA_EXCLUDEFROMCAPTURE). Created off the main thread (record.py's status lines).

use std::collections::BTreeMap;

use blurt_capture::overlay::{self, OverlayConfig};
use blurt_capture::Region;
use serde_json::{json, Value};
use tauri::{AppHandle, Emitter, Manager, Monitor, PhysicalPosition, PhysicalSize, WebviewUrl, WebviewWindowBuilder};

const COUNTDOWN: &str = "blurt-overlay-countdown";
const FRAME: &str = "blurt-overlay-frame";
const INK: &str = "blurt-overlay-ink";
/// Rust → rec.html: {op: 'countdown', n, total} | {op: 'frame', paused}
const REC_EV: &str = "blurt://rec";

/// The last op sent to each of these windows: a page that wasn't listening yet when it went (a window is made and
/// told at once) gets it again on its `ready` — the pen's first Alt+Shift+D used to be lost that way.
static LAST: std::sync::Mutex<Vec<(&'static str, Value)>> = std::sync::Mutex::new(Vec::new());

fn tell(app: &AppHandle, label: &'static str, op: Value) {
    {
        let mut l = LAST.lock().unwrap();
        l.retain(|(x, _)| *x != label);
        l.push((label, op.clone()));
    }
    let _ = app.emit_to(label, REC_EV, op);
}
/// The countdown panel (logical px, CountdownView.panelSize at its widest with the key line) and the room for its
/// shadow on each side (CountdownView.panelMargin).
const PANEL: (f64, f64) = (300.0, 250.0);
const PANEL_MARGIN: f64 = 40.0;
/// The frame lies this far outside the area (logical px; BorderView's window is the area plus 4 pt a side).
const FRAME_OUT: f64 = 4.0;

fn monitor_of(app: &AppHandle, r: &Region) -> Option<(Region, f64)> {
    let (cx, cy) = (r.x + r.w as i32 / 2, r.y + r.h as i32 / 2);
    let ms = app.available_monitors().ok()?;
    let reg = |m: &Monitor| Region::new(m.position().x, m.position().y, m.size().width, m.size().height);
    ms.iter()
        .find(|m| reg(m).contains(cx, cy))
        .or(ms.first())
        .map(|m| (reg(m), m.scale_factor()))
}

/// Where the countdown's window goes (BlurtCore OverlayFit.frame): over the area, at least the panel plus its
/// margin, centred on the area and kept on its screen. Physical px.
pub fn countdown_rect(region: Region, scale: f64, screen: Option<Region>) -> Region {
    let w = (region.w as f64).max((PANEL.0 + 2.0 * PANEL_MARGIN) * scale).round() as i32;
    let h = (region.h as f64).max((PANEL.1 + 2.0 * PANEL_MARGIN) * scale).round() as i32;
    let mut x = region.x + region.w as i32 / 2 - w / 2;
    let mut y = region.y + region.h as i32 / 2 - h / 2;
    if let Some(s) = screen {
        x = x.min((s.right() - w).max(s.x)).max(s.x);
        y = y.min((s.bottom() - h).max(s.y)).max(s.y);
    }
    Region::new(x, y, w as u32, h as u32)
}

/// The frame's window: the area plus FRAME_OUT a side, kept on its screen — on a full-screen take it lies over the
/// edge pixels (never recorded: content-protected), as macOS keeps the Mac's on the display.
pub fn frame_rect(region: Region, scale: f64, screen: Option<Region>) -> Region {
    let o = (FRAME_OUT * scale).round() as i32;
    let r = Region::new(region.x - o, region.y - o, region.w + 2 * o as u32, region.h + 2 * o as u32);
    screen.and_then(|s| r.intersect(&s)).unwrap_or(r)
}

fn open(app: &AppHandle, label: &str, at: Region, params: BTreeMap<&str, String>, mouse: bool) -> tauri::Result<()> {
    open_as(app, label, at, params, mouse, true)
}

/// `protected`: kept out of every capture (the countdown, the frame); the pen's ink is not — it is meant to be in the
/// video (InkView: "unlike the rest of the chrome this window *is* captured").
fn open_as(app: &AppHandle, label: &str, at: Region, params: BTreeMap<&str, String>, mouse: bool, protected: bool) -> tauri::Result<()> {
    if let Some(old) = app.get_webview_window(label) {
        let _ = old.destroy();
    }
    let cfg: OverlayConfig = super::overlay_config();
    let mut p = params;
    if let Some(l) = &cfg.lang {
        p.entry("lang").or_insert_with(|| l.clone());
    }
    if let Some(pl) = &cfg.platform {
        p.entry("platform").or_insert_with(|| pl.clone());
    }
    let init = format!("window.__BLURT_OVERLAY_PARAMS__ = {};", serde_json::to_string(&p).unwrap_or_default());
    let scale = monitor_of(app, &at).map_or(1.0, |m| m.1);
    let w = WebviewWindowBuilder::new(app, label, WebviewUrl::App(format!("{}rec.html", cfg.base).into()))
        .title("Blurt")
        .initialization_script(init)
        .transparent(true)
        .background_color(tauri::webview::Color(0, 0, 0, 0))
        .decorations(false)
        .shadow(false)
        .resizable(false)
        .skip_taskbar(true)
        .always_on_top(true)
        .visible_on_all_workspaces(true)
        .content_protected(protected && !cfg.capturable)
        .focusable(false)
        .focused(false)
        .position(at.x as f64 / scale, at.y as f64 / scale)
        .inner_size(at.w as f64 / scale, at.h as f64 / scale)
        .visible(false)
        .build()?;
    w.set_position(PhysicalPosition::new(at.x, at.y))?;
    w.set_size(PhysicalSize::new(at.w, at.h))?;
    if !mouse {
        let _ = w.set_ignore_cursor_events(true);
    }
    w.show()?;
    Ok(())
}

/// The keys that pause and finish the take, as the countdown names them (none when both are off).
fn keys(app: &AppHandle) -> String {
    let rows = crate::hotkeys::rows(app);
    let label = |a: &str| {
        rows.iter()
            .find(|r| r["action"] == a)
            .and_then(|r| r["label"].as_str())
            .filter(|l| !l.is_empty())
            .map(str::to_owned)
    };
    let pairs: Vec<Value> = [("pause", "pause"), ("stop", "finish")]
        .iter()
        .filter_map(|(a, w)| label(a).map(|k| json!({"key": k, "word": w})))
        .collect();
    Value::Array(pairs).to_string()
}

/// A countdown line from record.py: the first opens the window over `region` (a click on it → `go`), later ones
/// move the number on, `n == 0` closes it.
pub fn countdown(app: &AppHandle, region: Option<Region>, n: u64, total: u64) {
    if n == 0 {
        close(app, COUNTDOWN);
        return;
    }
    if app.get_webview_window(COUNTDOWN).is_some() {
        tell(app, COUNTDOWN, json!({"op": "countdown", "n": n, "total": total}));
        return;
    }
    let Some(region) = region.or_else(|| overlay::monitor_at_cursor(app).map(|m| {
        Region::new(m.position().x, m.position().y, m.size().width, m.size().height)
    })) else {
        return;
    };
    let (screen, scale) = monitor_of(app, &region).map_or((None, 1.0), |(s, k)| (Some(s), k));
    let mut p = BTreeMap::new();
    p.insert("mode", "countdown".to_string());
    p.insert("n", n.to_string());
    p.insert("total", total.to_string());
    p.insert("keys", keys(app));
    if let Err(e) = open(app, COUNTDOWN, countdown_rect(region, scale, screen), p, true) {
        eprintln!("blurt: countdown window: {e}");
    }
    island_on_top(app);
}

/// The island (and its lines) above every window of the take's chrome: a frame or countdown made after it would
/// otherwise stack over it, and the frame's line ran through the open island and its text (recording.md §3).
fn island_on_top(app: &AppHandle) {
    if let Some(i) = app.get_webview_window(overlay::Kind::Island.label()) {
        let _ = i.set_always_on_top(false);
        let _ = i.set_always_on_top(true);
    }
}

/// The frame around the recorded area: shown when the take starts, dashed while paused.
pub fn frame(app: &AppHandle, region: Option<Region>, paused: bool) {
    if app.get_webview_window(FRAME).is_some() {
        tell(app, FRAME, json!({"op": "frame", "paused": paused}));
        return;
    }
    let Some(region) = region else { return };
    let (screen, scale) = monitor_of(app, &region).map_or((None, 1.0), |(s, k)| (Some(s), k));
    let mut p = BTreeMap::new();
    p.insert("mode", "frame".to_string());
    p.insert("paused", if paused { "1" } else { "0" }.to_string());
    if let Err(e) = open(app, FRAME, frame_rect(region, scale, screen), p, false) {
        eprintln!("blurt: recording frame: {e}");
    }
    island_on_top(app);
}

fn close(app: &AppHandle, label: &str) {
    LAST.lock().unwrap().retain(|(x, _)| *x != label);
    if let Some(w) = app.get_webview_window(label) {
        let _ = w.destroy();
    }
}

/// The take is over (or never started): no countdown, no frame.
pub fn close_all(app: &AppHandle) {
    close(app, COUNTDOWN);
    close(app, FRAME);
    close(app, INK);
}

/// The pen while recording (the Mac's InkView; recording.md §4.6): a window exactly over the recorded area, recorded
/// with it, click-through until the pen is on; then it takes the drag (over any app) and shows the pen's ring at the
/// pointer. Ink fades 3 s after the last stroke. Made on the first use in a take.
pub fn ink(app: &AppHandle, region: Option<Region>, on: bool) {
    if app.get_webview_window(INK).is_none() {
        if !on {
            return;
        }
        let Some(region) = region else { return };
        let mut p = BTreeMap::new();
        p.insert("mode", "ink".to_string());
        // its first state with the page itself: nothing listens yet to an op sent right after the window is made
        p.insert("on", "1".to_string());
        if let Err(e) = open_as(app, INK, region, p, false, false) {
            eprintln!("blurt: pen window: {e}");
            return;
        }
        // the island stays clickable above the ink (InkView.end: island.orderFront)
        island_on_top(app);
    }
    if let Some(w) = app.get_webview_window(INK) {
        let _ = w.set_ignore_cursor_events(!on);
    }
    tell(app, INK, json!({"op": "ink", "on": on}));
}

/// A recording's cue (sounds/rec-*.wav, assets/sounds/build.py): `rec-tick` each second of the countdown (the Mac's
/// Pop), `rec-done` once a take is saved (its Submarine). Never while the take records: both come before or after it.
pub fn sound(app: &AppHandle, name: &str) {
    #[cfg(windows)]
    {
        let Ok(res) = app.path().resource_dir() else { return };
        let mut p = res.join("sounds").join(format!("{name}.wav"));
        if !p.is_file() {
            p = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("sounds").join(format!("{name}.wav"));
        }
        use windows::Win32::Media::Audio::{PlaySoundW, SND_ASYNC, SND_FILENAME, SND_NODEFAULT};
        let w: Vec<u16> = p.to_string_lossy().encode_utf16().chain(std::iter::once(0)).collect();
        unsafe {
            let _ = PlaySoundW(windows::core::PCWSTR(w.as_ptr()), None, SND_ASYNC | SND_FILENAME | SND_NODEFAULT);
        }
    }
    #[cfg(not(windows))]
    let _ = (app, name);
}

/// A click on the countdown (`go` from its page) starts the take now. Listened to once for the app's life.
pub fn listen_once(app: &AppHandle) {
    static ON: std::sync::OnceLock<()> = std::sync::OnceLock::new();
    ON.get_or_init(|| {
        let a = app.clone();
        overlay::listen_from(app, overlay::ev::ACTION, COUNTDOWN, move |v| {
            if v["action"] == "go" {
                let _ = a.state::<crate::AppState>().capture.control(super::Control::Go);
            }
        });
        // a page that has just loaded: what it missed meanwhile
        for label in [COUNTDOWN, FRAME, INK] {
            let a = app.clone();
            overlay::listen_from(app, overlay::ev::READY, label, move |_| {
                let last = LAST.lock().unwrap().iter().find(|(x, _)| *x == label).map(|(_, op)| op.clone());
                if let Some(op) = last {
                    let _ = a.emit_to(label, REC_EV, op);
                }
            });
        }
        // a stroke drawn: into events.jsonl at its video time (record.py `stroke:`)
        let a = app.clone();
        overlay::listen_from(app, overlay::ev::ACTION, INK, move |v| {
            if v["action"] == "stroke" {
                a.state::<crate::AppState>().capture.log_stroke(&v["stroke"]);
            }
        });
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn countdown_covers_the_area_or_fits_the_panel_on_screen() {
        let screen = Some(Region::new(0, 0, 1920, 1080));
        assert_eq!(countdown_rect(Region::new(100, 100, 1200, 800), 1.0, screen), Region::new(100, 100, 1200, 800));
        // a small area: the panel plus its margin, centred on it, kept on the screen
        let r = countdown_rect(Region::new(10, 10, 100, 60), 1.0, screen);
        assert_eq!((r.x, r.y, r.w, r.h), (0, 0, 380, 330));
        assert_eq!(countdown_rect(Region::new(800, 400, 100, 60), 2.0, None).w, 760);
    }

    #[test]
    fn frame_lies_outside_the_area_but_on_the_screen() {
        let screen = Some(Region::new(0, 0, 1920, 1080));
        assert_eq!(frame_rect(Region::new(100, 100, 400, 300), 1.5, screen), Region::new(94, 94, 412, 312));
        assert_eq!(frame_rect(Region::new(0, 0, 1920, 1080), 1.0, screen), Region::new(0, 0, 1920, 1080));
    }
}
