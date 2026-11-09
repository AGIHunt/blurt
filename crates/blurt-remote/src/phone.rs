//! A phone in Rust, for tests (tests/server.rs, examples/phone.rs): the phone's end of the handshake, the session over TCP, UDP
//! once the host says where, the relay's WebSocket. It does what Link.swift and RemoteChannel.swift do on the iPhone, no more.

use std::net::SocketAddr;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::UdpSocket;
use tokio::sync::mpsc;
use tokio_tungstenite::tungstenite::Message;

use crate::crypto::{PhoneHandshake, SealOut};
use crate::packets::{FrameReader, Kind, PointerPacket, MAX_FRAME};
use crate::wire::{ToMac, ToPhone};

#[derive(Debug)]
pub enum Event {
    Control(ToPhone),
    /// a video piece (datagram or relay stream)
    Video(Vec<u8>),
    Cursor(f32, f32),
    Probe(Vec<u8>),
    Closed,
}

enum Writer {
    Tcp(tokio::net::tcp::OwnedWriteHalf),
    Ws(futures_util::stream::SplitSink<crate::relay::Socket, Message>),
}

pub struct Phone {
    w: tokio::sync::Mutex<Writer>,
    out: Arc<Mutex<SealOut>>,
    rx: mpsc::UnboundedReceiver<Event>,
    tx: mpsc::UnboundedSender<Event>,
    udp: Option<(Arc<UdpSocket>, u32)>,
    udp_in: Option<crate::crypto::SealIn>,
    pub host: SocketAddr,
    pub check: String,
}

fn deliver(tx: &mpsc::UnboundedSender<Event>, plain: &[u8]) {
    let Some(k) = plain.first().and_then(|b| Kind::from_byte(*b)) else { return };
    let body = &plain[1..];
    let _ = tx.send(match k {
        Kind::Control => match ToPhone::decode(body) {
            Some(m) => Event::Control(m),
            None => return,
        },
        Kind::Video => Event::Video(body.to_vec()),
        Kind::Cursor if body.len() >= 8 => Event::Cursor(
            f32::from_le_bytes(body[0..4].try_into().unwrap()),
            f32::from_le_bytes(body[4..8].try_into().unwrap()),
        ),
        Kind::Probe => Event::Probe(body.to_vec()),
        _ => return,
    });
}

impl Phone {
    /// Connect over TCP and finish the handshake. Err: the host's refusal, or the way failed.
    pub async fn connect(host: SocketAddr, id: &str, key: &[u8]) -> Result<Phone, String> {
        let s = tokio::time::timeout(Duration::from_secs(3), tokio::net::TcpStream::connect(host)).await.map_err(|_| "timed out")?.map_err(|e| e.to_string())?;
        s.set_nodelay(true).ok();
        let (mut r, mut w) = s.into_split();
        let h = PhoneHandshake::new(id, key);
        w.write_all(&FrameReader::framed(&h.hello())).await.map_err(|e| e.to_string())?;
        let mut reader = FrameReader::default();
        let mut buf = vec![0u8; 65536];
        let reply = loop {
            if let Some(f) = reader.next_frame().map_err(|_| "bad length")? {
                break f;
            }
            let n = r.read(&mut buf).await.map_err(|e| e.to_string())?;
            if n == 0 {
                return Err("closed".into());
            }
            reader.feed(&buf[..n]);
        };
        let k = h.finish(&reply).map_err(|e| format!("{e:?}"))?;
        reader.limit = MAX_FRAME;
        let check = h.check(&k.transcript);
        let (tx, rx) = mpsc::unbounded_channel();
        let udp_in = Some(k.inn.clone());
        let mut inn = k.inn;
        let t2 = tx.clone();
        tokio::spawn(async move {
            loop {
                while let Ok(Some(f)) = reader.next_frame() {
                    match inn.open(&f) {
                        Some(p) => deliver(&t2, &p),
                        None => {
                            let _ = t2.send(Event::Closed);
                            return;
                        }
                    }
                }
                match r.read(&mut buf).await {
                    Ok(n) if n > 0 => reader.feed(&buf[..n]),
                    _ => {
                        let _ = t2.send(Event::Closed);
                        return;
                    }
                }
            }
        });
        let p = Phone { w: tokio::sync::Mutex::new(Writer::Tcp(w)), out: Arc::new(Mutex::new(k.out)), rx, tx, udp: None, udp_in, host, check };
        p.hello(&h.nonce).await;
        Ok(p)
    }

    /// The same over the relay: `<relay>/v1/<room>/phone`.
    pub async fn connect_relay(address: &str, id: &str, key: &[u8]) -> Result<Phone, String> {
        let ws = crate::relay::connect(address, &crate::relay::room(key), "phone").await?;
        let (mut w, mut r) = ws.split();
        let h = PhoneHandshake::new(id, key);
        w.send(Message::Binary(FrameReader::framed(&h.hello()).into())).await.map_err(|e| e.to_string())?;
        let mut reader = FrameReader::default();
        let reply = loop {
            if let Some(f) = reader.next_frame().map_err(|_| "bad length")? {
                break f;
            }
            match r.next().await {
                Some(Ok(Message::Binary(b))) => reader.feed(&b),
                Some(Ok(Message::Close(f))) => return Err(format!("closed {:?}", f.map(|f| u16::from(f.code)))),
                Some(Ok(_)) => {}
                _ => return Err("closed".into()),
            }
        };
        let k = h.finish(&reply).map_err(|e| format!("{e:?}"))?;
        reader.limit = MAX_FRAME;
        let check = h.check(&k.transcript);
        let (tx, rx) = mpsc::unbounded_channel();
        let udp_in = Some(k.inn.clone());
        let mut inn = k.inn;
        let t2 = tx.clone();
        tokio::spawn(async move {
            loop {
                while let Ok(Some(f)) = reader.next_frame() {
                    match inn.open(&f) {
                        Some(p) => deliver(&t2, &p),
                        None => {
                            let _ = t2.send(Event::Closed);
                            return;
                        }
                    }
                }
                match r.next().await {
                    Some(Ok(Message::Binary(b))) => reader.feed(&b),
                    Some(Ok(Message::Close(_))) | None | Some(Err(_)) => {
                        let _ = t2.send(Event::Closed);
                        return;
                    }
                    Some(Ok(_)) => {}
                }
            }
        });
        let p = Phone {
            w: tokio::sync::Mutex::new(Writer::Ws(w)),
            out: Arc::new(Mutex::new(k.out)),
            rx,
            tx,
            udp: None,
            udp_in,
            host: "0.0.0.0:0".parse().unwrap(),
            check,
        };
        p.hello(&h.nonce).await;
        Ok(p)
    }

    async fn hello(&self, nonce: &[u8]) {
        self.send(&ToMac::Hello { device: "Test Phone".into(), mic_on_phone: true, nonce: Some(nonce.to_vec()) }).await;
    }

    async fn sealed(&self, kind: Kind, body: &[u8]) {
        let mut plain = vec![kind as u8];
        plain.extend_from_slice(body);
        let f = FrameReader::framed(&self.out.lock().unwrap().seal(&plain));
        let mut w = self.w.lock().await;
        let _ = match &mut *w {
            Writer::Tcp(w) => w.write_all(&f).await.map_err(|_| ()),
            Writer::Ws(w) => w.send(Message::Binary(f.into())).await.map_err(|_| ()),
        };
    }

    pub async fn send(&self, m: &ToMac) {
        self.sealed(Kind::Control, &m.encode()).await;
    }

    pub async fn audio(&self, pcm: &[u8]) {
        self.sealed(Kind::Audio, pcm).await;
    }

    /// Over UDP once it works, else in the stream.
    pub async fn pointer(&self, p: PointerPacket) {
        let mut body = vec![Kind::Pointer as u8];
        body.extend_from_slice(&p.encode());
        match &self.udp {
            Some((u, session)) => {
                let d = self.out.lock().unwrap().seal_packet(&body, *session);
                let _ = u.send(&d).await;
            }
            None => self.sealed(Kind::Pointer, &p.encode()).await,
        }
    }

    /// The host said where (session.udpPort): probe it with sealed scrollStop packets; udpOK says one got through.
    pub async fn open_udp(&mut self, port: u16, session: u32) -> std::io::Result<()> {
        let u = Arc::new(UdpSocket::bind(if self.host.is_ipv4() { "0.0.0.0:0" } else { "[::]:0" }).await?);
        u.connect(SocketAddr::new(self.host.ip(), port)).await?;
        let (u2, tx) = (u.clone(), self.tx.clone());
        if let Some(mut inn) = self.udp_in.take() {
            // what comes back on it: video, the cursor, probes
            tokio::spawn(async move {
                let mut buf = vec![0u8; 2048];
                while let Ok(n) = u2.recv(&mut buf).await {
                    if let Some(p) = inn.open_packet(&buf[..n]) {
                        deliver(&tx, &p);
                    }
                }
            });
        }
        self.udp = Some((u, session));
        for _ in 0..3 {
            self.pointer(PointerPacket::Stop).await;
        }
        Ok(())
    }

    /// The next event within `t`.
    pub async fn next(&mut self, t: Duration) -> Option<Event> {
        tokio::time::timeout(t, self.rx.recv()).await.ok().flatten()
    }

    /// Control messages until one `want` takes, within `t`; the rest are dropped.
    pub async fn wait<T>(&mut self, t: Duration, want: impl Fn(&ToPhone) -> Option<T>) -> Option<T> {
        let end = tokio::time::Instant::now() + t;
        loop {
            let left = end.saturating_duration_since(tokio::time::Instant::now());
            match tokio::time::timeout(left, self.rx.recv()).await.ok().flatten()? {
                Event::Control(m) => {
                    if let Some(x) = want(&m) {
                        return Some(x);
                    }
                }
                Event::Closed => return None,
                _ => {}
            }
        }
    }
}

/// The pairing link's way in: connect with its code, wait for the yes and the new key, keep it, open the session.
/// → (the phone, its device id, its key now, the session info)
pub async fn pair(link: &str, at: SocketAddr) -> Result<(Phone, String, Vec<u8>, crate::wire::SessionInfo), String> {
    let p = crate::pairing::Pairing::parse(link).ok_or("not a pairing link")?;
    let mut phone = Phone::connect(at, &p.device_id, &p.key).await?;
    phone.wait(Duration::from_secs(5), |m| matches!(m, ToPhone::PairingWaits).then_some(())).await.ok_or("no question")?;
    let key = phone.wait(Duration::from_secs(10), |m| if let ToPhone::NewKey(k) = m { Some(k.clone()) } else { None }).await.ok_or("no yes")?;
    phone.send(&ToMac::KeyStored).await;
    let info = phone.wait(Duration::from_secs(5), |m| if let ToPhone::Session(i) = m { Some(i.clone()) } else { None }).await.ok_or("no session")?;
    Ok((phone, p.device_id, key, info))
}
