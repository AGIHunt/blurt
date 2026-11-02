//! Voice notes on Windows (the Mac's VoiceInput + VoiceNoteStream; capture.rs files what this hears): the microphone
//! straight from Blurt (mic.rs) instead of `tk_recorder.py voice`, cut at pauses as it comes in (segmenter.rs, as a
//! dictation is) and each piece sent to the warm speech server as soon as it is complete, the text so far under the
//! island (`live`, record.live_text). The pieces are heard again in windows (rehear.rs, 10–20 s: the Mac's 10 s
//! windows, within Fun-ASR-Nano's 20 s; record.voice.rehear) and the card gets the windows' text. At stop only the
//! open window is left, so the card has its words about as soon as it is caught. A piece that failed → the whole wav
//! once more, through the same server.
//!
//!  • press once: it listens until the key again or the island's Done — a pause doesn't end it, unless
//!    record.voice.end_on_pause (off): then `silence_ms` (1500) of quiet after speech does. Held longer than 0.35 s:
//!    push-to-talk, it ends when the key goes up (capture.rs `voice_released`).
//!  • at most record.voice.max_seconds (600); nothing heard within 20 s (8 s with end_on_pause) = nothing filed.
//!  • Esc discards it in its first 10 s only: the hook keeps that Esc from the app in front meanwhile (keys_win
//!    ESC_TAKEN), then gives it back — Esc is pressed all the time in Claude Code and vim. Discarded after something
//!    was said, it waits 5 s as NNN.discarded.wav: "Voice note discarded · Undo" files it after all (voice_rules.rs
//!    VoiceKeep / VoiceDiscard). A note the user ended in which nothing was heard: "No sound detected · Keep".
//!  • Structured (the Mac's v0.9-userfix, as dictation's): Shift double-tapped alone while it listens toggles it
//!    (voice_rules.rs LoneShift); once its words are in, polish's structuring pass lays out what was listed and
//!    settles self-corrections. The card's note is that text, the transcript stays beside it (`said_raw`). Cloud polish
//!    only, as dictation's Structured on Windows: without a service the note keeps the transcript.
//!  • the wav goes to shots/NNN.wav of the open shots batch (16 kHz mono), its line into shots.jsonl as
//!    `tk_recorder.py voice` writes it.
//!  • the pieces' model is whatever the warm server has loaded (dictation's choice); Only my voice stays dictation's.
//! Tests: BLURT_TEST_MIC_WAV plays a wav as the microphone (mic.rs).

use std::path::{Path, PathBuf};
use std::sync::atomic::Ordering::SeqCst;
use std::sync::atomic::AtomicBool;
use std::sync::mpsc::{channel, RecvTimeoutError, Sender};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use serde_json::{json, Value};
use tauri::{AppHandle, Manager};

use super::mic::{self, Mic};
use super::rehear::{self, Planner, Window};
use super::segmenter::{self, DictationSegmenter};
use super::trigger::ModifierTap;
use super::voice_rules::{self, Ended, KeepToast, LoneShift, VoiceKeep};
use super::{keys_win, server, stitch};
use crate::{island, settings, AppState};

const SR: usize = mic::SR as usize;
const ESC_SECONDS: f64 = 10.0;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Slot {
    Piece(usize),
    Window(usize),
}

pub enum Ev {
    Frame(Vec<f32>),
    Heard(Slot, Result<String, String>),
    /// a key while the note listens (Shift for Structured)
    Key(u32, bool, f64),
    /// the island's Structured chip
    Toggle,
    Stop,
    Cancel,
}

/// The running note's channel: the key, Done, Esc.
static CTL: Mutex<Option<(Sender<Ev>, Instant)>> = Mutex::new(None);
/// The running note is Structured (capture.rs `state`).
static STRUCTURED: AtomicBool = AtomicBool::new(false);

pub enum End {
    /// on disk: (n, "shots/NNN.wav", the words, the transcript when Structured changed them)
    Filed(u32, String, Option<String>, Option<String>),
    /// discarded after something was said (`unsure` false), or ended with nothing heard (`unsure`): its wav waits as
    /// `parked` for Undo / Keep, which files it as `file`
    Parked { n: u32, file: String, parked: PathBuf, unsure: bool, structured: bool },
    /// Esc before anything was said: nothing kept, nothing said
    Cancelled,
    /// nothing kept: `check_mic` — nothing heard at all within the wait ("Check the microphone")
    Nothing { check_mic: bool },
    /// the microphone wouldn't open
    NoMic,
}

pub fn stop(cancel: bool) -> bool {
    match CTL.lock().unwrap().as_ref() {
        Some((tx, _)) => tx.send(if cancel { Ev::Cancel } else { Ev::Stop }).is_ok(),
        None => false,
    }
}

/// From dictation's key thread, every key while a note listens: its Esc (true: the note took it — its first
/// seconds), and Shift for Structured.
pub fn key(code: u32, down: bool, t: f64) -> bool {
    let g = CTL.lock().unwrap();
    let Some((tx, t0)) = g.as_ref() else {
        return false;
    };
    if code == 0x1B {
        if t0.elapsed().as_secs_f64() > ESC_SECONDS {
            return false;
        }
        if down {
            let _ = tx.send(Ev::Cancel);
        }
        return true;
    }
    let _ = tx.send(Ev::Key(code, down, t));
    false
}

/// The island's Structured chip: the same toggle as Shift double-tapped.
pub fn toggle_structured() {
    if let Some((tx, _)) = CTL.lock().unwrap().as_ref() {
        let _ = tx.send(Ev::Toggle);
    }
}

pub fn structured() -> bool {
    STRUCTURED.load(SeqCst)
}

fn voice_cfg() -> Value {
    settings::read_config()
        .pointer("/record/voice")
        .cloned()
        .unwrap_or(json!({}))
}

fn next_n(session: &Path) -> u32 {
    let from_lines = std::fs::read_to_string(session.join("shots.jsonl"))
        .unwrap_or_default()
        .lines()
        .filter_map(|l| serde_json::from_str::<Value>(l).ok())
        .filter_map(|v| v["n"].as_u64())
        .max()
        .unwrap_or(0);
    let from_files = std::fs::read_dir(session.join("shots"))
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|e| {
            e.file_name()
                .to_string_lossy()
                .get(..3)
                .and_then(|s| s.parse::<u64>().ok())
        })
        .max()
        .unwrap_or(0);
    (from_lines.max(from_files) + 1) as u32
}

/// Discarded notes a quit or a crash left waiting for their Undo go (older than Undo's time).
fn sweep_parked(session: &Path) {
    for e in std::fs::read_dir(session.join("shots")).into_iter().flatten().flatten() {
        let name = e.file_name().to_string_lossy().to_string();
        let old = e
            .metadata()
            .and_then(|m| m.modified())
            .ok()
            .and_then(|m| m.elapsed().ok())
            .is_some_and(|a| a.as_secs_f64() > voice_rules::UNSURE_SECONDS + 5.0);
        if voice_rules::is_parked(&name) && old {
            let _ = std::fs::remove_file(e.path());
        }
    }
}

struct Note {
    audio: Vec<f32>,
    seg: DictationSegmenter,
    pieces: Vec<(usize, usize)>,
    hard: Vec<bool>,
    texts: Vec<Option<String>>,
    next_start: usize,
    failed: bool,
    planner: Planner,
    windows: Vec<(Window, Option<Option<String>>)>,
    covered_last: bool,
}

impl Note {
    fn live(&self) -> String {
        let texts: Vec<String> = self.texts.iter().map_while(|x| x.clone()).collect();
        stitch::join_pieces(&texts, &self.pauses()[..texts.len()])
    }

    fn pauses(&self) -> Vec<Option<f64>> {
        (0..self.texts.len()).map(|i| self.seg.pauses().get(i).copied().flatten()).collect()
    }

    /// The card's words: the windows' text where they answered, the pieces' elsewhere.
    fn said(&self) -> Option<String> {
        let wins: Vec<(Window, Option<String>)> = self.windows.iter().map(|(w, r)| (w.clone(), r.clone().flatten())).collect();
        rehear::typed(&self.texts, &wins, &self.pauses())
    }

    fn waiting(&self) -> bool {
        let n = self.texts.len();
        self.texts.iter().enumerate().any(|(i, t)| t.is_none() && !(self.covered_last && i + 1 == n))
            || self.windows.iter().any(|(_, r)| r.is_none())
    }

    fn heard(&mut self, slot: Slot, r: Result<String, String>) {
        match slot {
            Slot::Piece(i) => match r {
                Ok(s) => self.texts[i] = Some(super::engine::after_hard_cut(&self.hard, &self.texts, i, s)),
                Err(_) => {
                    self.texts[i] = Some(String::new());
                    self.failed = true;
                }
            },
            Slot::Window(k) => {
                let ans = r.ok().map(|s| s.trim().to_string()).filter(|s| !s.is_empty());
                let covers_last = self.covered_last && self.windows[k].0.last + 1 == self.texts.len();
                if ans.is_none() && covers_last {
                    // the covered last piece has no transcript of its own: the whole recording decides
                    self.failed = true;
                    self.covered_last = false;
                    if let Some(x) = self.texts.last_mut() {
                        x.get_or_insert_with(String::new);
                    }
                }
                self.windows[k].1 = Some(ans);
            }
        }
    }
}

/// Listen until stopped; blocks (capture.rs runs it on its own thread). `session` is the shots batch.
pub fn run(app: &AppHandle, session: &Path, project: Option<&str>, hold: bool) -> End {
    let (tx, rx) = channel::<Ev>();
    let (ftx, frx) = channel::<Vec<f32>>();
    let m = match Mic::open(ftx) {
        Ok(m) => m,
        Err(e) => {
            eprintln!("voice note: mic: {e}");
            return End::NoMic;
        }
    };
    {
        let tx = tx.clone();
        std::thread::spawn(move || {
            while let Ok(f) = frx.recv() {
                if tx.send(Ev::Frame(f)).is_err() {
                    break;
                }
            }
        });
    }
    let started = Instant::now();
    *CTL.lock().unwrap() = Some((tx.clone(), started));
    STRUCTURED.store(false, SeqCst);
    keys_win::ESC_TAKEN.store(true, SeqCst);
    sweep_parked(session);

    let runner = app.state::<AppState>().runner();
    // the model loads while the user talks
    {
        let runner = runner.clone();
        std::thread::spawn(move || {
            let _ = server::ensure(
                &runner,
                server::ASR,
                "transcribe.py",
                &["--preload", "--purpose", "dictation", "--no-download"],
            );
        });
    }
    // one worker: pieces and windows in the order they were said
    let (ptx, prx) = channel::<(Slot, PathBuf, String)>();
    {
        let (tx, runner) = (tx.clone(), runner.clone());
        std::thread::spawn(move || {
            while let Ok((slot, wav, prior)) = prx.recv() {
                let r = super::engine::recognise(&runner, &wav, &prior, None);
                let _ = std::fs::remove_file(&wav);
                if tx.send(Ev::Heard(slot, r)).is_err() {
                    break;
                }
            }
        });
    }

    let c = voice_cfg();
    let end_on_pause = c.get("end_on_pause").and_then(Value::as_bool).unwrap_or(false) && !hold;
    let silence = Duration::from_millis(c.get("silence_ms").and_then(Value::as_u64).unwrap_or(1500));
    let max_s = c.get("max_seconds").and_then(Value::as_f64).unwrap_or(600.0);
    let rehear_on = c.get("rehear").and_then(Value::as_bool).unwrap_or(true);
    let wait_s = if end_on_pause { 8.0 } else { 20.0 };
    let debug = std::env::var_os("BLURT_DEBUG_VOICE").is_some();
    let live = settings::read_config()
        .pointer("/record/live_text")
        .and_then(Value::as_bool)
        .unwrap_or(true);
    let mut lone = LoneShift::new();
    if let Some(m) = settings::read_config()
        .pointer("/record/dictation/modifier_tap")
        .and_then(Value::as_str)
        .and_then(ModifierTap::from_config)
    {
        lone.mode = m;
    }

    let tmp = crate::paths::blurt_home()
        .join("dictation")
        .join("audio")
        .join("pieces");
    let _ = std::fs::create_dir_all(&tmp);
    let tag = format!("v{}-{}", std::process::id(), started.elapsed().as_nanos() ^ 0x5eed);
    let queue = |note: &Note, slot: Slot, s: usize, e: usize, first: usize| {
        let name = match slot {
            Slot::Piece(i) => format!("{tag}-{i}.wav"),
            Slot::Window(k) => format!("{tag}-w{k}.wav"),
        };
        let wav = tmp.join(name);
        if mic::write_wav(&wav, &note.audio[s.min(note.audio.len())..e.min(note.audio.len())]).is_ok() {
            let prior: String = note.texts[..first.min(note.texts.len())].iter().flatten().cloned().collect::<Vec<_>>().join("");
            let _ = ptx.send((slot, wav, prior));
        }
    };

    let mut note = Note {
        audio: vec![],
        seg: {
            // pieces of 8 s at most: someone who never pauses half a second still sees words while talking (a
            // dictation keeps 20 s — the windows Fun-ASR can take — for the context)
            let mut g = DictationSegmenter::new(SR as f64);
            g.max_segment = 8.0;
            g
        },
        pieces: vec![],
        hard: vec![],
        texts: vec![],
        next_start: 0,
        failed: false,
        planner: Planner::new(rehear::CAP, SR as f64),
        windows: vec![],
        covered_last: false,
    };
    let mut heard = false;
    let mut sound_seconds = 0.0f64;
    let mut peak_db = f32::MIN;
    let mut quiet_since: Option<Instant> = None;
    let mut level_at = Instant::now();
    let mut esc_given_back = false;
    let mut structured = false;
    let ended = loop {
        let ev = match rx.recv_timeout(Duration::from_millis(200)) {
            Ok(ev) => Some(ev),
            Err(RecvTimeoutError::Timeout) => None,
            Err(RecvTimeoutError::Disconnected) => break Ended::User,
        };
        match ev {
            Some(Ev::Frame(f)) => {
                let lvl = mic::level(&f);
                peak_db = peak_db.max(segmenter::level(&f));
                note.audio.extend_from_slice(&f);
                for cut in note.seg.feed(&f) {
                    let start = note.next_start.min(cut.end);
                    note.next_start = cut.next_start;
                    note.pieces.push((start, cut.end));
                    note.hard.push(cut.hard);
                    note.texts.push(None);
                    let i = note.pieces.len() - 1;
                    queue(&note, Slot::Piece(i), start, cut.end, i);
                    if rehear_on {
                        for w in note.planner.piece(i, start, cut.end, cut.hard) {
                            if w.len() > 1 {
                                let (s, e, first) = (w.start, w.end, w.first);
                                note.windows.push((w, None));
                                queue(&note, Slot::Window(note.windows.len() - 1), s, e, first);
                            }
                        }
                    }
                    heard = true;
                    if debug {
                        eprintln!("voice: {:.1}s cut piece {} ({:.1}s)", started.elapsed().as_secs_f64(), i, (cut.end - start) as f64 / SR as f64);
                    }
                }
                if note.seg.quiet_seconds() < 0.03 {
                    sound_seconds += f.len() as f64 / SR as f64;
                }
                if note.seg.piece_has_speech() {
                    heard = true;
                    quiet_since = None;
                } else if heard {
                    quiet_since.get_or_insert_with(Instant::now);
                }
                if level_at.elapsed() > Duration::from_millis(60) {
                    level_at = Instant::now();
                    island::send(app, json!({"op": "level", "rms": lvl * 0.12}));
                }
            }
            Some(Ev::Heard(slot, r)) => {
                if debug {
                    eprintln!("voice: {:.1}s {slot:?} back: {r:?}", started.elapsed().as_secs_f64());
                }
                note.heard(slot, r);
                if live {
                    island::send(app, json!({"op": "live", "text": note.live()}));
                }
            }
            Some(ev @ (Ev::Key(..) | Ev::Toggle)) => {
                let toggled = match ev {
                    Ev::Key(code, down, t) => lone.key(code, down, t),
                    _ => true,
                };
                if toggled {
                    structured = !structured;
                    STRUCTURED.store(structured, SeqCst);
                    island::send(
                        app,
                        json!({"op": "toast", "kind": "dictation", "key": "voice.style", "ms": 4000,
                               "msg": if structured { "voice.structured_on" } else { "voice.structured_off" }}),
                    );
                    island::refresh(app);
                }
            }
            Some(Ev::Stop) => break Ended::User,
            Some(Ev::Cancel) => break Ended::Cancel,
            None => {}
        }
        let t = started.elapsed().as_secs_f64();
        if !esc_given_back && t > ESC_SECONDS {
            esc_given_back = true;
            keys_win::ESC_TAKEN.store(false, SeqCst);
        }
        if t >= max_s {
            break Ended::Maxed;
        }
        if !heard && t >= wait_s {
            break Ended::NoSpeech;
        }
        if end_on_pause && quiet_since.is_some_and(|q| q.elapsed() >= silence) {
            break Ended::Silence;
        }
    };
    *CTL.lock().unwrap() = None;
    STRUCTURED.store(false, SeqCst);
    keys_win::ESC_TAKEN.store(false, SeqCst);
    drop(m);
    let duration = note.audio.len() as f64 / SR as f64;
    let keep = VoiceKeep::decide(ended, heard, duration, sound_seconds, peak_db as f64);
    if debug {
        eprintln!("voice: ended {ended:?} after {duration:.1}s, heard {heard}, sound {sound_seconds:.2}s, peak {peak_db:.0} dB → {keep:?}");
    }
    let clear = || island::send(app, json!({"op": "live", "text": ""}));
    match keep {
        VoiceKeep::Drop(t) => {
            clear();
            return match t {
                KeepToast::None => End::Cancelled,
                KeepToast::Nothing => End::Nothing { check_mic: false },
                KeepToast::CheckMic => End::Nothing { check_mic: true },
            };
        }
        VoiceKeep::Undoable | VoiceKeep::Unsure => {
            clear();
            let shots = session.join("shots");
            let _ = std::fs::create_dir_all(&shots);
            let n = next_n(session);
            let file = format!("shots/{n:03}.wav");
            let parked = session.join(voice_rules::parked(&file));
            if mic::write_wav(&parked, &note.audio).is_err() {
                return End::Cancelled;
            }
            return End::Parked { n, file, parked, unsure: keep == VoiceKeep::Unsure, structured };
        }
        VoiceKeep::Keep => {}
    }
    if ended == Ended::Maxed {
        island::send(
            app,
            json!({"op": "toast", "kind": "dictation", "msg": "voice.maxed", "vars": {"min": format!("{}", (max_s / 60.0).round())}, "ms": 4000}),
        );
    }
    // the last piece — heard only in the open window when there is one
    let (start, end) = (note.next_start, note.audio.len());
    let last_piece = end > start + SR / 5;
    if last_piece {
        note.pieces.push((start, end));
        note.hard.push(false);
        note.texts.push(None);
    }
    let np = note.pieces.len();
    if rehear_on && np > 0 {
        let (s, e) = note.pieces[np - 1];
        let w = note.planner.finish(np - 1, s, e);
        if w.len() > 1 {
            let (ws, we, first) = (w.start, w.end, w.first);
            note.windows.push((w, None));
            queue(&note, Slot::Window(note.windows.len() - 1), ws, we, first);
            note.covered_last = last_piece;
        }
    }
    if last_piece && !note.covered_last {
        queue(&note, Slot::Piece(np - 1), start, end, np - 1);
    }
    let deadline = Instant::now() + Duration::from_secs(120);
    while note.waiting() && Instant::now() < deadline {
        match rx.recv_timeout(Duration::from_millis(250)) {
            Ok(Ev::Heard(slot, r)) => note.heard(slot, r),
            Ok(_) | Err(RecvTimeoutError::Timeout) => {}
            Err(RecvTimeoutError::Disconnected) => break,
        }
    }
    let shots = session.join("shots");
    let _ = std::fs::create_dir_all(&shots);
    let n = next_n(session);
    let file = format!("shots/{n:03}.wav");
    let wav = session.join(&file);
    if mic::write_wav(&wav, &note.audio).is_err() {
        clear();
        return End::NoMic;
    }
    let mut said = note.said().unwrap_or_default().trim().to_string();
    if said.is_empty() || note.failed || note.waiting() {
        // the whole take once more (Fun-ASR cuts a long one into its own windows)
        if let Ok(t) = super::engine::recognise(&runner, &wav, "", None) {
            if !t.trim().is_empty() {
                said = t.trim().to_string();
            }
        }
    }
    let (said, raw) = structure(&runner, &said, structured);
    write_line(session, n, &file, duration, project);
    clear();
    End::Filed(n, file, Some(said).filter(|s| !s.is_empty()), raw)
}

/// Structured: polish's structuring pass over the note's words → (the card's note, the transcript when they differ).
pub fn structure(runner: &crate::scripts::Runner, said: &str, structured: bool) -> (String, Option<String>) {
    if !structured || said.trim().is_empty() {
        return (said.to_string(), None);
    }
    let p = super::engine::polish_text(runner, said, None, true, false);
    let s = p.polished.filter(|_| !p.fell_back);
    voice_rules::structure_keep(said, s.as_deref())
}

/// The note's line in shots.jsonl, as `tk_recorder.py voice` writes it (its words come in a line of their own).
pub fn write_line(session: &Path, n: u32, file: &str, duration: f64, project: Option<&str>) {
    let wall = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs_f64() - duration)
        .unwrap_or(0.0);
    let mut line = json!({"n": n, "type": "voice", "file": null, "marked": null, "t": null,
                          "wall": (wall * 1000.0).round() / 1000.0, "region": null, "voice": file,
                          "text": null, "said": null, "strokes": [], "project": project});
    if project.is_some() {
        line["assigned_by"] = json!("capture");
    }
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .append(true)
        .create(true)
        .open(session.join("shots.jsonl"))
    {
        use std::io::Write;
        let _ = writeln!(f, "{line}");
    }
}

/// A parked note brought back (Undo / Keep): its wav back under its name, heard whole, Structured as it was.
/// → (its words, the transcript when Structured changed them); None when the wav is gone.
pub fn unpark(app: &AppHandle, session: &Path, n: u32, file: &str, parked: &Path, structured: bool, project: Option<&str>) -> Option<(Option<String>, Option<String>)> {
    let wav = session.join(file);
    std::fs::rename(parked, &wav).ok()?;
    let duration = std::fs::metadata(&wav).map_or(0.0, |m| m.len().saturating_sub(44) as f64 / (2.0 * SR as f64));
    let runner = app.state::<AppState>().runner();
    let said = super::engine::recognise(&runner, &wav, "", None).unwrap_or_default();
    let (said, raw) = structure(&runner, said.trim(), structured);
    write_line(session, n, file, duration, project);
    Some((Some(said).filter(|s| !s.is_empty()), raw))
}

/// A dictation is listening: a voice note waits (the Mac's capture.voice.dictation_busy).
pub fn dictation_busy() -> bool {
    super::engine::island_state()
        .get("phase")
        .and_then(Value::as_str)
        == Some("listening")
}

pub fn active() -> bool {
    CTL.lock().unwrap().is_some()
}
