//! Several displays through the real server and the Rust test phone: the list at session start and when it changes, the picture
//! following the pointer with hysteresis (150 ms on another display, or 20 pt into it), a pinned display (with the pointer in its
//! middle), unpinning, a pinned display that goes away, and the phone leaving.

use std::net::SocketAddr;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use blurt_remote::host::{
    Backend, Button, Crop, CursorShape, DisplayInfo, FrameSink, Input, Screen, ScreenConfig, ScreenInfo, ScrollPhase, SystemMove,
};
use blurt_remote::phone::pair;
use blurt_remote::store::FileKeyStore;
use blurt_remote::wire::{ScreenRequest, ToMac, ToPhone};
use blurt_remote::{App, Host, HostConfig};

#[derive(Clone, Default)]
struct World {
    log: Arc<Mutex<Vec<String>>>,
    displays: Arc<Mutex<Vec<DisplayInfo>>>,
    pointer: Arc<Mutex<(f64, f64)>>,
}

impl World {
    fn push(&self, s: String) {
        self.log.lock().unwrap().push(s);
    }
    fn has(&self, s: &str) -> bool {
        self.log.lock().unwrap().iter().any(|l| l == s)
    }
    fn at(&self, x: f64, y: f64) {
        *self.pointer.lock().unwrap() = (x, y);
    }
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
    fn move_by(&mut self, _: f64, _: f64) {}
    fn move_to(&mut self, x: f64, y: f64) {
        self.0.push(format!("to {x} {y}"));
    }
    fn scroll(&mut self, _: f64, _: f64, _: ScrollPhase) {}
    fn system(&mut self, _: SystemMove) {}
    fn release_all(&mut self) {}
    fn pointer(&self) -> Option<(f64, f64)> {
        None
    }
    fn cursor_shape(&mut self) -> Option<CursorShape> {
        None
    }
    fn pointer_desktop(&self) -> Option<(f64, f64)> {
        Some(*self.0.pointer.lock().unwrap())
    }
}

struct Scr(World);

impl Screen for Scr {
    fn start(&mut self, c: &ScreenConfig, _: FrameSink) -> Result<ScreenInfo, String> {
        self.0.push(format!("start {} {}x{}", c.display.as_deref().unwrap_or("-"), c.width, c.height));
        let d = self.0.displays.lock().unwrap().iter().find(|d| Some(&d.id) == c.display.as_ref()).cloned().ok_or("no such display")?;
        Ok(ScreenInfo { width: d.width, height: d.height, codec: "h264".into() })
    }
    fn set_crop(&mut self, _: Crop) {}
    fn set_rate(&mut self, _: u32, _: u32) {}
    fn keyframe(&mut self) {}
    fn refresh(&mut self) {}
    fn stop(&mut self) {
        self.0.push("stop".into());
    }
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
    fn displays(&self) -> Vec<DisplayInfo> {
        self.0 .0.displays.lock().unwrap().clone()
    }
}

struct NoApp;
impl App for NoApp {}

fn two() -> Vec<DisplayInfo> {
    vec![
        DisplayInfo { id: "A".into(), name: "Built-in".into(), x: 0.0, y: 0.0, width: 1512.0, height: 982.0, main: true },
        DisplayInfo { id: "B".into(), name: "DELL U2723QE".into(), x: 1512.0, y: -458.0, width: 2560.0, height: 1440.0, main: false },
    ]
}

async fn view(phone: &mut blurt_remote::phone::Phone, t: Duration) -> Option<(Option<String>, f64)> {
    phone.wait(t, |m| if let ToPhone::ScreenView { display, width, .. } = m { Some((display.clone(), *width)) } else { None }).await
}

#[tokio::test(flavor = "multi_thread")]
async fn follow_pin_unpin_and_a_display_going() {
    let dir = std::env::temp_dir().join(format!("blurt-remote-displays-{}", blurt_remote::crypto::new_id()));
    let w = World::default();
    *w.displays.lock().unwrap() = two();
    w.at(100.0, 100.0);
    let h = Host::start(
        HostConfig { dir: dir.clone(), name: "Two Screens".into(), version: "1.0.15".into(), test_answer: Some(true), port: 0 },
        Box::new(Back(In(w.clone()), Scr(w.clone()))),
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
    let (mut phone, ..) = pair(&link, at).await.expect("paired");
    let list = phone.wait(Duration::from_secs(3), |m| if let ToPhone::Displays(l) = m { Some(l.clone()) } else { None }).await.expect("the displays");
    assert_eq!(list.iter().map(|d| (d.id.as_str(), d.main)).collect::<Vec<_>>(), [("A", true), ("B", false)]);
    assert_eq!(list[1].y, -458.0);

    // follow: the display under the pointer, in its own shape
    phone
        .send(&ToMac::Screen(Some(ScreenRequest {
            target: "display".into(),
            crop: blurt_remote::wire::Crop::WHOLE,
            width: 1600,
            height: 1000,
            bitrate: 4_000_000,
            fps: 30,
            codecs: Some(vec!["h264".into()]),
            display: None,
        })))
        .await;
    assert_eq!(view(&mut phone, Duration::from_secs(3)).await, Some((Some("A".into()), 1512.0)));
    assert!(w.has("start A 1538x1000"), "{:?}", w.log.lock().unwrap());

    // 5 pt into B: not at once; after 150 ms there, yes
    w.at(1517.0, 300.0);
    let t0 = Instant::now();
    assert_eq!(view(&mut phone, Duration::from_millis(100)).await, None, "a graze doesn't flip the picture");
    assert_eq!(view(&mut phone, Duration::from_secs(2)).await, Some((Some("B".into()), 2560.0)));
    assert!(t0.elapsed() >= Duration::from_millis(150));
    assert!(w.has("start B 1600x900"), "a new stream in B's shape: {:?}", w.log.lock().unwrap());

    // 25 pt into A: straight away
    w.at(1487.0, 300.0);
    let t1 = Instant::now();
    assert_eq!(view(&mut phone, Duration::from_secs(2)).await, Some((Some("A".into()), 1512.0)));
    assert!(t1.elapsed() < Duration::from_millis(140), "pushed in deep: no waiting ({:?})", t1.elapsed());

    // pinned: B, with the pointer in its middle; the pointer staying on A doesn't move the picture
    w.log.lock().unwrap().clear();
    phone.send(&ToMac::ShowDisplay(Some("B".into()))).await;
    assert_eq!(view(&mut phone, Duration::from_secs(2)).await, Some((Some("B".into()), 2560.0)));
    tokio::time::sleep(Duration::from_millis(100)).await;
    assert!(w.has("to 0.5 0.5"), "{:?}", w.log.lock().unwrap());
    assert_eq!(view(&mut phone, Duration::from_millis(500)).await, None, "pinned");

    // follow again: back to A, where the pointer is
    phone.send(&ToMac::ShowDisplay(None)).await;
    assert_eq!(view(&mut phone, Duration::from_secs(2)).await, Some((Some("A".into()), 1512.0)));

    // pinned to B, and B is unplugged: the list again, and following on A
    phone.send(&ToMac::ShowDisplay(Some("B".into()))).await;
    assert_eq!(view(&mut phone, Duration::from_secs(2)).await, Some((Some("B".into()), 2560.0)));
    w.displays.lock().unwrap().truncate(1);
    let list = phone.wait(Duration::from_secs(4), |m| if let ToPhone::Displays(l) = m { Some(l.clone()) } else { None }).await.expect("the new list");
    assert_eq!(list.len(), 1);
    assert_eq!(view(&mut phone, Duration::from_secs(2)).await, Some((Some("A".into()), 1512.0)));
    // and it follows again (B back, the pointer on it)
    *w.displays.lock().unwrap() = two();
    phone.wait(Duration::from_secs(4), |m| matches!(m, ToPhone::Displays(_)).then_some(())).await.expect("B is back");
    w.at(2000.0, 100.0);
    assert_eq!(view(&mut phone, Duration::from_secs(2)).await, Some((Some("B".into()), 2560.0)));

    // the phone leaves: the stream stops
    w.log.lock().unwrap().clear();
    drop(phone);
    for _ in 0..100 {
        if w.has("stop") {
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    assert!(w.has("stop"));
    h.stop();
    let _ = std::fs::remove_dir_all(dir);
}
