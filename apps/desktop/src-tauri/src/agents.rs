//! Coding agents (C5). Everything about which agent and how to call it comes from `agents.py` (detect / command /
//! prompt); we only execute the argv it returns, stream its output as `agent://line` events and keep a run list for
//! the Agents panel.

use std::collections::HashMap;
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::process::{Child, Stdio};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde::Serialize;
use serde_json::{json, Value};
use tauri::{AppHandle, Emitter};

use crate::paths;
use crate::scripts::{self, Runner};

const KEEP_LINES: usize = 400;

#[derive(Clone, Serialize)]
pub struct AgentRun {
    pub run_id: String,
    pub agent: String,
    pub repo: String,
    pub prompt: String,
    /// "running" | "done" | "failed" | "stopped"
    pub state: String,
    pub started: f64,
    pub ended: Option<f64>,
    pub exit: Option<i32>,
    pub cost_usd: Option<f64>,
    /// [{session, id}] the run was asked to fix
    pub items: Vec<Value>,
    pub lines: Vec<String>,
}

#[derive(Default)]
pub struct Runs {
    pub list: Mutex<Vec<AgentRun>>,
    pub children: Mutex<HashMap<String, Arc<Mutex<Child>>>>,
}

pub fn now() -> f64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or(0.0)
}

pub fn new_run_id() -> String {
    // r-YYYYMMDD-HHMMSS-xxxx (C1's run_id shape), local time isn't worth a dependency: UTC is fine for an id.
    let secs = now() as i64;
    let (days, rem) = (secs.div_euclid(86_400), secs.rem_euclid(86_400));
    let (y, m, d) = civil_from_days(days);
    let rnd = (SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.subsec_nanos()).unwrap_or(0) ^ std::process::id()) & 0xffff;
    format!("r-{y:04}{m:02}{d:02}-{:02}{:02}{:02}-{rnd:04x}", rem / 3600, rem / 60 % 60, rem % 60)
}

/// Howard Hinnant's days → (y, m, d).
fn civil_from_days(z: i64) -> (i64, u32, u32) {
    let z = z + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    (if m <= 2 { y + 1 } else { y }, m, d)
}

pub fn detect(runner: &Runner) -> Result<Value, String> {
    runner.run("agents.py", &["detect".into()], None, Duration::from_secs(90)).map_err(String::from)
}

/// The fix prompt for these items (agents.py prompt fix — the wording lives in one place).
pub fn fix_prompt(runner: &Runner, uids: &[String], repo: Option<&Path>) -> Result<Value, String> {
    let mut args = vec!["prompt".to_string(), "fix".to_string(), "--items".to_string()];
    args.extend(uids.iter().cloned());
    if let Some(r) = repo {
        args.push("--repo".into());
        args.push(scripts::s(r));
    }
    runner.run("agents.py", &args, None, Duration::from_secs(30)).map_err(String::from)
}

/// `agents.py command ID headless --prompt-file F --repo R --var run_id=…` → spawn → stream. Returns the run id.
pub fn run(app: &AppHandle, runner: &Runner, runs: &Arc<Runs>, id: &str, prompt: &str, repo: &str, items: Vec<Value>) -> Result<String, String> {
    let run_id = new_run_id();
    let prompts = paths::blurt_home().join("prompts");
    let _ = std::fs::create_dir_all(&prompts);
    let pf = prompts.join(format!("{run_id}.md"));
    std::fs::write(&pf, prompt).map_err(|e| format!("{}: {e}", pf.display()))?;
    let args: Vec<String> = vec![
        "command".into(),
        id.into(),
        "headless".into(),
        "--prompt-file".into(),
        scripts::s(&pf),
        "--repo".into(),
        repo.into(),
        "--var".into(),
        format!("run_id={run_id}"),
    ];
    let cmd = runner.run("agents.py", &args, None, Duration::from_secs(30)).map_err(String::from)?;
    let argv: Vec<String> = cmd
        .get("argv")
        .and_then(Value::as_array)
        .map(|a| a.iter().filter_map(|v| v.as_str().map(str::to_owned)).collect())
        .filter(|a: &Vec<String>| !a.is_empty())
        .ok_or_else(|| format!("{id} has no headless mode"))?;
    let cwd = cmd.get("cwd").and_then(Value::as_str).map(PathBuf::from).unwrap_or_else(|| PathBuf::from(repo));
    let mut c = scripts::command(&argv);
    c.current_dir(&cwd).stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped());
    c.env("BLURT_AGENT", id).env("BLURT_RUN_ID", &run_id);
    if let Some(env) = cmd.get("env").and_then(Value::as_object) {
        for (k, v) in env {
            if let Some(v) = v.as_str() {
                c.env(k, v);
            }
        }
    }
    let mut child = c.spawn().map_err(|e| format!("couldn't start {}: {e}", argv[0]))?;
    let stdout = child.stdout.take();
    let stderr = child.stderr.take();
    let child = Arc::new(Mutex::new(child));
    runs.children.lock().unwrap().insert(run_id.clone(), child.clone());
    runs.list.lock().unwrap().insert(
        0,
        AgentRun {
            run_id: run_id.clone(),
            agent: id.into(),
            repo: repo.into(),
            prompt: prompt.into(),
            state: "running".into(),
            started: now(),
            ended: None,
            exit: None,
            cost_usd: None,
            items,
            lines: vec![],
        },
    );
    let _ = app.emit("agent://started", json!({"run_id": run_id, "agent": id}));
    let pump = |stream: Option<Box<dyn std::io::Read + Send>>, name: &'static str| {
        let (app, runs, run_id) = (app.clone(), runs.clone(), run_id.clone());
        std::thread::spawn(move || {
            let Some(s) = stream else { return };
            for line in BufReader::new(s).lines().map_while(Result::ok) {
                let cost = serde_json::from_str::<Value>(&line).ok().and_then(|v| v.get("total_cost_usd").and_then(Value::as_f64));
                if let Some(r) = runs.list.lock().unwrap().iter_mut().find(|r| r.run_id == run_id) {
                    if r.lines.len() >= KEEP_LINES {
                        r.lines.remove(0);
                    }
                    r.lines.push(line.clone());
                    if cost.is_some() {
                        r.cost_usd = cost;
                    }
                }
                let _ = app.emit("agent://line", json!({"run_id": run_id, "line": line, "stream": name}));
            }
        })
    };
    let t1 = pump(stdout.map(|s| Box::new(s) as Box<dyn std::io::Read + Send>), "stdout");
    let t2 = pump(stderr.map(|s| Box::new(s) as Box<dyn std::io::Read + Send>), "stderr");
    {
        let (app, runs, run_id) = (app.clone(), runs.clone(), run_id.clone());
        std::thread::spawn(move || {
            let _ = (t1.join(), t2.join());
            let code = loop {
                match child.lock().unwrap().try_wait() {
                    Ok(Some(st)) => break st.code(),
                    Ok(None) => {}
                    Err(_) => break None,
                }
                std::thread::sleep(Duration::from_millis(100));
            };
            runs.children.lock().unwrap().remove(&run_id);
            let mut state = if code == Some(0) { "done" } else { "failed" };
            if let Some(r) = runs.list.lock().unwrap().iter_mut().find(|r| r.run_id == run_id) {
                if r.state == "stopped" {
                    state = "stopped";
                }
                r.state = state.into();
                r.ended = Some(now());
                r.exit = code;
            }
            let _ = app.emit("agent://exit", json!({"run_id": run_id, "code": code, "state": state}));
            let agent = runs.list.lock().unwrap().iter().find(|r| r.run_id == run_id).map(|r| r.agent.clone()).unwrap_or_default();
            let body = match state {
                "done" => format!("{agent} finished — check the items it fixed"),
                "stopped" => format!("{agent} was stopped"),
                _ => format!("{agent} stopped with exit {}", code.map_or("?".to_string(), |c| c.to_string())),
            };
            crate::notify(&app, "Blurt", &body);
        });
    }
    Ok(run_id)
}

pub fn stop(runs: &Runs, run_id: &str) -> bool {
    let child = runs.children.lock().unwrap().get(run_id).cloned();
    if let Some(c) = child {
        if let Some(r) = runs.list.lock().unwrap().iter_mut().find(|r| r.run_id == run_id) {
            r.state = "stopped".into();
        }
        return c.lock().unwrap().kill().is_ok();
    }
    false
}

/// Let an agent fix items of one session: mark them `fixing` (items.py fix), build the prompt, start a headless run.
/// agent None = agents.py detect's pick.
pub fn fix_with_agent(
    app: &AppHandle,
    runner: &Runner,
    runs: &Arc<Runs>,
    session: &str,
    item_ids: &[String],
    agent: Option<String>,
) -> Result<Value, String> {
    let sdir = PathBuf::from(session);
    let repo = paths::repo_of_session(&sdir).ok_or("this session isn't in a project (repo) workspace — move it to a project first")?;
    let agent = match agent {
        Some(a) => a,
        None => detect(runner)?
            .get("pick")
            .and_then(Value::as_str)
            .map(str::to_owned)
            .ok_or("no coding agent is installed and logged in (Settings → Agents)")?,
    };
    // uids for the prompt (items.py get resolves ids and uids alike)
    let mut uids = Vec::new();
    for id in item_ids {
        let v = runner.run("items.py", &["get".into(), session.into(), id.clone()], None, Duration::from_secs(20)).map_err(String::from)?;
        if let Some(u) = v.pointer("/item/uid").and_then(Value::as_str) {
            uids.push(u.to_string());
        }
    }
    let prompt = fix_prompt(runner, &uids, Some(&repo))?
        .get("prompt")
        .and_then(Value::as_str)
        .map(str::to_owned)
        .ok_or("agents.py prompt fix returned no prompt")?;
    let items: Vec<Value> = item_ids.iter().map(|i| json!({"session": session, "id": i})).collect();
    let run_id = run(app, runner, runs, &agent, &prompt, &scripts::s(&repo), items)?;
    for id in item_ids {
        let _ = runner.run(
            "items.py",
            &["fix".into(), session.into(), id.clone(), "--state".into(), "fixing".into(), "--agent".into(), agent.clone(), "--run-id".into(), run_id.clone()],
            None,
            Duration::from_secs(20),
        );
    }
    Ok(json!({"run_id": run_id, "agent": agent, "repo": scripts::s(&repo)}))
}

/// The background "process this recording" run (same wording as the macOS app's AgentHub / Snap).
pub fn process_prompt(session: &Path) -> String {
    let shots = session.join("shots.jsonl").is_file() && !session.join("recording.mp4").is_file();
    let tail = "This is an unattended background run started by the Blurt app: don't ask questions and don't start the review \
                page (the app opens it as soon as items.json appears); write items.json, then summarise in 2–3 sentences.";
    if shots {
        format!(
            "Use the blurt skill to process this batch of screenshots: {}\nIt is a shots session (mode: shots, no video): each shot \
             anchors one item and is that item's primary frame; transcribe voice notes first; .marked.png files already carry the \
             user's ink.\n{tail}",
            session.display()
        )
    } else {
        format!("Use the blurt skill to process this recording: {}\n{tail}", session.display())
    }
}

pub fn process_session(app: &AppHandle, runner: &Runner, runs: &Arc<Runs>, session: &str, agent: Option<String>) -> Result<Value, String> {
    let sdir = PathBuf::from(session);
    let repo = paths::repo_of_session(&sdir).unwrap_or_else(|| sdir.clone());
    let agent = match agent {
        Some(a) => a,
        None => detect(runner)?.get("pick").and_then(Value::as_str).map(str::to_owned).ok_or("no coding agent is installed and logged in (Settings → Agents)")?,
    };
    let run_id = run(app, runner, runs, &agent, &process_prompt(&sdir), &scripts::s(&repo), vec![json!({"session": session})])?;
    Ok(json!({"run_id": run_id, "agent": agent}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn run_id_shape() {
        let r = new_run_id();
        assert_eq!(r.len(), "r-20261021-101500-ab12".len(), "{r}");
        assert!(r.starts_with("r-20"));
        assert_eq!(civil_from_days(0), (1970, 1, 1));
        assert_eq!(civil_from_days(20_747), (2026, 10, 21));
    }
}
