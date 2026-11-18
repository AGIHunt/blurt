//! One phone's connection, host side (the Mac's RemoteChannel): the TCP stream or the relay's WebSocket for the handshake, control
//! and audio; datagrams for the pointer, video, cursor and probes once a UDP path works (the phone's packets arrive at the
//! server's one UDP socket, and the address they came from is the way back). Over the relay with no direct path, what's worthless
//! late still goes in the stream, but video only while the stream keeps up (`stream_busy`).

use std::net::SocketAddr;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering::SeqCst};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use tokio::net::UdpSocket;
use tokio::sync::{mpsc, Notify};

use crate::crypto::{SealIn, SealOut};
use crate::packets::{FrameReader, Kind};
use crate::wire::ToPhone;

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
    seal: Mutex<Option<SealOut>>,
    udp_in: Mutex<Option<SealIn>>,
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
            seal: Mutex::new(None),
            udp_in: Mutex::new(None),
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
        *self.seal.lock().unwrap() = Some(out);
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

    fn sealed(&self, kind: Kind, body: &[u8], video: bool) {
        if self.closed.load(SeqCst) {
            return;
        }
        let mut s = self.seal.lock().unwrap();
        let Some(s) = s.as_mut() else { return };
        let mut plain = Vec::with_capacity(1 + body.len());
        plain.push(kind as u8);
        plain.extend_from_slice(body);
        // sealed and queued under one lock: the counter and the order on the wire agree
        let f = FrameReader::framed(&s.seal(&plain));
        let _ = self.out.send(Out::Frame { bytes: f, video });
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
            // the phone has gone quiet on this path (direct, over the relay): back to the stream
            if self.relay && f.is_some_and(|(_, at)| at.elapsed() > Duration::from_secs(7)) {
                *f = None;
            }
            f.map(|(a, _)| a)
        };
        if let Some(to) = to {
            let p = {
                let mut s = self.seal.lock().unwrap();
                let Some(s) = s.as_mut() else { return };
                let mut plain = Vec::with_capacity(1 + body.len());
                plain.push(kind as u8);
                plain.extend_from_slice(body);
                s.seal_packet(&plain, self.number)
            };
            let _ = self.udp.try_send_to(&p, to);
            return;
        }
        if !self.relay || kind == Kind::Probe {
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
