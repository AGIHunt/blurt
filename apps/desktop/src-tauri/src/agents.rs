//! The user's coding agents, as the app uses them: which are installed (`agents.py detect`, `models`), the hand-off
//! note copied for the user's own agent (`handoff.py`, contract K6), and organising captures with an agent run
//! headless (K4 process jobs: `agents.py command <agent> headless … --processing`). We run what the Python CLIs return.
//!
//! Organising works as the Mac's (AgentHub.process / attempt / attemptEnded): the user's order of agents, the first
//! usable one runs; a run that ends on a login, quota or model problem hands the recording to the next one (said on the
//! island, kept on the job as `organizer`). The run's cwd is the session folder, never the project (agents.json _doc);
//! the project's code is named in the prompt for reading. Its prompt is skills/blurt/scripts/organize_prompt.json, the
//! text the Mac sends too. A run succeeded when it filed items (items.json / batch.json written during it), not when it
//! exited 0; one that filed none ends done with no items (the island says so). A run that goes on past
//! [`organize_timeout`] is stopped (the Mac has no limit yet).

use std::collections::BTreeSet;
use std::io::Write as _;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant, SystemTime};

use serde_json::{json, Value};
use tauri::{AppHandle, Emitter, Manager};

use crate::jobs::JobWriter;
use crate::scripts::{self, Runner};
use crate::{island, l10n, paths, projects, AppState};

/// The last full `agents.py detect` (sign-in probes, every agent) and when: a take's end reads it instead of waiting
/// on a fresh one (the Mac's AgentHub cache: 10 min while the first usable agent is signed in).
static DETECTED: Mutex<Option<(Instant, Value)>> = Mutex::new(None);

pub fn detect(runner: &Runner) -> Result<Value, String> {
    detect_with(runner, true, None)
}

/// `agents.py detect`: `login` false = no sign-in probes (fast); `ids` = only these agents (Settings probes one row).
pub fn detect_with(runner: &Runner, login: bool, ids: Option<&[String]>) -> Result<Value, String> {
    detect_fresh(runner, login, ids, false)
}

/// … `fresh`: look for the agents' apps again (else kept 10 minutes by agents.py).
pub fn detect_fresh(runner: &Runner, login: bool, ids: Option<&[String]>, fresh: bool) -> Result<Value, String> {
    let mut args = vec!["detect".to_string(), "--lang".into(), crate::l10n::short_lang().into()];
    if fresh {
        args.push("--fresh".into());
    }
    if !login {
        // the quick look is only "on PATH or not": no CLI is started (a node CLI on Windows takes seconds each)
        args.extend(["--no-login".into(), "--no-version".into()]);
    }
    let all = ids.is_none_or(<[String]>::is_empty);
    if let Some(ids) = ids.filter(|i| !i.is_empty()) {
        args.extend(["--ids".into(), ids.join(",")]);
    }
    let r = runner.run("agents.py", &args, None, Duration::from_secs(90)).map_err(String::from)?;
    if login && all {
        *DETECTED.lock().unwrap() = Some((Instant::now(), r.clone()));
    }
    Ok(r)
}

/// Forget the cached detect (a run just found its agent signed out: the next one probes again).
fn forget_detected() {
    *DETECTED.lock().unwrap() = None;
}

/// What the cache says, without probing: Some(true) = an agent was usable a moment ago (10 min while the first one is
/// signed in, 1 min otherwise), Some(false) = none was, a moment ago (1 min), None = no recent answer.
pub fn usable_cached() -> Option<bool> {
    let c = DETECTED.lock().unwrap();
    let (at, d) = c.as_ref()?;
    let (usable, _) = queue(d);
    let ttl = if usable.first().is_some_and(|a| a.state == "ready") { 600 } else { 60 };
    (at.elapsed() < Duration::from_secs(ttl)).then_some(!usable.is_empty())
}

/// Can an agent organise in the background now (the window's Retry / Organize / Set Up an Agent…)? The full detect's
/// answer — sign-in checked, the one a run starts from —: the cached one while it holds, else a fresh one.
pub fn ready(runner: &Runner) -> Result<bool, String> {
    if let Some(b) = usable_cached() {
        return Ok(b);
    }
    detect(runner).map(|d| !queue(&d).0.is_empty())
}

/// The detect a run starts from: the cached one while its first usable agent is signed in and it is under 10 min old,
/// else a fresh one — every agent that wasn't ready is checked again (the user may just have signed in).
fn detect_for_run(runner: &Runner) -> Result<Value, String> {
    if let Some((at, d)) = DETECTED.lock().unwrap().clone() {
        if at.elapsed() < Duration::from_secs(600) && queue(&d).0.first().is_some_and(|a| a.state == "ready") {
            return Ok(d);
        }
    }
    detect(runner)
}

/// `agents.py models ID`: the agent's models (its own list or the CLI's cache; no network, no tokens).
pub fn models(runner: &Runner, agent: &str) -> Result<Value, String> {
    runner.run("agents.py", &["models".into(), agent.into()], None, Duration::from_secs(30)).map_err(String::from)
}

// ------------------------------------------------------------------ the hand-off note (K6)

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

// ------------------------------------------------------------------ the organising prompt (one text for both apps)

/// skills/blurt/scripts/organize_prompt.json, compiled in: the parts of the prompt, the Mac's too (OrganizerPrompt).
const PROMPT_PARTS: &str = include_str!("../../../../skills/blurt/scripts/organize_prompt.json");

fn part(key: &str) -> &'static str {
    static PARTS: OnceLock<Value> = OnceLock::new();
    PARTS.get_or_init(|| serde_json::from_str(PROMPT_PARTS).expect("organize_prompt.json")).get(key).and_then(Value::as_str).unwrap_or("")
}

/// What one organising run is about.
#[derive(Debug, Default, Clone)]
pub struct PromptInput {
    pub session: String,
    /// a shots session (snaps and voice notes, no video)
    pub shots: bool,
    /// only these captures (shots.jsonl n) of it
    pub captures: Vec<u64>,
    /// the SKILL.md the app runs
    pub skill_md: String,
    /// the scripts folder the run may call (agents.json's {scripts})
    pub scripts: String,
    /// the project's folder, to read
    pub code: Option<String>,
    /// `projects.py candidates` text (a capture with no project)
    pub candidates: Option<String>,
}

/// The parts that apply, in order, each one's placeholder filled once (a value is never searched again).
pub fn organize_prompt(i: &PromptInput) -> String {
    let mut s = part(if i.shots { "shots" } else { "recording" }).replace("{session}", &i.session);
    if !i.captures.is_empty() {
        let list: Vec<String> = i.captures.iter().map(u64::to_string).collect();
        s.push_str(&part("captures").replace("{captures}", &list.join(", ")));
    }
    s.push_str(part("run"));
    s.push_str(&part("skill").replace("{skill_md}", &i.skill_md));
    s.push_str(&scripts_hint(&i.scripts));
    if let Some(c) = i.code.as_deref().filter(|c| !c.is_empty()) {
        s.push_str(&part("code").replace("{code}", c));
    }
    if let Some(c) = i.candidates.as_deref().map(str::trim).filter(|c| !c.is_empty()) {
        s.push_str(&part("candidates").replace("{candidates}", c));
    }
    s
}

/// The line that tells an unattended run how to call the scripts (its permissions allow only that form).
pub fn scripts_hint(scripts: &str) -> String {
    part("scripts").replace("{scripts}", scripts)
}

/// A shots session: snaps and voice notes, no video (the Mac's isShotsSession).
fn is_shots(session: &Path) -> bool {
    let name = session.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    name.ends_with("-shots") || (session.join("shots.jsonl").is_file() && !session.join("recording.mp4").is_file())
}

/// The processing model's kind (agents.py --processing): a recording, or cards (snaps, voice notes).
fn processing_kind(session: &Path) -> &'static str {
    let name = session.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    if is_shots(session) || name.ends_with("-voice") {
        "cards"
    } else {
        "recording"
    }
}

/// Candidates only for a capture with no project: the run itself has none and its session is in the inbox store
/// (BlurtCore OrganizerPrompt.wantsCandidates).
pub fn wants_candidates(run_project: Option<&str>, session_project: Option<&str>) -> bool {
    run_project.is_none_or(|p| p == "inbox") && session_project.is_none_or(|p| p == "inbox")
}

// ------------------------------------------------------------------ organising (process jobs, K4)

/// The organising agents running now (job, pid, its writer): they end with the app, as the Mac's do.
static ORGANISING: Mutex<Vec<(String, u32, Arc<JobWriter>)>> = Mutex::new(Vec::new());
static QUITTING: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

/// End a run's whole process tree.
fn kill_pid(pid: u32) {
    let pid = pid.to_string();
    #[cfg(unix)]
    let _ = std::process::Command::new("kill").args(["-TERM", "--", &format!("-{pid}")]).stderr(Stdio::null()).status();
    #[cfg(windows)]
    let _ = scripts::command(&["taskkill".into(), "/T".into(), "/F".into(), "/PID".into(), pid]).stdout(Stdio::null()).stderr(Stdio::null()).status();
}

/// Quit: end every organising agent (its whole process tree) and mark its job stopped, so it neither runs on without
/// the app nor shows "running" for good on the next start. Its captures stay where they were (sort them again).
pub fn end_organising() {
    QUITTING.store(true, std::sync::atomic::Ordering::SeqCst);
    let all: Vec<(String, u32, Arc<JobWriter>)> = ORGANISING.lock().unwrap().drain(..).collect();
    for (_, pid, job) in all {
        kill_pid(pid);
        job.finish("cancelled", None);
    }
}

/// Rough cause of a failed run from the tail of its output (K4 error codes), when `agents.py classify` can't say.
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

/// An agent of the user's order, as detect saw it.
#[derive(Debug, Clone, PartialEq)]
pub struct Agent {
    pub id: String,
    pub name: String,
    pub state: String,
}

fn usable_state(s: &str) -> bool {
    matches!(s, "ready" | "configured" | "unknown")
}

/// detect → (the usable headless agents in the user's order, the ones passed over before the first of them) — the
/// Mac's AgentHub.process: `skipped` = the order's prefix that can't run, said on the island.
pub fn queue(detect: &Value) -> (Vec<Agent>, Vec<Agent>) {
    let rows: Vec<&Value> = detect["agents"].as_array().map(|a| a.iter().collect()).unwrap_or_default();
    let order: Vec<&str> = detect["order"].as_array().map(|a| a.iter().filter_map(Value::as_str).collect()).unwrap_or_default();
    let (mut usable, mut skipped) = (Vec::new(), Vec::new());
    for id in order {
        let Some(r) = rows.iter().find(|r| r["id"] == id) else { continue };
        if r["headless"] == json!(false) {
            continue;
        }
        let a = Agent {
            id: id.to_string(),
            name: r["name"].as_str().unwrap_or(id).to_string(),
            state: r["state"].as_str().unwrap_or("unknown").to_string(),
        };
        if usable_state(&a.state) {
            usable.push(a);
        } else if usable.is_empty() {
            skipped.push(a);
        }
    }
    (usable, skipped)
}

/// How long an organising run may take before it is stopped: 45 min, or three times the video's length, at most 4 h.
pub fn organize_timeout(video_secs: f64) -> Duration {
    let s = (video_secs.max(0.0) * 3.0).clamp(45.0 * 60.0, 4.0 * 3600.0);
    Duration::from_secs(s as u64)
}

/// How one attempt ended (the Mac's attemptEnded).
#[derive(Debug, Clone, PartialEq)]
pub enum Ended {
    /// it filed these items
    Filed(Vec<String>),
    /// it filed, but nothing came of it: no items
    Empty,
    /// a problem another agent wouldn't share (auth / quota / model): the next agent takes it
    Next(String),
    /// the job fails with this code (auth, quota, network, model, skill, outdated, timeout, agent_exit)
    Failed(String),
}

/// `filed`: the items it filed (None = it wrote no items.json / batch.json); `class`: agents.json's failure class
/// of its output; `more`: another usable agent is waiting.
pub fn decide(filed: Option<Vec<String>>, timed_out: bool, class: Option<&str>, more: bool) -> Ended {
    match filed {
        Some(u) if u.is_empty() => Ended::Empty,
        Some(u) => Ended::Filed(u),
        None if timed_out => Ended::Failed("timeout".into()),
        None => match class {
            Some(c @ ("auth" | "quota" | "model")) if more => Ended::Next(c.into()),
            Some(c) => Ended::Failed(c.into()),
            None => Ended::Failed("agent_exit".into()),
        },
    }
}

type Stamps = Vec<(String, Option<SystemTime>)>;

/// The files an organising run leaves (items.py ingest renames items.json and writes batch.json), as they are now.
fn files_now(session: &Path) -> Stamps {
    ["batch.json", "items.json", "items.ingested.json"]
        .iter()
        .map(|f| (f.to_string(), std::fs::metadata(session.join(f)).and_then(|m| m.modified()).ok()))
        .collect()
}

fn batch_items(session: &Path) -> Vec<String> {
    crate::settings::read_json(&session.join("batch.json"))
        .and_then(|b| b["items"].as_array().cloned())
        .unwrap_or_default()
        .iter()
        .filter_map(|v| v.as_str().map(str::to_owned))
        .collect()
}

/// What the run filed: None when it wrote none of its files; else the items it reported to the job, and the batch's
/// items that weren't there before it.
pub fn filed_items(before: &Stamps, after: &Stamps, reported: &[String], batch_before: &[String], batch_after: &[String]) -> Option<Vec<String>> {
    let wrote = after.iter().any(|(f, t)| t.is_some() && before.iter().find(|(g, _)| g == f).map(|(_, u)| u) != Some(t));
    if !wrote {
        return None;
    }
    let mut out: Vec<String> = reported.to_vec();
    let old: BTreeSet<&String> = batch_before.iter().collect();
    for u in batch_after.iter().filter(|u| !old.contains(u)) {
        if !out.contains(u) {
            out.push(u.clone());
        }
    }
    Some(out)
}

/// meta.json → "agent": who organises it and how that went (the Mac's updateMeta; the recordings list reads it).
fn note_meta(session: &Path, change: Value) {
    let f = session.join("meta.json");
    let mut m = crate::settings::read_json(&f).unwrap_or_else(|| json!({}));
    let mut a = m.get("agent").filter(|a| a.is_object()).cloned().unwrap_or_else(|| json!({}));
    if let (Some(a), Some(c)) = (a.as_object_mut(), change.as_object()) {
        for (k, v) in c {
            a.insert(k.clone(), v.clone());
        }
    }
    m["agent"] = a;
    let _ = std::fs::write(&f, serde_json::to_string_pretty(&m).unwrap_or_default());
}

fn log_path(job: &str) -> PathBuf {
    paths::jobs_dir().join(format!("{job}.log"))
}

fn log_line(job: &str, text: &str) {
    if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(log_path(job)) {
        let _ = writeln!(f, "── blurt {} · {text}", projects::iso_now());
    }
}

/// "Claude Code 未登录" / "Codex 登录失效": one agent passed over, in the user's language.
fn why(a: &Agent, class: Option<&str>, failures: &Value) -> String {
    let lang = l10n::short_lang();
    let short = match class {
        Some(c) => failures
            .as_array()
            .and_then(|f| f.iter().find(|x| x["id"] == c))
            .and_then(|x| x["short"][lang].as_str().or(x["short"]["en"].as_str()))
            .map(|s| format!(" {s}"))
            .unwrap_or_else(|| l10n::t("agent.why.unusable")),
        None => l10n::t(match a.state.as_str() {
            "not_installed" => "agent.why.not_installed",
            "logged_out" => "agent.why.logged_out",
            _ => "agent.why.unusable",
        }),
    };
    format!("{}{short}", a.name)
}

/// Another agent organises instead of the first in the user's order: said on the island, kept on the job.
fn note_fallback(app: &AppHandle, job: &JobWriter, passed: &[String], using: &Agent) {
    job.set("organizer", json!({"agent": using.id, "instead_of": passed}));
    log_line(&job.id, &format!("{} · organizing with {}", passed.join("; "), using.name));
    island::send(app, json!({"op": "toast", "kind": "capture", "msg": "rec.fallback", "key": format!("fallback.{}", job.id),
        "vars": {"why": passed.join(&l10n::t("agent.list_sep")), "agent": using.name}, "ms": 6000}));
}

/// What a run gets: the recording or batch, its captures, where its items go.
#[derive(Clone)]
struct Run {
    session: PathBuf,
    captures: Option<Vec<u64>>,
    project: Option<String>,
    parent: Option<String>,
}

/// K7 `process_captures`: file the given captures (shots.jsonl `n`) of a shots session into `project` (None = let
/// the AI sort them, item by item), or a whole recording; then organise them in a background process job.
/// `assigned_by`: write K7's assignment lines first (`user` when a card was dropped on a project or on "Unassigned");
/// None when the captures already carry their project (taken while a project was current).
/// Ok(the job) — the one already organising this recording when there is one; Err("no_agent") with no job when no
/// agent can run (the island and the window say what to do then).
pub fn process(
    app: &AppHandle,
    session: &Path,
    captures: Option<Vec<u64>>,
    project: Option<String>,
    assigned_by: Option<&str>,
    parent: Option<String>,
) -> Result<String, String> {
    if let (Some(c), Some(p), Some(by)) = (&captures, &project, assigned_by) {
        let mut f = std::fs::OpenOptions::new().append(true).create(true).open(session.join("shots.jsonl")).map_err(|e| e.to_string())?;
        for n in c {
            let line = json!({"n": n, "project": p, "assigned_by": by});
            let _ = writeln!(f, "{line}");
        }
    }
    let run = Run { session: session.to_path_buf(), captures, project, parent };
    let claim = match running_for(&run) {
        Err(id) => return Ok(id),
        Ok(c) => c,
    };
    let runner = app.state::<AppState>().runner();
    let detected = detect_for_run(&runner)?;
    begin(app, &runner, run, &detected, claim)
}

/// A take's end: returns at once (the island says "Organizing…" meanwhile); `said` gets Ok(job) once an agent
/// runs, or Err("no_agent") (no job) — on another thread.
pub fn process_take(app: &AppHandle, session: &Path, project: Option<String>, parent: Option<String>, said: impl FnOnce(Result<String, String>) + Send + 'static) {
    let app = app.clone();
    let run = Run { session: session.to_path_buf(), captures: None, project, parent };
    std::thread::spawn(move || {
        let claim = match running_for(&run) {
            Err(id) => return said(Ok(id)),
            Ok(c) => c,
        };
        let runner = app.state::<AppState>().runner();
        let r = detect_for_run(&runner).and_then(|d| begin(&app, &runner, run, &d, claim));
        said(r);
    });
}

/// Recordings a run is being set up for, before their job exists (detect alone can take 90 s): whoever asks
/// meanwhile waits for that job instead of starting a second one.
pub struct Claims {
    set: Mutex<BTreeSet<PathBuf>>,
    freed: std::sync::Condvar,
}

/// One recording claimed: released when dropped (once its job is written, or when setting it up failed).
pub struct Claim<'a> {
    claims: &'a Claims,
    key: PathBuf,
}

impl Drop for Claim<'_> {
    fn drop(&mut self) {
        self.claims.set.lock().unwrap().remove(&self.key);
        self.claims.freed.notify_all();
    }
}

impl Claims {
    pub const fn new() -> Self {
        Claims { set: Mutex::new(BTreeSet::new()), freed: std::sync::Condvar::new() }
    }

    /// Claim `key`, waiting while another run holds it; then Err(the job) when `existing` finds one already organising
    /// it (the other run's, or one from before), else Ok(the claim).
    pub fn claim(&self, key: PathBuf, existing: impl Fn() -> Option<String>) -> Result<Claim<'_>, String> {
        let mut set = self.set.lock().unwrap();
        while set.contains(&key) {
            set = self.freed.wait(set).unwrap();
        }
        set.insert(key.clone());
        drop(set);
        let claim = Claim { claims: self, key };
        match existing() {
            Some(id) => Err(id), // the claim drops here
            None => Ok(claim),
        }
    }
}

impl Default for Claims {
    fn default() -> Self {
        Self::new()
    }
}

static CLAIMS: Claims = Claims::new();

/// One organiser per recording, whatever asks (a Retry, a take's end, the list's Organize): Err(the job already
/// organising this whole recording), else Ok(this recording claimed until its job is written — None for some
/// captures of a batch, which aren't held to one run).
fn running_for(run: &Run) -> Result<Option<Claim<'static>>, String> {
    if run.captures.is_some() {
        return Ok(None);
    }
    let me = paths::normalize(&run.session);
    let existing = || {
        crate::jobs::list(true, 200)
            .into_iter()
            .find(|j| j["type"] == "process" && j["session"].as_str().is_some_and(|s| paths::normalize(Path::new(s)) == me))
            .and_then(|j| j["id"].as_str().map(str::to_owned))
    };
    CLAIMS.claim(me.clone(), existing).map(Some)
}

/// The job, its prompt, and the attempts on a thread of their own. `claim` is released once the job is written.
fn begin(app: &AppHandle, runner: &Runner, run: Run, detected: &Value, claim: Option<Claim<'static>>) -> Result<String, String> {
    let session = run.session.clone();
    let (usable, skipped) = queue(detected);
    if usable.is_empty() {
        note_meta(&session, json!({"result": "none", "at": projects::iso_now()}));
        return Err("no_agent".into());
    }
    let reg = projects::Registry::load();
    let session_project = reg.project_of_path(&session);
    let job_project = run.project.clone().filter(|p| p != "inbox").or_else(|| session_project.clone().filter(|p| p != "inbox"));
    let job = Arc::new(JobWriter::new("process", job_project.as_deref(), Some(&session), run.parent.as_deref(), None, &["prepare", "transcribe", "write", "frames", "route"]));
    drop(claim); // the job is listed now: whoever asks next finds it
    if let Some(c) = &run.captures {
        job.set_captures(c);
    }
    job.step("prepare", "running", None);
    // the prompt: the shared parts (organize_prompt.json), the project's code to read, the candidates for a capture
    // with no project
    let code = job_project.as_deref().and_then(|p| reg.project(p)).and_then(|p| p["path"].as_str()).filter(|p| Path::new(p).is_dir()).map(str::to_owned);
    let candidates = (wants_candidates(run.project.as_deref(), session_project.as_deref()) && !reg.projects.is_empty())
        .then(|| runner.run("projects.py", &["candidates".into()], None, Duration::from_secs(30)).ok())
        .flatten()
        .and_then(|r| r["text"].as_str().map(str::to_owned));
    let input = PromptInput {
        session: scripts::s(&session),
        shots: is_shots(&session),
        captures: run.captures.clone().unwrap_or_default(),
        skill_md: scripts::s(&paths::skill_dir().join("SKILL.md")),
        scripts: runner.scripts.as_deref().map(scripts::s).unwrap_or_default(),
        code,
        candidates,
    };
    let pf = paths::jobs_dir().join(format!("{}.prompt.md", job.id));
    if let Err(e) = std::fs::write(&pf, organize_prompt(&input)) {
        job.finish("failed", Some(("io", &e.to_string())));
        return Err(format!("{}: {e}", pf.display()));
    }
    let failures = runner.scripts.as_ref().and_then(|d| crate::settings::read_json(&d.join("agents.json"))).map(|r| r["failures"].clone()).unwrap_or(Value::Null);
    let passed: Vec<String> = skipped.iter().map(|a| why(a, None, &failures)).collect();
    if !passed.is_empty() {
        note_fallback(app, &job, &passed, &usable[0]);
    }
    job.step("prepare", "done", None);
    let id = job.id.clone();
    let (app2, runner2) = (app.clone(), runner.clone());
    let video = crate::settings::read_json(&session.join("meta.json")).and_then(|m| m["duration"].as_f64()).unwrap_or(0.0);
    let limit = organize_timeout(video);
    std::thread::spawn(move || attempts(&app2, &runner2, &run, &job, Attempts { queue: usable, passed, prompt: pf, failures, limit }));
    let _ = app.emit("jobs://started", json!({"id": id}));
    Ok(id)
}

/// Start one agent on the run: Ok(the child, its program) or Err(why it couldn't start).
fn start(runner: &Runner, run: &Run, job: &JobWriter, a: &Agent, pf: &Path) -> Result<(std::process::Child, String), String> {
    let session = &run.session;
    let args: Vec<String> = vec![
        "command".into(),
        a.id.clone(),
        "headless".into(),
        "--prompt-file".into(),
        scripts::s(pf),
        // its cwd: the session folder, never the project (agents.json _doc; the prompt names the code to read)
        "--repo".into(),
        scripts::s(session),
        "--var".into(),
        format!("run_id={}", job.id),
        // the scripts folder as the prompt spells it: claude's / gemini's allowlist is that same string (agents.py
        // would otherwise use its own resolved path, another spelling under a symlink or a junction)
        "--var".into(),
        format!("scripts={}", runner.scripts.as_deref().map(scripts::s).unwrap_or_default()),
        // the processing model for this kind of run (Settings → Agents): a recording, or cards
        "--processing".into(),
        processing_kind(session).into(),
    ];
    let cmd = runner.run("agents.py", &args, None, Duration::from_secs(30)).map_err(|e| e.message)?;
    let argv: Vec<String> = cmd["argv"].as_array().into_iter().flatten().filter_map(|v| v.as_str().map(str::to_owned)).collect();
    if argv.is_empty() {
        return Err(format!("{} has no headless mode", a.name));
    }
    let log = std::fs::OpenOptions::new().create(true).append(true).open(log_path(&job.id)).map_err(|e| e.to_string())?;
    let mut c = scripts::daemon_command(&argv); // its own process group: quitting ends it and what it started
    c.current_dir(session).stdin(Stdio::null()).stdout(log.try_clone().map_err(|e| e.to_string())?).stderr(log);
    c.env("BLURT_JOB", &job.id).env("BLURT_RUN_ID", &job.id).env("BLURT_AGENT", &a.id);
    c.env("BLURT_HOME", paths::blurt_home()).env("BLURT_WORKSPACE", paths::default_workspace());
    if let Some(p) = run.project.as_deref().filter(|p| *p != "inbox") {
        c.env("BLURT_PROJECT", p);
    }
    for (k, v) in cmd.get("env").and_then(Value::as_object).into_iter().flatten() {
        if let Some(v) = v.as_str() {
            c.env(k, v);
        }
    }
    let child = c.spawn().map_err(|e| format!("couldn't start {}: {e}", argv[0]))?;
    Ok((child, argv[0].clone()))
}

/// `agents.py classify` on this attempt's output (agents.json failures, as the Mac's classify); the rough
/// [`error_code`] when it can't run.
fn classify(runner: &Runner, job: &str, from: u64) -> Option<String> {
    let log = std::fs::read(log_path(job)).unwrap_or_default();
    let tail = String::from_utf8_lossy(&log[(from as usize).min(log.len())..]).into_owned();
    let f = paths::jobs_dir().join(format!("{job}.attempt.txt"));
    let class = std::fs::write(&f, &tail)
        .ok()
        .and_then(|_| runner.run("agents.py", &["classify".into(), scripts::s(&f)], None, Duration::from_secs(30)).ok())
        .map(|r| r["class"].as_str().map(str::to_owned));
    let _ = std::fs::remove_file(&f);
    match class {
        Some(c) => c,
        None => Some(error_code(&tail)).filter(|c| *c != "unknown").map(str::to_owned),
    }
}

/// The agents left to try and what the job knows about them.
struct Attempts {
    queue: Vec<Agent>,
    /// "Claude Code 未登录": the agents passed over so far
    passed: Vec<String>,
    prompt: PathBuf,
    failures: Value,
    limit: Duration,
}

fn attempts(app: &AppHandle, runner: &Runner, run: &Run, job: &Arc<JobWriter>, mut at: Attempts) {
    let session = &run.session;
    job.step("transcribe", "running", None);
    while !at.queue.is_empty() {
        let a = at.queue.remove(0);
        log_line(&job.id, &format!("organizing ({}) with {}", processing_kind(session), a.name));
        let from = std::fs::metadata(log_path(&job.id)).map(|m| m.len()).unwrap_or(0);
        note_meta(session, json!({"id": a.id, "name": a.name, "result": "running", "at": projects::iso_now(), "job": job.id}));
        let (before, batch_before) = (files_now(session), batch_items(session));
        let (mut child, bin) = match start(runner, run, job, &a, &at.prompt) {
            Ok(c) => c,
            Err(e) => {
                log_line(&job.id, &format!("couldn't start {}: {e}", a.name));
                // the next usable agent in the user's order takes it, as after a login or quota problem
                if !at.queue.is_empty() {
                    at.passed.push(why(&a, None, &at.failures));
                    note_fallback(app, job, &at.passed, &at.queue[0]);
                    continue;
                }
                note_meta(session, json!({"result": "failed", "class": "skill", "done_at": projects::iso_now()}));
                job.finish("failed", Some(("skill", &e)));
                break;
            }
        };
        ORGANISING.lock().unwrap().push((job.id.clone(), child.id(), job.clone()));
        let started = Instant::now();
        let mut timed_out = false;
        let code = loop {
            match child.try_wait() {
                Ok(Some(s)) => break s.code(),
                Ok(None) if started.elapsed() > at.limit => {
                    timed_out = true;
                    kill_pid(child.id());
                    let _ = child.kill();
                    break child.wait().ok().and_then(|s| s.code());
                }
                Ok(None) => std::thread::sleep(Duration::from_millis(500)),
                Err(_) => break None,
            }
        };
        ORGANISING.lock().unwrap().retain(|(j, ..)| j != &job.id);
        if QUITTING.load(std::sync::atomic::Ordering::SeqCst) {
            return; // end_organising said how it ended
        }
        // the items the run reported (items.py appends them to the job's events, folded by load: the writer's own
        // copy has them only after its next save)
        let now = crate::jobs::load(&job.id).unwrap_or_else(|| job.snapshot());
        let reported: Vec<String> = now["items"].as_array().into_iter().flatten().filter_map(|v| v.as_str().map(str::to_owned)).collect();
        let filed = filed_items(&before, &files_now(session), &reported, &batch_before, &batch_items(session));
        let class = if filed.is_none() && !timed_out { classify(runner, &job.id, from) } else { None };
        let ended = decide(filed, timed_out, class.as_deref(), !at.queue.is_empty());
        let exit = code.map_or("a signal".to_string(), |c| c.to_string());
        log_line(&job.id, &format!("{} ended (exit {exit}): {ended:?}", a.name));
        match ended {
            Ended::Filed(uids) => {
                finish_done(job, session, uids);
                break;
            }
            Ended::Empty => {
                finish_done(job, session, vec![]);
                break;
            }
            Ended::Next(c) => {
                if c == "auth" {
                    forget_detected();
                }
                at.passed.push(why(&a, Some(&c), &at.failures));
                note_fallback(app, job, &at.passed, &at.queue[0]);
            }
            Ended::Failed(c) => {
                if c == "auth" {
                    forget_detected();
                }
                let msg = if timed_out { format!("{} was stopped after {} min", a.name, at.limit.as_secs() / 60) } else { format!("{bin} exited with {exit}") };
                note_meta(session, json!({"result": "failed", "class": c, "exit": code, "done_at": projects::iso_now()}));
                // a problem with the agent: nothing of the recording itself failed (OrganizeSteps.onFailure)
                let transcribed = session.join("transcript.json").is_file();
                if transcribed {
                    job.step("transcribe", "done", None);
                } else if ["auth", "quota", "network", "model"].contains(&c.as_str()) {
                    job.step("transcribe", "pending", None);
                }
                job.finish("failed", Some((&c, &msg)));
                break;
            }
        }
    }
    crate::watcher::update(app, std::slice::from_ref(session));
}

fn finish_done(job: &JobWriter, session: &Path, uids: Vec<String>) {
    note_meta(session, json!({"result": "ok", "items": uids.len(), "done_at": projects::iso_now()}));
    for s in ["transcribe", "write", "frames"] {
        job.step(s, "done", None);
    }
    job.set_items(&uids);
    job.finish("done", None);
}

#[cfg(test)]
mod tests {
    use super::*;

    /// tests/organize-prompt/golden.json: what both apps make of each input (the Mac's OrganizerPromptTests reads it too).
    #[test]
    fn prompt_matches_the_golden_cases() {
        let f = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../tests/organize-prompt/golden.json");
        let g: Value = serde_json::from_slice(&std::fs::read(&f).unwrap()).unwrap();
        let cases = g["cases"].as_array().unwrap();
        assert!(cases.len() >= 3);
        for c in cases {
            let i = &c["input"];
            let input = PromptInput {
                session: i["session"].as_str().unwrap().into(),
                shots: i["shots"].as_bool().unwrap(),
                captures: i["captures"].as_array().map(|a| a.iter().filter_map(Value::as_u64).collect()).unwrap_or_default(),
                skill_md: i["skill_md"].as_str().unwrap().into(),
                scripts: i["scripts"].as_str().unwrap().into(),
                code: i["code"].as_str().map(str::to_owned),
                candidates: i["candidates"].as_str().map(str::to_owned),
            };
            assert_eq!(organize_prompt(&input), c["prompt"].as_str().unwrap(), "{}", c["name"]);
        }
    }

    #[test]
    fn prompt_names_what_the_mac_names() {
        let p = organize_prompt(&PromptInput { session: "/s".into(), skill_md: "/k/SKILL.md".into(), scripts: "/k/scripts".into(), code: Some("/r/app".into()), ..Default::default() });
        for want in ["/k/SKILL.md", "uv run /k/scripts/<name>.py", "run items.py ingest as SKILL.md says", "(read it, change nothing there): /r/app"] {
            assert!(p.contains(want), "{want}: {p}");
        }
        assert!(!p.contains("opens it"), "the app never opens the review page by itself (K4)");
        assert_eq!(scripts_hint("/x"), "\nRun the skill's scripts exactly as `uv run /x/<name>.py …` (no other form, no other command is allowed).");
    }

    #[test]
    fn candidates_only_without_a_project() {
        assert!(wants_candidates(None, Some("inbox")));
        assert!(wants_candidates(None, None));
        assert!(!wants_candidates(Some("atlas"), Some("inbox")));
        assert!(!wants_candidates(None, Some("atlas")));
    }

    #[test]
    fn kinds_of_session() {
        let d = tempfile::tempdir().unwrap();
        let rec = d.path().join("20261118-101500");
        std::fs::create_dir_all(&rec).unwrap();
        std::fs::write(rec.join("recording.mp4"), "").unwrap();
        std::fs::write(rec.join("shots.jsonl"), "").unwrap();
        assert_eq!(processing_kind(&rec), "recording");
        let shots = d.path().join("20261118-102000-shots");
        std::fs::create_dir_all(&shots).unwrap();
        assert_eq!(processing_kind(&shots), "cards");
        assert_eq!(processing_kind(&d.path().join("20261118-103000-voice")), "cards");
    }

    #[test]
    fn queue_follows_the_order() {
        let d = json!({"order": ["claude", "codex", "kimi"], "agents": [
            {"id": "codex", "name": "Codex", "state": "ready", "headless": true},
            {"id": "claude", "name": "Claude Code", "state": "logged_out", "headless": true},
            {"id": "kimi", "name": "Kimi Code", "state": "not_installed", "headless": true},
            {"id": "workbuddy", "name": "WorkBuddy", "state": "unknown", "headless": false},
        ]});
        let (usable, skipped) = queue(&d);
        assert_eq!(usable.iter().map(|a| a.id.as_str()).collect::<Vec<_>>(), ["codex"]);
        assert_eq!(skipped.iter().map(|a| a.id.as_str()).collect::<Vec<_>>(), ["claude"]);
        // a connect-only app never organises in the background: none usable
        let (u, _) = queue(&json!({"order": ["workbuddy"], "agents": [{"id": "workbuddy", "state": "unknown", "headless": false}]}));
        assert!(u.is_empty());
    }

    #[test]
    fn success_is_items_filed_not_exit_zero() {
        let t0 = SystemTime::UNIX_EPOCH + Duration::from_secs(100);
        let t1 = t0 + Duration::from_secs(5);
        let st = |b: Option<SystemTime>, i: Option<SystemTime>| -> Stamps {
            vec![("batch.json".into(), b), ("items.json".into(), None), ("items.ingested.json".into(), i)]
        };
        let s = |v: &[&str]| v.iter().map(|x| x.to_string()).collect::<Vec<_>>();
        // exit 0 but nothing written: not filed
        assert_eq!(filed_items(&st(None, None), &st(None, None), &[], &[], &[]), None);
        // an earlier run's batch, untouched: not filed by this run
        assert_eq!(filed_items(&st(Some(t0), None), &st(Some(t0), None), &[], &s(&["u0"]), &s(&["u0"])), None);
        // written: the items it reported, and the batch's new ones
        assert_eq!(filed_items(&st(Some(t0), None), &st(Some(t1), Some(t1)), &s(&["u2"]), &s(&["u0"]), &s(&["u0", "u1", "u2"])), Some(s(&["u2", "u1"])));
        // written with nothing in it: filed, no items
        assert_eq!(filed_items(&st(None, None), &st(Some(t1), Some(t1)), &[], &[], &[]), Some(vec![]));
    }

    #[test]
    fn outcomes() {
        assert_eq!(decide(Some(vec!["u1".into()]), false, None, true), Ended::Filed(vec!["u1".into()]));
        assert_eq!(decide(Some(vec![]), false, None, true), Ended::Empty);
        // items filed before the limit count, even when it was stopped
        assert_eq!(decide(Some(vec!["u1".into()]), true, None, false), Ended::Filed(vec!["u1".into()]));
        assert_eq!(decide(None, true, Some("auth"), true), Ended::Failed("timeout".into()));
        // login / quota / model: the next agent takes it; with none left, the job says why
        assert_eq!(decide(None, false, Some("auth"), true), Ended::Next("auth".into()));
        assert_eq!(decide(None, false, Some("quota"), true), Ended::Next("quota".into()));
        assert_eq!(decide(None, false, Some("quota"), false), Ended::Failed("quota".into()));
        // a problem the next agent would share stays this job's
        assert_eq!(decide(None, false, Some("network"), true), Ended::Failed("network".into()));
        assert_eq!(decide(None, false, None, true), Ended::Failed("agent_exit".into()));
    }

    #[test]
    fn one_run_per_recording_while_the_first_is_set_up() {
        use std::sync::atomic::{AtomicUsize, Ordering};
        static C: Claims = Claims::new();
        static JOB: Mutex<Option<String>> = Mutex::new(None);
        static STARTED: AtomicUsize = AtomicUsize::new(0);
        let key = PathBuf::from("/s/rec1");
        let existing = || JOB.lock().unwrap().clone();
        let first = C.claim(key.clone(), existing).expect("nothing organises it yet");
        // a second ask while the first is still detecting: it waits, then finds the first one's job
        let second = std::thread::spawn({
            let key = key.clone();
            move || match C.claim(key, || JOB.lock().unwrap().clone()) {
                Ok(_) => {
                    STARTED.fetch_add(1, Ordering::SeqCst);
                    None
                }
                Err(id) => Some(id),
            }
        });
        std::thread::sleep(Duration::from_millis(100));
        assert!(!second.is_finished(), "waits while the first run is set up");
        *JOB.lock().unwrap() = Some("j-1".into()); // JobWriter::new
        drop(first);
        assert_eq!(second.join().unwrap().as_deref(), Some("j-1"));
        assert_eq!(STARTED.load(Ordering::SeqCst), 0);
        // another recording isn't held up; a failed setup (no job, claim dropped) lets the next ask run
        let other = C.claim(PathBuf::from("/s/rec2"), || None);
        assert!(other.is_ok());
        drop(other);
        assert!(C.claim(PathBuf::from("/s/rec2"), || None).is_ok());
    }

    #[test]
    fn timeouts() {
        assert_eq!(organize_timeout(0.0), Duration::from_secs(45 * 60));
        assert_eq!(organize_timeout(30.0 * 60.0), Duration::from_secs(90 * 60));
        assert_eq!(organize_timeout(10.0 * 3600.0), Duration::from_secs(4 * 3600));
    }

    #[test]
    fn error_codes() {
        assert_eq!(error_code("Error: Not logged in · Please run /login"), "auth");
        assert_eq!(error_code("429 rate limit exceeded"), "quota");
        assert_eq!(error_code("getaddrinfo ENOTFOUND api.anthropic.com"), "network");
        assert_eq!(error_code("panic"), "unknown");
    }
}
