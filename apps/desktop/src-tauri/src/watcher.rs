//! Keep index.db fresh (§3): `notify` watches every workspace's sessions root; changes are grouped per session dir,
//! debounced 300 ms, then `index.py update <dirs>` runs and the UI gets `index://changed` {sessions}.

use std::collections::{BTreeSet, HashSet};
use std::path::{Path, PathBuf};
use std::sync::mpsc::{channel, RecvTimeoutError};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use notify::{RecursiveMode, Watcher};
use serde_json::json;
use tauri::{AppHandle, Emitter, Manager};

use crate::{paths, scripts, settings, AppState};

const DEBOUNCE: Duration = Duration::from_millis(300);

#[derive(Default)]
pub struct WatchState {
    watcher: Mutex<Option<notify::RecommendedWatcher>>,
    roots: Mutex<Vec<PathBuf>>,
}

/// Sessions roots to watch: the default workspace's recordings, record.workspaces, workspaces already indexed.
pub fn roots(app: &AppHandle) -> Vec<PathBuf> {
    let st = app.state::<AppState>();
    let mut ws: Vec<PathBuf> = vec![paths::default_workspace()];
    let cfg = settings::read_config();
    if let Some(list) = cfg.pointer("/record/workspaces").and_then(|v| v.as_array()) {
        ws.extend(list.iter().filter_map(|v| v.as_str()).map(PathBuf::from));
    }
    if let Some(cur) = cfg.pointer("/record/workspace").and_then(|v| v.as_str()) {
        ws.push(PathBuf::from(cur));
    }
    ws.extend(st.index().workspace_paths());
    let mut seen = HashSet::new();
    ws.into_iter().map(|w| paths::sessions_root(&w)).filter(|r| r.is_dir() && seen.insert(r.clone())).collect()
}

/// `<root>/<session>/…` → `<root>/<session>`; noise (live audio while recording, temp files) → None.
pub fn session_of(roots: &[PathBuf], p: &Path) -> Option<PathBuf> {
    let root = roots.iter().find(|r| p.starts_with(r))?;
    let rel = p.strip_prefix(root).ok()?;
    let mut comps = rel.components();
    let first = comps.next()?;
    let second = comps.next().map(|c| c.as_os_str().to_string_lossy().into_owned());
    let name = p.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    if second.as_deref() == Some("live") || name.ends_with(".tmp") || name.ends_with(".lock") || name == ".DS_Store" {
        return None;
    }
    Some(root.join(first))
}

pub fn start(app: &AppHandle) {
    let (tx, rx) = channel::<notify::Result<notify::Event>>();
    let watcher = match notify::recommended_watcher(tx) {
        Ok(w) => w,
        Err(e) => {
            eprintln!("blurt: file watching unavailable: {e}");
            return;
        }
    };
    let ws = app.state::<WatchState>();
    *ws.watcher.lock().unwrap() = Some(watcher);
    refresh(app);
    let app = app.clone();
    std::thread::spawn(move || {
        let mut pending: BTreeSet<PathBuf> = BTreeSet::new();
        let mut last = Instant::now();
        loop {
            match rx.recv_timeout(Duration::from_millis(100)) {
                Ok(Ok(ev)) => {
                    let roots = app.state::<WatchState>().roots.lock().unwrap().clone();
                    for p in ev.paths {
                        if let Some(s) = session_of(&roots, &p) {
                            pending.insert(s);
                            last = Instant::now();
                        }
                    }
                }
                Ok(Err(_)) => {}
                Err(RecvTimeoutError::Timeout) => {}
                Err(RecvTimeoutError::Disconnected) => break,
            }
            if !pending.is_empty() && last.elapsed() >= DEBOUNCE {
                let dirs: Vec<PathBuf> = std::mem::take(&mut pending).into_iter().collect();
                update(&app, &dirs);
            }
        }
    });
}

/// Watch the current roots (call after a scan or a workspace change).
pub fn refresh(app: &AppHandle) {
    let new = roots(app);
    let ws = app.state::<WatchState>();
    let mut old = ws.roots.lock().unwrap();
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
    for r in &new {
        // the asset protocol may serve frames / clips / shots from these
        let _ = app.asset_protocol_scope().allow_directory(r, true);
    }
    *old = new;
}

pub fn update(app: &AppHandle, dirs: &[PathBuf]) {
    let runner = app.state::<AppState>().runner();
    if runner.has("index.py") && runner.uv.is_some() {
        let mut args = vec!["update".to_string()];
        args.extend(dirs.iter().map(|d| scripts::s(d)));
        if let Err(e) = runner.run("index.py", &args, None, Duration::from_secs(60)) {
            eprintln!("blurt: index.py update: {e}");
        }
    }
    let _ = app.emit("index://changed", json!({"sessions": dirs.iter().map(|d| scripts::s(d)).collect::<Vec<_>>()}));
}

/// Startup: `index.py scan` (rebuilds a missing db; unchanged sessions are skipped), then watch what it found.
pub fn initial_scan(app: &AppHandle) {
    let app = app.clone();
    std::thread::spawn(move || {
        let runner = app.state::<AppState>().runner();
        let _ = app.emit("index://status", json!({"scanning": true}));
        let res = if runner.has("index.py") && runner.uv.is_some() {
            runner.run("index.py", &["scan".into()], None, Duration::from_secs(300)).map_err(String::from)
        } else {
            Err("uv or the blurt scripts are missing: showing the existing index read-only".into())
        };
        let _ = app.emit("index://status", json!({"scanning": false, "result": res.as_ref().ok(), "error": res.as_ref().err()}));
        refresh(&app);
        let _ = app.emit("index://changed", json!({"sessions": []}));
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn maps_paths_to_sessions() {
        let roots = vec![PathBuf::from("/r/.blurt/sessions"), PathBuf::from("/h/Blurt/recordings")];
        let s = |p: &str| session_of(&roots, Path::new(p));
        assert_eq!(s("/r/.blurt/sessions/20261021/items.json"), Some(PathBuf::from("/r/.blurt/sessions/20261021")));
        assert_eq!(s("/h/Blurt/recordings/x/shots/001.png"), Some(PathBuf::from("/h/Blurt/recordings/x")));
        assert_eq!(s("/r/.blurt/sessions/20261021/live/audio.pcm"), None);
        assert_eq!(s("/r/.blurt/sessions/20261021/items.json.123.tmp"), None);
        assert_eq!(s("/elsewhere/items.json"), None);
    }
}
