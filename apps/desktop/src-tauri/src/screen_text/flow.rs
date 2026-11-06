//! Copy Text from Screen (Alt+Shift+C) and its translation (Alt+Shift+T) on Windows — the Mac's ScreenTextCopy,
//! ScreenTextCard and ScreenTextRefine (⌥C / ⌥T; docs/design/screen-text.md, windows-parity/snap-and-note.md §6):
//!
//!  • a crosshair and one drag (the picker's text mode: no dim, no toolbar); the area is read on this PC (RapidOCR
//!    through screen_ocr.py's warm server, Windows' OCR while it isn't there; rules.rs lays the lines out);
//!  • the text (or its translation) goes on the clipboard, and is Ctrl+V'd into the app in front when dictation's paste
//!    rules say so (paste_policy::screen_text: a text field, or one UI Automation can't read; never a password field,
//!    Blurt itself, or a focus that is clearly no field); the island's one line says what became of it, true to what
//!    happened — "Pasted" only once the field, read back, shows it;
//!  • the translation: "Translating…", then the whole of it in a card under the island (Copy; gone 10 s after the
//!    pointer leaves it; Esc closes it only while the pointer is on it); a text already in a fixed target language is
//!    copied as it is and the island says so; a failed translation copies the original, with Try Again;
//!  • the second reading (record.screen_text.refine on): the same picture read again by the connected cloud model that
//!    reads images (`screen_text.py read --stdin`), merged into the draft; the merge replaces the draft on the clipboard
//!    while the clipboard still holds the draft. (The Mac's local reader is an MLX model: not on Windows.)

use std::sync::Mutex;
use std::time::{Duration, Instant};

use serde_json::{json, Value};
use tauri::{AppHandle, Emitter, Listener, Manager};
use tauri_plugin_global_shortcut::{GlobalShortcutExt, ShortcutState};

use super::ocr_win;
use crate::dictation::paste_policy::{self, screen_text::Outcome, Situation};
use crate::dictation::{cloud, insert as ins, server};
use crate::{capture, island, AppState};
use blurt_capture::overlay::{self, Kind};

/// One island line (the Mac's `capture.text.*`), `ms` long, with an optional button — led by the ok check for what
/// was copied or pasted, the attention triangle for a failure, nothing for "no text" (and "Translating…" gets its
/// spinner); never the dictation mic (ScreenTextCopy: `icon: .check` / `.warning`).
fn line(app: &AppHandle, msg: &str, vars: Value, ms: u64, action: Option<(&str, &str)>) {
    let mut op = json!({"op": "toast", "kind": "capture", "msg": msg, "vars": vars, "ms": ms, "key": "screen-text"});
    if let Some(m) = mark_of(msg) {
        op["mark"] = json!(m);
    }
    if let Some((a, label)) = action {
        op["action"] = json!({"a": a, "label": label});
    }
    island::send(app, op);
}

fn mark_of(msg: &str) -> Option<&'static str> {
    let k = msg.strip_prefix("capture.text.").unwrap_or(msg);
    match k {
        "translating" => None,
        "none" => Some("peep"),
        k if k == "failed" || k.starts_with("translate_") => Some("warning"),
        _ => Some("check"),
    }
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

/// The text read and the picture, for Try Again (the island's button on a failed translation).
static LAST: Mutex<Option<String>> = Mutex::new(None);

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
        // the next ⌥C / ⌥T takes the card's place
        close_card(&app);
        let cfg = capture::overlay_config();
        let purpose = if translate { overlay::Purpose::Translate } else { overlay::Purpose::Text };
        island::busy(&app, true);
        let Ok(Some(r)) = overlay::pick_region(&app, &cfg, None, purpose) else {
            island::busy(&app, false);
            return;
        };
        island::busy(&app, false);
        // at once: Peep thinks in the ear while it reads (Windows' OCR takes a second: never dead air after letting go)
        island::send(&app, json!({"op": "working", "on": true}));
        // the picker's window is gone; give the screen a frame to repaint without it
        std::thread::sleep(Duration::from_millis(60));
        let grab = match ocr_win::grab(r.x, r.y, r.w, r.h) {
            Ok(g) => g,
            Err(e) => {
                eprintln!("screen text: {e}");
                return line(&app, "capture.text.failed", json!({}), 4000, None);
            }
        };
        // RapidOCR (screen_ocr.py) first; Windows' own OCR while it isn't installed or doesn't answer
        let debug = std::env::var_os("BLURT_DEBUG_KEYS").is_some();
        let text = match rapid(&grab) {
            Some(lines) => {
                if debug {
                    eprintln!("screen text: rapidocr {} lines: {:?}", lines.len(), lines.iter().map(super::rules::join_words).collect::<Vec<_>>());
                }
                super::compose_lines(lines, &grab)
            }
            None => match ocr_win::read(&grab) {
                Ok(lines) => {
                    if debug {
                        eprintln!("screen text: windows ocr (rapidocr not ready), {} lines", lines.len());
                    }
                    super::compose(&lines, &grab)
                }
                Err(e) => {
                    eprintln!("screen text: {e}");
                    return line(&app, "capture.text.failed", json!({}), 4000, None);
                }
            },
        };
        if debug {
            eprintln!("screen text: {text:?}");
        }
        if text.trim().is_empty() {
            return line(&app, "capture.text.none", json!({}), 3000, None);
        }
        if translate {
            translate_text(&app, &text);
        } else {
            copy(&app, &text, &grab);
        }
    });
}

/// The island's Try Again on a failed translation.
pub fn retry(app: &AppHandle) {
    let Some(text) = LAST.lock().unwrap().clone() else { return };
    let app = app.clone();
    std::thread::spawn(move || translate_text(&app, &text));
}

// ------------------------------------------------------------------ copy (and the second reading)

fn copy(app: &AppHandle, draft: &str, grab: &ocr_win::Grab) {
    let o = deliver(draft, true);
    let key = paste_policy::screen_text::line_key(o, false);
    line(app, key, json!({}), if o == Outcome::Unconfirmed { 5000 } else { 2000 }, None);
    // the second reading: over the draft on the clipboard, never over something the user copied since
    let refine_on = crate::settings::read_config()
        .pointer("/record/screen_text/refine")
        .is_some_and(|v| v == &json!("on") || v == &json!(true));
    let Some(c) = refine_on.then(|| cloud::payload("screen_text")).flatten() else { return };
    let seq = ins::sequence();
    let png = std::env::temp_dir().join(format!("blurt-screen-{}-{}.png", std::process::id(), seq));
    if write_png(&png, grab).is_err() {
        return;
    }
    let runner = app.state::<AppState>().runner();
    let body = json!({"draft": draft, "cloud": c}).to_string();
    let r = runner.run("screen_text.py", &["read".into(), "--image".into(), png.to_string_lossy().into_owned(), "--stdin".into()], Some(body.as_bytes()), Duration::from_secs(30));
    let _ = std::fs::remove_file(&png);
    let Some(t) = r.ok().and_then(|v| v["text"].as_str().map(str::to_owned)).filter(|t| !t.trim().is_empty() && t != draft) else { return };
    if ins::sequence() == seq {
        ins::set_text(&t);
    } else {
        eprintln!("screen text: refine not applied (the clipboard changed)");
    }
}

/// `text` on the clipboard, and Ctrl+V'd into the app in front when the paste rules say so (`may_paste`: false for a
/// text that isn't what was asked for — a failed translation's original). What became of it: for a paste, once the
/// field, read back, shows the text, or once that can't be told (at most 1.5 s).
fn deliver(text: &str, may_paste: bool) -> Outcome {
    let front = ins::front();
    let ours = front.as_ref().is_some_and(|f| f.pid == std::process::id());
    let blocked = front.as_ref().is_some_and(|f| ins::blocks_input(f.pid));
    let mut sit = Situation::new(front.is_some(), ours, false, !blocked);
    let focus = ins::focus_read(true);
    if let Some(f) = &focus {
        sit.focus_secure = f.password;
        sit.focus_is_text = f.editable;
    }
    let paste = may_paste && paste_policy::screen_text::decide(&sit) == paste_policy::screen_text::Decision::Paste;
    ins::set_text(text);
    if !paste {
        return Outcome::Copied;
    }
    let before = focus.and_then(|f| f.field);
    std::thread::sleep(Duration::from_millis(30));
    let pasted = ins::paste_keys();
    let mut seen = false;
    if pasted {
        if let Some(b) = &before {
            let t0 = Instant::now();
            while t0.elapsed().as_secs_f64() < paste_policy::landing::CONFIRM_TIMEOUT {
                std::thread::sleep(Duration::from_secs_f64(paste_policy::landing::POLL));
                if ins::field_text().is_some_and(|now| paste_policy::landing::landed(&b.text, b.sel_start, b.sel_len, &now, text) || landed_lines(&b.text, &now, text)) {
                    seen = true;
                    break;
                }
            }
        }
    }
    paste_policy::screen_text::outcome(pasted, seen)
}

/// Several lines pasted: the field reads its line breaks back its own way (Notepad's RichEdit: `\r`), so the text is
/// looked for with every break as `\n` (the field changed, and now holds it).
fn landed_lines(before: &str, now: &str, text: &str) -> bool {
    let nl = |s: &str| s.replace("\r\n", "\n").replace('\r', "\n");
    let (b, n, t) = (nl(before), nl(now), nl(text));
    t.contains('\n') && n != b && n.contains(t.trim_end())
}

fn write_png(path: &std::path::Path, g: &ocr_win::Grab) -> Result<(), String> {
    let mut rgba = Vec::with_capacity(g.bgra.len());
    for p in g.bgra.chunks_exact(4) {
        rgba.extend_from_slice(&[p[2], p[1], p[0], 255]);
    }
    let f = std::fs::File::create(path).map_err(|e| e.to_string())?;
    let mut e = png::Encoder::new(std::io::BufWriter::new(f), g.w, g.h);
    e.set_color(png::ColorType::Rgba);
    e.set_depth(png::BitDepth::Eight);
    e.write_header().and_then(|mut w| w.write_image_data(&rgba)).map_err(|e| e.to_string())
}

// ------------------------------------------------------------------ translate

fn translate_text(app: &AppHandle, text: &str) {
    *LAST.lock().unwrap() = Some(text.to_string());
    line(app, "capture.text.translating", json!({}), 30_000, None);
    // ⌥T's own target (Settings → Copy Text from Screen, record.screen_text.translate.target — as the Mac's
    // ScreenTranslateConfig, not dictation's): Auto, or a language that text already in it keeps ("X|keep")
    let fixed = crate::settings::read_config()
        .pointer("/record/screen_text/translate/target")
        .and_then(|v| v.as_str())
        .filter(|t| !t.is_empty() && *t != "auto")
        .map(str::to_owned);
    let target = fixed.as_ref().map_or_else(|| "auto".to_string(), |t| format!("{t}|keep"));
    // Windows polishes and translates in the cloud only (no local polish model here): without one, say what it takes
    let Some(c) = cloud::payload("translate").or_else(|| cloud::payload("polish")) else {
        ins::set_text(text);
        return line(app, "capture.text.translate_needs_model", json!({}), 8000, None);
    };
    let runner = app.state::<AppState>().runner();
    if server::ensure(&runner, server::POLISH, "polish.py", &[]).is_err() || !server::wait_ready(server::POLISH, Duration::from_secs(20)) {
        return failed(app, text, "");
    }
    let req = json!({"cmd": "translate", "text": text, "target": target, "cloud": c});
    let r = server::call(server::POLISH, &req, Duration::from_secs(40), None);
    let out = r.as_ref().filter(|v| v["ok"] == json!(true)).and_then(|v| v["text"].as_str()).map(str::trim).unwrap_or("").to_string();
    if out.is_empty() {
        let code = r.as_ref().and_then(|v| v["code"].as_str()).unwrap_or("").to_string();
        return failed(app, text, &code);
    }
    // a fixed language the text is in already: the original, copied as it is (not pasted: it isn't a translation)
    if let Some(lang) = fixed.as_deref().filter(|_| out == text.trim()) {
        deliver(text, false);
        return line(app, "capture.text.already", json!({"lang": language_name(lang)}), 5000, None);
    }
    // the card under the island shows the whole translation, with Copy; the island's one line says what became of it
    show_card(app, &out);
    let o = deliver(&out, true);
    line(app, paste_policy::screen_text::line_key(o, true), json!({}), 5000, None);
}

/// The translation failed: the original is copied (never pasted), the line says why, with Try Again.
fn failed(app: &AppHandle, text: &str, code: &str) {
    deliver(text, false);
    let key = match code {
        c if c.contains("auth") || c.contains("key") => "capture.text.translate_key",
        c if c.contains("rate") || c.contains("quota") => "capture.text.translate_quota",
        c if c.contains("network") || c.contains("timeout") || c.contains("offline") => "capture.text.translate_offline",
        c if c.contains("no_model") => return line(app, "capture.text.translate_needs_model", json!({}), 8000, None),
        _ => "capture.text.translate_failed",
    };
    line(app, key, json!({}), 8000, Some(("text.retry", "capture.text.try_again")));
}

/// A target language's name in the UI language ("Already in English · original copied").
fn language_name(code: &str) -> String {
    let zh = crate::l10n::lang().starts_with("zh");
    let names: &[(&str, &str, &str)] = &[
        ("en", "English", "英文"),
        ("zh", "Chinese", "中文"),
        ("zh-Hans", "Chinese", "中文"),
        ("zh-Hant", "Traditional Chinese", "繁体中文"),
        ("ja", "Japanese", "日文"),
        ("ko", "Korean", "韩文"),
        ("fr", "French", "法文"),
        ("de", "German", "德文"),
        ("es", "Spanish", "西班牙文"),
        ("ru", "Russian", "俄文"),
    ];
    names.iter().find(|(c, _, _)| *c == code).map_or(code.to_string(), |(_, en, z)| if zh { z } else { en }.to_string())
}

// ------------------------------------------------------------------ the translation card (the Mac's ScreenTextCard)

/// The card's text (Copy puts it on the clipboard again) and whether it holds Esc now.
static CARD: Mutex<Option<CardState>> = Mutex::new(None);

struct CardState {
    /// which card this is (a destroyed card's late event never clears the next one's state)
    gen: u64,
    text: String,
    esc: bool,
    listener: Option<tauri::EventId>,
}

const CARD_W: f64 = 400.0;
/// room for the card's shadow left and right of it (textcard.css margin): the window is wider than the card
const SHADOW_ROOM: f64 = 24.0;

/// Under the island, in the live panel's width and place; a card already up takes the new text.
fn show_card(app: &AppHandle, text: &str) {
    let label = Kind::TextCard.label();
    if let Some(c) = CARD.lock().unwrap().as_mut() {
        c.text = text.to_string();
        let _ = app.emit_to(label, overlay::ev::NOTE, json!({"op": "text", "text": text}));
        return;
    }
    let Some(isl) = island::rect(app) else { return };
    let scale = app
        .available_monitors()
        .ok()
        .and_then(|ms| ms.into_iter().find(|m| m.position().x <= isl.x && isl.x < m.position().x + m.size().width as i32))
        .map_or(1.0, |m| m.scale_factor());
    let w = ((CARD_W + 2.0 * SHADOW_ROOM) * scale).round() as u32;
    // under the island — and under the hanging cards while they are down (the island page says where they end)
    let top = island::below_cards(app).unwrap_or(isl.y + (42.0 * scale) as i32);
    let at = blurt_capture::Region::new(isl.x + isl.w as i32 / 2 - w as i32 / 2, top, w, (120.0 * scale) as u32);
    let mut params = std::collections::BTreeMap::new();
    params.insert("text", text.to_string());
    let cfg = capture::overlay_config();
    let Ok(win) = overlay::open(app, Kind::TextCard, &cfg, at, params) else { return };
    let a = app.clone();
    let id = overlay::listen_from(app, overlay::ev::ACTION, label, move |v| card_action(&a, &v));
    static GEN: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let gen = GEN.fetch_add(1, std::sync::atomic::Ordering::SeqCst) + 1;
    {
        let a = app.clone();
        win.on_window_event(move |e| {
            if matches!(e, tauri::WindowEvent::Destroyed) && CARD.lock().unwrap().as_ref().is_some_and(|c| c.gen == gen) {
                card_gone(&a);
            }
        });
    }
    *CARD.lock().unwrap() = Some(CardState { gen, text: text.to_string(), esc: false, listener: Some(id) });
    // where the pointer is, over the card's window (CSS px of it): a window that never takes the focus gets no
    // pointerenter until it's clicked on Windows — the card's 10 s hold under the pointer reads this instead
    let a = app.clone();
    std::thread::spawn(move || {
        let mut last = (f64::NAN, f64::NAN);
        while CARD.lock().unwrap().as_ref().is_some_and(|c| c.gen == gen) {
            std::thread::sleep(Duration::from_millis(100));
            let Some(w) = a.get_webview_window(label) else { break };
            let (Ok(c), Ok(o), Ok(k)) = (a.cursor_position(), w.outer_position(), w.scale_factor()) else { continue };
            let at = (((c.x - o.x as f64) / k).round(), ((c.y - o.y as f64) / k).round());
            if at != last {
                last = at;
                let _ = a.emit_to(label, overlay::ev::NOTE, json!({"op": "cursor", "x": at.0, "y": at.1}));
            }
        }
    });
}

fn card_action(app: &AppHandle, v: &Value) {
    let label = Kind::TextCard.label();
    match v["action"].as_str() {
        Some("textcard.size") => {
            if let (Some(h), Some(w)) = (v["h"].as_f64(), app.get_webview_window(label)) {
                let _ = w.set_size(tauri::LogicalSize::new(CARD_W + 2.0 * SHADOW_ROOM, h.max(40.0)));
            }
        }
        Some("textcard.copy") => {
            if let Some(t) = CARD.lock().unwrap().as_ref().map(|c| c.text.clone()) {
                ins::set_text(&t);
            }
        }
        Some("textcard.pointer") => hold_esc(app, v["inside"] == true),
        Some("textcard.close") => {
            // (after its fade)
            let a = app.clone();
            std::thread::spawn(move || {
                std::thread::sleep(Duration::from_millis(320));
                if let Some(w) = a.get_webview_window(Kind::TextCard.label()) {
                    let _ = w.destroy();
                }
            });
        }
        _ => {}
    }
}

/// Esc is a system-wide key only while the pointer is over the card (an Esc meant for the app in front is never
/// taken otherwise).
fn hold_esc(app: &AppHandle, on: bool) {
    let mut g = CARD.lock().unwrap();
    let Some(c) = g.as_mut() else { return };
    if c.esc == on {
        return;
    }
    c.esc = on;
    let gs = app.global_shortcut();
    if on {
        let _ = gs.on_shortcut("Escape", |app, _sc, ev| {
            if ev.state == ShortcutState::Pressed {
                let _ = app.emit_to(Kind::TextCard.label(), overlay::ev::NOTE, json!({"op": "close"}));
            }
        });
    } else {
        let _ = gs.unregister("Escape");
    }
}

fn card_gone(app: &AppHandle) {
    hold_esc(app, false);
    if let Some(c) = CARD.lock().unwrap().take() {
        if let Some(id) = c.listener {
            app.unlisten(id);
        }
    }
}

/// The next ⌥C / ⌥T: the card goes.
fn close_card(app: &AppHandle) {
    if let Some(w) = app.get_webview_window(Kind::TextCard.label()) {
        let _ = w.destroy();
    }
    card_gone(app);
}
