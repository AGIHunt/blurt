//! Reaching this computer from anywhere (docs/design/remote.md §Away from home; RemoteRelay.swift). Blurt runs no relay: the
//! owner sets one up (tools/remote-relay) and gives its address here; the phone hears it inside the sealed session. Once a session
//! is up over the relay both ends trade addresses (LAN, public IPv6, what a STUN server sees) and knock, and the pointer and video
//! move to the first path that answers. The relay only ever sees sealed bytes.

use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::sync::Arc;
use std::time::Duration;

use crate::crypto::{base64url, hmac256};
use crate::wire::Candidate;

pub const PHONE_LEFT: u16 = 4000;
pub const MAC_GONE: u16 = 4001;
pub const REPLACED: u16 = 4002;

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

pub const STUN_SERVER: &str = "stun.cloudflare.com:3478";

// ------------------------------------------------------------------ this machine's addresses

fn virtual_interface(name: &str) -> bool {
    let n = name.to_ascii_lowercase();
    ["docker", "br-", "veth", "virbr", "vmnet", "vboxnet", "utun", "tun", "tap", "wg", "zt", "tailscale", "vethernet", "lxc", "podman"]
        .iter()
        .any(|p| n.starts_with(p) || n.contains("(wsl") || n.contains("hyper-v"))
}

/// This machine's LAN addresses (IPv4), the usual private ranges first.
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
pub async fn connect(address: &str, room: &str, role: &str) -> Result<Socket, String> {
    let url = room_url(address, room, role).ok_or("not a relay address")?;
    let mut cfg = tokio_tungstenite::tungstenite::protocol::WebSocketConfig::default();
    cfg.max_message_size = Some(1 << 21);
    cfg.max_frame_size = Some(1 << 21);
    let go = tokio_tungstenite::connect_async_tls_with_config(
        url.as_str(),
        Some(cfg),
        true,
        Some(tokio_tungstenite::Connector::Rustls(tls())),
    );
    match tokio::time::timeout(Duration::from_secs(8), go).await {
        Ok(Ok((s, _))) => Ok(s),
        Ok(Err(e)) => Err(e.to_string()),
        Err(_) => Err("timed out".into()),
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
        assert_eq!(room_url("relay.agihunt.info", "R", "mac").as_deref(), Some("wss://relay.agihunt.info/v1/R/mac"));
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
}
