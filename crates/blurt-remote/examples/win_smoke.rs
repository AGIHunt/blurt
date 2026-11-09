//! The Windows backend on a real machine, with numbers (docs/design/remote-windows.md §Windows backend).
//!
//!   cargo run --release --example win_smoke                       the monitor under the pointer, hardware encoder
//!   cargo run --release --example win_smoke -- --software         Microsoft's software H.264 encoder (the fallback)
//!   cargo run --release --example win_smoke -- --synthetic        no desktop needed (a service, SSH = session 0): text-like
//!                                                                 rows scrolling at 1920×1080, through the same converter + encoder
//!   options: --hevc (ask for HEVC first, writes .h265), --size 1920x1080 (synthetic), --out <file>, --no-input
//!
//! Stages: whole screen, 2× zoom, 3× zoom moving 7 times a second, a thinner pipe (2 Mbps, 30 fps), then still (should send nothing),
//! refreshes, a keyframe on request. It prints fps / encode ms / kbps per stage, the crop latency, the age of frames, and writes
//! what went to the phone as Annex B: `ffplay <file>` plays it. While capturing it prints a line every 33 ms, so a console on the
//! captured monitor is scrolling text (keep it in view). Then it moves the pointer in a small square and types nothing.

#[cfg(not(windows))]
fn main() {
    eprintln!("win_smoke runs on Windows (cargo run --example win_smoke there)");
}

#[cfg(windows)]
fn main() {
    win::main()
}

#[cfg(windows)]
mod win {
    use std::io::Write;
    use std::sync::{Arc, Mutex};
    use std::time::{Duration, Instant};

    use blurt_remote::host::{Backend, Crop, EncodedFrame, Screen, ScreenConfig};
    use blurt_remote::platform::windows::annexb;
    use blurt_remote::platform::windows::screen::{hardware_encoders, Options, Source};
    use blurt_remote::platform::windows::WinBackend;

    #[derive(Default)]
    struct Seen {
        frames: Vec<(f64, usize, bool, Crop)>, // (when, bytes, keyframe, crop)
        ages_ms: Vec<f64>,
        file: Vec<u8>,
    }

    fn arg(name: &str) -> Option<String> {
        let a: Vec<String> = std::env::args().collect();
        a.iter().position(|x| x == name).and_then(|i| a.get(i + 1).cloned())
    }
    fn flag(name: &str) -> bool {
        std::env::args().any(|x| x == name)
    }

    fn pct(v: &mut [f64], p: f64) -> f64 {
        if v.is_empty() {
            return 0.0;
        }
        v.sort_by(|a, b| a.partial_cmp(b).unwrap());
        v[((v.len() - 1) as f64 * p).round() as usize]
    }

    /// Run for `secs`, printing a ticker line every 33 ms (scrolling text for the capture), calling `each` at every tick.
    fn run(secs: f64, ticker: bool, mut each: impl FnMut(f64)) {
        let t0 = Instant::now();
        let mut n = 0u64;
        while t0.elapsed().as_secs_f64() < secs {
            if ticker {
                n += 1;
                println!("{n:06} Blurt remote smoke · 口喷鸡 · the quick brown fox jumps over the lazy dog · {:.3}", t0.elapsed().as_secs_f64());
            }
            each(t0.elapsed().as_secs_f64());
            std::thread::sleep(Duration::from_millis(33));
        }
    }

    pub fn main() {
        let synthetic = flag("--synthetic");
        let software = flag("--software");
        let hevc = flag("--hevc");
        let size = arg("--size").unwrap_or_else(|| "1920x1080".into());
        let (sw, sh) = size.split_once('x').and_then(|(a, b)| Some((a.parse().ok()?, b.parse().ok()?))).unwrap_or((1920, 1080));

        println!("hardware encoders:");
        for (codec, name) in hardware_encoders() {
            println!("  {codec}: {name}");
        }

        let mut b = WinBackend::new();
        println!("platform {}  display aspect {:.4}  now {:.3}", b.platform(), b.display_aspect(), b.now());
        b.win_screen().options =
            Options { source: if synthetic { Source::Synthetic { width: sw, height: sh } } else { Source::Monitor }, software };

        let seen = Arc::new(Mutex::new(Seen::default()));
        let sets = Arc::new(Mutex::new(Vec::<Vec<u8>>::new()));
        let t_ref = b.now();
        let clock = {
            let start = Instant::now();
            move || t_ref + start.elapsed().as_secs_f64()
        };
        let sink = {
            let seen = seen.clone();
            let sets = sets.clone();
            Arc::new(move |f: EncodedFrame| {
                let now = clock();
                let mut s = seen.lock().unwrap();
                if f.keyframe {
                    *sets.lock().unwrap() = f.parameter_sets.clone();
                }
                let bytes = f.picture.len() + f.parameter_sets.iter().map(|p| p.len()).sum::<usize>();
                s.frames.push((now, bytes, f.keyframe, f.crop));
                s.ages_ms.push((now - f.captured) * 1000.0);
                let annexb = annexb::to_annexb(if f.keyframe { &f.parameter_sets } else { &[] }, &f.picture);
                s.file.extend(annexb);
            })
        };
        let config = ScreenConfig {
            width: 2042,
            height: 1150,
            bitrate: 12_000_000,
            fps: 60,
            codecs: if hevc { vec!["hevc".into(), "h264".into()] } else { vec!["h264".into()] },
            crop: Crop::WHOLE,
            display: None,
        };
        let info = match b.win_screen().start(&config, sink) {
            Ok(i) => i,
            Err(e) => {
                println!("screen failed: {e}");
                std::process::exit(1);
            }
        };
        let st = b.win_screen().take_stats();
        println!(
            "screen: {:.0}×{:.0} pt, {} via {} ({}), output {}×{}",
            info.width, info.height, info.codec, st.encoder, st.capture, st.width, st.height
        );

        let stage = |b: &mut WinBackend, name: &str| {
            let s = b.win_screen().take_stats();
            let mut seen = seen.lock().unwrap();
            let mut ages = std::mem::take(&mut seen.ages_ms);
            let kb: Vec<f64> = seen.frames.iter().map(|f| f.1 as f64 / 1024.0).collect();
            let max_kb = kb.iter().cloned().fold(0.0, f64::max);
            seen.frames.clear();
            println!(
                "{name:<28} {:5.1} fps  encode {:5.2} ms  convert {:5.2} ms  {:7.0} kbps  key {:2}  skipped {:4}  captured {:4}  age p50 {:5.1} p95 {:5.1} ms  largest {:6.1} KB",
                s.fps(),
                s.encode_ms_avg(),
                s.convert_ms_avg(),
                s.kbps(),
                s.keyframes,
                s.skipped,
                s.captured,
                pct(&mut ages, 0.5),
                pct(&mut ages, 0.95),
                max_kb
            );
        };

        // whole screen
        b.win_screen().take_stats();
        run(3.0, !synthetic, |_| {});
        stage(&mut b, "whole");

        // 2× in the middle
        b.win_screen().set_crop(Crop { x: 0.25, y: 0.25, w: 0.5, h: 0.5 });
        run(2.0, !synthetic, |_| {});
        stage(&mut b, "2x");

        // 3×, the view moving 7 times a second (a pinch / pan): how soon each new crop shows
        let mut asked: Vec<(f64, Crop)> = Vec::new();
        let mut last_ask = -1.0;
        run(2.0, !synthetic, |t| {
            if t - last_ask >= 1.0 / 7.0 {
                last_ask = t;
                let k = (t * 7.0) as usize % 10;
                let c = Crop { x: 0.05 + k as f32 * 0.05, y: 0.3, w: 1.0 / 3.0, h: 1.0 / 3.0 };
                asked.push((clock(), c));
                b.win_screen().set_crop(c);
            }
        });
        let lat: Vec<f64> = {
            let s = seen.lock().unwrap();
            asked
                .iter()
                .filter_map(|(at, c)| {
                    s.frames
                        .iter()
                        .find(|f| f.0 >= *at && (f.3.x - c.x).abs() < 0.002 && (f.3.w - c.w).abs() < 0.002)
                        .map(|f| (f.0 - at) * 1000.0)
                })
                .collect()
        };
        stage(&mut b, "3x moving 7/s");
        let mut l = lat.clone();
        println!("  crop changes shown {}/{}  latency p50 {:.1} ms  max {:.1} ms", lat.len(), asked.len(), pct(&mut l, 0.5), pct(&mut l, 1.0));

        // a thinner pipe
        b.win_screen().set_crop(Crop::WHOLE);
        b.win_screen().set_rate(2_000_000, 30);
        run(2.0, !synthetic, |_| {});
        stage(&mut b, "whole at 2 Mbps / 30 fps");
        b.win_screen().set_rate(12_000_000, 60);

        if !synthetic {
            // still: nothing printed, nothing should be sent
            std::thread::sleep(Duration::from_millis(300));
            b.win_screen().take_stats();
            seen.lock().unwrap().frames.clear();
            std::thread::sleep(Duration::from_millis(1500));
            stage(&mut b, "still (expect ~0 fps)");
        }

        // refreshes on the held picture, then a keyframe asked for
        for _ in 0..3 {
            b.win_screen().refresh();
            std::thread::sleep(Duration::from_millis(250));
        }
        let sizes: Vec<String> = seen.lock().unwrap().frames.iter().map(|f| format!("{:.1} KB", f.1 as f64 / 1024.0)).collect();
        stage(&mut b, "3 refreshes");
        println!("  refresh sizes: {}", sizes.join(", "));
        b.win_screen().keyframe();
        std::thread::sleep(Duration::from_millis(300));
        let keys = seen.lock().unwrap().frames.iter().filter(|f| f.2).count();
        stage(&mut b, "keyframe asked");
        println!("  keyframes after asking: {keys}");

        b.win_screen().stop();
        let out = arg("--out").unwrap_or_else(|| {
            format!("win_smoke{}{}.{}", if software { "_sw" } else { "" }, if synthetic { "_synthetic" } else { "" }, if info.codec == "hevc" { "h265" } else { "h264" })
        });
        let bytes = std::mem::take(&mut seen.lock().unwrap().file);
        std::fs::File::create(&out).and_then(|mut f| f.write_all(&bytes)).expect("write the stream");
        println!("wrote {out} ({} KB): ffplay {out}", bytes.len() / 1024);

        if flag("--no-input") || synthetic {
            return;
        }
        // the pointer in a small square, 40 pt a side in 10 steps; nothing typed
        let input = b.input();
        println!("can_control {}  pointer {:?}", input.can_control(), input.pointer());
        if let Some(s) = input.cursor_shape() {
            println!("cursor shape {} B png, {:.1}×{:.1} pt, hot spot {:.1},{:.1}", s.png.len(), s.width, s.height, s.hot_x, s.hot_y);
        }
        let start = input.pointer();
        for (dx, dy) in [(4.0, 0.0), (0.0, 4.0), (-4.0, 0.0), (0.0, -4.0)] {
            for _ in 0..10 {
                input.move_by(dx, dy);
                std::thread::sleep(Duration::from_millis(16));
            }
            println!("  pointer {:?}", input.pointer());
        }
        println!("back where it started: {:?} → {:?}", start, input.pointer());
        input.release_all();
    }
}
