//! A still screen of text made sharp, measured on Windows (docs/design/remote-windows.md §2026-11-11; the Mac's probe is in
//! docs/design/remote-realtime.md §7). A page of 13 px code (a PNG, `width` wide, drawn on a Mac as the Mac's probe draws its
//! window: English and Chinese, five colours, dark) scrolls 23 px a frame for 1.5 s at the rate, then stops; the stopped picture is then sent again as
//! the server does it: `Sharpen` (sharpen.rs) asked every 1/60 s, `Screen::sharpen` / `refresh` through the real backend
//! (WinScreen: capture of the page → video processor → Media Foundation encoder), its `sent` fed with what came out. Then it scrolls
//! another 0.5 s, to see that the ceiling is off again. No desktop needed (an SSH session will do).
//!
//!   cargo run --release --example win_sharpen -- --page page1800.png --bitrate 2000000 --codec hevc --mode ladder --out run
//!   options: --software (Microsoft's H.264), --mode plain (eight plain resends: an encoder that takes no ceiling), --mode
//!            hold:<qp> (that ceiling, held, ten times), --probe (the encoder's rate 1.5 × while it sharpens, as the server
//!            does when it probes the network; prints how fast the resends went against the waits `Sharpen::sent` returned)
//!            --fps <n> (moving frames at that rate instead of rate.rs's)
//!   The ladder runs only where the encoder answers to it (encoder.rs `boosts`): BLURT_REMOTE_SHARPEN=1 forces it on, to measure.
//!
//! Writes <out>.h264 / .h265 (every frame, Annex B) and <out>.csv (one line a frame: n, seconds since the stop, bytes, what it was,
//! ceiling, keyframe), plus the offset of the stopped picture in the page on stdout; decode with ffmpeg and compare the luma
//! with the page's at that offset (BT.709, limited range).

#[cfg(not(windows))]
fn main() {
    eprintln!("win_sharpen runs on Windows");
}

#[cfg(windows)]
fn main() {
    win::main()
}

#[cfg(windows)]
mod win {
    use std::io::Write;
    use std::sync::atomic::{AtomicU32, Ordering};
    use std::sync::{Arc, Mutex};
    use std::time::{Duration, Instant};

    use blurt_remote::host::{Crop, EncodedFrame, Screen, ScreenConfig};
    use blurt_remote::platform::windows::annexb;
    use blurt_remote::platform::windows::screen::{Options, PageSource, Source};
    use blurt_remote::platform::windows::WinBackend;
    use blurt_remote::sharpen::{Sharpen, NO_CEILING};

    fn arg(name: &str) -> Option<String> {
        let a: Vec<String> = std::env::args().collect();
        a.iter().position(|x| x == name).and_then(|i| a.get(i + 1).cloned())
    }
    fn flag(name: &str) -> bool {
        std::env::args().any(|x| x == name)
    }

    #[derive(Clone, Copy, PartialEq, Debug)]
    enum Kind {
        Moving,
        Step,
        After,
    }

    struct St {
        t0: Instant,
        sharpen: Sharpen,
        pending: Option<u8>,
        last_frame_at: f64,
        bitrate: i64,
        /// the rate the resends go at (the server's `rate.probe()`: 1.5 × with --probe)
        pace: i64,
        waits: f64,
        kind: Kind,
        stop_at: f64,
        /// (t since start, bytes, kind, cap, keyframe)
        rows: Vec<(f64, usize, Kind, u8, bool)>,
        file: Vec<u8>,
        tries: u32,
        dropped: u32,
    }

    impl St {
        fn now(&self) -> f64 {
            self.t0.elapsed().as_secs_f64()
        }
    }

    fn load_page(path: &str) -> (u32, u32, Vec<u8>) {
        let d = png::Decoder::new(std::io::BufReader::new(std::fs::File::open(path).expect("page")));
        let mut r = d.read_info().expect("png");
        let mut buf = vec![0; r.output_buffer_size()];
        let info = r.next_frame(&mut buf).expect("png frame");
        let ch = info.color_type.samples();
        let mut bgra = Vec::with_capacity((info.width * info.height * 4) as usize);
        for px in buf[..info.buffer_size()].chunks(ch) {
            bgra.extend_from_slice(&[px[2], px[1], px[0], 255]);
        }
        (info.width, info.height, bgra)
    }

    pub fn main() {
        let page_path = arg("--page").expect("--page <png>");
        let bitrate: u32 = arg("--bitrate").and_then(|s| s.parse().ok()).unwrap_or(2_000_000);
        let codec = arg("--codec").unwrap_or_else(|| "hevc".into());
        let mode = arg("--mode").unwrap_or_else(|| "ladder".into());
        let out = arg("--out").unwrap_or_else(|| "sharpen".into());
        let software = flag("--software");
        let (width, rows, bgra) = load_page(&page_path);
        let height = (width * 10 / 16) / 2 * 2;
        // as rate.rs: 30 kbit a frame, 10 to 60 frames a second
        let fps = arg("--fps").and_then(|s| s.parse().ok()).unwrap_or((bitrate as i64 / 30_000).clamp(10, 60) as u32);
        let page: &'static PageSource = Box::leak(Box::new(PageSource { width, height, rows, bgra, offset: AtomicU32::new(0) }));

        let mut b = WinBackend::new();
        b.win_screen().options = Options { source: Source::Page(page), software };
        let st = Arc::new(Mutex::new(St {
            t0: Instant::now(),
            sharpen: Sharpen::finished(),
            pending: None,
            last_frame_at: 0.0,
            bitrate: bitrate as i64,
            pace: bitrate as i64,
            waits: 0.0,
            kind: Kind::Moving,
            stop_at: 0.0,
            rows: Vec::new(),
            file: Vec::new(),
            tries: 0,
            dropped: 0,
        }));
        // what the server's `frame` does with each frame (screen.rs), and the frame kept
        let sink = {
            let st = st.clone();
            Arc::new(move |f: EncodedFrame| {
                let mut s = st.lock().unwrap();
                let now = s.now();
                let bytes = f.picture.len() + if f.keyframe { f.parameter_sets.iter().map(|p| p.len()).sum::<usize>() } else { 0 };
                let sharpened = s.pending.take();
                let kind = if sharpened.is_some() { Kind::Step } else { s.kind };
                if let Some(cap) = sharpened {
                    let (br, pace) = (s.bitrate, s.pace);
                    let w = s.sharpen.sent(cap, bytes, br, pace, now);
                    s.waits += w;
                } else {
                    s.sharpen.again();
                    s.last_frame_at = now;
                }
                s.rows.push((now, bytes, kind, sharpened.unwrap_or(NO_CEILING), f.keyframe));
                s.file.extend(annexb::to_annexb(if f.keyframe { &f.parameter_sets } else { &[] }, &f.picture));
            })
        };
        let config = ScreenConfig {
            width,
            height,
            bitrate,
            fps,
            codecs: vec![codec.clone()],
            crop: Crop::WHOLE,
            display: None,
            capture_fps: ScreenConfig::capture_for(fps),
            repairs: true,
        };
        let screen = b.win_screen();
        if let Err(e) = screen.start(&config, sink) {
            println!("screen failed: {e}");
            std::process::exit(1);
        }
        let capped = screen.caps_quantiser();
        let stats = screen.take_stats();
        println!(
            "{} {} {}x{} at {} kbps, {fps} fps, quantiser ceiling: {}",
            stats.encoder,
            stats.codec,
            stats.width,
            stats.height,
            bitrate / 1000,
            if capped { "yes" } else { "no" }
        );

        // scrolling, a second and a half, 23 px a frame
        let frame = Duration::from_secs_f64(1.0 / fps as f64);
        let scroll = |from: u32, n: u32| {
            let t = Instant::now();
            for i in 0..n {
                page.offset.store((from + i) * 23, Ordering::SeqCst);
                let due = frame * (i + 1);
                std::thread::sleep(due.saturating_sub(t.elapsed()));
            }
        };
        let moving = fps * 3 / 2;
        scroll(1, moving);
        let still = page.offset.load(Ordering::SeqCst);
        std::thread::sleep(Duration::from_millis(150));
        // --probe: as the server, the encoder's rate 1.5 × while the ladder runs, and back after (screen.rs `asks.rate`)
        let probe = flag("--probe");
        let pace = if probe { bitrate as i64 * 3 / 2 } else { bitrate as i64 };
        if probe {
            let t = Instant::now();
            screen.set_rate(pace as u32, fps);
            println!("set_rate up: {:.0} µs to ask", t.elapsed().as_secs_f64() * 1e6);
        }
        {
            let mut s = st.lock().unwrap();
            s.stop_at = s.now();
            s.sharpen = Sharpen::default();
            s.pace = pace;
        }

        // the server's tick, 60 a second (screen.rs `tick`): the same frame again while the sharpening isn't done
        let hold: Option<u8> = mode.strip_prefix("hold:").and_then(|q| q.parse().ok());
        let mut held = 0;
        let mut last_ask = 0.0;
        let deadline = Instant::now() + Duration::from_secs(20);
        loop {
            std::thread::sleep(Duration::from_millis(16));
            if Instant::now() > deadline {
                println!("still not done after 20 s");
                break;
            }
            let ask = {
                let mut s = st.lock().unwrap();
                let now = s.now();
                if let Some(q) = hold {
                    if held >= 10 {
                        break;
                    }
                    if now - last_ask < 0.3 || now - s.last_frame_at <= 0.2 {
                        None
                    } else {
                        last_ask = now;
                        held += 1;
                        s.pending = Some(q);
                        s.tries += 1;
                        Some(q)
                    }
                } else {
                    if s.sharpen.done {
                        break;
                    }
                    if now - s.last_frame_at <= 0.2 {
                        continue;
                    }
                    let c = if mode == "plain" { false } else { capped };
                    match s.sharpen.next(now, c) {
                        Some(cap) => {
                            s.tries += 1;
                            if s.pending.is_some() {
                                s.dropped += 1; // the last one never came back
                            }
                            s.pending = Some(cap);
                            Some(cap)
                        }
                        None => None,
                    }
                }
            };
            match ask {
                Some(cap) if cap < NO_CEILING => screen.sharpen(cap),
                Some(_) => screen.refresh(),
                None => {}
            }
        }
        // the last one back, then moving again: the ceiling must be off
        std::thread::sleep(Duration::from_millis(400));
        if probe {
            screen.set_rate(bitrate, fps);
        }
        let steps_end = st.lock().unwrap().now();
        st.lock().unwrap().kind = Kind::After;
        scroll(moving + 1, fps / 2);
        std::thread::sleep(Duration::from_millis(300));
        screen.stop();

        let s = st.lock().unwrap();
        let ext = if codec == "hevc" { "h265" } else { "h264" };
        std::fs::write(format!("{out}.{ext}"), &s.file).unwrap();
        let mut csv = std::fs::File::create(format!("{out}.csv")).unwrap();
        writeln!(csv, "n,t,bytes,kind,cap,keyframe").unwrap();
        for (i, (t, bytes, kind, cap, key)) in s.rows.iter().enumerate() {
            writeln!(csv, "{i},{:.3},{bytes},{kind:?},{cap},{}", t - s.stop_at, *key as u8).unwrap();
        }
        let step_bytes: usize = s.rows.iter().filter(|r| r.2 == Kind::Step).map(|r| r.1).sum();
        let steps = s.rows.iter().filter(|r| r.2 == Kind::Step).count();
        let avg = |k: Kind, from: f64| {
            let v: Vec<usize> = s.rows.iter().filter(|r| r.2 == k && r.0 >= from).map(|r| r.1).collect();
            v.iter().sum::<usize>() as f64 / v.len().max(1) as f64
        };
        let last_step_t = s.rows.iter().filter(|r| r.2 == Kind::Step).map(|r| r.0).fold(s.stop_at, f64::max);
        println!("resends {:.0} kbit/s against the waits sent() returned ({:.2} s): {:.2} × the bitrate", step_bytes as f64 * 8.0 / s.waits.max(1e-3) / 1000.0, s.waits, step_bytes as f64 * 8.0 / s.waits.max(1e-3) / bitrate as f64);
        let keys: Vec<usize> = s.rows.iter().enumerate().filter(|(i, r)| r.4 && *i > 0).map(|(i, _)| i).collect();
        println!("keyframes after the first: {keys:?}");
        println!(
            "still offset {still}; {steps} resends, {} KB, {:.2} s, {} tries, {} dropped; moving frames before {:.1} KB, after {:.1} KB",
            step_bytes / 1000,
            last_step_t - s.stop_at,
            s.tries,
            s.dropped + s.pending.is_some() as u32,
            avg(Kind::Moving, s.stop_at - 0.5) / 1000.0,
            avg(Kind::After, steps_end) / 1000.0
        );
    }
}
