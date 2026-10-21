//! Capture on Windows / Linux (contract K7): recordings through `blurt_capture` (`record.py start --engine ffmpeg
//! --status-jsonl`), snaps and voice notes outside a recording through `tk_recorder.py shot` / `voice`. The island
//! shows all of it; nothing here opens a window by itself beyond the picker and the note bubble the user asked for.
//!
//! Where things go (K2): the current project's store, or the inbox store when the project is `auto`. A recording is
//! sorted as soon as it ends (a process job whose parent is the record job). A snap or a voice note taken while a
//! project is current flies into the island and is sorted with whatever else arrives within 8 s; in `auto` it hangs
//! under the island as a card until the user drops it on a project (or lets the AI sort them).
//!
//! Everything here runs off the main thread (blurt_capture: the picker blocks, and creating windows from the main
//! thread deadlocks on Windows).

use std::collections::HashMap;
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{ChildStdin, Stdio};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use blurt_capture::overlay::{self, Card, OverlayConfig};
use blurt_capture::{CaptureHandle, CaptureOptions, CaptureState, Launcher, Mic, Region, StatusEvent};
use serde_json::{json, Value};
use tauri::{AppHandle, Emitter, Manager};

use crate::jobs::JobWriter;
use crate::projects::{self, Registry};
use crate::{island, l10n, scripts, sessions, settings, AppState};

/// Captures taken while a project is current and arriving within this long of each other are sorted together.
const COALESCE: Duration = Duration::from_secs(8);

struct Take {
    session: PathBuf,
    project: Option<String>,
    job: Arc<JobWriter>,
    /// seconds recorded before the current stretch, and when the current stretch began
    elapsed: f64,
    since: Option<Instant>,
    paused: bool,
    shots: u32,
    /// the island's snap button: pause, snap, ask for a note, then go on
    note_pending: bool,
}

/// (project, captures, generation)
type Pending = (String, Vec<u64>, u64);

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
    /// session → (project, captures, generation): waiting COALESCE before they are sorted
    pending: Mutex<HashMap<PathBuf, Pending>>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Control {
    Pause,
    Resume,
    Stop,
    Snap,
    Marker,
    Discard,
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
            _ => return None,
        })
    }
    fn verb(self) -> &'static str {
        match self {
            Control::Pause => "pause",
            Control::Resume => "resume",
            Control::Stop => "stop",
            Control::Snap => "snap",
            Control::Marker => "marker",
            Control::Discard => "discard",
        }
    }
}

pub fn overlay_config() -> OverlayConfig {
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
        let voice = self.voice.lock().unwrap().as_ref().map(|v| json!({"elapsed": v.started.elapsed().as_secs_f64(), "hold": v.hold}));
        json!({
            "recording": matches!(st, Some(CaptureState::Starting | CaptureState::Recording | CaptureState::Paused)),
            "paused": take.as_ref().is_some_and(|t| t.paused),
            "elapsed": elapsed,
            "shots": take.as_ref().map_or(0, |t| t.shots),
            "session": take.as_ref().map(|t| scripts::s(&t.session)),
            "project": take.as_ref().and_then(|t| t.project.clone()),
            "picking": *self.busy.lock().unwrap(),
            "voice": voice,
        })
    }

    pub fn recording(&self) -> bool {
        self.state()["recording"] == true
    }

    pub fn control(&self, c: Control) -> Result<(), String> {
        let h = self.handle.lock().unwrap().clone().ok_or("not recording")?;
        let r = h.lock().unwrap().send(c.verb());
        r.map_err(|e| e.to_string())
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
        let res = self.start_inner(app, session, region, pick);
        self.release();
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
        let sdir = scripts::s(&session);
        let (app_ev, app_done, sdir2) = (app.clone(), app.clone(), sdir.clone());
        let handle = blurt_capture::record(&opts, move |e| on_status(&app_ev, e), move |res| finished(&app_done, &sdir2, res)).map_err(|e| {
            job.finish("failed", Some(("io", &e.to_string())));
            e.to_string()
        })?;
        *self.handle.lock().unwrap() = Some(handle);
        *self.take.lock().unwrap() = Some(Take {
            session: session.clone(),
            project,
            job,
            elapsed: 0.0,
            since: None,
            paused: false,
            shots: 0,
            note_pending: false,
        });
        island::keep_clear_of(app, region);
        crate::on_recording(app, true);
        let _ = app.emit("capture://status", json!({"ev": "started", "session": sdir}));
        Ok(sdir)
    }
}

/// One status line of the take: timing and counts for the island; the snap button's note.
fn on_status(app: &AppHandle, e: &StatusEvent) {
    let cap = &app.state::<AppState>().capture;
    let mut ask_note: Option<(PathBuf, u32, String)> = None;
    {
        let mut take = cap.take.lock().unwrap();
        if let Some(t) = take.as_mut() {
            match e {
                StatusEvent::Started { .. } | StatusEvent::Resumed { .. } => {
                    t.since = Some(Instant::now());
                    t.paused = false;
                }
                StatusEvent::Paused { .. } => {
                    t.elapsed += t.since.take().map_or(0.0, |s| s.elapsed().as_secs_f64());
                    t.paused = true;
                }
                StatusEvent::Snap { n, file, .. } => {
                    t.shots += 1;
                    if std::mem::take(&mut t.note_pending) {
                        ask_note = Some((t.session.clone(), *n, file.clone()));
                    }
                }
                _ => {}
            }
        }
    }
    match e {
        StatusEvent::Level { .. } => island::send(app, json!({"op": "status", "line": e.to_json()})),
        _ => {
            island::send(app, json!({"op": "status", "line": e.to_json()}));
            island::refresh(app);
        }
    }
    if let Some((session, n, file)) = ask_note {
        let app = app.clone();
        std::thread::spawn(move || {
            let card = Card::from_shot(&session, n, &file, None);
            let s2 = session.clone();
            let app2 = app.clone();
            let opened = overlay::note(&app, &overlay_config(), &card, Some(island_anchor(&app)), move |text| {
                if let Some(t) = text.filter(|t| !t.trim().is_empty()) {
                    append_line(&s2, &json!({"n": n, "text": t}));
                }
                let _ = app2.state::<AppState>().capture.control(Control::Resume);
            });
            if opened.is_err() {
                let _ = app.state::<AppState>().capture.control(Control::Resume);
            }
        });
    }
}

fn finished(app: &AppHandle, session: &str, res: Result<StatusEvent, blurt_capture::CaptureError>) {
    let st = app.state::<AppState>();
    *st.capture.handle.lock().unwrap() = None;
    let take = st.capture.take.lock().unwrap().take();
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
    // K7: a recording is sorted as soon as it ends, item by item into projects when it was taken in auto
    if v["ev"] == "stopped" {
        let parent = take.as_ref().map(|t| t.job.id.clone());
        let project = take.as_ref().and_then(|t| t.project.clone());
        if let Err(code) = sessions::process(app, Path::new(session), None, project, None, parent) {
            toast_error(app, if code == "no_agent" { "no_agent" } else { "unknown" });
        }
    }
    island::refresh(app);
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
            let _ = cap.control(Control::Snap);
        } else {
            snap_area(&app);
        }
    });
}

/// The island's snap button: during a recording snap + pause + note, then go on (K7); otherwise as the hotkey.
pub fn snap_with_note(app: &AppHandle) {
    let app = app.clone();
    std::thread::spawn(move || {
        let cap = &app.state::<AppState>().capture;
        if cap.recording() {
            if let Some(t) = cap.take.lock().unwrap().as_mut() {
                t.note_pending = true;
            }
            let _ = cap.control(Control::Pause);
            let _ = cap.control(Control::Snap);
        } else {
            snap_area(&app);
        }
    });
}

fn snap_area(app: &AppHandle) {
    let cap = &app.state::<AppState>().capture;
    if !cap.claim() {
        return;
    }
    let cfg = overlay_config();
    let picked = overlay::pick_region(app, &cfg, last_region(), overlay::Purpose::Screenshot);
    let region = match picked {
        Ok(Some(r)) => r,
        _ => {
            cap.release();
            return;
        }
    };
    let reg = Registry::load();
    let (project, session) = projects::shots_session(&reg);
    let runner = app.state::<AppState>().runner();
    let mut args = vec!["shot".to_string(), scripts::s(&session), "--region".into(), format!("{},{},{},{}", region.x, region.y, region.w, region.h)];
    if let Some(p) = &project {
        args.extend(["--project".into(), p.clone()]);
    }
    let job = JobWriter::new("snap", project.as_deref(), Some(&session), None, None, &["capture"]);
    job.step("capture", "running", None);
    let r = runner.run("tk_recorder.py", &args, None, Duration::from_secs(30));
    let Ok(r) = r else {
        job.finish("failed", Some(("io", "no frame")));
        cap.release();
        toast_error(app, "snap");
        return;
    };
    let n = r["n"].as_u64().unwrap_or(0);
    job.set_captures(&[n]);
    job.finish("done", None);
    let _ = app.asset_protocol_scope().allow_directory(&session, true);
    let card = Card::from_shot(&session, n as u32, r["file"].as_str().unwrap_or(""), None);
    // the note bubble (K7: a snap outside a recording asks for a word about it); then it is a capture like any other
    let (app2, s2, card2) = (app.clone(), session.clone(), card.clone());
    let opened = overlay::note(app, &cfg, &card, Some(island_anchor(app)), move |text| {
        let text = text.filter(|t| !t.trim().is_empty());
        if let Some(t) = &text {
            append_line(&s2, &json!({"n": n, "text": t}));
        }
        app2.state::<AppState>().capture.release();
        captured(&app2, &s2, project.clone(), Card { text, ..card2 });
    });
    if opened.is_err() {
        cap.release();
        captured(app, &session, Registry::load().capture_store().0, card);
    }
}

/// A snap or a voice note is on disk: into the island (project current) or onto a card (auto).
fn captured(app: &AppHandle, session: &Path, project: Option<String>, card: Card) {
    let n = u64::from(card.n);
    match project {
        Some(p) => {
            island::send(app, json!({"op": "card", "card": card, "pull": true}));
            schedule_sort(app, session, &p, n);
        }
        None => {
            island::send(app, json!({"op": "card", "card": card, "pull": false}));
            island::refresh_cards(app);
        }
    }
}

/// Captures of the current project wait COALESCE for company, then go to one process job.
fn schedule_sort(app: &AppHandle, session: &Path, project: &str, n: u64) {
    let cap = &app.state::<AppState>().capture;
    let generation = {
        let mut p = cap.pending.lock().unwrap();
        let e = p.entry(session.to_path_buf()).or_insert_with(|| (project.to_string(), vec![], 0));
        e.1.push(n);
        e.2 += 1;
        e.2
    };
    let (app, session) = (app.clone(), session.to_path_buf());
    std::thread::spawn(move || {
        std::thread::sleep(COALESCE);
        let cap = &app.state::<AppState>().capture;
        let due = {
            let mut p = cap.pending.lock().unwrap();
            match p.get(&session) {
                Some((_, _, g)) if *g == generation => p.remove(&session),
                _ => None,
            }
        };
        if let Some((project, ns, _)) = due {
            if let Err(code) = sessions::process(&app, &session, Some(ns), Some(project), None, None) {
                toast_error(&app, if code == "no_agent" { "no_agent" } else { "unknown" });
            }
            island::refresh(&app);
        }
    });
}

// ------------------------------------------------------------------ voice notes

/// The voice hotkey pressed: start (or stop a running one). `hold` = push-to-talk, ends on release.
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

/// Captures waiting under the island: in the inbox store's open shots batches, lines with no project, not deleted.
pub fn load_cards() -> Vec<Card> {
    let dir = crate::paths::inbox_store().join("sessions");
    let mut out = Vec::new();
    let mut sessions: Vec<PathBuf> = std::fs::read_dir(&dir)
        .into_iter()
        .flatten()
        .filter_map(Result::ok)
        .map(|e| e.path())
        .filter(|p| p.file_name().is_some_and(|n| n.to_string_lossy().ends_with("-shots")) && projects::is_open_batch(p))
        .collect();
    sessions.sort();
    for s in sessions {
        out.extend(cards_of(&s));
    }
    out
}

/// One batch's unfiled captures (shots.jsonl: later lines for the same n win, field by field).
pub fn cards_of(session: &Path) -> Vec<Card> {
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
        .map(|(n, m)| {
            let text = ["said", "text"].iter().find_map(|k| m.get(*k).and_then(Value::as_str).filter(|s| !s.is_empty())).map(str::to_owned);
            let voice_only = m.get("type").and_then(Value::as_str) == Some("voice");
            match (voice_only, m.get("marked").and_then(Value::as_str).or(m.get("file").and_then(Value::as_str))) {
                (false, Some(f)) => Card::from_shot(session, n as u32, f, text),
                _ => Card::voice(session, n as u32, text),
            }
        })
        .collect()
}

/// A card is thrown away (K7: `{"n", "deleted": true}`).
pub fn remove_card(session: &Path, n: u64) {
    append_line(session, &json!({"n": n, "deleted": true}));
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
    }
}
