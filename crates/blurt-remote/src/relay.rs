//! Reaching this computer from anywhere (docs/design/remote.md §Away from home; RemoteRelay.swift). Blurt runs no relay: the
//! owner sets one up (tools/remote-relay) and gives its address here; the phone hears it inside the sealed session. Once a session
//! is up over the relay both ends trade addresses (LAN, public IPv6, what a STUN server sees) and knock, and the pointer and video
//! move to the first path that answers. The relay only ever sees sealed bytes.
//!
//! With no relay of the owner's, Blurt's go-between (`GO_BETWEEN`, docs/design/remote-go-between.md) speaks the same protocol on a
//! strict budget: the two ends meet there, open the direct path and move the stream onto it (stream.rs). Overlay networks
//! (Tailscale, ZeroTier) need no server at all: their addresses are candidates like the LAN's.

use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::sync::Arc;
use std::time::Duration;

use crate::crypto::{base64url, hmac256};
use crate::wire::Candidate;

pub const PHONE_LEFT: u16 = 4000;
pub const MAC_GONE: u16 = 4001;
pub const REPLACED: u16 = 4002;
/// the go-between's budget for one connection is spent: it can't carry this session
pub const BUDGET: u16 = 4003;

/// Blurt's go-between: used only when the owner has no relay and the switch is on.
pub const GO_BETWEEN: &str = "wss://meet.blurt.work";

/// "busy today": after a refusal the go-between is tried again after 30 s, 2 min, 10 min, then every hour.
pub fn busy_wait(refusals: u32) -> Duration {
    Duration::from_secs(match refusals {
        0 | 1 => 30,
        2 => 120,
        3 => 600,
        _ => 3600,
    })
}

/// Derived from the paired key: unguessable, and it says nothing about the pair.
pub fn room(key: &[u8]) -> String {
    base64url(&hmac256(key, &[b"blurt-relay-room"]))
}

/// What someone typed, as the address to use: `relay.example.com` means wss://. None if it can't be one. `ws://` is allowed: what
/// passes is sealed either way, and a bare server with an open port needs no domain or certificate.
pub fn address(typed: &str) -> Option<String> {
    let mut t = typed.trim().to_string();
    if t.is_empty() {
        return None;
    }
    if !t.contains("://") {
        t = format!("wss://{t}");
    }
    while t.ends_with('/') {
        t.pop();
    }
    let u = url::Url::parse(&t).ok()?;
    if !(u.scheme() == "wss" || u.scheme() == "ws") || u.host_str().is_none_or(str::is_empty) || u.query().is_some() || u.fragment().is_some() {
        return None;
    }
    Some(t)
}

/// `<relay>/v1/<room>/<role>`
pub fn room_url(address: &str, room: &str, role: &str) -> Option<String> {
    Some(format!("{}/v1/{room}/{role}", self::address(address)?))
}

// ------------------------------------------------------------------ STUN

const COOKIE: [u8; 4] = [0x21, 0x12, 0xA4, 0x42];

pub fn stun_request(txn: &[u8; 12]) -> Vec<u8> {
    let mut d = vec![0, 1, 0, 0];
    d.extend_from_slice(&COOKIE);
    d.extend_from_slice(txn);
    d
}

/// Looks like a STUN binding success at all (the UDP listener hands these to `stun_parse`).
pub fn is_stun_response(d: &[u8]) -> bool {
    d.len() >= 20 && d[0] == 1 && d[1] == 1 && d[4..8] == COOKIE
}

/// The XOR-MAPPED-ADDRESS (IPv4) of a binding success for `txn`.
pub fn stun_parse(d: &[u8], txn: &[u8; 12]) -> Option<Candidate> {
    if !is_stun_response(d) || d[8..20] != txn[..] {
        return None;
    }
    let mut at = 20;
    while at + 4 <= d.len() {
        let kind = (d[at] as usize) << 8 | d[at + 1] as usize;
        let len = (d[at + 2] as usize) << 8 | d[at + 3] as usize;
        if at + 4 + len > d.len() {
            return None;
        }
        if kind == 0x0020 && len >= 8 && d[at + 5] == 1 {
            let port = ((d[at + 6] ^ 0x21) as u16) << 8 | (d[at + 7] ^ 0x12) as u16;
            let ip = Ipv4Addr::new(d[at + 8] ^ COOKIE[0], d[at + 9] ^ COOKIE[1], d[at + 10] ^ COOKIE[2], d[at + 11] ^ COOKIE[3]);
            return Some(Candidate { host: ip.to_string(), port });
        }
        at += 4 + len.div_ceil(4) * 4;
    }
    None
}

/// Asked together, the first answer taken: Cloudflare's (the Mac's), and one that answers from mainland China, where
/// Cloudflare's and Google's didn't (2026-11-09).
pub const STUN_SERVERS: [&str; 2] = ["stun.cloudflare.com:3478", "stun.miwifi.com:3478"];

// ------------------------------------------------------------------ this machine's addresses

/// An overlay network, by its addresses: Tailscale's ranges, or any address on a ZeroTier interface.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Overlay {
    Tailscale,
    Other,
}

impl Overlay {
    /// the route's name in Status: "tailscale" or "overlay"
    pub fn route(self) -> &'static str {
        match self {
            Overlay::Tailscale => "tailscale",
            Overlay::Other => "overlay",
        }
    }
}

fn zerotier(interface: &str) -> bool {
    let n = interface.to_ascii_lowercase();
    n.starts_with("zt") || n.contains("zerotier")
}

/// IPv4 100.64.0.0/10 and IPv6 fd7a:115c:a1e0::/48 are Tailscale's; anything on a `zt*` / ZeroTier interface is an overlay too.
pub fn overlay_of(ip: IpAddr, interface: &str) -> Option<Overlay> {
    match ip {
        IpAddr::V4(a) if a.octets()[0] == 100 && (a.octets()[1] & 0xC0) == 64 => Some(Overlay::Tailscale),
        IpAddr::V6(a) if a.segments()[..3] == [0xfd7a, 0x115c, 0xa1e0] => Some(Overlay::Tailscale),
        IpAddr::V6(a) if a.to_ipv4_mapped().is_some() => overlay_of(IpAddr::V4(a.to_ipv4_mapped().unwrap()), interface),
        IpAddr::V6(a) if (a.segments()[0] & 0xffc0) == 0xfe80 => None,
        _ if zerotier(interface) => Some(Overlay::Other),
        _ => None,
    }
}

/// The overlay a peer reached this computer over (a TCP session's addresses), if any: by the phone's address, or by the
/// interface the connection came in on.
pub fn overlay_route(peer: SocketAddr, local: SocketAddr) -> Option<Overlay> {
    let (peer, local) = (plain(peer).ip(), plain(local).ip());
    if let Some(o) = overlay_of(peer, "") {
        return Some(o);
    }
    let list = if_addrs::get_if_addrs().ok()?;
    list.iter().filter(|i| i.ip() == local).find_map(|i| overlay_of(local, &i.name))
}

/// This machine's overlay addresses (Tailscale, ZeroTier): reachable from wherever the phone is on the same overlay.
pub fn overlay_addresses() -> Vec<String> {
    let Ok(list) = if_addrs::get_if_addrs() else { return vec![] };
    let mut out: Vec<String> = list
        .into_iter()
        .filter(|i| !i.is_loopback() && !i.ip().is_unspecified() && overlay_of(i.ip(), &i.name).is_some())
        .map(|i| i.ip().to_string())
        .collect();
    out.sort();
    out.dedup();
    out
}

/// What the pairing link's `a=` and the session's candidates list: the LAN's addresses, then the overlays'.
pub fn local_addresses() -> Vec<String> {
    let mut out = lan_addresses();
    for a in overlay_addresses() {
        if !out.contains(&a) {
            out.push(a);
        }
    }
    out
}

fn virtual_interface(name: &str) -> bool {
    let n = name.to_ascii_lowercase();
    ["docker", "br-", "veth", "virbr", "vmnet", "vboxnet", "utun", "tun", "tap", "wg", "zt", "tailscale", "vethernet", "lxc", "podman"]
        .iter()
        .any(|p| n.starts_with(p) || n.contains("(wsl") || n.contains("hyper-v"))
}

/// This machine's LAN addresses (IPv4), the usual private ranges first. Virtual interfaces are skipped (containers, VMs, VPNs);
/// the overlays among them come back in `overlay_addresses`.
pub fn lan_addresses() -> Vec<String> {
    let Ok(list) = if_addrs::get_if_addrs() else { return vec![] };
    let mut out: Vec<(u8, String)> = list
        .into_iter()
        .filter(|i| !i.is_loopback() && !virtual_interface(&i.name))
        .filter_map(|i| match i.ip() {
            IpAddr::V4(a) if !a.is_link_local() && !a.is_unspecified() => {
                let rank = if a.is_private() { 0 } else { 1 };
                Some((rank, a.to_string()))
            }
            _ => None,
        })
        .collect();
    out.sort();
    out.dedup_by(|a, b| a.1 == b.1);
    out.into_iter().map(|(_, a)| a).collect()
}

/// This machine's public IPv6 addresses: reachable as they are, where a firewall lets a reply through.
pub fn public_ipv6() -> Vec<String> {
    let Ok(list) = if_addrs::get_if_addrs() else { return vec![] };
    let mut out: Vec<String> = list
        .into_iter()
        .filter(|i| !i.is_loopback())
        .filter_map(|i| match i.ip() {
            IpAddr::V6(a) => {
                let s = a.to_string();
                (s.starts_with('2') || s.starts_with('3')).then_some(s)
            }
            _ => None,
        })
        .collect();
    out.sort();
    out.dedup();
    out
}

// ------------------------------------------------------------------ the WebSocket

/// Why a WebSocket didn't open.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ConnectError {
    /// it answered over HTTP and refused the upgrade (429 and Cloudflare's 1015 among them): from the go-between, "busy today"
    Refused(u16),
    /// no answer, or the way failed
    Failed(String),
}

impl std::fmt::Display for ConnectError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ConnectError::Refused(code) => write!(f, "refused ({code})"),
            ConnectError::Failed(why) => f.write_str(why),
        }
    }
}

impl From<ConnectError> for String {
    fn from(e: ConnectError) -> String {
        e.to_string()
    }
}

pub type Socket = tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

fn tls() -> Arc<rustls::ClientConfig> {
    use std::sync::OnceLock;
    static C: OnceLock<Arc<rustls::ClientConfig>> = OnceLock::new();
    C.get_or_init(|| {
        let roots = rustls::RootCertStore { roots: webpki_roots::TLS_SERVER_ROOTS.to_vec() };
        let c = rustls::ClientConfig::builder_with_provider(Arc::new(rustls::crypto::ring::default_provider()))
            .with_safe_default_protocol_versions()
            .expect("ring supports TLS 1.2 and 1.3")
            .with_root_certificates(roots)
            .with_no_client_auth();
        Arc::new(c)
    })
    .clone()
}

/// A WebSocket to `<relay>/v1/<room>/<role>`, within 8 s.
pub async fn connect(address: &str, room: &str, role: &str) -> Result<Socket, ConnectError> {
    let url = room_url(address, room, role).ok_or(ConnectError::Failed("not a relay address".into()))?;
    let mut cfg = tokio_tungstenite::tungstenite::protocol::WebSocketConfig::default();
    cfg.max_message_size = Some(1 << 21);
    cfg.max_frame_size = Some(1 << 21);
    let go = tokio_tungstenite::connect_async_tls_with_config(
        url.as_str(),
        Some(cfg),
        true,
        Some(tokio_tungstenite::Connector::Rustls(tls())),
    );
    use tokio_tungstenite::tungstenite::Error;
    match tokio::time::timeout(Duration::from_secs(8), go).await {
        Ok(Ok((s, _))) => Ok(s),
        Ok(Err(Error::Http(r))) => Err(ConnectError::Refused(r.status().as_u16())),
        Ok(Err(e)) => Err(ConnectError::Failed(e.to_string())),
        Err(_) => Err(ConnectError::Failed("timed out".into())),
    }
}

/// Does anything answer as a relay at this address? A throwaway room, gone as soon as it's opened.
pub async fn check(address: &str) -> bool {
    let room = base64url(&crate::crypto::new_key());
    match connect(address, &room, "mac").await {
        Ok(mut s) => {
            let _ = s.close(None).await;
            true
        }
        Err(_) => false,
    }
}

/// The address a phone's UDP came from, as a plain one (an IPv4 that arrived on a dual-stack socket says so).
pub fn plain(a: SocketAddr) -> SocketAddr {
    match a {
        SocketAddr::V6(v6) => match v6.ip().to_ipv4_mapped() {
            Some(v4) => SocketAddr::new(IpAddr::V4(v4), v6.port()),
            None => a,
        },
        v4 => v4,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn addresses_as_typed() {
        assert_eq!(address(" relay.example.com/ ").as_deref(), Some("wss://relay.example.com"));
        assert_eq!(address("ws://1.2.3.4:8787").as_deref(), Some("ws://1.2.3.4:8787"));
        assert_eq!(address("https://relay.example.com"), None);
        assert_eq!(address("wss://relay.example.com?x=1"), None);
        assert_eq!(address("wss://relay.example.com#a"), None);
        assert_eq!(address("   "), None);
        assert_eq!(address("wss://"), None);
        assert_eq!(room_url("relay.example.com", "R", "mac").as_deref(), Some("wss://relay.example.com/v1/R/mac"));
    }

    #[test]
    fn stun_answers() {
        let txn = [7u8; 12];
        // a binding success with XOR-MAPPED-ADDRESS 203.0.113.5:50123
        let ip = [203u8, 0, 113, 5];
        let port: u16 = 50123;
        let mut d = vec![1, 1, 0, 12];
        d.extend_from_slice(&COOKIE);
        d.extend_from_slice(&txn);
        d.extend_from_slice(&[0x00, 0x20, 0, 8, 0, 1]);
        d.extend_from_slice(&(port ^ 0x2112).to_be_bytes());
        for i in 0..4 {
            d.push(ip[i] ^ COOKIE[i]);
        }
        assert_eq!(stun_parse(&d, &txn), Some(Candidate { host: "203.0.113.5".into(), port }));
        assert_eq!(stun_parse(&d, &[8u8; 12]), None, "someone else's answer");
        assert_eq!(stun_request(&txn).len(), 20);
    }

    #[test]
    fn overlays_by_address_and_interface() {
        let ip = |s: &str| s.parse::<IpAddr>().unwrap();
        assert_eq!(overlay_of(ip("100.64.0.1"), "utun4"), Some(Overlay::Tailscale));
        assert_eq!(overlay_of(ip("100.127.255.254"), "Tailscale"), Some(Overlay::Tailscale));
        assert_eq!(overlay_of(ip("100.128.0.1"), "tailscale0"), None, "just past 100.64.0.0/10");
        assert_eq!(overlay_of(ip("100.63.255.255"), "en0"), None);
        assert_eq!(overlay_of(ip("fd7a:115c:a1e0::1234"), "utun4"), Some(Overlay::Tailscale));
        assert_eq!(overlay_of(ip("fd7a:115c:a1e1::1"), "utun4"), None);
        assert_eq!(overlay_of(ip("::ffff:100.100.1.2"), ""), Some(Overlay::Tailscale), "v4-mapped, as a dual-stack socket sees it");
        assert_eq!(overlay_of(ip("10.147.17.5"), "ztabcdef12"), Some(Overlay::Other));
        assert_eq!(overlay_of(ip("10.147.17.5"), "ZeroTier One [8056c2e21c000001]"), Some(Overlay::Other));
        assert_eq!(overlay_of(ip("fe80::1"), "ztabcdef12"), None, "link-local isn't reachable from away");
        // the other virtual interfaces stay out: a VPN, a container bridge
        assert_eq!(overlay_of(ip("10.8.0.2"), "wg0"), None);
        assert_eq!(overlay_of(ip("172.17.0.1"), "docker0"), None);
        assert_eq!(overlay_of(ip("192.168.1.20"), "en0"), None);
        assert_eq!(Overlay::Tailscale.route(), "tailscale");
        assert_eq!(overlay_route("[::ffff:100.101.102.103]:5000".parse().unwrap(), "[::ffff:100.70.0.1]:7000".parse().unwrap()), Some(Overlay::Tailscale));
        assert_eq!(overlay_route("192.168.1.9:5000".parse().unwrap(), "192.168.1.2:7000".parse().unwrap()), None);
    }

    #[test]
    fn busy_backs_off_30_s_2_min_10_min_then_hourly() {
        let w: Vec<u64> = (1..=6).map(|n| busy_wait(n).as_secs()).collect();
        assert_eq!(w, [30, 120, 600, 3600, 3600, 3600]);
        assert_eq!(address(GO_BETWEEN).as_deref(), Some(GO_BETWEEN));
    }
}

// ------------------------------------------------------------------ peek

/// What a relay says of a room's computer without joining it (`GET …/peek`, tools/remote-relay): waiting there now, else since when
/// it's asleep (it said so before sleeping, close code 4010) or last seen (ms). Only a paired device can ask: the room comes from the
/// pair's key.
#[derive(Clone, Copy, Debug, PartialEq, Eq, serde::Serialize)]
pub struct Presence {
    pub host: bool,
    pub asleep: Option<i64>,
    pub seen: Option<i64>,
}

/// A computer's close code when it's going to sleep: the relay keeps the time for `peek`.
pub const ASLEEP: u16 = 4010;

/// Blocking (5 s at most): the room's computer as the relay at `address` knows it; None when it can't say (an older relay, no answer).
pub fn peek(address: &str, room: &str) -> Option<Presence> {
    use std::io::{Read, Write};
    let url = room_url(address, room, "peek")?;
    let (tls, rest) = if let Some(r) = url.strip_prefix("wss://") { (true, r) } else { (false, url.strip_prefix("ws://")?) };
    let (hostport, path) = rest.split_once('/').map(|(h, p)| (h, format!("/{p}")))?;
    let host = hostport.rsplit_once(':').filter(|(_, p)| p.parse::<u16>().is_ok()).map_or(hostport, |(h, _)| h);
    let port: u16 = hostport.rsplit_once(':').and_then(|(_, p)| p.parse().ok()).unwrap_or(if tls { 443 } else { 80 });
    let addr = std::net::ToSocketAddrs::to_socket_addrs(&(host, port)).ok()?.next()?;
    let mut tcp = std::net::TcpStream::connect_timeout(&addr, Duration::from_secs(5)).ok()?;
    tcp.set_read_timeout(Some(Duration::from_secs(5))).ok()?;
    tcp.set_write_timeout(Some(Duration::from_secs(5))).ok()?;
    let req = format!("GET {path} HTTP/1.1\r\nHost: {host}\r\nUser-Agent: Blurt\r\nAccept: application/json\r\nConnection: close\r\n\r\n");
    let mut body = Vec::new();
    if tls {
        let name = rustls::pki_types::ServerName::try_from(host.to_string()).ok()?;
        let conn = rustls::ClientConnection::new(self::tls(), name).ok()?;
        let mut s = rustls::StreamOwned::new(conn, tcp);
        s.write_all(req.as_bytes()).ok()?;
        let _ = s.read_to_end(&mut body);
    } else {
        tcp.write_all(req.as_bytes()).ok()?;
        let _ = tcp.read_to_end(&mut body);
    }
    let text = String::from_utf8_lossy(&body);
    let (head, json) = text.split_once("\r\n\r\n")?;
    if !head.starts_with("HTTP/1.1 200") && !head.starts_with("HTTP/1.0 200") {
        return None;
    }
    // a chunked answer (Cloudflare's): the JSON object is the part between the braces
    let json = &json[json.find('{')?..=json.rfind('}')?];
    let v: serde_json::Value = serde_json::from_str(json).ok()?;
    Some(Presence { host: v["host"].as_bool()?, asleep: v["asleep"].as_i64(), seen: v["seen"].as_i64() })
}
