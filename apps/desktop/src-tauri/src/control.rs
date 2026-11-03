//! "Set Up with Agent…" on Windows and Linux (docs/design/agent-setup.md; the Mac's App/AgentSetupServer.swift,
//! BlurtCore ControlSocket / AgentSetup, Settings/AgentSetupViews.swift): the running app's control endpoint, through
//! which the user's own agent (`setup.py`, the MCP server's setup_* tools) connects a cloud service, picks a model per
//! job, downloads a speech model and runs a test dictation — what Settings → Models does by hand.
//!
//! Endpoint. The Mac listens on a Unix socket checked with getpeereid; Python on Windows has no AF_UNIX, so here it
//! is 127.0.0.1 on a free port with a random secret in `$BLURT_HOME/run/control.json` {pid, port, token, protocol}
//! — the warm servers' pattern (dictation/server.rs). Only this user can read that file (their profile; 0600 on
//! Unix), so the secret (`auth` in every request) stands where the Mac's same-uid check does. One JSON object per line
//! in, one per line out, then the connection closes; 64 KB at most a request.
//!
//! Consent, as on the Mac (AgentSetupGrant): `hello` and `status` answer anyone holding the secret; `connect`,
//! `test`, `use`, `download` and `verify` need a grant — the session token Blurt hands the agent it starts
//! (`token`, from `sessions.py setup-session`'s environment; 2 h) or the user's Allow in a Blurt dialog (30 min; no
//! answer in 3 min = denied). One question at a time. A key arrives only in `connect`, goes to Credential Manager
//! through the same test-then-save as the Add Cloud Model sheet (dictation::commands::cloud_connect), and is never
//! logged, stored in a file or sent back.
//!
//! The live list (the Mac's AgentSetupProgress) is kept here and sent to Settings as `agent-setup://changed`.

use std::collections::HashMap;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use serde_json::{json, Value};
use tauri::{AppHandle, Emitter, Listener, Manager};

use crate::dictation::{cloud, commands};
use crate::{paths, scripts, settings, AppState};

type R<T> = Result<T, String>;

pub const PROTOCOL: i64 = 1;
const SESSION_TTL: Duration = Duration::from_secs(2 * 3600);
const APPROVAL_TTL: Duration = Duration::from_secs(30 * 60);
const ASK_WAIT: Duration = Duration::from_secs(180);
const MAX_REQUEST: u64 = 64 * 1024;

/// The curated services an agent may connect (Add Cloud Model's list here) and where their keys are made.
const PRESETS: [(&str, &str); 2] = [("deepseek", "DeepSeek"), ("dashscope", "Alibaba Cloud Model Studio (阿里云百炼)")];
/// the speech-only service with two credentials (setup.py PROVIDER_NAMES)
const VOLC_NAME: &str = "Volcengine Speech (火山引擎豆包语音)";
fn key_pages(preset: &str) -> Value {
    match preset {
        "deepseek" => json!({"any": "https://platform.deepseek.com/api_keys"}),
        _ => json!({"china": "https://bailian.console.aliyun.com/?tab=model#/api-key",
                    "global": "https://modelstudio.console.alibabacloud.com/?tab=model#/api-key"}),
    }
}
/// Model Studio's two addresses (polish_cloud.PRESETS; the region picks one)
fn base_url(preset: &str, region: Option<&str>) -> Option<&'static str> {
    (preset == "dashscope" && region == Some("global")).then_some("https://dashscope-intl.aliyuncs.com/compatible-mode/v1")
}

#[derive(Default)]
struct Grants {
    sessions: HashMap<String, Instant>,
    approved_until: Option<Instant>,
}

impl Grants {
    fn allows(&mut self, token: Option<&str>) -> bool {
        let now = Instant::now();
        self.sessions.retain(|_, until| *until > now);
        token.is_some_and(|t| self.sessions.contains_key(t)) || self.approved_until.is_some_and(|u| u > now)
    }
}

#[derive(Default)]
pub struct Control {
    secret: Mutex<String>,
    grants: Mutex<Grants>,
    asking: Mutex<()>,
    /// the live list and whose it is: {active, agent, job, token?, steps: [{kind, subject, state, name}]}
    progress: Mutex<Value>,
}

/// 32 random bytes as hex: std's hash keys come from the OS's random source; a few of them through SHA-1, twice.
fn random_hex() -> String {
    use sha1::{Digest, Sha1};
    use std::hash::{BuildHasher, Hasher};
    let mut out = String::new();
    for round in 0..2u8 {
        let mut h = Sha1::new();
        for i in 0..4u8 {
            let mut x = std::collections::hash_map::RandomState::new().build_hasher();
            x.write_u8(round * 4 + i);
            x.write_u128(std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or(0));
            h.update(x.finish().to_le_bytes());
        }
        h.update(std::process::id().to_le_bytes());
        out.extend(h.finalize().iter().take(16).map(|b| format!("{b:02x}")));
    }
    out
}

pub fn run_file() -> std::path::PathBuf {
    paths::blurt_home().join("run").join("control.json")
}

/// Listen (once, at launch). The Mac app has its own Unix socket; this runs on Windows and Linux.
pub fn start(app: &AppHandle) {
    app.manage(Control::default());
    *app.state::<Control>().progress.lock().unwrap() = json!({"active": false, "steps": []});
    let listener = match TcpListener::bind(("127.0.0.1", 0)) {
        Ok(l) => l,
        Err(e) => return eprintln!("blurt: no control endpoint: {e}"),
    };
    let port = listener.local_addr().map(|a| a.port()).unwrap_or(0);
    let secret = random_hex();
    *app.state::<Control>().secret.lock().unwrap() = secret.clone();
    let f = run_file();
    if let Some(d) = f.parent() {
        let _ = std::fs::create_dir_all(d);
    }
    let body = json!({"pid": std::process::id(), "port": port, "token": secret, "protocol": PROTOCOL}).to_string();
    let tmp = f.with_extension(format!("json.{}.tmp", std::process::id()));
    if std::fs::write(&tmp, body).is_ok() {
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o600));
        }
        let _ = std::fs::rename(&tmp, &f);
    }
    // a download an agent started: its row in the list follows the download
    {
        let h = app.clone();
        app.listen_any("model-download", move |e| {
            let v: Value = serde_json::from_str(e.payload()).unwrap_or_default();
            let st = match v["state"].as_str() {
                Some("done") => "done",
                Some("failed") => "failed",
                Some("stopped") => "failed",
                _ => return,
            };
            if let Some(id) = v["id"].as_str() {
                settle(&h, "download", id, st);
            }
        });
    }
    let app = app.clone();
    std::thread::spawn(move || {
        for s in listener.incoming().flatten() {
            let app = app.clone();
            std::thread::spawn(move || serve(&app, s));
        }
    });
}

/// The run file goes with the app (a stale one would point an agent at a port someone else may hold).
pub fn stop() {
    let f = run_file();
    if settings::read_json(&f).is_some_and(|v| v["pid"] == json!(std::process::id())) {
        let _ = std::fs::remove_file(f);
    }
}

fn serve(app: &AppHandle, s: TcpStream) {
    let _ = s.set_read_timeout(Some(Duration::from_secs(10)));
    let mut line = String::new();
    let mut rd = BufReader::new((&s).take(MAX_REQUEST + 1));
    let n = rd.read_line(&mut line).unwrap_or(0);
    let out = if n as u64 > MAX_REQUEST {
        err("too_long", "the request is longer than 64 KB")
    } else {
        match serde_json::from_str::<Value>(line.trim()) {
            Ok(o) if o.is_object() => handle(app, &o),
            _ => err("bad_request", "send one JSON object per line"),
        }
    };
    let mut w = &s;
    let _ = w.write_all(format!("{out}\n").as_bytes());
}

fn err(code: &str, msg: &str) -> Value {
    json!({"ok": false, "code": code, "error": msg})
}

pub fn handle(app: &AppHandle, o: &Value) -> Value {
    let c = app.state::<Control>();
    // the run file's secret: this user's processes only (constant time)
    let want = c.secret.lock().unwrap().clone();
    let got = o["auth"].as_str().unwrap_or("");
    if got.len() != want.len() || got.bytes().zip(want.bytes()).fold(0u8, |a, (x, y)| a | (x ^ y)) != 0 {
        return err("bad_auth", "the request didn't carry Blurt's run/control.json token");
    }
    let op = o["op"].as_str().unwrap_or("");
    let token = o["token"].as_str();
    // what was asked, never what was sent with it
    eprintln!("blurt agent-setup: {op}{}", o["preset"].as_str().map(|p| format!(" {p}")).unwrap_or_default());
    let needs_grant = matches!(op, "connect" | "test" | "use" | "download" | "verify");
    if needs_grant && !granted(app, token) {
        return err("denied", "the user didn't allow changes in Blurt; ask them to click Allow, or to use Set Up with Agent… in Settings → Models");
    }
    let granted_now = c.grants.lock().unwrap().allows(token);
    match op {
        "hello" => json!({"ok": true, "app": "Blurt", "protocol": PROTOCOL, "pid": std::process::id(),
                          "version": app.package_info().version.to_string(), "granted": granted_now}),
        "status" => status(app, granted_now),
        "connect" => connect(app, o),
        "test" => test(app, o),
        "use" => use_(app, o),
        "download" => download(app, o),
        "verify" => verify(app, o),
        "" => err("bad_request", "no op"),
        _ => err("unknown_op", &format!("unknown op {op}")),
    }
}

/// A live grant, else the user's answer (asked once; requests waiting behind it get it).
fn granted(app: &AppHandle, token: Option<&str>) -> bool {
    let c = app.state::<Control>();
    if c.grants.lock().unwrap().allows(token) {
        return true;
    }
    let _one = c.asking.lock().unwrap();
    if c.grants.lock().unwrap().allows(token) {
        return true;
    }
    let ok = ask(app);
    if ok {
        c.grants.lock().unwrap().approved_until = Some(Instant::now() + APPROVAL_TTL);
        let mut p = c.progress.lock().unwrap();
        if p["active"] != true || p["job"].is_null() {
            if p["active"] != true {
                *p = json!({"active": true, "agent": null, "job": null, "steps": []});
            }
            p["active"] = json!(true);
        }
        drop(p);
        changed(app);
        // the Allow window closes by itself
        let h = app.clone();
        std::thread::spawn(move || {
            std::thread::sleep(APPROVAL_TTL);
            let c = h.state::<Control>();
            let mut p = c.progress.lock().unwrap();
            if p["job"].is_null() {
                p["active"] = json!(false);
            }
            drop(p);
            changed(&h);
        });
    }
    ok
}

/// The question on screen in the main window: (its number, where the answer goes). `agent_setup_answer` fills it.
static ASKING: Mutex<Option<(u64, std::sync::mpsc::Sender<Option<bool>>)>> = Mutex::new(None);
static ASK_N: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

/// Allow / Don't Allow, in Blurt. No answer: no. Asked as Blurt's own confirm sheet in the main window (the same one as
/// Clear History: light or dark with the app, centred on the window): Don't Allow is the focused default, and neither
/// Enter nor Esc can allow — the user may be typing in the agent's terminal when it comes up; only a click on Allow
/// does (the Mac's: Return must not allow). The sheet closes when the wait runs out, so a late click answers nothing.
/// Before the page can show it (no window yet, the page not loaded): Windows' box, with Don't Allow the default.
fn ask(app: &AppHandle) -> bool {
    if std::env::var("BLURT_TEST_COMMANDS").as_deref() == Ok("1") {
        if let Ok(v) = std::env::var("BLURT_TEST_SETUP_ALLOW") {
            return v == "1";
        }
    }
    let t = |k: &str| crate::l10n::t(k);
    crate::show_main(app);
    let id = ASK_N.fetch_add(1, std::sync::atomic::Ordering::SeqCst) + 1;
    let (tx, rx) = std::sync::mpsc::channel::<Option<bool>>();
    *ASKING.lock().unwrap() = Some((id, tx));
    let _ = app.emit(
        "agent-setup://ask",
        json!({"id": id, "title": t("agent_setup.ask.unknown"), "detail": t("agent_setup.ask.detail"),
               "allow": t("agent_setup.ask.allow"), "deny": t("agent_setup.ask.deny")}),
    );
    // the page says it shows the sheet (None) within a moment, then answers
    let shown = matches!(rx.recv_timeout(Duration::from_secs(3)), Ok(None));
    let answer = if shown {
        let start = Instant::now();
        loop {
            let left = ASK_WAIT.saturating_sub(start.elapsed());
            match rx.recv_timeout(left) {
                Ok(Some(a)) => break a,
                Ok(None) => continue,
                Err(_) => break false,
            }
        }
    } else {
        native_ask(app)
    };
    ASKING.lock().unwrap().take();
    let _ = app.emit("agent-setup://ask-close", json!({"id": id}));
    answer
}

/// The page's side of the question: `allow` null when the sheet is up, then true / false.
#[tauri::command]
pub fn agent_setup_answer(id: u64, allow: Option<bool>) {
    if let Some((i, tx)) = ASKING.lock().unwrap().as_ref() {
        if *i == id {
            let _ = tx.send(allow);
        }
    }
}

fn native_ask(app: &AppHandle) -> bool {
    use tauri_plugin_dialog::{DialogExt, MessageDialogButtons, MessageDialogKind};
    let t = |k: &str| crate::l10n::t(k);
    let (tx, rx) = std::sync::mpsc::channel();
    app.dialog()
        .message(t("agent_setup.ask.detail"))
        .title(t("agent_setup.ask.unknown"))
        .kind(MessageDialogKind::Info)
        .buttons(MessageDialogButtons::OkCancelCustom(t("agent_setup.ask.allow"), t("agent_setup.ask.deny")))
        .show(move |ok| {
            let _ = tx.send(ok);
        });
    rx.recv_timeout(ASK_WAIT).unwrap_or(false)
}

// ------------------------------------------------------------------ the live list

fn changed(app: &AppHandle) {
    let v = state_view(app);
    let _ = app.emit("agent-setup://changed", v);
}

fn state_view(app: &AppHandle) -> Value {
    let mut p = app.state::<Control>().progress.lock().unwrap().clone();
    if let Some(o) = p.as_object_mut() {
        o.remove("token");
    }
    p
}

/// One thing done (the Mac's AgentSetupStep): connect / use / download / verify, running → done | failed.
fn step(app: &AppHandle, kind: &str, subject: &str, state: &str, name: &str) {
    {
        let c = app.state::<Control>();
        let mut p = c.progress.lock().unwrap();
        let steps = p["steps"].as_array_mut();
        let Some(steps) = steps else { return };
        if let Some(s) = steps.iter_mut().rev().find(|s| s["kind"] == kind && s["subject"] == subject && s["state"] == "running") {
            s["state"] = json!(state);
            if !name.is_empty() {
                s["name"] = json!(name);
            }
        } else {
            steps.push(json!({"kind": kind, "subject": subject, "state": state, "name": name}));
        }
    }
    changed(app);
}

fn settle(app: &AppHandle, kind: &str, subject: &str, state: &str) {
    let running = app.state::<Control>().progress.lock().unwrap()["steps"]
        .as_array()
        .is_some_and(|a| a.iter().any(|s| s["kind"] == kind && s["subject"] == subject && s["state"] == "running"));
    if running {
        step(app, kind, subject, state, "");
    }
}

// ------------------------------------------------------------------ status

fn machine() -> Value {
    let loc = sys_locale::get_locale().unwrap_or_default();
    let region = loc.split(['-', '_']).nth(1).filter(|r| r.len() == 2).map(|r| r.to_uppercase());
    #[allow(unused_mut)]
    let mut ram_gb: Option<f64> = None;
    #[cfg(windows)]
    unsafe {
        use windows::Win32::System::SystemInformation::{GlobalMemoryStatusEx, MEMORYSTATUSEX};
        let mut m = MEMORYSTATUSEX { dwLength: std::mem::size_of::<MEMORYSTATUSEX>() as u32, ..Default::default() };
        if GlobalMemoryStatusEx(&mut m).is_ok() {
            ram_gb = Some((m.ullTotalPhys as f64 / 1073741824.0 * 10.0).round() / 10.0);
        }
    }
    // the protocol's field is "mac" (setup.py reads it); "os" says which this is
    json!({"chip": std::env::var("PROCESSOR_IDENTIFIER").ok(), "ram_gb": ram_gb, "apple_silicon": false,
           "os": std::env::consts::OS, "macos": null, "languages": [loc], "region": region, "ui_language": crate::l10n::lang()})
}

fn status(app: &AppHandle, granted: bool) -> Value {
    let dm = commands::dictation_models(app.state::<AppState>()).unwrap_or_else(|_| json!({}));
    let sum = cloud::summary();
    let cfg = settings::read_config();
    let jobs_cfg = cfg.pointer("/record/cloud/jobs").cloned().unwrap_or_else(|| json!({}));
    let curated = scripts_json(app, "curated_models.json");
    let mut options = serde_json::Map::new();
    for (job, rows) in curated["jobs"].as_object().cloned().unwrap_or_default() {
        let connected: Vec<String> = sum["services"].as_array().into_iter().flatten().filter_map(|s| s["preset"].as_str().map(str::to_owned)).collect();
        options.insert(job, json!(rows.as_array().into_iter().flatten().map(|o| json!({
            "option": format!("{}:{}", o["service"].as_str().unwrap_or(""), o["model"].as_str().unwrap_or("")),
            "service": o["service"], "model": o["model"], "name": o["name"], "regions": o["regions"],
            "measured": o["measured"], "connected": connected.iter().any(|c| o["service"] == json!(c)),
        })).collect::<Vec<_>>()));
    }
    let models: Vec<Value> = dm["models"].as_array().into_iter().flatten().map(|m| json!({
        "id": m["id"], "name": m["name"], "installed": m["installed"], "size_mb": m["size_mb"], "fits": true, "recommended": m["recommended"],
    })).collect();
    let mut choices: Vec<Value> = vec![json!({"option": "auto"})];
    choices.extend(models.iter().map(|m| json!({"option": m["id"], "name": m["name"], "download_mb": if m["installed"] == true { Value::Null } else { m["size_mb"].clone() }})));
    choices.push(json!({"option": "cloud-polish", "uploads": "text"}));
    for (rec, svc) in [("qwen3-asr-flash", "dashscope"), ("volcengine-seedasr", crate::housekeeping::VOLC_SPEECH)] {
        let connected = sum["services"].as_array().into_iter().flatten().any(|s| s["preset"] == json!(svc));
        choices.push(json!({"option": rec, "uploads": "audio", "service": svc, "connected": connected}));
    }
    let downloads: Vec<Value> = commands::downloading_id().map(|id| json!({"id": id, "running": true})).into_iter().collect();
    let jobs: serde_json::Map<String, Value> = cloud::JOBS
        .iter()
        .map(|j| (j.to_string(), json!({"choice": jobs_cfg.get(*j).cloned().unwrap_or(json!("auto")), "route": sum["routes"][*j]})))
        .collect();
    json!({
        "ok": true, "app": "Blurt", "protocol": PROTOCOL, "mac": machine(),
        "dictation": {"recognizer": dm["selected"], "recommended": dm["recommended"], "recommended_local": dm["recommended"],
                      "auto": cfg.pointer("/record/dictation/asr_model").is_none(), "ready": dm["ready"], "choices": choices, "models": models},
        "polish_local": {"supported": false},
        "downloads": downloads, "download_failed": [],
        "services": sum["services"].as_array().into_iter().flatten().map(|s| json!({
            "id": s["id"], "preset": s["preset"], "name": provider_name(s["preset"].as_str().unwrap_or("")),
            "region": s["region"], "key": s["has_key"],
            "speech": s["preset"] == json!("dashscope") || s["preset"] == json!(crate::housekeeping::VOLC_SPEECH),
            "curated": PRESETS.iter().any(|p| s["preset"] == json!(p.0)) || s["preset"] == json!(crate::housekeeping::VOLC_SPEECH),
        })).collect::<Vec<_>>(),
        "jobs": jobs, "options": options,
        "providers": PRESETS.iter().map(|(p, n)| json!({"preset": p, "name": n, "pair": false, "speech_only": false, "key_pages": key_pages(p)}))
            .chain([json!({"preset": crate::housekeeping::VOLC_SPEECH, "name": VOLC_NAME, "pair": true, "speech_only": true,
                           "key_pages": {"china": "https://console.volcengine.com/speech/app"}})])
            .collect::<Vec<_>>(),
        "progress": state_view(app)["steps"], "granted": granted,
    })
}

fn scripts_json(app: &AppHandle, name: &str) -> Value {
    app.state::<AppState>().runner().scripts.and_then(|d| settings::read_json(&d.join(name))).unwrap_or_else(|| json!({}))
}

// ------------------------------------------------------------------ changes

fn provider_name(preset: &str) -> String {
    if preset == crate::housekeeping::VOLC_SPEECH {
        return VOLC_NAME.into();
    }
    PRESETS.iter().find(|p| p.0 == preset).map_or(preset.to_string(), |p| p.1.to_string())
}

/// The check's code in the agent's words (English; the agent says it in the user's).
fn failure(v: &Value) -> Value {
    let code = v["code"].as_str().unwrap_or("error");
    let msg = match code {
        "auth" => "the key was refused; check the key and its region",
        "network" | "timeout" => "couldn't reach the service; check the network",
        "rate_limited" | "quota" => "the service says too many requests or no quota left; check the account's balance",
        "model" => "the service doesn't know this model id",
        "empty" => "the model answered nothing",
        "no_uv" | "uv_missing" => "Blurt's tools aren't installed yet; open Blurt and finish its setup",
        _ => "the service returned an error",
    };
    json!({"ok": false, "code": code, "error": msg})
}

fn connect(app: &AppHandle, o: &Value) -> Value {
    let preset = o["preset"].as_str().unwrap_or("");
    if preset == crate::housekeeping::VOLC_SPEECH {
        return connect_pair(app, o);
    }
    if !PRESETS.iter().any(|p| p.0 == preset) {
        return err("not_curated", "Blurt connects DeepSeek or Alibaba Cloud Model Studio here; other services are added in Settings → Models");
    }
    let region = o["region"].as_str();
    if region.is_some_and(|r| r != "china" && r != "global") {
        return err("bad_region", "region is china or global");
    }
    let key = o["key"].as_str().map(str::trim).unwrap_or("");
    if key.is_empty() {
        return err("no_key", "no key given");
    }
    if key.chars().any(|c| c.is_whitespace() || c.is_control()) {
        return err("bad_key", "the key has characters no key has (spaces, line breaks); paste it again");
    }
    let name = provider_name(preset);
    step(app, "connect", preset, "running", &name);
    match commands::cloud_connect(app.clone(), preset.to_string(), key.to_string(), base_url(preset, region).map(String::from)) {
        Ok(v) if v["ok"] == true => {
            step(app, "connect", preset, "done", &name);
            json!({"ok": true, "service": preset, "ms": v["ms"], "speech": false})
        }
        Ok(v) => {
            step(app, "connect", preset, "failed", &name);
            failure(&v)
        }
        Err(e) => {
            step(app, "connect", preset, "failed", &name);
            err("error", &e)
        }
    }
}

/// Volcengine Speech: {"app_id", "access_token"}, tested on a short clip and kept as one item (housekeeping.rs
/// `cloud_connect_speech`, as Settings does).
fn connect_pair(app: &AppHandle, o: &Value) -> Value {
    let preset = crate::housekeeping::VOLC_SPEECH;
    let (a, t) = (o["app_id"].as_str().unwrap_or("").trim(), o["access_token"].as_str().unwrap_or("").trim());
    if a.is_empty() || t.is_empty() {
        return err("no_key", "Volcengine Speech takes an App ID and an Access Token");
    }
    let name = provider_name(preset);
    step(app, "connect", preset, "running", &name);
    match crate::housekeeping::cloud_connect_speech(app.state::<AppState>(), a.to_string(), t.to_string()) {
        Ok(v) if v["ok"] == true => {
            step(app, "connect", preset, "done", &name);
            json!({"ok": true, "service": preset, "ms": v["ms"], "speech": true})
        }
        Ok(v) => {
            step(app, "connect", preset, "failed", &name);
            match v["code"].as_str() {
                Some("app_id") => err("bad_key", "that isn't an App ID (letters and digits, from the Volcengine Speech console)"),
                Some("token") => err("bad_key", "the Access Token has characters no token has (spaces, line breaks); paste it again"),
                _ => failure(&v),
            }
        }
        Err(e) => {
            step(app, "connect", preset, "failed", &name);
            err("error", &e)
        }
    }
}

fn find_service(id: &str) -> Option<Value> {
    cloud::setup()["services"].as_array().into_iter().flatten().find(|s| s["id"] == json!(id) || s["preset"] == json!(id)).cloned()
}

fn test(app: &AppHandle, o: &Value) -> Value {
    let Some(s) = o["service"].as_str().and_then(find_service) else { return err("not_connected", "no such service is connected") };
    let id = s["id"].as_str().unwrap_or("");
    let Some(key) = cloud::key(id) else { return err("no_key", "Blurt holds no key for this service") };
    if s["preset"] == json!(crate::housekeeping::VOLC_SPEECH) {
        // the short clip again, with the saved pair
        let a = cloud::volc_split(&key).map(|p| p.0).unwrap_or_default();
        return match crate::housekeeping::cloud_connect_speech(app.state::<AppState>(), a, String::new()) {
            Ok(v) if v["ok"] == true => json!({"ok": true, "service": id, "ms": v["ms"]}),
            Ok(v) => failure(&v),
            Err(e) => err("error", &e),
        };
    }
    match commands::cloud_check(app, s["preset"].as_str().unwrap_or(""), &key, s["base_url"].as_str()) {
        Ok(v) if v["ok"] == true => json!({"ok": true, "service": id, "ms": v["ms"]}),
        Ok(v) => failure(&v),
        Err(e) => err("error", &e),
    }
}

fn use_(app: &AppHandle, o: &Value) -> Value {
    let job = o["job"].as_str().unwrap_or("");
    let option = o["option"].as_str().unwrap_or("").trim();
    if option.is_empty() {
        return err("no_option", "give an option");
    }
    match job {
        "polish" | "translate" | "vision" => {
            let (service, model) = match option {
                "auto" => (None, None),
                "local" => return err("no_option", "this PC runs no local text model; pick a connected service or auto"),
                x => {
                    let (svc, model) = x.split_once(':').map_or((x, None), |(a, b)| (a, Some(b)));
                    let Some(s) = find_service(svc) else { return err("not_connected", &format!("{svc} isn't connected; connect it first")) };
                    let curated = scripts_json(app, "curated_models.json");
                    let ok = model.is_none_or(|m| {
                        curated["jobs"][job].as_array().into_iter().flatten().any(|c| c["service"] == s["preset"] && c["model"] == json!(m))
                    });
                    if !ok {
                        return err("not_curated", "only Blurt's measured models are set from here; other models are a Custom Model in Settings → Models");
                    }
                    (s["id"].as_str().map(str::to_owned), model.map(str::to_owned))
                }
            };
            let name = model.clone().or(service.clone()).unwrap_or_else(|| "auto".into());
            match crate::housekeeping::cloud_job_set(job.to_string(), service, model) {
                Ok(sum) => {
                    step(app, "use", job, "done", &name);
                    json!({"ok": true, "job": job, "route": sum["routes"][job]})
                }
                Err(e) => {
                    step(app, "use", job, "failed", &name);
                    err("error", &e)
                }
            }
        }
        "dictation" => {
            if option == "auto" || option == "cloud-polish" {
                let _ = commands::dictation_use(None);
                step(app, "use", "dictation", "done", option);
                return json!({"ok": true, "job": "dictation", "option": option});
            }
            // a cloud recogniser (setup.py CLOUD_RECOGNIZERS): its service connected first
            if let Some(svc) = [("qwen3-asr-flash", "dashscope"), ("volcengine-seedasr", crate::housekeeping::VOLC_SPEECH)].iter().find(|c| c.0 == option).map(|c| c.1) {
                if find_service(svc).is_none() {
                    return err("not_connected", &format!("{svc} isn't connected; connect it first"));
                }
                if let Err(e) = commands::dictation_use(Some(option.to_string())) {
                    return err("error", &e);
                }
                step(app, "use", "dictation", "done", option);
                return json!({"ok": true, "job": "dictation", "option": option, "uploads": "audio"});
            }
            let dm = commands::dictation_models(app.state::<AppState>()).unwrap_or_else(|_| json!({}));
            let Some(m) = dm["models"].as_array().into_iter().flatten().find(|m| m["id"] == json!(option)).cloned() else {
                return err("unknown_option", "not one of status.dictation.choices");
            };
            let name = m["name"].as_str().unwrap_or(option).to_string();
            if let Err(e) = commands::dictation_use(Some(option.to_string())) {
                step(app, "use", "dictation", "failed", &name);
                return err("error", &e);
            }
            if m["installed"] != true {
                let _ = commands::model_download(app.clone(), option.to_string());
                step(app, "use", "dictation", "running", &name);
                step(app, "download", option, "running", &name);
                return json!({"ok": true, "job": "dictation", "option": option, "downloading": true});
            }
            step(app, "use", "dictation", "done", &name);
            json!({"ok": true, "job": "dictation", "option": option})
        }
        _ => err("unknown_job", "job is polish, translate, vision or dictation"),
    }
}

fn download(app: &AppHandle, o: &Value) -> Value {
    let dm = commands::dictation_models(app.state::<AppState>()).unwrap_or_else(|_| json!({}));
    let want = o["model"].as_str().unwrap_or("recommended");
    let id = if want == "recommended" { dm["recommended"].as_str().unwrap_or("").to_string() } else { want.to_string() };
    let Some(m) = dm["models"].as_array().into_iter().flatten().find(|m| m["id"] == json!(id)).cloned() else {
        return err("unknown_model", "not one of status.dictation.models");
    };
    if m["installed"] == true {
        return json!({"ok": true, "installed": [id]});
    }
    let name = m["name"].as_str().unwrap_or(&id).to_string();
    match commands::model_download(app.clone(), id.clone()) {
        Ok(()) => {
            step(app, "download", &id, "running", &name);
            json!({"ok": true, "started": [id], "size_mb": m["size_mb"]})
        }
        Err(e) if e.contains("already running") => json!({"ok": true, "started": [commands::downloading_id().unwrap_or(id)], "already": true}),
        Err(e) => err("download_failed", &e),
    }
}

// ------------------------------------------------------------------ verify

/// How much of `said` came back in `heard`, 0…1 (BlurtCore AgentSetupVerify.match): one minus the edit distance over
/// the length — by character for Chinese and Japanese, by word otherwise; case, punctuation and spaces ignored.
pub fn match_score(said: &str, heard: &str) -> f64 {
    fn units(s: &str) -> Vec<String> {
        let mut out = Vec::new();
        let mut word = String::new();
        for ch in s.to_lowercase().chars() {
            let cjk = matches!(ch as u32, 0x3040..=0x30FF | 0x3400..=0x9FFF);
            if cjk {
                if !word.is_empty() {
                    out.push(std::mem::take(&mut word));
                }
                out.push(ch.to_string());
            } else if ch.is_whitespace() || ch.is_ascii_punctuation() || "，。！？、；：“”‘’（）".contains(ch) {
                if !word.is_empty() {
                    out.push(std::mem::take(&mut word));
                }
            } else {
                word.push(ch);
            }
        }
        if !word.is_empty() {
            out.push(word);
        }
        out
    }
    let (a, b) = (units(said), units(heard));
    if a.is_empty() {
        return if b.is_empty() { 1.0 } else { 0.0 };
    }
    let mut prev: Vec<usize> = (0..=b.len()).collect();
    for i in 1..=a.len() {
        let mut cur = vec![i; b.len() + 1];
        for j in 1..=b.len() {
            cur[j] = (prev[j] + 1).min(cur[j - 1] + 1).min(prev[j - 1] + usize::from(a[i - 1] != b[j - 1]));
        }
        prev = cur;
    }
    (1.0 - prev[b.len()] as f64 / a.len() as f64).max(0.0)
}

/// The clip for a language ("zh…": Chinese, else English) — the Mac's words.
fn phrase(language: &str) -> (&'static str, &'static str) {
    if language.to_lowercase().starts_with("zh") {
        ("今天下午三点开会，记得带上电脑和会议记录。", "zh-CN")
    } else {
        ("Let's meet at three this afternoon, and please bring the laptop and the notes.", "en-US")
    }
}

/// Windows' own voice (System.Speech) into a 16 kHz mono wav; a voice of the language when one is installed.
fn speak(text: &str, culture: &str, wav: &std::path::Path) -> bool {
    if !cfg!(windows) {
        return false;
    }
    let q = |s: &str| format!("'{}'", s.replace('\'', "''"));
    let script = format!(
        "Add-Type -AssemblyName System.Speech; $s = New-Object System.Speech.Synthesis.SpeechSynthesizer; \
         $v = $s.GetInstalledVoices() | Where-Object {{ $_.VoiceInfo.Culture.Name -eq {c} }} | Select-Object -First 1; \
         if ($v) {{ $s.SelectVoice($v.VoiceInfo.Name) }}; \
         $f = New-Object System.Speech.AudioFormat.SpeechAudioFormatInfo(16000, [System.Speech.AudioFormat.AudioBitsPerSample]::Sixteen, [System.Speech.AudioFormat.AudioChannel]::Mono); \
         $s.SetOutputToWaveFile({w}, $f); $s.Speak({t}); $s.Dispose()",
        c = q(culture),
        w = q(&wav.to_string_lossy()),
        t = q(text)
    );
    let ok = scripts::command(&["powershell".into(), "-NoProfile".into(), "-NonInteractive".into(), "-Command".into(), script])
        .status()
        .is_ok_and(|s| s.success());
    ok && wav.is_file()
}

fn verify(app: &AppHandle, o: &Value) -> Value {
    use crate::dictation::server;
    let dm = commands::dictation_models(app.state::<AppState>()).unwrap_or_else(|_| json!({}));
    if dm["ready"] != true {
        return err("model_missing", "dictation's model isn't downloaded yet; download it first (status: downloads)");
    }
    let lang = o["language"].as_str().map(str::to_owned).unwrap_or_else(|| crate::l10n::lang().to_string());
    let (said, culture) = phrase(&lang);
    step(app, "verify", "", "running", "");
    let dir = paths::blurt_home().join("tmp");
    let _ = std::fs::create_dir_all(&dir);
    let wav = dir.join(format!("agent-verify-{}.wav", &random_hex()[..8]));
    let done = |ok: bool, out: Value| {
        let _ = std::fs::remove_file(&wav);
        step(app, "verify", "", if ok { "done" } else { "failed" }, "");
        out
    };
    if !speak(said, culture, &wav) {
        return done(false, err("no_voice", "Windows couldn't speak the test clip (System.Speech)"));
    }
    let seconds = std::fs::metadata(&wav).map(|m| m.len() as f64 / 32_000.0).unwrap_or(0.0);
    let runner = app.state::<AppState>().runner();
    if !server::running(server::ASR) {
        let _ = server::ensure(&runner, server::ASR, "transcribe.py", &["--preload", "--purpose", "dictation", "--no-download"]);
    }
    let cloud_polish = cloud::payload("polish");
    let polish_on = settings::read_config().pointer("/record/dictation/polish").and_then(Value::as_str) != Some("off");
    if polish_on && cloud_polish.is_some() {
        let _ = server::ensure(&runner, server::POLISH, "polish.py", &[]);
    }
    if !server::wait_ready(server::ASR, Duration::from_secs(60)) {
        return done(false, err("asr_slow", "the recogniser didn't start"));
    }
    let language = settings::read_config().pointer("/record/dictation/language").and_then(Value::as_str).unwrap_or("auto").to_string();
    let t0 = Instant::now();
    let heard = server::call(server::ASR, &json!({"cmd": "note", "wav": wav.to_string_lossy(), "language": language, "purpose": "dictation",
                                                   "vocab": true, "no_download": true, "prior": ""}), Duration::from_secs(90), None);
    let asr_ms = t0.elapsed().as_millis() as u64;
    let Some(raw) = heard.as_ref().filter(|v| v["ok"] == true).and_then(|v| v["text"].as_str()).map(str::to_owned) else {
        let code = heard.as_ref().and_then(|v| v["code"].as_str()).unwrap_or("asr_failed").to_string();
        return done(false, json!({"ok": false, "code": code, "error": "the recogniser didn't answer", "asr_ms": asr_ms}));
    };
    let recognizer = server::call(server::ASR, &json!({"cmd": "ping"}), Duration::from_millis(500), None).and_then(|v| v.get("model").cloned()).unwrap_or(Value::Null);
    let mut text = raw.clone();
    let mut polish = json!({"where": "off"});
    let mut polish_ms = 0;
    if let (true, Some(c)) = (polish_on, cloud_polish) {
        server::wait_ready(server::POLISH, Duration::from_secs(60));
        let t1 = Instant::now();
        if let Some(v) = server::call(server::POLISH, &json!({"cmd": "polish", "text": raw, "timeout": 15.0, "cloud": c}), Duration::from_secs(30), None) {
            if v["ok"] == true {
                if let Some(t) = v["text"].as_str().filter(|t| !t.trim().is_empty()) {
                    text = t.to_string();
                }
            }
            polish = json!({"where": if v["fell_back"] == true { "local" } else { "cloud" }, "model": v["model"], "fell_back": v["fell_back"] == true, "reason": v["reason"]});
        }
        polish_ms = t1.elapsed().as_millis() as u64;
    }
    let m = match_score(said, &text);
    let passed = m >= 0.6;
    done(passed, json!({"ok": true, "passed": passed, "said": said, "heard": raw, "text": text, "match": (m * 100.0).round() / 100.0,
                        "recognizer": recognizer, "polish": polish, "asr_ms": asr_ms, "polish_ms": polish_ms, "audio_s": (seconds * 10.0).round() / 10.0}))
}

// ------------------------------------------------------------------ Settings' side

/// The instruction to paste into the user's own agent (sessions.py SETUP_PROMPT's words, by absolute path).
#[tauri::command]
pub fn agent_setup_instruction(state: tauri::State<'_, AppState>) -> Value {
    let scripts = state.runner().scripts.unwrap_or_default();
    let skill = scripts.parent().map(|p| p.to_path_buf()).unwrap_or_default();
    json!({"guide": scripts::s(&skill.join("reference").join("setup-models.md")), "setup": scripts::s(&scripts.join("setup.py"))})
}

#[tauri::command]
pub fn agent_setup_state(app: AppHandle) -> Value {
    state_view(&app)
}

/// Open in Terminal: `sessions.py setup-session` — the agent in Blurt's terminal on the setup prompt, with a token
/// for this endpoint in its environment (handed over on stdin, never on a command line) → {job}.
#[tauri::command(async)]
pub fn agent_setup_start(app: AppHandle, agent: String) -> R<Value> {
    let c = app.state::<Control>();
    let token = random_hex();
    c.grants.lock().unwrap().sessions.insert(token.clone(), Instant::now() + SESSION_TTL);
    let runner = app.state::<AppState>().runner();
    let stdin = json!({"token": token}).to_string();
    let runner_kind = if cfg!(windows) { "app" } else { "auto" };
    let r = runner.run(
        "sessions.py",
        &["setup-session".into(), "--agent".into(), agent.clone(), "--runner".into(), runner_kind.into(), "--lang".into(), crate::l10n::short_lang().into()],
        Some(stdin.as_bytes()),
        Duration::from_secs(90),
    );
    let r = match r {
        Ok(v) => v,
        Err(e) => {
            c.grants.lock().unwrap().sessions.remove(&token);
            return Err(e.to_string());
        }
    };
    crate::sessions::launch(&app, &r);
    let job = r["job"].as_str().or_else(|| r["jobs"][0]["id"].as_str()).map(str::to_owned);
    let name = crate::sessions::detect_with(&runner, false, Some(std::slice::from_ref(&agent)))
        .ok()
        .and_then(|d| d["agents"].as_array().and_then(|a| a.iter().find(|x| x["id"] == json!(agent)).and_then(|x| x["name"].as_str().map(str::to_owned))))
        .unwrap_or(agent);
    *c.progress.lock().unwrap() = json!({"active": true, "agent": name, "job": job, "token": token, "steps": []});
    changed(&app);
    Ok(json!({"job": job}))
}

/// Stop: the session ends and nothing may change things until asked again.
#[tauri::command(async)]
pub fn agent_setup_stop(app: AppHandle) -> Value {
    let c = app.state::<Control>();
    let (job, _) = {
        let p = c.progress.lock().unwrap();
        (p["job"].as_str().map(str::to_owned), ())
    };
    let mut stop_error = Value::Null;
    if let Some(j) = &job {
        if let Err(e) = crate::sessions::stop(&app, &app.state::<AppState>().runner(), j, false) {
            stop_error = json!(e);
        }
    }
    *c.grants.lock().unwrap() = Grants::default();
    {
        let mut p = c.progress.lock().unwrap();
        p["active"] = json!(false);
        p["stop_error"] = stop_error;
        if let Some(o) = p.as_object_mut() {
            o.remove("token");
        }
    }
    changed(&app);
    state_view(&app)
}

/// Done: the list goes once the user has read it.
#[tauri::command]
pub fn agent_setup_dismiss(app: AppHandle) {
    *app.state::<Control>().progress.lock().unwrap() = json!({"active": false, "steps": []});
    changed(&app);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn verify_match_as_the_mac() {
        assert_eq!(match_score("Let's meet at three", "let's meet at three."), 1.0);
        assert!(match_score("今天下午三点开会", "今天下午三点开会。") > 0.99);
        assert!((match_score("a b c d", "a b x d") - 0.75).abs() < 1e-9);
        assert_eq!(match_score("", ""), 1.0);
        assert_eq!(match_score("", "x"), 0.0);
    }

    #[test]
    fn grants_expire_and_tokens_differ() {
        let mut g = Grants::default();
        assert!(!g.allows(None));
        g.sessions.insert("t".into(), Instant::now() + Duration::from_secs(60));
        assert!(g.allows(Some("t")) && !g.allows(Some("u")));
        g.approved_until = Some(Instant::now() + Duration::from_secs(60));
        assert!(g.allows(None));
        let (a, b) = (random_hex(), random_hex());
        assert_eq!(a.len(), 64);
        assert_ne!(a, b);
    }
}
