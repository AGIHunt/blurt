//! The Rust side of C8 against the real record.py: start → snap → pause → resume → stop through the handle.
//! Screen: ffmpeg's lavfi test source (BLURT_FAKE_SCREEN), or the real one with BLURT_CAPTURE_REAL=1 (CI: x11grab
//! under xvfb). No microphone. Skips when python3/python or ffmpeg is missing.

use blurt_capture::{start, CaptureOptions, CaptureState, Launcher, Mic, Region, StatusEvent};
use std::path::PathBuf;
use std::sync::mpsc;
use std::time::Duration;

fn record_py() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../skills/blurt/scripts/record.py")
}

fn python() -> Option<Launcher> {
    let ff = if cfg!(windows) { "ffmpeg.exe" } else { "ffmpeg" };
    let on_path = |n: &str| {
        std::env::split_paths(&std::env::var_os("PATH")?).map(|d| d.join(n)).find(|p| p.is_file())
    };
    on_path(ff)?;
    let py = ["python3", "python"]
        .iter()
        .find_map(|p| on_path(&if cfg!(windows) { format!("{p}.exe") } else { p.to_string() }))?;
    Some(Launcher::python(py, record_py()))
}

fn next(rx: &mpsc::Receiver<StatusEvent>, want: &str) -> StatusEvent {
    loop {
        let e = rx.recv_timeout(Duration::from_secs(40)).unwrap_or_else(|_| panic!("no {want:?} line"));
        let j = e.to_json();
        if j["ev"] == want {
            return e;
        }
        assert!(!e.is_final(), "wanted {want}, got final {j}");
    }
}

#[test]
fn record_snap_pause_resume_stop() {
    let Some(launcher) = python() else {
        eprintln!("skipped: needs python + ffmpeg");
        return;
    };
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().join("home");
    std::fs::create_dir_all(&home).unwrap();
    std::fs::write(home.join("config.json"), r#"{"record": {"install_app": false, "live": false}}"#).unwrap();
    let mut opts = CaptureOptions::new(launcher, tmp.path().join("session"));
    opts.region = Some(Region::new(0, 0, 321, 241));
    opts.mic = Mic::None;
    opts.fps = Some(15);
    opts.env.push(("BLURT_HOME".into(), home.into_os_string()));
    if std::env::var("BLURT_CAPTURE_REAL").as_deref() != Ok("1") {
        opts.env.push(("BLURT_FAKE_SCREEN".into(), "1".into()));
    }
    let (tx, rx) = mpsc::channel();
    let mut h = start(&opts, move |e| {
        let _ = tx.send(e.clone());
    })
    .unwrap();

    let StatusEvent::Started { t0 } = next(&rx, "started") else { unreachable!() };
    assert!(t0 > 1.7e9);
    assert_eq!(h.state(), CaptureState::Recording);
    std::thread::sleep(Duration::from_millis(1200));
    h.snap().unwrap();
    let StatusEvent::Snap { n, file, .. } = next(&rx, "snap") else { unreachable!() };
    assert_eq!((n, file.as_str()), (1, "shots/001.png"));
    h.pause().unwrap();
    next(&rx, "paused");
    assert_eq!(h.state(), CaptureState::Paused);
    h.resume().unwrap();
    next(&rx, "resumed");
    std::thread::sleep(Duration::from_millis(1200));
    let fin = h.stop_and_wait(Duration::from_secs(90)).unwrap();
    let StatusEvent::Stopped { video, duration, shots } = fin else { panic!("{fin:?}\n{}", h.stderr_tail()) };
    assert_eq!((video.as_str(), shots), ("recording.mp4", Some(1)));
    assert!(duration.unwrap() > 1.5);
    assert_eq!(h.state(), CaptureState::Finished);
    let s = h.session();
    for f in ["recording.mp4", "events.jsonl", "meta.json", "shots.jsonl", "shots/001.png"] {
        assert!(s.join(f).is_file(), "{f}");
    }
    let line: serde_json::Value =
        serde_json::from_str(std::fs::read_to_string(s.join("shots.jsonl")).unwrap().lines().next().unwrap()).unwrap();
    assert_eq!(line["file"], "shots/001.png");
    assert_eq!(line["region"], serde_json::json!([0, 0, 320, 240]));
}

#[test]
fn discard_and_error_end_the_stream() {
    let Some(launcher) = python() else { return };
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().join("home");
    std::fs::create_dir_all(&home).unwrap();
    std::fs::write(home.join("config.json"), r#"{"record": {"install_app": false, "live": false}}"#).unwrap();
    let mut opts = CaptureOptions::new(launcher.clone(), tmp.path().join("s1"));
    opts.mic = Mic::None;
    opts.region = Some(Region::new(0, 0, 200, 120));
    opts.env = vec![("BLURT_HOME".into(), home.clone().into_os_string()), ("BLURT_FAKE_SCREEN".into(), "1".into())];
    let (tx, rx) = mpsc::channel();
    let mut h = start(&opts, move |e| {
        let _ = tx.send(e.clone());
    })
    .unwrap();
    next(&rx, "started");
    h.discard().unwrap();
    assert_eq!(h.wait(Duration::from_secs(60)).unwrap(), StatusEvent::Discarded);
    assert!(!h.session().join("recording.mp4").exists());

    // record.py refusing its arguments (argparse, before any status line): the handle reports stderr
    let mut bad = opts.clone();
    bad.session = tmp.path().join("s2");
    bad.launcher.args.push("--no-such-flag".into());
    let mut h = start(&bad, |_| {}).unwrap();
    match h.wait(Duration::from_secs(60)) {
        Err(blurt_capture::CaptureError::Recorder(msg)) => assert!(msg.contains("no-such-flag"), "{msg}"),
        other => panic!("{other:?}"),
    }
}
