//! Blurt on the phone, host side (RemoteServer.swift; docs/design/remote.md): listens for paired phones and turns what they send
//! into pointer moves, keys, dictation and Blurt's commands.
//!
//!  • listens only once a phone is paired or a code is showing. No paired phone, no open port, no DNS-SD advert.
//!  • pairing: a code (QR) with a fresh key, good for one phone and two minutes, renewed while it shows. Every new phone needs a
//!    yes here, on any network, comparing six digits both ends show (commit-then-reveal: nobody in the middle picks them). The
//!    session that spent the code is sent a new key and becomes a device once the phone says it kept it.
//!  • a session opens only with the key its id has now (constant time): a handshake begun with a code that was spent, renewed or
//!    replaced since opens nothing.
//!  • DNS-SD `_blurt-remote._tcp`, TXT id = this host's id; the TCP port stays the same across launches.
//!  • one phone drives at a time: a new session replaces the old one (`replaced`).
//!  • nothing but the handshake before a session has greeted; a hello frame is at most 1 KB, 16 handshakes at once, 6 s each.
//!  • quiet for 2 s with anything held: let go of everything (the phone left the Wi-Fi, locked, or crashed). 12 s: the session is over.
//!  • the owner's relay: one waiting WebSocket per paired phone (and per showing code); a direct path from inside the session.
//!  • no relay of the owner's and the switch on: Blurt's go-between (docs/design/remote-go-between.md) in its place, only for
//!    meeting: the session moves its stream onto the direct path (channel.rs `move_out`), or ends with `noDirect` after 8 s.

use std::collections::HashMap;
use std::net::{IpAddr, Ipv6Addr, SocketAddr};
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering::SeqCst};
use std::sync::{Arc, Mutex, Weak};
use std::time::{Duration, Instant};

use futures_util::{SinkExt, StreamExt};
use serde_json::{json, Value};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream, UdpSocket};
use tokio::sync::mpsc;
use tokio_tungstenite::tungstenite::Message;

use crate::channel::{Chan, Out};
use crate::crypto::{self, same};
use crate::host::{Backend, DisplayInfo};
use crate::input::{self, Cmd, Shared, Told};
use crate::mic::MicFeed;
use crate::packets::{FrameReader, Kind, PointerPacket, MAX_FRAME};
use crate::pairing::{Pairing, SERVICE_TYPE};
use crate::relay;
use crate::screen::{ScreenSession, NO_SCREEN};
use crate::store::{now_ms, Connection, Device, DeviceKind, Files, KeyStore};
use crate::wire::{BlurtCommand, Candidate, DictationPhase, Front, SessionInfo, ToMac, ToPhone};

const SILENCE: f64 = 2.0;
const GONE: f64 = 12.0;
const PAIRING_LIFE: f64 = 120.0;
const PAIRING_GRACE: f64 = 20.0;
/// A copied link: pasted on another computer, often on another network, which takes longer than a scan. It lasts this long
/// whatever the code on screen does; spent like any code, and still nothing opens without the six digits and a yes here.
const COPIED_LIFE: f64 = 600.0;
const MAX_HANDSHAKES: usize = 16;
const HANDSHAKE_TIME: Duration = Duration::from_secs(6);
const CODE_TRIES: u32 = 8;
const MAX_STEPS: usize = 32;
const MAX_WAIT_MS: i64 = 3000;
const MAX_TEXT: usize = 64 * 1024;
/// on the go-between: no datagram from the phone this long after `session`, and the host says `noDirect` and closes
const NO_DIRECT: Duration = Duration::from_secs(8);

/// a viewer's keys captured: the host looks at its clipboard this often and sends a change (docs/design/remote-desktop-viewer.md)
const CLIPBOARD_EVERY: Duration = Duration::from_millis(500);
/// a nearby computer the owner said no to (or didn't answer): no nearby question for this long
const NEARBY_PAUSE: Duration = Duration::from_secs(30);
/// What the desktop app does for the host. Called on a thread of the host's own, one at a time, never under its locks: a hook may
/// call back into `Host`.
pub trait App: Send + Sync + 'static {
    /// The status changed (Settings, the tray).
    fn status(&self, _s: &Status) {}
    /// A file from `from` was saved to the Downloads folder as `name`: tell the person here.
    fn file_received(&self, _from: &str, _name: &str) {}
    /// The sentence a paired device hears when others were paired here since it was last in, or when one is let in while it's
    /// connected (anti-scam, remote-1.1.md §3), in the app's language. `devices`: their names, joined; `host`: this computer's name.
    fn new_pairing_notice(&self, devices: &str, host: &str) -> String {
        format!("New device paired with {host}: {devices}. If that wasn't you or your family, remove it on that computer.")
    }
    /// A new phone waits for a yes: the owner should see the six digits now (raise the window, a notification).
    fn asking(&self, _device: &str, _digits: &str) {}
    /// The phone's talk key: the dictation key's down / up. `phone_mic`: the take should listen through the phone (`Host::mic`).
    fn dictation_key(&self, _down: bool, _phone_mic: bool) {}
    /// Blurt's commands, as its hotkeys do them. `phone_mic`: a voice note may listen through the phone (`Host::listen`).
    fn blurt(&self, _c: BlurtCommand, _phone_mic: bool) {}
    /// The phone can't have its microphone after all (a call): what waits on it should use this computer's.
    fn phone_mic(&self, _on: bool) {}
    /// A phone connected (its name) or left (None): a take listening through it ends, its microphone goes.
    fn session(&self, _name: Option<&str>) {}
    /// A word for the owner's screen, where they're looking (a key pressed from the phone, the page turned to).
    fn hud(&self, _text: &str) {}
    /// The app in front now (ToPhone.front: the exe name on Windows, the desktop file id on Linux).
    fn front(&self) -> Option<Front> {
        None
    }
    /// Dictation's phase now (ToPhone.dictation).
    fn dictation_phase(&self) -> DictationPhase {
        DictationPhase::Unavailable
    }
    /// One event for the log (JSON, never a key or what was typed).
    fn log(&self, _event: &Value) {}
}

pub struct HostConfig {
    /// where devices.json and host.json go ($BLURT_HOME/remote)
    pub dir: std::path::PathBuf,
    /// the computer's name, as the phone shows it
    pub name: String,
    /// the app's version (ToPhone.session)
    pub version: String,
    /// tests only: answer every pairing question by itself, 3 s after it's asked
    pub test_answer: Option<bool>,
    /// tests: a fixed TCP port (0 = the saved one, or any)
    pub port: u16,
    /// Blurt's go-between: None = the built-in one (`relay::GO_BETWEEN`); Some("") = none (a test that mustn't reach out);
    /// Some(address) = another (tests: a local `BUDGET=1 node tools/remote-relay/server.js`)
    pub go_between: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Default)]
pub struct Status {
    pub listening: bool,
    pub port: u16,
    pub pairing: Option<PairingStatus>,
    pub asking: Option<Asking>,
    pub devices: Vec<Device>,
    pub connected: Option<Connected>,
    pub relay: RelayStatus,
    pub screen_allowed: bool,
    /// 保持可连接 (the setting), and whether this machine runs on a battery (Settings says "while plugged in")
    pub stay_awake: bool,
    pub battery: bool,
    pub can_control: bool,
    pub problem: Option<Problem>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct PairingStatus {
    pub url: String,
    /// unix ms
    pub expires_at: i64,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Asking {
    pub device: String,
    pub digits: String,
    pub via_relay: bool,
    /// a phone or a computer (its hello, which comes before the question)
    pub kind: DeviceKind,
    /// which session it's about: a yes given to one can't go to another
    pub number: u32,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Connected {
    pub id: String,
    pub name: String,
    /// "local" (the same network), "tailscale" or "overlay" (an overlay network's address: away, no server), "direct" (UDP,
    /// found through a relay or the go-between), "relay" (the owner's relay carries it), "goBetween" (Blurt's go-between, until
    /// the stream moves to the direct path)
    pub route: &'static str,
    pub screen: bool,
}

#[derive(Clone, Debug, PartialEq, Default)]
pub struct RelayStatus {
    pub address: Option<String>,
    pub from_phone: bool,
    /// None: not tried yet (or no address)
    pub reachable: Option<bool>,
    /// the go-between switch (docs/design/remote-go-between.md): used only while `address` is None
    pub go_between: bool,
    /// why the go-between couldn't carry the last session it tried, until one works (None: fine, or not tried)
    pub go_between_problem: Option<GoBetweenProblem>,
    /// the owner's relay is down and the go-between is used meanwhile (2026-11-20: a dead relay left nothing to come in through)
    pub fallback: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum GoBetweenProblem {
    /// the direct path didn't open on that network (`noDirect`, or the go-between's 4003 budget close)
    NoDirect,
    /// the go-between refused: its free quota for the day is gone, or it is rate-limiting
    Busy,
}

#[derive(Clone, Debug, PartialEq)]
pub enum Problem {
    /// the TCP port couldn't be opened (the error)
    Listen(String),
}

type Job = Box<dyn FnOnce(&dyn App) + Send>;

/// The host the app starts: everything runs on its own runtime and threads.
#[derive(Clone)]
pub struct Host {
    core: Arc<Core>,
}

#[derive(Clone)]
struct Code {
    id: String,
    key: [u8; 32],
    until: Instant,
    /// unix ms, for Settings
    expires: i64,
}

struct Sess {
    chan: Arc<Chan>,
    /// files it sends (made at the first one)
    incoming: Option<crate::incoming::Receiver>,
    /// its line in the connection log, once greeted (the session's sid)
    logged: bool,
    id: Option<String>,
    name: String,
    mic_on_phone: bool,
    key_down: bool,
    udp_seen: bool,
    /// the code this session spent: the new key waits here for keyStored
    pairing_key: Option<[u8; 32]>,
    key_sent: bool,
    /// a new phone the owner said yes to here, this session: it may also set the relay and drop the entry it replaces
    approved: bool,
    /// the device it took the session from heard of it then (`take_over`), and isn't told again when it next comes in
    told_to: Option<String>,
    /// the phone listed `move` (its stream can move onto the direct path): only such a phone is offered the go-between
    moves: bool,
    /// a computer driving this one (hello.features has `viewer`): its clipboard and keysCaptured count
    viewer: bool,
    /// a viewer's keys are captured: the clipboard goes both ways
    captured: bool,
    /// which capture the clipboard watch belongs to
    clip_gen: u64,
    /// the clipboard text both ends have now (sent, or received and put on): a change from it is sent
    clip_known: Option<String>,
    /// a new computer that found this one nearby, asking without a code (`pairing::nearby_key`)
    nearby: bool,
    /// the same device as the session open now: it takes over once its hello says it isn't a viewer's other window
    deferred: bool,
    nonce: Option<Vec<u8>>,
    transcript: [u8; 32],
    commitment: Option<Vec<u8>>,
    held_released: bool,
    punches: u32,
    screen: Option<Arc<ScreenSession>>,
    /// a screen request under way (its start may take a while): only the latest counts
    screen_gen: u64,
    /// the display the phone pinned (showDisplay), for the next stream too; None: follow the pointer
    pinned: Option<String>,
    /// ToPhone.session has gone: the displays only after it, as from the Mac (a relayed session's waits on STUN, while the watch
    /// looks at the displays every 2 s)
    told: bool,
}

struct RelayConn {
    sid: u64,
    stop: Arc<tokio::sync::Notify>,
}

struct Listeners {
    port: u16,
    udp_port: u16,
    stop: Arc<tokio::sync::Notify>,
    mdns: Option<(mdns_sd::ServiceDaemon, String)>,
}

struct State {
    settings: crate::store::Settings,
    devices: Vec<Device>,
    listeners: Option<Listeners>,
    showing_pairing: bool,
    pairing: Option<Code>,
    old_code: Option<Code>,
    /// the code whose link was copied (COPIED_LIFE)
    copied: Option<Code>,
    pairing_gen: u64,
    code_tries: HashMap<String, u32>,
    sessions: HashMap<u64, Sess>,
    current: Option<u64>,
    asking: Option<u64>,
    relays: HashMap<String, RelayConn>,
    /// the go-between's waiting connections while the owner's relay is down, one per paired device
    fallbacks: HashMap<String, RelayConn>,
    /// the owner's relay failed this many times in a row without connecting
    own_relay_fails: u32,
    relay_wait: HashMap<String, f64>,
    relay_at: Option<String>,
    spent_code: Option<String>,
    relay_reachable: Option<bool>,
    status: Status,
    last_control: bool,
    watch_gen: u64,
    awake: bool,
    /// 保持可连接 as last handed to the backend
    standby_awake: bool,
    /// the displays the phone was last told of
    displays_sent: Option<Vec<DisplayInfo>>,
    /// the lock the viewer was last told of (`Backend::locked`)
    locked_sent: Option<bool>,
    problem: Option<Problem>,
    /// the app's Phone capability is off (`Host::set_off`): nothing listens, no relay is held, no code shows
    off: bool,
    /// why the go-between couldn't carry the last session it tried (Settings says so until one works)
    meet_problem: Option<crate::server::GoBetweenProblem>,
    /// refusals from the go-between in a row ("busy today"): the next try waits 30 s, 2 min, 10 min, then an hour
    meet_refusals: u32,
    /// no nearby question until then (the owner said no to the last one)
    nearby_paused_until: Option<Instant>,
}

struct Core {
    rt: tokio::runtime::Runtime,
    st: Mutex<State>,
    files: Files,
    keys: Box<dyn KeyStore>,
    backend: Shared,
    input: std::sync::mpsc::Sender<Cmd>,
    /// how far the host has got with the phone's numbered pointer instructions: the input thread writes, the screen's ticker reads
    told: Arc<Told>,
    app: std::sync::mpsc::Sender<Job>,
    mic: Arc<MicFeed>,
    cfg: HostConfig,
    udp: Mutex<Option<Arc<UdpSocket>>>,
    /// where files from viewers go (the app sets it: `Host::set_downloads`); None: files aren't taken
    downloads: Mutex<Option<std::path::PathBuf>>,
    /// the last snapshot handed to the system service (`sync_standby`)
    standby_sent: Mutex<String>,
    handshaking: AtomicUsize,
    next_sid: AtomicU64,
    /// STUN asks waiting for their answer: txn → reply
    stun: Mutex<Vec<([u8; 12], tokio::sync::oneshot::Sender<Candidate>)>>,
    platform: &'static str,
    /// the backend's displays, polled every 2 s while a phone is connected; the screen session reads them
    displays: Arc<Mutex<Vec<DisplayInfo>>>,
    me: Mutex<Weak<Core>>,
}

impl Host {
    /// Starts the host. Nothing listens until a code shows or a phone is paired.
    pub fn start(cfg: HostConfig, backend: Box<dyn Backend>, keys: Box<dyn KeyStore>, app: Box<dyn App>) -> Host {
        let rt = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .thread_name("blurt-remote")
            .enable_all()
            .build()
            .expect("the remote host's runtime");
        let platform = backend.platform();
        let backend: Shared = Arc::new(Mutex::new(backend));
        let told = Arc::new(Told::default());
        let input = input::spawn(backend.clone(), told.clone());
        let (atx, arx) = std::sync::mpsc::channel::<Job>();
        std::thread::Builder::new()
            .name("blurt-remote-app".into())
            .spawn(move || {
                while let Ok(job) = arx.recv() {
                    job(app.as_ref());
                }
            })
            .expect("a thread");
        let files = Files::new(&cfg.dir);
        let settings = files.settings();
        let devices = files.devices();
        let st = State {
            settings,
            devices,
            listeners: None,
            showing_pairing: false,
            pairing: None,
            old_code: None,
            copied: None,
            pairing_gen: 0,
            code_tries: HashMap::new(),
            sessions: HashMap::new(),
            current: None,
            asking: None,
            relays: HashMap::new(),
            fallbacks: HashMap::new(),
            own_relay_fails: 0,
            relay_wait: HashMap::new(),
            relay_at: None,
            spent_code: None,
            relay_reachable: None,
            status: Status::default(),
            last_control: true,
            watch_gen: 0,
            awake: false,
            standby_awake: false,
            displays_sent: None,
            locked_sent: None,
            problem: None,
            off: false,
            meet_problem: None,
            meet_refusals: 0,
            nearby_paused_until: None,
        };
        let core = Arc::new(Core {
            rt,
            st: Mutex::new(st),
            files,
            keys,
            backend,
            input,
            told,
            app: atx,
            mic: Arc::new(MicFeed::new()),
            cfg,
            udp: Mutex::new(None),
            downloads: Mutex::new(None),
            standby_sent: Mutex::new(String::new()),
            handshaking: AtomicUsize::new(0),
            next_sid: AtomicU64::new(1),
            stun: Mutex::new(vec![]),
            platform,
            displays: Arc::new(Mutex::new(Vec::new())),
            me: Mutex::new(Weak::new()),
        });
        *core.me.lock().unwrap() = Arc::downgrade(&core);
        {
            let mut s = core.st.lock().unwrap();
            core.update_listening(&mut s);
            core.publish(&mut s);
        }
        Host { core }
    }

    pub fn status(&self) -> Status {
        self.core.st.lock().unwrap().status.clone()
    }

    /// Settings shows the code (on), or stopped showing it.
    pub fn show_pairing(&self, on: bool) {
        let c = &self.core;
        let mut s = c.st.lock().unwrap();
        s.showing_pairing = on;
        if on {
            c.update_listening(&mut s);
            if s.listeners.is_some() {
                c.renew_pairing(&mut s);
            }
        } else {
            s.pairing_gen += 1;
            s.pairing = None;
            s.old_code = None;
            c.update_listening(&mut s);
        }
        c.publish(&mut s);
    }

    /// Settings' Copy Link: the code on screen now stays good for COPIED_LIFE, though the screen moves on to new ones.
    pub fn pairing_link_copied(&self) {
        let c = &self.core;
        let mut s = c.st.lock().unwrap();
        let Some(mut code) = s.pairing.clone() else { return };
        code.until = Instant::now() + Duration::from_secs_f64(COPIED_LIFE);
        code.expires = now_ms() + (COPIED_LIFE * 1000.0) as i64;
        let id = code.id.clone();
        s.copied = Some(code);
        c.update_listening(&mut s);
        let me = c.arc();
        c.rt.spawn(async move {
            tokio::time::sleep(Duration::from_secs_f64(COPIED_LIFE + 1.0)).await;
            let mut s = me.st.lock().unwrap();
            if s.copied.as_ref().is_some_and(|c| c.id == id) {
                s.copied = None;
                me.update_listening(&mut s);
                me.publish(&mut s);
            }
        });
    }

    /// Yes or no to the phone that waits. `digits`: the six digits the owner saw: the answer counts only for the session they
    /// belong to, so a late click can't answer a different phone (None: whichever asks now).
    pub fn answer_pairing(&self, yes: bool, digits: Option<&str>) {
        let c = &self.core;
        let mut s = c.st.lock().unwrap();
        let number = match digits {
            Some(d) => match s.status.asking.as_ref().filter(|a| a.digits == d) {
                Some(a) => Some(a.number),
                None => return,
            },
            None => None,
        };
        c.answer(&mut s, yes, number);
        c.publish(&mut s);
    }

    /// Where files from viewers go (the Downloads folder): set, the host takes them and its sessions say so.
    pub fn set_downloads(&self, dir: Option<std::path::PathBuf>) {
        *self.core.downloads.lock().unwrap() = dir;
    }

    /// 连接记录: sessions and pairings on this computer, oldest first.
    pub fn connections(&self) -> Vec<Connection> {
        self.core.files.connections()
    }

    pub fn remove_device(&self, id: &str) {
        self.core.remove(id);
    }

    /// The owner's own name for a paired device (remote-1.1.md §6): this computer's lists, its question and its "being controlled"
    /// bar show it; nothing is sent, the id stays. Empty (or the device's own name) goes back to its own name.
    pub fn rename_device(&self, id: &str, name: &str) {
        let c = &self.core;
        let mut s = c.st.lock().unwrap();
        let Some(d) = s.devices.iter_mut().find(|d| d.id == id) else { return };
        let alias = crate::store::alias(name, &d.name);
        if d.alias == alias {
            return;
        }
        d.alias = alias;
        c.files.save_devices(&s.devices);
        // the mic's name and the bar follow at once when it's the one connected
        if let Some(n) = s.current.and_then(|sid| s.sessions.get(&sid)).filter(|x| x.chan.greeted.load(SeqCst) && x.id.as_deref() == Some(id)).map(|x| shown(&s, x)) {
            c.post(move |a| a.session(Some(&n)));
        }
        c.publish(&mut s);
    }

    /// The person at this computer ended the session (the "being controlled" bar): the device hears `ended` first, so it waits for
    /// its user instead of connecting again at once. It stays paired.
    pub fn end_session(&self) {
        let c = &self.core;
        let s = c.st.lock().unwrap();
        let Some(cur) = s.current else { return };
        let Some(ch) = s.sessions.get(&cur).map(|x| x.chan.clone()) else { return };
        drop(s);
        c.log(json!({"event": "remote_session", "state": "ended_here"}));
        ch.send(&ToPhone::Ended);
        let me = c.arc();
        c.rt.spawn(async move {
            tokio::time::sleep(Duration::from_millis(300)).await;
            ch.close();
            let mut s = me.st.lock().unwrap();
            if s.current == Some(cur) {
                me.closed_session(&mut s, cur);
            }
            me.publish(&mut s);
        });
    }

    /// The owner's relay address (None or empty: cleared). Err: it can't be one.
    pub fn set_relay(&self, typed: Option<&str>) -> Result<(), String> {
        let a = match typed.map(str::trim).filter(|t| !t.is_empty()) {
            Some(t) => Some(relay::address(t).ok_or_else(|| "not a relay address".to_string())?),
            None => None,
        };
        let c = &self.core;
        let mut s = c.st.lock().unwrap();
        s.settings.relay = Some(a);
        s.settings.relay_from_phone = false;
        s.relay_reachable = None;
        c.files.save_settings(&s.settings);
        c.relay_changed(&mut s);
        c.publish(&mut s);
        Ok(())
    }

    /// Does anything answer as a relay at this address? (Blocks up to 8 s.)
    pub fn check_relay(&self, typed: &str) -> bool {
        let Some(a) = relay::address(typed) else { return false };
        let (tx, rx) = std::sync::mpsc::channel();
        self.core.rt.spawn(async move {
            let _ = tx.send(relay::check(&a).await);
        });
        rx.recv().unwrap_or(false)
    }

    /// The go-between switch (Settings → Phone, on by default): Blurt's go-between for away from home while no relay of the
    /// owner's is set. Off: nothing connects out unless the owner sets a relay.
    pub fn set_go_between(&self, on: bool) {
        let c = &self.core;
        let mut s = c.st.lock().unwrap();
        if s.settings.go_between == on {
            return;
        }
        s.settings.go_between = on;
        s.meet_problem = None;
        c.files.save_settings(&s.settings);
        c.relay_changed(&mut s);
        c.publish(&mut s);
    }

    /// 保持可连接 (Settings → Remote Control, on by default).
    /// What a standby host needs to be this computer while no one is logged in (Windows, remote-1.1.md §2): its settings (its id
    /// among them, so devices know it), the paired devices and their keys. Handed to the system service, never to the network.
    pub fn standby_snapshot(&self) -> Value {
        let c = &self.core;
        let s = c.st.lock().unwrap();
        let keys: serde_json::Map<String, Value> = s
            .devices
            .iter()
            .filter_map(|d| c.keys.get(&format!("remote-{}", d.id)).map(|k| (d.id.clone(), json!(crate::wire::b64(&k)))))
            .collect();
        json!({"host": s.settings, "devices": s.devices, "keys": keys})
    }

    /// Keeps the system service's copy current (Windows): sent when it changed since last time, a no-op elsewhere.
    pub fn sync_standby(&self) {
        let snap = self.standby_snapshot().to_string();
        let mut last = self.core.standby_sent.lock().unwrap();
        if *last == snap {
            return;
        }
        self.core.backend.lock().unwrap().save_standby(&snap);
        *last = snap;
    }

    /// Another backend from now on (Windows: the system service was turned on or off, so the agent owns the screen and input, or
    /// no longer). The session in progress ends; the device connects again by itself.
    pub fn replace_backend(&self, backend: Box<dyn Backend>) {
        let c = &self.core;
        let mut s = c.st.lock().unwrap();
        if let Some(cur) = s.current {
            if let Some(x) = s.sessions.get(&cur) {
                x.chan.close();
            }
            c.closed_session(&mut s, cur);
        }
        *c.backend.lock().unwrap() = backend;
        c.log(json!({"event": "remote_backend", "state": "replaced"}));
    }

    pub fn set_stay_awake(&self, on: bool) {
        let c = &self.core;
        let mut s = c.st.lock().unwrap();
        if s.settings.stay_awake == on {
            return;
        }
        s.settings.stay_awake = on;
        c.files.save_settings(&s.settings);
        c.apply_awake(&mut s);
        c.publish(&mut s);
    }

    /// Plugged in or out (the app asks now and then): a laptop's answer changes with it.
    pub fn power_changed(&self) {
        let c = &self.core;
        let mut s = c.st.lock().unwrap();
        c.apply_awake(&mut s);
    }

    pub fn set_screen_allowed(&self, on: bool) {
        let c = &self.core;
        let mut s = c.st.lock().unwrap();
        s.settings.screen = on;
        c.files.save_settings(&s.settings);
        if !on {
            if let Some(sess) = s.current.and_then(|id| s.sessions.get_mut(&id)) {
                if let Some(sc) = sess.screen.take() {
                    sc.stop();
                    sess.chan.send(&ToPhone::ScreenFailed("off".into()));
                }
            }
            c.keep_awake(&mut s, true, false);
        }
        c.publish(&mut s);
    }

    /// The phone's microphone: attach a sender for the take (RemoteMicFeed).
    pub fn mic(&self) -> Arc<MicFeed> {
        self.core.mic.clone()
    }

    /// A voice note started from the phone wants its microphone (true), or is over (false).
    pub fn listen(&self, on: bool) {
        self.core.to_phone(&ToPhone::Listen(on));
    }

    pub fn front(&self, f: Front) {
        self.core.to_phone(&ToPhone::Front(f));
    }
    pub fn dictation(&self, p: DictationPhase) {
        self.core.to_phone(&ToPhone::Dictation(p));
    }
    pub fn live(&self, committed: &str, pending: &str) {
        self.core.to_phone(&ToPhone::Live { committed: committed.into(), pending: pending.into() });
    }
    pub fn level(&self, l: f32) {
        self.core.to_phone(&ToPhone::Level(l.clamp(0.0, 1.0)));
    }
    pub fn typed(&self, t: &str) {
        self.core.to_phone(&ToPhone::Typed(t.into()));
    }
    pub fn notice(&self, t: &str) {
        self.core.to_phone(&ToPhone::Notice(t.into()));
    }

    /// The phone that's connected now, if any (its name).
    pub fn connected(&self) -> Option<String> {
        self.status().connected.map(|c| c.name)
    }

    pub fn platform(&self) -> &'static str {
        self.core.platform
    }

    /// The app's Phone capability turned off (true) or back on: off, everything `stop` lets go of goes and stays gone
    /// — no port, no relay, no code — until it is on again; the paired phones are kept.
    pub fn set_off(&self, off: bool) {
        let c = &self.core;
        {
            let mut s = c.st.lock().unwrap();
            if s.off == off {
                return;
            }
            s.off = off;
            if !off {
                c.update_listening(&mut s);
                c.publish(&mut s);
                return;
            }
        }
        self.stop();
        let mut s = c.st.lock().unwrap();
        c.update_listening(&mut s); // the relay's address forgotten too: nothing reconnects while off
        c.publish(&mut s);
    }

    /// Lets go of everything, closes the session, stops listening (the app is quitting).
    pub fn stop(&self) {
        let c = &self.core;
        let mut s = c.st.lock().unwrap();
        if let Some(id) = s.current {
            if let Some(ch) = s.sessions.get(&id).map(|x| x.chan.clone()) {
                ch.close();
            }
            c.closed_session(&mut s, id);
        }
        s.showing_pairing = false;
        s.pairing = None;
        s.old_code = None;
        s.copied = None;
        let ids: Vec<String> = s.relays.keys().chain(s.fallbacks.keys()).cloned().collect();
        for id in ids {
            c.close_relay(&mut s, &id);
        }
        c.stop_listening(&mut s);
    }
}

impl Core {
    fn arc(&self) -> Arc<Core> {
        self.me.lock().unwrap().upgrade().expect("the host is alive")
    }

    fn post(&self, f: impl FnOnce(&dyn App) + Send + 'static) {
        let _ = self.app.send(Box::new(f));
    }

    fn log(&self, v: Value) {
        self.post(move |a| a.log(&v));
    }

    fn now(&self) -> f64 {
        self.backend.lock().unwrap().now()
    }

    fn to_phone(&self, m: &ToPhone) {
        let s = self.st.lock().unwrap();
        if let Some(sess) = s.current.and_then(|id| s.sessions.get(&id)) {
            if sess.chan.greeted.load(SeqCst) {
                sess.chan.send(m);
            }
        }
    }

    // ------------------------------------------------------------------ status

    fn publish(&self, s: &mut State) {
        let current = s.current.and_then(|id| s.sessions.get(&id));
        let st = Status {
            listening: s.listeners.is_some(),
            port: s.listeners.as_ref().map_or(0, |l| l.port),
            pairing: s.pairing.as_ref().and_then(|c| {
                let l = s.listeners.as_ref()?;
                Some(PairingStatus { url: self.pairing_url(s, c, l.port), expires_at: c.expires })
            }),
            asking: s.asking.and_then(|id| s.sessions.get(&id)).and_then(|a| {
                let digits = a.nonce.as_ref().and_then(|n| check_digits(a, n))?;
                Some(Asking { device: shown(s, a), digits, via_relay: a.chan.relay, kind: DeviceKind::of_hello(a.viewer), number: a.chan.number })
            }),
            devices: s.devices.clone(),
            connected: current.filter(|c| c.chan.greeted.load(SeqCst)).map(|c| Connected {
                id: c.id.clone().unwrap_or_default(),
                name: shown(s, c),
                route: route_of(&c.chan),
                screen: c.screen.is_some(),
            }),
            relay: RelayStatus {
                address: relay_address(&s.settings),
                from_phone: s.settings.relay_from_phone,
                reachable: relay_address(&s.settings).and(s.relay_reachable),
                go_between: s.settings.go_between,
                go_between_problem: s.meet_problem,
                fallback: self.own_relay_down(s) && s.settings.go_between,
            },
            screen_allowed: s.settings.screen,
            stay_awake: s.settings.stay_awake,
            battery: self.backend.lock().unwrap().has_battery(),
            can_control: s.last_control,
            problem: s.problem.clone(),
        };
        if st != s.status {
            s.status = st.clone();
            self.post(move |a| a.status(&st));
        }
    }

    fn pairing_url(&self, s: &State, c: &Code, port: u16) -> String {
        Pairing {
            host_id: s.settings.id.clone(),
            device_id: c.id.clone(),
            key: c.key.to_vec(),
            name: self.cfg.name.clone(),
            port,
            addresses: relay::local_addresses(),
            // the go-between too: a phone that can't move is told no relay in its session, and forgets it
            relay: self.away(s).map(|(a, _)| a),
        }
        .url()
    }

    /// Blurt's go-between, unless this host was told of another or none.
    fn meet_address(&self) -> Option<String> {
        match self.cfg.go_between.as_deref() {
            None => Some(relay::GO_BETWEEN.to_string()),
            Some("") => None,
            Some(a) => relay::address(a),
        }
    }

    fn is_meet(&self, address: &str) -> bool {
        let a = relay::address(address);
        a.is_some() && (a == self.meet_address() || a.as_deref() == Some(relay::GO_BETWEEN))
    }

    /// Where away from home goes now: the owner's relay; else the go-between while its switch is on. (address, the go-between)
    fn away(&self, s: &State) -> Option<(String, bool)> {
        if let Some(a) = relay_address(&s.settings) {
            return Some((a, false));
        }
        if s.settings.go_between {
            return self.meet_address().map(|a| (a, true));
        }
        None
    }

    /// The relay this phone is told of (`session.relay`, `relay`): the owner's, or the go-between to a phone that can move.
    fn offered(&self, s: &State, moves: bool) -> Option<String> {
        match self.away(s) {
            Some((a, false)) => Some(a),
            Some((a, true)) if moves => Some(a),
            _ => None,
        }
    }

    // ------------------------------------------------------------------ keys and devices

    fn code<'a>(&self, s: &'a State, id: &str) -> Option<&'a Code> {
        [s.pairing.as_ref(), s.old_code.as_ref(), s.copied.as_ref()].into_iter().flatten().find(|c| c.id == id && c.until > Instant::now())
    }

    fn key_for(&self, s: &State, id: &str) -> Option<Vec<u8>> {
        if let Some(c) = self.code(s, id) {
            return Some(c.key.to_vec());
        }
        if s.devices.iter().any(|d| d.id == id) {
            return self.keys.get(&format!("remote-{id}"));
        }
        None
    }

    /// The handshake's lookup: a code answers a few, no more (enough for a phone trying several ways at once, too few to try
    /// for digits). `local`: over TCP, not a relay: a computer that found this one nearby may ask with the nearby key.
    fn lookup(&self, id: &str, local: bool) -> Option<Vec<u8>> {
        let mut s = self.st.lock().unwrap();
        if self.code(&s, id).is_some() {
            let n = s.code_tries.entry(id.to_string()).or_insert(0);
            *n += 1;
            if *n > CODE_TRIES {
                return None;
            }
        }
        let nearby = local
            && id.starts_with(crate::pairing::NEARBY_PREFIX)
            && id.len() <= 64
            && self.nearby_open(&s);
        self.key_for(&s, id)
            .or_else(|| nearby.then(|| crate::pairing::nearby_key().to_vec()))
    }

    /// A computer on the same network may ask to pair without a code (docs/design/remote-desktop-viewer.md §Add Computer): one
    /// question at a time, none while another waits, and none for a while after the owner said no.
    fn nearby_open(&self, s: &State) -> bool {
        !s.off && s.asking.is_none() && s.nearby_paused_until.is_none_or(|t| Instant::now() >= t)
    }

    fn remove(&self, id: &str) {
        let mut s = self.st.lock().unwrap();
        self.keys.delete(&format!("remote-{id}"));
        s.devices.retain(|d| d.id != id);
        self.files.save_devices(&s.devices);
        let cur = s.current.filter(|c| s.sessions.get(c).is_some_and(|x| x.id.as_deref() == Some(id)));
        if let Some(c) = cur {
            // the phone hears it first, or it would only see the connection go and keep trying
            let ch = s.sessions[&c].chan.clone();
            ch.send(&ToPhone::Removed);
            let me = self.arc();
            let id = id.to_string();
            self.rt.spawn(async move {
                tokio::time::sleep(Duration::from_millis(300)).await;
                ch.close();
                let mut s = me.st.lock().unwrap();
                me.closed_session(&mut s, c);
                me.close_relay(&mut s, &id);
                me.update_listening(&mut s);
                me.publish(&mut s);
            });
        } else {
            self.update_listening(&mut s);
        }
        self.publish(&mut s);
    }

    // ------------------------------------------------------------------ listening

    fn update_listening(&self, s: &mut State) {
        // a question already asked keeps its way in, even once Settings stopped showing the code
        let copied = s.copied.as_ref().is_some_and(|c| c.until > Instant::now());
        let want = !s.off && (s.showing_pairing || !s.devices.is_empty() || s.asking.is_some() || copied);
        if want && s.listeners.is_none() {
            self.start_listening(s);
        } else if !want && s.listeners.is_some() {
            self.stop_listening(s);
        }
        self.update_relays(s);
    }

    fn start_listening(&self, s: &mut State) {
        let want_port = if self.cfg.port != 0 { self.cfg.port } else { s.settings.port };
        let _g = self.rt.enter();
        let tcp = match bind_tcp(want_port).or_else(|e| if want_port != 0 { bind_tcp(0) } else { Err(e) }) {
            Ok(l) => l,
            Err(e) => {
                self.log(json!({"event": "remote_listen_failed", "why": e.to_string()}));
                s.problem = Some(Problem::Listen(e.to_string()));
                return;
            }
        };
        let udp = match bind_udp() {
            Ok(u) => Arc::new(u),
            Err(e) => {
                self.log(json!({"event": "remote_listen_failed", "why": e.to_string()}));
                s.problem = Some(Problem::Listen(e.to_string()));
                return;
            }
        };
        s.problem = None;
        let port = tcp.local_addr().map(|a| a.port()).unwrap_or(0);
        let udp_port = udp.local_addr().map(|a| a.port()).unwrap_or(0);
        if self.cfg.port == 0 && port != s.settings.port {
            s.settings.port = port;
            self.files.save_settings(&s.settings);
        }
        *self.udp.lock().unwrap() = Some(udp.clone());
        let stop = Arc::new(tokio::sync::Notify::new());
        let me = self.arc();
        let st2 = stop.clone();
        self.rt.spawn(async move {
            loop {
                tokio::select! {
                    _ = st2.notified() => return,
                    a = tcp.accept() => match a {
                        Ok((c, from)) => me.accepted(c, from),
                        Err(_) => tokio::time::sleep(Duration::from_millis(100)).await,
                    },
                }
            }
        });
        let me = self.arc();
        let st3 = stop.clone();
        self.rt.spawn(async move {
            let mut buf = vec![0u8; 2048];
            loop {
                tokio::select! {
                    _ = st3.notified() => return,
                    r = udp.recv_from(&mut buf) => match r {
                        Ok((n, from)) => me.datagram(&buf[..n], from),
                        Err(_) => tokio::time::sleep(Duration::from_millis(5)).await,
                    },
                }
            }
        });
        let mdns = advertise(&self.cfg.name, &s.settings.id, port);
        self.log(json!({"event": "remote_listening", "port": port, "udp": udp_port, "dnssd": mdns.is_some()}));
        s.listeners = Some(Listeners { port, udp_port, stop, mdns });
        self.apply_awake(s);
    }

    fn stop_listening(&self, s: &mut State) {
        if let Some(l) = s.listeners.take() {
            l.stop.notify_waiters();
            if let Some((d, name)) = l.mdns {
                let _ = d.unregister(&name);
                let _ = d.shutdown();
            }
        }
        *self.udp.lock().unwrap() = None;
        self.apply_awake(s);
    }

    // ------------------------------------------------------------------ pairing

    fn renew_pairing(&self, s: &mut State) {
        if !s.showing_pairing || s.listeners.is_none() {
            return;
        }
        let code = Code {
            id: crypto::new_id(),
            key: crypto::new_key(),
            until: Instant::now() + Duration::from_secs_f64(PAIRING_LIFE),
            expires: now_ms() + (PAIRING_LIFE * 1000.0) as i64,
        };
        s.old_code = s.pairing.take();
        s.pairing = Some(code);
        s.pairing_gen += 1;
        let g = s.pairing_gen;
        if self.cfg.test_answer.is_some() {
            if let (Some(c), Some(l)) = (s.pairing.as_ref(), s.listeners.as_ref()) {
                self.log(json!({"event": "remote_pairing", "link": self.pairing_url(s, c, l.port)}));
            }
        }
        self.update_relays(s);
        let me = self.arc();
        self.rt.spawn(async move {
            tokio::time::sleep(Duration::from_secs_f64(PAIRING_LIFE - PAIRING_GRACE)).await;
            let mut s = me.st.lock().unwrap();
            if s.pairing_gen == g {
                me.renew_pairing(&mut s);
                me.publish(&mut s);
            }
        });
        let me = self.arc();
        self.rt.spawn(async move {
            // the code before this one has run out by then
            tokio::time::sleep(Duration::from_secs_f64(PAIRING_GRACE + 1.0)).await;
            let mut s = me.st.lock().unwrap();
            if s.old_code.as_ref().is_some_and(|o| o.until <= Instant::now()) {
                s.old_code = None;
                me.update_relays(&mut s);
            }
        });
    }

    fn answer(&self, s: &mut State, yes: bool, number: Option<u32>) {
        let Some(sid) = s.asking else { return };
        let Some(sess) = s.sessions.get_mut(&sid) else { return };
        if number.is_some_and(|n| n != sess.chan.number) {
            return;
        }
        s.asking = None;
        if yes {
            sess.approved = true;
            self.take_over(s, sid);
            self.greet(s, sid);
        } else {
            let ch = sess.chan.clone();
            if sess.nearby {
                s.nearby_paused_until = Some(Instant::now() + NEARBY_PAUSE);
            }
            ch.close();
            self.closed_session(s, sid);
            if s.showing_pairing {
                self.renew_pairing(s); // a no: the next phone gets a fresh code
            }
            self.update_listening(s);
        }
    }

    // ------------------------------------------------------------------ connections

    fn accepted(&self, c: TcpStream, from: SocketAddr) {
        if self.handshaking.load(SeqCst) >= MAX_HANDSHAKES {
            return; // dropped: closed at once
        }
        let _ = c.set_nodelay(true);
        let Some(udp) = self.udp.lock().unwrap().clone() else { return };
        let sid = self.next_sid.fetch_add(1, SeqCst);
        let (chan, rx) = Chan::new(sid, false, false, udp, self.rt.handle().clone());
        // Tailscale, ZeroTier: away from home, with no server between
        if let Ok(local) = c.local_addr() {
            *chan.overlay.lock().unwrap() = relay::overlay_route(from, local).map(relay::Overlay::route);
        }
        self.handshaking.fetch_add(1, SeqCst);
        let me = self.arc();
        let (r, w) = c.into_split();
        self.rt.spawn(write_tcp(w, rx, chan.frames_out.clone()));
        self.rt.spawn(async move {
            let _ = from;
            me.read_tcp(r, chan).await;
        });
    }

    async fn read_tcp(self: Arc<Self>, mut r: tokio::net::tcp::OwnedReadHalf, chan: Arc<Chan>) {
        let mut conn = Conn::new(chan.clone());
        let mut buf = vec![0u8; 64 * 1024];
        loop {
            let deadline = conn.deadline();
            let read = async {
                match deadline {
                    Some(d) => tokio::time::timeout_at(d, r.read(&mut buf)).await.ok(),
                    None => Some(r.read(&mut buf).await),
                }
            };
            let n = tokio::select! {
                _ = chan.shut.notified() => break,
                n = read => n,
            };
            match n {
                Some(Ok(n)) if n > 0 => {
                    if !self.bytes(&mut conn, &buf[..n]) {
                        break;
                    }
                }
                _ => break,
            }
        }
        self.ended(conn, None);
    }

    /// Bytes from the stream (or a relay message): frames out, each handled. False: the connection is over.
    fn bytes(self: &Arc<Self>, conn: &mut Conn, d: &[u8]) -> bool {
        conn.reader.feed(d);
        loop {
            match conn.reader.next_frame() {
                Ok(Some(f)) => {
                    if !self.frame(conn, &f) {
                        return false;
                    }
                }
                Ok(None) => return true,
                Err(_) => return false,
            }
        }
    }

    fn frame(self: &Arc<Self>, conn: &mut Conn, f: &[u8]) -> bool {
        let chan = conn.chan.clone();
        if conn.inn.is_none() {
            if conn.answered {
                return false;
            }
            let local = !chan.relay;
            let a = crypto::answer(f, crypto::random(), |id| self.lookup(id, local));
            let Some(k) = a.keys else {
                // one answer, then the connection is over
                chan.last(FrameReader::framed(&a.reply));
                conn.refused = true;
                return false;
            };
            chan.raw(FrameReader::framed(&a.reply));
            conn.answered = true;
            let udp_in = k.inn.clone();
            chan.keys(k.out, udp_in);
            conn.inn = Some(k.inn);
            conn.opened_with = Some((k.id, k.paired, k.transcript, k.commitment));
            // a waiting relay connection that answered a hello has 6 s to see a sealed frame, as any other
            conn.since = Instant::now();
            return true;
        }
        let Some(plain) = conn.inn.as_mut().and_then(|i| i.open(f)) else { return false };
        if !conn.opened {
            conn.opened = true;
            conn.reader.limit = MAX_FRAME; // only now: an id alone doesn't buy anyone a megabyte
            if !chan.relay {
                self.handshaking.fetch_sub(1, SeqCst);
                conn.counted = false;
            }
            let (id, key, transcript, commitment) = conn.opened_with.take().unwrap();
            if !self.opened(&chan, id, key, transcript, commitment) {
                return false;
            }
        }
        self.deliver(&chan, &plain);
        !chan.is_closed()
    }

    fn ended(&self, conn: Conn, relay_device: Option<String>) {
        if conn.counted {
            self.handshaking.fetch_sub(1, SeqCst);
        }
        conn.chan.close();
        let mut s = self.st.lock().unwrap();
        let sid = conn.chan.sid;
        self.closed_session(&mut s, sid);
        s.sessions.remove(&sid);
        if s.listeners.is_some() && !s.showing_pairing && s.devices.is_empty() && s.asking.is_none() {
            self.update_listening(&mut s); // the question that kept it open has gone
        }
        if let Some(id) = relay_device {
            let code = *conn.chan.relay_close.lock().unwrap();
            if code == Some(relay::BUDGET) && conn.chan.meet.load(SeqCst) && !conn.chan.moved_out() {
                // the go-between's budget for the connection is spent: it can't carry a session on that network
                self.log(json!({"event": "remote_go_between", "state": "budget"}));
                s.meet_problem = Some(GoBetweenProblem::NoDirect);
            }
            self.relay_ended(&mut s, &id, sid, conn.chan.greeted.load(SeqCst), code);
        }
        self.publish(&mut s);
    }

    /// The first sealed frame: is the key it used still that id's key?
    fn opened(&self, chan: &Arc<Chan>, id: String, used: Vec<u8>, transcript: [u8; 32], commitment: Option<Vec<u8>>) -> bool {
        let mut s = self.st.lock().unwrap();
        // removed, its code spent or renewed, or the phone paired again since: a handshake begun with it, perhaps hours ago on
        // a waiting relay connection, opens nothing
        let known = self.key_for(&s, &id);
        // a computer that found this one nearby: no code, the nearby key, and a yes here as for any new phone
        let nearby = known.is_none()
            && !chan.relay
            && id.starts_with(crate::pairing::NEARBY_PREFIX)
            && same(&used, &crate::pairing::nearby_key())
            && self.nearby_open(&s);
        let ok = nearby || known.is_some_and(|now| same(&now, &used));
        if !ok {
            self.log(json!({"event": "remote_session", "state": "refused", "why": "stale_key"}));
            return false;
        }
        let sid = chan.sid;
        s.sessions.insert(
            sid,
            Sess {
                incoming: None,
                logged: false,
                chan: chan.clone(),
                id: Some(id.clone()),
                name: String::new(),
                mic_on_phone: true,
                key_down: false,
                udp_seen: false,
                pairing_key: None,
                key_sent: false,
                approved: false,
                told_to: None,
                moves: false,
                viewer: false,
                captured: false,
                clip_gen: 0,
                clip_known: None,
                nearby,
                deferred: false,
                nonce: None,
                transcript,
                commitment,
                held_released: false,
                told: false,
                punches: 0,
                screen: None,
                screen_gen: 0,
                pinned: None,
            },
        );
        if nearby {
            s.sessions.get_mut(&sid).unwrap().pairing_key = Some(crypto::new_key());
            s.asking = Some(sid);
            self.log(json!({"event": "remote_pairing_nearby"}));
            self.publish(&mut s);
            return true;
        }
        // the code is spent the moment it opens a session
        if self.code(&s, &id).is_some() {
            // one new phone at a time: a second one using a code while the first waits is turned away
            if s.asking.is_some_and(|a| a != sid) {
                self.log(json!({"event": "remote_pairing_refused", "why": "busy"}));
                s.sessions.remove(&sid);
                return false;
            }
            s.sessions.get_mut(&sid).unwrap().pairing_key = Some(crypto::new_key());
            let current = s.pairing.as_ref().is_some_and(|c| c.id == id);
            if current {
                s.pairing = None;
            } else if s.old_code.as_ref().is_some_and(|c| c.id == id) {
                s.old_code = None;
            }
            if s.copied.as_ref().is_some_and(|c| c.id == id) {
                s.copied = None;
            }
            s.spent_code = Some(id.clone());
            // whoever holds a picture of the code, on any network: nothing until someone here says yes
            s.asking = Some(sid);
            // nothing else may come in on this code: the relay connection waiting in its room goes
            if waiting_other(&s, &id, sid) {
                self.close_relay(&mut s, &id);
            }
            if current && s.showing_pairing {
                self.renew_pairing(&mut s);
            }
            self.publish(&mut s);
            return true;
        }
        // the same device again while its session is open: a viewer's other window (hello.features "window") or the device
        // starting over. Which, its hello says (it comes with this first frame)
        if s.current.is_some_and(|c| {
            s.sessions
                .get(&c)
                .is_some_and(|x| x.id.as_deref() == Some(id.as_str()))
        }) {
            s.sessions.get_mut(&sid).unwrap().deferred = true;
            return true;
        }
        self.take_over(&mut s, sid);
        true
    }

    fn take_over(&self, s: &mut State, sid: u64) {
        if let Some(old) = s.current.filter(|o| *o != sid) {
            let (new_id, pairing, name) =
                s.sessions.get(&sid).map(|x| (x.id.clone(), x.pairing_key.is_some(), x.name.clone())).unwrap_or_default();
            if let Some((ch, old_id)) = s.sessions.get(&old).map(|o| (o.chan.clone(), o.id.clone())) {
                match old_id {
                    // anti-scam (remote-1.1.md §3): a device being let in for the first time is said to the one in use, before it
                    // gives way. The sentence is the app's: the notice, Replaced and the close go together, in that order
                    Some(old_id) if pairing && Some(&old_id) != new_id.as_ref() => {
                        if let Some(x) = s.sessions.get_mut(&sid) {
                            x.told_to = Some(old_id);
                        }
                        let host = self.cfg.name.clone();
                        self.post(move |a| {
                            ch.send(&ToPhone::Notice(a.new_pairing_notice(&name, &host)));
                            ch.send(&ToPhone::Replaced);
                            ch.close_after(Duration::from_millis(200));
                        });
                    }
                    _ => {
                        if old_id != new_id {
                            ch.send(&ToPhone::Replaced);
                        }
                        ch.close_after(Duration::from_millis(200));
                    }
                }
                self.closed_session(s, old);
            }
        }
        s.current = Some(sid);
        // the silence before this counts for nothing: a new device says nothing while the owner compares the digits, however long
        if let Some(x) = s.sessions.get(&sid) {
            x.chan.heard();
        }
        self.told.forget(sid); // another phone, or this one started again: its numbers start over
        let relay = s.sessions.get(&sid).is_some_and(|x| x.chan.relay);
        self.log(json!({"event": "remote_session", "state": "open", "relay": relay}));
        self.watch(s);
    }

    /// The session's watch: silence, and whether the OS takes our input. It runs only while a phone is connected.
    fn watch(&self, s: &mut State) {
        s.watch_gen += 1;
        let g = s.watch_gen;
        s.last_control = true; // a phone starts out assuming it may control: the first tick says otherwise
        s.displays_sent = None;
        let me = self.arc();
        self.rt.spawn(async move {
            let mut t = tokio::time::interval(Duration::from_millis(500));
            let mut n = 0u64;
            loop {
                t.tick().await;
                n += 1;
                let ok = me.backend.lock().unwrap().input().can_control();
                // the displays, every 2 s (and on the first tick): told to the phone when they change
                if n % 4 == 1 {
                    me.poll_displays(g);
                    me.poll_locked(g);
                }
                let mut s = me.st.lock().unwrap();
                if s.watch_gen != g || s.current.is_none() {
                    return;
                }
                let Some(sid) = s.current else { return };
                if ok != s.last_control {
                    s.last_control = ok;
                    if let Some(x) = s.sessions.get(&sid) {
                        x.chan.send(&ToPhone::CanControl(ok));
                    }
                }
                let Some(x) = s.sessions.get_mut(&sid) else { return };
                let quiet = x.chan.quiet().as_secs_f64();
                // after the move nothing else carries it: 6 s without a datagram and it's over (the phone starts again)
                let moved = x.chan.moved_out() || x.chan.moved_in();
                if quiet > GONE || (moved && quiet > crate::channel::MOVED_QUIET.as_secs_f64()) {
                    me.log(json!({"event": "remote_session", "state": "gone"}));
                    let ch = x.chan.clone();
                    ch.close();
                    me.closed_session(&mut s, sid);
                } else if quiet > SILENCE && !x.held_released {
                    x.held_released = true;
                    me.log(json!({"event": "remote_session", "state": "silent"}));
                    me.let_go(&mut s, sid);
                } else if quiet <= SILENCE {
                    x.held_released = false;
                }
                me.publish(&mut s);
            }
        });
    }

    /// Several displays: what the backend has now. A change goes to the phone (once it has its session), and to the screen
    /// session (the display shown may have gone).
    /// The screen locked or unlocked (where the backend can tell): the viewer says so instead of showing a picture that stopped.
    fn poll_locked(&self, g: u64) {
        let Some(l) = self.backend.lock().unwrap().locked() else { return };
        let mut s = self.st.lock().unwrap();
        if s.watch_gen != g || s.locked_sent == Some(l) {
            return;
        }
        let Some(x) = s.current.and_then(|sid| s.sessions.get(&sid)) else { return };
        if !x.chan.greeted.load(SeqCst) {
            return;
        }
        x.chan.send(&ToPhone::ScreenLocked(l));
        s.locked_sent = Some(l);
        self.log(json!({"event": "remote_locked", "locked": l}));
    }

    fn poll_displays(&self, g: u64) {
        let list = self.backend.lock().unwrap().displays();
        let mut s = self.st.lock().unwrap();
        if s.watch_gen != g {
            return;
        }
        let Some(x) = s.current.and_then(|sid| s.sessions.get(&sid)) else { return };
        if !x.chan.greeted.load(SeqCst) || !x.told || s.displays_sent.as_ref() == Some(&list) {
            return;
        }
        let changed = s.displays_sent.is_some();
        *self.displays.lock().unwrap() = list.clone();
        if !list.is_empty() {
            x.chan.send(&ToPhone::Displays(list.iter().map(crate::displays::to_wire).collect()));
        }
        let screen = x.screen.clone();
        s.displays_sent = Some(list);
        drop(s);
        if changed {
            self.log(json!({"event": "remote_displays", "count": self.displays.lock().unwrap().len()}));
            if let Some(sc) = screen {
                sc.displays_changed();
            }
        }
    }

    fn let_go(&self, s: &mut State, sid: u64) {
        let _ = self.input.send(Cmd::ReleaseAll);
        if let Some(x) = s.sessions.get_mut(&sid) {
            if x.key_down {
                x.key_down = false;
                self.post(|a| a.dictation_key(false, false));
            }
        }
    }

    fn closed_session(&self, s: &mut State, sid: u64) {
        if s.asking == Some(sid) {
            s.asking = None;
        }
        if s.current != Some(sid) {
            return;
        }
        s.current = None;
        s.watch_gen += 1;
        if let Some(x) = s.sessions.get_mut(&sid) {
            if let Some(sc) = x.screen.take() {
                sc.stop();
            }
            x.screen_gen += 1;
        }
        self.keep_awake(s, false, false);
        if s.sessions.get(&sid).is_some_and(|x| x.logged) {
            self.files.change_connections(|l| {
                if let Some(c) = l.iter_mut().rev().find(|c| c.id == sid && !c.paired) {
                    c.end = Some(now_ms());
                }
            });
        }
        self.let_go(s, sid);
        self.mic.detach();
        self.post(|a| a.session(None));
        self.log(json!({"event": "remote_session", "state": "closed"}));
    }

    fn keep_awake(&self, s: &mut State, on: bool, display: bool) {
        if on || s.awake {
            s.awake = on;
            self.backend.lock().unwrap().keep_awake(on, display);
        }
    }

    /// 保持可连接: no idle sleep while devices can connect (listening) and the setting is on, on mains power.
    fn apply_awake(&self, s: &mut State) {
        let mut b = self.backend.lock().unwrap();
        let want = s.listeners.is_some() && s.settings.stay_awake && b.plugged_in();
        if want != s.standby_awake {
            s.standby_awake = want;
            b.standby_awake(want);
            drop(b);
            self.log(json!({"event": "remote_stay_awake", "on": want}));
        }
    }

    // ------------------------------------------------------------------ what the phone says

    fn deliver(self: &Arc<Self>, chan: &Arc<Chan>, plain: &[u8]) {
        let Some(kind) = plain.first().and_then(|b| Kind::from_byte(*b)) else { return };
        let body = &plain[1..];
        match kind {
            Kind::Control => {
                if let Some(m) = ToMac::decode(body) {
                    chan.heard();
                    self.control(chan, m);
                }
            }
            Kind::Audio => {
                if chan.greeted.load(SeqCst) {
                    self.mic.receive(body);
                }
            }
            Kind::Pointer => {
                if let Some(p) = PointerPacket::decode(body) {
                    if chan.greeted.load(SeqCst) {
                        chan.heard();
                        let _ = self.input.send(Cmd::Pointer(p));
                        // its number, behind it in the queue: made once the move is, and the cursor's place says so (input.rs `Told`)
                        if let PointerPacket::Move { seq: Some(n), .. } = p {
                            let _ = self.input.send(Cmd::Made(chan.sid, n));
                        }
                    }
                }
            }
            Kind::Probe => chan.send_datagram(Kind::Probe, body),
            // pieces missing, frames decoded, a frame lost: the picture repairs itself (repair.rs)
            Kind::VideoFeedback => {
                if chan.greeted.load(SeqCst) {
                    let sc = {
                        let s = self.st.lock().unwrap();
                        self.screen(&s, chan.sid)
                    };
                    if let Some(sc) = sc {
                        sc.feedback(body);
                    }
                }
            }
            Kind::Video | Kind::Cursor => {}
            // the phone's stream after the move, and how far it has the host's
            Kind::Stream => {
                if chan.greeted.load(SeqCst) {
                    chan.stream_packet(body);
                }
            }
            Kind::StreamAck => chan.stream_ack(body),
        }
    }

    fn control(self: &Arc<Self>, chan: &Arc<Chan>, m: ToMac) {
        let sid = chan.sid;
        let mut guard = self.st.lock().unwrap();
        let s = &mut *guard;
        match m {
            ToMac::Hello { device, mic_on_phone, nonce, features } => {
                let has = |n: &str| features.as_ref().is_some_and(|f| f.iter().any(|x| x == n));
                let (moves, viewer) = (has(crate::wire::MOVE), has(crate::wire::VIEWER));
                if let Some(x) = s.sessions.get_mut(&sid) {
                    x.name = device.chars().take(64).collect();
                    x.mic_on_phone = mic_on_phone;
                    x.nonce = nonce;
                    x.moves = moves;
                    x.viewer = viewer;
                }
                chan.phone_moves.store(moves, SeqCst);
                if s.sessions.get(&sid).is_some_and(|x| x.deferred) {
                    if has(crate::wire::WINDOW) {
                        // a viewer's other window (another display): this host streams one display at a time, so the first
                        // window keeps the computer and this one hears why
                        self.log(json!({"event": "remote_session", "state": "refused", "why": "second_window"}));
                        chan.send(&ToPhone::ScreenFailed(crate::wire::ONE_DISPLAY.into()));
                        chan.close_after(Duration::from_millis(300));
                        s.sessions.remove(&sid);
                        return;
                    }
                    s.sessions.get_mut(&sid).unwrap().deferred = false;
                    self.take_over(s, sid);
                }
                self.greet(s, sid);
                self.publish(s);
                return;
            }
            ToMac::KeyStored => {
                self.key_stored(s, sid);
                self.publish(s);
                return;
            }
            // the phone's last frame on the old stream: the reader takes its frames from the UDP stream from here on
            ToMac::StreamMoved => {
                chan.peer_moved();
                return;
            }
            ToMac::Ping(t) => {
                chan.send(&ToPhone::Pong(t));
                if !chan.relay {
                    drop(guard);
                    chan.send(&ToPhone::Clock { phone: t, mac: self.now() });
                }
                return;
            }
            _ => {}
        }
        if !chan.greeted.load(SeqCst) || s.current != Some(sid) {
            return;
        }
        let windows = self.platform == "windows";
        match m {
            ToMac::Hello { .. } | ToMac::KeyStored | ToMac::Ping(_) => {}
            ToMac::Screen(r) => {
                let x = s.sessions.get_mut(&sid).unwrap();
                if let Some(sc) = x.screen.take() {
                    sc.stop();
                }
                x.screen_gen += 1;
                let g = x.screen_gen;
                let pinned = x.pinned.clone();
                self.keep_awake(s, true, false);
                let Some(mut r) = r else {
                    self.publish(s);
                    return;
                };
                // a display pinned before the picture was asked for stays pinned
                if r.display.is_none() {
                    r.display = pinned;
                }
                if !s.settings.screen {
                    chan.send(&ToPhone::ScreenFailed("off".into()));
                    return;
                }
                if self.backend.lock().unwrap().screen().is_none() {
                    chan.send(&ToPhone::ScreenFailed(NO_SCREEN.into()));
                    return;
                }
                self.keep_awake(s, true, true);
                drop(guard);
                // the start may wait on a portal's dialog: off the server's tasks, and only the latest request counts
                let (me, chan) = (self.clone(), chan.clone());
                self.rt.spawn_blocking(move || {
                    let log: Arc<dyn Fn(Value) + Send + Sync> = {
                        let me = me.clone();
                        Arc::new(move |v| me.log(v))
                    };
                    let started = ScreenSession::start(&r, chan.clone(), me.backend.clone(), me.input.clone(), me.rt.handle().clone(), log, me.displays.clone(), me.told.clone());
                    let mut s = me.st.lock().unwrap();
                    let still = s.current == Some(chan.sid) && s.sessions.get(&chan.sid).is_some_and(|x| x.screen_gen == g);
                    match started {
                        Ok(sc) if still => {
                            s.sessions.get_mut(&chan.sid).unwrap().screen = Some(Arc::new(sc));
                        }
                        Ok(sc) => sc.stop(),
                        Err(why) => {
                            me.log(json!({"event": "remote_screen", "state": "failed", "why": why}));
                            if still {
                                chan.send(&ToPhone::ScreenFailed(why));
                                me.keep_awake(&mut s, true, false);
                            }
                        }
                    }
                    me.publish(&mut s);
                });
            }
            ToMac::ScreenCrop(c) => {
                if let Some(sc) = self.screen(s, sid) {
                    sc.set_crop(c);
                }
            }
            ToMac::ScreenReport(r) => {
                if let Some(sc) = self.screen(s, sid) {
                    drop(guard);
                    sc.report(&r);
                }
            }
            ToMac::ScreenPace { idle } => {
                if let Some(sc) = self.screen(s, sid) {
                    sc.pace(idle);
                }
            }
            ToMac::RequestKeyframe => {
                if let Some(sc) = self.screen(s, sid) {
                    sc.keyframe();
                }
            }
            ToMac::PointerTo { x, y, seq } => {
                if let Some(sc) = self.screen(s, sid) {
                    sc.pointer_to(x, y);
                }
                // its number counts even with no picture to place it on: the phone waits for it
                if let Some(n) = seq {
                    let _ = self.input.send(Cmd::Made(sid, n));
                }
            }
            ToMac::ShowDisplay(d) => {
                s.sessions.get_mut(&sid).unwrap().pinned = d.clone();
                if let Some(sc) = self.screen(s, sid) {
                    sc.pin(d);
                }
            }
            ToMac::Unpair => {
                if let Some(id) = s.sessions.get(&sid).and_then(|x| x.id.clone()) {
                    drop(guard);
                    self.remove(&id);
                }
            }
            ToMac::Replaces { device_id } => {
                // only a phone the owner just said yes to may drop its own older entry
                let x = &s.sessions[&sid];
                if x.approved && x.id.as_deref() != Some(device_id.as_str()) && s.devices.iter().any(|d| d.id == device_id) {
                    drop(guard);
                    self.remove(&device_id);
                }
            }
            ToMac::OfferRelay(a) => {
                // and only it may set the relay: another paired phone can't point this one somewhere else
                if s.sessions[&sid].approved && s.settings.relay.is_none() && !self.is_meet(&a) {
                    if let Some(a) = relay::address(&a) {
                        s.settings.relay = Some(Some(a));
                        s.settings.relay_from_phone = true;
                        self.files.save_settings(&s.settings);
                        self.log(json!({"event": "remote_relay", "state": "adopted"}));
                        self.relay_changed(s);
                    }
                }
            }
            ToMac::Candidates(list) => {
                let x = s.sessions.get_mut(&sid).unwrap();
                if x.punches < 3 {
                    x.punches += 1;
                    self.punch(list);
                }
            }
            ToMac::ScreenStats(j) => self.log(json!({"event": "remote_screen_phone", "stats": j})),
            ToMac::ScreenSnapshot { .. } => {}
            ToMac::SetMicOnPhone(on) => {
                s.sessions.get_mut(&sid).unwrap().mic_on_phone = on;
                // a note waiting on the phone's microphone that the phone can't have: heard through this computer's instead
                if !on {
                    self.post(|a| a.phone_mic(false));
                }
            }
            ToMac::Key { chord, down } => {
                // a modifier pressed on its own shows too: it may have switched the input method
                if down != Some(false) && (!chord.key.is_empty() || (down.is_none() && chord.mods != 0)) {
                    let l = input::label(&chord, windows);
                    self.post(move |a| a.hud(&l));
                }
                let _ = self.input.send(Cmd::Key(chord, down));
            }
            ToMac::Mods(m) => {
                let _ = self.input.send(Cmd::Mods(m));
            }
            ToMac::Run(steps) => {
                if steps.len() > MAX_STEPS {
                    return;
                }
                let waits: i64 = steps.iter().map(|st| if let crate::wire::Step::Wait(ms) = st { (*ms).clamp(0, MAX_WAIT_MS + 1) } else { 0 }).sum();
                if waits > MAX_WAIT_MS {
                    return;
                }
                let keys: Vec<String> = steps
                    .iter()
                    .filter_map(|st| if let crate::wire::Step::Key(c) = st { Some(input::label(c, windows)) } else { None })
                    .collect();
                if !keys.is_empty() {
                    let l = keys.join(" ");
                    self.post(move |a| a.hud(&l));
                }
                let _ = self.input.send(Cmd::Run(steps));
            }
            ToMac::Text(t) => {
                if t.len() <= MAX_TEXT {
                    let _ = self.input.send(Cmd::Text(t));
                }
            }
            ToMac::Button { button, down } => {
                let _ = self.input.send(Cmd::Button(button, down));
            }
            ToMac::DragBegin => {
                let _ = self.input.send(Cmd::DragBegin);
            }
            ToMac::DictationKey { down } => {
                let x = s.sessions.get_mut(&sid).unwrap();
                x.key_down = down;
                let mic = x.mic_on_phone;
                if down {
                    self.mic.clear(); // the end of the last take isn't the start of this one
                }
                self.post(move |a| a.dictation_key(down, mic));
            }
            ToMac::Blurt(c) => {
                let mic = s.sessions[&sid].mic_on_phone;
                self.post(move |a| a.blurt(c, mic));
            }
            ToMac::System(m) => {
                let _ = self.input.send(Cmd::System(m));
            }
            ToMac::Activate { .. } => {} // a Mac's bundle id: nothing to open here
            ToMac::Hud(t) => {
                let t: String = t.chars().take(64).collect();
                self.post(move |a| a.hud(&t));
            }
            ToMac::ReleaseAll => self.let_go(s, sid),
            ToMac::StreamMoved => {} // read where it's read (`peer_moved`)
            // a viewer's: its clipboard onto this computer's, and whether its keys are here
            ToMac::Clipboard(t) => {
                let x = s.sessions.get_mut(&sid).unwrap();
                if !x.viewer
                    || !x.captured
                    || !crate::wire::clipboard_fits(&t)
                    || x.clip_known.as_deref() == Some(t.as_str())
                {
                    return;
                }
                x.clip_known = Some(t.clone());
                drop(guard);
                let backend = self.backend.clone();
                self.rt
                    .spawn_blocking(move || backend.lock().unwrap().input().set_clipboard(&t));
            }
            // 隐私屏: Mac only for now (this host doesn't list `privacy`, so viewers don't offer it)
            ToMac::PrivacyScreen(_) => {}
            ToMac::FileBegin { id, name, size } => {
                let Some(dir) = self.downloads.lock().unwrap().clone() else { return };
                let x = s.sessions.get_mut(&sid).unwrap();
                let r = x.incoming.get_or_insert_with(|| crate::incoming::Receiver::new(dir));
                if let Some(m) = r.begin(&id, &name, size, false) {
                    chan.send(&m);
                }
            }
            ToMac::FileChunk { id, data } => {
                if let Some(m) = s.sessions.get_mut(&sid).and_then(|x| x.incoming.as_mut()).and_then(|r| r.chunk(&id, &data)) {
                    chan.send(&m);
                }
            }
            ToMac::FileEnd { id } => {
                let Some(x) = s.sessions.get_mut(&sid) else { return };
                let from = x.name.clone();
                let Some(said) = x.incoming.as_mut().map(|r| r.end(&id)) else { return };
                if let Some(m) = said.msg {
                    chan.send(&m);
                }
                if let Some(name) = said.saved {
                    self.log(json!({"event": "remote_file", "state": "saved"}));
                    self.post(move |a| a.file_received(&from, &name));
                }
            }
            ToMac::KeysCaptured(on) => {
                let x = s.sessions.get_mut(&sid).unwrap();
                if !x.viewer || x.captured == on {
                    return;
                }
                x.captured = on;
                x.clip_gen += 1;
                if on {
                    let g = x.clip_gen;
                    drop(guard);
                    self.watch_clipboard(chan.clone(), g);
                }
            }
        }
    }

    /// While a viewer's keys are captured: this computer's clipboard, looked at twice a second, goes to the viewer when it
    /// changes here (not what the viewer just put on it, and not what it held when the keys came here).
    fn watch_clipboard(self: &Arc<Self>, chan: Arc<Chan>, g: u64) {
        let me = self.clone();
        self.rt.spawn(async move {
            // what this watch last read: a change is a read that differs from it
            let mut last: Option<Option<String>> = None;
            loop {
                let still = {
                    let s = me.st.lock().unwrap();
                    s.current == Some(chan.sid) && s.sessions.get(&chan.sid).is_some_and(|x| x.captured && x.clip_gen == g)
                };
                if !still || chan.is_closed() {
                    return;
                }
                let backend = me.backend.clone();
                let now = tokio::task::spawn_blocking(move || backend.lock().unwrap().input().clipboard()).await.ok().flatten();
                {
                    let mut s = me.st.lock().unwrap();
                    let Some(x) = s.sessions.get_mut(&chan.sid).filter(|x| x.captured && x.clip_gen == g) else { return };
                    let changed = last.as_ref().is_some_and(|l| *l != now);
                    if let Some(t) = now.as_ref().filter(|t| changed && crate::wire::clipboard_fits(t)) {
                        if x.clip_known.as_deref() != Some(t.as_str()) {
                            x.clip_known = Some(t.clone());
                            chan.send(&ToPhone::Clipboard(t.clone()));
                        }
                    }
                }
                last = Some(now);
                tokio::time::sleep(CLIPBOARD_EVERY).await;
            }
        });
    }

    fn screen(&self, s: &State, sid: u64) -> Option<Arc<ScreenSession>> {
        s.sessions.get(&sid).and_then(|x| x.screen.clone())
    }

    fn greet(&self, s: &mut State, sid: u64) {
        if s.asking == Some(sid) {
            let x = &s.sessions[&sid];
            // no digits that match what the handshake committed to, no question
            let Some(digits) = x.nonce.as_ref().and_then(|n| check_digits(x, n)) else {
                s.asking = None;
                let ch = x.chan.clone();
                ch.close();
                self.closed_session(s, sid);
                return;
            };
            let number = x.chan.number;
            let name = shown(s, x);
            x.chan.send(&ToPhone::PairingWaits);
            self.log(json!({"event": "remote_pairing_asks", "relay": x.chan.relay}));
            self.publish(s);
            {
                let d = digits.clone();
                self.post(move |a| a.asking(&name, &d));
            }
            // nobody answers: after two minutes it's a no, so a question left open can't keep everyone else waiting
            let me = self.arc();
            self.rt.spawn(async move {
                tokio::time::sleep(Duration::from_secs_f64(PAIRING_LIFE)).await;
                let mut s = me.st.lock().unwrap();
                if s.asking == Some(sid) {
                    me.answer(&mut s, false, Some(number));
                    me.publish(&mut s);
                }
            });
            if let Some(yes) = self.cfg.test_answer {
                let me = self.arc();
                self.rt.spawn(async move {
                    tokio::time::sleep(Duration::from_secs(3)).await;
                    let mut s = me.st.lock().unwrap();
                    me.answer(&mut s, yes, Some(number));
                    me.publish(&mut s);
                });
            }
            return;
        }
        if s.current != Some(sid) {
            return;
        }
        let x = s.sessions.get_mut(&sid).unwrap();
        let Some(id) = x.id.clone() else { return };
        if let Some(k) = x.pairing_key {
            x.key_sent = true;
            x.chan.send(&ToPhone::NewKey(k.to_vec())); // keyStored finishes it
            return;
        }
        let name = x.name.clone();
        let kind = DeviceKind::of_hello(x.viewer);
        // anti-scam: devices paired here since this one was last in are said to it, after its session (it listens from then on)
        let since = s.devices.iter().find(|d| d.id == id).and_then(|d| d.last_seen);
        let notice = since.and_then(|since| self.new_pairings(&id, since));
        if let Some(d) = s.devices.iter_mut().find(|d| d.id == id) {
            d.last_seen = Some(now_ms());
            if !name.is_empty() {
                d.name = name;
            }
            // a record from before kinds were kept learns it here
            d.kind = kind;
            self.files.save_devices(&s.devices);
        }
        self.begin(s, sid, notice);
    }

    fn key_stored(&self, s: &mut State, sid: u64) {
        if s.current != Some(sid) {
            return;
        }
        let x = s.sessions.get_mut(&sid).unwrap();
        let (Some(id), Some(k), true) = (x.id.clone(), x.pairing_key, x.key_sent) else { return };
        x.pairing_key = None;
        let name = x.name.clone();
        let told = x.told_to.clone();
        if let Err(e) = self.keys.put(&format!("remote-{id}"), &k) {
            self.log(json!({"event": "remote_key_store_failed", "why": e}));
        }
        s.devices.retain(|d| d.id != id);
        let kind = DeviceKind::of_hello(x.viewer);
        s.devices.push(Device {
            id: id.clone(),
            name,
            added: now_ms(),
            last_seen: Some(now_ms()),
            kind,
            alias: None,
        });
        self.files.save_devices(&s.devices);
        let name = s.devices.last().map(|d| d.name.clone()).unwrap_or_default();
        self.files.change_connections(|l| {
            l.push(Connection { id: sid, device_id: id.clone(), name: name.clone(), start: now_ms(), end: None, route: None, paired: true })
        });
        // the device connected when the owner said yes heard of it then (take_over); the others hear of it when they next come in
        if let Some(d) = told.and_then(|t| s.devices.iter_mut().find(|d| d.id == t)) {
            d.last_seen = Some(now_ms()); // not before the paired entry just logged
            self.files.save_devices(&s.devices);
        }
        self.begin(s, sid, None);
        self.update_listening(s);
        // a relay connection still in the code's room goes; the next waits in the new key's
        if waiting_other(s, &id, sid) {
            self.close_relay(s, &id);
        }
        self.update_relays(s);
    }

    /// `notice`: the devices paired since this one was last in, said right after the session message
    fn begin(&self, s: &mut State, sid: u64, notice: Option<String>) {
        if let Some(x) = s.sessions.get_mut(&sid) {
            if !x.logged {
                x.logged = true;
                let (dev, name, route) = (x.id.clone().unwrap_or_default(), x.name.clone(), route_of(&x.chan).to_string());
                self.files.change_connections(|l| {
                    l.push(Connection { id: sid, device_id: dev, name, start: now_ms(), end: None, route: Some(route), paired: false })
                });
            }
        }
        let x = &s.sessions[&sid];
        let chan = x.chan.clone();
        let name = shown(s, x);
        let moves = x.moves;
        chan.greeted.store(true, SeqCst);
        chan.heard();
        self.keep_awake(s, true, false);
        let (can, aspect) = {
            let mut b = self.backend.lock().unwrap();
            (b.input().can_control(), b.display_aspect())
        };
        s.last_control = can;
        let udp_port = s.listeners.as_ref().map_or(0, |l| l.udp_port);
        let relay = self.offered(s, moves);
        let info = SessionInfo {
            mac_name: self.cfg.name.clone(),
            udp_port,
            udp_session: chan.number,
            can_control: can,
            version: self.cfg.version.clone(),
            candidates: vec![],
            display_aspect: if aspect.is_finite() && aspect > 0.0 { aspect } else { 1.6 },
            relay,
            platform: Some(self.platform.to_string()),
            features: Some({
                let mut f = vec![crate::wire::MOVE.to_string(), crate::wire::VIEWER.to_string()];
                if self.downloads.lock().unwrap().is_some() {
                    f.push("files".to_string());
                }
                f
            }),
        };
        {
            let n = name.clone();
            self.post(move |a| a.session(Some(&n)));
        }
        let me = self.arc();
        self.rt.spawn(async move {
            let mut info = info;
            // where the phone might reach this computer: the LAN's and the overlays' addresses always (the phone keeps them, and
            // tries the overlays' when it's away); without the relay, also what the internet sees
            let mut list: Vec<Candidate> = relay::local_addresses().into_iter().map(|h| Candidate { host: h, port: udp_port }).collect();
            if chan.relay {
                list.extend(relay::public_ipv6().into_iter().map(|h| Candidate { host: h, port: udp_port }));
                if let Some(c) = me.stun().await {
                    list.push(c);
                }
            }
            info.candidates = list;
            chan.send(&ToPhone::Session(info));
            if let Some(list) = notice {
                let (chan, host) = (chan.clone(), me.cfg.name.clone());
                me.post(move |a| chan.send(&ToPhone::Notice(a.new_pairing_notice(&list, &host))));
            }
            if chan.meet.load(SeqCst) {
                // the go-between only introduces: no direct path within 8 s, and this session can't go on
                let (me, chan) = (me.clone(), chan.clone());
                me.clone().rt.spawn(async move {
                    tokio::time::sleep(NO_DIRECT).await;
                    let mut s = me.st.lock().unwrap();
                    let open = s.sessions.get(&chan.sid).is_some_and(|x| x.udp_seen);
                    if open || chan.is_closed() {
                        return;
                    }
                    me.log(json!({"event": "remote_go_between", "state": "no_direct"}));
                    chan.send(&ToPhone::NoDirect);
                    chan.close_after(Duration::from_millis(300));
                    s.meet_problem = Some(GoBetweenProblem::NoDirect);
                    me.publish(&mut s);
                });
            }
            let g = {
                let mut s = me.st.lock().unwrap();
                if let Some(x) = s.sessions.get_mut(&chan.sid) {
                    x.told = true;
                }
                s.watch_gen
            };
            me.poll_displays(g); // several displays: the list right after the session, not 2 s later
            let me2 = me.clone();
            me.post(move |a| {
                if let Some(f) = a.front() {
                    chan.send(&ToPhone::Front(f));
                }
                chan.send(&ToPhone::Dictation(a.dictation_phase()));
                drop(me2);
            });
        });
        self.publish(s);
    }

    /// What a STUN server sees of the UDP port (from the port itself), within 2 s.
    async fn stun(&self) -> Option<Candidate> {
        let udp = self.udp.lock().unwrap().clone()?;
        let txn: [u8; 12] = crypto::random();
        let (tx, rx) = tokio::sync::oneshot::channel();
        self.stun.lock().unwrap().push((txn, tx));
        for server in relay::STUN_SERVERS {
            let Ok(Ok(mut found)) = tokio::time::timeout(Duration::from_millis(500), tokio::net::lookup_host(server)).await else { continue };
            let Some(to) = found.find(|a| a.is_ipv4()) else { continue };
            let to = SocketAddr::new(
                IpAddr::V6(match to.ip() {
                    IpAddr::V4(v4) => v4.to_ipv6_mapped(),
                    IpAddr::V6(v6) => v6,
                }),
                to.port(),
            );
            let _ = udp.send_to(&relay::stun_request(&txn), to).await;
        }
        let r = tokio::time::timeout(Duration::from_secs(2), rx).await.ok().and_then(Result::ok);
        self.stun.lock().unwrap().retain(|(t, _)| *t != txn);
        r
    }

    /// Packets out to where the phone may be, from the port it's knocking on: they open this side's firewall. They carry nothing.
    fn punch(&self, list: Vec<Candidate>) {
        let Some(udp) = self.udp.lock().unwrap().clone() else { return };
        let targets: Vec<SocketAddr> = list
            .into_iter()
            .take(8)
            .filter_map(|c| c.host.parse::<IpAddr>().ok().map(|ip| (ip, c.port)))
            .map(|(ip, port)| match ip {
                IpAddr::V4(v4) => SocketAddr::new(IpAddr::V6(v4.to_ipv6_mapped()), port),
                v6 => SocketAddr::new(v6, port),
            })
            .collect();
        self.rt.spawn(async move {
            for _ in 0..8 {
                for t in &targets {
                    let _ = udp.send_to(&[0], *t).await;
                }
                tokio::time::sleep(Duration::from_millis(250)).await;
            }
        });
    }

    /// A datagram on the UDP port: STUN's answer, or the current session's (anything else is dropped on the spot).
    fn datagram(&self, d: &[u8], from: SocketAddr) {
        if relay::is_stun_response(d) {
            let mut w = self.stun.lock().unwrap();
            if let Some(i) = w.iter().position(|(t, _)| relay::stun_parse(d, t).is_some()) {
                let (t, tx) = w.remove(i);
                if let Some(c) = relay::stun_parse(d, &t) {
                    let _ = tx.send(c);
                }
            }
            return;
        }
        let chan = {
            let s = self.st.lock().unwrap();
            let Some(x) = s.current.and_then(|id| s.sessions.get(&id)) else { return };
            if !x.chan.greeted.load(SeqCst) || crypto::session_of_packet(d) != Some(x.chan.number) {
                return;
            }
            x.chan.clone()
        };
        let Some(plain) = chan.open_packet(d) else { return };
        chan.use_flow(from);
        chan.heard();
        let mut first = false;
        {
            let mut s = self.st.lock().unwrap();
            if let Some(x) = s.sessions.get_mut(&chan.sid) {
                if !x.udp_seen {
                    x.udp_seen = true;
                    first = true;
                }
            }
            if first {
                self.publish(&mut s);
            }
        }
        if first {
            self.log(json!({"event": "remote_udp", "state": "ok", "relay": chan.relay}));
            chan.send(&ToPhone::UdpOk);
            if chan.relay {
                chan.send_datagram(Kind::Probe, &[0; 8]); // the way back works too: the phone switches
            }
            // on the go-between, with a phone that can: everything moves onto this path, and the go-between goes quiet
            if chan.meet.load(SeqCst) && chan.phone_moves.load(SeqCst) && chan.move_out() {
                self.log(json!({"event": "remote_go_between", "state": "moved"}));
                let mut s = self.st.lock().unwrap();
                s.meet_problem = None;
                self.publish(&mut s);
            }
        }
        let me = self.arc();
        me.deliver(&chan, &plain);
    }

    /// Devices paired here since `since` (ms), other than `id`: their names, to be said to that device (anti-scam).
    fn new_pairings(&self, id: &str, since: i64) -> Option<String> {
        let mut names: Vec<String> = self
            .files
            .connections()
            .into_iter()
            .filter(|c| c.paired && c.device_id != id && c.start > since)
            .map(|c| c.name)
            .collect();
        names.sort();
        names.dedup();
        (!names.is_empty()).then(|| names.join(", "))
    }

    // ------------------------------------------------------------------ the relay

    fn relay_changed(&self, s: &mut State) {
        // first: it may be riding on the connection this closes
        if let Some(x) = s.current.and_then(|id| s.sessions.get(&id)) {
            x.chan.send(&ToPhone::Relay(self.offered(s, x.moves)));
        }
        self.update_relays(s);
        if s.showing_pairing && s.listeners.is_some() {
            self.renew_pairing(s); // the code carries the address
        }
    }

    fn update_relays(&self, s: &mut State) {
        let address = self.away(s).map(|(a, _)| a).filter(|_| s.listeners.is_some());
        let ids = standby_ids(s);
        // a changed address counts as gone: the phone has been told the new one
        let stale: Vec<String> = s
            .relays
            .iter()
            .filter(|(id, r)| {
                let carrying = s.spent_code.as_deref() == Some(id.as_str()) && (s.current == Some(r.sid) || s.asking == Some(r.sid));
                address.is_none() || !(ids.contains(id) || carrying) || s.relay_at != address
            })
            .map(|(id, _)| id.clone())
            .collect();
        for id in stale {
            if let Some(r) = s.relays.remove(&id) {
                self.stop_waiting(s, r);
            }
        }
        if s.relay_at != address {
            s.own_relay_fails = 0;
        }
        s.relay_at = address.clone();
        self.update_fallbacks(s);
        if address.is_none() {
            return;
        }
        for id in ids {
            if !s.relays.contains_key(&id) {
                self.connect_relay(s, &id);
            }
        }
    }

    /// Both of a device's waiting connections: the owner's relay and, while that's down, the go-between.
    fn close_relay(&self, s: &mut State, id: &str) {
        for r in [s.relays.remove(id), s.fallbacks.remove(id)].into_iter().flatten() {
            self.stop_waiting(s, r);
        }
    }

    fn stop_waiting(&self, s: &State, r: RelayConn) {
        r.stop.notify_one();
        if let Some(x) = s.sessions.get(&r.sid) {
            x.chan.close();
        }
    }

    fn own_relay_down(&self, s: &State) -> bool {
        relay_address(&s.settings).is_some() && s.own_relay_fails >= RELAY_DOWN_AFTER
    }

    /// The owner's relay connected, or failed once more: from RELAY_DOWN_AFTER failures in a row the go-between is used as well
    /// (while its switch is on), until the relay answers again.
    fn own_relay_answered(&self, s: &mut State, ok: bool) {
        if ok {
            if s.own_relay_fails == 0 {
                return;
            }
            let was = self.own_relay_down(s);
            s.own_relay_fails = 0;
            if !was {
                return;
            }
            self.log(json!({"event": "remote_relay", "state": "own_back"}));
        } else {
            s.own_relay_fails += 1;
            if s.own_relay_fails != RELAY_DOWN_AFTER {
                return;
            }
            self.log(json!({"event": "remote_relay", "state": "own_down"}));
        }
        self.update_fallbacks(s);
    }

    fn update_fallbacks(&self, s: &mut State) {
        let want = self.own_relay_down(s) && s.settings.go_between && s.listeners.is_some();
        let ids = standby_ids(s);
        let stale: Vec<String> = s
            .fallbacks
            .iter()
            .filter(|(id, r)| s.current != Some(r.sid) && (!want || !ids.contains(id)))
            .map(|(id, _)| id.clone())
            .collect();
        for id in stale {
            if let Some(r) = s.fallbacks.remove(&id) {
                self.stop_waiting(s, r);
            }
        }
        if !want {
            return;
        }
        for id in ids {
            if !s.fallbacks.contains_key(&id) {
                self.connect_fallback(s, &id);
            }
        }
    }

    fn connect_fallback(&self, s: &mut State, id: &str) {
        if !(self.own_relay_down(s) && s.settings.go_between) {
            return;
        }
        if let Some(a) = self.meet_address() {
            self.connect_via(s, id, a, true, true);
        }
    }

    fn connect_relay(&self, s: &mut State, id: &str) {
        let Some((address, meet)) = self.away(s) else { return };
        self.connect_via(s, id, address, meet, false);
    }

    /// `fallback`: the go-between while the owner's relay is down (kept in `fallbacks`, beside the relay's own connection).
    fn connect_via(&self, s: &mut State, id: &str, address: String, meet: bool, fallback: bool) {
        if if fallback { s.fallbacks.contains_key(id) } else { s.relays.contains_key(id) } {
            return;
        }
        let key = match self.code(s, id) {
            Some(c) => Some(c.key.to_vec()),
            None if s.devices.iter().any(|d| d.id == id) => self.keys.get(&format!("remote-{id}")),
            None => None,
        };
        let Some(key) = key else {
            // a paired device whose key can't be read: nothing waits for it, and it can't connect from away (a spent code is
            // simply done)
            if s.devices.iter().any(|d| d.id == id) {
                self.log(json!({"event": "remote_relay", "state": "no_key"}));
            }
            return;
        };
        let Some(udp) = self.udp.lock().unwrap().clone() else { return };
        let sid = self.next_sid.fetch_add(1, SeqCst);
        let stop = Arc::new(tokio::sync::Notify::new());
        let conn = RelayConn { sid, stop: stop.clone() };
        if fallback {
            s.fallbacks.insert(id.to_string(), conn);
        } else {
            s.relays.insert(id.to_string(), conn);
        }
        let me = self.arc();
        let id = id.to_string();
        self.rt.spawn(async move {
            let room = relay::room(&key);
            let ws = tokio::select! {
                _ = stop.notified() => return,
                ws = relay::connect(&address, &room, "mac") => ws,
            };
            let ws = match ws {
                Ok(ws) => {
                    let mut s = me.st.lock().unwrap();
                    if meet {
                        s.meet_refusals = 0;
                        if s.meet_problem == Some(GoBetweenProblem::Busy) {
                            s.meet_problem = None;
                        }
                    } else if s.relay_reachable != Some(true) {
                        s.relay_reachable = Some(true);
                    }
                    if !meet {
                        me.own_relay_answered(&mut s, true);
                    }
                    me.publish(&mut s);
                    drop(s);
                    me.log(json!({"event": "remote_relay", "state": "waiting", "goBetween": meet, "fallback": fallback}));
                    ws
                }
                Err(e) => {
                    me.log(json!({"event": "remote_relay", "state": "failed", "why": e.to_string(), "goBetween": meet}));
                    let mut s = me.st.lock().unwrap();
                    let busy = meet && matches!(e, relay::ConnectError::Refused(_));
                    if busy {
                        // the day's quota is gone, or it's rate-limiting: "busy today", and no retrying in a loop
                        s.meet_refusals += 1;
                        s.meet_problem = Some(GoBetweenProblem::Busy);
                    } else if !meet {
                        s.relay_reachable = Some(false);
                        me.own_relay_answered(&mut s, false);
                    }
                    let wait = busy.then(|| relay::busy_wait(s.meet_refusals));
                    me.relay_ended_after(&mut s, &id, sid, false, None, wait);
                    me.publish(&mut s);
                    return;
                }
            };
            let (chan, rx) = Chan::new(sid, true, true, udp, me.rt.handle().clone());
            chan.meet.store(meet, SeqCst);
            {
                // closed while connecting
                let s = me.st.lock().unwrap();
                let map = if fallback { &s.fallbacks } else { &s.relays };
                if map.get(&id).map(|r| r.sid) != Some(sid) {
                    return;
                }
            }
            let (sink, stream) = ws.split();
            me.rt.spawn(write_ws(sink, rx, chan.frames_out.clone()));
            let stop2 = stop.clone();
            let c2 = chan.clone();
            me.rt.spawn(async move {
                stop2.notified().await;
                c2.close();
            });
            me.clone().read_ws(stream, chan, id).await;
        });
    }

    async fn read_ws(self: Arc<Self>, mut stream: futures_util::stream::SplitStream<relay::Socket>, chan: Arc<Chan>, id: String) {
        let mut conn = Conn::new(chan.clone());
        conn.counted = false;
        // the heartbeat of a waiting connection is a WebSocket protocol ping, never a message: the go-between's host doesn't
        // bill incoming protocol pings, and the relay answers them by itself
        let mut beat = tokio::time::interval(Duration::from_secs(30));
        beat.tick().await;
        let mut pong_owed = false;
        // after the phone's streamMoved: its frames, in order, from the stream over UDP
        let mut moved: Option<mpsc::UnboundedReceiver<Vec<u8>>> = None;
        let mut ws_open = true;
        loop {
            let deadline = conn.deadline();
            let next = async {
                match deadline {
                    Some(d) => tokio::time::timeout_at(d, stream.next()).await.ok(),
                    None => Some(stream.next().await),
                }
            };
            let from_udp = async {
                match moved.as_mut() {
                    Some(r) => r.recv().await,
                    None => std::future::pending().await,
                }
            };
            tokio::select! {
                _ = chan.shut.notified() => break,
                _ = beat.tick(), if !conn.opened && ws_open => {
                    // a waiting connection that doesn't answer is dead, and a new one is made
                    if pong_owed { break; }
                    pong_owed = true;
                    chan.ping();
                }
                b = from_udp => match b {
                    Some(b) => if !self.bytes(&mut conn, &b) { break; },
                    None => break,
                },
                m = next, if ws_open => match m {
                    Some(Some(Ok(Message::Binary(b)))) => {
                        // nothing after the phone's streamMoved counts on the old stream
                        if moved.is_some() { continue; }
                        if !self.bytes(&mut conn, &b) { break; }
                        if chan.moved_in() {
                            moved = chan.take_moved();
                            conn.reader = FrameReader::default();
                            conn.reader.limit = MAX_FRAME;
                            self.log(json!({"event": "remote_go_between", "state": "phone_moved"}));
                        }
                    }
                    Some(Some(Ok(Message::Pong(_)))) => pong_owed = false,
                    Some(Some(Ok(Message::Close(f)))) => {
                        *chan.relay_close.lock().unwrap() = f.map(|f| u16::from(f.code));
                        // moved both ways: the session carries on over UDP
                        if moved.is_some() && chan.moved_out() { ws_open = false; continue; }
                        break;
                    }
                    Some(Some(Ok(_))) => {}
                    Some(None) | Some(Some(Err(_))) if moved.is_some() && chan.moved_out() => ws_open = false,
                    _ => break,
                },
            }
        }
        self.ended(conn, Some(id));
    }

    fn relay_ended(&self, s: &mut State, id: &str, sid: u64, greeted: bool, code: Option<u16>) {
        self.relay_ended_after(s, id, sid, greeted, code, None);
    }

    /// `after`: the go-between said it's busy, and the next try waits that long.
    fn relay_ended_after(&self, s: &mut State, id: &str, sid: u64, greeted: bool, code: Option<u16>, after: Option<Duration>) {
        let clean = code == Some(relay::PHONE_LEFT) || greeted;
        if s.fallbacks.get(id).map(|r| r.sid) == Some(sid) {
            s.fallbacks.remove(id);
            let wait = after.map_or(if clean { 0.5 } else { 4.0 }, |a| a.as_secs_f64());
            let me = self.arc();
            let id = id.to_string();
            self.rt.spawn(async move {
                tokio::time::sleep(Duration::from_secs_f64(wait)).await;
                let mut s = me.st.lock().unwrap();
                if !s.fallbacks.contains_key(&id) && standby_ids(&s).contains(&id) {
                    me.connect_fallback(&mut s, &id);
                }
            });
            return;
        }
        if s.relays.get(id).map(|r| r.sid) != Some(sid) {
            return;
        }
        s.relays.remove(id);
        // a failure waits longer each time, but not so long that a bad hello now and then keeps the phone off the relay
        let mut wait = if clean { 0.5 } else { (s.relay_wait.get(id).copied().unwrap_or(1.0) * 2.0).min(8.0) };
        s.relay_wait.insert(id.to_string(), if clean { 1.0 } else { wait });
        if let Some(a) = after {
            wait = a.as_secs_f64();
        }
        let me = self.arc();
        let id = id.to_string();
        self.rt.spawn(async move {
            tokio::time::sleep(Duration::from_secs_f64(wait)).await;
            let mut s = me.st.lock().unwrap();
            let ok = s.relay_at.is_some() && !s.relays.contains_key(&id);
            if ok {
                me.connect_relay(&mut s, &id);
            }
        });
    }
}

fn check_digits(x: &Sess, nonce: &[u8]) -> Option<String> {
    let c = x.commitment.as_ref()?;
    same(&crypto::commitment(nonce), c).then(|| crypto::check(&x.transcript, nonce))
}

/// How a session came in, as Status and the connection log say it.
/// What this computer calls a session's device: the owner's name for it if it's paired and renamed here, else what its hello said.
fn shown(s: &State, x: &Sess) -> String {
    x.id.as_deref().and_then(|id| s.devices.iter().find(|d| d.id == id)).and_then(|d| d.alias.clone()).unwrap_or_else(|| x.name.clone())
}

fn route_of(chan: &Chan) -> &'static str {
    if !chan.relay {
        chan.overlay.lock().unwrap().unwrap_or("local")
    } else if chan.meet.load(SeqCst) {
        if chan.moved_out() {
            "direct"
        } else {
            "goBetween"
        }
    } else if chan.has_datagrams() {
        "direct"
    } else {
        "relay"
    }
}

/// The owner's relay failing this many times in a row without connecting counts as down.
const RELAY_DOWN_AFTER: u32 = 2;

/// The devices a waiting connection is held for: the paired ones and any code showing (a phone on another network can pair too).
fn standby_ids(s: &State) -> Vec<String> {
    let mut ids: Vec<String> = s.devices.iter().map(|d| d.id.clone()).collect();
    ids.extend([s.pairing.as_ref(), s.old_code.as_ref(), s.copied.as_ref()].into_iter().flatten().map(|c| c.id.clone()));
    ids
}

/// A waiting connection for `id` other than the session `sid` (the relay's or the go-between's meanwhile).
fn waiting_other(s: &State, id: &str, sid: u64) -> bool {
    [s.relays.get(id), s.fallbacks.get(id)].into_iter().flatten().any(|r| r.sid != sid)
}

fn relay_address(s: &crate::store::Settings) -> Option<String> {
    s.relay.clone().flatten().and_then(|a| relay::address(&a))
}

type Opening = (String, Vec<u8>, [u8; 32], Option<Vec<u8>>);

/// A connection's reader state.
struct Conn {
    chan: Arc<Chan>,
    reader: FrameReader,
    inn: Option<crypto::SealIn>,
    /// (id, the paired key used, transcript, commitment): checked when the first sealed frame comes
    opened_with: Option<Opening>,
    answered: bool,
    opened: bool,
    refused: bool,
    /// counted against MAX_HANDSHAKES (local connections, until they open)
    counted: bool,
    since: Instant,
}

impl Conn {
    fn new(chan: Arc<Chan>) -> Conn {
        Conn { chan, reader: FrameReader::default(), inn: None, opened_with: None, answered: false, opened: false, refused: false, counted: true, since: Instant::now() }
    }

    /// Six seconds to finish the handshake. A waiting relay connection has no limit until a phone says hello on it.
    fn deadline(&self) -> Option<tokio::time::Instant> {
        if self.opened || (self.chan.standby && !self.answered) {
            return None;
        }
        Some(tokio::time::Instant::from_std(self.since + HANDSHAKE_TIME))
    }
}

async fn write_tcp(mut w: tokio::net::tcp::OwnedWriteHalf, mut rx: mpsc::UnboundedReceiver<Out>, frames_out: Arc<AtomicUsize>) {
    while let Some(o) = rx.recv().await {
        match o {
            Out::Frame { bytes, video } => {
                let r = w.write_all(&bytes).await;
                if video {
                    frames_out.fetch_sub(1, SeqCst);
                }
                if r.is_err() {
                    break;
                }
            }
            Out::Ping => {}
            Out::Last(b) => {
                let _ = w.write_all(&b).await;
                break;
            }
            Out::Close => break,
        }
    }
    let _ = w.shutdown().await;
}

async fn write_ws(
    mut w: futures_util::stream::SplitSink<relay::Socket, Message>,
    mut rx: mpsc::UnboundedReceiver<Out>,
    frames_out: Arc<AtomicUsize>,
) {
    while let Some(o) = rx.recv().await {
        match o {
            Out::Frame { bytes, video } => {
                let r = w.send(Message::Binary(bytes.into())).await;
                if video {
                    frames_out.fetch_sub(1, SeqCst);
                }
                if r.is_err() {
                    break;
                }
            }
            Out::Ping => {
                let _ = w.send(Message::Ping(Vec::new().into())).await;
            }
            Out::Last(b) => {
                let _ = w.send(Message::Binary(b.into())).await;
                break;
            }
            Out::Close => break,
        }
    }
    let _ = w.close().await;
}

/// Both stacks on one socket: IPv4 phones arrive as mapped addresses.
fn bind_tcp(port: u16) -> std::io::Result<TcpListener> {
    let s = socket2::Socket::new(socket2::Domain::IPV6, socket2::Type::STREAM, Some(socket2::Protocol::TCP))?;
    let _ = s.set_only_v6(false);
    #[cfg(not(windows))]
    s.set_reuse_address(true)?;
    s.bind(&SocketAddr::new(IpAddr::V6(Ipv6Addr::UNSPECIFIED), port).into())?;
    s.listen(64)?;
    s.set_nonblocking(true)?;
    TcpListener::from_std(s.into())
}

fn bind_udp() -> std::io::Result<UdpSocket> {
    let s = socket2::Socket::new(socket2::Domain::IPV6, socket2::Type::DGRAM, Some(socket2::Protocol::UDP))?;
    let _ = s.set_only_v6(false);
    // a keyframe is a hundred datagrams at once: room for them (macOS starts at 9 KB)
    let _ = s.set_send_buffer_size(4 << 20);
    let _ = s.set_recv_buffer_size(1 << 20);
    mark_for_wifi(&s);
    s.bind(&SocketAddr::new(IpAddr::V6(Ipv6Addr::UNSPECIFIED), 0).into())?;
    s.set_nonblocking(true)?;
    UdpSocket::from_std(s.into())
}

/// The picture, the pointer's place and probe echoes go in Wi-Fi's video queue (docs/design/remote-realtime.md §6, §Host 9): DSCP
/// AF41 (0x88 in the TOS byte; 34 → VI by RFC 8325 and by DSCP ÷ 8) on IPv4 and IPv6, and on Linux SO_PRIORITY 5, so the host's
/// own radio uses VI where its driver ignores DSCP (0–6 need no capability). Windows ignores IP_TOS (qWAVE would be needed).
fn mark_for_wifi(s: &socket2::Socket) {
    #[cfg(not(windows))]
    {
        let _ = s.set_tos_v4(0x88);
        #[cfg(any(target_os = "linux", target_os = "macos"))]
        let _ = s.set_tclass_v6(0x88);
        #[cfg(target_os = "linux")]
        let _ = s.set_priority(5);
    }
    #[cfg(windows)]
    let _ = s;
}

/// DNS-SD: instance name = the computer's name, TXT id = this host's id.
fn advertise(name: &str, id: &str, port: u16) -> Option<(mdns_sd::ServiceDaemon, String)> {
    let d = mdns_sd::ServiceDaemon::new().ok()?;
    let host = gethostname::gethostname().to_string_lossy().chars().filter(|c| c.is_ascii_alphanumeric() || *c == '-').collect::<String>();
    let host = if host.is_empty() { "blurt".to_string() } else { host };
    let info = mdns_sd::ServiceInfo::new(&format!("{SERVICE_TYPE}.local."), name, &format!("{host}.local."), "", port, &[("id", id)][..])
        .ok()?
        .enable_addr_auto();
    let full = info.get_fullname().to_string();
    d.register(info).ok()?;
    Some((d, full))
}

/// The computer's name as people see it.
pub fn computer_name() -> String {
    // Linux: the name set in Settings → About (hostnamectl's pretty name) first
    #[cfg(target_os = "linux")]
    if let Some(n) = std::fs::read_to_string("/etc/machine-info").ok().and_then(|t| pretty_hostname(&t)) {
        return n;
    }
    short_host(&gethostname::gethostname().to_string_lossy())
}

/// The host name without its domain: a cloud machine's `vm.zone.c.project.internal` or a LAN's `pc.local` reads as `vm`, `pc`.
fn short_host(h: &str) -> String {
    let h = h.split('.').next().unwrap_or("").trim();
    if h.is_empty() { "Computer".into() } else { h.into() }
}

#[cfg(any(target_os = "linux", test))]
fn pretty_hostname(machine_info: &str) -> Option<String> {
    let v = machine_info.lines().find_map(|l| l.strip_prefix("PRETTY_HOSTNAME="))?.trim();
    let v = v.trim_matches(|c| c == '"' || c == '\'').trim();
    (!v.is_empty()).then(|| v.to_string())
}

#[cfg(test)]
mod name_tests {
    #[test]
    fn a_computers_name_drops_its_domain() {
        assert_eq!(super::short_host("blurt-linux2.asia-southeast1-b.c.ordo-platform.internal"), "blurt-linux2");
        assert_eq!(super::short_host("Studio.local"), "Studio");
        assert_eq!(super::short_host("DESKTOP-4F2K"), "DESKTOP-4F2K");
        assert_eq!(super::short_host(""), "Computer");
        assert_eq!(super::pretty_hostname("PRETTY_HOSTNAME=\"Ana's ThinkPad\"\nICON_NAME=computer"), Some("Ana's ThinkPad".into()));
        assert_eq!(super::pretty_hostname("ICON_NAME=computer"), None);
    }
}
