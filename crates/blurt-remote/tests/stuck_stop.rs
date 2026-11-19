//! A picture whose stop hangs (a capture or encoder thread that won't finish) must not keep a phone out. Through the real server and
//! the Rust test phone: the picture on, the same phone connecting again (it gave up on a frozen picture, which takes the session over
//! and stops the old picture), the backend's stop held. The new connection still opens; the new picture waits for the old stop and
//! starts once it's done, never before (one backend, one screen: a late stop mustn't end the new one).

use std::net::SocketAddr;
use std::sync::{Arc, Condvar, Mutex};
use std::time::Duration;

use blurt_remote::host::{
    Backend, Button, Crop, CursorShape, DisplayInfo, FrameSink, Input, Screen, ScreenConfig, ScreenInfo, ScrollPhase, SystemMove,
};
use blurt_remote::phone::{pair, Phone};
use blurt_remote::store::FileKeyStore;
use blurt_remote::wire::{ScreenRequest, ToMac, ToPhone};
use blurt_remote::{App, Host, HostConfig};

#[derive(Clone, Default)]
struct World {
    log: Arc<Mutex<Vec<String>>>,
    /// true: the screen's stop may finish
    release: Arc<(Mutex<bool>, Condvar)>,
}

impl World {
    fn push(&self, s: &str) {
        self.log.lock().unwrap().push(s.into());
    }
    fn log(&self) -> Vec<String> {
        self.log.lock().unwrap().clone()
    }
    fn let_stop_finish(&self) {
        let (m, cv) = &*self.release;
        *m.lock().unwrap() = true;
        cv.notify_all();
    }
}

struct In;

impl Input for In {
    fn can_control(&self) -> bool {
        true
    }
    fn key(&mut self, _: &str, _: u8, _: Option<bool>) {}
    fn set_held(&mut self, _: u8) {}
    fn text(&mut self, _: &str) {}
    fn button(&mut self, _: Button, _: bool, _: u32) {}
    fn move_by(&mut self, _: f64, _: f64) {}
    fn move_to(&mut self, _: f64, _: f64) {}
    fn scroll(&mut self, _: f64, _: f64, _: ScrollPhase) {}
    fn system(&mut self, _: SystemMove) {}
    fn release_all(&mut self) {}
    fn pointer(&self) -> Option<(f64, f64)> {
        None
    }
    fn cursor_shape(&mut self) -> Option<CursorShape> {
        None
    }
}

struct Scr(World);

impl Screen for Scr {
    fn start(&mut self, _: &ScreenConfig, _: FrameSink) -> Result<ScreenInfo, String> {
        self.0.push("start");
        Ok(ScreenInfo { width: 1600.0, height: 1000.0, codec: "h264".into() })
    }
    fn set_crop(&mut self, _: Crop) {}
    fn set_rate(&mut self, _: u32, _: u32) {}
    fn keyframe(&mut self) {}
    fn refresh(&mut self) {}
    fn stop(&mut self) {
        if let Some(wait) = self.begin_stop() {
            wait();
        }
    }
    /// The wait hangs until the test lets it go (at most 20 s, so a broken run still ends), like a capture thread that won't join.
    fn begin_stop(&mut self) -> Option<Box<dyn FnOnce() + Send>> {
        self.0.push("stop begins");
        let w = self.0.clone();
        Some(Box::new(move || {
            let (m, cv) = &*w.release;
            let g = m.lock().unwrap();
            drop(cv.wait_timeout_while(g, Duration::from_secs(20), |go| !*go).unwrap());
            w.push("stop done");
        }))
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
        Vec::new()
    }
}

struct NoApp;
impl App for NoApp {}

fn ask() -> ToMac {
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
        window: None,
    }))
}

async fn view(phone: &mut Phone, t: Duration) -> bool {
    phone.wait(t, |m| matches!(m, ToPhone::ScreenView { .. }).then_some(())).await.is_some()
}

#[tokio::test(flavor = "multi_thread")]
async fn a_stop_that_hangs_keeps_no_phone_out() {
    let dir = std::env::temp_dir().join(format!("blurt-remote-stuck-stop-{}", blurt_remote::crypto::new_id()));
    let w = World::default();
    let h = Host::start(
        HostConfig { dir: dir.clone(), name: "Stuck".into(), version: "1.0.21".into(), test_answer: Some(true), port: 0, go_between: Some(String::new()) },
        Box::new(Back(In, Scr(w.clone()))),
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
    let (mut first, id, key, _) = pair(&link, at).await.expect("paired");
    first.send(&ask()).await;
    assert!(view(&mut first, Duration::from_secs(3)).await, "the picture: {:?}", w.log());

    // the same phone again, the old session still open: it takes over, and the old picture's stop hangs
    let mut second = tokio::time::timeout(Duration::from_secs(3), Phone::connect(at, &id, &key))
        .await
        .expect("a hanging stop kept the phone out")
        .expect("connected");
    for _ in 0..100 {
        if w.log().iter().any(|l| l == "stop begins") {
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    assert!(w.log().iter().any(|l| l == "stop begins"), "{:?}", w.log());

    // the server still answers: the new session asks for a picture, which waits for the old stop
    second.send(&ToMac::Ping(1.0)).await;
    assert!(second.wait(Duration::from_secs(2), |m| matches!(m, ToPhone::Pong(_)).then_some(())).await.is_some(), "the server is held up");
    second.send(&ask()).await;
    assert!(!view(&mut second, Duration::from_millis(500)).await, "a new picture before the old one stopped: {:?}", w.log());
    assert_eq!(w.log().iter().filter(|l| *l == "start").count(), 1, "{:?}", w.log());

    // the old stop finishes: then, and only then, the new picture
    w.let_stop_finish();
    assert!(view(&mut second, Duration::from_secs(3)).await, "{:?}", w.log());
    let log = w.log();
    let done = log.iter().position(|l| l == "stop done").expect("stopped");
    let again = log.iter().rposition(|l| l == "start").unwrap();
    assert!(done < again, "the new picture started before the old one had stopped: {log:?}");

    drop(first);
    drop(second);
    h.stop();
    let _ = std::fs::remove_dir_all(dir);
}
