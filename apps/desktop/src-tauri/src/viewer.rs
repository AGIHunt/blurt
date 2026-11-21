//! One computer driving another, this computer's side (docs/design/remote-desktop-viewer.md): the list of computers (the
//! Remote Control page, the tray's Computers), pairing with one (found nearby, or a pasted link), and a window per computer.
//! The protocol, pairing and sessions are crates/blurt-remote's (viewer.rs, keys.rs); this file is the app around them.
//!
//!  • `computers://status` carries `ComputersStatus` whenever it changes; the commands below change it.
//!  • A window per computer (label `viewer-<n>`, the page `index.html?viewer=<host id>`): its webview calls `viewer_attach` with a
//!    Channel, and the session starts. Through the channel: JSON events (the link, the round trip, displays, the picture's
//!    size, the pointer, the clipboard, a release) and the picture's frames as bytes (1, flags, u32 LE id, the codec string's
//!    length and bytes, Annex B). The webview decodes them (WebCodecs) and sends input back with the `viewer_*` commands.
//!  • Keys: the webview's key events (`viewer_key`, the web's `KeyboardEvent.code`), or on Windows the low-level hook while
//!    captured (viewer_keys.rs). blurt_remote::keys::Keyboard turns them into the host's messages and spots Ctrl+Alt.
//!  • Options (`viewer.json` beside the host's files): the modifier mapping to a Mac, and the clipboard. Both on by default.

use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicU64, Ordering::SeqCst};
use std::sync::{Arc, Mutex, OnceLock};

use blurt_remote::keys::{Keyboard, Sent};
use blurt_remote::packets::{PointerPacket, ScrollPhase};
use blurt_remote::viewer::{self, Computer, Computers, Event, Found, Link, PairError, PairStep, PairWith, Quality, Route, Session, Target, Want};
use blurt_remote::wire::{MouseButton, ToMac};
use serde::{Deserialize, Serialize};
use serde_json::json;
use tauri::ipc::{Channel, InvokeResponseBody};
use tauri::{AppHandle, Emitter, Manager, WebviewUrl, WebviewWindow, WebviewWindowBuilder};

static V: OnceLock<Viewers> = OnceLock::new();

struct Viewers {
    app: AppHandle,
    rt: tokio::runtime::Runtime,
    computers: Computers,
    nearby: Mutex<Vec<Found>>,
    /// what each computer's relay said lately (`peek`), while the list shows: asleep since, last seen
    presence: Mutex<HashMap<String, blurt_remote::relay::Presence>>,
    browser: Mutex<Option<viewer::Browser>>,
    pairing: Mutex<Option<Pairing>>,
    pair_gen: AtomicU64,
    /// the pairing under way: aborted by Cancel, Back or another pairing, so its connection closes and the host stops asking
    pair_task: Mutex<Option<tokio::task::JoinHandle<()>>>,
    /// how the last pairing began: Try Again begins it the same way
    pair_last: Mutex<Option<PairFrom>>,
    /// computers that refused this computer's key this run, with no session (`Link::Forgotten`): the list says Removed, the key is
    /// kept (anyone on the network can send a refusal); cleared when one connects
    refused: Mutex<HashSet<String>>,
    /// Add Again… from a viewer window: the main window's list opens Add Computer when this goes up
    add_requests: AtomicU64,
    /// pairings that ended paired: the Add Computer panel's job is done
    paired: AtomicU64,
    windows: Mutex<HashMap<String, Win>>,
    next_window: AtomicU64,
    options: Mutex<Options>,
    /// computers whose last try through the public connection service found no direct path (their window said so): the list says
    /// Can't Connect Directly until one connects or Connect tries again (the Mac's ViewerStore.failed)
    no_direct: Mutex<HashSet<String>>,
}

struct Pairing {
    name: String,
    state: &'static str,
    digits: Option<String>,
    error: Option<&'static str>,
    /// begun from a pasted link (else from a computer found nearby)
    link: bool,
}

#[derive(Clone)]
enum PairFrom {
    Nearby(Found),
    Link(String),
}

/// A window and its session.
struct Win {
    host_id: String,
    session: Option<Session>,
    channel: Option<Channel<InvokeResponseBody>>,
    keyboard: Keyboard,
    platform: String,
    captured: bool,
    focused: bool,
    link: Link,
    route: Option<Route>,
    /// the last clipboard text either way (not sent back)
    clip: Option<String>,
    /// the dictation key, down and not sent yet: alone it's dictation here, with another key it goes on (AltGr+E still types €)
    held_trigger: Option<String>,
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Options {
    /// To a Mac: Ctrl as ⌘, Win / Super as ⌃
    pub mapped: bool,
    /// text between the clipboards while keys are captured
    pub clipboard: bool,
}

impl Default for Options {
    fn default() -> Self {
        Options { mapped: true, clipboard: true }
    }
}

fn dir() -> std::path::PathBuf {
    crate::paths::blurt_home().join("remote")
}

fn viewers() -> Option<&'static Viewers> {
    V.get()
}

/// At launch (lib.rs setup): the list and its store; nothing connects until a window opens.
pub fn start(app: &AppHandle) {
    let Ok(rt) = tokio::runtime::Builder::new_multi_thread().worker_threads(2).thread_name("blurt-viewer").enable_all().build() else { return };
    let options = std::fs::read(dir().join("viewer.json")).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default();
    let _ = V.set(Viewers {
        app: app.clone(),
        rt,
        computers: Computers::new(dir(), crate::remote::key_store()),
        nearby: Mutex::new(vec![]),
        presence: Mutex::new(HashMap::new()),
        browser: Mutex::new(None),
        pairing: Mutex::new(None),
        pair_gen: AtomicU64::new(0),
        pair_task: Mutex::new(None),
        pair_last: Mutex::new(None),
        refused: Mutex::new(HashSet::new()),
        add_requests: AtomicU64::new(0),
        paired: AtomicU64::new(0),
        windows: Mutex::new(HashMap::new()),
        next_window: AtomicU64::new(1),
        options: Mutex::new(options),
        no_direct: Mutex::new(HashSet::new()),
    });
}

/// The window closed: its session ends, keys go back.
pub fn window_closed(label: &str) {
    let Some(v) = viewers() else { return };
    let w = v.windows.lock().unwrap().remove(label);
    if w.is_some() {
        capture_os(label, false);
        emit();
    }
}

/// The window came to the front or went behind: keys are only ever the front window's.
pub fn window_focused(label: &str, focused: bool) {
    let Some(v) = viewers() else { return };
    let mut ws = v.windows.lock().unwrap();
    let Some(w) = ws.get_mut(label) else { return };
    w.focused = focused;
    if !focused {
        let held = w.keyboard.let_go();
        if let Some(s) = &w.session {
            for m in held {
                s.send(m);
            }
        }
    }
    let on = w.captured && focused;
    drop(ws);
    capture_os(label, on);
}

// ------------------------------------------------------------------ the list

#[derive(Serialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ComputerUi {
    id: String,
    /// what this computer calls it: the owner's name for it (computers_rename), else the one its sessions give
    name: String,
    /// the name the host gives itself (the rename field's placeholder)
    own_name: String,
    platform: Option<String>,
    /// "connected" (a window shows it), "available" (found nearby, or reachable through its relay), "noDirect" (the public
    /// connection service found no direct path last time), "asleep", "offline", "removed" (it removed this computer: Add Again)
    state: &'static str,
    /// its key is still here: a "removed" said only from a refusal this run, so Connect stays in ⋯
    key: bool,
    route: Option<Route>,
    last_seen: Option<i64>,
    windows: usize,
}

#[derive(Serialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct NearbyUi {
    id: String,
    name: String,
}

#[derive(Serialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct PairingUi {
    name: String,
    /// "connecting", "asking" (the digits show; the owner answers there), "failed" (an unreachable one goes on trying meanwhile:
    /// if the host turns up and asks, "asking" takes its place)
    state: &'static str,
    digits: Option<String>,
    /// "unreachable", "spent" (refused before anyone was asked), "declined", "unanswered", "invalid"
    error: Option<&'static str>,
    /// begun from a pasted link (else from a computer found nearby)
    link: bool,
}

#[derive(Serialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ComputersStatus {
    computers: Vec<ComputerUi>,
    nearby: Vec<NearbyUi>,
    pairing: Option<PairingUi>,
    browsing: bool,
    /// goes up with each Add Again… from a viewer window: the list opens Add Computer
    add_requests: u64,
    /// goes up with each pairing that ended paired: the panel closes
    paired: u64,
}

fn status() -> ComputersStatus {
    let Some(v) = viewers() else { return ComputersStatus { computers: vec![], nearby: vec![], pairing: None, browsing: false, add_requests: 0, paired: 0 } };
    let list = v.computers.list();
    let nearby = v.nearby.lock().unwrap().clone();
    let no_direct = v.no_direct.lock().unwrap().clone();
    let presence = v.presence.lock().unwrap().clone();
    let refused = v.refused.lock().unwrap().clone();
    let ws = v.windows.lock().unwrap();
    let computers = list
        .iter()
        .map(|c| {
            let mine: Vec<&Win> = ws.values().filter(|w| w.host_id == c.host_id).collect();
            let live = mine.iter().find(|w| w.link == Link::Connected);
            let mut last_seen = c.last_seen;
            let gone = presence.get(&c.host_id).filter(|p| !p.host);
            let (state, route) = if let Some(w) = live {
                ("connected", w.route)
            } else if c.removed || refused.contains(&c.host_id) {
                // its key is gone there (or refused this run): it has to be added again
                ("removed", None)
            } else if nearby.iter().any(|n| n.host_id == c.host_id) {
                ("available", Some(Route::Local))
            } else if let Some(p) = gone {
                // its relay says it isn't there: asleep since (it said so), else offline since it was last seen
                last_seen = p.asleep.or(p.seen).or(c.last_seen);
                (if p.asleep.is_some() { "asleep" } else { "offline" }, None)
            } else if no_direct.contains(&c.host_id) {
                ("noDirect", None)
            } else if let Some(t) = c.addresses.iter().find_map(|a| a.parse().ok().and_then(|ip| blurt_remote::relay::overlay_of(ip, ""))) {
                ("available", c.last_route.or(Some(if t == blurt_remote::relay::Overlay::Tailscale { Route::Tailscale } else { Route::Overlay })))
            } else if let Some(r) = &c.relay {
                // the path it last used (a computer on this network that DNS-SD didn't find says Same network), else the relay
                ("available", c.last_route.or(Some(if r.contains("meet.blurt.work") { Route::GoBetween } else { Route::Relay })))
            } else {
                ("offline", None)
            };
            let key = !c.removed;
            ComputerUi { id: c.host_id.clone(), name: c.shown().to_string(), own_name: c.name.clone(), platform: c.platform.clone(), state, key, route, last_seen, windows: mine.len() }
        })
        .collect();
    // one that removed this computer (or refused its key this run) is offered again: it's added again
    let paired: Vec<&str> = list.iter().filter(|c| !c.removed && !refused.contains(&c.host_id)).map(|c| c.host_id.as_str()).collect();
    let nearby = nearby.iter().filter(|n| !paired.contains(&n.host_id.as_str())).map(|n| NearbyUi { id: n.host_id.clone(), name: n.name.clone() }).collect();
    let pairing =
        v.pairing.lock().unwrap().as_ref().map(|p| PairingUi { name: p.name.clone(), state: p.state, digits: p.digits.clone(), error: p.error, link: p.link });
    ComputersStatus { computers, nearby, pairing, browsing: v.browser.lock().unwrap().is_some(), add_requests: v.add_requests.load(SeqCst), paired: v.paired.load(SeqCst) }
}

fn emit() {
    if let Some(v) = viewers() {
        let _ = v.app.emit("computers://status", status());
    }
}

#[tauri::command]
pub fn computers_status() -> ComputersStatus {
    status()
}

/// Look for computers nearby (while the list shows): their rows say Available, and unpaired ones are offered under Add Computer.
#[tauri::command]
pub fn computers_browse(on: bool) -> ComputersStatus {
    if let Some(v) = viewers() {
        let mut b = v.browser.lock().unwrap();
        if on && b.is_none() {
            let own = std::fs::read(dir().join("host.json"))
                .ok()
                .and_then(|b| serde_json::from_slice::<serde_json::Value>(&b).ok())
                .and_then(|h| h["id"].as_str().map(str::to_string));
            *b = viewer::browse(
                own,
                Arc::new(|found| {
                    if let Some(v) = viewers() {
                        *v.nearby.lock().unwrap() = found;
                    }
                    emit();
                }),
            );
            peek_while_browsing();
        } else if !on {
            *b = None;
            v.nearby.lock().unwrap().clear();
        }
    }
    status()
}

/// While the list shows (browsing): each closed computer's relay is asked once a minute whether it's there (a few small requests).
fn peek_while_browsing() {
    std::thread::spawn(|| loop {
        let Some(v) = viewers() else { return };
        if v.browser.lock().unwrap().is_none() {
            return;
        }
        let open: Vec<String> = v.windows.lock().unwrap().values().filter(|w| w.link == Link::Connected).map(|w| w.host_id.clone()).collect();
        for c in v.computers.list() {
            let (Some(relay), Some(key)) = (c.relay.clone(), v.computers.key(&c.host_id)) else { continue };
            if open.contains(&c.host_id) {
                continue;
            }
            let p = blurt_remote::relay::peek(&relay, &blurt_remote::relay::room(&key));
            let mut m = v.presence.lock().unwrap();
            match p {
                Some(p) => m.insert(c.host_id.clone(), p),
                None => m.remove(&c.host_id),
            };
        }
        emit();
        std::thread::sleep(std::time::Duration::from_secs(60));
    });
}

fn set_pairing(g: u64, f: impl FnOnce(&mut Option<Pairing>)) {
    let Some(v) = viewers() else { return };
    if v.pair_gen.load(SeqCst) != g {
        return; // cancelled, or another one started
    }
    f(&mut v.pairing.lock().unwrap());
    emit();
}

/// Pair with a computer found nearby (`nearby`: its id) or with a pasted link (`link`). The host asks its owner; the digits show
/// here meanwhile. → the status (the pairing's progress comes as events).
#[tauri::command]
pub fn computers_pair(nearby: Option<String>, link: Option<String>) -> ComputersStatus {
    let Some(v) = viewers() else { return status() };
    let from = match (nearby, link) {
        (Some(id), _) => match v.nearby.lock().unwrap().iter().find(|f| f.host_id == id).cloned() {
            Some(f) => PairFrom::Nearby(f),
            None => return status(),
        },
        (None, Some(l)) => PairFrom::Link(l),
        _ => return status(),
    };
    start_pairing(v, from);
    status()
}

/// The failed panel's Try Again: the same link, or the computer found nearby, once more (a new question there).
#[tauri::command]
pub fn computers_retry_pairing() -> ComputersStatus {
    let Some(v) = viewers() else { return status() };
    let last = v.pair_last.lock().unwrap().clone();
    if let Some(from) = last {
        start_pairing(v, from);
    }
    status()
}

fn start_pairing(v: &'static Viewers, from: PairFrom) {
    stop_pairing(v);
    let by_link = matches!(from, PairFrom::Link(_));
    let with = match &from {
        PairFrom::Nearby(f) => PairWith::Nearby(f.clone()),
        PairFrom::Link(l) => match blurt_remote::pairing::Pairing::parse(l.trim()) {
            Some(p) => PairWith::Link(p),
            None => {
                *v.pairing.lock().unwrap() = Some(Pairing { name: String::new(), state: "failed", digits: None, error: Some("invalid"), link: true });
                emit();
                return;
            }
        },
    };
    *v.pair_last.lock().unwrap() = Some(from);
    let (host_id, name) = match &with {
        PairWith::Link(p) => (&p.host_id, &p.name),
        PairWith::Nearby(f) => (&f.host_id, &f.name),
    };
    // one paired before (Add Again…) is named as this computer calls it
    let name = v.computers.get(host_id).and_then(|c| c.alias).unwrap_or_else(|| name.clone());
    let g = v.pair_gen.fetch_add(1, SeqCst) + 1;
    *v.pairing.lock().unwrap() = Some(Pairing { name, state: "connecting", digits: None, error: None, link: by_link });
    emit();
    let me = blurt_remote::server::computer_name();
    let at = test_go_between();
    let task = v.rt.spawn(async move {
        // nothing answering is said, and it goes on trying: if the host turns up and asks, its digits take the place of the failure
        let r = viewer::pair_steps(with, &me, at.as_deref(), viewer::QUESTION_LIFE, true, |s| {
            set_pairing(g, move |p| {
                if let Some(p) = p {
                    match s {
                        PairStep::Unreachable => {
                            p.state = "failed";
                            p.error = Some("unreachable");
                            p.digits = None;
                        }
                        PairStep::Asking(d) => {
                            p.state = "asking";
                            p.error = None;
                            p.digits = Some(d);
                        }
                    }
                }
            });
        })
        .await;
        match r {
            Ok((c, key)) => {
                let id = c.host_id.clone();
                // paired (again): the record by the host's id, with its new key, and nothing said against it this run
                let ok = viewers().is_some_and(|v| v.computers.add(c, &key).is_ok());
                if ok {
                    if let Some(v) = viewers() {
                        v.refused.lock().unwrap().remove(&id);
                        v.paired.fetch_add(1, SeqCst);
                    }
                }
                set_pairing(g, |p| *p = if ok { None } else { p.take().map(|p| Pairing { state: "failed", error: Some("unreachable"), ..p }) });
                if ok {
                    // paired: its window opens, as a phone shows the computer at once
                    if let Some(v) = viewers() {
                        let app = v.app.clone();
                        let _ = v.app.run_on_main_thread(move || {
                            let _ = open_window(&app, &id);
                        });
                    }
                }
            }
            Err(e) => {
                let why = match e {
                    PairError::Unreachable => "unreachable",
                    PairError::Spent => "spent",
                    PairError::Declined => "declined",
                    PairError::Unanswered => "unanswered",
                };
                set_pairing(g, |p| {
                    if let Some(p) = p {
                        p.state = "failed";
                        p.error = Some(why);
                        p.digits = None;
                    }
                });
            }
        }
    });
    *v.pair_task.lock().unwrap() = Some(task);
}

/// A pairing under way stops: its task ends, the connection with it, so the host's question goes too.
fn stop_pairing(v: &Viewers) {
    v.pair_gen.fetch_add(1, SeqCst);
    if let Some(t) = v.pair_task.lock().unwrap().take() {
        t.abort();
    }
}

/// Done with the pairing panel (Cancel), or Back to its first page after a failure: a pairing still under way stops.
#[tauri::command]
pub fn computers_cancel_pairing() -> ComputersStatus {
    if let Some(v) = viewers() {
        stop_pairing(v);
        *v.pairing.lock().unwrap() = None;
    }
    emit();
    status()
}

/// Add Again…, from a viewer window whose computer removed this one: the main window's Remote Control page with Add Computer open,
/// and this window closes (it has nothing more to show).
#[tauri::command]
pub fn computers_add_again(app: AppHandle, window: WebviewWindow) -> ComputersStatus {
    crate::show_main(&app);
    let _ = app.emit("nav", json!({"view": "phone"}));
    if let Some(v) = viewers() {
        v.add_requests.fetch_add(1, SeqCst);
    }
    emit();
    if window.label().starts_with("viewer-") {
        let _ = window.close();
    }
    status()
}

#[tauri::command]
pub fn computers_remove(id: String) -> ComputersStatus {
    if let Some(v) = viewers() {
        let labels: Vec<String> = v.windows.lock().unwrap().iter().filter(|(_, w)| w.host_id == id).map(|(l, _)| l.clone()).collect();
        for l in labels {
            if let Some(w) = v.app.get_webview_window(&l) {
                let _ = w.close();
            }
            window_closed(&l);
        }
        // the host hears it next time it can (unpair), and drops this computer too
        if let (Some(c), Some(key)) = (v.computers.get(&id), v.computers.key(&id)) {
            let me = blurt_remote::server::computer_name();
            let at = test_go_between();
            v.rt.spawn(async move {
                let open = viewer::open(&me, &c.device_id, &key, c.port, &c.addresses, &[], None, at.as_deref());
                if let Ok(Ok((p, _))) = tokio::time::timeout(std::time::Duration::from_secs(3), open).await {
                    p.send(&ToMac::Unpair).await;
                    tokio::time::sleep(std::time::Duration::from_millis(300)).await;
                }
            });
        }
        v.computers.remove(&id);
        v.refused.lock().unwrap().remove(&id);
    }
    emit();
    status()
}

/// The owner's own name for a computer (remote-1.1.md §6): kept here only, nothing sent; "" goes back to the host's own name. Its
/// open windows take the new title.
#[tauri::command]
pub fn computers_rename(id: String, name: String) -> ComputersStatus {
    if let Some(v) = viewers() {
        v.computers.rename(&id, &name);
        if let Some(c) = v.computers.get(&id) {
            let labels: Vec<String> = v.windows.lock().unwrap().iter().filter(|(_, w)| w.host_id == id).map(|(l, _)| l.clone()).collect();
            for l in labels {
                if let Some(w) = v.app.get_webview_window(&l) {
                    let _ = w.set_title(c.shown());
                }
            }
        }
    }
    emit();
    status()
}

/// Open Window / Connect: the computer's window comes forward, or opens and connects. Async on purpose: a webview built inside a
/// synchronous command deadlocks on Windows (the window opens white and never answers).
#[tauri::command]
pub async fn computers_open(app: AppHandle, id: String) -> ComputersStatus {
    // Connect is a fresh try: what the last one found no longer stands
    if let Some(v) = viewers() {
        v.no_direct.lock().unwrap().remove(&id);
        // its key is gone: nothing to open a window with (the list offers Add Again… instead)
        if v.computers.get(&id).is_some_and(|c| c.removed) {
            return status();
        }
    }
    let _ = open_window(&app, &id);
    status()
}

fn open_window(app: &AppHandle, id: &str) -> Result<(), String> {
    let v = viewers().ok_or("not started")?;
    let c = v.computers.get(id).ok_or("not paired")?;
    let existing = v.windows.lock().unwrap().iter().find(|(_, w)| w.host_id == id).map(|(l, _)| l.clone());
    if let Some(w) = existing.and_then(|l| app.get_webview_window(&l)) {
        let _ = w.unminimize();
        let _ = w.show();
        let _ = w.set_focus();
        return Ok(());
    }
    let n = v.next_window.fetch_add(1, SeqCst);
    let label = format!("viewer-{n}");
    v.windows.lock().unwrap().insert(
        label.clone(),
        Win {
            host_id: c.host_id.clone(),
            session: None,
            channel: None,
            keyboard: Keyboard::new(),
            platform: c.platform.clone().unwrap_or_else(|| "mac".into()),
            captured: false,
            focused: true,
            link: Link::Connecting,
            route: None,
            clip: None,
            held_trigger: None,
        },
    );
    let url = format!("index.html?viewer={}", urlencode(&c.host_id));
    WebviewWindowBuilder::new(app, &label, WebviewUrl::App(url.into()))
        .title(c.shown())
        .inner_size(1280.0, 840.0)
        .min_inner_size(480.0, 320.0)
        .disable_drag_drop_handler()
        .build()
        .map_err(|e| e.to_string())?;
    emit();
    Ok(())
}

fn urlencode(s: &str) -> String {
    s.bytes().map(|b| if b.is_ascii_alphanumeric() || b"-_.~".contains(&b) { (b as char).to_string() } else { format!("%{b:02X}") }).collect()
}

fn test_go_between() -> Option<String> {
    if crate::remote::test_build() {
        std::env::var("BLURT_TEST_GO_BETWEEN").ok().filter(|s| !s.is_empty())
    } else {
        None
    }
}

// ------------------------------------------------------------------ a window

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ViewerInit {
    id: String,
    name: String,
    platform: Option<String>,
    options: Options,
    /// "all" or "local": whether system shortcuts reach the other computer while captured (viewer_keys.rs)
    system_shortcuts: &'static str,
    /// this computer: "windows", "linux" (the release keys and hint follow it)
    os: &'static str,
}

fn send_json(ch: &Channel<InvokeResponseBody>, v: serde_json::Value) {
    let _ = ch.send(InvokeResponseBody::Json(v.to_string()));
}

fn route_json(r: Option<Route>) -> serde_json::Value {
    serde_json::to_value(r).unwrap_or_default()
}

/// What a session says, to its window.
fn on_event(label: String) -> viewer::OnEvent {
    Arc::new(move |e: Event| {
        let Some(v) = viewers() else { return };
        let mut ws = v.windows.lock().unwrap();
        let Some(w) = ws.get_mut(&label) else { return };
        let Some(ch) = w.channel.clone() else { return };
        match e {
            Event::Frame(f) => {
                let mut b = Vec::with_capacity(f.data.len() + 16 + f.codec.len());
                b.push(1u8);
                b.push(f.keyframe as u8);
                b.extend_from_slice(&f.id.to_le_bytes());
                b.push(f.codec.len() as u8);
                b.extend_from_slice(f.codec.as_bytes());
                b.extend_from_slice(&f.data);
                drop(ws);
                let _ = ch.send(InvokeResponseBody::Raw(b));
            }
            Event::Link { link, route } => {
                let changed = w.link != link || w.route != route;
                w.link = link;
                w.route = route;
                let host = w.host_id.clone();
                drop(ws);
                match link {
                    Link::NoDirect => {
                        v.no_direct.lock().unwrap().insert(host);
                    }
                    Link::Removed => {
                        // said in a session it had opened, so it's so: the key goes, the list says Removed until it's added again
                        v.computers.mark_removed(&host);
                    }
                    Link::Forgotten => {
                        // a refusal with no session, which anyone on the network can send: said for this run, the key kept
                        v.refused.lock().unwrap().insert(host);
                    }
                    Link::Connected => {
                        v.no_direct.lock().unwrap().remove(&host);
                        v.refused.lock().unwrap().remove(&host);
                        // the list names this path afterwards, not the relay it happens to know
                        if route.is_some() && v.computers.get(&host).is_some_and(|c| c.last_route != route) {
                            v.computers.update(&host, |c| c.last_route = route);
                        }
                    }
                    _ => {}
                }
                send_json(&ch, json!({"type": "link", "link": link, "route": route_json(route)}));
                if changed {
                    emit();
                }
            }
            Event::Rtt(ms) => send_json(&ch, json!({"type": "rtt", "ms": ms})),
            Event::Session(i) => {
                w.platform = i.platform.clone().unwrap_or_else(|| "mac".into());
                let has = |n: &str| i.features.as_ref().is_some_and(|f| f.iter().any(|x| x == n));
                // the window's title is the name this computer gives it: the host's own only when it has none here
                let name = v.computers.get(&w.host_id).and_then(|c| c.alias).unwrap_or_else(|| i.mac_name.clone());
                send_json(&ch, json!({"type": "session", "name": name, "platform": i.platform, "canControl": i.can_control,
                    "privacy": has("privacy"), "files": has("files")}));
            }
            Event::Displays(l) => {
                let l: Vec<_> = l.iter().map(|d| json!({"id": d.id, "name": d.name, "x": d.x, "y": d.y, "width": d.width, "height": d.height, "main": d.main})).collect();
                send_json(&ch, json!({"type": "displays", "displays": l}));
            }
            Event::View { width, height, family, display } => {
                send_json(&ch, json!({"type": "view", "width": width, "height": height, "family": family, "display": display}))
            }
            Event::Cursor { x, y } => send_json(&ch, json!({"type": "cursor", "x": x, "y": y})),
            Event::CursorShape { png, hot_x, hot_y, width, height } => send_json(
                &ch,
                json!({"type": "cursorShape", "png": blurt_remote::wire::b64(&png), "hotX": hot_x, "hotY": hot_y, "width": width, "height": height}),
            ),
            Event::Clipboard(t) => {
                // the host's clipboard changed while keys were captured here: this computer's takes it
                let on = v.options.lock().unwrap().clipboard && w.captured;
                if on && blurt_remote::wire::clipboard_fits(&t) {
                    w.clip = Some(t.clone());
                    drop(ws);
                    use tauri_plugin_clipboard_manager::ClipboardExt;
                    let _ = v.app.clipboard().write_text(t);
                }
            }
            Event::ScreenFailed(why) => send_json(&ch, json!({"type": "screenFailed", "why": why})),
            Event::CanControl(b) => send_json(&ch, json!({"type": "canControl", "on": b})),
            Event::ScreenLocked(b) => send_json(&ch, json!({"type": "screenLocked", "locked": b})),
            Event::FileProgress { id, bytes } => {
                if let Some(a) = outgoing().lock().unwrap().get(&id) {
                    a.store(bytes, SeqCst);
                }
            }
            Event::FileSaved { id, name } => {
                outgoing().lock().unwrap().remove(&id);
                send_json(&ch, json!({"type": "file", "state": "saved", "name": name}));
            }
            Event::FileFailed { id, why } => {
                outgoing().lock().unwrap().remove(&id);
                send_json(&ch, json!({"type": "file", "state": "failed", "why": why}));
            }
            Event::Notice(text) => {
                // a notification, so it's seen even with this window behind
                use tauri_plugin_notification::NotificationExt;
                let title = v.computers.get(&w.host_id).map(|c| c.shown().to_string()).unwrap_or_else(|| "Blurt".into());
                let _ = v.app.notification().builder().title(title).body(text).show();
            }
        }
    })
}

/// The window's webview is ready: its channel, and the session starts (again, after a reload).
#[tauri::command]
pub fn viewer_attach(window: WebviewWindow, channel: Channel<InvokeResponseBody>) -> Result<ViewerInit, String> {
    let v = viewers().ok_or("not started")?;
    let label = window.label().to_string();
    let host_id = v.windows.lock().unwrap().get(&label).map(|w| w.host_id.clone()).ok_or("no such window")?;
    let c: Computer = v.computers.get(&host_id).ok_or("not paired")?;
    let key = v.computers.key(&host_id).ok_or("no key")?;
    let nearby = v.nearby.lock().unwrap().iter().find(|f| f.host_id == host_id).map(|f| f.addresses.clone()).unwrap_or_default();
    let target = Target { computer: c.clone(), key, device: blurt_remote::server::computer_name(), nearby, go_between_at: test_go_between() };
    let learned: viewer::OnLearned = {
        let id = host_id.clone();
        Arc::new(move |i| {
            if let Some(v) = viewers() {
                v.computers.update(&id, |c| {
                    c.name = i.mac_name.clone();
                    c.platform = i.platform.clone();
                    if i.relay.is_some() {
                        c.relay = i.relay.clone();
                    }
                    viewer::remember_candidates(&mut c.addresses, i);
                    c.last_seen = Some(blurt_remote::store::now_ms());
                });
            }
        })
    };
    {
        let mut ws = v.windows.lock().unwrap();
        let w = ws.get_mut(&label).ok_or("no such window")?;
        w.channel = Some(channel);
        w.session = None; // a reload: the old one closes first
        w.keyboard = Keyboard::new();
        w.captured = false;
    }
    let s = Session::start(v.rt.handle(), target, on_event(label.clone()), learned);
    if let Some(w) = v.windows.lock().unwrap().get_mut(&label) {
        w.session = Some(s);
    }
    let os = if cfg!(windows) { "windows" } else if cfg!(target_os = "linux") { "linux" } else { "mac" };
    Ok(ViewerInit { id: c.host_id.clone(), name: c.shown().to_string(), platform: c.platform, options: *v.options.lock().unwrap(), system_shortcuts: crate::viewer_keys::system_shortcuts(), os })
}

fn with_win<T>(window: &WebviewWindow, f: impl FnOnce(&mut Win) -> T) -> Option<T> {
    let v = viewers()?;
    let mut ws = v.windows.lock().unwrap();
    ws.get_mut(window.label()).map(f)
}

fn send(window: &WebviewWindow, m: ToMac) {
    with_win(window, |w| {
        if let Some(s) = &w.session {
            s.send(m)
        }
    });
}

/// The picture's area in pixels, what this webview decodes, the quality, the display (None: follow the pointer). None: off.
#[tauri::command]
pub fn viewer_screen(window: WebviewWindow, width: i64, height: i64, codecs: Vec<String>, quality: Quality, display: Option<String>, on: bool) {
    with_win(&window, |w| {
        if let Some(s) = &w.session {
            s.screen(on.then_some(Want { quality, window: (width, height), codecs, display }));
        }
    });
}

/// The pointer to this place on the picture, 0…1.
#[tauri::command]
pub fn viewer_pointer(window: WebviewWindow, x: f32, y: f32) {
    send(&window, ToMac::PointerTo { x: x.clamp(0.0, 1.0), y: y.clamp(0.0, 1.0), seq: None });
}

/// 0 left, 1 right, 2 middle.
#[tauri::command]
pub fn viewer_button(window: WebviewWindow, button: u8, down: bool) {
    let b = match button {
        1 => MouseButton::Right,
        2 => MouseButton::Middle,
        _ => MouseButton::Left,
    };
    send(&window, ToMac::Button { button: b, down });
}

/// Wheel or trackpad, in points, the content's direction (positive dy: content moves down). `phase`: 1 began, 2 changed, 3 ended.
#[tauri::command]
pub fn viewer_scroll(window: WebviewWindow, dx: f32, dy: f32, phase: u8) {
    let phase = match phase {
        1 => ScrollPhase::Began,
        3 => ScrollPhase::Ended,
        _ => ScrollPhase::Changed,
    };
    with_win(&window, |w| {
        if let Some(s) = &w.session {
            s.pointer(PointerPacket::Scroll { dx, dy, phase });
        }
    });
}

/// One key of this keyboard, by the web's `KeyboardEvent.code`. → true: Ctrl+Alt, the keys are given back.
#[tauri::command]
pub fn viewer_key(window: WebviewWindow, code: String, down: bool) -> bool {
    key_event(window.label(), &code, down)
}

/// The dictation key's codes (record.dictation.key, right Alt by default) while dictation is on: never sent alone to a remote.
fn dictation_codes() -> &'static [&'static str] {
    let d = crate::settings::read_config().pointer("/record/dictation").cloned().unwrap_or_default();
    if d.get("enabled").and_then(serde_json::Value::as_bool) == Some(false) {
        return &[];
    }
    match d.get("key").and_then(serde_json::Value::as_str) {
        Some("either_option" | "either_alt") => &["AltLeft", "AltRight"],
        _ => &["AltRight"],
    }
}

fn key_event(label: &str, code: &str, down: bool) -> bool {
    let Some(v) = viewers() else { return false };
    let mapped = v.options.lock().unwrap().mapped;
    let mut ws = v.windows.lock().unwrap();
    let Some(w) = ws.get_mut(label) else { return false };
    if !w.captured {
        return false;
    }
    // the dictation key (remote-1.1.md §4): held back; let go alone it was dictation here and the remote never hears it
    if dictation_codes().contains(&code) {
        if down && w.held_trigger.is_none() {
            w.held_trigger = Some(code.to_string());
            return true;
        }
        if !down && w.held_trigger.as_deref() == Some(code) {
            w.held_trigger = None;
            return true;
        }
    } else if down {
        if let Some(t) = w.held_trigger.take() {
            // another key with it: a chord (AltGr+E), so it goes on first
            let platform = w.platform.clone();
            for x in w.keyboard.event(&t, true, &platform, mapped) {
                if let (Sent::Message(m), Some(s)) = (x, &w.session) {
                    s.send(m);
                }
            }
        }
    }
    let mut released = false;
    let platform = w.platform.clone();
    for x in w.keyboard.event(code, down, &platform, mapped) {
        match x {
            Sent::Message(m) => {
                if let Some(s) = &w.session {
                    s.send(m);
                }
            }
            Sent::Release => released = true,
        }
    }
    if released {
        w.captured = false;
        if let Some(s) = &w.session {
            s.send(ToMac::KeysCaptured(false));
        }
        let ch = w.channel.clone();
        drop(ws);
        capture_os(label, false);
        if let Some(ch) = ch {
            send_json(&ch, json!({"type": "released"}));
        }
    }
    released
}

/// Keys captured (a click into the picture) or given back (Ctrl+Alt, the toolbar's switch). Captured, the host is told and this
/// computer's clipboard goes across.
#[tauri::command]
pub fn viewer_capture(window: WebviewWindow, on: bool) {
    let Some(v) = viewers() else { return };
    let clipboard = v.options.lock().unwrap().clipboard;
    let local = if on && clipboard {
        use tauri_plugin_clipboard_manager::ClipboardExt;
        v.app.clipboard().read_text().ok()
    } else {
        None
    };
    let focused = window.is_focused().unwrap_or(true);
    let mut ws = v.windows.lock().unwrap();
    let Some(w) = ws.get_mut(window.label()) else { return };
    if w.captured == on {
        return;
    }
    w.captured = on;
    if let Some(s) = &w.session {
        if !on {
            for m in w.keyboard.let_go() {
                s.send(m);
            }
        }
        s.send(ToMac::KeysCaptured(on));
        if let Some(t) = local.filter(|t| blurt_remote::wire::clipboard_fits(t) && w.clip.as_deref() != Some(t.as_str())) {
            w.clip = Some(t.clone());
            s.send(ToMac::Clipboard(t));
        }
    }
    drop(ws);
    capture_os(window.label(), on && focused);
}

/// The ⋯ menu's switches: the modifier mapping to a Mac, and the clipboard. Kept for every window.
#[tauri::command]
pub fn viewer_options(window: WebviewWindow, mapped: bool, clipboard: bool) -> Options {
    let Some(v) = viewers() else { return Options::default() };
    let o = Options { mapped, clipboard };
    *v.options.lock().unwrap() = o;
    if let Ok(b) = serde_json::to_vec_pretty(&o) {
        let _ = std::fs::create_dir_all(dir());
        let _ = std::fs::write(dir().join("viewer.json"), b);
    }
    with_win(&window, |w| {
        let p = w.platform.clone();
        if let (Some(m), Some(s)) = (w.keyboard.remap(&p, mapped), &w.session) {
            s.send(m);
        }
    });
    for (_, w) in v.app.webview_windows() {
        if w.label().starts_with("viewer-") {
            let _ = w.emit_to(w.label(), "viewer://options", o);
        }
    }
    o
}

/// The display switcher: show this one (and the pointer goes to it), or None: follow the pointer.
#[tauri::command]
pub fn viewer_show_display(window: WebviewWindow, id: Option<String>) {
    send(&window, ToMac::ShowDisplay(id));
}

/// Dictation with a computer's window in front (remote-1.1.md §4): the take is typed on that computer, whose host refuses it at a
/// lock screen or a password field. false: no such window, the take goes where it would have.
pub fn type_on_remote(text: &str) -> bool {
    let Some(v) = viewers() else { return false };
    let ws = v.windows.lock().unwrap();
    let Some(s) = ws.values().find(|w| w.focused && w.link == Link::Connected).and_then(|w| w.session.as_ref()) else { return false };
    s.send(ToMac::Text(text.to_string()));
    true
}

/// Files going out, by id: what the host has acknowledged writing (its fileProgress), so no more than WINDOW is ever in flight.
fn outgoing() -> &'static Mutex<HashMap<String, Arc<std::sync::atomic::AtomicI64>>> {
    static O: std::sync::OnceLock<Mutex<HashMap<String, Arc<std::sync::atomic::AtomicI64>>>> = std::sync::OnceLock::new();
    O.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Send Files… (and files dropped on the picture): each to the host's Downloads, in order, a chunk at a time and never more than
/// 4 MB ahead of what it has written. The window hears each one saved or not (`{"type": "file"}`).
#[tauri::command]
pub fn viewer_send_files(window: WebviewWindow, paths: Option<Vec<String>>) {
    let label = window.label().to_string();
    std::thread::spawn(move || {
        let paths: Vec<std::path::PathBuf> = match paths {
            Some(p) => p.into_iter().map(Into::into).collect(),
            None => {
                use tauri_plugin_dialog::DialogExt;
                let Some(v) = viewers() else { return };
                v.app.dialog().file().blocking_pick_files().unwrap_or_default().into_iter().filter_map(|f| f.into_path().ok()).collect()
            }
        };
        for p in paths {
            let Some(v) = viewers() else { return };
            let (sender, ch) = {
                let ws = v.windows.lock().unwrap();
                let Some(w) = ws.get(&label) else { return };
                (w.session.as_ref().map(|s| s.sender()), w.channel.clone())
            };
            let (Some(sender), Some(ch)) = (sender, ch) else { return };
            let name = p.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_else(|| "file".into());
            send_json(&ch, json!({"type": "file", "state": "sending", "name": name}));
            if !send_file(&sender, &p, &name) {
                send_json(&ch, json!({"type": "file", "state": "failed", "why": "read"}));
            }
        }
    });
}

fn send_file(s: &blurt_remote::viewer::Sender, p: &std::path::Path, name: &str) -> bool {
    use std::io::Read;
    const CHUNK: usize = 192 * 1024;
    const WINDOW: i64 = 4 << 20;
    let Ok(mut f) = std::fs::File::open(p) else { return false };
    let Ok(size) = f.metadata().map(|m| m.len() as i64) else { return false };
    let id = blurt_remote::crypto::new_id();
    let acked = Arc::new(std::sync::atomic::AtomicI64::new(0));
    outgoing().lock().unwrap().insert(id.clone(), acked.clone());
    if !s.send(ToMac::FileBegin { id: id.clone(), name: name.to_string(), size }) {
        return false;
    }
    let mut sent = 0i64;
    let mut buf = vec![0u8; CHUNK];
    loop {
        // the host is at most WINDOW behind; a minute without it moving and this one is given up
        let mut waited = 0;
        while sent - acked.load(SeqCst) > WINDOW {
            if waited > 3000 || !outgoing().lock().unwrap().contains_key(&id) {
                return true; // the host said why (fileFailed), or went quiet: the window says so either way
            }
            std::thread::sleep(std::time::Duration::from_millis(20));
            waited += 1;
        }
        let n = match f.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => n,
            Err(_) => return false,
        };
        if !s.send(ToMac::FileChunk { id: id.clone(), data: buf[..n].to_vec() }) {
            return false;
        }
        sent += n as i64;
    }
    s.send(ToMac::FileEnd { id })
}

/// A named move of the host's OS from the ⋯ menu (Ctrl+Alt+Del: `secureAttention`).
#[tauri::command]
pub fn viewer_system(window: WebviewWindow, name: String) {
    if let Some(m) = blurt_remote::wire::system_move(&name) {
        send(&window, ToMac::System(m));
    }
}

/// 隐私屏: the host covers its own screen (hosts whose session lists `privacy`).
#[tauri::command]
pub fn viewer_privacy(window: WebviewWindow, on: bool) {
    send(&window, ToMac::PrivacyScreen(on));
}

/// The decoder refused a frame: a keyframe.
#[tauri::command]
pub fn viewer_decode_failed(window: WebviewWindow) {
    with_win(&window, |w| {
        if let Some(s) = &w.session {
            s.decode_failed();
        }
    });
}

/// The keyboard taken from the system (Windows' hook, Linux's grab) while captured and in front, or given back.
fn capture_os(label: &str, on: bool) {
    #[cfg(windows)]
    {
        if on {
            let (tx, rx) = std::sync::mpsc::channel::<crate::viewer_keys::KeyEvent>();
            crate::viewer_keys::capture(Some(tx));
            let label = label.to_string();
            std::thread::spawn(move || {
                while let Ok(k) = rx.recv() {
                    if key_event(&label, k.code, k.down) {
                        return;
                    }
                }
            });
        } else {
            crate::viewer_keys::capture(None);
        }
    }
    #[cfg(target_os = "linux")]
    {
        if let Some(v) = viewers() {
            if let Some(w) = v.app.get_webview_window(label) {
                let w2 = w.clone();
                let _ = w.run_on_main_thread(move || crate::viewer_keys::grab(&w2, on));
            }
        }
    }
    #[cfg(not(any(windows, target_os = "linux")))]
    let _ = (label, on);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_status_is_the_contracts_shape() {
        let s = ComputersStatus {
            computers: vec![ComputerUi {
                id: "h".into(),
                name: "Studio PC".into(),
                own_name: "DESKTOP-7Q2".into(),
                platform: Some("windows".into()),
                state: "available",
                key: true,
                route: Some(Route::GoBetween),
                last_seen: None,
                windows: 0,
            }],
            nearby: vec![NearbyUi { id: "n".into(), name: "Den".into() }],
            pairing: Some(PairingUi { name: "Den".into(), state: "asking", digits: Some("123456".into()), error: None, link: false }),
            browsing: true,
            add_requests: 0,
            paired: 1,
        };
        let v = serde_json::to_value(&s).unwrap();
        assert_eq!(v["computers"][0]["route"], "goBetween");
        assert_eq!(v["computers"][0]["ownName"], "DESKTOP-7Q2");
        assert_eq!(v["computers"][0]["lastSeen"], serde_json::Value::Null);
        assert_eq!(v["pairing"]["digits"], "123456");
        assert_eq!(v["pairing"]["link"], false);
        assert_eq!(v["addRequests"], 0);
        assert_eq!(v["paired"], 1);
        assert_eq!(serde_json::to_value(Options::default()).unwrap(), json!({"mapped": true, "clipboard": true}));
        assert_eq!(urlencode("a b/c"), "a%20b%2Fc");
    }
}
