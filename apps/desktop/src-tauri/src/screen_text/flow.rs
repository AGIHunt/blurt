//! Copy Text from Screen (Alt+Shift+C) and its translation (Alt+Shift+T) on Windows — the Mac's ScreenTextCopy (⌥C /
//! ⌥T; docs/design/screen-text.md): drag over the text, it is read on this PC (Windows' OCR + rules.rs) and copied;
//! the translation goes through the cloud model connected for translation (polish.py serve `translate`), copied too
//! and shown under the island for a moment. A cloud model reading the picture again (the Mac's second reading) isn't
//! here yet.

use std::time::Duration;

use serde_json::json;
use tauri::{AppHandle, Manager};

use super::ocr_win;
use crate::dictation::{cloud, insert_win, server};
use crate::{capture, island, AppState};

fn toast(app: &AppHandle, msg: &str, vars: serde_json::Value) {
    island::send(
        app,
        json!({"op": "toast", "kind": "dictation", "msg": msg, "vars": vars}),
    );
}

const OCR: &str = "screen-ocr";

/// The picture read by screen_ocr.py's warm server: one word per line (its whole text and box), in the grab's pixels.
fn rapid(g: &ocr_win::Grab) -> Option<Vec<super::rules::Line>> {
    if !server::wait_ready(OCR, Duration::from_secs(25)) {
        return None;
    }
    let path = std::env::temp_dir().join(format!("blurt-screen-{}.bmp", std::process::id()));
    ocr_win::write_bmp(&path, g).ok()?;
    let v = server::call(
        OCR,
        &json!({"cmd": "ocr", "image": path.to_string_lossy()}),
        Duration::from_secs(20),
        None,
    );
    let _ = std::fs::remove_file(&path);
    let v = v.filter(|v| v["ok"] == json!(true))?;
    let lines = v["lines"].as_array()?;
    Some(
        lines
            .iter()
            .filter_map(|l| {
                let b = l["box"].as_array()?;
                let f = |i: usize| b.get(i).and_then(|x| x.as_f64()).unwrap_or(0.0);
                let text = l["text"].as_str()?.to_string();
                Some(super::line_from_text(
                    &text,
                    super::rules::Rect::new(f(0), f(1), f(2), f(3)),
                ))
            })
            .collect(),
    )
}

pub fn start(app: &AppHandle, translate: bool) {
    let app = app.clone();
    std::thread::spawn(move || {
        // the reader warms while the user drags (the first use loads it: ~1 s)
        {
            let runner = app.state::<AppState>().runner();
            std::thread::spawn(move || {
                let _ = server::ensure(&runner, OCR, "screen_ocr.py", &["--preload"]);
            });
        }
        let cfg = capture::overlay_config();
        let purpose = if translate {
            blurt_capture::overlay::Purpose::Translate
        } else {
            blurt_capture::overlay::Purpose::Text
        };
        let Ok(Some(r)) = blurt_capture::overlay::pick_region(&app, &cfg, None, purpose) else {
            return;
        };
        // the picker's window is gone; give the screen a frame to repaint without it
        std::thread::sleep(Duration::from_millis(60));
        let grab = match ocr_win::grab(r.x, r.y, r.w, r.h) {
            Ok(g) => g,
            Err(e) => {
                eprintln!("screen text: {e}");
                return toast(&app, "screen_text.toast.failed", json!({}));
            }
        };
        // RapidOCR (screen_ocr.py) first; Windows' own OCR while it isn't installed or doesn't answer
        let text = match rapid(&grab) {
            Some(lines) => super::compose_lines(lines, &grab),
            None => match ocr_win::read(&grab) {
                Ok(lines) => super::compose(&lines, &grab),
                Err(e) => {
                    eprintln!("screen text: {e}");
                    return toast(&app, "screen_text.toast.failed", json!({}));
                }
            },
        };
        if text.trim().is_empty() {
            return toast(&app, "screen_text.toast.none", json!({}));
        }
        if !translate {
            insert_win::set_text(&text);
            let n = text.lines().filter(|l| !l.trim().is_empty()).count();
            return toast(
                &app,
                "screen_text.toast.copied",
                json!({"n": n.to_string()}),
            );
        }
        let Some(c) = cloud::payload("translate").or_else(|| cloud::payload("polish")) else {
            insert_win::set_text(&text);
            return toast(&app, "screen_text.toast.no_cloud", json!({}));
        };
        let runner = app.state::<AppState>().runner();
        if server::ensure(&runner, server::POLISH, "polish.py", &[]).is_err()
            || !server::wait_ready(server::POLISH, Duration::from_secs(20))
        {
            return toast(&app, "screen_text.toast.failed", json!({}));
        }
        let target = crate::settings::read_config()
            .pointer("/record/dictation/translate_target")
            .and_then(|v| v.as_str())
            .unwrap_or("auto")
            .to_string();
        let req = json!({"cmd": "translate", "text": text, "target": target, "cloud": c});
        match server::call(server::POLISH, &req, Duration::from_secs(30), None) {
            Some(v)
                if v["ok"] == json!(true)
                    && v["text"].as_str().is_some_and(|t| !t.trim().is_empty()) =>
            {
                let t = v["text"].as_str().unwrap_or_default().to_string();
                insert_win::set_text(&t);
                island::send(&app, json!({"op": "live", "text": t, "typed": true}));
                toast(&app, "screen_text.toast.translated", json!({}));
                let a2 = app.clone();
                std::thread::spawn(move || {
                    std::thread::sleep(Duration::from_secs(6));
                    island::send(&a2, json!({"op": "live", "text": ""}));
                });
            }
            _ => {
                insert_win::set_text(&text);
                toast(&app, "screen_text.toast.translate_failed", json!({}));
            }
        }
    });
}
