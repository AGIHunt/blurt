//! The snap note's microphone on Windows (the Mac's NoteVoice + VoiceNoteStream in NoteBubble.swift): it listens as
//! the note opens, cut at pauses as it comes in (segmenter.rs, as a voice note is) and each piece sent to the warm
//! speech server as soon as it is complete — the words so far go to the note's page (`live`), grey, in the field's
//! place. Nothing ends it on a pause (the user commits the note): the mic stops after 20 s with nothing said (the note
//! stays, typed only), at 120 s, when the microphone goes away, or when the page says so (Tab took the words, typing
//! replaced them, the note closed). Kept, the last piece is recognised and the final words go to the page (`words`);
//! the audio waits for capture/snap.rs to write it as shots/NNN.wav once the note is done.
//! Ops to the page (note.ts `NoteOp`): voice, level, speech, live, ended, words.

use std::sync::mpsc::{channel, Receiver, RecvTimeoutError, Sender};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use serde_json::{json, Value};
use tauri::{AppHandle, Manager};

use super::mic::{self, Mic};
use super::segmenter::DictationSegmenter;
use super::{server, stitch};
use crate::AppState;

const SR: usize = mic::SR as usize;
/// the mic stops after this long with nothing said (the bubble stays, typed only)…
const NO_SPEECH: f64 = 20.0;
/// …and after this long in all
const MAX_LISTEN: f64 = 120.0;
/// no audio for this long once it had started: the microphone is gone
const LOST: f64 = 1.5;
/// the longest piece without a pause: the first (its words show early), the rest
const FIRST_PIECE: f64 = 3.0;
const PIECE: f64 = 8.0;
/// drawing keeps the mic open this long past the stroke (the Mac's NoteBubble.inkGrace)
const INK_GRACE: Duration = Duration::from_millis(1500);

enum Ev {
    Frame(Vec<f32>),
    Piece(usize, Result<String, String>),
    Stop(bool),
    /// the pen is on the picture: the no-speech stop waits a moment more
    Activity,
}

/// What was said: the 16 kHz mono audio and its words.
pub struct Take {
    pub audio: Vec<f32>,
    pub said: Option<String>,
}

pub struct NoteMic {
    tx: Sender<Ev>,
    done: Mutex<Option<Receiver<Option<Take>>>>,
}

/// How the note can listen now: "listen"; "busy" (a voice note has the mic: typed only); "nomic" (dictation is
/// listening, or no input device).
pub fn state() -> &'static str {
    if super::voice::active() {
        "busy"
    } else if super::voice::dictation_busy() {
        "nomic"
    } else {
        "listen"
    }
}

/// Starts listening; `emit` sends one op to the note's page. The page hears "nomic" itself if the mic won't open.
pub fn start(app: &AppHandle, emit: impl Fn(Value) + Send + 'static) -> NoteMic {
    let (tx, rx) = channel::<Ev>();
    let (dtx, drx) = channel::<Option<Take>>();
    let app = app.clone();
    let tx2 = tx.clone();
    std::thread::spawn(move || {
        let take = listen(&app, tx2, rx, &emit);
        let _ = dtx.send(take);
    });
    NoteMic { tx, done: Mutex::new(Some(drx)) }
}

impl NoteMic {
    /// Stop now (Tab, typing): `keep` what was said — its final words then go to the page.
    pub fn stop(&self, keep: bool) {
        let _ = self.tx.send(Ev::Stop(keep));
    }

    /// The user is drawing: the no-speech stop waits for the pen.
    pub fn activity(&self) {
        let _ = self.tx.send(Ev::Activity);
    }

    /// The note is done: stop (if it still listens) and hand over the take when it is kept. Kept, it blocks for the
    /// last piece's words (at most ~90 s on a cold server); not kept, it returns at once — the listener drops what it
    /// was still recognising (a discarded snap, a note typed over its grey words never wait for the speech server).
    pub fn finish(&self, keep: bool) -> Option<Take> {
        let _ = self.tx.send(Ev::Stop(keep));
        let rx = self.done.lock().unwrap().take()?;
        if !keep {
            return None;
        }
        rx.recv_timeout(Duration::from_secs(150)).ok().flatten()
    }
}

fn joined(texts: &[Option<String>], pauses: &[Option<f64>], upto_done: bool) -> String {
    let t: Vec<String> = if upto_done {
        texts.iter().map_while(|x| x.clone()).collect()
    } else {
        texts.iter().map(|x| x.clone().unwrap_or_default()).collect()
    };
    let p: Vec<Option<f64>> = (0..t.len()).map(|i| pauses.get(i).copied().flatten()).collect();
    stitch::join_pieces(&t, &p)
}

fn listen(app: &AppHandle, tx: Sender<Ev>, rx: Receiver<Ev>, emit: &dyn Fn(Value)) -> Option<Take> {
    let (ftx, frx) = channel::<Vec<f32>>();
    let m = match Mic::open(ftx) {
        Ok(m) => m,
        Err(e) => {
            eprintln!("snap note: mic: {e}");
            emit(json!({"op": "voice", "state": "nomic"}));
            return None;
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
    emit(json!({"op": "voice", "state": "listening"}));
    let runner = app.state::<AppState>().runner();
    // its words come from the warm server, not a cold model load
    {
        let runner = runner.clone();
        std::thread::spawn(move || {
            let _ = server::ensure(&runner, server::ASR, "transcribe.py", &["--preload", "--purpose", "dictation", "--no-download"]);
        });
    }
    let (ptx, prx) = channel::<(usize, std::path::PathBuf, String)>();
    {
        let (tx, runner) = (tx.clone(), runner.clone());
        std::thread::spawn(move || {
            while let Ok((i, wav, prior)) = prx.recv() {
                let r = super::engine::recognise(&runner, &wav, &prior, None);
                let _ = std::fs::remove_file(&wav);
                if tx.send(Ev::Piece(i, r)).is_err() {
                    break;
                }
            }
        });
    }
    let tmp = crate::paths::blurt_home().join("dictation").join("audio").join("pieces");
    let _ = std::fs::create_dir_all(&tmp);
    let started = Instant::now();
    let tag = format!("n{}-{}", std::process::id(), started.elapsed().as_nanos() ^ 0x5eed);
    let mut audio: Vec<f32> = vec![];
    let mut seg = DictationSegmenter::new(SR as f64);
    // the first piece is cut early, so the first grey words show within ~3 s of talking without a pause (the Mac's
    // come within ~1 s); after it, pieces run to 8 s or the next pause (fewer CPU calls; snap-and-note.md §2.4)
    seg.max_segment = FIRST_PIECE;
    let mut pieces: Vec<(usize, usize)> = vec![];
    let mut hard: Vec<bool> = vec![];
    let mut texts: Vec<Option<String>> = vec![];
    let mut next_start = 0usize;
    let mut failed = false;
    let mut heard = false;
    let mut said_live = false;
    let mut first_audio: Option<Instant> = None;
    let mut last_audio = Instant::now();
    let mut level_at = Instant::now();
    let mut grace_until = started;
    let queue = |audio: &[f32], texts: &[Option<String>], i: usize, s: usize, e: usize| {
        let wav = tmp.join(format!("{tag}-{i}.wav"));
        if mic::write_wav(&wav, &audio[s.min(audio.len())..e.min(audio.len())]).is_ok() {
            let prior: String = texts.iter().flatten().cloned().collect::<Vec<_>>().join("");
            let _ = ptx.send((i, wav, prior));
        }
    };
    let keep = loop {
        let ev = match rx.recv_timeout(Duration::from_millis(200)) {
            Ok(ev) => Some(ev),
            Err(RecvTimeoutError::Timeout) => None,
            Err(RecvTimeoutError::Disconnected) => break false,
        };
        match ev {
            Some(Ev::Frame(f)) => {
                last_audio = Instant::now();
                first_audio.get_or_insert(last_audio);
                let lvl = mic::level(&f);
                audio.extend_from_slice(&f);
                for cut in seg.feed(&f) {
                    seg.max_segment = PIECE;
                    let start = next_start.min(cut.end);
                    next_start = cut.next_start;
                    pieces.push((start, cut.end));
                    hard.push(cut.hard);
                    texts.push(None);
                    queue(&audio, &texts, pieces.len() - 1, start, cut.end);
                }
                if seg.piece_has_speech() && !heard {
                    heard = true;
                    emit(json!({"op": "speech"}));
                }
                if level_at.elapsed() > Duration::from_millis(60) {
                    level_at = Instant::now();
                    // the Mac's NoteVoice: (dB + 55) / 45; mic::level is (dB + 60) / 60
                    let db = lvl * 60.0 - 60.0;
                    emit(json!({"op": "level", "v": ((db + 55.0) / 45.0).clamp(0.0, 1.0)}));
                }
            }
            Some(Ev::Piece(i, r)) => {
                match r {
                    Ok(s) => texts[i] = Some(super::engine::after_hard_cut(&hard, &texts, i, s)),
                    Err(_) => {
                        texts[i] = Some(String::new());
                        failed = true;
                    }
                }
                let live = joined(&texts, seg.pauses(), true);
                said_live |= !live.trim().is_empty();
                emit(json!({"op": "live", "committed": live, "pending": ""}));
            }
            Some(Ev::Stop(k)) => break k && (heard || said_live),
            Some(Ev::Activity) => grace_until = Instant::now() + INK_GRACE,
            None => {}
        }
        let t = started.elapsed().as_secs_f64();
        if !heard && !said_live && t >= NO_SPEECH && Instant::now() >= grace_until {
            emit(json!({"op": "ended", "why": "nospeech"}));
            break false;
        }
        if t >= MAX_LISTEN {
            emit(json!({"op": "ended", "why": "maxed"}));
            break heard || said_live;
        }
        let gone = match first_audio {
            Some(_) => last_audio.elapsed().as_secs_f64() > LOST,
            None => t > 3.0,
        };
        if gone {
            emit(json!({"op": "ended", "why": "lost"}));
            break heard || said_live;
        }
    };
    drop(m);
    if !keep || audio.len() < SR / 3 {
        return None;
    }
    // the last piece, then every piece's words
    let (start, end) = (next_start, audio.len());
    if end > start + SR / 5 {
        pieces.push((start, end));
        hard.push(false);
        texts.push(None);
        queue(&audio, &texts, pieces.len() - 1, start, end);
    }
    let deadline = Instant::now() + Duration::from_secs(90);
    while texts.iter().any(Option::is_none) && Instant::now() < deadline {
        match rx.recv_timeout(Duration::from_millis(250)) {
            Ok(Ev::Piece(i, r)) => match r {
                Ok(s) => texts[i] = Some(super::engine::after_hard_cut(&hard, &texts, i, s)),
                Err(_) => {
                    texts[i] = Some(String::new());
                    failed = true;
                }
            },
            // not kept after all (the note discarded, or typed over): nothing more to recognise
            Ok(Ev::Stop(false)) => return None,
            Ok(_) | Err(RecvTimeoutError::Timeout) => {}
            Err(RecvTimeoutError::Disconnected) => break,
        }
    }
    let mut said = joined(&texts, seg.pauses(), false).trim().to_string();
    if said.is_empty() || failed || texts.iter().any(Option::is_none) {
        // the whole take once more (Fun-ASR cuts a long one into its own windows)
        let wav = tmp.join(format!("{tag}-all.wav"));
        if mic::write_wav(&wav, &audio).is_ok() {
            if let Ok(t) = super::engine::recognise(&runner, &wav, "", None) {
                if !t.trim().is_empty() {
                    said = t.trim().to_string();
                }
            }
            let _ = std::fs::remove_file(&wav);
        }
    }
    let said = Some(said).filter(|s| !s.is_empty());
    emit(json!({"op": "words", "said": said}));
    Some(Take { audio, said })
}

/// shots/NNN.wav (16 kHz mono, 16-bit).
pub fn write(take: &Take, path: &std::path::Path) -> std::io::Result<()> {
    if let Some(d) = path.parent() {
        std::fs::create_dir_all(d)?;
    }
    mic::write_wav(path, &take.audio)
}
