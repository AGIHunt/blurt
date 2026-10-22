//! An agent session end to end, the way the embedded terminal sees it (contract K5): an item is dispatched with
//! `sessions.py` into a tmux window on a private socket (a scripted stand-in agent, no network), `attach-cmd` gives
//! the view's command, and a pty of ours ([`Ptys`], what xterm.js talks to) attaches: we read the agent's screen,
//! answer its question with keystrokes, and watch the job's status move through the K4 fold. Needs uv, git, tmux and
//! the v0.7 scripts; skipped otherwise (and on Windows, where sessions run in ConPTY instead).
//!
//!   cargo test --test session                   (BLURT_SCRIPTS=<dir> to test other scripts than the repo's)

#![cfg(unix)]

use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::{mpsc, Arc};
use std::time::{Duration, Instant};

use blurt_desktop_lib::pty::{Ptys, Spawn};
use blurt_desktop_lib::scripts::Runner;
use blurt_desktop_lib::{jobs, paths, projects};
use serde_json::{json, Value};

fn which(n: &str) -> Option<PathBuf> {
    std::env::split_paths(&std::env::var_os("PATH")?).map(|d| d.join(n)).find(|p| p.is_file())
}

const AGENT: &str = r#"#!/usr/bin/env python3
import sys, time
print("Stand-in agent ready:", (sys.argv[-1] if len(sys.argv) > 1 else "")[:40], flush=True)
time.sleep(0.5)
print("Allow this? [y/n]", flush=True)
answer = sys.stdin.readline().strip()
print("answered:", answer, flush=True)
for i in range(8):
    print("working", i, flush=True)
    time.sleep(0.1)
sys.stdin.readline()
"#;

fn wait_for(what: &str, secs: u64, mut f: impl FnMut() -> bool) {
    let t0 = Instant::now();
    while !f() {
        assert!(t0.elapsed() < Duration::from_secs(secs), "timed out waiting for {what}");
        std::thread::sleep(Duration::from_millis(150));
    }
}

#[test]
fn dispatch_attach_type() {
    let root = paths::normalize(&Path::new(env!("CARGO_MANIFEST_DIR")).join("../../.."));
    let scripts = std::env::var_os("BLURT_SCRIPTS").map(PathBuf::from).unwrap_or_else(|| root.join("skills/blurt/scripts"));
    let (Some(uv), Some(_), Some(_)) = (which("uv"), which("tmux"), which("git")) else {
        eprintln!("skipped: needs uv, tmux and git");
        return;
    };
    if !scripts.join("sessions.py").is_file() || !scripts.join("projects.py").is_file() {
        eprintln!("skipped: the v0.7 scripts are missing in {}", scripts.display());
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().join("home");
    std::fs::create_dir_all(home.join("bin")).unwrap();
    let socket = format!("blurt-test-p8-{}", std::process::id());
    std::env::set_var("BLURT_HOME", &home);
    std::env::set_var("BLURT_WORKSPACE", tmp.path().join("ws"));
    std::env::set_var("BLURT_TMUX_SOCKET", &socket);
    std::env::set_var("BLURT_NO_LOGIN_SHELL", "1");
    let agent = home.join("bin/standin-agent");
    std::fs::write(&agent, AGENT).unwrap();
    Command::new("chmod").arg("+x").arg(&agent).status().unwrap();
    let cfg = json!({"record": {"install_app": false, "agent_defs": {"standin": {"name": "Stand-in", "bins": ["standin-agent"],
        "interactive": {"session": {"argv": ["{prompt}"]}, "waiting_patterns": ["Allow this\\? \\[y/n\\]"]}}}}});
    std::fs::write(home.join("config.json"), cfg.to_string()).unwrap();
    let repo = tmp.path().join("app");
    std::fs::create_dir_all(&repo).unwrap();
    for a in [&["init", "-q"][..], &["commit", "-q", "--allow-empty", "-m", "init"]] {
        Command::new("git").args(["-c", "user.email=t@t", "-c", "user.name=t"]).args(a).current_dir(&repo).status().unwrap();
    }
    let runner = Runner { scripts: Some(scripts), uv: Some(uv) };
    let pid = projects::add(&runner, &repo.to_string_lossy()).unwrap()["project"]["id"].as_str().unwrap().to_string();
    let item = runner
        .run("items.py", &["add".into(), "--project".into(), pid, "--json".into(), json!({"kind": "issue", "title": "Save button too faint"}).to_string()], None, Duration::from_secs(60))
        .unwrap();
    let uid = item["uid"].as_str().unwrap().to_string();

    let r = runner
        .run("sessions.py", &["dispatch".into(), "--items".into(), uid, "--agent".into(), "standin".into(), "--worktree".into(), "off".into()], None, Duration::from_secs(90))
        .unwrap();
    let job = r["jobs"][0]["id"].as_str().unwrap().to_string();
    let m = runner.argv("sessions.py", &["monitor".into(), "--interval".into(), "0.5".into()]).unwrap();
    let _cleanup = Cleanup {
        monitor: blurt_desktop_lib::scripts::daemon_command(&m).stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null()).spawn().unwrap(),
        socket: socket.clone(),
    };
    let status = || jobs::load(&job).and_then(|j| j.pointer("/agent/status").and_then(Value::as_str).map(str::to_owned)).unwrap_or_default();

    // the view: attach-cmd → our pty
    let a = runner.run("sessions.py", &["attach-cmd".into(), job.clone()], None, Duration::from_secs(30)).unwrap();
    let argv: Vec<String> = a["argv"].as_array().unwrap().iter().filter_map(|v| v.as_str().map(str::to_owned)).collect();
    let env = a.get("env").and_then(Value::as_object).cloned().unwrap_or_default();
    let ptys = Ptys::default();
    let (tx, rx) = mpsc::channel::<Vec<u8>>();
    let id = ptys
        .spawn(Spawn { argv, env, cwd: None, job: Some(job.clone()), owned: false, cols: 100, rows: 30 }, Arc::new(move |_, d| { let _ = tx.send(d.to_vec()); }), Arc::new(|_, _, _| {}))
        .unwrap();
    let mut screen = String::new();
    let mut read_until = |needle: &str| {
        let t0 = Instant::now();
        while !screen.contains(needle) {
            assert!(t0.elapsed() < Duration::from_secs(20), "the screen never showed {needle:?}:\n{screen}");
            if let Ok(d) = rx.recv_timeout(Duration::from_millis(200)) {
                screen.push_str(&String::from_utf8_lossy(&d));
            }
        }
    };
    read_until("Allow this?");
    wait_for("waiting_input", 20, || status() == "waiting_input");
    ptys.resize(id, 120, 36).unwrap();
    ptys.write(id, b"y\r").unwrap();
    read_until("answered: y");
    wait_for("running again", 20, || status() == "running");
    ptys.write(id, b"\r").unwrap();
    wait_for("exited", 20, || status() == "exited");
    ptys.close(id);
}

/// The monitor and the private tmux server go away whatever happens to the test.
struct Cleanup {
    monitor: std::process::Child,
    socket: String,
}

impl Drop for Cleanup {
    fn drop(&mut self) {
        blurt_desktop_lib::scripts::kill_tree(&mut self.monitor);
        let _ = Command::new("tmux").args(["-L", &self.socket, "kill-server"]).status();
        // kill-server leaves the socket file behind
        let dir = std::env::var("TMUX_TMPDIR").unwrap_or_else(|_| "/tmp".into());
        let uid = Command::new("id").arg("-u").output().map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string());
        if let Ok(uid) = uid {
            let _ = std::fs::remove_file(std::path::Path::new(&dir).join(format!("tmux-{uid}")).join(&self.socket));
        }
    }
}
