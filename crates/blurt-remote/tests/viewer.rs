//! A computer driving another, end to end (docs/design/remote-desktop-viewer.md): the real host with a made-up backend (a recorded
//! H.264 screen, input written down, a clipboard in memory) and the Rust viewer (viewer.rs), on the same network and through
//! `BUDGET=1 node tools/remote-relay/server.js` as the public connection service.
//!
//!  • pairing with the host's link, and with a computer found nearby (no code; the owner's yes; a no pauses nearby asks);
//!  • the session says "viewer" both ways; the window's size is the picture's ceiling; frames arrive whole, in Annex B, with
//!    the codec string;
//!  • keys from the viewer's keyboard (Ctrl+C to a Mac host is ⌘C); the clipboard both ways while captured, and not otherwise;
//!  • through the public connection service: the session meets, moves onto the direct path, and frames and keys still arrive.
//!
//! Nothing here touches this computer's own screen, keyboard or clipboard.

use std::net::{IpAddr, SocketAddr};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering::SeqCst};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use blurt_remote::host::{
    Backend, Button, Crop, CursorShape, EncodedFrame, FrameSink, Input, Screen, ScreenConfig,
    ScreenInfo, ScrollPhase, SystemMove,
};
use blurt_remote::keys::{Keyboard, Sent};
use blurt_remote::pairing::Pairing;
use blurt_remote::store::FileKeyStore;
use blurt_remote::viewer::{
    self, Event, Found, Link, PairError, PairStep, PairWith, Quality, Route, Session, Target, Want,
};
use blurt_remote::wire::ToMac;
use blurt_remote::{App, Host, HostConfig};

/// One host streaming at a time: frame numbers are one counter per process (screen.rs FRAME_ID), and two streams at once would
/// leave each with gaps that its viewer takes for lost frames.
static ONE_AT_A_TIME: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

fn now() -> f64 {
    static T: OnceLock<Instant> = OnceLock::new();
    T.get_or_init(Instant::now).elapsed().as_secs_f64()
}

/// What the made-up computer did.
#[derive(Clone, Default)]
struct World {
    log: Arc<Mutex<Vec<String>>>,
    clipboard: Arc<Mutex<Option<String>>>,
    started: Arc<Mutex<Vec<(u32, u32)>>>,
}

impl World {
    fn push(&self, s: String) {
        self.log.lock().unwrap().push(s);
    }
    fn has(&self, s: &str) -> bool {
        self.log.lock().unwrap().iter().any(|l| l == s)
    }
}

struct In(World);

impl Input for In {
    fn can_control(&self) -> bool {
        true
    }
    fn key(&mut self, name: &str, mods: u8, down: Option<bool>) {
        self.0.push(format!("key {name} {mods} {down:?}"));
    }
    fn set_held(&mut self, mods: u8) {
        self.0.push(format!("held {mods}"));
    }
    fn text(&mut self, _: &str) {}
    fn button(&mut self, b: Button, down: bool, clicks: u32) {
        self.0.push(format!("button {b:?} {down} {clicks}"));
    }
    fn move_by(&mut self, _: f64, _: f64) {}
    fn move_to(&mut self, x: f64, y: f64) {
        self.0.push(format!("to {x:.2} {y:.2}"));
    }
    fn scroll(&mut self, _: f64, dy: f64, p: ScrollPhase) {
        self.0.push(format!("scroll {dy} {p:?}"));
    }
    fn system(&mut self, _: SystemMove) {}
    fn release_all(&mut self) {}
    fn pointer(&self) -> Option<(f64, f64)> {
        Some((0.5, 0.5))
    }
    fn cursor_shape(&mut self) -> Option<CursorShape> {
        None
    }
    fn clipboard(&mut self) -> Option<String> {
        self.0.clipboard.lock().unwrap().clone()
    }
    fn set_clipboard(&mut self, t: &str) {
        self.0.push(format!("clipboard {t}"));
        *self.0.clipboard.lock().unwrap() = Some(t.to_string());
    }
}

/// The recorded stream (platform/windows/testdata/screen.h264, 60 frames, keyframes at 0 and 30) as a screen, round and round.
/// (parameter sets, (keyframe, the frame's one NAL unit))
type Recorded = (Vec<Vec<u8>>, Vec<(bool, Vec<u8>)>);

fn recorded() -> Recorded {
    let b = std::fs::read(
        std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("src/platform/windows/testdata/screen.h264"),
    )
    .unwrap();
    let mut starts = vec![];
    let mut i = 0;
    while i + 3 <= b.len() {
        if b[i] == 0 && b[i + 1] == 0 && b[i + 2] == 1 {
            starts.push(i + 3);
            i += 3;
        } else {
            i += 1;
        }
    }
    let nals: Vec<Vec<u8>> = starts
        .iter()
        .enumerate()
        .map(|(k, s)| {
            let mut v = b[*s..starts.get(k + 1).map(|n| n - 3).unwrap_or(b.len())].to_vec();
            while v.last() == Some(&0) {
                v.pop();
            }
            v
        })
        .collect();
    let sets: Vec<Vec<u8>> = nals
        .iter()
        .filter(|n| matches!(n[0] & 0x1f, 7 | 8))
        .take(2)
        .cloned()
        .collect();
    let frames = nals
        .iter()
        .filter(|n| matches!(n[0] & 0x1f, 1 | 5))
        .map(|n| (n[0] & 0x1f == 5, n.clone()))
        .collect();
    (sets, frames)
}

struct Scr {
    w: World,
    running: Arc<AtomicBool>,
    key: Arc<AtomicBool>,
}

impl Screen for Scr {
    fn start(&mut self, c: &ScreenConfig, sink: FrameSink) -> Result<ScreenInfo, String> {
        self.w.started.lock().unwrap().push((c.width, c.height));
        self.running.store(false, SeqCst);
        let running = Arc::new(AtomicBool::new(true));
        self.running = running.clone();
        let key = self.key.clone();
        std::thread::spawn(move || {
            let (sets, frames) = recorded();
            let mut i = 0;
            while running.load(SeqCst) {
                if key.swap(false, SeqCst) {
                    i = frames.iter().position(|f| f.0).unwrap();
                }
                let (k, nal) = &frames[i % frames.len()];
                let mut picture = (nal.len() as u32).to_be_bytes().to_vec();
                picture.extend_from_slice(nal);
                sink(EncodedFrame {
                    picture,
                    keyframe: *k,
                    parameter_sets: if *k { sets.clone() } else { vec![] },
                    captured: now(),
                    ..Default::default()
                });
                i += 1;
                std::thread::sleep(Duration::from_millis(33));
            }
        });
        Ok(ScreenInfo {
            width: 1440.0,
            height: 900.0,
            codec: "h264".into(),
        })
    }
    fn set_crop(&mut self, _: Crop) {}
    fn set_rate(&mut self, _: u32, _: u32) {}
    fn keyframe(&mut self) {
        self.key.store(true, SeqCst);
    }
    fn refresh(&mut self) {}
    fn stop(&mut self) {
        self.running.store(false, SeqCst);
    }
}

struct Back(In, Scr, &'static str);

impl Backend for Back {
    fn input(&mut self) -> &mut dyn Input {
        &mut self.0
    }
    fn screen(&mut self) -> Option<&mut dyn Screen> {
        Some(&mut self.1)
    }
    fn platform(&self) -> &'static str {
        self.2
    }
    fn display_aspect(&self) -> f64 {
        1.6
    }
    fn now(&self) -> f64 {
        now()
    }
    fn keep_awake(&mut self, _: bool, _: bool) {}
}

struct NoApp;
impl App for NoApp {}

fn host(
    w: &World,
    platform: &'static str,
    answer: bool,
    go_between: &str,
) -> (Host, std::path::PathBuf) {
    host_on(w, platform, answer, go_between, 0)
}

fn host_on(
    w: &World,
    platform: &'static str,
    answer: bool,
    go_between: &str,
    port: u16,
) -> (Host, std::path::PathBuf) {
    let dir = std::env::temp_dir().join(format!(
        "blurt-remote-viewer-{}",
        blurt_remote::crypto::new_id()
    ));
    let h = Host::start(
        HostConfig {
            dir: dir.clone(),
            name: "Studio PC".into(),
            version: "1.0.27".into(),
            test_answer: Some(answer),
            port,
            go_between: Some(go_between.into()),
        },
        Box::new(Back(
            In(w.clone()),
            Scr {
                w: w.clone(),
                running: Arc::default(),
                key: Arc::default(),
            },
            platform,
        )),
        Box::new(FileKeyStore::new(dir.join("keys.json"))),
        Box::new(NoApp),
    );
    (h, dir)
}

async fn until<T>(what: &str, f: impl Fn() -> Option<T>) -> T {
    for _ in 0..600 {
        if let Some(x) = f() {
            return x;
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
    panic!("never: {what}");
}

/// Everything a session said, kept for the test to look through.
#[derive(Clone, Default)]
struct Seen(Arc<Mutex<Vec<Event>>>, Arc<AtomicUsize>);

impl Seen {
    fn on(&self) -> viewer::OnEvent {
        let s = self.clone();
        Arc::new(move |e| {
            if matches!(e, Event::Frame(_)) {
                s.1.fetch_add(1, SeqCst);
            }
            s.0.lock().unwrap().push(e)
        })
    }
    fn find<T>(&self, f: impl Fn(&Event) -> Option<T>) -> Option<T> {
        self.0.lock().unwrap().iter().find_map(f)
    }
    fn frames(&self) -> usize {
        self.1.load(SeqCst)
    }
    fn route(&self) -> Option<Route> {
        self.0.lock().unwrap().iter().rev().find_map(|e| {
            if let Event::Link {
                link: Link::Connected,
                route,
            } = e
            {
                *route
            } else {
                None
            }
        })
    }
}

fn keys(s: &Session, k: &mut Keyboard, code: &str, down: bool, host: &str) {
    for x in k.event(code, down, host, true) {
        if let Sent::Message(m) = x {
            s.send(m);
        }
    }
}

async fn paired_by_link(
    h: &Host,
    digits: Arc<Mutex<Option<String>>>,
) -> (viewer::Computer, Vec<u8>) {
    h.show_pairing(true);
    let link = until("a code", || h.status().pairing.map(|p| p.url)).await;
    let p = Pairing::parse(&link).unwrap();
    let d2 = digits.clone();
    let r = viewer::pair(PairWith::Link(p), "Desk Laptop", None, move |d| {
        *d2.lock().unwrap() = Some(d.to_string())
    })
    .await;
    h.show_pairing(false);
    r.expect("paired")
}

#[tokio::test(flavor = "multi_thread")]
async fn pair_by_link_then_picture_keys_and_clipboard() {
    let _one = ONE_AT_A_TIME.lock().await;
    let w = World::default();
    let (h, _dir) = host(&w, "mac", true, "");
    let digits = Arc::new(Mutex::new(None));
    let (c, key) = paired_by_link(&h, digits.clone()).await;
    // the six digits the host asked with are the ones the viewer showed
    assert_eq!(digits.lock().unwrap().as_deref().map(str::len), Some(6));
    assert_eq!(c.platform.as_deref(), Some("mac"));
    assert_eq!(c.name, "Studio PC");
    assert!(h
        .status()
        .devices
        .iter()
        .any(|d| d.id == c.device_id && d.name == "Desk Laptop"));

    let seen = Seen::default();
    let s = Session::start(
        &tokio::runtime::Handle::current(),
        // loopback first: this machine's LAN address may be filtered for UDP (macOS's firewall and an unsigned test binary)
        Target {
            computer: c.clone(),
            key,
            device: "Desk Laptop".into(),
            nearby: vec![IpAddr::from([127, 0, 0, 1])],
            go_between_at: None,
        },
        seen.on(),
        Arc::new(|_| {}),
    );
    let info = until("session", || {
        seen.find(|e| {
            if let Event::Session(i) = e {
                Some(i.clone())
            } else {
                None
            }
        })
    })
    .await;
    assert!(
        info.features
            .as_ref()
            .is_some_and(|f| f.iter().any(|x| x == "viewer")),
        "the host takes a viewer's extras"
    );
    assert_eq!(seen.route(), Some(Route::Local));
    until("connected on the host", || {
        h.status().connected.filter(|c| c.route == "local")
    })
    .await;

    // the picture: a window of 1200 × 800 pixels is the ceiling; the host fits its display's shape (1.6) inside
    s.screen(Some(Want {
        quality: Quality::Auto,
        window: (1200, 800),
        codecs: vec!["h264".into()],
        display: None,
    }));
    until("the stream started", || {
        w.started.lock().unwrap().first().copied()
    })
    .await;
    assert_eq!(w.started.lock().unwrap()[0], (1200, 750));
    until("20 frames", || (seen.frames() >= 20).then_some(())).await;
    let first = seen
        .find(|e| {
            if let Event::Frame(f) = e {
                Some(f.clone())
            } else {
                None
            }
        })
        .unwrap();
    assert!(first.keyframe, "the first frame handed on is a keyframe");
    assert_eq!(
        first.codec, "avc1.64000D",
        "the recorded stream's High profile, level 1.3"
    );
    assert_eq!(&first.data[..5], &[0, 0, 0, 1, 0x67], "Annex B, SPS first");
    let (sets, frames) = recorded();
    assert_eq!(
        first.data,
        viewer::annex_b(
            &sets,
            &[&(frames[0].1.len() as u32).to_be_bytes()[..], &frames[0].1].concat()
        )
    );
    assert!(
        seen.find(|e| if let Event::View { width, family, .. } = e {
            Some((*width, family.clone()))
        } else {
            None
        }) == Some((1440.0, "h264".into()))
    );

    // keys: Ctrl+C on this keyboard is ⌘C to a Mac
    let mut k = Keyboard::new();
    keys(&s, &mut k, "ControlLeft", true, "mac");
    keys(&s, &mut k, "KeyC", true, "mac");
    keys(&s, &mut k, "KeyC", false, "mac");
    keys(&s, &mut k, "ControlLeft", false, "mac");
    until("⌘C", || {
        (w.has("held 1")
            && w.has("key C 0 Some(true)")
            && w.has("key C 0 Some(false)")
            && w.has("held 0"))
        .then_some(())
    })
    .await;
    // the keypad and F13, which the phone never sent
    keys(&s, &mut k, "Numpad7", true, "mac");
    keys(&s, &mut k, "Numpad7", false, "mac");
    keys(&s, &mut k, "F13", true, "mac");
    keys(&s, &mut k, "F13", false, "mac");
    until("keypad and F13", || {
        (w.has("key Keypad7 0 Some(false)") && w.has("key F13 0 Some(false)")).then_some(())
    })
    .await;

    // the pointer: absolute, a double click in place, the wheel
    s.send(ToMac::PointerTo {
        x: 0.25,
        y: 0.75,
        seq: None,
    });
    for down in [true, false, true, false] {
        s.send(ToMac::Button {
            button: blurt_remote::wire::MouseButton::Left,
            down,
        });
    }
    s.pointer(blurt_remote::packets::PointerPacket::Scroll {
        dx: 0.0,
        dy: -40.0,
        phase: blurt_remote::packets::ScrollPhase::Changed,
    });
    until("pointer", || {
        (w.has("to 0.25 0.75") && w.has("button Left true 2") && w.has("scroll -40 Began"))
            .then_some(())
    })
    .await;

    // the clipboard: nothing goes until the keys are captured
    *w.clipboard.lock().unwrap() = Some("on the host before".into());
    s.send(ToMac::Clipboard("too early".into()));
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert!(!w.has("clipboard too early"));
    s.send(ToMac::KeysCaptured(true));
    s.send(ToMac::Clipboard("from the viewer".into()));
    until("the viewer's clipboard on the host", || {
        w.has("clipboard from the viewer").then_some(())
    })
    .await;
    tokio::time::sleep(Duration::from_millis(700)).await;
    assert!(
        seen.find(|e| if let Event::Clipboard(t) = e {
            Some(t.clone())
        } else {
            None
        })
        .is_none(),
        "what the viewer sent doesn't come back"
    );
    *w.clipboard.lock().unwrap() = Some("copied on the host".into());
    let back = until("the host's clipboard on the viewer", || {
        seen.find(|e| {
            if let Event::Clipboard(t) = e {
                Some(t.clone())
            } else {
                None
            }
        })
    })
    .await;
    assert_eq!(back, "copied on the host");
    // too long: not sent
    s.send(ToMac::Clipboard("x".repeat(64 * 1024 + 1)));
    // released: the host's clipboard stays there
    s.send(ToMac::KeysCaptured(false));
    tokio::time::sleep(Duration::from_millis(200)).await;
    *w.clipboard.lock().unwrap() = Some("after the release".into());
    tokio::time::sleep(Duration::from_millis(1200)).await;
    let all: Vec<String> = seen
        .0
        .lock()
        .unwrap()
        .iter()
        .filter_map(|e| {
            if let Event::Clipboard(t) = e {
                Some(t.clone())
            } else {
                None
            }
        })
        .collect();
    assert_eq!(all, vec!["copied on the host".to_string()]);
    assert!(!w
        .log
        .lock()
        .unwrap()
        .iter()
        .any(|l| l.starts_with("clipboard xxx")));

    // a bigger window asks again, and the host follows
    s.screen(Some(Want {
        quality: Quality::Auto,
        window: (2000, 1400),
        codecs: vec!["h264".into()],
        display: None,
    }));
    until("a new size", || {
        w.started
            .lock()
            .unwrap()
            .contains(&(2000, 1250))
            .then_some(())
    })
    .await;

    // removed on the host: the viewer hears it and stops
    h.remove_device(&c.device_id);
    until("removed", || {
        seen.find(|e| {
            matches!(
                e,
                Event::Link {
                    link: Link::Removed,
                    ..
                }
            )
            .then_some(())
        })
    })
    .await;
    drop(s);
    h.stop();
}

#[tokio::test(flavor = "multi_thread")]
async fn pair_with_a_computer_found_nearby() {
    let _one = ONE_AT_A_TIME.lock().await;
    let w = World::default();
    let (h, _dir) = host(&w, "windows", true, "");
    // a host listens (and advertises) once it has a device or shows a code: a phone paired before
    h.show_pairing(true);
    let link = until("a code", || h.status().pairing.map(|p| p.url)).await;
    let port = h.status().port;
    let _ = viewer::pair(
        PairWith::Link(Pairing::parse(&link).unwrap()),
        "Phone",
        None,
        |_| {},
    )
    .await
    .expect("the first device");
    h.show_pairing(false);
    let found = Found {
        host_id: "x".into(),
        name: "Studio PC".into(),
        addresses: vec![IpAddr::from([127, 0, 0, 1])],
        port,
    };
    let digits = Arc::new(Mutex::new(None));
    let d2 = digits.clone();
    let (c, key) = viewer::pair(
        PairWith::Nearby(found.clone()),
        "Desk Laptop",
        None,
        move |d| *d2.lock().unwrap() = Some(d.to_string()),
    )
    .await
    .expect("paired nearby");
    assert!(
        digits.lock().unwrap().is_some(),
        "the owner was asked, with digits"
    );
    assert!(c.device_id.starts_with("nearby-"));
    assert_ne!(
        key,
        blurt_remote::pairing::nearby_key().to_vec(),
        "a key of its own, not the nearby one"
    );
    assert_eq!(h.status().devices.len(), 2);
    // and it opens a session with that key
    let (mut p, _) = viewer::open(
        "Desk Laptop",
        &c.device_id,
        &key,
        port,
        &["127.0.0.1".into()],
        &[],
        None,
        None,
    )
    .await
    .expect("opens");
    p.wait(Duration::from_secs(5), |m| {
        matches!(m, blurt_remote::wire::ToPhone::Session(_)).then_some(())
    })
    .await
    .expect("session");
    drop(p);
    h.stop();

    // an owner who says no: refused, and the next nearby ask within 30 s isn't taken
    let w = World::default();
    let (h, _dir) = host(&w, "windows", false, "");
    h.show_pairing(true);
    until("listening", || (h.status().port != 0).then_some(())).await;
    let port = h.status().port;
    let found = Found { port, ..found };
    let r = viewer::pair(PairWith::Nearby(found.clone()), "Desk Laptop", None, |_| {}).await;
    assert_eq!(r.err(), Some(PairError::Declined));
    let r = viewer::pair(PairWith::Nearby(found), "Desk Laptop", None, |_| {}).await;
    assert_eq!(
        r.err(),
        Some(PairError::Spent),
        "paused after a no: not taking a new computer now"
    );
    // an id the host doesn't know, without the nearby prefix, is not_paired as it always was (a removed phone hears that)
    let r = blurt_remote::phone::Phone::connect(
        format!("127.0.0.1:{port}").parse::<SocketAddr>().unwrap(),
        "someone",
        &[1; 32],
    )
    .await;
    assert!(r.err().is_some_and(|e| e.contains("NotPaired")));
    h.stop();
}

// ------------------------------------------------------------------ how a pairing ends when it doesn't pair

/// A pasted link whose code the host no longer takes (used already): refused before anyone was asked, not "didn't allow".
#[tokio::test(flavor = "multi_thread")]
async fn a_spent_link_is_not_a_refusal() {
    let _one = ONE_AT_A_TIME.lock().await;
    let w = World::default();
    let (h, _dir) = host(&w, "windows", true, "");
    h.show_pairing(true);
    let link = until("a code", || h.status().pairing.map(|p| p.url)).await;
    viewer::pair(
        PairWith::Link(Pairing::parse(&link).unwrap()),
        "Desk Laptop",
        None,
        |_| {},
    )
    .await
    .expect("the first time");
    let asked = Arc::new(AtomicBool::new(false));
    let a2 = asked.clone();
    let r = viewer::pair(
        PairWith::Link(Pairing::parse(&link).unwrap()),
        "Desk Laptop",
        None,
        move |_| a2.store(true, SeqCst),
    )
    .await;
    assert_eq!(r.err(), Some(PairError::Spent));
    assert!(!asked.load(SeqCst), "nobody was asked");
    h.stop();
}

/// The owner said no (here 3 s after the question, the test host's answer): declined. The same close at 90 % of the host's question
/// or later is nobody answering (the question's life cut to 3 s here).
#[tokio::test(flavor = "multi_thread")]
async fn a_no_and_no_answer() {
    let _one = ONE_AT_A_TIME.lock().await;
    for (life, want) in [
        (viewer::QUESTION_LIFE, PairError::Declined),
        (Duration::from_secs(3), PairError::Unanswered),
    ] {
        let w = World::default();
        let (h, _dir) = host(&w, "windows", false, "");
        h.show_pairing(true);
        let link = until("a code", || h.status().pairing.map(|p| p.url)).await;
        let steps = Arc::new(Mutex::new(vec![]));
        let s2 = steps.clone();
        let r = viewer::pair_steps(
            PairWith::Link(Pairing::parse(&link).unwrap()),
            "Desk Laptop",
            None,
            life,
            true,
            move |s| s2.lock().unwrap().push(s),
        )
        .await;
        assert_eq!(r.err(), Some(want));
        assert!(
            matches!(steps.lock().unwrap().as_slice(), [PairStep::Asking(d)] if d.len() == 6),
            "{:?}",
            steps.lock().unwrap()
        );
        h.stop();
    }
}

/// Nothing there at first: it says so and goes on trying; once the host is up and asks, the digits come (they replace "can't
/// reach" in the panel), and a yes pairs.
#[tokio::test(flavor = "multi_thread")]
async fn unreachable_then_asked() {
    let _one = ONE_AT_A_TIME.lock().await;
    let port = std::net::TcpListener::bind("127.0.0.1:0")
        .unwrap()
        .local_addr()
        .unwrap()
        .port();
    let found = Found {
        host_id: "x".into(),
        name: "Studio PC".into(),
        addresses: vec![IpAddr::from([127, 0, 0, 1])],
        port,
    };
    let steps = Arc::new(Mutex::new(vec![]));
    let s2 = steps.clone();
    let pairing = tokio::spawn(async move {
        viewer::pair_steps(
            PairWith::Nearby(found),
            "Desk Laptop",
            None,
            viewer::QUESTION_LIFE,
            true,
            move |s| s2.lock().unwrap().push(s),
        )
        .await
    });
    let unreachable = || {
        steps
            .lock()
            .unwrap()
            .contains(&PairStep::Unreachable)
            .then_some(())
    };
    for _ in 0..60 {
        if unreachable().is_some() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(250)).await;
    }
    assert!(unreachable().is_some(), "{:?}", steps.lock().unwrap());
    let w = World::default();
    let (h, _dir) = host_on(&w, "windows", true, "", port);
    h.show_pairing(true);
    let (c, _key) = tokio::time::timeout(Duration::from_secs(20), pairing)
        .await
        .expect("in time")
        .unwrap()
        .expect("paired");
    assert!(c.device_id.starts_with("nearby-"));
    assert!(
        matches!(
            steps.lock().unwrap().as_slice(),
            [PairStep::Unreachable, PairStep::Asking(_)]
        ),
        "{:?}",
        steps.lock().unwrap()
    );
    h.stop();
}

/// A key the host refuses with no session (anyone on the network can send that): `Forgotten`, not the `Removed` a session says.
#[tokio::test(flavor = "multi_thread")]
async fn a_refused_key_is_forgotten_not_removed() {
    let _one = ONE_AT_A_TIME.lock().await;
    let w = World::default();
    let (h, _dir) = host(&w, "windows", true, "");
    h.show_pairing(true);
    let link = until("a code", || h.status().pairing.map(|p| p.url)).await;
    let (c, _key) = viewer::pair(
        PairWith::Link(Pairing::parse(&link).unwrap()),
        "Desk Laptop",
        None,
        |_| {},
    )
    .await
    .expect("paired");
    let seen = Seen::default();
    let s = Session::start(
        &tokio::runtime::Handle::current(),
        Target {
            computer: c,
            key: vec![9; 32],
            device: "Desk Laptop".into(),
            nearby: vec![IpAddr::from([127, 0, 0, 1])],
            go_between_at: None,
        },
        seen.on(),
        Arc::new(|_| {}),
    );
    until("forgotten", || {
        seen.find(|e| {
            matches!(
                e,
                Event::Link {
                    link: Link::Forgotten,
                    ..
                }
            )
            .then_some(())
        })
    })
    .await;
    assert!(seen
        .find(|e| matches!(
            e,
            Event::Link {
                link: Link::Removed,
                ..
            }
        )
        .then_some(()))
        .is_none());
    drop(s);
    h.stop();
}

// ------------------------------------------------------------------ through the public connection service

struct Relay(Child, u16);

impl Drop for Relay {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

async fn relay() -> Result<Relay, String> {
    let repo = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
    let port = std::net::TcpListener::bind("127.0.0.1:0")
        .map_err(|e| e.to_string())?
        .local_addr()
        .unwrap()
        .port();
    let mut c = Command::new("node");
    c.arg(repo.join("tools/remote-relay/server.js"))
        .env("BUDGET", "1")
        .env("HOST", "127.0.0.1")
        .env("PORT", port.to_string());
    c.stdout(Stdio::null()).stderr(Stdio::null());
    if !repo.join("tools/remote-relay/node_modules/ws").exists() {
        let pnpm = repo.join("web/node_modules/.pnpm");
        if let Some(p) = std::fs::read_dir(&pnpm).ok().and_then(|d| {
            d.flatten().map(|e| e.path()).find(|p| {
                p.file_name()
                    .is_some_and(|n| n.to_string_lossy().starts_with("ws@8"))
            })
        }) {
            c.env("NODE_PATH", p.join("node_modules"));
        }
    }
    let r = Relay(c.spawn().map_err(|e| format!("node: {e}"))?, port);
    for _ in 0..50 {
        tokio::time::sleep(Duration::from_millis(100)).await;
        if tokio::net::TcpStream::connect(("127.0.0.1", port))
            .await
            .is_ok()
        {
            return Ok(r);
        }
    }
    Err("the relay didn't start".into())
}

#[tokio::test(flavor = "multi_thread")]
async fn through_the_public_connection_service_then_direct() {
    let _one = ONE_AT_A_TIME.lock().await;
    let r = match relay().await {
        Ok(r) => r,
        Err(why) => return eprintln!("skipped: {why}"),
    };
    let meet = format!("ws://127.0.0.1:{}", r.1);
    let w = World::default();
    let (h, _dir) = host(&w, "windows", true, &meet);
    let (c, key) = paired_by_link(&h, Arc::default()).await;
    assert_eq!(
        c.relay.as_deref(),
        Some(meet.as_str()),
        "a viewer that can move is offered the public connection service"
    );
    // away: no address that answers, only the public connection service
    let away = viewer::Computer {
        addresses: vec![],
        port: 9,
        ..c.clone()
    };
    let seen = Seen::default();
    let s = Session::start(
        &tokio::runtime::Handle::current(),
        Target {
            computer: away,
            key,
            device: "Desk Laptop".into(),
            nearby: vec![],
            go_between_at: Some(meet.clone()),
        },
        seen.on(),
        Arc::new(|_| {}),
    );
    // first through it, then the direct path (the session's candidates include this machine's addresses)
    until("direct", || {
        (seen.route() == Some(Route::Direct)).then_some(())
    })
    .await;
    let first = seen.find(|e| {
        if let Event::Link {
            link: Link::Connected,
            route,
        } = e
        {
            *route
        } else {
            None
        }
    });
    assert_eq!(first, Some(Route::GoBetween));
    assert_eq!(
        seen.route(),
        Some(Route::Direct),
        "moved onto the direct path"
    );
    s.screen(Some(Want {
        quality: Quality::Auto,
        window: (1600, 1000),
        codecs: vec!["h264".into()],
        display: None,
    }));
    until("frames after the move", || {
        (seen.frames() >= 30).then_some(())
    })
    .await;
    let mut k = Keyboard::new();
    keys(&s, &mut k, "ControlLeft", true, "windows");
    keys(&s, &mut k, "KeyV", true, "windows");
    keys(&s, &mut k, "KeyV", false, "windows");
    keys(&s, &mut k, "ControlLeft", false, "windows");
    until("Ctrl+V", || {
        (w.has("held 8") && w.has("key V 0 Some(false)")).then_some(())
    })
    .await;
    // far more than the service's budget went (frames), and the session is still up
    tokio::time::sleep(Duration::from_secs(2)).await;
    assert!(h.status().connected.is_some());
    // once connected, never dropped (a first try before the host waits in its room may say Offline: that's the start, not a drop)
    let events = seen.0.lock().unwrap().clone();
    let up = events
        .iter()
        .position(|e| {
            matches!(
                e,
                Event::Link {
                    link: Link::Connected,
                    ..
                }
            )
        })
        .expect("connected");
    assert!(!events[up..].iter().any(|e| matches!(
        e,
        Event::Link {
            link: Link::NoDirect | Link::Offline,
            ..
        }
    )));
    drop(s);
    h.stop();
}

/// 2026-11-20, the office: the computer's own relay was dead. The viewer says so after two tries, and goes through the public
/// connection service, where the host waits meanwhile.
#[tokio::test(flavor = "multi_thread")]
async fn a_dead_own_relay_goes_through_the_public_connection_service() {
    let _one = ONE_AT_A_TIME.lock().await;
    let r = match relay().await {
        Ok(r) => r,
        Err(why) => return eprintln!("skipped: {why}"),
    };
    let meet = format!("ws://127.0.0.1:{}", r.1);
    let w = World::default();
    let (h, _dir) = host(&w, "windows", true, &meet);
    let (c, key) = paired_by_link(&h, Arc::default()).await;
    // the owner's relay: nothing listens on port 9
    h.set_relay(Some("ws://127.0.0.1:9")).unwrap();
    until("host falls back", || {
        h.status().relay.fallback.then_some(())
    })
    .await;
    let away = viewer::Computer {
        addresses: vec![],
        port: 9,
        relay: Some("ws://127.0.0.1:9".into()),
        ..c.clone()
    };
    let seen = Seen::default();
    let s = Session::start(
        &tokio::runtime::Handle::current(),
        Target {
            computer: away,
            key,
            device: "Desk Laptop".into(),
            nearby: vec![],
            go_between_at: Some(meet.clone()),
        },
        seen.on(),
        Arc::new(|_| {}),
    );
    until("connected", || {
        seen.find(|e| {
            if let Event::Link {
                link: Link::Connected,
                route,
            } = e
            {
                *route
            } else {
                None
            }
        })
    })
    .await;
    assert!(
        seen.0.lock().unwrap().iter().any(|e| matches!(
            e,
            Event::Link {
                link: Link::RelayDown,
                ..
            }
        )),
        "said why first"
    );
    drop(s);
    h.stop();
}

/// Send Files (remote-1.1.md §6): a file goes, in chunks, to the host's Downloads under its own name, and the viewer hears it saved.
#[tokio::test(flavor = "multi_thread")]
async fn a_file_goes_to_the_hosts_downloads() {
    let _one = ONE_AT_A_TIME.lock().await;
    let w = World::default();
    let (h, dir) = host(&w, "windows", true, "");
    let downloads = dir.join("Downloads");
    h.set_downloads(Some(downloads.clone()));
    let (c, key) = paired_by_link(&h, Arc::default()).await;
    let seen = Seen::default();
    let s = Session::start(
        &tokio::runtime::Handle::current(),
        Target {
            computer: c.clone(),
            key,
            device: "Desk Laptop".into(),
            nearby: vec![IpAddr::from([127, 0, 0, 1])],
            go_between_at: None,
        },
        seen.on(),
        Arc::new(|_| {}),
    );
    let info = until("session", || {
        seen.find(|e| {
            if let Event::Session(i) = e {
                Some(i.clone())
            } else {
                None
            }
        })
    })
    .await;
    assert!(
        info.features
            .as_ref()
            .is_some_and(|f| f.iter().any(|x| x == "files")),
        "a host with a Downloads folder takes files"
    );
    // 3 MB in 192 KB chunks: progress comes back every MB
    let body: Vec<u8> = (0..3 * 1024 * 1024).map(|i| (i % 251) as u8).collect();
    s.send(ToMac::FileBegin {
        id: "f1".into(),
        name: "../report.bin".into(),
        size: body.len() as i64,
    });
    for c in body.chunks(192 * 1024) {
        s.send(ToMac::FileChunk {
            id: "f1".into(),
            data: c.to_vec(),
        });
    }
    s.send(ToMac::FileEnd { id: "f1".into() });
    let name = until("saved", || {
        seen.find(|e| {
            if let Event::FileSaved { name, .. } = e {
                Some(name.clone())
            } else {
                None
            }
        })
    })
    .await;
    assert_eq!(name, "report.bin", "no folders in the name");
    assert!(seen
        .find(|e| matches!(e, Event::FileProgress { bytes, .. } if *bytes >= 1 << 20).then_some(()))
        .is_some());
    assert_eq!(std::fs::read(downloads.join("report.bin")).unwrap(), body);
    assert!(!downloads.join("report.bin.part").exists());
    drop(s);
    h.stop();
}
