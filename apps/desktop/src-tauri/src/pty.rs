//! The embedded terminal's other end (contract K5): pseudo-terminals through portable-pty — a Unix pty on macOS /
//! Linux, ConPTY on Windows. Output reaches the page as `pty://data` {ptyId, data: base64}, the end as `pty://exit`
//! {ptyId, code}; the page writes keystrokes with `pty_write` and reports its size with `pty_resize`.
//!
//! Two kinds:
//! * a **view** runs `sessions.py attach-cmd JOB` (a grouped tmux session of its own, so two views never fight over
//!   the current window); closing the view kills only that client — the agent keeps running in tmux.
//! * an **app-runner session** (no tmux: Windows, or tmux missing) runs the agent itself. It belongs to the app, not to
//!   a view: output is kept (the last 1 MB) so a view opened later replays it, and when the agent exits we tell
//!   sessions.py (`event --event pane-dead --exit N`), which moves the job and its items on (K3) — unless the user
//!   stopped it (Interrupt / End Session: `sessions.py stop` says so instead). What it left on screen stays readable
//!   until the app quits (Show Output, as the Mac's AppRunner keeps its view).
//!   Its screen is also drawn here (a vt100 parser) and its bottom lines go to `$BLURT_HOME/run/screens/<job>.json`
//!   with the time of its last output: the monitor (`sessions.py`) reads them as it reads a tmux pane on the Mac —
//!   a question it waits on (trust, a notice), an error it shows (not logged in), a screen still for a minute.
//!
//! [`Ptys`] is the window-less core (tests drive it directly); the functions below wire it to Tauri events.

use std::collections::HashMap;
use std::io::{Read, Write};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
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
    owned: bool,
    master: Mutex<Box<dyn MasterPty + Send>>,
    writer: Mutex<Box<dyn Write + Send>>,
    killer: Mutex<Box<dyn ChildKiller + Send + Sync>>,
    ring: Mutex<Vec<u8>>,
    /// the user stopped it (Interrupt / End Session): its exit isn't reported as the agent's own
    user_stop: AtomicBool,
    /// an app-runner session's screen, as a terminal draws it (ScreenWatch)
    screen: Option<Mutex<vt100::Parser>>,
    /// when it last printed anything (epoch seconds)
    activity: Mutex<f64>,
    exited: AtomicBool,
}

fn epoch() -> f64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or(0.0)
}

/// Where an app-runner job's screen goes for sessions.py (outside `jobs/`, which the app watches for job changes).
pub fn screen_file(job: &str) -> PathBuf {
    crate::paths::blurt_home().join("run").join("screens").join(format!("{job}.json"))
}

/// The screen's non-empty rows, top to bottom (what `tmux capture-pane` gives sessions.py, minus the blank ones).
pub fn screen_lines(p: &vt100::Parser) -> Vec<String> {
    let s = p.screen();
    let (_, cols) = s.size();
    s.rows(0, cols).map(|r| r.trim_end().to_string()).filter(|r| !r.trim().is_empty()).collect()
}

/// ScreenWatch: while the agent runs, its bottom lines and last-output time, rewritten when they change (≤ 1 a
/// second); removed once it has exited.
fn watch_screen(pty: Arc<Pty>, job: String) {
    let file = screen_file(&job);
    if let Some(d) = file.parent() {
        let _ = std::fs::create_dir_all(d);
    }
    let mut last: Option<(Vec<String>, f64)> = None;
    while !pty.exited.load(Ordering::SeqCst) {
        std::thread::sleep(Duration::from_millis(700));
        let Some(sc) = &pty.screen else { break };
        let lines = screen_lines(&sc.lock().unwrap());
        let act = *pty.activity.lock().unwrap();
        let now = (lines, act);
        if last.as_ref() == Some(&now) {
            continue;
        }
        let tail: Vec<&String> = now.0.iter().rev().take(40).rev().collect();
        let body = json!({"job": job, "activity": now.1, "lines": tail}).to_string();
        let tmp = file.with_extension("json.tmp");
        // a reader holding the file open (Windows) fails the rename: try again on the next tick
        if std::fs::write(&tmp, body).is_ok() && std::fs::rename(&tmp, &file).is_ok() {
            last = Some(now);
        }
    }
    let _ = std::fs::remove_file(&file);
    let _ = std::fs::remove_file(file.with_extension("json.tmp"));
}

#[derive(Default)]
struct Inner {
    next: AtomicU32,
    open: Mutex<HashMap<u32, Arc<Pty>>>,
    /// job → its app-runner pty (until its exit has been reported)
    owned: Mutex<HashMap<String, u32>>,
    /// job → what an app-runner session that ended left on screen (Show Output)
    ended: Mutex<HashMap<String, Vec<u8>>>,
}

/// What to run in a new pty. `env` comes on top of the app's agent environment.
pub struct Spawn {
    pub argv: Vec<String>,
    pub env: serde_json::Map<String, Value>,
    pub cwd: Option<PathBuf>,
    pub job: Option<String>,
    /// an app-runner session (kept, replayed) rather than a view
    pub owned: bool,
    pub cols: u16,
    pub rows: u16,
}

pub type OnData = Arc<dyn Fn(u32, &[u8]) + Send + Sync>;
/// (pty id, the app-runner job it ran — None for views, exit code, the user stopped it)
pub type OnExit = Arc<dyn Fn(u32, Option<String>, i64, bool) + Send + Sync>;

#[derive(Default, Clone)]
pub struct Ptys(Arc<Inner>);

impl Ptys {
    pub fn spawn(&self, s: Spawn, on_data: OnData, on_exit: OnExit) -> Result<u32, String> {
        let first = s.argv.first().ok_or("empty command")?;
        let pair = native_pty_system()
            .openpty(PtySize { rows: s.rows.max(2), cols: s.cols.max(10), pixel_width: 0, pixel_height: 0 })
            .map_err(|e| format!("pty: {e}"))?;
        let mut cmd = CommandBuilder::new(first);
        cmd.args(&s.argv[1..]);
        for (k, v) in scripts::agent_environment() {
            cmd.env(k, v);
        }
        cmd.env("TERM", "xterm-256color");
        cmd.env("COLORTERM", "truecolor");
        for (k, v) in &s.env {
            if let Some(v) = v.as_str() {
                cmd.env(k, v);
            }
        }
        if let Some(d) = s.cwd.filter(|d| d.is_dir()) {
            cmd.cwd(d);
        }
        let mut child = pair.slave.spawn_command(cmd).map_err(|e| format!("couldn't start {first}: {e}"))?;
        drop(pair.slave);
        let mut reader = pair.master.try_clone_reader().map_err(|e| e.to_string())?;
        let writer = pair.master.take_writer().map_err(|e| e.to_string())?;
        let id = self.0.next.fetch_add(1, Ordering::SeqCst) + 1;
        let pty = Arc::new(Pty {
            owned: s.owned,
            master: Mutex::new(pair.master),
            writer: Mutex::new(writer),
            killer: Mutex::new(child.clone_killer()),
            ring: Mutex::new(Vec::new()),
            user_stop: AtomicBool::new(false),
            screen: (s.owned && s.job.is_some()).then(|| Mutex::new(vt100::Parser::new(s.rows.max(2), s.cols.max(10), 0))),
            activity: Mutex::new(epoch()),
            exited: AtomicBool::new(false),
        });
        self.0.open.lock().unwrap().insert(id, pty.clone());
        if let (true, Some(j)) = (s.owned, &s.job) {
            self.0.owned.lock().unwrap().insert(j.clone(), id);
        }
        let held = pty.clone();
        let reading = std::thread::spawn(move || {
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
                        if let Some(sc) = &pty.screen {
                            sc.lock().unwrap().process(&buf[..n]);
                            *pty.activity.lock().unwrap() = epoch();
                        }
                        on_data(id, &buf[..n]);
                    }
                }
            }
        });
        let inner = self.0.clone();
        let job = s.job.filter(|_| s.owned);
        if let (Some(j), true) = (&job, held.screen.is_some()) {
            let (p, j) = (held.clone(), j.clone());
            std::thread::spawn(move || watch_screen(p, j));
        }
        std::thread::spawn(move || {
            let code = child.wait().map(|s| s.exit_code() as i64).unwrap_or(-1);
            // the last output first (a Windows ConPTY reader may outlive the child: don't wait for it forever)
            for _ in 0..40 {
                if reading.is_finished() {
                    break;
                }
                std::thread::sleep(Duration::from_millis(25));
            }
            inner.open.lock().unwrap().remove(&id);
            held.exited.store(true, Ordering::SeqCst);
            if let Some(j) = &job {
                inner.ended.lock().unwrap().insert(j.clone(), held.ring.lock().unwrap().clone());
            }
            // still "running" for stop() until its exit is reported: the user's stop is said after the agent's own
            on_exit(id, job.clone(), code, held.user_stop.load(Ordering::SeqCst));
            if let Some(j) = &job {
                inner.owned.lock().unwrap().remove(j);
            }
        });
        Ok(id)
    }

    pub fn write(&self, id: u32, data: &[u8]) -> Result<(), String> {
        let p = self.0.open.lock().unwrap().get(&id).cloned().ok_or("terminal closed")?;
        let mut w = p.writer.lock().unwrap();
        w.write_all(data).and_then(|_| w.flush()).map_err(|e| e.to_string())
    }

    pub fn resize(&self, id: u32, cols: u16, rows: u16) -> Result<(), String> {
        let p = self.0.open.lock().unwrap().get(&id).cloned().ok_or("terminal closed")?;
        let size = PtySize { rows: rows.max(2), cols: cols.max(10), pixel_width: 0, pixel_height: 0 };
        let r = p.master.lock().unwrap().resize(size).map_err(|e| e.to_string());
        if let Some(sc) = &p.screen {
            sc.lock().unwrap().screen_mut().set_size(rows.max(2), cols.max(10));
        }
        r
    }

    /// A view goes away: a tmux client is ended (the session lives on); an app-runner pty is left running.
    pub fn close(&self, id: u32) {
        let p = self.0.open.lock().unwrap().get(&id).cloned();
        if let Some(p) = p.filter(|p| !p.owned) {
            let _ = p.killer.lock().unwrap().kill();
        }
    }

    /// The app-runner pty of a job and its output so far (Some(id)), or what it left on screen once it ended (None).
    pub fn owned_replay(&self, job: &str) -> Option<(Option<u32>, Vec<u8>)> {
        if let Some(p) = self.owned_pty(job) {
            let id = self.0.owned.lock().unwrap().get(job).copied();
            let r = p.ring.lock().unwrap().clone();
            return Some((id, r));
        }
        self.0.ended.lock().unwrap().get(job).map(|r| (None, r.clone()))
    }

    fn owned_pty(&self, job: &str) -> Option<Arc<Pty>> {
        let id = self.0.owned.lock().unwrap().get(job).copied()?;
        self.0.open.lock().unwrap().get(&id).cloned()
    }

    /// An app-runner job whose agent hasn't exited (or whose exit isn't reported yet).
    pub fn running(&self, job: &str) -> bool {
        self.0.owned.lock().unwrap().contains_key(job)
    }

    /// Control-C into the agent's terminal, as the user stopping it.
    pub fn interrupt_job(&self, job: &str) -> bool {
        let Some(p) = self.owned_pty(job) else { return false };
        p.user_stop.store(true, Ordering::SeqCst);
        let mut w = p.writer.lock().unwrap();
        w.write_all(b"\x03").and_then(|_| w.flush()).is_ok()
    }

    pub fn kill_job(&self, job: &str) -> bool {
        let p = self.owned_pty(job);
        p.is_some_and(|p| {
            p.user_stop.store(true, Ordering::SeqCst);
            p.killer.lock().unwrap().kill().is_ok()
        })
    }

    pub fn owned_jobs(&self) -> Vec<String> {
        self.0.owned.lock().unwrap().keys().cloned().collect()
    }

    pub fn kill_all(&self) {
        let all: Vec<Arc<Pty>> = self.0.open.lock().unwrap().values().cloned().collect();
        for p in all {
            let _ = p.killer.lock().unwrap().kill();
        }
    }
}

fn b64(data: &[u8]) -> String {
    base64::engine::general_purpose::STANDARD.encode(data)
}

// ------------------------------------------------------------------ Tauri glue

/// Start `argv` in a new pty whose output goes to the pages; an app-runner job's exit is reported to sessions.py.
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
    let a1 = app.clone();
    let on_data: OnData = Arc::new(move |id, data| {
        let _ = a1.emit("pty://data", json!({"ptyId": id, "data": b64(data)}));
    });
    let a2 = app.clone();
    let on_exit: OnExit = Arc::new(move |id, job, code, user| {
        // stopped by the user: `sessions.py stop` marks it (cancelled), not as the agent's own exit
        if let Some(j) = job.filter(|_| !user) {
            let runner = a2.state::<AppState>().runner();
            let args = vec!["event".into(), "--job".into(), j, "--event".into(), "pane-dead".into(), "--exit".into(), code.to_string()];
            if let Err(e) = runner.run("sessions.py", &args, None, Duration::from_secs(20)) {
                eprintln!("blurt: sessions.py event: {e}");
            }
        }
        let _ = a2.emit("pty://exit", json!({"ptyId": id, "code": code}));
    });
    let s = Spawn { argv: argv.to_vec(), env: env.clone(), cwd, job, owned, cols, rows };
    app.state::<Ptys>().spawn(s, on_data, on_exit)
}

/// A terminal view on an agent job: the app-runner pty when the app runs it (→ its output so far, to replay; once it
/// ended, only that: ptyId null, ended true), else a tmux client from `sessions.py attach-cmd`.
/// → {ptyId, replay: base64 | null, owned, ended}
pub fn open(app: &AppHandle, runner: &Runner, job: &str, cols: u16, rows: u16) -> Result<Value, String> {
    let ptys = app.state::<Ptys>();
    if let Some((id, replay)) = ptys.owned_replay(job) {
        if let Some(id) = id {
            let _ = ptys.resize(id, cols, rows);
        }
        return Ok(json!({"ptyId": id, "replay": b64(&replay), "owned": true, "ended": id.is_none()}));
    }
    let r = runner.run("sessions.py", &["attach-cmd".into(), job.into()], None, Duration::from_secs(20)).map_err(String::from)?;
    let argv: Vec<String> = r["argv"].as_array().into_iter().flatten().filter_map(|v| v.as_str().map(str::to_owned)).collect();
    let env = r.get("env").and_then(Value::as_object).cloned().unwrap_or_default();
    let id = spawn(app, &argv, &env, None, Some(job.to_string()), false, cols, rows)?;
    Ok(json!({"ptyId": id, "replay": null, "owned": false, "ended": false}))
}

pub fn write(app: &AppHandle, id: u32, data: &str) -> Result<(), String> {
    app.state::<Ptys>().write(id, data.as_bytes())
}

pub fn resize(app: &AppHandle, id: u32, cols: u16, rows: u16) -> Result<(), String> {
    app.state::<Ptys>().resize(id, cols, rows)
}

pub fn close(app: &AppHandle, id: u32) {
    app.state::<Ptys>().close(id);
}

/// App runner: end the agent's process (End Session after Control-C wasn't enough).
pub fn kill_job(app: &AppHandle, job: &str) -> bool {
    app.state::<Ptys>().kill_job(job)
}

/// App runner: Control-C, as `sessions.py stop` sends it into a tmux window.
pub fn interrupt_job(app: &AppHandle, job: &str) -> bool {
    app.state::<Ptys>().interrupt_job(job)
}

/// App runner: the agent is still up (its exit not reported yet).
pub fn running(app: &AppHandle, job: &str) -> bool {
    app.state::<Ptys>().running(job)
}

/// Jobs the app runs itself (their sessions end when Blurt quits; the UI says so).
pub fn owned_jobs(app: &AppHandle) -> Vec<String> {
    app.state::<Ptys>().owned_jobs()
}

/// Quit: end every pty (tmux views detach; app-runner agents end, as the UI warned).
pub fn kill_all(app: &AppHandle) {
    app.state::<Ptys>().kill_all();
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::sync::mpsc;

    #[test]
    fn echo_round_trip_and_exit() {
        let ptys = Ptys::default();
        let (tx, rx) = mpsc::channel::<Vec<u8>>();
        let (etx, erx) = mpsc::channel::<(Option<String>, i64, bool)>();
        let s = Spawn { argv: vec!["/bin/cat".into()], env: Default::default(), cwd: None, job: Some("j-1".into()), owned: true, cols: 80, rows: 24 };
        let id = ptys
            .spawn(s, Arc::new(move |_, d| { let _ = tx.send(d.to_vec()); }), Arc::new(move |_, j, c, u| { let _ = etx.send((j, c, u)); }))
            .unwrap();
        ptys.resize(id, 120, 40).unwrap();
        ptys.write(id, "héllo blurt\r".as_bytes()).unwrap();
        let mut got = Vec::new();
        while !String::from_utf8_lossy(&got).contains("héllo blurt") {
            got.extend(rx.recv_timeout(Duration::from_secs(5)).expect("echo"));
        }
        assert_eq!(ptys.owned_jobs(), ["j-1"]);
        assert!(String::from_utf8_lossy(&ptys.owned_replay("j-1").unwrap().1).contains("héllo"));
        assert!(ptys.running("j-1"));
        assert!(ptys.kill_job("j-1"));
        let (job, _code, user) = erx.recv_timeout(Duration::from_secs(5)).expect("exit");
        assert_eq!(job.as_deref(), Some("j-1"));
        assert!(user, "the user's stop is said as such");
        for _ in 0..100 {
            if !ptys.running("j-1") {
                break;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        assert!(ptys.owned_jobs().is_empty());
        // what it left on screen stays readable (Show Output)
        let (id, out) = ptys.owned_replay("j-1").expect("ended output");
        assert!(id.is_none() && String::from_utf8_lossy(&out).contains("héllo"));
    }

    #[test]
    fn screen_lines_are_what_is_drawn() {
        let mut p = vt100::Parser::new(6, 40, 0);
        // a redraw in place (as Ink does): the old question is gone, the new one is what a reader sees
        p.process(b"Welcome\r\nDo you trust the files in this folder?\r\n\x1b[1A\x1b[2K\rEnter to continue \xc2\xb7 Esc to cancel\r\n\r\n");
        assert_eq!(screen_lines(&p), ["Welcome", "Enter to continue · Esc to cancel"]);
        p.screen_mut().set_size(4, 20);
        assert_eq!(screen_lines(&p)[0], "Welcome");
    }
}
