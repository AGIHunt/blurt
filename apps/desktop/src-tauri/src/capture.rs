//! Recording (C8) through WP8's `blurt_capture`: the region picker, then `overlay::record` — `record.py start
//! --engine ffmpeg --status-jsonl` with its HUD, snaps hung on the perch. Everything here runs off the main thread
//! (blurt_capture: the picker blocks, and creating windows from the main thread deadlocks on Windows).
//!
//! The main window hears `capture://status` {ev: "started" | "stopped" | "discarded" | "error" | "picking", …}.

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use blurt_capture::overlay::{self, OverlayConfig, Perch};
use blurt_capture::{CaptureHandle, CaptureOptions, CaptureState, Launcher, Mic, Region, StatusEvent};
use serde_json::{json, Value};
use tauri::{AppHandle, Emitter, Manager, Wry};

use crate::{paths, scripts, settings, AppState};

#[derive(Default)]
pub struct Capture {
    handle: Mutex<Option<Arc<Mutex<CaptureHandle>>>>,
    session: Mutex<Option<String>>,
    perch: Mutex<Option<Arc<Perch<Wry>>>>,
    /// a picker is open: a second "record" press must not open another
    busy: Mutex<bool>,
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

fn overlay_config() -> OverlayConfig {
    OverlayConfig {
        lang: Some(if crate::zh() { "zh" } else { "en" }.into()),
        platform: Some(if cfg!(windows) { "win" } else { "gnome" }.into()),
        ..Default::default()
    }
}

fn timestamp() -> String {
    let id = crate::agents::new_run_id(); // r-YYYYMMDD-HHMMSS-xxxx
    id[2..17].to_string()
}

/// `record.workspace` (the project picked in the toolbar) when set, else the default workspace's recordings.
pub fn default_session_dir() -> PathBuf {
    let cfg = settings::read_config();
    let ws = cfg
        .pointer("/record/workspace")
        .and_then(Value::as_str)
        .map(PathBuf::from)
        .filter(|p| p.is_dir())
        .unwrap_or_else(paths::default_workspace);
    paths::sessions_root(&ws).join(timestamp())
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

impl Capture {
    pub fn state(&self) -> Value {
        let h = self.handle.lock().unwrap().clone();
        let st = h.as_ref().map(|h| h.lock().unwrap().state());
        json!({
            "recording": matches!(st, Some(CaptureState::Starting | CaptureState::Recording | CaptureState::Paused)),
            "paused": st == Some(CaptureState::Paused),
            "picking": *self.busy.lock().unwrap(),
            "session": *self.session.lock().unwrap(),
            "engine": "blurt-capture (record.py ffmpeg)",
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

    fn perch(&self, app: &AppHandle, cfg: &OverlayConfig) -> Option<Arc<Perch<Wry>>> {
        let mut p = self.perch.lock().unwrap();
        if p.is_none() {
            match overlay::perch(app, cfg) {
                Ok(perch) => {
                    let app2 = app.clone();
                    perch.on_action(move |action, n| {
                        let _ = app2.emit("perch://action", json!({"action": action, "n": n}));
                        if action == "process" || action == "open" {
                            crate::show_main(&app2);
                        }
                    });
                    *p = Some(perch);
                }
                Err(e) => eprintln!("blurt: no perch window: {e}"),
            }
        }
        p.clone()
    }

    /// Picker → record (blocks until the take has started or failed). Call from a worker thread.
    pub fn start(&self, app: &AppHandle, session: Option<PathBuf>, region: Option<Region>, pick: bool) -> Result<String, String> {
        if self.recording() {
            return Err("already recording".into());
        }
        {
            let mut b = self.busy.lock().unwrap();
            if *b {
                return Err("already choosing an area".into());
            }
            *b = true;
        }
        let res = self.start_inner(app, session, region, pick);
        *self.busy.lock().unwrap() = false;
        res
    }

    fn start_inner(&self, app: &AppHandle, session: Option<PathBuf>, region: Option<Region>, pick: bool) -> Result<String, String> {
        let runner = app.state::<AppState>().runner();
        let record_py = runner.scripts.as_ref().map(|d| d.join("record.py")).filter(|p| p.is_file()).ok_or("record.py not found")?;
        let launcher = match &runner.uv {
            Some(uv) => Launcher::uv(uv, &record_py),
            None => Launcher::detect(&record_py).ok_or("neither uv nor python found")?,
        };
        let cfg = overlay_config();
        let region = if pick && region.is_none() {
            let _ = app.emit("capture://status", json!({"ev": "picking"}));
            match overlay::pick_region(app, &cfg, last_region()).map_err(|e| e.to_string())? {
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
        let session = session.unwrap_or_else(default_session_dir);
        std::fs::create_dir_all(&session).map_err(|e| format!("{}: {e}", session.display()))?;
        if let Some(root) = session.parent() {
            let _ = app.asset_protocol_scope().allow_directory(root, true);
        }
        let mut opts = CaptureOptions::new(launcher, &session);
        opts.region = region;
        opts.mic = mic_from_config();
        opts.env = scripts::agent_environment().iter().map(|(k, v)| (k.into(), v.into())).collect();
        let perch = self.perch(app, &cfg);
        let sdir = scripts::s(&session);
        let (app2, sdir2) = (app.clone(), sdir.clone());
        let handle = overlay::record(app, &cfg, opts, perch, move |res| finished(&app2, &sdir2, res)).map_err(|e| e.to_string())?;
        *self.handle.lock().unwrap() = Some(handle);
        *self.session.lock().unwrap() = Some(sdir.clone());
        crate::on_recording(app, true);
        let _ = app.emit("capture://status", json!({"ev": "started", "session": sdir}));
        Ok(sdir)
    }
}

fn finished(app: &AppHandle, session: &str, res: Result<StatusEvent, blurt_capture::CaptureError>) {
    let st = app.state::<AppState>();
    *st.capture.handle.lock().unwrap() = None;
    *st.capture.session.lock().unwrap() = None;
    crate::on_recording(app, false);
    let mut v = match &res {
        Ok(e) => e.to_json(),
        Err(e) => json!({"ev": "error", "msg": e.to_string()}),
    };
    v["session"] = json!(session);
    let _ = app.emit("capture://status", &v);
    match v["ev"].as_str() {
        Some("stopped") => crate::notify(app, "Blurt", if crate::zh() { "录制已保存，在收件箱里" } else { "Recording saved to the inbox" }),
        Some("error") => crate::notify(app, "Blurt", v["msg"].as_str().unwrap_or("recording failed")),
        _ => {}
    }
    crate::watcher::update(app, &[Path::new(session).to_path_buf()]);
}

/// Toggle used by the tray, the record hotkey and blurt://record (spawns: never blocks the caller).
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
                let _ = app.emit("capture://status", json!({"ev": "error", "msg": e}));
            }
        }
    });
}

/// Wait for a take to end (tests / quit).
pub fn stop_and_wait(app: &AppHandle, timeout: Duration) {
    let st = app.state::<AppState>();
    let h = st.capture.handle.lock().unwrap().clone();
    if let Some(h) = h {
        let _ = h.lock().unwrap().stop_and_wait(timeout);
    }
}
