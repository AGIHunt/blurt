//! A phone in Rust, for tests (tests/server.rs, tests/go_between.rs, examples/phone.rs): the phone's end of the handshake, the
//! session over TCP, UDP once the host says where, the relay's WebSocket. It does what Link.swift and RemoteChannel.swift do on the
//! iPhone, no more. Away from home (docs/design/remote-go-between.md) it says it can move (`hello.features`), keeps the host's
//! candidates, tries the overlay addresses among them over TCP beside the relay (`connect_away`), knocks on the candidates over UDP
//! (`open_direct`), and on the go-between moves its stream onto the direct path once the host says `udpOK`.

use std::net::{IpAddr, Ipv6Addr, SocketAddr};
use std::sync::atomic::{AtomicBool, Ordering::SeqCst};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use futures_util::{SinkExt, StreamExt};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::UdpSocket;
use tokio::sync::mpsc;
use tokio_tungstenite::tungstenite::Message;

use crate::crypto::{PhoneHandshake, SealIn, SealOut};
use crate::packets::{cursor_from, FrameReader, Kind, PointerPacket, VideoPacket, MAX_FRAME};
use crate::repair::{Feedback, Output, Receiver};
use crate::stream::{self, StreamIn, StreamOut};
use crate::wire::{Candidate, ScreenReport, ScreenRequest, SessionInfo, ToMac, ToPhone};

#[derive(Debug)]
pub enum Event {
    Control(ToPhone),
    /// a video piece (datagram or relay stream)
    Video(Vec<u8>),
    /// the pointer's place, and the newest of this phone's numbered pointer instructions it includes (12 bytes; None: the 8-byte one)
    Cursor(f32, f32, Option<u32>),
    Probe(Vec<u8>),
    /// over: the connection closed (`Phone::close_code` has the relay's code), or nothing came for 6 s after the move
    Closed,
}

/// How this phone behaves (`connect_with`, `connect_relay_with`, `connect_away`).
#[derive(Clone, Debug)]
pub struct Options {
    /// `hello.features`: `["move"]` by default; None plays a phone from before the go-between
    pub features: Option<Vec<String>>,
    /// the relay it connects through is Blurt's go-between: nothing large goes before the move, and the stream moves once the
    /// host says `udpOK` (and lists `move`)
    pub go_between: bool,
    /// `hello.device`: the name the host shows ("Test Phone"; a viewer: its computer's name)
    pub device: String,
}

impl Default for Options {
    fn default() -> Self {
        Options {
            features: Some(vec![crate::wire::MOVE.to_string()]),
            go_between: false,
            device: "Test Phone".into(),
        }
    }
}

impl Options {
    pub fn go_between() -> Options {
        Options { go_between: true, ..Options::default() }
    }

    fn moves(&self) -> bool {
        self.features.as_ref().is_some_and(|f| f.iter().any(|x| x == crate::wire::MOVE))
    }
}

enum Writer {
    Tcp(tokio::net::tcp::OwnedWriteHalf),
    Ws(futures_util::stream::SplitSink<crate::relay::Socket, Message>),
}

impl Writer {
    async fn write(&mut self, f: Vec<u8>) {
        let _ = match self {
            Writer::Tcp(w) => w.write_all(&f).await.map_err(|_| ()),
            Writer::Ws(w) => w.send(Message::Binary(f.into())).await.map_err(|_| ()),
        };
    }

    async fn close(&mut self) {
        match self {
            Writer::Tcp(w) => {
                let _ = w.shutdown().await;
            }
            Writer::Ws(w) => {
                let _ = w.close().await;
            }
        }
    }
}

/// What the phone's tasks share.
struct Inner {
    /// the old stream's writer; held while a frame is sealed, so the counters and the order on the wire agree
    w: tokio::sync::Mutex<Writer>,
    out: Mutex<SealOut>,
    /// Some once this phone has moved: its stream over UDP
    stream: Mutex<Option<StreamOut>>,
    stream_in: Mutex<StreamIn>,
    moved_tx: mpsc::UnboundedSender<Vec<u8>>,
    /// the UDP socket and the session number
    udp: Mutex<Option<(Arc<UdpSocket>, u32)>>,
    /// where the host's datagrams come from: the way to it
    udp_to: Mutex<Option<SocketAddr>>,
    /// the candidates knocked on, until one answers
    knock: Mutex<Vec<SocketAddr>>,
    heard_udp: Mutex<Instant>,
    opts: Options,
    relayed: bool,
    host_moves: AtomicBool,
    candidates: Mutex<Vec<Candidate>>,
    close_code: Arc<Mutex<Option<u16>>>,
    closed: AtomicBool,
    t0: Instant,
}

impl Inner {
    fn now(&self) -> f64 {
        self.t0.elapsed().as_secs_f64()
    }

    /// The stream moves on this connection: the go-between, a host that can, a phone that can.
    fn moves(&self) -> bool {
        self.relayed && self.opts.go_between && self.opts.moves() && self.host_moves.load(SeqCst)
    }

    fn moved_out(&self) -> bool {
        self.stream.lock().unwrap().is_some()
    }

    /// A sealed datagram on its way: to where the host answers from, or before that to every candidate. False: no UDP yet.
    fn udp_send(&self, kind: Kind, body: &[u8]) -> bool {
        let Some((u, session)) = self.udp.lock().unwrap().clone() else { return false };
        let to: Vec<SocketAddr> = match *self.udp_to.lock().unwrap() {
            Some(a) => vec![a],
            None => self.knock.lock().unwrap().clone(),
        };
        if to.is_empty() {
            return false;
        }
        let mut plain = vec![kind as u8];
        plain.extend_from_slice(body);
        for t in to {
            let d = self.out.lock().unwrap().seal_packet(&plain, session);
            let _ = u.try_send_to(&d, t);
        }
        true
    }

    fn send_chunks(&self, chunks: Vec<stream::Chunk>) {
        for (off, b) in chunks {
            self.udp_send(Kind::Stream, &stream::encode_chunk(off, &b));
        }
    }

    async fn sealed(&self, kind: Kind, body: &[u8]) {
        if self.closed.load(SeqCst) {
            return;
        }
        let mut w = self.w.lock().await;
        let mut plain = vec![kind as u8];
        plain.extend_from_slice(body);
        let f = FrameReader::framed(&self.out.lock().unwrap().seal(&plain));
        let chunks = self.stream.lock().unwrap().as_mut().map(|s| s.write(&f, self.now()));
        match chunks {
            Some(c) => self.send_chunks(c),
            None => w.write(f).await,
        }
    }

    /// The move, the phone's side: `streamMoved` as the last frame on the old stream, then everything over UDP.
    async fn move_out(self: &Arc<Self>) {
        {
            let mut w = self.w.lock().await;
            if self.moved_out() || self.closed.load(SeqCst) {
                return;
            }
            let mut plain = vec![Kind::Control as u8];
            plain.extend_from_slice(&ToMac::StreamMoved.encode());
            let f = FrameReader::framed(&self.out.lock().unwrap().seal(&plain));
            w.write(f).await;
            *self.stream.lock().unwrap() = Some(StreamOut::new());
        }
        let me = self.clone();
        tokio::spawn(async move {
            let mut t = tokio::time::interval(Duration::from_millis(10));
            while !me.closed.load(SeqCst) {
                t.tick().await;
                let now = me.now();
                if let Some(a) = me.stream_in.lock().unwrap().tick(now) {
                    me.udp_send(Kind::StreamAck, &stream::encode_ack(a));
                }
                let c = me.stream.lock().unwrap().as_mut().map(|s| s.tick(now)).unwrap_or_default();
                me.send_chunks(c);
            }
        });
    }
}

pub struct Phone {
    inner: Arc<Inner>,
    rx: mpsc::UnboundedReceiver<Event>,
    tx: mpsc::UnboundedSender<Event>,
    udp_in: Option<SealIn>,
    pub host: SocketAddr,
    pub check: String,
}

impl Drop for Phone {
    /// Gone: the connection closes, as an app that quits.
    fn drop(&mut self) {
        self.inner.closed.store(true, SeqCst);
        if let Ok(rt) = tokio::runtime::Handle::try_current() {
            let inner = self.inner.clone();
            rt.spawn(async move { inner.w.lock().await.close().await });
        }
    }
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
        Kind::Cursor => match cursor_from(body) {
            Some((x, y, seq)) => Event::Cursor(x, y, seq),
            None => return,
        },
        Kind::Probe => Event::Probe(body.to_vec()),
        _ => return,
    });
}

/// The frames of the session: from the old stream until the host's `streamMoved`, then from the stream over UDP. Acts on the
/// few messages the connection itself needs (the session's features and candidates, `udpOK` for the move) and hands every one on.
async fn read(inner: Arc<Inner>, mut reader: FrameReader, mut inn: SealIn, mut old: mpsc::UnboundedReceiver<Vec<u8>>, mut moved: mpsc::UnboundedReceiver<Vec<u8>>, tx: mpsc::UnboundedSender<Event>) {
    let mut switched = false;
    loop {
        if inner.closed.load(SeqCst) {
            return;
        }
        let b = if !switched {
            match old.recv().await {
                Some(b) => b,
                None => {
                    let _ = tx.send(Event::Closed);
                    return;
                }
            }
        } else {
            tokio::select! {
                b = moved.recv() => match b { Some(b) => b, None => return },
                _ = tokio::time::sleep(Duration::from_millis(500)) => {
                    // nothing over UDP for 6 s after the move: over, start again
                    if inner.heard_udp.lock().unwrap().elapsed() > Duration::from_secs(6) {
                        let _ = tx.send(Event::Closed);
                        return;
                    }
                    continue;
                }
            }
        };
        reader.feed(&b);
        loop {
            let f = match reader.next_frame() {
                Ok(Some(f)) => f,
                Ok(None) => break,
                Err(_) => {
                    let _ = tx.send(Event::Closed);
                    return;
                }
            };
            let Some(p) = inn.open(&f) else {
                let _ = tx.send(Event::Closed);
                return;
            };
            let m = (p.first() == Some(&(Kind::Control as u8))).then(|| ToPhone::decode(&p[1..])).flatten();
            match &m {
                Some(ToPhone::Session(i)) => {
                    inner.host_moves.store(i.features.as_ref().is_some_and(|f| f.iter().any(|x| x == crate::wire::MOVE)), SeqCst);
                    *inner.candidates.lock().unwrap() = i.candidates.clone();
                }
                Some(ToPhone::UdpOk) if inner.moves() => {
                    // the host has the phone's datagrams: once its way back is known too, the stream moves
                    let me = inner.clone();
                    tokio::spawn(async move {
                        for _ in 0..100 {
                            if me.udp_to.lock().unwrap().is_some() {
                                me.move_out().await;
                                return;
                            }
                            tokio::time::sleep(Duration::from_millis(10)).await;
                        }
                    });
                }
                _ => {}
            }
            deliver(&tx, &p);
            if matches!(m, Some(ToPhone::StreamMoved)) && !switched && inner.moves() {
                // the host's last frame on the old stream: the rest of it comes over UDP
                switched = true;
                *inner.heard_udp.lock().unwrap() = Instant::now();
                reader = FrameReader::default();
                reader.limit = MAX_FRAME;
                break;
            }
        }
    }
}

/// Bound to both stacks, as the host's: IPv4 candidates go as mapped addresses.
fn dual_stack_udp() -> std::io::Result<UdpSocket> {
    let s = socket2::Socket::new(socket2::Domain::IPV6, socket2::Type::DGRAM, Some(socket2::Protocol::UDP))?;
    let _ = s.set_only_v6(false);
    s.bind(&SocketAddr::new(IpAddr::V6(Ipv6Addr::UNSPECIFIED), 0).into())?;
    s.set_nonblocking(true)?;
    UdpSocket::from_std(s.into())
}

fn mapped(a: SocketAddr) -> SocketAddr {
    match a.ip() {
        IpAddr::V4(v4) => SocketAddr::new(IpAddr::V6(v4.to_ipv6_mapped()), a.port()),
        _ => a,
    }
}

/// The candidates worth a TCP try from away, at the host's TCP port: Tailscale's ranges, and private and unique-local addresses
/// (a ZeroTier network's look like a LAN's: the phone can't tell them apart, so it tries them all, each for 1.5 s, in parallel).
pub fn overlay_targets(candidates: &[Candidate], tcp_port: u16) -> Vec<SocketAddr> {
    let mut out = vec![];
    for c in candidates {
        let Ok(ip) = c.host.parse::<IpAddr>() else { continue };
        let worth = match ip {
            IpAddr::V4(a) => a.is_private() || crate::relay::overlay_of(ip, "").is_some(),
            IpAddr::V6(a) => (a.segments()[0] & 0xfe00) == 0xfc00,
        };
        let t = SocketAddr::new(ip, tcp_port);
        if worth && !out.contains(&t) {
            out.push(t);
        }
    }
    out
}

/// What the phone's connection label says for a path (docs/design/remote-go-between.md §Overlay addresses).
pub fn path_label(a: SocketAddr) -> &'static str {
    match crate::relay::overlay_of(a.ip(), "") {
        Some(crate::relay::Overlay::Tailscale) => "Tailscale",
        _ => "Overlay network",
    }
}

impl Phone {
    /// Connect over TCP and finish the handshake. Err: the host's refusal, or the way failed.
    pub async fn connect(host: SocketAddr, id: &str, key: &[u8]) -> Result<Phone, String> {
        Phone::connect_with(host, id, key, Options::default()).await
    }

    pub async fn connect_with(host: SocketAddr, id: &str, key: &[u8], opts: Options) -> Result<Phone, String> {
        let s = tokio::time::timeout(Duration::from_secs(3), tokio::net::TcpStream::connect(host)).await.map_err(|_| "timed out")?.map_err(|e| e.to_string())?;
        Phone::over_tcp(s, host, id, key, opts).await
    }

    pub async fn over_tcp(
        s: tokio::net::TcpStream,
        host: SocketAddr,
        id: &str,
        key: &[u8],
        opts: Options,
    ) -> Result<Phone, String> {
        s.set_nodelay(true).ok();
        let (mut r, mut w) = s.into_split();
        let h = PhoneHandshake::new(id, key);
        w.write_all(&FrameReader::framed(&h.hello())).await.map_err(|e| e.to_string())?;
        let (old_tx, old_rx) = mpsc::unbounded_channel::<Vec<u8>>();
        tokio::spawn(async move {
            let mut buf = vec![0u8; 65536];
            loop {
                match r.read(&mut buf).await {
                    Ok(n) if n > 0 => {
                        if old_tx.send(buf[..n].to_vec()).is_err() {
                            return;
                        }
                    }
                    _ => return,
                }
            }
        });
        Phone::start(Writer::Tcp(w), old_rx, h, host, false, opts, Arc::new(Mutex::new(None))).await
    }

    /// The same over the relay: `<relay>/v1/<room>/phone`.
    pub async fn connect_relay(address: &str, id: &str, key: &[u8]) -> Result<Phone, String> {
        Phone::connect_relay_with(address, id, key, Options::default()).await
    }

    pub async fn connect_relay_with(address: &str, id: &str, key: &[u8], opts: Options) -> Result<Phone, String> {
        let ws = crate::relay::connect(address, &crate::relay::room(key), "phone").await?;
        Phone::over_ws(ws, id, key, opts).await
    }

    pub async fn over_ws(
        ws: crate::relay::Socket,
        id: &str,
        key: &[u8],
        opts: Options,
    ) -> Result<Phone, String> {
        let (mut w, mut r) = ws.split();
        let h = PhoneHandshake::new(id, key);
        w.send(Message::Binary(FrameReader::framed(&h.hello()).into())).await.map_err(|e| e.to_string())?;
        let (old_tx, old_rx) = mpsc::unbounded_channel::<Vec<u8>>();
        let code = Arc::new(Mutex::new(None));
        let c2 = code.clone();
        tokio::spawn(async move {
            while let Some(m) = r.next().await {
                match m {
                    Ok(Message::Binary(b)) => {
                        if old_tx.send(b.to_vec()).is_err() {
                            return;
                        }
                    }
                    Ok(Message::Close(f)) => {
                        *c2.lock().unwrap() = f.map(|f| u16::from(f.code));
                        return;
                    }
                    Ok(_) => {}
                    Err(_) => return,
                }
            }
        });
        Phone::start(Writer::Ws(w), old_rx, h, "0.0.0.0:0".parse().unwrap(), true, opts, code).await
    }

    async fn start(
        w: Writer,
        mut old: mpsc::UnboundedReceiver<Vec<u8>>,
        h: PhoneHandshake,
        host: SocketAddr,
        relayed: bool,
        opts: Options,
        code: Arc<Mutex<Option<u16>>>,
    ) -> Result<Phone, String> {
        let mut reader = FrameReader::default();
        let reply = loop {
            if let Some(f) = reader.next_frame().map_err(|_| "bad length")? {
                break f;
            }
            match old.recv().await {
                Some(b) => reader.feed(&b),
                // the relay's code is in before its reader lets go
                None => return Err(match *code.lock().unwrap() {
                    Some(c) => format!("closed {:?}", Some(c)),
                    None => "closed".into(),
                }),
            }
        };
        reader.limit = MAX_FRAME;
        let k = h.finish(&reply).map_err(|e| format!("{e:?}"))?;
        let check = h.check(&k.transcript);
        let (tx, rx) = mpsc::unbounded_channel();
        let (moved_tx, moved_rx) = mpsc::unbounded_channel();
        let inner = Arc::new(Inner {
            w: tokio::sync::Mutex::new(w),
            out: Mutex::new(k.out),
            stream: Mutex::new(None),
            stream_in: Mutex::new(StreamIn::new()),
            moved_tx,
            udp: Mutex::new(None),
            udp_to: Mutex::new(None),
            knock: Mutex::new(vec![]),
            heard_udp: Mutex::new(Instant::now()),
            opts,
            relayed,
            host_moves: AtomicBool::new(false),
            candidates: Mutex::new(vec![]),
            close_code: code,
            closed: AtomicBool::new(false),
            t0: Instant::now(),
        });
        let udp_in = Some(k.inn.clone());
        tokio::spawn(read(inner.clone(), reader, k.inn, old, moved_rx, tx.clone()));
        let p = Phone { inner, rx, tx, udp_in, host, check };
        p.hello(&h.nonce).await;
        Ok(p)
    }

    /// Away from home, as the phone apps connect: a TCP connection to each overlay address (`overlay_targets` of the candidates
    /// it kept), 1.5 s each, in parallel with the relay or the go-between. If both work the overlay wins. → the phone, and the
    /// path's label ("Tailscale", "Overlay network", or "relay").
    pub async fn connect_away(relay: Option<&str>, overlay: &[SocketAddr], id: &str, key: &[u8], opts: Options) -> Result<(Phone, &'static str), String> {
        let tcp = async {
            let mut tries: futures_util::stream::FuturesUnordered<_> = overlay
                .iter()
                .map(|a| async move { (*a, tokio::time::timeout(Duration::from_millis(1500), tokio::net::TcpStream::connect(*a)).await) })
                .collect();
            while let Some((a, r)) = tries.next().await {
                if let Ok(Ok(s)) = r {
                    return Some((a, s));
                }
            }
            None
        };
        let ws = async {
            match relay {
                Some(r) => Some(crate::relay::connect(r, &crate::relay::room(key), "phone").await),
                None => None,
            }
        };
        let (t, w) = tokio::join!(tcp, ws);
        if let Some((a, s)) = t {
            drop(w);
            let p = Phone::over_tcp(s, a, id, key, Options { go_between: false, ..opts }).await?;
            return Ok((p, path_label(a)));
        }
        match w {
            Some(Ok(ws)) => Ok((Phone::over_ws(ws, id, key, opts).await?, "relay")),
            Some(Err(e)) => Err(e.into()),
            None => Err("no way to the computer".into()),
        }
    }

    async fn hello(&self, nonce: &[u8]) {
        let o = &self.inner.opts;
        let viewer = o
            .features
            .as_ref()
            .is_some_and(|f| f.iter().any(|x| x == crate::wire::VIEWER));
        self.send(&ToMac::Hello {
            device: o.device.clone(),
            mic_on_phone: !viewer,
            nonce: Some(nonce.to_vec()),
            features: o.features.clone(),
        })
        .await;
    }

    pub async fn send(&self, m: &ToMac) {
        self.inner.sealed(Kind::Control, &m.encode()).await;
    }

    /// The microphone: in the stream. Not over the go-between before the move.
    pub async fn audio(&self, pcm: &[u8]) {
        if self.on_go_between_unmoved() {
            return;
        }
        self.inner.sealed(Kind::Audio, pcm).await;
    }

    /// Over UDP once it works, else in the stream (but never over the go-between).
    pub async fn pointer(&self, p: PointerPacket) {
        self.datagram(Kind::Pointer, &p.encode()).await;
    }

    /// The picture's feedback (repair.rs): over UDP once it works, else in the stream.
    pub async fn feedback(&self, f: &Feedback) {
        self.datagram(Kind::VideoFeedback, &f.encode()).await;
    }

    fn on_go_between_unmoved(&self) -> bool {
        self.inner.relayed && self.inner.opts.go_between && !self.inner.moved_out()
    }

    async fn datagram(&self, kind: Kind, b: &[u8]) {
        if self.inner.udp_send(kind, b) {
            return;
        }
        if self.inner.relayed && self.inner.opts.go_between {
            return; // the go-between carries nothing worthless late
        }
        self.inner.sealed(kind, b).await;
    }

    /// The UDP socket and what comes back on it: video, the cursor, probes, and the stream after the move.
    fn udp_socket(&mut self, session: u32) -> std::io::Result<()> {
        let u = Arc::new(dual_stack_udp()?);
        let (u2, tx, inner) = (u.clone(), self.tx.clone(), self.inner.clone());
        if let Some(mut inn) = self.udp_in.take() {
            tokio::spawn(async move {
                let mut buf = vec![0u8; 2048];
                while !inner.closed.load(SeqCst) {
                    let Ok(Ok((n, from))) = tokio::time::timeout(Duration::from_millis(500), u2.recv_from(&mut buf)).await else { continue };
                    let Some(p) = inn.open_packet(&buf[..n]) else { continue };
                    inner.udp_to.lock().unwrap().get_or_insert(from);
                    *inner.heard_udp.lock().unwrap() = Instant::now();
                    match p.first().and_then(|b| Kind::from_byte(*b)) {
                        Some(Kind::Stream) => {
                            let Some((off, b)) = stream::decode_chunk(&p[1..]) else { continue };
                            let r = inner.stream_in.lock().unwrap().receive(off, b, inner.now());
                            if !r.bytes.is_empty() {
                                let _ = inner.moved_tx.send(r.bytes);
                            }
                            if let Some(a) = r.ack {
                                inner.udp_send(Kind::StreamAck, &stream::encode_ack(a));
                            }
                        }
                        Some(Kind::StreamAck) => {
                            let Some(next) = stream::decode_ack(&p[1..]) else { continue };
                            let c = inner.stream.lock().unwrap().as_mut().map(|s| s.ack(next, inner.now())).unwrap_or_default();
                            inner.send_chunks(c);
                        }
                        _ => deliver(&tx, &p),
                    }
                }
            });
        }
        *self.inner.udp.lock().unwrap() = Some((u, session));
        Ok(())
    }

    /// The host said where (session.udpPort): probe it with sealed scrollStop packets; udpOK says one got through.
    pub async fn open_udp(&mut self, port: u16, session: u32) -> std::io::Result<()> {
        self.udp_socket(session)?;
        *self.inner.udp_to.lock().unwrap() = Some(mapped(SocketAddr::new(self.host.ip(), port)));
        for _ in 0..3 {
            self.pointer(PointerPacket::Stop).await;
        }
        Ok(())
    }

    /// Away: knock on every candidate the session named (sealed scrollStop packets, as the apps do), a few times; the first
    /// that answers is the way (`udpOK` says the host has the phone's).
    pub async fn open_direct(&mut self, info: &SessionInfo) -> std::io::Result<()> {
        self.udp_socket(info.udp_session)?;
        let targets: Vec<SocketAddr> =
            info.candidates.iter().take(8).filter_map(|c| c.host.parse::<IpAddr>().ok().map(|ip| mapped(SocketAddr::new(ip, c.port)))).collect();
        *self.inner.knock.lock().unwrap() = targets;
        let inner = self.inner.clone();
        tokio::spawn(async move {
            for _ in 0..8 {
                if inner.udp_to.lock().unwrap().is_some() || inner.closed.load(SeqCst) {
                    return;
                }
                inner.udp_send(Kind::Pointer, &PointerPacket::Stop.encode());
                tokio::time::sleep(Duration::from_millis(250)).await;
            }
        });
        Ok(())
    }

    /// The candidates the last session named: kept for the next time this phone is away (`overlay_targets`).
    pub fn candidates(&self) -> Vec<Candidate> {
        self.inner.candidates.lock().unwrap().clone()
    }

    /// This phone has moved its stream onto the direct path.
    pub fn moved(&self) -> bool {
        self.inner.moved_out()
    }

    /// The relay's close code, once it closed (4003: the go-between's budget).
    pub fn close_code(&self) -> Option<u16> {
        *self.inner.close_code.lock().unwrap()
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

// ------------------------------------------------------------------ the picture, measured (docs/design/remote-realtime.md)

/// A made-up bad network for measured runs, as the iOS app's TestWeather (debug builds there): pieces dropped at `rate` in runs of
/// `burst` on average (Gilbert–Elliott: Wi-Fi loses in bursts), and everything held for `stall` seconds once every `every` seconds,
/// then let through at once. Applied to the picture's pieces as they arrive, before the receiver sees them. Seeded: a run repeats.
pub struct Weather {
    rate: f64,
    burst: f64,
    stall: f64,
    every: f64,
    bad: bool,
    stall_start: f64,
    next_stall: f64,
    rng: u64,
    pub dropped: usize,
    /// one way, seconds: pieces arrive this much later and what the phone says reaches the host this much later (a long path)
    pub delay: f64,
}

impl Weather {
    pub fn new(rate: f64, burst: f64, stall: f64, every: f64, seed: u64) -> Weather {
        Weather {
            rate: rate.clamp(0.0, 0.9),
            burst: burst.max(1.0),
            stall: stall.max(0.0),
            every: every.max(0.1),
            bad: false,
            stall_start: f64::NEG_INFINITY,
            next_stall: 0.0,
            rng: seed | 1,
            dropped: 0,
            delay: 0.0,
        }
    }

    pub fn clear() -> Weather {
        Weather::new(0.0, 1.0, 0.0, 1.0, 1)
    }

    /// `loss` "rate[:burst]" and `stall` "ms:seconds", as BLURT_TEST_LOSS / BLURT_TEST_STALL on the phone.
    pub fn parse(loss: Option<&str>, stall: Option<&str>, seed: u64) -> Weather {
        let nums = |s: Option<&str>| -> Vec<f64> { s.unwrap_or("").split(':').filter_map(|x| x.parse().ok()).collect() };
        let (l, s) = (nums(loss), nums(stall));
        Weather::new(
            l.first().copied().unwrap_or(0.0),
            l.get(1).copied().unwrap_or(1.0),
            s.first().copied().unwrap_or(0.0) / 1000.0,
            s.get(1).copied().unwrap_or(1.0),
            seed,
        )
    }

    fn random(&mut self) -> f64 {
        // xorshift64*
        self.rng ^= self.rng >> 12;
        self.rng ^= self.rng << 25;
        self.rng ^= self.rng >> 27;
        (self.rng.wrapping_mul(0x2545F4914F6CDD1D) >> 11) as f64 / (1u64 << 53) as f64
    }

    /// When this piece arrives: Some(now), Some(later) if a stall holds it, None if it's lost.
    pub fn passes(&mut self, now: f64) -> Option<f64> {
        if self.stall > 0.0 {
            if self.next_stall == 0.0 {
                self.next_stall = now + self.every;
            }
            if now >= self.next_stall {
                self.stall_start = self.next_stall;
                self.next_stall += self.every;
            }
            if now < self.stall_start + self.stall {
                return Some(self.stall_start + self.stall);
            }
        }
        if self.rate <= 0.0 {
            return Some(now);
        }
        // two states: in a bad run every piece is lost; a run ends with 1/burst, and starts so that the average loss is `rate`
        let end = 1.0 / self.burst;
        let start = self.rate * end / (1.0 - self.rate).max(1e-9);
        let r = self.random();
        self.bad = if self.bad { r >= end } else { r < start };
        if self.bad {
            self.dropped += 1;
            None
        } else {
            Some(now)
        }
    }
}

/// What a measured run saw, the doc's columns: frames shown a second, the longest gap between two new pictures, age at decode,
/// frames given up, keyframes asked, what was repaired, the rate.
#[derive(Clone, Debug, Default)]
pub struct Measure {
    pub seconds: f64,
    pub shown: usize,
    pub fps: f64,
    pub longest_gap_ms: f64,
    /// ms from the host composing a frame to the phone having it whole (the host's clock through ToPhone::Clock)
    pub age_p50_ms: f64,
    pub age_p95_ms: f64,
    pub age_max_ms: f64,
    pub dropped: usize,
    pub keyframes_asked: usize,
    pub lost_asked: usize,
    pub keyframes: usize,
    pub refreshes: usize,
    /// pieces asked for again
    pub nacked: usize,
    /// pieces rebuilt from parity
    pub repaired: usize,
    pub pieces: usize,
    /// pieces the made-up network dropped
    pub weather_dropped: usize,
    pub mbps: f64,
    /// frames whose bytes `verify` refused
    pub corrupt: usize,
    /// screenView.features
    pub features: Option<Vec<String>>,
}

/// How to watch: the request, for how long (`warmup` first, not counted), the made-up network, and an optional check of each frame's
/// payload (the loopback test's synthetic pictures carry their own pattern).
pub struct Watch {
    pub request: ScreenRequest,
    pub warmup: f64,
    pub seconds: f64,
    pub weather: Weather,
    pub verify: Option<fn(&[u8]) -> bool>,
}

impl Phone {
    /// Ask for the picture and watch it as the iOS app does (ScreenStream.swift): pieces through the made-up network into the
    /// receiver, its feedback to the host, a keyframe asked for when it says so, reports and pings every second. Then stop it.
    pub async fn watch(&mut self, w: Watch) -> Measure {
        let t0 = std::time::Instant::now();
        let now = move || t0.elapsed().as_secs_f64();
        let mut weather = w.weather;
        let features = w.request.features.is_some();
        self.send(&ToMac::Screen(Some(w.request))).await;
        // the round trip from the start: until it's known the receiver's patience is a home network's
        self.send(&ToMac::Ping(now())).await;
        let mut rx = Receiver::new(false, false, now());
        let mut m = Measure::default();
        let mut held: Vec<(f64, VideoPacket)> = vec![];
        let (mut last_report, mut frames_since, mut bytes_since, mut received) = (0.0, 0i64, 0usize, 0usize);
        let mut dropped_reported = 0usize;
        let mut clock: Option<f64> = None; // host clock − phone clock
        let mut last_shown: Option<f64> = None;
        let mut ages = vec![];
        let mut next_tick = now();
        // what the phone says, on its way to the host (with a made-up delay)
        let mut outbox: Vec<(f64, Feedback)> = vec![];
        let delay = weather.delay;
        let end = w.warmup + w.seconds;
        let counting = |t: f64| t >= w.warmup;
        loop {
            let t = now();
            if t >= end {
                break;
            }
            if t - last_report >= 1.0 {
                last_report = t;
                let lost = rx.dropped - dropped_reported;
                dropped_reported = rx.dropped;
                self.send(&ToMac::ScreenReport(ScreenReport { frames: frames_since, lost: lost as i64, rtt: Some(rx.rtt), received: received as i64 })).await;
                self.send(&ToMac::Ping(t)).await;
                frames_since = 0;
                let _ = bytes_since;
                bytes_since = 0;
            }
            while let Some(i) = outbox.iter().position(|(at, _)| *at <= t) {
                let (_, fb) = outbox.remove(i);
                self.feedback(&fb).await;
            }
            let until = (next_tick - t).max(0.0);
            let mut events = vec![];
            match tokio::time::timeout(Duration::from_secs_f64(until), self.rx.recv()).await {
                Ok(Some(e)) => events.push(e),
                Ok(None) => break,
                Err(_) => {}
            }
            // everything already here is read before the timers run: after a hitch it's what they would otherwise judge missing
            while let Ok(e) = self.rx.try_recv() {
                events.push(e);
            }
            let t = now();
            // pieces a stall or the path's delay held, now let through: ahead of what came after them, as a network keeps order
            let mut arrived: Vec<VideoPacket> = vec![];
            if !held.is_empty() {
                let (due, wait): (Vec<_>, Vec<_>) = held.drain(..).partition(|(at, _)| *at <= t);
                held = wait;
                arrived.extend(due.into_iter().map(|(_, p)| p));
            }
            let mut stop = false;
            for e in events {
                match e {
                    Event::Video(v) => {
                        if let Some(p) = VideoPacket::decode(&v) {
                            if counting(t) {
                                m.pieces += 1;
                            }
                            match weather.passes(t) {
                                Some(at) if at + delay <= t => arrived.push(p),
                                Some(at) => held.push((at + delay, p)),
                                None => {}
                            }
                        }
                    }
                    Event::Control(c) => match c {
                        ToPhone::ScreenView { features: f, .. } => {
                            let f = if features { f } else { None };
                            let has = |n: &str| f.as_ref().is_some_and(|f| f.iter().any(|x| x == n));
                            rx.nack = has(crate::repair::NACK);
                            rx.ltr = has(crate::repair::LTR);
                            m.features = f;
                        }
                        ToPhone::Pong(sent) => rx.rtt = (now() - sent + 2.0 * delay).clamp(0.0005, 2.0),
                        // the path's own round trip, without the made-up delay (the clock message isn't delayed)
                        ToPhone::Clock { phone, mac } => clock = Some(mac - phone - (rx.rtt - 2.0 * delay).max(0.0) / 2.0),
                        ToPhone::ScreenFailed(_) => stop = true,
                        _ => {}
                    },
                    Event::Closed => stop = true,
                    _ => {}
                }
            }
            if stop {
                break;
            }
            let t = now();
            let mut out: Vec<Output> = vec![];
            for p in arrived {
                received += p.payload.len();
                bytes_since += p.payload.len();
                if counting(t) {
                    m.mbps += p.payload.len() as f64;
                }
                out.extend(rx.add(p, t));
            }
            if t >= next_tick {
                next_tick = t + 0.004;
                out.extend(rx.tick(t));
            }
            // what the receiver said, in order; decoded frames may add acks
            let mut i = 0;
            while i < out.len() {
                match out[i].clone() {
                    Output::Frame(f) => {
                        frames_since += 1;
                        if counting(t) {
                            m.shown += 1;
                            if f.keyframe {
                                m.keyframes += 1;
                            }
                            if f.refresh && !f.keyframe {
                                m.refreshes += 1;
                            }
                            if let Some(prev) = last_shown {
                                m.longest_gap_ms = m.longest_gap_ms.max((t - prev) * 1000.0);
                            }
                            if let Some(c) = clock {
                                ages.push((t + c - f.captured) * 1000.0);
                            }
                            if w.verify.is_some_and(|v| !v(&f.data)) {
                                m.corrupt += 1;
                            }
                        }
                        last_shown = Some(t);
                        out.extend(rx.decoded(&f, t));
                    }
                    Output::Feedback(fb) => {
                        if matches!(fb, Feedback::Lost { .. }) && counting(t) {
                            m.lost_asked += 1;
                        }
                        if delay > 0.0 {
                            outbox.push((t + delay, fb));
                        } else {
                            self.feedback(&fb).await;
                        }
                    }
                    Output::Keyframe => {
                        if counting(t) {
                            m.keyframes_asked += 1;
                        }
                        self.send(&ToMac::RequestKeyframe).await;
                    }
                }
                i += 1;
            }
            if !counting(t) {
                // the counters the receiver keeps, from the end of the warm-up
                m.dropped = rx.dropped;
                m.nacked = rx.nacked;
                m.repaired = rx.repaired;
                m.weather_dropped = weather.dropped;
            }
        }
        self.send(&ToMac::Screen(None)).await;
        // nothing new to the end counts as a gap too
        if let Some(prev) = last_shown {
            m.longest_gap_ms = m.longest_gap_ms.max((now().min(end) - prev.max(w.warmup)) * 1000.0);
        }
        m.seconds = w.seconds;
        m.dropped = rx.dropped - m.dropped;
        m.nacked = rx.nacked - m.nacked;
        m.repaired = rx.repaired - m.repaired;
        m.weather_dropped = weather.dropped - m.weather_dropped;
        m.fps = m.shown as f64 / w.seconds;
        m.mbps = m.mbps * 8.0 / w.seconds / 1e6;
        ages.sort_by(|a, b| a.total_cmp(b));
        let q = |f: f64| ages.get(((ages.len() as f64 * f) as usize).min(ages.len().saturating_sub(1))).copied().unwrap_or(-1.0);
        (m.age_p50_ms, m.age_p95_ms, m.age_max_ms) = (q(0.5), q(0.95), ages.last().copied().unwrap_or(-1.0));
        m
    }
}

impl std::fmt::Display for Measure {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "{:.1} fps shown, longest gap {:.0} ms, age p50/p95/max {:.1}/{:.1}/{:.0} ms, dropped {}, keyframes asked {}, lost asked {}, \
             keyframes {}, refreshes {}, pieces {} (made-up loss {}), asked again {}, by parity {}, {:.2} Mbps, corrupt {}, features {:?}",
            self.fps,
            self.longest_gap_ms,
            self.age_p50_ms,
            self.age_p95_ms,
            self.age_max_ms,
            self.dropped,
            self.keyframes_asked,
            self.lost_asked,
            self.keyframes,
            self.refreshes,
            self.pieces,
            self.weather_dropped,
            self.nacked,
            self.repaired,
            self.mbps,
            self.corrupt,
            self.features
        )
    }
}

#[cfg(test)]
mod tests {
    use super::Weather;

    #[test]
    fn the_made_up_network_loses_what_it_says_in_bursts() {
        let mut w = Weather::new(0.03, 3.0, 0.0, 1.0, 42);
        let (mut lost, mut runs, mut was) = (0, 0, false);
        for i in 0..200_000 {
            let gone = w.passes(i as f64 * 1e-4).is_none();
            lost += gone as usize;
            runs += (gone && !was) as usize;
            was = gone;
        }
        let rate = lost as f64 / 200_000.0;
        assert!((0.025..0.035).contains(&rate), "{rate}");
        let burst = lost as f64 / runs as f64;
        assert!((2.5..3.5).contains(&burst), "{burst}");
    }

    #[test]
    fn a_stall_holds_everything_then_lets_it_through() {
        let mut w = Weather::parse(None, Some("80:2"), 1);
        assert_eq!(w.passes(0.0), Some(0.0));
        assert_eq!(w.passes(2.01), Some(2.08));
        assert_eq!(w.passes(2.09), Some(2.09));
    }
}
