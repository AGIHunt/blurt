//! Linux backend (Wayland first: GNOME on Ubuntu 26.04; KDE and X11 sessions wherever their portal does the same). See host.rs
//! for the contract and docs/design/remote-linux.md for what was decided and measured.
//!
//!   keys.rs, math.rs, nal.rs,  pure: key tables and the modifier state machine, crop / scroll / pointer arithmetic, Annex B →
//!   mirror.rs                  AVCC, the monitor copy crops are cut from. Built and tested on every OS (`cargo test` on a Mac).
//!   portal.rs                  one xdg-desktop-portal RemoteDesktop session with ScreenCast attached, the restore token, the
//!                              Notify* calls in order on one task, Inhibit
//!   capture.rs                 the monitor's PipeWire stream: frames into the mirror, damage, cursor position and bitmap
//!   encode.rs                  GStreamer: appsrc → convert/scale to the constant output size → H.264 / HEVC → appsink
//!   input.rs, screen.rs        host.rs Input and Screen on top of those
//!
//! What the app may set before `backend()` (all optional): `set_state_dir` (where the portal's restore token is kept),
//! `set_dialog_parent` (the X11 window GNOME's dialog opens over), `set_paste` (its own way of putting text in).

pub mod keys;
pub mod math;
pub mod mirror;
pub mod nal;

#[cfg(target_os = "linux")]
mod capture;
#[cfg(target_os = "linux")]
pub mod encode;
#[cfg(target_os = "linux")]
mod input;
#[cfg(target_os = "linux")]
mod portal;
#[cfg(target_os = "linux")]
mod screen;

#[cfg(target_os = "linux")]
pub use self::imp::*;

#[cfg(target_os = "linux")]
mod imp {
    use std::sync::{Arc, Mutex, OnceLock};
    use std::time::{Duration, Instant};

    use super::capture::Shared;
    use super::input::LinuxInput;
    use super::portal::{self, Portal};
    use super::screen::LinuxScreen;
    use crate::host::{Backend, Input, Screen};

    pub use super::portal::{set_dialog_parent, set_state_dir};
    pub use super::screen::pick_encoder;

    /// Text the app inserts its own way (the desktop app's dictation insert, which knows terminals want Ctrl+Shift+V and
    /// keeps the clipboard). Without it: XWayland's clipboard and Ctrl+V.
    pub fn set_paste(f: impl Fn(&str) -> bool + Send + Sync + 'static) {
        *super::input::PASTE.lock().unwrap() = Some(Arc::new(f));
    }

    pub fn now() -> f64 {
        static START: OnceLock<Instant> = OnceLock::new();
        START.get_or_init(Instant::now).elapsed().as_secs_f64()
    }

    pub struct LinuxBackend {
        portal: Arc<Portal>,
        input: LinuxInput,
        screen: LinuxScreen,
        /// when the last phone left: the session closes a little later (GNOME's chips go), unless one comes back
        idle_close: Arc<Mutex<Option<Instant>>>,
    }

    /// How long the portal session outlives the phone, for a quick reconnect.
    const LINGER: Duration = Duration::from_secs(30);

    pub fn backend() -> Box<dyn Backend> {
        Box::new(linux_backend())
    }

    pub fn linux_backend() -> LinuxBackend {
        let portal = Portal::new();
        let shared = Arc::new(Shared::default());
        LinuxBackend {
            input: LinuxInput::new(portal.clone(), shared.clone()),
            screen: LinuxScreen::new(portal.clone(), shared, now),
            portal,
            idle_close: Arc::default(),
        }
    }

    impl LinuxBackend {
        /// Opens the portal session now and waits for it (the dialog, the first time). Ok: input can be sent.
        pub fn connect(&mut self, limit: Duration) -> Result<(), String> {
            self.portal.wait(limit).map(|_| ())
        }

        /// The portal session ends now (the phone left, or the app quits).
        pub fn close(&mut self) {
            self.screen.stop();
            self.input.release_all();
            self.portal.flush(Duration::from_millis(500));
            self.portal.close();
            self.input.forget();
        }
    }

    impl Backend for LinuxBackend {
        fn input(&mut self) -> &mut dyn Input {
            if !self.portal.is_open() {
                self.input.forget();
            }
            &mut self.input
        }

        fn screen(&mut self) -> Option<&mut dyn Screen> {
            Some(&mut self.screen)
        }

        fn platform(&self) -> &'static str {
            "linux"
        }

        fn display_aspect(&self) -> f64 {
            if let Some(s) = self.portal.stream().filter(|s| s.size.1 > 0) {
                return s.size.0 as f64 / s.size.1 as f64;
            }
            // the last session's monitor; before any, the most common shape
            std::fs::read_to_string(portal::state_dir().join("display-aspect"))
                .ok()
                .and_then(|s| s.trim().parse::<f64>().ok())
                .filter(|a| a.is_finite() && *a > 0.2 && *a < 5.0)
                .unwrap_or(16.0 / 9.0)
        }

        fn now(&self) -> f64 {
            now()
        }

        fn keep_awake(&mut self, on: bool, display: bool) {
            self.portal.keep_awake(on, display);
            if on {
                *self.idle_close.lock().unwrap() = None;
                return;
            }
            let at = Instant::now();
            *self.idle_close.lock().unwrap() = Some(at);
            let (flag, p) = (self.idle_close.clone(), self.portal.clone());
            std::thread::spawn(move || {
                std::thread::sleep(LINGER);
                if *flag.lock().unwrap() == Some(at) {
                    p.close();
                }
            });
        }
    }

    impl Drop for LinuxBackend {
        fn drop(&mut self) {
            self.close();
        }
    }
}
