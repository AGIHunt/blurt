//! The encoder: GStreamer, low latency throughout.
//!
//!   appsrc (the crop, raw BGRx/RGBx…, any size) → videoconvertscale (to the constant output size, I420 / NV12, threads)
//!   → the encoder chosen at runtime (math::choose_encoder: VA-API / NVENC / QSV in hardware, else x264)
//!   → h264parse / h265parse (Annex B, parameter sets on every keyframe) → appsink → nal::to_unit → host.rs EncodedFrame
//!
//! The crop changes the appsrc's caps, never the output's: videoconvertscale renegotiates its input and the encoder sees one
//! size forever, so a new crop costs no restart, no keyframe and no black frame. Bitrate changes go to the running encoder.
//! A keyframe is an upstream force-key-unit event before the next picture.

use std::collections::VecDeque;
use std::sync::{Arc, Mutex};

use gstreamer as gst;
use gstreamer::glib;
use gstreamer::prelude::*;
use gstreamer_app as gst_app;

use super::nal::{self, Codec, Unit};
use crate::host::Crop;

pub fn init() -> Result<(), String> {
    gst::init().map_err(|e| format!("GStreamer: {e}"))
}

pub fn has_element(name: &str) -> bool {
    init().is_ok() && gst::ElementFactory::find(name).is_some()
}

/// One raw picture for the encoder: packed rows (stride = width × 4).
pub struct Picture {
    pub data: Arc<Vec<u8>>,
    pub width: u32,
    pub height: u32,
    /// GStreamer's name for the pixel format (BGRx…)
    pub format: &'static str,
    pub crop: Crop,
    pub captured: f64,
}

struct Bytes(Arc<Vec<u8>>);
impl AsRef<[u8]> for Bytes {
    fn as_ref(&self) -> &[u8] {
        self.0.as_slice()
    }
}

pub type UnitSink = Arc<dyn Fn(Unit, Crop, f64, f64) + Send + Sync>;

/// A frame in the encoder: its pts, the crop it shows, when it was captured, when it was pushed.
type InFlight = (u64, Crop, f64, std::time::Instant);

/// The element's bitrate, frame by frame (`push_capped`): what `set_rate` asked for, the frames on their way to the encoder
/// that are to be made at another, and what the element has now. All in the element's unit.
#[derive(Default)]
struct Rates {
    base: u32,
    queue: VecDeque<(u64, u32)>,
    applied: u32,
}

pub struct Encoder {
    pipeline: gst::Pipeline,
    src: gst_app::AppSrc,
    enc: gst::Element,
    pub element: String,
    pub codec: Codec,
    pub width: u32,
    pub height: u32,
    caps: Mutex<Option<(u32, u32, &'static str)>>,
    /// (pts, crop, captured, pushed at) for frames in flight, oldest first
    pending: Arc<Mutex<VecDeque<InFlight>>>,
    rates: Arc<Mutex<Rates>>,
    /// the real frame rate `set_rate` was last told
    fps: Mutex<u32>,
    /// a resend that sharpens is made at a raised bitrate (`boosts`)
    boost: Option<(f64, f64)>,
    /// a change of bitrate makes this element start over with a keyframe (`rekeys_on_rate`)
    rekeys: bool,
    last_pts: Mutex<u64>,
    start: std::time::Instant,
}

/// The frame rate the encoder is told, whatever the real one. With a variable rate (0/1) x264 holds every picture back
/// until the next arrives (it needs the next timestamp for the duration): on a still screen the last picture would never
/// come out (measured: 4 of 5 out). So the caps say 60, and the bitrate is scaled to what each real frame may spend.
pub const NOMINAL_FPS: u32 = 60;

/// What to tell an encoder running at NOMINAL_FPS so that each of `fps` real frames gets `bitrate / fps`.
pub fn nominal_bitrate(bitrate: u32, fps: u32) -> u32 {
    (bitrate as u64 * NOMINAL_FPS as u64 / fps.clamp(1, NOMINAL_FPS) as u64).min(400_000_000) as u32
}

/// Bitrate in the element's own unit.
fn bitrate_value(element: &str, bps: u32) -> u32 {
    if element == "openh264enc" {
        bps
    } else {
        (bps / 1000).max(50)
    }
}

fn set(e: &gst::Element, name: &str, value: &str) {
    if e.find_property(name).is_some() {
        // a value an older version doesn't know is not fatal: the element keeps its default
        let r = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| e.set_property_from_str(name, value)));
        if r.is_err() {
            eprintln!("blurt-remote: {} has no {name}={value}", e.factory().map(|f| f.name().to_string()).unwrap_or_default());
        }
    }
}

/// The longest keyframe interval each element takes, for a phone that repairs (docs/design/remote-realtime.md §Host 6): it asks for
/// one when it needs it, and a keyframe every 10 s of scrolling was 100–170 KB at once with the frames around it starved.
fn gop(element: &str, repairs: bool) -> &'static str {
    if !repairs {
        return "600";
    }
    match element {
        "x264enc" => "2147483647",
        "x265enc" | "openh264enc" => "600",
        _ if element.starts_with("nv") => "-1",
        // VA's key-int-max stops at 1024
        _ if element.starts_with("va") && !element.starts_with("vaapi") => "1024",
        _ => "600",
    }
}

fn configure(e: &gst::Element, element: &str, bitrate: u32, fps: u32, repairs: bool) {
    let key_int = gop(element, repairs);
    let bitrate = nominal_bitrate(bitrate, fps);
    // the VBV in nominal time: about `vbv_ms(fps)` of real time
    let vbv = (super::math::vbv_ms(fps) * fps.clamp(1, NOMINAL_FPS) / NOMINAL_FPS).max(20);
    let kbps = bitrate_value(element, bitrate).to_string();
    let threads = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(4).min(4).to_string();
    match element {
        "x264enc" => {
            // zerolatency: no B-frames, no lookahead, sliced threads (a picture leaves as soon as it's encoded)
            set(e, "tune", "zerolatency");
            set(e, "speed-preset", "superfast");
            set(e, "bitrate", &kbps);
            set(e, "vbv-buf-capacity", &vbv.to_string());
            set(e, "key-int-max", key_int);
            set(e, "bframes", "0");
            // a sharpening resend's raised rate can take the quantiser down more than 4 at once (x264's default; measured: with
            // 4 the ladder ended at 29.6 dB, with 24 at 36.5, the moving frames' size unchanged)
            set(e, "qp-step", "24");
            // said again: x264enc applies its own properties over the tune, and its defaults (frame threads, sync
            // lookahead) hold a frame back
            set(e, "sliced-threads", "true");
            set(e, "sync-lookahead", "0");
            set(e, "rc-lookahead", "0");
            set(e, "threads", &threads);
            set(e, "byte-stream", "true");
            set(e, "aud", "false");
            // repeat-headers: SPS/PPS before every IDR, so a keyframe asked for carries them in-band
            set(e, "option-string", "repeat-headers=1:scenecut=0");
        }
        "x265enc" => {
            set(e, "tune", "zerolatency");
            set(e, "speed-preset", "ultrafast");
            set(e, "bitrate", &kbps);
            set(e, "key-int-max", "600");
            set(e, "option-string", "repeat-headers=1:bframes=0:scenecut=0");
        }
        "openh264enc" => {
            set(e, "bitrate", &kbps);
            set(e, "rate-control", "bitrate");
            set(e, "complexity", "low");
            set(e, "gop-size", "600");
        }
        _ if element.starts_with("va") && !element.starts_with("vaapi") => {
            set(e, "rate-control", "cbr");
            set(e, "bitrate", &kbps);
            set(e, "b-frames", "0");
            set(e, "ref-frames", "1");
            set(e, "key-int-max", key_int);
            set(e, "target-usage", "6");
            set(e, "cpb-size", &(bitrate_value(element, bitrate) * vbv / 1000).max(100).to_string());
        }
        _ if element.starts_with("vaapi") => {
            set(e, "rate-control", "cbr");
            set(e, "bitrate", &kbps);
            set(e, "keyframe-period", "600");
            set(e, "max-bframes", "0");
            set(e, "refs", "1");
        }
        _ if element.starts_with("nv") => {
            set(e, "preset", "p1");
            set(e, "tune", "ultra-low-latency");
            set(e, "preset", "low-latency-hp");
            set(e, "rc-mode", "cbr");
            set(e, "bitrate", &kbps);
            set(e, "gop-size", key_int);
            set(e, "bframes", "0");
            set(e, "b-frames", "0");
            set(e, "zerolatency", "true");
            set(e, "zero-reorder-delay", "true");
            set(e, "rc-lookahead", "0");
        }
        _ if element.starts_with("qsv") => {
            set(e, "rate-control", "cbr");
            set(e, "bitrate", &kbps);
            set(e, "gop-size", "600");
            set(e, "b-frames", "0");
            set(e, "low-latency", "true");
        }
        _ => set(e, "bitrate", &kbps),
    }
}

/// The elements that sharpen a still picture by its bitrate (`Screen::sharpen`; docs/design/remote-linux.md §2026-11-11): a
/// change of `bitrate` while playing costs them nothing and takes effect from the next frame. None takes a quantiser ceiling
/// cleanly (measured on GStreamer 1.24: x264enc's and openh264enc's `qp-max` can't change while playing; NVENC's can, but each
/// change makes the next frame an IDR). VA isn't measured: `BLURT_REMOTE_BOOST=1` tries any element.
///
/// Each element's (gain, most): how `boost_seconds` is scaled for it, tuned by measurement at 2 Mbps (§2026-11-11). x264's ABR
/// answers a raised rate slowly (asked for 0.36 s of the rate, it made 0.1–0.2 s), so it's asked for four times as much; NVENC's
/// CBR spends the whole buffer the still time filled on the first raised frame, so it's asked for half.
fn boosts(element: &str) -> Option<(f64, f64)> {
    match element {
        "x264enc" => Some((4.0, 1.2)),
        "nvcudah264enc" => Some((0.5, 0.18)),
        _ if std::env::var_os("BLURT_REMOTE_BOOST").is_some_and(|v| v == "1") => Some((1.0, 0.36)),
        _ => None,
    }
}

/// The elements that answer any change of bitrate with a keyframe (measured, 103–168 KB at 2 Mbps): x265enc, openh264enc and
/// GStreamer 1.24's nvh264enc / nvh265enc (nvbaseenc; the newer GstNvEncoder, nvcuda*enc, doesn't).
fn rekeys_on_rate(element: &str, e: &gst::Element) -> bool {
    matches!(element, "x265enc" | "openh264enc") || (matches!(element, "nvh264enc" | "nvh265enc") && e.find_property("max-qp-p").is_none())
}

/// How much of the bitrate a sharpening resend made under `max_qp` is given, in seconds of it. The encoder is told 60 fps
/// (NOMINAL_FPS) and so gives a frame 1/fps of the rate; a resend comes 0.1–0.2 s after the last frame and is owed that much,
/// then more the finer the step (twice as much every 6 below 46), × the element's gain, up to its most (`boosts`), aimed at a
/// resend that costs about the 0.4 s of the rate sharpen.rs steers by.
fn boost_seconds(max_qp: u8, since_last: f64, (gain, most): (f64, f64)) -> f64 {
    (gain * since_last.clamp(0.1, 0.25) * 2f64.powf((46.0 - max_qp as f64) / 6.0)).min(most)
}

/// Whether `e` lets `prop` change while it plays.
fn mutable_playing(e: &gst::Element, prop: &str) -> bool {
    e.find_property(prop).is_some_and(|p| p.flags().contains(gst::PARAM_FLAG_MUTABLE_PLAYING) && p.flags().contains(glib::ParamFlags::WRITABLE))
}

impl Encoder {
    /// A pipeline for `element` (math::choose_encoder) at the output size, frames to `sink`: (unit, crop, captured, encode ms).
    /// `repairs`: the phone repairs the picture (no periodic keyframes).
    #[allow(clippy::too_many_arguments)]
    pub fn new(element: &str, codec: Codec, width: u32, height: u32, bitrate: u32, fps: u32, repairs: bool, sink: UnitSink) -> Result<Encoder, String> {
        init()?;
        let format = super::math::encoder_format(element);
        let (parse, caps) = match codec {
            Codec::H264 => ("h264parse", "video/x-h264,stream-format=byte-stream,alignment=au"),
            Codec::Hevc => ("h265parse", "video/x-h265,stream-format=byte-stream,alignment=au"),
        };
        let threads = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(4).min(8);
        // videoconvertscale (1.22+) converts and scales in one pass; older GStreamer has the pair
        let scale = if gst::ElementFactory::find("videoconvertscale").is_some() {
            format!("videoconvertscale name=scale n-threads={threads} add-borders=false method=bilinear chroma-mode=full")
        } else {
            format!("videoscale add-borders=false n-threads={threads} ! videoconvert n-threads={threads}")
        };
        let desc = format!(
            "appsrc name=src is-live=true format=time do-timestamp=false block=false max-buffers=0 ! \
             {scale} ! video/x-raw,format={format},width={width},height={height},pixel-aspect-ratio=1/1 ! \
             {element} name=enc ! {parse} config-interval=-1 ! {caps} ! appsink name=sink sync=false max-buffers=8 drop=false"
        );
        let pipeline = gst::parse::launch(&desc)
            .map_err(|e| format!("{element}: {e}"))?
            .downcast::<gst::Pipeline>()
            .map_err(|_| "not a pipeline".to_string())?;
        let src = pipeline.by_name("src").and_then(|e| e.downcast::<gst_app::AppSrc>().ok()).ok_or("no appsrc")?;
        let enc = pipeline.by_name("enc").ok_or("no encoder")?;
        configure(&enc, element, bitrate, fps, repairs);
        let appsink = pipeline.by_name("sink").and_then(|e| e.downcast::<gst_app::AppSink>().ok()).ok_or("no appsink")?;
        let pending: Arc<Mutex<VecDeque<InFlight>>> = Arc::default();
        let p2 = pending.clone();
        let sets = Mutex::new(Vec::<Vec<u8>>::new());
        appsink.set_callbacks(
            gst_app::AppSinkCallbacks::builder()
                .new_sample(move |s| {
                    let sample = s.pull_sample().map_err(|_| gst::FlowError::Eos)?;
                    let Some(buf) = sample.buffer() else { return Ok(gst::FlowSuccess::Ok) };
                    // in order, one out for each in (the encoder runs with no reordering and drops nothing; the base class
                    // moves timestamps by 1000 h, so they can't be matched)
                    let info = p2.lock().unwrap().pop_front().map(|(_, c, cap, at)| (c, cap, at));
                    let Ok(map) = buf.map_readable() else { return Ok(gst::FlowSuccess::Ok) };
                    let unit = nal::to_unit(codec, map.as_slice(), &mut sets.lock().unwrap());
                    if std::env::var_os("BLURT_REMOTE_DEBUG").is_some_and(|v| v == "2") {
                        let types: Vec<u8> = nal::split_annexb(map.as_slice()).iter().map(|n| n[0] & 0x1f).collect();
                        eprintln!("blurt-remote: encoded {} bytes, NAL types {types:?}, unit {}, info {}", map.len(), unit.is_some(), info.is_some());
                    }
                    if let (Some(u), Some((crop, captured, at))) = (unit, info) {
                        sink(u, crop, captured, at.elapsed().as_secs_f64() * 1000.0);
                    }
                    Ok(gst::FlowSuccess::Ok)
                })
                .build(),
        );
        // a frame's bitrate goes on as it reaches the encoder and the one `set_rate` asked for comes back with the next, so a
        // raised one is exactly that frame's (appsrc → convert → encoder is one streaming thread, in order)
        let base = bitrate_value(element, nominal_bitrate(bitrate, fps));
        let rates = Arc::new(Mutex::new(Rates { base, queue: VecDeque::new(), applied: base }));
        let boost = boosts(element).filter(|_| mutable_playing(&enc, "bitrate"));
        if boost.is_some() {
            let (r2, weak) = (rates.clone(), enc.downgrade());
            enc.static_pad("sink").ok_or("no encoder input")?.add_probe(gst::PadProbeType::BUFFER, move |_, info| {
                let (Some(pts), Some(e)) = (info.buffer().and_then(|b| b.pts()), weak.upgrade()) else { return gst::PadProbeReturn::Ok };
                let pts = pts.nseconds();
                let mut r = r2.lock().unwrap();
                while r.queue.front().is_some_and(|f| f.0 < pts) {
                    r.queue.pop_front();
                }
                let want = if r.queue.front().is_some_and(|f| f.0 == pts) { r.queue.pop_front().unwrap().1 } else { r.base };
                if want != r.applied {
                    e.set_property_from_str("bitrate", &want.to_string());
                    r.applied = want;
                }
                gst::PadProbeReturn::Ok
            });
        }
        let rekeys = rekeys_on_rate(element, &enc);
        pipeline.set_state(gst::State::Playing).map_err(|e| format!("{element} won't start: {e}"))?;
        Ok(Encoder {
            pipeline,
            src,
            enc,
            element: element.to_string(),
            codec,
            width,
            height,
            caps: Mutex::new(None),
            pending,
            rates,
            fps: Mutex::new(fps.clamp(1, NOMINAL_FPS)),
            boost,
            rekeys,
            last_pts: Mutex::new(0),
            start: std::time::Instant::now(),
        })
    }

    /// Encode one picture; `key`: as a keyframe (with its parameter sets).
    pub fn push(&self, p: &Picture, key: bool) -> Result<(), String> {
        self.push_capped(p, key, None)
    }

    /// Whether `push_capped` sharpens a resend with this element (`boosts`).
    pub fn caps_quantiser(&self) -> bool {
        self.boost.is_some()
    }

    /// Whether `set_rate` to another bitrate costs nothing (no keyframe: `rekeys_on_rate`).
    pub fn rate_change_is_cheap(&self) -> bool {
        !self.rekeys
    }

    /// `push`, for a resend of the last picture as sharp as quantising no block more coarsely than `max_qp` would make it: that
    /// one frame is given the bitrate the step needs (`boost_seconds`), where `caps_quantiser`; else as `push`. Every other
    /// frame is made at the rate `set_rate` asked for.
    pub fn push_capped(&self, p: &Picture, key: bool, max_qp: Option<u8>) -> Result<(), String> {
        {
            let mut c = self.caps.lock().unwrap();
            if *c != Some((p.width, p.height, p.format)) {
                let caps = gst::Caps::builder("video/x-raw")
                    .field("format", p.format)
                    .field("width", p.width as i32)
                    .field("height", p.height as i32)
                    .field("framerate", gst::Fraction::new(NOMINAL_FPS as i32, 1))
                    .field("pixel-aspect-ratio", gst::Fraction::new(1, 1))
                    .build();
                self.src.set_caps(Some(&caps));
                *c = Some((p.width, p.height, p.format));
            }
        }
        if key {
            // in the stream, right before this picture (appsrc queues it with the buffers): an upstream event at the encoder's
            // output could land on a picture still on its way (measured: one frame early, 4 runs in 6 on 4 vCPUs)
            let ev = gstreamer_video::DownstreamForceKeyUnitEvent::builder().all_headers(true).build();
            self.src.send_event(ev);
        }
        // real time, strictly rising: the rate control reads a resend as time passing, not as part of a burst
        let (pts, since_last) = {
            let mut last = self.last_pts.lock().unwrap();
            let now = self.start.elapsed().as_nanos() as u64;
            let since = now.saturating_sub(*last) as f64 / 1e9;
            *last = now.max(*last + 1_000_000);
            (*last, since)
        };
        let mut buf = gst::Buffer::from_slice(Bytes(p.data.clone()));
        {
            let b = buf.get_mut().unwrap();
            b.set_pts(gst::ClockTime::from_nseconds(pts));
            b.set_duration(gst::ClockTime::NONE);
        }
        {
            let mut q = self.pending.lock().unwrap();
            q.push_back((pts, p.crop, p.captured, std::time::Instant::now()));
        }
        if let (Some(q), Some(b), false) = (max_qp, self.boost, key) {
            // a frame's share at the encoder's rate is base / NOMINAL_FPS; this one is to be `boost_seconds` of the real rate
            let fps = *self.fps.lock().unwrap() as f64;
            let mut r = self.rates.lock().unwrap();
            let v = (r.base as f64 * fps * boost_seconds(q, since_last, b)).round().min(u32::MAX as f64) as u32;
            let v = v.max(r.base);
            r.queue.push_back((pts, v));
        }
        self.src.push_buffer(buf).map(|_| ()).map_err(|e| format!("push: {e:?}"))
    }

    /// Two pictures are in the encoder already: the next waits (and a newer one may take its place), so nothing queues up.
    pub fn busy(&self) -> bool {
        self.pending.lock().unwrap().len() >= 2
    }

    /// A new rate for the running encoder (no restart): `fps` is what's actually sent. The same value again does nothing (on the
    /// elements that `rekeys_on_rate` a change costs a keyframe); a change takes 0.02–0.07 ms.
    pub fn set_rate(&self, bitrate: u32, fps: u32) {
        let v = bitrate_value(&self.element, nominal_bitrate(bitrate, fps));
        *self.fps.lock().unwrap() = fps.clamp(1, NOMINAL_FPS);
        let mut r = self.rates.lock().unwrap();
        r.base = v;
        if v != r.applied && self.enc.find_property("bitrate").is_some() {
            self.enc.set_property_from_str("bitrate", &v.to_string());
            r.applied = v;
        }
    }

    /// Something went wrong in the pipeline since the last call (an element error), in words.
    pub fn error(&self) -> Option<String> {
        let bus = self.pipeline.bus()?;
        while let Some(m) = bus.pop() {
            if let gst::MessageView::Error(e) = m.view() {
                return Some(format!("{}: {}", e.src().map(|s| s.name().to_string()).unwrap_or_default(), e.error()));
            }
        }
        None
    }
}

impl Drop for Encoder {
    fn drop(&mut self) {
        let _ = self.pipeline.set_state(gst::State::Null);
    }
}

#[cfg(test)]
mod tests {
    //! The real encoder, no screen: frames from videotestsrc (a moving ball over colour bars, and a still one) go through the
    //! same Mirror and Encoder the backend uses, while the crop and the bitrate change; the result is decoded with
    //! avdec_h264 to prove it plays and has one size. Skipped where x264enc / avdec_h264 aren't installed.
    use super::*;
    use crate::platform::linux::math::{crop_rect, rect_crop};
    use crate::platform::linux::mirror::Mirror;
    use std::time::Duration;

    const W: u32 = 1920;
    const H: u32 = 1080;

    fn source_frames(n: usize, pattern: &str) -> Vec<Vec<u8>> {
        let p = gst::parse::launch(&format!(
            "videotestsrc pattern={pattern} num-buffers={n} ! video/x-raw,format=BGRx,width={W},height={H},framerate=60/1 ! appsink name=s sync=false"
        ))
        .unwrap()
        .downcast::<gst::Pipeline>()
        .unwrap();
        let s = p.by_name("s").unwrap().downcast::<gst_app::AppSink>().unwrap();
        p.set_state(gst::State::Playing).unwrap();
        let mut out = vec![];
        while let Ok(sample) = s.pull_sample() {
            out.push(sample.buffer().unwrap().map_readable().unwrap().to_vec());
        }
        p.set_state(gst::State::Null).unwrap();
        out
    }

    /// Decode an Annex B stream; the sizes of the decoded pictures.
    fn decode(stream: &[u8]) -> Vec<(i32, i32)> {
        let p = gst::parse::launch(
            "appsrc name=a caps=video/x-h264,stream-format=byte-stream,alignment=au ! h264parse ! avdec_h264 ! appsink name=s sync=false",
        )
        .unwrap()
        .downcast::<gst::Pipeline>()
        .unwrap();
        let a = p.by_name("a").unwrap().downcast::<gst_app::AppSrc>().unwrap();
        let s = p.by_name("s").unwrap().downcast::<gst_app::AppSink>().unwrap();
        p.set_state(gst::State::Playing).unwrap();
        a.push_buffer(gst::Buffer::from_slice(stream.to_vec())).unwrap();
        a.end_of_stream().unwrap();
        let mut sizes = vec![];
        while let Ok(sample) = s.pull_sample() {
            let st = sample.caps().unwrap().structure(0).unwrap().to_owned();
            sizes.push((st.get::<i32>("width").unwrap(), st.get::<i32>("height").unwrap()));
        }
        let bus = p.bus().unwrap();
        while let Some(m) = bus.pop() {
            if let gst::MessageView::Error(e) = m.view() {
                panic!("decode: {}", e.error());
            }
        }
        p.set_state(gst::State::Null).unwrap();
        sizes
    }

    type Got = Arc<Mutex<Vec<(Unit, Crop, f64, f64)>>>;

    fn encoder(out: (u32, u32), bitrate: u32) -> Option<(Encoder, Got)> {
        if !has_element("x264enc") || !has_element("avdec_h264") {
            eprintln!("skipped: x264enc / avdec_h264 not installed");
            return None;
        }
        let got: Got = Arc::default();
        let g = got.clone();
        let e = Encoder::new("x264enc", Codec::H264, out.0, out.1, bitrate, 60, false, Arc::new(move |u, c, cap, ms| g.lock().unwrap().push((u, c, cap, ms))))
            .expect("x264 pipeline");
        Some((e, got))
    }

    fn wait_for(got: &Got, n: usize) {
        for _ in 0..200 {
            if got.lock().unwrap().len() >= n {
                return;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
    }

    #[test]
    fn crops_and_bitrate_change_while_running_and_it_plays() {
        let Some((enc, got)) = encoder((1280, 720), 4_000_000) else { return };
        // noise: every frame new everywhere, the worst case for the rate control (as scrolling text is)
        let frames = source_frames(120, "snow");
        let mut m = Mirror::default();
        let crops = [
            Crop::WHOLE,
            Crop { x: 0.25, y: 0.25, w: 0.5, h: 0.5 },
            Crop { x: 0.6, y: 0.1, w: 0.3333, h: 0.3333 },
            Crop { x: 0.0, y: 0.5, w: 0.5, h: 0.5 },
        ];
        let mut sent = 0;
        let t0 = std::time::Instant::now();
        for (i, f) in frames.iter().enumerate() {
            m.apply(f, W as usize * 4, W, H, "BGRx", None);
            // a new crop every 8 frames (7 a second at 60 fps); the bitrate halves halfway
            let c = crops[(i / 8) % crops.len()];
            let r = crop_rect(c, W, H);
            let Some(Some(px)) = m.cut(r, None) else { panic!("cut") };
            if i == 60 {
                enc.set_rate(1_000_000, 60);
            }
            let key = i == 0 || i == 90;
            enc.push(&Picture { data: Arc::new(px), width: r.w, height: r.h, format: "BGRx", crop: rect_crop(r, W, H), captured: i as f64 }, key).unwrap();
            sent += 1;
            std::thread::sleep(Duration::from_millis(4));
            while enc.busy() {
                std::thread::sleep(Duration::from_millis(1));
            }
            assert_eq!(enc.error(), None);
        }
        wait_for(&got, sent);
        let elapsed = t0.elapsed();
        let got = got.lock().unwrap();
        assert!(got.len() >= sent - 2, "{} of {sent} frames came out", got.len());
        // keyframes: the first and the one asked for, each with SPS + PPS; nothing else is a keyframe
        let keys: Vec<usize> = got.iter().filter(|g| g.0.keyframe).map(|g| g.2 as usize).collect();
        assert_eq!(keys, vec![0, 90], "keyframes where asked, and only there");
        let mut stream = vec![];
        for (u, c, captured, _) in got.iter() {
            assert_eq!(u.parameter_sets.is_empty(), !u.keyframe);
            if u.keyframe {
                assert_eq!(u.parameter_sets.len(), 2);
                assert_eq!(u.parameter_sets[0][0] & 0x1f, 7, "SPS first");
                assert_eq!(u.parameter_sets[1][0] & 0x1f, 8, "then PPS");
            }
            // length-prefixed slices only: no start codes, no parameter sets, no SEI / AUD
            for nal in nal::split_lengths(&u.picture).expect("4-byte lengths") {
                assert!(matches!(nal[0] & 0x1f, 1 | 5), "NAL type {}", nal[0] & 0x1f);
            }
            // frames say which crop they show
            let i = *captured as usize;
            let want = rect_crop(crop_rect(crops[(i / 8) % crops.len()], W, H), W, H);
            assert_eq!(*c, want, "frame {i}");
            stream.extend(nal::annexb(u));
        }
        // the bitrate change took: the second half (before the keyframe) is smaller
        let size = |r: std::ops::Range<usize>| {
            let n = got.iter().filter(|g| r.contains(&(g.2 as usize))).count().max(1);
            got.iter().filter(|g| r.contains(&(g.2 as usize))).map(|g| g.0.picture.len()).sum::<usize>() / n
        };
        let (hi, lo) = (size(20..55), size(65..88));
        assert!(lo * 10 < hi * 7, "after 4→1 Mbps: {hi} → {lo} bytes");
        let ms: Vec<f64> = got.iter().map(|g| g.3).collect();
        let mean = ms.iter().sum::<f64>() / ms.len() as f64;
        eprintln!(
            "x264 1280×720: {} frames in {:.2}s, convert+encode {:.1} ms mean, {:.1} ms max, {} → {} bytes a frame at 4 → 1 Mbps",
            got.len(),
            elapsed.as_secs_f64(),
            mean,
            ms.iter().cloned().fold(0.0, f64::max),
            hi,
            lo
        );
        let sizes = decode(&stream);
        assert!(sizes.len() >= got.len() - 1, "decoded {} of {}", sizes.len(), got.len());
        assert!(sizes.iter().all(|&s| s == (1280, 720)), "one output size whatever the crop: {:?}", sizes.iter().find(|&&s| s != (1280, 720)));
    }

    #[test]
    fn a_still_screen_sends_nothing_new_and_a_refresh_sharpens_it() {
        let Some((enc, got)) = encoder((960, 540), 300_000) else { return };
        let frames = source_frames(3, "smpte");
        let mut m = Mirror::default();
        let r = crop_rect(Crop::WHOLE, W, H);
        m.apply(&frames[0], W as usize * 4, W, H, "BGRx", None);
        let first = m.cut(r, None).unwrap().unwrap();
        // the same picture again: the cut says so, nothing is pushed
        m.apply(&frames[0].clone(), W as usize * 4, W, H, "BGRx", None);
        assert!(m.cut(r, Some(&first)).unwrap().is_none());
        let p = Picture { data: Arc::new(first), width: r.w, height: r.h, format: "BGRx", crop: Crop::WHOLE, captured: 0.0 };
        enc.push(&p, true).unwrap();
        // a refresh: the same picture encoded again, several times, each time smaller
        for _ in 0..4 {
            std::thread::sleep(Duration::from_millis(30));
            enc.push(&p, false).unwrap();
        }
        wait_for(&got, 5);
        let got = got.lock().unwrap();
        let sizes: Vec<usize> = got.iter().map(|g| g.0.picture.len()).collect();
        eprintln!("still frame at 300 kbps: {sizes:?} bytes");
        assert_eq!(sizes.len(), 5);
        assert!(got[0].0.keyframe && !got[1].0.keyframe);
        assert!(got[1..].iter().all(|g| !g.0.keyframe && g.0.parameter_sets.is_empty()), "resends are P-frames");
    }
}
