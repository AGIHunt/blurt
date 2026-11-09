//! A phone for testing a host from this machine: pairs with a link, drives a key and the pointer, asks for the screen in H.264,
//! zooms half-way through, and writes what arrives, reassembled, as an Annex B file ffmpeg can decode.
//!
//!   cargo run --example phone -- --link '<blurtremote://pair?…>' [--at 127.0.0.1:PORT] [--relay ws://…] [--seconds 6] [--out f.h264]
//!
//! --measure: watch the picture as the iOS app does, with its repairs (docs/design/remote-realtime.md), through a made-up network,
//! and print what the doc measures: frames shown a second, the longest gap, age, frames given up, keyframes asked, what was mended.
//!   --loss 0.01:2      pieces lost at 1 %, in bursts of 2 on average (as BLURT_TEST_LOSS on the phone)
//!   --stall 80:2       everything held 80 ms every 2 s (BLURT_TEST_STALL)
//!   --delay 30         ms one way: a long path, so the round trip is 60 ms more (parity's territory)
//!   --repair on|off|both   offer nack/ltr/fec (on, the default), offer nothing (off: as before 1.0.15), or off then on
//!   --fps 60 --bitrate 12000000 --size 1866x1206 --warmup 1 --seconds 12

use std::io::Write;
use std::net::SocketAddr;
use std::time::{Duration, Instant};

use blurt_remote::packets::{unpack_payload, PointerPacket, VideoAssembler, VideoPacket};
use blurt_remote::pairing::Pairing;
use blurt_remote::phone::{Event, Phone, Watch, Weather};
use blurt_remote::wire::{Chord, Crop, ScreenReport, ScreenRequest, ToMac, ToPhone};

#[tokio::main]
async fn main() {
    let args: Vec<String> = std::env::args().collect();
    let arg = |n: &str| args.iter().position(|a| a == n).and_then(|i| args.get(i + 1)).cloned();
    let link = arg("--link").expect("--link");
    let p = Pairing::parse(&link).expect("a pairing link");
    let seconds: f64 = arg("--seconds").and_then(|s| s.parse().ok()).unwrap_or(6.0);
    let out = arg("--out").unwrap_or_else(|| "phone-test.h264".into());
    let mut phone = match arg("--relay") {
        Some(r) => Phone::connect_relay(&r, &p.device_id, &p.key).await.expect("relay"),
        None => {
            let at: SocketAddr = arg("--at").unwrap_or_else(|| format!("127.0.0.1:{}", p.port)).parse().unwrap();
            Phone::connect(at, &p.device_id, &p.key).await.expect("connect")
        }
    };
    println!("six digits on this phone: {}", phone.check);
    phone.wait(Duration::from_secs(5), |m| matches!(m, ToPhone::PairingWaits).then_some(())).await.expect("the host asks");
    let key = phone.wait(Duration::from_secs(130), |m| if let ToPhone::NewKey(k) = m { Some(k.clone()) } else { None }).await.expect("a yes");
    phone.send(&ToMac::KeyStored).await;
    let info = phone.wait(Duration::from_secs(5), |m| if let ToPhone::Session(i) = m { Some(i.clone()) } else { None }).await.expect("session");
    println!("session: {} ({:?}) udp {} candidates {:?} key {}", info.mac_name, info.platform, info.udp_port, info.candidates, blurt_remote::crypto::base64url(&key));
    if !phone.host.ip().is_unspecified() {
        phone.open_udp(info.udp_port, info.udp_session).await.unwrap();
    }
    if args.iter().any(|a| a == "--measure") {
        measure(&mut phone, &arg).await;
        return;
    }
    // Ctrl+C into the focused window: not with --cross, whose run on a Windows console would stop the host it's testing
    if !args.iter().any(|a| a == "--cross") {
        phone.send(&ToMac::Key { chord: Chord::new(8, "C"), down: None }).await;
    }
    phone.pointer(PointerPacket::Move { dx: 10.0, dy: 5.0 }).await;
    let cross = args.iter().any(|a| a == "--cross");
    if cross {
        // to the left edge first, so the picture starts on the leftmost display wherever the last run left the pointer
        across(&phone, -100.0).await;
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    phone
        .send(&ToMac::Screen(Some(ScreenRequest {
            target: "display".into(),
            crop: Crop::WHOLE,
            width: 1280,
            height: 800,
            bitrate: 2_000_000,
            fps: 30,
            codecs: Some(vec!["hevc".into(), "h264".into()]),
            display: None,
            features: None,
        })))
        .await;
    let mut a = VideoAssembler::new();
    let mut file = std::fs::File::create(&out).unwrap();
    let mut segment = 0;
    let (mut frames, mut keys, mut bytes, mut cursors, mut pieces) = (0i64, 0, 0usize, 0, 0);
    let t0 = Instant::now();
    let mut last_report = Instant::now();
    let mut zoomed = false;
    let (mut last_key_ask, mut key_asks): (Option<Instant>, u32) = (None, 0);
    let mut stage = 0;
    let mut displays: Vec<String> = vec![];
    while t0.elapsed().as_secs_f64() < seconds {
        if last_report.elapsed() > Duration::from_secs(1) {
            last_report = Instant::now();
            phone.send(&ToMac::ScreenReport(ScreenReport { frames, lost: a.dropped as i64, rtt: Some(0.01), received: bytes as i64 })).await;
            phone.send(&ToMac::Ping(t0.elapsed().as_secs_f64())).await;
        }
        // as the iOS app does: while a frame was lost (or none has come yet), ask for a keyframe, at most 4 times a second
        if (a.waiting_for_key || frames == 0) && last_key_ask.is_none_or(|t: Instant| t.elapsed() >= Duration::from_millis(250)) {
            last_key_ask = Some(Instant::now());
            key_asks += 1;
            phone.send(&ToMac::RequestKeyframe).await;
        }
        let el = t0.elapsed().as_secs_f64();
        if cross {
            // several displays: the pointer across to the next one (the picture follows); pinned to the first (the picture goes
            // there) and the pointer across again (it stays); following again (to where the pointer is)
            if stage == 0 && el > seconds * 0.2 {
                stage = 1;
                println!("{el:.2}s across");
                across(&phone, 100.0).await;
            } else if stage == 1 && el > seconds * 0.4 {
                stage = 2;
                println!("{el:.2}s pin {:?}", displays.first());
                phone.send(&ToMac::ShowDisplay(displays.first().cloned())).await;
            } else if stage == 2 && el > seconds * 0.55 {
                stage = 3;
                println!("{el:.2}s across, pinned");
                across(&phone, 100.0).await;
            } else if stage == 3 && el > seconds * 0.75 {
                stage = 4;
                println!("{el:.2}s follow");
                phone.send(&ToMac::ShowDisplay(None)).await;
            }
        } else if !zoomed && el > seconds / 2.0 {
            zoomed = true;
            phone.send(&ToMac::ScreenCrop(Crop { x: 0.25, y: 0.25, w: 0.5, h: 0.5 })).await;
        }
        match phone.next(Duration::from_millis(100)).await {
            Some(Event::Video(v)) => {
                pieces += 1;
                let Some(pk) = VideoPacket::decode(&v) else { continue };
                if let Some(f) = a.add(pk) {
                    let pl = unpack_payload(&f.data).expect("payload");
                    frames += 1;
                    bytes += f.data.len();
                    if f.keyframe {
                        keys += 1;
                        for s in &pl.parameter_sets {
                            file.write_all(&[0, 0, 0, 1]).unwrap();
                            file.write_all(s).unwrap();
                        }
                    }
                    let mut at = 0;
                    while at + 4 <= pl.picture.len() {
                        let n = u32::from_be_bytes(pl.picture[at..at + 4].try_into().unwrap()) as usize;
                        file.write_all(&[0, 0, 0, 1]).unwrap();
                        file.write_all(&pl.picture[at + 4..at + 4 + n]).unwrap();
                        at += 4 + n;
                    }
                }
            }
            Some(Event::Cursor(..)) => cursors += 1,
            Some(Event::Control(ToPhone::ScreenView { width, height, codec, display, .. })) => {
                println!("{:.2}s screen {width}×{height} {codec:?} {display:?}", t0.elapsed().as_secs_f64());
                // each new picture (another display) in a file of its own: <out>.1, .2 …
                segment += 1;
                if segment > 1 {
                    file = std::fs::File::create(format!("{out}.{}", segment - 1)).unwrap();
                }
            }
            Some(Event::Control(ToPhone::Displays(l))) => {
                displays = l.iter().map(|d| d.id.clone()).collect();
                println!("displays {:?}", l.iter().map(|d| format!("{} {}×{} at {},{}{}", d.id, d.width, d.height, d.x, d.y, if d.main { " main" } else { "" })).collect::<Vec<_>>());
            }
            Some(Event::Control(ToPhone::ScreenFailed(w))) => {
                println!("screen failed: {w}");
                break;
            }
            Some(Event::Closed) => break,
            _ => {}
        }
    }
    phone.send(&ToMac::Screen(None)).await;
    tokio::time::sleep(Duration::from_millis(200)).await;
    println!("frames {frames} keyframes {keys} pieces {pieces} bytes {bytes} dropped {} keyframes asked {key_asks} cursor {cursors} → {out}", a.dropped);
}

/// --measure: one run per --repair setting, each printed as one line.
async fn measure(phone: &mut Phone, arg: &dyn Fn(&str) -> Option<String>) {
    let num = |k: &str, d: f64| arg(k).and_then(|v| v.parse::<f64>().ok()).unwrap_or(d);
    let (w, h) = arg("--size")
        .and_then(|s| s.split_once('x').and_then(|(a, b)| Some((a.parse().ok()?, b.parse().ok()?))))
        .unwrap_or((1866i64, 1206i64));
    let runs: &[bool] = match arg("--repair").as_deref() {
        Some("off") => &[false],
        Some("both") => &[false, true],
        _ => &[true],
    };
    for (i, repair) in runs.iter().enumerate() {
        let mut weather = Weather::parse(arg("--loss").as_deref(), arg("--stall").as_deref(), 7 + i as u64);
        weather.delay = num("--delay", 0.0) / 1000.0;
        let request = ScreenRequest {
            target: "display".into(),
            crop: Crop::WHOLE,
            width: w,
            height: h,
            bitrate: num("--bitrate", 12_000_000.0) as i64,
            fps: num("--fps", 60.0) as i64,
            codecs: Some(vec!["hevc".into(), "h264".into()]),
            display: None,
            features: repair.then(|| blurt_remote::repair::ALL.iter().map(|s| s.to_string()).collect()),
        };
        let m = phone.watch(Watch { request, warmup: num("--warmup", 1.0), seconds: num("--seconds", 12.0), weather, verify: None }).await;
        println!("repair {}: {m}", if *repair { "on" } else { "off" });
        tokio::time::sleep(Duration::from_millis(500)).await;
    }
}

/// 2,400 pt sideways (past a 1080p display), in 24 moves.
async fn across(phone: &Phone, dx: f32) {
    for _ in 0..24 {
        phone.pointer(PointerPacket::Move { dx, dy: 0.0 }).await;
    }
}
