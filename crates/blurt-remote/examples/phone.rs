//! A phone for testing a host from this machine: pairs with a link, drives a key and the pointer, asks for the screen in H.264,
//! zooms half-way through, and writes what arrives, reassembled, as an Annex B file ffmpeg can decode.
//!
//!   cargo run --example phone -- --link '<blurtremote://pair?…>' [--at 127.0.0.1:PORT] [--relay ws://…] [--seconds 6] [--out f.h264]

use std::io::Write;
use std::net::SocketAddr;
use std::time::{Duration, Instant};

use blurt_remote::packets::{unpack_payload, PointerPacket, VideoAssembler, VideoPacket};
use blurt_remote::pairing::Pairing;
use blurt_remote::phone::{Event, Phone};
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
    phone.send(&ToMac::Key { chord: Chord::new(8, "C"), down: None }).await;
    phone.pointer(PointerPacket::Move { dx: 10.0, dy: 5.0 }).await;
    phone
        .send(&ToMac::Screen(Some(ScreenRequest {
            target: "display".into(),
            crop: Crop::WHOLE,
            width: 1280,
            height: 800,
            bitrate: 2_000_000,
            fps: 30,
            codecs: Some(vec!["hevc".into(), "h264".into()]),
        })))
        .await;
    let mut a = VideoAssembler::new();
    let mut file = std::fs::File::create(&out).unwrap();
    let (mut frames, mut keys, mut bytes, mut cursors, mut pieces) = (0i64, 0, 0usize, 0, 0);
    let t0 = Instant::now();
    let mut last_report = Instant::now();
    let mut zoomed = false;
    while t0.elapsed().as_secs_f64() < seconds {
        if last_report.elapsed() > Duration::from_secs(1) {
            last_report = Instant::now();
            phone.send(&ToMac::ScreenReport(ScreenReport { frames, lost: a.dropped as i64, rtt: Some(0.01), received: bytes as i64 })).await;
            phone.send(&ToMac::Ping(t0.elapsed().as_secs_f64())).await;
        }
        if !zoomed && t0.elapsed().as_secs_f64() > seconds / 2.0 {
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
            Some(Event::Control(ToPhone::ScreenView { width, height, codec })) => println!("screen {width}×{height} {codec:?}"),
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
    println!("frames {frames} keyframes {keys} pieces {pieces} bytes {bytes} dropped {} cursor {cursors} → {out}", a.dropped);
}
