//! host.rs Screen: the portal's monitor stream (capture.rs) → the mirror → the crop, cut at the rate asked → the encoder.
//!
//! One feeder thread decides what's encoded and when:
//!  • a changed frame whose damage touches the crop, no sooner than 1/fps after the last (the latest waits, never a queue);
//!  • a new crop: cut again from the mirror at once, so the phone's view sharpens even on a still screen;
//!  • a cut identical to the last one (a change elsewhere, a pointer-only update): nothing;
//!  • `refresh` / `keyframe`: the last cut again (as a keyframe if asked), for the encoder to sharpen or to start over.
//! Every frame is labelled with the crop it was cut at, exactly: there is no capture-side crop that lands a frame or two late.

use std::sync::{Arc, Condvar, Mutex};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use super::capture::{self, Capture, Shared};
use super::encode::{Encoder, Picture};
use super::math::{self, Rect};
use super::nal::Codec;
use super::portal::Portal;
use crate::host::{Crop, EncodedFrame, FrameSink, Screen, ScreenConfig, ScreenInfo};

#[derive(Default)]
struct Feed {
    crop: Option<Crop>,
    /// new content touches the crop / the crop changed: cut again
    dirty: bool,
    captured: f64,
    want_key: bool,
    refresh: bool,
    fps: u32,
    bitrate: Option<u32>,
    stop: bool,
}

struct Running {
    feed: Arc<(Mutex<Feed>, Condvar)>,
    feeder: Option<JoinHandle<()>>,
    _capture: Capture,
}

pub struct LinuxScreen {
    portal: Arc<Portal>,
    shared: Arc<Shared>,
    now: fn() -> f64,
    running: Option<Running>,
}

/// How long `start` waits for the portal: the first time that's the user answering GNOME's dialog.
const DIALOG_WAIT: Duration = Duration::from_secs(90);

impl LinuxScreen {
    pub fn new(portal: Arc<Portal>, shared: Arc<Shared>, now: fn() -> f64) -> Self {
        LinuxScreen { portal, shared, now, running: None }
    }

    fn poke(&self, f: impl FnOnce(&mut Feed)) {
        if let Some(r) = &self.running {
            let (m, cv) = &*r.feed;
            f(&mut m.lock().unwrap());
            cv.notify_all();
        }
    }
}

/// The encoder for these codecs on this machine (BLURT_REMOTE_ENCODER forces one, for tests).
pub fn pick_encoder(codecs: &[String]) -> Option<(&'static str, String)> {
    let force = std::env::var("BLURT_REMOTE_ENCODER").ok();
    math::choose_encoder(codecs, &super::encode::has_element, force.as_deref())
}

impl Screen for LinuxScreen {
    fn start(&mut self, config: &ScreenConfig, sink: FrameSink) -> Result<ScreenInfo, String> {
        self.stop();
        super::encode::init()?;
        let stream = self.portal.wait(DIALOG_WAIT)?.ok_or("The computer didn't share a screen in its Remote Desktop dialog.")?;
        let (codec, element) = pick_encoder(&config.codecs).ok_or("No video encoder is installed (gstreamer1.0-plugins-ugly has x264).")?;
        let fd = self.portal.pipewire_fd()?;
        // the frames' size comes with the first one: wait for it, so the output keeps the monitor's shape
        let first = Arc::new((Mutex::new(false), Condvar::new()));
        let feed = Arc::new((Mutex::new(Feed { crop: Some(math::sane(config.crop)), fps: config.fps.max(1), ..Default::default() }), Condvar::new()));
        let (f2, first2) = (feed.clone(), first.clone());
        let shared = self.shared.clone();
        let on_frame: capture::OnFrame = Arc::new(move |damage, at| {
            let (m, cv) = &*f2;
            let mut f = m.lock().unwrap();
            let crop = f.crop.unwrap_or(Crop::WHOLE);
            let (w, h) = {
                let mm = shared.mirror.lock().unwrap();
                (mm.width, mm.height)
            };
            if math::damage_hits(damage.as_deref(), math::crop_rect(crop, w, h)) {
                f.dirty = true;
                f.captured = at;
                cv.notify_all();
            }
            let (fm, fcv) = &*first2;
            *fm.lock().unwrap() = true;
            fcv.notify_all();
        });
        *self.shared.mirror.lock().unwrap() = Default::default();
        let cap = capture::start(Some(fd), Some(stream.node), self.shared.clone(), self.now, on_frame)?;
        {
            let (m, cv) = &*first;
            let g = cv.wait_timeout_while(m.lock().unwrap(), Duration::from_secs(5), |got| !*got).unwrap().0;
            if !*g {
                return Err("The screen stream sent no picture.".into());
            }
        }
        let (src_w, src_h) = {
            let m = self.shared.mirror.lock().unwrap();
            (m.width, m.height)
        };
        if stream.size.0 > 0 {
            *self.shared.scale.lock().unwrap() = src_w as f64 / stream.size.0 as f64;
        }
        let (ow, oh) = math::fit_output(config.width, config.height, src_w, src_h);
        let now = self.now;
        let timing = Arc::new(Mutex::new((0u32, 0.0f64, 0.0f64)));
        let t2 = timing.clone();
        let enc_sink: super::encode::UnitSink = Arc::new(move |u, crop, captured, ms| {
            {
                let mut t = t2.lock().unwrap();
                t.0 += 1;
                t.1 += ms;
                t.2 = t.2.max(ms);
            }
            sink(EncodedFrame { picture: u.picture, keyframe: u.keyframe, parameter_sets: u.parameter_sets, crop, captured });
        });
        let enc = Encoder::new(&element, Codec::from_name(codec), ow, oh, config.bitrate, config.fps, enc_sink)?;
        if std::env::var_os("BLURT_REMOTE_DEBUG").is_some() {
            eprintln!("blurt-remote: screen {src_w}×{src_h} px ({}×{} pt) → {ow}×{oh} {codec} by {element}", stream.size.0, stream.size.1);
        }
        let shared = self.shared.clone();
        let f3 = feed.clone();
        let feeder = std::thread::Builder::new()
            .name("blurt-remote-feed".into())
            .spawn(move || feeder(f3, shared, enc, now, timing))
            .map_err(|e| e.to_string())?;
        {
            let (m, cv) = &*feed;
            let mut f = m.lock().unwrap();
            f.dirty = true;
            f.want_key = true;
            f.captured = now();
            cv.notify_all();
        }
        self.running = Some(Running { feed, feeder: Some(feeder), _capture: cap });
        let (w, h) = if stream.size.0 > 0 { (stream.size.0 as f64, stream.size.1 as f64) } else { (src_w as f64, src_h as f64) };
        Ok(ScreenInfo { width: w, height: h, codec: codec.to_string() })
    }

    fn set_crop(&mut self, crop: Crop) {
        let c = math::sane(crop);
        let now = (self.now)();
        self.poke(|f| {
            if f.crop != Some(c) {
                f.crop = Some(c);
                f.dirty = true;
                // a cut of what's on screen now
                f.captured = now;
            }
        });
    }

    fn set_rate(&mut self, bitrate: u32, fps: u32) {
        self.poke(|f| {
            f.bitrate = Some(bitrate);
            f.fps = fps.max(1);
        });
    }

    fn keyframe(&mut self) {
        self.poke(|f| f.want_key = true);
    }

    fn refresh(&mut self) {
        self.poke(|f| f.refresh = true);
    }

    fn stop(&mut self) {
        if let Some(mut r) = self.running.take() {
            {
                let (m, cv) = &*r.feed;
                m.lock().unwrap().stop = true;
                cv.notify_all();
            }
            if let Some(t) = r.feeder.take() {
                let _ = t.join();
            }
            // the capture thread stops when `r` drops
        }
    }
}

impl Drop for LinuxScreen {
    fn drop(&mut self) {
        self.stop();
    }
}

/// (frames, total ms, max ms) from the push to the encoded frame: convert + scale + encode.
type Timing = Arc<Mutex<(u32, f64, f64)>>;

fn feeder(feed: Arc<(Mutex<Feed>, Condvar)>, shared: Arc<Shared>, enc: Encoder, now: fn() -> f64, timing: Timing) {
    let (m, cv) = &*feed;
    let mut last: Option<(Rect, Arc<Vec<u8>>, &'static str)> = None;
    let mut next_due = Instant::now();
    let mut stats = (Instant::now(), 0u32);
    loop {
        let mut f = m.lock().unwrap();
        loop {
            if f.stop {
                return;
            }
            let due = Instant::now() >= next_due && !enc.busy();
            if (f.dirty && due) || f.refresh || (f.want_key && due) || f.bitrate.is_some() {
                break;
            }
            // the encoder finishing doesn't wake this: a busy one is looked at again each millisecond
            let wait = if f.dirty || f.want_key { next_due.saturating_duration_since(Instant::now()) } else { Duration::from_millis(500) };
            f = cv.wait_timeout(f, wait.max(Duration::from_millis(1))).unwrap().0;
        }
        if let Some(b) = f.bitrate.take() {
            enc.set_rate(b, f.fps);
        }
        let crop = f.crop.unwrap_or(Crop::WHOLE);
        let (dirty, refresh, key) = (f.dirty, f.refresh, f.want_key);
        let captured = if dirty { f.captured.max(0.0) } else { now() };
        let fps = f.fps;
        if !(dirty || refresh || key) {
            continue;
        }
        f.dirty = false;
        f.refresh = false;
        f.want_key = false;
        drop(f);
        let mut picture = None;
        if dirty {
            let mm = shared.mirror.lock().unwrap();
            let r = math::crop_rect(crop, mm.width, mm.height);
            let same = last.as_ref().filter(|l| l.0 == r && l.2 == mm.format).map(|l| l.1.as_slice());
            match mm.cut(r, same) {
                Some(Some(px)) => picture = Some((r, Arc::new(px), mm.format, rect_label(r, mm.width, mm.height))),
                Some(None) => {}
                None => {}
            }
        }
        if picture.is_none() && (refresh || key) {
            if let Some((r, px, fmt)) = &last {
                let mm = shared.mirror.lock().unwrap();
                picture = Some((*r, px.clone(), fmt, rect_label(*r, mm.width, mm.height)));
            }
        }
        let Some((r, px, fmt, label)) = picture else {
            if key {
                // nothing to show yet: ask again with the next frame
                m.lock().unwrap().want_key = true;
            }
            continue;
        };
        let p = Picture { data: px.clone(), width: r.w, height: r.h, format: fmt, crop: label, captured: if dirty { captured } else { now() } };
        if let Err(e) = enc.push(&p, key) {
            eprintln!("blurt-remote: encoder: {e}");
        }
        if let Some(e) = enc.error() {
            eprintln!("blurt-remote: encoder: {e}");
        }
        last = Some((r, px, fmt));
        next_due = Instant::now() + Duration::from_secs_f64((1.0 / fps as f64 - 0.003).max(0.0));
        stats.1 += 1;
        if std::env::var_os("BLURT_REMOTE_DEBUG").is_some() && stats.0.elapsed() > Duration::from_secs(2) {
            let mut t = timing.lock().unwrap();
            use std::sync::atomic::Ordering::Relaxed;
            eprintln!(
                "blurt-remote: {} frames from the compositor ({} pointer-only), {} encoded in {:.1}s, convert+encode {:.1} ms mean, {:.1} max",
                shared.frames_in.swap(0, Relaxed),
                shared.cursor_only.swap(0, Relaxed),
                stats.1,
                stats.0.elapsed().as_secs_f64(),
                t.1 / t.0.max(1) as f64,
                t.2
            );
            *t = (0, 0.0, 0.0);
            stats = (Instant::now(), 0);
        }
    }
}

fn rect_label(r: Rect, w: u32, h: u32) -> Crop {
    math::rect_crop(r, w, h)
}
