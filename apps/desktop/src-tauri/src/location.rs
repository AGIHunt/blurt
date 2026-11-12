//! Where Blurt keeps its data (Settings → Storage → Data location; docs/guide.md §Storage).
//!
//!   the pointer       `<config dir>/Blurt/location.json` (Windows `%APPDATA%\Blurt`, Linux `~/.config/Blurt`), outside
//!                     the data so it survives a move: {"home", "workspace", "own_caches", "cleanup"}. Choosing folder X
//!                     means home = X\.blurt and workspace = X (the inbox store at X\inbox). No pointer: the default,
//!                     ~/.blurt and ~/Blurt. `_common.py` reads the same file, for the scripts run outside the app.
//!   at startup        `init`, first thing in `run()`, before any thread or child: the pointer read once, then
//!                     BLURT_HOME, BLURT_WORKSPACE — and, for a chosen folder, UV_CACHE_DIR, UV_PYTHON_INSTALL_DIR and
//!                     HF_HOME inside it — put in our environment, so every script, uv and Hugging Face agree with
//!                     paths.rs. A variable the user set wins (and locks the location: Change… says why). The names we
//!                     set are listed in BLURT_LOCATION_ENV, so a Blurt started by this one (a restart, the updater's
//!                     installer) recomputes them instead of taking them as the user's.
//!   the legacy guard  Windows, before v1.0.20 paths.rs honoured HOME: no pointer, HOME set, HOME\.blurt\config.json
//!                     there and none in the profile → a pointer to HOME's folders (own_caches off: uv and Hugging
//!                     Face keep their usual folders), so nothing seems lost.
//!   moving            `storage_location_move`: refused while a recording, a dictation, a model download or a job
//!                     runs; the warm model servers ended; home + inbox (+ v0.6 recordings) copied with progress
//!                     events (`storage://move`), a second pass for what changed meanwhile, sizes verified; the
//!                     absolute paths in home's JSON files rebased; the pointer written with the old folders under
//!                     `cleanup`; the app restarts. The index isn't copied: the startup scan rebuilds it.
//!   cleanup           at the next launch, once Blurt runs from the new place, the old folders are deleted in the
//!                     background (only Blurt's own: a .blurt, an inbox, a recordings folder; the old workspace folder
//!                     only when that leaves it empty); what couldn't go stays listed and is tried again next time.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::OnceLock;
use std::time::{Duration, Instant, SystemTime};

use serde_json::{json, Value};
use tauri::{AppHandle, Emitter, Manager};

use crate::{paths, scripts, AppState};

type R<T> = Result<T, String>;

/// The variables a previous Blurt exported (comma-separated): not the user's.
const MARK: &str = "BLURT_LOCATION_ENV";
pub const VARS: [&str; 5] = ["BLURT_HOME", "BLURT_WORKSPACE", "UV_CACHE_DIR", "UV_PYTHON_INSTALL_DIR", "HF_HOME"];
/// Room left over on the new drive beyond what is copied.
const MARGIN: u64 = 200_000_000;

#[derive(Debug, Clone, PartialEq, Default)]
pub struct Pointer {
    pub home: PathBuf,
    pub workspace: PathBuf,
    /// uv's cache, uv's Pythons and Hugging Face's cache live in home too (cache/uv, python, cache/huggingface)
    pub own_caches: bool,
    /// the folders a move left behind, deleted once Blurt runs from the new place
    pub cleanup: Vec<PathBuf>,
}

impl Pointer {
    /// A folder the user chose: X\.blurt and X.
    pub fn for_folder(folder: &Path) -> Pointer {
        Pointer { home: folder.join(".blurt"), workspace: folder.to_path_buf(), own_caches: true, cleanup: vec![] }
    }

    /// The default location, as a pointer (only written while it still has old folders to clean up).
    pub fn default_for(profile: &Path) -> Pointer {
        Pointer { home: profile.join(".blurt"), workspace: profile.join("Blurt"), own_caches: false, cleanup: vec![] }
    }

    pub fn is_default(&self, profile: &Path) -> bool {
        let d = Pointer::default_for(profile);
        self.home == d.home && self.workspace == d.workspace && !self.own_caches
    }

    pub fn parse(v: &Value) -> Option<Pointer> {
        let path = |k: &str| v.get(k).and_then(Value::as_str).filter(|s| !s.is_empty()).map(PathBuf::from).filter(|p| p.is_absolute());
        Some(Pointer {
            home: path("home")?,
            workspace: path("workspace")?,
            own_caches: v.get("own_caches").and_then(Value::as_bool).unwrap_or(true),
            cleanup: v
                .get("cleanup")
                .and_then(Value::as_array)
                .map(|a| a.iter().filter_map(Value::as_str).map(PathBuf::from).filter(|p| p.is_absolute()).collect())
                .unwrap_or_default(),
        })
    }

    pub fn to_json(&self) -> Value {
        let mut v = json!({"home": scripts::s(&self.home), "workspace": scripts::s(&self.workspace), "own_caches": self.own_caches});
        if !self.cleanup.is_empty() {
            v["cleanup"] = json!(self.cleanup.iter().map(|p| scripts::s(p)).collect::<Vec<_>>());
        }
        v
    }
}

/// `<config dir>/Blurt/location.json`; `BLURT_LOCATION_FILE` instead (tests).
pub fn pointer_file() -> Option<PathBuf> {
    if let Some(f) = std::env::var_os("BLURT_LOCATION_FILE").filter(|f| !f.is_empty()) {
        return Some(PathBuf::from(f));
    }
    dirs::config_dir().map(|d| d.join("Blurt").join("location.json"))
}

pub fn read_pointer(file: &Path) -> Option<Pointer> {
    Pointer::parse(&serde_json::from_str(&std::fs::read_to_string(file).ok()?).ok()?)
}

/// Atomic; None removes the file.
pub fn write_pointer(file: &Path, p: Option<&Pointer>) -> std::io::Result<()> {
    let Some(p) = p else {
        return match std::fs::remove_file(file) {
            Err(e) if e.kind() != std::io::ErrorKind::NotFound => Err(e),
            _ => Ok(()),
        };
    };
    if let Some(d) = file.parent() {
        std::fs::create_dir_all(d)?;
    }
    let tmp = file.with_extension(format!("json.{}.tmp", std::process::id()));
    std::fs::write(&tmp, serde_json::to_vec_pretty(&p.to_json()).unwrap_or_default())?;
    std::fs::rename(&tmp, file)
}

/// Windows before v1.0.20: the data under a HOME that isn't the profile, none in the profile → keep using HOME's.
pub fn legacy(home_env: Option<&Path>, profile: &Path) -> Option<Pointer> {
    let h = home_env.filter(|h| h.is_absolute() && *h != profile)?;
    let (here, there) = (h.join(".blurt").join("config.json"), profile.join(".blurt").join("config.json"));
    (here.is_file() && !there.is_file()).then(|| Pointer { home: h.join(".blurt"), workspace: h.join("Blurt"), own_caches: false, cleanup: vec![] })
}

/// What goes in our environment (pure): `user` = the variables the user set, never replaced.
pub fn exports(ptr: Option<&Pointer>, profile: &Path, user: &[&str]) -> Vec<(&'static str, PathBuf)> {
    let d = Pointer::default_for(profile);
    let p = ptr.unwrap_or(&d);
    let mut v = vec![("BLURT_HOME", p.home.clone()), ("BLURT_WORKSPACE", p.workspace.clone())];
    // caches in the data folder only for a folder the user chose, and only when home is the pointer's
    if p.own_caches && ptr.is_some() && !user.contains(&"BLURT_HOME") {
        v.push(("UV_CACHE_DIR", p.home.join("cache").join("uv")));
        v.push(("UV_PYTHON_INSTALL_DIR", p.home.join("python")));
        v.push(("HF_HOME", p.home.join("cache").join("huggingface")));
    }
    v.retain(|(k, _)| !user.contains(k));
    v
}

struct Resolved {
    pointer: Option<Pointer>,
    /// the variables the user set themselves
    user: Vec<&'static str>,
}

static RESOLVED: OnceLock<Resolved> = OnceLock::new();

/// First thing in `run()`: no thread has started yet, so changing the environment is safe.
pub fn init() {
    if let Some(m) = std::env::var_os(MARK) {
        for k in m.to_string_lossy().split(',').filter(|k| VARS.contains(k)) {
            std::env::remove_var(k);
        }
        std::env::remove_var(MARK);
    }
    let user: Vec<&'static str> = VARS.iter().copied().filter(|k| std::env::var_os(k).is_some_and(|v| !v.is_empty())).collect();
    let profile = paths::home();
    let file = pointer_file();
    let mut pointer = file.as_deref().and_then(read_pointer);
    if pointer.is_none() && cfg!(windows) && !user.contains(&"BLURT_HOME") {
        let home_env = std::env::var_os("HOME").filter(|h| !h.is_empty()).map(PathBuf::from);
        if let Some(p) = legacy(home_env.as_deref(), &profile) {
            if let Some(f) = &file {
                let _ = write_pointer(f, Some(&p));
            }
            pointer = Some(p);
        }
    }
    let mut set = Vec::new();
    for (k, v) in exports(pointer.as_ref(), &profile, &user) {
        std::env::set_var(k, v);
        set.push(k);
    }
    if !set.is_empty() {
        std::env::set_var(MARK, set.join(","));
    }
    let _ = RESOLVED.set(Resolved { pointer, user });
}

fn resolved() -> Option<&'static Resolved> {
    RESOLVED.get()
}

/// From setup: the asset protocol serves the data wherever it is (the static scope only knows ~/.blurt and ~/Blurt),
/// and the folders an earlier move left behind go, in the background.
pub fn start(app: &AppHandle) {
    let scope = app.asset_protocol_scope();
    let _ = scope.allow_directory(paths::blurt_home(), true);
    let _ = scope.allow_directory(paths::default_workspace(), true);
    let Some(p) = resolved().and_then(|r| r.pointer.clone()) else { return };
    if p.cleanup.is_empty() && !p.is_default(&paths::home()) {
        return;
    }
    std::thread::spawn(move || {
        // the new place is the one in use: only then is the old copy let go
        if paths::blurt_home() != p.home || !p.home.is_dir() {
            return;
        }
        let keep = [paths::blurt_home(), paths::default_workspace()];
        let left: Vec<PathBuf> = p.cleanup.iter().filter(|c| !remove_old(c, &keep)).cloned().collect();
        let Some(file) = pointer_file() else { return };
        let next = Pointer { cleanup: left, ..p.clone() };
        let _ = if next.cleanup.is_empty() && next.is_default(&paths::home()) { write_pointer(&file, None) } else { write_pointer(&file, Some(&next)) };
    });
}

/// An old folder of Blurt's own (a .blurt, an inbox, a v0.6 recordings folder; any other folder only when empty).
/// Never one that holds, or is inside, a folder in use. → it is gone.
pub fn remove_old(p: &Path, keep: &[PathBuf]) -> bool {
    if !p.exists() {
        return true;
    }
    if p.parent().is_none() || keep.iter().any(|k| k.starts_with(p) || p.starts_with(k)) {
        return true; // never ours to delete: drop it from the list
    }
    let name = p.file_name().map(|n| n.to_string_lossy().to_lowercase()).unwrap_or_default();
    if matches!(name.as_str(), ".blurt" | "inbox" | "recordings") && p.is_dir() {
        let _ = std::fs::remove_dir_all(p);
        return !p.exists();
    }
    // the old workspace: only when nothing else is in it
    if std::fs::read_dir(p).is_ok_and(|mut it| it.next().is_none()) {
        return std::fs::remove_dir(p).is_ok();
    }
    true // something of the user's is in it, or it isn't a folder: left alone, not tried again
}

// ------------------------------------------------------------------ the move, pure parts

/// What the user picked → the data folder: itself when it is named Blurt, else a Blurt folder in it (D:\ → D:\Blurt).
pub fn target_folder(picked: &Path) -> PathBuf {
    if picked.file_name().is_some_and(|n| n.to_string_lossy().eq_ignore_ascii_case("blurt")) {
        picked.to_path_buf()
    } else {
        picked.join("Blurt")
    }
}

/// Lexical, with Windows' case-insensitive compare.
fn inside(a: &Path, b: &Path) -> bool {
    if cfg!(windows) {
        let l = |p: &Path| PathBuf::from(scripts::s(&paths::normalize(p)).replace('/', "\\").to_lowercase());
        l(a).starts_with(l(b))
    } else {
        paths::normalize(a).starts_with(paths::normalize(b))
    }
}

/// Why the data can't go from (home, workspace) to `to`; None when it can (pure apart from reading the target).
pub fn refusal(home: &Path, workspace: &Path, to: &Pointer) -> Option<&'static str> {
    let (inbox, to_inbox) = (workspace.join("inbox"), to.workspace.join("inbox"));
    if inside(&to.home, home) && inside(home, &to.home) {
        return Some("same");
    }
    for new in [&to.home, &to_inbox, &to.workspace] {
        if inside(new, home) || inside(new, &inbox) {
            return Some("inside_current");
        }
    }
    for new in [&to.home, &to_inbox] {
        if inside(home, new) || inside(&inbox, new) {
            return Some("contains_current");
        }
    }
    let has = |p: &Path| std::fs::read_dir(p).is_ok_and(|mut d| d.next().is_some());
    if has(&to.home) || has(&to_inbox) {
        return Some("has_data");
    }
    None
}

/// A path under one of home's folders that isn't copied: run state, temporary files, the index (rebuilt at the next
/// launch), uv's script environments (they name the old Python's path; uv makes them again from its cache), and the
/// caches when they don't move with the data.
pub fn skipped(rel: &Path, keep_caches: bool) -> bool {
    let c: Vec<String> = rel.components().map(|c| c.as_os_str().to_string_lossy().into_owned()).collect();
    match c.first().map(String::as_str) {
        Some("run" | "tmp") => true,
        Some("index.db" | "index.db-wal" | "index.db-shm") => c.len() == 1,
        Some("cache" | "python") if !keep_caches => true,
        Some("cache") => c.get(1).is_some_and(|x| x == "uv") && c.get(2).is_some_and(|x| x.starts_with("environments-v")),
        _ => false,
    }
}

/// `s` when it is `old` or under it → the same path under `new` (Windows: either slash, ASCII case ignored).
pub fn rebase(s: &str, old: &str, new: &str, windows: bool) -> Option<String> {
    let old = old.trim_end_matches(['/', '\\']);
    if old.is_empty() {
        return None;
    }
    let sep = |c: char| c == '/' || (windows && c == '\\');
    let same = |a: char, b: char| a == b || (windows && ((sep(a) && sep(b)) || a.eq_ignore_ascii_case(&b)));
    let mut it = s.char_indices();
    for o in old.chars() {
        match it.next() {
            Some((_, c)) if same(c, o) => {}
            _ => return None,
        }
    }
    let rest = &s[it.next().map_or(s.len(), |(i, _)| i)..];
    if !rest.is_empty() && !rest.starts_with(sep) {
        return None;
    }
    Some(format!("{}{rest}", new.trim_end_matches(['/', '\\'])))
}

/// Every string in `v` rebased by the first pair that applies → whether anything changed.
pub fn rebase_json(v: &mut Value, pairs: &[(String, String)], windows: bool) -> bool {
    match v {
        Value::String(s) => match pairs.iter().find_map(|(o, n)| rebase(s, o, n, windows)) {
            Some(n) if n != *s => {
                *s = n;
                true
            }
            _ => false,
        },
        Value::Array(a) => a.iter_mut().fold(false, |ch, x| rebase_json(x, pairs, windows) | ch),
        Value::Object(o) => o.values_mut().fold(false, |ch, x| rebase_json(x, pairs, windows) | ch),
        _ => false,
    }
}

/// The JSON files in the new home that may name the old folders (config.json, projects.json, …, and the jobs).
fn rebase_files(home: &Path, pairs: &[(String, String)]) {
    let files = [home.to_path_buf(), home.join("jobs")]
        .into_iter()
        .flat_map(|d| std::fs::read_dir(d).into_iter().flatten().filter_map(Result::ok).map(|e| e.path()))
        .filter(|p| p.extension().is_some_and(|e| e == "json") && p.is_file());
    for f in files {
        let Some(mut v) = crate::settings::read_json(&f) else { continue };
        if rebase_json(&mut v, pairs, cfg!(windows)) {
            let tmp = f.with_extension(format!("json.{}.tmp", std::process::id()));
            if std::fs::write(&tmp, serde_json::to_vec_pretty(&v).unwrap_or_default()).is_ok() {
                let _ = std::fs::rename(&tmp, &f);
            }
        }
    }
}

// ------------------------------------------------------------------ copying

struct File {
    src: PathBuf,
    dst: PathBuf,
    len: u64,
    modified: Option<SystemTime>,
}

/// The files under `src` (links not followed: uv's version links point at the old place) → `dst`, minus `skip`.
fn walk(src: &Path, dst: &Path, rel: &Path, skip: &dyn Fn(&Path) -> bool, out: &mut Vec<File>) {
    for e in std::fs::read_dir(src.join(rel)).into_iter().flatten().filter_map(Result::ok) {
        let r = rel.join(e.file_name());
        if skip(&r) {
            continue;
        }
        let Ok(m) = std::fs::symlink_metadata(e.path()) else { continue };
        if m.file_type().is_symlink() {
            continue;
        }
        if m.is_dir() {
            walk(src, dst, &r, skip, out);
        } else {
            out.push(File { src: src.join(&r), dst: dst.join(&r), len: m.len(), modified: m.modified().ok() });
        }
    }
}

/// The trees a move copies: (from, to, skip by path relative to `from`).
struct Tree {
    from: PathBuf,
    to: PathBuf,
    home: bool,
}

fn trees(home: &Path, workspace: &Path, to: &Pointer) -> Vec<Tree> {
    let mut v = vec![
        Tree { from: home.to_path_buf(), to: to.home.clone(), home: true },
        Tree { from: workspace.join("inbox"), to: to.workspace.join("inbox"), home: false },
    ];
    if workspace.join("recordings").is_dir() {
        v.push(Tree { from: workspace.join("recordings"), to: to.workspace.join("recordings"), home: false });
    }
    v
}

fn list(trees: &[Tree], keep_caches: bool) -> Vec<File> {
    let mut out = Vec::new();
    for t in trees {
        let home = t.home;
        walk(&t.from, &t.to, Path::new(""), &|r: &Path| home && skipped(r, keep_caches), &mut out);
    }
    out
}

/// The bytes a move to `to` copies (the current caches only when they go along).
fn bytes_to_move(to: &Pointer) -> u64 {
    list(&trees(&paths::blurt_home(), &paths::default_workspace(), to), keep_caches(to)).iter().map(|f| f.len).sum()
}

/// The caches in home go along only when they live there now and will at the new place.
fn keep_caches(to: &Pointer) -> bool {
    to.own_caches && current_caches_ours()
}

/// uv's cache is in the data folder now (a chosen folder; not the legacy pointer, not a user's own UV_CACHE_DIR).
fn current_caches_ours() -> bool {
    std::env::var_os("UV_CACHE_DIR").is_some_and(|v| Path::new(&v).starts_with(paths::blurt_home()))
}

fn copy_files(files: &[File], done: &mut u64, total: u64, tick: &mut dyn FnMut(u64, u64)) -> R<()> {
    let mut last = Instant::now();
    for f in files {
        if let Some(d) = f.dst.parent() {
            std::fs::create_dir_all(d).map_err(|e| format!("{}: {e}", d.display()))?;
        }
        std::fs::copy(&f.src, &f.dst).map_err(|e| format!("{}: {e}", f.src.display()))?;
        *done += f.len;
        if last.elapsed() > Duration::from_millis(150) {
            tick(*done, total);
            last = Instant::now();
        }
    }
    Ok(())
}

/// Copy, then once more what changed while copying (a dictation's history line, a job's log), then check each file's
/// size against its source.
fn copy_trees(trees: &[Tree], keep_caches: bool, tick: &mut dyn FnMut(u64, u64)) -> R<()> {
    let first = list(trees, keep_caches);
    let total: u64 = first.iter().map(|f| f.len).sum();
    let mut done = 0;
    copy_files(&first, &mut done, total, tick)?;
    let seen: std::collections::HashMap<&Path, (u64, Option<SystemTime>)> = first.iter().map(|f| (f.src.as_path(), (f.len, f.modified))).collect();
    let second = list(trees, keep_caches);
    let changed: Vec<File> = second.into_iter().filter(|f| seen.get(f.src.as_path()) != Some(&(f.len, f.modified))).collect();
    let mut extra = 0;
    copy_files(&changed, &mut extra, 0, &mut |_, _| {})?;
    for f in list(trees, keep_caches) {
        let got = std::fs::metadata(&f.dst).map(|m| m.len()).ok();
        if got != Some(f.len) {
            return Err(format!("{}: copied {} of {} bytes", f.dst.display(), got.unwrap_or(0), f.len));
        }
    }
    tick(total, total);
    Ok(())
}

// ------------------------------------------------------------------ what's running

/// What must end before the data can move (a code the page words), or None.
fn busy(app: &AppHandle) -> Option<&'static str> {
    if app.state::<AppState>().capture.recording() {
        return Some("busy_recording");
    }
    #[cfg(dict)]
    if crate::dictation::voice::active() || !crate::dictation::engine::island_state().is_null() {
        return Some("busy_dictation");
    }
    if crate::dictation::commands::downloading() {
        return Some("busy_download");
    }
    if !crate::jobs::list(true, 5).is_empty() {
        return Some("busy_job");
    }
    None
}

/// The warm model servers keep files open in the data folder: ended (they start again when needed).
fn end_servers() {
    let run = paths::blurt_home().join("run");
    for e in std::fs::read_dir(run).into_iter().flatten().filter_map(Result::ok) {
        let p = e.path();
        let Some(name) = p.file_stem().map(|n| n.to_string_lossy().into_owned()) else { continue };
        if p.extension().is_none_or(|x| x != "json") || name == "control" {
            continue;
        }
        if let Some(pid) = crate::dictation::server::record(&name).and_then(|r| r.pid) {
            crate::dictation::server::end(&name, pid);
        }
    }
}

static MOVING: AtomicBool = AtomicBool::new(false);

// ------------------------------------------------------------------ commands

/// Settings → Storage's Data location row.
#[tauri::command]
pub fn storage_location() -> Value {
    let profile = paths::home();
    let r = resolved();
    let p = r.and_then(|r| r.pointer.clone()).filter(|p| !p.is_default(&profile));
    let fixed = r.and_then(|r| r.user.iter().find(|k| **k == "BLURT_HOME" || **k == "BLURT_WORKSPACE").copied());
    // the folder that holds both (a chosen X; HOME for the legacy pointer)
    let folder = p.as_ref().filter(|_| fixed.is_none()).map(|p| if p.home == p.workspace.join(".blurt") { p.workspace.clone() } else { p.home.parent().map_or(p.home.clone(), Path::to_path_buf) });
    json!({
        "home": scripts::s(&paths::blurt_home()),
        "workspace": scripts::s(&paths::default_workspace()),
        "custom": folder.is_some(),
        "folder": folder.map(|f| scripts::s(&f)),
        "profile": scripts::s(&profile),
        "fixed_by": fixed,
        // read again: the cleanup at launch rewrites it when it is done
        "cleanup": r.is_some_and(|r| r.pointer.is_some()) && pointer_file().and_then(|f| read_pointer(&f)).is_some_and(|p| !p.cleanup.is_empty()),
        "moving": MOVING.load(Ordering::SeqCst),
    })
}

fn target(folder: Option<&str>) -> Pointer {
    match folder {
        Some(f) => Pointer::for_folder(&target_folder(Path::new(f))),
        None => Pointer::default_for(&paths::home()),
    }
}

/// Can the data go to `folder` (None: the default location)? → {ok, error?, folder, home, workspace, bytes, free,
/// redownload}. `redownload`: Python and its packages come down again at the new place the first time.
fn check(app: &AppHandle, folder: Option<&str>) -> Value {
    let to = target(folder);
    let base = json!({"folder": folder.map(|_| scripts::s(&to.workspace)), "home": scripts::s(&to.home), "workspace": scripts::s(&to.workspace)});
    let fail = |code: &str, extra: Value| {
        let mut v = base.clone();
        v["ok"] = json!(false);
        v["error"] = json!(code);
        if let (Some(o), Some(e)) = (v.as_object_mut(), extra.as_object()) {
            o.extend(e.clone());
        }
        v
    };
    if let Some(k) = resolved().and_then(|r| r.user.iter().find(|k| **k == "BLURT_HOME" || **k == "BLURT_WORKSPACE")) {
        return fail("env", json!({"var": k}));
    }
    if MOVING.load(Ordering::SeqCst) {
        return fail("moving", json!({}));
    }
    if let Some(b) = busy(app) {
        return fail(b, json!({}));
    }
    if let Some(r) = refusal(&paths::blurt_home(), &paths::default_workspace(), &to) {
        return fail(r, json!({}));
    }
    if writable(&to.workspace).is_err() {
        return fail("not_writable", json!({}));
    }
    let bytes = bytes_to_move(&to);
    let free = crate::housekeeping::free_bytes(&to.workspace);
    if free.is_some_and(|f| f < bytes + MARGIN) {
        return fail("no_space", json!({"bytes": bytes, "free": free}));
    }
    let mut v = base;
    v["ok"] = json!(true);
    v["bytes"] = json!(bytes);
    v["free"] = json!(free);
    v["redownload"] = json!(to.own_caches != current_caches_ours());
    v
}

/// The folder (and its parents) made if missing, a file written and removed; folders this made are removed again.
fn writable(dir: &Path) -> R<()> {
    let first_missing = dir.ancestors().take_while(|a| !a.exists()).last().map(Path::to_path_buf);
    let res = std::fs::create_dir_all(dir).and_then(|_| {
        let probe = dir.join(format!(".blurt-probe-{}", std::process::id()));
        std::fs::write(&probe, b"ok")?;
        std::fs::remove_file(&probe)
    });
    if let Some(m) = first_missing {
        let _ = std::fs::remove_dir_all(m);
    }
    res.map_err(|e| e.to_string())
}

/// Change…: the folder dialog, then the check → the check's answer, or {cancel: true}.
#[tauri::command(async)]
pub fn storage_location_pick(app: AppHandle, title: String) -> Value {
    let mut d = crate::island::folder_dialog(&app).set_title(title);
    if let Some(up) = paths::default_workspace().parent().filter(|p| p.is_dir()) {
        d = d.set_directory(up);
    }
    let Some(dir) = d.blocking_pick_folder().and_then(|d| d.into_path().ok()) else { return json!({"cancel": true}) };
    check(&app, Some(&scripts::s(&dir)))
}

/// The check alone (Use the Default Location: `folder` None).
#[tauri::command(async)]
pub fn storage_location_check(app: AppHandle, folder: Option<String>) -> Value {
    check(&app, folder.as_deref())
}

/// Move the data to `folder` (None: back to the default) and restart; progress as `storage://move`
/// {phase: copy, done, total} → {phase: restart} | {phase: error, error, detail}.
#[tauri::command(async)]
pub fn storage_location_move(app: AppHandle, folder: Option<String>) -> R<Value> {
    let c = check(&app, folder.as_deref());
    if c["ok"] != true {
        return Ok(c);
    }
    if MOVING.swap(true, Ordering::SeqCst) {
        return Ok(json!({"ok": false, "error": "moving"}));
    }
    let to = target(folder.as_deref());
    let app2 = app.clone();
    std::thread::spawn(move || {
        let emit = |v: Value| {
            let _ = app2.emit("storage://move", v);
        };
        match move_to(&to, &mut |done, total| emit(json!({"phase": "copy", "done": done, "total": total}))) {
            Ok(()) => {
                emit(json!({"phase": "restart"}));
                std::thread::sleep(Duration::from_millis(600));
                app2.restart();
            }
            Err(e) => {
                MOVING.store(false, Ordering::SeqCst);
                emit(json!({"phase": "error", "error": "copy_failed", "detail": e}));
            }
        }
    });
    Ok(c)
}

fn move_to(to: &Pointer, tick: &mut dyn FnMut(u64, u64)) -> R<()> {
    let (home, workspace) = (paths::blurt_home(), paths::default_workspace());
    let file = pointer_file().ok_or("no settings folder for the location file")?;
    end_servers();
    let ts = trees(&home, &workspace, to);
    let made: Vec<PathBuf> = [to.home.clone(), to.workspace.join("inbox"), to.workspace.join("recordings"), to.workspace.clone()]
        .into_iter()
        .filter(|p| !p.exists())
        .collect();
    if let Err(e) = copy_trees(&ts, keep_caches(to), tick) {
        // only what this move made: the target had no Blurt data (refusal's has_data); the folder itself when empty
        for p in &made {
            if p == &to.workspace {
                let _ = std::fs::remove_dir(p);
            } else {
                let _ = std::fs::remove_dir_all(p);
            }
        }
        return Err(e);
    }
    let s = |p: &Path| scripts::s(p);
    let pairs = [
        (s(&home), s(&to.home)),
        (s(&workspace.join("inbox")), s(&to.workspace.join("inbox"))),
        (s(&workspace.join("recordings")), s(&to.workspace.join("recordings"))),
        (s(&workspace), s(&to.workspace)),
    ];
    // the workspace pair only for the folder itself (record.workspace of v0.6): a project inside it doesn't move
    rebase_files(&to.home, &pairs[..3]);
    rebase_exact(&to.home, &pairs[3].0, &pairs[3].1);
    let mut cleanup: Vec<PathBuf> = resolved().and_then(|r| r.pointer.as_ref()).map(|p| p.cleanup.clone()).unwrap_or_default();
    cleanup.extend([home.clone(), workspace.join("inbox")]);
    if workspace.join("recordings").is_dir() {
        cleanup.push(workspace.join("recordings"));
    }
    cleanup.push(workspace.clone());
    // never the new place, nor a folder holding it (remove_old checks again at the next launch)
    cleanup.retain(|c| ![&to.home, &to.workspace].iter().any(|k| inside(k, c) || inside(c, k)));
    cleanup.dedup();
    let next = Pointer { cleanup, ..to.clone() };
    write_pointer(&file, Some(&next)).map_err(|e| format!("{}: {e}", file.display()))?;
    Ok(())
}

/// A JSON string that is exactly the old workspace → the new one.
fn rebase_exact(home: &Path, old: &str, new: &str) {
    for f in ["config.json", "projects.json"].map(|n| home.join(n)) {
        let Some(mut v) = crate::settings::read_json(&f) else { continue };
        if exact_json(&mut v, old, new) {
            let tmp = f.with_extension(format!("json.{}.tmp", std::process::id()));
            if std::fs::write(&tmp, serde_json::to_vec_pretty(&v).unwrap_or_default()).is_ok() {
                let _ = std::fs::rename(&tmp, &f);
            }
        }
    }
}

fn exact_json(v: &mut Value, old: &str, new: &str) -> bool {
    let new_t = new.trim_end_matches(['/', '\\']);
    match v {
        Value::String(s) => match rebase(s.trim_end_matches(['/', '\\']), old, new, cfg!(windows)) {
            Some(n) if n == new_t && *s != n => {
                *s = n;
                true
            }
            _ => false,
        },
        Value::Array(a) => a.iter_mut().fold(false, |ch, x| exact_json(x, old, new) | ch),
        Value::Object(o) => o.values_mut().fold(false, |ch, x| exact_json(x, old, new) | ch),
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// An absolute root on every platform ("/" has no drive on Windows, so it isn't absolute there).
    fn root() -> PathBuf {
        PathBuf::from(if cfg!(windows) { r"C:\" } else { "/" })
    }

    #[test]
    fn pointer_round_trip() {
        let r = root();
        let p = Pointer { cleanup: vec![r.join("old").join(".blurt")], ..Pointer::for_folder(&r.join("d").join("Blurt")) };
        assert_eq!(p.home, r.join("d").join("Blurt").join(".blurt"));
        assert_eq!(Pointer::parse(&p.to_json()), Some(p.clone()));
        // relative or missing paths are no pointer; own_caches defaults on
        let abs = |x: &str| scripts::s(&r.join(x));
        assert_eq!(Pointer::parse(&json!({"home": "rel", "workspace": abs("w")})), None);
        assert_eq!(Pointer::parse(&json!({"workspace": abs("w")})), None);
        assert!(Pointer::parse(&json!({"home": abs("h"), "workspace": abs("w")})).unwrap().own_caches);
        let d = tempfile::tempdir().unwrap();
        let f = d.path().join("Blurt/location.json");
        write_pointer(&f, Some(&p)).unwrap();
        assert_eq!(read_pointer(&f), Some(p));
        write_pointer(&f, None).unwrap();
        assert!(read_pointer(&f).is_none());
        write_pointer(&f, None).unwrap(); // already gone: fine
    }

    #[test]
    fn exports_default_custom_and_user_set() {
        let prof = root().join("u").join("me");
        let ex = |p: Option<&Pointer>, user: &[&str]| exports(p, &prof, user);
        // default: the two folders, uv and Hugging Face keep their own
        assert_eq!(ex(None, &[]), vec![("BLURT_HOME", prof.join(".blurt")), ("BLURT_WORKSPACE", prof.join("Blurt"))]);
        let e = root().join("e").join("Blurt");
        let p = Pointer::for_folder(&e);
        let h = e.join(".blurt");
        assert_eq!(
            ex(Some(&p), &[]),
            vec![
                ("BLURT_HOME", h.clone()),
                ("BLURT_WORKSPACE", e.clone()),
                ("UV_CACHE_DIR", h.join("cache").join("uv")),
                ("UV_PYTHON_INSTALL_DIR", h.join("python")),
                ("HF_HOME", h.join("cache").join("huggingface")),
            ]
        );
        // the user's own variables win; their BLURT_HOME keeps the caches where they are
        assert_eq!(ex(Some(&p), &["BLURT_HOME", "HF_HOME"]), vec![("BLURT_WORKSPACE", e.clone())]);
        assert_eq!(ex(Some(&p), &["UV_CACHE_DIR"]).len(), 4);
        // the legacy pointer: HOME's folders, the usual caches
        let l = Pointer { own_caches: false, ..p };
        assert_eq!(ex(Some(&l), &[]).len(), 2);
    }

    #[test]
    fn legacy_guard() {
        let d = tempfile::tempdir().unwrap();
        let (home, prof) = (d.path().join("dhome"), d.path().join("profile"));
        std::fs::create_dir_all(home.join(".blurt")).unwrap();
        std::fs::create_dir_all(prof.join(".blurt")).unwrap();
        assert_eq!(legacy(Some(&home), &prof), None, "no config under HOME");
        std::fs::write(home.join(".blurt/config.json"), "{}").unwrap();
        let p = legacy(Some(&home), &prof).unwrap();
        assert_eq!((p.home, p.workspace, p.own_caches), (home.join(".blurt"), home.join("Blurt"), false));
        assert_eq!(legacy(Some(&prof), &prof), None, "HOME is the profile");
        assert_eq!(legacy(None, &prof), None);
        std::fs::write(prof.join(".blurt/config.json"), "{}").unwrap();
        assert_eq!(legacy(Some(&home), &prof), None, "the profile has its own");
    }

    #[test]
    fn rebasing() {
        assert_eq!(rebase("/u/me/.blurt/models/x", "/u/me/.blurt", "/e/Blurt/.blurt", false).as_deref(), Some("/e/Blurt/.blurt/models/x"));
        assert_eq!(rebase("/u/me/.blurt", "/u/me/.blurt/", "/e/B/.blurt", false).as_deref(), Some("/e/B/.blurt"));
        assert_eq!(rebase("/u/me/.blurtx/a", "/u/me/.blurt", "/n", false), None);
        assert_eq!(rebase("/U/me/.blurt/a", "/u/me/.blurt", "/n", false), None);
        // Windows: either slash, any ASCII case
        assert_eq!(rebase(r"c:/Users/Me/Blurt\inbox\sessions\1", r"C:\Users\me\Blurt\inbox", r"E:\Blurt\inbox", true).as_deref(), Some(r"E:\Blurt\inbox\sessions\1"));
        assert_eq!(rebase("其他/路径", r"C:\a", r"E:\b", true), None);
        let mut v = json!({"a": "/h/.blurt/x", "b": ["/w/inbox", "/w/proj", 3], "c": {"d": "/w"}});
        let pairs = vec![("/h/.blurt".to_string(), "/n/.blurt".to_string()), ("/w/inbox".to_string(), "/n/inbox".to_string())];
        assert!(rebase_json(&mut v, &pairs, false));
        assert_eq!(v, json!({"a": "/n/.blurt/x", "b": ["/n/inbox", "/w/proj", 3], "c": {"d": "/w"}}));
        assert!(!rebase_json(&mut v, &pairs, false));
        // the workspace itself, never what is inside it
        assert!(exact_json(&mut v, "/w", "/n"));
        assert_eq!(v["c"]["d"], "/n");
        assert_eq!(v["b"][1], "/w/proj");
    }

    #[test]
    fn target_and_refusals() {
        assert_eq!(target_folder(Path::new("/mnt/e")), PathBuf::from("/mnt/e/Blurt"));
        assert_eq!(target_folder(Path::new("/mnt/e/blurt")), PathBuf::from("/mnt/e/blurt"));
        let d = tempfile::tempdir().unwrap();
        let (home, ws) = (d.path().join("me/.blurt"), d.path().join("me/Blurt"));
        let to = |f: &str| Pointer::for_folder(&target_folder(&d.path().join(f)));
        assert_eq!(refusal(&home, &ws, &Pointer::default_for(&d.path().join("me"))), Some("same"));
        assert_eq!(refusal(&home, &ws, &to("me/.blurt/x")), Some("inside_current"));
        assert_eq!(refusal(&home, &ws, &to("me/Blurt/inbox")), Some("inside_current"));
        assert_eq!(refusal(&home, &ws, &to("e")), None);
        // a custom place back to the default
        let (h2, w2) = (d.path().join("e/Blurt/.blurt"), d.path().join("e/Blurt"));
        assert_eq!(refusal(&h2, &w2, &Pointer::default_for(&d.path().join("me"))), None);
        assert_eq!(refusal(&h2, &w2, &to("e")), Some("same"));
        std::fs::create_dir_all(d.path().join("f/Blurt/inbox/items")).unwrap();
        assert_eq!(refusal(&home, &ws, &to("f")), Some("has_data"));
    }

    #[test]
    fn what_is_copied() {
        let s = |p: &str, k: bool| skipped(Path::new(p), k);
        assert!(s("run/asr-serve.json", true) && s("tmp/x", true) && s("index.db", true) && s("index.db-wal", true));
        assert!(!s("models/asr/x/model.onnx", false) && !s("config.json", false) && !s("dictation/audio/1.wav", false));
        assert!(s("cache/uv/archive-v0/x", false) && s("python/cpython-3.12/python.exe", false));
        assert!(!s("cache/uv/archive-v0/x", true) && !s("python/cpython-3.12/python.exe", true));
        assert!(s("cache/uv/environments-v2/x/pyvenv.cfg", true));
        assert!(!s("jobs/index.db", true));
    }

    #[test]
    fn copies_and_verifies() {
        let d = tempfile::tempdir().unwrap();
        let (home, ws) = (d.path().join("me/.blurt"), d.path().join("me/Blurt"));
        for (f, body) in [("config.json", "{}"), ("models/asr/m/w.onnx", "weights"), ("run/x.json", "{}"), ("index.db", "db")] {
            std::fs::create_dir_all(home.join(f).parent().unwrap()).unwrap();
            std::fs::write(home.join(f), body).unwrap();
        }
        std::fs::create_dir_all(ws.join("inbox/items")).unwrap();
        std::fs::write(ws.join("inbox/items/IN-1.md"), "# hi").unwrap();
        let to = Pointer::for_folder(&d.path().join("e/Blurt"));
        let ts = trees(&home, &ws, &to);
        let mut ticks = vec![];
        copy_trees(&ts, false, &mut |a, b| ticks.push((a, b))).unwrap();
        assert!(to.home.join("models/asr/m/w.onnx").is_file() && to.workspace.join("inbox/items/IN-1.md").is_file());
        assert!(!to.home.join("run").exists() && !to.home.join("index.db").exists());
        assert_eq!(ticks.last(), Some(&(2 + 7 + 4, 2 + 7 + 4)));
    }

    #[test]
    fn cleanup_only_takes_blurts_own() {
        let d = tempfile::tempdir().unwrap();
        let keep = [d.path().join("e/Blurt/.blurt"), d.path().join("e/Blurt")];
        let old_home = d.path().join("me/.blurt");
        std::fs::create_dir_all(old_home.join("models")).unwrap();
        assert!(remove_old(&old_home, &keep) && !old_home.exists());
        let ws = d.path().join("me/Blurt");
        std::fs::create_dir_all(ws.join("inbox/items")).unwrap();
        std::fs::write(ws.join("notes.txt"), "mine").unwrap();
        assert!(remove_old(&ws.join("inbox"), &keep));
        assert!(remove_old(&ws, &keep) && ws.join("notes.txt").is_file(), "the user's file keeps the folder");
        std::fs::remove_file(ws.join("notes.txt")).unwrap();
        assert!(remove_old(&ws, &keep) && !ws.exists());
        // never the folder in use, nor one holding it
        assert!(remove_old(&d.path().join("e"), &keep) && keep[0].parent().is_some());
        std::fs::create_dir_all(&keep[0]).unwrap();
        assert!(remove_old(&d.path().join("e/Blurt"), &keep) && keep[0].is_dir());
    }
}
