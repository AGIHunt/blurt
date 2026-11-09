//! The session's cryptography (docs/design/remote-protocol.md §Layers; reference RemoteCrypto.swift). A key press on the phone
//! becomes a key press here, so nothing on the network may read or forge one.
//!
//!   phone → host  hello {v, id, eph, c}    in the clear; `id` picks the paired key, `c` commits to a nonce
//!   host → phone  hello {v, eph, proof}    proof = HMAC(paired, "mac" ∥ transcript)
//!   phone → host  first sealed frame       only the paired key could have sealed it
//! Keys: HKDF-SHA256(ikm = X25519 secret, salt = paired key, info = transcript, 64 bytes): phone→host, then host→phone.
//! Seals: ChaCha20-Poly1305, nonce = u32 BE channel ∥ u64 BE counter (TCP channel 0 from 0, implicit; UDP channel 1 from 1,
//! carried in the packet, a 64-wide replay window).

use chacha20poly1305::aead::{Aead, KeyInit};
use chacha20poly1305::{ChaCha20Poly1305, Key, Nonce};
use hmac::{Hmac, Mac};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use x25519_dalek::{PublicKey, StaticSecret};

use crate::wire::{b64, unb64};

pub const VERSION: i64 = 1;

pub fn random<const N: usize>() -> [u8; N] {
    let mut b = [0u8; N];
    getrandom::getrandom(&mut b).expect("the system's random source");
    b
}

/// A fresh 256-bit key (pairing codes, the key a new phone keeps).
pub fn new_key() -> [u8; 32] {
    random()
}

/// A fresh id: 128 random bits, base64url (RemoteCrypto.newID).
pub fn new_id() -> String {
    base64url(&random::<16>())
}

pub fn base64url(d: &[u8]) -> String {
    use base64::Engine as _;
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(d)
}

pub fn unbase64url(s: &str) -> Option<Vec<u8>> {
    use base64::engine::{general_purpose::GeneralPurpose, DecodePaddingMode, GeneralPurposeConfig};
    use base64::Engine as _;
    const E: GeneralPurpose = GeneralPurpose::new(
        &base64::alphabet::URL_SAFE,
        GeneralPurposeConfig::new().with_decode_padding_mode(DecodePaddingMode::Indifferent),
    );
    E.decode(s).ok()
}

pub fn sha256(parts: &[&[u8]]) -> [u8; 32] {
    let mut h = Sha256::new();
    for p in parts {
        h.update(p);
    }
    h.finalize().into()
}

pub fn hmac256(key: &[u8], parts: &[&[u8]]) -> [u8; 32] {
    let mut m = <Hmac<Sha256> as Mac>::new_from_slice(key).expect("HMAC takes any key");
    for p in parts {
        m.update(p);
    }
    m.finalize().into_bytes().into()
}

/// Equal keys, compared in constant time.
pub fn same(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    let d = a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y));
    std::hint::black_box(d) == 0
}

pub fn transcript(id: &str, phone_eph: &[u8], host_eph: &[u8]) -> [u8; 32] {
    sha256(&[format!("blurt-remote-{VERSION}").as_bytes(), id.as_bytes(), phone_eph, host_eph])
}

/// The six digits both ends show while a new phone waits for a yes (RemoteCrypto.check).
pub fn check(transcript: &[u8], nonce: &[u8]) -> String {
    let h = sha256(&[b"check", transcript, nonce]);
    let n = u32::from_be_bytes([h[0], h[1], h[2], h[3]]);
    format!("{:06}", n % 1_000_000)
}

pub fn commitment(nonce: &[u8]) -> [u8; 32] {
    sha256(&[b"commit", nonce])
}

pub fn proof(paired: &[u8], transcript: &[u8]) -> [u8; 32] {
    hmac256(paired, &[b"mac", transcript])
}

/// (phone → host, host → phone)
pub fn session_keys(secret: &[u8], paired: &[u8], transcript: &[u8]) -> ([u8; 32], [u8; 32]) {
    let hk = hkdf::Hkdf::<Sha256>::new(Some(paired), secret);
    let mut okm = [0u8; 64];
    hk.expand(transcript, &mut okm).expect("64 bytes is a valid HKDF length");
    let mut a = [0u8; 32];
    let mut b = [0u8; 32];
    a.copy_from_slice(&okm[..32]);
    b.copy_from_slice(&okm[32..]);
    (a, b)
}

/// X25519 from a private key's 32 bytes: (public, shared secret with `peer`). None for a peer key that gives no secret.
pub fn x25519(private: [u8; 32], peer: &[u8]) -> Option<([u8; 32], [u8; 32])> {
    let s = StaticSecret::from(private);
    let p: [u8; 32] = peer.try_into().ok()?;
    let shared = s.diffie_hellman(&PublicKey::from(p));
    if !shared.was_contributory() {
        return None;
    }
    Some((PublicKey::from(&s).to_bytes(), shared.to_bytes()))
}

pub fn public_key(private: [u8; 32]) -> [u8; 32] {
    PublicKey::from(&StaticSecret::from(private)).to_bytes()
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum HandshakeError {
    NotPaired,
    BadProof,
    BadMessage,
    Version,
}

fn nonce(channel: u32, n: u64) -> Nonce {
    let mut d = [0u8; 12];
    d[..4].copy_from_slice(&channel.to_be_bytes());
    d[4..].copy_from_slice(&n.to_be_bytes());
    Nonce::from(d)
}

/// The sending half: TCP counter from 0, UDP from 1.
pub struct SealOut {
    aead: ChaCha20Poly1305,
    sent: u64,
    sent_udp: u64,
}

/// The receiving half. `open` is the stream's (in order); `open_packet` the datagrams' (a 64-wide window).
pub struct SealIn {
    aead: ChaCha20Poly1305,
    received: u64,
    received_udp: u64,
    seen_udp: u64,
}

impl SealOut {
    pub fn new(key: &[u8; 32]) -> SealOut {
        SealOut { aead: ChaCha20Poly1305::new(Key::from_slice(key)), sent: 0, sent_udp: 0 }
    }

    /// TCP: ciphertext ∥ tag; the nonce is how many came before.
    pub fn seal(&mut self, plain: &[u8]) -> Vec<u8> {
        let n = nonce(0, self.sent);
        self.sent += 1;
        self.aead.encrypt(&n, plain).expect("ChaCha20-Poly1305 seals any length we send")
    }

    /// UDP: session (4) ∥ counter (8) ∥ ciphertext ∥ tag.
    pub fn seal_packet(&mut self, plain: &[u8], session: u32) -> Vec<u8> {
        self.sent_udp += 1;
        let c = self.aead.encrypt(&nonce(1, self.sent_udp), plain).expect("seal");
        let mut d = Vec::with_capacity(12 + c.len());
        d.extend_from_slice(&session.to_be_bytes());
        d.extend_from_slice(&self.sent_udp.to_be_bytes());
        d.extend_from_slice(&c);
        d
    }
}

impl SealIn {
    pub fn new(key: &[u8; 32]) -> SealIn {
        SealIn { aead: ChaCha20Poly1305::new(Key::from_slice(key)), received: 0, received_udp: 0, seen_udp: 0 }
    }

    pub fn open(&mut self, frame: &[u8]) -> Option<Vec<u8>> {
        if frame.len() < 16 {
            return None;
        }
        let d = self.aead.decrypt(&nonce(0, self.received), frame).ok()?;
        self.received += 1;
        Some(d)
    }

    /// None: forged, damaged, or a replay. Anything in the last 64 counts not yet seen is taken; older drops.
    pub fn open_packet(&mut self, p: &[u8]) -> Option<Vec<u8>> {
        if p.len() < 28 {
            return None;
        }
        let n = u64::from_be_bytes(p[4..12].try_into().ok()?);
        if n == 0 {
            return None;
        }
        if n <= self.received_udp {
            let back = self.received_udp - n;
            if back >= 64 || self.seen_udp & (1u64 << back) != 0 {
                return None;
            }
        }
        let d = self.aead.decrypt(&nonce(1, n), &p[12..]).ok()?;
        if n > self.received_udp {
            let up = n - self.received_udp;
            self.seen_udp = if up >= 64 { 0 } else { self.seen_udp << up };
            self.received_udp = n;
            self.seen_udp |= 1;
        } else {
            self.seen_udp |= 1u64 << (self.received_udp - n);
        }
        Some(d)
    }
}

pub fn session_of_packet(p: &[u8]) -> Option<u32> {
    (p.len() >= 28).then(|| u32::from_be_bytes([p[0], p[1], p[2], p[3]]))
}

/// What the host's end of a handshake decided.
pub struct Answer {
    /// the reply hello, JSON (sent framed in any case; a refusal then closes)
    pub reply: Vec<u8>,
    /// None: refused
    pub keys: Option<Keys>,
}

/// An accepted handshake: the halves, and what the server checks when the session opens.
pub struct Keys {
    pub id: String,
    pub out: SealOut,
    pub inn: SealIn,
    pub transcript: [u8; 32],
    /// the paired key the handshake used: still that id's key when the session opens, or nothing opens
    pub paired: Vec<u8>,
    /// what the phone committed to
    pub commitment: Option<Vec<u8>>,
}

impl Keys {
    /// The six digits, if `nonce` is the one the phone committed to (None otherwise).
    pub fn check_revealing(&self, nonce: &[u8]) -> Option<String> {
        let c = self.commitment.as_ref()?;
        same(&commitment(nonce), c).then(|| check(&self.transcript, nonce))
    }
}

pub fn refusal(error: &str) -> Vec<u8> {
    serde_json::to_vec(&json!({"v": VERSION, "error": error})).unwrap_or_default()
}

/// The host's end: `lookup` says which paired key an id has (None: not one of ours). `eph`: the host's throwaway private key
/// (fresh for every handshake; fixed only in the vector test).
pub fn answer(hello: &[u8], eph: [u8; 32], lookup: impl FnOnce(&str) -> Option<Vec<u8>>) -> Answer {
    let refuse = |e: &str| Answer { reply: refusal(e), keys: None };
    let Ok(h) = serde_json::from_slice::<Value>(hello) else { return refuse("bad_message") };
    let (Some(v), Some(id), Some(phone_eph)) = (
        h.get("v").and_then(Value::as_i64),
        h.get("id").and_then(Value::as_str),
        h.get("eph").and_then(Value::as_str).and_then(unb64),
    ) else {
        return refuse("bad_message");
    };
    let c = match h.get("c") {
        None | Some(Value::Null) => None,
        Some(c) => match c.as_str().and_then(unb64) {
            Some(c) => Some(c),
            None => return refuse("bad_message"),
        },
    };
    if v != VERSION {
        return refuse("version");
    }
    let Some(paired) = lookup(id) else { return refuse("not_paired") };
    let Some((host_eph, secret)) = x25519(eph, &phone_eph) else { return refuse("bad_message") };
    let t = transcript(id, &phone_eph, &host_eph);
    let (to_host, to_phone) = session_keys(&secret, &paired, &t);
    let reply = serde_json::to_vec(&json!({"v": VERSION, "eph": b64(&host_eph), "proof": b64(&proof(&paired, &t))})).unwrap_or_default();
    Answer {
        reply,
        keys: Some(Keys {
            id: id.to_string(),
            out: SealOut::new(&to_phone),
            inn: SealIn::new(&to_host),
            transcript: t,
            paired,
            commitment: c,
        }),
    }
}

/// The phone's end (the test phone, and the vectors).
pub struct PhoneHandshake {
    pub id: String,
    paired: Vec<u8>,
    eph: [u8; 32],
    pub nonce: [u8; 32],
}

/// The phone's keys once the host proved itself.
pub struct PhoneKeys {
    pub out: SealOut,
    pub inn: SealIn,
    pub transcript: [u8; 32],
}

impl PhoneHandshake {
    pub fn new(id: &str, paired: &[u8]) -> PhoneHandshake {
        Self::with(id, paired, random(), random())
    }

    pub fn with(id: &str, paired: &[u8], eph: [u8; 32], nonce: [u8; 32]) -> PhoneHandshake {
        PhoneHandshake { id: id.to_string(), paired: paired.to_vec(), eph, nonce }
    }

    pub fn hello(&self) -> Vec<u8> {
        serde_json::to_vec(&json!({"v": VERSION, "id": self.id, "eph": b64(&public_key(self.eph)), "c": b64(&commitment(&self.nonce))}))
            .unwrap_or_default()
    }

    pub fn finish(&self, reply: &[u8]) -> Result<PhoneKeys, HandshakeError> {
        let m: Value = serde_json::from_slice(reply).map_err(|_| HandshakeError::BadMessage)?;
        if m.get("error").and_then(Value::as_str) == Some("not_paired") {
            return Err(HandshakeError::NotPaired);
        }
        if m.get("v").and_then(Value::as_i64) != Some(VERSION) {
            return Err(HandshakeError::Version);
        }
        let e = m.get("eph").and_then(Value::as_str).and_then(unb64).ok_or(HandshakeError::BadMessage)?;
        let p = m.get("proof").and_then(Value::as_str).and_then(unb64).ok_or(HandshakeError::BadMessage)?;
        let (mine, secret) = x25519(self.eph, &e).ok_or(HandshakeError::BadMessage)?;
        let t = transcript(&self.id, &mine, &e);
        if !same(&proof(&self.paired, &t), &p) {
            return Err(HandshakeError::BadProof);
        }
        let (to_host, to_phone) = session_keys(&secret, &self.paired, &t);
        Ok(PhoneKeys { out: SealOut::new(&to_host), inn: SealIn::new(&to_phone), transcript: t })
    }

    pub fn check(&self, transcript: &[u8]) -> String {
        check(transcript, &self.nonce)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_handshake_both_ways_and_replays_drop() {
        let key = new_key().to_vec();
        let phone = PhoneHandshake::new("dev", &key);
        let a = answer(&phone.hello(), random(), |id| (id == "dev").then(|| key.clone()));
        let mut host = a.keys.expect("accepted");
        let mut p = phone.finish(&a.reply).expect("proof");
        assert_eq!(host.check_revealing(&phone.nonce), Some(phone.check(&p.transcript)));
        assert_eq!(host.check_revealing(&[0; 32]), None);
        let f = p.out.seal(b"\0{}");
        assert_eq!(host.inn.open(&f).as_deref(), Some(&b"\0{}"[..]));
        assert_eq!(host.inn.open(&f), None, "a replayed stream frame");
        let u1 = p.out.seal_packet(b"\x02\x03", 9);
        let u2 = p.out.seal_packet(b"\x02\x03", 9);
        assert_eq!(session_of_packet(&u1), Some(9));
        assert!(host.inn.open_packet(&u2).is_some());
        assert!(host.inn.open_packet(&u1).is_some(), "overtaken, not yet seen");
        assert!(host.inn.open_packet(&u1).is_none(), "seen");
        let back = host.out.seal(b"hi");
        assert_eq!(p.inn.open(&back).as_deref(), Some(&b"hi"[..]));
    }

    #[test]
    fn strangers_are_refused() {
        let phone = PhoneHandshake::new("who", &[1; 32]);
        let a = answer(&phone.hello(), random(), |_| None);
        assert!(a.keys.is_none());
        assert_eq!(phone.finish(&a.reply).err(), Some(HandshakeError::NotPaired));
        assert!(answer(b"{}", random(), |_| Some(vec![1; 32])).keys.is_none());
        let wrong = answer(&phone.hello(), random(), |_| Some(vec![2; 32]));
        assert_eq!(phone.finish(&wrong.reply).err(), Some(HandshakeError::BadProof));
    }
}
