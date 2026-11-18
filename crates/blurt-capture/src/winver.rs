//! Which Windows this is, as far as capture exclusion goes (docs/design/windows-parity/snap-and-note.md §Windows 10
//! before 2004).
//!
//! Every overlay is content-protected so captures leave it out: tao sets `WDA_EXCLUDEFROMCAPTURE`. That value exists
//! from Windows 10 2004 (build 19041); before it, Windows treats it as `WDA_MONITOR` — the window comes out *black* in
//! every capture (BitBlt, gdigrab, Desktop Duplication). Black is worse than being seen, so on those builds the
//! overlays are left unprotected, and the pictures Blurt keeps come from the picker's still (taken before any
//! overlay showed) instead of a grab made while they are up.

/// The first build where `WDA_EXCLUDEFROMCAPTURE` leaves a window out of captures (Windows 10 2004).
pub const EXCLUDE_FROM_CAPTURE_BUILD: u32 = 19041;

/// Does content protection leave a window out of captures on this build (else it blackens it)?
pub fn excludes_from_capture(build: u32) -> bool {
    build >= EXCLUDE_FROM_CAPTURE_BUILD
}

/// Windows' build number (RtlGetVersion: not subject to the manifest's version lie), read once. `BLURT_WINDOWS_BUILD`
/// stands in for it (tests: the old builds' path on a new Windows). None off Windows.
pub fn windows_build() -> Option<u32> {
    static BUILD: std::sync::OnceLock<Option<u32>> = std::sync::OnceLock::new();
    *BUILD.get_or_init(|| {
        if let Some(b) = std::env::var("BLURT_WINDOWS_BUILD").ok().and_then(|v| v.trim().parse().ok()) {
            return Some(b);
        }
        real_build()
    })
}

#[cfg(windows)]
fn real_build() -> Option<u32> {
    /// OSVERSIONINFOW
    #[repr(C)]
    struct VersionInfo {
        size: u32,
        major: u32,
        minor: u32,
        build: u32,
        platform: u32,
        csd: [u16; 128],
    }
    #[link(name = "ntdll")]
    extern "system" {
        fn RtlGetVersion(info: *mut VersionInfo) -> i32;
    }
    let mut v = VersionInfo { size: std::mem::size_of::<VersionInfo>() as u32, major: 0, minor: 0, build: 0, platform: 0, csd: [0; 128] };
    // SAFETY: `v` is a properly sized OSVERSIONINFOW with its size field set; RtlGetVersion only writes into it
    let status = unsafe { RtlGetVersion(&mut v) };
    (status == 0 && v.build > 0).then_some(v.build)
}

#[cfg(not(windows))]
fn real_build() -> Option<u32> {
    None
}

/// Content protection would show our windows black in captures here (Windows before 2004): leave them unprotected.
pub fn protection_blackens() -> bool {
    cfg!(windows) && windows_build().is_some_and(|b| !excludes_from_capture(b))
}

/// Our windows can be left out of captures here (Windows 2004+; macOS). Linux can't; nor can Windows before 2004 —
/// there they are seen in a recording, so the island keeps clear of a recorded area as on Linux.
pub fn capture_exclusion() -> bool {
    if cfg!(target_os = "linux") {
        return false;
    }
    !protection_blackens()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exclusion_starts_with_2004() {
        assert!(!excludes_from_capture(17763)); // Windows Server 2019 / 1809
        assert!(!excludes_from_capture(18363)); // 1909
        assert!(excludes_from_capture(19041)); // 2004
        assert!(excludes_from_capture(19045)); // 22H2
        assert!(excludes_from_capture(26100)); // Windows 11 24H2
    }

    #[cfg(not(windows))]
    #[test]
    fn nothing_blackens_off_windows() {
        assert!(!protection_blackens());
        assert_eq!(capture_exclusion(), !cfg!(target_os = "linux"));
    }
}
