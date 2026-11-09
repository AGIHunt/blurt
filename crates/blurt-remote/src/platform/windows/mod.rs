//! Windows backend (docs/design/remote-windows.md §Windows backend), the contract in host.rs. Windows 10 1903+ and 11.
//!
//!   screen.rs     the monitor under the pointer: Windows.Graphics.Capture (capture.rs; DXGI Desktop Duplication when WGC
//!                 isn't there) → the D3D11 video processor crops and scales to NV12 at a constant size (convert.rs) → a
//!                 Media Foundation hardware encoder, H.264 or HEVC, low latency (encoder.rs) → length-prefixed NAL units
//!   input.rs      SendInput: keys by scan code, the pointer in physical pixels from points, the wheel in high resolution,
//!                 text as Unicode key events or pasted (clipboard.rs); the cursor's look; UIPI
//!   power.rs      keep the PC (and its display) awake while a phone is connected
//!
//! The pure parts (key tables, the bitstream, geometry, bookkeeping) build on any OS so they're unit-tested on the Mac too.

pub mod annexb;
pub mod cursor_image;
pub mod geometry;
pub mod keyboard;
pub mod keymap;
pub mod pacing;
pub mod pointer;

#[cfg(windows)]
mod capture;
#[cfg(windows)]
mod clipboard;
#[cfg(windows)]
mod convert;
#[cfg(windows)]
mod encoder;
#[cfg(windows)]
pub mod input;
#[cfg(windows)]
pub mod monitors;
#[cfg(windows)]
mod power;
#[cfg(windows)]
pub mod screen;

#[cfg(windows)]
pub use self::imp::{backend, WinBackend};

#[cfg(windows)]
mod imp {
    use std::sync::{Arc, Mutex};

    use super::geometry::Monitor;
    use super::input::WinInput;
    use super::screen::WinScreen;
    use crate::host::{Backend, DisplayInfo, Input, Screen};

    /// The monitor being shown, shared by the screen (which picks it) and the input (which places the pointer on it).
    pub type Shown = Arc<Mutex<Option<Monitor>>>;

    pub struct WinBackend {
        input: WinInput,
        screen: WinScreen,
        power: super::power::Power,
    }

    impl WinBackend {
        pub fn new() -> Self {
            let shown: Shown = Arc::new(Mutex::new(None));
            WinBackend { input: WinInput::new(shown.clone()), screen: WinScreen::new(shown), power: super::power::Power::default() }
        }

        /// The concrete screen, for what the trait doesn't say (examples/win_smoke.rs reads its numbers).
        pub fn win_screen(&mut self) -> &mut WinScreen {
            &mut self.screen
        }
    }

    impl Default for WinBackend {
        fn default() -> Self {
            Self::new()
        }
    }

    pub fn backend() -> Box<dyn Backend> {
        Box::new(WinBackend::new())
    }

    impl Backend for WinBackend {
        fn input(&mut self) -> &mut dyn Input {
            &mut self.input
        }
        fn screen(&mut self) -> Option<&mut dyn Screen> {
            Some(&mut self.screen)
        }
        fn platform(&self) -> &'static str {
            "windows"
        }
        fn display_aspect(&self) -> f64 {
            let all = super::monitors::all();
            let m = all.iter().find(|m| m.primary).or(all.first());
            m.map_or(16.0 / 9.0, |m| m.rect.width().max(1) as f64 / m.rect.height().max(1) as f64)
        }
        fn now(&self) -> f64 {
            super::monitors::now()
        }
        fn keep_awake(&mut self, on: bool, display: bool) {
            self.power.set(on, display);
        }
        /// Several displays: every monitor by its device name, in points (monitors.rs `frame_points`).
        fn displays(&self) -> Vec<DisplayInfo> {
            super::monitors::named()
                .into_iter()
                .map(|(m, name)| {
                    let (x, y, width, height) = super::monitors::frame_points(&m);
                    let n = name.trim_start_matches(r"\\.\").trim_start_matches("DISPLAY");
                    DisplayInfo { name: format!("Display {n}"), id: name, x, y, width, height, main: m.primary }
                })
                .collect()
        }
    }

    impl Drop for WinBackend {
        fn drop(&mut self) {
            self.screen.stop();
            self.input.release_all();
            self.power.set(false, false);
        }
    }
}
