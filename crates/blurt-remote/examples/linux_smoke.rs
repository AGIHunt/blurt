//! The Linux backend on a real desktop, end to end (docs/design/remote-linux.md §Testing):
//!
//!   cargo run --release --example linux_smoke -- [--seconds 5] [--width 2042] [--height 1276] [--bitrate 8000000] [--fps 60]
//!                                                [--codecs hevc,h264] [--out /tmp/remote.h264] [--type "text"] [--no-move]
//!
//! Opens the portal session (GNOME's Remote Desktop dialog the first time; then its restore token), streams for a few seconds
//! while the crop changes (whole → seven new crops a second → 2× zoom), writes what the phone would decode to an Annex B file
//! (`ffprobe` / `ffplay` it), prints frames a second, kbit/s and the age of each frame when it left the encoder, moves the
//! pointer in a small square reading back where the stream says it is, and types `--type` into whatever has focus.

#[cfg(target_os = "linux")]
fn main() {
    use blurt_remote::host::{Backend, Crop, ScreenConfig};
    use blurt_remote::platform::linux;
    use std::io::Write;
    use std::sync::{Arc, Mutex};
    use std::time::{Duration, Instant};

    let args: Vec<String> = std::env::args().collect();
    let arg = |k: &str| args.iter().position(|a| a == k).and_then(|i| args.get(i + 1)).cloned();
    let num = |k: &str, d: u32| arg(k).and_then(|v| v.parse().ok()).unwrap_or(d);
    let seconds = num("--seconds", 5);
    let out = arg("--out").unwrap_or_else(|| "/tmp/blurt-remote-smoke.h264".into());
    let codecs: Vec<String> = arg("--codecs").unwrap_or_else(|| "hevc,h264".into()).split(',').map(|s| s.to_string()).collect();
    let config = ScreenConfig {
        width: num("--width", 2042),
        height: num("--height", 1276),
        bitrate: num("--bitrate", 8_000_000),
        fps: num("--fps", 60),
        codecs: codecs.clone(),
        crop: Crop::WHOLE,
        display: None,
        capture_fps: ScreenConfig::capture_for(num("--fps", 60)),
        repairs: false,
    };
    println!("encoder for {codecs:?}: {:?}", linux::pick_encoder(&codecs));

    let mut b = linux::linux_backend();
    let t = Instant::now();
    match b.connect(Duration::from_secs(120)) {
        Ok(()) => println!("portal session open in {:.0} ms, can_control={}", t.elapsed().as_secs_f64() * 1000.0, b.input().can_control()),
        Err(e) => {
            println!("portal: {e}");
            std::process::exit(1);
        }
    }
    println!("display aspect {:.3}, displays {:?}", b.display_aspect(), b.displays());
    b.keep_awake(true, true);

    #[derive(Default)]
    struct Stats {
        frames: u32,
        bytes: usize,
        keys: u32,
        ages: Vec<f64>,
        crops: Vec<Crop>,
    }
    let file = Arc::new(Mutex::new(std::fs::File::create(&out).expect("output file")));
    let stats = Arc::new(Mutex::new(Stats::default()));
    let (f2, s2) = (file.clone(), stats.clone());
    let sink: blurt_remote::host::FrameSink = Arc::new(move |fr| {
        let age = (linux::now() - fr.captured) * 1000.0;
        let mut s = s2.lock().unwrap();
        s.frames += 1;
        s.bytes += fr.picture.len() + fr.parameter_sets.iter().map(|p| p.len()).sum::<usize>();
        s.keys += fr.keyframe as u32;
        s.ages.push(age);
        if s.crops.last() != Some(&fr.crop) {
            s.crops.push(fr.crop);
        }
        let unit = linux::nal::Unit { picture: fr.picture, keyframe: fr.keyframe, parameter_sets: fr.parameter_sets };
        let _ = f2.lock().unwrap().write_all(&linux::nal::annexb(&unit));
    });
    let t = Instant::now();
    let info = b.screen().unwrap().start(&config, sink);
    println!("screen start in {:.0} ms: {info:?}", t.elapsed().as_secs_f64() * 1000.0);
    if info.is_err() {
        std::process::exit(1);
    }

    let crops = [
        Crop { x: 0.25, y: 0.25, w: 0.5, h: 0.5 },
        Crop { x: 0.0, y: 0.0, w: 0.4, h: 0.4 },
        Crop { x: 0.5, y: 0.4, w: 0.3333, h: 0.3333 },
        Crop { x: 0.1, y: 0.5, w: 0.5, h: 0.5 },
    ];
    let start = Instant::now();
    let mut last_report = Instant::now();
    let mut tick = 0u32;
    let moving = !args.iter().any(|a| a == "--no-move");
    let mut side = 0;
    while start.elapsed() < Duration::from_secs(seconds as u64) {
        std::thread::sleep(Duration::from_millis(50));
        tick += 1;
        let s = start.elapsed().as_secs_f64();
        let share = seconds as f64 / 5.0;
        // whole, then a new crop every 150 ms (about 7 a second, as the phone asks while pinching), then 2× zoom
        if s > 1.0 * share && s < 3.0 * share && tick.is_multiple_of(3) {
            b.screen().unwrap().set_crop(crops[(tick / 3) as usize % crops.len()]);
        } else if s >= 3.0 * share && s < 3.0 * share + 0.06 {
            b.screen().unwrap().set_crop(Crop { x: 0.25, y: 0.25, w: 0.5, h: 0.5 });
        }
        if s >= 4.0 * share && s < 4.0 * share + 0.06 {
            b.screen().unwrap().set_rate(config.bitrate / 4, config.fps / 2);
            println!("  rate → {} kbit/s, {} fps", config.bitrate / 4000, config.fps / 2);
        }
        // a 60-point square, a side every half second
        if moving && tick.is_multiple_of(2) {
            let (dx, dy) = [(6.0, 0.0), (0.0, 6.0), (-6.0, 0.0), (0.0, -6.0)][(side / 10) % 4];
            b.input().move_by(dx, dy);
            side += 1;
        }
        if last_report.elapsed() >= Duration::from_secs(1) {
            let mut st = stats.lock().unwrap();
            let secs = last_report.elapsed().as_secs_f64();
            let mut ages = std::mem::take(&mut st.ages);
            ages.sort_by(|a, b| a.partial_cmp(b).unwrap());
            let p = |q: f64| ages.get(((ages.len() as f64 - 1.0) * q).round() as usize).copied().unwrap_or(0.0);
            println!(
                "{:4.1}s  {:5.1} fps  {:6.0} kbit/s  {} key  age ms p50 {:.1} p95 {:.1} max {:.1}  pointer {:?}",
                s,
                st.frames as f64 / secs,
                st.bytes as f64 * 8.0 / secs / 1000.0,
                st.keys,
                p(0.5),
                p(0.95),
                p(1.0),
                b.input().pointer().map(|(x, y)| ((x * 1000.0).round() / 1000.0, (y * 1000.0).round() / 1000.0))
            );
            st.frames = 0;
            st.bytes = 0;
            st.keys = 0;
            last_report = Instant::now();
            if let Some(c) = b.input().cursor_shape() {
                println!("  cursor shape: {} byte PNG, {}×{} pt, hot spot {},{}", c.png.len(), c.width, c.height, c.hot_x, c.hot_y);
            }
        }
    }
    // a still screen: a refresh and a keyframe asked for
    b.screen().unwrap().refresh();
    b.screen().unwrap().keyframe();
    std::thread::sleep(Duration::from_millis(300));
    println!("crops the frames said they showed: {}", stats.lock().unwrap().crops.len());
    if let Some(t) = arg("--type") {
        b.input().text(&t);
        b.input().key("Return", 0, None);
        println!("typed {t:?} + Return");
        std::thread::sleep(Duration::from_millis(1500));
    }
    if args.iter().any(|a| a == "--scroll") {
        // two fingers moving up 300 pt over half a second: the content moves up (the view scrolls down), then a lift
        use blurt_remote::host::ScrollPhase;
        // the pointer to the middle of the monitor first (an absolute move), where what's under it scrolls
        b.screen().unwrap().refresh();
        b.input().move_to(0.5, 0.5);
        std::thread::sleep(Duration::from_millis(300));
        println!("moved to (0.5, 0.5): the stream says {:?}", b.input().pointer());
        b.input().scroll(0.0, -10.0, ScrollPhase::Began);
        for _ in 0..30 {
            std::thread::sleep(Duration::from_millis(16));
            b.input().scroll(0.0, -10.0, ScrollPhase::Changed);
        }
        b.input().scroll(0.0, 0.0, ScrollPhase::Ended);
        println!("scrolled 310 pt");
        std::thread::sleep(Duration::from_millis(1500));
    }
    if args.iter().any(|a| a == "--overview") {
        use blurt_remote::host::SystemMove;
        b.input().system(SystemMove::MissionControl);
        println!("overview (Super tap) at {:.1}s", start.elapsed().as_secs_f64());
        std::thread::sleep(Duration::from_millis(2500));
        b.input().key("Escape", 0, None);
    }
    b.screen().unwrap().stop();
    b.input().release_all();
    b.keep_awake(false, false);
    println!("wrote {out}");
}

#[cfg(not(target_os = "linux"))]
fn main() {
    eprintln!("linux_smoke runs on Linux");
}
