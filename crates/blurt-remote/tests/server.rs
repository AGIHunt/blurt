//! The real server on loopback against the Rust test phone: pairing with the six digits and an automatic yes (the test flag),
//! the new key, a session with the backend's platform, keys and the pointer over TCP and UDP, the security rules that can be
//! seen from outside, and a screen request on a host with no screen.

use std::net::SocketAddr;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use blurt_remote::host::{Backend, Button, CursorShape, Input, ScrollPhase, SystemMove};
use blurt_remote::packets::{PointerPacket, ScrollPhase as WirePhase};
use blurt_remote::phone::{pair, Phone};
use blurt_remote::store::FileKeyStore;
use blurt_remote::wire::{BlurtCommand, Chord, ToMac, ToPhone};
use blurt_remote::{App, Host, HostConfig};

#[derive(Clone, Default)]
struct Lines(Arc<Mutex<Vec<String>>>);

impl Lines {
    fn push(&self, s: String) {
        self.0.lock().unwrap().push(s);
    }
    fn take(&self) -> Vec<String> {
        std::mem::take(&mut self.0.lock().unwrap())
    }
    async fn wait(&self, what: &str) -> Vec<String> {
        for _ in 0..100 {
            if self.0.lock().unwrap().iter().any(|l| l.contains(what)) {
                return self.take();
            }
            tokio::time::sleep(Duration::from_millis(30)).await;
        }
        panic!("never saw {what:?}: {:?}", self.0.lock().unwrap());
    }
}

struct TestInput(Lines);

impl Input for TestInput {
    fn can_control(&self) -> bool {
        true
    }
    fn key(&mut self, name: &str, mods: u8, down: Option<bool>) {
        self.0.push(format!("key {name} {mods} {down:?}"));
    }
    fn set_held(&mut self, mods: u8) {
        self.0.push(format!("held {mods}"));
    }
    fn text(&mut self, t: &str) {
        self.0.push(format!("text {t}"));
    }
    fn button(&mut self, b: Button, down: bool, clicks: u32) {
        self.0.push(format!("button {b:?} {down} {clicks}"));
    }
    fn move_by(&mut self, dx: f64, dy: f64) {
        self.0.push(format!("move {dx} {dy}"));
    }
    fn move_to(&mut self, x: f64, y: f64) {
        self.0.push(format!("to {x} {y}"));
    }
    fn scroll(&mut self, dx: f64, dy: f64, p: ScrollPhase) {
        self.0.push(format!("scroll {dx} {dy} {p:?}"));
    }
    fn system(&mut self, m: SystemMove) {
        self.0.push(format!("system {m:?}"));
    }
    fn release_all(&mut self) {
        self.0.push("release".into());
    }
    fn pointer(&self) -> Option<(f64, f64)> {
        None
    }
    fn cursor_shape(&mut self) -> Option<CursorShape> {
        None
    }
}

struct TestBackend(TestInput);

impl Backend for TestBackend {
    fn input(&mut self) -> &mut dyn Input {
        &mut self.0
    }
    fn screen(&mut self) -> Option<&mut dyn blurt_remote::host::Screen> {
        None
    }
    fn platform(&self) -> &'static str {
        "windows"
    }
    fn display_aspect(&self) -> f64 {
        1.5
    }
    fn now(&self) -> f64 {
        0.0
    }
    fn keep_awake(&mut self, on: bool, display: bool) {
        self.0 .0.push(format!("awake {on} {display}"));
    }
}

struct TestApp(Lines);

impl App for TestApp {
    fn asking(&self, device: &str, digits: &str) {
        self.0.push(format!("asking {device} {digits}"));
    }
    fn dictation_key(&self, down: bool, phone_mic: bool) {
        self.0.push(format!("dictation {down} {phone_mic}"));
    }
    fn blurt(&self, c: BlurtCommand, _: bool) {
        self.0.push(format!("blurt {}", c.name()));
    }
    fn session(&self, name: Option<&str>) {
        self.0.push(format!("session {name:?}"));
    }
}

fn host(dir: &std::path::Path, input: Lines, app: Lines) -> Host {
    host_answering(dir, input, app, Some(true))
}

fn host_answering(dir: &std::path::Path, input: Lines, app: Lines, answer: Option<bool>) -> Host {
    Host::start(
        HostConfig { dir: dir.into(), name: "Studio PC".into(), version: "1.0.15".into(), test_answer: answer, port: 0, go_between: Some(String::new()) },
        Box::new(TestBackend(TestInput(input))),
        Box::new(FileKeyStore::new(dir.join("keys.json"))),
        Box::new(TestApp(app)),
    )
}

async fn until<T>(f: impl Fn() -> Option<T>) -> T {
    for _ in 0..200 {
        if let Some(x) = f() {
            return x;
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
    panic!("never");
}

#[tokio::test(flavor = "multi_thread")]
async fn pairing_a_session_keys_and_the_pointer() {
    let dir = std::env::temp_dir().join(format!("blurt-remote-test-{}", blurt_remote::crypto::new_id()));
    let (input, app) = (Lines::default(), Lines::default());
    let h = host(&dir, input.clone(), app.clone());
    assert!(!h.status().listening, "nothing listens with no phone paired and no code showing");
    h.show_pairing(true);
    let (link, port) = until(|| h.status().pairing.map(|p| (p.url, h.status().port))).await;
    let at: SocketAddr = format!("127.0.0.1:{port}").parse().unwrap();

    // a stranger is refused, and a code answers only so many handshakes
    let stranger = Phone::connect(at, "nobody", &[9; 32]).await;
    assert_eq!(stranger.err().as_deref(), Some("NotPaired"));

    let (mut phone, device, key, info) = pair(&link, at).await.expect("paired");
    assert_eq!(info.platform.as_deref(), Some("windows"));
    assert_eq!(info.mac_name, "Studio PC");
    assert!(info.can_control);
    assert_eq!(info.display_aspect, 1.5);
    let asked = app.wait("asking").await;
    assert!(asked.iter().any(|l| l.starts_with("asking Test Phone ") && l.ends_with(&phone.check)), "the same six digits: {asked:?}");
    until(|| h.status().connected.filter(|c| c.route == "local")).await;
    assert_eq!(h.status().devices.len(), 1);
    assert!(h.status().pairing.is_some(), "a fresh code took the spent one's place");

    // Ctrl+C, the way a keyboard makes it
    input.take();
    phone.send(&ToMac::Key { chord: Chord::new(8, "C"), down: None }).await;
    assert_eq!(input.wait("held 0").await, ["held 8", "key C 0 None", "held 0"]);

    // the pointer over the stream, then over UDP once the host says it got a packet
    phone.pointer(PointerPacket::Move { dx: 3.0, dy: -2.0, seq: None }).await;
    input.wait("move 3 -2").await;
    phone.open_udp(info.udp_port, info.udp_session).await.unwrap();
    phone.wait(Duration::from_secs(3), |m| matches!(m, ToPhone::UdpOk).then_some(())).await.expect("udpOK");
    phone.pointer(PointerPacket::Scroll { dx: 0.0, dy: 7.0, phase: WirePhase::Changed }).await;
    input.wait("scroll 0 7 Began").await;

    // the talk key and Blurt's commands go to the app
    phone.send(&ToMac::DictationKey { down: true }).await;
    app.wait("dictation true true").await;
    phone.send(&ToMac::Blurt(BlurtCommand::Snap)).await;
    app.wait("blurt snap").await;

    // a sequence over the cap is dropped whole; one within it runs
    let long: Vec<_> = (0..33).map(|_| blurt_remote::wire::Step::Key(Chord::new(0, "A"))).collect();
    phone.send(&ToMac::Run(long)).await;
    phone.send(&ToMac::Run(vec![blurt_remote::wire::Step::Key(Chord::new(0, "Escape")), blurt_remote::wire::Step::Wait(50), blurt_remote::wire::Step::Key(Chord::new(0, "Escape"))])).await;
    let ran = input.wait("key Escape").await;
    assert!(!ran.iter().any(|l| l == "key A 0 None"), "{ran:?}");

    // no screen on this host: said in plain words
    phone.send(&ToMac::Screen(Some(blurt_remote::wire::ScreenRequest {
        target: "display".into(),
        crop: blurt_remote::wire::Crop::WHOLE,
        width: 1600,
        height: 1000,
        bitrate: 4_000_000,
        fps: 30,
        codecs: Some(vec!["h264".into()]),
        display: None,
        features: None,
            window: None,
    })))
    .await;
    let why = phone.wait(Duration::from_secs(3), |m| if let ToPhone::ScreenFailed(w) = m { Some(w.clone()) } else { None }).await;
    assert_eq!(why.as_deref(), Some(blurt_remote::screen::NO_SCREEN));

    // quiet for 2 s: everything held is let go of, the dictation key too
    input.take();
    tokio::time::sleep(Duration::from_millis(2600)).await;
    assert!(input.take().contains(&"release".to_string()));
    app.wait("dictation false").await;

    // renamed here (remote-1.1.md §6): the list, the bar and the mic's name say it at once; the id stays
    app.take();
    h.rename_device(&device, "  Kitchen tablet ");
    let d = h.status().devices[0].clone();
    assert_eq!((d.id.as_str(), d.name.as_str(), d.shown()), (device.as_str(), "Test Phone", "Kitchen tablet"));
    assert_eq!(h.status().connected.map(|c| c.name).as_deref(), Some("Kitchen tablet"));
    app.wait("session Some(\"Kitchen tablet\")").await;

    // the spent code opens nothing any more; the new key does, and takes over from the old session
    let p = blurt_remote::pairing::Pairing::parse(&link).unwrap();
    assert!(Phone::connect(at, &p.device_id, &p.key).await.is_err());
    let mut again = Phone::connect(at, &device, &key).await.expect("the kept key");
    let info2 = again.wait(Duration::from_secs(3), |m| if let ToPhone::Session(i) = m { Some(i.clone()) } else { None }).await;
    assert!(info2.is_some());
    assert!(info2.unwrap().udp_session != info.udp_session);
    // its hello named it again: the alias still shows, and is what the new session is called here
    until(|| h.status().connected.filter(|c| c.name == "Kitchen tablet")).await;
    assert_eq!(h.status().devices[0].alias.as_deref(), Some("Kitchen tablet"));
    // emptied: its own name again
    h.rename_device(&device, "");
    assert_eq!(h.status().devices[0].shown(), "Test Phone");
    assert_eq!(h.status().connected.map(|c| c.name).as_deref(), Some("Test Phone"));

    // removed here: the phone hears so, and the key is gone
    h.remove_device(&device);
    again.wait(Duration::from_secs(2), |m| matches!(m, ToPhone::Removed).then_some(())).await.expect("removed");
    tokio::time::sleep(Duration::from_millis(500)).await;
    assert!(Phone::connect(at, &device, &key).await.is_err());
    h.show_pairing(false);
    until(|| (!h.status().listening).then_some(())).await;
    h.stop();
    let _ = std::fs::remove_dir_all(dir);
}

#[tokio::test(flavor = "multi_thread")]
async fn a_hello_too_big_closes_and_a_slow_handshake_times_out() {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let dir = std::env::temp_dir().join(format!("blurt-remote-test-{}", blurt_remote::crypto::new_id()));
    let h = host(&dir, Lines::default(), Lines::default());
    h.show_pairing(true);
    let port = until(|| h.status().pairing.map(|_| h.status().port)).await;
    let mut c = tokio::net::TcpStream::connect(("127.0.0.1", port)).await.unwrap();
    c.write_all(&4096u32.to_be_bytes()).await.unwrap();
    let mut b = [0u8; 16];
    let n = tokio::time::timeout(Duration::from_secs(2), c.read(&mut b)).await.expect("closed at once").unwrap_or(0);
    assert_eq!(n, 0);
    let mut idle = tokio::net::TcpStream::connect(("127.0.0.1", port)).await.unwrap();
    let t0 = std::time::Instant::now();
    let n = tokio::time::timeout(Duration::from_secs(9), idle.read(&mut b)).await.expect("closed within 6 s").unwrap_or(0);
    assert_eq!(n, 0);
    assert!(t0.elapsed() >= Duration::from_secs(5));
    h.stop();
    let _ = std::fs::remove_dir_all(dir);
}

#[tokio::test(flavor = "multi_thread")]
async fn the_yes_is_for_the_digits_shown_and_survives_the_pane_closing() {
    let dir = std::env::temp_dir().join(format!("blurt-remote-test-{}", blurt_remote::crypto::new_id()));
    let app = Lines::default();
    let h = host_answering(&dir, Lines::default(), app.clone(), None);
    h.show_pairing(true);
    let (link, port) = until(|| h.status().pairing.map(|p| (p.url, h.status().port))).await;
    let at: SocketAddr = format!("127.0.0.1:{port}").parse().unwrap();
    let p = blurt_remote::pairing::Pairing::parse(&link).unwrap();
    let mut phone = Phone::connect(at, &p.device_id, &p.key).await.unwrap();
    phone.wait(Duration::from_secs(3), |m| matches!(m, ToPhone::PairingWaits).then_some(())).await.expect("asks");
    let asking = until(|| h.status().asking).await;
    assert_eq!(asking.digits, phone.check);
    assert!(!asking.via_relay);
    // Settings closes: the question stays, and so does the way in
    h.show_pairing(false);
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert!(h.status().asking.is_some());
    assert!(h.status().listening);
    // a yes for other digits answers nothing
    let wrong = if asking.digits == "000000" { "000001" } else { "000000" };
    h.answer_pairing(true, Some(wrong));
    assert!(h.status().asking.is_some());
    h.answer_pairing(true, Some(&asking.digits));
    let key = phone.wait(Duration::from_secs(3), |m| if let ToPhone::NewKey(k) = m { Some(k.clone()) } else { None }).await;
    assert_eq!(key.map(|k| k.len()), Some(32));
    phone.send(&ToMac::KeyStored).await;
    phone.wait(Duration::from_secs(3), |m| matches!(m, ToPhone::Session(_)).then_some(())).await.expect("session");
    assert!(h.status().listening, "a paired phone keeps it listening");

    // a no, with the code showing: a fresh code
    h.show_pairing(true);
    let first = until(|| h.status().pairing.map(|p| p.url)).await;
    let q = blurt_remote::pairing::Pairing::parse(&first).unwrap();
    let mut other = Phone::connect(at, &q.device_id, &q.key).await.unwrap();
    other.wait(Duration::from_secs(3), |m| matches!(m, ToPhone::PairingWaits).then_some(())).await.expect("asks");
    let asking = until(|| h.status().asking).await;
    h.answer_pairing(false, Some(&asking.digits));
    assert!(matches!(other.next(Duration::from_secs(2)).await, Some(blurt_remote::phone::Event::Closed) | None));
    let next = h.status().pairing.map(|p| p.url).unwrap();
    assert_ne!(Pairing::parse(&next).unwrap().device_id, q.device_id);
    h.stop();
    let _ = std::fs::remove_dir_all(dir);
}

use blurt_remote::pairing::Pairing;

/// Copy Link: that link keeps working while the code on screen moves on (two renewals later it's neither the code shown nor the one
/// before), and it's spent like any code. A link that wasn't copied is gone by then.
#[tokio::test(flavor = "multi_thread")]
async fn a_copied_link_outlives_the_codes_on_screen() {
    let dir = std::env::temp_dir().join(format!("blurt-remote-test-{}", blurt_remote::crypto::new_id()));
    let h = host_answering(&dir, Lines::default(), Lines::default(), None);
    h.show_pairing(true);
    let (copied, port) = until(|| h.status().pairing.map(|p| (p.url, h.status().port))).await;
    h.pairing_link_copied();
    h.show_pairing(true);
    let shown_next = until(|| h.status().pairing.map(|p| p.url).filter(|u| *u != copied)).await;
    h.show_pairing(true);
    until(|| h.status().pairing.map(|p| p.url).filter(|u| *u != shown_next && *u != copied)).await;
    let at: SocketAddr = format!("127.0.0.1:{port}").parse().unwrap();

    // not copied, two codes ago: refused
    let gone = Pairing::parse(&shown_next).unwrap();
    h.show_pairing(true);
    tokio::time::sleep(Duration::from_millis(100)).await;
    assert_eq!(Phone::connect(at, &gone.device_id, &gone.key).await.err().as_deref(), Some("NotPaired"));

    // copied: it asks
    let p = Pairing::parse(&copied).unwrap();
    let mut phone = Phone::connect(at, &p.device_id, &p.key).await.unwrap();
    phone.wait(Duration::from_secs(3), |m| matches!(m, ToPhone::PairingWaits).then_some(())).await.expect("asks");
    h.answer_pairing(false, None);
    tokio::time::sleep(Duration::from_millis(200)).await;
    // spent: it opens nothing again
    assert_eq!(Phone::connect(at, &p.device_id, &p.key).await.err().as_deref(), Some("NotPaired"));
    h.stop();
    let _ = std::fs::remove_dir_all(dir);
}

/// The app's Phone capability off: nothing listens, a code can't be shown, and on again it listens as before.
#[tokio::test(flavor = "multi_thread")]
async fn off_means_not_listening() {
    let dir = std::env::temp_dir().join(format!("blurt-remote-test-{}", blurt_remote::crypto::new_id()));
    let h = host(&dir, Lines::default(), Lines::default());
    h.show_pairing(true);
    until(|| h.status().pairing.map(|_| ())).await;
    assert!(h.status().listening);
    h.set_off(true);
    assert!(!h.status().listening && h.status().pairing.is_none());
    h.show_pairing(true);
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert!(!h.status().listening && h.status().pairing.is_none(), "no code while off");
    h.set_off(false);
    h.show_pairing(true);
    until(|| h.status().pairing.map(|_| ())).await;
    assert!(h.status().listening);
    h.stop();
    let _ = std::fs::remove_dir_all(&dir);
}

/// Whether a paired device is a phone or a computer (its hello lists `viewer`): known while it asks, kept on its record, read back
/// after a restart. The UI draws its icon from this.
#[tokio::test(flavor = "multi_thread")]
async fn a_device_is_a_phone_or_a_computer() {
    use blurt_remote::phone::Options;
    use blurt_remote::store::DeviceKind;
    let dir = std::env::temp_dir().join(format!("blurt-remote-test-{}", blurt_remote::crypto::new_id()));
    let h = host_answering(&dir, Lines::default(), Lines::default(), None);
    let mut port = 0;
    let mut pair_as = async |opts: Options| {
        h.show_pairing(true);
        let (link, p) = until(|| h.status().pairing.map(|p| (p.url, h.status().port))).await;
        port = p;
        let at: SocketAddr = format!("127.0.0.1:{p}").parse().unwrap();
        let code = Pairing::parse(&link).unwrap();
        let mut d = Phone::connect_with(at, &code.device_id, &code.key, opts).await.unwrap();
        d.wait(Duration::from_secs(3), |m| matches!(m, ToPhone::PairingWaits).then_some(())).await.expect("asks");
        let asking = until(|| h.status().asking).await;
        h.answer_pairing(true, Some(&asking.digits));
        d.wait(Duration::from_secs(3), |m| matches!(m, ToPhone::NewKey(_)).then_some(())).await.expect("a key");
        d.send(&ToMac::KeyStored).await;
        d.wait(Duration::from_secs(3), |m| matches!(m, ToPhone::Session(_)).then_some(())).await.expect("session");
        (asking.kind, d)
    };
    let viewer = Options {
        features: Some(vec![blurt_remote::wire::MOVE.into(), blurt_remote::wire::VIEWER.into()]),
        device: "Den PC".into(),
        ..Options::default()
    };
    let (asked, _pc) = pair_as(viewer).await;
    assert_eq!(asked, DeviceKind::Computer, "a viewer asks as a computer");
    let (asked, _phone) = pair_as(Options::default()).await;
    assert_eq!(asked, DeviceKind::Phone);
    assert!(port > 0);
    let kinds = |h: &Host| h.status().devices.iter().map(|d| (d.name.clone(), d.kind)).collect::<Vec<_>>();
    assert_eq!(kinds(&h), [("Den PC".to_string(), DeviceKind::Computer), ("Test Phone".to_string(), DeviceKind::Phone)]);
    h.stop();
    // kept: a host started again over the same folder knows which is which
    let again = host(&dir, Lines::default(), Lines::default());
    assert_eq!(kinds(&again), [("Den PC".to_string(), DeviceKind::Computer), ("Test Phone".to_string(), DeviceKind::Phone)]);
    again.stop();
    // a host owns its runtime: let it go off the test's async thread
    tokio::task::spawn_blocking(move || drop((h, again))).await.unwrap();
    let _ = std::fs::remove_dir_all(&dir);
}

/// Anti-scam (remote-1.1.md §3): a device paired while another was away is said to that one when it next comes in.
#[tokio::test(flavor = "multi_thread")]
async fn a_new_pairing_is_said_to_the_devices_already_paired() {
    use blurt_remote::phone::Options;
    let dir = std::env::temp_dir().join(format!("blurt-remote-test-{}", blurt_remote::crypto::new_id()));
    let h = host_answering(&dir, Lines::default(), Lines::default(), None);
    let pair_as = async |opts: Options| {
        h.show_pairing(true);
        let (link, p) = until(|| h.status().pairing.map(|p| (p.url, h.status().port))).await;
        let at: SocketAddr = format!("127.0.0.1:{p}").parse().unwrap();
        let code = Pairing::parse(&link).unwrap();
        let mut d = Phone::connect_with(at, &code.device_id, &code.key, opts).await.unwrap();
        d.wait(Duration::from_secs(3), |m| matches!(m, ToPhone::PairingWaits).then_some(())).await.expect("asks");
        let asking = until(|| h.status().asking).await;
        h.answer_pairing(true, Some(&asking.digits));
        let key = d.wait(Duration::from_secs(3), |m| if let ToPhone::NewKey(k) = m { Some(k.clone()) } else { None }).await.expect("a key");
        d.send(&ToMac::KeyStored).await;
        d.wait(Duration::from_secs(3), |m| matches!(m, ToPhone::Session(_)).then_some(())).await.expect("session");
        (at, code.device_id, key, d)
    };
    let mine = Options { device: "Den PC".into(), ..Options::default() };
    let (at, id, key, pc) = pair_as(mine.clone()).await;
    drop(pc);
    until(|| h.status().connected.is_none().then_some(())).await;
    tokio::time::sleep(Duration::from_millis(20)).await;
    let (_, _, _, phone) = pair_as(Options { device: "Stranger".into(), ..Options::default() }).await;
    drop(phone);
    until(|| h.status().connected.is_none().then_some(())).await;
    let mut pc = Phone::connect_with(at, &id, &key, mine).await.unwrap();
    // after the session, where a device listens from (one that waits for Session first used to drop it)
    pc.wait(Duration::from_secs(3), |m| matches!(m, ToPhone::Session(_)).then_some(())).await.expect("session");
    let said = pc.wait(Duration::from_secs(3), |m| if let ToPhone::Notice(t) = m { Some(t.clone()) } else { None }).await;
    assert!(said.as_deref().is_some_and(|t| t.contains("Stranger")), "{said:?}");
    // said once: the next time it comes in, nothing
    drop(pc);
    until(|| h.status().connected.is_none().then_some(())).await;
    let mut pc = Phone::connect_with(at, &id, &key, Options { device: "Den PC".into(), ..Options::default() }).await.unwrap();
    let again = pc.wait(Duration::from_secs(1), |m| if let ToPhone::Notice(t) = m { Some(t.clone()) } else { None }).await;
    assert_eq!(again, None);
    drop(pc);
    h.stop();
    tokio::task::spawn_blocking(move || drop(h)).await.unwrap();
    let _ = std::fs::remove_dir_all(&dir);
}

/// Anti-scam (remote-1.1.md §3): a device paired while another is in use is said to that one at once, before it gives way (it used to
/// hear only Replaced), and not again when it next comes in. A device that was away hears of it after its session, where it listens.
#[tokio::test(flavor = "multi_thread")]
async fn a_new_pairing_is_said_to_the_device_in_use() {
    use blurt_remote::phone::{Event, Options};
    let dir = std::env::temp_dir().join(format!("blurt-remote-test-{}", blurt_remote::crypto::new_id()));
    let h = host_answering(&dir, Lines::default(), Lines::default(), None);
    let pair_as = async |opts: Options| {
        h.show_pairing(true);
        let (link, p) = until(|| h.status().pairing.map(|p| (p.url, h.status().port))).await;
        let at: SocketAddr = format!("127.0.0.1:{p}").parse().unwrap();
        let code = Pairing::parse(&link).unwrap();
        let mut d = Phone::connect_with(at, &code.device_id, &code.key, opts).await.unwrap();
        d.wait(Duration::from_secs(3), |m| matches!(m, ToPhone::PairingWaits).then_some(())).await.expect("asks");
        let asking = until(|| h.status().asking).await;
        h.answer_pairing(true, Some(&asking.digits));
        let key = d.wait(Duration::from_secs(3), |m| if let ToPhone::NewKey(k) = m { Some(k.clone()) } else { None }).await.expect("a key");
        d.send(&ToMac::KeyStored).await;
        d.wait(Duration::from_secs(3), |m| matches!(m, ToPhone::Session(_)).then_some(())).await.expect("session");
        (at, code.device_id, key, d)
    };
    let mine = Options { device: "Den PC".into(), ..Options::default() };
    let (at, id, key, mut pc) = pair_as(mine.clone()).await;
    let (_, _, _, phone) = pair_as(Options { device: "Stranger".into(), ..Options::default() }).await;
    // what the device in use heard, in order, until it was let go
    let mut heard = vec![];
    while let Some(e) = pc.next(Duration::from_secs(2)).await {
        match e {
            Event::Control(ToPhone::Notice(t)) => heard.push(format!("notice {t}")),
            Event::Control(ToPhone::Replaced) => heard.push("replaced".into()),
            Event::Closed => break,
            _ => {}
        }
    }
    assert_eq!(heard.len(), 2, "{heard:?}");
    assert!(heard[0].starts_with("notice") && heard[0].contains("Stranger"), "{heard:?}");
    assert_eq!(heard[1], "replaced");
    drop(phone);
    until(|| h.status().connected.is_none().then_some(())).await;
    // said once: coming in again, nothing
    let mut pc = Phone::connect_with(at, &id, &key, mine).await.unwrap();
    let again = pc.wait(Duration::from_secs(1), |m| if let ToPhone::Notice(t) = m { Some(t.clone()) } else { None }).await;
    assert_eq!(again, None);
    drop(pc);
    h.stop();
    tokio::task::spawn_blocking(move || drop(h)).await.unwrap();
    let _ = std::fs::remove_dir_all(&dir);
}
