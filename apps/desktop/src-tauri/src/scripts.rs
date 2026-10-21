//! Running the skill's Python CLIs (`uv run --script <scripts>/<name> …`). They print one JSON line per call (C2/C3/C5);
//! `run` returns the last JSON line of stdout. All writes to items.json go through here (`items.py …`).

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
        Err(ScriptError { code, message: format!("{script} {}: {message}", args.first().map_or("", |s| s.as_str())), stdout: out, stderr: errs })
    }
}

fn tail(s: &str, n: usize) -> String {
    let t = s.trim();
    let start = t.char_indices().rev().nth(n).map_or(0, |(i, _)| i);
    t[start..].to_string()
}

/// Wait with a deadline, reading both pipes on threads so a chatty child can't block on a full pipe.
fn wait(mut child: Child, timeout: Duration) -> Result<(Option<i32>, String, String), String> {
    let mut so = child.stdout.take();
    let mut se = child.stderr.take();
    let t1 = std::thread::spawn(move || {
        let mut b = Vec::new();
        if let Some(s) = so.as_mut() {
            let _ = s.read_to_end(&mut b);
        }
        String::from_utf8_lossy(&b).into_owned()
    });
    let t2 = std::thread::spawn(move || {
        let mut b = Vec::new();
        if let Some(s) = se.as_mut() {
            let _ = s.read_to_end(&mut b);
        }
        String::from_utf8_lossy(&b).into_owned()
    });
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
    Ok((status.code(), t1.join().unwrap_or_default(), t2.join().unwrap_or_default()))
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

pub fn s(p: &Path) -> String {
    p.to_string_lossy().into_owned()
}
