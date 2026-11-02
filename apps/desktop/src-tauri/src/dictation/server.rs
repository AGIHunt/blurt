//! The warm model servers (BlurtCore WarmServer / the Mac's WarmSpawn): `transcribe.py serve` and `polish.py serve`
//! write `$BLURT_HOME/run/<name>.json` ({pid, port, token, parent, started}); one JSON line in, one JSON line out over
//! 127.0.0.1. Talking to them directly skips a `uv run` per request, which is most of what a dictation waits for.
//!
//! They are started offline-first (`BLURT_NO_DOWNLOAD=1`, `UV_OFFLINE=1`; one online retry when uv lacks a package),
//! with `--parent <our pid>` so they end with Blurt, and end by themselves after 10 idle minutes.
//!
//! A server that stopped answering (the Mac's WarmServer.health / DictationASRFailure.hung): at key-down `ensure` pings
//! it and looks at its CPU time — no answer and no CPU while the ping waited is stuck, and it is ended and started
//! again; no answer but CPU moving is a model loading or a long decode, left alone. A request in flight is given up on
//! once it has waited 3 s while the server's CPU stood still for 2 s (`call`); the server is then ended too.

use std::io::{BufRead, BufReader, Write};
use std::net::{SocketAddr, TcpStream};
use std::path::PathBuf;
use std::process::Stdio;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use serde_json::{json, Value};

use crate::paths;
use crate::scripts::{self, Runner};

pub const ASR: &str = "asr-serve";
pub const POLISH: &str = "polish-serve";

fn info_path(name: &str) -> PathBuf {
    paths::blurt_home().join("run").join(format!("{name}.json"))
}

pub struct Record {
    pub pid: Option<u32>,
    pub parent: Option<u32>,
    pub port: u16,
    pub token: String,
}

pub fn record(name: &str) -> Option<Record> {
    let v: Value = serde_json::from_str(&std::fs::read_to_string(info_path(name)).ok()?).ok()?;
    let port = v.get("port")?.as_u64().filter(|p| *p > 0 && *p < 65536)? as u16;
    Some(Record {
        pid: v.get("pid").and_then(Value::as_u64).map(|p| p as u32),
        parent: v.get("parent").and_then(Value::as_u64).map(|p| p as u32),
        port,
        token: v
            .get("token")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string(),
    })
}

#[cfg(windows)]
fn alive(pid: u32) -> bool {
    use windows::Win32::Foundation::{CloseHandle, STILL_ACTIVE};
    use windows::Win32::System::Threading::{
        GetExitCodeProcess, OpenProcess, PROCESS_QUERY_LIMITED_INFORMATION,
    };
    unsafe {
        let Ok(h) = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid) else {
            return false;
        };
        let mut code = 0u32;
        let ok = GetExitCodeProcess(h, &mut code).is_ok();
        let _ = CloseHandle(h);
        ok && code == STILL_ACTIVE.0 as u32
    }
}

#[cfg(not(windows))]
fn alive(pid: u32) -> bool {
    std::path::Path::new(&format!("/proc/{pid}")).exists()
}

/// CPU seconds the process has used (kernel + user); None when it can't be read.
#[cfg(windows)]
fn cpu_seconds(pid: u32) -> Option<f64> {
    use windows::Win32::Foundation::{CloseHandle, FILETIME};
    use windows::Win32::System::Threading::{
        GetProcessTimes, OpenProcess, PROCESS_QUERY_LIMITED_INFORMATION,
    };
    unsafe {
        let h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid).ok()?;
        let (mut c, mut e, mut k, mut u) = (
            FILETIME::default(),
            FILETIME::default(),
            FILETIME::default(),
            FILETIME::default(),
        );
        let ok = GetProcessTimes(h, &mut c, &mut e, &mut k, &mut u).is_ok();
        let _ = CloseHandle(h);
        let t = |f: FILETIME| ((u64::from(f.dwHighDateTime) << 32) | u64::from(f.dwLowDateTime)) as f64 / 1e7;
        ok.then(|| t(k) + t(u))
    }
}

#[cfg(not(windows))]
fn cpu_seconds(pid: u32) -> Option<f64> {
    // /proc/<pid>/stat: utime and stime are fields 14 and 15, after the parenthesised name
    let s = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    let rest = s.rsplit_once(')')?.1;
    let f: Vec<&str> = rest.split_whitespace().collect();
    let ticks = f.get(11)?.parse::<f64>().ok()? + f.get(12)?.parse::<f64>().ok()?;
    Some(ticks / 100.0)
}

/// The process runs Python (a server is `uv run` → python): a pid reused by anything else isn't ours to end. Reading
/// another process's command line takes its PEB on Windows; its image is enough to tell. None: can't be read.
#[cfg(windows)]
fn is_python(pid: u32) -> Option<bool> {
    use windows::Win32::Foundation::CloseHandle;
    use windows::Win32::System::Threading::{
        OpenProcess, QueryFullProcessImageNameW, PROCESS_NAME_WIN32, PROCESS_QUERY_LIMITED_INFORMATION,
    };
    unsafe {
        let h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid).ok()?;
        let mut buf = [0u16; 1024];
        let mut n = buf.len() as u32;
        let ok = QueryFullProcessImageNameW(h, PROCESS_NAME_WIN32, windows::core::PWSTR(buf.as_mut_ptr()), &mut n).is_ok();
        let _ = CloseHandle(h);
        ok.then(|| String::from_utf16_lossy(&buf[..n as usize]).to_lowercase().contains("python"))
    }
}

#[cfg(not(windows))]
fn is_python(pid: u32) -> Option<bool> {
    let c = std::fs::read(format!("/proc/{pid}/cmdline")).ok()?;
    Some(String::from_utf8_lossy(&c).contains("python"))
}

#[cfg(windows)]
fn kill(pid: u32) {
    use windows::Win32::Foundation::CloseHandle;
    use windows::Win32::System::Threading::{OpenProcess, TerminateProcess, PROCESS_TERMINATE};
    unsafe {
        if let Ok(h) = OpenProcess(PROCESS_TERMINATE, false, pid) {
            let _ = TerminateProcess(h, 1);
            let _ = CloseHandle(h);
        }
    }
}

#[cfg(not(windows))]
fn kill(pid: u32) {
    let _ = std::process::Command::new("kill").args(["-9", &pid.to_string()]).status();
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Health {
    /// it answered a ping
    Answers,
    /// no answer, but its CPU time moves (a model loading, a long decode), or it can't be told: left alone
    Working,
    /// no run file, or its process is gone
    Gone,
    /// the pid now belongs to something else: the file is stale, the process not ours
    NotAServer,
    /// alive, ours, no answer and no CPU: stuck
    Stuck,
}

/// The verdict from the facts (pure). `cpu`: CPU seconds used while the ping waited.
pub fn verdict(has_pid: bool, alive: bool, answered: bool, python: Option<bool>, cpu: Option<f64>) -> Health {
    if !has_pid || !alive {
        return Health::Gone;
    }
    if answered {
        return Health::Answers;
    }
    match python {
        None => return Health::Working,
        Some(false) => return Health::NotAServer,
        Some(true) => {}
    }
    match cpu {
        Some(c) if c < 0.01 => Health::Stuck,
        _ => Health::Working,
    }
}

/// Ping it (`timeout`) and look at its process. Blocks up to `timeout`.
pub fn health(name: &str, timeout: Duration) -> Health {
    let Some(pid) = record(name).and_then(|r| r.pid) else {
        return Health::Gone;
    };
    if !alive(pid) {
        return Health::Gone;
    }
    let c0 = cpu_seconds(pid);
    let t0 = Instant::now();
    let answered = call(name, &json!({"cmd": "ping"}), timeout, None).is_some_and(|v| v["ok"] == json!(true));
    // a ping refused at once still gets the whole window to show CPU
    if !answered {
        if let Some(left) = timeout.checked_sub(t0.elapsed()) {
            std::thread::sleep(left);
        }
    }
    let cpu = c0.zip(cpu_seconds(pid)).map(|(a, b)| b - a);
    verdict(true, alive(pid), answered, is_python(pid), cpu)
}

/// End a stuck server and remove its file (only when the file still names it).
pub fn end(name: &str, pid: u32) {
    if pid <= 1 || pid == std::process::id() {
        return;
    }
    kill(pid);
    let until = Instant::now() + Duration::from_millis(1500);
    while alive(pid) && Instant::now() < until {
        std::thread::sleep(Duration::from_millis(20));
    }
    if record(name).and_then(|r| r.pid) == Some(pid) {
        let _ = std::fs::remove_file(info_path(name));
    }
}

/// A request in flight is hung: no answer after 3 s while the server's CPU hasn't moved for 2 s (the idle CPU decides,
/// whatever the audio's length — a server that works keeps its CPU moving).
pub fn hung(waited: f64, cpu_idle: f64) -> bool {
    waited >= 3.0 && cpu_idle >= 2.0
}

pub fn running(name: &str) -> bool {
    record(name).is_some_and(|r| r.pid.is_none_or(alive))
}

/// One request → the answer; None when there is no server, it refused, or `timeout` passed. `give_up` is asked about
/// every quarter second while the answer is out (true ends the wait: Esc, a hang).
pub fn call(
    name: &str,
    req: &Value,
    timeout: Duration,
    give_up: Option<&dyn Fn() -> bool>,
) -> Option<Value> {
    let r = record(name)?;
    if r.pid.is_some_and(|p| !alive(p)) {
        return None;
    }
    let mut body = req.clone();
    body["token"] = json!(r.token);
    let addr = SocketAddr::from(([127, 0, 0, 1], r.port));
    let mut s = TcpStream::connect_timeout(&addr, Duration::from_millis(500)).ok()?;
    s.set_write_timeout(Some(timeout)).ok()?;
    let mut line = serde_json::to_vec(&body).ok()?;
    line.push(b'\n');
    s.write_all(&line).ok()?;
    let slice = if give_up.is_some() || r.pid.is_some() {
        Duration::from_millis(250)
    } else {
        timeout
    };
    s.set_read_timeout(Some(slice.min(timeout))).ok()?;
    let t0 = Instant::now();
    let deadline = t0 + timeout;
    // the hang check (not for a ping: `health` judges those)
    let watch = r.pid.filter(|_| req["cmd"] != json!("ping"));
    let mut cpu_last = watch.and_then(cpu_seconds);
    let mut still_since = Instant::now();
    let mut rd = BufReader::new(s);
    let mut buf = Vec::new();
    loop {
        match rd.read_until(b'\n', &mut buf) {
            Ok(0) => return None,
            Ok(_) if buf.last() == Some(&b'\n') => break,
            Ok(_) => {}
            Err(e)
                if matches!(
                    e.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                ) =>
            {
                if Instant::now() >= deadline || give_up.is_some_and(|g| g()) {
                    return None;
                }
                if let Some(pid) = watch {
                    match cpu_seconds(pid) {
                        Some(c) if cpu_last.is_none_or(|l| c - l >= 0.005) => {
                            cpu_last = Some(c);
                            still_since = Instant::now();
                        }
                        Some(_) => {}
                        None => still_since = Instant::now(),
                    }
                    if hung(t0.elapsed().as_secs_f64(), still_since.elapsed().as_secs_f64()) {
                        eprintln!("blurt: {name} hung (no CPU for 2 s): ended");
                        end(name, pid);
                        return None;
                    }
                }
            }
            Err(_) => return None,
        }
    }
    serde_json::from_slice(&buf).ok()
}

/// A take streamed to the speech server while it is said (`transcribe.py serve`'s `stream`, docs/design/dictation.md
/// §Cloud recognition: Volcengine hears the audio as it comes, so at key-up only its last block is left): one JSON line
/// (`header`, the token added), then raw 16 kHz s16 mono PCM, then our side shut at key-up, then one JSON line back —
/// a note's answer. Dropping it unanswered (a cancelled take) resets the connection and the session ends.
pub struct Stream {
    s: TcpStream,
}

impl Stream {
    pub fn open(name: &str, header: &Value) -> Option<Stream> {
        let r = record(name)?;
        let mut body = header.clone();
        body["token"] = json!(r.token);
        body["cmd"] = json!("stream");
        let mut s = TcpStream::connect_timeout(&SocketAddr::from(([127, 0, 0, 1], r.port)), Duration::from_millis(500)).ok()?;
        s.set_write_timeout(Some(Duration::from_secs(5))).ok()?;
        let mut line = serde_json::to_vec(&body).ok()?;
        line.push(b'\n');
        s.write_all(&line).ok()?;
        Some(Stream { s })
    }

    /// Microphone samples (−1…1) as s16 little-endian.
    pub fn send(&mut self, samples: &[f32]) -> bool {
        let b: Vec<u8> = samples.iter().flat_map(|x| ((x.clamp(-1.0, 1.0) * 32767.0) as i16).to_le_bytes()).collect();
        self.s.write_all(&b).is_ok()
    }

    /// Key-up: our side shut; the answer within `timeout`. `give_up`: asked every quarter second (Esc).
    pub fn finish(mut self, timeout: Duration, give_up: &dyn Fn() -> bool) -> Option<Value> {
        let _ = self.s.flush();
        self.s.shutdown(std::net::Shutdown::Write).ok()?;
        self.s.set_read_timeout(Some(Duration::from_millis(250))).ok()?;
        let deadline = Instant::now() + timeout;
        let mut rd = BufReader::new(self.s);
        let mut buf = Vec::new();
        loop {
            match rd.read_until(b'\n', &mut buf) {
                Ok(0) => return serde_json::from_slice(&buf).ok(),
                Ok(_) if buf.last() == Some(&b'\n') => return serde_json::from_slice(&buf).ok(),
                Ok(_) => {}
                Err(e) if matches!(e.kind(), std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut) => {
                    if Instant::now() >= deadline || give_up() {
                        return None;
                    }
                }
                Err(_) => return None,
            }
        }
    }
}

static SPAWNING: Mutex<()> = Mutex::new(());

/// Start a server unless one runs. `script` "transcribe.py" / "polish.py", `args` after `serve`. Returns at once; the
/// server writes its run file once it listens (`wait_ready`).
pub fn ensure(runner: &Runner, name: &str, script: &str, args: &[&str]) -> Result<(), String> {
    let _g = SPAWNING.lock().unwrap();
    if running(name) {
        if health(name, Duration::from_millis(500)) != Health::Stuck {
            return Ok(());
        }
        if let Some(pid) = record(name).and_then(|r| r.pid) {
            eprintln!("blurt: {name} stuck (no answer, no CPU): restarting");
            end(name, pid);
        }
    }
    let mut a: Vec<String> = vec!["serve".into()];
    a.extend(args.iter().map(|s| s.to_string()));
    a.extend(["--parent".into(), std::process::id().to_string()]);
    let argv = runner.argv(script, &a).map_err(|e| e.message)?;
    let mut c = scripts::command(&argv);
    // the speech server: the cloud speech keys (cloud.rs `speech_env`; a cloud model then hears the takes)
    if script == "transcribe.py" {
        for (k, v) in super::cloud::speech_env() {
            c.env(k, v);
        }
    }
    c.env("BLURT_NO_DOWNLOAD", "1")
        .stdin(Stdio::null())
        .stdout(Stdio::null());
    let log = paths::blurt_home().join("logs");
    let _ = std::fs::create_dir_all(&log);
    match std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(log.join(format!("{name}.log")))
    {
        Ok(f) => {
            c.stderr(f);
        }
        Err(_) => {
            c.stderr(Stdio::null());
        }
    }
    c.spawn().map(|_| ()).map_err(|e| e.to_string())
}

/// Wait until the server answers a ping (a model loading answers too: `serve` replies while it loads).
pub fn wait_ready(name: &str, timeout: Duration) -> bool {
    let t0 = Instant::now();
    while t0.elapsed() < timeout {
        if call(
            name,
            &json!({"cmd": "ping"}),
            Duration::from_millis(800),
            None,
        )
        .is_some_and(|v| v["ok"] == json!(true))
        {
            return true;
        }
        std::thread::sleep(Duration::from_millis(150));
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn verdicts() {
        assert_eq!(verdict(false, true, false, Some(true), Some(0.0)), Health::Gone);
        assert_eq!(verdict(true, false, false, Some(true), Some(0.0)), Health::Gone);
        assert_eq!(verdict(true, true, true, Some(false), None), Health::Answers);
        assert_eq!(verdict(true, true, false, Some(false), Some(0.0)), Health::NotAServer);
        assert_eq!(verdict(true, true, false, None, Some(0.0)), Health::Working);
        assert_eq!(verdict(true, true, false, Some(true), Some(0.3)), Health::Working);
        assert_eq!(verdict(true, true, false, Some(true), None), Health::Working);
        assert_eq!(verdict(true, true, false, Some(true), Some(0.0)), Health::Stuck);
    }

    #[test]
    fn hang_rule() {
        assert!(!hung(2.9, 2.9)); // too early
        assert!(!hung(10.0, 1.9)); // working
        assert!(hung(3.0, 2.0));
    }
}
