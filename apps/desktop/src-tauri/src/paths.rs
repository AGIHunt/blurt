//! Where things live (v0.7 contract K1 / K2 / K4 / K6), the same rules as `_common.py` and the macOS app:
//! `$BLURT_HOME` (default `~/.blurt`) holds `config.json`, `projects.json`, `index.db`, `jobs/` and `handoff/`; every
//! project folder keeps its items and sessions in a store, `<project>/.blurt/`; unassigned captures live in the inbox
//! store, `$BLURT_WORKSPACE/inbox/` (default `~/Blurt/inbox/`).

use std::path::{Path, PathBuf};

use tauri::{AppHandle, Manager};

pub fn home() -> PathBuf {
    // $HOME first so tests (and the Linux e2e) can relocate everything; dirs::home_dir is the platform answer.
    std::env::var_os("HOME")
        .filter(|h| !h.is_empty())
        .map(PathBuf::from)
        .or_else(dirs::home_dir)
        .unwrap_or_else(|| PathBuf::from("."))
}

pub fn blurt_home() -> PathBuf {
    std::env::var_os("BLURT_HOME").filter(|h| !h.is_empty()).map(PathBuf::from).unwrap_or_else(|| home().join(".blurt"))
}

pub fn index_db() -> PathBuf {
    blurt_home().join("index.db")
}

pub fn config_file() -> PathBuf {
    blurt_home().join("config.json")
}

/// The project registry (K2), written only by `projects.py`.
pub fn projects_file() -> PathBuf {
    blurt_home().join("projects.json")
}

pub fn jobs_dir() -> PathBuf {
    blurt_home().join("jobs")
}

pub fn handoff_dir() -> PathBuf {
    blurt_home().join("handoff")
}

pub fn default_workspace() -> PathBuf {
    std::env::var_os("BLURT_WORKSPACE")
        .filter(|h| !h.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| home().join("Blurt"))
}

/// The store of unassigned items (K1): `$BLURT_WORKSPACE/inbox`.
pub fn inbox_store() -> PathBuf {
    default_workspace().join("inbox")
}

/// Sessions recorded before v0.7; `items.py migrate --all` (run at startup) moves their items into the inbox store.
pub fn legacy_recordings() -> PathBuf {
    default_workspace().join("recordings")
}

/// A project's store: `<project>/.blurt`; the inbox store is its own folder.
pub fn store_of(project_path: &Path) -> PathBuf {
    if project_path == inbox_store() {
        return project_path.to_path_buf();
    }
    project_path.join(".blurt")
}

/// `<store>/sessions/<ts>` → `<store>`.
pub fn store_of_session(session: &Path) -> Option<PathBuf> {
    let sessions = session.parent()?;
    if sessions.file_name()? != "sessions" {
        return None;
    }
    sessions.parent().map(Path::to_path_buf)
}

fn first_existing(cands: impl IntoIterator<Item = PathBuf>) -> Option<PathBuf> {
    cands.into_iter().find(|p| p.exists())
}

/// The skill's scripts (items.py, projects.py, sessions.py, …): `$BLURT_SCRIPTS` → the copy bundled with the app →
/// the repo checkout (dev builds) → the installed skill.
pub fn scripts_dir(app: &AppHandle) -> Option<PathBuf> {
    let mut c: Vec<PathBuf> = Vec::new();
    if let Some(p) = std::env::var_os("BLURT_SCRIPTS").filter(|p| !p.is_empty()) {
        c.push(PathBuf::from(p));
    }
    if let Ok(res) = app.path().resource_dir() {
        c.push(res.join("scripts"));
    }
    c.push(Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../skills/blurt/scripts"));
    let h = home();
    c.push(h.join(".claude/skills/blurt/scripts"));
    c.push(h.join(".agents/skills/blurt/scripts"));
    first_existing(c.into_iter().map(|p| p.join("items.py"))).and_then(|p| p.parent().map(normalize))
}

/// `uv` from PATH, else the copy the onboarding installs (`~/.blurt/bin/uv`), else the usual installer locations.
pub fn uv() -> Option<PathBuf> {
    let exe = if cfg!(windows) { "uv.exe" } else { "uv" };
    if let Some(path) = std::env::var_os("PATH") {
        for d in std::env::split_paths(&path) {
            let p = d.join(exe);
            if p.is_file() {
                return Some(p);
            }
        }
    }
    let h = home();
    first_existing([
        blurt_home().join("bin").join(exe),
        h.join(".blurt/bin").join(exe),
        h.join(".local/bin").join(exe),
        h.join(".cargo/bin").join(exe),
    ])
}

/// Lexically clean `a/b/../c` (no symlink resolution: Windows `canonicalize` gives `\\?\` paths Python dislikes).
pub fn normalize(p: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for comp in p.components() {
        match comp {
            std::path::Component::ParentDir => {
                if !out.pop() {
                    out.push("..");
                }
            }
            std::path::Component::CurDir => {}
            other => out.push(other.as_os_str()),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stores() {
        let s = Path::new("/r/my-saas/.blurt/sessions/20261021-101500");
        assert_eq!(store_of_session(s), Some(PathBuf::from("/r/my-saas/.blurt")));
        assert_eq!(store_of_session(Path::new("/h/Blurt/inbox/sessions/x")), Some(PathBuf::from("/h/Blurt/inbox")));
        assert_eq!(store_of_session(Path::new("/h/Blurt/recordings/x")), None);
        assert_eq!(store_of(Path::new("/r/my-saas")), PathBuf::from("/r/my-saas/.blurt"));
    }

    #[test]
    fn normalize_dotdot() {
        assert_eq!(normalize(Path::new("/a/b/../c/./d")), PathBuf::from("/a/c/d"));
    }
}
