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
use crate::packets::{cursor_from, FrameReader, Kind, PointerPacket, VideoPacket, MAX_FRAME};
use crate::repair::{Feedback, Output, Receiver};
use crate::wire::{ScreenReport, ScreenRequest, ToMac, ToPhone};

#[derive(Debug)]
pub enum Event {
    Control(ToPhone),
    /// a video piece (datagram or relay stream)
    Video(Vec<u8>),
    /// the pointer's place, and the newest of this phone's numbered pointer instructions it includes (12 bytes; None: the 8-byte one)
    Cursor(f32, f32, Option<u32>),
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
        Kind::Cursor => match cursor_from(body) {
            Some((x, y, seq)) => Event::Cursor(x, y, seq),
            None => return,
        },
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
        self.datagram(Kind::Pointer, &p.encode()).await;
    }

    /// The picture's feedback (repair.rs): over UDP once it works, else in the stream.
    pub async fn feedback(&self, f: &Feedback) {
        self.datagram(Kind::VideoFeedback, &f.encode()).await;
    }

    async fn datagram(&self, kind: Kind, b: &[u8]) {
        match &self.udp {
            Some((u, session)) => {
                let mut body = vec![kind as u8];
                body.extend_from_slice(b);
                let d = self.out.lock().unwrap().seal_packet(&body, *session);
                let _ = u.send(&d).await;
            }
            None => self.sealed(kind, b).await,
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
