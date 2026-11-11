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
//! | `blurt://note-done` | note → Rust | `{label, n, text \| null}`; a fresh snap's note: its whole outcome (note.ts `SnapDone`) |
//! | `blurt://note` | Rust → a snap's note | a note op (`shot`, `voice`, `level`, `speech`, `live`, `ended`, `words`, `commit`, `failed`) |
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
    pub const NOTE: &str = "blurt://note";
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    Picker,
    Island,
    Note,
    /// ⌥T's translation under the island (the Mac's ScreenTextCard): never takes the keys
    TextCard,
}

impl Kind {
    pub fn page(self) -> &'static str {
        match self {
            Kind::Picker => "picker.html",
            Kind::Island => "island.html",
            Kind::Note => "note.html",
            Kind::TextCard => "textcard.html",
        }
    }

    /// Window label (`blurt-overlay-*`: what the app's capability lists).
    pub fn label(self) -> &'static str {
        match self {
            Kind::Picker => "blurt-overlay-picker",
            Kind::Island => "blurt-overlay-island",
            Kind::Note => "blurt-overlay-note",
            Kind::TextCard => "blurt-overlay-textcard",
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
        take_keys(&w);
    }
    Ok(w)
}

/// Windows: a plain SetForegroundWindow (tao's set_focus) is refused under the foreground lock when another app is in
/// front and the hotkey's grant has lapsed — the keys then go to the app behind. The host app registers how to force
/// it (AttachThreadInput, checked and retried); it gets the window's HWND and runs on its own thread.
static FOCUS_HOOK: std::sync::OnceLock<fn(isize)> = std::sync::OnceLock::new();

pub fn set_focus_hook(f: fn(isize)) {
    let _ = FOCUS_HOOK.set(f);
}

/// The window takes the keyboard: focus, then (Windows) the host's forcing until it really is in front.
pub fn take_keys<R: Runtime>(w: &WebviewWindow<R>) {
    let _ = w.set_focus();
    #[cfg(windows)]
    if let (Some(f), Ok(h)) = (FOCUS_HOOK.get().copied(), w.hwnd()) {
        let h = h.0 as isize;
        thread::spawn(move || f(h));
    }
}

fn label_of(payload: &Value) -> &str {
    payload.get("label").and_then(Value::as_str).unwrap_or("")
}

/// Listens to `event` from the overlay window `label` only.
pub fn listen_from<R: Runtime>(
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

/// What the chosen area is for: the picker words its button after it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Purpose {
    Record,
    Screenshot,
    /// Copy Text from Screen (Alt+C)
    Text,
    /// translate the text on screen (Alt+T)
    Translate,
}

/// What the host app tells the picker (registered once, [`set_picker_hooks`]): the visible windows on the desktop, top
/// first, in physical px (a click picks one — the Mac's window snapping; Windows lists them), and whether a teaching
/// line still shows ("picker": the key legend, the first few pickers — the Mac's HintBudget).
pub struct PickerHooks {
    /// None: no window list here (Linux) — a click takes the whole screen
    pub windows: fn() -> Option<Vec<Region>>,
    pub hint: fn(&str) -> bool,
    /// the monitor (physical px) as it is before the picker opens, as an image file — the loupe magnifies it (the Mac's
    /// LoupeStills), somewhere the host's asset protocol serves; None: no loupe
    pub still: fn(Region) -> Option<std::path::PathBuf>,
}

static HOOKS: std::sync::OnceLock<PickerHooks> = std::sync::OnceLock::new();

pub fn set_picker_hooks(h: PickerHooks) {
    let _ = HOOKS.set(h);
}

/// Lets the user choose the area on the monitor under the pointer (drag; click = the window under the pointer;
/// Esc cancels). Returns physical px of the desktop, even-sized; `None` when cancelled. Blocks: not on the main thread.
pub fn pick_region<R: Runtime>(app: &AppHandle<R>, cfg: &OverlayConfig, last: Option<Region>, purpose: Purpose) -> tauri::Result<Option<Region>> {
    Ok(pick_region_with(app, cfg, last, purpose, false)?.map(|(r, _)| r))
}

/// The CSS rect (px of a window at `origin` with `scale`) of a desktop region.
fn css_of(r: &Region, origin: (i32, i32), scale: f64) -> [f64; 4] {
    let f = |v: f64| (v * 10.0).round() / 10.0;
    [f((r.x - origin.0) as f64 / scale), f((r.y - origin.1) as f64 / scale), f(r.w as f64 / scale), f(r.h as f64 / scale)]
}

/// Where a monitor-wide overlay (the picker, a snap's stage) goes. GNOME keeps a normal X11 window inside the work
/// area: one asked for at the monitor's origin lands below the top bar and right of the dock (67, 32 on 26.04), and
/// its page, drawing from the monitor's origin, put the snap's frozen picture and the loupe that far off. So on Linux
/// these overlays cover the work area, and their coordinates start there; elsewhere the whole monitor.
fn cover(monitor: Region, work: Region) -> Region {
    if cfg!(target_os = "linux") && !work.is_empty() {
        work
    } else {
        monitor
    }
}

/// [`pick_region`]; `hold`: a snap — the picker's window stays up, frozen (only the dim), and is handed back, so the
/// screen never flickers before the note's stage covers it ([`snap_note`]); the caller destroys it.
pub fn pick_region_with<R: Runtime>(
    app: &AppHandle<R>,
    cfg: &OverlayConfig,
    last: Option<Region>,
    purpose: Purpose,
    hold: bool,
) -> tauri::Result<Option<(Region, Option<WebviewWindow<R>>)>> {
    let Some(mon) = monitor_at_cursor(app) else { return Ok(None) };
    let wa = mon.work_area();
    let work = Region::new(wa.position.x, wa.position.y, wa.size.width, wa.size.height);
    // the window's place, and the origin of the page's coordinates (see `cover`)
    let (mr, scale) = (cover(monitor_region(&mon), work), mon.scale_factor());
    let mut params = BTreeMap::new();
    let p = match purpose {
        Purpose::Record => "record",
        Purpose::Screenshot => "screenshot",
        Purpose::Text => "text",
        Purpose::Translate => "translate",
    };
    params.insert("purpose", p.to_string());
    if let Some(l) = last.and_then(|l| l.intersect(&mr)) {
        params.insert("last", css_of(&l, (mr.x, mr.y), scale).map(|v| format!("{v:.0}")).join(","));
    }
    params.insert("work", css_of(&work, (mr.x, mr.y), scale).map(|v| v.to_string()).join(","));
    if let Some(h) = HOOKS.get() {
        if !matches!(purpose, Purpose::Text | Purpose::Translate) {
            if let Some(list) = (h.windows)() {
                let wins: Vec<[f64; 4]> = list.iter().filter_map(|w| w.intersect(&mr)).map(|w| css_of(&w, (mr.x, mr.y), scale)).collect();
                params.insert("wins", serde_json::to_string(&wins).unwrap_or_else(|_| "[]".into()));
            }
            params.insert("legend", if (h.hint)("picker") { "1" } else { "0" }.into());
        }
        // the loupe's still: taken before the picker shows, so the picker is never in it
        // (a file the host's asset protocol already serves: this crate doesn't change its scope)
        if let Some(p) = (h.still)(mr) {
            params.insert("still", file_src(&p));
        }
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
    let picked = rect
        .map(|r| Region::from_css(r, origin, scale))
        .and_then(|r| r.intersect(&mr))
        .map(Region::even)
        .filter(|r| !r.is_empty());
    let keep = hold && picked.is_some() && !cfg.capturable;
    if !keep {
        let _ = w.destroy();
    }
    Ok(picked.map(|r| (r, keep.then_some(w))))
}

// ------------------------------------------------------------------------------------------------ island

/// The island window: the monitor's whole work area (it was the top 600 px: the Cards panel and its big preview —
/// centred on the screen — need the rest, as the Mac's panel spans the screen: HangingCards.panelH). Click-through
/// except over what is drawn. At least this tall (logical px) on a very small screen.
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
    /// kept at a place of its own (Linux, out of a recorded area): not re-placed with the screen
    pinned: Arc<AtomicBool>,
    /// the top-middle hot zone brings the island out (set_peek)
    peek: Arc<AtomicBool>,
}

fn island_rect(m: Option<&Monitor>) -> (Region, f64) {
    m.map(|m| {
        let a = m.work_area();
        let s = m.scale_factor();
        (Region::new(a.position.x, a.position.y, a.size.width, a.size.height.max((ISLAND_H * s).round() as u32)), s)
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
    // nothing on the island (no open body, toast, take, voice note, dictation, menu or panel): it may move screens
    let idle = Arc::new(AtomicBool::new(true));
    let i2 = idle.clone();
    listeners.push(listen_from(app, ev::HIT_RECTS, label, move |v| {
        if let Ok(r) = serde_json::from_value::<Vec<CssRect>>(v["rects"].clone()) {
            *r2.lock().unwrap() = r;
        }
        i2.store(v["idle"].as_bool().unwrap_or(false), Ordering::SeqCst);
    }));
    let (app2, s2) = (app.clone(), sticky.clone());
    listeners.push(listen_from(app, ev::READY, label, move |_| {
        for op in s2.lock().unwrap().values() {
            let _ = app2.emit_to(label, ev::ISLAND, op.clone());
        }
    }));
    let window = open(app, Kind::Island, cfg, at, BTreeMap::new())?;
    // Linux: tao's click-through is an input shape too, applied later on its own loop — it would undo ours
    #[cfg(not(target_os = "linux"))]
    let _ = window.set_ignore_cursor_events(true);
    #[cfg(target_os = "linux")]
    input_shape(&window, &[]);
    let alive = Arc::new(AtomicBool::new(true));
    let a2 = alive.clone();
    window.on_window_event(move |e| {
        if matches!(e, WindowEvent::Destroyed) {
            a2.store(false, Ordering::SeqCst);
        }
    });
    let at = Arc::new(Mutex::new((at, scale)));
    let pinned = Arc::new(AtomicBool::new(false));
    let peek = Arc::new(AtomicBool::new(true));
    spawn_hit_tester(app.clone(), window.clone(), rects, alive.clone(), at.clone(), Follow { idle, pinned: pinned.clone(), peek: peek.clone() });
    Ok(Arc::new(Island { app: app.clone(), window, sticky, listeners: Mutex::new(listeners), alive, at, pinned, peek }))
}

/// The island's input region: its drawn rects (CSS px = GDK's logical px), the rest of the window passes clicks on.
/// An X input shape on the toplevel, which mutter honours for XWayland windows.
#[cfg(target_os = "linux")]
fn input_shape<R: Runtime>(w: &WebviewWindow<R>, rects: &[CssRect]) {
    let (w2, rects) = (w.clone(), rects.to_vec());
    let _ = w.run_on_main_thread(move || {
        use gtk::prelude::*;
        let Ok(gw) = w2.gtk_window() else { return };
        let region = gtk::cairo::Region::create();
        for r in &rects {
            let rect = gtk::cairo::RectangleInt::new(r.x.floor() as i32, r.y.floor() as i32, r.w.ceil() as i32 + 1, r.h.ceil() as i32 + 1);
            let _ = region.union_rectangle(&rect);
        }
        gw.input_shape_combine_region(Some(&region));
    });
}

struct Follow {
    idle: Arc<AtomicBool>,
    pinned: Arc<AtomicBool>,
    peek: Arc<AtomicBool>,
}

/// Where the island window should be now: on its screen as that screen is now (a resolution, scaling or work-area
/// change, an RDP reconnect at another size), or — while nothing shows on it — on the screen with the pointer (K7:
/// the island shows where you are; Island.swift poll).
fn island_target<R: Runtime>(app: &AppHandle<R>, cur: &(Region, f64), idle: bool) -> (Region, f64) {
    if idle {
        island_rect(monitor_at_cursor(app).as_ref())
    } else {
        island_rect(monitor_containing(app, &cur.0).as_ref())
    }
}

/// ~30 Hz: take the mouse only over the drawn rects; a pointer resting in the top-middle zone reveals the island.
/// Once a second: the window follows its screen (island_target).
fn spawn_hit_tester<R: Runtime>(
    app: AppHandle<R>,
    w: WebviewWindow<R>,
    rects: Arc<Mutex<Vec<CssRect>>>,
    alive: Arc<AtomicBool>,
    at: Arc<Mutex<(Region, f64)>>,
    follow: Follow,
) {
    thread::spawn(move || {
        let mut ignoring = true;
        let mut peek_since: Option<Instant> = None;
        let mut tick: u32 = 0;
        #[cfg(target_os = "linux")]
        let mut shaped: Vec<CssRect> = vec![];
        while alive.load(Ordering::SeqCst) {
            thread::sleep(Duration::from_millis(33));
            tick = tick.wrapping_add(1);
            // Linux (XWayland): the pointer's position reaches an X client only while it is over one of its windows, so
            // a click-through island never sees it coming; the window takes clicks where its rects are instead
            #[cfg(target_os = "linux")]
            {
                let now = rects.lock().unwrap().clone();
                if now != shaped {
                    input_shape(&w, &now);
                    shaped = now;
                }
            }
            if tick % 30 == 0 && !follow.pinned.load(Ordering::SeqCst) {
                let cur = *at.lock().unwrap();
                let want = island_target(&app, &cur, follow.idle.load(Ordering::SeqCst));
                if want != cur {
                    *at.lock().unwrap() = want;
                    // position first: arriving on a screen of another scale resizes the window, then the size lands
                    let _ = w.set_position(PhysicalPosition::new(want.0.x, want.0.y));
                    let _ = w.set_size(PhysicalSize::new(want.0.w, want.0.h));
                }
            }
            if cfg!(target_os = "linux") {
                continue;
            }
            let Ok(p) = app.cursor_position() else { continue };
            let (region, scale) = *at.lock().unwrap();
            let origin = w.inner_position().map(|o| (o.x, o.y)).unwrap_or((region.x, region.y));
            let s = w.scale_factor().unwrap_or(scale);
            let (cx, cy) = ((p.x - origin.0 as f64) / s, (p.y - origin.1 as f64) / s);
            let over = rects.lock().unwrap().iter().any(|r| cx >= r.x && cx < r.x + r.w && cy >= r.y && cy < r.y + r.h);
            if over == ignoring {
                ignoring = !over;
                let _ = w.set_ignore_cursor_events(ignoring);
                // the page's mouseenter / mouseleave don't come when the window turns click-through (or back) under a
                // pointer that has stopped moving: say it from here too
                let _ = app.emit_to(Kind::Island.label(), ev::ISLAND, json!({"op": "hover", "x": cx, "y": cy, "out": !over}));
            }
            let mid = region.w as f64 / s / 2.0;
            let in_peek = follow.peek.load(Ordering::SeqCst) && (cx - mid).abs() < PEEK.0 / 2.0 && (0.0..PEEK.1).contains(&cy);
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
            #[cfg(not(target_os = "linux"))] // Linux: the input shape already takes the switcher's clicks
            let _ = self.window.set_ignore_cursor_events(false);
            take_keys(&self.window);
        }
    }

    /// Move to the monitor under the pointer when it is another one (K7: the island shows where you are).
    pub fn follow_cursor(&self) {
        let (at, scale) = island_rect(monitor_at_cursor(&self.app).as_ref());
        let mut cur = self.at.lock().unwrap();
        if *cur != (at, scale) {
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
        self.pinned.store(y.is_some(), Ordering::SeqCst);
        *self.at.lock().unwrap() = (at, scale);
        let _ = self.window.set_position(PhysicalPosition::new(at.x, at.y));
        let _ = self.window.set_size(PhysicalSize::new(at.w, at.h));
    }

    /// Whether a pointer resting at the top edge's middle brings the island out. Off when the island stays hidden at
    /// rest: there the top edge is the apps' own (a browser's tabs), not a menu bar as on the Mac.
    pub fn set_peek(&self, on: bool) {
        self.peek.store(on, Ordering::SeqCst);
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

/// A fresh snap's note (the Mac's InkStage + NoteBubble in place): one window over the monitor holding `sel` (physical
/// px), its page `note.html?mode=snap` — the picture frozen at `sel`, the pen on it, the bubble docked beside it. The
/// window takes the keys. `params`: n, src, place, projects, voice, hint, first, g (see note.ts); `sel` and `work` are
/// added here in the window's CSS px. Talk to it with [`ev::NOTE`] (`emit_to(Kind::Note.label(), …)`) and
/// [`listen_from`] (`ev::NOTE_DONE`, `ev::ACTION`, `ev::READY`).
pub fn snap_note<R: Runtime>(
    app: &AppHandle<R>,
    cfg: &OverlayConfig,
    sel: Region,
    mut params: BTreeMap<&'static str, String>,
) -> tauri::Result<WebviewWindow<R>> {
    let mon = monitor_containing(app, &sel);
    let (mon_r, scale) = mon.as_ref().map(|m| (monitor_region(m), m.scale_factor())).unwrap_or((sel, 1.0));
    let work = mon
        .as_ref()
        .map(|m| {
            let a = m.work_area();
            Region::new(a.position.x, a.position.y, a.size.width, a.size.height)
        })
        .unwrap_or(mon_r);
    // the stage lies where the picker did (`cover`): its frozen picture is drawn where it was taken
    let mr = cover(mon_r, work);
    params.insert("mode", "snap".into());
    params.insert("sel", css_of(&sel, (mr.x, mr.y), scale).map(|v| v.to_string()).join(","));
    params.insert("work", css_of(&work, (mr.x, mr.y), scale).map(|v| v.to_string()).join(","));
    open(app, Kind::Note, cfg, mr, params)
}


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
        for k in [Kind::Picker, Kind::Island, Kind::Note, Kind::TextCard] {
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
