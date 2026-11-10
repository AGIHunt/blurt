//! Blurt on the phone, with this computer as its host (docs/design/remote.md, remote-protocol.md §The desktop app; the Mac's
//! RemoteServer.swift + RemotePane.swift). The session server is `crates/blurt-remote`; this file is what the desktop app gives it
//! and what Settings → Phone calls:
//!
//!  • the commands and the `remote://status` event (`RemoteStatus`, the QR code drawn here as an SVG);
//!  • the phone's keys and the paired list in `$BLURT_HOME/remote`, each phone's key in the OS's store (Credential Manager,
//!    the Secret Service);
//!  • a new phone asking: the main window comes forward with the six digits, and a notification says so;
//!  • the phone's talk key is the dictation key (the same trigger: tap, hold, double tap), and its microphone takes the place of
//!    this computer's when the phone asks for that; the take's phase, level, words and what was typed go back to the phone;
//!  • Blurt's commands from the phone do what the hotkeys do;
//!  • Windows Defender Firewall: whether it lets phones in on this network (`firewall`), and the one-click fix
//!    (`remote_allow_firewall`, remote_firewall.rs).
//!
//! Nothing listens until Settings shows a code or a phone is paired. Test builds (debug, BLURT_TEST_COMMANDS=1) keep keys in a
//! file and may answer the pairing question by themselves (BLURT_TEST_PAIR_ANSWER=yes|no), as the Mac's test hooks do.

use std::sync::mpsc::Sender;
use std::sync::{Mutex, OnceLock};

use blurt_remote::host::Backend;
use blurt_remote::server::{Problem, Status};
use blurt_remote::wire::{BlurtCommand, DictationPhase, Front};
use blurt_remote::{App, Host, HostConfig, KeyStore};
use serde::Serialize;
use serde_json::Value;
use tauri::{AppHandle, Emitter};

static HOST: OnceLock<Host> = OnceLock::new();
static APP: OnceLock<AppHandle> = OnceLock::new();

#[path = "remote_firewall.rs"]
mod firewall;

fn host() -> Option<&'static Host> {
    HOST.get()
}

fn testing() -> bool {
    cfg!(debug_assertions) && std::env::var("BLURT_TEST_COMMANDS").as_deref() == Ok("1")
}

fn zh() -> bool {
    crate::l10n::lang() == "zh-Hans"
}

/// At launch: the host, idle until a code shows or a phone is paired.
pub fn start(app: &AppHandle) {
    if HOST.get().is_some() || std::env::var_os("BLURT_NO_REMOTE").is_some() {
        return;
    }
    let _ = APP.set(app.clone());
    let dir = crate::paths::blurt_home().join("remote");
    let keys: Box<dyn KeyStore> = if testing() || cfg!(not(any(windows, target_os = "linux"))) {
        Box::new(blurt_remote::store::FileKeyStore::new(dir.join("test-keys.json")))
    } else {
        Box::new(OsKeys)
    };
    #[cfg(target_os = "linux")]
    linux_setup(app);
    let backend: Box<dyn Backend> = blurt_remote::platform::backend();
    let test_answer = if testing() {
        match std::env::var("BLURT_TEST_PAIR_ANSWER").as_deref() {
            Ok("yes") => Some(true),
            Ok("no") => Some(false),
            _ => None,
        }
    } else {
        None
    };
    let h = Host::start(
        HostConfig {
            dir,
            name: blurt_remote::server::computer_name(),
            version: app.package_info().version.to_string(),
            test_answer,
            port: 0,
        },
        backend,
        keys,
        Box::new(Desktop { app: app.clone() }),
    );
    let _ = HOST.set(h);
}

/// Linux, before the backend exists (remote-linux.md §For the app): the portal's restore token next to the app's own
/// (`$BLURT_HOME/portal`), GNOME's dialog over Blurt's window, and long or non-ASCII text from the phone put in the way
/// dictation does (Ctrl+Shift+V into a terminal). Called from `setup`, on the main thread.
#[cfg(target_os = "linux")]
fn linux_setup(app: &AppHandle) {
    use blurt_remote::platform::linux;
    linux::set_state_dir(crate::paths::blurt_home().join("portal"));
    // the main window exists now; the island (always on top, which GNOME's dialog should open over, as for dictation's
    // access) is made on a thread of its own a moment later, so it replaces the main window once it's there
    linux::set_dialog_parent(crate::mainwin::x11_id_of(app, "main"));
    let a = app.clone();
    std::thread::spawn(move || {
        for _ in 0..20 {
            std::thread::sleep(std::time::Duration::from_millis(500));
            if let Some(x) = crate::mainwin::x11_id_off_main(&a, "blurt-overlay-island") {
                linux::set_dialog_parent(Some(x));
                return;
            }
        }
    });
    linux::set_paste(linux_paste);
}

/// The phone's text through dictation's paste: the clipboard, Ctrl+V (Ctrl+Shift+V into a terminal) on dictation's own
/// Remote Desktop session, and the user's clipboard back unless they copied something since. false (nothing done): no
/// access to that session yet, and the crate pastes its own way, through the phone's session.
#[cfg(target_os = "linux")]
fn linux_paste(text: &str) -> bool {
    use crate::dictation::insert_linux as ins;
    if !ins::has_access() {
        return false;
    }
    let saved = ins::save();
    if !ins::set_text(text) {
        return false;
    }
    let seq = ins::sequence();
    std::thread::sleep(std::time::Duration::from_millis(30));
    if !ins::paste_keys() {
        ins::restore(&saved);
        return false;
    }
    std::thread::spawn(move || {
        std::thread::sleep(std::time::Duration::from_millis(800));
        if ins::sequence() == seq {
            ins::restore(&saved);
        }
    });
    true
}

/// Quitting: let go of everything held, close the session, stop listening.
pub fn stop() {
    if let Some(h) = host() {
        h.stop();
    }
}

// ------------------------------------------------------------------ Settings → Phone

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct RemoteStatus {
    listening: bool,
    pairing: Option<PairingUi>,
    asking: Option<AskingUi>,
    devices: Vec<DeviceUi>,
    connected: Option<ConnectedUi>,
    relay: RelayUi,
    screen_allowed: bool,
    can_control: bool,
    problem: Option<String>,
    /// "ok", "blocked" (Windows Defender Firewall keeps phones out on this network: `remote_allow_firewall`) or "unknown"
    firewall: &'static str,
}

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
struct PairingUi {
    url: String,
    qr_svg: String,
    expires_at: i64,
}

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
struct AskingUi {
    device: String,
    digits: String,
    via_relay: bool,
}

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
struct DeviceUi {
    id: String,
    name: String,
    last_seen: Option<i64>,
}

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
struct ConnectedUi {
    id: String,
    name: String,
    route: &'static str,
    screen: bool,
}

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
struct RelayUi {
    address: Option<String>,
    from_phone: bool,
    reachable: Option<bool>,
}

/// The pairing link as a QR code: a complete <svg>, dark on light whatever the theme (cameras read it either way, and the
/// page puts it on a light tile).
fn qr_svg(url: &str) -> String {
    use qrcode::render::svg;
    match qrcode::QrCode::with_error_correction_level(url.as_bytes(), qrcode::EcLevel::M) {
        Ok(c) => c
            .render::<svg::Color>()
            .min_dimensions(240, 240)
            .quiet_zone(true)
            .dark_color(svg::Color("#000000"))
            .light_color(svg::Color("#ffffff"))
            .build()
            // the <svg> alone: the page puts it straight into its markup
            .split_once("<svg")
            .map(|(_, rest)| format!("<svg{rest}"))
            .unwrap_or_default(),
        Err(_) => String::new(),
    }
}

fn problem(p: &Problem) -> String {
    match p {
        Problem::Listen(why) => {
            if zh() {
                format!("无法在本机打开连接端口（{why}）。手机暂时连不上这台电脑。")
            } else {
                format!("Couldn't open a port on this computer ({why}). Phones can't connect to it for now.")
            }
        }
    }
}

fn to_ui(s: &Status) -> RemoteStatus {
    // the QR code is drawn once per code, not on every status
    static QR: Mutex<Option<(String, String)>> = Mutex::new(None);
    let pairing = s.pairing.as_ref().map(|p| {
        let mut q = QR.lock().unwrap();
        let svg = match q.as_ref() {
            Some((u, svg)) if *u == p.url => svg.clone(),
            _ => {
                let svg = qr_svg(&p.url);
                *q = Some((p.url.clone(), svg.clone()));
                svg
            }
        };
        PairingUi { url: p.url.clone(), qr_svg: svg, expires_at: p.expires_at }
    });
    RemoteStatus {
        listening: s.listening,
        pairing,
        asking: s.asking.as_ref().map(|a| AskingUi { device: a.device.clone(), digits: a.digits.clone(), via_relay: a.via_relay }),
        devices: s.devices.iter().map(|d| DeviceUi { id: d.id.clone(), name: d.name.clone(), last_seen: d.last_seen }).collect(),
        connected: s.connected.as_ref().map(|c| ConnectedUi { id: c.id.clone(), name: c.name.clone(), route: c.route, screen: c.screen }),
        relay: RelayUi { address: s.relay.address.clone(), from_phone: s.relay.from_phone, reachable: s.relay.reachable },
        screen_allowed: s.screen_allowed,
        can_control: s.can_control,
        problem: s.problem.as_ref().map(problem),
        firewall: firewall::state(),
    }
}

/// Settings hears the status again (a firewall check changed its answer).
fn emit_now() {
    if let Some(a) = APP.get() {
        let _ = a.emit("remote://status", now_status());
    }
}

/// The firewall checked again, off the caller's thread; Settings hears if the answer changed.
fn firewall_recheck() {
    if !cfg!(windows) {
        return;
    }
    std::thread::spawn(|| {
        if firewall::recheck() {
            emit_now();
        }
    });
}

/// While the host listens (Windows): checked when it starts, then again whenever the network's profile changes (Public ↔
/// Private, another network), polled every 10 s — one cheap COM call.
fn firewall_watch() {
    static RUNNING: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
    if !cfg!(windows) || RUNNING.swap(true, std::sync::atomic::Ordering::SeqCst) {
        return;
    }
    std::thread::spawn(|| {
        let mut last = None;
        while host().is_some_and(|h| h.status().listening) {
            let now = firewall::current_profiles();
            if last.is_none() || now != last {
                last = now;
                if firewall::recheck() {
                    emit_now();
                }
            }
            std::thread::sleep(std::time::Duration::from_secs(10));
        }
        RUNNING.store(false, std::sync::atomic::Ordering::SeqCst);
    });
}

fn now_status() -> RemoteStatus {
    to_ui(&host().map(Host::status).unwrap_or_default())
}

#[tauri::command]
pub fn remote_status() -> RemoteStatus {
    now_status()
}

/// Settings → Phone shows the code (on: listen, advertise, a code good for 2 minutes and one phone), or closed. A question
/// already asked stays: the app-wide dialog keeps showing it.
#[tauri::command]
pub fn remote_show_pairing(on: bool) -> RemoteStatus {
    if let Some(h) = host() {
        h.show_pairing(on);
    }
    if on {
        firewall_recheck();
    }
    now_status()
}

/// Windows Defender Firewall keeps phones out: the doc's netsh lines, elevated through Windows' own UAC prompt, on the owner's
/// click only. Waits for it, checks again, and answers; a declined prompt leaves `firewall` "blocked", with no error.
#[tauri::command]
pub async fn remote_allow_firewall() -> RemoteStatus {
    let _ = tauri::async_runtime::spawn_blocking(firewall::allow).await;
    let s = now_status();
    emit_now();
    s
}

/// The owner's answer. `digits`: the six digits they were shown; the answer counts only for the phone showing those.
#[tauri::command]
pub fn remote_answer_pairing(yes: bool, digits: Option<String>) -> RemoteStatus {
    if let Some(h) = host() {
        h.answer_pairing(yes, digits.as_deref());
    }
    now_status()
}

#[tauri::command]
pub fn remote_remove_device(id: String) -> RemoteStatus {
    if let Some(h) = host() {
        h.remove_device(&id);
    }
    now_status()
}

/// "" clears it; Err with a sentence when it can't be a relay's address.
#[tauri::command]
pub fn remote_set_relay(address: String) -> Result<RemoteStatus, String> {
    let Some(h) = host() else { return Ok(now_status()) };
    let a = address.trim();
    h.set_relay((!a.is_empty()).then_some(a)).map_err(|_| {
        if zh() {
            "这不是中继地址。应以 wss:// 或 ws:// 开头，例如 wss://relay.example.com。".to_string()
        } else {
            "That isn't a relay address. It starts with wss:// or ws://, like wss://relay.example.com.".to_string()
        }
    })?;
    Ok(now_status())
}

/// Does anything answer as a relay there (up to 8 s)?
#[tauri::command]
pub async fn remote_check_relay(address: String) -> bool {
    let Some(h) = host().cloned() else { return false };
    tauri::async_runtime::spawn_blocking(move || h.check_relay(&address)).await.unwrap_or(false)
}

#[tauri::command]
pub fn remote_set_screen_allowed(on: bool) -> RemoteStatus {
    if let Some(h) = host() {
        h.set_screen_allowed(on);
    }
    now_status()
}

/// The prompt for Claude Code or Codex that sets up a relay (the Mac's Copy Instructions, for phone and computer).
#[tauri::command]
pub fn remote_relay_instructions() -> String {
    RELAY_PROMPT.to_string()
}

const RELAY_PROMPT: &str = "Set up a relay I own for Blurt on my phone, then give me its address to paste into Blurt.

Blurt for phones turns an iPhone or Android phone into a trackpad and keyboard for a computer. When the two aren't on the same network they connect through a small WebSocket relay. It passes sealed bytes it can't read and stores nothing.

The code and the full steps are here; read README.md first:
https://github.com/AGIHunt/blurt/tree/main/tools/remote-relay

Ask me which of these I have, then do that one:
A. A domain on Cloudflare: deploy the Worker on a subdomain such as relay.example.com. The free plan is enough for one person.
B. A server with a public IP: run server.js as a service (Node 12 or later, one dependency). With a domain, serve it over HTTPS on port 443 with a publicly trusted certificate. Without one, open a port and use ws://.

Either way, give it a secret path as README.md says: a random RELAY_SECRET (openssl rand -hex 16), so strangers who find the host can't use it. Don't put the secret in a DNS name.

If I'm in mainland China, prefer a server there: the round trip is far shorter. A domain served from a mainland server needs an ICP filing.

Don't change anything else on the server or the domain, and ask before opening a port or spending money. Keep credentials out of anything you print.

When it's up, run `node test.mjs <address>` from that folder and check it passes. Then tell me the one address with its secret, like wss://relay.example.com/<secret>, and that it goes in Blurt → Settings → Phone → Relay Address. Reply in the language I'm writing in.";

// ------------------------------------------------------------------ what the host asks of the app

struct Desktop {
    app: AppHandle,
}

impl App for Desktop {
    fn status(&self, s: &Status) {
        if s.listening {
            firewall_watch(); // Windows: is the firewall letting phones in?
        }
        let _ = self.app.emit("remote://status", to_ui(s));
    }

    /// A new phone waits for a yes: the main window comes forward (the app-wide dialog shows the digits), and a notification
    /// says so in case the window can't take the focus.
    fn asking(&self, device: &str, digits: &str) {
        let app = self.app.clone();
        let _ = self.app.run_on_main_thread(move || crate::show_main(&app));
        use tauri_plugin_notification::NotificationExt;
        let (title, body) = if zh() {
            (format!("{device} 想连接这台电脑"), format!("在口喷鸡中确认手机上显示的是 {digits}，再允许。"))
        } else {
            (format!("{device} wants to connect"), format!("In Blurt, check the phone shows {digits}, then allow it."))
        };
        let _ = self.app.notification().builder().title(title).body(body).show();
    }

    fn dictation_key(&self, down: bool, phone_mic: bool) {
        #[cfg(dict)]
        crate::dictation::engine::remote_key(down, phone_mic);
        let _ = (down, phone_mic);
    }

    fn blurt(&self, c: BlurtCommand, phone_mic: bool) {
        let action = match c {
            BlurtCommand::Snap => "snap",
            BlurtCommand::Record => "record",
            BlurtCommand::CopyText => "text",
            BlurtCommand::Translate => "translate",
            BlurtCommand::Cards => "cards",
            BlurtCommand::VoiceNote => return voice_note(&self.app, phone_mic),
            #[cfg(dict)]
            BlurtCommand::DictationCancel => return crate::dictation::engine::remote_command(crate::dictation::engine::Remote::Cancel),
            #[cfg(dict)]
            BlurtCommand::DictationStructured => return crate::dictation::engine::remote_command(crate::dictation::engine::Remote::Structured),
            #[cfg(dict)]
            BlurtCommand::DictationTranslate => return crate::dictation::engine::remote_command(crate::dictation::engine::Remote::Translate),
            #[cfg(dict)]
            BlurtCommand::DictationSend => return crate::dictation::engine::remote_command(crate::dictation::engine::Remote::Send),
            #[cfg(not(dict))]
            _ => return,
        };
        let app = self.app.clone();
        let _ = self.app.run_on_main_thread(move || crate::dispatch(&app, action));
    }

    /// The phone can't have its microphone after all (a call has it): a note waiting on it is heard through this computer's.
    fn phone_mic(&self, on: bool) {
        if !on {
            note_falls_back();
        }
    }

    fn session(&self, name: Option<&str>) {
        *PHONE.lock().unwrap() = name.map(str::to_string);
        if name.is_none() {
            // a take listening through the phone ends with it
            #[cfg(dict)]
            crate::dictation::engine::remote_command(crate::dictation::engine::Remote::Gone);
        } else {
            watch_front();
        }
    }

    fn front(&self) -> Option<Front> {
        front_now()
    }

    fn dictation_phase(&self) -> DictationPhase {
        phase_now()
    }

    fn log(&self, e: &Value) {
        // what the Mac emits as events; never keys or text (the host doesn't log those)
        if e["event"] != "remote_screen_host" && e["event"] != "remote_screen_phone" {
            eprintln!("blurt remote: {e}");
        }
    }
}

/// The phone connected now (its name), for the mic's name.
static PHONE: Mutex<Option<String>> = Mutex::new(None);

fn front_now() -> Option<Front> {
    #[cfg(dict)]
    {
        let f = crate::dictation::insert::front()?;
        let name = crate::dictation::insert::app_name(&f).unwrap_or_else(|| f.exe.trim_end_matches(".exe").to_string());
        Some(Front { bundle: f.exe, name })
    }
    #[cfg(not(dict))]
    None
}

/// The app in front, told to the phone when it changes (its keys follow it: "Tabs" in a terminal). Polled once a second while a
/// phone is connected; nothing runs otherwise.
fn watch_front() {
    static RUNNING: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
    if RUNNING.swap(true, std::sync::atomic::Ordering::SeqCst) {
        return;
    }
    std::thread::spawn(|| {
        let mut last: Option<Front> = None;
        while PHONE.lock().unwrap().is_some() {
            let f = front_now();
            if f.is_some() && f != last {
                if let (Some(h), Some(f)) = (host(), f.clone()) {
                    h.front(f);
                }
                last = f;
            }
            std::thread::sleep(std::time::Duration::from_secs(1));
        }
        RUNNING.store(false, std::sync::atomic::Ordering::SeqCst);
    });
}

// ------------------------------------------------------------------ dictation, both ways

fn phase_now() -> DictationPhase {
    #[cfg(dict)]
    {
        if !crate::dictation::engine::enabled() {
            return DictationPhase::Unavailable;
        }
        let v = crate::dictation::engine::island_state();
        v["phase"].as_str().and_then(DictationPhase::from_name).unwrap_or(DictationPhase::Idle)
    }
    #[cfg(not(dict))]
    DictationPhase::Unavailable
}

/// Dictation's state changed (island.rs `refresh`): the phone hears a new phase once.
pub fn dictation_changed() {
    static LAST: Mutex<Option<DictationPhase>> = Mutex::new(None);
    let Some(h) = host() else { return };
    if h.connected().is_none() {
        *LAST.lock().unwrap() = None;
        return;
    }
    let p = phase_now();
    let mut l = LAST.lock().unwrap();
    if *l != Some(p) {
        *l = Some(p);
        h.dictation(p);
    }
}

/// The mic's level while a take listens, 0…1 (engine.rs, at the island's pace).
pub fn level(l: f32) {
    if let Some(h) = host() {
        h.level(l);
    }
}

/// The words so far (engine.rs; this computer's recognisers give finished pieces, nothing pending).
pub fn live(committed: &str) {
    if let Some(h) = host() {
        h.live(committed, "");
    }
}

/// What a take typed, once it landed.
pub fn typed(text: &str) {
    if let Some(h) = host() {
        h.typed(text);
    }
}

/// The phone's microphone for a take, in this computer's mic's place: (its name, the guard that detaches it when dropped).
/// None: no phone connected. `note`: only for a voice note the phone asked for (`voice_note`).
pub fn phone_mic(tx: Sender<Vec<f32>>, note: bool) -> Option<(String, Sender<()>)> {
    let h = host()?;
    let name = PHONE.lock().unwrap().clone()?;
    if note {
        let mut n = NOTE.lock().unwrap();
        if !n.wants {
            return None;
        }
        n.wants = false;
        n.feed = Some(tx.clone());
    }
    let feed = h.mic();
    feed.attach(tx);
    let (stop, until) = std::sync::mpsc::channel::<()>();
    std::thread::spawn(move || {
        let _ = until.recv(); // the Mic went: the take is over
        feed.detach();
        if note {
            let mut n = NOTE.lock().unwrap();
            n.feed = None;
            n.fallback = None; // this computer's mic, if the phone couldn't
            drop(n);
            if let Some(h) = host() {
                h.listen(false);
            }
        }
    });
    Some((name, stop))
}

#[derive(Default)]
struct Note {
    /// the next voice note listens through the phone
    wants: bool,
    /// the note listening through it now
    feed: Option<Sender<Vec<f32>>>,
    /// …heard through this computer's mic instead (the phone couldn't): dropped, it stops
    fallback: Option<Sender<()>>,
}

static NOTE: Mutex<Note> = Mutex::new(Note { wants: false, feed: None, fallback: None });

/// Voice Note from the phone: start, or stop the one going. A note started from a phone that uses its own microphone is heard
/// through it, as dictation is (ToPhone.listen); if it doesn't start after all, the phone lets its microphone go.
fn voice_note(app: &AppHandle, phone_mic: bool) {
    #[cfg(dict)]
    {
        let note_on = crate::dictation::voice::active();
        let listening = phase_now() == DictationPhase::Listening;
        let asked = !note_on && !listening && phone_mic && host().is_some();
        if asked {
            if let Some(h) = host() {
                h.mic().clear();
                NOTE.lock().unwrap().wants = true;
                h.listen(true);
            }
        }
        let a = app.clone();
        let _ = app.run_on_main_thread(move || {
            if crate::dictation::voice::active() {
                crate::capture::voice_stop(&a, false);
            } else {
                crate::capture::voice_start(&a, false);
            }
        });
        if asked {
            std::thread::spawn(|| {
                std::thread::sleep(std::time::Duration::from_secs(2));
                let mut n = NOTE.lock().unwrap();
                if n.wants {
                    n.wants = false; // never took the phone's microphone
                    drop(n);
                    if let Some(h) = host() {
                        h.listen(false);
                    }
                }
            });
        }
    }
    #[cfg(not(dict))]
    {
        let _ = phone_mic;
        let a = app.clone();
        let _ = app.run_on_main_thread(move || crate::dispatch(&a, "voice"));
    }
}

/// The phone said it can't have its microphone: the note waiting on it is heard through this computer's, quietly. The next
/// note tries the phone again.
fn note_falls_back() {
    let mut n = NOTE.lock().unwrap();
    n.wants = false;
    #[cfg(dict)]
    if let (Some(tx), None) = (n.feed.clone(), n.fallback.as_ref()) {
        let (stop, until) = std::sync::mpsc::channel::<()>();
        n.fallback = Some(stop);
        std::thread::spawn(move || {
            // a mic stream stays on the thread that opened it
            match crate::dictation::mic::Mic::open(tx) {
                Ok(_m) => {
                    let _ = until.recv();
                }
                Err(e) => eprintln!("blurt remote: this computer's mic for the note: {e}"),
            }
        });
    }
}

// ------------------------------------------------------------------ keys in the OS's store

/// Each paired phone's key (32 bytes, base64) under its device id: Windows Credential Manager (target "Blurt Phone/<id>"), the
/// Secret Service on Linux (application = blurt, service = <id>).
struct OsKeys;

impl KeyStore for OsKeys {
    fn get(&self, id: &str) -> Option<Vec<u8>> {
        os_get(id).and_then(|s| blurt_remote::wire::unb64(&s))
    }
    fn put(&self, id: &str, key: &[u8]) -> Result<(), String> {
        os_put(id, &blurt_remote::wire::b64(key))
    }
    fn delete(&self, id: &str) {
        os_delete(id)
    }
}

#[cfg(windows)]
fn target(id: &str) -> Vec<u16> {
    format!("Blurt Phone/{id}").encode_utf16().chain(std::iter::once(0)).collect()
}

#[cfg(windows)]
fn os_get(id: &str) -> Option<String> {
    use windows::Win32::Security::Credentials::{CredFree, CredReadW, CREDENTIALW, CRED_TYPE_GENERIC};
    let t = target(id);
    unsafe {
        let mut p: *mut CREDENTIALW = std::ptr::null_mut();
        CredReadW(windows::core::PCWSTR(t.as_ptr()), CRED_TYPE_GENERIC, None, &mut p).ok()?;
        let c = &*p;
        let bytes = std::slice::from_raw_parts(c.CredentialBlob, c.CredentialBlobSize as usize).to_vec();
        CredFree(p as *const _);
        String::from_utf8(bytes).ok().filter(|k| !k.is_empty())
    }
}

#[cfg(windows)]
fn os_put(id: &str, k: &str) -> Result<(), String> {
    use windows::Win32::Security::Credentials::{CredWriteW, CREDENTIALW, CRED_FLAGS, CRED_PERSIST_LOCAL_MACHINE, CRED_TYPE_GENERIC};
    let mut t = target(id);
    let mut user: Vec<u16> = "Blurt".encode_utf16().chain(std::iter::once(0)).collect();
    let mut blob = k.as_bytes().to_vec();
    let c = CREDENTIALW {
        Flags: CRED_FLAGS(0),
        Type: CRED_TYPE_GENERIC,
        TargetName: windows::core::PWSTR(t.as_mut_ptr()),
        CredentialBlobSize: blob.len() as u32,
        CredentialBlob: blob.as_mut_ptr(),
        Persist: CRED_PERSIST_LOCAL_MACHINE,
        UserName: windows::core::PWSTR(user.as_mut_ptr()),
        ..Default::default()
    };
    unsafe { CredWriteW(&c, 0) }.map_err(|e| e.to_string())
}

#[cfg(windows)]
fn os_delete(id: &str) {
    use windows::Win32::Security::Credentials::{CredDeleteW, CRED_TYPE_GENERIC};
    let t = target(id);
    unsafe {
        let _ = CredDeleteW(windows::core::PCWSTR(t.as_ptr()), CRED_TYPE_GENERIC, None);
    }
}

#[cfg(target_os = "linux")]
fn os_get(id: &str) -> Option<String> {
    crate::dictation::secret_linux::key(id)
}

#[cfg(target_os = "linux")]
fn os_put(id: &str, k: &str) -> Result<(), String> {
    crate::dictation::secret_linux::store_key(id, k)
}

#[cfg(target_os = "linux")]
fn os_delete(id: &str) {
    crate::dictation::secret_linux::delete_key(id)
}

#[cfg(not(any(windows, target_os = "linux")))]
fn os_get(_: &str) -> Option<String> {
    None
}

#[cfg(not(any(windows, target_os = "linux")))]
fn os_put(_: &str, _: &str) -> Result<(), String> {
    Err("no key store here".into())
}

#[cfg(not(any(windows, target_os = "linux")))]
fn os_delete(_: &str) {}

#[cfg(test)]
mod tests {
    #[test]
    fn the_status_is_the_contracts_shape() {
        let s = blurt_remote::server::Status {
            listening: true,
            pairing: Some(blurt_remote::server::PairingStatus { url: "blurtremote://pair?v=1".into(), expires_at: 1_700_000_000_000 }),
            ..Default::default()
        };
        let v = serde_json::to_value(super::to_ui(&s)).unwrap();
        for k in ["listening", "pairing", "asking", "devices", "connected", "relay", "screenAllowed", "canControl", "problem", "firewall"] {
            assert!(v.get(k).is_some(), "{k}");
        }
        let svg = v["pairing"]["qrSvg"].as_str().unwrap();
        assert!(svg.starts_with("<svg") && svg.trim_end().ends_with("</svg>"), "{svg:.80}");
        assert_eq!(v["pairing"]["expiresAt"], 1_700_000_000_000i64);
        assert_eq!(v["firewall"], if cfg!(windows) { "unknown" } else { "ok" });
        for k in ["address", "fromPhone", "reachable"] {
            assert!(v["relay"].get(k).is_some(), "relay.{k}");
        }
    }
}
