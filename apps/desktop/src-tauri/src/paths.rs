//! Where things live. Same rules as `_common.py` / the macOS app: `$BLURT_HOME` (default `~/.blurt`) holds
//! `config.json` and `index.db`; `$BLURT_WORKSPACE` (default `~/Blurt`) is the default workspace whose sessions are in
//! `recordings/`; a repo workspace keeps its sessions in `<repo>/.blurt/sessions`.

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

pub fn default_workspace() -> PathBuf {
    std::env::var_os("BLURT_WORKSPACE")
        .filter(|h| !h.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| home().join("Blurt"))
}

/// The directory that holds a workspace's session dirs.
pub fn sessions_root(workspace: &Path) -> PathBuf {
    if workspace == default_workspace() {
        workspace.join("recordings")
    } else {
        workspace.join(".blurt").join("sessions")
    }
}

/// `<repo>/.blurt/sessions/<ts>` → `<repo>`; `~/Blurt/recordings/<ts>` → None (not a repo: nothing to fix in).
pub fn repo_of_session(session: &Path) -> Option<PathBuf> {
    let sessions = session.parent()?;
    let dot = sessions.parent()?;
    if sessions.file_name()? == "sessions" && dot.file_name()? == ".blurt" {
        return dot.parent().map(Path::to_path_buf);
    }
    None
}

fn first_existing(cands: impl IntoIterator<Item = PathBuf>) -> Option<PathBuf> {
    cands.into_iter().find(|p| p.exists())
}

/// The skill's scripts (items.py, index.py, agents.py, …): `$BLURT_SCRIPTS` → the copy bundled with the app →
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
    fn repo_of_session_works() {
        let s = Path::new("/r/my-saas/.blurt/sessions/20261021-101500");
        assert_eq!(repo_of_session(s), Some(PathBuf::from("/r/my-saas")));
        assert_eq!(repo_of_session(Path::new("/h/Blurt/recordings/20261021-101500")), None);
    }

    #[test]
    fn normalize_dotdot() {
        assert_eq!(normalize(Path::new("/a/b/../c/./d")), PathBuf::from("/a/c/d"));
    }
}
