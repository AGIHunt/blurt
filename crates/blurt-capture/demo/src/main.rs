//! Test harness for blurt-capture (CI under xvfb, local smoke tests). Prints JSON lines on stdout.
//!
//!   blurt-capture-demo overlays [--box x,y,w,h] [--seconds 20]
//!       HUD (fed demo status lines), perch with two cards, note bubble. Without --box they are placed as in the
//!       app (HUD bottom-centre, perch at the top, note under it); with --box all three go inside that physical
//!       rect; --backdrop puts an opaque orange always-on-top window of ours under them first (a screenshot of the
//!       box then holds only our pixels). Prints {"windows": {label: [x,y,w,h]}}.
//!   blurt-capture-demo record --record-py PATH --session DIR [--region x,y,w,h] [--seconds 5] [--fake]
//!       a real take through overlay::record (HUD + perch): snap after 1.5 s, stop after --seconds.
//!       Prints {"final": <status line>, "cards": [...]}; exit 0 when the take was kept.
//!   blurt-capture-demo pick       the region picker; prints {"picked": "x,y,w,h" | null}

use blurt_capture::overlay::{self, Card, Kind, OverlayConfig};
use blurt_capture::{CaptureOptions, Launcher, Mic, Region, StatusEvent};
use serde_json::json;
use std::collections::BTreeMap;
use std::path::PathBuf;
use std::thread;
use std::time::Duration;
use tauri::{AppHandle, Emitter, Manager, Wry};

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
    Card { n, src: format!("data:image/svg+xml,{enc}"), text: text.map(str::to_string), file: None }
}

fn rect_of(app: &AppHandle<Wry>, k: Kind) -> Option<[i64; 4]> {
    let w = app.get_webview_window(k.label())?;
    let p = w.outer_position().ok()?;
    let s = w.outer_size().ok()?;
    Some([p.x as i64, p.y as i64, s.width as i64, s.height as i64])
}

fn overlays(app: AppHandle<Wry>) {
    let cfg = OverlayConfig::default();
    let secs: u64 = arg("--seconds").and_then(|s| s.parse().ok()).unwrap_or(20);
    let boxed: Option<Region> = arg("--box").and_then(|s| s.parse().ok());
    let _perch_keep;
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
    if let Some(b) = boxed {
        // everything inside the box: perch along its top, HUD at its bottom, note in the middle
        let s = app.primary_monitor().ok().flatten().map(|m| m.scale_factor()).unwrap_or(1.0);
        let px = |v: f64| (v * s).round() as u32;
        let open = |k: Kind, r: Region, p: BTreeMap<&str, String>| overlay::open(&app, k, &cfg, r, p).unwrap();
        open(Kind::Perch, Region::new(b.x, b.y, b.w, px(230.0)), BTreeMap::new());
        let mut hp = BTreeMap::new();
        hp.insert("mic", "1".to_string());
        let hud = (px(420.0), px(56.0));
        open(Kind::Hud, Region::new(b.right() - hud.0 as i32 - px(16.0) as i32, b.bottom() - hud.1 as i32 - px(16.0) as i32, hud.0, hud.1), hp);
        let mut np = BTreeMap::new();
        np.insert("n", "2".to_string());
        np.insert("text", "demo note".to_string());
        np.insert("src", svg_card(2, 25, None).src);
        open(Kind::Note, Region::new(b.x + px(16.0) as i32, b.y + px(200.0) as i32, px(440.0), px(360.0)), np);
        thread::sleep(Duration::from_millis(1500));
        let cards = vec![svg_card(1, 210, Some("Save button too faint")), svg_card(2, 25, None), svg_card(3, 140, Some("search here"))];
        let _ = app.emit_to(Kind::Perch.label(), overlay::ev::PERCH, json!({"op": "set", "cards": cards}));
        let _ = app.emit_to(Kind::Perch.label(), overlay::ev::PERCH, json!({"op": "show", "hold": 0}));
        _perch_keep = None;
    } else {
        let perch = overlay::perch(&app, &cfg).expect("perch");
        overlay::hud(&app, &cfg, None, true).expect("hud");
        let card = svg_card(3, 140, Some("search here"));
        overlay::note(&app, &cfg, &card, None, |t| emit_line(json!({"note": t}))).expect("note");
        thread::sleep(Duration::from_millis(1500));
        perch.add(svg_card(1, 210, Some("Save button too faint")));
        perch.add(svg_card(2, 25, None));
        perch.add(card);
        perch.show(0);
        _perch_keep = Some(perch);
    }
    let hud = Kind::Hud.label();
    let t0 = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs_f64();
    let _ = app.emit_to(hud, overlay::ev::STATUS, json!({"ev": "started", "t0": t0}));
    let _ = app.emit_to(hud, overlay::ev::STATUS, json!({"ev": "snap", "n": 3, "file": "shots/003.png"}));
    let app2 = app.clone();
    thread::spawn(move || {
        for k in 0.. {
            let rms = 0.02 + 0.1 * ((k as f64) / 3.0).sin().abs();
            if app2.emit_to(hud, overlay::ev::STATUS, json!({"ev": "level", "rms": rms})).is_err() {
                break;
            }
            thread::sleep(Duration::from_millis(100));
        }
    });
    thread::sleep(Duration::from_millis(1500)); // let the drop / swing settle
    let windows: serde_json::Map<String, serde_json::Value> = [Kind::Hud, Kind::Perch, Kind::Note]
        .into_iter()
        .filter_map(|k| rect_of(&app, k).map(|r| (k.label().to_string(), json!(r))))
        .collect();
    emit_line(json!({"windows": windows}));
    thread::sleep(Duration::from_secs(secs));
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
    let cfg = OverlayConfig::default();
    let perch = overlay::perch(&app, &cfg).expect("perch");
    let (tx, rx) = std::sync::mpsc::channel();
    let handle = overlay::record(&app, &cfg, opts, Some(perch.clone()), move |r| {
        let _ = tx.send(r);
    })
    .expect("start");
    thread::sleep(Duration::from_millis(1500));
    if let Some(r) = rect_of(&app, Kind::Hud) {
        emit_line(json!({"windows": {Kind::Hud.label(): r}}));
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
    emit_line(json!({"final": fin, "cards": perch.cards()}));
    thread::sleep(Duration::from_millis(500));
    app.exit(if ok { 0 } else { 1 });
}

fn pick(app: AppHandle<Wry>) {
    let r = overlay::pick_region(&app, &OverlayConfig::default(), None).ok().flatten();
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
