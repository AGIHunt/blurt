//! Dictation on Windows (docs/design/dictation.md; the Mac's Dictation.swift + DictationTakes.swift): talk, and the
//! words are typed into whichever app has the focus. The rules are the Mac's BlurtCore ports (trigger.rs,
//! segmenter.rs, stitch.rs, paste_policy.rs, flow.rs, rehear.rs, apps.rs, context.rs); this acts on them.
//!
//!  • trigger: right Alt alone, read by the low-level hook (keys_win.rs) and decided by trigger.rs — auto (a tap is
//!    hands-free, holding is push-to-talk), a double tap sends Return, Esc cancels, Shift double-tapped toggles
//!    Structured and Ctrl double-tapped Translate while it listens. Esc is Blurt's while a take listens (it never
//!    reaches the app in front); a key joining push-to-talk in its first second is a shortcut, cancelled quietly.
//!  • capture: the mic opens on the clean key-down (`Arm`), before the trigger decides, so the first syllable is kept;
//!    the warm speech server is started then too. The field around the cursor is read at the start (UI Automation,
//!    never a password field): polish gets it as context, the speech model the text before the cursor.
//!  • a hands-free take nobody stops (flow.rs `Runaway`): "Still listening" after 20 s without speech, the clock counts
//!    down from 4:30, and the 5-minute limit says so when it ends the take; the tap right after is its stop.
//!  • text: segmenter.rs cuts the audio at pauses while the user talks and each finished piece is recognised as it
//!    completes, in order, by one worker; the pieces are heard again in windows of at most 20 s (rehear.rs) and the
//!    typed text comes from the windows. At key-up only the open window is left. A piece that failed sends the take
//!    down the safety path: the whole recording once more.
//!  • takes in flight: the stop frees the key at once; takes are typed in the order they were said. Still on its way
//!    3 s after the stop: "Still recognizing… Esc to cancel". Esc then stops it — never typed — with Undo on
//!    "Cancelled" for 5 s (its recording kept until then); Esc while it is polished types it as heard. A take never
//!    waits for its words forever (`TakeDeadline`).
//!  • recognition failed: the recording stays, a history row says why, and the island says it in the user's terms,
//!    with Retry (the whole recording heard again, then typed into the app in front).
//!  • insert (insert_win.rs, paste_policy.rs): clipboard → Ctrl+V into the app in front at paste time (also when the
//!    user switched apps meanwhile, as on the Mac since 2026-10-31) → the clipboard back once the field shows the text
//!    (UI Automation read back; 0.6 s / 1.5 s where it can't be read). One line says how it went (`DeliveredLine`):
//!    "Copied, not sent", "Pasted · Copy Again", the text kept with Copy when the focus isn't a field. Elevated windows
//!    (UIPI) get a copy; password fields nothing (held, with Copy).
//!  • after a take: the first takes' tips, and a notice when Typeless or Wispr Flow runs too (once a day per app, never
//!    over a listening take).
//!  • history: `$BLURT_HOME/dictation/history.jsonl` (the Mac's DictationEntry keys) and the take's wav in `audio/`.

use std::cell::Cell;
use std::collections::{HashMap, HashSet, VecDeque};
use std::path::{Path, PathBuf};
use std::sync::atomic::Ordering::SeqCst;
use std::sync::mpsc::{channel, Receiver, RecvTimeoutError, Sender};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

use serde_json::{json, Value};
use tauri::{AppHandle, Manager};

use super::apps;
use super::context::Context;
use super::flow::{
    self, nothing_heard, toast_keys as keys, AsrFailure, Clash, ClashMoment, CopiedGuard, DeliveredLine, KeptText,
    Runaway, RunawayNotice, SendRule, SendVerdict, TakeDeadline, Tip,
};
use super::insert::{self as ins, Front};
use super::keys::{self as keys_win, KeyEvent};
use super::mic::{self, Mic};
use super::paste_policy::{self, landing, send as send_policy, Decision, Situation};
use super::prefs::{Prefs, Style};
use super::rehear::{self, Planner, Window};
use super::segmenter::DictationSegmenter;
use super::server;
use super::stitch;
use super::trigger::{vk, DictationTrigger, Event, Key, Miss, Output};
use crate::{island, paths, settings, AppState};

const SR: usize = mic::SR as usize;
/// the take's audio kept from before the start was decided (the key-down's own pre-roll)
const PRE_ROLL: usize = SR / 2;
/// an Esc that isn't the cancel key (Ctrl+Esc chosen, Esc alone pressed): no VK has this code
const PLAIN_ESCAPE: u32 = 0x1_001B;

/// Which job a speech-server answer is for.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Slot {
    Piece(usize),
    Window(usize),
    /// the whole recording: the safety path, Retry, Undo
    Whole,
}

enum Msg {
    Key(KeyEvent),
    /// the dictation key as Blurt's own window saw it (`forward_key`)
    Forwarded(u32, bool),
    Frame(Vec<f32>),
    /// a job came back from the speech server: (take, slot, text or error code, ms)
    Heard(u64, Slot, Result<String, String>, u64),
    /// the field around the cursor, read at the take's start
    Context(u64, Option<Context>),
    /// the other dictation apps running now (Typeless, Wispr Flow)
    Clash(Vec<String>),
    /// an island button ("dictation.undo:…", "dictation.retry:…", "dictation.copy:…")
    Action(String),
    /// the paste worker is done with a take
    Delivered(Delivered),
    /// a speech model download finished (commands.rs)
    ModelArrived,
    /// …or failed
    ModelFailed,
    /// Alt+Shift+L: reformat the last take (hotkeys.rs → lib.rs `dispatch`)
    Reformat,
}

/// The speech model came in: the newest take that failed for want of it gets Retry (the Mac's `modelArrived`).
pub fn model_arrived() {
    if let Some(tx) = INBOX.get() {
        let _ = tx.send(Msg::ModelArrived);
    }
}

/// The speech model's download failed (no network, no uv …): the island says so, with Retry — "Download…" must never
/// just go quiet (dogfood 11-02: the island went idle and the next key-down offered the same Download… again).
pub fn model_failed() {
    if let Some(tx) = INBOX.get() {
        let _ = tx.send(Msg::ModelFailed);
    }
}

/// Reformat-last (Alt+Shift+L, the Mac's ⌥L): the take typed last, in the next style — Verbatim → Light → Structured.
pub fn reformat_last() {
    if let Some(tx) = INBOX.get() {
        let _ = tx.send(Msg::Reformat);
    }
}

/// What the island shows (island.rs `state` reads it).
static ISLAND: Mutex<Option<Value>> = Mutex::new(None);
/// The engine's inbox, for `forward_key` and the island's buttons.
static INBOX: OnceLock<Sender<Msg>> = OnceLock::new();
/// Takes Esc stopped while their speech jobs were out: the worker skips their jobs and gives up on one in flight.
static DROPPED: Mutex<Vec<u64>> = Mutex::new(Vec::new());
/// The last few takes' texts, for the island's Copy buttons (id, text).
static TEXTS: Mutex<VecDeque<(String, String)>> = Mutex::new(VecDeque::new());
/// When the island's last dictation line went up and how long it stays (a tip never covers another line).
static LAST_TOAST: Mutex<Option<(Instant, u64)>> = Mutex::new(None);
/// The speech server is starting and loading its model (a CPU load is ~17 s): a take waiting now says so.
static ASR_LOADING: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
/// The warm speech server's arguments (every start: the prewarm at launch, a key-down, a take, a stream).
const ASR_ARGS: [&str; 4] = ["--preload", "--purpose", "dictation", "--no-download"];

/// The paste worker's line, shared with the engine (Esc, a double tap) and the island's state.
#[derive(Default)]
struct Line {
    /// handed to the paste worker, not started yet (oldest first)
    queued: VecDeque<String>,
    /// the take the worker has now, and whether it is being polished
    current: Option<String>,
    polishing: bool,
    /// Esc while it polishes: it goes in as heard
    skip_polish: bool,
    /// Esc while it is pasted: its queued Return is dropped
    send_cancelled: bool,
    /// a double tap after the take was handed over: Return once it is in
    send: HashSet<String>,
    /// queued takes Esc cancelled (the worker skips them) and those it skipped (Undo hears them again)
    cancelled: HashSet<String>,
    skipped: HashSet<String>,
}

impl Line {
    fn busy(&self) -> bool {
        !self.queued.is_empty() || self.current.is_some()
    }
}

fn line() -> &'static Mutex<Line> {
    static L: OnceLock<Mutex<Line>> = OnceLock::new();
    L.get_or_init(Default::default)
}

fn dropped(n: u64) -> bool {
    DROPPED.lock().unwrap().contains(&n)
}

fn drop_take(n: u64) {
    let mut d = DROPPED.lock().unwrap();
    d.push(n);
    let over = d.len().saturating_sub(64);
    d.drain(..over);
}

/// The dictation key went down / up while one of Blurt's own windows had the focus. The hook doesn't hear keys sent
/// to Blurt's own windows (seen on the VM: nothing reached it while the main window was in front, everything again
/// once another app was), so the window passes the key on (App.tsx); the engine drops it when the hook already
/// reported the same change (`key_down`).
pub fn forward_key(code: u32, down: bool) {
    if let Some(tx) = INBOX.get() {
        let _ = tx.send(Msg::Forwarded(code, down));
    }
}

/// An island button whose action starts with "dictation." (island.rs `on_action`).
pub fn island_action(action: &str) {
    if let Some(tx) = INBOX.get() {
        let _ = tx.send(Msg::Action(action.to_string()));
    }
}

/// What the island shows: listening while a take listens, else the stage of the oldest take still on its way —
/// "Polishing…" while the paste worker polishes one.
pub fn island_state() -> Value {
    let base = ISLAND.lock().unwrap().clone().unwrap_or(Value::Null);
    if base.is_null() && line().lock().unwrap().polishing {
        return json!({"phase": "polishing", "elapsed": 0, "at": 0});
    }
    base
}

/// What Undo and Retry need of a take.
#[derive(Clone, Debug)]
struct Meta {
    id: String,
    wall: chrono::DateTime<chrono::Local>,
    duration: f64,
    style: Style,
    translate: bool,
    front: Option<Front>,
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
    /// the cut that ended piece i was hard: piece i + 1 repeats its last words (stitch::drop_overlap)
    hard: Vec<bool>,
    next_start: usize,
    /// the pieces' transcripts (None: not back yet — or the covered last piece, which only its window hears)
    texts: Vec<Option<String>>,
    covered_last: bool,
    planner: Planner,
    /// the windows heard again: None not back, Some(None) failed or empty, Some(Some(text))
    windows: Vec<(Window, Option<Option<String>>)>,
    /// the whole recording heard: None not asked, Some(None) on its way
    whole: Option<Option<Result<String, String>>>,
    asr_ms: u64,
    failed: Option<String>,
    stopped_at: Option<Instant>,
    slow_said: bool,
    send: bool,
    /// the take's style (Shift toggles Structured), and what the app / category / default alone gives
    style: Style,
    base: Style,
    translate: bool,
    /// how often Shift / Ctrl switched it (what is remembered for its app once it is typed)
    style_toggles: u32,
    translate_toggles: u32,
    /// the selected speech model is a cloud service: no pieces, the whole take at key-up (each pass is billed)
    cloud: bool,
    /// the segmenter heard speech in it (a cloud take with none isn't sent)
    spoke: bool,
    /// Volcengine: the take's audio streams to the speech server while it is said (`stream_take`)
    stream: Option<Sender<StreamMsg>>,
    /// the loudest frame (mic.rs level) and how many frames: "No sound from <mic>"
    peak: f32,
    frames: usize,
    runaway: Runaway,
    context: Option<Context>,
    duration: f64,
}

impl Take {
    fn meta(&self) -> Meta {
        Meta {
            id: self.id.clone(),
            wall: self.wall,
            duration: self.duration,
            style: self.style,
            translate: self.translate,
            front: self.front.clone(),
        }
    }

    fn wav(&self) -> PathBuf {
        audio_dir().join(format!("{}.wav", self.id))
    }

    /// Something is still out: a piece (not the covered last one), a window, the whole recording.
    fn waiting(&self) -> bool {
        let n = self.texts.len();
        let pieces = self
            .texts
            .iter()
            .enumerate()
            .any(|(i, t)| t.is_none() && !(self.covered_last && i + 1 == n));
        pieces || self.windows.iter().any(|(_, r)| r.is_none()) || self.whole == Some(None)
    }

    /// The text heard so far for the live panel: the pieces' transcripts in order, up to the first not back.
    fn live(&self) -> String {
        let shown: Vec<String> = self.texts.iter().map_while(|x| x.clone()).collect();
        let pauses = self.seg.pauses();
        stitch::join_pieces(&shown, &pauses[..shown.len().min(pauses.len())])
    }

    fn pauses(&self) -> Vec<Option<f64>> {
        (0..self.texts.len()).map(|i| self.seg.pauses().get(i).copied().flatten()).collect()
    }

    /// The text before piece `first` that a window or a piece hears as context.
    fn prior(&self, first: usize) -> String {
        self.texts[..first.min(self.texts.len())].iter().flatten().cloned().collect::<Vec<_>>().join("")
    }

    /// What the speech model gets of the field (the Mac's transcribe `before`, `hint`, `app`).
    fn before(&self) -> AsrCtx {
        AsrCtx {
            before: self.context.as_ref().map(Context::asr_before).unwrap_or_default(),
            hint: self.context.as_ref().map(Context::hint).unwrap_or_default(),
            app: self.front.as_ref().map(display_name).unwrap_or_default(),
        }
    }
}

/// A take ready to type.
struct Done {
    id: String,
    wall: chrono::DateTime<chrono::Local>,
    front: Option<Front>,
    raw: String,
    send: bool,
    style: Style,
    translate: bool,
    duration: f64,
    asr_ms: u64,
    /// keep the recording (record.dictation.keep_audio)
    keep_audio: bool,
    /// write the history line (record.dictation.retention_days not 0, "Don't keep")
    keep_history: bool,
    /// the cancel key's name ("Esc", "Ctrl+Esc")
    cancel_label: &'static str,
    stopped_at: Instant,
    pieces: usize,
    windows: usize,
    wav: PathBuf,
    context: Option<Context>,
    style_toggles: u32,
    translate_toggles: u32,
    /// the speech model looped on a piece of it (cut by the server): never sent on a double tap
    looped: bool,
}

/// What became of a take the paste worker had.
#[derive(Default)]
struct Delivered {
    id: String,
    /// pasted | copied | held | none | cancelled
    result: String,
    sent: bool,
    send_asked: bool,
    exe: Option<String>,
    stopped_at: Option<Instant>,
    /// the app it started in (an executable's stem; its name for a line), and whether the text went into another one
    start_app: String,
    start_app_name: String,
    app_changed: bool,
    style: Option<Style>,
    style_toggles: u32,
    translate: bool,
    translate_toggles: u32,
    /// the speech model that heard it; cloud polish's own error ("auth": the key was refused)
    asr_model: Option<String>,
    polish_cloud_error: Option<String>,
    /// the island said something about this take already (a tip, a notice wait)
    had_line: bool,
    /// pasted, but the focus was read and isn't a text field (the desktop, Explorer's files): the words went nowhere —
    /// the island keeps them with Copy, and a double tap must not press Return there
    no_field: bool,
    /// what the take asked for actually happened: translated, made into a list (only that is remembered for the app)
    translated: bool,
    list: bool,
}

struct Engine {
    app: AppHandle,
    tx: Sender<Msg>,
    asr: Sender<Job>,
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
    /// the dictation key's state as last reported (hook or window): a forwarded repeat of it is dropped
    key_down: bool,
    /// the last key that went down (Esc or another key: a cancel's reason)
    last_key: u32,
    /// takes stopped on their way by Esc, kept for Undo: (when, what Undo needs)
    cancelled: Vec<(Instant, Meta)>,
    /// takes whose recognition failed, kept for Retry (the last five)
    failed: VecDeque<Meta>,
    /// takes handed to the paste worker (what Undo needs if Esc stops them there)
    handed: VecDeque<Meta>,
    /// the last take was only copied (then) and whether a key went down since: a double tap holds its Return
    copied_at: Option<Instant>,
    /// …and it found no text field: the take whose words the island keeps (its Copy goes with "not sent")
    no_field_take: Option<String>,
    key_after_copy: bool,
    /// when and into which app the last take was typed: a double tap sends right after one
    last_paste: Option<(Instant, Option<String>)>,
    last_send_at: Option<Instant>,
    /// a tip waiting to be said: (tip, from when, the take's stop)
    tip: Option<(Tip, Instant, Instant)>,
    /// the other dictation apps' notice, held back while a take listens
    clash_after_take: Option<Vec<String>>,
    /// a tap hold mode doesn't use, said after the double-tap window
    miss_hold_at: Option<Instant>,
    /// record.dictation as last read, the config file's time then, and when it was last looked at
    prefs: Prefs,
    prefs_stamp: Option<std::time::SystemTime>,
    prefs_checked: Instant,
    /// the key or the mode changed while a take listened: the trigger is made again once it stops
    rebuild: bool,
    /// the take that failed for want of a speech model (Retry once one is in)
    no_model_take: Option<String>,
    /// each app's last take this launch (the "as last time" reminder's clock)
    last_take_in: HashMap<String, Instant>,
    /// Alt+Shift+L came while this take was on its way: it runs once that take is in (and goes with it otherwise)
    reformat_after: Option<String>,
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

/// The dictation key's name in a line ("Right Alt to finish").
fn key_label(k: Key) -> String {
    let zh = crate::l10n::lang() == "zh-Hans";
    match (k, zh) {
        (Key::RightAlt, false) => "Right Alt".into(),
        (Key::RightAlt, true) => "右 Alt".into(),
        (_, _) => "Alt".into(),
    }
}

/// A take's cue: the start's peep (`sounds`, on unless turned off), the stop's and the cancel's peck (`stop_sound`,
/// off unless turned on; the Mac's DictationSound) — `on` says which switch. Never while a recording runs (it would be
/// in it).
/// "… stays on in WeChat · Shift to switch back" / "As last time in WeChat: …": the line for what was remembered
/// (`prefix` .structured / .translate / .both), with the keys that switch it.
fn remembered_line(prefix: &str, structured: bool, translated: bool) -> Option<(&'static str, &'static str)> {
    let saved = prefix.ends_with("saved");
    match (structured, translated) {
        (true, true) => Some((if saved { "dictation.remember.saved.both" } else { "dictation.remember.kept.both" }, "Shift / Ctrl")),
        (true, false) => Some((if saved { "dictation.remember.saved.structured" } else { "dictation.remember.kept.structured" }, "Shift")),
        (false, true) => Some((if saved { "dictation.remember.saved.translate" } else { "dictation.remember.kept.translate" }, "Ctrl")),
        _ => None,
    }
}

/// "Dictation needs a speech model" (`msg`: at a key-down, or ".kept" for a take that failed for want of it): while one
/// downloads, how far it is ("still downloading (412 MB / 950 MB) · Show"); else the button with what it costs
/// ("Download (230 MB)", the Mac's no_model.action_size) — or Settings… for a cloud model without its key.
pub(crate) fn say_no_model(app: &AppHandle, msg: &str, ms: u64) {
    let downloading = super::commands::downloading();
    if downloading {
        let p = *super::commands::PROGRESS.lock().unwrap();
        let (m, vars) = match p {
            Some((d, t)) => ("dictation.toast.model_downloading", json!({"done": fmt_mb(d), "total": fmt_mb(t)})),
            None => ("dictation.toast.no_model.downloading", json!({})),
        };
        return say(app, m, vars, keys::MODEL, ms, Some(model_action(true)), false);
    }
    let (a, label) = model_action(false);
    let size = (a == "dictation.download")
        .then(|| super::commands::MODELS.lock().unwrap().as_ref().and_then(super::flow::speech_models::to_get))
        .flatten()
        .and_then(|(id, _)| model_size(&id));
    let mut op = json!({"op": "toast", "kind": "dictation", "msg": msg, "vars": {}, "key": keys::MODEL, "ms": ms, "mark": "warning",
                        "action": {"a": a, "label": label}});
    if let Some(sz) = size {
        op["action"]["label"] = json!("dictation.toast.no_model.action_size");
        op["action"]["vars"] = json!({"size": sz});
    }
    // no speech model at all (not one that failed a take): a cloud service is the other way, as on the Mac —
    // "Download (950 MB)" · "Use Cloud…", 10 s
    let none_here = super::commands::MODELS.lock().unwrap().as_ref().is_some_and(|v| {
        v["models"].as_array().is_some_and(|rows| !rows.iter().any(|r| r["installed"] == json!(true)))
    });
    if msg == "dictation.toast.no_model" && a == "dictation.download" && none_here {
        op["second"] = json!({"a": "dictation.cloud", "label": "dictation.toast.no_model.cloud"});
        op["ms"] = json!(ms.max(10_000));
    }
    *LAST_TOAST.lock().unwrap() = Some((Instant::now(), ms));
    island::send(app, op);
}

/// "230 MB", "1.2 GB".
fn fmt_mb(mb: f64) -> String {
    if mb >= 1000.0 {
        format!("{:.1} GB", mb / 1024.0)
    } else {
        format!("{} MB", mb.round() as i64)
    }
}

/// A speech model's download size ("230 MB"), from `dictation-models`' rows.
fn model_size(id: &str) -> Option<String> {
    let m = super::commands::MODELS.lock().unwrap();
    let rows = m.as_ref()?["models"].as_array()?.clone();
    rows.iter().find(|r| r["id"] == id).and_then(|r| r["size_mb"].as_f64()).filter(|s| *s > 0.0).map(fmt_mb)
}

/// The button on "Dictation needs a speech model": Show while it downloads, Settings… when the chosen model is a cloud
/// one without its key, else Download….
fn model_action(downloading: bool) -> (String, &'static str) {
    if downloading {
        ("dictation.models".into(), "dictation.toast.model_downloading.action")
    } else if super::commands::MODELS.lock().unwrap().as_ref().is_some_and(super::flow::speech_models::needs_key) {
        ("dictation.cloud".into(), "dictation.toast.asr_cloud_key.action")
    } else {
        ("dictation.download".into(), "dictation.toast.no_model.get")
    }
}

/// The reformat-last hotkey's label (Alt+Shift+L by default), None when it is off.
fn reformat_key() -> Option<String> {
    crate::hotkeys::from_config(&settings::read_config())
        .into_iter()
        .find(|(a, _)| *a == "reformat")
        .and_then(|(_, c)| c)
        .map(|c| c.label())
}

fn sound(app: &AppHandle, name: &str, on: bool) {
    if !on || app.state::<AppState>().capture.recording() {
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
    #[cfg(target_os = "linux")]
    {
        // PipeWire's player (pipewire-bin, on every Ubuntu desktop), else PulseAudio's; never waited for
        let p2 = p.clone();
        std::thread::spawn(move || {
            for player in ["pw-play", "paplay"] {
                if let Ok(mut c) = std::process::Command::new(player).arg(&p2).stdout(std::process::Stdio::null()).stderr(std::process::Stdio::null()).spawn() {
                    let _ = c.wait();
                    return;
                }
            }
        });
    }
    #[cfg(windows)]
    {
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
}

/// One line on the island (`msg` a catalog key, `vars` its values), about `key`: a newer line with the same key
/// replaces it. `passive`: not a reply to what the user just did (a reminder, a tip) — it never covers another line.
/// `action`: one button, sent back as an island action.
#[allow(clippy::too_many_arguments)]
fn say(app: &AppHandle, msg: &str, vars: Value, key: &str, ms: u64, action: Option<(String, &str)>, passive: bool) {
    let mut op = json!({"op": "toast", "kind": "dictation", "msg": msg, "vars": vars, "key": key, "ms": ms});
    if let Some(m) = keys::mark(msg) {
        op["mark"] = json!(m);
    }
    if let Some((a, label)) = action {
        op["action"] = json!({"a": a, "label": label});
    }
    if passive {
        op["passive"] = json!(true);
    }
    *LAST_TOAST.lock().unwrap() = Some((Instant::now(), ms));
    island::send(app, op);
}

/// "Sent" (a double tap's Return went in): the ears' moment — keyboard on the left, ✓ and the word on the right for
/// 1.6 s (the Mac's island.dictationSent → earMoment(lead: .keyboard)), not a line.
fn say_sent(app: &AppHandle) {
    island::send(app, json!({"op": "toast", "kind": "dictation", "msg": "dictation.toast.sent", "key": keys::TAKE, "moment": "keyboard"}));
}

/// The island drops what it says under these keys (a new take, the end of listening, a take that landed).
fn drop_toasts(app: &AppHandle, ks: &[&str]) {
    island::send(app, json!({"op": "toast_drop", "keys": ks}));
}

fn toast_idle() -> bool {
    LAST_TOAST
        .lock()
        .unwrap()
        .is_none_or(|(at, ms)| at.elapsed() > Duration::from_millis(ms))
}

fn remember_text(id: &str, text: &str) {
    let mut t = TEXTS.lock().unwrap();
    t.retain(|(i, _)| i != id);
    t.push_back((id.to_string(), text.to_string()));
    while t.len() > 5 {
        t.pop_front();
    }
}

fn today() -> String {
    chrono::Local::now().format("%Y-%m-%d").to_string()
}

/// `what` was said today already (app.dictation_notices: the day each was last said).
fn said_today(what: &str) -> bool {
    settings::read_config().pointer(&format!("/app/dictation_notices/{what}")).and_then(Value::as_str)
        == Some(today().as_str())
}

fn mark_said(what: &str) {
    let mut said = settings::read_config()
        .pointer("/app/dictation_notices")
        .cloned()
        .filter(Value::is_object)
        .unwrap_or(json!({}));
    said[what] = json!(today());
    let _ = settings::merge(json!({"app": {"dictation_notices": said}}));
}

fn tips_shown() -> HashMap<String, i64> {
    settings::read_config()
        .pointer("/app/dictation_tips")
        .and_then(Value::as_object)
        .map(|o| o.iter().filter_map(|(k, v)| v.as_i64().map(|n| (k.clone(), n))).collect())
        .unwrap_or_default()
}

fn save_tips(t: &HashMap<String, i64>) {
    let _ = settings::merge(json!({"app": {"dictation_tips": t}}));
}

/// The user used it themselves: its tip isn't needed any more.
fn note_used(tip: Tip) {
    let mut t = tips_shown();
    if t.get(tip.as_str()).copied().unwrap_or(0) < tip.times() {
        t.insert(tip.as_str().into(), tip.times());
        save_tips(&t);
    }
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
    let _ = INBOX.set(tx.clone());
    let asr = asr_worker(app.clone(), tx.clone());
    let paste = paste_worker(app.clone(), tx.clone());
    let prefs = Prefs::from_json(&cfg());
    let t = make_trigger(&prefs);
    keys_win::CANCEL_MODS.store(cancel_mods(&prefs), SeqCst);
    let mut e = Engine {
        app: app.clone(),
        tx: tx.clone(),
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
        key_down: false,
        last_key: 0,
        cancelled: vec![],
        failed: VecDeque::new(),
        handed: VecDeque::new(),
        copied_at: None,
        no_field_take: None,
        key_after_copy: false,
        last_paste: None,
        last_send_at: None,
        tip: None,
        clash_after_take: None,
        miss_hold_at: None,
        prefs,
        prefs_stamp: config_stamp(),
        prefs_checked: Instant::now(),
        rebuild: false,
        no_model_take: None,
        last_take_in: HashMap::new(),
        reformat_after: None,
    };
    {
        let runner = app.state::<AppState>().runner();
        std::thread::spawn(move || {
            super::commands::refresh_ready(&runner);
            prewarm(&runner);
        });
    }
    // the other dictation apps, a moment after launch (and at each take's start)
    {
        let tx = tx.clone();
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_secs(8));
            let _ = tx.send(Msg::Clash(apps::clash_apps(&ins::running_exes())));
        });
    }
    std::thread::Builder::new()
        .name("dictation".into())
        .spawn(move || e.run(rx))
        .map_err(|e| e.to_string())?;
    Ok(())
}

/// The speech model loaded at launch (the Mac warms its model at launch too): on the CPU a cold load is ~17 s, and the
/// first take after starting Blurt waited ~20 s for it (dogfood 11-02). Only when dictation is on, a local model is
/// here (ready) and chosen — a cloud model has nothing to load.
fn prewarm(runner: &crate::scripts::Runner) {
    if !enabled() || *super::commands::READY.lock().unwrap() != Some(true) || server::running(server::ASR) {
        return;
    }
    let cloud = super::commands::MODELS.lock().unwrap().as_ref().is_some_and(super::flow::speech_models::selected_cloud);
    if cloud {
        return;
    }
    ASR_LOADING.store(true, SeqCst);
    let t0 = Instant::now();
    if server::ensure(runner, server::ASR, "transcribe.py", &ASR_ARGS).is_ok() {
        let ok = server::wait_ready(server::ASR, Duration::from_secs(120));
        eprintln!("dictation: speech model prewarmed ({ok}) in {:.1} s", t0.elapsed().as_secs_f64());
    }
    ASR_LOADING.store(false, SeqCst);
}

/// The trigger as the settings say (key, mode, double-tap send, Shift / Ctrl single or double).
fn make_trigger(p: &Prefs) -> DictationTrigger {
    let mut t = DictationTrigger::new(p.key, p.mode);
    t.double_tap_window = DictationTrigger::window(keys_win::double_tap_window());
    t.modifier_tap_shift = p.modifier_tap_shift;
    t.modifier_tap_command = p.modifier_tap_command;
    t.double_tap = p.double_tap_send;
    t
}

fn cancel_mods(p: &Prefs) -> u8 {
    match p.cancel_key {
        super::prefs::CancelKey::Esc => 0,
        super::prefs::CancelKey::CtrlEsc => 1,
        super::prefs::CancelKey::ShiftEsc => 2,
    }
}

/// When the config file was last written (the settings reload when it changes).
fn config_stamp() -> Option<std::time::SystemTime> {
    std::fs::metadata(paths::config_file()).and_then(|m| m.modified()).ok()
}

impl Engine {
    fn run(&mut self, rx: Receiver<Msg>) {
        loop {
            let wait = self
                .trigger
                .deadline()
                .map(|d| Duration::from_secs_f64((d - keys_win::now()).clamp(0.0, 5.0)))
                .unwrap_or(Duration::from_millis(250))
                .min(Duration::from_millis(250));
            match rx.recv_timeout(wait) {
                Ok(Msg::Key(k)) => {
                    if std::env::var_os("BLURT_DEBUG_KEYS").is_some() {
                        eprintln!("dictation: key {:#x} {} (enabled {})", k.code, if k.down { "down" } else { "up" }, enabled());
                    }
                    let time = k.tick_ms as f64 / 1000.0;
                    // a voice note listening: its Esc, and its Shift for Structured
                    if super::voice::key(k.code, k.down, time) {
                        continue;
                    }
                    let ours = self.trigger.key.codes().contains(&k.code);
                    if ours {
                        self.key_down = k.down;
                        crate::onboarding::dictation_key(&self.app, k.down); // the Welcome's "press it" check
                    } else if k.down {
                        self.last_key = k.code;
                        self.key_after_copy = true;
                    }
                    if !self.prefs.enabled {
                        continue;
                    }
                    // Ctrl+Esc / Shift+Esc chosen as the cancel key: a plain Esc is any other key to the trigger
                    let code = if k.code == vk::ESCAPE
                        && !self.prefs.cancel_key.matches(keys_win::held(0x11), keys_win::held(0x10))
                    {
                        PLAIN_ESCAPE
                    } else {
                        k.code
                    };
                    if k.down && k.code == vk::ESCAPE {
                        self.last_key = code;
                    }
                    let out = self.trigger.handle(Event::Key {
                        code,
                        down: k.down,
                        time,
                    });
                    self.apply(out);
                    self.missed();
                }
                Ok(Msg::Forwarded(code, down)) => {
                    if down == self.key_down || !self.prefs.enabled || !self.trigger.key.codes().contains(&code) {
                        continue; // the hook had it (or not the dictation key)
                    }
                    self.key_down = down;
                    crate::onboarding::dictation_key(&self.app, down);
                    let out = self.trigger.handle(Event::Key { code, down, time: keys_win::now() });
                    self.apply(out);
                }
                Ok(Msg::Frame(f)) => self.frame(f),
                Ok(Msg::Heard(n, slot, r, ms)) => self.heard(n, slot, r, ms),
                Ok(Msg::Context(n, c)) => {
                    if let Some(t) = self.take.as_mut().filter(|t| t.n == n) {
                        if let Some(s) = &t.stream {
                            let _ = s.send(StreamMsg::Header(c.as_ref().map(Context::asr_before).unwrap_or_default()));
                        }
                        t.context = c;
                    } else if let Some(t) = self.flight.iter_mut().find(|t| t.n == n) {
                        t.context = c;
                    }
                }
                Ok(Msg::Clash(apps)) => self.clash(apps),
                Ok(Msg::Action(a)) => self.action(&a),
                Ok(Msg::Delivered(d)) => self.delivered(d),
                Ok(Msg::ModelArrived) => {
                    if let Some(id) = self.no_model_take.take().filter(|id| self.failed.iter().any(|m| &m.id == id)) {
                        say(&self.app, "dictation.toast.model_ready", json!({}), keys::MODEL, 8000,
                            // the button says what it does now that the model is in: transcribe the kept recording
                            Some((format!("dictation.retry:{id}"), "dictation.toast.transcribe")), false);
                    }
                }
                Ok(Msg::ModelFailed) => say(&self.app, "dictation.toast.model_failed", json!({}), keys::MODEL, 8000,
                    Some(("dictation.download".to_string(), "dictation.toast.retry")), false),
                Ok(Msg::Reformat) => self.reformat_last(),
                Err(RecvTimeoutError::Timeout) => {}
                Err(RecvTimeoutError::Disconnected) => return,
            }
            self.tick();
            // an armed press that became a shortcut: give the mic back
            if self.take.is_none() && !self.trigger.armed_down() && self.mic.is_some() {
                self.close_mic();
            }
        }
    }

    /// What time does: the trigger's deadline, the 5-minute limit, a slow take, a take past its deadline, Undo's time
    /// running out, a tip coming up.
    /// The settings changed (Settings, the config file): read again — the key and how it starts apply at once (no
    /// relaunch), a take listening when its key changed stops as if the key came up (the Mac's
    /// `DictationFnClash.keyChangeEndsTake`), a change of mode waits for the take to stop.
    fn reload(&mut self) {
        if self.prefs_checked.elapsed() < Duration::from_millis(500) {
            return;
        }
        self.prefs_checked = Instant::now();
        let stamp = config_stamp();
        if stamp == self.prefs_stamp {
            return;
        }
        self.prefs_stamp = stamp;
        let new = Prefs::from_json(&cfg());
        if new == self.prefs {
            return;
        }
        let rebuild = new.trigger_changed(&self.prefs);
        let key_changed = new.key != self.prefs.key;
        self.prefs = new;
        keys_win::CANCEL_MODS.store(cancel_mods(&self.prefs), SeqCst);
        if rebuild {
            if self.take.is_some() && key_changed {
                self.trigger.reset(false, false);
                self.stop();
            }
            self.rebuild = true;
        }
        if !self.prefs.enabled && self.take.is_some() {
            self.cancel(true);
        }
    }

    fn tick(&mut self) {
        self.reload();
        if self.rebuild && self.take.is_none() && !self.trigger.armed_down() {
            self.rebuild = false;
            let pending = self.trigger.pending;
            self.trigger = make_trigger(&self.prefs);
            self.trigger.pending = pending;
            self.key_down = false;
        }
        let out = self.trigger.handle(Event::Tick { time: keys_win::now() });
        if !out.is_empty() {
            self.apply(out);
        }
        self.missed();
        if let Some(at) = self.miss_hold_at {
            if at.elapsed().as_secs_f64() >= self.trigger.double_tap_window + 0.15 {
                self.miss_hold_at = None;
                let sent_since = self.last_send_at.is_some_and(|s| s > at);
                if !sent_since && self.take.is_none() && !said_today("miss_hold") {
                    mark_said("miss_hold");
                    say(&self.app, "dictation.toast.hold_mode", json!({"key": key_label(self.trigger.key)}), "dictation.miss", 4000, None, false);
                }
            }
        }
        if self.take.as_ref().is_some_and(|t| t.started.elapsed().as_secs_f64() >= Runaway::LIMIT) {
            // the limit, said in place of "still listening"; the next tap (meant as the stop) doesn't start a take
            say(&self.app, "dictation.toast.limit", json!({}), keys::LISTENING, (DictationTrigger::LIMIT_GRACE * 1000.0) as u64, None, false);
            self.trigger.ended_by_itself(keys_win::now());
            self.stop();
        }
        // the oldest take still on its way 3 s after its stop: say so, with the way out
        let key = self.trigger.key;
        if let Some(t) = self.flight.front_mut() {
            if !t.slow_said && t.waiting() && t.stopped_at.is_some_and(|s| s.elapsed().as_secs_f64() >= flow::SLOW_AFTER) {
                t.slow_said = true;
                // the model is still loading (launch, or the server's first take after an idle hour): say that
                let msg = if ASR_LOADING.load(SeqCst) { "dictation.toast.slow.loading" } else { "dictation.toast.slow.asr" };
                say(&self.app, msg, json!({"cancel": self.prefs.cancel_key.label()}), keys::SLOW, 60_000, None, false);
            }
        }
        // a take never waits for its words forever: past its deadline it is too slow (the recording stays: Retry)
        let mut late = false;
        for t in self.flight.iter_mut() {
            let Some(s) = t.stopped_at else { continue };
            if t.waiting() && s.elapsed().as_secs_f64() >= TakeDeadline::seconds(t.duration) {
                for x in t.texts.iter_mut() {
                    x.get_or_insert_with(String::new);
                }
                for w in t.windows.iter_mut() {
                    w.1.get_or_insert(None);
                }
                if t.whole == Some(None) {
                    t.whole = Some(Some(Err("timeout".into())));
                }
                t.failed = Some("timeout".into());
                t.covered_last = false;
                drop_take(t.n);
                late = true;
            }
        }
        if late {
            self.finish_ready();
        }
        // Undo's time is over: the recordings of the takes Esc stopped go
        let gone: Vec<Meta> = {
            let (old, keep): (Vec<_>, Vec<_>) = std::mem::take(&mut self.cancelled)
                .into_iter()
                .partition(|(at, _)| at.elapsed().as_secs_f64() > flow::UNDO_SECONDS + 1.0);
            self.cancelled = keep;
            old.into_iter().map(|(_, m)| m).collect()
        };
        for m in gone {
            line().lock().unwrap().skipped.remove(&m.id);
            let _ = std::fs::remove_file(audio_dir().join(format!("{}.wav", m.id)));
        }
        // the tip after a take: a second later, never over another line, not after a send, not while listening
        if let Some((tip, at, stopped)) = self.tip {
            if Instant::now() >= at {
                self.tip = None;
                let sent_since = self.last_send_at.is_some_and(|s| s > stopped);
                if toast_idle() && !sent_since && self.take.is_none() {
                    let mut shown = tips_shown();
                    *shown.entry(tip.as_str().into()).or_insert(0) += 1;
                    save_tips(&shown);
                    match tip {
                        Tip::Send => say(&self.app, "dictation.tip.send", json!({"key": key_label(key)}), keys::TIP, 3000, None, true),
                        Tip::List => say(&self.app, "dictation.tip.list", json!({}), keys::TIP, 3000, None, true),
                        Tip::Reformat => {
                            if let Some(k) = reformat_key() {
                                say(&self.app, "dictation.tip.reformat", json!({"key": k}), keys::TIP, 3000, None, true)
                            }
                        }
                    }
                }
            }
        }
    }

    /// A press this mode doesn't use: how it starts. Tap mode's held press is said at once, while the key is still
    /// down, so the user lets go before talking into nothing; hold mode's tap once a day, after the double-tap window
    /// (it may be a double tap's first tap).
    fn missed(&mut self) {
        match self.trigger.take_miss() {
            Some(Miss::HeldInTapMode) => {
                say(&self.app, "dictation.toast.tap_mode", json!({"key": key_label(self.trigger.key)}), "dictation.miss", 4000, None, false)
            }
            Some(Miss::TappedInHoldMode) => self.miss_hold_at = Some(Instant::now()),
            None => {}
        }
    }

    fn apply(&mut self, out: Vec<Output>) {
        // a double tap's own cancel (it sends right after): quiet
        let sends = out.contains(&Output::Send);
        for o in out {
            match o {
                Output::Arm => self.arm(),
                Output::Start => self.begin(),
                Output::Stop => self.stop(),
                Output::Cancel => self.cancel(sends),
                Output::Send => self.send(),
                Output::Style => {
                    if self.take.is_some() && super::cloud::payload("polish").is_none() {
                        // nothing can make a list (Windows has no local polish model): say what it takes instead of
                        // switching to a style that would come out as said (the Mac's sayStylesNeedModel)
                        say(&self.app, "dictation.style.needs_cloud", json!({}), keys::STYLE, 6000,
                            Some(("dictation.cloud".to_string(), "dictation.translate.toast.setup")), false);
                    } else if let Some(t) = &mut self.take {
                        t.style = t.style.toggled(t.base);
                        t.style_toggles += 1;
                        note_used(Tip::List);
                        let to = t.style;
                        self.style_hint(to);
                    }
                    self.show();
                }
                Output::Translate => {
                    if self.take.is_some()
                        && super::cloud::payload("translate").or_else(|| super::cloud::payload("polish")).is_none()
                    {
                        // no service translates: say so (with Set Up…) and leave it off — never typed raw and then
                        // remembered as "translate stays on" (dogfood 11-02)
                        say(&self.app, "dictation.translate.toast.unavailable", json!({}), keys::STYLE, 6000,
                            Some(("dictation.cloud".to_string(), "dictation.translate.toast.setup")), false);
                    } else if let Some(t) = &mut self.take {
                        t.translate = !t.translate;
                        t.translate_toggles += 1;
                        let on = t.translate;
                        self.translate_hint(on);
                    }
                    self.show();
                }
            }
        }
        self.sync_pending();
    }

    /// What Shift did, the first two times it made a take Structured (the Mac's DictationStyleToggleHint: the ear's
    /// list mark says it after that).
    fn style_hint(&self, to: Style) {
        let shown = cfg().get("style_hint_shown").and_then(Value::as_i64).unwrap_or(0);
        if shown >= 2 {
            return;
        }
        let press = modifier_press("Shift", self.prefs.modifier_tap_shift == super::trigger::ModifierTap::Double);
        if to == Style::Structured {
            let _ = super::commands::set_dictation("style_hint_shown", json!(shown + 1));
            say(&self.app, "dictation.style.toast.structured", json!({"style": style_name(Style::Structured), "press": press}), keys::STYLE, 3000, None, false);
        } else {
            say(&self.app, "dictation.style.toast.back", json!({"style": style_name(to)}), keys::STYLE, 3000, None, false);
        }
    }

    /// What Ctrl did, the first two times it turned translate on (the Mac's DictationTranslateHint): which way it
    /// translates, and how to turn it off.
    fn translate_hint(&self, on: bool) {
        let shown = cfg().get("translate_hint_shown").and_then(Value::as_i64).unwrap_or(0);
        if shown >= 2 {
            return;
        }
        if !on {
            say(&self.app, "dictation.translate.toast.off", json!({}), keys::STYLE, 3000, None, false);
            return;
        }
        let _ = super::commands::set_dictation("translate_hint_shown", json!(shown + 1));
        let press = modifier_press("Ctrl", self.prefs.modifier_tap_command == super::trigger::ModifierTap::Double);
        let target = cfg().get("translate_target").and_then(Value::as_str).unwrap_or("auto").to_string();
        let into = target.split('|').next().unwrap_or("auto");
        if into == "auto" {
            // polish.py's Auto: Chinese ↔ English (the other one of the pair)
            say(&self.app, "dictation.translate.toast.on.auto", json!({"a": language_name("zh"), "b": language_name("en"), "press": press}), keys::STYLE, 3000, None, false);
        } else {
            say(&self.app, "dictation.translate.toast.on.into", json!({"lang": language_name(into), "press": press}), keys::STYLE, 3000, None, false);
        }
    }

    /// The trigger knows takes are on their way (a tap past the double-tap window starts the next one; Esc cancels).
    fn sync_pending(&mut self) {
        self.trigger.pending = !self.flight.is_empty() || line().lock().unwrap().busy();
    }

    fn open_mic(&mut self) -> bool {
        if self.mic.is_some() {
            return true;
        }
        let (ftx, frx) = channel::<Vec<f32>>();
        match Mic::open_named(ftx, self.prefs.mic.as_deref()) {
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
            let _ = server::ensure(&runner, server::ASR, "transcribe.py", &ASR_ARGS);
        });
    }

    fn begin(&mut self) {
        if *super::commands::READY.lock().unwrap() == Some(false) {
            say_no_model(&self.app, "dictation.toast.no_model", 6000);
            self.trigger.reset(false, true);
            self.close_mic();
            return;
        }
        if self.app.state::<AppState>().capture.recording() {
            say(&self.app, "dictation.toast.recording_busy", json!({}), keys::TAKE, 2400, None, false);
            self.trigger.reset(false, true);
            return;
        }
        if super::voice::active() {
            say(&self.app, "dictation.toast.voice_busy", json!({}), keys::TAKE, 2400, None, false);
            self.trigger.reset(false, true);
            self.close_mic();
            return;
        }
        if !self.open_mic() {
            mic_unavailable(&self.app);
            self.trigger.reset(false, true);
            return;
        }
        let n = self.next;
        self.next += 1;
        let wall = chrono::Local::now();
        let mut seg = DictationSegmenter::new(SR as f64);
        let audio: Vec<f32> = self.pre.drain(..).collect();
        seg.feed(&audio);
        #[cfg(target_os = "linux")]
        ins::prepare();
        let front = ins::front();
        let exe = front.as_ref().map(|f| f.exe.clone());
        let stem = exe.as_deref().map(apps::stem).unwrap_or_default();
        // the style: the app in front decides the base now (with what was remembered for it); Shift (or the island)
        // can still make it Structured. Translate starts on in an app it was left on in.
        let base = self.prefs.styles.base(exe.as_deref());
        let translate_cfg = cfg().get("translate").cloned();
        let translate = !stem.is_empty() && super::prefs::remember::translates(translate_cfg.as_ref(), &stem);
        let (cloud, streams, model) = super::commands::MODELS.lock().unwrap().as_ref().map_or((false, false, None), |v| {
            (super::flow::speech_models::selected_cloud(v), super::flow::speech_models::streams(v), v["selected"].as_str().map(String::from))
        });
        // Volcengine hears the take while it is said: the pre-roll goes now, the field's text when it is read
        let stream = streams.then(|| {
            let (tx, rx) = channel::<StreamMsg>();
            let _ = tx.send(StreamMsg::Pcm(self.pre.iter().copied().collect()));
            stream_take(self.app.clone(), self.tx.clone(), n, rx, json!({"model_id": model, "language": cfg().get("language").and_then(Value::as_str).unwrap_or("auto"),
                "vocab": true, "app": front.as_ref().map(display_name).unwrap_or_default(), "purpose": "dictation"}));
            tx
        });
        let name = front.as_ref().map(display_name).unwrap_or_default();
        self.remind_remembered(&stem, &name, base, translate);
        self.take = Some(Take {
            n,
            id: format!(
                "d-{}-{:04x}",
                wall.format("%Y%m%d-%H%M%S"),
                (n as u32).wrapping_mul(2654435761) >> 16
            ),
            started: Instant::now(),
            wall,
            front: front.clone(),
            audio,
            seg,
            pieces: vec![],
            hard: vec![],
            next_start: 0,
            texts: vec![],
            covered_last: false,
            planner: Planner::new(self.prefs.rehear_window, SR as f64),
            windows: vec![],
            whole: None,
            asr_ms: 0,
            failed: None,
            stopped_at: None,
            slow_said: false,
            send: false,
            style: base,
            base,
            translate,
            style_toggles: 0,
            translate_toggles: 0,
            cloud,
            spoke: false,
            stream,
            peak: 0.0,
            frames: 0,
            runaway: Runaway::new(),
            context: None,
            duration: 0.0,
        });
        // Esc is Blurt's while the take listens
        keys_win::ESC_DICTATION.store(true, SeqCst);
        // what the island said about the last take (nothing heard, copied, its tip, "still listening", "still
        // recognizing") is over — not a failed take's Retry or "Cancelled · Undo"
        drop_toasts(&self.app, &keys::DROPPED_AT_START);
        self.tip = None;
        // the field around the cursor, read while the user talks (UI Automation calls can take a moment)
        if self.prefs.context {
            let tx = self.tx.clone();
            let f = front.clone();
            std::thread::spawn(move || {
                let _ = tx.send(Msg::Context(n, read_context(f.as_ref())));
            });
        }
        // the other dictation apps: said once this take stops listening
        {
            let tx = self.tx.clone();
            std::thread::spawn(move || {
                let _ = tx.send(Msg::Clash(apps::clash_apps(&ins::running_exes())));
            });
        }
        // the start's peep comes with the first audio (the mic really listens: "talk now", not "key seen")
        self.show();
    }

    fn frame(&mut self, f: Vec<f32>) {
        let lvl = mic::level(&f);
        let push_to_talk = self.trigger.push_to_talk();
        let rehear = self.prefs.rehear;
        let Some(t) = &mut self.take else {
            // armed: keep the last half second
            self.pre.extend(f);
            while self.pre.len() > PRE_ROLL {
                self.pre.pop_front();
            }
            return;
        };
        t.peak = t.peak.max(lvl);
        if let Some(s) = &t.stream {
            let _ = s.send(StreamMsg::Pcm(f.clone()));
        }
        if t.frames == 0 {
            sound(&self.app, "start", self.prefs.start_sound);
        }
        t.frames += 1;
        t.audio.extend_from_slice(&f);
        let cuts = t.seg.feed(&f);
        t.spoke |= t.seg.piece_has_speech();
        let mut jobs: Vec<(Slot, usize, usize, usize)> = vec![];
        // a cloud model hears the whole take at key-up: no pieces (the segmenter still tells speech from quiet)
        for c in cuts.into_iter().filter(|_| !t.cloud) {
            let start = t.next_start.min(c.end);
            t.next_start = c.next_start;
            t.pieces.push((start, c.end));
            t.hard.push(c.hard);
            t.texts.push(None);
            let i = t.pieces.len() - 1;
            jobs.push((Slot::Piece(i), start, c.end, i));
            if rehear {
                for w in t.planner.piece(i, start, c.end, c.hard) {
                    if w.len() > 1 {
                        let (s, e, first) = (w.start, w.end, w.first);
                        t.windows.push((w, None));
                        jobs.push((Slot::Window(t.windows.len() - 1), s, e, first));
                    }
                }
            }
        }
        // the runaway take: talking now is the last speech under half a second ago
        let elapsed = t.started.elapsed().as_secs_f64();
        let notice = t.runaway.feed(elapsed, t.seg.quiet_seconds() < 0.5, !push_to_talk);
        let n = t.n;
        for (slot, s, e, first) in jobs {
            self.queue_job(n, slot, s, e, first);
        }
        match notice {
            Some(RunawayNotice::StillListening) => say(
                &self.app,
                "dictation.toast.still_listening",
                json!({"key": key_label(self.trigger.key), "cancel": self.prefs.cancel_key.label()}),
                keys::LISTENING,
                4000,
                None,
                true,
            ),
            Some(RunawayNotice::EndsSoon) => {
                say(&self.app, "dictation.toast.ends_soon", json!({}), keys::LISTENING, 3000, None, true);
                self.show();
            }
            None => {}
        }
        if self.level_at.elapsed() > Duration::from_millis(60) {
            self.level_at = Instant::now();
            island::send(&self.app, json!({"op": "level", "rms": lvl * 0.12}));
        }
    }

    /// A piece's or a window's audio to the speech worker. `first`: the first piece it covers (its context is the
    /// text before it).
    fn queue_job(&self, n: u64, slot: Slot, s: usize, e: usize, first: usize) {
        let t = self
            .take
            .as_ref()
            .filter(|t| t.n == n)
            .or_else(|| self.flight.iter().find(|t| t.n == n));
        let Some(t) = t else { return };
        let dir = audio_dir().join("pieces");
        let _ = std::fs::create_dir_all(&dir);
        let name = match slot {
            Slot::Piece(i) => format!("{}-{i}.wav", t.id),
            Slot::Window(k) => format!("{}-w{k}.wav", t.id),
            Slot::Whole => unreachable!(),
        };
        let wav = dir.join(name);
        let samples = &t.audio[s.min(t.audio.len())..e.min(t.audio.len())];
        if mic::write_wav(&wav, samples).is_ok() {
            let _ = self.asr.send(Job {
                n,
                slot,
                wav,
                prior: t.prior(first),
                before: t.before(),
                temp: true,
            });
        }
    }

    fn stop(&mut self) {
        let Some(mut t) = self.take.take() else {
            return;
        };
        keys_win::ESC_DICTATION.store(false, SeqCst);
        t.stopped_at = Some(Instant::now());
        t.duration = t.audio.len() as f64 / SR as f64;
        let (start, end) = (t.next_start, t.audio.len());
        let last_piece = end > start + SR / 5 && !t.cloud;
        // a cloud model: the whole recording, once, at key-up (with the field's text before the cursor)
        let whole = t.cloud && t.spoke;
        let streamed = t.stream.is_some();
        if whole || streamed {
            t.whole = Some(None);
        }
        // the stream's end: its answer comes as the take's whole
        if let Some(s) = t.stream.take() {
            let _ = s.send(if t.spoke { StreamMsg::End } else { StreamMsg::Drop });
            if !t.spoke {
                t.whole = None;
            }
        }
        if last_piece {
            t.pieces.push((start, end));
            t.hard.push(false);
            t.texts.push(None);
        }
        let mut jobs: Vec<(Slot, usize, usize, usize)> = vec![];
        let np = t.pieces.len();
        if self.prefs.rehear && np > 0 {
            // the open window (the pieces since the last one) is what is left: heard once, the last piece only there
            let (s, e) = t.pieces[np - 1];
            let w = t.planner.finish(np - 1, s, e);
            if w.len() > 1 {
                let (ws, we, first) = (w.start, w.end, w.first);
                t.windows.push((w, None));
                jobs.push((Slot::Window(t.windows.len() - 1), ws, we, first));
                t.covered_last = last_piece;
            }
        }
        if last_piece && !t.covered_last {
            jobs.push((Slot::Piece(np - 1), start, end, np - 1));
        }
        let n = t.n;
        let _ = std::fs::create_dir_all(audio_dir());
        let _ = mic::write_wav(&t.wav(), &t.audio);
        if whole && !streamed {
            let _ = self.asr.send(Job { n, slot: Slot::Whole, wav: t.wav(), prior: String::new(), before: t.before(), temp: false });
        }
        self.flight.push_back(t);
        for (slot, s, e, first) in jobs {
            self.queue_job(n, slot, s, e, first);
        }
        self.close_mic();
        sound(&self.app, "stop", self.prefs.stop_sound);
        self.listening_ended();
        self.show();
        self.finish_ready();
    }

    /// The take stopped listening (stopped, cancelled, ended by itself): Shift's line goes, a notice held back is said.
    fn listening_ended(&mut self) {
        keys_win::ESC_DICTATION.store(false, SeqCst);
        drop_toasts(&self.app, &keys::DROPPED_WHEN_LISTENING_ENDS);
        if let Some(apps) = self.clash_after_take.take() {
            self.say_clash(&apps, true);
        }
    }

    /// Esc, a double tap's second tap: ends a take that is listening (nothing kept) — or, when none listens, stops
    /// the takes still on their way (never typed, a queued Return dropped), with Undo. `quiet`: the double tap's own
    /// cancel (it sends right after), or a shortcut that joined push-to-talk in its first second.
    fn cancel(&mut self, quiet: bool) {
        if let Some(t) = self.take.take() {
            let esc = self.last_key == vk::ESCAPE;
            let quiet = quiet
                || DictationTrigger::joined_early(esc, true, t.started.elapsed().as_secs_f64(), t.pieces.len());
            drop_take(t.n);
            self.close_mic();
            self.listening_ended();
            island::send(&self.app, json!({"op": "live", "text": ""}));
            if !quiet {
                sound(&self.app, "cancel", self.prefs.stop_sound);
                say(&self.app, "dictation.toast.cancelled", json!({}), keys::CANCEL, 1200, None, false);
            }
            self.show();
            return;
        }
        let stopped = self.cancel_pending();
        if !stopped.is_empty() && !quiet {
            say(
                &self.app,
                "dictation.toast.cancelled",
                json!({}),
                keys::CANCEL,
                (flow::UNDO_SECONDS * 1000.0) as u64,
                Some((format!("dictation.undo:{}", stopped.join(",")), "dictation.toast.undo")),
                false,
            );
        }
        self.show();
    }

    /// The takes still on their way stop (never typed). One being polished goes in as heard instead; a paste already
    /// under way can't be taken back, but its queued Return is dropped. The stopped takes keep their recording for
    /// Undo's time. → the ids stopped.
    fn cancel_pending(&mut self) -> Vec<String> {
        let mut stopped = vec![];
        self.reformat_after = None;
        {
            let mut l = line().lock().unwrap();
            if l.current.is_some() {
                if l.polishing {
                    l.skip_polish = true;
                } else {
                    l.send_cancelled = true;
                }
            }
            let queued: Vec<String> = l.queued.iter().cloned().collect();
            for id in queued {
                l.cancelled.insert(id.clone());
                l.send.remove(&id);
                stopped.push(id);
            }
        }
        for id in &stopped {
            if let Some(m) = self.handed.iter().find(|m| &m.id == id).cloned() {
                self.cancelled.push((Instant::now(), m));
            }
        }
        for t in std::mem::take(&mut self.flight) {
            drop_take(t.n);
            stopped.push(t.id.clone());
            self.cancelled.push((Instant::now(), t.meta()));
        }
        drop_toasts(&self.app, &[keys::SLOW]);
        island::send(&self.app, json!({"op": "live", "text": ""}));
        stopped
    }

    /// A double tap: Return in the app in front ("send"). After the takes still on their way, once the last one has
    /// been pasted; otherwise now — only right after a take typed into the app still in front.
    fn send(&mut self) {
        if let Some(t) = self.flight.back_mut() {
            t.send = true; // Return goes in once its text is in
            return;
        }
        {
            let mut l = line().lock().unwrap();
            if let Some(id) = l.queued.back().cloned().or_else(|| l.current.clone()) {
                l.send.insert(id);
                return;
            }
        }
        // the last take is only on the clipboard and nothing was pressed since: Return would go where nothing was
        // pasted
        if let Some(c) = self.copied_at {
            if CopiedGuard::holds_return(Some(0.0), self.key_after_copy, c.elapsed().as_secs_f64()) {
                match &self.no_field_take {
                    // no field took the last take: Return would open the file selected in Explorer, or do nothing at
                    // all — not sent, with its Copy
                    Some(id) => say(&self.app, "dictation.toast.not_sent.no_field", json!({}), keys::TAKE, 6000,
                                    Some((format!("dictation.copy:{id}"), "dictation.toast.copy")), false),
                    None => say(&self.app, "dictation.toast.copied.not_sent", json!({}), keys::TAKE, 4000, None, false),
                }
                return;
            }
        }
        let now = ins::front();
        let last = self.last_paste.as_ref().map(|(_, exe)| (0.0, exe.as_deref()));
        let since = self.last_paste.as_ref().map_or(f64::INFINITY, |(at, _)| at.elapsed().as_secs_f64());
        if SendRule::decide(false, last, now.as_ref().map(|f| f.exe.as_str()), since) != SendVerdict::Send {
            return; // nothing dictated just before, in this app: no Return
        }
        let ours = now.as_ref().is_some_and(|f| f.pid == std::process::id());
        let blocked = now.as_ref().is_some_and(|f| !ours && ins::blocks_input(f.pid));
        let password = ins::focus_read(false).is_some_and(|f| f.password);
        match send_policy::decide(now.is_some(), ours, password, !blocked) {
            send_policy::Decision::Press => {
                ins::press_return();
                self.last_send_at = Some(Instant::now());
                note_used(Tip::Send);
                say_sent(&self.app);
            }
            send_policy::Decision::Skip { reason } => send_skipped(&self.app, Some(reason)),
        }
    }

    fn heard(&mut self, n: u64, slot: Slot, r: Result<String, String>, ms: u64) {
        if dropped(n) {
            return;
        }
        let listening = self.take.as_ref().is_some_and(|t| t.n == n);
        let t = if listening {
            self.take.as_mut()
        } else {
            self.flight.iter_mut().find(|t| t.n == n)
        };
        let Some(t) = t else { return };
        t.asr_ms += ms;
        match slot {
            Slot::Piece(i) => match r {
                Ok(s) => {
                    let s = after_hard_cut(&t.hard, &t.texts, i, s);
                    if let Some(x) = t.texts.get_mut(i) {
                        *x = Some(s);
                    }
                }
                Err(code) => {
                    if let Some(x) = t.texts.get_mut(i) {
                        *x = Some(String::new());
                    }
                    t.failed.get_or_insert(code);
                }
            },
            Slot::Window(k) => {
                let covers_last = t.covered_last && t.windows.get(k).is_some_and(|(w, _)| w.last + 1 == t.texts.len());
                let answer = match r {
                    Ok(s) if !s.trim().is_empty() => Some(s.trim().to_string()),
                    Ok(_) => {
                        // nothing for heard speech: the pieces' transcripts stay (a covered piece: the safety path)
                        if covers_last {
                            t.failed.get_or_insert("empty_window".into());
                        }
                        None
                    }
                    Err(code) => {
                        if covers_last {
                            t.failed.get_or_insert(code);
                        }
                        None
                    }
                };
                if let Some(w) = t.windows.get_mut(k) {
                    w.1 = Some(answer);
                }
                if covers_last && t.windows[k].1 == Some(None) {
                    // the covered piece has no transcript of its own: the whole recording decides
                    t.covered_last = false;
                    if let Some(x) = t.texts.last_mut() {
                        x.get_or_insert_with(String::new);
                    }
                }
            }
            // the stream couldn't be opened (no server yet, a dropped connection): the whole recording, sent once
            Slot::Whole if r.as_ref().err().is_some_and(|c| c == "stream_failed") => {
                let job = Job { n, slot: Slot::Whole, wav: t.wav(), prior: String::new(), before: t.before(), temp: false };
                let _ = self.asr.send(job);
            }
            Slot::Whole => t.whole = Some(Some(r)),
        }
        if listening {
            let live = t.live();
            island::send(&self.app, json!({"op": "live", "text": live}));
        }
        self.finish_ready();
    }

    /// Hand the oldest stopped takes whose words are all in to the paste worker, in order — or say what went wrong.
    fn finish_ready(&mut self) {
        while let Some(t) = self.flight.front_mut() {
            if t.waiting() {
                break;
            }
            // a piece failed: the whole recording once more (not for an answer a second run would only repeat)
            if t.failed.is_some() && t.whole.is_none() && !AsrFailure::definite(t.failed.as_deref()) {
                t.whole = Some(None);
                let job = Job {
                    n: t.n,
                    slot: Slot::Whole,
                    wav: t.wav(),
                    prior: String::new(),
                    before: t.before(),
                    temp: false,
                };
                let _ = self.asr.send(job);
                break;
            }
            let t = self.flight.pop_front().unwrap();
            let outcome: Result<String, String> = match &t.whole {
                Some(Some(Ok(s))) => Ok(s.trim().to_string()),
                Some(Some(Err(code))) => Err(code.clone()),
                _ => match &t.failed {
                    Some(code) if AsrFailure::definite(Some(code)) => Err(code.clone()),
                    _ => {
                        let wins: Vec<(Window, Option<String>)> =
                            t.windows.iter().map(|(w, r)| (w.clone(), r.clone().flatten())).collect();
                        Ok(rehear::typed(&t.texts, &wins, &t.pauses())
                            .unwrap_or_else(|| t.texts.iter().flatten().cloned().collect::<Vec<_>>().join("")))
                    }
                },
            };
            match outcome {
                Err(code) => self.recognition_failed(&t, &code),
                Ok(raw) if raw.trim().is_empty() => {
                    if self.reformat_after.as_deref() == Some(t.id.as_str()) {
                        self.reformat_after = None;
                    }
                    // nothing heard: the mic it listened with, and its recording goes
                    let _ = std::fs::remove_file(t.wav());
                    island::send(&self.app, json!({"op": "live", "text": ""}));
                    let silent = nothing_heard::silent_mic(t.peak, t.frames);
                    let name = (!self.mic_name.is_empty()).then(|| self.mic_name.clone());
                    say(
                        &self.app,
                        nothing_heard::key(silent, name.is_some()),
                        json!({"mic": name.unwrap_or_default()}),
                        keys::TAKE,
                        4000,
                        Some(("dictation.mic".to_string(), "dictation.toast.nothing.change")),
                        false,
                    );
                }
                Ok(raw) => {
                    self.handed.push_back(t.meta());
                    while self.handed.len() > 8 {
                        self.handed.pop_front();
                    }
                    line().lock().unwrap().queued.push_back(t.id.clone());
                    let _ = self.paste.send(Done {
                        id: t.id.clone(),
                        wall: t.wall,
                        front: t.front.clone(),
                        raw,
                        send: t.send,
                        style: t.style,
                        translate: t.translate,
                        duration: t.duration,
                        keep_audio: self.prefs.keep_audio,
                        keep_history: self.prefs.keep_history,
                        cancel_label: self.prefs.cancel_key.label(),
                        asr_ms: t.asr_ms,
                        stopped_at: t.stopped_at.unwrap_or_else(Instant::now),
                        pieces: t.texts.len(),
                        windows: t.windows.iter().filter(|(_, r)| matches!(r, Some(Some(_)))).count(),
                        wav: t.wav(),
                        context: t.context.clone(),
                        style_toggles: t.style_toggles,
                        translate_toggles: t.translate_toggles,
                        looped: LOOPED.lock().unwrap().as_mut().is_some_and(|l| l.remove(&t.n)),
                    });
                }
            }
        }
        if self.flight.is_empty() && !line().lock().unwrap().busy() {
            drop_toasts(&self.app, &[keys::SLOW]);
        }
        self.sync_pending();
        self.show();
    }

    /// The speech model couldn't recognise the take: its recording stays, a history row says so, the island says
    /// what failed — with Retry (or Download… when there is no model).
    fn recognition_failed(&mut self, t: &Take, code: &str) {
        if self.reformat_after.as_deref() == Some(t.id.as_str()) {
            self.reformat_after = None;
        }
        let f = AsrFailure::from_code(Some(code));
        island::send(&self.app, json!({"op": "live", "text": ""}));
        failed_history(t, &f.code());
        super::history::changed(&self.app);
        self.failed.push_back(t.meta());
        while self.failed.len() > 5 {
            self.failed.pop_front();
        }
        if f == AsrFailure::NoModel {
            *super::commands::READY.lock().unwrap() = Some(false);
            // once the model is in, this take gets Retry (`model_arrived`)
            self.no_model_take = Some(t.id.clone());
            say_no_model(&self.app, "dictation.toast.no_model.kept", 8000);
            return;
        }
        let l = f.line();
        let action = if l.retry_helps() {
            (format!("dictation.retry:{}", t.id), "dictation.toast.retry")
        } else {
            ("dictation.settings".to_string(), "dictation.toast.asr_cloud_key.action")
        };
        say(&self.app, l.key(), json!({}), &keys::failed(&t.id), 8000, Some(action), false);
    }

    /// Hear a take's whole recording again (Retry, Undo) and type it like any take — into the app in front then.
    fn hear_again(&mut self, m: Meta) {
        let wav = audio_dir().join(format!("{}.wav", m.id));
        if !wav.is_file() {
            say(&self.app, "dictation.toast.retry_gone", json!({}), &keys::failed(&m.id), 3000, None, false);
            return;
        }
        let n = self.next;
        self.next += 1;
        let t = Take {
            n,
            id: m.id.clone(),
            started: Instant::now(),
            wall: m.wall,
            front: m.front.clone(),
            audio: vec![],
            seg: DictationSegmenter::new(SR as f64),
            pieces: vec![],
            hard: vec![],
            next_start: 0,
            texts: vec![],
            covered_last: false,
            planner: Planner::new(self.prefs.rehear_window, SR as f64),
            windows: vec![],
            whole: Some(None),
            asr_ms: 0,
            failed: None,
            stopped_at: Some(Instant::now()),
            slow_said: false,
            send: false,
            style: m.style,
            base: m.style,
            translate: m.translate,
            style_toggles: 0,
            translate_toggles: 0,
            cloud: false,
            spoke: true,
            stream: None,
            peak: 1.0,
            frames: 0,
            runaway: Runaway::new(),
            context: None,
            duration: m.duration,
        };
        let _ = self.asr.send(Job { n, slot: Slot::Whole, wav, prior: String::new(), before: AsrCtx::default(), temp: false });
        self.flight.push_back(t);
        self.sync_pending();
        self.show();
    }

    fn action(&mut self, a: &str) {
        let (verb, arg) = a.split_once(':').unwrap_or((a, ""));
        match verb {
            // "Cancelled · Undo": the takes Esc stopped go on as if it hadn't come
            "dictation.undo" => {
                drop_toasts(&self.app, &[keys::CANCEL]);
                for id in arg.split(',').filter(|s| !s.is_empty()) {
                    let Some(ix) = self.cancelled.iter().position(|(_, m)| m.id == id) else { continue };
                    let (_, m) = self.cancelled.remove(ix);
                    let resumed = {
                        let mut l = line().lock().unwrap();
                        // still waiting in the paste worker's line: it simply goes in
                        l.cancelled.remove(id) && !l.skipped.remove(id)
                    };
                    if !resumed {
                        line().lock().unwrap().skipped.remove(id);
                        self.hear_again(m);
                    }
                }
            }
            // Linux: Remote Desktop access. GNOME opens the dialog over the window given as its parent: the island,
            // always on top — Blurt can't bring its main window forward right after the user typed elsewhere (GNOME's
            // focus-stealing prevention only says "Blurt is ready"), and an unparented dialog lands behind the app
            #[cfg(target_os = "linux")]
            "dictation.allow_typing" => {
                drop_toasts(&self.app, &[keys::TAKE]);
                let app = self.app.clone();
                std::thread::spawn(move || {
                    let parent = crate::mainwin::x11_id_off_main(&app, "blurt-overlay-island")
                        .or_else(|| crate::mainwin::x11_id_off_main(&app, "main"));
                    let (msg, ms) = match ins::request_access(parent) {
                        Ok(()) => ("dictation.toast.typing_allowed", 3000),
                        Err(e) if e == "no_keyboard" => ("dictation.toast.typing_interaction_off", 8000),
                        Err(_) => ("dictation.toast.typing_not_allowed", 5000),
                    };
                    say(&app, msg, json!({}), keys::TAKE, ms, None, false);
                });
            }
            "dictation.retry" => {
                let k = keys::failed(arg);
                drop_toasts(&self.app, &[k.as_str()]);
                if let Some(ix) = self.failed.iter().position(|m| m.id == arg) {
                    let m = self.failed.remove(ix).unwrap();
                    self.hear_again(m);
                } else {
                    say(&self.app, "dictation.toast.retry_gone", json!({}), keys::TAKE, 3000, None, false);
                }
            }
            // Copy / Copy Again: the take's text on the clipboard
            "dictation.copy" => {
                let text = TEXTS.lock().unwrap().iter().find(|(i, _)| i == arg).map(|(_, t)| t.clone());
                if let Some(t) = text {
                    ins::set_text(&t);
                    say(&self.app, "dictation.toast.copied.done", json!({}), keys::TAKE, 2400, None, false);
                }
            }
            // Windows' microphone privacy page, or its Sound settings
            "dictation.open" => {
                use tauri_plugin_opener::OpenerExt;
                let url = if arg == "privacy" { "ms-settings:privacy-microphone" } else { "ms-settings:sound" };
                let _ = self.app.opener().open_url(url, None::<&str>);
            }
            // "Download…": what is missing, through the one downloader (commands.rs `model_download`)
            "dictation.download" => {
                // a cloud model chosen without its key: nothing to download — Settings → Speech services
                if super::commands::MODELS.lock().unwrap().as_ref().is_some_and(super::flow::speech_models::needs_key) {
                    return self.open_settings("speech/speech.services");
                }
                let get = super::commands::MODELS.lock().unwrap().as_ref().and_then(super::flow::speech_models::to_get);
                match get {
                    Some((id, choose)) => {
                        if choose {
                            let _ = super::commands::set_dictation("asr_model", json!(id));
                        }
                        let size = model_size(&id);
                        match super::commands::model_download(self.app.clone(), id) {
                            Ok(()) => say(&self.app, if size.is_some() { "dictation.toast.model_started.size" } else { "dictation.toast.model_started" },
                                          json!({"key": key_label(self.trigger.key), "size": size.unwrap_or_default()}), keys::MODEL, 5000,
                                          Some(("dictation.models".to_string(), "dictation.toast.model_downloading.action")), false),
                            // one is coming down already: how far it is
                            Err(_) if super::commands::downloading() => say_no_model(&self.app, "dictation.toast.no_model", 4000),
                            Err(e) => {
                                eprintln!("dictation: download didn't start: {e}");
                                say(&self.app, "dictation.toast.model_failed", json!({}), keys::MODEL, 8000,
                                    Some(("dictation.download".to_string(), "dictation.toast.retry")), false)
                            }
                        }
                    }
                    None => self.open_settings("speech/speech.models"),
                }
            }
            "dictation.models" => self.open_settings("speech/speech.models"),
            // reformat-last's Undo: back to the style it was typed in
            "dictation.reformat_undo" => {
                let original = LAST.lock().unwrap().as_ref().map(|l| l.original);
                if let Some(o) = original {
                    reformat(self.app.clone(), Some(o), true);
                }
            }
            // "Sounds like a list · Make a List"
            "dictation.make_list" => reformat(self.app.clone(), Some(Style::Structured), false),
            // "Format spoken lists in WeChat from now on? · Yes": the app's own style, marked learned
            "dictation.learn_style" => {
                if let Some((app_stem, st)) = arg.split_once('|') {
                    if let Some(style) = Style::from_config(st) {
                        let mut c = cfg().get("styles").cloned().filter(Value::is_object).unwrap_or(json!({}));
                        if !c["apps"].is_object() {
                            c["apps"] = json!({});
                        }
                        c["apps"][app_stem] = json!(style.as_str());
                        let mut learned: Vec<String> = c["learned"].as_array().map(|a| a.iter().filter_map(|x| x.as_str().map(String::from)).collect()).unwrap_or_default();
                        if !learned.iter().any(|x| x == app_stem) {
                            learned.push(app_stem.to_string());
                        }
                        c["learned"] = json!(learned);
                        let _ = super::commands::set_dictation("styles", c);
                        say(&self.app, "dictation.style.learn.done", json!({}), keys::NOTICE, 3000, None, false);
                    }
                }
            }
            // "Learned “X” · Undo": the word goes again
            "dictation.forget" => {
                let _ = super::commands::dictation_words_edit("remove".into(), arg.to_string(), None);
            }
            "dictation.mic" => self.open_settings("dictation/mic"),
            "dictation.cloud" => self.open_settings("speech/speech.services"),
            "dictation.settings" => self.open_settings("speech/speech.services"),
            // "Typeless is also running · Settings…": where the dictation key is chosen
            "dictation.keys" => self.open_settings("dictation/dictation.key"),
            _ => {}
        }
    }

    /// Typeless or Wispr Flow running beside Blurt: both may react to the same key and the text can go in twice.
    fn clash(&mut self, running: Vec<String>) {
        if !self.prefs.enabled {
            return;
        }
        let apps = Clash::to_mention(&running, |a| said_today(&format!("fn_clash_{}", apps::stem(a))));
        match Clash::moment(&apps, self.take.is_some()) {
            ClashMoment::None => {}
            ClashMoment::AfterTake => self.clash_after_take = Some(apps),
            ClashMoment::Now => self.say_clash(&apps, false),
        }
    }

    fn say_clash(&self, apps: &[String], after_take: bool) {
        for a in apps {
            mark_said(&format!("fn_clash_{}", apps::stem(a)));
        }
        let sep = if crate::l10n::lang() == "zh-Hans" { "、" } else { ", " };
        say(
            &self.app,
            "dictation.toast.fn_clash",
            json!({"apps": apps.join(sep)}),
            keys::CLASH,
            8000,
            Some(("dictation.keys".to_string(), "dictation.translate.toast.setup")),
            after_take,
        );
    }

    /// The paste worker is done with a take.
    fn delivered(&mut self, d: Delivered) {
        self.handed.retain(|m| m.id != d.id);
        // Alt+Shift+L pressed while this take was on its way: it meant this one — only when it was typed
        // typed: pasted into a field (a paste that found no field went nowhere)
        let typed = d.result == "pasted" && !d.no_field;
        if self.reformat_after.as_deref() == Some(d.id.as_str()) {
            self.reformat_after = None;
            if typed {
                reformat(self.app.clone(), None, false);
            }
        }
        if d.result != "cancelled" {
            if typed {
                self.last_paste = Some((Instant::now(), d.exe.clone()));
            }
            // only on the clipboard, or kept on the island with no field to go into: a double tap holds its Return
            self.copied_at = (d.result == "copied" || d.no_field).then(Instant::now);
            self.no_field_take = d.no_field.then(|| d.id.clone());
            self.key_after_copy = false;
            if d.sent {
                self.last_send_at = Some(Instant::now());
                note_used(Tip::Send);
            }
            if typed {
                // the first takes' tips
                let mut tips = tips_shown();
                *tips.entry("takes".into()).or_insert(0) += 1;
                save_tips(&tips);
                let chat = apps::category(d.exe.as_deref()) == apps::Category::Chat;
                if !d.app_changed {
                    self.remember(&d);
                    // Shift / the island switched it: a signal for the app's style
                    if let (Some(st), true) = (d.style, d.style_toggles > 0) {
                        style_signal(&self.app, &d.start_app, &d.start_app_name, &d.id, st);
                    }
                }
                if !d.start_app.is_empty() {
                    self.last_take_in.insert(d.start_app.clone(), Instant::now());
                }
                // a notice once a day (a key refused, a weaker model ran), else one of the first takes' tips, else the
                // one cloud-polish reminder
                if !self.notice_after(&d) {
                    // the reformat tip only where the key is set
                    let tip = Tip::next(chat, self.trigger.double_tap, d.sent || d.send_asked, &tips)
                        .filter(|t| *t != Tip::Reformat || reformat_key().is_some());
                    match tip {
                        Some(tip) if !d.had_line => {
                            self.tip = Some((tip, Instant::now() + Duration::from_secs(1), d.stopped_at.unwrap_or_else(Instant::now)));
                        }
                        _ => self.remind_cloud(tips.get("takes").copied().unwrap_or(0), &d),
                    }
                }
            }
        }
        if self.flight.is_empty() && !line().lock().unwrap().busy() {
            drop_toasts(&self.app, &[keys::SLOW]);
        }
        self.sync_pending();
        self.show();
    }

    /// Alt+Shift+L: not while a take listens (Shift is the style key then); while one is on its way it means that
    /// take, once it is in (the Mac's DictationReformatAfterPaste).
    fn reformat_last(&mut self) {
        if self.take.is_some() {
            return;
        }
        note_used(Tip::Reformat);
        let waiting = self.flight.back().map(|t| t.id.clone()).or_else(|| {
            let l = line().lock().unwrap();
            l.queued.back().cloned().or_else(|| l.current.clone())
        });
        match waiting {
            Some(id) => self.reformat_after = Some(id),
            None => reformat(self.app.clone(), None, false),
        }
    }

    /// Settings in the main window (SettingsView's `nav`): "pane" or "pane/row" (dictation/mic, speech/speech.models).
    fn open_settings(&self, link: &str) {
        use tauri::Emitter;
        crate::show_main(&self.app);
        let _ = self.app.emit("nav", json!({"view": "settings", "pane": link}));
    }

    /// After a typed take: what Shift / Ctrl switched stays on in the app it started in (the Mac's
    /// DictationRemembering, `learn_styles`, on); said the first three times.
    fn remember(&mut self, d: &Delivered) {
        let c = cfg();
        if d.start_app.is_empty() || c.get("learn_styles").and_then(Value::as_bool) == Some(false) {
            return;
        }
        let (mut structured, mut translated) = (false, false);
        // Structured switched on but no list came of it (no cloud model, the pass fell back): nothing to remember —
        // the app must not be left "structured" by a take that wasn't
        if let Some(style) = d.style.filter(|s| *s != Style::Structured || d.list) {
            if let Some(v) = super::prefs::remember::style(style, d.style_toggles, c.get("styles"), &d.start_app) {
                structured = v["apps"][&d.start_app] == "structured";
                let _ = super::commands::set_dictation("styles", v);
            }
        }
        // translate switched on and nothing was translated (no service, it failed): not remembered either
        let translate_ok = !d.translate || d.translated;
        if let Some(v) = translate_ok.then(|| super::prefs::remember::translate(d.translate, d.translate_toggles, c.get("translate"), &d.start_app)).flatten() {
            translated = d.translate;
            let _ = super::commands::set_dictation("translate", v);
        }
        let shown = c.get("remember_hint_shown").and_then(Value::as_i64).unwrap_or(0);
        let Some((msg, keys_)) = remembered_line("dictation.remember.saved", structured, translated) else { return };
        if shown >= 3 {
            return;
        }
        let _ = super::commands::set_dictation("remember_hint_shown", json!(shown + 1));
        say(&self.app, msg, json!({"app": d.start_app_name, "keys": keys_}), keys::NOTICE, 4000, None, false);
    }

    /// A take starts with something remembered and the app was quiet for an hour (or not used since launch): say so,
    /// while it listens — a translation left on in yesterday's chat must not go out unnoticed.
    fn remind_remembered(&mut self, app: &str, name: &str, base: Style, translate: bool) {
        if app.is_empty() || cfg().get("learn_styles").and_then(Value::as_bool) == Some(false) {
            return;
        }
        let since = self.last_take_in.get(app).map(|t| t.elapsed().as_secs_f64());
        if !super::prefs::remember::remind(since) {
            return;
        }
        let learned = cfg()
            .pointer("/styles/learned")
            .and_then(Value::as_array)
            .is_some_and(|a| a.iter().any(|x| x.as_str() == Some(app)));
        let structured = learned && base == Style::Structured;
        if !structured && !translate {
            return;
        }
        let Some((msg, keys_)) = remembered_line("dictation.remember.kept", structured, translate) else { return };
        self.last_take_in.insert(app.to_string(), Instant::now());
        say(&self.app, msg, json!({"app": name, "keys": keys_}), keys::STYLE, 4000, None, false);
    }

    /// The once-a-day notices after a typed take: cloud polish's key refused, a weaker speech model than the
    /// recommended one ran. → whether one was said.
    fn notice_after(&mut self, d: &Delivered) -> bool {
        if d.polish_cloud_error.as_deref() == Some("auth") && !said_today("polish_cloud_key") {
            mark_said("polish_cloud_key");
            say(&self.app, "dictation.toast.polish_cloud_key", json!({}), keys::NOTICE, 6000,
                Some(("dictation.cloud".to_string(), "dictation.translate.toast.setup")), true);
            return true;
        }
        // cloud polish unreachable (offline, a proxy refusing, out of quota): the words went in as said — once an hour,
        // so a whole afternoon offline isn't one line per take
        let offline = matches!(d.polish_cloud_error.as_deref(), Some("network" | "timeout" | "rate_limited" | "server"));
        if offline {
            static SAID: Mutex<Option<Instant>> = Mutex::new(None);
            let mut at = SAID.lock().unwrap();
            if at.is_none_or(|t| t.elapsed() > Duration::from_secs(3600)) {
                *at = Some(Instant::now());
                let msg = if d.polish_cloud_error.as_deref() == Some("rate_limited") { "dictation.toast.polish_quota" } else { "dictation.toast.polish_offline" };
                say(&self.app, msg, json!({}), keys::NOTICE, 6000,
                    Some(("dictation.cloud".to_string(), "dictation.translate.toast.setup")), true);
                return true;
            }
        }
        let weaker = super::commands::MODELS
            .lock()
            .unwrap()
            .as_ref()
            .is_some_and(|v| super::flow::speech_models::weaker_model_ran(v, d.asr_model.as_deref()));
        if weaker && !said_today("asr_fallback") {
            mark_said("asr_fallback");
            // the button says what it brings and what it costs ("Download (950 MB)"), as the no-model line's does
            let size = super::commands::MODELS.lock().unwrap().as_ref().and_then(super::flow::speech_models::to_get).and_then(|(id, _)| model_size(&id));
            let mut op = json!({"op": "toast", "kind": "dictation", "msg": "dictation.toast.weaker_asr", "vars": {}, "key": keys::NOTICE, "ms": 6000,
                                "passive": true, "action": {"a": "dictation.download", "label": "dictation.toast.no_model.action"}});
            if let Some(m) = keys::mark("dictation.toast.weaker_asr") {
                op["mark"] = json!(m);
            }
            if let Some(sz) = size {
                op["action"]["label"] = json!("dictation.toast.no_model.action_size");
                op["action"]["vars"] = json!({"size": sz});
            }
            *LAST_TOAST.lock().unwrap() = Some((Instant::now(), 6000));
            island::send(&self.app, op);
            return true;
        }
        false
    }

    /// The cloud-polish reminder: once ever, after 10 typed takes, with no cloud service connected (Windows has no
    /// polish of its own: without one the words go in as heard).
    fn remind_cloud(&mut self, takes: i64, d: &Delivered) {
        let c = cfg();
        let shown = c.get("cloud_hint_shown").and_then(Value::as_bool) == Some(true) || c.get("cloud_hint").and_then(Value::as_bool) == Some(false);
        let cloud = super::cloud::payload("polish").is_some();
        let in_blurt = d.exe.as_deref().is_some_and(|e| apps::stem(e) == apps::stem(&std::env::current_exe().map(|p| p.to_string_lossy().to_string()).unwrap_or_default()));
        if !super::flow::CloudReminder::due(takes, shown, cloud, in_blurt, d.had_line, toast_idle() && self.take.is_none()) {
            return;
        }
        let _ = super::commands::set_dictation("cloud_hint_shown", json!(true));
        say(&self.app, "dictation.cloud.hint", json!({}), keys::NOTICE, (super::flow::CloudReminder::SECONDS * 1000.0) as u64,
            Some(("dictation.cloud".to_string(), "dictation.cloud.hint.setup")), true);
    }

    fn show(&self) {
        let st = if let Some(t) = &self.take {
            json!({"phase": "listening", "elapsed": t.started.elapsed().as_secs_f64(), "at": 0,
                   "style": if t.style == Style::Structured { "structured" } else { "light" }, "translate": t.translate,
                   "target": t.translate.then(|| flow::ear_target(cfg().get("translate_target").and_then(Value::as_str).unwrap_or("auto")))})
        } else if !self.flight.is_empty() {
            json!({"phase": "transcribing", "elapsed": 0, "at": 0})
        } else {
            Value::Null
        };
        *ISLAND.lock().unwrap() = Some(st);
        island::refresh(&self.app);
    }
}

/// The field around the cursor in the app in front (never a password field), and the window's title.
fn read_context(front: Option<&Front>) -> Option<Context> {
    let me = std::process::id();
    let f = front.filter(|f| f.pid != me)?;
    let focus = ins::focus_read(true)?;
    if focus.password || (focus.pid != 0 && focus.pid != f.pid) {
        return None;
    }
    let mut c = match focus.field {
        Some(fd) if fd.cursor_known => Context::around(&fd.text, fd.sel_start, fd.sel_len),
        // a value without a cursor to read: the text is taken as what comes before it
        Some(fd) => Context::around(&fd.text, usize::MAX, 0),
        None => Context::default(),
    };
    c.title = ins::window_title(f.hwnd);
    c.app = Some(apps::stem(&f.exe));
    (!c.is_empty()).then_some(c)
}

/// The microphone wouldn't open: "Microphone access not allowed · Open settings" when Windows' privacy switches say
/// no (the Mac's capture.voice.mic_denied), else "Microphone unavailable · Change mic…" — the same way out as the
/// silent-mic line (the mic may be unplugged or another app holds it; Settings → Dictation → Microphone picks another).
fn mic_unavailable(app: &AppHandle) {
    if crate::onboarding::onboarding_mic()["access"] == "denied" {
        say(app, "dictation.toast.mic_denied", json!({}), keys::TAKE, 6000, Some(("dictation.open:privacy".into(), "dictation.toast.mic_settings")), false);
    } else {
        say(app, "dictation.toast.mic", json!({}), keys::TAKE, 6000, Some(("dictation.mic".into(), "dictation.toast.nothing.change")), false);
    }
}

/// A double tap's Return didn't go in: why, so the user doesn't think the message went.
fn send_skipped(app: &AppHandle, why: Option<&str>) {
    let msg = match why {
        Some("no_accessibility") => "dictation.toast.not_sent.elevated",
        Some("secure_input") => "dictation.toast.not_sent.secure",
        Some("not_pasted") => "dictation.toast.not_sent.copied",
        Some("runaway") => "dictation.toast.not_sent.runaway",
        _ => "dictation.toast.not_sent",
    };
    say(app, msg, json!({}), keys::TAKE, 3000, None, false);
}

/// A piece after a hard cut (no pause found within the longest piece) starts with words the one before already has.
pub(super) fn after_hard_cut(hard: &[bool], texts: &[Option<String>], i: usize, s: String) -> String {
    match (i.checked_sub(1).and_then(|p| hard.get(p)), i.checked_sub(1).and_then(|p| texts.get(p))) {
        (Some(true), Some(Some(prev))) => stitch::drop_overlap(prev, &s),
        _ => s,
    }
}

/// What a take's stream thread gets.
enum StreamMsg {
    /// the field's text before the cursor: the stream's header goes now (or after 0.4 s without one)
    Header(String),
    Pcm(Vec<f32>),
    /// key-up: the answer
    End,
    /// key-up with nothing said: no answer wanted
    Drop,
}

/// A take streamed while it is said (Volcengine; server.rs `Stream`). Its answer comes back as the take's whole
/// recording (`Slot::Whole`); "stream_failed" when it couldn't be opened (the engine then sends the recording whole).
/// The engine dropping the channel (Esc) resets the connection: the session ends unanswered.
fn stream_take(app: AppHandle, back: Sender<Msg>, n: u64, rx: Receiver<StreamMsg>, mut header: Value) {
    std::thread::spawn(move || {
        let mut pending: Vec<f32> = vec![];
        let t0 = Instant::now();
        // the header waits a moment for the field's text (read at the start, in parallel)
        let mut ended: Option<bool> = None;
        loop {
            let left = Duration::from_millis(400).saturating_sub(t0.elapsed());
            match rx.recv_timeout(left) {
                Ok(StreamMsg::Header(b)) => {
                    if !b.is_empty() {
                        header["before"] = json!(b);
                    }
                    break;
                }
                Ok(StreamMsg::Pcm(x)) => pending.extend(x),
                Ok(StreamMsg::End) => {
                    ended = Some(true);
                    break;
                }
                Ok(StreamMsg::Drop) | Err(RecvTimeoutError::Disconnected) => return,
                Err(RecvTimeoutError::Timeout) => break,
            }
        }
        let runner = app.state::<AppState>().runner();
        let _ = server::ensure(&runner, server::ASR, "transcribe.py", &ASR_ARGS);
        let opened = server::wait_ready(server::ASR, Duration::from_secs(20)).then(|| server::Stream::open(server::ASR, &header)).flatten();
        let Some(mut st) = opened else {
            // drain until the end, then ask for the whole recording
            while ended.is_none() {
                match rx.recv() {
                    Ok(StreamMsg::End) => ended = Some(true),
                    Ok(StreamMsg::Drop) | Err(_) => return,
                    _ => {}
                }
            }
            let _ = back.send(Msg::Heard(n, Slot::Whole, Err("stream_failed".into()), 0));
            return;
        };
        let mut ok = st.send(&pending);
        let audio = pending.len() as f64 / SR as f64;
        let mut seconds = audio;
        while ended.is_none() {
            match rx.recv() {
                Ok(StreamMsg::Pcm(x)) => {
                    seconds += x.len() as f64 / SR as f64;
                    ok = ok && st.send(&x);
                }
                Ok(StreamMsg::End) => ended = Some(true),
                Ok(StreamMsg::Header(_)) => {}
                Ok(StreamMsg::Drop) | Err(_) => return, // dropped: the connection resets
            }
        }
        if !ok {
            let _ = back.send(Msg::Heard(n, Slot::Whole, Err("stream_failed".into()), 0));
            return;
        }
        let t_up = Instant::now();
        // the service's own wait after key-up (10 s + its backlog), a little more for the answer to come back
        let wait = Duration::from_secs_f64(15.0 + 0.4 * seconds);
        let r = match st.finish(wait, &|| dropped(n)) {
            Some(v) if v["ok"] == json!(true) => Ok(v["text"].as_str().unwrap_or("").trim().to_string()),
            Some(v) => Err(v["code"].as_str().unwrap_or("error").to_string()),
            None if dropped(n) => Err("cancelled".into()),
            None => Err("timeout".into()),
        };
        let _ = back.send(Msg::Heard(n, Slot::Whole, r, t_up.elapsed().as_millis() as u64));
    });
}

/// The field as the speech model gets it: `before` the last 300 characters before the cursor (a model with
/// field_context_chars hears them), `hint` the window's title and the text around the cursor (only which of the user's
/// words appear in it is used: their order in the model's word list), `app` the app's name, named to the model before
/// the words (飞书 → 会话, not 绘画; Windows PowerShell → git, not get). The Mac sends the same three.
#[derive(Clone, Debug, Default)]
pub(super) struct AsrCtx {
    pub(super) before: String,
    pub(super) hint: String,
    pub(super) app: String,
}

/// Takes one of whose pieces came back from a cut repetition loop (`looped`), and the take the speech worker hears now.
static LOOPED: Mutex<Option<HashSet<u64>>> = Mutex::new(None);
thread_local! {
    static LOOPED_NOW: Cell<Option<u64>> = const { Cell::new(None) };
}

/// A job for the speech worker.
struct Job {
    n: u64,
    slot: Slot,
    wav: PathBuf,
    prior: String,
    before: AsrCtx,
    /// a piece's or a window's own file: removed once heard (the whole recording stays)
    temp: bool,
}

/// One worker: pieces and windows are recognised in the order they were said (one warm server, one at a time). A
/// take Esc stopped has its jobs skipped, and one in flight given up on.
fn asr_worker(app: AppHandle, back: Sender<Msg>) -> Sender<Job> {
    let (tx, rx) = channel::<Job>();
    std::thread::spawn(move || {
        while let Ok(j) = rx.recv() {
            let n = j.n;
            if dropped(n) {
                if j.temp {
                    let _ = std::fs::remove_file(&j.wav);
                }
                continue;
            }
            let t0 = Instant::now();
            let runner = app.state::<AppState>().runner();
            let give_up = move || dropped(n);
            LOOPED_NOW.with(|c| c.set(Some(n)));
            let r = recognise_with(&runner, &j.wav, &j.prior, Some("dictation"), &j.before, Some(&give_up));
            LOOPED_NOW.with(|c| c.set(None));
            if j.temp {
                let _ = std::fs::remove_file(&j.wav);
            }
            if back.send(Msg::Heard(n, j.slot, r, t0.elapsed().as_millis() as u64)).is_err() {
                break;
            }
        }
    });
    tx
}

/// Seconds of audio in one of our wavs (16-bit mono 16 kHz, mic.rs `write_wav`).
fn wav_seconds(wav: &Path) -> f64 {
    std::fs::metadata(wav).map_or(0.0, |m| m.len().saturating_sub(44) as f64 / (2.0 * SR as f64))
}

/// One piece through the warm server. `purpose` "dictation" (its model, Only my voice); None: the loaded model as is
/// (a voice note).
pub(super) fn recognise(
    runner: &crate::scripts::Runner,
    wav: &std::path::Path,
    prior: &str,
    purpose: Option<&str>,
) -> Result<String, String> {
    recognise_with(runner, wav, prior, purpose, &AsrCtx::default(), None)
}

/// `recognise` with the field's text before the cursor (`before`: a model with `field_context_chars` hears it; the
/// server neither logs it nor answers it back) and a way to give up while the answer is out (Esc).
pub(super) fn recognise_with(
    runner: &crate::scripts::Runner,
    wav: &std::path::Path,
    prior: &str,
    purpose: Option<&str>,
    field: &AsrCtx,
    give_up: Option<&dyn Fn() -> bool>,
) -> Result<String, String> {
    if !server::running(server::ASR) {
        // started for this take: its model loads first (a take waiting now says "Loading the speech model")
        ASR_LOADING.store(true, SeqCst);
        if let Err(e) = server::ensure(runner, server::ASR, "transcribe.py", &ASR_ARGS) {
            ASR_LOADING.store(false, SeqCst);
            return Err(e);
        }
    }
    // the server answers once its model is loaded (the preload comes before its first answer); a cold load can take
    // up to a minute on a slow disk
    let ready = server::wait_ready(server::ASR, Duration::from_secs(45));
    ASR_LOADING.store(false, SeqCst);
    if !ready {
        return Err("asr_slow".into());
    }
    let language = cfg()
        .get("language")
        .and_then(Value::as_str)
        .unwrap_or("auto")
        .to_string();
    let mut req = json!({"cmd": "note", "wav": wav.to_string_lossy(), "language": language,
                     "vocab": true, "no_download": true, "prior": prior});
    if let Some(p) = purpose {
        req["purpose"] = json!(p);
    }
    for (k, v) in [("before", &field.before), ("hint", &field.hint), ("app", &field.app)] {
        if !v.is_empty() {
            req[k] = json!(v);
        }
    }
    // a model load plus 1.5× the audio at most; a hung server is told well before (server.rs `hung`)
    let timeout = Duration::from_secs_f64(AsrFailure::server_timeout(wav_seconds(wav)));
    match server::call(server::ASR, &req, timeout, give_up) {
        Some(v) if v["ok"] == json!(true) => {
            // the speech model looped and the server cut it (transcribe.py FunAsrOnnx): words may be missing — the
            // take is typed, but a double tap never sends it
            if v["looped"] == json!(true) {
                if let Some(n) = LOOPED_NOW.with(|c| c.get()) {
                    LOOPED.lock().unwrap().get_or_insert_with(HashSet::new).insert(n);
                }
            }
            Ok(v["text"].as_str().unwrap_or("").trim().to_string())
        }
        Some(v) => Err(v["code"].as_str().unwrap_or("error").to_string()),
        None if give_up.is_some_and(|g| g()) => Err("cancelled".into()),
        None => Err("asr_slow".into()),
    }
}

/// One worker: takes are typed in the order they were said.
fn paste_worker(app: AppHandle, back: Sender<Msg>) -> Sender<Done> {
    let (tx, rx) = channel::<Done>();
    std::thread::spawn(move || {
        while let Ok(d) = rx.recv() {
            {
                let mut l = line().lock().unwrap();
                l.queued.retain(|x| x != &d.id);
                if l.cancelled.remove(&d.id) {
                    // Esc stopped it while it waited: Undo hears it again
                    l.skipped.insert(d.id.clone());
                    drop(l);
                    let _ = back.send(Msg::Delivered(Delivered {
                        id: d.id.clone(),
                        result: "cancelled".into(),
                        stopped_at: Some(d.stopped_at),
                        ..Delivered::default()
                    }));
                    continue;
                }
                l.current = Some(d.id.clone());
                l.polishing = true;
                l.skip_polish = false;
                l.send_cancelled = false;
            }
            island::refresh(&app);
            let out = deliver(&app, d);
            {
                let mut l = line().lock().unwrap();
                l.current = None;
                l.polishing = false;
                l.send.remove(&out.id);
            }
            let _ = back.send(Msg::Delivered(out));
            island::refresh(&app);
        }
    });
    tx
}

/// Ctrl+V of `text` into the app in front, then — once the field shows it (`before`: the field read just before; None:
/// it can't be read) — `on_return` (a double tap's Return) and the user's clipboard back: Return at 0.6 s at the
/// latest, the clipboard 0.15 s after the text was seen, else after 1.5 s (`landing`). → when the text was seen.
fn paste_and_land(text: &str, before: Option<&ins::Field>, on_return: &mut dyn FnMut()) -> Option<f64> {
    let saved = ins::save();
    ins::set_text(text);
    let seq = ins::sequence();
    std::thread::sleep(Duration::from_millis(30));
    ins::paste_keys();
    let t0 = Instant::now();
    let mut seen: Option<f64> = None;
    let mut gave_up = before.is_none();
    let mut returned = false;
    loop {
        let t = t0.elapsed().as_secs_f64();
        if !gave_up && seen.is_none() {
            if let (Some(b), Some(now)) = (before, ins::field_text()) {
                if landing::landed(&b.text, b.sel_start, b.sel_len, &now, text) {
                    seen = Some(t0.elapsed().as_secs_f64());
                }
            }
            if seen.is_none() && t >= landing::CONFIRM_TIMEOUT {
                gave_up = true;
            }
        }
        let t = t0.elapsed().as_secs_f64();
        if !returned && (seen.is_some() || t >= landing::return_after(None)) {
            returned = true;
            on_return();
        }
        if returned && (seen.is_some() || gave_up) && t >= landing::restore_after(seen) {
            break;
        }
        if t > landing::CONFIRM_TIMEOUT + 1.0 {
            break;
        }
        std::thread::sleep(Duration::from_secs_f64(landing::POLL));
    }
    // the clipboard changed since (the user copied something): theirs stays
    if ins::sequence() == seq {
        ins::restore(&saved);
    }
    seen
}

/// Polish, paste, the one line about it, the history.
fn deliver(app: &AppHandle, d: Done) -> Delivered {
    let runner = app.state::<AppState>().runner();
    // "Still polishing… Esc types it unpolished": 3 s after the stop
    {
        let (app2, id, cancel) = (app.clone(), d.id.clone(), d.cancel_label);
        let at = d.stopped_at + Duration::from_secs_f64(flow::SLOW_AFTER);
        std::thread::spawn(move || {
            if let Some(w) = at.checked_duration_since(Instant::now()) {
                std::thread::sleep(w);
            }
            let still = {
                let l = line().lock().unwrap();
                l.current.as_deref() == Some(id.as_str()) && l.polishing && !l.skip_polish
            };
            if still {
                say(&app2, "dictation.toast.slow.polish", json!({"cancel": cancel}), keys::SLOW, 60_000, None, false);
            }
        });
    }
    let t_polish = Instant::now();
    // the app the text goes into: the one in front now (the user may have switched meanwhile)
    let now = ins::front();
    let exe = now.as_ref().map(|f| f.exe.clone()).or_else(|| d.front.as_ref().map(|f| f.exe.clone()));
    let skip = || line().lock().unwrap().skip_polish;
    let p = polish_full(&runner, &d.raw, exe.as_deref(), d.context.as_ref(), d.style, d.translate, Some(&skip));
    line().lock().unwrap().polishing = false;
    let mut text = p.text.clone();
    let polish_ms = t_polish.elapsed().as_millis() as u64;

    // the paste
    let me = std::process::id();
    let now = ins::front();
    let ours = now.as_ref().is_some_and(|f| f.pid == me);
    let blocked = now.as_ref().is_some_and(|f| !ours && ins::blocks_input(f.pid));
    let focus = if ours { None } else { ins::focus_read(true) };
    let mut sit = Situation::new(now.is_some(), ours, false, !blocked);
    if let Some(f) = &focus {
        sit.focus_secure = f.password;
        sit.focus_is_text = f.editable;
    }
    let no_field = focus.as_ref().is_some_and(|f| f.editable == Some(false));
    let password = focus.as_ref().is_some_and(|f| f.password);
    let decision = paste_policy::decide(&sit);
    // fitted into the field at the cursor (fit.rs: the words that repeat the field go, punctuation and spacing follow
    // the sentence); a field that can't be read gets the text as it is — nothing in the field is ever changed
    let field = focus.as_ref().and_then(|f| f.field.as_ref()).filter(|f| f.cursor_known);
    let mut fitted: Vec<&'static str> = vec![];
    if let (Some(f), true, Decision::Paste { .. }) = (field, cfg().get("context").and_then(Value::as_bool) != Some(false), decision) {
        let c = Context::around(&f.text, f.sel_start, f.sel_len);
        // the field's sentence goes on before the cursor: a transcript heard in lower case keeps it (polish's model
        // already lowered a capital that only started a sentence)
        let cased = if !p.list && !p.translated && stitch::mid_sentence(&c.before) { stitch::keep_case(&d.raw, &text) } else { text.clone() };
        let (t, ch) = super::fit::fit_at_cursor(&cased, &c.before, &c.after, p.list);
        fitted = ch;
        if cased != text {
            fitted.push("capital");
        }
        text = t;
    }
    remember_text(&d.id, &text);
    let asked = Cell::new(false);
    let sent = Cell::new(false);
    let skip_why: Cell<Option<&'static str>> = Cell::new(None);
    let wants_send = || {
        let l = line().lock().unwrap();
        !l.send_cancelled && (d.send || l.send.contains(&d.id))
    };
    // far more characters than anyone says in this time: the speech model looped (Fun-ASR-Nano did: 2,000+ characters
    // for 6 s). Typed, so nothing is lost, but never sent on a double tap — a chat must not receive it.
    let runaway = d.looped || flow::SpeechLoop::looped(d.raw.chars().count(), d.duration);
    let mut confirmed = true;
    let mut copy_reason: Option<&'static str> = None;
    // the island shows what is typed for a moment — what a double tap would now send (not with its ✓ where no field
    // takes it: the line that keeps the text says so instead)
    if !no_field {
        island::send(app, json!({"op": "live", "text": text, "typed": true}));
    }
    let result: &str = match decision {
        Decision::Paste { confirmed: c } => {
            let mut on_return = || {
                if !wants_send() {
                    return;
                }
                asked.set(true);
                if runaway {
                    skip_why.set(Some("runaway"));
                    return;
                }
                match send_policy::queued(true, no_field) {
                    send_policy::Decision::Press => match send_policy::decide(true, false, password, !blocked) {
                        send_policy::Decision::Press => {
                            ins::press_return();
                            sent.set(true);
                        }
                        send_policy::Decision::Skip { reason } => skip_why.set(Some(reason)),
                    },
                    send_policy::Decision::Skip { reason } => skip_why.set(Some(reason)),
                }
            };
            let seen = paste_and_land(&text, focus.as_ref().and_then(|f| f.field.as_ref()), &mut on_return);
            // the field showing the text confirms it, whatever its role
            confirmed = c || seen.is_some();
            "pasted"
        }
        Decision::Own => {
            // one of Blurt's own windows (the Welcome's Try it box): its field gets the text; no Return there
            let mut none = || {
                if wants_send() {
                    asked.set(true);
                    skip_why.set(Some("blurt_in_front"));
                }
            };
            paste_and_land(&text, None, &mut none);
            "pasted"
        }
        Decision::Hold { .. } => {
            asked.set(wants_send());
            "held"
        }
        Decision::Copy { reason } => {
            ins::set_text(&text);
            copy_reason = Some(reason);
            asked.set(wants_send());
            "copied"
        }
    };
    let a2 = app.clone();
    std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(1500));
        island::send(&a2, json!({"op": "live", "text": ""}));
    });

    // one line about how it went (never two that replace each other in one frame)
    let id = d.id.clone();
    let copy = || Some((format!("dictation.copy:{id}"), "dictation.toast.copy"));
    let line_ = DeliveredLine::line(result, asked.get() && !sent.get(), confirmed, no_field);
    match line_ {
        #[cfg(target_os = "linux")]
        DeliveredLine::Copied if copy_reason == Some("no_accessibility") => {
            // no Remote Desktop access yet: copied, and the way to let Blurt type (insert_linux.rs)
            say(app, "dictation.toast.copied.no_typing", json!({}), keys::TAKE, 8000,
                Some(("dictation.allow_typing".to_string(), "dictation.toast.allow_typing")), false);
            // the first such take of a run asks at once: the user just tried to dictate, the dialog is expected
            static ASKED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
            if !ASKED.swap(true, SeqCst) {
                if let Some(tx) = INBOX.get() {
                    let _ = tx.send(Msg::Action("dictation.allow_typing".into()));
                }
            }
        }
        DeliveredLine::Copied if copy_reason == Some("no_accessibility") => {
            // UIPI: the window in front runs as administrator and Blurt doesn't
            say(app, "dictation.toast.copied.elevated", json!({}), keys::TAKE, 4000, None, false);
        }
        DeliveredLine::Copied | DeliveredLine::CopiedNotSent => {
            if let Some(k) = line_.copy_key() {
                say(app, k, json!({}), keys::TAKE, (line_.copy_seconds() * 1000.0) as u64, None, false);
            }
        }
        DeliveredLine::NotSent => send_skipped(app, skip_why.get()),
        DeliveredLine::Held => say(app, "dictation.toast.secure_held", json!({}), keys::TAKE, 6000, copy(), false),
        DeliveredLine::PastedUnsure => {
            say(app, "dictation.toast.pasted_unsure", json!({}), keys::TAKE, 3000, Some((format!("dictation.copy:{id}"), "dictation.toast.copy_again")), false)
        }
        // the focus isn't a text field: the island keeps the text (its start) with Copy until the next take
        DeliveredLine::NoField => say(
            app,
            "dictation.toast.no_field",
            json!({"text": KeptText::preview(&text)}),
            keys::TAKE,
            60_000,
            copy(),
            false,
        ),
        DeliveredLine::None => {
            if sent.get() {
                say_sent(app);
            } else if asked.get() && skip_why.get().is_some() {
                // typed, and a double tap asked for Return that didn't go (a looped take, a password field …): say so
                send_skipped(app, skip_why.get());
            } else if let Some(k) = d.translate.then_some(p.translate_error.as_deref()).flatten().map(translate_failed_key) {
                // Ctrl asked for a translation and it didn't happen: the words went in as said — say why
                let action = (k == "dictation.translate.toast.unavailable" || k == "dictation.translate.toast.key")
                    .then(|| ("dictation.cloud".to_string(), "dictation.translate.toast.setup"));
                say(app, k, json!({}), keys::TAKE, 5000, action, false);
            } else if d.style == Style::Structured && p.fell_back {
                // Shift asked for a list and the structuring pass fell back: say so, or it looks as if Shift did nothing
                // — and when the cloud couldn't be reached, that is the reason (not the words)
                let msg = match p.cloud_error.as_deref() {
                    Some("network" | "timeout" | "server") => "dictation.toast.polish_offline",
                    Some("rate_limited") => "dictation.toast.polish_quota",
                    Some("auth") => "dictation.toast.polish_cloud_key",
                    _ => "dictation.toast.no_list",
                };
                // the same line and button as the once-an-hour cloud hint: a cloud failure always says where to fix it
                let fix = (msg != "dictation.toast.no_list").then(|| ("dictation.cloud".to_string(), "dictation.translate.toast.setup"));
                say(app, msg, json!({}), keys::TAKE, if msg == "dictation.toast.no_list" { 3000 } else { 5000 }, fix, false);
            }
        }
    }

    // what reformat-last needs, and the watch for the user's fixes (only where the field could be read)
    if result == "pasted" && !ours && line_ != DeliveredLine::NoField {
        if let Some(pid) = now.as_ref().map(|x| x.pid) {
            // a field that can't be read: reformat-last copies its versions instead of replacing
            set_last_paste(app, &d, &p, &text, pid, now.as_ref().map(|x| x.exe.clone()), field.map_or(0, |f| f.sel_start));
            if let Some(f) = field.filter(|_| cfg().get("learn").and_then(Value::as_bool) != Some(false)) {
                start_watch(app, pid, &text, f.sel_start);
            }
        }
    }
    let into = now.as_ref().or(d.front.as_ref());
    let total_ms = d.stopped_at.elapsed().as_millis() as u64;
    history(&d, &p, &text, into, result, total_ms, polish_ms, &fitted);
    // record.dictation.keep_audio off: the recording goes once the text is in (a failed take keeps its own for Retry)
    if !d.keep_audio {
        let _ = std::fs::remove_file(&d.wav);
    }
    super::history::changed(app);
    let start_exe = d.front.as_ref().map(|f| f.exe.clone()).unwrap_or_default();
    let now_exe = now.as_ref().map(|f| f.exe.clone());
    let had_line = !matches!(line_, DeliveredLine::None) || sent.get() || (d.translate && p.translate_error.is_some());
    Delivered {
        id: d.id.clone(),
        result: result.to_string(),
        sent: sent.get(),
        send_asked: asked.get(),
        stopped_at: Some(d.stopped_at),
        start_app: apps::stem(&start_exe),
        start_app_name: d.front.as_ref().map(display_name).unwrap_or_default(),
        app_changed: now_exe.as_deref().map(apps::stem) != Some(apps::stem(&start_exe)),
        exe: now_exe,
        style: Some(d.style),
        style_toggles: d.style_toggles,
        translate: d.translate,
        translate_toggles: d.translate_toggles,
        asr_model: current_asr_model(),
        polish_cloud_error: p.cloud_error.clone(),
        had_line,
        no_field: line_ == DeliveredLine::NoField,
        translated: p.translated,
        list: p.list,
    }
}

/// An app's name in a line ("Structured stays on in Notepad"): Windows' own name for it (insert_win `app_name`), else
/// its executable without ".exe".
fn display_name(f: &Front) -> String {
    ins::app_name(f).unwrap_or_else(|| f.exe.trim_end_matches(".exe").trim_end_matches(".EXE").to_string())
}

/// The line for a translation asked for and not made (polish.py's reason): no service, the key refused, out of quota,
/// offline — else "Couldn't translate".
fn translate_failed_key(reason: &str) -> &'static str {
    match reason.trim_start_matches("cloud_") {
        "unavailable" => "dictation.translate.toast.unavailable",
        "auth" => "dictation.translate.toast.key",
        "rate_limited" | "quota" => "dictation.translate.toast.quota",
        "network" | "timeout" | "offline" => "dictation.translate.toast.offline",
        _ => "dictation.translate.toast.failed",
    }
}

/// The model the warm speech server has loaded (the history's `asr_model`, the weaker-model notice).
fn current_asr_model() -> Option<String> {
    server::call(server::ASR, &json!({"cmd": "ping"}), Duration::from_millis(500), None)
        .and_then(|v| v.get("model").and_then(Value::as_str).map(String::from))
}

// ------------------------------------------------------------------ reformat-last (Alt+Shift+L)

/// How a modifier is pressed to switch ("double-tap Shift" / "双击 Shift"), as the settings say.
fn modifier_press(key: &str, double: bool) -> String {
    let zh = crate::l10n::lang() == "zh-Hans";
    match (double, zh) {
        (true, true) => format!("双击 {key}"),
        (false, true) => format!("按 {key}"),
        (true, false) => format!("double-tap {key}"),
        (false, false) => format!("press {key}"),
    }
}

/// A translate target in a line, in the app's language (as the Mac's Dictation.languageName; English is always
/// "English" in the pair, as Settings writes it).
fn language_name(code: &str) -> String {
    let zh = crate::l10n::lang() == "zh-Hans";
    let (z, e) = match code {
        "zh" | "zh-Hans" | "zh-CN" => ("中文", "Chinese"),
        "zh-Hant" | "zh-TW" => ("繁體中文", "Traditional Chinese"),
        "en" => ("English", "English"),
        "ja" => ("日语", "Japanese"),
        "ko" => ("韩语", "Korean"),
        "fr" => ("法语", "French"),
        "de" => ("德语", "German"),
        "es" => ("西班牙语", "Spanish"),
        "pt" => ("葡萄牙语", "Portuguese"),
        "ru" => ("俄语", "Russian"),
        "it" => ("意大利语", "Italian"),
        "vi" => ("越南语", "Vietnamese"),
        other => return other.to_string(),
    };
    (if zh { z } else { e }).to_string()
}

/// A style's name in a line (the Mac's Dictation.styleName).
fn style_name(s: Style) -> &'static str {
    let zh = crate::l10n::lang() == "zh-Hans";
    match (s, zh) {
        (Style::Verbatim, false) => "Verbatim",
        (Style::Light, false) => "Light",
        (_, false) => "Structured",
        (Style::Verbatim, true) => "原话",
        (Style::Light, true) => "轻整理",
        (_, true) => "结构化",
    }
}

/// The last typed take, for reformat-last (the Mac's DictationLastPaste): its versions, where it went, how to find it
/// again in the field (the text on either side of it).
#[derive(Clone, Debug)]
struct LastPaste {
    id: String,
    /// the app it went into (an executable's stem) and its name for a line
    app: String,
    name: String,
    at: Instant,
    pid: u32,
    exe: Option<String>,
    raw: String,
    light: Option<String>,
    structured: Option<String>,
    structured_tried: bool,
    original: Style,
    current: Style,
    typed: String,
    current_version: String,
    prefix: String,
    suffix: String,
    location: usize,
}

static LAST: Mutex<Option<LastPaste>> = Mutex::new(None);

impl LastPaste {
    fn version(&self, s: Style) -> Option<String> {
        match s {
            Style::Verbatim => Some(self.raw.clone()),
            Style::Light => self.light.clone(),
            Style::Structured | Style::Auto => self.structured.clone(),
        }
    }

    /// The text around it now, to find it again untouched.
    fn anchor(&mut self) {
        if let Some(t) = ins::field_text() {
            if let Some((p, s, at)) = super::learn::anchors(&t, &self.typed, self.location) {
                self.prefix = p;
                self.suffix = s;
                self.location = at;
            }
        }
    }
}

fn set_last_paste(app: &AppHandle, d: &Done, p: &Polished, typed: &str, pid: u32, exe: Option<String>, location: usize) {
    // a translated take has no versions in its own language to cycle through
    if p.translated {
        *LAST.lock().unwrap() = None;
        return;
    }
    let original = if d.style == Style::Auto { if p.list { Style::Structured } else { Style::Light } } else { d.style };
    let light = if d.style.structures() && p.polished.is_some() && p.list { None } else if p.polished.is_some() || p.fell_back { Some(p.text.clone()) } else { None };
    let exe_name = exe.clone().unwrap_or_default();
    let mut lp = LastPaste {
        id: d.id.clone(),
        app: apps::stem(&exe_name),
        name: ins::front().filter(|f| f.pid == pid).map(|f| display_name(&f)).unwrap_or_else(|| exe_name.trim_end_matches(".exe").trim_end_matches(".EXE").to_string()),
        at: Instant::now(),
        pid,
        exe,
        raw: d.raw.clone(),
        light: if original == Style::Verbatim { None } else { light },
        structured: if original == Style::Structured { Some(p.text.clone()) } else { None },
        structured_tried: d.style.structures(),
        original,
        current: original,
        typed: typed.to_string(),
        current_version: p.text.clone(),
        prefix: String::new(),
        suffix: String::new(),
        location,
    };
    lp.anchor();
    let chip = original == Style::Light && cfg().get("suggest_lists").and_then(Value::as_bool) != Some(false)
        && stitch::may_hold_list(lp.light.as_deref().unwrap_or(&lp.raw));
    let (id, src, exe) = (lp.id.clone(), lp.light.clone().unwrap_or_else(|| lp.raw.clone()), lp.exe.clone());
    *LAST.lock().unwrap() = Some(lp);
    if chip {
        list_chip(app, id, src, exe);
    }
}

/// "Sounds like a list · Make a List" (the Mac's ≡ chip): a take typed as prose that may hold a list gets the
/// structuring pass after the paste — the dictation never waits for it — and, when the model made a list, one click (or
/// the reformat key) makes it one. Shown, it counts as "left as prose" for the app's style unless the user takes it.
fn list_chip(app: &AppHandle, id: String, src: String, exe: Option<String>) {
    let app = app.clone();
    std::thread::spawn(move || {
        let runner = app.state::<AppState>().runner();
        let r = polish_full(&runner, &src, exe.as_deref(), None, Style::Structured, false, None);
        if r.fell_back || r.polished.is_none() || stitch::list_lines(&r.text) < 2 {
            return;
        }
        let (app_stem, name) = {
            let mut g = LAST.lock().unwrap();
            let Some(lp) = g.as_mut().filter(|l| l.id == id && l.current == Style::Light) else { return };
            lp.structured = Some(r.text.clone());
            lp.structured_tried = true;
            (lp.app.clone(), lp.name.clone())
        };
        if super::voice::active() || ISLAND.lock().unwrap().as_ref().is_some_and(|v| v["phase"] == "listening") {
            return;
        }
        let (msg, vars) = match reformat_key() {
            Some(k) => ("dictation.style.chip.key", json!({"key": k})),
            None => ("dictation.style.chip", json!({})),
        };
        say(&app, msg, vars, keys::TAKE, 6000, Some(("dictation.make_list".into(), "dictation.style.chip.action")), false);
        style_signal(&app, &app_stem, &name, &id, Style::Light);
    });
}

fn signals_path() -> PathBuf {
    paths::blurt_home().join("dictation").join("style_signals.json")
}

/// One take's signal for its app's style (style_learn.rs); then, when the app's signals agree and it wasn't asked,
/// the question once ("Format spoken lists in WeChat from now on?", 12 s, unanswered = no).
fn style_signal(app: &AppHandle, app_stem: &str, name: &str, id: &str, style: Style) {
    let c = cfg();
    if app_stem.is_empty() || c.get("learn_styles").and_then(Value::as_bool) == Some(false) {
        return;
    }
    let mut store: Value = std::fs::read_to_string(signals_path()).ok().and_then(|t| serde_json::from_str(&t).ok()).unwrap_or(json!({}));
    super::style_learn::record(&mut store, app_stem, id, style);
    let _ = std::fs::write(signals_path(), store.to_string());
    let current = Prefs::from_json(&c).styles.base(Some(app_stem));
    let asked: Vec<String> = c["style_asked"].as_array().map(|a| a.iter().filter_map(|x| x.as_str().map(String::from)).collect()).unwrap_or_default();
    let Some(target) = super::style_learn::suggest(&super::style_learn::signals(&store, app_stem), current, &asked, app_stem) else { return };
    let mut asked = asked;
    asked.push(super::style_learn::ask_key(app_stem, target));
    let _ = super::commands::set_dictation("style_asked", json!(asked));
    say(app, &format!("dictation.style.learn.{}", target.as_str()), json!({"app": name}), keys::NOTICE, 12_000,
        Some((format!("dictation.learn_style:{app_stem}|{}", target.as_str()), "dictation.style.learn.yes")), false);
}

/// Reformat-last (Alt+Shift+L): the take typed last in the next style that reads differently — Verbatim → Light →
/// Structured — replaced in the field while it is there untouched (within 5 minutes), else copied. `to`: a given
/// style (Undo: back to the original). Off the engine's thread (polish may run for a version not made yet).
fn reformat(app: AppHandle, to: Option<Style>, undo: bool) {
    std::thread::spawn(move || {
        let Some(mut lp) = LAST.lock().unwrap().clone() else {
            say(&app, "dictation.style.reformat.nothing", json!({}), keys::TAKE, 2400, None, false);
            return;
        };
        let runner = app.state::<AppState>().runner();
        // the versions not made yet: polish (Light), the structuring pass (Structured), off the dictation's path
        if lp.light.is_none() && !lp.raw.is_empty() {
            let r = polish_full(&runner, &lp.raw, lp.exe.as_deref(), None, Style::Light, false, None);
            if !r.fell_back && r.polished.is_some() {
                lp.light = Some(r.text);
            }
        }
        if lp.structured.is_none() && !lp.structured_tried {
            lp.structured_tried = true;
            let src = lp.light.clone().unwrap_or_else(|| lp.raw.clone());
            let r = polish_full(&runner, &src, lp.exe.as_deref(), None, Style::Structured, false, None);
            if !r.fell_back && r.polished.is_some() {
                lp.structured = Some(r.text);
            }
        }
        let order = match to {
            Some(s) => vec![s],
            None => vec![lp.current.next(), lp.current.next().next()],
        };
        let Some((style, text)) = order
            .into_iter()
            .find_map(|s| lp.version(s).filter(|t| *t != lp.current_version).map(|t| (s, t)))
        else {
            if to.is_none() {
                say(&app, "dictation.style.reformat.same", json!({}), keys::TAKE, 2400, None, false);
            }
            *LAST.lock().unwrap() = Some(lp);
            return;
        };
        let outcome = replace_last(&mut lp, &text);
        let replaced = matches!(outcome, Replace::Done);
        let mut text = text;
        let mut msg_override: Option<&'static str> = None;
        match outcome {
            Replace::Done => {}
            Replace::Copy => {
                ins::set_text(&text);
            }
            Replace::Unreadable => {
                ins::set_text(&text);
                msg_override = Some("dictation.style.copied.original");
            }
            // the user's edited text in the new style, by the same passes the take's own versions got (Light:
            // polish; Structured: the structuring pass; Verbatim: as it stands) — copied, the field left alone
            Replace::Edited(edited) => {
                let mut out = edited.clone();
                if style != Style::Verbatim {
                    let r = polish_full(&runner, &edited, lp.exe.as_deref(), None, style, false, None);
                    if !r.fell_back && r.polished.is_some() {
                        out = r.text;
                    }
                }
                ins::set_text(&out);
                text = out;
                msg_override = Some("dictation.style.copied.edited");
            }
        }
        lp.current = style;
        lp.current_version = text;
        let name = style_name(style);
        let (msg, action) = match (undo, replaced) {
            (true, true) => ("dictation.style.undone", None),
            (false, true) => ("dictation.style.reformatted", Some(("dictation.reformat_undo".to_string(), "dictation.toast.undo"))),
            (_, false) => (msg_override.unwrap_or("dictation.style.copied"), None),
        };
        // what the user chose (a reformat kept, or undone: the style it had) is a signal for the app's style
        style_signal(&app, &lp.app, &lp.name, &lp.id, style);
        say(&app, msg, json!({"style": name, "key": style.as_str()}), keys::TAKE, if replaced && !undo { 5000 } else { 2400 }, action, false);
        let watch = replaced && cfg().get("learn").and_then(Value::as_bool) != Some(false);
        let (pid, typed, loc) = (lp.pid, lp.typed.clone(), lp.location);
        *LAST.lock().unwrap() = Some(lp);
        if watch {
            start_watch(&app, pid, &typed, loc);
        }
    });
}

/// What became of a reformat in the field.
enum Replace {
    /// the new version is in the field
    Done,
    /// too late, another app in front, a field that can't be read or selected: copied
    Copy,
    /// the user changed the text: what the field says there now (re-styled and copied, never overwritten)
    Edited(String),
    /// changed, and what it is now can't be told apart: the take's own version copied
    Unreadable,
}

/// Replace the last take's text in the field where it still is untouched: select it (UI Automation) and paste the
/// new version over it, fitted to the text around it.
fn replace_last(lp: &mut LastPaste, text: &str) -> Replace {
    if lp.at.elapsed().as_secs_f64() > super::learn::REFORMAT_WINDOW {
        return Replace::Copy;
    }
    let Some(f) = ins::focus_read(true).filter(|f| f.pid == lp.pid && !f.password) else { return Replace::Copy };
    let Some(field) = f.field else { return Replace::Copy };
    let Some((start, len)) = super::learn::span(&field.text, &lp.typed, &lp.prefix, &lp.suffix, lp.location) else {
        // the user changed it: never overwritten — what they see now is what gets re-styled and copied (v0.9 dogfood:
        // their 方案→计划 fix was missing from the copy)
        let max = lp.typed.encode_utf16().count() * 3 + 200;
        return match super::learn::locate(&field.text, &lp.prefix, &lp.suffix, lp.location, max) {
            Some(e) if !e.trim().is_empty() => Replace::Edited(e),
            _ => Replace::Unreadable,
        };
    };
    if !ins::select_range(start, len, &lp.typed) {
        return Replace::Copy;
    }
    let c = Context::around(&field.text, start, len);
    let list = stitch::list_lines(text) >= 2;
    let (fitted, _) = super::fit::fit_at_cursor(text, &c.before, &c.after, list);
    // the watch of the old text ends without learning: the text is being replaced
    WATCH_SKIP.store(WATCH_GEN.load(SeqCst), SeqCst);
    WATCH_GEN.fetch_add(1, SeqCst);
    let before = ins::Field { text: field.text.clone(), sel_start: start, sel_len: len, cursor_known: true };
    paste_and_land(&fitted, Some(&before), &mut || {});
    lp.typed = fitted;
    lp.location = start;
    lp.at = Instant::now();
    lp.anchor();
    Replace::Done
}

// ------------------------------------------------------------------ learning from the user's fixes

/// The watch running now: a newer one (the next take, a reformat) ends it.
static WATCH_GEN: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
/// A watch ended by a reformat: it learns nothing (its text was replaced, not fixed).
static WATCH_SKIP: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(u64::MAX);

/// Watch the field the take went into for a minute (learn.rs): once it ends, the user's fixes become words.
fn start_watch(app: &AppHandle, pid: u32, typed: &str, location: usize) {
    let gen = WATCH_GEN.fetch_add(1, SeqCst) + 1;
    let (app, typed) = (app.clone(), typed.to_string());
    std::thread::spawn(move || {
        use super::learn;
        let Some(text) = ins::focus_read(true).filter(|f| f.pid == pid).and_then(|f| f.field).map(|f| f.text) else { return };
        let Some((prefix, suffix, near)) = learn::anchors(&text, &typed, location) else { return };
        let mut w = learn::EditWatch::new(&typed);
        let max = typed.encode_utf16().count() * 3 + 200;
        let t0 = Instant::now();
        // the next take, a reformat: what the user did so far is learned now (a reformat's replacement learns nothing)
        let mut learn_it = true;
        loop {
            std::thread::sleep(Duration::from_secs_f64(learn::EVERY));
            if WATCH_GEN.load(SeqCst) != gen {
                learn_it = WATCH_SKIP.load(SeqCst) != gen;
                break;
            }
            if t0.elapsed().as_secs_f64() >= learn::SECONDS {
                break;
            }
            let Some(now) = ins::focus_read(true).filter(|f| f.pid == pid).and_then(|f| f.field).map(|f| f.text) else { break };
            match learn::locate(&now, &prefix, &suffix, near, max) {
                Some(span) => w.saw(&span),
                None => break,
            }
        }
        // nothing of the document stays: only the typed text and its edited form go to the learner
        let Some((typed, edited)) = w.end().filter(|_| learn_it) else { return };
        // the list it was typed as was taken apart in the field: a signal for Light in its app
        if super::style_learn::reverted(&typed, &edited) {
            let who = LAST.lock().unwrap().as_ref().filter(|l| l.typed == typed).map(|l| (l.app.clone(), l.name.clone(), l.id.clone()));
            if let Some((a, n, id)) = who {
                style_signal(&app, &a, &n, &id, Style::Light);
            }
        }
        let runner = app.state::<AppState>().runner();
        let args: Vec<String> = ["learn", "--raw", &typed, "--corrected", &edited, "--suggest"].iter().map(|s| s.to_string()).collect();
        let Ok(v) = runner.run("dictation_vocab.py", &args, None, Duration::from_secs(30)) else { return };
        for fx in v["fixes"].as_array().cloned().unwrap_or_default() {
            if fx["result"] == "learned" {
                if let Some(term) = fx["fixed"].as_str() {
                    say(&app, "dictation.toast.learned", json!({"term": term}), "dictation.learned", 4000,
                        Some((format!("dictation.forget:{term}"), "dictation.toast.undo")), true);
                }
            }
        }
    });
}

/// What polish made of a take.
pub(super) struct Polished {
    pub(super) text: String,
    pub(super) polished: Option<String>,
    pub(super) model: Option<String>,
    pub(super) fell_back: bool,
    pub(super) reason: Option<String>,
    pub(super) ms: u64,
    pub(super) variant: Option<&'static str>,
    pub(super) context_used: bool,
    /// the structuring pass made a list (Structured / Auto)
    pub(super) list: bool,
    /// the text is a translation (reformat-last leaves it alone: its versions are the words as said)
    pub(super) translated: bool,
    /// cloud polish's own error, without its "cloud_" prefix ("auth": the key was refused; network, timeout,
    /// rate_limited …)
    pub(super) cloud_error: Option<String>,
    /// a translation asked for and not made: why ("unavailable": no service; the cloud's code; "refused_…")
    pub(super) translate_error: Option<String>,
}

fn vocab() -> Value {
    // only active terms are used (a suggestion, a removed or rejected term isn't; dictation_vocab.py reads it the same)
    let p = paths::blurt_home().join("dictation").join("vocabulary.json");
    let v: Value = std::fs::read_to_string(p)
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or(json!({}));
    json!(super::words::active(&v))
}

/// `polish` of a text heard (also the Dictation page's Retry, history.rs): `app` the exe it goes into, without ".exe".
pub(super) fn polish_text(
    runner: &crate::scripts::Runner,
    raw: &str,
    app: Option<String>,
    structured: bool,
    translate: bool,
) -> Polished {
    let style = if structured { Style::Structured } else { Style::Light };
    polish_full(runner, raw, app.as_deref(), None, style, translate, None)
}

/// Cloud polish (Light), the Structured pass and translation, through the warm polish server — only with a cloud
/// service connected: Windows has no local polish model (docs/design/windows-models.md). Polish gets the app's variant
/// (terminal, chat) and the field around the cursor. `give_up`: Esc while it polishes — the text goes in as heard.
/// Any failure types the recogniser's text.
fn polish_full(
    runner: &crate::scripts::Runner,
    raw: &str,
    app: Option<&str>,
    context: Option<&Context>,
    style: Style,
    translate: bool,
    give_up: Option<&dyn Fn() -> bool>,
) -> Polished {
    let variant = apps::polish_variant(app);
    let plain = Polished {
        text: raw.to_string(),
        polished: None,
        model: None,
        fell_back: false,
        reason: None,
        ms: 0,
        variant,
        context_used: false,
        list: false,
        translated: false,
        cloud_error: None,
        translate_error: None,
    };
    // Verbatim types what the speech model wrote (record.dictation.polish off is Verbatim everywhere)
    let polish_on = cfg().get("polish").and_then(Value::as_str) != Some("off") && style.polishes();
    let cloud = super::cloud::payload("polish");
    let tcloud = super::cloud::payload("translate").or_else(|| cloud.clone());
    if (cloud.is_none() || !polish_on) && !(translate && tcloud.is_some()) {
        // translate asked with no service to do it (Ctrl-Ctrl is refused then, but a remembered "translate" can start
        // a take): typed as said, and the island says why
        let translate_error = (translate && tcloud.is_none()).then(|| "unavailable".to_string());
        return Polished { translate_error, ..plain };
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
    let skipped = || give_up.is_some_and(|g| g());
    let t0 = Instant::now();
    // Settings → Dictation's Polish time limit (record.dictation.polish_timeout_ms, the Mac's key) replaces the 4 s base
    let base = cfg().get("polish_timeout_ms").and_then(Value::as_f64).map_or(4.0, |ms| (ms / 1000.0).max(0.5));
    let budget = base + 0.006 * raw.chars().count() as f64;
    let ctx = match context {
        Some(c) => {
            let mut j = c.polish_json();
            j["app"] = json!(app.map(apps::stem));
            j
        }
        None => json!({ "app": app.map(apps::stem) }),
    };
    let mut text = raw.to_string();
    let mut out = Polished {
        context_used: context.is_some_and(|c| !c.is_empty()),
        ..plain
    };
    if let (Some(c), true) = (&cloud, polish_on) {
        let ask = |structure: bool| -> Result<Value, String> {
            let mut req = if structure {
                json!({"cmd": "structure", "text": raw, "timeout": budget * 2.0, "vocab": vocab(), "context": ctx, "cloud": c, "local_fallback": false})
            } else {
                // no local model to fall back on (Windows): the cloud's failure is the reason (polish.py `local_fallback`)
                json!({"cmd": "polish", "text": raw, "timeout": budget, "vocab": vocab(), "context": ctx, "cloud": c, "local_fallback": false})
            };
            if let (Some(v), false) = (variant, structure) {
                req["variant"] = json!(v);
            }
            let wait = if structure { budget * 2.0 } else { budget } + 3.0;
            match server::call(server::POLISH, &req, Duration::from_secs_f64(wait), give_up) {
                Some(v) if v["ok"] == json!(true) && !v["text"].as_str().unwrap_or("").trim().is_empty() => Ok(v),
                Some(v) => Err(v["code"].as_str().or(v["reason"].as_str()).unwrap_or("error").to_string()),
                None => Err(if skipped() { "skipped" } else { "timeout" }.into()),
            }
        };
        let take = |out: &mut Polished, v: &Value| {
            out.fell_back = v["fell_back"] == json!(true);
            out.reason = v["reason"].as_str().map(String::from);
            // the cloud's own failure ("cloud_network" as the reason of a pass that fell back)
            out.cloud_error = v["cloud_error"]
                .as_str()
                .or(out.reason.as_deref().filter(|r| out.fell_back && r.starts_with("cloud_")))
                .map(|e| e.trim_start_matches("cloud_").to_string());
            out.model = v["model"].as_str().map(String::from);
        };
        // Structured / Auto: one structuring pass over the whole take; Auto types it only when it made a list
        let mut structured: Option<String> = None;
        if style.structures() {
            match ask(true) {
                Ok(v) => {
                    take(&mut out, &v);
                    structured = v["text"].as_str().map(String::from);
                }
                Err(why) => {
                    out.fell_back = style == Style::Structured;
                    out.reason = Some(why);
                }
            }
        }
        let (picked, list) = style.pick(raw, structured.as_deref());
        out.list = list;
        if structured.is_some() && (style == Style::Structured || list) {
            text = picked;
            out.polished = Some(text.clone());
        } else if !skipped() {
            match ask(false) {
                Ok(v) => {
                    take(&mut out, &v);
                    text = v["text"].as_str().unwrap_or("").to_string();
                    if !out.fell_back {
                        out.polished = Some(text.clone());
                    }
                }
                Err(why) => {
                    out.fell_back = true;
                    let code = why.trim_start_matches("cloud_").to_string();
                    if code != "skipped" {
                        out.cloud_error = Some(code);
                    }
                    out.reason = Some(why);
                }
            }
        }
    }
    if translate && !skipped() {
        if let Some(c) = &tcloud {
            let target = cfg()
                .get("translate_target")
                .and_then(Value::as_str)
                .unwrap_or("auto")
                .to_string();
            // `check`: polish.py's guard looks at the answer and says why it fell back (the Mac's request)
            let req = json!({"cmd": "translate", "text": text, "target": target, "cloud": c, "spoken": true, "vocab": vocab(), "check": true});
            match server::call(server::POLISH, &req, Duration::from_secs(20), give_up) {
                Some(v) if v["ok"] == json!(true) && v["fell_back"] != json!(true) => {
                    if let Some(t) = v["text"].as_str().filter(|t| !t.trim().is_empty()) {
                        if t != text {
                            out.translated = true;
                        }
                        text = t.to_string();
                    }
                }
                Some(v) => {
                    let why = v["cloud_error"].as_str().or(v["reason"].as_str()).or(v["code"].as_str()).unwrap_or("error");
                    out.translate_error = Some(why.trim_start_matches("cloud_").to_string());
                }
                None if skipped() => {}
                None => out.translate_error = Some("timeout".into()),
            }
        } else {
            out.translate_error = Some("unavailable".into());
        }
    }
    out.text = text;
    out.ms = t0.elapsed().as_millis() as u64;
    out
}

#[allow(clippy::too_many_arguments)]
fn history(d: &Done, p: &Polished, text: &str, app: Option<&Front>, insert: &str, total_ms: u64, polish_ms: u64, fitted: &[&str]) {
    if !d.keep_history {
        return; // "Don't keep" (retention_days 0): the text went where it was typed, and nowhere else
    }
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
        "app_name": app.and_then(ins::app_name), "exe_path": app.and_then(ins::exe_full_path),
        "duration": (d.duration * 100.0).round() / 100.0, "raw": d.raw, "polished": p.polished, "text": text,
        "model": p.model, "fell_back": p.fell_back, "reason": p.reason, "insert": insert,
        "audio": if d.keep_audio { json!(format!("audio/{}", d.wav.file_name().and_then(|n| n.to_str()).unwrap_or(""))) } else { Value::Null },
        "asr_model": model, "asr_ms": d.asr_ms, "polish_ms": polish_ms, "total_ms": total_ms, "segments": d.pieces,
        "windows": d.windows, "style": d.style.as_str(), "send": d.send,
        "variant": p.variant, "context_used": p.context_used,
        "fitted": if fitted.is_empty() { Value::Null } else { json!(fitted) },
    });
    let mut row = row;
    if d.looped {
        row["looped"] = json!(true); // a repetition loop was cut out of it (the Dictation Lab, feedback reports)
    }
    super::history::append_line(&row);
}

/// A take whose recognition failed (the Mac's "asr_failed:<code>" entry): no text, its recording kept, Retry on the
/// island and on the Dictation page (history.rs).
fn failed_history(t: &Take, code: &str) {
    let app = t.front.as_ref();
    super::history::append_line(&json!({
        "id": t.id, "t": t.wall.to_rfc3339_opts(chrono::SecondsFormat::Secs, false),
        "app": app.map(|f| f.exe.trim_end_matches(".exe").to_string()), "bundle": app.map(|f| f.exe.clone()),
        "app_name": app.and_then(ins::app_name),
        "duration": (t.duration * 100.0).round() / 100.0, "raw": "", "polished": null, "text": "", "model": null,
        "fell_back": false, "reason": format!("asr_failed:{code}"), "insert": "none",
        "audio": format!("audio/{}.wav", t.id), "asr_ms": t.asr_ms,
        "style": t.style.as_str(),
    }));
}
