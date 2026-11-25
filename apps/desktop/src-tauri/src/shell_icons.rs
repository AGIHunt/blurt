//! Windows: the Shell reads Blurt's icon again, once for each install (docs/design/windows-parity/installer.md,
//! 安装后的图标). If another program holds blurt.exe while it is installed (a virus scanner does), Explorer keeps the
//! generic exe icon for the shortcut, and neither the installer's own refresh nor starting Blurt brings the real one
//! back. By the time Blurt runs, its exe can be opened.
//!
//! SHCNE_ASSOCCHANGED, as the installer sends: telling the Shell about the exe alone (SHCNE_UPDATEITEM) left the
//! shortcut as it was. It makes Explorer read every icon again, so never on every launch.

use std::path::Path;

/// This install: the version, and when the installer wrote its uninstall.exe (a reinstall of the same version counts).
/// Not the exe's own times: NSIS gives a file it unpacks the times it was packed with. No uninstall.exe (the MSI): the
/// version alone.
fn install(version: &str, uninstaller: Option<std::time::SystemTime>) -> String {
    let secs = uninstaller.and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok()).map_or(0, |d| d.as_secs());
    format!("{version} {secs}")
}

/// True the first time it is asked about `install`. Noted before the refresh: a note that can't be written means no
/// refresh, rather than one on every launch.
fn first_time(note: &Path, install: &str) -> bool {
    if std::fs::read_to_string(note).is_ok_and(|s| s.trim() == install) {
        return false;
    }
    if let Some(d) = note.parent() {
        let _ = std::fs::create_dir_all(d);
    }
    std::fs::write(note, install).is_ok()
}

/// At launch, off the main thread (housekeeping.rs). Not a debug build: its exe is new after every compile.
pub fn refresh_once(version: &str) {
    if !cfg!(windows) || cfg!(debug_assertions) {
        return;
    }
    let uninstaller = std::env::current_exe().and_then(|e| std::fs::metadata(e.with_file_name("uninstall.exe"))).and_then(|m| m.modified());
    // in run/, not config.json: nothing of the user's, and a move of the data may leave it behind
    let note = crate::paths::blurt_home().join("run").join("shell-icons");
    if first_time(&note, &install(version, uninstaller.ok())) {
        refresh();
    }
}

#[cfg(windows)]
fn refresh() {
    use windows::Win32::UI::Shell::{SHChangeNotify, SHCNE_ASSOCCHANGED, SHCNF_IDLIST};
    unsafe { SHChangeNotify(SHCNE_ASSOCCHANGED, SHCNF_IDLIST, None, None) };
}

#[cfg(not(windows))]
fn refresh() {}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{Duration, UNIX_EPOCH};

    #[test]
    fn once_for_each_install() {
        let d = tempfile::tempdir().unwrap();
        let note = d.path().join("run").join("shell-icons");
        let (t1, t2) = (Some(UNIX_EPOCH + Duration::from_secs(100)), Some(UNIX_EPOCH + Duration::from_secs(200)));
        assert!(first_time(&note, &install("1.1.4", t1)), "the first launch after an install");
        assert!(!first_time(&note, &install("1.1.4", t1)), "the next launch");
        assert!(first_time(&note, &install("1.1.5", t1)), "an update");
        assert!(first_time(&note, &install("1.1.5", t2)), "the same version installed again");
        assert!(!first_time(&note, &install("1.1.5", t2)));
        assert!(first_time(&note, &install("1.1.6", None)), "no uninstall.exe: the version alone");
        assert!(!first_time(&note, &install("1.1.6", None)));
    }

    #[test]
    fn a_note_that_cannot_be_written_means_no_refresh() {
        let d = tempfile::tempdir().unwrap();
        std::fs::write(d.path().join("run"), "a file where the folder goes").unwrap();
        assert!(!first_time(&d.path().join("run").join("shell-icons"), "1.1.4 100"));
    }
}
