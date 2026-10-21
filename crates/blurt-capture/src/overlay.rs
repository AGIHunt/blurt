//! Overlay windows (Tauri 2) drawn by `web/apps/overlays`: the region picker, the island (the top-centre pill of
//! v0.7 contract K7 with the claw-held cards under it) and the note bubble.
//!
//! Every overlay is transparent, undecorated, always on top, on all workspaces, out of the taskbar and
//! content-protected — Windows: `WDA_EXCLUDEFROMCAPTURE` (tao), so gdigrab / the recording never sees it; Linux X11
//! has no equivalent, so the host moves the island out of the recorded area ([`Island::place`]). The island never
//! takes focus (Windows `WS_EX_NOACTIVATE`, GTK `accept-focus = false`) except while its project switcher wants the
//! keyboard ([`Island::set_keyboard`]); the picker and the note bubble do.
//!
//! # What the host app provides
//! * the overlay pages at `<frontendDist>/overlays/*.html` (build `web/apps/overlays`; [`OverlayConfig::base`]);
//! * a capability that lets windows `blurt-overlay-*` use `core:default` (events), and the asset protocol
//!   (`app.security.assetProtocol.enable` with the stores in its scope) for card thumbnails;
//! * on macOS only (smoke tests): `macOSPrivateApi` for transparency.
//!
//! Call these from async commands or other threads, never the main thread: [`pick_region`] blocks until the user
//! chooses, and creating windows from a synchronous command deadlocks on Windows.
//!
//! # Events (the overlay host protocol; `web/apps/overlays/src/host.ts` has the same names)
//! | event | direction | payload |
//! |---|---|---|
//! | `blurt://island` | Rust → island | an island op (`state`, `cards`, `card`, `pull`, `toast`, `switcher`, `peek`, `level`) |
//! | `blurt://action` | overlay → Rust | `{label, action, …}` (island: record / snap / voice / pause / … / `card.assign` …) |
//! | `blurt://picked` | picker → Rust | `{label, rect: {x,y,w,h} \| null}` in the window's CSS px |
//! | `blurt://hit-rects` | island → Rust | `{label, rects: [{x,y,w,h}]}` where it takes the mouse |
//! | `blurt://note-done` | note → Rust | `{label, n, text \| null}` |
//! | `blurt://ready` | overlay → Rust | `{label, kind}` once it listens |
//!
//! Initial parameters (`lang`, `platform`, `n`, `src`, `text`, `last`) reach a page through an initialization script
//! (`window.__BLURT_OVERLAY_PARAMS__`), the same keys as the browser preview's query string.

use crate::region::{CssRect, Region};
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
    pub const ISLAND: &str = "blurt://island";
    pub const ACTION: &str = "blurt://action";
    pub const PICKED: &str = "blurt://picked";
    pub const HIT_RECTS: &str = "blurt://hit-rects";
    pub const NOTE_DONE: &str = "blurt://note-done";
    pub const READY: &str = "blurt://ready";
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    Picker,
    Island,
    Note,
}

impl Kind {
    pub fn page(self) -> &'static str {
        match self {
            Kind::Picker => "picker.html",
            Kind::Island => "island.html",
            Kind::Note => "note.html",
        }
    }

    /// Window label (`blurt-overlay-*`: what the app's capability lists).
    pub fn label(self) -> &'static str {
        match self {
            Kind::Picker => "blurt-overlay-picker",
            Kind::Island => "blurt-overlay-island",
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
    /// `en` / `zh-Hans`; default: the page follows the system language.
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

/// A capture held by the claw under the island (K7: a snap with its note, or a voice note, not yet in a project).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Card {
    /// `n` in the batch's shots.jsonl
    pub n: u32,
    /// Loadable URL of the thumbnail (see [`file_src`]); empty for a voice note.
    pub src: String,
    #[serde(default)]
    pub text: Option<String>,
    /// Session-relative file (`shots/003.png`).
    #[serde(default)]
    pub file: Option<String>,
    /// `shot` | `voice`
    #[serde(default = "shot")]
    pub kind: String,
    /// The batch (session dir) it belongs to.
    #[serde(default)]
    pub session: Option<String>,
}

fn shot() -> String {
    "shot".into()
}

impl Card {
    pub fn from_shot(session: &Path, n: u32, file: &str, text: Option<String>) -> Self {
        Card {
            n,
            src: file_src(&session.join(file)),
            text,
            file: Some(file.to_string()),
            kind: shot(),
            session: Some(session.to_string_lossy().into_owned()),
        }
    }

    pub fn voice(session: &Path, n: u32, text: Option<String>) -> Self {
        Card { n, src: String::new(), text, file: None, kind: "voice".into(), session: Some(session.to_string_lossy().into_owned()) }
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
        params.insert("last", [css(l.x - mr.x), css(l.y - mr.y), css(l.w as i32), css(l.h as i32)].join(","));
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

// ------------------------------------------------------------------------------------------------ island

/// The island window: the full width of the monitor's work area along its top, this tall (logical px) — room for
/// the expanded island (≤ 420), the cards hanging under it and their swing. Click-through except over what is drawn.
pub const ISLAND_H: f64 = 600.0;
/// K7: on a screen without a notch the pill hides when idle; the pointer resting 250 ms in the top-middle 320×8 zone
/// brings it out.
const PEEK: (f64, f64, Duration) = (320.0, 8.0, Duration::from_millis(250));
/// Ops the page needs again after a reload (sent on `ready`).
const STICKY: [&str; 2] = ["state", "cards"];

pub struct Island<R: Runtime> {
    app: AppHandle<R>,
    window: WebviewWindow<R>,
    sticky: Arc<Mutex<BTreeMap<String, Value>>>,
    listeners: Mutex<Vec<EventId>>,
    alive: Arc<AtomicBool>,
    at: Arc<Mutex<(Region, f64)>>,
}

fn island_rect(m: Option<&Monitor>) -> (Region, f64) {
    m.map(|m| {
        let a = m.work_area();
        let s = m.scale_factor();
        (Region::new(a.position.x, a.position.y, a.size.width, (ISLAND_H * s).round() as u32), s)
    })
    .unwrap_or((Region::new(0, 0, 1920, ISLAND_H as u32), 1.0))
}

pub fn island<R: Runtime>(app: &AppHandle<R>, cfg: &OverlayConfig) -> tauri::Result<Arc<Island<R>>> {
    let (at, scale) = island_rect(monitor_at_cursor(app).as_ref());
    let rects: Arc<Mutex<Vec<CssRect>>> = Arc::default();
    let sticky: Arc<Mutex<BTreeMap<String, Value>>> = Arc::default();
    let label = Kind::Island.label();
    let mut listeners = Vec::new();
    let r2 = rects.clone();
    listeners.push(listen_from(app, ev::HIT_RECTS, label, move |v| {
        if let Ok(r) = serde_json::from_value::<Vec<CssRect>>(v["rects"].clone()) {
            *r2.lock().unwrap() = r;
        }
    }));
    let (app2, s2) = (app.clone(), sticky.clone());
    listeners.push(listen_from(app, ev::READY, label, move |_| {
        for op in s2.lock().unwrap().values() {
            let _ = app2.emit_to(label, ev::ISLAND, op.clone());
        }
    }));
    let window = open(app, Kind::Island, cfg, at, BTreeMap::new())?;
    let _ = window.set_ignore_cursor_events(true);
    let alive = Arc::new(AtomicBool::new(true));
    let a2 = alive.clone();
    window.on_window_event(move |e| {
        if matches!(e, WindowEvent::Destroyed) {
            a2.store(false, Ordering::SeqCst);
        }
    });
    let at = Arc::new(Mutex::new((at, scale)));
    spawn_hit_tester(app.clone(), window.clone(), rects, alive.clone(), at.clone());
    Ok(Arc::new(Island { app: app.clone(), window, sticky, listeners: Mutex::new(listeners), alive, at }))
}

/// ~30 Hz: take the mouse only over the drawn rects; a pointer resting in the top-middle zone reveals the island.
fn spawn_hit_tester<R: Runtime>(
    app: AppHandle<R>,
    w: WebviewWindow<R>,
    rects: Arc<Mutex<Vec<CssRect>>>,
    alive: Arc<AtomicBool>,
    at: Arc<Mutex<(Region, f64)>>,
) {
    thread::spawn(move || {
        let mut ignoring = true;
        let mut peek_since: Option<Instant> = None;
        while alive.load(Ordering::SeqCst) {
            thread::sleep(Duration::from_millis(33));
            let Ok(p) = app.cursor_position() else { continue };
            let (region, scale) = *at.lock().unwrap();
            let origin = w.inner_position().map(|o| (o.x, o.y)).unwrap_or((region.x, region.y));
            let s = w.scale_factor().unwrap_or(scale);
            let (cx, cy) = ((p.x - origin.0 as f64) / s, (p.y - origin.1 as f64) / s);
            let over = rects.lock().unwrap().iter().any(|r| cx >= r.x && cx < r.x + r.w && cy >= r.y && cy < r.y + r.h);
            if over == ignoring {
                ignoring = !over;
                let _ = w.set_ignore_cursor_events(ignoring);
            }
            let mid = region.w as f64 / s / 2.0;
            let in_peek = (cx - mid).abs() < PEEK.0 / 2.0 && (0.0..PEEK.1).contains(&cy);
            match (in_peek, peek_since) {
                (true, None) => peek_since = Some(Instant::now()),
                (true, Some(t)) if t.elapsed() >= PEEK.2 => {
                    let _ = app.emit_to(Kind::Island.label(), ev::ISLAND, json!({"op": "peek"}));
                    peek_since = Some(Instant::now() + Duration::from_secs(3600)); // once per visit
                }
                (false, _) => peek_since = None,
                _ => {}
            }
        }
    });
}

impl<R: Runtime> Island<R> {
    pub fn window(&self) -> &WebviewWindow<R> {
        &self.window
    }

    pub fn alive(&self) -> bool {
        self.alive.load(Ordering::SeqCst)
    }

    /// Sends one op to the page; `state` and `cards` are also kept for a page that (re)loads later.
    pub fn send(&self, op: Value) {
        if let Some(name) = op.get("op").and_then(Value::as_str).filter(|n| STICKY.contains(n)) {
            self.sticky.lock().unwrap().insert(name.to_string(), op.clone());
        }
        let _ = self.app.emit_to(Kind::Island.label(), ev::ISLAND, op);
    }

    /// Island actions: `{action, …}` as the page sent them (the label is checked already).
    pub fn on_action(&self, f: impl Fn(Value) + Send + 'static) {
        let id = listen_from(&self.app, ev::ACTION, Kind::Island.label(), f);
        self.listeners.lock().unwrap().push(id);
    }

    /// The project switcher takes the keyboard (↑↓ ↩ Esc, typing filters); otherwise the island never takes focus.
    pub fn set_keyboard(&self, on: bool) {
        let _ = self.window.set_focusable(on);
        if on {
            let _ = self.window.set_ignore_cursor_events(false);
            let _ = self.window.set_focus();
        }
    }

    /// Move to the monitor under the pointer when it is another one (K7: the island shows where you are).
    pub fn follow_cursor(&self) {
        let (at, scale) = island_rect(monitor_at_cursor(&self.app).as_ref());
        let mut cur = self.at.lock().unwrap();
        if cur.0 != at {
            *cur = (at, scale);
            let _ = self.window.set_position(PhysicalPosition::new(at.x, at.y));
            let _ = self.window.set_size(PhysicalSize::new(at.w, at.h));
        }
    }

    /// Put the window's top edge at `y` (physical px) on its monitor — Linux keeps it out of a recorded area this
    /// way, as X11 has no capture exclusion. `None` = back at the top of the work area.
    pub fn place(&self, y: Option<i32>) {
        let (mut at, scale) = island_rect(monitor_at_cursor(&self.app).as_ref());
        if let Some(y) = y {
            at.y = y;
        }
        *self.at.lock().unwrap() = (at, scale);
        let _ = self.window.set_position(PhysicalPosition::new(at.x, at.y));
    }

    /// The island's area on the desktop (physical px).
    pub fn rect(&self) -> Region {
        self.at.lock().unwrap().0
    }
}

impl<R: Runtime> Drop for Island<R> {
    fn drop(&mut self) {
        for id in self.listeners.lock().unwrap().drain(..) {
            self.app.unlisten(id);
        }
        self.alive.store(false, Ordering::SeqCst);
        let _ = self.window.destroy();
    }
}

// ------------------------------------------------------------------------------------------------ note

const NOTE_SIZE: (f64, f64) = (440.0, 360.0);

/// The note bubble for a capture, centred under `near` or under the island. `on_done` gets the text, or `None` when
/// skipped / closed.
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
    let anchor = near.unwrap_or(Region::new(mr.x + mr.w as i32 / 2 - 1, mr.y + (56.0 * scale) as i32, 2, 2));
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
        for k in [Kind::Picker, Kind::Island, Kind::Note] {
            assert!(k.label().starts_with("blurt-overlay-"));
        }
    }

    #[test]
    fn cards() {
        let c = Card::from_shot(Path::new("/s"), 3, "shots/003.png", Some("hi".into()));
        assert_eq!((c.kind.as_str(), c.session.as_deref()), ("shot", Some("/s")));
        let v: Card = serde_json::from_value(json!({"n": 1, "src": ""})).unwrap();
        assert_eq!(v.kind, "shot");
        assert_eq!(Card::voice(Path::new("/s"), 4, None).kind, "voice");
    }
}
