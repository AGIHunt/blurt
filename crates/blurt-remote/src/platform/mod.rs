//! Each OS's half of host.rs. `backend()` is what the server uses.

#[cfg(windows)]
pub mod windows;
#[cfg(windows)]
pub use self::windows::backend;

#[cfg(target_os = "linux")]
pub mod linux;
#[cfg(target_os = "linux")]
pub use self::linux::backend;

/// Anywhere else (the Mac, where Blurt's own Swift host runs; and tests): nothing can be shown or pressed.
#[cfg(not(any(windows, target_os = "linux")))]
pub fn backend() -> Box<dyn crate::host::Backend> {
    Box::new(crate::host::NoBackend::default())
}
