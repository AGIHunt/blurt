//! On a Windows test machine with the system service on: drive its agent as Blurt would (from the console session) and keep what it
//! sends. `agent_probe <seconds> <out.h264> [type|sas]`: the picture as Annex B H.264 (ffmpeg makes stills of it), and with `type` the
//! letters Q W E typed (after Ctrl+Alt+Del with `sas`) into whatever has the keyboard (the lock screen's password box shows three dots).
#[cfg(windows)]
fn main() {
    use std::io::Write;
    use std::sync::{Arc, Mutex};
    use blurt_remote::host::{Backend, Crop, ScreenConfig};
    let args: Vec<String> = std::env::args().skip(1).collect();
    let secs: u64 = args.first().and_then(|s| s.parse().ok()).unwrap_or(5);
    let out = args.get(1).cloned().unwrap_or_else(|| "agent.h264".into());
    let typing = args.get(2).is_some_and(|a| a == "type" || a == "sas" || a == "enter");
    let enter = args.get(2).is_some_and(|a| a == "enter");
    let uac = args.get(2).is_some_and(|a| a == "uac");
    let sas = args.get(2).is_some_and(|a| a == "sas" || a == "enter");
    let Some(mut p) = blurt_remote::platform::windows::service::connect() else {
        eprintln!("no agent: is the service on, and is this the console session?");
        std::process::exit(1);
    };
    println!("platform {} can_control {} displays {:?}", p.platform(), p.input().can_control(), p.displays().iter().map(|d| &d.id).collect::<Vec<_>>());
    let file = Arc::new(Mutex::new(std::fs::File::create(&out).unwrap()));
    let count = Arc::new(Mutex::new((0usize, 0usize)));
    let (f, c) = (file.clone(), count.clone());
    let cfg = ScreenConfig { width: 1280, height: 720, bitrate: 4_000_000, fps: 30, codecs: vec!["h264".into()], crop: Crop::WHOLE, display: None, capture_fps: 30, repairs: false };
    let info = p.screen().unwrap().start(&cfg, Arc::new(move |fr| {
        let mut w = f.lock().unwrap();
        for ps in &fr.parameter_sets {
            let _ = w.write_all(&[0, 0, 0, 1]);
            let _ = w.write_all(ps);
        }
        let mut at = 0;
        while at + 4 <= fr.picture.len() {
            let n = u32::from_be_bytes(fr.picture[at..at + 4].try_into().unwrap()) as usize;
            let _ = w.write_all(&[0, 0, 0, 1]);
            let _ = w.write_all(&fr.picture[at + 4..(at + 4 + n).min(fr.picture.len())]);
            at += 4 + n;
        }
        let mut k = c.lock().unwrap();
        k.0 += 1;
        if fr.keyframe { k.1 += 1; }
    }));
    println!("started {info:?}");
    std::thread::sleep(std::time::Duration::from_secs(1));
    p.screen().unwrap().keyframe();
    if uac {
        // the UAC prompt's Yes: Alt+Y
        std::thread::sleep(std::time::Duration::from_secs(2));
        p.screen().unwrap().keyframe();
        std::thread::sleep(std::time::Duration::from_millis(500));
        p.input().key("Y", blurt_remote::host::mods::OPTION, None);
        println!("pressed Alt+Y");
    }
    if sas {
        p.input().system(blurt_remote::host::SystemMove::SecureAttention);
        println!("sent Ctrl+Alt+Del");
        std::thread::sleep(std::time::Duration::from_secs(2));
        p.screen().unwrap().keyframe();
    }
    if typing {
        for k in ["Q", "W", "E"] {
            p.input().key(k, 0, None);
            std::thread::sleep(std::time::Duration::from_millis(150));
        }
        println!("typed QWE");
        if enter {
            p.input().key("Return", 0, None);
            println!("pressed Return");
        }
    }
    // a keyframe a second, so a still screen still shows up, and frames per second are counted
    for i in 0..secs {
        std::thread::sleep(std::time::Duration::from_secs(1));
        p.screen().unwrap().keyframe();
        let k = count.lock().unwrap();
        println!("t={} frames {}", i + 1, k.0);
    }
    p.screen().unwrap().stop();
    let k = count.lock().unwrap();
    println!("frames {} keyframes {}", k.0, k.1);
}

#[cfg(not(windows))]
fn main() {
    eprintln!("Windows only");
}
