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

use crate::jobs::{self, JobWriter};
use crate::scripts::{self, Runner, ScriptError};
use crate::{l10n, paths, projects, pty, AppState};

pub fn detect(runner: &Runner) -> Result<Value, String> {
    detect_with(runner, true, None)
}

/// `agents.py detect`: `login` false = no sign-in probes (fast: the hand-off panel's first frame); `ids` = only these
/// agents (the panel probes the chosen one first, as the Mac's DispatchModel does).
pub fn detect_with(runner: &Runner, login: bool, ids: Option<&[String]>) -> Result<Value, String> {
    let mut args = vec!["detect".to_string()];
    if !login {
        args.push("--no-login".into());
    }
    if let Some(ids) = ids.filter(|i| !i.is_empty()) {
        args.extend(["--ids".into(), ids.join(",")]);
    }
    runner.run("agents.py", &args, None, Duration::from_secs(90)).map_err(String::from)
}

/// A sessions.py failure for the UI: its message with the machine code at the end (`… [already_dispatched]`, what
/// `errText` reads), and what the CLI said besides the code (`job`, `version`, `need`, `fix`, `item_id`, `agent`) as
/// one JSON object just before it — the hand-off panel's ways out need them (Open Its Session, the update command).
fn rich(e: ScriptError) -> String {
    let last = e.stdout.lines().rev().find_map(|l| serde_json::from_str::<Value>(l.trim()).ok().filter(Value::is_object));
    let Some(mut o) = last else { return e.message };
    let Some(code) = o.get("code").and_then(Value::as_str).map(str::to_owned) else { return e.message };
    let m = o.as_object_mut().unwrap();
    for k in ["ok", "error", "code"] {
        m.remove(k);
    }
    if m.is_empty() {
        return e.message;
    }
    let base = e.message.strip_suffix(&format!(" [{code}]")).unwrap_or(&e.message).to_string();
    format!("{base} {} [{code}]", Value::Object(m.clone()))
}

fn sessions(runner: &Runner, args: &[String], secs: u64) -> Result<Value, String> {
    runner.run("sessions.py", args, None, Duration::from_secs(secs)).map_err(rich)
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
    /// the panel just probed the agent's sign-in: sessions.py needn't check again
    pub force: bool,
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
    if o.force {
        args.push("--force".into());
    }
    args.extend(["--lang".into(), l10n::short_lang().into()]);
    let r = sessions(runner, &args, 90)?;
    if !o.dry_run {
        launch(app, &r);
        open_links(app, &r);
    }
    Ok(r)
}

/// Start what sessions.py left for the app runner (`launch`: no tmux) in our own ptys.
pub fn launch(app: &AppHandle, r: &Value) {
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

/// Windows: does an app open this kind of file? A session's .diff has none by default, and opening it then shows the
/// "Open with" chooser (dogfood WW51): the caller opens it in Notepad instead. Folders always open (Explorer).
#[cfg(windows)]
pub fn has_handler(path: &str) -> bool {
    use windows::core::{HSTRING, PCWSTR};
    use windows::Win32::UI::Shell::{AssocQueryStringW, ASSOCF_INIT_IGNOREUNKNOWN, ASSOCSTR_EXECUTABLE};
    let p = Path::new(path);
    if p.is_dir() {
        return true;
    }
    let Some(ext) = p.extension().and_then(|e| e.to_str()) else { return false };
    let ext = HSTRING::from(format!(".{ext}"));
    let mut len = 0u32;
    // only the length is asked for: S_FALSE with it when an app is registered, an error when none is
    let hr = unsafe { AssocQueryStringW(ASSOCF_INIT_IGNOREUNKNOWN, ASSOCSTR_EXECUTABLE, &ext, PCWSTR::null(), None, &mut len) };
    hr.is_ok() && len > 0
}

pub fn list(runner: &Runner, all: bool) -> Result<Value, String> {
    let mut args = vec!["list".to_string()];
    if all {
        args.push("--all".into());
    }
    runner.run("sessions.py", &args, None, Duration::from_secs(30)).map_err(String::from)
}

/// diff | merge | pr | discard | keep. `expect` (merge / pr): the diff's `reviewed` token — what the user saw; a
/// worktree that changed since is refused (code changed), so nothing lands unreviewed.
pub fn finish(runner: &Runner, job: &str, action: &str, expect: Option<&str>) -> Result<Value, String> {
    let t = if action == "pr" { 180 } else { 90 };
    let mut args = vec!["finish".to_string(), job.to_string(), "--action".into(), action.into()];
    if let Some(x) = expect.filter(|x| !x.is_empty() && matches!(action, "merge" | "pr")) {
        args.extend(["--expect".into(), x.into()]);
    }
    sessions(runner, &args, t)
}

/// Interrupt (kill false) / End Session (kill true). A tmux window gets sessions.py's Control-C (twice, then it waits
/// for the window). The app runner's agent gets the same keys here, in its pty; End Session ends the process when
/// they weren't enough. Then `sessions.py stop` marks the job as the user's stop (cancelled).
pub fn stop(app: &AppHandle, runner: &Runner, job: &str, kill: bool) -> Result<Value, String> {
    end_pty(app, job, kill);
    let mut args = vec!["stop".to_string(), job.to_string()];
    if kill {
        args.push("--kill".into());
    }
    sessions(runner, &args, 30)
}

/// The app runner's agent, as the user stopping it: Control-C twice (as sessions.py sends into a tmux window), then —
/// `kill` — its process when that wasn't enough. Its exit isn't reported as the agent's own (pty.rs user_stop).
fn end_pty(app: &AppHandle, job: &str, kill: bool) {
    if !pty::running(app, job) {
        return;
    }
    pty::interrupt_job(app, job);
    std::thread::sleep(Duration::from_millis(400));
    pty::interrupt_job(app, job);
    let gone = |secs: u64| {
        let t = std::time::Instant::now();
        while t.elapsed() < Duration::from_secs(secs) {
            if !pty::running(app, job) {
                return true;
            }
            std::thread::sleep(Duration::from_millis(100));
        }
        false
    };
    if !gone(3) && kill {
        pty::kill_job(app, job);
        gone(5);
    }
}

pub fn open_external(runner: &Runner, job: &str, terminal: Option<&str>) -> Result<Value, String> {
    let mut args = vec!["open-external".to_string(), job.to_string()];
    if let Some(t) = terminal.filter(|t| !t.is_empty()) {
        args.extend(["--terminal".into(), t.into()]);
    }
    sessions(runner, &args, 20)
}

/// Restart Session (SessionRecovery): the same items, agent and model in a fresh session; an app-runner one starts
/// here right away.
pub fn restart(app: &AppHandle, runner: &Runner, job: &str) -> Result<Value, String> {
    let r = sessions(runner, &["restart".into(), job.into(), "--lang".into(), l10n::short_lang().into()], 120)?;
    launch(app, &r);
    open_links(app, &r); // a desktop session starts there again
    Ok(r)
}

/// Take Back: the items still with the session back to To Do (`sessions.py take-back`) → {taken_back, has_changes?}.
pub fn take_back(runner: &Runner, job: &str) -> Result<Value, String> {
    sessions(runner, &["take-back".into(), job.into()], 60)
}

// ------------------------------------------------------------------ the agent's desktop app (DesktopApp.swift)
//
// agents.json interactive.desktop (Claude): Blurt never sends anything in the app — a hand-off opens its claude://
// link, which fills in a new conversation; the user confirms the folder and presses Send. Installed = one of
// desktop.app.windows exists (the Squirrel install under %LOCALAPPDATA%\AnthropicClaude, a per-user install under
// Programs, the Store / MSIX package's data folder) or its protocol is registered (HKCU / HKLM Software\Classes\claude).
// Untested on a Windows machine from here: the paths and the package name are Anthropic's current ones as far as
// known; the protocol check is what makes it work for an install elsewhere.

fn desktop_specs(runner: &Runner) -> Vec<(String, Value)> {
    let Some(f) = runner.scripts.as_ref().map(|d| d.join("agents.json")) else { return Vec::new() };
    let v = crate::settings::read_json(&f).unwrap_or(Value::Null);
    v["agents"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|a| {
            let d = &a["interactive"]["desktop"];
            (d["url"].is_string()).then(|| (a["id"].as_str().unwrap_or("").to_string(), d.clone()))
        })
        .collect()
}

/// "${LOCALAPPDATA}/x" and "%LOCALAPPDATA%\x" → the path ("" when a variable isn't set).
pub fn expand_env(p: &str) -> String {
    let mut out = String::new();
    let mut rest = p;
    while let Some(i) = rest.find(['$', '%']) {
        out.push_str(&rest[..i]);
        let tail = &rest[i..];
        let (name, used) = if let Some(t) = tail.strip_prefix("${") {
            match t.find('}') {
                Some(e) => (&t[..e], e + 3),
                None => ("", 0),
            }
        } else if let Some(t) = tail.strip_prefix('%') {
            match t.find('%') {
                Some(e) if e > 0 => (&t[..e], e + 2),
                _ => ("", 0),
            }
        } else {
            ("", 0)
        };
        if used == 0 {
            out.push_str(&tail[..1]);
            rest = &tail[1..];
            continue;
        }
        match std::env::var(name) {
            Ok(v) if !v.is_empty() => out.push_str(&v),
            _ => return String::new(),
        }
        rest = &tail[used..];
    }
    out.push_str(rest);
    out
}

/// A path, its last part may end in "*" (a package folder: Claude_<publisher id>).
pub fn path_matches(p: &str) -> bool {
    if p.is_empty() {
        return false;
    }
    let path = Path::new(p);
    let name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    match name.strip_suffix('*') {
        Some(prefix) => path
            .parent()
            .and_then(|d| std::fs::read_dir(d).ok())
            .is_some_and(|rd| rd.flatten().any(|e| e.file_name().to_string_lossy().starts_with(prefix))),
        None => path.exists(),
    }
}

#[cfg(windows)]
fn protocol_registered(proto: &str) -> bool {
    use windows::core::PCWSTR;
    use windows::Win32::Foundation::ERROR_SUCCESS;
    use windows::Win32::System::Registry::{RegGetValueW, HKEY_CURRENT_USER, HKEY_LOCAL_MACHINE, RRF_RT_REG_SZ};
    if proto.is_empty() {
        return false;
    }
    let wide = |s: &str| s.encode_utf16().chain(std::iter::once(0)).collect::<Vec<u16>>();
    let (k, n) = (wide(&format!(r"Software\Classes\{proto}")), wide("URL Protocol"));
    [HKEY_CURRENT_USER, HKEY_LOCAL_MACHINE].into_iter().any(|root| {
        let mut size: u32 = 0;
        let r = unsafe {
            RegGetValueW(root, PCWSTR(k.as_ptr()), PCWSTR(n.as_ptr()), RRF_RT_REG_SZ, None, None, Some(&mut size as *mut u32))
        };
        r == ERROR_SUCCESS
    })
}

fn desktop_installed(spec: &Value) -> bool {
    if cfg!(not(windows)) {
        return false; // the Tauri app's other platform, Linux, has no Claude desktop
    }
    let paths: Vec<String> = match &spec["app"]["windows"] {
        Value::String(p) => vec![p.clone()],
        Value::Array(a) => a.iter().filter_map(|v| v.as_str().map(str::to_owned)).collect(),
        _ => Vec::new(),
    };
    if paths.iter().any(|p| path_matches(&expand_env(p))) {
        return true;
    }
    #[cfg(windows)]
    {
        return protocol_registered(spec["protocol"].as_str().unwrap_or(""));
    }
    #[allow(unreachable_code)]
    false
}

/// The agents with a desktop app → {id: {name, available, continue}} (the hand-off sheet's "Runs in", the session's
/// "Continue in Claude Desktop…", the desktop card's "Go to Claude").
pub fn desktop_apps(runner: &Runner) -> Value {
    let mut m = serde_json::Map::new();
    for (id, d) in desktop_specs(runner) {
        m.insert(id, json!({"name": d["name"], "available": desktop_installed(&d), "continue": d["continue"]["argv"].is_array()}));
    }
    Value::Object(m)
}

fn test_commands() -> bool {
    std::env::var("BLURT_TEST_COMMANDS").as_deref() == Ok("1")
}

/// A hand-off's link (dispatch / restart with --runner desktop): only the app's own scheme; nothing opens under
/// BLURT_TEST_COMMANDS (test runs never reach the user's real Claude).
fn open_links(app: &AppHandle, r: &Value) {
    use tauri_plugin_opener::OpenerExt;
    for row in r["jobs"].as_array().into_iter().flatten() {
        let Some(url) = row["url"].as_str() else { continue };
        if !url.starts_with("claude://") || test_commands() {
            eprintln!("blurt: desktop link for {} not opened ({} chars)", row["id"], url.len());
            continue;
        }
        if let Err(e) = app.opener().open_url(url, None::<&str>) {
            eprintln!("blurt: opening the desktop link: {e}");
        }
    }
}

/// Go to Claude: the app comes forward (its `open` link; Blurt has no link to a conversation already started).
pub fn go_desktop(app: &AppHandle, runner: &Runner, agent: &str) -> Result<(), String> {
    use tauri_plugin_opener::OpenerExt;
    let spec = desktop_specs(runner).into_iter().find(|(id, _)| id == agent).map(|(_, d)| d).ok_or("no desktop app [no_desktop]")?;
    let url = spec["open"].as_str().filter(|u| u.starts_with("claude://")).ok_or("no desktop app [no_desktop]")?;
    if test_commands() {
        return Ok(());
    }
    app.opener().open_url(url, None::<&str>).map_err(|e| e.to_string())
}

/// `sessions.py desktop-check`: may a running session of `agent` continue in its desktop app.
pub fn desktop_check(runner: &Runner, agent: &str) -> Result<Value, String> {
    sessions(runner, &["desktop-check".into(), "--agent".into(), agent.into()], 45)
}

/// Continue in Claude Desktop: a tmux session in one step (sessions.py ends its window). The app runner's (Windows)
/// in two: sessions.py checks and marks it moved, the app ends the agent in its pty, then sessions.py resumes the
/// conversation in the desktop app.
pub fn continue_desktop(app: &AppHandle, runner: &Runner, job: &str, without_mcp: bool) -> Result<Value, String> {
    let j = jobs::load(job).ok_or("this session no longer exists [no_job]")?;
    let mut args = vec!["continue-desktop".to_string(), job.to_string()];
    if without_mcp {
        args.push("--without-mcp".into());
    }
    if j["agent"]["runner"] != "app" {
        return sessions(runner, &args, 120);
    }
    args.extend(["--stage".into(), "prepare".into()]);
    sessions(runner, &args, 90)?;
    end_pty(app, job, true);
    sessions(runner, &["continue-desktop".into(), job.into(), "--stage".into(), "launch".into()], 60)
}

// ------------------------------------------------------------------ the sessions pane's rows

/// Ended sessions stay listed this long (worktrees waiting for merge / PR / discard stay until finished).
const KEEP_ENDED_SECS: i64 = 24 * 3600;

/// `$BLURT_HOME/ui/terminal.json` (the Mac's PaneMemory, the same file): what each pane showed last, and the sessions
/// removed from the list (Remove Session).
fn memory_file() -> PathBuf {
    paths::blurt_home().join("ui").join("terminal.json")
}

fn memory() -> Value {
    crate::settings::read_json(&memory_file()).filter(Value::is_object).unwrap_or_else(|| json!({}))
}

fn write_memory(v: &Value) -> Result<(), String> {
    let f = memory_file();
    if let Some(d) = f.parent() {
        std::fs::create_dir_all(d).map_err(|e| e.to_string())?;
    }
    let tmp = f.with_extension(format!("json.{}.tmp", std::process::id()));
    std::fs::write(&tmp, serde_json::to_vec_pretty(v).unwrap_or_default()).map_err(|e| e.to_string())?;
    std::fs::rename(&tmp, &f).map_err(|e| e.to_string())
}

/// The pane `pane` now shows `job` (a relaunched app reattaches to it).
pub fn remember(pane: &str, job: &str) -> Result<(), String> {
    let mut m = memory();
    if m["panes"][pane] == json!(job) {
        return Ok(());
    }
    if !m["panes"].is_object() {
        m["panes"] = json!({});
    }
    m["panes"][pane] = json!(job);
    write_memory(&m)
}

/// Remove Session: out of the list for good (its folder was gone and nothing is left with it).
pub fn forget(job: &str) -> Result<(), String> {
    let mut m = memory();
    let mut removed: Vec<String> = m["removed"].as_array().into_iter().flatten().filter_map(|v| v.as_str().map(str::to_owned)).collect();
    if !removed.iter().any(|r| r == job) {
        removed.push(job.to_string());
        removed.sort();
    }
    m["removed"] = json!(removed);
    write_memory(&m)
}

/// The items an agent job works on, as the hand-off note names them ([{id, title}], none when it has no note).
pub fn job_labels(j: &Value) -> Vec<Value> {
    j["agent"]["handoff"]
        .as_str()
        .filter(|h| !h.is_empty())
        .and_then(|h| std::fs::read_to_string(paths::handoff_dir().join(format!("{h}.md"))).ok())
        .map(|t| handoff_labels(&t))
        .unwrap_or_default()
}

/// The main window's jobs with an agent session's item labels (its rows show the first item's id and title, as the
/// Mac's JobRow does).
pub fn with_labels(mut list: Vec<Value>) -> Vec<Value> {
    for j in list.iter_mut().filter(|j| j["type"] == "agent") {
        let l = job_labels(j);
        j["labels"] = json!(l);
    }
    list
}

/// `$BLURT_HOME/handoff/<H>.md` → its "## 1. BA-12 · Title" headings ([{id, title}]).
pub fn handoff_labels(text: &str) -> Vec<Value> {
    let mut out = Vec::new();
    for line in text.lines() {
        let Some(rest) = line.strip_prefix("## ") else { continue };
        let rest = rest.trim_start();
        let Some(dot) = rest.find(". ") else { continue };
        if dot == 0 || !rest[..dot].chars().all(|c| c.is_ascii_digit()) {
            continue;
        }
        let rest = rest[dot + 2..].trim_start();
        let Some((id, title)) = rest.split_once(" · ") else { continue };
        let id = id.trim();
        if id.is_empty() || id.contains(char::is_whitespace) {
            continue;
        }
        out.push(json!({"id": id, "title": title.trim()}));
    }
    out
}

fn secs_since(v: &Value) -> Option<i64> {
    let t = chrono::DateTime::parse_from_rfc3339(v.as_str()?).ok()?;
    Some((chrono::Utc::now() - t.with_timezone(&chrono::Utc)).num_seconds())
}

/// Is a session listed (SessionsModel.rebuild): live; a worktree not finished yet; ended within a day.
pub fn keep_row(j: &Value) -> bool {
    let a = &j["agent"];
    if jobs::is_active(j) || (a["worktree"].is_object() && a["finish"].is_null()) {
        return true;
    }
    let at = [&j["ended"], &j["updated"], &j["created"]].into_iter().find(|v| v.is_string()).cloned().unwrap_or(Value::Null);
    secs_since(&at).is_some_and(|s| s < KEEP_ENDED_SECS)
}

/// The terminal apps open-external can use here (Linux, tmux sessions) → [{id, name}]; none on Windows, where a
/// session runs in Blurt's own ConPTY and no other terminal can attach to it.
fn external_terminals() -> Vec<Value> {
    if cfg!(any(windows, target_os = "macos")) {
        return Vec::new();
    }
    let path = scripts::agent_environment().get("PATH").cloned().unwrap_or_default();
    let found = |exe: &str| std::env::split_paths(&path).any(|d| d.join(exe).is_file());
    [("gnome-terminal", "GNOME Terminal"), ("konsole", "Konsole"), ("wezterm", "WezTerm"), ("kitty", "kitty")]
        .iter()
        .filter(|(id, _)| found(id))
        .map(|(id, name)| json!({"id": id, "name": name}))
        .collect()
}

/// When this app started: an app-runner job from before then that no pty of ours runs ended with the last Blurt.
/// The organising agents running now (job, pid, its writer): they end with the app, as the Mac's do.
static ORGANISING: Mutex<Vec<(String, u32, Arc<JobWriter>)>> = Mutex::new(Vec::new());
static QUITTING: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

/// Quit: end every organising agent (its whole process tree) and mark its job stopped, so it neither runs on without
/// the app nor shows "running" for good on the next start. Its captures stay where they were (sort them again).
pub fn end_organising() {
    QUITTING.store(true, std::sync::atomic::Ordering::SeqCst);
    let all: Vec<(String, u32, Arc<JobWriter>)> = ORGANISING.lock().unwrap().drain(..).collect();
    for (_, pid, job) in all {
        let pid = pid.to_string();
        #[cfg(unix)]
        let _ = std::process::Command::new("kill").args(["-TERM", "--", &format!("-{pid}")]).stderr(Stdio::null()).status();
        #[cfg(windows)]
        let _ = scripts::command(&["taskkill".into(), "/T".into(), "/F".into(), "/PID".into(), pid]).stdout(Stdio::null()).stderr(Stdio::null()).status();
        job.finish("cancelled", None);
    }
}

static STARTED: std::sync::OnceLock<chrono::DateTime<chrono::Utc>> = std::sync::OnceLock::new();
static ORPHANS_SEEN: Mutex<Vec<String>> = Mutex::new(Vec::new());

/// An app-runner session (Windows: always) ends when Blurt quits, and its exit may not have been reported on the way
/// out. Once per launch, such a job still marked running is reported as having exited (`sessions.py event
/// --event pane-dead`), so it shows its ended card — Restart Session, Take Back — instead of a spinner that never stops.
fn orphaned(app: &AppHandle, j: &Value, owned: &[String]) -> bool {
    let id = j["id"].as_str().unwrap_or("");
    let before = j["created"]
        .as_str()
        .and_then(|c| chrono::DateTime::parse_from_rfc3339(c).ok())
        .zip(STARTED.get())
        .is_some_and(|(c, s)| c.with_timezone(&chrono::Utc) < *s);
    if j["agent"]["runner"] != "app" || !jobs::is_active(j) || owned.iter().any(|o| o == id) || !before {
        return false;
    }
    let mut seen = ORPHANS_SEEN.lock().unwrap();
    if seen.iter().any(|s| s == id) {
        return true;
    }
    seen.push(id.to_string());
    let (app, id) = (app.clone(), id.to_string());
    std::thread::spawn(move || {
        let runner = app.state::<AppState>().runner();
        let args = vec!["event".into(), "--job".into(), id, "--event".into(), "pane-dead".into(), "--exit".into(), "0".into()];
        if let Err(e) = runner.run("sessions.py", &args, None, Duration::from_secs(20)) {
            eprintln!("blurt: sessions.py event (app runner gone): {e}");
        }
    });
    true
}

/// The sessions pane's rows (contract K5, as the Mac's SessionsModel reads JobStore): every listed agent job's
/// effective state, plus what the page can't read itself — the hand-off sheet's item labels, whether a worktree's
/// folder is still there, the log, whether the app runs it — and the pane memory.
/// → {jobs: [Job + {labels, folder_gone, log, handoff_path, owned, output}], panes, terminals, preferred_terminal}
pub fn rows(app: &AppHandle) -> Value {
    let removed: Vec<String> = memory()["removed"].as_array().into_iter().flatten().filter_map(|v| v.as_str().map(str::to_owned)).collect();
    let owned = pty::owned_jobs(app);
    let ptys = app.state::<pty::Ptys>();
    let mut out = Vec::new();
    for mut j in jobs::list(false, 400) {
        if j["type"] != "agent" || !j["agent"].is_object() || !keep_row(&j) {
            continue;
        }
        if orphaned(app, &j, &owned) {
            // it ended with the last Blurt: say so now, as the event will
            j["state"] = json!("done");
            j["agent"]["status"] = json!("exited");
            j["ended"] = j["updated"].clone();
        }
        let id = j["id"].as_str().unwrap_or("").to_string();
        if removed.contains(&id) {
            continue;
        }
        let a = &j["agent"];
        let labels = a["handoff"]
            .as_str()
            .filter(|h| !h.is_empty())
            .and_then(|h| std::fs::read_to_string(paths::handoff_dir().join(format!("{h}.md"))).ok())
            .map(|t| handoff_labels(&t))
            .unwrap_or_default();
        let handoff_path = a["handoff"].as_str().filter(|h| !h.is_empty()).map(|h| scripts::s(&paths::handoff_dir().join(format!("{h}.md"))));
        let folder_gone = a["worktree"]["path"].as_str().is_some_and(|p| !Path::new(p).is_dir());
        let log = paths::jobs_dir().join(format!("{id}.log"));
        j["labels"] = json!(labels);
        j["folder_gone"] = json!(folder_gone);
        j["log"] = if log.is_file() { json!(scripts::s(&log)) } else { Value::Null };
        j["handoff_path"] = json!(handoff_path);
        j["owned"] = json!(owned.contains(&id));
        j["output"] = json!(ptys.owned_replay(&id).is_some());
        out.push(j);
    }
    let cfg = crate::settings::read_config();
    json!({
        "jobs": out,
        "panes": memory()["panes"].clone(),
        "terminals": external_terminals(),
        "preferred_terminal": cfg.pointer("/terminal/external").cloned().unwrap_or(Value::Null),
        "font_size": cfg.pointer("/terminal/font_size").cloned().unwrap_or(Value::Null),
        "desktop": desktop_apps(&app.state::<AppState>().runner()),
    })
}

// ------------------------------------------------------------------ status notifications (SessionNotifier)

/// The same kind within 10 s: one notification listing them all (kind → when, its lines).
static RECENT: Mutex<Option<std::collections::HashMap<String, (std::time::Instant, Vec<String>)>>> = Mutex::new(None);

/// One quiet system notification when a session starts waiting for the user, finishes a turn, ends or fails, and
/// Blurt isn't in front (the caller checks that and config notify.agent): "Needs your input · bug-agent" /
/// "BA-12 · Login button does nothing". The same kind within 10 s → "2 sessions need your input", one line each.
/// → (title, body), what was shown.
pub fn notify_text(job: &Value, status: &str) -> (String, String, String) {
    let a = &job["agent"];
    let pid = job["project"].as_str().unwrap_or("inbox");
    let project = if pid == "blurt-setup" {
        l10n::t("notify.session.setup")
    } else if pid == "inbox" {
        projects::inbox_row()["name"].as_str().unwrap_or("").to_string()
    } else {
        projects::Registry::load().project(pid).and_then(|p| p["name"].as_str()).map(str::to_owned).unwrap_or_else(|| {
            a["cwd"].as_str().and_then(|c| Path::new(c).file_name()).map(|n| n.to_string_lossy().into_owned()).unwrap_or_default()
        })
    };
    let labels = a["handoff"]
        .as_str()
        .filter(|h| !h.is_empty())
        .and_then(|h| std::fs::read_to_string(paths::handoff_dir().join(format!("{h}.md"))).ok())
        .map(|t| handoff_labels(&t))
        .unwrap_or_default();
    let head = labels
        .first()
        .map(|l| format!("{} · {}", l["id"].as_str().unwrap_or(""), l["title"].as_str().unwrap_or("")))
        .unwrap_or_else(|| a["tmux"]["name"].as_str().unwrap_or("").to_string());
    let more = if labels.len() > 1 { format!(" {}", l10n::tf("notify.session.more", &[("n", (labels.len() - 1).to_string())])) } else { String::new() };
    let title = l10n::tf(&format!("notify.session.{status}"), &[("project", project.clone())]);
    let mut body = format!("{head}{more}");
    if status == "waiting_input" {
        if let Some(m) = a["status_message"].as_str().filter(|m| !m.is_empty()) {
            body.push('\n');
            body.push_str(m);
        }
    }
    if status == "error" {
        body.push('\n');
        body.push_str(&l10n::t("notify.session.exit"));
    }
    (title, body, format!("{project} · {head}"))
}

/// Show a session's notification (silent). On Windows it's a WinRT toast whose click brings Blurt forward on that
/// session (blurt://job/<id>, as SessionNotifier's click does on the Mac): the notification plugin's toasts can't say
/// they were clicked there. Elsewhere, and if the toast can't be shown, the plugin's notification.
pub fn show_notification(app: &AppHandle, title: &str, body: &str, job: &str) {
    #[cfg(windows)]
    {
        if toast(app, title, body, job).is_ok() {
            return;
        }
    }
    let _ = job;
    use tauri_plugin_notification::NotificationExt;
    let _ = app.notification().builder().title(title).body(body).silent().show();
}

/// The toast: the installed app's AppUserModelID (the bundle identifier, as tauri-plugin-notification sets it), or
/// PowerShell's for a build run from target\ (an unregistered id shows nothing). Untested on Windows from this Mac:
/// a click on the toast on screen opens the session; a click in the notification centre after Blurt dropped the
/// toast may only bring Blurt forward.
#[cfg(windows)]
fn toast(app: &AppHandle, title: &str, body: &str, job: &str) -> Result<(), String> {
    use tauri_winrt_notification::Toast;
    let dev = std::env::current_exe()
        .ok()
        .and_then(|e| e.parent().map(|d| d.ends_with("target\\debug") || d.ends_with("target\\release")))
        .unwrap_or(false);
    let id = if dev { Toast::POWERSHELL_APP_ID.to_string() } else { app.config().identifier.clone() };
    let mut lines = body.splitn(2, '\n');
    let (a, b) = (lines.next().unwrap_or(""), lines.next().unwrap_or(""));
    let (app2, url) = (app.clone(), format!("blurt://job/{job}"));
    let mut t = Toast::new(&id).title(title).text1(a).sound(None);
    if !b.is_empty() {
        t = t.text2(b);
    }
    t.on_activated(move |_| {
            crate::handle_url(&app2, &url);
            Ok(())
        })
        .show()
        .map_err(|e| e.to_string())
}

/// Merge with what was said of the same kind in the last 10 s → the title and body to show now.
pub fn merge_recent(status: &str, title: String, body: String, line: String) -> (String, String) {
    let mut g = RECENT.lock().unwrap();
    let m = g.get_or_insert_with(Default::default);
    let now = std::time::Instant::now();
    let mut lines = vec![line];
    let mut out = (title, body);
    if let Some((at, prev)) = m.get(status) {
        if at.elapsed() < Duration::from_secs(10) {
            lines = prev.iter().cloned().chain(lines).collect();
            out = (l10n::plural(&format!("notify.session.many.{status}"), lines.len() as i64, &[]), lines.join("\n"));
        }
    }
    m.insert(status.to_string(), (now, lines));
    out
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
    let _ = STARTED.set(chrono::Utc::now());
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
    let mut c = scripts::daemon_command(&argv); // its own process group: quitting ends it and what it started
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
    ORGANISING.lock().unwrap().push((id.clone(), child.id(), job.clone()));
    let (app2, session) = (app.clone(), session.to_path_buf());
    std::thread::spawn(move || {
        let code = child.wait().ok().and_then(|s| s.code());
        ORGANISING.lock().unwrap().retain(|(j, ..)| j != &job.id);
        if QUITTING.load(std::sync::atomic::Ordering::SeqCst) {
            return; // end_organising said how it ended
        }
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
    fn handoff_headings() {
        let md = "# Hand-off H-0031\n\n## 1. SF-9 · Avatar upload returns 500\nbody\n## 2. SF-12 · Checkout · Safari\n## Notes\n## 3. two words · x\n";
        let l = handoff_labels(md);
        assert_eq!(l, vec![json!({"id": "SF-9", "title": "Avatar upload returns 500"}), json!({"id": "SF-12", "title": "Checkout · Safari"})]);
    }

    #[test]
    fn desktop_paths() {
        std::env::set_var("BLURT_T_LAD", "/tmp/lad");
        assert_eq!(expand_env("${BLURT_T_LAD}/AnthropicClaude/claude.exe"), "/tmp/lad/AnthropicClaude/claude.exe");
        assert_eq!(expand_env("%BLURT_T_LAD%\\Programs"), "/tmp/lad\\Programs");
        assert_eq!(expand_env("${BLURT_T_NOPE}/x"), "");
        assert_eq!(expand_env("100% sure"), "100% sure");
        let d = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(d.path().join("Packages/Claude_pzs8sxrjxfjjc")).unwrap();
        assert!(path_matches(&format!("{}/Packages/Claude_*", d.path().display())));
        assert!(!path_matches(&format!("{}/Packages/Codex_*", d.path().display())));
        assert!(!path_matches(""));
    }

    #[test]
    fn rows_kept() {
        let now = chrono::Utc::now();
        let iso = |s: i64| (now - chrono::Duration::seconds(s)).to_rfc3339();
        assert!(keep_row(&json!({"state": "running", "agent": {}})));
        assert!(keep_row(&json!({"state": "done", "ended": iso(90_000), "agent": {"worktree": {"path": "/w"}, "finish": null}})));
        assert!(!keep_row(&json!({"state": "done", "ended": iso(90_000), "agent": {"worktree": {"path": "/w"}, "finish": {"action": "merge"}}})));
        assert!(keep_row(&json!({"state": "failed", "ended": iso(3_600), "agent": {}})));
        assert!(!keep_row(&json!({"state": "failed", "ended": iso(90_000), "agent": {}})));
    }

    #[test]
    fn errors_keep_what_the_cli_said() {
        let e = ScriptError {
            code: Some(1),
            message: "sessions.py dispatch: SF-9 is already in a session [already_dispatched]".into(),
            stdout: "{\"ok\": false, \"error\": \"SF-9 is already in a session\", \"code\": \"already_dispatched\", \"job\": \"j-1\"}\n".into(),
            stderr: String::new(),
        };
        let m = rich(e);
        assert!(m.ends_with(" [already_dispatched]") && m.contains(r#"{"job":"j-1"}"#), "{m}");
        let plain = ScriptError { code: Some(1), message: "x: y [gone]".into(), stdout: "{\"ok\":false,\"code\":\"gone\",\"error\":\"y\"}".into(), stderr: String::new() };
        assert_eq!(rich(plain), "x: y [gone]");
    }

    #[test]
    fn error_codes() {
        assert_eq!(error_code("Error: Not logged in · Please run /login"), "auth");
        assert_eq!(error_code("429 rate limit exceeded"), "quota");
        assert_eq!(error_code("getaddrinfo ENOTFOUND api.anthropic.com"), "network");
        assert_eq!(error_code("panic"), "unknown");
    }
}
