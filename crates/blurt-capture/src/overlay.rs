//! Overlay windows (Tauri 2) drawn by `web/apps/overlays`: region picker, recording HUD, perch (鸡舍), note bubble.
//!
//! Every overlay is transparent, undecorated, always on top, on all workspaces, out of the taskbar and
//! content-protected — Windows: `WDA_EXCLUDEFROMCAPTURE` (tao), so gdigrab / the recording never sees it; Linux X11
//! has no equivalent, so the HUD is placed outside the recorded area. The HUD and the perch never take focus
//! (Windows `WS_EX_NOACTIVATE`, GTK `accept-focus = false`); the picker and the note bubble do (keyboard).
//!
//! # What the host app provides (WP7)
//! * the overlay pages at `<frontendDist>/overlays/*.html` (build `web/apps/overlays`; [`OverlayConfig::base`]);
//! * a capability that lets windows `blurt-overlay-*` use `core:default` (events), and the asset protocol
//!   (`app.security.assetProtocol.enable` with the sessions in its scope) for shot thumbnails;
//! * on macOS only (smoke tests): `macOSPrivateApi` for transparency.
//!
//! Call these from async commands or other threads, never the main thread: [`pick_region`] blocks until the user
//! chooses, and creating windows from a synchronous command deadlocks on Windows.
//!
//! # Events (the overlay host protocol; `web/apps/overlays/src/host.ts` has the same names)
//! | event | direction | payload |
//! |---|---|---|
//! | `blurt://status` | Rust → HUD | a C8 status line as-is |
//! | `blurt://action` | overlay → Rust | `{label, action, n?}` (HUD: pause/resume/snap/stop/discard; perch: copy/remove/process/clear/note) |
//! | `blurt://picked` | picker → Rust | `{label, rect: {x,y,w,h} \| null}` in the window's CSS px |
//! | `blurt://hit-rects` | perch → Rust | `{label, rects: [{x,y,w,h}]}` where it takes the mouse |
//! | `blurt://perch` | Rust → perch | `{op: set\|add\|remove\|show\|hide\|busy, …}` |
//! | `blurt://note-done` | note → Rust | `{label, n, text \| null}` |
//! | `blurt://ready` | overlay → Rust | `{label, kind}` once it listens |
//!
//! Initial parameters (`lang`, `platform`, `n`, `src`, `text`, `last`, `mic`) reach a page through an
//! initialization script (`window.__BLURT_OVERLAY_PARAMS__`), the same keys as the browser preview's query string.

use crate::engine::{self, CaptureError, CaptureHandle, CaptureOptions, Mic};
use crate::region::{CssRect, Region};
use crate::status::StatusEvent;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{mpsc, Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};
use tauri::{
    AppHandle, Emitter, EventId, Listener, Manager, Monitor, PhysicalPosition, PhysicalSize, Runtime, WebviewUrl,
    WebviewWindow, WebviewWindowBuilder, WindowEvent,
};

pub mod ev {
    pub const STATUS: &str = "blurt://status";
    pub const ACTION: &str = "blurt://action";
    pub const PICKED: &str = "blurt://picked";
    pub const HIT_RECTS: &str = "blurt://hit-rects";
    pub const PERCH: &str = "blurt://perch";
    pub const NOTE_DONE: &str = "blurt://note-done";
    pub const READY: &str = "blurt://ready";
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    Picker,
    Hud,
    Perch,
    Note,
}

impl Kind {
    pub fn page(self) -> &'static str {
        match self {
            Kind::Picker => "picker.html",
            Kind::Hud => "hud.html",
            Kind::Perch => "perch.html",
            Kind::Note => "note.html",
        }
    }

    /// Window label (`blurt-overlay-*`: what the app's capability lists).
    pub fn label(self) -> &'static str {
        match self {
            Kind::Picker => "blurt-overlay-picker",
            Kind::Hud => "blurt-overlay-hud",
            Kind::Perch => "blurt-overlay-perch",
            Kind::Note => "blurt-overlay-note",
        }
    }

    fn takes_keys(self) -> bool {
        matches!(self, Kind::Picker | Kind::Note)
    }
}

#[derive(Debug, Clone)]
pub struct OverlayConfig {
    /// Path of the overlay pages inside the app's frontendDist (default `overlays/`).
    pub base: String,
    /// `zh` / `en`; default: the page follows the system language.
    pub lang: Option<String>,
    /// `win` / `gnome` token set; default: from the user agent.
    pub platform: Option<String>,
    /// Let screenshots see the overlays (tests only: content protection hides them from every capture on Windows
    /// and macOS). Default: `BLURT_OVERLAY_CAPTURABLE=1` in the environment.
    pub capturable: bool,
}

impl Default for OverlayConfig {
    fn default() -> Self {
        Self {
            base: "overlays/".into(),
            lang: None,
            platform: None,
            capturable: std::env::var("BLURT_OVERLAY_CAPTURABLE").as_deref() == Ok("1"),
        }
    }
}

/// A shot hanging on the perch / shown in the note bubble.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Card {
    pub n: u32,
    /// Loadable URL (see [`file_src`]).
    pub src: String,
    #[serde(default)]
    pub text: Option<String>,
    /// Session-relative file (`shots/003.png`).
    #[serde(default)]
    pub file: Option<String>,
}

impl Card {
    pub fn from_shot(session: &Path, n: u32, file: &str, text: Option<String>) -> Self {
        Card { n, src: file_src(&session.join(file)), text, file: Some(file.to_string()) }
    }
}

/// Tauri's asset-protocol URL for a local file (what `convertFileSrc` returns in JS).
pub fn file_src(path: &Path) -> String {
    let enc: String = path
        .to_string_lossy()
        .bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'!' | b'~' | b'*' | b'\'' | b'(' | b')' => {
                (b as char).to_string()
            }
            _ => format!("%{b:02X}"),
        })
        .collect();
    if cfg!(windows) {
        format!("http://asset.localhost/{enc}")
    } else {
        format!("asset://localhost/{enc}")
    }
}

fn monitor_region(m: &Monitor) -> Region {
    Region::new(m.position().x, m.position().y, m.size().width, m.size().height)
}

/// The monitor under the pointer (else the primary one).
pub fn monitor_at_cursor<R: Runtime>(app: &AppHandle<R>) -> Option<Monitor> {
    let monitors = app.available_monitors().ok()?;
    if let Ok(p) = app.cursor_position() {
        if let Some(m) = monitors.iter().find(|m| monitor_region(m).contains(p.x as i32, p.y as i32)) {
            return Some(m.clone());
        }
    }
    app.primary_monitor().ok().flatten().or_else(|| monitors.into_iter().next())
}

fn monitor_containing<R: Runtime>(app: &AppHandle<R>, r: &Region) -> Option<Monitor> {
    let (cx, cy) = (r.x + r.w as i32 / 2, r.y + r.h as i32 / 2);
    app.available_monitors()
        .ok()?
        .into_iter()
        .find(|m| monitor_region(m).contains(cx, cy))
        .or_else(|| monitor_at_cursor(app))
}

/// Opens (or replaces) one overlay window covering `at` (physical px), hidden until placed, then shown.
pub fn open<R: Runtime>(
    app: &AppHandle<R>,
    kind: Kind,
    cfg: &OverlayConfig,
    at: Region,
    params: BTreeMap<&str, String>,
) -> tauri::Result<WebviewWindow<R>> {
    if let Some(old) = app.get_webview_window(kind.label()) {
        let _ = old.destroy();
    }
    let scale = monitor_containing(app, &at).map(|m| m.scale_factor()).unwrap_or(1.0);
    let mut p: BTreeMap<&str, String> = params;
    if let Some(l) = &cfg.lang {
        p.entry("lang").or_insert_with(|| l.clone());
    }
    if let Some(pl) = &cfg.platform {
        p.entry("platform").or_insert_with(|| pl.clone());
    }
    let init = format!("window.__BLURT_OVERLAY_PARAMS__ = {};", serde_json::to_string(&p).unwrap_or_default());
    let url = WebviewUrl::App(format!("{}{}", cfg.base, kind.page()).into());
    let w = WebviewWindowBuilder::new(app, kind.label(), url)
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
        .content_protected(!cfg.capturable)
        .focusable(kind.takes_keys())
        .focused(kind.takes_keys())
        .position(at.x as f64 / scale, at.y as f64 / scale)
        .inner_size(at.w as f64 / scale, at.h as f64 / scale)
        .visible(false)
        .build()?;
    w.set_position(PhysicalPosition::new(at.x, at.y))?;
    w.set_size(PhysicalSize::new(at.w, at.h))?;
    w.show()?;
    if kind.takes_keys() {
        let _ = w.set_focus();
    }
    Ok(w)
}

fn label_of(payload: &Value) -> &str {
    payload.get("label").and_then(Value::as_str).unwrap_or("")
}

fn listen_from<R: Runtime>(
    app: &AppHandle<R>,
    event: &'static str,
    label: &'static str,
    f: impl Fn(Value) + Send + 'static,
) -> EventId {
    app.listen_any(event, move |e| {
        if let Ok(v) = serde_json::from_str::<Value>(e.payload()) {
            if label_of(&v) == label {
                f(v);
            }
        }
    })
}

// ------------------------------------------------------------------------------------------------ picker

/// Lets the user choose the area on the monitor under the pointer (drag; click = whole screen; Esc cancels).
/// Returns physical px of the desktop, even-sized; `None` when cancelled. Blocks: not on the main thread.
pub fn pick_region<R: Runtime>(app: &AppHandle<R>, cfg: &OverlayConfig, last: Option<Region>) -> tauri::Result<Option<Region>> {
    let Some(mon) = monitor_at_cursor(app) else { return Ok(None) };
    let (mr, scale) = (monitor_region(&mon), mon.scale_factor());
    let mut params = BTreeMap::new();
    if let Some(l) = last.and_then(|l| l.intersect(&mr)) {
        let css = |v: i32| format!("{:.0}", v as f64 / scale);
        params.insert(
            "last",
            [css(l.x - mr.x), css(l.y - mr.y), css(l.w as i32), css(l.h as i32)].join(","),
        );
    }
    let (tx, rx) = mpsc::channel::<Option<CssRect>>();
    let tx2 = tx.clone();
    let id = listen_from(app, ev::PICKED, Kind::Picker.label(), move |v| {
        let _ = tx.send(serde_json::from_value(v["rect"].clone()).ok());
    });
    let w = match open(app, Kind::Picker, cfg, mr, params) {
        Ok(w) => w,
        Err(e) => {
            app.unlisten(id);
            return Err(e);
        }
    };
    w.on_window_event(move |e| {
        if matches!(e, WindowEvent::Destroyed) {
            let _ = tx2.send(None);
        }
    });
    let rect = rx.recv().ok().flatten();
    app.unlisten(id);
    let origin = w.inner_position().map(|p| (p.x, p.y)).unwrap_or((mr.x, mr.y));
    let scale = w.scale_factor().unwrap_or(scale);
    let _ = w.destroy();
    Ok(rect
        .map(|r| Region::from_css(r, origin, scale))
        .and_then(|r| r.intersect(&mr))
        .map(Region::even)
        .filter(|r| !r.is_empty()))
}

// ------------------------------------------------------------------------------------------------ HUD

const HUD_SIZE: (f64, f64) = (420.0, 56.0); // logical px

/// The recording bar, placed outside `region` when the monitor has room (else inside along its bottom edge).
pub fn hud<R: Runtime>(app: &AppHandle<R>, cfg: &OverlayConfig, region: Option<Region>, mic: bool) -> tauri::Result<WebviewWindow<R>> {
    let mon = region.as_ref().and_then(|r| monitor_containing(app, r)).or_else(|| monitor_at_cursor(app));
    let (mr, scale) = mon.as_ref().map(|m| (monitor_region(m), m.scale_factor())).unwrap_or((Region::new(0, 0, 1920, 1080), 1.0));
    let size = ((HUD_SIZE.0 * scale).round() as u32, (HUD_SIZE.1 * scale).round() as u32);
    let area = region.unwrap_or(mr);
    let (x, y) = area.place_outside(size, &mr, (8.0 * scale) as i32);
    let mut params = BTreeMap::new();
    params.insert("mic", if mic { "1" } else { "0" }.to_string());
    open(app, Kind::Hud, cfg, Region::new(x, y, size.0, size.1), params)
}

// ------------------------------------------------------------------------------------------------ perch

const PERCH_H: f64 = 230.0; // logical px
const PEEK: (f64, f64, Duration) = (200.0, 4.0, Duration::from_millis(250)); // top-middle zone that reveals it

/// The perch window: full monitor width at the top, click-through except over what it draws.
pub struct Perch<R: Runtime> {
    app: AppHandle<R>,
    window: WebviewWindow<R>,
    cards: Arc<Mutex<Vec<Card>>>,
    listeners: Vec<EventId>,
    alive: Arc<AtomicBool>,
}

pub fn perch<R: Runtime>(app: &AppHandle<R>, cfg: &OverlayConfig) -> tauri::Result<Arc<Perch<R>>> {
    let mon = monitor_at_cursor(app);
    let (wa, scale) = mon
        .as_ref()
        .map(|m| {
            let a = m.work_area();
            (Region::new(a.position.x, a.position.y, a.size.width, a.size.height), m.scale_factor())
        })
        .unwrap_or((Region::new(0, 0, 1920, 1080), 1.0));
    let at = Region::new(wa.x, wa.y, wa.w, (PERCH_H * scale).round() as u32);
    let rects: Arc<Mutex<Vec<CssRect>>> = Arc::default();
    let cards: Arc<Mutex<Vec<Card>>> = Arc::default();
    let label = Kind::Perch.label();
    let mut listeners = Vec::new();
    let r2 = rects.clone();
    listeners.push(listen_from(app, ev::HIT_RECTS, label, move |v| {
        if let Ok(r) = serde_json::from_value::<Vec<CssRect>>(v["rects"].clone()) {
            *r2.lock().unwrap() = r;
        }
    }));
    let (app2, c2) = (app.clone(), cards.clone());
    listeners.push(listen_from(app, ev::READY, label, move |_| {
        let cards = c2.lock().unwrap().clone();
        let show = !cards.is_empty();
        let _ = app2.emit_to(label, ev::PERCH, json!({"op": "set", "cards": cards}));
        if show {
            let _ = app2.emit_to(label, ev::PERCH, json!({"op": "show", "hold": 3000}));
        }
    }));
    let window = open(app, Kind::Perch, cfg, at, BTreeMap::new())?;
    let _ = window.set_ignore_cursor_events(true);
    let alive = Arc::new(AtomicBool::new(true));
    let a2 = alive.clone();
    window.on_window_event(move |e| {
        if matches!(e, WindowEvent::Destroyed) {
            a2.store(false, Ordering::SeqCst);
        }
    });
    spawn_hit_tester(app.clone(), window.clone(), rects, alive.clone(), at, scale);
    Ok(Arc::new(Perch { app: app.clone(), window, cards, listeners, alive }))
}

/// ~30 Hz: take the mouse only over the drawn rects; a pointer resting in the top-middle zone reveals the perch.
fn spawn_hit_tester<R: Runtime>(
    app: AppHandle<R>,
    w: WebviewWindow<R>,
    rects: Arc<Mutex<Vec<CssRect>>>,
    alive: Arc<AtomicBool>,
    at: Region,
    scale: f64,
) {
    thread::spawn(move || {
        let mut ignoring = true;
        let mut peek_since: Option<Instant> = None;
        while alive.load(Ordering::SeqCst) {
            thread::sleep(Duration::from_millis(33));
            let Ok(p) = app.cursor_position() else { continue };
            let origin = w.inner_position().map(|o| (o.x, o.y)).unwrap_or((at.x, at.y));
            let s = w.scale_factor().unwrap_or(scale);
            let (cx, cy) = ((p.x - origin.0 as f64) / s, (p.y - origin.1 as f64) / s);
            let over = rects.lock().unwrap().iter().any(|r| cx >= r.x && cx < r.x + r.w && cy >= r.y && cy < r.y + r.h);
            if over == ignoring {
                ignoring = !over;
                let _ = w.set_ignore_cursor_events(ignoring);
            }
            let mid = at.w as f64 / s / 2.0;
            let in_peek = (cx - mid).abs() < PEEK.0 / 2.0 && (0.0..PEEK.1).contains(&cy);
            match (in_peek, peek_since) {
                (true, None) => peek_since = Some(Instant::now()),
                (true, Some(t)) if t.elapsed() >= PEEK.2 => {
                    let _ = app.emit_to(Kind::Perch.label(), ev::PERCH, json!({"op": "show", "hold": 3000}));
                    peek_since = Some(Instant::now() + Duration::from_secs(3600)); // once per visit
                }
                (false, _) => peek_since = None,
                _ => {}
            }
        }
    });
}

impl<R: Runtime> Perch<R> {
    pub fn window(&self) -> &WebviewWindow<R> {
        &self.window
    }

    fn op(&self, v: Value) {
        let _ = self.app.emit_to(Kind::Perch.label(), ev::PERCH, v);
    }

    /// Hangs a shot (or updates its note) and shows the perch for 3 s.
    pub fn add(&self, card: Card) {
        {
            let mut c = self.cards.lock().unwrap();
            c.retain(|x| x.n != card.n);
            c.push(card.clone());
        }
        self.op(json!({"op": "add", "card": card}));
    }

    pub fn remove(&self, n: u32) {
        self.cards.lock().unwrap().retain(|x| x.n != n);
        self.op(json!({"op": "remove", "n": n}));
    }

    pub fn cards(&self) -> Vec<Card> {
        self.cards.lock().unwrap().clone()
    }

    /// `hold_ms` = 0: stays until [`Perch::hide`].
    pub fn show(&self, hold_ms: u32) {
        self.op(json!({"op": "show", "hold": hold_ms}));
    }

    pub fn hide(&self) {
        self.op(json!({"op": "hide"}));
    }

    /// The nest of wobbling eggs while an agent processes the batch.
    pub fn busy(&self, on: bool, label: Option<&str>) {
        self.op(json!({"op": "busy", "on": on, "label": label}));
    }

    /// Perch actions (`copy` / `remove` / `process` / `clear` / `note`, with `n` where it applies).
    pub fn on_action(&self, f: impl Fn(&str, Option<u32>) + Send + 'static) -> EventId {
        listen_from(&self.app, ev::ACTION, Kind::Perch.label(), move |v| {
            let n = v.get("n").and_then(Value::as_u64).map(|n| n as u32);
            f(v["action"].as_str().unwrap_or(""), n)
        })
    }
}

impl<R: Runtime> Drop for Perch<R> {
    fn drop(&mut self) {
        for id in self.listeners.drain(..) {
            self.app.unlisten(id);
        }
        self.alive.store(false, Ordering::SeqCst);
        let _ = self.window.destroy();
    }
}

// ------------------------------------------------------------------------------------------------ note

const NOTE_SIZE: (f64, f64) = (440.0, 360.0);

/// The note bubble for a shot, centred under `near` (e.g. the card on the perch) or near the top of the screen.
/// `on_done` gets the text, or `None` when skipped / closed.
pub fn note<R: Runtime>(
    app: &AppHandle<R>,
    cfg: &OverlayConfig,
    card: &Card,
    near: Option<Region>,
    on_done: impl FnOnce(Option<String>) + Send + 'static,
) -> tauri::Result<WebviewWindow<R>> {
    let mon = monitor_at_cursor(app);
    let (mr, scale) = mon.as_ref().map(|m| (monitor_region(m), m.scale_factor())).unwrap_or((Region::new(0, 0, 1920, 1080), 1.0));
    let size = ((NOTE_SIZE.0 * scale).round() as u32, (NOTE_SIZE.1 * scale).round() as u32);
    let anchor = near.unwrap_or(Region::new(mr.x + mr.w as i32 / 2 - 1, mr.y + (PERCH_H * scale) as i32, 2, 2));
    let (x, y) = anchor.place_outside(size, &mr, 0);
    let mut params = BTreeMap::new();
    params.insert("n", card.n.to_string());
    params.insert("src", card.src.clone());
    if let Some(t) = &card.text {
        params.insert("text", t.clone());
    }
    let done = Arc::new(Mutex::new(Some(on_done)));
    let (d1, d2) = (done.clone(), done);
    let app2 = app.clone();
    let id = Arc::new(Mutex::new(None::<EventId>));
    let id2 = id.clone();
    *id.lock().unwrap() = Some(listen_from(app, ev::NOTE_DONE, Kind::Note.label(), move |v| {
        if let Some(f) = d1.lock().unwrap().take() {
            f(v["text"].as_str().map(str::to_string));
        }
        if let Some(w) = app2.get_webview_window(Kind::Note.label()) {
            let _ = w.destroy();
        }
    }));
    let w = open(app, Kind::Note, cfg, Region::new(x, y, size.0, size.1), params)?;
    let app3 = app.clone();
    w.on_window_event(move |e| {
        if matches!(e, WindowEvent::Destroyed) {
            if let Some(f) = d2.lock().unwrap().take() {
                f(None);
            }
            if let Some(i) = id2.lock().unwrap().take() {
                app3.unlisten(i);
            }
        }
    });
    Ok(w)
}

// ------------------------------------------------------------------------------------------------ a take

/// A take with its HUD: status lines go to the HUD (and snaps onto the perch, if given), HUD buttons control the
/// recorder, the HUD closes after the final line, then `on_done` gets that line.
pub fn record<R: Runtime>(
    app: &AppHandle<R>,
    cfg: &OverlayConfig,
    opts: CaptureOptions,
    perch: Option<Arc<Perch<R>>>,
    on_done: impl FnOnce(Result<StatusEvent, CaptureError>) + Send + 'static,
) -> Result<Arc<Mutex<CaptureHandle>>, CaptureError> {
    let hud_label = Kind::Hud.label();
    std::fs::create_dir_all(&opts.session)?;
    let session = std::fs::canonicalize(&opts.session)?;
    // lines that arrive before the HUD page listens are replayed when it says ready
    let seen: Arc<Mutex<Vec<Value>>> = Arc::default();
    let (app1, seen1) = (app.clone(), seen.clone());
    let ready_id = listen_from(app, ev::READY, hud_label, move |_| {
        for v in seen1.lock().unwrap().iter() {
            let _ = app1.emit_to(hud_label, ev::STATUS, v.clone());
        }
    });
    let fail = |e: CaptureError| {
        app.unlisten(ready_id);
        if let Some(w) = app.get_webview_window(hud_label) {
            let _ = w.destroy();
        }
        e
    };
    hud(app, cfg, opts.region, opts.mic != Mic::None).map_err(|e| fail(CaptureError::Recorder(format!("HUD: {e}"))))?;
    let app2 = app.clone();
    let handle = engine::start(&opts, move |e| {
        let v = e.to_json();
        if !matches!(e, StatusEvent::Level { .. }) {
            seen.lock().unwrap().push(v.clone());
        }
        let _ = app2.emit_to(hud_label, ev::STATUS, v);
        if let (StatusEvent::Snap { n, file, .. }, Some(p)) = (e, perch.as_ref()) {
            p.add(Card::from_shot(&session, *n, file, None));
        }
    })
    .map_err(fail)?;
    let handle = Arc::new(Mutex::new(handle));
    let h2 = handle.clone();
    let id = listen_from(app, ev::ACTION, hud_label, move |v| {
        let action = v["action"].as_str().unwrap_or("");
        if matches!(action, "pause" | "resume" | "snap" | "stop" | "discard" | "marker") {
            let _ = h2.lock().unwrap().send(action);
        }
    });
    let (h3, app3) = (handle.clone(), app.clone());
    thread::spawn(move || {
        loop {
            if h3.lock().unwrap().is_finished() {
                break;
            }
            thread::sleep(Duration::from_millis(100));
        }
        let result = h3.lock().unwrap().wait(Duration::from_secs(5));
        app3.unlisten(id);
        app3.unlisten(ready_id);
        thread::sleep(Duration::from_millis(700)); // let "Saved" show
        if let Some(w) = app3.get_webview_window(hud_label) {
            let _ = w.destroy();
        }
        on_done(result);
    });
    Ok(handle)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn asset_urls_like_convert_file_src() {
        let u = file_src(Path::new("/home/a b/s/shots/001.png"));
        let want = "%2Fhome%2Fa%20b%2Fs%2Fshots%2F001.png";
        assert!(u.ends_with(want), "{u}");
    }

    #[test]
    fn labels_are_blurt_overlay_star() {
        for k in [Kind::Picker, Kind::Hud, Kind::Perch, Kind::Note] {
            assert!(k.label().starts_with("blurt-overlay-"));
        }
    }
}
