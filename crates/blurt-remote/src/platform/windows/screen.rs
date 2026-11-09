//! The monitor under the pointer, to the phone (the Mac's RemoteScreen.swift): capture → crop + scale + NV12 on the GPU →
//! hardware encoder → length-prefixed NAL units. One worker thread owns every D3D11 / WinRT / Media Foundation object; the
//! `Screen` the server holds only sends it commands, so it is Send whatever COM is.
//!
//! * The output size is fixed for the stream (the monitor's shape, as large as asked for, never more pixels than the monitor
//!   has); a crop is a source rectangle, changed between two frames.
//! * The last capture is kept whole on the GPU: a crop change, `refresh` and `keyframe` are made from it at once, still screen
//!   or not. Every frame says which crop it shows, exactly (to the pixel).
//! * A still screen sends nothing: WGC and Desktop Duplication only give a frame when something changed, their dirty regions
//!   (where the OS has them) skip changes outside the crop, and otherwise the new NV12 output is compared byte for byte with
//!   the last one sent, as the Mac compares its frames.

use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use ::windows::core::Interface;
use ::windows::Win32::Foundation::HMODULE;
use ::windows::Win32::Graphics::Direct3D::{D3D_DRIVER_TYPE_HARDWARE, D3D_DRIVER_TYPE_UNKNOWN};
use ::windows::Win32::Graphics::Direct3D11::{
    D3D11CreateDevice, ID3D11Device, ID3D11Multithread, D3D11_CREATE_DEVICE_BGRA_SUPPORT, D3D11_CREATE_DEVICE_VIDEO_SUPPORT,
    D3D11_SDK_VERSION,
};
use ::windows::Win32::Graphics::Dxgi::{CreateDXGIFactory1, IDXGIAdapter, IDXGIFactory1, IDXGIOutput1};
use ::windows::Win32::Graphics::Gdi::HMONITOR;
use ::windows::Win32::Media::MediaFoundation::{MFShutdown, MFStartup, MFSTARTUP_FULL, MF_VERSION};
use ::windows::Win32::System::Com::{CoInitializeEx, CoUninitialize, COINIT_MULTITHREADED};

use super::annexb::{self, Codec};
use super::capture::{Capture, Signal, Synthetic};
use super::convert::Converter;
use super::encoder::Encoder;
use super::geometry::{self, Monitor, Rect};
use super::imp::Shown;
use super::monitors;
use super::pacing::{Next, Pacer};
use crate::host::{Crop, EncodedFrame, FrameSink, Screen, ScreenConfig, ScreenInfo};

/// The software encoder's longest side: Microsoft's H.264 MFT on a CPU keeps 30 fps at about this size.
const SOFTWARE_LONGEST: u32 = 1280;

/// Where pictures come from.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Source {
    /// the monitor under the pointer
    Monitor,
    /// text-like rows scrolling, this size, no desktop needed (measuring the encoder from a service or an SSH session)
    Synthetic { width: u32, height: u32 },
}

/// How to start, beyond what the phone asked for.
#[derive(Clone, Copy, Debug)]
pub struct Options {
    pub source: Source,
    /// skip the hardware encoders (measuring the fallback)
    pub software: bool,
}

impl Default for Options {
    fn default() -> Self {
        Options { source: Source::Monitor, software: false }
    }
}

/// Numbers since the last `take_stats`.
#[derive(Clone, Debug, Default)]
pub struct Stats {
    pub frames: u32,
    pub keyframes: u32,
    pub bytes: u64,
    /// from the picture going to the encoder to its output
    pub encode_ms: f64,
    /// the video processor's blit and, when made, the read-back compare
    pub convert_ms: f64,
    /// captures that changed nothing in the crop, and outputs that came out the same as the last
    pub skipped: u32,
    pub captured: u32,
    pub seconds: f64,
    pub capture: &'static str,
    pub encoder: String,
    pub codec: &'static str,
    pub width: u32,
    pub height: u32,
}

impl Stats {
    pub fn fps(&self) -> f64 {
        self.frames as f64 / self.seconds.max(1e-3)
    }
    pub fn kbps(&self) -> f64 {
        self.bytes as f64 * 8.0 / self.seconds.max(1e-3) / 1000.0
    }
    pub fn encode_ms_avg(&self) -> f64 {
        self.encode_ms / self.frames.max(1) as f64
    }
    pub fn convert_ms_avg(&self) -> f64 {
        self.convert_ms / self.frames.max(1) as f64
    }
}

enum Cmd {
    Crop(Crop),
    Rate(u32, u32),
    Keyframe,
    Refresh,
    Stop,
}

struct Running {
    tx: Sender<Cmd>,
    signal: Signal,
    thread: Option<JoinHandle<()>>,
}

pub struct WinScreen {
    shown: Shown,
    running: Option<Running>,
    stats: Arc<Mutex<(Stats, Instant)>>,
    pub options: Options,
}

impl WinScreen {
    pub fn new(shown: Shown) -> Self {
        WinScreen { shown, running: None, stats: Arc::new(Mutex::new((Stats::default(), Instant::now()))), options: Options::default() }
    }

    /// The numbers since the last call (the Mac logs the same every 2 s as `remote_screen_mac`).
    pub fn take_stats(&self) -> Stats {
        let mut g = self.stats.lock().unwrap_or_else(|e| e.into_inner());
        let (s, since) = &mut *g;
        let mut out = std::mem::take(s);
        out.seconds = since.elapsed().as_secs_f64();
        s.capture = out.capture;
        s.encoder = out.encoder.clone();
        s.codec = out.codec;
        s.width = out.width;
        s.height = out.height;
        *since = Instant::now();
        out
    }

    fn send(&self, c: Cmd) {
        if let Some(r) = &self.running {
            let _ = r.tx.send(c);
            r.signal.notify();
        }
    }
}

impl Screen for WinScreen {
    fn start(&mut self, config: &ScreenConfig, sink: FrameSink) -> Result<ScreenInfo, String> {
        self.stop();
        let (tx, rx) = channel();
        let (ready_tx, ready_rx) = channel();
        let signal = Signal::default();
        let worker = Worker {
            config: config.clone(),
            options: self.options,
            sink,
            rx,
            signal: signal.clone(),
            shown: self.shown.clone(),
            stats: self.stats.clone(),
        };
        let thread = std::thread::Builder::new()
            .name("blurt-remote-screen".into())
            .spawn(move || worker.run(ready_tx))
            .map_err(|e| e.to_string())?;
        self.running = Some(Running { tx, signal, thread: Some(thread) });
        match ready_rx.recv_timeout(Duration::from_secs(10)) {
            Ok(Ok(info)) => Ok(info),
            Ok(Err(e)) => {
                self.stop();
                Err(e)
            }
            Err(_) => {
                self.stop();
                Err("The screen didn't start in time.".into())
            }
        }
    }

    fn set_crop(&mut self, crop: Crop) {
        self.send(Cmd::Crop(crop));
    }

    fn set_rate(&mut self, bitrate: u32, fps: u32) {
        self.send(Cmd::Rate(bitrate, fps));
    }

    fn keyframe(&mut self) {
        self.send(Cmd::Keyframe);
    }

    fn refresh(&mut self) {
        self.send(Cmd::Refresh);
    }

    fn stop(&mut self) {
        if let Some(mut r) = self.running.take() {
            let _ = r.tx.send(Cmd::Stop);
            r.signal.notify();
            if let Some(t) = r.thread.take() {
                let _ = t.join();
            }
        }
        *self.shown.lock().unwrap_or_else(|e| e.into_inner()) = None;
    }
}

impl Drop for WinScreen {
    fn drop(&mut self) {
        self.stop();
    }
}

struct Worker {
    config: ScreenConfig,
    options: Options,
    sink: FrameSink,
    rx: Receiver<Cmd>,
    signal: Signal,
    shown: Shown,
    stats: Arc<Mutex<(Stats, Instant)>>,
}

/// What each frame going into the encoder carries out again.
#[derive(Clone, Copy)]
struct Tag {
    crop: Crop,
    captured: f64,
    started: Instant,
}

/// The adapter that drives this monitor, and its DXGI output (Desktop Duplication needs both to be the same GPU).
fn adapter_for(monitor: HMONITOR) -> Option<(IDXGIAdapter, Option<IDXGIOutput1>)> {
    unsafe {
        let f: IDXGIFactory1 = CreateDXGIFactory1().ok()?;
        let mut i = 0;
        while let Ok(a) = f.EnumAdapters1(i) {
            let mut j = 0;
            while let Ok(o) = a.EnumOutputs(j) {
                if let Ok(d) = o.GetDesc() {
                    if d.Monitor == monitor {
                        return Some((a.cast().ok()?, o.cast().ok()));
                    }
                }
                j += 1;
            }
            i += 1;
        }
    }
    None
}

/// Microsoft's Basic Display / Basic Render adapter (PCI vendor 0x1414): no video encoder, no video processor worth the name.
const MICROSOFT_VENDOR: u32 = 0x1414;

fn vendor(a: &IDXGIAdapter) -> u32 {
    unsafe { a.GetDesc() }.map_or(0, |d| d.VendorId)
}

/// The first GPU that isn't Microsoft's basic adapter: where a monitor's own adapter has no encoder (a VM's virtual display beside
/// its real GPU, a remote session's indirect display), capture on that GPU instead; WGC copies across adapters.
fn hardware_adapter() -> Option<IDXGIAdapter> {
    unsafe {
        let f: IDXGIFactory1 = CreateDXGIFactory1().ok()?;
        let mut i = 0;
        while let Ok(a) = f.EnumAdapters1(i) {
            let a: IDXGIAdapter = a.cast().ok()?;
            if vendor(&a) != MICROSOFT_VENDOR {
                return Some(a);
            }
            i += 1;
        }
    }
    None
}

fn create_device(adapter: Option<&IDXGIAdapter>) -> Result<ID3D11Device, String> {
    let mut device = None;
    let flags = D3D11_CREATE_DEVICE_BGRA_SUPPORT | D3D11_CREATE_DEVICE_VIDEO_SUPPORT;
    unsafe {
        let r = match adapter {
            Some(a) => D3D11CreateDevice(a, D3D_DRIVER_TYPE_UNKNOWN, HMODULE::default(), flags, None, D3D11_SDK_VERSION, Some(&mut device), None, None),
            None => D3D11CreateDevice(None, D3D_DRIVER_TYPE_HARDWARE, HMODULE::default(), flags, None, D3D11_SDK_VERSION, Some(&mut device), None, None),
        };
        r.map_err(|e| format!("Direct3D 11: {e}"))?;
    }
    let device = device.ok_or("Direct3D 11: no device")?;
    // Media Foundation's encoders use the device from their own threads
    if let Ok(mt) = device.cast::<ID3D11Multithread>() {
        let _ = unsafe { mt.SetMultithreadProtected(true) };
    }
    Ok(device)
}

enum Enc {
    Gpu(Encoder<Tag>),
    Cpu(Encoder<Tag>),
}

impl Enc {
    fn get(&mut self) -> &mut Encoder<Tag> {
        match self {
            Enc::Gpu(e) | Enc::Cpu(e) => e,
        }
    }
}

impl Worker {
    fn run(self, ready: Sender<Result<ScreenInfo, String>>) {
        let _dpi = monitors::Dpi::physical();
        let com = unsafe { CoInitializeEx(None, COINIT_MULTITHREADED) }.is_ok();
        let mf = unsafe { MFStartup(MF_VERSION, MFSTARTUP_FULL) }.is_ok();
        let mut ready = Some(ready);
        if let Err(e) = self.stream(&mut ready) {
            if let Some(r) = ready.take() {
                let _ = r.send(Err(e));
            } else {
                log(&format!("stopped: {e}"));
            }
        }
        if mf {
            let _ = unsafe { MFShutdown() };
        }
        if com {
            unsafe { CoUninitialize() };
        }
    }

    fn open_encoder(&self, device: &ID3D11Device, src: (u32, u32)) -> Result<(Enc, (u32, u32)), String> {
        let c = &self.config;
        let fps = c.fps.clamp(1, 120);
        let bitrate = c.bitrate.clamp(100_000, 50_000_000);
        let mut errors = Vec::new();
        if !self.options.software {
            let size = geometry::output_size(c.width, c.height, src.0, src.1, None);
            let wants: Vec<&str> = if c.codecs.is_empty() { vec!["hevc"] } else { c.codecs.iter().map(|s| s.as_str()).collect() };
            for w in wants {
                let codec = match w {
                    "hevc" => Codec::Hevc,
                    "h264" => Codec::H264,
                    _ => continue,
                };
                match Encoder::hardware(device, codec, size.0, size.1, fps, bitrate) {
                    Ok(e) => return Ok((Enc::Gpu(e), size)),
                    Err(e) => {
                        log(&format!("hardware {w} at {}×{}: {e}", size.0, size.1));
                        errors.push(e)
                    }
                }
            }
        }
        // a phone that sent no list predates codecs and decodes HEVC only (remote-protocol.md §Video codecs)
        if c.codecs.iter().any(|s| s == "h264") {
            let size = geometry::output_size(c.width, c.height, src.0, src.1, Some(SOFTWARE_LONGEST));
            match Encoder::software(size.0, size.1, fps, bitrate) {
                Ok(e) => return Ok((Enc::Cpu(e), size)),
                Err(e) => errors.push(e),
            }
        }
        log(&format!("no encoder: {}", errors.join("; ")));
        Err("This PC has no video encoder for the phone's formats.".into())
    }

    fn stream(&self, ready: &mut Option<Sender<Result<ScreenInfo, String>>>) -> Result<(), String> {
        // the monitor, its GPU, the capture
        let (monitor, adapter, output) = match self.options.source {
            Source::Monitor => {
                let m = monitors::under_pointer().ok_or("There is no screen to show.")?;
                let (a, o) = adapter_for(HMONITOR(m.handle as *mut _)).map_or((None, None), |(a, o)| (Some(a), o));
                (m, a, o)
            }
            Source::Synthetic { width, height } => {
                let r = Rect { left: 0, top: 0, right: width as i32, bottom: height as i32 };
                (Monitor { rect: r, scale: 1.0, primary: true, handle: 0 }, None, None)
            }
        };
        // the monitor's own GPU (Desktop Duplication needs it, and a laptop's iGPU has its own encoder), unless it is Microsoft's
        // basic adapter: then a real GPU's
        let adapter = match adapter {
            Some(a) if vendor(&a) != MICROSOFT_VENDOR => Some(a),
            other => hardware_adapter().or(other),
        };
        let device = create_device(adapter.as_ref()).or_else(|_| create_device(None))?;
        if let Some(a) = &adapter {
            if let Ok(d) = unsafe { a.GetDesc() } {
                let n = d.Description.iter().take_while(|c| **c != 0).count();
                log(&format!("adapter: {} (vendor {:#06x})", String::from_utf16_lossy(&d.Description[..n]), d.VendorId));
            }
        }
        let mut capture = match self.options.source {
            Source::Monitor => Capture::monitor(&device, HMONITOR(monitor.handle as *mut _), output.as_ref(), self.signal.clone()).map_err(|e| {
                log(&format!("capture: {e}"));
                "Windows wouldn't let Blurt capture the screen.".to_string()
            })?,
            Source::Synthetic { width, height } => Capture::Synthetic(Synthetic::new(&device, width, height, self.config.fps)?),
        };
        let src = (monitor.rect.width().max(2) as u32, monitor.rect.height().max(2) as u32);
        let (mut enc, out) = self.open_encoder(&device, src)?;
        let mut conv = Converter::new(&device, src.0, src.1, out.0, out.1, self.config.fps)?;
        let codec = enc.get().codec;
        {
            let mut g = self.stats.lock().unwrap_or_else(|e| e.into_inner());
            g.0 = Stats {
                capture: capture.kind(),
                encoder: enc.get().name.clone(),
                codec: codec.wire_name(),
                width: out.0,
                height: out.1,
                ..Default::default()
            };
            g.1 = Instant::now();
        }
        *self.shown.lock().unwrap_or_else(|e| e.into_inner()) = Some(monitor);
        let (pw, ph) = monitor.points();
        let (enc_name, hardware) = (enc.get().name.clone(), enc.get().hardware);
        log(&format!(
            "on: {} {}×{} px ({pw}×{ph} pt) → {}×{} {} via {} ({}), {} kbps {} fps",
            capture.kind(),
            src.0,
            src.1,
            out.0,
            out.1,
            codec.wire_name(),
            enc_name,
            if hardware { "hardware" } else { "software" },
            self.config.bitrate / 1000,
            self.config.fps
        ));
        if let Some(r) = ready.take() {
            let _ = r.send(Ok(ScreenInfo { width: pw, height: ph, codec: codec.wire_name().into() }));
        }

        let mut crop = geometry::valid_crop(self.config.crop);
        let mut pacer = Pacer::new(self.config.fps);
        let mut want_key = true;
        let mut sets: Vec<Vec<u8>> = annexb::parameter_sets(codec, &enc.get().header);
        let mut last_out: Vec<u8> = Vec::new();
        let mut this_out: Vec<u8> = Vec::new();
        let mut captured_at = 0.0;
        let mut dirty_known = false;
        let t0 = Instant::now();
        let mut last_time = -1i64;
        let mut fails = 0;
        loop {
            // commands first
            while let Ok(c) = self.rx.try_recv() {
                match c {
                    Cmd::Stop => return Ok(()),
                    Cmd::Crop(c) => {
                        let c = geometry::valid_crop(c);
                        if c != crop {
                            crop = c;
                            pacer.crop_changed();
                        }
                    }
                    Cmd::Rate(b, f) => {
                        enc.get().set_rate(b.clamp(100_000, 50_000_000), f);
                        pacer.set_fps(f);
                    }
                    Cmd::Keyframe => {
                        want_key = true;
                        pacer.keyframe();
                    }
                    Cmd::Refresh => pacer.refresh(),
                }
            }
            let now = monitors::now();
            let wait = match pacer.next(now) {
                Next::Encode(due) => {
                    let (rect, shown_crop) = geometry::crop_rect(crop, conv.in_w, conv.in_h);
                    let started = Instant::now();
                    let nv12 = match conv.render(&rect) {
                        Ok(t) => t,
                        Err(e) => {
                            log(&e);
                            pacer.done(now, false);
                            continue;
                        }
                    };
                    let cpu = matches!(enc, Enc::Cpu(_));
                    // nothing new in the picture: compare what came out with what went last (a crop change or a forced one goes anyway)
                    let compare = cpu || (due.changed && !due.forced && !dirty_known);
                    if compare {
                        if let Err(e) = conv.read(&nv12, &mut this_out) {
                            log(&e);
                        }
                    }
                    let convert_ms = started.elapsed().as_secs_f64() * 1000.0;
                    if compare && !due.forced && !this_out.is_empty() && this_out == last_out && !want_key {
                        pacer.done(now, false);
                        self.stats.lock().unwrap_or_else(|e| e.into_inner()).0.skipped += 1;
                        continue;
                    }
                    if compare {
                        std::mem::swap(&mut last_out, &mut this_out);
                    } else {
                        last_out.clear();
                    }
                    let key = want_key || due.keyframe;
                    // 100-ns real time, increasing: a resend must not look like part of the burst before it
                    let time = ((t0.elapsed().as_secs_f64() * 1e7) as i64).max(last_time + 1);
                    last_time = time;
                    let tag = Tag { crop: shown_crop, captured: if due.forced && !due.changed { now } else { captured_at }, started };
                    let r = match &mut enc {
                        Enc::Gpu(e) => e.encode_texture(&nv12, time, key, tag),
                        Enc::Cpu(e) => e.encode_memory(&last_out, time, key, tag),
                    };
                    match r {
                        Ok(outs) => {
                            fails = 0;
                            if key {
                                want_key = false;
                            }
                            pacer.done(now, true);
                            for o in outs {
                                self.emit(codec, o, &mut sets, convert_ms);
                            }
                        }
                        Err(e) => {
                            log(&format!("encode: {e}"));
                            pacer.done(now, false);
                            pacer.retry_keyframe();
                            want_key = true;
                            fails += 1;
                            if fails > 30 {
                                return Err(e);
                            }
                        }
                    }
                    Duration::ZERO
                }
                Next::Wait(s) => Duration::from_secs_f64(s.clamp(0.0, 0.1)),
                Next::Idle => Duration::from_millis(100),
            };
            if let Some(f) = capture.next(wait, &self.signal) {
                if f.width != conv.in_w || f.height != conv.in_h {
                    // the monitor changed size: a new converter at the same output size
                    match Converter::new(&device, f.width, f.height, out.0, out.1, self.config.fps) {
                        Ok(c) => conv = c,
                        Err(e) => {
                            log(&e);
                            continue;
                        }
                    }
                    if let Some(m) = self.shown.lock().unwrap_or_else(|e| e.into_inner()).as_mut() {
                        m.rect.right = m.rect.left + f.width as i32;
                        m.rect.bottom = m.rect.top + f.height as i32;
                    }
                }
                conv.hold(&f.texture);
                captured_at = f.time;
                dirty_known = f.dirty.is_some();
                let (rect, _) = geometry::crop_rect(crop, conv.in_w, conv.in_h);
                let in_crop = f.dirty.as_ref().is_none_or(|d| geometry::touches(d, &rect));
                pacer.picture(in_crop);
                let mut g = self.stats.lock().unwrap_or_else(|e| e.into_inner());
                g.0.captured += 1;
                if !in_crop {
                    g.0.skipped += 1;
                }
            }
        }
    }

    fn emit(&self, codec: Codec, o: super::encoder::Output<Tag>, sets: &mut Vec<Vec<u8>>, convert_ms: f64) {
        let sp = annexb::split(codec, &o.annexb);
        if !sp.parameter_sets.is_empty() {
            *sets = sp.parameter_sets.clone();
        }
        if !sp.has_picture {
            return;
        }
        let keyframe = sp.keyframe || o.keyframe;
        let encode_ms = o.tag.started.elapsed().as_secs_f64() * 1000.0 - convert_ms;
        let bytes = sp.picture.len() + if keyframe { sets.iter().map(|s| s.len()).sum::<usize>() } else { 0 };
        {
            let mut g = self.stats.lock().unwrap_or_else(|e| e.into_inner());
            g.0.frames += 1;
            g.0.bytes += bytes as u64;
            g.0.encode_ms += encode_ms.max(0.0);
            g.0.convert_ms += convert_ms;
            if keyframe {
                g.0.keyframes += 1;
            }
        }
        (self.sink)(EncodedFrame {
            picture: sp.picture,
            keyframe,
            parameter_sets: if keyframe { sets.clone() } else { Vec::new() },
            crop: o.tag.crop,
            captured: o.tag.captured,
        });
    }
}

fn log(s: &str) {
    if std::env::var_os("BLURT_REMOTE_LOG").is_some() {
        eprintln!("remote screen (windows): {s}");
    }
}

/// The hardware encoders Media Foundation lists for NV12 → H.264 and → HEVC, by name (examples/win_smoke.rs, diagnostics).
pub fn hardware_encoders() -> Vec<(&'static str, String)> {
    unsafe {
        let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
        let _ = MFStartup(MF_VERSION, MFSTARTUP_FULL);
    }
    let mut out = Vec::new();
    for codec in [Codec::H264, Codec::Hevc] {
        for (name, _) in super::encoder::hardware_encoders(codec) {
            out.push((codec.wire_name(), name));
        }
    }
    out
}
