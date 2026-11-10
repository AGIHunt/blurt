//! The phone's numbered pointer instructions through the real server and the Rust test phone (docs/design/remote-protocol.md):
//! a phone that sends no numbers keeps getting the 8-byte cursor, one that numbers its moves gets 12 bytes with the newest number
//! the place includes, a move that doesn't move the pointer still gets its number, a `pointerTo` counts with no picture up, and a
//! new session forgets.

use std::net::SocketAddr;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use blurt_remote::host::{Backend, Button, Crop, CursorShape, FrameSink, Input, Screen, ScreenConfig, ScreenInfo, ScrollPhase, SystemMove};
use blurt_remote::input::REPORT_LAG;
use blurt_remote::packets::PointerPacket;
use blurt_remote::phone::{pair, Event, Phone};
use blurt_remote::store::FileKeyStore;
use blurt_remote::wire::{ScreenRequest, ToMac, ToPhone};
use blurt_remote::{App, Host, HostConfig};

/// A pointer that stays where it is whatever moves it, as one held against the screen's edge, unless it's placed.
#[derive(Clone)]
struct World {
    pointer: Arc<Mutex<(f64, f64)>>,
    log: Arc<Mutex<Vec<String>>>,
}

struct In(World);

impl Input for In {
    fn can_control(&self) -> bool {
        true
    }
    fn key(&mut self, _: &str, _: u8, _: Option<bool>) {}
    fn set_held(&mut self, _: u8) {}
    fn text(&mut self, _: &str) {}
    fn button(&mut self, _: Button, _: bool, _: u32) {}
    fn move_by(&mut self, dx: f64, dy: f64) {
        self.0.log.lock().unwrap().push(format!("move {dx} {dy}"));
    }
    fn move_to(&mut self, x: f64, y: f64) {
        self.0.log.lock().unwrap().push(format!("to {x} {y}"));
        *self.0.pointer.lock().unwrap() = (x, y);
    }
    fn scroll(&mut self, _: f64, _: f64, _: ScrollPhase) {}
    fn system(&mut self, _: SystemMove) {}
    fn release_all(&mut self) {}
    fn pointer(&self) -> Option<(f64, f64)> {
        Some(*self.0.pointer.lock().unwrap())
    }
    fn cursor_shape(&mut self) -> Option<CursorShape> {
        None
    }
}

struct Scr;

impl Screen for Scr {
    fn start(&mut self, _: &ScreenConfig, _: FrameSink) -> Result<ScreenInfo, String> {
        Ok(ScreenInfo { width: 1600.0, height: 1000.0, codec: "h264".into() })
    }
    fn set_crop(&mut self, _: Crop) {}
    fn set_rate(&mut self, _: u32, _: u32) {}
    fn keyframe(&mut self) {}
    fn refresh(&mut self) {}
    fn stop(&mut self) {}
}

struct Back(In, Scr);

impl Backend for Back {
    fn input(&mut self) -> &mut dyn Input {
        &mut self.0
    }
    fn screen(&mut self) -> Option<&mut dyn Screen> {
        Some(&mut self.1)
    }
    fn platform(&self) -> &'static str {
        "windows"
    }
    fn display_aspect(&self) -> f64 {
        1.6
    }
    fn now(&self) -> f64 {
        0.0
    }
    fn keep_awake(&mut self, _: bool, _: bool) {}
}

struct NoApp;
impl App for NoApp {}

fn screen() -> ToMac {
    ToMac::Screen(Some(ScreenRequest {
        target: "display".into(),
        crop: blurt_remote::wire::Crop::WHOLE,
        width: 1600,
        height: 1000,
        bitrate: 4_000_000,
        fps: 30,
        codecs: Some(vec!["h264".into()]),
        display: None,
        features: None,
    }))
}

/// The next cursor place within `t`: x, y and the number it came with.
async fn cursor(phone: &mut Phone, t: Duration) -> Option<(f32, f32, Option<u32>)> {
    let end = Instant::now() + t;
    loop {
        match phone.next(end.saturating_duration_since(Instant::now())).await? {
            Event::Cursor(x, y, seq) => return Some((x, y, seq)),
            Event::Closed => return None,
            _ => {}
        }
    }
}

/// Every cursor place for `t`.
async fn cursors(phone: &mut Phone, t: Duration) -> Vec<(f32, f32, Option<u32>)> {
    let end = Instant::now() + t;
    let mut all = vec![];
    while let Some(c) = cursor(phone, end.saturating_duration_since(Instant::now())).await {
        all.push(c);
    }
    all
}

/// UDP up (the cursor is a datagram), the picture asked for, and the first place: it goes at once.
async fn watch(phone: &mut Phone, info: &blurt_remote::wire::SessionInfo) -> (f32, f32, Option<u32>) {
    phone.open_udp(info.udp_port, info.udp_session).await.unwrap();
    phone.wait(Duration::from_secs(3), |m| matches!(m, ToPhone::UdpOk).then_some(())).await.expect("udpOK");
    phone.send(&screen()).await;
    phone.wait(Duration::from_secs(3), |m| matches!(m, ToPhone::ScreenView { .. }).then_some(())).await.expect("the picture");
    cursor(phone, Duration::from_secs(2)).await.expect("where the pointer is")
}

#[tokio::test(flavor = "multi_thread")]
async fn the_cursor_carries_the_phones_number_once_it_sends_one() {
    let dir = std::env::temp_dir().join(format!("blurt-remote-numbers-{}", blurt_remote::crypto::new_id()));
    let w = World { pointer: Arc::new(Mutex::new((0.25, 0.5))), log: Arc::default() };
    let h = Host::start(
        HostConfig { dir: dir.clone(), name: "Numbers".into(), version: "1.0.17".into(), test_answer: Some(true), port: 0 },
        Box::new(Back(In(w.clone()), Scr)),
        Box::new(FileKeyStore::new(dir.join("keys.json"))),
        Box::new(NoApp),
    );
    h.show_pairing(true);
    let (link, port) = loop {
        let s = h.status();
        if let Some(p) = s.pairing {
            break (p.url, s.port);
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    };
    let at: SocketAddr = format!("127.0.0.1:{port}").parse().unwrap();
    let (mut phone, device, key, info) = pair(&link, at).await.expect("paired");

    // a phone that numbers nothing (before 1.0.17): 8 bytes, moves or not
    assert_eq!(watch(&mut phone, &info).await, (0.25, 0.5, None));
    phone.pointer(PointerPacket::Move { dx: 3.0, dy: 0.0, seq: None }).await;
    let plain = cursors(&mut phone, Duration::from_millis(700)).await;
    assert!(!plain.is_empty(), "it goes twice a second regardless");
    assert!(plain.iter().all(|c| *c == (0.25, 0.5, None)), "{plain:?}");

    // a numbered move that moves nothing (this pointer stays put, as against the screen's edge): its number still comes, on its
    // own and not with the next regular place, which is half a second after the one just seen; and not before the OS has had time
    // to report the move
    cursor(&mut phone, Duration::from_secs(2)).await.expect("a regular one");
    let sent = Instant::now();
    phone.pointer(PointerPacket::Move { dx: 3.0, dy: 0.0, seq: Some(1) }).await;
    assert_eq!(cursor(&mut phone, Duration::from_secs(2)).await, Some((0.25, 0.5, Some(1))), "12 bytes, with the number");
    assert!(sent.elapsed() >= REPORT_LAG, "{:?}", sent.elapsed());
    assert!(sent.elapsed() < Duration::from_millis(400), "the number changed, so it went: {:?}", sent.elapsed());

    // from then on every place carries the newest number: the regular ones, and after more moves the last of them
    for n in 2..=6 {
        phone.pointer(PointerPacket::Move { dx: 1.0, dy: 1.0, seq: Some(n) }).await;
    }
    let after = cursors(&mut phone, Duration::from_millis(900)).await;
    assert!(after.iter().all(|c| c.2.is_some()), "{after:?}");
    assert_eq!(after.last().unwrap().2, Some(6));
    assert!(after.iter().filter(|c| c.2 == Some(6)).count() >= 2, "and again with the regular ones: {after:?}");

    // pointerTo shares the count: the pointer goes there, and the place says so
    phone.send(&ToMac::PointerTo { x: 0.75, y: 0.125, seq: Some(7) }).await;
    let placed = cursors(&mut phone, Duration::from_millis(400)).await;
    assert_eq!(placed.last(), Some(&(0.75, 0.125, Some(7))), "{placed:?}");
    assert!(w.log.lock().unwrap().iter().any(|l| l == "to 0.75 0.125"));
    assert!(!placed.contains(&(0.25, 0.5, Some(7))), "never the number with the place before it: {placed:?}");

    // with no picture up there's nowhere to place it, and its number counts all the same
    phone.send(&ToMac::Screen(None)).await;
    phone.send(&ToMac::PointerTo { x: 0.1, y: 0.1, seq: Some(8) }).await;
    tokio::time::sleep(REPORT_LAG + Duration::from_millis(100)).await;
    while phone.next(Duration::from_millis(50)).await.is_some() {}
    phone.send(&screen()).await;
    assert_eq!(cursor(&mut phone, Duration::from_secs(2)).await, Some((0.75, 0.125, Some(8))), "not placed, but made");

    // a new session forgets: the same phone again (or another one) gets 8 bytes until it sends a number of its own
    let mut again = Phone::connect(at, &device, &key).await.expect("the kept key");
    let info2 = again.wait(Duration::from_secs(3), |m| if let ToPhone::Session(i) = m { Some(i.clone()) } else { None }).await.expect("a session");
    assert_eq!(watch(&mut again, &info2).await, (0.75, 0.125, None));
    again.pointer(PointerPacket::Move { dx: 3.0, dy: 0.0, seq: None }).await;
    let fresh = cursors(&mut again, Duration::from_millis(700)).await;
    assert!(!fresh.is_empty() && fresh.iter().all(|c| c.2.is_none()), "{fresh:?}");
    again.pointer(PointerPacket::Move { dx: 3.0, dy: 0.0, seq: Some(1) }).await;
    let numbered = cursors(&mut again, Duration::from_millis(600)).await;
    assert_eq!(numbered.last().map(|c| c.2), Some(Some(1)), "its own count, from 1: {numbered:?}");

    h.stop();
    let _ = std::fs::remove_dir_all(dir);
}
