//! The embedded terminal's other end (contract K5): pseudo-terminals through portable-pty — a Unix pty on macOS /
//! Linux, ConPTY on Windows. Output reaches the page as `pty://data` {ptyId, data: base64}, the end as `pty://exit`
//! {ptyId, code}; the page writes keystrokes with `pty_write` and reports its size with `pty_resize`.
//!
//! Two kinds:
//! * a **view** runs `sessions.py attach-cmd JOB` (a grouped tmux session of its own, so two views never fight over
//!   the current window); closing the view kills only that client — the agent keeps running in tmux.
//! * an **app-runner session** (no tmux: Windows, or tmux missing) runs the agent itself. It belongs to the app, not to
//!   a view: output is kept (the last 1 MB) so a view opened later replays it, and when the agent exits we tell
//!   sessions.py (`event --event pane-dead --exit N`), which moves the job and its items on (K3).

use std::collections::HashMap;
use std::io::{Read, Write};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use base64::Engine as _;
use portable_pty::{native_pty_system, ChildKiller, CommandBuilder, MasterPty, PtySize};
use serde_json::{json, Value};
use tauri::{AppHandle, Emitter, Manager};

use crate::scripts::{self, Runner};
use crate::AppState;

const RING: usize = 1 << 20;

struct Pty {
    job: Option<String>,
    owned: bool,
    master: Mutex<Box<dyn MasterPty + Send>>,
    writer: Mutex<Box<dyn Write + Send>>,
    killer: Mutex<Box<dyn ChildKiller + Send + Sync>>,
    ring: Mutex<Vec<u8>>,
}

#[derive(Default)]
pub struct Ptys {
    next: AtomicU32,
    open: Mutex<HashMap<u32, Arc<Pty>>>,
    /// job → its app-runner pty
    owned: Mutex<HashMap<String, u32>>,
}

fn b64(data: &[u8]) -> String {
    base64::engine::general_purpose::STANDARD.encode(data)
}

/// Start `argv` in a new pty. `env` comes on top of the app's agent environment.
#[allow(clippy::too_many_arguments)]
pub fn spawn(
    app: &AppHandle,
    argv: &[String],
    env: &serde_json::Map<String, Value>,
    cwd: Option<PathBuf>,
    job: Option<String>,
    owned: bool,
    cols: u16,
    rows: u16,
) -> Result<u32, String> {
    let first = argv.first().ok_or("empty command")?;
    let pair = native_pty_system()
        .openpty(PtySize { rows: rows.max(2), cols: cols.max(10), pixel_width: 0, pixel_height: 0 })
        .map_err(|e| format!("pty: {e}"))?;
    let mut cmd = CommandBuilder::new(first);
    cmd.args(&argv[1..]);
    for (k, v) in scripts::agent_environment() {
        cmd.env(k, v);
    }
    cmd.env("TERM", "xterm-256color");
    cmd.env("COLORTERM", "truecolor");
    for (k, v) in env {
        if let Some(v) = v.as_str() {
            cmd.env(k, v);
        }
    }
    if let Some(d) = cwd.filter(|d| d.is_dir()) {
        cmd.cwd(d);
    }
    let mut child = pair.slave.spawn_command(cmd).map_err(|e| format!("couldn't start {first}: {e}"))?;
    drop(pair.slave);
    let mut reader = pair.master.try_clone_reader().map_err(|e| e.to_string())?;
    let writer = pair.master.take_writer().map_err(|e| e.to_string())?;
    let id = app.state::<Ptys>().next.fetch_add(1, Ordering::SeqCst) + 1;
    let pty = Arc::new(Pty {
        job: job.clone(),
        owned,
        master: Mutex::new(pair.master),
        writer: Mutex::new(writer),
        killer: Mutex::new(child.clone_killer()),
        ring: Mutex::new(Vec::new()),
    });
    let ptys = app.state::<Ptys>();
    ptys.open.lock().unwrap().insert(id, pty.clone());
    if let (true, Some(j)) = (owned, &job) {
        ptys.owned.lock().unwrap().insert(j.clone(), id);
    }
    // output
    {
        let (app, pty) = (app.clone(), pty.clone());
        std::thread::spawn(move || {
            let mut buf = vec![0u8; 16 * 1024];
            loop {
                match reader.read(&mut buf) {
                    Ok(0) | Err(_) => break,
                    Ok(n) => {
                        if pty.owned {
                            let mut r = pty.ring.lock().unwrap();
                            r.extend_from_slice(&buf[..n]);
                            if r.len() > RING {
                                let cut = r.len() - RING;
                                r.drain(..cut);
                            }
                        }
                        let _ = app.emit("pty://data", json!({"ptyId": id, "data": b64(&buf[..n])}));
                    }
                }
            }
        });
    }
    // exit
    {
        let app = app.clone();
        std::thread::spawn(move || {
            let code = child.wait().map(|s| s.exit_code() as i64).unwrap_or(-1);
            std::thread::sleep(Duration::from_millis(50)); // let the last output out first
            let ptys = app.state::<Ptys>();
            let pty = ptys.open.lock().unwrap().remove(&id);
            if let Some(p) = pty {
                if let (true, Some(j)) = (p.owned, &p.job) {
                    ptys.owned.lock().unwrap().remove(j);
                    let runner = app.state::<AppState>().runner();
                    let args = vec!["event".into(), "--job".into(), j.clone(), "--event".into(), "pane-dead".into(), "--exit".into(), code.to_string()];
                    if let Err(e) = runner.run("sessions.py", &args, None, Duration::from_secs(20)) {
                        eprintln!("blurt: sessions.py event: {e}");
                    }
                }
            }
            let _ = app.emit("pty://exit", json!({"ptyId": id, "code": code}));
        });
    }
    Ok(id)
}

/// A terminal view on an agent job: the app-runner pty when the app runs it (→ its output so far, to replay), else
/// a tmux client from `sessions.py attach-cmd`. → {ptyId, replay: base64 | null, owned}
pub fn open(app: &AppHandle, runner: &Runner, job: &str, cols: u16, rows: u16) -> Result<Value, String> {
    let ptys = app.state::<Ptys>();
    let owned = ptys.owned.lock().unwrap().get(job).copied();
    if let Some(id) = owned {
        let replay = ptys.open.lock().unwrap().get(&id).map(|p| b64(&p.ring.lock().unwrap()));
        let _ = resize(app, id, cols, rows);
        return Ok(json!({"ptyId": id, "replay": replay, "owned": true}));
    }
    let r = runner.run("sessions.py", &["attach-cmd".into(), job.into()], None, Duration::from_secs(20)).map_err(String::from)?;
    let argv: Vec<String> = r["argv"].as_array().into_iter().flatten().filter_map(|v| v.as_str().map(str::to_owned)).collect();
    let env = r.get("env").and_then(Value::as_object).cloned().unwrap_or_default();
    let id = spawn(app, &argv, &env, None, Some(job.to_string()), false, cols, rows)?;
    Ok(json!({"ptyId": id, "replay": null, "owned": false}))
}

pub fn write(app: &AppHandle, id: u32, data: &str) -> Result<(), String> {
    let p = app.state::<Ptys>().open.lock().unwrap().get(&id).cloned().ok_or("terminal closed")?;
    let mut w = p.writer.lock().unwrap();
    w.write_all(data.as_bytes()).and_then(|_| w.flush()).map_err(|e| e.to_string())
}

pub fn resize(app: &AppHandle, id: u32, cols: u16, rows: u16) -> Result<(), String> {
    let p = app.state::<Ptys>().open.lock().unwrap().get(&id).cloned().ok_or("terminal closed")?;
    let size = PtySize { rows: rows.max(2), cols: cols.max(10), pixel_width: 0, pixel_height: 0 };
    let r = p.master.lock().unwrap().resize(size).map_err(|e| e.to_string());
    r
}

/// A view goes away: a tmux client is ended (the session lives on); an app-runner pty is left running.
pub fn close(app: &AppHandle, id: u32) {
    let p = app.state::<Ptys>().open.lock().unwrap().get(&id).cloned();
    if let Some(p) = p.filter(|p| !p.owned) {
        let _ = p.killer.lock().unwrap().kill();
    }
}

/// App runner: stop the agent (K5 `sessions.py stop` does the same for tmux windows).
pub fn kill_job(app: &AppHandle, job: &str) -> bool {
    let ptys = app.state::<Ptys>();
    let id = ptys.owned.lock().unwrap().get(job).copied();
    let p = id.and_then(|id| ptys.open.lock().unwrap().get(&id).cloned());
    p.is_some_and(|p| p.killer.lock().unwrap().kill().is_ok())
}

/// Jobs the app runs itself (their sessions end when Blurt quits; the UI says so).
pub fn owned_jobs(app: &AppHandle) -> Vec<String> {
    app.state::<Ptys>().owned.lock().unwrap().keys().cloned().collect()
}

/// Quit: end every pty (tmux views detach; app-runner agents end, as the UI warned).
pub fn kill_all(app: &AppHandle) {
    let all: Vec<Arc<Pty>> = app.state::<Ptys>().open.lock().unwrap().values().cloned().collect();
    for p in all {
        let _ = p.killer.lock().unwrap().kill();
    }
}
