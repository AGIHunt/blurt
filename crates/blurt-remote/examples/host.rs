//! The real host on any machine, with a backend that presses nothing: every input event is a JSON line on stdout, as the Mac's
//! BLURT_TEST_REMOTE does. Pair a phone with the printed link (`xcrun simctl openurl <device> '<link>'` for the simulator).
//!
//!   cargo run --example host -- [--screen-test] [--answer yes|no|ask] [--relay ws://127.0.0.1:8787] [--dir <folder>] [--port N]
//!   cargo run --example host -- --real    this OS's own backend (platform::backend(): Windows' capture, encoder, SendInput)
//!
//! --screen-test: a synthetic screen, ffmpeg's testsrc2 → libx264 (ultrafast, zerolatency, no B-frames) → H.264 frames as
//! length-prefixed NAL units with SPS/PPS on keyframes; the crop, size and rate are honoured by restarting ffmpeg (roughly).
//! --answer: the pairing question's answer, 3 s after it's asked (the test flag; default yes). `ask`: type yes / no on stdin.
//! --displays N: N made-up displays side by side (1920×1080 main, 2560×1440 to its right and 180 pt higher, 1280×800 left of
//! main), each its own test pattern; the pointer crosses between them and the picture follows it (or what the phone pins).

use std::io::{BufRead, Read, Write};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering::SeqCst};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Instant;

use blurt_remote::host::{Backend, Button, CursorShape, Crop, DisplayInfo, EncodedFrame, FrameSink, Input, Screen, ScreenConfig, ScreenInfo, ScrollPhase, SystemMove};
use blurt_remote::store::FileKeyStore;
use blurt_remote::wire::{BlurtCommand, DictationPhase, Front};
use blurt_remote::{App, Host, HostConfig};
use serde_json::{json, Value};

fn emit(v: Value) {
    let mut o = std::io::stdout().lock();
    let _ = writeln!(o, "{v}");
    let _ = o.flush();
}

fn now() -> f64 {
    static T: OnceLock<Instant> = OnceLock::new();
    T.get_or_init(Instant::now).elapsed().as_secs_f64()
}

/// The made-up desktop: its displays, and the one being shown (the screen sets it, input places the pointer on it).
struct Desk {
    displays: Vec<DisplayInfo>,
    shown: Mutex<String>,
}

impl Desk {
    fn new(n: usize) -> Arc<Desk> {
        let all = [
            DisplayInfo { id: "TEST-1".into(), name: "Test Display 1".into(), x: 0.0, y: 0.0, width: 1920.0, height: 1080.0, main: true },
            DisplayInfo { id: "TEST-2".into(), name: "Test Display 2".into(), x: 1920.0, y: -180.0, width: 2560.0, height: 1440.0, main: false },
            DisplayInfo { id: "TEST-3".into(), name: "Test Display 3".into(), x: -1280.0, y: 140.0, width: 1280.0, height: 800.0, main: false },
        ];
        Arc::new(Desk { displays: all[..n.clamp(1, 3)].to_vec(), shown: Mutex::new("TEST-1".into()) })
    }
    fn shown(&self) -> DisplayInfo {
        let id = self.shown.lock().unwrap().clone();
        self.displays.iter().find(|d| d.id == id).cloned().unwrap_or_else(|| self.displays[0].clone())
    }
    /// A point on some display: off every display, the nearest edge of the nearest one.
    fn clamp(&self, x: f64, y: f64) -> (f64, f64) {
        if self.displays.iter().any(|d| d.contains(x, y)) {
            return (x, y);
        }
        let mut best = (x, y);
        let mut dist = f64::INFINITY;
        for d in &self.displays {
            let q = (x.clamp(d.x, d.x + d.width - 1.0), y.clamp(d.y, d.y + d.height - 1.0));
            let e = (q.0 - x).hypot(q.1 - y);
            if e < dist {
                dist = e;
                best = q;
            }
        }
        best
    }
}

struct LogInput {
    x: f64,
    y: f64,
    desk: Arc<Desk>,
}

fn line(s: String) {
    emit(json!({"event": "remote_input", "line": s}));
}

impl Input for LogInput {
    fn can_control(&self) -> bool {
        true
    }
    fn key(&mut self, name: &str, mods: u8, down: Option<bool>) {
        line(format!("key {name} mods={mods} {}", match down { None => "tap", Some(true) => "down", Some(false) => "up" }));
    }
    fn set_held(&mut self, mods: u8) {
        line(format!("held mods={mods}"));
    }
    fn text(&mut self, t: &str) {
        line(format!("text {t}"));
    }
    fn button(&mut self, b: Button, down: bool, clicks: u32) {
        line(format!("button {b:?} {} count={clicks}", if down { "down" } else { "up" }));
    }
    fn move_by(&mut self, dx: f64, dy: f64) {
        (self.x, self.y) = self.desk.clamp(self.x + dx, self.y + dy);
        line(format!("move {dx:.1},{dy:.1} → {:.0},{:.0}", self.x, self.y));
    }
    fn move_to(&mut self, x: f64, y: f64) {
        let d = self.desk.shown();
        self.x = d.x + x * d.width;
        self.y = d.y + y * d.height;
        line(format!("place {:.0},{:.0} on {}", self.x, self.y, d.id));
    }
    fn scroll(&mut self, dx: f64, dy: f64, p: ScrollPhase) {
        line(format!("scroll {dx:.1},{dy:.1} {p:?}"));
    }
    fn system(&mut self, m: SystemMove) {
        line(format!("system {m:?}"));
    }
    fn release_all(&mut self) {
        line("release all".into());
    }
    fn pointer(&self) -> Option<(f64, f64)> {
        let d = self.desk.shown();
        Some(((self.x - d.x) / d.width, (self.y - d.y) / d.height))
    }
    fn pointer_desktop(&self) -> Option<(f64, f64)> {
        Some((self.x, self.y))
    }
    fn cursor_shape(&mut self) -> Option<CursorShape> {
        None
    }
}

// ------------------------------------------------------------------ the synthetic screen

struct Ffmpeg {
    desk: Arc<Desk>,
    config: Option<ScreenConfig>,
    sink: Option<FrameSink>,
    child: Option<Child>,
    gen: Arc<AtomicU64>,
    last_restart: Option<Instant>,
}

impl Ffmpeg {
    fn restart(&mut self) {
        if let Some(mut c) = self.child.take() {
            let _ = c.kill();
            let _ = c.wait();
        }
        let (Some(cfg), Some(sink)) = (self.config.clone(), self.sink.clone()) else { return };
        let g = self.gen.fetch_add(1, SeqCst) + 1;
        self.last_restart = Some(Instant::now());
        let c = cfg.crop;
        let shown = self.desk.shown();
        let (sw, sh) = (shown.width, shown.height);
        let n = self.desk.displays.iter().position(|d| d.id == shown.id).unwrap_or(0);
        let pattern = ["testsrc2", "smptehdbars", "rgbtestsrc"][n % 3];
        let crop = format!(
            "crop={}:{}:{}:{},scale={}:{}",
            ((c.w as f64 * sw) as u32) / 2 * 2,
            ((c.h as f64 * sh) as u32) / 2 * 2,
            (c.x as f64 * sw) as u32,
            (c.y as f64 * sh) as u32,
            cfg.width,
            cfg.height
        );
        let kbps = (cfg.bitrate / 1000).max(100);
        let child = Command::new("ffmpeg")
            .args(["-hide_banner", "-loglevel", "error", "-re", "-f", "lavfi", "-i"])
            .arg(format!("{pattern}=size={}x{}:rate={}", sw as u32, sh as u32, cfg.fps.max(1)))
            .args(["-vf", &crop, "-pix_fmt", "yuv420p", "-c:v", "libx264", "-preset", "ultrafast", "-tune", "zerolatency", "-bf", "0"])
            .args(["-x264-params", "keyint=600:scenecut=0:aud=1:repeat-headers=1:slices=1"])
            .args(["-b:v", &format!("{kbps}k"), "-maxrate", &format!("{kbps}k"), "-bufsize", &format!("{}k", kbps / 2)])
            .args(["-f", "h264", "-"])
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn();
        let mut child = match child {
            Ok(c) => c,
            Err(e) => {
                emit(json!({"event": "screen_test", "error": format!("ffmpeg: {e}")}));
                return;
            }
        };
        let out = child.stdout.take().unwrap();
        let gen = self.gen.clone();
        let crop = cfg.crop;
        std::thread::spawn(move || read_annexb(out, move |f| {
            if gen.load(SeqCst) != g {
                return false;
            }
            sink(EncodedFrame { crop, captured: now(), ..f });
            true
        }));
        self.child = Some(child);
        emit(json!({"event": "screen_test", "ffmpeg": {"display": shown.id, "pattern": pattern, "width": cfg.width, "height": cfg.height, "kbps": kbps,
            "fps": cfg.fps, "crop": [c.x, c.y, c.w, c.h]}}));
    }
}

/// Annex B (start codes) from libx264, with access unit delimiters, into frames of length-prefixed NAL units.
fn read_annexb(mut r: impl Read, mut each: impl FnMut(EncodedFrame) -> bool) {
    let mut buf: Vec<u8> = vec![];
    let mut chunk = vec![0u8; 1 << 16];
    let mut nals: Vec<Vec<u8>> = vec![];
    let finish = |nals: &mut Vec<Vec<u8>>, each: &mut dyn FnMut(EncodedFrame) -> bool| -> bool {
        if nals.is_empty() {
            return true;
        }
        let mut sets = vec![];
        let mut picture = vec![];
        let mut key = false;
        for n in nals.drain(..) {
            match n[0] & 0x1f {
                7 | 8 => sets.push(n),
                9 | 6 => {}
                t => {
                    key |= t == 5;
                    picture.extend_from_slice(&(n.len() as u32).to_be_bytes());
                    picture.extend_from_slice(&n);
                }
            }
        }
        if picture.is_empty() {
            return true;
        }
        each(EncodedFrame { picture, keyframe: key, parameter_sets: if key { sets } else { vec![] }, crop: Crop::WHOLE, captured: 0.0 })
    };
    loop {
        let n = match r.read(&mut chunk) {
            Ok(0) | Err(_) => return,
            Ok(n) => n,
        };
        buf.extend_from_slice(&chunk[..n]);
        // complete NAL units: from one start code up to the next
        let starts: Vec<(usize, usize)> = (0..buf.len().saturating_sub(3))
            .filter_map(|i| {
                if buf[i] == 0 && buf[i + 1] == 0 && buf[i + 2] == 1 {
                    Some((if i > 0 && buf[i - 1] == 0 { i - 1 } else { i }, i + 3))
                } else {
                    None
                }
            })
            .collect();
        if starts.len() < 2 {
            continue;
        }
        for w in starts.windows(2) {
            let nal = buf[w[0].1..w[1].0].to_vec();
            if nal.is_empty() {
                continue;
            }
            if nal[0] & 0x1f == 9 && !finish(&mut nals, &mut each) {
                return;
            }
            nals.push(nal);
        }
        let last = starts.last().unwrap().0;
        buf.drain(..last);
    }
}

impl Screen for Ffmpeg {
    fn start(&mut self, config: &ScreenConfig, sink: FrameSink) -> Result<ScreenInfo, String> {
        if !config.codecs.iter().any(|c| c == "h264") {
            return Err("This test screen only sends H.264, and the phone didn't ask for it.".into());
        }
        // the display asked for, else the one under the pointer's (the desk's shown one)
        if let Some(id) = &config.display {
            if self.desk.displays.iter().any(|d| &d.id == id) {
                *self.desk.shown.lock().unwrap() = id.clone();
            }
        }
        self.config = Some(config.clone());
        self.sink = Some(sink);
        self.restart();
        let d = self.desk.shown();
        Ok(ScreenInfo { width: d.width, height: d.height, codec: "h264".into() })
    }
    fn set_crop(&mut self, crop: Crop) {
        if let Some(c) = &mut self.config {
            if c.crop != crop {
                c.crop = crop;
                self.restart();
            }
        }
    }
    fn set_rate(&mut self, bitrate: u32, fps: u32) {
        if let Some(c) = &mut self.config {
            c.bitrate = bitrate;
            c.fps = fps;
        }
        emit(json!({"event": "screen_test", "rate": {"bitrate": bitrate, "fps": fps}}));
        self.restart();
    }
    fn keyframe(&mut self) {
        // a fresh ffmpeg starts with one; not more than twice a second
        if self.last_restart.is_none_or(|t| t.elapsed().as_secs_f64() > 0.5) {
            self.restart();
        }
    }
    fn refresh(&mut self) {}
    fn stop(&mut self) {
        self.gen.fetch_add(1, SeqCst);
        if let Some(mut c) = self.child.take() {
            let _ = c.kill();
            let _ = c.wait();
        }
        self.config = None;
        self.sink = None;
    }
}

struct LogBackend {
    desk: Arc<Desk>,
    input: LogInput,
    screen: Option<Ffmpeg>,
}

impl Backend for LogBackend {
    fn input(&mut self) -> &mut dyn Input {
        &mut self.input
    }
    fn screen(&mut self) -> Option<&mut dyn Screen> {
        self.screen.as_mut().map(|s| s as &mut dyn Screen)
    }
    fn platform(&self) -> &'static str {
        std::env::var("BLURT_TEST_PLATFORM").ok().filter(|p| p == "linux").map_or("windows", |_| "linux")
    }
    fn display_aspect(&self) -> f64 {
        let d = &self.desk.displays[0];
        d.width / d.height
    }
    fn displays(&self) -> Vec<DisplayInfo> {
        self.desk.displays.clone()
    }
    fn now(&self) -> f64 {
        now()
    }
    fn keep_awake(&mut self, on: bool, display: bool) {
        emit(json!({"event": "keep_awake", "on": on, "display": display}));
    }
}

struct LogApp {
    host: Arc<Mutex<Option<Host>>>,
}

impl App for LogApp {
    fn status(&self, s: &blurt_remote::Status) {
        emit(json!({"event": "status", "listening": s.listening, "port": s.port,
            "asking": s.asking.as_ref().map(|a| json!({"device": a.device, "digits": a.digits, "relay": a.via_relay})),
            "connected": s.connected.as_ref().map(|c| json!({"name": c.name, "route": c.route, "screen": c.screen})),
            "devices": s.devices.len(), "relay": s.relay.address, "reachable": s.relay.reachable}));
        if let Some(p) = &s.pairing {
            emit(json!({"event": "pairing_link", "link": p.url}));
        }
    }
    fn asking(&self, device: &str, digits: &str) {
        emit(json!({"event": "asking", "device": device, "digits": digits}));
    }
    fn dictation_key(&self, down: bool, phone_mic: bool) {
        emit(json!({"event": "dictation_key", "down": down, "phone_mic": phone_mic}));
        // what the desktop app sends back while a take listens; the phone's microphone counted as it arrives
        if let Some(h) = self.host.lock().unwrap().as_ref() {
            h.dictation(if down { DictationPhase::Listening } else { DictationPhase::Idle });
            if down && phone_mic {
                let (tx, rx) = std::sync::mpsc::channel::<Vec<f32>>();
                h.mic().attach(tx);
                let h = h.clone();
                std::thread::spawn(move || {
                    let (mut n, mut peak) = (0usize, 0f32);
                    let t0 = Instant::now();
                    while let Ok(f) = rx.recv_timeout(std::time::Duration::from_millis(1500)) {
                        n += f.len();
                        peak = f.iter().fold(peak, |p, x| p.max(x.abs()));
                        h.level(peak.min(1.0));
                        if t0.elapsed().as_secs() > 30 {
                            break;
                        }
                    }
                    h.mic().detach();
                    emit(json!({"event": "phone_mic", "samples": n, "seconds": n as f64 / 16000.0, "peak": peak}));
                });
            }
        }
    }
    fn blurt(&self, c: BlurtCommand, phone_mic: bool) {
        emit(json!({"event": "blurt", "command": c.name(), "phone_mic": phone_mic}));
    }
    fn session(&self, name: Option<&str>) {
        emit(json!({"event": "session", "phone": name}));
    }
    fn hud(&self, text: &str) {
        emit(json!({"event": "hud", "text": text}));
    }
    fn front(&self) -> Option<Front> {
        Some(Front { bundle: "WindowsTerminal.exe".into(), name: "Terminal".into() })
    }
    fn dictation_phase(&self) -> DictationPhase {
        DictationPhase::Idle
    }
    fn log(&self, e: &Value) {
        emit(e.clone());
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let arg = |n: &str| args.iter().position(|a| a == n).and_then(|i| args.get(i + 1)).cloned();
    let screen = args.iter().any(|a| a == "--screen-test");
    let answer = arg("--answer").unwrap_or_else(|| "yes".into());
    let dir = arg("--dir").map(std::path::PathBuf::from).unwrap_or_else(|| std::env::temp_dir().join("blurt-remote-host"));
    let port = arg("--port").and_then(|p| p.parse().ok()).unwrap_or(0);
    let shared = Arc::new(Mutex::new(None));
    let desk = Desk::new(arg("--displays").and_then(|n| n.parse().ok()).unwrap_or(1));
    let backend = LogBackend {
        desk: desk.clone(),
        input: LogInput { x: 960.0, y: 540.0, desk: desk.clone() },
        screen: screen.then(|| Ffmpeg { desk: desk.clone(), config: None, sink: None, child: None, gen: Arc::new(AtomicU64::new(0)), last_restart: None }),
    };
    let h = Host::start(
        HostConfig {
            dir: dir.clone(),
            name: arg("--name").unwrap_or_else(|| "Test Host".into()),
            version: "1.0.15".into(),
            test_answer: match answer.as_str() {
                "no" => Some(false),
                "ask" => None,
                _ => Some(true),
            },
            port,
        },
        if args.iter().any(|a| a == "--real") { blurt_remote::platform::backend() } else { Box::new(backend) },
        Box::new(FileKeyStore::new(dir.join("test-keys.json"))),
        Box::new(LogApp { host: shared.clone() }),
    );
    *shared.lock().unwrap() = Some(h.clone());
    if let Some(r) = arg("--relay") {
        if let Err(e) = h.set_relay(Some(&r)) {
            emit(json!({"event": "relay", "error": e}));
        }
    }
    // the real backend's screen: allowed, as Settings → Phone's switch would
    if args.iter().any(|a| a == "--real") {
        h.set_screen_allowed(true);
    }
    h.show_pairing(true);
    emit(json!({"event": "host", "dir": dir, "platform": h.platform(), "screen": screen}));
    // stdin: yes / no (the question), pair (a fresh code), quit
    for l in std::io::stdin().lock().lines() {
        let Ok(l) = l else { break };
        match l.trim() {
            "yes" => h.answer_pairing(true, None),
            "no" => h.answer_pairing(false, None),
            "pair" => h.show_pairing(true),
            "quit" => break,
            "" => {}
            other => emit(json!({"event": "stdin", "unknown": other})),
        }
    }
    // stdin closed (run in the background): keep serving
    if !args.iter().any(|a| a == "--exit-on-eof") {
        loop {
            std::thread::park();
        }
    }
    h.stop();
}
