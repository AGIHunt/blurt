//! Test harness for blurt-capture (CI under xvfb, local smoke tests). Prints JSON lines on stdout.
//!
//!   blurt-capture-demo overlays [--box x,y,w,h] [--seconds 20] [--backdrop]
//!       the island (expanded, with a project, an active job and three cards held by the claw) and a note bubble.
//!       Without --box they are placed as in the app (island along the top, note under it); with --box both go
//!       inside that physical rect; --backdrop puts an opaque orange always-on-top window of ours under them first
//!       (a screenshot of the box then holds only our pixels). Prints {"windows": {label: [x,y,w,h]}}.
//!   blurt-capture-demo record --record-py PATH --session DIR [--region x,y,w,h] [--seconds 5] [--fake]
//!       a real take through engine::record with the island showing it: snap after 1.5 s, stop after --seconds.
//!       Prints {"final": <status line>, "snaps": n}; exit 0 when the take was kept.
//!   blurt-capture-demo pick       the region picker; prints {"picked": "x,y,w,h" | null}

use blurt_capture::overlay::{self, Card, Kind, OverlayConfig};
use blurt_capture::{CaptureOptions, Launcher, Mic, Region, StatusEvent};
use serde_json::json;
use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::Duration;
use tauri::{AppHandle, Manager, Wry};

fn arg(name: &str) -> Option<String> {
    let a: Vec<String> = std::env::args().collect();
    a.iter().position(|x| x == name).and_then(|i| a.get(i + 1).cloned())
}

fn flag(name: &str) -> bool {
    std::env::args().any(|x| x == name)
}

fn emit_line(v: serde_json::Value) {
    println!("{v}");
}

fn svg_card(n: u32, hue: u32, text: Option<&str>) -> Card {
    let svg = format!(
        "<svg xmlns='http://www.w3.org/2000/svg' width='240' height='156'><rect width='240' height='156' fill='hsl({hue} 55% 55%)'/><rect x='18' y='44' width='200' height='90' rx='6' fill='white' opacity='.5'/></svg>"
    );
    let enc: String = svg
        .bytes()
        .map(|b| if b.is_ascii_alphanumeric() { (b as char).to_string() } else { format!("%{b:02X}") })
        .collect();
    Card { n, src: format!("data:image/svg+xml,{enc}"), text: text.map(str::to_string), file: None, kind: "shot".into(), session: None }
}

fn rect_of(app: &AppHandle<Wry>, k: Kind) -> Option<[i64; 4]> {
    let w = app.get_webview_window(k.label())?;
    let p = w.outer_position().ok()?;
    let s = w.outer_size().ok()?;
    Some([p.x as i64, p.y as i64, s.width as i64, s.height as i64])
}

/// What the app sends the island at rest (the island page's `IslandState`).
fn demo_state(recording: bool) -> serde_json::Value {
    let t0 = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs_f64() - 74.0;
    json!({"op": "state", "state": {
        "project": {"id": "p1", "name": "bug-agent", "key": "BA"},
        "projects": [{"id": "p1", "name": "bug-agent", "key": "BA"}, {"id": "p2", "name": "airank", "key": "AIR"}],
        "toReview": 5,
        "recording": if recording { json!({"t0": t0, "paused": false, "shots": 2}) } else { json!(null) },
        "jobs": [{"id": "j1", "type": "process", "title": "Pricing page walkthrough", "step": "write", "progress": 0.6}],
        "sessions": [{"job": "j2", "agent": "Claude Code", "status": "waiting_input", "items": ["BA-12"]}],
        "hotkeys": {"record": "Alt+Shift+R", "snap": "Alt+Shift+A", "voice": "Alt+Shift+V", "project": "Alt+Shift+O"},
        "expanded": !recording,
    }})
}

fn overlays(app: AppHandle<Wry>) {
    let cfg = OverlayConfig::default();
    let secs: u64 = arg("--seconds").and_then(|s| s.parse().ok()).unwrap_or(20);
    let boxed: Option<Region> = arg("--box").and_then(|s| s.parse().ok());
    if let (Some(b), true) = (boxed, flag("--backdrop")) {
        // an opaque always-on-top window of ours under the overlays: a screenshot of the box shows only our pixels
        let s = app.primary_monitor().ok().flatten().map(|m| m.scale_factor()).unwrap_or(1.0);
        let url = tauri::WebviewUrl::External("about:blank".parse().unwrap());
        let w = tauri::WebviewWindowBuilder::new(&app, "demo-backdrop", url)
            .decorations(false)
            .always_on_top(true)
            .focusable(false)
            .skip_taskbar(true)
            .background_color(tauri::webview::Color(232, 64, 12, 255))
            .position(b.x as f64 / s, b.y as f64 / s)
            .inner_size(b.w as f64 / s, b.h as f64 / s)
            .build()
            .expect("backdrop");
        let _ = w.set_position(tauri::PhysicalPosition::new(b.x, b.y));
        thread::sleep(Duration::from_millis(500));
    }
    let island = overlay::island(&app, &cfg).expect("island");
    let card = svg_card(3, 140, Some("search here"));
    if let Some(b) = boxed {
        // everything inside the box: the island along its top, the note in its lower half
        let s = app.primary_monitor().ok().flatten().map(|m| m.scale_factor()).unwrap_or(1.0);
        let px = |v: f64| (v * s).round() as u32;
        let w = island.window();
        let _ = w.set_position(tauri::PhysicalPosition::new(b.x, b.y));
        let _ = w.set_size(tauri::PhysicalSize::new(b.w, px(overlay::ISLAND_H).min(b.h)));
        let mut np = BTreeMap::new();
        np.insert("n", "2".to_string());
        np.insert("text", "demo note".to_string());
        np.insert("src", svg_card(2, 25, None).src);
        overlay::open(&app, Kind::Note, &cfg, Region::new(b.x + px(16.0) as i32, b.bottom() - px(376.0) as i32, px(440.0), px(360.0)), np).expect("note");
    } else {
        overlay::note(&app, &cfg, &card, None, |t| emit_line(json!({"note": t}))).expect("note");
    }
    thread::sleep(Duration::from_millis(1500));
    island.send(demo_state(false));
    island.send(json!({"op": "cards", "cards": [svg_card(1, 210, Some("Save button too faint")), svg_card(2, 25, None), card]}));
    thread::sleep(Duration::from_millis(2000)); // let the cards fly up and the swing settle
    let windows: serde_json::Map<String, serde_json::Value> = [Kind::Island, Kind::Note]
        .into_iter()
        .filter_map(|k| rect_of(&app, k).map(|r| (k.label().to_string(), json!(r))))
        .collect();
    emit_line(json!({"windows": windows}));
    thread::sleep(Duration::from_secs(secs));
    drop(island);
    app.exit(0);
}

fn record(app: AppHandle<Wry>) {
    let record_py = PathBuf::from(arg("--record-py").expect("--record-py"));
    let session = PathBuf::from(arg("--session").expect("--session"));
    let secs: f64 = arg("--seconds").and_then(|s| s.parse().ok()).unwrap_or(5.0);
    let launcher = Launcher::detect(&record_py).expect("uv or python on PATH");
    let mut opts = CaptureOptions::new(launcher, &session);
    opts.region = arg("--region").and_then(|s| s.parse().ok());
    opts.mic = Mic::None;
    opts.fps = Some(15);
    if let Some(h) = arg("--home") {
        opts.env.push(("BLURT_HOME".into(), h.into()));
    }
    if flag("--fake") {
        opts.env.push(("BLURT_FAKE_SCREEN".into(), "1".into()));
    }
    let island = overlay::island(&app, &OverlayConfig::default()).expect("island");
    island.send(demo_state(true));
    let snaps = Arc::new(AtomicU32::new(0));
    let (tx, rx) = std::sync::mpsc::channel();
    let (i2, s2) = (island.clone(), snaps.clone());
    let handle = blurt_capture::record(
        &opts,
        move |e| {
            if let StatusEvent::Snap { .. } = e {
                s2.fetch_add(1, Ordering::SeqCst);
            }
            i2.send(json!({"op": "status", "line": e.to_json()}));
        },
        move |r| {
            let _ = tx.send(r);
        },
    )
    .expect("start");
    thread::sleep(Duration::from_millis(1500));
    if let Some(r) = rect_of(&app, Kind::Island) {
        emit_line(json!({"windows": {Kind::Island.label(): r}}));
    }
    let _ = handle.lock().unwrap().snap();
    thread::sleep(Duration::from_secs_f64((secs - 1.5).max(1.0)));
    let _ = handle.lock().unwrap().stop();
    let result = rx.recv_timeout(Duration::from_secs(90));
    let ok = matches!(result, Ok(Ok(StatusEvent::Stopped { .. })));
    let fin = match result {
        Ok(Ok(e)) => e.to_json(),
        Ok(Err(e)) => json!({"error": e.to_string(), "stderr": handle.lock().unwrap().stderr_tail()}),
        Err(_) => json!({"error": "timeout"}),
    };
    emit_line(json!({"final": fin, "snaps": snaps.load(Ordering::SeqCst)}));
    thread::sleep(Duration::from_millis(500));
    app.exit(if ok { 0 } else { 1 });
}

fn pick(app: AppHandle<Wry>) {
    let r = overlay::pick_region(&app, &OverlayConfig::default(), None, overlay::Purpose::Record).ok().flatten();
    emit_line(json!({"picked": r.map(|r| r.to_string())}));
    app.exit(0);
}

fn main() {
    let mode = std::env::args().nth(1).unwrap_or_else(|| "overlays".into());
    tauri::Builder::default()
        .setup(move |app| {
            let h = app.handle().clone();
            #[cfg(target_os = "macos")]
            app.set_activation_policy(tauri::ActivationPolicy::Accessory);
            thread::spawn(move || match mode.as_str() {
                "record" => record(h),
                "pick" => pick(h),
                _ => overlays(h),
            });
            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("tauri app")
        .run(|_, e| {
            if let tauri::RunEvent::ExitRequested { api, code: None, .. } = e {
                api.prevent_exit(); // no windows yet / overlays closed: keep running until the scenario exits
            }
        });
}
