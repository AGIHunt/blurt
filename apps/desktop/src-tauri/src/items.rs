//! The review component's host (protocol v3) over `items.py` v3 (contract K1): `doc` builds the document from the
//! Markdown items of one session or one project, `poll` answers "changed since this etag?", `user-ops` applies the
//! user's edits. A scope is `{"session": abs}` or `{"project": id | "inbox", "state"?, "kind"?}` (K3; the old
//! `status` / `work` filters still pass through, items.py maps them to states).
//!
//! The component polls every couple of seconds. Each poll would start Python, so we answer from a cache instead
//! while nothing under a store changed: the watcher bumps [`bump`] on every change in a store's `items/` or
//! `sessions/`, and a poll whose etag is the one we last handed out for that scope returns unchanged at once.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;
use std::time::Duration;

use serde_json::{json, Value};

use crate::scripts::Runner;

static GENERATION: AtomicU64 = AtomicU64::new(1);

/// A store changed (the watcher calls this): cached etags are stale.
pub fn bump() {
    GENERATION.fetch_add(1, Ordering::SeqCst);
}

#[derive(Default)]
pub struct DocCache {
    /// scope key → (etag, generation it was computed at)
    last: Mutex<HashMap<String, (String, u64)>>,
    /// scope key → every absolute path the doc last served for it names (frames, clips, attachments, sessions): the
    /// files the page may show in the file manager or open (`listed`)
    files: Mutex<HashMap<String, std::collections::HashSet<String>>>,
}

impl DocCache {
    /// The paths `doc` names, kept for `scope` (replacing what it named before).
    pub fn note_files(&self, scope: &Value, doc: &Value) {
        let mut set = std::collections::HashSet::new();
        let session = scope.get("session").and_then(Value::as_str).map(std::path::Path::new);
        collect_paths(doc.get("items").unwrap_or(&Value::Null), session, &mut set);
        // a session's own recording
        collect_paths(&json!([{"clip": doc.get("source_video").cloned().unwrap_or(Value::Null)}]), session, &mut set);
        self.files.lock().unwrap().insert(scope_key(scope), set);
    }

    /// A doc the page was served names this path (an item's own file says it: the Mac's `attached()`).
    pub fn listed(&self, path: &str) -> bool {
        let want = path_key(path);
        self.files.lock().unwrap().values().any(|s| s.contains(&want))
    }

    fn remember(&self, scope: &Value, etag: &str, generation: u64) {
        self.last.lock().unwrap().insert(scope_key(scope), (etag.to_string(), generation));
    }

    fn fresh(&self, scope: &Value, etag: &str) -> bool {
        let now = GENERATION.load(Ordering::SeqCst);
        self.last.lock().unwrap().get(&scope_key(scope)).is_some_and(|(e, g)| e == etag && *g == now)
    }
}

/// A path as compared: slashes one way, no trailing one; a Windows path (a drive, UNC) without regard to case, as
/// Windows compares them — a POSIX one exactly (Linux's names differ by case).
fn path_key(p: &str) -> String {
    let b = p.as_bytes();
    let windows = p.starts_with("\\\\") || (b.len() > 1 && b[0].is_ascii_alphabetic() && b[1] == b':');
    let k = p.replace('\\', "/");
    let k = k.trim_end_matches('/');
    if windows {
        k.to_lowercase()
    } else {
        k.to_string()
    }
}

/// The files a doc's items name — their pictures (`frames[].path`), recording (`clip`), attached files
/// (`attachments`), capture (`source.session`) and file (`path`) — never words in a field. Absolute paths (POSIX,
/// a Windows drive, UNC); in a session's v2 doc, relative ones under the session.
fn collect_paths(items: &Value, session: Option<&std::path::Path>, out: &mut std::collections::HashSet<String>) {
    let mut add = |v: &Value| {
        let Some(s) = v.as_str().filter(|s| !s.is_empty() && !s.contains('\n') && s.len() < 4096) else { return };
        let b = s.as_bytes();
        let drive = b.len() > 2 && b[0].is_ascii_alphabetic() && b[1] == b':' && (b[2] == b'/' || b[2] == b'\\');
        if s.starts_with('/') || s.starts_with("\\\\") || drive {
            out.insert(path_key(s));
        } else if let Some(root) = session.filter(|_| !s.contains("://") && !s.split(['/', '\\']).any(|c| c == "..")) {
            out.insert(path_key(&root.join(s).to_string_lossy()));
        }
    };
    for it in items.as_array().into_iter().flatten() {
        for f in it.get("frames").and_then(Value::as_array).into_iter().flatten() {
            add(f.get("path").unwrap_or(f));
        }
        match it.get("attachments") {
            Some(Value::Array(a)) => a.iter().for_each(&mut add),
            Some(v) => add(v),
            None => {}
        }
        for k in ["clip", "path"] {
            add(it.get(k).unwrap_or(&Value::Null));
        }
        add(it.pointer("/source/session").unwrap_or(&Value::Null));
    }
}

fn scope_key(scope: &Value) -> String {
    serde_json::to_string(scope).unwrap_or_default()
}

/// `{"session": "/abs"}` → [SESSION]; `{"project": "p", "state": ["new"], …}` → [--project p --state new …].
pub fn scope_args(scope: &Value) -> Result<Vec<String>, String> {
    if let Some(s) = scope.get("session").and_then(Value::as_str) {
        return Ok(vec![s.to_string()]);
    }
    let p = scope.get("project").and_then(Value::as_str).ok_or("scope needs a session or a project")?;
    let mut out = vec!["--project".to_string(), p.to_string()];
    for (key, flag) in [("state", "--state"), ("status", "--status"), ("work", "--work"), ("kind", "--kind")] {
        for v in scope.get(key).and_then(Value::as_array).into_iter().flatten().filter_map(Value::as_str) {
            out.push(flag.into());
            out.push(v.into());
        }
    }
    // the item on show is in its doc whatever the project's doc leaves out (a discarded one selected under the
    // Discarded filter shows itself — the Mac's shownItemArgs)
    if let Some(uid) = scope.get("item").and_then(Value::as_str).filter(|u| !u.is_empty()) {
        out.extend(["--item".to_string(), uid.to_string()]);
    }
    Ok(out)
}

/// → {doc, etag}
pub fn doc(runner: &Runner, cache: &DocCache, scope: &Value) -> Result<Value, String> {
    let generation = GENERATION.load(Ordering::SeqCst);
    let mut args = vec!["doc".to_string()];
    args.extend(scope_args(scope)?);
    let r = runner.run("items.py", &args, None, Duration::from_secs(30)).map_err(String::from)?;
    let etag = r.get("etag").and_then(Value::as_str).unwrap_or("").to_string();
    cache.remember(scope, &etag, generation);
    let doc = r.get("doc").cloned().unwrap_or(Value::Null);
    cache.note_files(scope, &doc);
    Ok(json!({"doc": doc, "etag": etag}))
}

/// → {etag} when unchanged, {doc, etag} otherwise
pub fn poll(runner: &Runner, cache: &DocCache, scope: &Value, etag: &str) -> Result<Value, String> {
    if cache.fresh(scope, etag) {
        return Ok(json!({"etag": etag}));
    }
    let generation = GENERATION.load(Ordering::SeqCst);
    let mut args = vec!["poll".to_string()];
    args.extend(scope_args(scope)?);
    args.extend(["--etag".to_string(), etag.to_string()]);
    let r = runner.run("items.py", &args, None, Duration::from_secs(30)).map_err(String::from)?;
    let now = r.get("etag").and_then(Value::as_str).unwrap_or(etag).to_string();
    cache.remember(scope, &now, generation);
    Ok(match r.get("doc") {
        Some(d) if !d.is_null() => {
            cache.note_files(scope, d);
            json!({"doc": d, "etag": now})
        }
        _ => json!({"etag": now}),
    })
}

/// → {ok, etag, doc}; ops as `items.py user-ops` takes them (set / remove / add / state, ids are uids).
pub fn ops(runner: &Runner, cache: &DocCache, scope: &Value, ops: &Value, confirm: bool) -> Result<Value, String> {
    let body = json!({"ops": ops}).to_string();
    let mut args = vec!["user-ops".to_string()];
    args.extend(scope_args(scope)?);
    args.push("--stdin".into());
    if confirm {
        args.push("--confirm".into());
    }
    let r = runner.run("items.py", &args, Some(body.as_bytes()), Duration::from_secs(30)).map_err(String::from)?;
    bump(); // our own write: every other scope may show these items too
    if let Some(e) = r.get("etag").and_then(Value::as_str) {
        cache.remember(scope, e, GENERATION.load(Ordering::SeqCst));
    }
    if let Some(d) = r.get("doc").filter(|d| !d.is_null()) {
        cache.note_files(scope, d);
    }
    Ok(r)
}

/// `items.py state --action` for the list's own state menu (K3: keep, done, send back, discard, …; only the user
/// keeps, finishes, drops or restores an item).
pub fn state(runner: &Runner, uids: &[String], action: &str, note: Option<&str>) -> Result<Value, String> {
    let mut args = vec!["state".to_string()];
    args.extend(uids.iter().cloned());
    args.extend(["--action".into(), action.into(), "--by".into(), "user".into()]);
    if let Some(n) = note.filter(|n| !n.is_empty()) {
        args.extend(["--note".into(), n.into()]);
    }
    let r = runner.run("items.py", &args, None, Duration::from_secs(30)).map_err(String::from)?;
    bump();
    Ok(r)
}

/// `items.py move` — the user drags items onto a project (K2: a user's choice is never overridden by the AI).
pub fn move_items(runner: &Runner, uids: &[String], project: &str) -> Result<Value, String> {
    let mut args = vec!["move".to_string()];
    args.extend(uids.iter().cloned());
    args.extend(["--project".into(), project.into(), "--by".into(), "user".into()]);
    let r = runner.run("items.py", &args, None, Duration::from_secs(30)).map_err(String::from)?;
    bump();
    Ok(r)
}

/// `items.py state --undo` — ⌘Z / Ctrl+Z after the user's own state change: each item back to the state it had (the
/// user taking back their own step, so it is never recorded as a new decision).
pub fn undo_state(runner: &Runner, uids: &[String], to: &str) -> Result<Value, String> {
    let mut args = vec!["state".to_string()];
    args.extend(uids.iter().cloned());
    args.extend(["--state".into(), to.into(), "--undo".into(), "--by".into(), "user".into()]);
    let r = runner.run("items.py", &args, None, Duration::from_secs(30)).map_err(String::from)?;
    bump();
    Ok(r)
}

/// `items.py add --project P --json ITEM` — New Item (the list heading's + / Ctrl+N, a paste, a drop): kind, title,
/// details, frames. `attachments` (files dropped that aren't pictures, absolute paths) go on with `attach` once the
/// item exists, which references them where they are and copies the ones in a temporary place (`is_temporary`).
pub fn add(runner: &Runner, project: &str, item: &Value) -> Result<Value, String> {
    let mut item = item.clone();
    let files: Vec<String> = item
        .as_object_mut()
        .and_then(|o| o.remove("attachments"))
        .and_then(|a| a.as_array().map(|a| a.iter().filter_map(Value::as_str).map(str::to_owned).collect()))
        .unwrap_or_default();
    let args = vec!["add".to_string(), "--project".into(), project.into(), "--json".into(), item.to_string()];
    let r = runner.run("items.py", &args, None, Duration::from_secs(30)).map_err(String::from)?;
    if let (false, Some(uid)) = (files.is_empty(), r["uid"].as_str()) {
        attach(runner, uid, &[], &files, None, None)?;
    }
    bump();
    Ok(r)
}

/// `items.py attach REF` — something dropped on an item of the main window (drag-drop.md §4): pictures become frames
/// (`frames`: items.py copies them in), other files are referenced by absolute path (`files`; one in a temporary
/// place — a chat app's cache, %TEMP%, /tmp — is copied into the item's assets first: `--keep`), text goes after the
/// details. `restore`: the "before" an earlier attach returned — the Undo. Returns items.py's {before, added}.
pub fn attach(runner: &Runner, uid: &str, frames: &[String], files: &[String], text: Option<&str>, restore: Option<&Value>) -> Result<Value, String> {
    let mut args = vec!["attach".to_string(), uid.to_string()];
    if let Some(before) = restore {
        args.extend(["--restore".into(), before.to_string()]);
    } else {
        let temp = std::env::temp_dir();
        for f in frames {
            args.extend(["--frame".into(), f.clone()]);
        }
        for f in files {
            let flag = if is_temporary(std::path::Path::new(f), &temp) { "--keep" } else { "--file" };
            args.extend([flag.into(), f.clone()]);
        }
        if let Some(t) = text.filter(|t| !t.trim().is_empty()) {
            args.extend(["--text".into(), t.to_string()]);
        }
    }
    let r = runner.run("items.py", &args, None, Duration::from_secs(60)).map_err(String::from)?;
    bump();
    Ok(r)
}

/// A file in a place that empties itself — the system's temporary folder (`temp`: %TEMP% on Windows, $TMPDIR / /tmp
/// elsewhere), any user's AppData\Local\Temp, /tmp, /var/tmp, macOS's /var/folders — so an item can't just point at
/// it: a chat app's cached PDF, a browser's download in progress. Compared without regard to case or slash direction
/// (Windows paths).
pub fn is_temporary(path: &std::path::Path, temp: &std::path::Path) -> bool {
    let norm = |p: &std::path::Path| p.to_string_lossy().replace('\\', "/").to_lowercase();
    let (p, t) = (norm(path), norm(temp));
    let t = t.trim_end_matches('/');
    (!t.is_empty() && p.starts_with(&format!("{t}/")))
        || p.contains("/appdata/local/temp/")
        || ["/tmp/", "/var/tmp/", "/private/tmp/", "/var/folders/", "/private/var/folders/"].iter().any(|d| p.starts_with(d))
}

/// `export_local.py bundle` — Export Hand-off Bundle…: the items as one .zip for someone else (the Mac's
/// MainWindowController.exportBundle). Nothing changes state.
pub fn export_bundle(runner: &Runner, uids: &[String], out: &str, lang: &str) -> Result<Value, String> {
    let mut args = vec!["bundle".to_string(), "--items".into()];
    args.extend(uids.iter().cloned());
    args.extend(["-o".into(), out.into(), "--lang".into(), lang.into()]);
    runner.run("export_local.py", &args, None, Duration::from_secs(300)).map_err(String::from)
}

/// The Fill In Details with AI prompt (the Mac's AgentHub.enrich): the items filed straight from the user's notes get
/// their kind, title and lens fields from one unattended agent run; the user's own words and choices stay.
pub fn enrich_prompt(uids: &[String], scripts: &str, project_path: Option<&str>) -> String {
    // `uv run <scripts>/items.py`: the one form the run's permissions allow (agents.json pins it; organize_prompt.json's
    // scripts hint says so)
    let items = format!("uv run {scripts}/items.py");
    let mut s = format!(
        "Use the blurt skill. These items were filed straight from the user's own notes, without an agent (they carry \
         `enrich: pending`): {}.\nFor each one: `{items} get <uid>`, read it and look at its frames; then set the right kind \
         (issue / idea / note / task) unless the user chose one (it is in the item's `_user`: keep it), a clear title, and \
         what that kind's lens asks for (for an issue: steps, expected / actual, code_refs found in the project's code) with \
         `{items} patch <uid> --set key=VALUE … --unset enrich`. Keep the user's words in quote; don't change status, project \
         or work. This is an unattended background run started by the Blurt app: don't ask questions and don't open the \
         review page. Finish with one sentence.",
        uids.join(", ")
    );
    s.push_str(&crate::agents::scripts_hint(scripts));
    if let Some(p) = project_path.filter(|p| std::path::Path::new(p).is_dir()) {
        s.push_str(&format!("\nThe project's code (read it, change nothing there): {p}"));
    }
    s
}

/// Fill In Details with AI: one background `process` job ("AI fill-in") running the first ready agent headless with the
/// processing model, in a scratch folder (never the project). Ok(job id). The index follows when the run ends.
pub fn enrich(app: &tauri::AppHandle, uids: &[String], project: Option<&str>) -> Result<String, String> {
    use std::process::Stdio;
    use tauri::{Emitter, Manager};
    let state = app.state::<crate::AppState>();
    let runner = state.runner();
    let project = project.filter(|p| *p != "inbox");
    let title = if crate::l10n::lang() == "zh-Hans" { "AI 补全" } else { "AI fill-in" };
    let job = std::sync::Arc::new(crate::jobs::JobWriter::new("process", project, None, None, Some(title), &["prepare", "write"]));
    job.set_items(uids);
    job.step("prepare", "running", None);
    let fail = |job: &crate::jobs::JobWriter, code: &str, msg: &str| {
        job.finish("failed", Some((code, msg)));
        Err::<String, String>(format!("{msg} [{code}]"))
    };
    let agent = match crate::agents::detect(&runner).ok().and_then(|d| d["pick"].as_str().map(str::to_owned)) {
        Some(a) => a,
        None => return fail(&job, "no_agent", "no coding agent is installed and signed in"),
    };
    let scripts = runner.scripts.as_ref().map(|d| crate::scripts::s(d)).unwrap_or_default();
    let reg = crate::projects::Registry::load();
    let ppath = project.and_then(|p| reg.project(p)).and_then(|p| p["path"].as_str()).map(str::to_owned);
    let jobs = crate::paths::jobs_dir();
    let pf = jobs.join(format!("{}.prompt.md", job.id));
    std::fs::write(&pf, enrich_prompt(uids, &scripts, ppath.as_deref())).map_err(|e| format!("{}: {e}", pf.display()))?;
    let cwd = crate::paths::blurt_home().join("tmp").join(&job.id);
    let _ = std::fs::create_dir_all(&cwd);
    let args: Vec<String> = vec![
        "command".into(), agent.clone(), "headless".into(), "--prompt-file".into(), crate::scripts::s(&pf), "--repo".into(),
        crate::scripts::s(&cwd), "--var".into(), format!("run_id={}", job.id), "--processing".into(),
    ];
    let cmd = match runner.run("agents.py", &args, None, Duration::from_secs(30)) {
        Ok(c) => c,
        Err(e) => return fail(&job, "skill", &e.message),
    };
    let argv: Vec<String> = cmd["argv"].as_array().into_iter().flatten().filter_map(|v| v.as_str().map(str::to_owned)).collect();
    if argv.is_empty() {
        return fail(&job, "skill", "this agent has no headless mode");
    }
    let log = std::fs::File::create(jobs.join(format!("{}.log", job.id))).map_err(|e| e.to_string())?;
    let mut c = crate::scripts::command(&argv);
    c.current_dir(&cwd).stdin(Stdio::null()).stdout(log.try_clone().map_err(|e| e.to_string())?).stderr(log);
    c.env("BLURT_JOB", &job.id).env("BLURT_RUN_ID", &job.id).env("BLURT_AGENT", &agent);
    c.env("BLURT_HOME", crate::paths::blurt_home()).env("BLURT_WORKSPACE", crate::paths::default_workspace());
    if let Some(p) = project {
        c.env("BLURT_PROJECT", p);
    }
    for (k, v) in cmd.get("env").and_then(Value::as_object).into_iter().flatten() {
        if let Some(v) = v.as_str() {
            c.env(k, v);
        }
    }
    let mut child = match c.spawn() {
        Ok(ch) => ch,
        Err(e) => return fail(&job, "skill", &format!("couldn't start {}: {e}", argv[0])),
    };
    job.step("prepare", "done", None);
    job.step("write", "running", None);
    let id = job.id.clone();
    // the item files to re-index once the run is over (the sandboxed run doesn't touch index.db)
    let files: Vec<std::path::PathBuf> = uids.iter().filter_map(|u| state.index().item(u).ok().flatten()).filter_map(|r| r["path"].as_str().map(std::path::PathBuf::from)).collect();
    let app2 = app.clone();
    std::thread::spawn(move || {
        let code = child.wait().ok().and_then(|s| s.code());
        let _ = std::fs::remove_dir_all(&cwd);
        if code == Some(0) {
            job.step("write", "done", None);
            job.finish("done", None);
        } else {
            let tail = std::fs::read_to_string(crate::paths::jobs_dir().join(format!("{}.log", job.id))).unwrap_or_default();
            let tail: String = tail.chars().rev().take(4000).collect::<Vec<_>>().into_iter().rev().collect();
            let msg = format!("{} exited with {}", argv[0], code.map_or("a signal".to_string(), |c| c.to_string()));
            job.finish("failed", Some((crate::agents::error_code(&tail), &msg)));
        }
        crate::watcher::update(&app2, &files);
    });
    let _ = app.emit("jobs://started", json!({"id": id}));
    Ok(id)
}

/// The files a row carries when it is dragged out of the window: its first picture, else its .md (the Mac's row drag:
/// Finder makes copies, a chat app takes the picture, a terminal pastes the paths).
pub fn drag_files(rows: &[Value]) -> Vec<std::path::PathBuf> {
    rows.iter()
        .filter_map(|r| {
            let frame = r["primary_frame"].as_str().map(std::path::PathBuf::from).filter(|p| p.is_file());
            frame.or_else(|| r["path"].as_str().map(std::path::PathBuf::from).filter(|p| p.is_file()))
        })
        .collect()
}

/// A picture pasted or dropped into the window (its bytes; WebView2 gives a page no file paths): written to a temporary
/// file New Item can hand to `items.py add` as a frame. `name` keeps the extension.
pub fn save_temp_image(name: &str, bytes: &[u8]) -> Result<String, String> {
    let ext = std::path::Path::new(name).extension().and_then(|e| e.to_str()).map(str::to_lowercase).filter(|e| ["png", "jpg", "jpeg", "gif", "webp", "bmp"].contains(&e.as_str())).unwrap_or_else(|| "png".into());
    let dir = std::env::temp_dir().join("blurt-new-item");
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let stamp = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or(0);
    let p = dir.join(format!("{stamp}.{ext}"));
    std::fs::write(&p, bytes).map_err(|e| e.to_string())?;
    Ok(p.to_string_lossy().into_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn enrich_prompt_and_drag_files() {
        let p = enrich_prompt(&["u1".into(), "u2".into()], "/s", None);
        assert!(p.contains("u1, u2") && p.contains("uv run /s/items.py get <uid>") && p.contains("--unset enrich"), "{p}");
        // the one form the run may use (claude / gemini allow only `uv run <scripts>/<name>.py`)
        assert!(!p.contains("--script") && p.contains("exactly as `uv run /s/<name>.py …`"), "{p}");
        assert!(!p.contains("change nothing there"));
        let d = tempfile::tempdir().unwrap();
        let (f, md) = (d.path().join("a.png"), d.path().join("b.md"));
        std::fs::write(&f, b"x").unwrap();
        std::fs::write(&md, b"x").unwrap();
        let rows = [json!({"primary_frame": f, "path": md}), json!({"primary_frame": null, "path": md}), json!({"path": "/nope"})];
        assert_eq!(drag_files(&rows), vec![f.clone(), md.clone()]);
        let saved = save_temp_image("shot.PNG", b"png").unwrap();
        assert!(saved.ends_with(".png") && std::fs::read(&saved).unwrap() == b"png");
        let _ = std::fs::remove_file(saved);
    }

    #[test]
    fn files_in_temporary_places_are_copied_not_referenced() {
        use std::path::Path;
        let win_temp = Path::new(r"C:\Users\Ana\AppData\Local\Temp");
        assert!(is_temporary(Path::new(r"C:\Users\Ana\AppData\Local\Temp\WeChat Files\a.pdf"), win_temp));
        assert!(is_temporary(Path::new(r"c:\users\ana\appdata\local\temp\x.mp4"), win_temp));
        // another user's temp (an elevated app), and a TEMP moved elsewhere
        assert!(is_temporary(Path::new(r"C:\Users\Admin\AppData\Local\Temp\x.zip"), win_temp));
        assert!(is_temporary(Path::new(r"D:\tmp\scratch\x.zip"), Path::new(r"D:\tmp\")));
        assert!(!is_temporary(Path::new(r"C:\Users\Ana\Documents\spec.pdf"), win_temp));
        assert!(!is_temporary(Path::new(r"C:\Users\Ana\AppData\Local\Templates\a.pdf"), win_temp));
        let linux = Path::new("/tmp");
        assert!(is_temporary(Path::new("/tmp/feishu/a.pdf"), linux));
        assert!(is_temporary(Path::new("/var/tmp/a.pdf"), linux));
        assert!(!is_temporary(Path::new("/home/ana/tmp-notes/a.pdf"), linux));
        assert!(!is_temporary(Path::new("/tmpfile.pdf"), linux));
        assert!(is_temporary(Path::new("/var/folders/x/T/a.pdf"), Path::new("")));
    }

    #[test]
    fn scopes() {
        assert_eq!(scope_args(&json!({"session": "/s/x"})).unwrap(), ["/s/x"]);
        assert_eq!(
            scope_args(&json!({"project": "p", "state": ["new", "to_verify"], "kind": ["issue"]})).unwrap(),
            ["--project", "p", "--state", "new", "--state", "to_verify", "--kind", "issue"]
        );
        assert_eq!(
            scope_args(&json!({"project": "inbox", "status": ["draft"], "work": ["todo", "to_verify"]})).unwrap(),
            ["--project", "inbox", "--status", "draft", "--work", "todo", "--work", "to_verify"]
        );
        assert!(scope_args(&json!({})).is_err());
        assert_eq!(scope_args(&json!({"project": "p", "item": "u1"})).unwrap(), ["--project", "p", "--item", "u1"]);
    }

    #[test]
    fn a_page_may_reveal_only_what_its_doc_names() {
        let c = DocCache::default();
        let doc = json!({"items": [
            {"uid": "u1", "frames": [{"path": "/s/p/.blurt/assets/u1/a.png"}], "attachments": ["/Users/ana/Documents/Spec V2.pdf", r"C:\Users\Ana\clip.mp4"],
             "source": {"session": "/s/p/.blurt/sessions/x"}, "title": "/etc/passwd", "details": "/etc/hosts"},
        ]});
        c.note_files(&json!({"project": "p"}), &doc);
        assert!(c.listed("/Users/ana/Documents/Spec V2.pdf"));
        assert!(c.listed(r"c:\users\ana\CLIP.mp4") && c.listed("C:/Users/Ana/clip.mp4"));
        assert!(c.listed("/s/p/.blurt/assets/u1/a.png") && c.listed("/s/p/.blurt/sessions/x/"));
        // only the fields that name files: a title or the details never do
        assert!(!c.listed("/etc/passwd") && !c.listed("/etc/hosts") && !c.listed("/Users/ana/Documents"));
        // a later doc for the same scope replaces what it named (an attachment removed is no longer revealable)
        c.note_files(&json!({"project": "p"}), &json!({"items": [{"uid": "u1"}]}));
        assert!(!c.listed("/Users/ana/Documents/Spec V2.pdf"));
        // a v2 session doc: its relative frames, under the session
        c.note_files(&json!({"session": "/r/s1"}), &json!({"items": [{"frames": [{"path": "shots/001.png"}, {"path": "../x/y.png"}]}], "source_video": "rec.mp4"}));
        assert!(c.listed("/r/s1/shots/001.png") && c.listed("/r/s1/rec.mp4"));
        assert!(!c.listed("/r/x/y.png") && !c.listed("/r/s1/../x/y.png"));
    }

    #[test]
    fn cache_follows_generation() {
        let c = DocCache::default();
        let s = json!({"project": "p"});
        c.remember(&s, "\"e1\"", GENERATION.load(Ordering::SeqCst));
        assert!(c.fresh(&s, "\"e1\""));
        assert!(!c.fresh(&s, "\"e0\""));
        assert!(!c.fresh(&json!({"project": "q"}), "\"e1\""));
        bump();
        assert!(!c.fresh(&s, "\"e1\""));
    }
}
