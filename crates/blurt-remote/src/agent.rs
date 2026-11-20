//! The Windows system service's split (docs/design/remote-1.1.md §2): the agent — LocalSystem in the console session, no network —
//! owns the screen and the input on whichever desktop has the keyboard (Default, the lock and login screens, the UAC prompt); the host
//! that talks to phones and computers runs unprivileged and reaches them through one pipe. This is that pipe: `serve` on the agent's
//! side around a real `Backend`, `Proxy` on the host's side as a `Backend` of its own. Both work over any byte stream, so the protocol
//! is tested on every OS (a socket pair); on Windows the stream is a named pipe (platform/windows/pipe.rs).
//!
//! On the stream: [u32 LE length][u8 kind][u32 LE id][payload]. Kinds: 1 a request (JSON `Req`, id > 0 when it wants an answer),
//! 2 its answer (JSON `Rep`, same id), 3 an encoded frame (binary, `frame_bytes`), 4 the agent's hello (JSON `Hello`, first).
//! Frames cross encoded, so the pipe carries kilobytes, not pixels.

use std::collections::HashMap;
use std::io::{Read, Write};
use std::sync::atomic::{AtomicU32, Ordering::SeqCst};
use std::sync::{mpsc, Arc, Mutex};
use std::time::Duration;

use serde::{Deserialize, Serialize};

use crate::host::{
    Backend, Button, Crop, CursorShape, DisplayInfo, EncodedFrame, FrameSink, Input, Screen, ScreenConfig, ScreenInfo, ScrollPhase,
    SystemMove,
};

const REQ: u8 = 1;
const REP: u8 = 2;
const FRAME: u8 = 3;
const HELLO: u8 = 4;
/// a message larger than this ends the connection (a keyframe at 4K is well under it)
const MAX: usize = 32 << 20;
/// an answer that takes longer than this is given up (the agent is gone or stuck)
const WAIT: Duration = Duration::from_secs(5);

/// What the agent can do, said first.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Hello {
    pub platform: String,
    pub screen: bool,
    pub caps_quantiser: bool,
    pub rate_change_is_cheap: bool,
    pub supports_recovery: bool,
    pub display_aspect: f64,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub enum Req {
    // input (no answer unless noted)
    CanControl,
    Key { name: String, mods: u8, down: Option<bool> },
    SetHeld(u8),
    Text(String),
    Button { button: Button, down: bool, clicks: u32 },
    MoveBy(f64, f64),
    MoveTo(f64, f64),
    Scroll { dx: f64, dy: f64, phase: ScrollPhase },
    System(SystemMove),
    ReleaseAll,
    Pointer,
    PointerDesktop,
    CursorShape,
    // the backend
    Displays,
    DisplayAspect,
    KeepAwake { on: bool, display: bool },
    StandbyAwake(bool),
    PluggedIn,
    HasBattery,
    // the screen
    Start(ScreenConfig),
    SetCrop(Crop),
    SetRate { bitrate: u32, fps: u32 },
    Keyframe,
    Refresh,
    Sharpen(u8),
    Stop,
    RecoveryFrame,
    Acknowledged(Vec<u64>),
    SetDisplay(Option<String>),
    /// the logged-in user's host: what the standby host needs (`Host::standby_snapshot`), kept by the agent for the login screen
    SaveStandby(String),
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub enum Rep {
    Done,
    Bool(bool),
    Point(Option<(f64, f64)>),
    Cursor(Option<CursorShape>),
    Displays(Vec<DisplayInfo>),
    Number(f64),
    Started(Result<ScreenInfo, String>),
}

// ------------------------------------------------------------------ the stream

fn write_msg(w: &mut dyn Write, kind: u8, id: u32, payload: &[u8]) -> std::io::Result<()> {
    let len = (1 + 4 + payload.len()) as u32;
    let mut head = Vec::with_capacity(9);
    head.extend_from_slice(&len.to_le_bytes());
    head.push(kind);
    head.extend_from_slice(&id.to_le_bytes());
    w.write_all(&head)?;
    w.write_all(payload)?;
    w.flush()
}

fn read_msg(r: &mut dyn Read) -> std::io::Result<(u8, u32, Vec<u8>)> {
    let mut b4 = [0u8; 4];
    r.read_exact(&mut b4)?;
    let len = u32::from_le_bytes(b4) as usize;
    if !(5..=MAX).contains(&len) {
        return Err(std::io::Error::new(std::io::ErrorKind::InvalidData, "bad length"));
    }
    let mut body = vec![0u8; len];
    r.read_exact(&mut body)?;
    let id = u32::from_le_bytes([body[1], body[2], body[3], body[4]]);
    Ok((body[0], id, body[5..].to_vec()))
}

/// An encoded frame as bytes: flags, crop, time, reference, the parameter sets, then the picture.
pub fn frame_bytes(f: &EncodedFrame) -> Vec<u8> {
    let mut b = Vec::with_capacity(f.picture.len() + 64);
    b.push(f.keyframe as u8 | (f.refresh as u8) << 1 | (f.reference.is_some() as u8) << 2);
    for v in [f.crop.x, f.crop.y, f.crop.w, f.crop.h] {
        b.extend_from_slice(&v.to_le_bytes());
    }
    b.extend_from_slice(&f.captured.to_le_bytes());
    b.extend_from_slice(&f.reference.unwrap_or(0).to_le_bytes());
    b.push(f.parameter_sets.len().min(255) as u8);
    for p in f.parameter_sets.iter().take(255) {
        b.extend_from_slice(&(p.len() as u32).to_le_bytes());
        b.extend_from_slice(p);
    }
    b.extend_from_slice(&f.picture);
    b
}

pub fn frame_from(b: &[u8]) -> Option<EncodedFrame> {
    let mut at = 0usize;
    let mut take = |n: usize| -> Option<&[u8]> {
        let s = b.get(at..at + n)?;
        at += n;
        Some(s)
    };
    let flags = take(1)?[0];
    let mut c = [0f32; 4];
    for v in c.iter_mut() {
        *v = f32::from_le_bytes(take(4)?.try_into().ok()?);
    }
    let captured = f64::from_le_bytes(take(8)?.try_into().ok()?);
    let reference = u64::from_le_bytes(take(8)?.try_into().ok()?);
    let n = take(1)?[0] as usize;
    let mut parameter_sets = Vec::with_capacity(n);
    for _ in 0..n {
        let len = u32::from_le_bytes(take(4)?.try_into().ok()?) as usize;
        parameter_sets.push(take(len)?.to_vec());
    }
    let picture = b.get(at..)?.to_vec();
    Some(EncodedFrame {
        picture,
        keyframe: flags & 1 != 0,
        refresh: flags & 2 != 0,
        reference: (flags & 4 != 0).then_some(reference),
        parameter_sets,
        crop: Crop { x: c[0], y: c[1], w: c[2], h: c[3] },
        captured,
    })
}

// ------------------------------------------------------------------ the agent's side

/// Serves one host until the stream ends: each request on `backend`, frames from its screen back as they come. Returns when the host
/// goes (the screen stopped and everything let go first).
pub fn serve(reader: &mut dyn Read, writer: Box<dyn Write + Send>, backend: &mut dyn Backend, standby: Option<&dyn Fn(&str)>) {
    let writer = Arc::new(Mutex::new(writer));
    let hello = Hello {
        platform: backend.platform().to_string(),
        screen: backend.screen().is_some(),
        caps_quantiser: backend.screen().is_some_and(|s| s.caps_quantiser()),
        rate_change_is_cheap: backend.screen().is_some_and(|s| s.rate_change_is_cheap()),
        supports_recovery: backend.screen().is_some_and(|s| s.supports_recovery()),
        display_aspect: backend.display_aspect(),
    };
    if write_msg(&mut **writer.lock().unwrap(), HELLO, 0, &serde_json::to_vec(&hello).unwrap_or_default()).is_err() {
        return;
    }
    while let Ok((kind, id, body)) = read_msg(reader) {
        if kind != REQ {
            continue;
        }
        let Ok(req) = serde_json::from_slice::<Req>(&body) else { continue };
        if let Req::SaveStandby(snapshot) = &req {
            if let Some(f) = standby {
                f(snapshot);
            }
            continue;
        }
        let rep = answer(backend, req, &writer);
        if id != 0 {
            let b = serde_json::to_vec(&rep).unwrap_or_default();
            if write_msg(&mut **writer.lock().unwrap(), REP, id, &b).is_err() {
                break;
            }
        }
    }
    if let Some(s) = backend.screen() {
        s.stop();
    }
    backend.input().release_all();
}

fn answer(b: &mut dyn Backend, req: Req, writer: &Arc<Mutex<Box<dyn Write + Send>>>) -> Rep {
    match req {
        Req::CanControl => Rep::Bool(b.input().can_control()),
        Req::Key { name, mods, down } => {
            b.input().key(&name, mods, down);
            Rep::Done
        }
        Req::SetHeld(m) => {
            b.input().set_held(m);
            Rep::Done
        }
        Req::Text(t) => {
            b.input().text(&t);
            Rep::Done
        }
        Req::Button { button, down, clicks } => {
            b.input().button(button, down, clicks);
            Rep::Done
        }
        Req::MoveBy(x, y) => {
            b.input().move_by(x, y);
            Rep::Done
        }
        Req::MoveTo(x, y) => {
            b.input().move_to(x, y);
            Rep::Done
        }
        Req::Scroll { dx, dy, phase } => {
            b.input().scroll(dx, dy, phase);
            Rep::Done
        }
        Req::System(m) => {
            b.input().system(m);
            Rep::Done
        }
        Req::ReleaseAll => {
            b.input().release_all();
            Rep::Done
        }
        Req::Pointer => Rep::Point(b.input().pointer()),
        Req::PointerDesktop => Rep::Point(b.input().pointer_desktop()),
        Req::CursorShape => Rep::Cursor(b.input().cursor_shape()),
        Req::Displays => Rep::Displays(b.displays()),
        Req::DisplayAspect => Rep::Number(b.display_aspect()),
        Req::KeepAwake { on, display } => {
            b.keep_awake(on, display);
            Rep::Done
        }
        Req::StandbyAwake(on) => {
            b.standby_awake(on);
            Rep::Done
        }
        Req::PluggedIn => Rep::Bool(b.plugged_in()),
        Req::HasBattery => Rep::Bool(b.has_battery()),
        Req::Start(cfg) => {
            let Some(s) = b.screen() else { return Rep::Started(Err("no screen".into())) };
            let w = writer.clone();
            let sink: FrameSink = Arc::new(move |f: EncodedFrame| {
                let _ = write_msg(&mut **w.lock().unwrap(), FRAME, 0, &frame_bytes(&f));
            });
            // a screen that needs a slow step first (a portal dialog, an encoder's warm-up) takes it here, on the agent
            if let Some(prep) = s.prepare() {
                if let Err(e) = prep() {
                    return Rep::Started(Err(e));
                }
            }
            Rep::Started(s.start(&cfg, sink))
        }
        Req::SetCrop(c) => screen(b, |s| s.set_crop(c)),
        Req::SetRate { bitrate, fps } => screen(b, |s| s.set_rate(bitrate, fps)),
        Req::Keyframe => screen(b, |s| s.keyframe()),
        Req::Refresh => screen(b, |s| s.refresh()),
        Req::Sharpen(q) => screen(b, |s| s.sharpen(q)),
        Req::Stop => screen(b, |s| s.stop()),
        Req::RecoveryFrame => screen(b, |s| s.recovery_frame()),
        Req::Acknowledged(r) => screen(b, |s| s.acknowledged(&r)),
        Req::SetDisplay(d) => Rep::Bool(b.screen().is_some_and(|s| s.set_display(d.as_deref()))),
        Req::SaveStandby(_) => Rep::Done,
    }
}

fn screen(b: &mut dyn Backend, f: impl FnOnce(&mut dyn Screen)) -> Rep {
    if let Some(s) = b.screen() {
        f(s);
    }
    Rep::Done
}

// ------------------------------------------------------------------ the host's side

struct Link {
    writer: Mutex<Box<dyn Write + Send>>,
    next: AtomicU32,
    waiting: Mutex<HashMap<u32, mpsc::Sender<Rep>>>,
    sink: Mutex<Option<FrameSink>>,
    alive: std::sync::atomic::AtomicBool,
}

impl Link {
    fn tell(&self, r: Req) {
        if let Ok(b) = serde_json::to_vec(&r) {
            if write_msg(&mut **self.writer.lock().unwrap(), REQ, 0, &b).is_err() {
                self.alive.store(false, SeqCst);
            }
        }
    }

    fn ask(&self, r: Req) -> Option<Rep> {
        if !self.alive.load(SeqCst) {
            return None;
        }
        let id = self.next.fetch_add(1, SeqCst).max(1);
        let (tx, rx) = mpsc::channel();
        self.waiting.lock().unwrap().insert(id, tx);
        let b = serde_json::to_vec(&r).ok()?;
        if write_msg(&mut **self.writer.lock().unwrap(), REQ, id, &b).is_err() {
            self.alive.store(false, SeqCst);
            self.waiting.lock().unwrap().remove(&id);
            return None;
        }
        let rep = rx.recv_timeout(WAIT).ok();
        self.waiting.lock().unwrap().remove(&id);
        rep
    }
}

/// The host's `Backend` when the agent owns the screen and the input. The clipboard stays the host's own (`clipboard`): the agent,
/// as SYSTEM, has no user's clipboard.
pub struct Proxy {
    /// closes the stream both ways (the reader thread holds its own handle to it)
    shutdown: Box<dyn Fn() + Send + Sync>,
    link: Arc<Link>,
    hello: Hello,
    screen: ProxyScreen,
    clock: fn() -> f64,
    clipboard: Option<Box<dyn Input>>,
}

pub struct ProxyScreen {
    link: Arc<Link>,
    hello: Hello,
}

impl Proxy {
    /// Over a stream to the agent: waits for its hello (5 s), then reads its answers and frames on a thread of its own. `clock`: the
    /// host's monotonic seconds, the same clock as the agent's (QueryPerformanceCounter on Windows). `clipboard`: an Input whose
    /// clipboard is used (the host's own backend), or None.
    pub fn connect(
        mut reader: Box<dyn Read + Send>,
        writer: Box<dyn Write + Send>,
        shutdown: Box<dyn Fn() + Send + Sync>,
        clock: fn() -> f64,
        clipboard: Option<Box<dyn Input>>,
    ) -> Result<Proxy, String> {
        let (kind, _, body) = read_msg(&mut *reader).map_err(|e| format!("no hello: {e}"))?;
        if kind != HELLO {
            return Err("not the agent".into());
        }
        let hello: Hello = serde_json::from_slice(&body).map_err(|e| e.to_string())?;
        let link = Arc::new(Link {
            writer: Mutex::new(writer),
            next: AtomicU32::new(1),
            waiting: Mutex::new(HashMap::new()),
            sink: Mutex::new(None),
            alive: std::sync::atomic::AtomicBool::new(true),
        });
        let l = link.clone();
        std::thread::Builder::new()
            .name("blurt-agent-reader".into())
            .spawn(move || {
                while let Ok((kind, id, body)) = read_msg(&mut *reader) {
                    match kind {
                        REP => {
                            let tx = l.waiting.lock().unwrap().remove(&id);
                            if let (Some(tx), Ok(rep)) = (tx, serde_json::from_slice::<Rep>(&body)) {
                                let _ = tx.send(rep);
                            }
                        }
                        FRAME => {
                            let sink = l.sink.lock().unwrap().clone();
                            if let (Some(sink), Some(f)) = (sink, frame_from(&body)) {
                                sink(f);
                            }
                        }
                        _ => {}
                    }
                }
                l.alive.store(false, SeqCst);
                l.waiting.lock().unwrap().clear();
            })
            .map_err(|e| e.to_string())?;
        Ok(Proxy { screen: ProxyScreen { link: link.clone(), hello: hello.clone() }, shutdown, link, hello, clock, clipboard })
    }

    /// Hands the agent what the standby host needs (`Host::standby_snapshot`).
    pub fn save_standby(&self, snapshot: &str) {
        self.link.tell(Req::SaveStandby(snapshot.to_string()));
    }

    /// The agent is still there (the pipe hasn't closed).
    pub fn alive(&self) -> bool {
        self.link.alive.load(SeqCst)
    }
}

impl Drop for Proxy {
    fn drop(&mut self) {
        self.link.alive.store(false, SeqCst);
        (self.shutdown)();
    }
}

impl Input for Proxy {
    fn can_control(&self) -> bool {
        matches!(self.link.ask(Req::CanControl), Some(Rep::Bool(true)))
    }
    fn key(&mut self, name: &str, mods: u8, down: Option<bool>) {
        self.link.tell(Req::Key { name: name.into(), mods, down });
    }
    fn set_held(&mut self, mods: u8) {
        self.link.tell(Req::SetHeld(mods));
    }
    fn text(&mut self, text: &str) {
        self.link.tell(Req::Text(text.into()));
    }
    fn button(&mut self, button: Button, down: bool, clicks: u32) {
        self.link.tell(Req::Button { button, down, clicks });
    }
    fn move_by(&mut self, dx: f64, dy: f64) {
        self.link.tell(Req::MoveBy(dx, dy));
    }
    fn move_to(&mut self, x: f64, y: f64) {
        self.link.tell(Req::MoveTo(x, y));
    }
    fn scroll(&mut self, dx: f64, dy: f64, phase: ScrollPhase) {
        self.link.tell(Req::Scroll { dx, dy, phase });
    }
    fn system(&mut self, m: SystemMove) {
        self.link.tell(Req::System(m));
    }
    fn release_all(&mut self) {
        self.link.tell(Req::ReleaseAll);
    }
    fn pointer(&self) -> Option<(f64, f64)> {
        match self.link.ask(Req::Pointer) {
            Some(Rep::Point(p)) => p,
            _ => None,
        }
    }
    fn pointer_desktop(&self) -> Option<(f64, f64)> {
        match self.link.ask(Req::PointerDesktop) {
            Some(Rep::Point(p)) => p,
            _ => None,
        }
    }
    fn cursor_shape(&mut self) -> Option<CursorShape> {
        match self.link.ask(Req::CursorShape) {
            Some(Rep::Cursor(c)) => c,
            _ => None,
        }
    }
    fn clipboard(&mut self) -> Option<String> {
        self.clipboard.as_mut().and_then(|c| c.clipboard())
    }
    fn set_clipboard(&mut self, text: &str) {
        if let Some(c) = self.clipboard.as_mut() {
            c.set_clipboard(text);
        }
    }
}

impl Screen for ProxyScreen {
    fn start(&mut self, config: &ScreenConfig, sink: FrameSink) -> Result<ScreenInfo, String> {
        *self.link.sink.lock().unwrap() = Some(sink);
        match self.link.ask(Req::Start(config.clone())) {
            Some(Rep::Started(r)) => r,
            _ => Err("the agent didn't answer".into()),
        }
    }
    fn set_crop(&mut self, crop: Crop) {
        self.link.tell(Req::SetCrop(crop));
    }
    fn set_rate(&mut self, bitrate: u32, fps: u32) {
        self.link.tell(Req::SetRate { bitrate, fps });
    }
    fn rate_change_is_cheap(&self) -> bool {
        self.hello.rate_change_is_cheap
    }
    fn keyframe(&mut self) {
        self.link.tell(Req::Keyframe);
    }
    fn refresh(&mut self) {
        self.link.tell(Req::Refresh);
    }
    fn caps_quantiser(&self) -> bool {
        self.hello.caps_quantiser
    }
    fn sharpen(&mut self, max_qp: u8) {
        self.link.tell(Req::Sharpen(max_qp));
    }
    fn stop(&mut self) {
        // answered, so no frame of this stream reaches the next one's sink
        self.link.ask(Req::Stop);
        *self.link.sink.lock().unwrap() = None;
    }
    fn supports_recovery(&self) -> bool {
        self.hello.supports_recovery
    }
    fn recovery_frame(&mut self) {
        self.link.tell(Req::RecoveryFrame);
    }
    fn acknowledged(&mut self, references: &[u64]) {
        self.link.tell(Req::Acknowledged(references.to_vec()));
    }
    fn set_display(&mut self, id: Option<&str>) -> bool {
        matches!(self.link.ask(Req::SetDisplay(id.map(str::to_string))), Some(Rep::Bool(true)))
    }
}

impl Backend for Proxy {
    fn input(&mut self) -> &mut dyn Input {
        self
    }
    fn screen(&mut self) -> Option<&mut dyn Screen> {
        if self.hello.screen {
            Some(&mut self.screen)
        } else {
            None
        }
    }
    fn platform(&self) -> &'static str {
        match self.hello.platform.as_str() {
            "windows" => "windows",
            "linux" => "linux",
            "mac" => "mac",
            _ => "unknown",
        }
    }
    fn display_aspect(&self) -> f64 {
        match self.link.ask(Req::DisplayAspect) {
            Some(Rep::Number(a)) => a,
            _ => self.hello.display_aspect,
        }
    }
    fn now(&self) -> f64 {
        (self.clock)()
    }
    fn keep_awake(&mut self, on: bool, display: bool) {
        self.link.tell(Req::KeepAwake { on, display });
    }
    fn standby_awake(&mut self, on: bool) {
        self.link.tell(Req::StandbyAwake(on));
    }
    fn plugged_in(&self) -> bool {
        !matches!(self.link.ask(Req::PluggedIn), Some(Rep::Bool(false)))
    }
    fn has_battery(&self) -> bool {
        matches!(self.link.ask(Req::HasBattery), Some(Rep::Bool(true)))
    }
    fn save_standby(&mut self, snapshot: &str) {
        Proxy::save_standby(self, snapshot);
    }
    fn displays(&self) -> Vec<DisplayInfo> {
        match self.link.ask(Req::Displays) {
            Some(Rep::Displays(d)) => d,
            _ => vec![],
        }
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::os::unix::net::UnixStream;

    /// A backend that records what it's told and sends three frames when started.
    #[derive(Default)]
    struct Fake {
        said: Arc<Mutex<Vec<String>>>,
        screen: FakeScreen,
    }
    #[derive(Default)]
    struct FakeScreen {
        said: Arc<Mutex<Vec<String>>>,
    }
    impl Input for Fake {
        fn can_control(&self) -> bool {
            true
        }
        fn key(&mut self, name: &str, mods: u8, down: Option<bool>) {
            self.said.lock().unwrap().push(format!("key {name} {mods} {down:?}"));
        }
        fn set_held(&mut self, _: u8) {}
        fn text(&mut self, t: &str) {
            self.said.lock().unwrap().push(format!("text {t}"));
        }
        fn button(&mut self, _: Button, _: bool, _: u32) {}
        fn move_by(&mut self, _: f64, _: f64) {}
        fn move_to(&mut self, x: f64, y: f64) {
            self.said.lock().unwrap().push(format!("to {x} {y}"));
        }
        fn scroll(&mut self, _: f64, _: f64, _: ScrollPhase) {}
        fn system(&mut self, _: SystemMove) {}
        fn release_all(&mut self) {
            self.said.lock().unwrap().push("release".into());
        }
        fn pointer(&self) -> Option<(f64, f64)> {
            Some((0.25, 0.5))
        }
        fn cursor_shape(&mut self) -> Option<CursorShape> {
            None
        }
    }
    impl Screen for FakeScreen {
        fn start(&mut self, c: &ScreenConfig, sink: FrameSink) -> Result<ScreenInfo, String> {
            self.said.lock().unwrap().push(format!("start {}x{}", c.width, c.height));
            std::thread::spawn(move || {
                for i in 0..3u8 {
                    sink(EncodedFrame {
                        picture: vec![0, 0, 0, 2, i, i],
                        keyframe: i == 0,
                        parameter_sets: if i == 0 { vec![vec![0x67, 1], vec![0x68, 2]] } else { vec![] },
                        captured: i as f64,
                        reference: (i == 2).then_some(7),
                        ..Default::default()
                    });
                }
            });
            Ok(ScreenInfo { width: 1920.0, height: 1080.0, codec: "h264".into() })
        }
        fn set_crop(&mut self, _: Crop) {}
        fn set_rate(&mut self, b: u32, f: u32) {
            self.said.lock().unwrap().push(format!("rate {b} {f}"));
        }
        fn keyframe(&mut self) {}
        fn refresh(&mut self) {}
        fn stop(&mut self) {
            self.said.lock().unwrap().push("stop".into());
        }
    }
    impl Backend for Fake {
        fn input(&mut self) -> &mut dyn Input {
            self
        }
        fn screen(&mut self) -> Option<&mut dyn Screen> {
            Some(&mut self.screen)
        }
        fn platform(&self) -> &'static str {
            "windows"
        }
        fn display_aspect(&self) -> f64 {
            16.0 / 9.0
        }
        fn now(&self) -> f64 {
            0.0
        }
        fn keep_awake(&mut self, _: bool, _: bool) {}
        fn displays(&self) -> Vec<DisplayInfo> {
            vec![DisplayInfo { id: "\\\\.\\DISPLAY1".into(), name: "Dell".into(), x: 0.0, y: 0.0, width: 1920.0, height: 1080.0, main: true }]
        }
    }

    #[test]
    fn frames_round_trip() {
        let f = EncodedFrame {
            picture: vec![1, 2, 3],
            keyframe: true,
            parameter_sets: vec![vec![9], vec![8, 7]],
            crop: Crop { x: 0.1, y: 0.2, w: 0.5, h: 0.5 },
            captured: 12.5,
            refresh: true,
            reference: Some(3),
        };
        assert_eq!(frame_from(&frame_bytes(&f)), Some(f));
        assert_eq!(frame_from(&[1, 2]), None);
    }

    #[test]
    fn the_host_drives_the_agents_backend_through_the_pipe() {
        let (a, b) = UnixStream::pair().unwrap();
        let said = Arc::new(Mutex::new(vec![]));
        let mut fake = Fake { said: said.clone(), screen: FakeScreen { said: said.clone() } };
        let agent = std::thread::spawn(move || {
            let mut r = a.try_clone().unwrap();
            serve(&mut r, Box::new(a), &mut fake, None);
        });
        let closer = b.try_clone().unwrap();
        let shutdown = Box::new(move || {
            let _ = closer.shutdown(std::net::Shutdown::Both);
        });
        let mut p = Proxy::connect(Box::new(b.try_clone().unwrap()), Box::new(b), shutdown, || 1.0, None).unwrap();
        assert_eq!(p.platform(), "windows");
        assert!(p.can_control());
        assert_eq!(p.pointer(), Some((0.25, 0.5)));
        assert_eq!(p.displays().len(), 1);
        p.input().key("A", 8, None);
        p.input().text("你好");
        p.input().move_to(0.5, 0.5);
        let frames = Arc::new(Mutex::new(vec![]));
        let fr = frames.clone();
        let cfg = ScreenConfig {
            width: 1280,
            height: 720,
            bitrate: 2_000_000,
            fps: 30,
            codecs: vec!["h264".into()],
            crop: Crop::WHOLE,
            display: None,
            capture_fps: 30,
            repairs: true,
        };
        let info = p.screen().unwrap().start(&cfg, Arc::new(move |f| fr.lock().unwrap().push(f))).unwrap();
        assert_eq!(info.codec, "h264");
        for _ in 0..100 {
            if frames.lock().unwrap().len() == 3 {
                break;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        let got = frames.lock().unwrap().clone();
        assert_eq!(got.len(), 3);
        assert!(got[0].keyframe && got[0].parameter_sets.len() == 2);
        assert_eq!(got[2].reference, Some(7));
        p.screen().unwrap().set_rate(1_000_000, 20);
        p.screen().unwrap().stop();
        drop(p);
        agent.join().unwrap();
        let said = said.lock().unwrap().clone();
        assert_eq!(
            said,
            ["key A 8 None", "text 你好", "to 0.5 0.5", "start 1280x720", "rate 1000000 20", "stop", "stop", "release"],
            "in order; the agent stops the screen and lets go of everything when the host goes"
        );
    }
}
