//! App-level moments and the backends behind Settings' Models / Storage / Agents rows on Windows and Linux — the
//! Mac's App/LaunchMessages.swift, App/Housekeeping.swift, App/Updater.swift, BlurtCore VideoRetention / SkillContract /
//! LaunchQueue, Settings/PrivacyStoragePanes.swift's StorageModel and the AgentsPane's model (docs/design/windows-parity/
//! settings.md §6, §3).
//!
//!   launch messages   at most one island line per launch: for 3 s posts are held, then the highest rank goes up and
//!                     the rest are dropped; until 90 s after launch one that arrives after a line was shown is dropped
//!                     too. Ranks (lowest first): model, job, project, permission, shortcuts, welcome, models, skill,
//!                     config. A post may say `still_true` (asked when the hold ends) and `shown` (once it went up).
//!   housekeeping      at launch, quietly: the skill's contract against the app's; jobs the last run left "running"
//!                     marked failed; v0.6's carried-over project asked about once; organized recordings' videos older
//!                     than record.delete_videos_after_days to the Recycle Bin (and daily); `transcribe.py auto --apply`
//!                     and its model suggestion; shortcuts that won't work. (items.py / projects.py migrate and jobs.py
//!                     gc already run in watcher::initial_scan.)
//!   updates           the release feed the Mac's Sparkle reads (GitHub's latest release) and blurt.work's copy, the
//!                     mainland copy first where setup.rs turns the mirrors on; a check at launch and every day while
//!                     the app runs; a found version is said once in the island ("Blurt 1.2 is available · Update…")
//!                     and named in the tray menu until it is installed.
//!   storage           sizes of what Blurt keeps; Move to Recycle Bin; the videos of organized recordings by age.
//!   models per job    record.cloud.jobs (cloud.rs reads it) and asr.models / asr.auto (transcribe.py reads them).
//!   agents            agents.json, Connect (agents.py install, a dry run first) and a test run.
//!   feedback          feedback.py send (the Dictation page's Send Feedback…).

use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use serde_json::{json, Value};
use tauri::{AppHandle, Emitter, Manager};

use crate::projects::Registry;
use crate::{island, jobs, paths, scripts, settings, AppState};

type R<T> = Result<T, String>;

/// BlurtCore SkillContract.expected — bump with skills/blurt/scripts/_common.py CONTRACT.
pub const CONTRACT: i64 = 1;

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Debug)]
pub enum Rank {
    Model = 1,
    Job,
    Project,
    Permission,
    Shortcuts,
    Welcome,
    Models,
    Skill,
    Config,
}

type Hook = Box<dyn FnOnce() + Send>;
type Check = Box<dyn Fn() -> bool + Send>;

struct Held {
    rank: Rank,
    op: Value,
    shown: Option<Hook>,
    still_true: Option<Check>,
}

pub struct Moments {
    started: Instant,
    collecting: Mutex<bool>,
    held: Mutex<Vec<Held>>,
    shown_one: Mutex<bool>,
    /// a version the background check found and that isn't installed yet (the tray names it)
    pub update: Mutex<Option<String>>,
}

impl Default for Moments {
    fn default() -> Self {
        Moments { started: Instant::now(), collecting: Mutex::new(true), held: Mutex::new(Vec::new()), shown_one: Mutex::new(false), update: Mutex::new(None) }
    }
}

const HOLD: Duration = Duration::from_secs(3);
const WINDOW: Duration = Duration::from_secs(90);

/// The pure rule (BlurtCore LaunchQueue): which of the held posts goes up — the highest rank still true.
fn pick(held: &[(Rank, bool)]) -> Option<usize> {
    held.iter().enumerate().filter(|(_, (_, ok))| *ok).max_by_key(|(i, (r, _))| (*r, usize::MAX - *i)).map(|(i, _)| i)
}

/// An island line `{"op": "toast", "kind": "dictation", …}` with the overlays' string key `msg` (`launch.*`).
pub fn line(msg: &str, vars: Value, mark: &str, action: Option<(&str, &str)>, ms: u64) -> Value {
    let mut op = json!({"op": "toast", "kind": "dictation", "key": format!("launch.{msg}"), "msg": format!("launch.{msg}"), "vars": vars,
                        "mark": mark, "ms": ms, "passive": true});
    if let Some((a, label)) = action {
        op["action"] = json!({"a": a, "label": format!("launch.{label}")});
    }
    op
}

/// A launch message (LaunchMessages.post).
pub fn post(app: &AppHandle, rank: Rank, op: Value, shown: Option<Hook>, still_true: Option<Check>) {
    let m = app.state::<Moments>();
    if *m.collecting.lock().unwrap() {
        m.held.lock().unwrap().push(Held { rank, op, shown, still_true });
        return;
    }
    if m.started.elapsed() < WINDOW && *m.shown_one.lock().unwrap() {
        return; // one launch line was enough
    }
    if still_true.as_ref().is_some_and(|f| !f()) {
        return;
    }
    show(app, op, shown);
}

fn show(app: &AppHandle, op: Value, shown: Option<Hook>) {
    *app.state::<Moments>().shown_one.lock().unwrap() = true;
    island::send(app, op);
    if let Some(f) = shown {
        f();
    }
}

fn flush(app: &AppHandle) {
    let m = app.state::<Moments>();
    *m.collecting.lock().unwrap() = false;
    let mut held = std::mem::take(&mut *m.held.lock().unwrap());
    let states: Vec<(Rank, bool)> = held.iter().map(|h| (h.rank, h.still_true.as_ref().is_none_or(|f| f()))).collect();
    if let Some(i) = pick(&states) {
        let h = held.swap_remove(i);
        show(app, h.op, h.shown);
    }
}

fn set_config(pointer: &[&str], v: Option<Value>) {
    let _ = settings::update(|cfg| set_at(cfg, pointer, v));
}

fn set_at(cfg: &mut Value, pointer: &[&str], v: Option<Value>) {
    let mut cur = cfg;
    for k in &pointer[..pointer.len() - 1] {
        if cur.get(*k).and_then(Value::as_object).is_none() {
            cur[*k] = json!({});
        }
        cur = &mut cur[*k];
    }
    let last = pointer[pointer.len() - 1];
    match v {
        Some(v) => cur[last] = v,
        None => {
            if let Some(o) = cur.as_object_mut() {
                o.remove(last);
            }
        }
    }
}

// ------------------------------------------------------------------ at launch

/// Called once from setup.
pub fn start(app: &AppHandle) {
    app.manage(Moments::default());
    if std::env::var_os("BLURT_NO_HOUSEKEEPING").is_some() {
        *app.state::<Moments>().collecting.lock().unwrap() = false;
        return;
    }
    {
        let app = app.clone();
        std::thread::spawn(move || {
            std::thread::sleep(HOLD);
            flush(&app);
        });
    }
    updates_loop(app);
    let app = app.clone();
    let launched = chrono::Local::now();
    std::thread::spawn(move || {
        check_contract(&app);
        finish_interrupted_jobs(launched);
        ask_carried_over_project(&app);
        shortcuts_that_wont_work(&app);
        delete_old_videos(&app);
        speech_models(&app);
        expire_taken();
        // daily while the app runs (dragged-out cards hourly, as the Mac's expiry timer)
        let h = app.clone();
        std::thread::spawn(move || loop {
            std::thread::sleep(Duration::from_secs(24 * 3600));
            delete_old_videos(&h);
        });
        std::thread::spawn(|| loop {
            std::thread::sleep(Duration::from_secs(3600));
            expire_taken();
        });
    });
}

/// Cards dragged out into another app ("taken": the Cards panel's History keeps them 7 days) go to the Recycle Bin
/// once their 7 days are up — the picture, its marked copy, its voice, its out/<NNN>/ folder — and the batch gets
/// `{"n", "deleted": true}` (the Mac's Snapper.expireTaken). Test runs (BLURT_TEST_COMMANDS) recycle nothing.
pub fn expire_taken() -> usize {
    expire_taken_in(&paths::inbox_store().join("sessions"), chrono::Utc::now().timestamp_millis() as f64 / 1000.0, std::env::var("BLURT_TEST_COMMANDS").as_deref() != Ok("1"))
}

const TAKEN_DAYS: f64 = 7.0;

fn expire_taken_in(dir: &Path, now: f64, recycle_files: bool) -> usize {
    use std::io::Write;
    let mut count = 0;
    for session in std::fs::read_dir(dir).into_iter().flatten().filter_map(Result::ok).map(|e| e.path()) {
        if !session.file_name().is_some_and(|n| n.to_string_lossy().ends_with("-shots")) {
            continue;
        }
        let raw = std::fs::read_to_string(session.join("shots.jsonl")).unwrap_or_default();
        let mut by_n: std::collections::BTreeMap<u64, serde_json::Map<String, Value>> = Default::default();
        for line in raw.lines() {
            let Ok(Value::Object(m)) = serde_json::from_str::<Value>(line) else { continue };
            let Some(n) = m.get("n").and_then(Value::as_u64) else { continue };
            by_n.entry(n).or_default().extend(m);
        }
        let mut lines = String::new();
        for (n, m) in by_n {
            let taken = m.get("taken").and_then(Value::as_f64);
            let live = m.get("deleted") != Some(&json!(true)) && m.get("project").is_none_or(Value::is_null);
            if !live || !taken.is_some_and(|t| now - t >= TAKEN_DAYS * 86_400.0) {
                continue;
            }
            let mut files: Vec<PathBuf> = ["file", "marked", "voice"].iter().filter_map(|k| m.get(*k).and_then(Value::as_str)).map(|r| session.join(r)).collect();
            files.push(session.join("out").join(format!("{n:03}")));
            files.retain(|f| f.exists());
            if recycle_files {
                recycle(&files);
            }
            lines.push_str(&format!("{}\n", json!({"n": n, "deleted": true})));
            count += 1;
        }
        if !lines.is_empty() {
            if let Ok(mut f) = std::fs::OpenOptions::new().append(true).create(true).open(session.join("shots.jsonl")) {
                let _ = f.write_all(lines.as_bytes());
            }
        }
    }
    count
}

/// The `CONTRACT = n` line of the skill's _common.py; None: no skill there; 0: a skill from before the handshake.
pub fn skill_contract(scripts: Option<&Path>) -> Option<i64> {
    let text = std::fs::read_to_string(scripts?.join("_common.py")).ok()?;
    Some(
        text.lines()
            .filter_map(|l| l.strip_prefix("CONTRACT"))
            .filter_map(|r| r.trim_start().strip_prefix('='))
            .find_map(|r| r.trim().split(|c: char| !c.is_ascii_digit()).next().and_then(|d| d.parse().ok()))
            .unwrap_or(0),
    )
}

/// "skill_older" | "app_older" | None.
pub fn mismatch(skill: Option<i64>) -> Option<&'static str> {
    let s = skill?;
    (s != CONTRACT).then_some(if s < CONTRACT { "skill_older" } else { "app_older" })
}

fn check_contract(app: &AppHandle) {
    let runner = app.state::<AppState>().runner();
    let skill = skill_contract(runner.scripts.as_deref());
    let Some(m) = mismatch(skill) else { return };
    let sig = format!("{}/{}", app.package_info().version, skill.unwrap_or(-1));
    if settings::read_config().pointer("/app/contract_warned").and_then(Value::as_str) == Some(sig.as_str()) {
        return;
    }
    let op = line(&format!("contract.{m}"), json!({}), "warning", Some(("app.contract_help", "contract.how")), 8000);
    post(app, Rank::Skill, op, Some(Box::new(move || set_config(&["app", "contract_warned"], Some(json!(sig))))), None);
}

/// Jobs the app owned that were still "running" when it quit (or crashed): failed, the running step failed and the
/// rest skipped, so the job page explains it (Housekeeping.finishInterruptedJobs). Agent sessions are sessions.py's.
fn finish_interrupted_jobs(launched: chrono::DateTime<chrono::Local>) {
    for j in jobs::list(true, 200) {
        if j["type"] == "agent" || j["owner"] != "app" {
            continue;
        }
        let created = j["created"].as_str().and_then(|c| chrono::DateTime::parse_from_rfc3339(c).ok());
        if !created.is_some_and(|c| c < launched - chrono::Duration::seconds(5)) {
            continue;
        }
        let Some(id) = j["id"].as_str() else { continue };
        let p = paths::jobs_dir().join(format!("{id}.json"));
        let Some(mut doc) = settings::read_json(&p) else { continue };
        if !matches!(doc["state"].as_str(), Some("running" | "queued")) {
            // its file is older than the folded events: write the folded state
            doc = j.clone();
        }
        let now = crate::projects::iso_now();
        doc["state"] = json!("failed");
        doc["ended"] = json!(now);
        doc["error"] = json!({"code": "unknown", "message": "Blurt quit before this job finished", "hint_key": "main.job.hint.interrupted"});
        if let Some(steps) = doc["steps"].as_array_mut() {
            for s in steps {
                match s["state"].as_str() {
                    Some("running") => {
                        s["state"] = json!("failed");
                        s["ended"] = json!(now);
                    }
                    Some("pending" | "queued") => s["state"] = json!("skipped"),
                    _ => {}
                }
            }
        }
        // keep what was folded in: the events were read into `j`
        doc["events_offset"] = j.get("events_offset").cloned().unwrap_or(doc["events_offset"].clone());
        let tmp = p.with_extension(format!("json.{}.tmp", std::process::id()));
        if std::fs::write(&tmp, serde_json::to_vec_pretty(&doc).unwrap_or_default()).is_ok() {
            let _ = std::fs::rename(&tmp, &p);
        }
    }
}

/// v0.6's bound repo became the current project in the migration, which nobody chose here: asked once, in the
/// island (not answered: asked again next launch).
fn ask_carried_over_project(app: &AppHandle) {
    let reg = settings::read_json(&paths::projects_file()).unwrap_or_default();
    if reg["current_by"] != "migrate" {
        return;
    }
    let Some(p) = Registry::load().current_project().cloned() else { return };
    let name = p["name"].as_str().unwrap_or("").to_string();
    // a two-way question gets both answers (the Mac's askAboutCarriedOverProject): Unassigned, then Keep <project>;
    // it waits until it's answered (the island holds it while a capture, a take or a note is under way)
    let mut op = line("migrate.ask", json!({"name": name}), "folder", None, 600_000);
    op["project"] = p["id"].clone();
    op["action"] = json!({"a": "app.project_keep", "label": "launch.migrate.keep", "vars": {"name": name}, "extra": {"project": p["id"]}});
    op["second"] = json!({"a": "app.project_keep", "label": "launch.migrate.unassigned"});
    post(app, Rank::Project, op, None, None);
}

/// Shortcuts the system wouldn't give us (another app holds them, a Windows shortcut, the same keys twice): said once
/// at launch, with Change… (the Mac's "Shortcut ⌥R won't work").
fn shortcuts_that_wont_work(app: &AppHandle) {
    // the first apply happens in setup right after us: give it a moment
    std::thread::sleep(Duration::from_millis(800));
    let bad: Vec<String> = crate::hotkeys::rows(app)
        .into_iter()
        .filter(|r| matches!(r["result"].as_str(), Some("taken" | "system" | "duplicate")))
        .filter_map(|r| r["label"].as_str().map(str::to_owned))
        .collect();
    if bad.is_empty() {
        return;
    }
    let op = if bad.len() == 1 {
        line("keys.wont_work", json!({"key": bad[0]}), "warning", Some(("app.settings:shortcuts", "keys.change")), 8000)
    } else {
        line("keys.wont_work_several", json!({"n": bad.len()}), "warning", Some(("app.settings:shortcuts", "keys.change")), 8000)
    };
    post(app, Rank::Shortcuts, op, None, None);
}

/// K9: `transcribe.py auto --apply` picks the speech models for this machine; a better one that isn't here yet is
/// suggested once (it stays pending in app.model_suggest_pending until its line was seen). Not before the Welcome
/// is done (it downloads the first model). A model only recordings would use waits for the first recording.
fn speech_models(app: &AppHandle) {
    let cfg = settings::read_config();
    if cfg.pointer("/app/onboarded").and_then(Value::as_bool) != Some(true) {
        return;
    }
    let runner = app.state::<AppState>().runner();
    if !runner.has("transcribe.py") || runner.uv.is_none() {
        return;
    }
    let Ok(r) = runner.run("transcribe.py", &["auto".into(), "--apply".into()], None, Duration::from_secs(120)) else { return };
    if r["ok"] != true {
        return;
    }
    let need = r["needs_download"].as_array().cloned().unwrap_or_default();
    let pending = cfg.pointer("/app/model_suggest_pending").is_some();
    if need.is_empty() {
        if pending {
            set_config(&["app", "model_suggest_pending"], None);
        }
        return;
    }
    if r["hardware_changed"] != true && !pending {
        return;
    }
    let mb: f64 = need.iter().filter_map(|n| n["size_mb"].as_f64()).sum();
    let models: Vec<Value> = need.iter().map(|n| n["model"].clone()).collect();
    set_config(&["app", "model_suggest_pending"], Some(json!({"models": models, "size_mb": mb})));
    let purposes: std::collections::BTreeSet<String> =
        need.iter().flat_map(|n| n["purposes"].as_array().cloned().unwrap_or_default()).filter_map(|p| p.as_str().map(str::to_owned)).collect();
    let for_recordings = !purposes.is_empty() && purposes.iter().all(|p| p == "batch");
    if for_recordings && !has_recording() {
        return; // stays pending
    }
    let size = if mb >= 1000.0 { format!("{:.1} GB", mb / 1024.0) } else { format!("{} MB", mb.round() as i64) };
    let msg = if for_recordings { "speech.recommended_recordings" } else { "speech.recommended" };
    let op = line(msg, json!({"size": size}), "download", Some(("app.settings:speech", "speech.recommended.action")), 10_000);
    post(app, Rank::Model, op, Some(Box::new(|| set_config(&["app", "model_suggest_pending"], None))), None);
}

fn has_recording() -> bool {
    session_roots().iter().any(|r| {
        std::fs::read_dir(r).into_iter().flatten().filter_map(Result::ok).any(|d| d.path().join("recording.mp4").is_file())
    })
}

// ------------------------------------------------------------------ the island's buttons for these lines

/// `app.*` actions from the island (island::on_action hands them here).
pub fn island_action(app: &AppHandle, a: &str, v: &Value) {
    match a {
        "app.contract_help" => contract_help(app),
        "app.update" => install_update(app.clone()),
        "app.project_keep" => {
            let id = v["project"].as_str().unwrap_or("auto").to_string();
            let h = app.clone();
            std::thread::spawn(move || {
                let _ = crate::projects::use_project(&h.state::<AppState>().runner(), &id);
                island::refresh(&h);
                let _ = h.emit("projects://changed", json!({}));
            });
        }
        _ if a.starts_with("app.settings:") => {
            crate::show_main(app);
            let _ = app.emit("nav", json!({"view": "settings", "pane": &a["app.settings:".len()..]}));
        }
        _ => {}
    }
}

/// The way to fix a skill / app mismatch: a newer app from the updater when there is one, else the guide's
/// "Updating" section (Housekeeping.contractHelp).
pub fn contract_help(app: &AppHandle) {
    use tauri_plugin_opener::OpenerExt;
    let runner = app.state::<AppState>().runner();
    if mismatch(skill_contract(runner.scripts.as_deref())) == Some("app_older") && updates_configured(app) {
        crate::show_main(app);
        let _ = app.emit("nav", json!({"view": "settings", "pane": "general", "check_updates": true}));
        return;
    }
    let zh = crate::l10n::lang() == "zh-Hans";
    let anchor = if zh { "9-%E6%9B%B4%E6%96%B0" } else { "9-updating" };
    let _ = app.opener().open_url(format!("https://github.com/AGIHunt/blurt/blob/main/docs/guide.md#{anchor}"), None::<&str>);
}

// ------------------------------------------------------------------ updates

/// GitHub's latest release (where the Mac's Sparkle feed lives: …/releases/latest/download/appcast.xml) carries the
/// Tauri feed `latest.json` beside it; tauri.conf's endpoint (blurt.work) is its copy, which the mainland reaches
/// where github.com often doesn't — tried first there (setup.rs's mirror rule), last elsewhere.
pub const GITHUB_FEED: &str = "https://github.com/AGIHunt/blurt/releases/latest/download/latest.json";

pub fn updates_configured(app: &AppHandle) -> bool {
    app.config().plugins.0.get("updater").and_then(|u| u.get("pubkey")).and_then(Value::as_str).is_some_and(|k| !k.is_empty())
}

fn feed_urls(app: &AppHandle) -> Vec<tauri::Url> {
    let configured: Vec<String> = app
        .config()
        .plugins
        .0
        .get("updater")
        .and_then(|u| u.get("endpoints"))
        .and_then(Value::as_array)
        .map(|a| a.iter().filter_map(|e| e.as_str().map(str::to_owned)).collect())
        .unwrap_or_default();
    let mut all: Vec<String> = if crate::setup::mirror() {
        configured.into_iter().chain([GITHUB_FEED.to_string()]).collect()
    } else {
        std::iter::once(GITHUB_FEED.to_string()).chain(configured).collect()
    };
    all.dedup();
    all.iter().filter_map(|u| tauri::Url::parse(u).ok()).collect()
}

async fn check_now(app: &AppHandle) -> R<Option<String>> {
    use tauri_plugin_updater::UpdaterExt;
    let up = app.updater_builder().endpoints(feed_urls(app)).map_err(|e| e.to_string())?.timeout(Duration::from_secs(30)).build().map_err(|e| e.to_string())?;
    Ok(up.check().await.map_err(|e| e.to_string())?.map(|u| u.version))
}

/// At launch and once a day: a found version is said once in the island and named in the tray until installed.
pub fn updates_loop(app: &AppHandle) {
    if !updates_configured(app) || std::env::var_os("BLURT_NO_UPDATE_CHECK").is_some() {
        return;
    }
    let app = app.clone();
    tauri::async_runtime::spawn(async move {
        tokio_sleep(Duration::from_secs(20)).await; // after the launch's own work
        loop {
            if let Ok(Some(v)) = check_now(&app).await {
                let said = app.state::<Moments>().update.lock().unwrap().replace(v.clone()) == Some(v.clone());
                crate::tray::refresh(&app);
                if !said {
                    island::send(&app, line("update.found", json!({"version": v}), "download", Some(("app.update", "update.found.action")), 15_000));
                }
            }
            tokio_sleep(Duration::from_secs(24 * 3600)).await;
        }
    });
}

async fn tokio_sleep(d: Duration) {
    let _ = tauri::async_runtime::spawn_blocking(move || std::thread::sleep(d)).await;
}

/// Download, install (the NSIS installer in passive mode) and restart; progress as `update://progress` events.
pub fn install_update(app: AppHandle) {
    use tauri_plugin_updater::UpdaterExt;
    tauri::async_runtime::spawn(async move {
        let res: R<()> = async {
            let up = app.updater_builder().endpoints(feed_urls(&app)).map_err(|e| e.to_string())?.build().map_err(|e| e.to_string())?;
            let Some(u) = up.check().await.map_err(|e| e.to_string())? else { return Ok(()) };
            let mut done = 0u64;
            let a2 = app.clone();
            u.download_and_install(
                move |n, total| {
                    done += n as u64;
                    let _ = a2.emit("update://progress", json!({"done": done, "total": total}));
                },
                || {},
            )
            .await
            .map_err(|e| e.to_string())?;
            app.restart();
        }
        .await;
        if let Err(e) = res {
            let _ = app.emit("update://progress", json!({"error": e}));
        }
    });
}

#[tauri::command(async)]
pub async fn update_check(app: AppHandle) -> R<Value> {
    if !updates_configured(&app) {
        return Ok(json!({"configured": false}));
    }
    let v = check_now(&app).await?;
    *app.state::<Moments>().update.lock().unwrap() = v.clone();
    crate::tray::refresh(&app);
    Ok(json!({"configured": true, "available": v.is_some(), "version": v}))
}

/// What the About line and the tray show without a network round trip: configured, and a version found earlier.
#[tauri::command]
pub fn update_state(app: AppHandle) -> Value {
    let pending = app.try_state::<Moments>().and_then(|m| m.update.lock().unwrap().clone());
    json!({"configured": updates_configured(&app), "pending": pending})
}

#[tauri::command]
pub fn update_install(app: AppHandle) {
    install_update(app);
}

#[tauri::command]
pub fn app_contract(state: tauri::State<'_, AppState>) -> Value {
    let skill = skill_contract(state.runner().scripts.as_deref());
    json!({"skill": skill, "app": CONTRACT, "mismatch": mismatch(skill)})
}

#[tauri::command]
pub fn app_contract_help(app: AppHandle) {
    contract_help(&app);
}

// ------------------------------------------------------------------ storage

/// Every store's sessions/ (where recordings and snaps are), plus v0.6's ~/Blurt/recordings when it is still there.
pub fn session_roots() -> Vec<PathBuf> {
    let mut v: Vec<PathBuf> = Registry::load().stores().into_iter().map(|s| s.join("sessions")).filter(|p| p.is_dir()).collect();
    let legacy = paths::legacy_recordings();
    if legacy.is_dir() && !v.contains(&legacy) {
        v.push(legacy);
    }
    v
}

pub fn disk_size(p: &Path) -> u64 {
    let Ok(m) = std::fs::symlink_metadata(p) else { return 0 };
    if !m.is_dir() {
        return m.len();
    }
    std::fs::read_dir(p).into_iter().flatten().filter_map(Result::ok).map(|e| disk_size(&e.path())).sum()
}

/// The files that are only the video: the mp4 and the motion scan made from it.
const VIDEO_FILES: [&str; 2] = ["recording.mp4", "recording.scan.npz"];

#[derive(Debug, Clone)]
pub struct Video {
    pub session: PathBuf,
    pub files: Vec<PathBuf>,
    pub bytes: u64,
    pub age_days: f64,
}

/// The recording became items: its transcript is there and its batch isn't being made.
pub fn organized(session: &Path) -> bool {
    session.join("transcript.json").is_file()
        && settings::read_json(&session.join("batch.json")).is_some_and(|b| b.is_object() && b["processing"] != true)
}

/// Sessions whose video can go: organized, recorded at least `days` ago (None = any age), not `excluding`.
pub fn videos(roots: &[PathBuf], days: Option<u32>, excluding: Option<&Path>) -> Vec<Video> {
    let now = std::time::SystemTime::now();
    let mut out = Vec::new();
    for r in roots {
        for s in std::fs::read_dir(r).into_iter().flatten().filter_map(Result::ok).map(|e| e.path()) {
            if excluding.is_some_and(|x| x == s) {
                continue;
            }
            let Ok(m) = std::fs::metadata(s.join("recording.mp4")) else { continue };
            if !organized(&s) {
                continue;
            }
            let age = m.modified().ok().and_then(|t| now.duration_since(t).ok()).map_or(0.0, |d| d.as_secs_f64() / 86400.0);
            if days.is_some_and(|d| age < d as f64) {
                continue;
            }
            let files: Vec<PathBuf> = VIDEO_FILES.iter().map(|f| s.join(f)).filter(|f| f.exists()).collect();
            let bytes = files.iter().map(|f| disk_size(f)).sum();
            out.push(Video { session: s, files, bytes, age_days: age });
        }
    }
    out.sort_by(|a, b| b.age_days.total_cmp(&a.age_days));
    out
}

/// {"mode": "video"} — and once the video is gone {"video_removed": iso} — merged into the session's meta.json, so a
/// recording without its video never reads as a snap batch (VideoRetention.stamp).
pub fn stamp(session: &Path, removed: bool) {
    let f = session.join("meta.json");
    let mut m = settings::read_json(&f).filter(Value::is_object).unwrap_or_else(|| json!({}));
    m["mode"] = json!("video");
    if removed {
        m["video_removed"] = json!(crate::projects::iso_now());
    }
    let tmp = f.with_extension(format!("json.{}.tmp", std::process::id()));
    if std::fs::write(&tmp, serde_json::to_vec_pretty(&m).unwrap_or_default()).is_ok() {
        let _ = std::fs::rename(&tmp, &f);
    }
}

/// To the Recycle Bin (Windows: the shell's own delete-to-recycle-bin; Linux: `gio trash`). → what went.
pub fn recycle(files: &[PathBuf]) -> Vec<PathBuf> {
    if files.is_empty() {
        return vec![];
    }
    #[cfg(windows)]
    {
        // Microsoft.VisualBasic's FileSystem sends to the Recycle Bin without any dialog (one PowerShell for all)
        let quote = |p: &Path| format!("'{}'", p.to_string_lossy().replace('\'', "''"));
        let mut script = String::from("Add-Type -AssemblyName Microsoft.VisualBasic;");
        for f in files {
            let call = if f.is_dir() { "DeleteDirectory" } else { "DeleteFile" };
            script.push_str(&format!(
                "try {{ [Microsoft.VisualBasic.FileIO.FileSystem]::{call}({}, 'OnlyErrorDialogs', 'SendToRecycleBin') }} catch {{}};",
                quote(f)
            ));
        }
        let _ = scripts::command(&["powershell".into(), "-NoProfile".into(), "-NonInteractive".into(), "-Command".into(), script]).status();
    }
    #[cfg(not(windows))]
    {
        let mut argv = vec!["gio".to_string(), "trash".into()];
        argv.extend(files.iter().map(|f| f.to_string_lossy().into_owned()));
        let _ = scripts::command(&argv).status();
    }
    files.iter().filter(|f| !f.exists()).cloned().collect()
}

fn current_session(app: &AppHandle) -> Option<PathBuf> {
    app.state::<AppState>().capture.state()["session"].as_str().map(PathBuf::from)
}

/// The videos to the Recycle Bin, each session stamped a recording first and `video_removed` once its video went.
pub fn trash_videos(c: &[Video]) -> (usize, u64) {
    for v in c {
        stamp(&v.session, false);
    }
    let all: Vec<PathBuf> = c.iter().flat_map(|v| v.files.clone()).collect();
    let gone = recycle(&all);
    let mut n = 0;
    let mut bytes = 0;
    for v in c {
        if gone.contains(&v.session.join("recording.mp4")) {
            stamp(&v.session, true);
            n += 1;
            bytes += v.bytes;
        }
    }
    (n, bytes)
}

pub fn auto_days() -> Option<u32> {
    settings::read_config().pointer("/record/delete_videos_after_days").and_then(Value::as_u64).filter(|d| *d > 0).map(|d| d as u32)
}

/// Settings → Storage's "Delete videos automatically" (off unless the user chose an age). The recording in progress
/// is never touched.
pub fn delete_old_videos(app: &AppHandle) {
    let Some(days) = auto_days() else { return };
    let c = videos(&session_roots(), Some(days), current_session(app).as_deref());
    if !c.is_empty() {
        let _ = trash_videos(&c);
        crate::watcher::initial_scan(app); // the index learns the recordings lost their videos
    }
}

#[tauri::command(async)]
pub fn storage_scan(app: AppHandle) -> Value {
    let roots = session_roots();
    let folders: Vec<Value> = roots
        .iter()
        .map(|r| {
            let n = std::fs::read_dir(r).into_iter().flatten().filter_map(Result::ok).filter(|e| !e.file_name().to_string_lossy().starts_with('.')).count();
            json!({"path": scripts::s(r), "bytes": disk_size(r), "sessions": n})
        })
        .collect();
    let vids = videos(&roots, None, current_session(&app).as_deref());
    let video_rows: Vec<Value> = vids.iter().map(|v| json!({"session": scripts::s(&v.session), "bytes": v.bytes, "age_days": v.age_days})).collect();
    let h = paths::blurt_home();
    let mut models = Vec::new();
    let mdir = h.join("models");
    for e in std::fs::read_dir(&mdir).into_iter().flatten().filter_map(Result::ok).map(|e| e.path()) {
        let name = e.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
        if name.starts_with('.') {
            continue;
        }
        if name == "asr" || name == "polish" {
            for m in std::fs::read_dir(&e).into_iter().flatten().filter_map(Result::ok).map(|x| x.path()) {
                if !m.file_name().is_some_and(|n| n.to_string_lossy().starts_with('.')) {
                    models.push(json!({"path": scripts::s(&m), "folder": m.file_name().map(|n| n.to_string_lossy().into_owned()), "bytes": disk_size(&m)}));
                }
            }
        } else {
            models.push(json!({"path": scripts::s(&e), "folder": name, "bytes": disk_size(&e)}));
        }
    }
    // App data, as the Mac's Storage lists it (key → its row's words; removable ones may go to the Recycle Bin)
    let files: Vec<Value> = [
        ("dictation_history", "dictation/history.jsonl", false),
        ("dictation_audio", "dictation/audio", false),
        ("index", "index.db", false),
        ("build", "build", true),
        ("runs", "runs", false),
        ("jobs", "jobs", false),
        ("handoff", "handoff", false),
        ("prompts", "prompts", true),
        ("bench", "bench", true),
        ("tmp", "tmp", true),
        ("logs", "logs", false),
    ]
    .iter()
    .filter_map(|(k, rel, rm)| {
        let p = h.join(rel);
        let mut b = disk_size(&p);
        if *rel == "index.db" {
            b += disk_size(&h.join("index.db-wal")) + disk_size(&h.join("index.db-shm"));
        }
        (b > 0).then(|| json!({"key": k, "path": scripts::s(&p), "bytes": b, "removable": rm}))
    })
    .collect();
    json!({"folders": folders, "videos": video_rows, "models": models, "files": files, "auto_days": auto_days(), "available": free_bytes(&h)})
}

/// Free space on the disk that holds `p` (Storage's lead line, the Mac's "%@ available"); None when it can't be read.
fn free_bytes(p: &Path) -> Option<u64> {
    let p = std::iter::successors(Some(p), |x| x.parent()).find(|x| x.exists())?;
    #[cfg(windows)]
    {
        // .NET's DriveInfo: no extra Win32 feature for one number
        let q = scripts::s(p).replace('\'', "''");
        let script = format!("[System.IO.DriveInfo]::new([System.IO.Path]::GetPathRoot('{q}')).AvailableFreeSpace");
        let out = scripts::command(&["powershell".into(), "-NoProfile".into(), "-NonInteractive".into(), "-Command".into(), script]).output().ok()?;
        return String::from_utf8_lossy(&out.stdout).trim().parse().ok();
    }
    #[allow(unreachable_code)]
    {
        let out = std::process::Command::new("df").args(["-Pk"]).arg(p).output().ok()?;
        let text = String::from_utf8_lossy(&out.stdout).into_owned();
        let kb: u64 = text.lines().nth(1)?.split_whitespace().nth(3)?.parse().ok()?;
        Some(kb * 1024)
    }
}

/// Move to Recycle Bin, from Storage (only paths under Blurt's own folder or a session's video).
#[tauri::command(async)]
pub fn storage_trash(files: Vec<String>) -> R<Vec<String>> {
    let home = paths::blurt_home();
    let n = files.len();
    let files: Vec<PathBuf> = files.iter().map(PathBuf::from).filter(|p| p.starts_with(&home) && p != &home).collect();
    if files.len() != n {
        return Err("not Blurt's own files".into());
    }
    Ok(recycle(&files).iter().map(|p| scripts::s(p)).collect())
}

/// The videos of organized recordings older than `days` (None: all) to the Recycle Bin → {count, bytes}.
#[tauri::command(async)]
pub fn videos_trash(app: AppHandle, days: Option<u32>) -> Value {
    let c = videos(&session_roots(), days, current_session(&app).as_deref());
    let (n, bytes) = trash_videos(&c);
    crate::watcher::initial_scan(&app);
    json!({"count": n, "bytes": bytes})
}

/// "Delete videos automatically": None = never; an age deletes what is already older at once.
#[tauri::command(async)]
pub fn videos_auto_set(app: AppHandle, days: Option<u32>) -> Value {
    set_config(&["record", "delete_videos_after_days"], days.filter(|d| *d > 0).map(|d| json!(d)));
    delete_old_videos(&app);
    json!({"auto_days": auto_days()})
}

// ------------------------------------------------------------------ models per job

fn read_script_json(app: &AppHandle, name: &str) -> R<Value> {
    let dir = app.state::<AppState>().runner().scripts.ok_or("scripts")?;
    settings::read_json(&dir.join(name)).ok_or_else(|| format!("{name} not found"))
}

/// Blurt's measured cloud models per job (curated_models.json: what Settings offers; anything else is a custom model).
#[tauri::command]
pub fn cloud_curated(app: AppHandle) -> R<Value> {
    read_script_json(&app, "curated_models.json")
}

/// A text job's model (record.cloud.jobs): None = Automatic (the first connected service's measured model).
#[tauri::command]
pub fn cloud_job_set(job: String, service: Option<String>, model: Option<String>) -> R<Value> {
    if !crate::dictation::cloud::JOBS.contains(&job.as_str()) {
        return Err(format!("unknown job {job}"));
    }
    let mut cloud = crate::dictation::cloud::setup();
    if cloud.get("jobs").and_then(Value::as_object).is_none() {
        cloud["jobs"] = json!({});
    }
    let jobs = cloud["jobs"].as_object_mut().unwrap();
    match service.filter(|s| !s.is_empty()) {
        Some(s) => {
            let mut v = json!({"service": s});
            if let Some(m) = model.filter(|m| !m.is_empty()) {
                v["model"] = json!(m);
            }
            jobs.insert(job, v);
        }
        None => {
            jobs.remove(&job);
        }
    }
    cloud["v"] = json!(2);
    set_config(&["record", "cloud"], Some(cloud));
    Ok(crate::dictation::commands::cloud_summary())
}

/// Volcengine Speech (the Mac's VolcengineSpeech + CloudServiceSheet's pair rows): a speech-only service with two
/// credentials, kept as one item like every other key — preset and id "volcengine-speech", Windows Credential Manager
/// target "Blurt Cloud Polish/volcengine-speech", value "<App ID>:<Access Token>" (cloud.rs `volc_split` reads it).
pub const VOLC_SPEECH: &str = "volcengine-speech";

/// An App ID as the console shows it: letters and digits, up to 64 (VolcengineSpeech.validAppID).
pub fn valid_app_id(s: &str) -> bool {
    !s.is_empty() && s.len() <= 64 && s.chars().all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
}

/// Test the pair on a short clip (`transcribe.py check-cloud --model-id volcengine-seedasr`, the pair on stdin — never
/// on the command line or in a log), then save it. An empty token keeps the saved one (the App ID is no secret: shown
/// again). {"ok", "ms", "summary"} or {"ok": false, "code"}: app_id, no_token, token, auth, quota, network, …
#[tauri::command(async)]
pub fn cloud_connect_speech(state: tauri::State<'_, AppState>, app_id: String, token: String) -> R<Value> {
    use crate::dictation::cloud;
    let a = app_id.trim();
    if !valid_app_id(a) {
        return Ok(json!({"ok": false, "code": "app_id"}));
    }
    let typed = token.trim().to_string();
    let t = if typed.is_empty() { cloud::key(VOLC_SPEECH).and_then(|k| cloud::volc_split(&k)).map(|p| p.1) } else { Some(typed) };
    let Some(t) = t else { return Ok(json!({"ok": false, "code": "no_token"})) };
    if t.chars().any(|c| !c.is_ascii_graphic()) {
        return Ok(json!({"ok": false, "code": "token"}));
    }
    let body = json!({"app_id": a, "token": t}).to_string();
    let args: Vec<String> = ["check-cloud", "--model-id", "volcengine-seedasr"].iter().map(|s| s.to_string()).collect();
    let r = state.runner().run("transcribe.py", &args, Some(body.as_bytes()), Duration::from_secs(45));
    let v = match r {
        Ok(v) => v,
        Err(e) => serde_json::from_str::<Value>(e.stdout.lines().last().unwrap_or("")).unwrap_or_else(|_| json!({"ok": false, "code": "error"})),
    };
    if v["ok"] != json!(true) {
        return Ok(json!({"ok": false, "code": v["code"].as_str().unwrap_or("error")}));
    }
    cloud::connect(VOLC_SPEECH, &format!("{a}:{t}"), None, None)?;
    // the speech server holds the keys it started with: the next take starts one with these
    let _ = crate::dictation::server::call(crate::dictation::server::ASR, &json!({"cmd": "exit"}), Duration::from_secs(2), None);
    Ok(json!({"ok": true, "ms": v["ms"], "summary": cloud::summary()}))
}

/// The saved Volcengine App ID (no secret: Settings shows it again so a new token can go with it).
#[tauri::command]
pub fn cloud_speech_app_id() -> Option<String> {
    crate::dictation::cloud::key(VOLC_SPEECH).and_then(|k| crate::dictation::cloud::volc_split(&k)).map(|p| p.0)
}

// ------------------------------------------------------------------ Only my voice: the voice profile
//
// The Mac's VoiceprintModel (docs/design/voiceprint.md): the profile is made by reading a passage aloud with the
// microphone dictation uses; the speech tools learn it (`transcribe.py voiceprint enroll WAV` — the CLI: it may
// download the ~28 MB model, which the warm server never waits for) and the passage's recording is deleted once it is
// learned. The switch (record.dictation.only_my_voice) only turns on with a profile in place.

/// seconds of speech that make a good profile; the least the speech tools accept; a minute ends the take; a take
/// nobody reads into ends after 8 s (VoiceprintModel.enough / least, NoteVoice maxLength / noSpeechTimeout)
#[cfg_attr(not(windows), allow(dead_code))]
const VP_ENOUGH: f64 = 12.0;
#[cfg_attr(not(windows), allow(dead_code))]
const VP_LEAST: f64 = 6.0;
#[cfg_attr(not(windows), allow(dead_code))]
const VP_MAX: f64 = 60.0;
#[cfg_attr(not(windows), allow(dead_code))]
const VP_NO_SPEECH: f64 = 8.0;

/// the take being read: Some(stop) while the microphone runs — send true to finish (learn), false to cancel
static VP_TAKE: Mutex<Option<std::sync::mpsc::Sender<bool>>> = Mutex::new(None);

fn vp_wav() -> PathBuf {
    std::env::temp_dir().join("blurt-voiceprint.wav")
}

/// The warm speech server when it runs (no process start), else the CLI.
fn vp_request(state: &AppState, req: Value, cli: &[&str], secs: u64) -> Option<Value> {
    use crate::dictation::server;
    if server::running(server::ASR) {
        if let Some(v) = server::call(server::ASR, &req, Duration::from_secs(secs), None) {
            return Some(v);
        }
    }
    let args: Vec<String> = std::iter::once("voiceprint").chain(cli.iter().copied()).map(String::from).collect();
    state.runner().run("transcribe.py", &args, None, Duration::from_secs(secs)).ok()
}

/// A profile deleted elsewhere (or never made): the switch can't stay on.
fn vp_apply(r: &Value) -> Value {
    let enrolled = r["enrolled"].as_bool().unwrap_or(false);
    if !enrolled && settings::read_config().pointer("/record/dictation/only_my_voice") == Some(&json!(true)) {
        set_config(&["record", "dictation", "only_my_voice"], None);
    }
    json!({"enrolled": enrolled, "stale": r["stale"].as_bool().unwrap_or(false), "model_ready": r["model_ready"].as_bool().unwrap_or(false)})
}

/// {enrolled, stale, model_ready, recording}
#[tauri::command(async)]
pub fn voiceprint_status(state: tauri::State<'_, AppState>) -> Value {
    let r = vp_request(&state, json!({"cmd": "vp_status"}), &["status"], 30).filter(|r| r["ok"] == true).unwrap_or_else(|| json!({}));
    let mut v = vp_apply(&r);
    v["recording"] = json!(VP_TAKE.lock().unwrap().is_some());
    v
}

/// The sheet opened: the model comes down while the passage is read. {ok, …status} or {ok: false, code: "network"}.
#[tauri::command(async)]
pub fn voiceprint_prepare(state: tauri::State<'_, AppState>) -> Value {
    let args: Vec<String> = ["voiceprint", "prepare"].iter().map(|s| s.to_string()).collect();
    match state.runner().run("transcribe.py", &args, None, Duration::from_secs(600)) {
        Ok(r) if r["ok"] == true => {
            let mut v = vp_apply(&r);
            v["ok"] = json!(true);
            v
        }
        _ => json!({"ok": false, "code": "network"}),
    }
}

/// Delete Voice Profile: the switch goes off with it.
#[tauri::command(async)]
pub fn voiceprint_clear(state: tauri::State<'_, AppState>) -> Value {
    set_config(&["record", "dictation", "only_my_voice"], None);
    let r = vp_request(&state, json!({"cmd": "vp_clear"}), &["clear"], 15).unwrap_or_else(|| json!({}));
    vp_apply(&r)
}

/// Done (true: learn what was read, once there is enough of it) or Cancel (false).
#[tauri::command]
pub fn voiceprint_stop(finish: bool) {
    if let Some(tx) = VP_TAKE.lock().unwrap().as_ref() {
        let _ = tx.send(finish);
    }
}

/// Start Recording: the microphone dictation uses (record.dictation.mic), the passage heard as `voiceprint://changed`
/// {phase: starting | recording | saving | idle, progress 0…1, level, can_finish, failed?: too_short | mic_failed |
/// network | <code>, learned?: true}. It ends itself once the passage is read (or the reader stopped after enough of
/// it), after a minute, or when nobody reads into it.
#[tauri::command]
pub fn voiceprint_start(app: AppHandle) -> R<()> {
    let mut slot = VP_TAKE.lock().unwrap();
    if slot.is_some() {
        return Ok(());
    }
    let (stop_tx, stop_rx) = std::sync::mpsc::channel::<bool>();
    *slot = Some(stop_tx);
    drop(slot);
    std::thread::spawn(move || {
        let emit = |v: Value| {
            let _ = app.emit("voiceprint://changed", v);
        };
        emit(json!({"phase": "starting", "progress": 0}));
        let take = vp_record(&emit, &stop_rx);
        *VP_TAKE.lock().unwrap() = None;
        let wav = vp_wav();
        match take {
            Err(code) => {
                let _ = std::fs::remove_file(&wav);
                emit(json!({"phase": "idle", "progress": 0, "failed": code}));
            }
            Ok(false) => {
                let _ = std::fs::remove_file(&wav);
                emit(json!({"phase": "idle", "progress": 0}));
            }
            Ok(true) => {
                emit(json!({"phase": "saving", "progress": 1}));
                let args: Vec<String> = vec!["voiceprint".into(), "enroll".into(), scripts::s(&wav)];
                let runner = app.state::<AppState>().runner();
                let r = match runner.run("transcribe.py", &args, None, Duration::from_secs(600)) {
                    Ok(v) => v,
                    Err(e) => serde_json::from_str::<Value>(e.stdout.lines().last().unwrap_or("")).unwrap_or_else(|_| json!({"ok": false, "code": "error"})),
                };
                let _ = std::fs::remove_file(&wav);
                if r["ok"] == true {
                    set_config(&["record", "dictation", "only_my_voice"], Some(json!(true)));
                    let mut v = vp_apply(&r);
                    v["phase"] = json!("idle");
                    v["learned"] = json!(true);
                    emit(v);
                } else {
                    let code = match r["code"].as_str().unwrap_or("error") {
                        "too_short" => "too_short",
                        "network" | "model_missing" => "network",
                        c => c,
                    };
                    emit(json!({"phase": "idle", "progress": 0, "failed": code}));
                }
            }
        }
    });
    Ok(())
}

/// The take itself: Ok(true) = learn it (the WAV is written), Ok(false) = cancelled, Err(code) = say why.
#[cfg(windows)]
fn vp_record(emit: &dyn Fn(Value), stop: &std::sync::mpsc::Receiver<bool>) -> Result<bool, String> {
    use crate::dictation::mic;
    let (tx, rx) = std::sync::mpsc::channel::<Vec<f32>>();
    let name = settings::read_config().pointer("/record/dictation/mic").and_then(Value::as_str).filter(|s| !s.is_empty()).map(String::from);
    let _mic = mic::Mic::open_named(tx, name.as_deref()).map_err(|e| {
        eprintln!("blurt voiceprint: mic: {e}");
        "mic_failed".to_string()
    })?;
    let frame_s = mic::FRAME as f64 / mic::SR as f64;
    let (mut samples, mut speech, mut quiet, mut total) = (Vec::<f32>::new(), 0.0f64, 0.0f64, 0.0f64);
    let mut floor = 0.2f32; // the room's level, tracked low
    let mut last_emit = Instant::now();
    let mut first = true;
    loop {
        match stop.try_recv() {
            Ok(false) => return Ok(false),
            Ok(true) if speech >= VP_LEAST => break,
            Ok(true) => {}
            Err(std::sync::mpsc::TryRecvError::Disconnected) => return Ok(false),
            Err(_) => {}
        }
        let f = match rx.recv_timeout(Duration::from_millis(200)) {
            Ok(f) => f,
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => continue,
            Err(_) => return Err("mic_failed".into()),
        };
        if first {
            first = false;
            emit(json!({"phase": "recording", "progress": 0}));
        }
        let lvl = mic::level(&f);
        floor = if lvl < floor { lvl } else { floor + (lvl - floor) * 0.002 };
        let voiced = lvl > 0.3 && lvl > floor + 0.15;
        total += frame_s;
        if voiced {
            speech += frame_s;
            quiet = 0.0;
        } else {
            quiet += frame_s;
        }
        samples.extend_from_slice(&f);
        let progress = (speech / VP_ENOUGH).min(1.0);
        if last_emit.elapsed() >= Duration::from_millis(100) {
            last_emit = Instant::now();
            emit(json!({"phase": "recording", "progress": progress, "level": lvl, "can_finish": speech >= VP_LEAST}));
        }
        // the passage is read (or the reader stopped after enough of it): no need to press Done
        if progress >= 1.0 || (speech >= VP_LEAST && quiet >= 2.5) || total >= VP_MAX {
            if speech < VP_LEAST {
                return Err("too_short".into());
            }
            break;
        }
        if speech < 0.5 && total >= VP_NO_SPEECH {
            return Err("too_short".into());
        }
    }
    mic::write_wav(&vp_wav(), &samples).map_err(|e| e.to_string())?;
    Ok(true)
}

/// Linux: no microphone module yet (dictation is Windows-only).
#[cfg(not(windows))]
fn vp_record(_emit: &dyn Fn(Value), _stop: &std::sync::mpsc::Receiver<bool>) -> Result<bool, String> {
    Err("mic_failed".into())
}

/// Speech recognition back to automatic (asr.auto) and re-picked for this machine.
#[tauri::command(async)]
pub fn asr_auto_apply(state: tauri::State<'_, AppState>) -> R<Value> {
    set_config(&["asr", "auto"], Some(json!(true)));
    state.runner().run("transcribe.py", &["auto".into(), "--apply".into()], None, Duration::from_secs(120)).map_err(String::from)
}

// ------------------------------------------------------------------ agents

/// agents.json: every agent's name, install and sign-in words, processing defaults, and the failure classes.
#[tauri::command]
pub fn agents_registry(app: AppHandle) -> R<Value> {
    read_script_json(&app, "agents.json")
}

/// Connect: the blurt skill and MCP server into the agent (`agents.py install`), a dry run first.
#[tauri::command(async)]
pub fn agents_install(state: tauri::State<'_, AppState>, id: String, dry_run: bool) -> R<Value> {
    let mut args = vec!["install".to_string(), id];
    if dry_run {
        args.push("--dry-run".into());
    }
    state.runner().run("agents.py", &args, None, Duration::from_secs(120)).map_err(String::from)
}

/// One tiny headless prompt through the agent's real command line: it runs and is signed in (a few tokens).
/// → {ok, secs} or {ok: false, class, timeout}.
#[tauri::command(async)]
pub fn agents_test(state: tauri::State<'_, AppState>, id: String) -> R<Value> {
    let runner = state.runner();
    let tmp = std::env::temp_dir().join("blurt-agent-test");
    let _ = std::fs::create_dir_all(&tmp);
    let c = runner
        .run(
            "agents.py",
            &["command".into(), id.clone(), "headless".into(), "--prompt".into(), "Reply with exactly the word: ok".into(), "--repo".into(), scripts::s(&tmp), "--no-events".into()],
            None,
            Duration::from_secs(60),
        )
        .map_err(String::from)?;
    let argv: Vec<String> = c["argv"].as_array().map(|a| a.iter().filter_map(|x| x.as_str().map(str::to_owned)).collect()).unwrap_or_default();
    if argv.is_empty() {
        return Ok(json!({"ok": false, "class": "no_command"}));
    }
    let mut cmd = scripts::command(&argv);
    cmd.current_dir(&tmp).stdin(std::process::Stdio::null()).stdout(std::process::Stdio::piped()).stderr(std::process::Stdio::piped());
    if let Some(env) = c["env"].as_object() {
        for (k, v) in env {
            if let Some(v) = v.as_str() {
                cmd.env(k, v);
            }
        }
    }
    let t0 = Instant::now();
    let child = cmd.spawn().map_err(|e| e.to_string())?;
    match scripts::wait(child, Duration::from_secs(120)) {
        Err(_) => Ok(json!({"ok": false, "timeout": true})),
        Ok((code, out, err)) => {
            let secs = t0.elapsed().as_secs_f64();
            if code == Some(0) && out.to_lowercase().contains("ok") {
                return Ok(json!({"ok": true, "secs": secs}));
            }
            // its reason in words (classify), never an exit code or the raw output (that goes to the log)
            eprintln!("blurt agent test {id}: {code:?}: {}", out.chars().rev().take(600).collect::<String>().chars().rev().collect::<String>());
            let f = tmp.join("out.txt");
            let _ = std::fs::write(&f, format!("{out}\n{err}"));
            let cls = runner.run("agents.py", &["classify".into(), scripts::s(&f)], None, Duration::from_secs(30)).ok();
            Ok(json!({"ok": false, "class": cls.and_then(|v| v.get("class").cloned()).unwrap_or(Value::Null)}))
        }
    }
}

// ------------------------------------------------------------------ feedback

/// Send Feedback (docs/design/feedback.md): feedback.py bundles the chosen dictations — history lines, recordings,
/// the device, the models — into one zip and uploads it. `preview` first says what would go.
#[tauri::command(async)]
pub fn feedback_send(app: AppHandle, ids: Vec<String>, context: bool, preview: Option<bool>) -> R<Value> {
    let mut args = vec![if preview == Some(true) { "preview" } else { "send" }.to_string(), "--ids".into(), ids.join(","), "--app-version".into(), app.package_info().version.to_string(), "--app-build".into(), (if cfg!(windows) { "windows" } else { "linux" }).into()];
    if !context {
        args.push("--no-context".into());
    }
    app.state::<AppState>().runner().run("feedback.py", &args, None, Duration::from_secs(600)).map_err(String::from)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_card_dragged_out_a_week_ago_is_deleted_a_newer_one_stays() {
        let dir = std::env::temp_dir().join(format!("blurt-taken-{}", std::process::id()));
        let s = dir.join("20261020-shots");
        std::fs::create_dir_all(&s).unwrap();
        let now = 2_000_000_000.0;
        let lines = [
            json!({"n": 1, "file": "shots/001.png"}),
            json!({"n": 2, "file": "shots/002.png"}),
            json!({"n": 3, "file": "shots/003.png"}),
            json!({"n": 1, "taken": now - 8.0 * 86_400.0}),
            json!({"n": 2, "taken": now - 86_400.0}),
        ];
        std::fs::write(s.join("shots.jsonl"), lines.iter().map(|l| format!("{l}\n")).collect::<String>()).unwrap();
        assert_eq!(expire_taken_in(&dir, now, false), 1);
        assert_eq!(expire_taken_in(&dir, now, false), 0, "once");
        let raw = std::fs::read_to_string(s.join("shots.jsonl")).unwrap();
        assert!(raw.lines().last().unwrap().contains("\"deleted\":true") && raw.lines().last().unwrap().contains("\"n\":1"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn launch_queue_rule() {
        // the highest rank still true goes up; the first of equals
        assert_eq!(pick(&[(Rank::Model, true), (Rank::Skill, true), (Rank::Project, true)]), Some(1));
        assert_eq!(pick(&[(Rank::Model, true), (Rank::Skill, false)]), Some(0));
        assert_eq!(pick(&[(Rank::Job, true), (Rank::Job, true)]), Some(0));
        assert_eq!(pick(&[]), None);
    }

    #[test]
    fn contract_line() {
        let d = tempfile::tempdir().unwrap();
        std::fs::write(d.path().join("_common.py"), "import os\nCONTRACT = 1  # the handshake\n").unwrap();
        assert_eq!(skill_contract(Some(d.path())), Some(1));
        std::fs::write(d.path().join("_common.py"), "import os\n").unwrap();
        assert_eq!(skill_contract(Some(d.path())), Some(0));
        assert_eq!(mismatch(Some(0)), Some("skill_older"));
        assert_eq!(mismatch(Some(2)), Some("app_older"));
        assert_eq!(mismatch(Some(1)), None);
        assert_eq!(mismatch(None), None);
    }

    #[test]
    fn old_organized_videos_only() {
        let d = tempfile::tempdir().unwrap();
        let s = d.path().join("20260101-100000");
        std::fs::create_dir_all(&s).unwrap();
        std::fs::write(s.join("recording.mp4"), vec![0u8; 1000]).unwrap();
        assert!(videos(&[d.path().to_path_buf()], None, None).is_empty()); // not organized yet
        std::fs::write(s.join("transcript.json"), "{}").unwrap();
        std::fs::write(s.join("batch.json"), r#"{"processing": true}"#).unwrap();
        assert!(videos(&[d.path().to_path_buf()], None, None).is_empty()); // being made
        std::fs::write(s.join("batch.json"), r#"{"processing": false}"#).unwrap();
        let v = videos(&[d.path().to_path_buf()], None, None);
        assert_eq!(v.len(), 1);
        assert_eq!(v[0].bytes, 1000);
        assert!(videos(&[d.path().to_path_buf()], Some(30), None).is_empty()); // made today
        assert!(videos(&[d.path().to_path_buf()], None, Some(&s)).is_empty()); // the take in progress
        stamp(&s, true);
        let m = settings::read_json(&s.join("meta.json")).unwrap();
        assert_eq!(m["mode"], "video");
        assert!(m["video_removed"].is_string());
    }
}
