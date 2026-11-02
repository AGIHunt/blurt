//! The warm model servers (BlurtCore WarmServer / the Mac's WarmSpawn): `transcribe.py serve` and `polish.py serve`
//! write `$BLURT_HOME/run/<name>.json` ({pid, port, token, parent, started}); one JSON line in, one JSON line out over
//! 127.0.0.1. Talking to them directly skips a `uv run` per request, which is most of what a dictation waits for.
//!
//! They are started offline-first (`BLURT_NO_DOWNLOAD=1`, `UV_OFFLINE=1`; one online retry when uv lacks a package),
//! with `--parent <our pid>` so they end with Blurt, and end by themselves after 10 idle minutes.

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
    pub port: u16,
    pub token: String,
}

pub fn record(name: &str) -> Option<Record> {
    let v: Value = serde_json::from_str(&std::fs::read_to_string(info_path(name)).ok()?).ok()?;
    let port = v.get("port")?.as_u64().filter(|p| *p > 0 && *p < 65536)? as u16;
    Some(Record {
        pid: v.get("pid").and_then(Value::as_u64).map(|p| p as u32),
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
    let slice = if give_up.is_some() {
        Duration::from_millis(250)
    } else {
        timeout
    };
    s.set_read_timeout(Some(slice.min(timeout))).ok()?;
    let deadline = Instant::now() + timeout;
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
            }
            Err(_) => return None,
        }
    }
    serde_json::from_slice(&buf).ok()
}

static SPAWNING: Mutex<()> = Mutex::new(());

/// Start a server unless one runs. `script` "transcribe.py" / "polish.py", `args` after `serve`. Returns at once; the
/// server writes its run file once it listens (`wait_ready`).
pub fn ensure(runner: &Runner, name: &str, script: &str, args: &[&str]) -> Result<(), String> {
    let _g = SPAWNING.lock().unwrap();
    if running(name) {
        return Ok(());
    }
    let mut a: Vec<String> = vec!["serve".into()];
    a.extend(args.iter().map(|s| s.to_string()));
    a.extend(["--parent".into(), std::process::id().to_string()]);
    let argv = runner.argv(script, &a).map_err(|e| e.message)?;
    let mut c = scripts::command(&argv);
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
