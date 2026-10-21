//! Recording for the Blurt Tauri app on Windows and Linux (docs/design/desktop-app.md §5 C8, WP8).
//!
//! * [`engine`] — runs `record.py start --engine ffmpeg --status-jsonl` and controls it through the session's
//!   `.cmd` file: [`start`] → [`CaptureHandle`] (`pause` / `resume` / `snap` / `stop` / `discard` / `wait`).
//!   Later a native engine (Windows Graphics Capture, PipeWire) can replace it behind the same API.
//! * [`overlay`] (feature `overlay`, Tauri 2) — the transparent, always-on-top, non-focusable, content-protected
//!   windows drawn by `web/apps/overlays`: [`overlay::pick_region`], [`overlay::hud`], [`overlay::perch`],
//!   [`overlay::note`], and [`overlay::record`] which wires a take to its HUD and the perch.
//!
//! Coordinates: a [`Region`] is physical pixels of the virtual desktop (what gdigrab / x11grab take).

pub mod engine;
pub mod region;
pub mod status;

#[cfg(feature = "overlay")]
pub mod overlay;

pub use engine::{start, CaptureError, CaptureHandle, CaptureOptions, CaptureState, Launcher, Mic};
pub use region::{CssRect, Region};
pub use status::StatusEvent;

#[cfg(feature = "overlay")]
pub use overlay::pick_region;
