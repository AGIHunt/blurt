//! The skill the app carries (the Mac's BlurtCore BundledSkill): `<resources>/skill` — SKILL.md, scripts/, reference/,
//! assets/ and a `.version` stamp, staged by build.rs (`gen/skill`) — copied to `$BLURT_HOME/skill` (paths::skill_dir)
//! at launch whenever that copy's stamp isn't the bundle's. The app runs its scripts from that copy and Connect links
//! agents to it: never the install folder (Program Files / an AppImage mount / /usr/lib), which an update replaces or
//! unmounts, and never a bare scripts folder (an agent needs SKILL.md). The new copy is made next to the old one
//! and swapped in, so a script starting meanwhile never sees half a skill.

use std::path::{Path, PathBuf};

pub const STAMP: &str = ".version";

/// A skill folder: SKILL.md and its scripts.
pub fn is_skill(dir: &Path) -> bool {
    dir.join("SKILL.md").is_file() && dir.join("scripts").join("_common.py").is_file()
}

pub fn stamp(dir: &Path) -> Option<String> {
    std::fs::read_to_string(dir.join(STAMP)).ok().map(|s| s.trim().to_string()).filter(|s| !s.is_empty())
}

/// What a copy leaves alone: Python's caches and environments.
fn skipped(name: &std::ffi::OsStr) -> bool {
    name == "__pycache__" || name == ".venv"
}

fn copy_dir(src: &Path, dest: &Path) -> std::io::Result<()> {
    copy_tree(src, dest, false)
}

/// `src` into `dest`; `no_stamp`: all but the top's stamp.
fn copy_tree(src: &Path, dest: &Path, no_stamp: bool) -> std::io::Result<()> {
    std::fs::create_dir_all(dest)?;
    for e in std::fs::read_dir(src)? {
        let e = e?;
        let name = e.file_name();
        if skipped(&name) || (no_stamp && name == STAMP) {
            continue;
        }
        let (from, to) = (e.path(), dest.join(&name));
        if e.file_type()?.is_dir() {
            copy_dir(&from, &to)?;
        } else {
            std::fs::copy(&from, &to)?;
        }
    }
    Ok(())
}

/// Remove from `dest` what `src` doesn't have (a script the skill dropped). Best effort: a file a script holds open
/// stays.
fn prune(src: &Path, dest: &Path) {
    for e in std::fs::read_dir(dest).into_iter().flatten().filter_map(Result::ok) {
        let name = e.file_name();
        if skipped(&name) || name == STAMP {
            continue;
        }
        let (from, to) = (src.join(&name), e.path());
        let is_dir = e.file_type().is_ok_and(|t| t.is_dir());
        if is_dir && from.is_dir() {
            prune(&from, &to);
        } else if !from.exists() || is_dir != from.is_dir() {
            let _ = if is_dir { std::fs::remove_dir_all(&to) } else { std::fs::remove_file(&to) };
        }
    }
}

/// The copy over the old one, in place (Windows, when a script holds a file of it open): its stamp goes first and
/// comes back last, only once every file is copied — a copy that stopped halfway is made again at the next launch.
fn copy_in_place(src: &Path, dest: &Path) -> std::io::Result<()> {
    let _ = std::fs::remove_file(dest.join(STAMP));
    copy_tree(src, dest, true)?;
    prune(src, dest);
    match std::fs::copy(src.join(STAMP), dest.join(STAMP)) {
        Err(e) if e.kind() != std::io::ErrorKind::NotFound => Err(e),
        _ => Ok(()),
    }
}

/// Copies `src` to `dest` unless `dest` already is that copy (same stamp, a whole skill). → Ok(true) when copied.
pub fn sync(src: &Path, dest: &Path) -> std::io::Result<bool> {
    let want = stamp(src);
    if want.is_some() && stamp(dest) == want && is_skill(dest) {
        return Ok(false);
    }
    let parent = dest.parent().map(Path::to_path_buf).unwrap_or_else(|| PathBuf::from("."));
    std::fs::create_dir_all(&parent)?;
    let name = dest.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_else(|| "skill".into());
    let tag = format!("{}-{}", std::process::id(), std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.subsec_nanos()).unwrap_or(0));
    let fresh = parent.join(format!(".{name}-new-{tag}"));
    let old = parent.join(format!(".{name}-old-{tag}"));
    if let Err(e) = copy_dir(src, &fresh) {
        let _ = std::fs::remove_dir_all(&fresh);
        return Err(e);
    }
    let had = dest.exists() || std::fs::symlink_metadata(dest).is_ok();
    if had {
        // Windows: a folder whose file a script holds open can't be renamed; then copy over it in place
        if std::fs::rename(dest, &old).is_err() {
            let r = copy_in_place(&fresh, dest);
            let _ = std::fs::remove_dir_all(&fresh);
            return r.map(|_| true);
        }
    }
    if let Err(e) = std::fs::rename(&fresh, dest) {
        if had {
            let _ = std::fs::rename(&old, dest); // put the old copy back rather than leave none
        }
        let _ = std::fs::remove_dir_all(&fresh);
        return Err(e);
    }
    let _ = std::fs::remove_dir_all(&old);
    Ok(true)
}

/// At launch, before anything runs a script: the bundled skill (`<resources>/skill`) to paths::skill_dir(). None
/// without a bundled skill.
pub fn sync_at_launch(resources: Option<PathBuf>) -> Option<std::io::Result<bool>> {
    let src = resources?.join("skill");
    if !is_skill(&src) {
        return None;
    }
    let r = sync(&src, &crate::paths::skill_dir());
    if let Err(e) = &r {
        eprintln!("blurt: couldn't copy the skill to {}: {e}", crate::paths::skill_dir().display());
    }
    Some(r)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn skill(dir: &Path, version: &str, body: &str) {
        std::fs::create_dir_all(dir.join("scripts/__pycache__")).unwrap();
        std::fs::write(dir.join("SKILL.md"), format!("---\nname: blurt\n---\n{body}")).unwrap();
        std::fs::write(dir.join("scripts/_common.py"), body).unwrap();
        std::fs::write(dir.join("scripts/__pycache__/x.pyc"), "junk").unwrap();
        std::fs::create_dir_all(dir.join("reference")).unwrap();
        std::fs::write(dir.join("reference/asr.md"), body).unwrap();
        std::fs::write(dir.join(STAMP), version).unwrap();
    }

    #[test]
    fn copies_when_the_stamp_changes_and_only_then() {
        let d = tempfile::tempdir().unwrap();
        let (src, dest) = (d.path().join("res/skill"), d.path().join("home/skill"));
        skill(&src, "1.0.26 abc", "one");
        assert!(sync(&src, &dest).unwrap());
        assert!(is_skill(&dest) && stamp(&dest).as_deref() == Some("1.0.26 abc"));
        assert!(!dest.join("scripts/__pycache__").exists(), "no caches copied");
        assert!(!sync(&src, &dest).unwrap(), "same stamp: nothing to do");
        skill(&src, "1.0.27 def", "two");
        std::fs::write(dest.join("scripts/stale.py"), "old").unwrap();
        assert!(sync(&src, &dest).unwrap());
        assert_eq!(std::fs::read_to_string(dest.join("reference/asr.md")).unwrap(), "two");
        assert!(!dest.join("scripts/stale.py").exists(), "swapped in whole: nothing of the old copy left");
        let leftovers: Vec<_> = std::fs::read_dir(d.path().join("home")).unwrap().filter_map(|e| e.ok()).map(|e| e.file_name()).collect();
        assert_eq!(leftovers.len(), 1, "{leftovers:?}");
    }

    #[test]
    fn a_broken_copy_is_replaced_even_with_the_same_stamp() {
        let d = tempfile::tempdir().unwrap();
        let (src, dest) = (d.path().join("res/skill"), d.path().join("home/skill"));
        skill(&src, "v", "x");
        sync(&src, &dest).unwrap();
        std::fs::remove_file(dest.join("SKILL.md")).unwrap();
        assert!(sync(&src, &dest).unwrap() && is_skill(&dest));
    }

    #[test]
    fn in_place_the_stamp_comes_last_and_old_files_go() {
        let d = tempfile::tempdir().unwrap();
        let (src, dest) = (d.path().join("res/skill"), d.path().join("home/skill"));
        skill(&dest, "1.0.26", "one");
        std::fs::write(dest.join("scripts/stale.py"), "old").unwrap();
        std::fs::create_dir_all(dest.join("gone/deep")).unwrap();
        skill(&src, "1.0.27", "two");
        std::fs::remove_dir_all(src.join("scripts/__pycache__")).unwrap();
        copy_in_place(&src, &dest).unwrap();
        assert_eq!(stamp(&dest).as_deref(), Some("1.0.27"));
        assert_eq!(std::fs::read_to_string(dest.join("reference/asr.md")).unwrap(), "two");
        assert!(!dest.join("scripts/stale.py").exists() && !dest.join("gone").exists(), "files the skill dropped are gone");
        assert!(dest.join("scripts/__pycache__/x.pyc").exists(), "caches left alone");
    }

    #[cfg(unix)]
    #[test]
    fn in_place_a_copy_that_stops_halfway_has_no_stamp() {
        use std::os::unix::fs::PermissionsExt;
        let d = tempfile::tempdir().unwrap();
        let (src, dest) = (d.path().join("res/skill"), d.path().join("home/skill"));
        skill(&dest, "1.0.26", "one");
        skill(&src, "1.0.27", "two");
        let locked = src.join("scripts/zz_locked.py");
        std::fs::write(&locked, "x").unwrap();
        std::fs::set_permissions(&locked, std::fs::Permissions::from_mode(0o000)).unwrap();
        if std::fs::read(&locked).is_ok() {
            return; // root reads it anyway: nothing to show
        }
        assert!(copy_in_place(&src, &dest).is_err());
        assert_eq!(stamp(&dest), None, "not stamped: the next launch copies it again");
        std::fs::set_permissions(&locked, std::fs::Permissions::from_mode(0o644)).unwrap();
        assert!(sync(&src, &dest).unwrap() && stamp(&dest).as_deref() == Some("1.0.27"));
    }

    #[test]
    fn nothing_without_a_bundled_skill() {
        let d = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(d.path().join("skill/scripts")).unwrap(); // scripts but no SKILL.md
        assert!(sync_at_launch(Some(d.path().to_path_buf())).is_none());
        assert!(sync_at_launch(None).is_none());
    }
}
