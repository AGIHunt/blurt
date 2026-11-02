//! Dictation on Windows (docs/design/dictation.md; the Mac's Dictation.swift): talk, and the words are typed into
//! whichever app has the focus.
//!
//!  • trigger: right Alt alone, read by the low-level hook (keys_win.rs) and decided by trigger.rs — auto (a tap is
//!    hands-free, holding is push-to-talk), a double tap sends Return, Esc cancels, Shift double-tapped toggles
//!    Structured and Ctrl double-tapped Translate while it listens.
//!  • capture: the mic opens on the clean key-down (`Arm`), before the trigger decides, so the first syllable is kept;
//!    the warm speech server is started then too (`transcribe.py serve --preload --purpose dictation`).
//!  • text: segmenter.rs cuts the audio at pauses while the user talks and each finished piece is recognised as it
//!    completes, in order, by one worker; at key-up only the last piece is left. The pieces are joined (stitch.rs) and
//!    shown under the island as they come (the `live` op).
//!  • insert (insert_win.rs, paste_policy.rs): clipboard → Ctrl+V into the app the take started in → the clipboard
//!    back; a take whose app is no longer in front, or an elevated window, gets a copy and "Copied — paste with Ctrl+V".
//!    Takes are typed in the order they were said, each once the ones before it are in.
//!  • history: `$BLURT_HOME/dictation/history.jsonl` (the Mac's DictationEntry keys) and the take's wav in `audio/`.
//!
//! Not yet here (TODO.md §Windows): polish (cloud polish needs the keys in Credential Manager), hearing again in
//! longer windows, interim live words, the field's context through UI Automation, learning, the runaway take's
//! reminders, Structured / Translate passes (the toggles are shown, the text is typed as heard).

use std::collections::VecDeque;
use std::path::PathBuf;
use std::sync::mpsc::{channel, Receiver, RecvTimeoutError, Sender};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use serde_json::{json, Value};
use tauri::{AppHandle, Manager};

use super::insert_win::{self as ins, Front};
use super::keys_win::{self, KeyEvent};
use super::mic::{self, Mic};
use super::paste_policy::{self, Decision, Situation};
use super::segmenter::DictationSegmenter;
use super::server;
use super::stitch;
use super::trigger::{DictationTrigger, Event, Key, Mode, Output};
use crate::{island, paths, settings, AppState};

const SR: usize = mic::SR as usize;
/// the take's audio kept from before the start was decided (the key-down's own pre-roll)
const PRE_ROLL: usize = SR / 2;
/// a hands-free take nobody stops ends here (the Mac's DictationRunaway limit)
const LIMIT_S: f64 = 300.0;

enum Msg {
    Key(KeyEvent),
    Frame(Vec<f32>),
    /// a piece came back from the speech server: (take, index, text or error code)
    Piece(u64, usize, Result<String, String>, u64),
}

/// What the island shows (island.rs `state` reads it).
static ISLAND: Mutex<Option<Value>> = Mutex::new(None);

pub fn island_state() -> Value {
    ISLAND.lock().unwrap().clone().unwrap_or(Value::Null)
}

struct Take {
    n: u64,
    id: String,
    started: Instant,
    wall: chrono::DateTime<chrono::Local>,
    front: Option<Front>,
    audio: Vec<f32>,
    seg: DictationSegmenter,
    /// sample ranges of the pieces sent so far, and where the next one starts (a hard cut overlaps)
    pieces: Vec<(usize, usize)>,
    next_start: usize,
    texts: Vec<Option<String>>,
    asr_ms: u64,
    failed: Option<String>,
    stopped: bool,
    send: bool,
    structured: bool,
    translate: bool,
    heard: f32,
}

struct Engine {
    app: AppHandle,
    tx: Sender<Msg>,
    asr: Sender<(u64, usize, PathBuf, String)>,
    paste: Sender<Done>,
    trigger: DictationTrigger,
    mic: Option<Mic>,
    pre: VecDeque<f32>,
    take: Option<Take>,
    /// stopped takes still being recognised, oldest first
    flight: VecDeque<Take>,
    next: u64,
    level_at: Instant,
    mic_name: String,
    model_missing: bool,
}

/// A take ready to type.
struct Done {
    id: String,
    wall: chrono::DateTime<chrono::Local>,
    front: Option<Front>,
    text: String,
    raw: String,
    send: bool,
    structured: bool,
    translate: bool,
    duration: f64,
    asr_ms: u64,
    total_ms: u64,
    pieces: usize,
    wav: PathBuf,
}

fn cfg() -> Value {
    settings::read_config()
        .pointer("/record/dictation")
        .cloned()
        .unwrap_or(json!({}))
}

pub fn enabled() -> bool {
    cfg()
        .get("enabled")
        .and_then(Value::as_bool)
        .unwrap_or(true)
}

fn audio_dir() -> PathBuf {
    paths::blurt_home().join("dictation").join("audio")
}

fn sound(app: &AppHandle, name: &str) {
    if cfg().get("sounds").and_then(Value::as_bool) == Some(false) {
        return;
    }
    let Ok(res) = app.path().resource_dir() else {
        return;
    };
    let mut p = res.join("sounds").join(format!("{name}.wav"));
    if !p.is_file() {
        p = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("sounds")
            .join(format!("{name}.wav"));
    }
    use windows::Win32::Media::Audio::{PlaySoundW, SND_ASYNC, SND_FILENAME, SND_NODEFAULT};
    let w: Vec<u16> = p
        .to_string_lossy()
        .encode_utf16()
        .chain(std::iter::once(0))
        .collect();
    unsafe {
        let _ = PlaySoundW(
            windows::core::PCWSTR(w.as_ptr()),
            None,
            SND_ASYNC | SND_FILENAME | SND_NODEFAULT,
        );
    }
}

fn toast(app: &AppHandle, msg: &str, vars: Value, action: Option<(&str, &str)>) {
    let mut op = json!({"op": "toast", "kind": "dictation", "msg": msg, "vars": vars});
    if let Some((a, label)) = action {
        op["action"] = json!({"a": a, "label": label});
    }
    island::send(app, op);
}

/// Start listening for the key (once, at launch). Err: the hook was refused.
pub fn start(app: &AppHandle) -> Result<(), String> {
    let (tx, rx) = channel::<Msg>();
    let (ktx, krx) = channel::<KeyEvent>();
    keys_win::start(ktx)?;
    {
        let tx = tx.clone();
        std::thread::spawn(move || {
            while let Ok(k) = krx.recv() {
                if tx.send(Msg::Key(k)).is_err() {
                    break;
                }
            }
        });
    }
    let asr = asr_worker(app.clone(), tx.clone());
    let paste = paste_worker(app.clone());
    let c = cfg();
    let key = c
        .get("key")
        .and_then(Value::as_str)
        .and_then(Key::from_config)
        .unwrap_or(Key::RightAlt);
    let mode = c
        .get("mode")
        .and_then(Value::as_str)
        .and_then(Mode::from_config)
        .unwrap_or(Mode::Auto);
    let mut t = DictationTrigger::new(key, mode);
    t.double_tap_window = DictationTrigger::window(keys_win::double_tap_window());
    t.modifier_tap_shift = DictationTrigger::SHIPPED_MODIFIER_TAP;
    t.modifier_tap_command = DictationTrigger::SHIPPED_MODIFIER_TAP;
    let mut e = Engine {
        app: app.clone(),
        tx,
        asr,
        paste,
        trigger: t,
        mic: None,
        pre: VecDeque::new(),
        take: None,
        flight: VecDeque::new(),
        next: 1,
        level_at: Instant::now(),
        mic_name: String::new(),
        model_missing: false,
    };
    {
        let runner = app.state::<AppState>().runner();
        std::thread::spawn(move || super::commands::refresh_ready(&runner));
    }
    std::thread::Builder::new()
        .name("dictation".into())
        .spawn(move || e.run(rx))
        .map_err(|e| e.to_string())?;
    Ok(())
}

impl Engine {
    fn run(&mut self, rx: Receiver<Msg>) {
        loop {
            let wait = self
                .trigger
                .deadline()
                .map(|d| Duration::from_secs_f64((d - keys_win::now()).clamp(0.0, 5.0)))
                .unwrap_or(Duration::from_millis(500));
            match rx.recv_timeout(wait) {
                Ok(Msg::Key(k)) => {
                    if !enabled() {
                        continue;
                    }
                    let time = k.tick_ms as f64 / 1000.0;
                    let out = self.trigger.handle(Event::Key {
                        code: k.code,
                        down: k.down,
                        time,
                    });
                    self.apply(out);
                }
                Ok(Msg::Frame(f)) => self.frame(f),
                Ok(Msg::Piece(n, i, r, ms)) => self.piece(n, i, r, ms),
                Err(RecvTimeoutError::Timeout) => {
                    let out = self.trigger.handle(Event::Tick {
                        time: keys_win::now(),
                    });
                    self.apply(out);
                    if let Some(t) = &self.take {
                        if t.started.elapsed().as_secs_f64() > LIMIT_S {
                            toast(&self.app, "dictation.toast.limit", json!({}), None);
                            self.trigger.ended_by_itself(keys_win::now());
                            self.stop();
                        }
                    }
                }
                Err(RecvTimeoutError::Disconnected) => return,
            }
            // an armed press that became a shortcut: give the mic back
            if self.take.is_none() && !self.trigger.armed_down() && self.mic.is_some() {
                self.close_mic();
            }
        }
    }

    fn apply(&mut self, out: Vec<Output>) {
        for o in out {
            match o {
                Output::Arm => self.arm(),
                Output::Start => self.begin(),
                Output::Stop => self.stop(),
                Output::Cancel => self.cancel(),
                Output::Send => self.send(),
                Output::Style => {
                    if let Some(t) = &mut self.take {
                        t.structured = !t.structured;
                    }
                    self.show();
                }
                Output::Translate => {
                    if let Some(t) = &mut self.take {
                        t.translate = !t.translate;
                    }
                    self.show();
                }
            }
        }
    }

    fn open_mic(&mut self) -> bool {
        if self.mic.is_some() {
            return true;
        }
        let (ftx, frx) = channel::<Vec<f32>>();
        match Mic::open(ftx) {
            Ok(m) => {
                self.mic_name = m.device.clone();
                self.mic = Some(m);
                let tx = self.tx.clone();
                std::thread::spawn(move || {
                    while let Ok(f) = frx.recv() {
                        if tx.send(Msg::Frame(f)).is_err() {
                            break;
                        }
                    }
                });
                true
            }
            Err(e) => {
                eprintln!("dictation: mic: {e}");
                false
            }
        }
    }

    fn close_mic(&mut self) {
        self.mic = None; // dropping the stream ends it (and the forwarder with it)
        self.pre.clear();
    }

    fn arm(&mut self) {
        self.open_mic();
        let st = self.app.state::<AppState>();
        let runner = st.runner();
        std::thread::spawn(move || {
            let _ = server::ensure(
                &runner,
                server::ASR,
                "transcribe.py",
                &["--preload", "--purpose", "dictation", "--no-download"],
            );
        });
    }

    fn begin(&mut self) {
        if *super::commands::READY.lock().unwrap() == Some(false) {
            let downloading = super::commands::downloading();
            toast(
                &self.app,
                if downloading {
                    "dictation.toast.no_model.downloading"
                } else {
                    "dictation.toast.no_model"
                },
                json!({}),
                None,
            );
            self.trigger.reset(false, true);
            self.close_mic();
            return;
        }
        if self.app.state::<AppState>().capture.recording() {
            toast(&self.app, "dictation.toast.recording_busy", json!({}), None);
            self.trigger.reset(false, true);
            return;
        }
        if !self.open_mic() {
            toast(&self.app, "dictation.toast.mic", json!({}), None);
            self.trigger.reset(false, true);
            return;
        }
        let n = self.next;
        self.next += 1;
        let wall = chrono::Local::now();
        let mut seg = DictationSegmenter::new(SR as f64);
        let audio: Vec<f32> = self.pre.drain(..).collect();
        seg.feed(&audio);
        self.take = Some(Take {
            n,
            id: format!(
                "d-{}-{:04x}",
                wall.format("%Y%m%d-%H%M%S"),
                (n as u32).wrapping_mul(2654435761) >> 16
            ),
            started: Instant::now(),
            wall,
            front: ins::front(),
            audio,
            seg,
            pieces: vec![],
            next_start: 0,
            texts: vec![],
            asr_ms: 0,
            failed: None,
            stopped: false,
            send: false,
            structured: false,
            translate: false,
            heard: 0.0,
        });
        sound(&self.app, "start");
        self.show();
    }

    fn frame(&mut self, f: Vec<f32>) {
        let lvl = mic::level(&f);
        let Some(t) = &mut self.take else {
            // armed: keep the last half second
            self.pre.extend(f);
            while self.pre.len() > PRE_ROLL {
                self.pre.pop_front();
            }
            return;
        };
        t.heard = t.heard.max(lvl);
        t.audio.extend_from_slice(&f);
        let cuts = t.seg.feed(&f);
        let mut send = vec![];
        for c in cuts {
            let start = t.next_start.min(c.end);
            t.next_start = c.next_start;
            t.pieces.push((start, c.end));
            t.texts.push(None);
            send.push((t.pieces.len() - 1, start, c.end));
        }
        let (n, id) = (t.n, t.id.clone());
        for (i, s, e) in send {
            self.queue_piece(n, &id, i, s, e);
        }
        if self.level_at.elapsed() > Duration::from_millis(60) {
            self.level_at = Instant::now();
            island::send(&self.app, json!({"op": "level", "rms": lvl * 0.12}));
        }
    }

    fn queue_piece(&self, n: u64, id: &str, i: usize, s: usize, e: usize) {
        let t = self
            .take
            .as_ref()
            .filter(|t| t.n == n)
            .or_else(|| self.flight.iter().find(|t| t.n == n));
        let Some(t) = t else { return };
        let dir = audio_dir().join("pieces");
        let _ = std::fs::create_dir_all(&dir);
        let wav = dir.join(format!("{id}-{i}.wav"));
        if mic::write_wav(&wav, &t.audio[s.min(t.audio.len())..e.min(t.audio.len())]).is_ok() {
            let prior: String = t
                .texts
                .iter()
                .flatten()
                .cloned()
                .collect::<Vec<_>>()
                .join("");
            let _ = self.asr.send((n, i, wav, prior));
        }
    }

    fn stop(&mut self) {
        let Some(mut t) = self.take.take() else {
            return;
        };
        t.stopped = true;
        let start = t.next_start;
        let end = t.audio.len();
        if end > start + SR / 5 {
            t.pieces.push((start, end));
            t.texts.push(None);
        }
        let last = t.pieces.len();
        let (n, id) = (t.n, t.id.clone());
        let _ = std::fs::create_dir_all(audio_dir());
        let _ = mic::write_wav(&audio_dir().join(format!("{id}.wav")), &t.audio);
        self.flight.push_back(t);
        if last > 0
            && self
                .flight
                .back()
                .is_some_and(|t| t.texts[last - 1].is_none())
            && end > start + SR / 5
        {
            self.queue_piece(n, &id, last - 1, start, end);
        }
        self.close_mic();
        sound(&self.app, "stop");
        self.trigger.pending = true;
        self.show();
        self.finish_ready();
    }

    fn cancel(&mut self) {
        if self.take.take().is_some() {
            self.close_mic();
        } else if let Some(t) = self.flight.pop_back() {
            // the take on its way: never typed
            let _ = t;
        }
        sound(&self.app, "cancel");
        toast(&self.app, "dictation.toast.cancelled", json!({}), None);
        island::send(&self.app, json!({"op": "live", "text": ""}));
        self.trigger.pending = !self.flight.is_empty();
        self.show();
    }

    fn send(&mut self) {
        if let Some(t) = self.flight.back_mut() {
            t.send = true; // Return goes in once its text is in
        } else {
            keys_win::send_keys(&[(0x0D, false, false), (0x0D, true, false)]);
            toast(&self.app, "dictation.toast.sent", json!({}), None);
        }
    }

    fn piece(&mut self, n: u64, i: usize, r: Result<String, String>, ms: u64) {
        let t = if self.take.as_ref().is_some_and(|t| t.n == n) {
            self.take.as_mut()
        } else {
            self.flight.iter_mut().find(|t| t.n == n)
        };
        let Some(t) = t else { return };
        t.asr_ms += ms;
        match r {
            Ok(s) => {
                if let Some(slot) = t.texts.get_mut(i) {
                    *slot = Some(s);
                }
            }
            Err(code) => {
                if let Some(slot) = t.texts.get_mut(i) {
                    *slot = Some(String::new());
                }
                t.failed.get_or_insert(code);
            }
        }
        let shown: Vec<String> = t.texts.iter().map_while(|x| x.clone()).collect();
        let joined = stitch::join_pieces(
            &shown,
            &t.seg.pauses()[..shown.len().min(t.seg.pauses().len())],
        );
        if !t.stopped {
            island::send(&self.app, json!({"op": "live", "text": joined}));
        }
        self.finish_ready();
    }

    /// Hand the oldest stopped takes whose pieces are all back to the paste worker, in order.
    fn finish_ready(&mut self) {
        while self
            .flight
            .front()
            .is_some_and(|t| t.texts.iter().all(Option::is_some))
        {
            let t = self.flight.pop_front().unwrap();
            let pauses: Vec<Option<f64>> = (0..t.texts.len())
                .map(|i| t.seg.pauses().get(i).copied().flatten())
                .collect();
            let texts: Vec<String> = t
                .texts
                .iter()
                .map(|x| x.clone().unwrap_or_default())
                .collect();
            let raw = stitch::join_pieces(&texts, &pauses);
            let duration = t.audio.len() as f64 / SR as f64;
            if raw.trim().is_empty() {
                let msg = if t.failed.as_deref() == Some("model_missing") {
                    "dictation.toast.no_model"
                } else {
                    "dictation.toast.nothing"
                };
                if t.failed.as_deref() == Some("model_missing") {
                    self.model_missing = true;
                }
                toast(&self.app, msg, json!({"mic": self.mic_name}), None);
                island::send(&self.app, json!({"op": "live", "text": ""}));
                continue;
            }
            let _ = self.paste.send(Done {
                id: t.id.clone(),
                wall: t.wall,
                front: t.front.clone(),
                text: raw.clone(),
                raw,
                send: t.send,
                structured: t.structured,
                translate: t.translate,
                duration,
                asr_ms: t.asr_ms,
                total_ms: t.started.elapsed().as_millis() as u64,
                pieces: t.texts.len(),
                wav: audio_dir().join(format!("{}.wav", t.id)),
            });
        }
        self.trigger.pending = !self.flight.is_empty();
        self.show();
    }

    fn show(&self) {
        let st = if let Some(t) = &self.take {
            json!({"phase": "listening", "elapsed": t.started.elapsed().as_secs_f64(), "at": 0,
                   "style": if t.structured { "structured" } else { "light" }, "translate": t.translate})
        } else if !self.flight.is_empty() {
            json!({"phase": "transcribing", "elapsed": 0, "at": 0})
        } else {
            Value::Null
        };
        *ISLAND.lock().unwrap() = Some(st);
        island::refresh(&self.app);
    }
}

/// One worker: pieces are recognised in the order they were said (one warm server, one at a time).
fn asr_worker(app: AppHandle, back: Sender<Msg>) -> Sender<(u64, usize, PathBuf, String)> {
    let (tx, rx) = channel::<(u64, usize, PathBuf, String)>();
    std::thread::spawn(move || {
        while let Ok((n, i, wav, prior)) = rx.recv() {
            let t0 = Instant::now();
            let runner = app.state::<AppState>().runner();
            let r = recognise(&runner, &wav, &prior);
            let _ = std::fs::remove_file(&wav);
            if back
                .send(Msg::Piece(n, i, r, t0.elapsed().as_millis() as u64))
                .is_err()
            {
                break;
            }
        }
    });
    tx
}

fn recognise(
    runner: &crate::scripts::Runner,
    wav: &std::path::Path,
    prior: &str,
) -> Result<String, String> {
    if !server::running(server::ASR) {
        server::ensure(
            runner,
            server::ASR,
            "transcribe.py",
            &["--preload", "--purpose", "dictation", "--no-download"],
        )?;
    }
    // a model loading answers the ping; its first decode then waits for the load (up to a minute on a cold disk)
    if !server::wait_ready(server::ASR, Duration::from_secs(45)) {
        return Err("asr_slow".into());
    }
    let language = cfg()
        .get("language")
        .and_then(Value::as_str)
        .unwrap_or("auto")
        .to_string();
    let req = json!({"cmd": "note", "wav": wav.to_string_lossy(), "language": language, "purpose": "dictation",
                     "vocab": true, "no_download": true, "prior": prior});
    match server::call(server::ASR, &req, Duration::from_secs(90), None) {
        Some(v) if v["ok"] == json!(true) => {
            Ok(v["text"].as_str().unwrap_or("").trim().to_string())
        }
        Some(v) => Err(v["code"].as_str().unwrap_or("error").to_string()),
        None => Err("asr_slow".into()),
    }
}

/// One worker: takes are typed in the order they were said.
fn paste_worker(app: AppHandle) -> Sender<Done> {
    let (tx, rx) = channel::<Done>();
    std::thread::spawn(move || {
        while let Ok(mut d) = rx.recv() {
            let t0 = Instant::now();
            let runner = app.state::<AppState>().runner();
            let p = polish(&runner, &d);
            d.text = p.text.clone();
            let now = ins::front();
            let same = match (&d.front, &now) {
                (Some(a), Some(b)) => a.pid == b.pid,
                _ => false,
            };
            let ours = now.as_ref().is_some_and(|f| f.pid == std::process::id());
            let blocked = now.as_ref().is_some_and(|f| ins::blocks_input(f.pid));
            let mut sit = Situation::new(now.is_some() && same, ours, false, !blocked);
            // never into a password field (the Mac's `hold`); a field UIA can read says whether the paste can be confirmed
            if let Some((password, text)) = ins::focus() {
                sit.focus_secure = password;
                sit.focus_is_text = Some(text);
            }
            let decision = paste_policy::decide(&sit);
            let insert = match decision {
                Decision::Paste { .. } => {
                    let saved = ins::save();
                    ins::set_text(&d.text);
                    let seq = ins::sequence();
                    std::thread::sleep(Duration::from_millis(30));
                    ins::paste_keys();
                    let ret = paste_policy::landing::return_after(None);
                    std::thread::sleep(Duration::from_secs_f64(ret));
                    if d.send {
                        ins::press_return();
                    }
                    let rest = paste_policy::landing::restore_after(None) - ret;
                    std::thread::sleep(Duration::from_secs_f64(rest.max(0.0)));
                    // the clipboard changed since (the user copied something): theirs stays
                    if ins::sequence() == seq {
                        ins::restore(&saved);
                    }
                    "pasted"
                }
                Decision::Own => {
                    ins::set_text(&d.text);
                    ins::paste_keys();
                    "pasted"
                }
                Decision::Hold { .. } => {
                    toast(&app, "dictation.toast.secure_held", json!({}), None);
                    "held"
                }
                Decision::Copy { .. } => {
                    ins::set_text(&d.text);
                    let msg = if blocked && same {
                        "dictation.toast.copied.elevated"
                    } else {
                        "dictation.toast.copied"
                    };
                    toast(&app, msg, json!({}), None);
                    "copied"
                }
            };
            island::send(&app, json!({"op": "live", "text": d.text, "typed": true}));
            let a2 = app.clone();
            std::thread::spawn(move || {
                std::thread::sleep(Duration::from_millis(1500));
                island::send(&a2, json!({"op": "live", "text": ""}));
            });
            history(
                &d,
                &p,
                now.as_ref().or(d.front.as_ref()),
                insert,
                d.total_ms + t0.elapsed().as_millis() as u64,
            );
        }
    });
    tx
}

/// What polish made of a take.
struct Polished {
    text: String,
    polished: Option<String>,
    model: Option<String>,
    fell_back: bool,
    reason: Option<String>,
    ms: u64,
}

fn vocab() -> Value {
    let p = paths::blurt_home()
        .join("dictation")
        .join("vocabulary.json");
    let v: Value = std::fs::read_to_string(p)
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or(json!({}));
    json!(v["terms"]
        .as_array()
        .cloned()
        .unwrap_or_default()
        .into_iter()
        .filter(|t| t["state"] != json!("removed"))
        .collect::<Vec<_>>())
}

/// Cloud polish (Light), the Structured pass and translation, through the warm polish server — only with a cloud
/// service connected: Windows has no local polish model (docs/design/windows-models.md). Any failure types the
/// recogniser's text.
fn polish(runner: &crate::scripts::Runner, d: &Done) -> Polished {
    let plain = Polished {
        text: d.raw.clone(),
        polished: None,
        model: None,
        fell_back: false,
        reason: None,
        ms: 0,
    };
    let polish_on = cfg().get("polish").and_then(Value::as_str) != Some("off");
    let cloud = super::cloud::payload("polish");
    let tcloud = super::cloud::payload("translate").or_else(|| cloud.clone());
    if (cloud.is_none() || !polish_on) && !(d.translate && tcloud.is_some()) {
        return plain;
    }
    if server::ensure(runner, server::POLISH, "polish.py", &[]).is_err()
        || !server::wait_ready(server::POLISH, Duration::from_secs(20))
    {
        return Polished {
            fell_back: true,
            reason: Some("unavailable".into()),
            ..plain
        };
    }
    let t0 = Instant::now();
    let budget = 4.0 + 0.006 * d.raw.chars().count() as f64;
    let ctx = json!({"app": d.front.as_ref().map(|f| f.exe.trim_end_matches(".exe").to_string())});
    let mut text = d.raw.clone();
    let mut out = Polished { ..plain };
    if let (Some(c), true) = (&cloud, polish_on) {
        let req = if d.structured {
            json!({"cmd": "structure", "text": text, "timeout": budget, "vocab": vocab(), "context": ctx, "cloud": c, "local_fallback": false})
        } else {
            json!({"cmd": "polish", "text": text, "timeout": budget, "vocab": vocab(), "context": ctx, "cloud": c})
        };
        match server::call(
            server::POLISH,
            &req,
            Duration::from_secs_f64(budget + 3.0),
            None,
        ) {
            Some(v)
                if v["ok"] == json!(true)
                    && !v["text"].as_str().unwrap_or("").trim().is_empty() =>
            {
                text = v["text"].as_str().unwrap_or("").to_string();
                out.fell_back = v["fell_back"] == json!(true);
                out.reason = v["reason"].as_str().map(String::from);
                out.model = v["model"].as_str().map(String::from);
                out.polished = Some(text.clone());
            }
            Some(v) => {
                out.fell_back = true;
                out.reason = Some(
                    v["code"]
                        .as_str()
                        .or(v["reason"].as_str())
                        .unwrap_or("error")
                        .to_string(),
                );
            }
            None => {
                out.fell_back = true;
                out.reason = Some("timeout".into());
            }
        }
    }
    if d.translate {
        if let Some(c) = &tcloud {
            let target = cfg()
                .get("translate_target")
                .and_then(Value::as_str)
                .unwrap_or("auto")
                .to_string();
            let req = json!({"cmd": "translate", "text": text, "target": target, "cloud": c, "spoken": true, "vocab": vocab()});
            if let Some(v) = server::call(server::POLISH, &req, Duration::from_secs(20), None)
                .filter(|v| v["ok"] == json!(true))
            {
                if let Some(t) = v["text"].as_str().filter(|t| !t.trim().is_empty()) {
                    text = t.to_string();
                }
            }
        }
    }
    out.text = text;
    out.ms = t0.elapsed().as_millis() as u64;
    out
}

fn history(d: &Done, p: &Polished, app: Option<&Front>, insert: &str, total_ms: u64) {
    let dir = paths::blurt_home().join("dictation");
    let _ = std::fs::create_dir_all(&dir);
    let model = server::call(
        server::ASR,
        &json!({"cmd": "ping"}),
        Duration::from_millis(500),
        None,
    )
    .and_then(|v| v.get("model").and_then(Value::as_str).map(String::from));
    let row = json!({
        "id": d.id, "t": d.wall.to_rfc3339_opts(chrono::SecondsFormat::Secs, false),
        "app": app.map(|f| f.exe.trim_end_matches(".exe").to_string()), "bundle": app.map(|f| f.exe.clone()),
        "duration": (d.duration * 100.0).round() / 100.0, "raw": d.raw, "polished": p.polished, "text": d.text,
        "model": p.model, "fell_back": p.fell_back, "reason": p.reason, "insert": insert,
        "audio": format!("audio/{}", d.wav.file_name().and_then(|n| n.to_str()).unwrap_or("")),
        "asr_model": model, "asr_ms": d.asr_ms, "polish_ms": p.ms, "total_ms": total_ms, "segments": d.pieces,
        "style": if d.structured { "structured" } else { "light" }, "send": d.send,
    });
    use std::io::Write;
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(dir.join("history.jsonl"))
    {
        let _ = writeln!(f, "{row}");
    }
}
