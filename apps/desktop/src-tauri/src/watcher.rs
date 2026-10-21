//! Keeping up with the files (contracts K1 / K2 / K4): `notify` watches every store (`<project>/.blurt`, the inbox
//! store), `projects.json` and `jobs/`.
//! * a store change → `index.py update <paths>` (debounced 300 ms), `index://changed`, and the review documents' poll
//!   cache is invalidated;
//! * `projects.json` → the stores to watch are recomputed, `projects://changed`;
//! * `jobs/` → the changed jobs are folded again (debounced 100 ms), `jobs://changed [Job]`, and K4's reminders.
//!
//! Startup: `items.py migrate --all` (v1 / v2 sessions → Markdown, silent), `index.py scan`, `jobs.py gc`.

use std::collections::{BTreeSet, HashMap};
use std::path::{Path, PathBuf};
use std::sync::mpsc::{channel, RecvTimeoutError};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use notify::{RecursiveMode, Watcher};
use serde_json::{json, Value};
use tauri::{AppHandle, Emitter, Manager};

use crate::projects::Registry;
use crate::{island, items, jobs, paths, scripts, AppState};

const STORE_DEBOUNCE: Duration = Duration::from_millis(300);
const JOBS_DEBOUNCE: Duration = Duration::from_millis(100);

#[derive(Default)]
pub struct WatchState {
    watcher: Mutex<Option<notify::RecommendedWatcher>>,
    stores: Mutex<Vec<PathBuf>>,
    /// last folded state of every job seen (for K4's transitions)
    jobs: Mutex<HashMap<String, Value>>,
}

/// What a changed path means for the index: an item file, a session dir, or nothing (noise).
pub fn index_target(stores: &[PathBuf], p: &Path) -> Option<PathBuf> {
    let store = stores.iter().filter(|s| p.starts_with(s)).max_by_key(|s| s.components().count())?;
    let rel = p.strip_prefix(store).ok()?;
    let mut comps = rel.components().map(|c| c.as_os_str().to_string_lossy().into_owned());
    let first = comps.next()?;
    let name = p.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    if name.ends_with(".tmp") || name.ends_with(".lock") || name == ".DS_Store" || name.starts_with(".#") {
        return None;
    }
    match first.as_str() {
        "items" => (rel.components().count() == 2 && name.ends_with(".md")).then(|| p.to_path_buf()),
        "sessions" => {
            let session = comps.next()?;
            if comps.next().as_deref() == Some("live") {
                return None; // live audio while recording
            }
            Some(store.join("sessions").join(session))
        }
        _ => None,
    }
}

pub fn start(app: &AppHandle) {
    let (tx, rx) = channel::<notify::Result<notify::Event>>();
    let mut watcher = match notify::recommended_watcher(tx) {
        Ok(w) => w,
        Err(e) => {
            eprintln!("blurt: file watching unavailable: {e}");
            return;
        }
    };
    let home = paths::blurt_home();
    let _ = std::fs::create_dir_all(paths::jobs_dir());
    let _ = watcher.watch(&home, RecursiveMode::NonRecursive);
    let _ = watcher.watch(&paths::jobs_dir(), RecursiveMode::NonRecursive);
    {
        let ws = app.state::<WatchState>();
        *ws.watcher.lock().unwrap() = Some(watcher);
        *ws.jobs.lock().unwrap() = jobs::list(false, 300).into_iter().filter_map(|j| Some((j["id"].as_str()?.to_string(), j))).collect();
    }
    refresh(app);
    let app = app.clone();
    std::thread::spawn(move || {
        let (mut store_paths, mut job_paths): (BTreeSet<PathBuf>, Vec<PathBuf>) = Default::default();
        let (mut store_at, mut jobs_at) = (Instant::now(), Instant::now());
        let projects_file = paths::projects_file();
        let jobs_dir = paths::jobs_dir();
        loop {
            match rx.recv_timeout(Duration::from_millis(50)) {
                Ok(Ok(ev)) => {
                    let stores = app.state::<WatchState>().stores.lock().unwrap().clone();
                    for p in ev.paths {
                        if p == projects_file {
                            refresh(&app);
                            let _ = app.emit("projects://changed", json!({}));
                            island::refresh(&app);
                        } else if p.parent() == Some(jobs_dir.as_path()) {
                            job_paths.push(p);
                            jobs_at = Instant::now();
                        } else if let Some(t) = index_target(&stores, &p) {
                            store_paths.insert(t);
                            store_at = Instant::now();
                        }
                    }
                }
                Ok(Err(_)) | Err(RecvTimeoutError::Timeout) => {}
                Err(RecvTimeoutError::Disconnected) => break,
            }
            if !job_paths.is_empty() && jobs_at.elapsed() >= JOBS_DEBOUNCE {
                jobs_changed(&app, &std::mem::take(&mut job_paths));
            }
            if !store_paths.is_empty() && store_at.elapsed() >= STORE_DEBOUNCE {
                let dirs: Vec<PathBuf> = std::mem::take(&mut store_paths).into_iter().collect();
                update(&app, &dirs);
            }
        }
    });
}

fn jobs_changed(app: &AppHandle, changed: &[PathBuf]) {
    let ids = jobs::changed_ids(changed);
    let now: Vec<Value> = ids.iter().filter_map(|id| jobs::load(id)).collect();
    if now.is_empty() {
        return;
    }
    let notices = {
        let ws = app.state::<WatchState>();
        let mut known = ws.jobs.lock().unwrap();
        // a job we never saw before is a new one of this run: compare against its first state
        for j in &now {
            let id = j["id"].as_str().unwrap_or("").to_string();
            known.entry(id).or_insert_with(|| json!({"id": j["id"], "type": j["type"], "state": "queued"}));
        }
        let n = jobs::transitions(&known, &now);
        for j in &now {
            known.insert(j["id"].as_str().unwrap_or("").to_string(), j.clone());
        }
        n
    };
    let _ = app.emit("jobs://changed", &now);
    island::notices(app, notices);
}

/// Watch the current stores (after startup and whenever projects.json changes), and let the asset protocol serve them.
pub fn refresh(app: &AppHandle) {
    let mut new = Registry::load().stores();
    new.retain(|s| s.is_dir() || s == &paths::inbox_store());
    let _ = std::fs::create_dir_all(paths::inbox_store());
    let ws = app.state::<WatchState>();
    let mut old = ws.stores.lock().unwrap();
    if let Some(w) = ws.watcher.lock().unwrap().as_mut() {
        for r in old.iter().filter(|r| !new.contains(r)) {
            let _ = w.unwatch(r);
        }
        for r in new.iter().filter(|r| !old.contains(r)) {
            if let Err(e) = w.watch(r, RecursiveMode::Recursive) {
                eprintln!("blurt: can't watch {}: {e}", r.display());
            }
        }
    }
    let scope = app.asset_protocol_scope();
    for r in &new {
        // frames, clips, shots and card thumbnails
        let _ = scope.allow_directory(r, true);
    }
    let _ = scope.allow_directory(paths::handoff_dir(), true);
    *old = new;
}

/// Re-index these items / session dirs, then tell the pages.
pub fn update(app: &AppHandle, targets: &[PathBuf]) {
    let runner = app.state::<AppState>().runner();
    if runner.has("index.py") && runner.uv.is_some() {
        let mut args = vec!["update".to_string()];
        args.extend(targets.iter().map(|d| scripts::s(d)));
        if let Err(e) = runner.run("index.py", &args, None, Duration::from_secs(60)) {
            eprintln!("blurt: index.py update: {e}");
        }
    }
    items::bump();
    let _ = app.emit("index://changed", json!({"paths": targets.iter().map(|d| scripts::s(d)).collect::<Vec<_>>()}));
    if targets.iter().any(|t| t.starts_with(paths::inbox_store())) {
        island::refresh_cards(app);
    }
    island::refresh(app);
}

/// Startup: migrate old sessions, build / refresh the index, tidy old jobs — in the background, silently.
pub fn initial_scan(app: &AppHandle) {
    let app = app.clone();
    std::thread::spawn(move || {
        let runner = app.state::<AppState>().runner();
        let _ = app.emit("index://status", json!({"scanning": true}));
        let ready = runner.has("index.py") && runner.uv.is_some();
        if ready && runner.has("items.py") {
            if let Err(e) = runner.run("items.py", &["migrate".into(), "--all".into()], None, Duration::from_secs(300)) {
                eprintln!("blurt: items.py migrate: {e}");
            }
        }
        if ready && runner.has("projects.py") {
            let _ = runner.run("projects.py", &["migrate".into()], None, Duration::from_secs(60));
        }
        let res = if ready {
            runner.run("index.py", &["scan".into()], None, Duration::from_secs(300)).map_err(String::from)
        } else {
            Err(if runner.uv.is_none() { "uv" } else { "scripts" }.to_string())
        };
        if runner.has("jobs.py") {
            let _ = runner.run("jobs.py", &["gc".into()], None, Duration::from_secs(60));
        }
        let _ = app.emit("index://status", json!({"scanning": false, "error": res.as_ref().err()}));
        refresh(&app);
        items::bump();
        let _ = app.emit("index://changed", json!({"paths": []}));
        island::refresh(&app);
        island::refresh_cards(&app);
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn maps_paths_to_index_targets() {
        let stores = vec![PathBuf::from("/r/.blurt"), PathBuf::from("/h/Blurt/inbox")];
        let t = |p: &str| index_target(&stores, Path::new(p));
        assert_eq!(t("/r/.blurt/items/BA-12-登录.md"), Some(PathBuf::from("/r/.blurt/items/BA-12-登录.md")));
        assert_eq!(t("/r/.blurt/items/.BA-12.md.123.tmp"), None);
        assert_eq!(t("/r/.blurt/sessions/20261021/batch.json"), Some(PathBuf::from("/r/.blurt/sessions/20261021")));
        assert_eq!(t("/h/Blurt/inbox/sessions/x-shots/shots/001.png"), Some(PathBuf::from("/h/Blurt/inbox/sessions/x-shots")));
        assert_eq!(t("/r/.blurt/sessions/20261021/live/audio.pcm"), None);
        assert_eq!(t("/r/.blurt/assets/u1/1.png"), None);
        assert_eq!(t("/r/.blurt/store.json"), None);
        assert_eq!(t("/elsewhere/items/x.md"), None);
    }
}
