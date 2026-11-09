//! The picture's repairs end to end (docs/design/remote-realtime.md): the real server on loopback, a synthetic 60 fps screen that
//! sizes its frames by the bitrate it's given (a scroll at 12 Mbps: 25 KB a frame, 22 pieces; a keyframe six times that), and the Rust
//! test phone watching it through a made-up network (`phone::Weather`, as the iOS app's TestWeather), measured as the doc measures:
//! frames shown a second, the longest gap between two new pictures, frames given up, keyframes asked, what was repaired, the rate.
//!
//! Each stage runs 1 s of warm-up and BLURT_REALTIME_SECONDS (default 4) measured; `cargo test --test realtime -- --nocapture` prints
//! the table. The synthetic encoder makes recovery frames the way an LTR encoder does: every 4th frame a reference, and after a loss a
//! small frame from an acknowledged one (a keyframe if none is).

use std::net::SocketAddr;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use blurt_remote::host::{
    Backend, Button, Crop, CursorShape, EncodedFrame, FrameSink, Input, Screen, ScreenConfig, ScreenInfo, ScrollPhase, SystemMove,
};
use blurt_remote::packets::unpack_payload;
use blurt_remote::phone::{pair, Measure, Watch, Weather};
use blurt_remote::repair::ALL;
use blurt_remote::store::FileKeyStore;
use blurt_remote::wire::ScreenRequest;
use blurt_remote::{App, Host, HostConfig};

fn now() -> f64 {
    static T: OnceLock<Instant> = OnceLock::new();
    T.get_or_init(Instant::now).elapsed().as_secs_f64()
}

/// The synthetic picture: its number, then bytes that follow from it, so a piece sent again or rebuilt wrong shows.
fn picture(seq: u32, len: usize) -> Vec<u8> {
    let mut v = seq.to_be_bytes().to_vec();
    v.extend((4..len.max(4)).map(|i| (seq as usize).wrapping_mul(31).wrapping_add(i * 7) as u8));
    v
}

fn verify(data: &[u8]) -> bool {
    let Some(p) = unpack_payload(data) else { return false };
    if p.picture.len() < 4 {
        return false;
    }
    let seq = u32::from_be_bytes(p.picture[..4].try_into().unwrap());
    p.picture == picture(seq, p.picture.len())
}

#[derive(Default)]
struct SynthSt {
    gen: u64,
    want_key: bool,
    want_recovery: bool,
    acked: Vec<u64>,
    bitrate: u32,
    fps: u32,
    repairs: bool,
    keyframes: usize,
    recoveries: usize,
    recovery_keyframes: usize,
}

/// A 60 Hz scroll, encoded by a make-believe LTR encoder.
#[derive(Clone)]
struct Synth {
    st: Arc<Mutex<SynthSt>>,
    recovery: bool,
}

impl Screen for Synth {
    fn start(&mut self, c: &ScreenConfig, sink: FrameSink) -> Result<ScreenInfo, String> {
        let gen = {
            let mut s = self.st.lock().unwrap();
            s.gen += 1;
            s.want_key = true;
            s.acked.clear();
            s.bitrate = c.bitrate;
            s.fps = c.fps;
            s.repairs = c.repairs;
            s.gen
        };
        let st = self.st.clone();
        std::thread::spawn(move || {
            let mut seq = 0u32;
            let t0 = Instant::now();
            loop {
                seq += 1;
                // the app draws at 60 Hz whatever is asked
                let due = t0 + Duration::from_secs_f64(seq as f64 / 60.0);
                if let Some(d) = due.checked_duration_since(Instant::now()) {
                    std::thread::sleep(d);
                }
                let f = {
                    let mut s = st.lock().unwrap();
                    if s.gen != gen {
                        return;
                    }
                    let per = (s.bitrate as usize / 8 / s.fps.clamp(1, 60) as usize).max(1000);
                    let periodic = !s.repairs && seq % 600 == 0;
                    let (mut key, mut refresh) = (s.want_key || periodic, false);
                    if !key && s.want_recovery {
                        s.recoveries += 1;
                        if s.acked.is_empty() {
                            key = true;
                            s.recovery_keyframes += 1;
                        } else {
                            refresh = true;
                        }
                    }
                    s.want_key = false;
                    s.want_recovery = false;
                    if key {
                        s.keyframes += 1;
                        s.acked.clear();
                    }
                    let len = if key { per * 6 } else if refresh { per * 3 / 10 } else { per - 2000 + (seq as usize * 997) % 4000 };
                    EncodedFrame {
                        picture: picture(seq, len),
                        keyframe: key,
                        parameter_sets: if key { vec![vec![0x67, 1, 2], vec![0x68, 3]] } else { vec![] },
                        crop: Crop::WHOLE,
                        captured: now(),
                        refresh,
                        reference: (seq % 4 == 0).then_some(seq as u64),
                    }
                };
                sink(f);
            }
        });
        Ok(ScreenInfo { width: 1512.0, height: 982.0, codec: "h264".into() })
    }
    fn set_crop(&mut self, _: Crop) {}
    fn set_rate(&mut self, bitrate: u32, fps: u32) {
        let mut s = self.st.lock().unwrap();
        s.bitrate = bitrate;
        s.fps = fps;
    }
    fn keyframe(&mut self) {
        self.st.lock().unwrap().want_key = true;
    }
    fn refresh(&mut self) {}
    fn stop(&mut self) {
        self.st.lock().unwrap().gen += 1;
    }
    fn supports_recovery(&self) -> bool {
        self.recovery
    }
    fn recovery_frame(&mut self) {
        self.st.lock().unwrap().want_recovery = true;
    }
    fn acknowledged(&mut self, references: &[u64]) {
        self.st.lock().unwrap().acked.extend_from_slice(references);
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

struct Back(In, Synth);
impl Backend for Back {
    fn input(&mut self) -> &mut dyn Input {
        &mut self.0
    }
    fn screen(&mut self) -> Option<&mut dyn Screen> {
        Some(&mut self.1)
    }
    fn platform(&self) -> &'static str {
        "linux"
    }
    fn display_aspect(&self) -> f64 {
        1512.0 / 982.0
    }
    fn now(&self) -> f64 {
        now()
    }
    fn keep_awake(&mut self, _: bool, _: bool) {}
}

/// The server's stats lines, summed: pieces sent again, parity pieces, recovery frames asked.
#[derive(Clone, Default)]
struct Logs(Arc<Mutex<Vec<serde_json::Value>>>);
struct LogApp(Logs);
impl App for LogApp {
    fn log(&self, e: &serde_json::Value) {
        self.0 .0.lock().unwrap().push(e.clone());
    }
}

impl Logs {
    fn take(&self) -> Vec<serde_json::Value> {
        std::mem::take(&mut self.0.lock().unwrap())
    }
}

fn sum(lines: &[serde_json::Value], event: &str, key: &str) -> i64 {
    lines.iter().filter(|l| l["event"] == event).filter_map(|l| l[key].as_i64()).sum()
}

fn request(repairs: bool) -> ScreenRequest {
    ScreenRequest {
        target: "display".into(),
        crop: blurt_remote::wire::Crop::WHOLE,
        width: 1866,
        height: 1206,
        bitrate: 12_000_000,
        fps: 60,
        codecs: Some(vec!["h264".into()]),
        display: None,
        features: repairs.then(|| ALL.iter().map(|s| s.to_string()).collect()),
    }
}

struct Stage {
    name: &'static str,
    repairs: bool,
    weather: Weather,
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn loss_is_repaired_not_restarted() {
    let seconds: f64 = std::env::var("BLURT_REALTIME_SECONDS").ok().and_then(|s| s.parse().ok()).unwrap_or(4.0);
    let dir = std::env::temp_dir().join(format!("blurt-remote-realtime-{}", blurt_remote::crypto::new_id()));
    let synth = Synth { st: Arc::new(Mutex::new(SynthSt::default())), recovery: true };
    let logs = Logs::default();
    let h = Host::start(
        HostConfig { dir: dir.clone(), name: "Loopback".into(), version: "1.0.15".into(), test_answer: Some(true), port: 0 },
        Box::new(Back(In, synth.clone())),
        Box::new(FileKeyStore::new(dir.join("keys.json"))),
        Box::new(LogApp(logs.clone())),
    );
    h.set_screen_allowed(true);
    h.show_pairing(true);
    let (link, port) = loop {
        let s = h.status();
        if let Some(p) = s.pairing {
            break (p.url, s.port);
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    };
    let at: SocketAddr = format!("127.0.0.1:{port}").parse().unwrap();
    let (mut phone, _, _, info) = pair(&link, at).await.expect("paired");
    phone.open_udp(info.udp_port, info.udp_session).await.unwrap();
    tokio::time::sleep(Duration::from_millis(300)).await;

    let far = |rate: f64, burst: f64, seed: u64| {
        let mut w = Weather::new(rate, burst, 0.0, 1.0, seed);
        w.delay = 0.03; // a 60 ms round trip: away from home
        w
    };
    let stages = [
        Stage { name: "clean, repairs", repairs: true, weather: Weather::clear() },
        Stage { name: "1 %, bursts of 2, before", repairs: false, weather: Weather::new(0.01, 2.0, 0.0, 1.0, 7) },
        Stage { name: "1 %, bursts of 2, repairs", repairs: true, weather: Weather::new(0.01, 2.0, 0.0, 1.0, 7) },
        Stage { name: "3 %, bursts of 3, before", repairs: false, weather: Weather::new(0.03, 3.0, 0.0, 1.0, 9) },
        Stage { name: "3 %, bursts of 3, repairs", repairs: true, weather: Weather::new(0.03, 3.0, 0.0, 1.0, 9) },
        Stage { name: "1 %, independent, repairs", repairs: true, weather: Weather::new(0.01, 1.0, 0.0, 1.0, 11) },
        Stage { name: "80 ms stall every 2 s, repairs", repairs: true, weather: Weather::parse(None, Some("80:2"), 3) },
        Stage { name: "3 %, bursts of 3, 60 ms round trip, repairs", repairs: true, weather: far(0.03, 3.0, 5) },
    ];
    let mut results: Vec<(&str, Measure, i64, i64, i64, u32, usize)> = vec![];
    for st in stages {
        logs.take();
        let before = synth.st.lock().unwrap().recoveries;
        let m = phone
            .watch(Watch { request: request(st.repairs), warmup: 1.0, seconds, weather: st.weather, verify: Some(verify) })
            .await;
        tokio::time::sleep(Duration::from_millis(300)).await;
        let lines = logs.take();
        let (resent, parity, ignored) =
            (sum(&lines, "remote_screen_host", "resent"), sum(&lines, "remote_screen_host", "parity"), sum(&lines, "remote_screen_host", "resend_ignored"));
        let rate = synth.st.lock().unwrap().bitrate;
        let recoveries = synth.st.lock().unwrap().recoveries - before;
        println!("{:<44} {m}\n{:<44} host: resent {resent}, parity {parity}, resend ignored {ignored}, recoveries {recoveries}, bitrate after {:.1} Mbps",
            st.name, "", rate as f64 / 1e6);
        results.push((st.name, m, resent, parity, ignored, rate, recoveries));
    }
    h.stop();
    let _ = std::fs::remove_dir_all(dir);

    let get = |n: &str| results.iter().find(|r| r.0 == n).unwrap();
    // clean: every frame, nothing asked
    let clean = &get("clean, repairs").1;
    assert!(clean.fps > 57.0, "{clean}");
    assert_eq!((clean.keyframes_asked, clean.dropped, clean.corrupt), (0, 0, 0), "{clean}");
    assert_eq!(clean.features.as_deref(), Some(&["fec".to_string(), "ltr".into(), "nack".into()][..]));
    for name in ["1 %, bursts of 2, repairs", "3 %, bursts of 3, repairs", "1 %, independent, repairs", "80 ms stall every 2 s, repairs"] {
        let (_, m, resent, _, _, rate, _) = get(name);
        assert!(m.fps > 56.0, "{name}: {m}");
        assert_eq!(m.keyframes_asked, 0, "{name}: {m}");
        assert!(m.dropped <= 2, "{name}: {m}");
        assert_eq!(m.corrupt, 0, "{name}: what was sent again or rebuilt is what was sent: {m}");
        assert!(m.longest_gap_ms < 150.0, "{name}: {m}");
        assert!(*rate >= 11_000_000, "{name}: the rate stays near the top, not a third of it ({rate})");
        if m.weather_dropped > 0 && !name.contains("stall") {
            assert!(*resent > 0, "{name}");
        }
    }
    // before: the old way, for comparison
    for (with, without) in [("1 %, bursts of 2, repairs", "1 %, bursts of 2, before"), ("3 %, bursts of 3, repairs", "3 %, bursts of 3, before")] {
        let (a, b) = (&get(with).1, &get(without).1);
        assert!(b.keyframes_asked > 0, "{without}: {b}");
        assert!(a.fps > b.fps + 5.0, "{with} {a} against {without} {b}");
    }
    // away from home: parity takes over part of the mending
    let (_, m, _, parity, _, _, _) = get("3 %, bursts of 3, 60 ms round trip, repairs");
    assert!(*parity > 0, "parity at a 60 ms round trip and 3 % loss: {m}");
    assert!(m.repaired > 0, "{m}");
    assert!(m.fps > 50.0, "{m}");
}
