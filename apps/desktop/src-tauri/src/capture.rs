//! Capture on Windows / Linux (contract K7): recordings through `blurt_capture` (`record.py start --engine ffmpeg
//! --status-jsonl`), snaps and voice notes outside a recording through `tk_recorder.py shot` / `voice`. The island
//! shows all of it; nothing here opens a window by itself beyond the picker and the note bubble the user asked for.
//!
//! Where things go (K2): the current project's store, or the inbox store when the project is `auto`. A recording is
//! sorted as soon as it ends (a process job whose parent is the record job). A snap or a voice note taken while a
//! project is current flies into the island and is filed there at once (`captures.py file`: the note is the item, no
//! agent — the Mac's Snapper.file); in `auto` it hangs under the island as a card until the user drops it on a project
//! (filed the same way) or lets the AI organize them.
//!
//! Everything here runs off the main thread (blurt_capture: the picker blocks, and creating windows from the main
//! thread deadlocks on Windows).

use std::io::Write;
#[cfg(not(dict))]
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::process::ChildStdin;
#[cfg(not(dict))]
use std::process::Stdio;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use blurt_capture::overlay::{self, Card, OverlayConfig};
use blurt_capture::{CaptureHandle, CaptureOptions, CaptureState, Launcher, Mic, Region, StatusEvent};
use serde_json::{json, Value};
use tauri::{AppHandle, Emitter, Manager};

use crate::jobs::JobWriter;
use crate::projects::{self, Registry};
use crate::{agents, island, l10n, scripts, settings, AppState};

/// the snap flow: picker, frozen picture + pen + note bubble, card (the Mac's Snapper / InkStage / NoteBubble)
pub mod snap;
/// the recording's countdown and the frame round its area (the Mac's Chrome.swift)
mod chrome;
/// what the PC plays, as the take's second audio track (record.system_audio)
mod sysaudio;
/// Windows: the overlays that take the keys really get them (the foreground lock)
#[cfg(windows)]
mod focus;
#[cfg(target_os = "linux")]
pub mod portal_linux;
/// a recording on its way to being organized: the usual length, Change (the Mac's OrganizeProgress / Refile)
mod organize;

struct Take {
    session: PathBuf,
    project: Option<String>,
    job: Arc<JobWriter>,
    /// seconds recorded before the current stretch, and when the current stretch began
    elapsed: f64,
    since: Option<Instant>,
    paused: bool,
    shots: u32,
    /// the recorded area (Start Over records it again without the picker; the frame goes round it)
    region: Option<Region>,
    /// the 3-2-1 is on: not recording yet (the island waits for "started")
    countdown: bool,
    /// Save Video Only: kept, not organized (the Mac's Recorder.videoOnly)
    video_only: bool,
    /// Start Over: once this take is discarded, the same area again
    restart: bool,
    /// the pen is latched (its key / the ··· menu; the Mac's ⌥D): on while not paused
    pen: bool,
    #[cfg(windows)]
    system: Option<sysaudio::Loopback>,
    /// Wayland: the ScreenCast stream record.py reads — held, never read: dropping it with the take closes the session
    #[cfg(target_os = "linux")]
    #[allow(dead_code)]
    cast: Option<portal_linux::Cast>,
}

/// a `snap-region` still waiting for its status line: (n, file), or None if it failed
type SnapWait = std::sync::mpsc::Sender<Option<(u32, String)>>;

struct Voice {
    stdin: Option<ChildStdin>,
    started: Instant,
    hold: bool,
}

#[derive(Default)]
pub struct Capture {
    handle: Mutex<Option<Arc<Mutex<CaptureHandle>>>>,
    take: Mutex<Option<Take>>,
    voice: Mutex<Option<Voice>>,
    /// a picker or a note is open: a second press must not open another
    busy: Mutex<bool>,
    /// snaps of an area asked of record.py during a take (`snap-region`), oldest first: each gets the next `snap`
    /// status line — (n, file) — or None for a failed still
    snap_waits: Mutex<Vec<SnapWait>>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Control {
    Pause,
    Resume,
    Stop,
    Snap,
    Marker,
    Discard,
    /// Save Video Only: finish, keep the video, don't organize it
    VideoOnly,
    /// the countdown's Start now / a click on it
    Go,
}

impl Control {
    pub fn parse(s: &str) -> Option<Self> {
        Some(match s {
            "pause" => Control::Pause,
            "resume" => Control::Resume,
            "stop" => Control::Stop,
            "snap" => Control::Snap,
            "marker" => Control::Marker,
            "discard" => Control::Discard,
            "videoonly" | "video_only" => Control::VideoOnly,
            "go" => Control::Go,
            _ => return None,
        })
    }
    fn verb(self) -> &'static str {
        match self {
            Control::Pause => "pause",
            Control::Resume => "resume",
            Control::Stop | Control::VideoOnly => "stop",
            Control::Snap => "snap",
            Control::Marker => "marker",
            Control::Discard => "discard",
            Control::Go => "go",
        }
    }
}

pub fn overlay_config() -> OverlayConfig {
    // every area picker: a click takes the window under the pointer, the key legend the first few times (snap.rs)
    overlay::set_picker_hooks(overlay::PickerHooks { windows: snap::visible_windows, hint: snap::hint_budget, still: snap::monitor_still });
    #[cfg(windows)]
    overlay::set_focus_hook(focus::force);
    OverlayConfig {
        lang: Some(l10n::lang().into()),
        platform: Some(if cfg!(windows) { "win" } else { "gnome" }.into()),
        ..Default::default()
    }
}

fn last_region() -> Option<Region> {
    let v = settings::read_config();
    let r = v.pointer("/record/last_region_px")?.as_array()?;
    let n: Vec<i64> = r.iter().filter_map(Value::as_i64).collect();
    (n.len() == 4 && n[2] > 0 && n[3] > 0).then(|| Region::new(n[0] as i32, n[1] as i32, n[2] as u32, n[3] as u32))
}

fn mic_from_config() -> Mic {
    let v = settings::read_config();
    match v.pointer("/record/mic") {
        Some(Value::Bool(false)) => Mic::None,
        Some(Value::String(s)) if s == "off" || s == "none" => Mic::None,
        Some(Value::String(s)) if !s.is_empty() && s != "default" => Mic::Named(s.clone()),
        _ => Mic::Default,
    }
}

fn toast_error(app: &AppHandle, code: &str) {
    island::send(app, json!({"op": "toast", "kind": "error", "code": code}));
    let _ = app.emit("capture://status", json!({"ev": "error", "code": code, "msg": l10n::t(&format!("error.{code}"))}));
}

impl Capture {
    /// For the island and the main window: {recording, paused, elapsed, shots, session, project, picking, voice}.
    pub fn state(&self) -> Value {
        let h = self.handle.lock().unwrap().clone();
        let st = h.as_ref().map(|h| h.lock().unwrap().state());
        let take = self.take.lock().unwrap();
        let elapsed = take.as_ref().map(|t| t.elapsed + t.since.map_or(0.0, |s| s.elapsed().as_secs_f64()));
        let end_on_pause = settings::read_config().pointer("/record/voice/end_on_pause").and_then(Value::as_bool).unwrap_or(false);
        // how it ends, for the island's hint: on release (held), at a pause, or by the key / Done
        let voice = self.voice.lock().unwrap().as_ref().map(|v| {
            let ends = if v.hold { "hold" } else if end_on_pause || !cfg!(windows) { "pause" } else { "key" };
            #[cfg(dict)]
            let structured = crate::dictation::voice::structured();
            #[cfg(not(dict))]
            let structured = false;
            // the note's cap (record.voice.max_seconds; Windows' voice.rs ends it there) and what is left of it
            let max = settings::read_config().pointer("/record/voice/max_seconds").and_then(Value::as_f64).unwrap_or(600.0);
            let elapsed = v.started.elapsed().as_secs_f64();
            json!({"elapsed": elapsed, "hold": v.hold, "ends": ends, "structured": structured,
                   "limit": {"left": (max - elapsed).max(0.0), "max": max}})
        });
        json!({
            "recording": matches!(st, Some(CaptureState::Starting | CaptureState::Recording | CaptureState::Paused)),
            "paused": take.as_ref().is_some_and(|t| t.paused),
            "elapsed": elapsed,
            "shots": take.as_ref().map_or(0, |t| t.shots),
            "session": take.as_ref().map(|t| scripts::s(&t.session)),
            "project": take.as_ref().and_then(|t| t.project.clone()),
            "picking": *self.busy.lock().unwrap(),
            "voice": voice,
            // the 3-2-1 before a take: the take exists (Finish / Discard cancel it) but nothing is recorded yet
            "countdown": take.as_ref().is_some_and(|t| t.countdown),
            "pen": take.as_ref().is_some_and(|t| t.pen),
        })
    }

    pub fn recording(&self) -> bool {
        self.state()["recording"] == true
    }

    pub fn control(&self, c: Control) -> Result<(), String> {
        let h = self.handle.lock().unwrap().clone().ok_or("not recording")?;
        if matches!(c, Control::Stop | Control::VideoOnly | Control::Discard) {
            if let Some(t) = self.take.lock().unwrap().as_mut() {
                t.video_only |= c == Control::VideoOnly;
                // what the PC played is complete before record.py reads it
                #[cfg(windows)]
                if let Some(l) = t.system.take() {
                    l.stop();
                }
            }
        }
        let r = h.lock().unwrap().send(c.verb());
        r.map_err(|e| e.to_string())
    }

    /// A still of `region` (desktop px) into the running take (record.py `snap-region`: its own numbering, the
    /// video time, events.jsonl): (n, "shots/NNN.png") once it is on disk, None after an error or 20 s.
    pub fn shoot_in_take(&self, region: Region) -> Option<(u32, String)> {
        let h = self.handle.lock().unwrap().clone()?;
        let (tx, rx) = std::sync::mpsc::channel();
        self.snap_waits.lock().unwrap().push(tx);
        let cmd = format!("snap-region:{},{},{},{}", region.x, region.y, region.w, region.h);
        if h.lock().unwrap().send(&cmd).is_err() {
            self.snap_waits.lock().unwrap().pop();
            return None;
        }
        rx.recv_timeout(Duration::from_secs(20)).ok().flatten()
    }

    /// A stroke the pen drew (rec.html `stroke`: shape, points 0–1 of the area, how long it took): into events.jsonl
    /// at its video time (record.py `stroke:`; the Mac's Recorder.log("stroke")).
    pub fn log_stroke(&self, stroke: &Value) {
        if let Some(h) = self.handle.lock().unwrap().clone() {
            let _ = h.lock().unwrap().send(&format!("stroke:{stroke}"));
        }
    }

    /// The take's session and project, for a snap during it (none during the countdown).
    fn take_for_snap(&self) -> Option<(PathBuf, Option<String>)> {
        self.take.lock().unwrap().as_ref().filter(|t| !t.countdown).map(|t| (t.session.clone(), t.project.clone()))
    }

    /// Start Over (the Mac's stop(discard:restart:)): this take goes, and once it has, the same area is recorded again
    /// — no picker, the countdown as usual.
    pub fn restart(&self) -> Result<(), String> {
        if let Some(t) = self.take.lock().unwrap().as_mut() {
            t.restart = true;
        }
        self.control(Control::Discard)
    }

    fn claim(&self) -> bool {
        let mut b = self.busy.lock().unwrap();
        if *b {
            return false;
        }
        *b = true;
        true
    }

    fn release(&self) {
        *self.busy.lock().unwrap() = false;
    }

    /// Picker → record. Blocks until the take has started or failed: call from a worker thread.
    pub fn start(&self, app: &AppHandle, session: Option<PathBuf>, region: Option<Region>, pick: bool) -> Result<String, String> {
        if self.recording() {
            return Err("already recording".into());
        }
        if !self.claim() {
            return Err("busy".into());
        }
        island::busy(app, true);
        let res = self.start_inner(app, session, region, pick);
        self.release();
        island::busy(app, false);
        island::refresh(app);
        res
    }

    fn start_inner(&self, app: &AppHandle, session: Option<PathBuf>, region: Option<Region>, pick: bool) -> Result<String, String> {
        let runner = app.state::<AppState>().runner();
        let record_py = runner.scripts.as_ref().map(|d| d.join("record.py")).filter(|p| p.is_file()).ok_or("scripts")?;
        let launcher = match &runner.uv {
            Some(uv) => Launcher::uv(uv, &record_py),
            None => Launcher::detect(&record_py).ok_or("uv")?,
        };
        let cfg = overlay_config();
        let region = if pick && region.is_none() {
            let _ = app.emit("capture://status", json!({"ev": "picking"}));
            match overlay::pick_region(app, &cfg, last_region(), overlay::Purpose::Record).map_err(|e| e.to_string())? {
                Some(r) => {
                    let _ = settings::merge(json!({"record": {"last_region_px": [r.x, r.y, r.w, r.h]}}));
                    Some(r)
                }
                None => {
                    let _ = app.emit("capture://status", json!({"ev": "cancelled"}));
                    return Err("cancelled".into());
                }
            }
        } else {
            region
        };
        let reg = Registry::load();
        let (project, session) = match session {
            Some(s) => (reg.project_of_path(&s).filter(|p| p != "inbox"), s),
            None => projects::new_video_session(&reg),
        };
        std::fs::create_dir_all(&session).map_err(|e| format!("{}: {e}", session.display()))?;
        let _ = app.asset_protocol_scope().allow_directory(&session, true);
        let job = Arc::new(JobWriter::new("record", project.as_deref(), Some(&session), None, None, &["capture", "finalize"]));
        job.step("capture", "running", None);
        let mut opts = CaptureOptions::new(launcher, &session);
        opts.region = region;
        opts.mic = mic_from_config();
        opts.env = scripts::agent_environment().iter().map(|(k, v)| (k.into(), v.into())).collect();
        opts.env.push(("BLURT_JOB".into(), job.id.clone().into()));
        let rec_cfg = settings::read_config();
        // Settings → Recording: the 3-2-1 (none / 3 / 5 s) and what the PC plays as a second track
        opts.countdown = Some(rec_cfg.pointer("/record/countdown").and_then(Value::as_u64).unwrap_or(3).min(10) as u32);
        let system_audio = rec_cfg.pointer("/record/system_audio").and_then(Value::as_bool).unwrap_or(false);
        // started before record.py, so it covers the first frame (record.py cuts it to each segment)
        #[cfg(windows)]
        let system = system_audio
            .then(|| sysaudio::Loopback::start(&session).map_err(|e| eprintln!("blurt: system audio: {e}")).ok())
            .flatten();
        #[cfg(windows)]
        {
            opts.system_audio = system.is_some();
        }
        #[cfg(not(windows))]
        let _ = system_audio; // Linux: no loopback here yet (recording.md §8)
        // Wayland: the screen comes from the ScreenCast portal (its dialog the first time, over the island)
        #[cfg(target_os = "linux")]
        let cast = if crate::hotkeys::is_wayland() {
            let parent = crate::mainwin::x11_id_off_main(app, "blurt-overlay-island").or_else(|| crate::mainwin::x11_id_off_main(app, "main"));
            match portal_linux::screencast(parent) {
                Ok(c) => {
                    opts.env.extend(c.env().into_iter().map(|(k, v)| (k.into(), v.into())));
                    Some(c)
                }
                Err(e) => {
                    job.finish("failed", Some(("screencast", &e)));
                    return Err(if e == "denied" { "cancelled".into() } else { format!("screen sharing: {e}") });
                }
            }
        } else {
            None
        };
        chrome::listen_once(app);
        // the 3-2-1 is up the moment the area is chosen (the Mac's is): record.py's own countdown lines, once it has
        // started (~1 s through uv), only move the number on
        if let Some(n) = opts.countdown.filter(|n| *n > 0) {
            chrome::countdown(app, region, u64::from(n), u64::from(n));
        }
        let sdir = scripts::s(&session);
        let (app_ev, app_done, sdir2) = (app.clone(), app.clone(), sdir.clone());
        // the take exists before the recorder does: its first status line ("started") must find it
        *self.take.lock().unwrap() = Some(Take {
            session: session.clone(),
            project,
            job: job.clone(),
            elapsed: 0.0,
            since: None,
            paused: false,
            shots: 0,
            region,
            countdown: opts.countdown.is_some_and(|n| n > 0),
            video_only: false,
            restart: false,
            pen: false,
            #[cfg(windows)]
            system,
            #[cfg(target_os = "linux")]
            cast,
        });
        let handle = blurt_capture::record(&opts, move |e| on_status(&app_ev, e), move |res| finished(&app_done, &sdir2, res)).map_err(|e| {
            chrome::close_all(app);
            *self.take.lock().unwrap() = None;
            job.finish("failed", Some(("io", &e.to_string())));
            e.to_string()
        })?;
        *self.handle.lock().unwrap() = Some(handle);
        island::keep_clear_of(app, region);
        crate::on_recording(app, true);
        let _ = app.emit("capture://status", json!({"ev": "started", "session": sdir}));
        Ok(sdir)
    }
}

/// One status line of the take: timing and counts for the island; the snap button's note.
fn on_status(app: &AppHandle, e: &StatusEvent) {
    let cap = &app.state::<AppState>().capture;
    rec_chrome(app, e);
    {
        let mut take = cap.take.lock().unwrap();
        if let Some(t) = take.as_mut() {
            match e {
                StatusEvent::Started { .. } | StatusEvent::Resumed { .. } => {
                    t.since = Some(Instant::now());
                    t.paused = false;
                    t.countdown = false;
                }
                StatusEvent::Paused { .. } => {
                    t.elapsed += t.since.take().map_or(0.0, |s| s.elapsed().as_secs_f64());
                    t.paused = true;
                }
                StatusEvent::Snap { n, file, .. } => {
                    t.shots += 1;
                    let mut w = cap.snap_waits.lock().unwrap();
                    if !w.is_empty() {
                        let _ = w.remove(0).send(Some((*n, file.clone())));
                    }
                }
                _ => {}
            }
        }
    }
    if let StatusEvent::Error { code: Some(c), .. } = e {
        let mut w = cap.snap_waits.lock().unwrap();
        if c == "snap" && !w.is_empty() {
            let _ = w.remove(0).send(None);
        }
    }
    match e {
        StatusEvent::Level { .. } => island::send(app, json!({"op": "status", "line": e.to_json()})),
        _ => {
            island::send(app, json!({"op": "status", "line": e.to_json()}));
            island::refresh(app);
        }
    }
}

/// The pen's key (Alt+Shift+D) and the ··· menu's Pen: latch the pen on or off for this take (the Mac's
/// Recorder.togglePen). While it is on, Esc turns it off (the recorded app can't be clicked meanwhile).
pub fn toggle_pen(app: &AppHandle) {
    set_pen(app, None);
}

/// `on`: None toggles. The pen draws only while the take rolls (never paused, never during the countdown).
pub fn set_pen(app: &AppHandle, on: Option<bool>) {
    let cap = &app.state::<AppState>().capture;
    let (region, live) = {
        let mut take = cap.take.lock().unwrap();
        let Some(t) = take.as_mut().filter(|t| !t.countdown) else { return };
        t.pen = on.unwrap_or(!t.pen);
        (t.region, t.pen && !t.paused)
    };
    crate::hotkeys::transient(app, "penesc", live.then_some("Escape"));
    chrome::ink(app, region, live);
    island::refresh(app);
}

/// The take's chrome follows its status lines (recording.md §3–4, §7): the countdown, the frame (dashed while paused),
/// the live caption's watcher once it rolls, the low-space line.
fn rec_chrome(app: &AppHandle, e: &StatusEvent) {
    let cap = &app.state::<AppState>().capture;
    let (region, session) = match cap.take.lock().unwrap().as_ref() {
        Some(t) => (t.region, t.session.clone()),
        None => return,
    };
    match e {
        StatusEvent::Other(v) if v["ev"] == "countdown" => {
            let n = v["n"].as_u64().unwrap_or(0);
            chrome::countdown(app, region, n, v["total"].as_u64().unwrap_or(n));
            if n > 0 {
                chrome::sound(app, "rec-tick");
            }
        }
        StatusEvent::Other(v) if v["ev"] == "low_space" => {
            let gb = v["free"].as_f64().unwrap_or(0.0) / 1e9;
            let free = if gb >= 1.0 { format!("{gb:.1} GB") } else { format!("{:.0} MB", gb * 1000.0) };
            island::send(app, json!({"op": "toast", "kind": "capture", "msg": "rec.low_space", "vars": {"free": free},
                "key": "record-low-space", "ms": 6000, "mark": "warning"}));
        }
        StatusEvent::Started { .. } => {
            chrome::countdown(app, region, 0, 0);
            chrome::frame(app, region, false);
            watch_live(app, &session);
        }
        // paused: the frame dashed and the pen put down (it comes back on with the take)
        StatusEvent::Paused { .. } | StatusEvent::Resumed { .. } => {
            let paused = matches!(e, StatusEvent::Paused { .. });
            chrome::frame(app, region, paused);
            let pen = cap.take.lock().unwrap().as_ref().is_some_and(|t| t.pen);
            if pen {
                crate::hotkeys::transient(app, "penesc", (!paused).then_some("Escape"));
                chrome::ink(app, region, !paused);
            }
        }
        _ => {}
    }
}

/// While the take runs (the Mac's RecordingWatch, once a second): the newest line of live/transcript.jsonl goes under
/// the island as the live caption (record.live_caption, default on) — a line closed while paused waits for the resume.
fn watch_live(app: &AppHandle, session: &Path) {
    let (app, session) = (app.clone(), session.to_path_buf());
    std::thread::spawn(move || {
        let file = session.join("live").join("transcript.jsonl");
        let (mut offset, mut pending, mut last) = (0usize, None::<String>, String::new());
        loop {
            std::thread::sleep(Duration::from_secs(1));
            let (paused, same) = match app.state::<AppState>().capture.take.lock().unwrap().as_ref() {
                Some(t) => (t.paused, t.session == session),
                None => (false, false),
            };
            if !same {
                break;
            }
            let raw = std::fs::read(&file).unwrap_or_default();
            if raw.len() < offset {
                offset = 0; // rewritten from scratch
            }
            if let Some(end) = raw[offset..].iter().rposition(|&b| b == b'\n') {
                let chunk = String::from_utf8_lossy(&raw[offset..offset + end + 1]).into_owned();
                offset += end + 1;
                if let Some(t) = chunk.lines().filter_map(|l| serde_json::from_str::<Value>(l).ok()).filter_map(|v| v["text"].as_str().map(str::to_owned)).next_back() {
                    pending = Some(t);
                }
            }
            let on = settings::read_config().pointer("/record/live_caption").and_then(Value::as_bool).unwrap_or(true);
            if !on || paused {
                continue;
            }
            if let Some(t) = pending.take().map(|t| t.trim().to_string()).filter(|t| !t.is_empty() && *t != last) {
                island::send(&app, json!({"op": "caption", "text": t}));
                last = t;
            }
        }
    });
}

/// A saved take that wasn't plain sailing, said once after its own line (the Mac's App.sayRecovered; recording.md
/// §6.6): it ended before Finish ("The recorded display was disconnected — the first 3:12 is kept"), or the grabber
/// was started again and a few seconds are missing. record.py put both in meta.json.
fn say_recovered(app: &AppHandle, session: &Path, duration: f64) {
    let Some(m) = std::fs::read(session.join("meta.json")).ok().and_then(|b| serde_json::from_slice::<Value>(&b).ok()) else { return };
    let (msg, vars) = if let Some(r) = m.pointer("/ended_early/reason").and_then(Value::as_str) {
        let r = if ["display_gone", "interrupted", "disk_full"].contains(&r) { r } else { "stopped" };
        (format!("rec.partial.{r}"), json!({"length": clock(duration)}))
    } else if m["recovered"].as_array().is_some_and(|a| !a.is_empty()) {
        let lost = m["lost_seconds"].as_f64().unwrap_or(0.0).ceil().max(1.0) as u64;
        ("rec.recovered_lost".to_string(), json!({"n": lost.to_string()}))
    } else {
        return;
    };
    island::send(app, json!({"op": "toast", "kind": "capture", "msg": msg, "vars": vars, "key": "record-recovered", "ms": 8000, "mark": "warning"}));
}

/// `0:42` / `1:02:05`, as the island writes a take's length.
fn clock(secs: f64) -> String {
    let s = secs.max(0.0).round() as u64;
    if s >= 3600 {
        format!("{}:{:02}:{:02}", s / 3600, s / 60 % 60, s % 60)
    } else {
        format!("{}:{:02}", s / 60, s % 60)
    }
}

/// Save Video Only (the Mac's savedVideoOnly): meta.json says so (housekeeping and the skill can tell), the video is
/// selected in File Explorer to send to someone, and the island says so with the way back to it.
fn saved_video_only(app: &AppHandle, session: &Path, duration: f64) {
    let meta = session.join("meta.json");
    let mut m: Value = std::fs::read(&meta).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_else(|| json!({}));
    m["video_only"] = json!(true);
    let _ = std::fs::write(&meta, serde_json::to_string_pretty(&m).unwrap_or_default());
    reveal_video(session);
    island::send(app, json!({"op": "toast", "kind": "capture", "msg": "rec.video_only_saved", "vars": {"length": clock(duration)},
        "key": "record-saved", "ms": 8000, "mark": "check",
        "action": {"a": format!("rec.reveal:{}", scripts::s(session)), "label": "rec.show_in_explorer"}}));
}

/// The take's video selected in File Explorer (Linux: its folder opened).
pub fn reveal_video(session: &Path) {
    let video = session.join("recording.mp4");
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        let arg = format!("/select,{}", crate::paths::normalize(&video).display());
        let _ = std::process::Command::new("explorer").raw_arg(arg).spawn();
    }
    #[cfg(not(windows))]
    {
        let _ = video;
        let _ = std::process::Command::new("xdg-open").arg(session).spawn();
    }
}

/// `blurt://record` / `blurt://snap` from a link while Blurt isn't in front: the island asks first, one click to go
/// ahead (the Mac's confirmFromURL: "A link wants to start a screen recording · Start Recording").
pub fn confirm_from_url(app: &AppHandle, what: &str) {
    island::send(app, json!({"op": "toast", "kind": "capture", "msg": format!("rec.url.ask_{what}"), "key": "url-confirm",
        "ms": 10000, "mark": "warning", "action": {"a": format!("rec.url:{what}"), "label": format!("rec.url.{what}")}}));
}

/// The island's buttons on a take's lines: `rec.reveal:<session>` (Show in File Explorer), `rec.again:x,y,w,h`
/// (Record Again: the same area, no picker), `rec.url:record|snap` (a link's go-ahead).
pub fn rec_action(app: &AppHandle, action: &str) {
    if let Some(what) = action.strip_prefix("rec.url:") {
        match what {
            "record" if !app.state::<AppState>().capture.recording() => toggle(app),
            "snap" => snap(app),
            _ => {}
        }
    } else if let Some((from, uids)) = action.strip_prefix("rec.refile:").and_then(|r| r.split_once('|')) {
        offer_refile(app, from, uids);
    } else if let Some(s) = action.strip_prefix("rec.change:") {
        organize::offer_change(app, Path::new(s));
    } else if let Some((to, s)) = action.strip_prefix("rec.move:").and_then(|r| r.split_once('|')) {
        match s.strip_prefix("items:").and_then(|t| t.split_once('|')) {
            Some((from, uids)) => refile_items(app, from, uids, to),
            None => organize::refile(app, Path::new(s), to),
        }
    } else if let Some(s) = action.strip_prefix("rec.reveal:") {
        reveal_video(Path::new(s));
    } else if let Some(r) = action.strip_prefix("rec.again:") {
        let n: Vec<i64> = r.split(',').filter_map(|x| x.parse().ok()).collect();
        let region = (n.len() == 4 && n[2] > 0 && n[3] > 0).then(|| Region::new(n[0] as i32, n[1] as i32, n[2] as u32, n[3] as u32));
        let app = app.clone();
        std::thread::spawn(move || {
            if let Err(e) = app.state::<AppState>().capture.start(&app, None, region, region.is_none()) {
                if e != "cancelled" {
                    toast_error(&app, "unknown");
                }
            }
        });
    }
}

fn finished(app: &AppHandle, session: &str, res: Result<StatusEvent, blurt_capture::CaptureError>) {
    let st = app.state::<AppState>();
    *st.capture.handle.lock().unwrap() = None;
    let take = st.capture.take.lock().unwrap().take();
    chrome::close_all(app);
    crate::hotkeys::transient(app, "penesc", None);
    #[cfg(windows)]
    let take = take.map(|mut t| {
        if let Some(l) = t.system.take() {
            l.stop();
        }
        t
    });
    crate::on_recording(app, false);
    island::keep_clear_of(app, None);
    let mut v = match &res {
        Ok(e) => e.to_json(),
        Err(e) => json!({"ev": "error", "msg": e.to_string()}),
    };
    v["session"] = json!(session);
    let _ = app.emit("capture://status", &v);
    if let Some(t) = &take {
        t.job.step("capture", "done", None);
        match v["ev"].as_str() {
            Some("stopped") => {
                t.job.step("finalize", "done", None);
                t.job.finish("done", None);
            }
            Some("discarded") => t.job.finish("cancelled", None),
            _ => t.job.finish("failed", Some(("io", v["msg"].as_str().unwrap_or("recording failed")))),
        }
    }
    crate::watcher::update(app, &[PathBuf::from(session)]);
    let duration = v["duration"].as_f64().unwrap_or(0.0);
    st.capture.snap_waits.lock().unwrap().clear();
    // the take's snaps hung on their threads while it ran; they go with the recording now (snap-and-note.md §11)
    island::refresh_cards(app);
    island::refresh(app);
    match v["ev"].as_str() {
        Some("stopped") => {
            // the take's end in the ears (the Mac's RecordingDone: ✓ and its length); an island without it ignores it
            island::send(app, json!({"op": "rec_done", "length": clock(duration)}));
            chrome::sound(app, "rec-done");
            say_recovered(app, Path::new(session), duration);
            let organize = settings::read_config().pointer("/record/process").and_then(Value::as_str) != Some("off");
            if take.as_ref().is_some_and(|t| t.video_only) {
                saved_video_only(app, Path::new(session), duration);
            } else if organize {
                // K7: a recording is sorted as soon as it ends, item by item into projects when it was taken in auto
                let parent = take.as_ref().map(|t| t.job.id.clone());
                let project = take.as_ref().and_then(|t| t.project.clone());
                let name = organize::name(project.as_deref());
                let place = project.clone().unwrap_or_else(|| "inbox".into());
                match agents::process(app, Path::new(session), None, project, None, parent) {
                    // where its items go, how long that usually takes here, and Change (Refile.offerRecording, §6.2)
                    Ok(_) => {
                        let (msg, vars) = match organize::usual(duration) {
                            Some(u) => ("rec.organizing_usual", json!({"project": name, "minutes": organize::minutes(u).to_string()})),
                            None => ("rec.organizing", json!({"project": name})),
                        };
                        // its mark: the project's folder (where it goes), never a done check on something that just began
                        island::send(app, json!({"op": "toast", "kind": "capture", "msg": msg, "vars": vars,
                            "key": format!("refile.{session}"), "ms": 8000, "project": place,
                            "action": {"a": format!("rec.change:{session}"), "label": "rec.change"}}));
                    }
                    Err(code) => toast_error(app, if code == "no_agent" { "no_agent" } else { "unknown" }),
                }
            } else {
                // Settings → After a recording: Keep the video only
                island::send(app, json!({"op": "toast", "kind": "capture", "msg": "rec.saved", "vars": {"length": clock(duration)},
                    "key": "record-saved", "ms": 6000, "mark": "check"}));
            }
        }
        Some("discarded") => {
            // Start Over: the same area again, the countdown as usual
            if let Some(t) = take.as_ref().filter(|t| t.restart) {
                let (app, region) = (app.clone(), t.region);
                std::thread::spawn(move || {
                    if let Err(e) = app.state::<AppState>().capture.start(&app, None, region, region.is_none()) {
                        if e != "cancelled" {
                            toast_error(&app, "unknown");
                        }
                    }
                });
            }
        }
        _ => {
            // nothing was kept: say why, and offer the same area again (the Mac's failedTake alert, on the island)
            let msg = if v["code"] == "no_frames" { "rec.failed.no_frames" } else { "rec.failed.unknown" };
            let again = take.as_ref().and_then(|t| t.region).map_or_else(|| "record".to_string(), |r| format!("rec.again:{},{},{},{}", r.x, r.y, r.w, r.h));
            island::send(app, json!({"op": "toast", "kind": "capture", "msg": msg,
                "key": "record-failed", "ms": 10000, "mark": "warning", "action": {"a": again, "label": "rec.again"}}));
        }
    }
}

/// Tray, record hotkey, island button, blurt://record (spawns: never blocks the caller).
pub fn toggle(app: &AppHandle) {
    let app = app.clone();
    std::thread::spawn(move || {
        let st = app.state::<AppState>();
        let res = if st.capture.recording() {
            st.capture.control(Control::Stop).map(|_| String::new())
        } else {
            st.capture.start(&app, None, None, true)
        };
        if let Err(e) = res {
            if e != "cancelled" {
                toast_error(&app, if ["scripts", "uv", "busy"].contains(&e.as_str()) { &e } else { "unknown" });
                eprintln!("blurt: record: {e}");
            }
        }
    });
}

/// Wait for a take to end (quit).
pub fn stop_and_wait(app: &AppHandle, timeout: Duration) {
    let st = app.state::<AppState>();
    let h = st.capture.handle.lock().unwrap().clone();
    if let Some(h) = h {
        let _ = h.lock().unwrap().stop_and_wait(timeout);
    }
}

fn append_line(session: &Path, line: &Value) {
    if let Ok(mut f) = std::fs::OpenOptions::new().append(true).create(true).open(session.join("shots.jsonl")) {
        let _ = writeln!(f, "{line}");
    }
}

/// Just under the island, centred: where the note bubble opens.
fn island_anchor(app: &AppHandle) -> Region {
    let r = island::rect(app).unwrap_or(Region::new(0, 0, 1920, 600));
    Region::new(r.x + r.w as i32 / 2 - 1, r.y + 64, 2, 2)
}

// ------------------------------------------------------------------ snaps

/// The snap hotkey: during a recording just a frame (no pause, no note); otherwise pick an area and snap it.
pub fn snap(app: &AppHandle) {
    let app = app.clone();
    std::thread::spawn(move || {
        let cap = &app.state::<AppState>().capture;
        if cap.recording() {
            snap_in_take(&app);
        } else {
            snap_area(&app);
        }
    });
}

/// The island's snap button: exactly the snap hotkey (the Mac's Island.snapWithNote) — during a take the snap flow
/// into it, the recording going on.
pub fn snap_with_note(app: &AppHandle) {
    snap(app);
}

/// During a take (the Mac's ⌥A while recording; snap-and-note.md §11, recording.md §5.8): the snap flow — pick an
/// area, its note, its card on the thread — with the still taken by record.py into the take (its number, the video
/// time, events.jsonl). Nothing during the countdown.
fn snap_in_take(app: &AppHandle) {
    let cap = &app.state::<AppState>().capture;
    let Some((session, project)) = cap.take_for_snap() else { return };
    let a = app.clone();
    let shoot = Box::new(move |r: Region| a.state::<AppState>().capture.shoot_in_take(r));
    snap::run_in_take(app, snap::TakeSnap { session, project, shoot });
}

/// Outside a recording: the Mac's snap flow (capture/snap.rs) — pick, the picture frozen in place with the pen and the
/// note bubble beside it, listening; a card (or filed) when the note is done.
fn snap_area(app: &AppHandle) {
    snap::run(app);
}

/// "Edit Note…" on a card: the full note bubble (snap.rs). Blocks: a worker thread.
pub fn edit_note(app: &AppHandle, session: &Path, n: u32, under: Option<Region>) {
    snap::edit_note(app, session, n, under);
}

/// The island's Undo on "Snap discarded".
pub fn snap_undo(app: &AppHandle) {
    snap::undo(app);
}

/// A snap or a voice note is on disk: into the island and filed (project current) or onto a card (auto).
pub(crate) fn captured(app: &AppHandle, session: &Path, project: Option<String>, card: Card) {
    let n = u64::from(card.n);
    match project {
        Some(p) => {
            island::send(app, json!({"op": "card", "card": card, "pull": true}));
            file_now(app, session, vec![n], &p, None);
        }
        None => {
            island::send(app, json!({"op": "card", "card": card, "pull": false}));
            island::refresh_cards(app);
        }
    }
}

/// Captures with a project become its items at once (the Mac's Snapper.file / Captures.write): `captures.py file` —
/// the note is the item, no agent, no tokens — as a process job all the same (the main window lists it), then one
/// quiet line, "Filed to X · KEY-12 · Change". `by`: an assignment to write first ("user": a card dropped on a
/// project; "capture": the note's chip); None when the capture's own line already says where it goes. A project
/// whose folder is gone takes nothing: they stay cards, and the island offers Locate… (the Mac's keepAsCards).
/// Runs on its own thread.
pub(crate) fn file_now(app: &AppHandle, session: &Path, ns: Vec<u64>, project: &str, by: Option<&'static str>) {
    if ns.is_empty() {
        return;
    }
    let (app, session, project) = (app.clone(), session.to_path_buf(), project.to_string());
    std::thread::spawn(move || {
        let reg = Registry::load();
        let entry = (project != "inbox").then(|| reg.project(&project).cloned()).flatten();
        let name = organize::name(Some(&project));
        if entry.as_ref().is_some_and(|p| !p["path"].as_str().is_some_and(|x| Path::new(x).is_dir())) {
            return kept_as_cards(&app, &session, &ns, &project, &name);
        }
        if let Some(by) = by {
            for n in &ns {
                append_line(&session, &json!({"n": n, "project": project, "assigned_by": by}));
            }
        }
        let job = JobWriter::new("process", (project != "inbox").then_some(project.as_str()), Some(&session), None, None, &["prepare", "write"]);
        job.mark_filed();
        job.set_captures(&ns);
        job.step("prepare", "done", None);
        job.step("write", "running", None);
        let runner = app.state::<AppState>().runner();
        let mut args = vec!["file".to_string(), scripts::s(&session), "--captures".into()];
        args.extend(ns.iter().map(u64::to_string));
        args.extend(["--project".into(), project.clone(), "--lang".into(), if l10n::lang().starts_with("zh") { "zh" } else { "en" }.into()]);
        match runner.run("captures.py", &args, None, Duration::from_secs(120)) {
            Ok(r) => {
                let made: Vec<&Value> = r["items"].as_array().map(|a| a.iter().collect()).unwrap_or_default();
                let uids: Vec<String> = made.iter().filter_map(|i| i["uid"].as_str().map(str::to_owned)).collect();
                job.set_items(&uids);
                job.step("write", "done", None);
                job.finish("done", None);
                crate::items::bump();
                island::refresh_cards(&app);
                island::refresh(&app);
                let Some(first) = made.first() else { return };
                let ids = format!("{}{}", first["id"].as_str().unwrap_or(""), if uids.len() > 1 { format!(" +{}", uids.len() - 1) } else { String::new() });
                island::send(&app, json!({"op": "toast", "kind": "capture", "msg": "snap.filed", "vars": {"project": name, "ids": ids},
                    "key": format!("filed.{}", scripts::s(&session)), "ms": 6000, "mark": "check", "project": project,
                    "action": {"a": format!("rec.refile:{project}|{}", uids.join(",")), "label": "rec.change"}}));
            }
            Err(e) => {
                eprintln!("blurt: captures.py file: {e}");
                job.finish("failed", Some(("io", &e.to_string())));
                if e.to_string().contains("[folder_missing]") {
                    return kept_as_cards(&app, &session, &ns, &project, &name);
                }
                // nothing was written: they hang as cards, and the island says so
                for n in &ns {
                    append_line(&session, &json!({"n": n, "project": null, "assigned_by": null}));
                }
                island::refresh_cards(&app);
                island::send(&app, json!({"op": "toast", "kind": "capture", "msg": "snap.file_failed", "ms": 6000, "mark": "warning"}));
            }
        }
    });
}

/// Their project's folder is gone: they stay (or become) Unassigned cards, "“X” folder not found · Card kept ·
/// Locate…" (the Mac's MissingFolder.warn).
fn kept_as_cards(app: &AppHandle, session: &Path, ns: &[u64], project: &str, name: &str) {
    for n in ns {
        append_line(session, &json!({"n": n, "project": null, "assigned_by": null}));
    }
    island::refresh_cards(app);
    island::send(app, json!({"op": "toast", "kind": "capture", "msg": "island.missing.card_kept", "vars": {"name": name},
        "key": "missing-folder", "ms": 8000, "mark": "warning",
        "action": {"a": "project.locate", "label": "island.locate", "extra": {"id": project}}}));
}

/// "Change" on "Filed to X": the island's project picker; the items go where the user picks (`items:<from>|<uids>`).
fn offer_refile(app: &AppHandle, from: &str, uids: &str) {
    island::send(app, json!({"op": "pick", "title": "snap.file_to", "current": if from == "inbox" { Value::Null } else { json!(from) },
        "token": format!("items:{from}|{uids}")}));
}

/// Filed items to another project (items.py move, only those still where they were filed), then "Moved to Y · Undo".
fn refile_items(app: &AppHandle, from: &str, uids: &str, to: &str) {
    if from == to || uids.is_empty() {
        return;
    }
    let (app, from, uids, to) = (app.clone(), from.to_string(), uids.to_string(), to.to_string());
    std::thread::spawn(move || {
        let mut args = vec!["move".to_string()];
        args.extend(uids.split(',').filter(|u| !u.is_empty()).map(str::to_owned));
        args.extend(["--project".into(), to.clone(), "--from".into(), from.clone()]);
        if app.state::<AppState>().runner().run("items.py", &args, None, Duration::from_secs(60)).is_err() {
            island::send(&app, json!({"op": "toast", "kind": "capture", "msg": "rec.move_failed", "ms": 6000, "mark": "warning"}));
            return;
        }
        crate::items::bump();
        island::send(&app, json!({"op": "toast", "kind": "capture", "msg": "rec.moved", "vars": {"project": organize::name(Some(&to))},
            "key": "refile.items", "ms": 6000, "mark": "check", "project": to,
            "action": {"a": format!("rec.move:{from}|items:{to}|{uids}"), "label": "island.undo"}}));
        island::refresh(&app);
    });
}

// ------------------------------------------------------------------ voice notes

/// The voice hotkey pressed: start (or stop a running one). `hold` = push-to-talk, ends on release. Windows: Blurt's own
/// microphone and the warm speech server, with the words while you talk (dictation/voice.rs).
#[cfg(dict)]
pub fn voice_start(app: &AppHandle, hold: bool) {
    use crate::dictation::voice::{self, End};
    use crate::dictation::voice_rules;
    let cap = &app.state::<AppState>().capture;
    if cap.recording() {
        toast_error(app, "voice.recording");
        return;
    }
    if cap.voice.lock().unwrap().is_some() {
        voice_stop(app, false);
        return;
    }
    if voice::dictation_busy() {
        island::send(app, json!({"op": "toast", "kind": "dictation", "msg": "voice.dictation_busy"}));
        return;
    }
    let reg = Registry::load();
    let (project, session) = projects::shots_session(&reg);
    *cap.voice.lock().unwrap() = Some(Voice { stdin: None, started: Instant::now(), hold });
    let job = Arc::new(JobWriter::new("voice", project.as_deref(), Some(&session), None, None, &["listen", "transcribe", "file"]));
    job.step("listen", "running", None);
    island::refresh(app);
    let app = app.clone();
    std::thread::spawn(move || {
        let end = voice::run(&app, &session, project.as_deref(), hold);
        *app.state::<AppState>().capture.voice.lock().unwrap() = None;
        match end {
            End::Filed(n, _file, said, raw) => {
                job.step("listen", "done", None);
                job.set_captures(&[u64::from(n)]);
                voice_filed(&app, &session, project, n, said, raw, Some(job.as_ref()));
            }
            End::Parked { n, file, parked, unsure, structured } => {
                // "Voice note discarded · Undo" / "No sound detected · Keep": the wav waits under another name
                job.finish("cancelled", None);
                let token = format!("{n}-{}", std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.as_millis()));
                let secs = if unsure { voice_rules::UNSURE_SECONDS } else { voice_rules::UNDO_SECONDS };
                PARKED.lock().unwrap().push((token.clone(), session.clone(), project.clone(), n, file, parked.clone(), structured));
                island::send(&app, json!({"op": "toast", "kind": "dictation", "key": "voice.discarded",
                    "msg": if unsure { "voice.nothing_short" } else { "voice.discarded" }, "ms": (secs * 1000.0) as u64,
                    "action": {"a": format!("voice.undo:{token}"), "label": if unsure { "voice.keep" } else { "dictation.toast.undo" }}}));
                std::thread::spawn(move || {
                    std::thread::sleep(Duration::from_secs_f64(secs + 1.0));
                    let mut p = PARKED.lock().unwrap();
                    if let Some(ix) = p.iter().position(|x| x.0 == token) {
                        p.remove(ix);
                        let _ = std::fs::remove_file(&parked);
                    }
                });
            }
            End::Cancelled => {
                job.finish("cancelled", None);
            }
            End::Nothing { check_mic } => {
                job.finish("cancelled", None);
                island::send(&app, json!({"op": "toast", "kind": "dictation", "msg": if check_mic { "voice.nothing" } else { "voice.nothing_short" }, "ms": 5000}));
            }
            End::NoMic => {
                job.finish("failed", Some(("mic", "voice note failed")));
                toast_error(&app, "voice.mic");
            }
        }
        island::refresh(&app);
    });
}

/// Discarded voice notes waiting for their Undo / Keep: (token, session, project, n, "shots/NNN.wav", the parked wav,
/// Structured).
#[cfg(dict)]
type ParkedNote = (String, PathBuf, Option<String>, u32, String, PathBuf, bool);
#[cfg(dict)]
static PARKED: Mutex<Vec<ParkedNote>> = Mutex::new(Vec::new());

/// A voice note's words are in: its line(s) in shots.jsonl (the words; with Structured, the transcript as heard beside
/// them, `said_raw`), the card.
#[cfg(dict)]
fn voice_filed(app: &AppHandle, session: &Path, project: Option<String>, n: u32, said: Option<String>, raw: Option<String>, job: Option<&JobWriter>) {
    if let Some(t) = &said {
        let mut line = json!({"n": n, "said": t});
        if let Some(r) = &raw {
            line["said_raw"] = json!(r);
        }
        append_line(session, &line);
    }
    if let Some(job) = job {
        job.step("transcribe", if said.is_some() { "done" } else { "skipped" }, None);
        job.finish("done", None);
    }
    captured(app, session, project, Card::voice(session, n, said));
}

/// "Voice note discarded · Undo" / "No sound detected · Keep" clicked (island action `voice.undo:<token>`): the note
/// is filed after all, heard whole.
#[cfg(dict)]
pub fn voice_undo(app: &AppHandle, action: &str) {
    let token = action.strip_prefix("voice.undo:").unwrap_or("");
    let found = {
        let mut p = PARKED.lock().unwrap();
        p.iter().position(|x| x.0 == token).map(|ix| p.remove(ix))
    };
    let Some((_, session, project, n, file, parked, structured)) = found else { return };
    let app = app.clone();
    std::thread::spawn(move || {
        if let Some((said, raw)) = crate::dictation::voice::unpark(&app, &session, n, &file, &parked, structured, project.as_deref()) {
            voice_filed(&app, &session, project, n, said, raw, None);
        }
        island::refresh(&app);
    });
}

/// The voice hotkey pressed: start (or stop a running one). `hold` = push-to-talk, ends on release.
#[cfg(not(dict))]
pub fn voice_start(app: &AppHandle, hold: bool) {
    let cap = &app.state::<AppState>().capture;
    if cap.recording() {
        toast_error(app, "voice.recording");
        return;
    }
    if cap.voice.lock().unwrap().is_some() {
        voice_stop(app, false);
        return;
    }
    let runner = app.state::<AppState>().runner();
    let reg = Registry::load();
    let (project, session) = projects::shots_session(&reg);
    let cfg = settings::read_config();
    let silence = cfg.pointer("/record/voice/silence_ms").and_then(Value::as_u64).unwrap_or(1500);
    let mut args = vec!["voice".to_string(), scripts::s(&session), "--silence-ms".into(), silence.to_string(), "--max".into(), "120".into()];
    if hold {
        args.push("--hold".into());
    }
    if let Some(p) = &project {
        args.extend(["--project".into(), p.clone()]);
    }
    let Ok(argv) = runner.argv("tk_recorder.py", &args) else {
        toast_error(app, "scripts");
        return;
    };
    let mut c = scripts::command(&argv);
    c.stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::null());
    let mut child = match c.spawn() {
        Ok(ch) => ch,
        Err(_) => {
            toast_error(app, "voice.mic");
            return;
        }
    };
    *cap.voice.lock().unwrap() = Some(Voice { stdin: child.stdin.take(), started: Instant::now(), hold });
    let job = Arc::new(JobWriter::new("voice", project.as_deref(), Some(&session), None, None, &["listen", "transcribe", "file"]));
    job.step("listen", "running", None);
    island::refresh(app);
    let stdout = child.stdout.take();
    let app = app.clone();
    std::thread::spawn(move || {
        let mut done: Option<Value> = None;
        let mut failed: Option<String> = None;
        for line in stdout.map(BufReader::new).into_iter().flat_map(|r| r.lines().map_while(Result::ok)) {
            let Ok(v) = serde_json::from_str::<Value>(&line) else { continue };
            match v["ev"].as_str() {
                Some("level") => island::send(&app, json!({"op": "level", "rms": v["rms"]})),
                Some("done") => done = Some(v),
                Some("error") => failed = v["code"].as_str().map(str::to_owned),
                _ => {}
            }
        }
        let _ = child.wait();
        *app.state::<AppState>().capture.voice.lock().unwrap() = None;
        let Some(d) = done else {
            match failed {
                Some(code) => {
                    job.finish("failed", Some((&code, "voice note failed")));
                    toast_error(&app, "voice.mic");
                }
                None => job.finish("cancelled", None),
            }
            island::refresh(&app);
            return;
        };
        job.step("listen", "done", None);
        job.step("transcribe", "running", None);
        let n = d["n"].as_u64().unwrap_or(0);
        job.set_captures(&[n]);
        let wav = session.join(d["file"].as_str().unwrap_or(""));
        let runner = app.state::<AppState>().runner();
        let said = runner
            .run("transcribe.py", &["note".into(), scripts::s(&wav), "--language".into(), "auto".into()], None, Duration::from_secs(120))
            .ok()
            .and_then(|r| r["text"].as_str().map(str::to_owned))
            .filter(|t| !t.trim().is_empty());
        if let Some(t) = &said {
            append_line(&session, &json!({"n": n, "said": t}));
        }
        job.step("transcribe", if said.is_some() { "done" } else { "skipped" }, None);
        job.finish("done", None);
        captured(&app, &session, project, Card::voice(&session, n as u32, said));
        island::refresh(&app);
    });
}

/// Release of the push-to-talk key, the island's stop / Esc (cancel).
pub fn voice_stop(app: &AppHandle, cancel: bool) {
    let st = app.state::<AppState>();
    let mut v = st.capture.voice.lock().unwrap();
    #[cfg(dict)]
    if v.as_ref().is_some_and(|v| v.stdin.is_none()) {
        drop(v);
        crate::dictation::voice::stop(cancel);
        return;
    }
    if let Some(stdin) = v.as_mut().and_then(|v| v.stdin.as_mut()) {
        let _ = stdin.write_all(if cancel { b"cancel\n" } else { b"stop\n" });
        let _ = stdin.flush();
    }
}

/// The push-to-talk key went up: ends a held note (a quick press keeps listening until silence).
pub fn voice_released(app: &AppHandle) {
    let held = app.state::<AppState>().capture.voice.lock().unwrap().as_ref().is_some_and(|v| v.hold || v.started.elapsed() >= Duration::from_millis(350));
    if held {
        voice_stop(app, false);
    }
}

// ------------------------------------------------------------------ cards (K7)

/// Captures waiting under the island: in the inbox store's open shots batches, lines with no project, not deleted —
/// and a snap taken while a project was current whose note sent it to Unassigned (its line in that project's batch says
/// project null; the Mac's cards hang from any store's batch, Snapper.cardBatches).
pub fn load_cards() -> Vec<Card> {
    open_shots_batches().iter().flat_map(|s| cards_of(s)).collect()
}

/// The inbox store's open shots batches, oldest first.
fn open_shots_batches() -> Vec<PathBuf> {
    let dir = crate::paths::inbox_store().join("sessions");
    let mut sessions: Vec<PathBuf> = std::fs::read_dir(&dir)
        .into_iter()
        .flatten()
        .filter_map(Result::ok)
        .map(|e| e.path())
        .filter(|p| p.file_name().is_some_and(|n| n.to_string_lossy().ends_with("-shots")) && projects::is_open_batch(p))
        .collect();
    sessions.sort();
    sessions
}

/// One batch's unfiled captures (shots.jsonl: later lines for the same n win, field by field).
pub fn cards_of(session: &Path) -> Vec<Card> {
    card_lines(session).into_iter().filter(|l| l.taken.is_none()).map(|l| l.card).collect()
}

/// A card with when it was captured (`wall`) and when it was dragged out into another app (`taken`; None: it hangs),
/// both epoch seconds.
pub struct CardLine {
    pub card: Card,
    pub taken: Option<f64>,
    pub wall: Option<f64>,
}

impl CardLine {
    /// The card for the island: its fields, `wall` and (in History) `taken`.
    pub fn to_json(&self) -> Value {
        let mut v = serde_json::to_value(&self.card).unwrap_or_default();
        v["wall"] = json!(self.wall);
        if let Some(t) = self.taken {
            v["taken"] = json!(t);
        }
        v
    }
}

/// The cards hanging now (load_cards), as the island shows them: with when each was captured.
pub fn load_card_values() -> Vec<Value> {
    open_shots_batches().iter().flat_map(|s| card_lines(s)).filter(|l| l.taken.is_none()).map(|l| l.to_json()).collect()
}

/// One batch's unfiled, undeleted captures with when each was dragged out into another app (`taken`, epoch seconds;
/// None: it hangs) — the Mac's Recently Taken; captures.py skips a taken one too.
pub fn card_lines(session: &Path) -> Vec<CardLine> {
    let raw = std::fs::read_to_string(session.join("shots.jsonl")).unwrap_or_default();
    let mut by_n: std::collections::BTreeMap<u64, serde_json::Map<String, Value>> = Default::default();
    for line in raw.lines() {
        let Ok(Value::Object(m)) = serde_json::from_str::<Value>(line) else { continue };
        let Some(n) = m.get("n").and_then(Value::as_u64) else { continue };
        let e = by_n.entry(n).or_default();
        for (k, v) in m {
            e.insert(k, v);
        }
    }
    by_n.into_iter()
        .filter(|(_, m)| m.get("deleted") != Some(&Value::Bool(true)) && m.get("project").is_none_or(Value::is_null))
        // a snap whose note is still open is no card yet (it flies in when the note is done)
        .filter(|(n, _)| !snap::noting(session, *n))
        .map(|(n, m)| {
            let text = ["said", "text"].iter().find_map(|k| m.get(*k).and_then(Value::as_str).filter(|s| !s.is_empty())).map(str::to_owned);
            let voice_only = m.get("type").and_then(Value::as_str) == Some("voice");
            let card = match (voice_only, m.get("marked").and_then(Value::as_str).or(m.get("file").and_then(Value::as_str))) {
                (false, Some(f)) => Card::from_shot(session, n as u32, f, text),
                _ => Card::voice(session, n as u32, text),
            };
            CardLine { card, taken: m.get("taken").and_then(Value::as_f64), wall: m.get("wall").and_then(Value::as_f64) }
        })
        .collect()
}

/// The Cards panel's History (the Mac's CardsSegment.used): cards dragged out or pasted into another app in the last
/// 7 days, newest use first, each with `taken` (epoch seconds) and `wall` (when it was captured).
pub fn load_history() -> Vec<Value> {
    let dir = crate::paths::inbox_store().join("sessions");
    let now = chrono::Utc::now().timestamp_millis() as f64 / 1000.0;
    let mut out: Vec<(f64, Value)> = std::fs::read_dir(&dir)
        .into_iter()
        .flatten()
        .filter_map(Result::ok)
        .map(|e| e.path())
        .filter(|p| p.file_name().is_some_and(|n| n.to_string_lossy().ends_with("-shots")))
        .flat_map(|s| card_lines(&s))
        .filter_map(|l| l.taken.filter(|t| now - t < 7.0 * 86_400.0).map(|t| (t, l.to_json())))
        .collect();
    out.sort_by(|a, b| b.0.total_cmp(&a.0));
    out.into_iter().map(|(_, v)| v).collect()
}

/// A card is thrown away (K7: `{"n", "deleted": true}`). Its files stay: the island offers Undo for a few seconds.
pub fn remove_card(session: &Path, n: u64) {
    append_line(session, &json!({"n": n, "deleted": true}));
}

/// Undo of a delete: the card hangs again.
pub fn restore_card(session: &Path, n: u64) {
    append_line(session, &json!({"n": n, "deleted": false}));
}

/// A card dragged into another app has been used: it leaves its thread (the Mac's Snapper.takeOut, `{"n", "taken":
/// wall}`) — not deleted, its files stay.
pub fn take_card(session: &Path, n: u64) {
    let wall = chrono::Utc::now().timestamp_millis() as f64 / 1000.0;
    append_line(session, &json!({"n": n, "taken": wall}));
}

/// Put Back (Undo of a drag-out): on its thread again.
pub fn put_back_card(session: &Path, n: u64) {
    append_line(session, &json!({"n": n, "taken": null}));
}

/// The next free `n` of a shots batch (tk_recorder.py next_shot_n): past every shots.jsonl line and every file in shots/.
fn next_shot_n(session: &Path) -> u64 {
    let raw = std::fs::read_to_string(session.join("shots.jsonl")).unwrap_or_default();
    let lines = raw.lines().filter_map(|l| serde_json::from_str::<Value>(l).ok()?["n"].as_u64());
    let files = std::fs::read_dir(session.join("shots")).into_iter().flatten().filter_map(Result::ok).filter_map(|e| {
        let name = e.file_name().to_string_lossy().into_owned();
        name.chars().take_while(char::is_ascii_digit).collect::<String>().parse::<u64>().ok()
    });
    lines.chain(files).max().unwrap_or(0) + 1
}

/// A screenshot the system took (Settings → General → Cards, record.collect_system_shots): copied into the shots batch
/// as the next capture — a card, or filed into `project` as a snap would be. The file itself stays where it was.
pub fn import_system_shot(session: &Path, project: Option<&str>, src: &Path) -> Option<Card> {
    let ext = src.extension()?.to_string_lossy().to_lowercase();
    std::fs::create_dir_all(session.join("shots")).ok()?;
    let n = next_shot_n(session);
    let file = format!("shots/{n:03}.{ext}");
    std::fs::copy(src, session.join(&file)).ok()?;
    let wall = chrono::Utc::now().timestamp_millis() as f64 / 1000.0;
    let mut line = json!({"n": n, "file": file, "marked": null, "t": null, "wall": wall, "region": [], "voice": null,
                          "text": null, "strokes": [], "type": "shot", "source": "system", "project": project});
    if project.is_some() {
        line["assigned_by"] = json!("capture");
    }
    append_line(session, &line);
    Some(Card::from_shot(session, n as u32, &file, None))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cards_from_shots_jsonl() {
        let d = tempfile::tempdir().unwrap();
        let s = d.path();
        let lines = [
            json!({"n": 1, "file": "shots/001.png", "type": "shot", "project": null}),
            json!({"n": 2, "type": "voice", "file": null, "voice": "shots/002.wav", "project": null}),
            json!({"n": 2, "said": "加个搜索"}),
            json!({"n": 3, "file": "shots/003.png", "project": "p1", "assigned_by": "capture"}),
            json!({"n": 4, "file": "shots/004.png", "project": null}),
            json!({"n": 4, "deleted": true}),
            json!({"n": 1, "project": "p2", "assigned_by": "user"}),
            json!({"n": 5, "file": "shots/005.png"}),
        ];
        std::fs::write(s.join("shots.jsonl"), lines.iter().map(|l| l.to_string() + "\n").collect::<String>()).unwrap();
        let c = cards_of(s);
        let ns: Vec<u32> = c.iter().map(|c| c.n).collect();
        assert_eq!(ns, [2, 5]);
        assert_eq!((c[0].kind.as_str(), c[0].text.as_deref()), ("voice", Some("加个搜索")));
        assert_eq!(c[1].kind, "shot");
        remove_card(s, 5);
        assert_eq!(cards_of(s).len(), 1);
        restore_card(s, 5);
        assert_eq!(cards_of(s).len(), 2, "Undo hangs it again");
        take_card(s, 5);
        assert_eq!(cards_of(s).len(), 1, "dragged out: off its thread");
        assert!(card_lines(s).iter().any(|l| l.card.n == 5 && l.taken.is_some()), "…and in History");
        put_back_card(s, 5);
        assert_eq!(cards_of(s).len(), 2, "put back");
        let shot = d.path().join("Screenshot 2026-11-02 101500.png");
        std::fs::write(&shot, b"png").unwrap();
        let c = import_system_shot(s, None, &shot).unwrap();
        assert_eq!((c.n, c.file.as_deref()), (6, Some("shots/006.png")), "after every n so far");
        assert!(s.join("shots/006.png").is_file() && shot.is_file(), "copied, the original stays");
        assert_eq!(cards_of(s).len(), 3, "a card");
        // a snap whose note is still open is no card yet: it flies in when the note is done
        snap::set_noting(Some((s, 6)));
        assert_eq!(cards_of(s).len(), 2, "still being noted");
        snap::set_noting(None);
        assert_eq!(cards_of(s).len(), 3, "done: a card");
        // before the shot's n is known: anything written from the next free n on is the open note's
        snap::noting_from(s, 7);
        append_line(s, &json!({"n": 7, "file": "shots/007.png", "project": null}));
        assert_eq!(cards_of(s).len(), 3, "a shot still being taken is no card");
        snap::set_noting(None);
    }
}
