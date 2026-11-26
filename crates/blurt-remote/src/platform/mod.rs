//! Each OS's half of host.rs. `backend()` is what the server uses.

// Windows: its pure parts (key tables, bitstream, geometry, bookkeeping) are also built for tests on any OS
#[cfg(any(windows, test))]
pub mod windows;
#[cfg(windows)]
pub use self::windows::backend;

// built everywhere for its pure helpers' tests; the backend itself only on Linux
#[cfg(any(target_os = "linux", test))]
pub mod linux;
#[cfg(target_os = "linux")]
pub use self::linux::backend;

/// Image bytes ↔ pixels for the clipboard (pure), and the clipboard's image and files on Windows and Linux.
pub mod pixels;
#[cfg(any(windows, target_os = "linux"))]
pub mod clip;

/// Anywhere else (the Mac, where Blurt's own Swift host runs; and tests): nothing can be shown or pressed.
#[cfg(not(any(windows, target_os = "linux")))]
pub fn backend() -> Box<dyn crate::host::Backend> {
    Box::new(crate::host::NoBackend::default())
}
