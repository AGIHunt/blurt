//! The screen, to the phone: the platform-neutral half of RemoteScreen.swift (docs/design/remote.md §Screen, §What it costs). The
//! backend captures, crops, scales and encodes; this decides how much, cuts frames into datagrams, paces keyframes on a direct path,
//! holds back on the relay's stream, asks for a resend when the picture stops, and sends the pointer's place and shape.
//!
//!  • the pointer isn't in the video: its place goes 60 times a second when it moves and twice a second regardless (15 / every 5 s
//!    on the relay's stream, where nothing is lost); its shape when it changes.
//!  • the rate follows the phone's reports (`Rate`); idle (nobody touching the phone) it drops to 5 fps.
//!  • over the relay's stream a frame goes whole, and nothing more goes once more than 1.5 s of picture is on its way: keys go the
//!    same way and mustn't wait behind it. Nothing at all arriving for 6 s means those bytes went down a dead path: a keyframe.
//!  • a frame the way out can't take is dropped, and the picture can't go on without the frames before it: the next one sent is a
//!    keyframe (`Screen::keyframe`), asked for once the way clears.
//!  • a still picture: `Screen::refresh` until a resend comes out under 1.5 KB (at most 8), then nothing.
//!
//! The sink runs on the backend's thread and never touches the backend (its `stop` may be waiting for that thread); the ticker does.

use std::sync::atomic::{AtomicBool, AtomicU32, Ordering::SeqCst};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use crate::channel::Chan;
use crate::host::{EncodedFrame, FrameSink, ScreenConfig};
use crate::input::{Cmd, Shared};
use crate::packets::{cursor, pack_payload, Kind, VideoPacket};
use crate::rate::Rate;
use crate::wire::{Crop, ScreenReport, ScreenRequest, ToPhone};

/// Across streams, so a late piece of the last one can't pass for a frame of this one.
static FRAME_ID: AtomicU32 = AtomicU32::new(0);

const REFINES_PER_STILL: u32 = 8;
const SETTLED: usize = 1500;
const BURST: usize = 16;

/// The phone's request within reason: a number out of range mustn't trap anything.
pub fn clamp(r: &ScreenRequest) -> ScreenRequest {
    let mut r = r.clone();
    r.fps = r.fps.clamp(1, 120);
    r.width = r.width.clamp(64, 8192);
    r.height = r.height.clamp(64, 8192);
    r.bitrate = r.bitrate.clamp(100_000, 50_000_000);
    r.crop = r.crop.valid();
    r
}

/// The output size: the display's shape, as large as the phone asked for, even numbers.
pub fn fit(w: i64, h: i64, aspect: f64) -> (u32, u32) {
    let aspect = if aspect.is_finite() && aspect > 0.1 { aspect } else { 1.6 };
    let (w, h) = (w as f64, h as f64);
    let (ow, oh) = if w / h > aspect { (h * aspect, h) } else { (w, w / aspect) };
    (((ow as u32) / 2 * 2).max(64), ((oh as u32) / 2 * 2).max(64))
}

struct St {
    running: bool,
    rate: Rate,
    relayed: bool,
    idle: bool,
    started: Instant,
    // the way out
    sent_total: usize,
    received_total: usize,
    last_report_at: f64,
    report_bytes: usize,
    report_since: f64,
    busy_skips: i64,
    held_since: f64,
    paced_until: f64,
    was_whole: bool,
    // keyframes
    broken: bool,
    last_key_at: f64,
    last_key_asked: f64,
    last_key_answered: f64,
    key_through: usize,
    // a still picture
    last_frame_at: f64,
    last_refresh_at: f64,
    refresh_pending: bool,
    refines: u32,
    last_frame_bytes: usize,
    // the pointer
    last_cursor: Option<(f64, f64)>,
    tick: u64,
    // measurements
    encoded: u32,
    bytes: usize,
    keyframes: u32,
    skipped: u32,
    stats_since: f64,
}

impl St {
    fn now(&self) -> f64 {
        self.started.elapsed().as_secs_f64()
    }

    fn fps(&self) -> u32 {
        (if self.idle { self.rate.fps.min(5) } else { self.rate.fps }) as u32
    }
}

pub struct ScreenSession {
    st: Arc<Mutex<St>>,
    chan: Arc<Chan>,
    backend: Shared,
    input: std::sync::mpsc::Sender<Cmd>,
    stopped: Arc<AtomicBool>,
    log: Arc<dyn Fn(serde_json::Value) + Send + Sync>,
}

impl ScreenSession {
    /// Starts the backend's stream (blocking: a portal may ask first; run it off the server's tasks). Err: the sentence for
    /// ToPhone.screenFailed.
    pub fn start(
        r: &ScreenRequest,
        chan: Arc<Chan>,
        backend: Shared,
        input: std::sync::mpsc::Sender<Cmd>,
        rt: tokio::runtime::Handle,
        log: Arc<dyn Fn(serde_json::Value) + Send + Sync>,
    ) -> Result<ScreenSession, String> {
        let r = clamp(r);
        // a dialog the user answers (Wayland's portal) is waited on without the backend's lock: input goes on meanwhile
        let wait = backend.lock().unwrap().screen().and_then(|s| s.prepare());
        if let Some(wait) = wait {
            wait()?;
        }
        let relayed = chan.relay;
        let rate = Rate::new(r.bitrate, r.fps, relayed);
        let aspect = backend.lock().unwrap().display_aspect();
        let (width, height) = fit(r.width, r.height, aspect);
        let st = Arc::new(Mutex::new(St {
            running: true,
            rate,
            relayed,
            idle: false,
            started: Instant::now(),
            sent_total: 0,
            received_total: 0,
            last_report_at: 0.0,
            report_bytes: 0,
            report_since: 0.0,
            busy_skips: 0,
            held_since: 0.0,
            paced_until: 0.0,
            was_whole: false,
            broken: false,
            last_key_at: 0.0,
            last_key_asked: 0.0,
            last_key_answered: 0.0,
            key_through: 0,
            last_frame_at: 0.0,
            last_refresh_at: 0.0,
            refresh_pending: false,
            refines: REFINES_PER_STILL,
            last_frame_bytes: 0,
            last_cursor: None,
            tick: 0,
            encoded: 0,
            bytes: 0,
            keyframes: 0,
            skipped: 0,
            stats_since: 0.0,
        }));
        let (bitrate, fps) = {
            let s = st.lock().unwrap();
            (s.rate.bitrate as u32, s.rate.fps as u32)
        };
        let config = ScreenConfig {
            width,
            height,
            bitrate,
            fps,
            codecs: r.codecs.clone().unwrap_or_else(|| vec!["hevc".into()]),
            crop: r.crop.to_host(),
        };
        let sink: FrameSink = {
            let (st, chan, rt, log) = (st.clone(), chan.clone(), rt.clone(), log.clone());
            Arc::new(move |f: EncodedFrame| frame(&st, &chan, &rt, &log, f))
        };
        let info = {
            let mut b = backend.lock().unwrap();
            let Some(screen) = b.screen() else {
                return Err(NO_SCREEN.into());
            };
            screen.start(&config, sink)?
        };
        chan.send(&ToPhone::ScreenView { width: info.width, height: info.height, codec: Some(info.codec.clone()) });
        log(serde_json::json!({"event": "remote_screen", "state": "on", "width": width, "height": height, "bitrate": bitrate,
                               "fps": fps, "codec": info.codec, "relay": relayed}));
        let s = ScreenSession { st, chan, backend, input, stopped: Arc::new(AtomicBool::new(false)), log };
        s.ticker(&rt, if relayed { 15 } else { 60 });
        Ok(s)
    }

    fn ticker(&self, rt: &tokio::runtime::Handle, hz: u64) {
        let (st, chan, backend, stopped) = (self.st.clone(), self.chan.clone(), self.backend.clone(), self.stopped.clone());
        rt.spawn(async move {
            let mut t = tokio::time::interval(Duration::from_micros(1_000_000 / hz));
            t.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
            let mut last_shape: Option<Vec<u8>> = None;
            loop {
                t.tick().await;
                if stopped.load(SeqCst) || chan.is_closed() {
                    return;
                }
                tick(&st, &chan, &backend, hz, &mut last_shape);
            }
        });
    }

    pub fn set_crop(&self, c: Crop) {
        if let Some(s) = self.backend.lock().unwrap().screen() {
            s.set_crop(c.valid().to_host());
        }
    }

    /// The pointer to this place on the screen being shown: the view moved away from it.
    pub fn pointer_to(&self, x: f32, y: f32) {
        if x.is_finite() && y.is_finite() {
            let _ = self.input.send(Cmd::MoveTo(x.clamp(0.0, 1.0) as f64, y.clamp(0.0, 1.0) as f64));
        }
    }

    /// What arrived at the phone: the rate follows it.
    pub fn report(&self, asked: &ScreenReport) {
        let frames = asked.frames.clamp(0, 10_000);
        let lost = asked.lost.clamp(0, frames);
        let received = asked.received.clamp(0, 1 << 50) as usize;
        let rtt = asked.rtt.map(|r| if r.is_finite() { r.clamp(0.0, 60.0) } else { 0.0 });
        let change = {
            let mut s = self.st.lock().unwrap();
            let now = s.now();
            let seconds = (now - s.report_since).max(0.1);
            let sent = (s.report_bytes as f64 * 8.0 / seconds) as i64;
            let delivered = (received.saturating_sub(s.received_total) as f64 * 8.0 / seconds) as i64;
            if received > s.received_total {
                s.held_since = 0.0;
            }
            s.received_total = received;
            s.last_report_at = now;
            let in_one = s.relayed && !self.chan.has_datagrams();
            // a keyframe is a lump, not a queue
            let backed_up = in_one
                && now - s.last_key_at > 2.0
                && s.sent_total.saturating_sub(received) > 64_000usize.max(s.rate.bitrate as usize / 8 * 3 / 4);
            let busy = s.busy_skips;
            let changed = s.rate.update(frames, lost, busy, backed_up, rtt, sent, delivered);
            s.busy_skips = 0;
            s.report_bytes = 0;
            s.report_since = now;
            changed.then(|| (s.rate.bitrate as u32, s.fps(), lost, sent))
        };
        if let Some((bitrate, fps, lost, sent)) = change {
            if let Some(sc) = self.backend.lock().unwrap().screen() {
                sc.set_rate(bitrate, fps);
            }
            (self.log)(serde_json::json!({"event": "remote_screen_rate", "bitrate": bitrate, "fps": fps, "lost": lost, "sent": sent}));
        }
    }

    /// Nobody's touching the phone: a long job scrolling by doesn't need every frame.
    pub fn pace(&self, idle: bool) {
        let (bitrate, fps) = {
            let mut s = self.st.lock().unwrap();
            if s.idle == idle {
                return;
            }
            s.idle = idle;
            (s.rate.bitrate as u32, s.fps())
        };
        if let Some(sc) = self.backend.lock().unwrap().screen() {
            sc.set_rate(bitrate, fps);
        }
    }

    /// The phone asks four times a second until one lands: one on its way needs a moment to arrive, or they'd pile up.
    pub fn keyframe(&self) {
        {
            let mut s = self.st.lock().unwrap();
            let now = s.now();
            let in_one = s.relayed && !self.chan.has_datagrams();
            // the one asked for is still arriving, and on a thin link another would only bury it
            if in_one && s.received_total < s.key_through && now - s.last_key_at < 6.0 {
                return;
            }
            if now < s.paced_until || now - s.last_key_answered <= 0.7 {
                return;
            }
            s.last_key_answered = now;
            s.last_key_asked = now;
            s.refines = 0;
        }
        if let Some(sc) = self.backend.lock().unwrap().screen() {
            sc.keyframe();
        }
    }

    pub fn stop(&self) {
        if self.stopped.swap(true, SeqCst) {
            return;
        }
        self.st.lock().unwrap().running = false;
        if let Some(sc) = self.backend.lock().unwrap().screen() {
            sc.stop();
        }
        (self.log)(serde_json::json!({"event": "remote_screen", "state": "off"}));
    }
}

impl Drop for ScreenSession {
    fn drop(&mut self) {
        self.stop();
    }
}

pub const NO_SCREEN: &str = "This computer can't show its screen on the phone yet.";

/// Ahead of the phone by more than a moment's worth: nothing more goes until it catches up. If its reports stop, so does this.
fn holding_back(s: &mut St, chan: &Chan) -> bool {
    let now = s.now();
    let in_one = s.relayed && !chan.has_datagrams();
    if !in_one || s.sent_total.saturating_sub(s.received_total) <= 48_000usize.max(s.rate.bitrate as usize / 8 * 3 / 2) {
        s.held_since = 0.0;
        return false;
    }
    if s.held_since == 0.0 {
        s.held_since = now;
    }
    if now - s.held_since > 6.0 {
        // nothing arrived at all: those bytes went down a dead path; start over from a keyframe
        s.held_since = 0.0;
        s.sent_total = s.received_total;
        s.broken = true;
        return false;
    }
    now - s.last_report_at < 3.0
}

/// One encoded frame from the backend's thread.
fn frame(st: &Arc<Mutex<St>>, chan: &Arc<Chan>, rt: &tokio::runtime::Handle, log: &Arc<dyn Fn(serde_json::Value) + Send + Sync>, f: EncodedFrame) {
    let mut s = st.lock().unwrap();
    if !s.running {
        return;
    }
    let now = s.now();
    if s.refresh_pending {
        s.refresh_pending = false;
    } else {
        s.refines = 0;
        s.last_frame_at = now;
    }
    if s.broken && !f.keyframe {
        s.skipped += 1;
        return;
    }
    if chan.stream_busy() || holding_back(&mut s, chan) {
        s.busy_skips += 1;
        s.skipped += 1;
        s.broken = true; // what comes next can't be decoded without this one
        return;
    }
    s.broken = false;
    let id = FRAME_ID.fetch_add(1, SeqCst).wrapping_add(1);
    let crop = Crop::from_host(f.crop);
    let body = pack_payload(crop, if f.keyframe { &f.parameter_sets } else { &[] }, &f.picture);
    // in the relay's stream a frame goes whole: each message counts against the free plan
    let whole = s.relayed && !chan.has_datagrams();
    if whole != s.was_whole {
        // a change of path: what went the other way says nothing about this one
        s.was_whole = whole;
        s.sent_total = s.received_total;
    }
    let size = if whole { body.len().max(1) } else { VideoPacket::PAYLOAD };
    let pieces = VideoPacket::split(&body, id, f.keyframe, f.captured, size);
    if s.relayed && !whole && pieces.len() > BURST {
        // a keyframe all at once is what a thin link's queue drops, and one lost piece costs the whole frame: spread out over
        // twice the rate
        let gap = (BURST * VideoPacket::PAYLOAD) as f64 * 8.0 / (s.rate.bitrate as f64 * 2.0);
        let batches: Vec<Vec<VideoPacket>> = pieces.chunks(BURST).map(|c| c.to_vec()).collect();
        s.paced_until = now + gap * (batches.len() - 1) as f64;
        for (i, batch) in batches.into_iter().enumerate() {
            let (chan, st) = (chan.clone(), st.clone());
            let go = move || {
                if st.lock().unwrap().running {
                    for p in &batch {
                        chan.send_datagram(Kind::Video, &p.encode());
                    }
                }
            };
            if i == 0 {
                go();
            } else {
                rt.spawn(async move {
                    tokio::time::sleep(Duration::from_secs_f64(gap * i as f64)).await;
                    go();
                });
            }
        }
    } else {
        for p in &pieces {
            chan.send_datagram(Kind::Video, &p.encode());
        }
    }
    s.last_frame_bytes = body.len();
    s.encoded += 1;
    s.bytes += body.len();
    s.report_bytes += body.len();
    if whole {
        s.sent_total += body.len();
    }
    if f.keyframe {
        s.last_key_at = now;
        s.key_through = s.sent_total;
        s.keyframes += 1;
    }
    if now - s.stats_since >= 2.0 {
        let secs = now - s.stats_since;
        log(serde_json::json!({"event": "remote_screen_host", "fps": (s.encoded as f64 / secs) as u32,
            "kbps": (s.bytes as f64 * 8.0 / secs / 1000.0) as u64, "keyframes": s.keyframes, "skipped": s.skipped}));
        s.encoded = 0;
        s.bytes = 0;
        s.keyframes = 0;
        s.skipped = 0;
        s.stats_since = now;
    }
}

/// What the ticker asks of the backend this tick.
#[derive(Default)]
struct Asks {
    keyframe: bool,
    refresh: bool,
    shape: bool,
}

fn tick(st: &Arc<Mutex<St>>, chan: &Arc<Chan>, backend: &Shared, hz: u64, last_shape: &mut Option<Vec<u8>>) {
    let mut asks = Asks::default();
    let (cursor_every, shape_now) = {
        let mut s = st.lock().unwrap();
        if !s.running {
            return;
        }
        s.tick += 1;
        let now = s.now();
        let in_one = s.relayed && !chan.has_datagrams();
        let held = chan.stream_busy() || holding_back(&mut s, chan);
        // a frame was dropped (or a path died): a keyframe, once the way is clear
        if s.broken && !held && now - s.last_key_asked > 0.7 && now >= s.paced_until {
            s.last_key_asked = now;
            asks.keyframe = true;
        }
        // the picture has stopped: the same frame again, for the encoder to sharpen
        if !asks.keyframe
            && s.refines < REFINES_PER_STILL
            && !held
            && !s.broken
            && s.encoded_any()
            && now - s.last_frame_at > 0.2
            && now - s.last_refresh_at > 0.2
            && now >= s.paced_until
        {
            if s.refines > 0 && s.last_frame_bytes < SETTLED {
                s.refines = REFINES_PER_STILL; // a resend this small: as good as it gets
            } else {
                s.refines += 1;
                s.last_refresh_at = now;
                s.refresh_pending = true;
                asks.refresh = true;
            }
        }
        let every = if in_one { hz * 5 } else { (hz / 2).max(1) };
        (every, s.tick.is_multiple_of((hz / 4).max(1)))
    };
    asks.shape = shape_now;
    let (pointer, shape) = {
        let mut b = backend.lock().unwrap();
        if let Some(sc) = b.screen() {
            if asks.keyframe {
                sc.keyframe();
            } else if asks.refresh {
                sc.refresh();
            }
        }
        let i = b.input();
        (i.pointer(), if asks.shape { i.cursor_shape() } else { None })
    };
    let mut s = st.lock().unwrap();
    if let Some(p) = pointer {
        if s.last_cursor != Some(p) || s.tick.is_multiple_of(cursor_every) {
            s.last_cursor = Some(p);
            chan.send_datagram(Kind::Cursor, &cursor(p.0 as f32, p.1 as f32));
        }
    }
    drop(s);
    if let Some(c) = shape {
        if last_shape.as_ref() != Some(&c.png) {
            *last_shape = Some(c.png.clone());
            chan.send(&ToPhone::CursorShape { png: c.png, hot_x: c.hot_x, hot_y: c.hot_y, width: c.width, height: c.height });
        }
    }
}

impl St {
    fn encoded_any(&self) -> bool {
        self.last_frame_at > 0.0
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_output_keeps_the_displays_shape() {
        assert_eq!(fit(2000, 2000, 16.0 / 9.0), (2000, 1124));
        assert_eq!(fit(1280, 400, 1.6), (640, 400));
        assert_eq!(fit(1281, 801, 1.6), (1280, 800));
        assert_eq!(fit(64, 64, f64::NAN).0 % 2, 0);
    }

    #[test]
    fn requests_are_clamped() {
        let r = clamp(&ScreenRequest {
            target: "display".into(),
            crop: Crop { x: 2.0, y: 0.0, w: 0.5, h: 0.5 },
            width: 1 << 40,
            height: -5,
            bitrate: 0,
            fps: 1000,
            codecs: None,
        });
        assert_eq!((r.width, r.height, r.bitrate, r.fps), (8192, 64, 100_000, 120));
        assert_eq!(r.crop.x, 0.5);
    }
}
