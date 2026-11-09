//! The pairing link the QR code holds (RemotePairing.swift):
//!   blurtremote://pair?v=1&mac=<host id>&id=<device id>&k=<base64url key>&n=<name>&p=<tcp port>&a=<addr,addr>&r=<relay>
//! The addresses let the phone connect at once where Bonjour is slow or blocked; `mac` finds the same computer later under
//! whatever name or address it has by then; the relay lets a phone pair from another network.

use crate::crypto::{base64url, unbase64url, VERSION};

pub const SERVICE_TYPE: &str = "_blurt-remote._tcp";
pub const SCHEME: &str = "blurtremote";

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Pairing {
    pub host_id: String,
    pub device_id: String,
    pub key: Vec<u8>,
    pub name: String,
    pub port: u16,
    pub addresses: Vec<String>,
    pub relay: Option<String>,
}

/// What URLComponents leaves as it is in a query value: unreserved, and the sub-delimiters and `:` `/` `@` that a query may
/// hold, except `&`, `=` and `+`, which a reader could take for something else.
fn escape(s: &str) -> String {
    let mut o = String::with_capacity(s.len());
    for b in s.bytes() {
        let keep = b.is_ascii_alphanumeric() || b"-._~!$'()*,;:@/".contains(&b);
        if keep {
            o.push(b as char);
        } else {
            o.push_str(&format!("%{b:02X}"));
        }
    }
    o
}

fn unescape(s: &str) -> Option<String> {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%' {
            let h = std::str::from_utf8(b.get(i + 1..i + 3)?).ok()?;
            out.push(u8::from_str_radix(h, 16).ok()?);
            i += 3;
        } else {
            out.push(b[i]);
            i += 1;
        }
    }
    String::from_utf8(out).ok()
}

impl Pairing {
    pub fn url(&self) -> String {
        let mut q = vec![
            ("v", VERSION.to_string()),
            ("mac", self.host_id.clone()),
            ("id", self.device_id.clone()),
            ("k", base64url(&self.key)),
            ("n", self.name.clone()),
            ("p", self.port.to_string()),
            ("a", self.addresses.join(",")),
        ];
        if let Some(r) = &self.relay {
            q.push(("r", r.clone()));
        }
        let query: Vec<String> = q.into_iter().map(|(k, v)| format!("{k}={}", escape(&v))).collect();
        format!("{SCHEME}://pair?{}", query.join("&"))
    }

    pub fn parse(url: &str) -> Option<Pairing> {
        let rest = url.strip_prefix(&format!("{SCHEME}://pair?"))?;
        let items: Vec<(String, String)> = rest
            .split('&')
            .filter_map(|kv| {
                let (k, v) = kv.split_once('=').unwrap_or((kv, ""));
                Some((unescape(k)?, unescape(v)?))
            })
            .collect();
        let q = |n: &str| items.iter().find(|(k, _)| k == n).map(|(_, v)| v.clone());
        if q("v")? != VERSION.to_string() {
            return None;
        }
        let host_id = q("mac").filter(|s| !s.is_empty())?;
        let device_id = q("id").filter(|s| !s.is_empty())?;
        let key = q("k").and_then(|k| unbase64url(&k)).filter(|k| k.len() == 32)?;
        let port = q("p")?.parse::<u16>().ok()?;
        Some(Pairing {
            host_id,
            device_id,
            key,
            name: q("n").unwrap_or_else(|| "Mac".into()),
            port,
            addresses: q("a").unwrap_or_default().split(',').filter(|s| !s.is_empty()).map(String::from).collect(),
            relay: q("r").and_then(|r| crate::relay::address(&r)),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_relay_goes_in_the_code_and_a_strange_one_stays_out() {
        let mut p = Pairing {
            host_id: "m".into(),
            device_id: "d".into(),
            key: vec![7; 32],
            name: "Studio & Den + 1".into(),
            port: 1,
            addresses: vec![],
            relay: Some("wss://relay.example.com".into()),
        };
        assert_eq!(Pairing::parse(&p.url()), Some(p.clone()));
        p.relay = Some("https://relay.example.com".into());
        assert_eq!(Pairing::parse(&p.url()).unwrap().relay, None);
    }
}
