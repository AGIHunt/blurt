//! The viewer: this computer showing and driving another that runs Blurt (docs/design/remote-desktop-viewer.md). To the host it is
//! one more paired device, like a phone: the same pairing, the same paths, the same picture and input messages, plus what the
//! wire gives a viewer (`hello.features` "viewer", the clipboard, `keysCaptured`, `screen.window`). It grows out of the test phone
//! (phone.rs), which already does the handshake, every path and the move onto the direct path.
//!
//!  • `Computers`: the computers this one may drive (`computers.json` beside the host's files) and each one's key, in the app's
//!    secret store as `computer-<host id>`.
//!  • `browse`: computers nearby, by DNS-SD `_blurt-remote._tcp` (TXT id = the host's id). A host advertises only while it has a
//!    paired device or shows a code.
//!  • `pair`: with a pairing link (`blurtremote://pair?…`, from the host's Add Device) or with a computer found nearby (no code:
//!    `pairing::nearby_key`, which a host takes only over its own TCP port). Either way the host asks its owner for a yes and both
//!    ends show the same six digits.
//!  • `Session`: one window's connection, kept up while the window is open (connecting again after a drop), with the picture's
//!    receiver (repair.rs) and its reports and pings, frames handed on as Annex B with the WebCodecs codec string, and whatever the
//!    host says as `Event`s.

use std::net::{IpAddr, SocketAddr};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering::SeqCst};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};
use tokio::sync::mpsc;

use crate::packets::{unpack_payload, PointerPacket, VideoPacket};
use crate::pairing::Pairing;
use crate::phone::{Event as PhoneEvent, Options, Phone};
use crate::repair::{Output, Receiver};
use crate::store::{now_ms, KeyStore};
use crate::wire::{Display, PixelSize, ScreenReport, ScreenRequest, SessionInfo, ToMac, ToPhone};

// ------------------------------------------------------------------ the computers this one may drive

/// A computer this one is paired with (`computers.json`). Its key is in the secret store, not here.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Computer {
    /// the host's id (the pairing link's `mac`, its DNS-SD TXT id): finds it again under any name or address
    pub host_id: String,
    pub name: String,
    /// "mac", "windows" or "linux", once a session has said
    #[serde(default)]
    pub platform: Option<String>,
    /// this computer's id at that host
    pub device_id: String,
    /// the host's TCP port
    pub port: u16,
    /// where it was last reachable: the link's addresses, then the last session's candidates
    #[serde(default)]
    pub addresses: Vec<String>,
    /// its relay: the owner's, or the public connection service (from the link's `r=` or `session.relay`)
    #[serde(default)]
    pub relay: Option<String>,
    /// unix ms
    pub added: i64,
    #[serde(default)]
    pub last_seen: Option<i64>,
    /// the path its last session was on (the list says it rather than guessing from the relay it knows)
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_route: Option<Route>,
    /// the host removed this computer, said in a session it had opened: its key is gone, and it has to be added again (the Mac's
    /// `RemoteComputer.removed`; absent in records from before 1.1)
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub removed: bool,
    /// the owner's own name for it (double-click the name, or ⋯ → Rename…; remote-1.1.md §6): shown in `name`'s place, kept when
    /// a session names it again and when it is paired again, never sent; `host_id` is never touched. Lists from before have none.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub alias: Option<String>,
}

impl Computer {
    /// What this computer calls it: the owner's name for it, else the one its sessions give.
    pub fn shown(&self) -> &str {
        self.alias.as_deref().unwrap_or(&self.name)
    }
}

pub struct Computers {
    dir: PathBuf,
    keys: Arc<dyn KeyStore>,
    lock: Mutex<()>,
}

fn key_name(host_id: &str) -> String {
    format!("computer-{host_id}")
}

impl Computers {
    pub fn new(dir: impl Into<PathBuf>, keys: Arc<dyn KeyStore>) -> Computers {
        Computers {
            dir: dir.into(),
            keys,
            lock: Mutex::new(()),
        }
    }

    fn path(&self) -> PathBuf {
        self.dir.join("computers.json")
    }

    fn read(&self) -> Vec<Computer> {
        std::fs::read(self.path())
            .ok()
            .and_then(|b| serde_json::from_slice(&b).ok())
            .unwrap_or_default()
    }

    pub fn list(&self) -> Vec<Computer> {
        let _g = self.lock.lock().unwrap();
        self.read()
    }

    fn save(&self, list: &[Computer]) {
        if let Ok(b) = serde_json::to_vec_pretty(list) {
            let _ = std::fs::create_dir_all(&self.dir);
            let tmp = self.path().with_extension("tmp");
            if std::fs::write(&tmp, b).is_ok() {
                let _ = std::fs::rename(tmp, self.path());
            }
        }
    }

    pub fn get(&self, host_id: &str) -> Option<Computer> {
        self.list().into_iter().find(|c| c.host_id == host_id)
    }

    pub fn key(&self, host_id: &str) -> Option<Vec<u8>> {
        self.keys.get(&key_name(host_id))
    }

    /// Paired (again): the key first, so a computer is never listed without one. Paired again, it keeps the name given it here.
    pub fn add(&self, mut c: Computer, key: &[u8]) -> Result<(), String> {
        self.keys.put(&key_name(&c.host_id), key)?;
        let _g = self.lock.lock().unwrap();
        let mut list = self.read();
        if c.alias.is_none() {
            c.alias = list.iter().find(|x| x.host_id == c.host_id).and_then(|x| x.alias.clone());
        }
        list.retain(|x| x.host_id != c.host_id);
        list.push(c);
        self.save(&list);
        Ok(())
    }

    pub fn update(&self, host_id: &str, f: impl FnOnce(&mut Computer)) {
        let _g = self.lock.lock().unwrap();
        let mut list = self.read();
        if let Some(c) = list.iter_mut().find(|c| c.host_id == host_id) {
            f(c);
            self.save(&list);
        }
    }

    /// The owner's own name for it; empty (or its own name) goes back to the name its sessions give. Nothing is sent to it.
    pub fn rename(&self, host_id: &str, name: &str) {
        self.update(host_id, |c| c.alias = crate::store::alias(name, &c.name));
    }

    /// The host removed this computer in a session: the key goes, the record stays, marked, so the list can offer Add Again.
    pub fn mark_removed(&self, host_id: &str) {
        self.keys.delete(&key_name(host_id));
        self.update(host_id, |c| c.removed = true);
    }

    pub fn remove(&self, host_id: &str) {
        self.keys.delete(&key_name(host_id));
        let _g = self.lock.lock().unwrap();
        let mut list = self.read();
        list.retain(|c| c.host_id != host_id);
        self.save(&list);
    }
}

// ------------------------------------------------------------------ nearby

/// A computer on this network, from DNS-SD.
#[derive(Clone, Debug, PartialEq)]
pub struct Found {
    pub host_id: String,
    pub name: String,
    pub addresses: Vec<IpAddr>,
    pub port: u16,
}

/// Browsing stops when this is dropped.
pub struct Browser {
    stop: Arc<AtomicBool>,
}

impl Drop for Browser {
    fn drop(&mut self) {
        self.stop.store(true, SeqCst);
    }
}

/// DNS-SD escapes in an instance name ("Studio\032PC") back to text.
fn instance_name(full: &str) -> String {
    let raw = full.split("._blurt-remote").next().unwrap_or(full);
    let b = raw.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'\\' {
            if let Some(n) = raw
                .get(i + 1..i + 4)
                .and_then(|d| d.parse::<u8>().ok())
                .filter(|_| b.len() >= i + 4)
            {
                out.push(n);
                i += 4;
                continue;
            }
            if i + 1 < b.len() {
                out.push(b[i + 1]);
                i += 2;
                continue;
            }
        }
        out.push(b[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// Computers nearby, as they come and go (`on` gets the whole list each time). `own_id`: this computer's own host id, left out.
pub fn browse(
    own_id: Option<String>,
    on: Arc<dyn Fn(Vec<Found>) + Send + Sync>,
) -> Option<Browser> {
    let d = mdns_sd::ServiceDaemon::new().ok()?;
    let rx = d
        .browse(&format!("{}.local.", crate::pairing::SERVICE_TYPE))
        .ok()?;
    let stop = Arc::new(AtomicBool::new(false));
    let s2 = stop.clone();
    std::thread::Builder::new()
        .name("blurt-viewer-browse".into())
        .spawn(move || {
            let mut found: Vec<(String, Found)> = vec![];
            while !s2.load(SeqCst) {
                let Ok(ev) = rx.recv_timeout(Duration::from_millis(300)) else {
                    continue;
                };
                let changed = match ev {
                    mdns_sd::ServiceEvent::ServiceResolved(info) => {
                        let Some(id) = info.get_property_val_str("id").map(str::to_string) else {
                            continue;
                        };
                        if own_id.as_deref() == Some(id.as_str()) {
                            continue;
                        }
                        let full = info.get_fullname().to_string();
                        let mut addresses: Vec<IpAddr> =
                            info.get_addresses().iter().copied().collect();
                        addresses.sort_by_key(|a| (!a.is_ipv4(), *a));
                        let f = Found {
                            host_id: id,
                            name: instance_name(&full),
                            addresses,
                            port: info.get_port(),
                        };
                        found.retain(|(n, x)| *n != full && x.host_id != f.host_id);
                        found.push((full, f));
                        true
                    }
                    mdns_sd::ServiceEvent::ServiceRemoved(_, full) => {
                        let n = found.len();
                        found.retain(|(f, _)| *f != full);
                        n != found.len()
                    }
                    _ => false,
                };
                if changed {
                    on(found.iter().map(|(_, f)| f.clone()).collect());
                }
            }
            let _ = d.shutdown();
        })
        .ok()?;
    Some(Browser { stop })
}

// ------------------------------------------------------------------ the ways to a computer

/// The path a session is on, as the host names it (server.rs `Connected.route`; the toolbar's words: copy.md).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Route {
    Local,
    Tailscale,
    Overlay,
    Direct,
    Relay,
    GoBetween,
}

/// The first TCP connection to open, of these, each given `each`.
async fn tcp_first(
    addrs: Vec<SocketAddr>,
    each: Duration,
) -> Option<(SocketAddr, tokio::net::TcpStream)> {
    use futures_util::StreamExt;
    let mut tries: futures_util::stream::FuturesUnordered<_> = addrs
        .into_iter()
        .map(|a| async move {
            (
                a,
                tokio::time::timeout(each, tokio::net::TcpStream::connect(a)).await,
            )
        })
        .collect();
    while let Some((a, r)) = tries.next().await {
        if let Ok(Ok(s)) = r {
            return Some((a, s));
        }
    }
    None
}

fn targets(addresses: &[String], extra: &[IpAddr], port: u16) -> Vec<SocketAddr> {
    let mut out: Vec<SocketAddr> = extra.iter().map(|ip| SocketAddr::new(*ip, port)).collect();
    for a in addresses {
        if let Ok(ip) = a.parse::<IpAddr>() {
            let t = SocketAddr::new(ip, port);
            if !out.contains(&t) {
                out.push(t);
            }
        }
    }
    out
}

fn tcp_route(a: SocketAddr) -> Route {
    match crate::relay::overlay_of(a.ip(), "") {
        Some(crate::relay::Overlay::Tailscale) => Route::Tailscale,
        Some(_) => Route::Overlay,
        None => Route::Local,
    }
}

/// Why a connection didn't open.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Unreached {
    /// nothing answered on any path
    Offline,
    /// the public connection service is over today's limit (HTTP 429 or the like)
    Busy,
    /// it answered and refused this computer's key: removed there, or a code gone stale
    NotPaired,
    /// the computer's own relay doesn't answer (2026-11-20, the office)
    RelayDown,
}

fn options(device: &str, go_between: bool) -> Options {
    Options {
        features: Some(vec![
            crate::wire::MOVE.to_string(),
            crate::wire::VIEWER.to_string(),
        ]),
        go_between,
        device: device.to_string(),
    }
}

fn is_go_between(relay: &str) -> bool {
    crate::relay::address(relay).as_deref() == Some(crate::relay::GO_BETWEEN)
}

/// The host turned this key away: `not_paired`, or (an id from a nearby pairing it has since removed) a proof made with the
/// nearby key.
fn refused(e: &str) -> bool {
    e.contains("NotPaired") || e.contains("not_paired") || e.contains("BadProof")
}

/// Opens a session with the host by the first path that works, in the phone's order: the same network (and overlays) over TCP,
/// then its relay or the public connection service. → the phone end, and the path. `go_between_at`: tests point the public
/// connection service at a local relay.
#[allow(clippy::too_many_arguments)]
pub async fn open(
    device: &str,
    id: &str,
    key: &[u8],
    port: u16,
    addresses: &[String],
    nearby: &[IpAddr],
    relay: Option<&str>,
    go_between_at: Option<&str>,
) -> Result<(Phone, Route), Unreached> {
    open_with(device, id, key, port, addresses, nearby, relay, go_between_at, false).await
}

/// `fallback`: the computer's own relay has been down; when it still doesn't answer, the public connection service is tried, where its
/// host waits meanwhile.
#[allow(clippy::too_many_arguments)]
pub async fn open_with(
    device: &str,
    id: &str,
    key: &[u8],
    port: u16,
    addresses: &[String],
    nearby: &[IpAddr],
    relay: Option<&str>,
    go_between_at: Option<&str>,
    fallback: bool,
) -> Result<(Phone, Route), Unreached> {
    let tcp = targets(addresses, nearby, port);
    if let Some((a, s)) = tcp_first(tcp, Duration::from_millis(1500)).await {
        return match Phone::over_tcp(s, a, id, key, options(device, false)).await {
            Ok(p) => Ok((p, tcp_route(a))),
            Err(e) if refused(&e) => Err(Unreached::NotPaired),
            Err(_) => Err(Unreached::Offline),
        };
    }
    let Some(r) = relay else {
        return Err(Unreached::Offline);
    };
    let mut meet = is_go_between(r)
        || go_between_at.is_some_and(|g| crate::relay::address(g) == crate::relay::address(r));
    let mut fell_back = false;
    let address = if is_go_between(r) {
        go_between_at.unwrap_or(r)
    } else {
        r
    };
    let ws = match crate::relay::connect(address, &crate::relay::room(key), "phone").await {
        Ok(ws) => ws,
        Err(crate::relay::ConnectError::Refused(_)) if meet => return Err(Unreached::Busy),
        Err(_) if meet => return Err(Unreached::Offline),
        Err(_) if !fallback => return Err(Unreached::RelayDown),
        Err(_) => {
            meet = true;
            fell_back = true;
            match crate::relay::connect(go_between_at.unwrap_or(crate::relay::GO_BETWEEN), &crate::relay::room(key), "phone").await {
                Ok(ws) => ws,
                Err(crate::relay::ConnectError::Refused(_)) => return Err(Unreached::Busy),
                Err(_) => return Err(Unreached::RelayDown),
            }
        }
    };
    match Phone::over_ws(ws, id, key, options(device, meet)).await {
        Ok(p) => Ok((p, if meet { Route::GoBetween } else { Route::Relay })),
        Err(e) if refused(&e) => Err(Unreached::NotPaired),
        Err(_) if fell_back => Err(Unreached::RelayDown),
        // the room was empty: the host isn't waiting there (asleep, off, or not connected)
        Err(_) => Err(Unreached::Offline),
    }
}

// ------------------------------------------------------------------ pairing

pub enum PairWith {
    Link(Pairing),
    Nearby(Found),
}

/// How a pairing ended without a key. The host never says which (a bare close, or a refused handshake), so it's read from when
/// (the Mac's `RemoteViewerLink.PairingFailure`, docs/design/remote-desktop-viewer.md §When it doesn't pair):
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum PairError {
    /// nothing answered (the link's addresses and relay, or the nearby computer); only from `pair`, which tries once
    Unreachable,
    /// refused before anyone was asked: a link's code ran out or was used already; nearby, the host isn't taking a new computer
    /// now (it's asking about another, or was just told no), or it's an older host that doesn't pair nearby
    Spent,
    /// the question was asked and the host let go: its owner said no
    Declined,
    /// the question was asked and nobody answered: the host gives up after its two minutes
    Unanswered,
}

/// What a pairing that keeps trying (`pair_steps`) says on the way.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum PairStep {
    /// nothing has answered for a while; still trying
    Unreachable,
    /// the host asks its owner now, with these six digits (whatever was said before: they take its place)
    Asking(String),
}

/// How long a host asks its owner about a new device before it takes the silence as a no (server.rs `PAIRING_LIFE`): a close
/// this late, 90 % of it or more, is "nobody answered", not "no".
pub const QUESTION_LIFE: Duration = Duration::from_secs(120);
/// Unreachable is said once nothing has answered for this long (the Mac's 8 s).
const UNREACHABLE_AFTER: Duration = Duration::from_secs(8);

/// Pairs with a computer: connects, shows the six digits (`digits`) while the host asks its owner, and once the owner says yes
/// keeps the new key. → the computer and its key (the caller stores both: `Computers::add`). Tries once. `go_between_at`: tests
/// only.
pub async fn pair(
    with: PairWith,
    device: &str,
    go_between_at: Option<&str>,
    digits: impl Fn(&str),
) -> Result<(Computer, Vec<u8>), PairError> {
    pair_steps(with, device, go_between_at, QUESTION_LIFE, false, |s| {
        if let PairStep::Asking(d) = s {
            digits(&d)
        }
    })
    .await
}

/// `pair`, for the Add Computer panel. `keep_trying`: while nothing answers it says `Unreachable` and goes on trying, so if the
/// host turns up and asks, its digits replace that (the caller ends it by dropping or aborting the future). `question_life`: the
/// host's (tests shorten it).
pub async fn pair_steps(
    with: PairWith,
    device: &str,
    go_between_at: Option<&str>,
    question_life: Duration,
    keep_trying: bool,
    step: impl Fn(PairStep),
) -> Result<(Computer, Vec<u8>), PairError> {
    let (host_id, name, device_id, key, port, addresses, nearby, relay) = match with {
        PairWith::Link(p) => (
            p.host_id,
            p.name,
            p.device_id,
            p.key,
            p.port,
            p.addresses,
            vec![],
            p.relay,
        ),
        PairWith::Nearby(f) => (
            f.host_id,
            f.name,
            crate::pairing::nearby_id(),
            crate::pairing::nearby_key().to_vec(),
            f.port,
            vec![],
            f.addresses,
            None,
        ),
    };
    let started = tokio::time::Instant::now();
    let mut said_unreachable = false;
    let (mut phone, route) = loop {
        match open(
            device,
            &device_id,
            &key,
            port,
            &addresses,
            &nearby,
            relay.as_deref(),
            go_between_at,
        )
        .await
        {
            Ok(x) => break x,
            Err(Unreached::NotPaired) => return Err(PairError::Spent),
            Err(_) if !keep_trying => return Err(PairError::Unreachable),
            Err(e) => {
                if !said_unreachable && started.elapsed() >= UNREACHABLE_AFTER {
                    said_unreachable = true;
                    step(PairStep::Unreachable);
                }
                // a public connection service over its limit isn't asked again at once
                let wait = if e == Unreached::Busy { 15 } else { 2 };
                tokio::time::sleep(Duration::from_secs(wait)).await;
            }
        }
    };
    // the host gives up on its question after `question_life`; this side, a little later
    let patience = question_life + question_life / 12;
    let mut asked: Option<tokio::time::Instant> = None;
    let mut deadline = tokio::time::Instant::now() + patience;
    let new_key = loop {
        let left = deadline.saturating_duration_since(tokio::time::Instant::now());
        match phone.next(left.min(Duration::from_secs(1))).await {
            Some(PhoneEvent::Control(ToPhone::PairingWaits)) => {
                let now = tokio::time::Instant::now();
                asked = Some(now);
                deadline = now + patience;
                step(PairStep::Asking(phone.check.clone()));
            }
            Some(PhoneEvent::Control(ToPhone::NewKey(k))) => break k,
            Some(PhoneEvent::Closed) => {
                return Err(match asked {
                    None => PairError::Spent,
                    Some(t) if t.elapsed() >= question_life.mul_f64(0.9) => PairError::Unanswered,
                    Some(_) => PairError::Declined,
                })
            }
            Some(_) => {}
            None if tokio::time::Instant::now() >= deadline => {
                return Err(if asked.is_some() {
                    PairError::Unanswered
                } else {
                    PairError::Unreachable
                })
            }
            None => {}
        }
    };
    if new_key.len() != 32 {
        return Err(PairError::Spent);
    }
    phone.send(&ToMac::KeyStored).await;
    let info = phone
        .wait(Duration::from_secs(8), |m| {
            if let ToPhone::Session(i) = m {
                Some(i.clone())
            } else {
                None
            }
        })
        .await
        .ok_or(PairError::Declined)?;
    let mut addresses = addresses;
    addresses.extend(nearby.iter().map(|a| a.to_string()));
    remember_candidates(&mut addresses, &info);
    let c = Computer {
        host_id,
        name: if info.mac_name.is_empty() {
            name
        } else {
            info.mac_name.clone()
        },
        platform: info.platform.clone(),
        device_id,
        port,
        addresses,
        relay: info.relay.clone().or(relay),
        added: now_ms(),
        last_seen: Some(now_ms()),
        last_route: Some(route),
        removed: false,
        alias: None,
    };
    phone.send(&ToMac::ReleaseAll).await;
    Ok((c, new_key))
}

/// The session's candidates, kept for the next time, at most 8 (what was known first stays first).
pub fn remember_candidates(addresses: &mut Vec<String>, info: &SessionInfo) {
    for c in &info.candidates {
        if !addresses.contains(&c.host) {
            addresses.push(c.host.clone());
        }
    }
    addresses.retain(|a| a.parse::<IpAddr>().is_ok());
    addresses.truncate(8);
}

// ------------------------------------------------------------------ the picture

/// One frame for the decoder: Annex B, with its parameter sets in front of a keyframe, and the WebCodecs codec string.
#[derive(Clone, Debug, PartialEq)]
pub struct VideoFrame {
    pub id: u32,
    pub keyframe: bool,
    /// "h264" or "hevc"
    pub family: String,
    /// "avc1.640028", "hev1.1.6.L120.90": from the last keyframe's SPS
    pub codec: String,
    pub data: Vec<u8>,
    /// the host's clock when it was composed (seconds)
    pub captured: f64,
}

/// NAL units with 4-byte lengths (and bare parameter sets) → Annex B with 4-byte start codes. A length past the end ends it.
pub fn annex_b(parameter_sets: &[Vec<u8>], picture: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(
        picture.len() + parameter_sets.iter().map(|p| p.len() + 4).sum::<usize>(),
    );
    for p in parameter_sets {
        out.extend_from_slice(&[0, 0, 0, 1]);
        out.extend_from_slice(p);
    }
    let mut at = 0;
    while at + 4 <= picture.len() {
        let n = u32::from_be_bytes(picture[at..at + 4].try_into().unwrap()) as usize;
        at += 4;
        let Some(nal) = picture.get(at..at + n) else {
            break;
        };
        out.extend_from_slice(&[0, 0, 0, 1]);
        out.extend_from_slice(nal);
        at += n;
    }
    out
}

fn unescape_rbsp(b: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(b.len());
    let mut zeros = 0;
    for &x in b {
        if zeros >= 2 && x == 3 {
            zeros = 0;
            continue;
        }
        zeros = if x == 0 { zeros + 1 } else { 0 };
        out.push(x);
    }
    out
}

/// The WebCodecs codec string for a stream, from its parameter sets (RFC 6381; ISO/IEC 14496-15 Annex E for HEVC).
pub fn codec_string(family: &str, parameter_sets: &[Vec<u8>]) -> Option<String> {
    if family == "h264" {
        let sps = parameter_sets
            .iter()
            .find(|p| p.first().is_some_and(|b| b & 0x1f == 7) && p.len() >= 4)?;
        return Some(format!("avc1.{:02X}{:02X}{:02X}", sps[1], sps[2], sps[3]));
    }
    let sps = parameter_sets
        .iter()
        .find(|p| p.first().is_some_and(|b| (b >> 1) & 0x3f == 33) && p.len() >= 3)?;
    let r = unescape_rbsp(&sps[2..]);
    if r.len() < 13 {
        return None;
    }
    // r[0]: vps id, sub layers, nesting; r[1..13]: profile_tier_level's general part
    let space = r[1] >> 6;
    let tier = (r[1] >> 5) & 1;
    let profile = r[1] & 0x1f;
    let compat = u32::from_be_bytes(r[2..6].try_into().unwrap()).reverse_bits();
    let constraints = &r[6..12];
    let level = r[12];
    let mut s = format!(
        "hev1.{}{}.{:X}.{}{}",
        ["", "A", "B", "C"][space as usize],
        profile,
        compat,
        if tier == 1 { 'H' } else { 'L' },
        level
    );
    if let Some(last) = constraints.iter().rposition(|b| *b != 0) {
        for b in &constraints[..=last] {
            s.push_str(&format!(".{b:X}"));
        }
    }
    Some(s)
}

/// Picture quality, the phone's four (ScreenPlan.swift): one choice instead of a size, a rate and a bitrate.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Quality {
    Auto,
    Sharp,
    Balanced,
    Saver,
}

/// The request's ceilings for a viewer, as the phone's: the window is the size (the host fits the display's shape into it and
/// never sends more than the display has), the rate and frames as the phone asks on that path. → (width, height, bitrate, fps).
pub fn plan(q: Quality, away: bool, window: (i64, i64)) -> (i64, i64, i64, i64) {
    let (w, h) = (window.0.max(64), window.1.max(64));
    let tier = if q == Quality::Auto {
        if away {
            Quality::Balanced
        } else {
            Quality::Sharp
        }
    } else {
        q
    };
    match tier {
        Quality::Saver => (w.min(1280), h.min(800), 1_000_000, 15),
        Quality::Sharp if !away => (w, h, 12_000_000, 60),
        Quality::Sharp => (w, h, 8_000_000, 30),
        _ => {
            // as the phone's Balanced: 4 Mbps for 1800 × 1100, up to 8
            let (bw, bh) = (w.min(2560), h.min(1600));
            (
                bw,
                bh,
                (bw * bh * 4_000_000 / (1800 * 1100)).clamp(4_000_000, 8_000_000),
                30,
            )
        }
    }
}

// ------------------------------------------------------------------ a session

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Link {
    Connecting,
    Connected,
    /// no path answered; tried again soon
    Offline,
    /// the public connection service is over today's limit
    Busy,
    /// the direct path didn't open on the public connection service
    NoDirect,
    /// the computer's own relay doesn't answer (the public connection service is tried meanwhile)
    RelayDown,
    /// the host removed this computer, said in a session it had opened: so it is (the key can go)
    Removed,
    /// the host refused this computer's key, with no session: it may have removed it, or never had it, but anyone on the network
    /// can send a refusal, so the key is kept
    Forgotten,
    /// another device took over there
    Replaced,
    /// the person at the computer ended the session
    Ended,
}

#[derive(Clone, Debug)]
pub enum Event {
    Link {
        link: Link,
        route: Option<Route>,
    },
    /// the round trip, ms (from ping and pong)
    Rtt(f64),
    Session(SessionInfo),
    Displays(Vec<Display>),
    /// what the picture shows from now on: the display's size in points, its codec, which display
    View {
        width: f64,
        height: f64,
        family: String,
        display: Option<String>,
    },
    Frame(VideoFrame),
    /// the host's pointer, 0…1 of the display shown
    Cursor {
        x: f32,
        y: f32,
    },
    CursorShape {
        png: Vec<u8>,
        hot_x: f64,
        hot_y: f64,
        width: f64,
        height: f64,
    },
    Clipboard(String),
    ScreenFailed(String),
    CanControl(bool),
    /// the host's screen locked (true) or opened again (false) where the host can't show it: the last frame stays, said so
    ScreenLocked(bool),
    /// the host's own words for this user (a new device paired there): shown as a notification
    Notice(String),
    /// a file going to the host: written so far, saved (its name there), or not ("space", "too_big", "write", "locked")
    FileProgress { id: String, bytes: i64 },
    FileSaved { id: String, name: String },
    FileFailed { id: String, why: String },
}

/// What the window asks for its picture.
#[derive(Clone, Debug, PartialEq)]
pub struct Want {
    pub quality: Quality,
    /// the picture's area in the window, in pixels
    pub window: (i64, i64),
    /// what the window decodes, best first ("hevc", "h264")
    pub codecs: Vec<String>,
    pub display: Option<String>,
}

pub enum Command {
    Send(ToMac),
    Pointer(PointerPacket),
    Screen(Option<Want>),
    /// the decoder refused a frame: a keyframe is needed
    DecodeFailed,
    Close,
}

/// Where the session finds its computer.
#[derive(Clone)]
pub struct Target {
    pub computer: Computer,
    pub key: Vec<u8>,
    /// this computer's name, as the host lists it
    pub device: String,
    /// addresses found nearby just now
    pub nearby: Vec<IpAddr>,
    /// tests: the public connection service at another address
    pub go_between_at: Option<String>,
}

/// One window's connection. Dropping it closes it.
pub struct Session {
    tx: mpsc::UnboundedSender<Command>,
}

#[derive(Clone)]
pub struct Sender(mpsc::UnboundedSender<Command>);

impl Sender {
    /// false once the session is gone
    pub fn send(&self, m: ToMac) -> bool {
        self.0.send(Command::Send(m)).is_ok()
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        let _ = self.tx.send(Command::Close);
    }
}

pub type OnEvent = Arc<dyn Fn(Event) + Send + Sync>;
pub type OnLearned = Arc<dyn Fn(&SessionInfo) + Send + Sync>;

impl Session {
    /// Starts connecting on `rt`, and stays connected (trying again after a drop) until closed. `on` gets every event, from the
    /// runtime's threads; `learned` gets what the computer said about itself (name, platform, candidates, relay) to keep.
    pub fn start(
        rt: &tokio::runtime::Handle,
        t: Target,
        on: OnEvent,
        learned: OnLearned,
    ) -> Session {
        let (tx, rx) = mpsc::unbounded_channel();
        rt.spawn(run(t, rx, on, learned));
        Session { tx }
    }

    pub fn send(&self, m: ToMac) {
        let _ = self.tx.send(Command::Send(m));
    }

    /// A handle that only sends (a file going out on a thread of its own); the session still ends with this one.
    pub fn sender(&self) -> Sender {
        Sender(self.tx.clone())
    }

    pub fn pointer(&self, p: PointerPacket) {
        let _ = self.tx.send(Command::Pointer(p));
    }

    pub fn screen(&self, w: Option<Want>) {
        let _ = self.tx.send(Command::Screen(w));
    }

    pub fn decode_failed(&self) {
        let _ = self.tx.send(Command::DecodeFailed);
    }

    pub fn close(&self) {
        let _ = self.tx.send(Command::Close);
    }
}

const RETRY: [u64; 5] = [1, 2, 4, 8, 15];

async fn run(
    mut t: Target,
    mut rx: mpsc::UnboundedReceiver<Command>,
    on: OnEvent,
    learned: OnLearned,
) {
    let mut want: Option<Want> = None;
    let mut tries = 0u32;
    // the computer's own relay failed this many times in a row: from 2, the public connection service is tried too
    let mut relay_fails = 0u32;
    loop {
        on(Event::Link {
            link: Link::Connecting,
            route: None,
        });
        let c = t.computer.clone();
        let opened = tokio::select! {
            r = open_with(&t.device, &c.device_id, &t.key, c.port, &c.addresses, &t.nearby, c.relay.as_deref(), t.go_between_at.as_deref(),
                relay_fails >= 2) => r,
            _ = closed(&mut rx, &mut want) => return,
        };
        let wait = match opened {
            Ok((phone, route)) => {
                tries = 0;
                if route == Route::Relay {
                    relay_fails = 0;
                }
                match live(phone, route, &mut rx, &mut want, &on, &learned, &mut t).await {
                    End::Closed => return,
                    End::Removed => {
                        on(Event::Link {
                            link: Link::Removed,
                            route: None,
                        });
                        return;
                    }
                    End::Replaced => {
                        on(Event::Link {
                            link: Link::Replaced,
                            route: None,
                        });
                        return;
                    }
                    End::Ended => {
                        on(Event::Link {
                            link: Link::Ended,
                            route: None,
                        });
                        return;
                    }
                    End::NoDirect => {
                        on(Event::Link {
                            link: Link::NoDirect,
                            route: None,
                        });
                        Duration::from_secs(30)
                    }
                    End::Dropped => Duration::from_millis(500),
                }
            }
            Err(Unreached::NotPaired) => {
                on(Event::Link {
                    link: Link::Forgotten,
                    route: None,
                });
                return;
            }
            Err(Unreached::RelayDown) => {
                relay_fails += 1;
                on(Event::Link {
                    link: if relay_fails >= 2 { Link::RelayDown } else { Link::Offline },
                    route: None,
                });
                tries += 1;
                Duration::from_secs(RETRY[(tries as usize - 1).min(RETRY.len() - 1)])
            }
            Err(Unreached::Busy) => {
                on(Event::Link {
                    link: Link::Busy,
                    route: None,
                });
                tries += 1;
                crate::relay::busy_wait(tries)
            }
            Err(Unreached::Offline) => {
                on(Event::Link {
                    link: Link::Offline,
                    route: None,
                });
                tries += 1;
                Duration::from_secs(RETRY[(tries as usize - 1).min(RETRY.len() - 1)])
            }
        };
        tokio::select! {
            _ = tokio::time::sleep(wait) => {}
            _ = closed(&mut rx, &mut want) => return,
        }
    }
}

/// Waits for Close while not connected, keeping the latest screen request for when it is.
async fn closed(rx: &mut mpsc::UnboundedReceiver<Command>, want: &mut Option<Want>) {
    loop {
        match rx.recv().await {
            None | Some(Command::Close) => return,
            Some(Command::Screen(w)) => *want = w,
            Some(_) => {}
        }
    }
}

enum End {
    Closed,
    Dropped,
    Removed,
    Replaced,
    Ended,
    NoDirect,
}

pub fn request(w: &Want, away: bool) -> ScreenRequest {
    let (width, height, bitrate, fps) = plan(w.quality, away, w.window);
    ScreenRequest {
        target: "display".into(),
        crop: crate::wire::Crop::WHOLE,
        width,
        height,
        bitrate,
        fps,
        codecs: Some(w.codecs.clone()),
        display: w.display.clone(),
        features: Some(crate::repair::ALL.iter().map(|s| s.to_string()).collect()),
        window: Some(PixelSize {
            width: w.window.0,
            height: w.window.1,
        }),
    }
}

/// What the picture needs between frames.
struct Picture {
    receiver: Receiver,
    family: String,
    codec: Option<String>,
    frames: i64,
}

async fn live(
    mut phone: Phone,
    mut route: Route,
    rx: &mut mpsc::UnboundedReceiver<Command>,
    want: &mut Option<Want>,
    on: &OnEvent,
    learned: &OnLearned,
    t: &mut Target,
) -> End {
    let t0 = Instant::now();
    let now = move || t0.elapsed().as_secs_f64();
    let tcp = matches!(route, Route::Local | Route::Tailscale | Route::Overlay);
    let mut pic = Picture {
        receiver: Receiver::new(false, false, now()),
        family: "hevc".into(),
        codec: None,
        frames: 0,
    };
    let mut asked = false;
    let mut info: Option<SessionInfo> = None;
    let (mut last_tick, mut last_ping) = (0.0, -1.0);
    let (mut received, mut dropped_told) = (0usize, 0usize);
    // UDP knocks until the host says it heard one: a first datagram can be lost (or not leave a socket that isn't writable yet)
    let (mut udp_ok, mut knocked, mut knocks) = (false, 0.0, 0);
    let mut rtt = 0.05;
    loop {
        let away = !matches!(route, Route::Local);
        tokio::select! {
            c = rx.recv() => match c {
                None | Some(Command::Close) => {
                    phone.send(&ToMac::ReleaseAll).await;
                    return End::Closed;
                }
                Some(Command::Send(m)) => phone.send(&m).await,
                Some(Command::Pointer(p)) => phone.pointer(p).await,
                Some(Command::Screen(w)) => {
                    *want = w;
                    if info.is_some() {
                        asked = want.is_some();
                        phone.send(&ToMac::Screen(want.as_ref().map(|w| request(w, away)))).await;
                    }
                }
                Some(Command::DecodeFailed) => {
                    pic.receiver.decoder_failed(now());
                    phone.send(&ToMac::RequestKeyframe).await;
                }
            },
            e = phone.next(Duration::from_millis(4)) => match e {
                None => {}
                Some(PhoneEvent::Closed) => return End::Dropped,
                Some(PhoneEvent::Video(v)) => {
                    if let Some(p) = VideoPacket::decode(&v) {
                        received += p.payload.len();
                        let outs = pic.receiver.add(p, now());
                        for o in outs {
                            out(o, &mut phone, &mut pic, on, now()).await;
                        }
                    }
                }
                Some(PhoneEvent::Cursor(x, y, _)) => on(Event::Cursor { x, y }),
                Some(PhoneEvent::Probe(_)) => {}
                Some(PhoneEvent::Control(m)) => match m {
                    ToPhone::Session(i) => {
                        learned(&i);
                        remember_candidates(&mut t.computer.addresses, &i);
                        if tcp {
                            let _ = phone.open_udp(i.udp_port, i.udp_session).await;
                        } else {
                            let _ = phone.open_direct(&i).await;
                        }
                        on(Event::Link { link: Link::Connected, route: Some(route) });
                        on(Event::Session(i.clone()));
                        info = Some(i);
                        if let Some(w) = want.as_ref() {
                            asked = true;
                            phone.send(&ToMac::Screen(Some(request(w, away)))).await;
                        }
                    }
                    ToPhone::UdpOk if tcp => udp_ok = true,
                    ToPhone::UdpOk if route != Route::Direct => {
                        udp_ok = true;
                        // the direct path is open: what the relay or the public connection service carried goes on it
                        route = Route::Direct;
                        on(Event::Link { link: Link::Connected, route: Some(route) });
                    }
                    ToPhone::Pong(sent) => {
                        rtt = (now() - sent).clamp(0.0005, 5.0);
                        pic.receiver.rtt = rtt;
                        on(Event::Rtt(rtt * 1000.0));
                    }
                    ToPhone::ScreenView { width, height, codec: c, display, features } => {
                        let has = |n: &str| features.as_ref().is_some_and(|f| f.iter().any(|x| x == n));
                        pic.receiver = Receiver::new(has(crate::repair::NACK), has(crate::repair::LTR), now());
                        pic.receiver.rtt = rtt;
                        pic.family = c.unwrap_or_else(|| "hevc".into());
                        pic.codec = None;
                        on(Event::View { width, height, family: pic.family.clone(), display });
                    }
                    ToPhone::Displays(l) => on(Event::Displays(l)),
                    ToPhone::CursorShape { png, hot_x, hot_y, width, height } => on(Event::CursorShape { png, hot_x, hot_y, width, height }),
                    ToPhone::Clipboard(t) => on(Event::Clipboard(t)),
                    ToPhone::ScreenFailed(w) => {
                        asked = false;
                        on(Event::ScreenFailed(w));
                    }
                    ToPhone::CanControl(b) => on(Event::CanControl(b)),
                    ToPhone::ScreenLocked(b) => on(Event::ScreenLocked(b)),
                    ToPhone::Notice(t) => on(Event::Notice(t)),
                    ToPhone::FileProgress { id, bytes } => on(Event::FileProgress { id, bytes }),
                    ToPhone::FileSaved { id, name } => on(Event::FileSaved { id, name }),
                    ToPhone::FileFailed { id, why } => on(Event::FileFailed { id, why }),
                    ToPhone::Removed => return End::Removed,
                    ToPhone::Replaced => return End::Replaced,
                    ToPhone::Ended => return End::Ended,
                    ToPhone::NoDirect => return End::NoDirect,
                    _ => {}
                },
            },
        }
        let n = now();
        if n - last_tick >= 0.004 {
            last_tick = n;
            let outs = pic.receiver.tick(n);
            for o in outs {
                out(o, &mut phone, &mut pic, on, n).await;
            }
        }
        if tcp && info.is_some() && !udp_ok && knocks < 40 && n - knocked >= 0.25 {
            knocked = n;
            knocks += 1;
            phone.pointer(PointerPacket::Stop).await;
        }
        if n - last_ping >= 1.0 {
            last_ping = n;
            // a ping a second keeps the session (the host lets go of held keys after 2 s of quiet)
            phone.send(&ToMac::Ping(n)).await;
            if asked {
                let lost = pic.receiver.dropped - dropped_told;
                dropped_told = pic.receiver.dropped;
                let r = ScreenReport {
                    frames: pic.frames,
                    lost: lost as i64,
                    rtt: Some(rtt),
                    received: received as i64,
                };
                phone.send(&ToMac::ScreenReport(r)).await;
                pic.frames = 0;
            }
        }
    }
}

async fn out(o: Output, phone: &mut Phone, pic: &mut Picture, on: &OnEvent, now: f64) {
    match o {
        Output::Frame(f) => {
            let Some(p) = unpack_payload(&f.data) else {
                return;
            };
            if !p.parameter_sets.is_empty() {
                if let Some(c) = codec_string(&pic.family, &p.parameter_sets) {
                    pic.codec = Some(c);
                }
            }
            let Some(c) = pic.codec.clone() else { return }; // nothing decodes before the first keyframe
            pic.frames += 1;
            on(Event::Frame(VideoFrame {
                id: f.id,
                keyframe: f.keyframe,
                family: pic.family.clone(),
                codec: c,
                data: annex_b(&p.parameter_sets, &p.picture),
                captured: f.captured,
            }));
            let more = pic.receiver.decoded(&f, now);
            for o in more {
                if let Output::Feedback(fb) = o {
                    phone.feedback(&fb).await;
                }
            }
        }
        Output::Feedback(fb) => phone.feedback(&fb).await,
        Output::Keyframe => phone.send(&ToMac::RequestKeyframe).await,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn annex_b_puts_start_codes_where_lengths_were() {
        let sets = vec![vec![0x67, 1, 2], vec![0x68, 3]];
        let pic = [0, 0, 0, 2, 0x65, 9, 0, 0, 0, 1, 0x41];
        assert_eq!(
            annex_b(&sets, &pic),
            vec![
                0, 0, 0, 1, 0x67, 1, 2, 0, 0, 0, 1, 0x68, 3, 0, 0, 0, 1, 0x65, 9, 0, 0, 0, 1, 0x41
            ]
        );
        assert_eq!(
            annex_b(&[], &[0, 0, 0, 9, 1]),
            Vec::<u8>::new(),
            "a length past the end ends it"
        );
    }

    #[test]
    fn codec_strings_from_parameter_sets() {
        // H.264 High 4.0
        assert_eq!(
            codec_string("h264", &[vec![0x67, 0x64, 0x00, 0x28, 0xac]]),
            Some("avc1.640028".into())
        );
        // HEVC Main, level 4 (120), with emulation-prevention bytes among the constraint flags
        let sps = vec![
            0x42, 0x01, 0x01, 0x01, 0x60, 0x00, 0x00, 0x03, 0x00, 0x90, 0x00, 0x00, 0x03, 0x00,
            0x00, 0x03, 0x00, 0x78, 0xa0,
        ];
        assert_eq!(
            codec_string("hevc", &[vec![0x40, 0x01, 0x0c], sps]),
            Some("hev1.1.6.L120.90".into())
        );
        assert_eq!(codec_string("h264", &[]), None);
    }

    fn split_annex_b(b: &[u8]) -> Vec<Vec<u8>> {
        let mut starts = vec![];
        let mut i = 0;
        while i + 3 <= b.len() {
            if b[i] == 0 && b[i + 1] == 0 && b[i + 2] == 1 {
                starts.push(i + 3);
                i += 3;
            } else {
                i += 1;
            }
        }
        starts
            .iter()
            .enumerate()
            .map(|(k, s)| {
                let end = starts.get(k + 1).map(|n| n - 3).unwrap_or(b.len());
                let mut v = b[*s..end].to_vec();
                while v.last() == Some(&0) {
                    v.pop(); // a 4-byte start code's leading zero
                }
                v
            })
            .collect()
    }

    #[test]
    fn the_codec_strings_of_the_recorded_streams() {
        // the Windows backend's recorded encoder output (platform/windows/testdata)
        let dir =
            std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src/platform/windows/testdata");
        for (file, family, prefix) in [
            ("screen.h264", "h264", "avc1."),
            ("screen.h265", "hevc", "hev1."),
        ] {
            let b = std::fs::read(dir.join(file)).unwrap();
            let c = codec_string(family, &split_annex_b(&b)).unwrap_or_else(|| panic!("{file}"));
            assert!(c.starts_with(prefix), "{c}");
            eprintln!("{file}: {c}");
        }
    }

    #[test]
    fn the_window_is_the_ceiling_and_rates_are_the_phones() {
        assert_eq!(
            plan(Quality::Auto, false, (2400, 1500)),
            (2400, 1500, 12_000_000, 60)
        );
        assert_eq!(
            plan(Quality::Auto, true, (1800, 1100)),
            (1800, 1100, 4_000_000, 30)
        );
        assert_eq!(plan(Quality::Auto, true, (3000, 2000)).2, 8_000_000);
        assert_eq!(
            plan(Quality::Saver, false, (3000, 2000)),
            (1280, 800, 1_000_000, 15)
        );
        assert_eq!(
            plan(Quality::Sharp, true, (3000, 2000)),
            (3000, 2000, 8_000_000, 30)
        );
        let r = request(
            &Want {
                quality: Quality::Auto,
                window: (1600, 1000),
                codecs: vec!["h264".into()],
                display: None,
            },
            false,
        );
        assert_eq!(
            r.window,
            Some(PixelSize {
                width: 1600,
                height: 1000
            })
        );
        assert_eq!(r.boxed(), (1600, 1000));
    }

    #[test]
    fn instance_names_unescape() {
        assert_eq!(
            instance_name("Studio\\032PC._blurt-remote._tcp.local."),
            "Studio PC"
        );
        assert_eq!(instance_name("A\\.B._blurt-remote._tcp.local."), "A.B");
    }

    #[test]
    fn computers_keep_their_key_apart() {
        let d =
            std::env::temp_dir().join(format!("blurt-viewer-store-{}", crate::crypto::new_id()));
        let keys: Arc<dyn KeyStore> =
            Arc::new(crate::store::FileKeyStore::new(d.join("keys.json")));
        let cs = Computers::new(&d, keys);
        let c = Computer {
            host_id: "h".into(),
            name: "Studio".into(),
            platform: Some("windows".into()),
            device_id: "d".into(),
            port: 4242,
            addresses: vec!["192.168.1.2".into()],
            relay: None,
            added: 1,
            last_seen: None,
            last_route: None,
            removed: false,
            alias: None,
        };
        cs.add(c.clone(), &[7; 32]).unwrap();
        assert_eq!(cs.list(), vec![c.clone()]);
        assert_eq!(cs.key("h"), Some(vec![7; 32]));
        assert!(
            !std::fs::read_to_string(d.join("computers.json"))
                .unwrap()
                .contains("BwcH"),
            "no key in the list"
        );
        cs.update("h", |c| c.last_seen = Some(5));
        assert_eq!(cs.get("h").unwrap().last_seen, Some(5));
        // the path last used is kept, by its wire name
        cs.update("h", |c| c.last_route = Some(Route::Local));
        assert!(std::fs::read_to_string(d.join("computers.json")).unwrap().contains(r#""lastRoute": "local""#));
        assert_eq!(cs.get("h").unwrap().last_route, Some(Route::Local));
        assert!(!std::fs::read_to_string(d.join("computers.json"))
            .unwrap()
            .contains("removed"));
        // removed by the host in a session: the key goes, the record stays, marked; paired again, a fresh record with a key
        cs.mark_removed("h");
        assert!(cs.get("h").unwrap().removed && cs.key("h").is_none());
        cs.add(c.clone(), &[8; 32]).unwrap();
        assert!(!cs.get("h").unwrap().removed && cs.key("h") == Some(vec![8; 32]));
        // a list from before 1.1 has no `removed`
        let old: Vec<Computer> = serde_json::from_str(
            r#"[{"hostId":"x","name":"Old","deviceId":"d","port":1,"added":1}]"#,
        )
        .unwrap();
        assert!(!old[0].removed);
        assert_eq!((old[0].alias.as_deref(), old[0].shown()), (None, "Old"));
        cs.remove("h");
        assert!(cs.list().is_empty() && cs.key("h").is_none());
        let _ = std::fs::remove_dir_all(d);
    }

    #[test]
    fn a_renamed_computer_keeps_its_name_when_the_host_says_its_own() {
        let d = std::env::temp_dir().join(format!("blurt-viewer-alias-{}", crate::crypto::new_id()));
        let keys: Arc<dyn KeyStore> = Arc::new(crate::store::FileKeyStore::new(d.join("keys.json")));
        let cs = Computers::new(&d, keys);
        let c = Computer {
            host_id: "h".into(),
            name: "DESKTOP-7Q2".into(),
            platform: Some("windows".into()),
            device_id: "d".into(),
            port: 4242,
            addresses: vec![],
            relay: None,
            added: 1,
            last_seen: None,
            last_route: None,
            removed: false,
            alias: None,
        };
        cs.add(c.clone(), &[7; 32]).unwrap();
        assert!(!std::fs::read_to_string(d.join("computers.json")).unwrap().contains("alias"));
        cs.rename("h", " Studio PC ");
        assert_eq!(cs.get("h").unwrap().shown(), "Studio PC");
        // a session says the host's own name (the app's `learned`): the name follows, the alias stays first, the id untouched
        cs.update("h", |c| c.name = "Workshop".into());
        let got = cs.get("h").unwrap();
        assert_eq!((got.host_id.as_str(), got.name.as_str(), got.shown()), ("h", "Workshop", "Studio PC"));
        // read back from disk, and paired again (a fresh record from pair_steps): still the owner's name
        assert!(std::fs::read_to_string(d.join("computers.json")).unwrap().contains(r#""alias": "Studio PC""#));
        cs.add(c.clone(), &[8; 32]).unwrap();
        assert_eq!(cs.get("h").unwrap().shown(), "Studio PC");
        // emptied: the host's own name again
        cs.rename("h", "  ");
        assert_eq!(cs.get("h").unwrap().alias, None);
        assert_eq!(cs.get("h").unwrap().shown(), "DESKTOP-7Q2");
        let _ = std::fs::remove_dir_all(d);
    }
}
