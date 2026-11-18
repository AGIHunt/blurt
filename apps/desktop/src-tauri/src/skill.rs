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

fn copy_dir(src: &Path, dest: &Path) -> std::io::Result<()> {
    std::fs::create_dir_all(dest)?;
    for e in std::fs::read_dir(src)? {
        let e = e?;
        let name = e.file_name();
        if name == "__pycache__" || name == ".venv" {
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
            let r = copy_dir(&fresh, dest);
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
    fn nothing_without_a_bundled_skill() {
        let d = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(d.path().join("skill/scripts")).unwrap(); // scripts but no SKILL.md
        assert!(sync_at_launch(Some(d.path().to_path_buf())).is_none());
        assert!(sync_at_launch(None).is_none());
    }
}
