//! The contract between the session server (platform-neutral: protocol, crypto, pairing, rate control, packets) and each OS.
//! The server owns timing and policy; a backend only shows, encodes and presses. Everything here mirrors what the Mac does in
//! skills/blurt/recorder/macos/Sources/BlurtApp/Remote/{RemoteInput,RemoteScreen}.swift, so read those for behaviour.
//!
//! Coordinates: "points" are the OS's logical pixels for the display being shown (DPI-scaled on Windows, the compositor's logical
//! size on Wayland). Normalised positions are 0…1 of the display being shown, origin top-left.

use std::sync::Arc;

/// RemoteModifiers on the wire, as bits. Meaning on Windows / Linux: COMMAND = the Windows / Super key, CONTROL = Ctrl,
/// OPTION = Alt, SHIFT = Shift, FUNCTION = nothing (it only exists on Apple keyboards). The phone shows Ctrl / Alt / Win
/// (or Super) for these hosts and its default keys use Ctrl for shortcuts there (docs/design/remote-protocol.md §Hosts).
pub mod mods {
    pub const COMMAND: u8 = 1;
    pub const SHIFT: u8 = 2;
    pub const OPTION: u8 = 4;
    pub const CONTROL: u8 = 8;
    pub const FUNCTION: u8 = 16;
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Button {
    Left,
    Right,
    Middle,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ScrollPhase {
    Began,
    Changed,
    Ended,
    /// the server's own coast after a fling (the Mac's momentum phase): apps that animate scrolling may treat it so
    Momentum,
}

/// RemoteSystemMove: named moves of the OS, each mapped by the backend to its own shortcut or API.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SystemMove {
    /// all windows (Windows: Win+Tab; GNOME: the Activities overview)
    MissionControl,
    /// the front app's windows (Windows: Win+Tab too, or nothing better; GNOME: Super+` cycles them)
    AppExpose,
    /// previous / next virtual desktop (Windows: Ctrl+Win+←/→; GNOME: Super+PageUp/PageDown or Ctrl+Alt+←/→)
    SpaceLeft,
    SpaceRight,
    /// zoom the front app (Ctrl+= / Ctrl+-)
    ZoomIn,
    ZoomOut,
    /// make the pointer easy to find (optional; may do nothing)
    FindCursor,
}

/// The pointer's look, when it changes: PNG with its hot spot, sizes in points.
#[derive(Clone, Debug, PartialEq)]
pub struct CursorShape {
    pub png: Vec<u8>,
    pub hot_x: f64,
    pub hot_y: f64,
    pub width: f64,
    pub height: f64,
}

/// Keys, buttons and the pointer. Called from the server's thread, one call at a time.
pub trait Input: Send {
    /// false: the OS won't take synthetic input yet (Wayland: the RemoteDesktop portal not granted; Windows: an elevated window in
    /// front that a non-elevated process can't reach). The phone shows this.
    fn can_control(&self) -> bool;
    /// One key by its wire name (RemoteKey.all in RemoteKeys.swift: "A"…"Z", "0"…"9", "F1"…"F12", "Return", "Tab", "Space", "Delete"
    /// (backspace), "Escape", "ForwardDelete", "Left", "Right", "Down", "Up", "Home", "End", "PageUp", "PageDown", and the punctuation
    /// "- = [ ] ; ' , . / \ `" as US-layout physical keys), or "" for the modifiers alone. `mods` are pressed around it, on top of
    /// whatever `set_held` holds. `down`: None = press and release; Some(true / false) = hold across calls (⌘ during ⌘Tab → Alt
    /// during Alt+Tab here). Unknown names do nothing.
    fn key(&mut self, name: &str, mods: u8, down: Option<bool>);
    /// The modifiers the phone holds (sticky keys): really down on the host until changed, so they apply to clicks and scrolls.
    fn set_held(&mut self, mods: u8);
    /// Unicode text into whatever has focus. A backend may type it as Unicode key events or paste it (keeping the clipboard), as the
    /// desktop app's dictation insert does (apps/desktop/src-tauri/src/dictation/insert_*.rs).
    fn text(&mut self, text: &str);
    /// `clicks`: 1 for a plain press, 2/3 when the server has seen a double / triple click at the same spot (it counts, not the OS).
    fn button(&mut self, button: Button, down: bool, clicks: u32);
    /// Relative move in points (already accelerated on the phone). Clamped to the desktop by the backend.
    fn move_by(&mut self, dx: f64, dy: f64);
    /// Absolute move, 0…1 of the display being shown.
    fn move_to(&mut self, x: f64, y: f64);
    /// Scroll in points, natural direction already applied by the phone (positive dy = content moves down = scrolls up, as macOS
    /// with Natural Scrolling). Backends convert to wheel units (Windows: WHEEL_DELTA 120 per line, high-resolution deltas are
    /// fine; Wayland: axis values in logical pixels) and honour the OS's own direction setting if it has one.
    fn scroll(&mut self, dx: f64, dy: f64, phase: ScrollPhase);
    fn system(&mut self, m: SystemMove);
    /// Let go of everything this backend holds down: keys, modifiers, buttons. Must be safe to call at any time, twice.
    fn release_all(&mut self);
    /// Where the pointer is, 0…1 of the display being shown (may be outside 0…1 when it's on another display). None: unknown.
    fn pointer(&self) -> Option<(f64, f64)>;
    /// The pointer's shape if it changed since the last call.
    fn cursor_shape(&mut self) -> Option<CursorShape>;
    /// Where the pointer is on the desktop, in the coordinates `Backend::displays` uses (points, top-left origin). The server follows
    /// the pointer from display to display with it. None (the default): unknown, and the server works it out from `pointer` and the
    /// display being shown. (Added 2026-11-09 for several displays.)
    fn pointer_desktop(&self) -> Option<(f64, f64)> {
        None
    }
}

/// One of the computer's displays (ToPhone.displays): its frame in points on the desktop (top-left origin, y down, as the OS's display
/// settings arrange them). On Windows a monitor's frame is its physical rectangle ÷ its own scale; mixed DPI can leave small gaps or
/// overlaps between them, which is fine: the server only asks which one a point is in.
#[derive(Clone, Debug, PartialEq)]
pub struct DisplayInfo {
    /// stable while it stays connected: the monitor's device name on Windows (\\.\DISPLAY2), the portal stream's id on Linux
    pub id: String,
    /// what the user calls it ("DELL U2723QE"); the id if nothing better is known
    pub name: String,
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
    /// the primary display
    pub main: bool,
}

impl DisplayInfo {
    pub fn contains(&self, x: f64, y: f64) -> bool {
        x >= self.x && x < self.x + self.width && y >= self.y && y < self.y + self.height
    }
}

/// What the phone asked for, already clamped by the server (RemoteScreenRequest + the rate controller's current numbers).
#[derive(Clone, Debug, PartialEq)]
pub struct ScreenConfig {
    /// output size in pixels, even numbers; the source crop is scaled to this size whatever the crop
    pub width: u32,
    pub height: u32,
    pub bitrate: u32,
    pub fps: u32,
    /// best first, from the phone: "hevc", "h264". The backend picks the first it can encode, hardware preferred.
    pub codecs: Vec<String>,
    pub crop: Crop,
    /// which display (a `DisplayInfo::id`); None: the one under the pointer, as before displays were listed. The server always names
    /// one when `Backend::displays` lists any, and starts the stream again when the pointer moves to another (follow mode) or the
    /// phone pins one, unless `Screen::set_display` switched in place.
    pub display: Option<String>,
    /// How often to look at the screen, frames a second (added 2026-11-09, docs/design/remote-realtime.md §4): 120 when `fps` is 60 or
    /// more, else `fps`. Captured faster than sent, a change is picked up within 8 ms of being drawn instead of 17; what's encoded
    /// stays at `fps` on average (`FrameCredit`). DXGI duplication and PipeWire deliver at the display's own rate whatever this says.
    pub capture_fps: u32,
    /// The phone repairs the picture (nack or ltr): no keyframe every few seconds, only when asked. False: as before, a keyframe
    /// every 600 frames or so as a safety net for a phone that can only start over.
    pub repairs: bool,
}

impl ScreenConfig {
    /// The capture rate for a sending rate: 120 at 60 or more, else the same.
    pub fn capture_for(fps: u32) -> u32 {
        if fps >= 60 {
            120
        } else {
            fps.max(1)
        }
    }
}

/// 0…1 of the display being shown (RemoteCrop).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Crop {
    pub x: f32,
    pub y: f32,
    pub w: f32,
    pub h: f32,
}

impl Crop {
    pub const WHOLE: Crop = Crop { x: 0.0, y: 0.0, w: 1.0, h: 1.0 };
}

/// What's being shown, once the stream is up.
#[derive(Clone, Debug, PartialEq)]
pub struct ScreenInfo {
    /// the display's size in points (ToPhone.screenView)
    pub width: f64,
    pub height: f64,
    /// "hevc" or "h264"
    pub codec: String,
}

/// One encoded picture. Low-latency settings throughout: no B-frames, no reordering, no lookahead, CBR-ish rate control capped at
/// `bitrate`, a keyframe only when asked (or every few seconds at most), one slice per frame.
#[derive(Clone, Debug, PartialEq)]
pub struct EncodedFrame {
    /// NAL units, each preceded by its length as 4 bytes big-endian (the AVCC / HVCC form VideoToolbox gives the Mac), with no
    /// parameter sets and no Annex B start codes. A backend whose encoder gives Annex B converts it.
    pub picture: Vec<u8>,
    pub keyframe: bool,
    /// keyframes only: VPS, SPS, PPS (HEVC) or SPS, PPS (H.264), each a bare NAL unit without start code or length
    pub parameter_sets: Vec<Vec<u8>>,
    /// which part of the display this picture shows: the crop in force when it was captured
    pub crop: Crop,
    /// when it was composed, seconds on the host's monotonic clock (the same clock the server reads in `now()`)
    pub captured: f64,
    /// A recovery frame (`Screen::recovery_frame`), not a keyframe: a P-frame from a reference the phone acknowledged (LTR), or the
    /// first of an intra refresh. The phone shows it after giving up a frame instead of waiting for a keyframe. (Added 2026-11-09.)
    pub refresh: bool,
    /// The encoder may refer back to this frame once the phone has decoded it (an LTR slot): the phone acknowledges it and the
    /// server hands this number back through `Screen::acknowledged`. None: not a reference (the default).
    pub reference: Option<u64>,
}

impl Default for EncodedFrame {
    fn default() -> Self {
        EncodedFrame {
            picture: vec![],
            keyframe: false,
            parameter_sets: vec![],
            crop: Crop::WHOLE,
            captured: 0.0,
            refresh: false,
            reference: None,
        }
    }
}

pub type FrameSink = Arc<dyn Fn(EncodedFrame) + Send + Sync>;

/// The display under the pointer, captured, cropped, scaled and encoded. One stream at a time.
pub trait Screen: Send {
    /// What `start` would wait on that the user has to answer (Wayland: the portal's dialog, the first time), as a blocking
    /// call the server makes *without* holding the backend, so keys and the pointer keep working meanwhile. Err: as `start`'s.
    /// None (the default): nothing to wait for.
    fn prepare(&mut self) -> Option<Box<dyn FnOnce() -> Result<(), String> + Send>> {
        None
    }
    /// Start, or restart with a new size. Frames go to `sink` from the backend's own thread. A still display sends nothing new
    /// (the server asks for a resend with `refresh` to sharpen the last picture). Err: a sentence for the user, already in plain
    /// words (ToPhone.screenFailed), such as the portal dialog being refused.
    fn start(&mut self, config: &ScreenConfig, sink: FrameSink) -> Result<ScreenInfo, String>;
    /// A new part of the display at the same output size. Frames say which crop they show; a change may take a frame or two.
    fn set_crop(&mut self, crop: Crop);
    fn set_rate(&mut self, bitrate: u32, fps: u32);
    /// Next frame is a keyframe, even if nothing changed on screen.
    fn keyframe(&mut self);
    /// Encode the last captured picture again (the screen stopped changing): the encoder sharpens it.
    fn refresh(&mut self);
    fn stop(&mut self);
    /// Whether this stream's encoder makes recovery frames (`recovery_frame` other than a keyframe). Asked after `start`; true lets
    /// the server offer the phone "ltr" (docs/design/remote-realtime.md §2). False (the default): a frame lost for good costs a
    /// keyframe, as before.
    fn supports_recovery(&self) -> bool {
        false
    }
    /// The phone gave up a frame: the next frame encoded is a recovery frame, flagged `EncodedFrame::refresh`: a P-frame from a
    /// reference the phone acknowledged (LTR), or the start of an intra refresh. If there's nothing acknowledged to refer to, or the
    /// encoder can't, a keyframe. As `keyframe`, the last captured picture is encoded now if nothing new is coming. Default: `keyframe`.
    fn recovery_frame(&mut self) {
        self.keyframe();
    }
    /// The phone has decoded the frames that carried these `EncodedFrame::reference`s: the encoder may refer back to them.
    fn acknowledged(&mut self, _references: &[u64]) {}
    /// Show another display without stopping the stream (same output size: the server only asks when the two have the same shape).
    /// True: done, the next frame (a keyframe) is that display's, and `pointer` / `move_to` are relative to it from now on. False (the
    /// default): not supported, and the server stops the stream and starts it again on that display.
    fn set_display(&mut self, _id: Option<&str>) -> bool {
        false
    }
}

/// What the backend gives the server.
pub trait Backend: Send {
    fn input(&mut self) -> &mut dyn Input;
    /// None: this OS can't show its screen (yet); the phone's screen button says so.
    fn screen(&mut self) -> Option<&mut dyn Screen>;
    /// "windows" or "linux" (RemoteSessionInfo.platform)
    fn platform(&self) -> &'static str;
    /// the main display's width ÷ height (RemoteSessionInfo.displayAspect)
    fn display_aspect(&self) -> f64;
    /// Seconds on a monotonic clock shared with EncodedFrame.captured.
    fn now(&self) -> f64;
    /// Keep the machine (and with `display`, the screen) awake while a phone is connected; false lets it sleep again.
    fn keep_awake(&mut self, on: bool, display: bool);
    /// Every display, in desktop points (ToPhone.displays). The server asks every 2 s while a phone is connected and tells the phone
    /// when it changed. Empty (the default): one display, whichever the backend shows; nothing is sent.
    fn displays(&self) -> Vec<DisplayInfo> {
        Vec::new()
    }
}

/// No screen, no keys: for the Mac build of this crate and for tests.
#[derive(Default)]
pub struct NoBackend {
    input: NoInput,
}

#[derive(Default)]
struct NoInput;

impl Input for NoInput {
    fn can_control(&self) -> bool {
        false
    }
    fn key(&mut self, _: &str, _: u8, _: Option<bool>) {}
    fn set_held(&mut self, _: u8) {}
    fn text(&mut self, _: &str) {}
    fn button(&mut self, _: Button, _: bool, _: u32) {}
    fn move_by(&mut self, _: f64, _: f64) {}
    fn move_to(&mut self, _: f64, _: f64) {}
    fn scroll(&mut self, _: f64, _: f64, _: ScrollPhase) {}
    fn system(&mut self, _: SystemMove) {}
    fn release_all(&mut self) {}
    fn pointer(&self) -> Option<(f64, f64)> {
        None
    }
    fn cursor_shape(&mut self) -> Option<CursorShape> {
        None
    }
}

impl Backend for NoBackend {
    fn input(&mut self) -> &mut dyn Input {
        &mut self.input
    }
    fn screen(&mut self) -> Option<&mut dyn Screen> {
        None
    }
    fn platform(&self) -> &'static str {
        if cfg!(windows) {
            "windows"
        } else {
            "linux"
        }
    }
    fn display_aspect(&self) -> f64 {
        1.6
    }
    fn now(&self) -> f64 {
        use std::sync::OnceLock;
        use std::time::Instant;
        static START: OnceLock<Instant> = OnceLock::new();
        START.get_or_init(Instant::now).elapsed().as_secs_f64()
    }
    fn keep_awake(&mut self, _: bool, _: bool) {}
}
