//! Handing work to agents (contract K5 / K6) and sorting captures (K4 process jobs). Everything about which agent
//! and how to start it comes from the Python CLIs — `sessions.py` (dispatch into tmux windows, or the app runner),
//! `handoff.py` (the hand-off sheet and the one-line instruction), `agents.py` (detect, the headless command used
//! for sorting). We run what they return.

use std::io::Write as _;
use std::path::{Path, PathBuf};
use std::process::{Child, Stdio};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde::Deserialize;
use serde_json::{json, Value};
use tauri::{AppHandle, Emitter, Manager};

use crate::jobs::JobWriter;
use crate::scripts::{self, Runner};
use crate::{l10n, paths, projects, pty, AppState};

pub fn detect(runner: &Runner) -> Result<Value, String> {
    runner.run("agents.py", &["detect".into()], None, Duration::from_secs(90)).map_err(String::from)
}

/// `agents.py models ID`: the agent's models (its own list or the CLI's cache; no network, no tokens).
pub fn models(runner: &Runner, agent: &str) -> Result<Value, String> {
    runner.run("agents.py", &["models".into(), agent.into()], None, Duration::from_secs(30)).map_err(String::from)
}

fn pick_agent(runner: &Runner, wanted: Option<String>) -> Result<String, String> {
    match wanted.filter(|a| !a.is_empty()) {
        Some(a) => Ok(a),
        None => detect(runner)?.get("pick").and_then(Value::as_str).map(str::to_owned).ok_or_else(|| "no_agent".to_string()),
    }
}

#[derive(Debug, Default, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct DispatchOpts {
    pub items: Vec<String>,
    pub agent: Option<String>,
    /// together | parallel
    pub mode: Option<String>,
    /// on | off | auto
    pub worktree: Option<String>,
    /// tmux | app | auto
    pub runner: Option<String>,
    pub dry_run: bool,
    /// the agent's model; None / "" = the CLI's own setting
    pub model: Option<String>,
}

/// `sessions.py dispatch …`; an app-runner result (`launch`) starts in our own pty right away.
pub fn dispatch(app: &AppHandle, runner: &Runner, o: &DispatchOpts) -> Result<Value, String> {
    if o.items.is_empty() {
        return Err("nothing to dispatch".into());
    }
    let mut args = vec!["dispatch".to_string(), "--items".to_string()];
    args.extend(o.items.iter().cloned());
    if let Some(a) = o.agent.as_deref().filter(|a| !a.is_empty()) {
        args.extend(["--agent".into(), a.into()]);
    }
    if let Some(m) = o.model.as_deref().filter(|m| !m.is_empty()) {
        args.extend(["--model".into(), m.into()]);
    }
    args.extend(["--mode".into(), o.mode.clone().unwrap_or_else(|| "together".into())]);
    args.extend(["--worktree".into(), o.worktree.clone().unwrap_or_else(|| "auto".into())]);
    // Windows has no tmux: the app runs the agent in ConPTY (K5 "没有 tmux / Windows")
    let run = o.runner.clone().unwrap_or_else(|| if cfg!(windows) { "app".into() } else { "auto".into() });
    args.extend(["--runner".into(), run]);
    if o.dry_run {
        args.push("--dry-run".into());
    }
    args.extend(["--lang".into(), l10n::short_lang().into()]);
    let r = runner.run("sessions.py", &args, None, Duration::from_secs(90)).map_err(String::from)?;
    if !o.dry_run {
        for l in r.get("launch").and_then(Value::as_array).into_iter().flatten() {
            let argv: Vec<String> = l["argv"].as_array().into_iter().flatten().filter_map(|v| v.as_str().map(str::to_owned)).collect();
            let env = l.get("env").and_then(Value::as_object).cloned().unwrap_or_default();
            let cwd = l["cwd"].as_str().map(PathBuf::from);
            let job = l["job"].as_str().map(str::to_owned);
            match pty::spawn(app, &argv, &env, cwd, job, true, 120, 32) {
                // agents that can't take the prompt as an argument get it pasted once they are up (P2: `paste`)
                Ok(id) => {
                    if let Some(text) = l["paste"].as_str().filter(|t| !t.is_empty()).map(str::to_owned) {
                        let app = app.clone();
                        std::thread::spawn(move || {
                            std::thread::sleep(Duration::from_secs(3));
                            let _ = pty::write(&app, id, &format!("\x1b[200~{text}\x1b[201~\r"));
                        });
                    }
                }
                Err(e) => eprintln!("blurt: app runner: {e}"),
            }
        }
    }
    Ok(r)
}

pub fn list(runner: &Runner, all: bool) -> Result<Value, String> {
    let mut args = vec!["list".to_string()];
    if all {
        args.push("--all".into());
    }
    runner.run("sessions.py", &args, None, Duration::from_secs(30)).map_err(String::from)
}

pub fn finish(runner: &Runner, job: &str, action: &str) -> Result<Value, String> {
    let t = if action == "pr" { 180 } else { 60 };
    runner
        .run("sessions.py", &["finish".into(), job.into(), "--action".into(), action.into()], None, Duration::from_secs(t))
        .map_err(String::from)
}

pub fn stop(app: &AppHandle, runner: &Runner, job: &str, kill: bool) -> Result<Value, String> {
    if pty::kill_job(app, job) {
        return Ok(json!({"ok": true}));
    }
    let mut args = vec!["stop".to_string(), job.to_string()];
    if kill {
        args.push("--kill".into());
    }
    runner.run("sessions.py", &args, None, Duration::from_secs(20)).map_err(String::from)
}

pub fn open_external(runner: &Runner, job: &str, terminal: Option<&str>) -> Result<Value, String> {
    let mut args = vec!["open-external".to_string(), job.to_string()];
    if let Some(t) = terminal.filter(|t| !t.is_empty()) {
        args.extend(["--terminal".into(), t.into()]);
    }
    runner.run("sessions.py", &args, None, Duration::from_secs(20)).map_err(String::from)
}

pub fn send(runner: &Runner, job: &str, text: &str, enter: bool) -> Result<Value, String> {
    let mut args = vec!["send".to_string(), job.to_string(), "--text".to_string(), text.to_string()];
    if enter {
        args.push("--enter".into());
    }
    runner.run("sessions.py", &args, None, Duration::from_secs(20)).map_err(String::from)
}

/// K6: the hand-off sheet for these items, marked handed off (the user just clicked copy) → {id, path, text}.
pub fn handoff(runner: &Runner, uids: &[String], full: bool) -> Result<Value, String> {
    let mut args = vec!["create".to_string(), "--items".to_string()];
    args.extend(uids.iter().cloned());
    args.extend(["--lang".into(), l10n::short_lang().into(), "--to".into(), "external".into(), "--mark".into()]);
    let r = runner.run("handoff.py", &args, None, Duration::from_secs(30)).map_err(String::from)?;
    crate::items::bump();
    let text = r.get(if full { "full" } else { "instruction" }).cloned().unwrap_or(Value::Null);
    Ok(json!({"id": r["id"], "path": r["path"], "text": text, "items": r["items"]}))
}

/// `sessions.py monitor` while the app runs (it holds its own lock: a second one exits at once).
#[derive(Default)]
pub struct Monitor(Mutex<Option<Child>>);

pub fn start_monitor(app: &AppHandle) {
    let runner = app.state::<AppState>().runner();
    if !runner.has("sessions.py") {
        return;
    }
    // --parent: the monitor ends with the app even when stop_monitor never runs (a crash, a kill)
    let args = ["monitor".to_string(), "--parent".into(), std::process::id().to_string()];
    let Ok(argv) = runner.argv("sessions.py", &args) else { return };
    let mut c = scripts::daemon_command(&argv);
    c.stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null());
    match c.spawn() {
        Ok(child) => *app.state::<Monitor>().0.lock().unwrap() = Some(child),
        Err(e) => eprintln!("blurt: sessions.py monitor: {e}"),
    }
}

pub fn stop_monitor(app: &AppHandle) {
    if let Some(mut c) = app.state::<Monitor>().0.lock().unwrap().take() {
        scripts::kill_tree(&mut c);
    }
}

// ------------------------------------------------------------------ sorting (process jobs, K4)

/// What the headless agent is asked (SKILL.md does the rest; `items.py` ingests what it writes).
pub fn process_prompt(session: &Path, captures: Option<&[u64]>, project: Option<&Value>) -> String {
    let shots = session.join("shots.jsonl").is_file() && !session.join("recording.mp4").is_file();
    let mut s = if shots {
        format!(
            "Use the blurt skill to process this batch of captures: {}\nIt is a shots session (mode: shots, no video): each \
             shot anchors one item and is that item's primary frame; voice-only lines (type voice) are items of their own; \
             transcribe voice notes first; .marked.png files already carry the user's ink.",
            session.display()
        )
    } else {
        format!("Use the blurt skill to process this recording: {}", session.display())
    };
    if let Some(c) = captures.filter(|c| !c.is_empty()) {
        let list: Vec<String> = c.iter().map(u64::to_string).collect();
        s.push_str(&format!("\nOnly the captures n = {} of shots.jsonl belong to this run; leave the others alone.", list.join(", ")));
    }
    if let Some(p) = project {
        s.push_str(&format!(
            "\nThe items belong to the project \"{}\" ({}).",
            p["name"].as_str().unwrap_or(""),
            p["path"].as_str().unwrap_or("")
        ));
    }
    s.push_str(
        "\nThis is an unattended background run started by the Blurt app: don't ask questions and don't start the review \
         page; write items.json, then summarise in 2–3 sentences.",
    );
    s
}

/// Rough cause of a failed run from the tail of its output (K4 error codes).
pub fn error_code(log_tail: &str) -> &'static str {
    let t = log_tail.to_lowercase();
    if ["not logged in", "please log in", "/login", "unauthorized", "authentication", "api key"].iter().any(|k| t.contains(k)) {
        "auth"
    } else if ["rate limit", "quota", "usage limit", "credit balance"].iter().any(|k| t.contains(k)) {
        "quota"
    } else if ["network", "enotfound", "econnrefused", "timed out", "connection"].iter().any(|k| t.contains(k)) {
        "network"
    } else {
        "unknown"
    }
}

/// K7 `process_captures`: file the given captures (shots.jsonl `n`) of a shots session into `project` (None = let
/// the AI sort them, item by item), or a whole recording; then sort them in a background process job.
/// `assigned_by`: write K7's assignment lines first (`user` when a card was dropped on a project or on "Unassigned");
/// None when the captures already carry their project (taken while a project was current).
pub fn process(
    app: &AppHandle,
    session: &Path,
    captures: Option<Vec<u64>>,
    project: Option<String>,
    assigned_by: Option<&str>,
    parent: Option<String>,
) -> Result<String, String> {
    let runner = app.state::<AppState>().runner();
    let reg = projects::Registry::load();
    let proj = project.as_deref().filter(|p| *p != "inbox").and_then(|p| reg.project(p)).cloned();
    if let (Some(c), Some(p), Some(by)) = (&captures, &project, assigned_by) {
        let mut f = std::fs::OpenOptions::new().append(true).create(true).open(session.join("shots.jsonl")).map_err(|e| e.to_string())?;
        for n in c {
            let line = json!({"n": n, "project": p, "assigned_by": by});
            let _ = writeln!(f, "{line}");
        }
    }
    let job_project = project.clone().or_else(|| reg.project_of_path(session).filter(|p| p != "inbox"));
    let job = Arc::new(JobWriter::new("process", job_project.as_deref(), Some(session), parent.as_deref(), None, &["prepare", "transcribe", "write", "frames", "route"]));
    if let Some(c) = &captures {
        job.set_captures(c);
    }
    job.step("prepare", "running", None);
    let agent = match pick_agent(&runner, None) {
        Ok(a) => a,
        Err(_) => {
            job.finish("failed", Some(("skill", "no coding agent is installed and logged in")));
            return Err("no_agent".into());
        }
    };
    let prompt = process_prompt(session, captures.as_deref(), proj.as_ref());
    let jobs = paths::jobs_dir();
    let pf = jobs.join(format!("{}.prompt.md", job.id));
    std::fs::write(&pf, &prompt).map_err(|e| format!("{}: {e}", pf.display()))?;
    let repo = proj.as_ref().and_then(|p| p["path"].as_str()).map(PathBuf::from).unwrap_or_else(|| session.to_path_buf());
    let args: Vec<String> = vec![
        "command".into(),
        agent.clone(),
        "headless".into(),
        "--prompt-file".into(),
        scripts::s(&pf),
        "--repo".into(),
        scripts::s(&repo),
        "--var".into(),
        format!("run_id={}", job.id),
        // v0.7: organising runs with the processing model (cheap, low effort) unless the user chose otherwise
        "--processing".into(),
    ];
    let cmd = match runner.run("agents.py", &args, None, Duration::from_secs(30)) {
        Ok(c) => c,
        Err(e) => {
            job.finish("failed", Some(("skill", &e.message)));
            return Err(e.message);
        }
    };
    let argv: Vec<String> = cmd["argv"].as_array().into_iter().flatten().filter_map(|v| v.as_str().map(str::to_owned)).collect();
    if argv.is_empty() {
        job.finish("failed", Some(("skill", "this agent has no headless mode")));
        return Err("no_agent".into());
    }
    let cwd = cmd["cwd"].as_str().map(PathBuf::from).unwrap_or(repo);
    let log = std::fs::File::create(jobs.join(format!("{}.log", job.id))).map_err(|e| e.to_string())?;
    let mut c = scripts::command(&argv);
    c.current_dir(&cwd).stdin(Stdio::null()).stdout(log.try_clone().map_err(|e| e.to_string())?).stderr(log);
    c.env("BLURT_JOB", &job.id).env("BLURT_RUN_ID", &job.id).env("BLURT_AGENT", &agent);
    c.env("BLURT_HOME", paths::blurt_home()).env("BLURT_WORKSPACE", paths::default_workspace());
    if let Some(p) = &job_project {
        c.env("BLURT_PROJECT", p);
    }
    for (k, v) in cmd.get("env").and_then(Value::as_object).into_iter().flatten() {
        if let Some(v) = v.as_str() {
            c.env(k, v);
        }
    }
    let mut child = match c.spawn() {
        Ok(ch) => ch,
        Err(e) => {
            job.finish("failed", Some(("skill", &e.to_string())));
            return Err(format!("couldn't start {}: {e}", argv[0]));
        }
    };
    job.step("prepare", "done", None);
    job.step("transcribe", "running", None);
    let id = job.id.clone();
    let (app2, session) = (app.clone(), session.to_path_buf());
    std::thread::spawn(move || {
        let code = child.wait().ok().and_then(|s| s.code());
        if code == Some(0) {
            // the items the run filed: what items.py reported into our events, else the batch it wrote
            if job.snapshot()["items"].as_array().is_none_or(Vec::is_empty) {
                if let Some(b) = crate::settings::read_json(&session.join("batch.json")) {
                    let uids: Vec<String> = b["items"].as_array().into_iter().flatten().filter_map(|v| v.as_str().map(str::to_owned)).collect();
                    job.set_items(&uids);
                }
            }
            job.finish("done", None);
        } else {
            let tail = std::fs::read_to_string(paths::jobs_dir().join(format!("{}.log", job.id))).unwrap_or_default();
            let tail: String = tail.chars().rev().take(4000).collect::<Vec<_>>().into_iter().rev().collect();
            let msg = format!("{} exited with {}", argv[0], code.map_or("a signal".to_string(), |c| c.to_string()));
            job.finish("failed", Some((error_code(&tail), &msg)));
        }
        crate::watcher::update(&app2, &[session]);
    });
    let _ = app.emit("jobs://started", json!({"id": id}));
    Ok(id)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn prompts() {
        let d = tempfile::tempdir().unwrap();
        std::fs::write(d.path().join("shots.jsonl"), "").unwrap();
        let p = process_prompt(d.path(), Some(&[3, 4]), Some(&json!({"name": "bug-agent", "path": "/r/bug-agent"})));
        assert!(p.contains("shots session") && p.contains("n = 3, 4") && p.contains("\"bug-agent\""), "{p}");
        assert!(!p.contains("opens it"), "the app never opens the review page by itself (K4)");
    }

    #[test]
    fn error_codes() {
        assert_eq!(error_code("Error: Not logged in · Please run /login"), "auth");
        assert_eq!(error_code("429 rate limit exceeded"), "quota");
        assert_eq!(error_code("getaddrinfo ENOTFOUND api.anthropic.com"), "network");
        assert_eq!(error_code("panic"), "unknown");
    }
}
