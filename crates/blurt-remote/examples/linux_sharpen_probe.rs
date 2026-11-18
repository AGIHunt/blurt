//! How sharp a still screen of text gets on Linux, resend by resend (docs/design/remote-linux.md §2026-11-11): the host's own
//! encoder (encode.rs, as the backend builds it) fed a dense screen of 13 px code, English and Chinese in five colours on a dark
//! background, scrolled for 1.5 s, then still. Then the resends exactly as the server drives them (sharpen.rs's
//! `Sharpen`, its pacing included): `plain` is the eight resends an encoder without a ceiling gets, `ladder` the ceiling coming
//! down to SHARP. Each frame is decoded (avdec) and its luma compared with the source's. Then half a second more of scrolling,
//! to see the ceiling has come off.
//!
//!   cargo run --release --example linux_sharpen_probe -- <element> <bitrate> <width> <plain|ladder>
//!   (moving at the fps the server would ask for, rate.rs `frames` away from home; while it resends, the encoder at 1.5× the rate
//!   and the resends paced at that, where a change of rate is cheap, as the server does)
//!   e.g. … nvh265enc 2000000 1800 ladder        (BLURT_REMOTE_QP_PROPS=qp-max:51 tries a property on an element not in the table)

#[cfg(target_os = "linux")]
fn main() {
    use blurt_remote::host::Crop;
    use blurt_remote::platform::linux::encode::{Encoder, Picture};
    use blurt_remote::platform::linux::nal::{self, Codec, Unit};
    use blurt_remote::sharpen::{Sharpen, NO_CEILING};
    use gstreamer as gst;
    use gstreamer::prelude::*;
    use gstreamer_app as gst_app;
    use std::sync::{Arc, Mutex};
    use std::time::{Duration, Instant};

    let args: Vec<String> = std::env::args().collect();
    if args.len() < 5 {
        eprintln!("usage: linux_sharpen_probe <element> <bitrate> <width> <plain|ladder>");
        std::process::exit(2);
    }
    let element = args[1].clone();
    let bitrate: u32 = args[2].parse().unwrap();
    let w: u32 = args[3].parse().unwrap();
    let ladder = args[4] == "ladder";

    let h = w * 10 / 16 / 2 * 2;
    let codec = if element.contains("265") { Codec::Hevc } else { Codec::H264 };
    // the frame rate the server would ask for at this bitrate away from home (rate.rs `frames`: ceiling 30)
    let fps_now = (bitrate / 30_000).clamp(10, 30);
    const STEP: u32 = 23; // pixels a frame, as the Mac probe
    let (moving, after) = (fps_now * 3 / 2, fps_now / 2);
    gst::init().unwrap();

    // the text, drawn once on a tall canvas; a frame is a window into it
    let canvas_h = h + (moving + after + 2) * STEP;
    let colours = ["#dbdbdb", "#40c8e0", "#ff9f0a", "#999999", "#ff375f"];
    let mut markup = String::from("<span line_height=\"17408\">");
    for i in 0..(canvas_h / 17 + 2) {
        let line = format!(
            "{}  func refine(_ 画面: 帧, 码率 kbps: Int) -&gt; Bool {{ guard now - lastFrameAt &gt; 0.2 else {{ return false }} // 静止后补清 {}",
            1000 + i,
            (i as u64 * 7919) % 100003
        );
        markup += &format!("<span foreground=\"{}\">{}</span>\n", colours[i as usize % colours.len()], line);
    }
    markup += "</span>";
    let p = gst::parse::launch(&format!(
        "videotestsrc pattern=solid-color foreground-color=0xff1c1c1c num-buffers=1 ! video/x-raw,format=BGRx,width={w},height={canvas_h},framerate=1/1 ! \
         textoverlay name=t auto-resize=false wrap-mode=-1 valignment=top halignment=left xpad=12 ypad=0 draw-shadow=false draw-outline=false \
         font-desc=\"DejaVu Sans Mono 13px\" ! videoconvert ! video/x-raw,format=BGRx ! appsink name=s sync=false"
    ))
    .unwrap()
    .downcast::<gst::Pipeline>()
    .unwrap();
    p.by_name("t").unwrap().set_property("text", &markup);
    let s = p.by_name("s").unwrap().downcast::<gst_app::AppSink>().unwrap();
    p.set_state(gst::State::Playing).unwrap();
    let canvas: Vec<u8> = s.pull_sample().unwrap().buffer().unwrap().map_readable().unwrap().to_vec();
    p.set_state(gst::State::Null).unwrap();
    let row = w as usize * 4;
    let frame_at = |k: u32| -> Vec<u8> {
        let o = (k * STEP) as usize * row;
        canvas[o..o + h as usize * row].to_vec()
    };
    let luma = |px: &[u8]| -> Vec<f32> { px.as_chunks::<4>().0.iter().map(|q| 0.114 * q[0] as f32 + 0.587 * q[1] as f32 + 0.299 * q[2] as f32).collect() };
    let psnr = |a: &[f32], b: &[f32]| -> f64 {
        let s: f64 = a.iter().zip(b).map(|(x, y)| ((x - y) as f64).powi(2)).sum();
        let mse = s / a.len() as f64;
        if mse == 0.0 { 99.0 } else { 10.0 * (255.0f64 * 255.0 / mse).log10() }
    };
    if std::env::var_os("PROBE_DUMP").is_some() {
        std::fs::write(format!("/tmp/probe-source-{w}x{h}.bgrx"), frame_at(moving - 1)).unwrap();
    }

    // out: (unit, which frame of the canvas, when it came out)
    type Out = Arc<Mutex<Vec<(Unit, u32, Instant)>>>;
    let out: Out = Arc::default();
    let o2 = out.clone();
    let enc = Encoder::new(&element, codec, w, h, bitrate, fps_now, true, Arc::new(move |u, _crop, captured, _ms| {
        o2.lock().unwrap().push((u, captured as u32, Instant::now()));
    }))
    .unwrap_or_else(|e| panic!("{element}: {e}"));
    let capped = enc.caps_quantiser();
    if ladder && !capped {
        println!("{element}: takes no quantiser ceiling (caps_quantiser false): the server would send eight plain resends");
        std::process::exit(3);
    }
    let push = |k: u32, cap: Option<u8>, key: bool| {
        let pic = Picture { data: Arc::new(frame_at(k)), width: w, height: h, format: "BGRx", crop: Crop::WHOLE, captured: k as f64 };
        enc.push_capped(&pic, key, cap).unwrap();
        if let Some(e) = enc.error() {
            panic!("{element}: {e}");
        }
    };
    let wait_out = |n: usize, secs: f64| {
        let t = Instant::now();
        while out.lock().unwrap().len() < n && t.elapsed().as_secs_f64() < secs {
            std::thread::sleep(Duration::from_millis(1));
        }
    };

    // 1. scrolling, a second and a half at the rate
    let t0 = Instant::now();
    for k in 0..moving {
        let due = t0 + Duration::from_secs_f64(k as f64 / fps_now as f64);
        if let Some(d) = due.checked_duration_since(Instant::now()) {
            std::thread::sleep(d);
        }
        while enc.busy() {
            std::thread::sleep(Duration::from_millis(1));
        }
        push(k, None, k == 0);
    }
    wait_out(moving as usize, 2.0);
    let made_moving = out.lock().unwrap().len();
    let moving_bytes: usize = out.lock().unwrap().iter().map(|o| o.0.picture.len()).sum();
    let last_moving_bytes: usize = out.lock().unwrap().iter().rev().take(30).map(|o| o.0.picture.len()).sum::<usize>() / 30;
    let mut last_frame_at = out.lock().unwrap().last().map(|o| o.2).unwrap_or_else(Instant::now);

    // 2. still: the resends, as screen.rs's tick and frame() drive Sharpen
    let clock = Instant::now();
    let now = |at: Instant| at.duration_since(clock).as_secs_f64();
    let mut sh = Sharpen::default();
    let mut pending: Option<(u8, usize, Instant)> = None; // (cap, outputs before it, pushed at)
    let (mut tries, mut steps) = (0, vec![]); // steps: (cap, bytes, output index, at)
    // the server raises the encoder's rate to 1.5× while a still picture's resends also probe the network (rate.rs `probe`), on
    // an encoder where that costs nothing, and paces the resends at that
    let probe = enc.rate_change_is_cheap();
    let pace = if probe { bitrate as i64 * 3 / 2 } else { bitrate as i64 };
    let mut set_rate_ms = vec![];
    if probe {
        let t = Instant::now();
        enc.set_rate(bitrate * 3 / 2, fps_now);
        set_rate_ms.push(t.elapsed().as_secs_f64() * 1000.0);
    }
    let first_resend = Instant::now();
    let still = moving - 1;
    while !sh.done && first_resend.elapsed() < Duration::from_secs(30) {
        std::thread::sleep(Duration::from_micros(1_000_000 / 60));
        // a frame back from the encoder: the resend's (refresh_pending), never a moving one here
        if let Some((cap, before, _)) = pending {
            let o = out.lock().unwrap();
            if o.len() > before {
                let bytes = o[before].0.picture.len() + o[before].0.parameter_sets.iter().map(|s| s.len()).sum::<usize>() + 17;
                let at = o[before].2;
                drop(o);
                last_frame_at = last_frame_at.max(at);
                sh.sent(cap, bytes, bitrate as i64, pace, now(at));
                steps.push((cap, bytes, before, at));
                pending = None;
            }
        }
        let t = Instant::now();
        if t.duration_since(last_frame_at).as_secs_f64() <= 0.2 {
            continue;
        }
        if let Some(cap) = sh.next(now(t), ladder) {
            // a pending one that never came back was dropped by the rate control: this one replaces it
            tries += 1;
            let n = out.lock().unwrap().len();
            push(still, if cap < NO_CEILING { Some(cap) } else { None }, false);
            pending = Some((cap, n, t));
        }
    }
    // the last step's frame
    wait_out(made_moving + steps.len() + 1, 1.0);
    if let Some((cap, before, _)) = pending {
        let o = out.lock().unwrap();
        if o.len() > before {
            let bytes = o[before].0.picture.len() + 17;
            steps.push((cap, bytes, before, o[before].2));
        }
    }
    let resend_end = steps.last().map(|s| s.3).unwrap_or_else(Instant::now);
    std::thread::sleep(Duration::from_millis(300));
    if probe {
        let t = Instant::now();
        enc.set_rate(bitrate, fps_now);
        set_rate_ms.push(t.elapsed().as_secs_f64() * 1000.0);
    }

    // 3. moving again: the ceiling is off, the frames are the rate control's own
    let before_after = out.lock().unwrap().len();
    let t1 = Instant::now();
    for j in 0..after {
        let due = t1 + Duration::from_secs_f64(j as f64 / fps_now as f64);
        if let Some(d) = due.checked_duration_since(Instant::now()) {
            std::thread::sleep(d);
        }
        while enc.busy() {
            std::thread::sleep(Duration::from_millis(1));
        }
        push(moving + j, None, false);
    }
    wait_out(before_after + after as usize, 2.0);
    let all = out.lock().unwrap();
    let after_sizes: Vec<usize> = all[before_after..].iter().map(|o| o.0.picture.len()).collect();
    let keys_after = all[before_after..].iter().filter(|o| o.0.keyframe).count();
    let keys_in_steps = steps.iter().filter(|s| all[s.2].0.keyframe).count();

    // 4. decode it all and compare with the source
    let mut stream = vec![];
    for (u, _, _) in all.iter() {
        stream.extend(nal::annexb(u));
    }
    let (parse, dec, caps) = match codec {
        Codec::H264 => ("h264parse", "avdec_h264", "video/x-h264,stream-format=byte-stream,alignment=au"),
        Codec::Hevc => ("h265parse", "avdec_h265", "video/x-h265,stream-format=byte-stream,alignment=au"),
    };
    let d = gst::parse::launch(&format!(
        "appsrc name=a caps={caps} ! {parse} ! {dec} ! videoconvert ! video/x-raw,format=BGRx ! appsink name=s sync=false max-buffers=0"
    ))
    .unwrap()
    .downcast::<gst::Pipeline>()
    .unwrap();
    let a = d.by_name("a").unwrap().downcast::<gst_app::AppSrc>().unwrap();
    let s = d.by_name("s").unwrap().downcast::<gst_app::AppSink>().unwrap();
    d.set_state(gst::State::Playing).unwrap();
    a.push_buffer(gst::Buffer::from_slice(stream)).unwrap();
    a.end_of_stream().unwrap();
    let want: std::collections::HashSet<usize> = steps.iter().map(|s| s.2).chain([made_moving - 1]).collect();
    let dump = std::env::var_os("PROBE_DUMP").is_some();
    let src = luma(&frame_at(still));
    let mut db = std::collections::HashMap::new();
    let mut i = 0;
    while let Ok(sample) = s.pull_sample() {
        if want.contains(&i) {
            let px = sample.buffer().unwrap().map_readable().unwrap().to_vec();
            let src_k = all[i].1;
            let reference = if src_k == still { src.clone() } else { luma(&frame_at(src_k)) };
            db.insert(i, psnr(&reference, &luma(&px)));
            if dump && (i == *want.iter().max().unwrap() || i == made_moving - 1) {
                let what = if i == made_moving - 1 { "stop" } else { args[4].as_str() };
                std::fs::write(format!("/tmp/probe-{element}-{}-{what}-{w}.bgrx", bitrate / 1000), &px).unwrap();
            }
        }
        i += 1;
    }
    d.set_state(gst::State::Null).unwrap();
    let decoded = i;

    let at_stop = db.get(&(made_moving - 1)).copied().unwrap_or(f64::NAN);
    println!(
        "{element} {} kbps {w}×{h} {}: moving {} of {moving} frames out, {:.0} kbps made; when it stops {at_stop:.1} dB",
        bitrate / 1000,
        args[4],
        made_moving,
        moving_bytes as f64 * 8.0 / 1.5 / 1000.0
    );
    let mut total = 0;
    for (n, (cap, bytes, idx, at)) in steps.iter().enumerate() {
        total += bytes;
        println!(
            "  {:5.2}s resend {:2} {}: {:7} bytes  {:.1} dB  (so far {} KB){}",
            at.duration_since(first_resend).as_secs_f64(),
            n + 1,
            if *cap < NO_CEILING { format!("qp≤{cap}") } else { "plain".into() },
            bytes,
            db.get(idx).copied().unwrap_or(f64::NAN),
            total / 1000,
            if all[*idx].0.keyframe { "  KEYFRAME" } else { "" }
        );
    }
    let last_db = steps.last().and_then(|s| db.get(&s.2)).copied().unwrap_or(f64::NAN);
    println!(
        "SUMMARY element={element} kbps={} width={w} mode={} stop_db={at_stop:.1} end_db={last_db:.1} kb={} secs={:.2} steps={} tries={} dropped={} keyframes_in_resends={keys_in_steps} \
         moving_mean_last30={} after_first3={:?} after_mean={} keys_after={keys_after} decoded={decoded}/{} \
         rate_raised={probe} set_rate_ms={set_rate_ms:.2?} largest_kb={} kbps_over_rate={:.2}",
        bitrate / 1000,
        args[4],
        total / 1000,
        resend_end.duration_since(first_resend).as_secs_f64(),
        steps.len(),
        tries,
        tries - steps.len(),
        last_moving_bytes,
        &after_sizes[..after_sizes.len().min(3)],
        after_sizes.iter().sum::<usize>() / after_sizes.len().max(1),
        all.len(),
        steps.iter().map(|s| s.1).max().unwrap_or(0) / 1000,
        total as f64 * 8.0 / resend_end.duration_since(first_resend).as_secs_f64().max(0.001) / bitrate as f64
    );
}

#[cfg(not(target_os = "linux"))]
fn main() {
    eprintln!("linux_sharpen_probe: Linux only");
}
