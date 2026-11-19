//! One phone's connection, host side (the Mac's RemoteChannel): the TCP stream or the relay's WebSocket for the handshake, control
//! and audio; datagrams for the pointer, video, cursor and probes once a UDP path works (the phone's packets arrive at the
//! server's one UDP socket, and the address they came from is the way back). Over the relay with no direct path, what's worthless
//! late still goes in the stream, but video only while the stream keeps up (`stream_busy`).
//!
//! On Blurt's go-between (docs/design/remote-go-between.md) the stream moves: once the direct path works and the phone said it can,
//! `move_out` sends `streamMoved` as the last frame on the WebSocket and every sealed frame after it goes in kind-7 datagrams
//! (stream.rs), the same bytes with the same implicit counters. Until then nothing that's large or worthless late goes over the
//! go-between: no picture, no cursor, and control messages over 1 KB wait for the move.

use std::net::SocketAddr;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering::SeqCst};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use tokio::net::UdpSocket;
use tokio::sync::{mpsc, Notify};

use crate::crypto::{SealIn, SealOut};
use crate::packets::{FrameReader, Kind};
use crate::stream::{self, StreamIn, StreamOut};
use crate::wire::ToPhone;

/// Control messages larger than this wait for the move on the go-between (`cursorShape`, a long list of displays).
pub const HOLD_OVER: usize = 1024;
/// After the move: this long without a datagram and the session is over.
pub const MOVED_QUIET: Duration = Duration::from_secs(6);

/// The sending side, under one lock: the seal's counters, and where sealed frames go once the stream has moved.
struct Sending {
    seal: Option<SealOut>,
    /// Some once this side has moved: its stream over UDP
    stream: Option<StreamOut>,
    /// control held for the move (plain: kind ∥ body, sealed when it goes)
    held: Vec<Vec<u8>>,
}

pub enum Out {
    /// a length-prefixed frame; `video`: count it against the relay stream's back-pressure until it's written
    Frame { bytes: Vec<u8>, video: bool },
    /// a WebSocket ping (a waiting relay connection that doesn't answer is dead)
    Ping,
    /// this, then close (a refused handshake's one answer)
    Last(Vec<u8>),
    Close,
}

pub struct Chan {
    pub sid: u64,
    pub relay: bool,
    /// a relay connection held open waiting for its phone
    pub standby: bool,
    /// the UDP session number: finds the session for a datagram
    pub number: u32,
    out: mpsc::UnboundedSender<Out>,
    seal: Mutex<Sending>,
    udp_in: Mutex<Option<SealIn>>,
    /// a connection through Blurt's go-between: the stream moves (when the phone can), and it carries nothing large before then
    pub meet: AtomicBool,
    /// the phone listed `move` in its hello
    pub phone_moves: AtomicBool,
    /// the phone's `streamMoved` has been read: its frames now come from `moved_rx`
    moved_in: AtomicBool,
    /// what the phone's stream over UDP delivers, in order
    stream_in: Mutex<StreamIn>,
    moved_tx: mpsc::UnboundedSender<Vec<u8>>,
    moved_rx: Mutex<Option<mpsc::UnboundedReceiver<Vec<u8>>>>,
    /// the route when it isn't the plain local network: "tailscale" or "overlay" (a TCP session over an overlay address)
    pub overlay: Mutex<Option<&'static str>>,
    t0: Instant,
    udp: Arc<UdpSocket>,
    flow: Mutex<Option<(SocketAddr, Instant)>>,
    /// video frames in the relay's stream not yet written
    pub frames_out: Arc<AtomicUsize>,
    pub last_heard: Mutex<Instant>,
    pub greeted: AtomicBool,
    closed: AtomicBool,
    pub shut: Notify,
    /// the relay's close code, when that ended it
    pub relay_close: Mutex<Option<u16>>,
    rt: tokio::runtime::Handle,
}

impl Chan {
    pub fn new(sid: u64, relay: bool, standby: bool, udp: Arc<UdpSocket>, rt: tokio::runtime::Handle) -> (Arc<Chan>, mpsc::UnboundedReceiver<Out>) {
        let (tx, rx) = mpsc::unbounded_channel();
        let (moved_tx, moved_rx) = mpsc::unbounded_channel();
        let c = Chan {
            sid,
            relay,
            standby,
            number: loop {
                let n = u32::from_be_bytes(crate::crypto::random::<4>());
                if n != 0 {
                    break n;
                }
            },
            out: tx,
            seal: Mutex::new(Sending { seal: None, stream: None, held: vec![] }),
            udp_in: Mutex::new(None),
            meet: AtomicBool::new(false),
            phone_moves: AtomicBool::new(false),
            moved_in: AtomicBool::new(false),
            stream_in: Mutex::new(StreamIn::new()),
            moved_tx,
            moved_rx: Mutex::new(Some(moved_rx)),
            overlay: Mutex::new(None),
            t0: Instant::now(),
            udp,
            flow: Mutex::new(None),
            frames_out: Arc::new(AtomicUsize::new(0)),
            last_heard: Mutex::new(Instant::now()),
            greeted: AtomicBool::new(false),
            closed: AtomicBool::new(false),
            shut: Notify::new(),
            relay_close: Mutex::new(None),
            rt,
        };
        (Arc::new(c), rx)
    }

    pub fn keys(&self, out: SealOut, udp_in: SealIn) {
        self.seal.lock().unwrap().seal = Some(out);
        *self.udp_in.lock().unwrap() = Some(udp_in);
    }

    pub fn raw(&self, framed: Vec<u8>) {
        let _ = self.out.send(Out::Frame { bytes: framed, video: false });
    }

    pub fn last(&self, framed: Vec<u8>) {
        let _ = self.out.send(Out::Last(framed));
    }

    pub fn ping(&self) {
        let _ = self.out.send(Out::Ping);
    }

    fn now(&self) -> f64 {
        self.t0.elapsed().as_secs_f64()
    }

    fn sealed(&self, kind: Kind, body: &[u8], video: bool) {
        if self.closed.load(SeqCst) {
            return;
        }
        let mut g = self.seal.lock().unwrap();
        let mut plain = Vec::with_capacity(1 + body.len());
        plain.push(kind as u8);
        plain.extend_from_slice(body);
        // the go-between carries nothing large: it waits for the move
        if g.stream.is_none() && self.meet.load(SeqCst) && kind == Kind::Control && body.len() > HOLD_OVER {
            if g.held.len() < 64 {
                g.held.push(plain);
            }
            return;
        }
        // sealed and queued under one lock: the counter and the order on the wire agree
        self.write_sealed(&mut g, &plain, video);
    }

    /// One frame sealed on channel 0 and on its way: the old stream, or the stream over UDP after the move.
    fn write_sealed(&self, g: &mut Sending, plain: &[u8], video: bool) {
        let Some(s) = g.seal.as_mut() else { return };
        let f = FrameReader::framed(&s.seal(plain));
        match g.stream.as_mut() {
            Some(st) => {
                let chunks = st.write(&f, self.now());
                self.send_chunks(g, chunks);
            }
            None => {
                let _ = self.out.send(Out::Frame { bytes: f, video });
            }
        }
    }

    fn send_chunks(&self, g: &mut Sending, chunks: Vec<stream::Chunk>) {
        for (off, b) in chunks {
            self.packet(g, Kind::Stream, &stream::encode_chunk(off, &b));
        }
    }

    /// A sealed datagram to the phone, if there's a way to it.
    fn packet(&self, g: &mut Sending, kind: Kind, body: &[u8]) {
        let Some(to) = self.flow.lock().unwrap().map(|(a, _)| a) else { return };
        let Some(s) = g.seal.as_mut() else { return };
        let mut plain = Vec::with_capacity(1 + body.len());
        plain.push(kind as u8);
        plain.extend_from_slice(body);
        let p = s.seal_packet(&plain, self.number);
        let _ = self.udp.try_send_to(&p, to);
    }

    /// The move, this side (on the go-between, once the direct path works and the phone can move): `streamMoved` is the last
    /// frame on the WebSocket, and everything after it, the control held back first, goes over UDP. The WebSocket stays open.
    pub fn move_out(self: &Arc<Self>) -> bool {
        if self.closed.load(SeqCst) {
            return false;
        }
        {
            let mut g = self.seal.lock().unwrap();
            if g.stream.is_some() || g.seal.is_none() {
                return false;
            }
            let mut plain = vec![Kind::Control as u8];
            plain.extend_from_slice(&ToPhone::StreamMoved.encode());
            self.write_sealed(&mut g, &plain, false);
            g.stream = Some(StreamOut::new());
            for p in std::mem::take(&mut g.held) {
                self.write_sealed(&mut g, &p, false);
            }
        }
        // the timers: what isn't acked goes again, an ack held back goes when it's due
        let c = self.clone();
        self.rt.spawn(async move {
            let mut t = tokio::time::interval(Duration::from_millis(10));
            t.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
            while !c.closed.load(SeqCst) {
                t.tick().await;
                c.stream_tick();
            }
        });
        true
    }

    fn stream_tick(&self) {
        let now = self.now();
        let ack = self.stream_in.lock().unwrap().tick(now);
        let mut g = self.seal.lock().unwrap();
        if let Some(a) = ack {
            self.packet(&mut g, Kind::StreamAck, &stream::encode_ack(a));
        }
        if let Some(st) = g.stream.as_mut() {
            let chunks = st.tick(now);
            self.send_chunks(&mut g, chunks);
        }
    }

    /// This side has moved its stream.
    pub fn moved_out(&self) -> bool {
        self.seal.lock().unwrap().stream.is_some()
    }

    /// A kind-7 datagram from the phone: bytes of its stream after the move, acked; what's in order goes to the reader.
    pub fn stream_packet(&self, body: &[u8]) {
        let Some((off, b)) = stream::decode_chunk(body) else { return };
        let r = self.stream_in.lock().unwrap().receive(off, b, self.now());
        if !r.bytes.is_empty() {
            let _ = self.moved_tx.send(r.bytes);
        }
        if let Some(a) = r.ack {
            let mut g = self.seal.lock().unwrap();
            self.packet(&mut g, Kind::StreamAck, &stream::encode_ack(a));
        }
    }

    /// A kind-8 datagram: how far the phone has the host's stream.
    pub fn stream_ack(&self, body: &[u8]) {
        let Some(next) = stream::decode_ack(body) else { return };
        let mut g = self.seal.lock().unwrap();
        let Some(st) = g.stream.as_mut() else { return };
        let chunks = st.ack(next, self.now());
        self.send_chunks(&mut g, chunks);
    }

    /// The phone's `streamMoved`: its frames come from the UDP stream from now on (`take_moved`).
    pub fn peer_moved(&self) {
        if self.meet.load(SeqCst) && self.phone_moves.load(SeqCst) {
            self.moved_in.store(true, SeqCst);
        }
    }

    pub fn moved_in(&self) -> bool {
        self.moved_in.load(SeqCst)
    }

    /// The phone's stream over UDP, in order, for the reader that took over from the WebSocket.
    pub fn take_moved(&self) -> Option<mpsc::UnboundedReceiver<Vec<u8>>> {
        self.moved_rx.lock().unwrap().take()
    }

    /// Away from the computer's own network, for the picture's ceiling: a relay, the go-between, or an overlay network.
    pub fn away(&self) -> bool {
        self.relay || self.overlay.lock().unwrap().is_some()
    }

    pub fn send(&self, m: &ToPhone) {
        self.sealed(Kind::Control, &m.encode(), false);
    }

    pub fn heard(&self) {
        *self.last_heard.lock().unwrap() = Instant::now();
    }

    pub fn quiet(&self) -> Duration {
        self.last_heard.lock().unwrap().elapsed()
    }

    /// A datagram path, this moment: direct, or the local network's.
    pub fn has_datagrams(&self) -> bool {
        self.flow.lock().unwrap().is_some()
    }

    /// Over the relay: the stream isn't keeping up, so the next frame had better wait.
    pub fn stream_busy(&self) -> bool {
        self.frames_out.load(SeqCst) >= 2
    }

    /// A datagram the listener matched to this session: opened, or None (forged, damaged, a replay).
    pub fn open_packet(&self, p: &[u8]) -> Option<Vec<u8>> {
        self.udp_in.lock().unwrap().as_mut()?.open_packet(p)
    }

    /// The address the phone's packets come from is the way back to it.
    pub fn use_flow(&self, from: SocketAddr) {
        *self.flow.lock().unwrap() = Some((from, Instant::now()));
    }

    /// For what's worthless late. With no datagram path it goes in the relay's stream, video only while the stream keeps up.
    pub fn send_datagram(&self, kind: Kind, body: &[u8]) {
        if self.closed.load(SeqCst) {
            return;
        }
        let to = {
            let mut f = self.flow.lock().unwrap();
            // the phone has gone quiet on this path (direct, over the relay): back to the stream. Not once the stream has moved:
            // there's no way back then (the session ends after 6 s with nothing).
            if self.relay && !self.meet.load(SeqCst) && f.is_some_and(|(_, at)| at.elapsed() > Duration::from_secs(7)) {
                *f = None;
            }
            f.map(|(a, _)| a)
        };
        if let Some(to) = to {
            let p = {
                let mut g = self.seal.lock().unwrap();
                let Some(s) = g.seal.as_mut() else { return };
                let mut plain = Vec::with_capacity(1 + body.len());
                plain.push(kind as u8);
                plain.extend_from_slice(body);
                s.seal_packet(&plain, self.number)
            };
            let _ = self.udp.try_send_to(&p, to);
            return;
        }
        // the go-between carries no picture, no cursor, nothing worthless late: only the direct path does
        if !self.relay || kind == Kind::Probe || self.meet.load(SeqCst) {
            return;
        }
        if kind == Kind::Video {
            // the sender checks `stream_busy` before it spends anything on a frame: dropped here, it would cost a keyframe
            if self.frames_out.load(SeqCst) >= 4 {
                return;
            }
            self.frames_out.fetch_add(1, SeqCst);
            self.sealed(kind, body, true);
        } else {
            self.sealed(kind, body, false); // the pointer's position: small, and it doesn't count against the video
        }
    }

    pub fn is_closed(&self) -> bool {
        self.closed.load(SeqCst)
    }

    pub fn close(&self) {
        if !self.closed.swap(true, SeqCst) {
            let _ = self.out.send(Out::Close);
            self.shut.notify_one();
        }
    }

    /// Closed after `after` (the phone hears what was just sent first).
    pub fn close_after(self: &Arc<Self>, after: Duration) {
        let c = self.clone();
        self.rt.spawn(async move {
            tokio::time::sleep(after).await;
            c.close();
        });
    }
}
