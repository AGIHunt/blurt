//! Running the skill's Python CLIs (`uv run --script <scripts>/<name> …`). They print one JSON line per call (C2/C3/C5);
//! `run` returns the last JSON line of stdout; a failure's message ends with the CLI's machine code as ` [code]`.

use std::collections::HashMap;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::OnceLock;
use std::time::{Duration, Instant};

use serde_json::Value;
use tauri::AppHandle;

use crate::paths;

#[derive(Debug)]
pub struct ScriptError {
    pub code: Option<i32>,
    pub message: String,
    pub stdout: String,
    pub stderr: String,
}

impl std::fmt::Display for ScriptError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.message)
    }
}

impl From<ScriptError> for String {
    fn from(e: ScriptError) -> String {
        e.message
    }
}

fn err(message: impl Into<String>) -> ScriptError {
    ScriptError { code: None, message: message.into(), stdout: String::new(), stderr: String::new() }
}

/// Where the scripts and uv are; both None-able (the UI shows "install uv" / "skill not found" and greys out writes).
#[derive(Clone, Debug)]
pub struct Runner {
    pub scripts: Option<PathBuf>,
    pub uv: Option<PathBuf>,
}

impl Runner {
    pub fn new(app: &AppHandle) -> Self {
        Runner { scripts: paths::scripts_dir(app), uv: paths::uv() }
    }

    pub fn has(&self, script: &str) -> bool {
        self.scripts.as_ref().is_some_and(|d| d.join(script).is_file())
    }

    /// argv to run a script; the script path is absolute.
    pub fn argv(&self, script: &str, args: &[String]) -> Result<Vec<String>, ScriptError> {
        let dir = self.scripts.as_ref().ok_or_else(|| err("blurt skill scripts not found (set BLURT_SCRIPTS)"))?;
        let path = dir.join(script);
        if !path.is_file() {
            return Err(err(format!("{script} not found in {}", dir.display())));
        }
        let uv = self.uv.as_ref().ok_or_else(|| err("uv not found (install it from https://docs.astral.sh/uv/)"))?;
        let mut v = vec![
            uv.to_string_lossy().into_owned(),
            "run".into(),
            "--quiet".into(),
            "--script".into(),
            path.to_string_lossy().into_owned(),
        ];
        v.extend(args.iter().cloned());
        Ok(v)
    }

    /// Run to completion; Ok(last JSON line) on exit 0, Err otherwise (message = the CLI's `error` field or stderr tail).
    pub fn run(&self, script: &str, args: &[String], stdin: Option<&[u8]>, timeout: Duration) -> Result<Value, ScriptError> {
        let argv = self.argv(script, args)?;
        let mut cmd = command(&argv);
        cmd.stdin(if stdin.is_some() { Stdio::piped() } else { Stdio::null() })
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        let mut child = cmd.spawn().map_err(|e| err(format!("couldn't start {script}: {e}")))?;
        if let (Some(data), Some(mut w)) = (stdin, child.stdin.take()) {
            let data = data.to_vec();
            std::thread::spawn(move || {
                let _ = w.write_all(&data);
            });
        }
        let (code, out, errs) = wait(child, timeout).map_err(|e| err(format!("{script}: {e}")))?;
        let last = out.lines().rev().find_map(|l| serde_json::from_str::<Value>(l.trim()).ok());
        if code == Some(0) {
            return last.ok_or_else(|| ScriptError {
                code,
                message: format!("{script} printed no JSON"),
                stdout: out.clone(),
                stderr: errs.clone(),
            });
        }
        let message = last
            .as_ref()
            .and_then(|v| v.get("error").and_then(Value::as_str).map(str::to_owned))
            .unwrap_or_else(|| tail(&errs, 600));
        // the CLI's machine code (contract: `code`) rides at the end, in brackets: the UI words it in its language
        let machine = last.as_ref().and_then(|v| v.get("code").and_then(Value::as_str)).map(|c| format!(" [{c}]")).unwrap_or_default();
        Err(ScriptError { code, message: format!("{script} {}: {message}{machine}", args.first().map_or("", |s| s.as_str())), stdout: out, stderr: errs })
    }
}

fn tail(s: &str, n: usize) -> String {
    let t = s.trim();
    let start = t.char_indices().rev().nth(n).map_or(0, |(i, _)| i);
    t[start..].to_string()
}

/// Wait with a deadline, reading both pipes on threads so a chatty child can't block on a full pipe. A daemon the
/// child started (the tmux server) may inherit the pipes and keep them open: once the child has exited we wait for
/// the rest of its output only briefly.
fn wait(mut child: Child, timeout: Duration) -> Result<(Option<i32>, String, String), String> {
    fn pump(stream: Option<impl Read + Send + 'static>) -> std::sync::mpsc::Receiver<String> {
        let (tx, rx) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            let mut b = Vec::new();
            if let Some(mut s) = stream {
                let mut chunk = [0u8; 8192];
                loop {
                    match s.read(&mut chunk) {
                        Ok(0) | Err(_) => break,
                        Ok(n) => b.extend_from_slice(&chunk[..n]),
                    }
                    let _ = tx.send(String::from_utf8_lossy(&b).into_owned()); // what we have so far
                }
            }
            let _ = tx.send(String::from_utf8_lossy(&b).into_owned());
        });
        rx
    }
    let (so, se) = (pump(child.stdout.take()), pump(child.stderr.take()));
    let deadline = Instant::now() + timeout;
    let status = loop {
        match child.try_wait() {
            Ok(Some(st)) => break st,
            Ok(None) if Instant::now() >= deadline => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(format!("timed out after {}s", timeout.as_secs()));
            }
            Ok(None) => std::thread::sleep(Duration::from_millis(15)),
            Err(e) => return Err(e.to_string()),
        }
    };
    let drain = |rx: std::sync::mpsc::Receiver<String>| {
        let mut last = String::new();
        let until = Instant::now() + Duration::from_secs(2);
        while let Ok(v) = rx.recv_timeout(until.saturating_duration_since(Instant::now())) {
            last = v;
        }
        last
    };
    Ok((status.code(), drain(so), drain(se)))
}

/// A Command for argv with the user's environment (login-shell PATH) and, on Windows, no console window.
pub fn command(argv: &[String]) -> Command {
    let mut cmd = Command::new(&argv[0]);
    cmd.args(&argv[1..]);
    for (k, v) in agent_environment() {
        cmd.env(k, v);
    }
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        cmd.creation_flags(CREATE_NO_WINDOW);
    }
    cmd
}

/// The environment children get: ours, plus PATH from the user's login shell on Unix (an app started from the desktop
/// doesn't see ~/.local/bin, nvm, … — the same reason the macOS app uses agentEnvironment()), plus the usual bin dirs.
pub fn agent_environment() -> &'static HashMap<String, String> {
    static ENV: OnceLock<HashMap<String, String>> = OnceLock::new();
    ENV.get_or_init(|| {
        let mut m = HashMap::new();
        let mut parts: Vec<PathBuf> = std::env::var_os("PATH").map(|p| std::env::split_paths(&p).collect()).unwrap_or_default();
        #[cfg(unix)]
        if std::env::var_os("BLURT_NO_LOGIN_SHELL").is_none() {
            if let Some(p) = login_shell_path() {
                for d in std::env::split_paths(&p) {
                    if !parts.contains(&d) {
                        parts.push(d);
                    }
                }
            }
        }
        let h = paths::home();
        for d in [paths::blurt_home().join("bin"), h.join(".local/bin"), h.join(".cargo/bin"), h.join(".npm-global/bin")] {
            if !parts.contains(&d) {
                parts.push(d);
            }
        }
        if let Ok(p) = std::env::join_paths(parts) {
            m.insert("PATH".into(), p.to_string_lossy().into_owned());
        }
        m.insert("PYTHONIOENCODING".into(), "utf-8".into());
        m
    })
}

#[cfg(unix)]
fn login_shell_path() -> Option<String> {
    let shell = std::env::var("SHELL").ok().filter(|s| !s.is_empty()).unwrap_or_else(|| "/bin/sh".into());
    let child = Command::new(shell)
        .args(["-l", "-c", "printf '%s' \"$PATH\""])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    let (code, out, _) = wait(child, Duration::from_secs(4)).ok()?;
    (code == Some(0) && !out.trim().is_empty()).then(|| out.trim().to_string())
}

/// A long-lived helper (`uv run … sessions.py monitor`): in a process group of its own, so [`kill_tree`] also ends
/// the Python that `uv run` starts under it.
pub fn daemon_command(argv: &[String]) -> Command {
    let mut c = command(argv);
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        c.process_group(0);
    }
    c
}

/// End a [`daemon_command`] child and everything it started.
pub fn kill_tree(child: &mut Child) {
    let pid = child.id().to_string();
    #[cfg(unix)]
    let _ = Command::new("kill").args(["-TERM", "--", &format!("-{pid}")]).stderr(Stdio::null()).status();
    #[cfg(windows)]
    let _ = command(&["taskkill".into(), "/T".into(), "/F".into(), "/PID".into(), pid]).stdout(Stdio::null()).stderr(Stdio::null()).status();
    let _ = child.kill();
    let _ = child.wait();
}

pub fn s(p: &Path) -> String {
    p.to_string_lossy().into_owned()
}
