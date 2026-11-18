//! The phone's hands on Windows: SendInput for keys, text, the pointer, buttons and the wheel (the Mac's RemoteInput.swift).
//!
//! * Every event carries `REMOTE_TAG` in dwExtraInfo, as the Mac's carry its marker: Blurt's own dictation hook
//!   (dictation/keys_win.rs) can tell the phone's keys from the user's.
//! * The pointer is placed with absolute moves over the virtual desktop (MOUSEEVENTF_VIRTUALDESK), in physical pixels this
//!   side keeps with their fractions: Windows' pointer acceleration ("Enhance pointer precision") would bend relative moves a
//!   second time after the phone's own curve. Buttons carry the same position, so a click lands where the pointer was just put
//!   even before the system has caught up with the move.
//! * A real mouse moved in between takes over (more than 3 px from where we put it), as on the Mac.

use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use ::windows::Win32::Foundation::{CloseHandle, HANDLE, HWND, LPARAM, WPARAM};
use ::windows::Win32::Graphics::Gdi::{
    CreateCompatibleDC, DeleteDC, DeleteObject, GetDIBits, GetObjectW, BITMAP, BITMAPINFO, BITMAPINFOHEADER, BI_RGB,
    DIB_RGB_COLORS, HBITMAP, HGDIOBJ,
};
use ::windows::Win32::Security::{GetTokenInformation, TokenElevation, TOKEN_ELEVATION, TOKEN_QUERY};
use ::windows::Win32::System::StationsAndDesktops::{CloseDesktop, OpenInputDesktop, DESKTOP_ACCESS_FLAGS, DESKTOP_CONTROL_FLAGS};
use ::windows::Win32::System::SystemInformation::GetTickCount;
use ::windows::Win32::System::Threading::{GetCurrentProcess, OpenProcess, OpenProcessToken, PROCESS_QUERY_LIMITED_INFORMATION};
use ::windows::Win32::UI::Input::Ime::ImmGetDefaultIMEWnd;
use ::windows::Win32::UI::Input::KeyboardAndMouse::{
    GetDoubleClickTime, MapVirtualKeyW, SendInput, INPUT, INPUT_0, INPUT_KEYBOARD, INPUT_MOUSE, KEYBDINPUT, KEYBD_EVENT_FLAGS,
    KEYEVENTF_EXTENDEDKEY, KEYEVENTF_KEYUP, KEYEVENTF_SCANCODE, KEYEVENTF_UNICODE, MAPVK_VK_TO_VSC, MOUSEEVENTF_ABSOLUTE,
    MOUSEEVENTF_HWHEEL, MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP, MOUSEEVENTF_MIDDLEDOWN, MOUSEEVENTF_MIDDLEUP, MOUSEEVENTF_MOVE,
    MOUSEEVENTF_RIGHTDOWN, MOUSEEVENTF_RIGHTUP, MOUSEEVENTF_VIRTUALDESK, MOUSEEVENTF_WHEEL, MOUSEINPUT, MOUSE_EVENT_FLAGS,
    VIRTUAL_KEY,
};
use ::windows::Win32::UI::WindowsAndMessaging::{
    GetCursorInfo, GetForegroundWindow, GetIconInfo, GetSystemMetrics, GetWindowThreadProcessId, SendMessageTimeoutW,
    SystemParametersInfoW, CURSORINFO, CURSOR_SHOWING, HICON, ICONINFO, SMTO_ABORTIFHUNG, SM_CXDOUBLECLK, SM_CYDOUBLECLK,
    SPI_GETWHEELSCROLLLINES, SYSTEM_PARAMETERS_INFO_ACTION, SYSTEM_PARAMETERS_INFO_UPDATE_FLAGS,
};

use super::geometry::{self, Monitor};
use super::imp::Shown;
use super::keyboard::{KeyEvent, Keyboard};
use super::keymap::{self, Key};
use super::monitors;
use super::pointer::{self, LastDown, Wheel};
use crate::host::{mods, Button, CursorShape, Input, ScrollPhase, SystemMove};

/// dwExtraInfo of everything the phone sends ("BRMT", the Mac's RemoteInput.marker). The desktop app's own keys are "BLRT".
pub const REMOTE_TAG: usize = 0x4252_4D54;

/// Text longer than this (UTF-16 units) is pasted, as on the Mac: a long run of key events is slow and an app may drop some.
const TYPE_AT_MOST: usize = 64;

struct Paste {
    saved: Option<super::clipboard::Saved>,
    generation: u64,
    ours: u32,
}

pub struct WinInput {
    kb: Keyboard,
    shown: Shown,
    /// where we put the pointer, physical pixels with their fractions
    pos: Option<(f64, f64)>,
    placed_at: Option<Instant>,
    buttons: Vec<Button>,
    last_down: Option<LastDown>,
    wheel: Wheel,
    lines: (u32, Option<Instant>),
    monitors: (Vec<Monitor>, Option<Instant>),
    cursor: isize,
    control: (bool, Option<Instant>),
    paste: Arc<Mutex<Paste>>,
}

impl WinInput {
    pub fn new(shown: Shown) -> Self {
        WinInput {
            kb: Keyboard::default(),
            shown,
            pos: None,
            placed_at: None,
            buttons: Vec::new(),
            last_down: None,
            wheel: Wheel::default(),
            lines: (3, None),
            monitors: (Vec::new(), None),
            cursor: 0,
            control: (true, None),
            paste: Arc::new(Mutex::new(Paste { saved: None, generation: 0, ours: 0 })),
        }
    }

    // MARK: sending

    fn key_input(k: Key, down: bool) -> INPUT {
        let mut f = KEYBD_EVENT_FLAGS(0);
        if !down {
            f |= KEYEVENTF_KEYUP;
        }
        if k.extended {
            f |= KEYEVENTF_EXTENDEDKEY;
        }
        if k.positional {
            f |= KEYEVENTF_SCANCODE;
        }
        INPUT {
            r#type: INPUT_KEYBOARD,
            Anonymous: INPUT_0 {
                ki: KEYBDINPUT {
                    wVk: VIRTUAL_KEY(if k.positional { 0 } else { k.vk }),
                    wScan: k.scan,
                    dwFlags: f,
                    time: 0,
                    dwExtraInfo: REMOTE_TAG,
                },
            },
        }
    }

    fn unicode_input(unit: u16, down: bool) -> INPUT {
        let mut f = KEYEVENTF_UNICODE;
        if !down {
            f |= KEYEVENTF_KEYUP;
        }
        INPUT {
            r#type: INPUT_KEYBOARD,
            Anonymous: INPUT_0 { ki: KEYBDINPUT { wVk: VIRTUAL_KEY(0), wScan: unit, dwFlags: f, time: 0, dwExtraInfo: REMOTE_TAG } },
        }
    }

    fn mouse_input(dx: i32, dy: i32, data: i32, flags: MOUSE_EVENT_FLAGS, time: u32) -> INPUT {
        INPUT {
            r#type: INPUT_MOUSE,
            Anonymous: INPUT_0 { mi: MOUSEINPUT { dx, dy, mouseData: data as u32, dwFlags: flags, time, dwExtraInfo: REMOTE_TAG } },
        }
    }

    fn send(inputs: &[INPUT]) {
        if inputs.is_empty() {
            return;
        }
        // one call: nothing the user does gets in between
        unsafe { SendInput(inputs, std::mem::size_of::<INPUT>() as i32) };
    }

    fn send_keys(evs: &[KeyEvent]) {
        let v: Vec<INPUT> = evs.iter().map(|e| Self::key_input(e.key, e.down)).collect();
        Self::send(&v);
    }

    // MARK: where things are

    fn monitors(&mut self) -> &[Monitor] {
        let stale = self.monitors.1.is_none_or(|t| t.elapsed() > Duration::from_secs(2)) || self.monitors.0.is_empty();
        if stale {
            self.monitors = (monitors::all(), Some(Instant::now()));
        }
        &self.monitors.0
    }

    /// The monitor being shown, or the one under the pointer.
    fn shown_monitor(&mut self) -> Option<Monitor> {
        if let Some(m) = *self.shown.lock().unwrap_or_else(|e| e.into_inner()) {
            return Some(m);
        }
        let at = self.pos.or_else(monitors::cursor);
        let ms = self.monitors().to_vec();
        at.and_then(|(x, y)| geometry::monitor_at(&ms, x, y).copied()).or_else(|| ms.iter().find(|m| m.primary).copied())
    }

    /// Where the pointer is: where we put it (with its fractions), unless a real mouse has moved it since.
    fn here(&mut self) -> (f64, f64) {
        if let (Some(p), Some(t)) = (self.pos, self.placed_at) {
            // the system takes a moment to report a pointer just placed
            if t.elapsed() < Duration::from_millis(150) {
                return p;
            }
        }
        let c = monitors::cursor().unwrap_or((0.0, 0.0));
        if let Some(p) = self.pos {
            if (c.0 - p.0).hypot(c.1 - p.1) <= 3.0 {
                return p;
            }
        }
        self.pos = Some(c);
        c
    }

    fn absolute(&mut self, p: (f64, f64)) -> (i32, i32) {
        let desk = geometry::virtual_desktop(self.monitors());
        geometry::to_absolute(&desk, p.0, p.1)
    }

    const ABS: MOUSE_EVENT_FLAGS = MOUSE_EVENT_FLAGS(MOUSEEVENTF_MOVE.0 | MOUSEEVENTF_ABSOLUTE.0 | MOUSEEVENTF_VIRTUALDESK.0);

    fn put(&mut self, p: (f64, f64)) {
        self.pos = Some(p);
        self.placed_at = Some(Instant::now());
        let (x, y) = self.absolute(p);
        Self::send(&[Self::mouse_input(x, y, 0, Self::ABS, 0)]);
    }

    fn scroll_lines(&mut self) -> u32 {
        if self.lines.1.is_none_or(|t| t.elapsed() > Duration::from_secs(5)) {
            let mut n = 3u32;
            unsafe {
                let _ = SystemParametersInfoW(
                    SPI_GETWHEELSCROLLLINES,
                    0,
                    Some(&mut n as *mut u32 as *mut _),
                    SYSTEM_PARAMETERS_INFO_UPDATE_FLAGS(0),
                );
            }
            self.lines = (n, Some(Instant::now()));
        }
        self.lines.0
    }

    // MARK: text

    /// An input method is on and composing in its own script (Microsoft Pinyin in Chinese mode, Japanese IME in kana): Unicode key
    /// events would go into or break its composition, so the text is pasted. The IME's default window answers for any process.
    fn ime_native() -> bool {
        const WM_IME_CONTROL: u32 = 0x0283;
        const IMC_GETCONVERSIONMODE: usize = 0x0001;
        const IMC_GETOPENSTATUS: usize = 0x0005;
        const IME_CMODE_NATIVE: usize = 0x0001;
        unsafe {
            let fg = GetForegroundWindow();
            if fg.0.is_null() {
                return false;
            }
            let ime = ImmGetDefaultIMEWnd(fg);
            if ime.0.is_null() {
                return false;
            }
            let ask = |what: usize| -> Option<usize> {
                let mut r = 0usize;
                let ok = SendMessageTimeoutW(ime, WM_IME_CONTROL, WPARAM(what), LPARAM(0), SMTO_ABORTIFHUNG, 100, Some(&mut r));
                (ok.0 != 0).then_some(r)
            };
            ask(IMC_GETOPENSTATUS).unwrap_or(0) != 0 && ask(IMC_GETCONVERSIONMODE).unwrap_or(0) & IME_CMODE_NATIVE != 0
        }
    }

    fn type_text(&mut self, text: &str) {
        let mut v: Vec<INPUT> = Vec::new();
        let mut chars = text.chars().peekable();
        while let Some(c) = chars.next() {
            match c {
                '\r' => {
                    if chars.peek() != Some(&'\n') {
                        Self::send(&std::mem::take(&mut v));
                        let evs = self.kb.press("Return", 0);
                        Self::send_keys(&evs);
                    }
                }
                '\n' => {
                    Self::send(&std::mem::take(&mut v));
                    let evs = self.kb.press("Return", 0);
                    Self::send_keys(&evs);
                }
                c => {
                    let mut buf = [0u16; 2];
                    // a surrogate pair goes as its two units, each down and up: apps put them together
                    for u in c.encode_utf16(&mut buf).iter() {
                        v.push(Self::unicode_input(*u, true));
                        v.push(Self::unicode_input(*u, false));
                    }
                }
            }
        }
        Self::send(&v);
    }

    fn paste_text(&mut self, text: &str) {
        let generation = {
            let mut p = self.paste.lock().unwrap_or_else(|e| e.into_inner());
            if p.saved.is_none() {
                p.saved = Some(super::clipboard::save());
            }
            if !super::clipboard::set_text(text) {
                return;
            }
            p.ours = super::clipboard::sequence();
            p.generation += 1;
            p.generation
        };
        // Ctrl+V by the key's meaning, not its place: V on any layout
        let v = Key { vk: 0x56, scan: unsafe { MapVirtualKeyW(0x56, MAPVK_VK_TO_VSC) } as u16, extended: false, positional: false };
        let ctrl = keymap::mod_key(mods::CONTROL).unwrap();
        let (up, again) = self.kb.around_paste();
        let mut evs = up;
        let ctrl_down = self.kb.down_mods() & mods::CONTROL != 0;
        if !ctrl_down {
            evs.push(KeyEvent { key: ctrl, down: true });
        }
        evs.push(KeyEvent { key: v, down: true });
        evs.push(KeyEvent { key: v, down: false });
        if !ctrl_down {
            evs.push(KeyEvent { key: ctrl, down: false });
        }
        evs.extend(again);
        Self::send_keys(&evs);
        // the old clipboard back once the app has read it, unless more text came meanwhile or someone copied something since
        let paste = self.paste.clone();
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(600));
            let mut p = paste.lock().unwrap_or_else(|e| e.into_inner());
            if p.generation != generation {
                return;
            }
            if let Some(s) = p.saved.take() {
                if super::clipboard::sequence() == p.ours {
                    super::clipboard::restore(&s);
                }
            }
        });
    }

    // MARK: UIPI

    fn elevated(process: HANDLE) -> Option<bool> {
        unsafe {
            let mut tok = HANDLE::default();
            OpenProcessToken(process, TOKEN_QUERY, &mut tok).ok()?;
            let mut e = TOKEN_ELEVATION::default();
            let mut len = 0u32;
            let r = GetTokenInformation(
                tok,
                TokenElevation,
                Some(&mut e as *mut _ as *mut _),
                std::mem::size_of::<TOKEN_ELEVATION>() as u32,
                &mut len,
            );
            let _ = CloseHandle(tok);
            r.ok()?;
            Some(e.TokenIsElevated != 0)
        }
    }

    /// Our input reaches the window in front: not the secure desktop (UAC, the lock screen), and not an elevated window while we
    /// aren't (UIPI drops our events without a word). A process we can't even query is taken as elevated.
    fn reachable() -> bool {
        unsafe {
            const DESKTOP_READOBJECTS: u32 = 0x0001;
            match OpenInputDesktop(DESKTOP_CONTROL_FLAGS(0), false, DESKTOP_ACCESS_FLAGS(DESKTOP_READOBJECTS)) {
                Ok(d) => {
                    let _ = CloseDesktop(d);
                }
                Err(_) => return false,
            }
            if Self::elevated(GetCurrentProcess()).unwrap_or(false) {
                return true;
            }
            let fg: HWND = GetForegroundWindow();
            if fg.0.is_null() {
                return true;
            }
            let mut pid = 0u32;
            GetWindowThreadProcessId(fg, Some(&mut pid));
            if pid == 0 || pid == std::process::id() {
                return true;
            }
            match OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid) {
                Ok(h) => {
                    let e = Self::elevated(h).unwrap_or(true);
                    let _ = CloseHandle(h);
                    !e
                }
                Err(_) => false,
            }
        }
    }

    // MARK: the cursor's look

    unsafe fn read_bitmap(bmp: HBITMAP) -> Option<(u32, u32, Vec<u8>)> {
        if bmp.is_invalid() {
            return None;
        }
        let mut b = BITMAP::default();
        if GetObjectW(HGDIOBJ(bmp.0), std::mem::size_of::<BITMAP>() as i32, Some(&mut b as *mut _ as *mut _)) == 0 {
            return None;
        }
        let (w, h) = (b.bmWidth.max(0) as u32, b.bmHeight.max(0) as u32);
        if w == 0 || h == 0 || w > 1024 || h > 2048 {
            return None;
        }
        let mut bi = BITMAPINFO { bmiHeader: BITMAPINFOHEADER {
            biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
            biWidth: w as i32,
            biHeight: -(h as i32), // top-down
            biPlanes: 1,
            biBitCount: 32,
            biCompression: BI_RGB.0,
            ..Default::default()
        }, ..Default::default() };
        let mut px = vec![0u8; (w * h * 4) as usize];
        let dc = CreateCompatibleDC(None);
        let n = GetDIBits(dc, bmp, 0, h, Some(px.as_mut_ptr() as *mut _), &mut bi, DIB_RGB_COLORS);
        let _ = DeleteDC(dc);
        (n > 0).then_some((w, h, px))
    }

    fn png(img: &super::cursor_image::Image) -> Option<Vec<u8>> {
        let mut out = Vec::new();
        {
            let mut e = png::Encoder::new(&mut out, img.width, img.height);
            e.set_color(png::ColorType::Rgba);
            e.set_depth(png::BitDepth::Eight);
            let mut w = e.write_header().ok()?;
            w.write_image_data(&img.rgba).ok()?;
        }
        Some(out)
    }
}

impl Input for WinInput {
    fn can_control(&self) -> bool {
        // asked often; the answer is cheap but not free. `&self`: the cache lives behind a cell-free copy
        if let (v, Some(t)) = self.control {
            if t.elapsed() < Duration::from_millis(300) {
                return v;
            }
        }
        Self::reachable()
    }

    fn key(&mut self, name: &str, mods: u8, down: Option<bool>) {
        let evs = match down {
            None => self.kb.press(name, mods),
            Some(d) => self.kb.hold(name, mods, d),
        };
        Self::send_keys(&evs);
        self.control = (Self::reachable(), Some(Instant::now()));
    }

    fn set_held(&mut self, mods: u8) {
        let evs = self.kb.set_sticky(mods);
        Self::send_keys(&evs);
    }

    fn text(&mut self, text: &str) {
        if text.is_empty() {
            return;
        }
        if text.encode_utf16().count() > TYPE_AT_MOST || Self::ime_native() {
            self.paste_text(text);
        } else {
            self.type_text(text);
        }
    }

    fn button(&mut self, button: Button, down: bool, clicks: u32) {
        let mut at = self.here();
        let now = unsafe { GetTickCount() };
        let mut time = 0u32;
        if down {
            let box_ = unsafe { (GetSystemMetrics(SM_CXDOUBLECLK), GetSystemMetrics(SM_CYDOUBLECLK)) };
            let dbl = unsafe { GetDoubleClickTime() };
            let plan = pointer::plan_down(self.last_down.as_ref(), button, clicks, now, at, dbl, box_);
            if let Some(p) = plan.move_to {
                at = p;
            }
            if let Some(t) = plan.time {
                time = t;
            }
            self.kb.pointer_used();
            if !self.buttons.contains(&button) {
                self.buttons.push(button);
            }
        } else {
            self.buttons.retain(|b| *b != button);
        }
        let flag = match (button, down) {
            (Button::Left, true) => MOUSEEVENTF_LEFTDOWN,
            (Button::Left, false) => MOUSEEVENTF_LEFTUP,
            (Button::Right, true) => MOUSEEVENTF_RIGHTDOWN,
            (Button::Right, false) => MOUSEEVENTF_RIGHTUP,
            (Button::Middle, true) => MOUSEEVENTF_MIDDLEDOWN,
            (Button::Middle, false) => MOUSEEVENTF_MIDDLEUP,
        };
        self.pos = Some(at);
        let (x, y) = self.absolute(at);
        Self::send(&[Self::mouse_input(x, y, 0, Self::ABS | flag, time)]);
        if down {
            self.last_down = Some(LastDown { button, at: if time != 0 { time } else { now }, x: at.0, y: at.1, up_at: 0 });
        } else if let Some(l) = self.last_down.as_mut().filter(|l| l.button == button) {
            l.up_at = unsafe { GetTickCount() };
        }
    }

    fn move_by(&mut self, dx: f64, dy: f64) {
        let from = self.here();
        let ms = self.monitors().to_vec();
        let to = geometry::move_by(&ms, from, dx, dy);
        self.pos = Some(to);
        let (x, y) = self.absolute(to);
        Self::send(&[Self::mouse_input(x, y, 0, Self::ABS, 0)]);
    }

    fn move_to(&mut self, x: f64, y: f64) {
        let Some(m) = self.shown_monitor() else { return };
        let p = m.place(x, y);
        self.put(p);
    }

    fn scroll(&mut self, dx: f64, dy: f64, phase: ScrollPhase) {
        if phase == ScrollPhase::Began {
            self.wheel.reset();
        }
        if phase == ScrollPhase::Ended {
            return;
        }
        let per = pointer::units_per_point(self.scroll_lines());
        let (h, v) = self.wheel.add(dx, dy, per);
        if h == 0 && v == 0 {
            return;
        }
        self.kb.pointer_used();
        let mut evs = Vec::with_capacity(2);
        if v != 0 {
            evs.push(Self::mouse_input(0, 0, v, MOUSEEVENTF_WHEEL, 0));
        }
        if h != 0 {
            evs.push(Self::mouse_input(0, 0, h, MOUSEEVENTF_HWHEEL, 0));
        }
        Self::send(&evs);
    }

    fn system(&mut self, m: SystemMove) {
        use mods::*;
        let evs = match m {
            // Task View is both: Windows has no "this app's windows" view
            SystemMove::MissionControl | SystemMove::AppExpose => self.kb.press("Tab", COMMAND),
            SystemMove::SpaceLeft => self.kb.press("Left", CONTROL | COMMAND),
            SystemMove::SpaceRight => self.kb.press("Right", CONTROL | COMMAND),
            SystemMove::ZoomIn | SystemMove::ZoomOut => {
                // by the key's meaning: the layout's own + / − (Ctrl+= on a US keyboard, Ctrl++ on a German one)
                let vk = if m == SystemMove::ZoomIn { keymap::VK_OEM_PLUS } else { keymap::VK_OEM_MINUS };
                let scan = unsafe { MapVirtualKeyW(vk as u32, MAPVK_VK_TO_VSC) } as u16;
                self.kb.press_key(Some(Key { vk, scan, extended: false, positional: false }), CONTROL)
            }
            SystemMove::FindCursor => {
                // "Show the location of the pointer when I press the Ctrl key", if it's on
                const SPI_GETMOUSESONAR: u32 = 0x101C;
                let mut on = 0i32;
                unsafe {
                    let _ = SystemParametersInfoW(
                        SYSTEM_PARAMETERS_INFO_ACTION(SPI_GETMOUSESONAR),
                        0,
                        Some(&mut on as *mut i32 as *mut _),
                        SYSTEM_PARAMETERS_INFO_UPDATE_FLAGS(0),
                    );
                }
                if on != 0 {
                    self.kb.press("", CONTROL)
                } else {
                    Vec::new()
                }
            }
        };
        Self::send_keys(&evs);
    }

    fn release_all(&mut self) {
        let at = self.pos.unwrap_or_else(|| monitors::cursor().unwrap_or((0.0, 0.0)));
        let (x, y) = self.absolute(at);
        let ups: Vec<INPUT> = std::mem::take(&mut self.buttons)
            .into_iter()
            .map(|b| {
                let f = match b {
                    Button::Left => MOUSEEVENTF_LEFTUP,
                    Button::Right => MOUSEEVENTF_RIGHTUP,
                    Button::Middle => MOUSEEVENTF_MIDDLEUP,
                };
                Self::mouse_input(x, y, 0, Self::ABS | f, 0)
            })
            .collect();
        Self::send(&ups);
        let evs = self.kb.release_all();
        Self::send_keys(&evs);
        self.wheel.reset();
    }

    /// Several displays: the pointer in the points `Backend::displays` uses.
    fn pointer_desktop(&self) -> Option<(f64, f64)> {
        monitors::cursor_points()
    }

    fn pointer(&self) -> Option<(f64, f64)> {
        let (x, y) = monitors::cursor()?;
        let shown = *self.shown.lock().unwrap_or_else(|e| e.into_inner());
        let m = shown.or_else(monitors::under_pointer)?;
        Some(m.normalise(x, y))
    }

    fn cursor_shape(&mut self) -> Option<CursorShape> {
        let _dpi = monitors::Dpi::physical();
        let mut ci = CURSORINFO { cbSize: std::mem::size_of::<CURSORINFO>() as u32, ..Default::default() };
        unsafe { GetCursorInfo(&mut ci) }.ok()?;
        if ci.flags.0 & CURSOR_SHOWING.0 == 0 || ci.hCursor.is_invalid() {
            return None;
        }
        let id = ci.hCursor.0 as isize;
        if id == self.cursor {
            return None;
        }
        let mut ii = ICONINFO::default();
        unsafe { GetIconInfo(HICON(ci.hCursor.0), &mut ii) }.ok()?;
        let color = unsafe { Self::read_bitmap(ii.hbmColor) };
        let mask = unsafe { Self::read_bitmap(ii.hbmMask) };
        unsafe {
            if !ii.hbmColor.is_invalid() {
                let _ = DeleteObject(HGDIOBJ(ii.hbmColor.0));
            }
            if !ii.hbmMask.is_invalid() {
                let _ = DeleteObject(HGDIOBJ(ii.hbmMask.0));
            }
        }
        let img = match (color, mask) {
            (Some((w, h, c)), m) => super::cursor_image::from_color(w, h, &c, m.as_ref().filter(|m| m.0 == w).map(|m| m.2.as_slice())),
            (None, Some((w, h2, m))) => super::cursor_image::from_mono(w, h2, &m),
            (None, None) => None,
        }?;
        let png = Self::png(&img)?;
        self.cursor = id;
        let scale = self.shown_monitor().map_or(1.0, |m| m.scale).max(0.5);
        Some(CursorShape {
            png,
            hot_x: ii.xHotspot as f64 / scale,
            hot_y: ii.yHotspot as f64 / scale,
            width: img.width as f64 / scale,
            height: img.height as f64 / scale,
        })
    }
}
