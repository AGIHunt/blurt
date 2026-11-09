//! The monitors as this process sees them per-monitor DPI aware (physical pixels whatever the app's own awareness), the
//! pointer, and the clock frames and the server share.

use ::windows::Win32::Foundation::{LPARAM, POINT, RECT, TRUE};
use ::windows::Win32::Graphics::Gdi::{EnumDisplayMonitors, GetMonitorInfoW, HDC, HMONITOR, MONITORINFO, MONITORINFOEXW};
use ::windows::Win32::System::Performance::{QueryPerformanceCounter, QueryPerformanceFrequency};
use ::windows::Win32::UI::HiDpi::{
    GetDpiForMonitor, SetThreadDpiAwarenessContext, DPI_AWARENESS_CONTEXT, DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2,
    MDT_EFFECTIVE_DPI,
};
use ::windows::Win32::UI::WindowsAndMessaging::GetCursorPos;

use super::geometry::{Monitor, Rect};

/// This thread sees physical pixels until dropped (the Tauri app is per-monitor aware already; the server's threads may not be).
pub struct Dpi(DPI_AWARENESS_CONTEXT);

impl Dpi {
    pub fn physical() -> Dpi {
        Dpi(unsafe { SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2) })
    }
}

impl Drop for Dpi {
    fn drop(&mut self) {
        if !self.0 .0.is_null() {
            unsafe { SetThreadDpiAwarenessContext(self.0) };
        }
    }
}

const MONITORINFOF_PRIMARY: u32 = 1;

unsafe extern "system" fn each(m: HMONITOR, _: HDC, _: *mut RECT, data: LPARAM) -> ::windows::core::BOOL {
    let out = &mut *(data.0 as *mut Vec<Monitor>);
    let mut info = MONITORINFO { cbSize: std::mem::size_of::<MONITORINFO>() as u32, ..Default::default() };
    if GetMonitorInfoW(m, &mut info).as_bool() {
        let (mut dx, mut dy) = (96u32, 96u32);
        let _ = GetDpiForMonitor(m, MDT_EFFECTIVE_DPI, &mut dx, &mut dy);
        let r = info.rcMonitor;
        out.push(Monitor {
            rect: Rect { left: r.left, top: r.top, right: r.right, bottom: r.bottom },
            scale: dx.max(48) as f64 / 96.0,
            primary: info.dwFlags & MONITORINFOF_PRIMARY != 0,
            handle: m.0 as isize,
        });
    }
    TRUE
}

/// Every monitor, physical pixels.
pub fn all() -> Vec<Monitor> {
    let _dpi = Dpi::physical();
    let mut out: Vec<Monitor> = Vec::new();
    unsafe {
        let _ = EnumDisplayMonitors(None, None, Some(each), LPARAM(&mut out as *mut _ as isize));
    }
    out
}

// ---- several displays (the core's DisplayInfo): device names as ids, frames in points ----

/// A monitor's device name (\\.\DISPLAY2): stable while it stays connected.
fn device_name(handle: isize) -> Option<String> {
    let mut ex = MONITORINFOEXW::default();
    ex.monitorInfo.cbSize = std::mem::size_of::<MONITORINFOEXW>() as u32;
    unsafe { GetMonitorInfoW(HMONITOR(handle as *mut _), &mut ex.monitorInfo as *mut MONITORINFO) }.as_bool().then(|| {
        let n = ex.szDevice.iter().position(|c| *c == 0).unwrap_or(ex.szDevice.len());
        String::from_utf16_lossy(&ex.szDevice[..n])
    })
}

/// Every monitor with its device name.
pub fn named() -> Vec<(Monitor, String)> {
    let _dpi = Dpi::physical();
    all().into_iter().filter_map(|m| device_name(m.handle).map(|n| (m, n))).collect()
}

/// The monitor with this device name, if it's still there.
pub fn by_device(name: &str) -> Option<Monitor> {
    named().into_iter().find(|(_, n)| n == name).map(|(m, _)| m)
}

/// A monitor's frame in points: its physical rectangle ÷ its own scale (mixed DPI can leave gaps or overlaps between them; a
/// point is only ever asked which one it's on).
pub fn frame_points(m: &Monitor) -> (f64, f64, f64, f64) {
    let s = if m.scale > 0.0 { m.scale } else { 1.0 };
    (m.rect.left as f64 / s, m.rect.top as f64 / s, m.rect.width() as f64 / s, m.rect.height() as f64 / s)
}

/// The pointer in the same points as `frame_points`, by the monitor it's on.
pub fn cursor_points() -> Option<(f64, f64)> {
    let (x, y) = cursor()?;
    let all = all();
    let m = super::geometry::monitor_at(&all, x, y)?;
    let s = if m.scale > 0.0 { m.scale } else { 1.0 };
    Some((m.rect.left as f64 / s + (x - m.rect.left as f64) / s, m.rect.top as f64 / s + (y - m.rect.top as f64) / s))
}

/// The pointer in physical pixels.
pub fn cursor() -> Option<(f64, f64)> {
    let _dpi = Dpi::physical();
    let mut p = POINT::default();
    unsafe { GetCursorPos(&mut p) }.ok()?;
    Some((p.x as f64, p.y as f64))
}

/// The monitor under the pointer (else the primary).
pub fn under_pointer() -> Option<Monitor> {
    let all = all();
    let at = cursor();
    at.and_then(|(x, y)| super::geometry::monitor_at(&all, x, y).copied())
        .or_else(|| all.iter().find(|m| m.primary).copied())
        .or_else(|| all.first().copied())
}

fn frequency() -> i64 {
    use std::sync::OnceLock;
    static F: OnceLock<i64> = OnceLock::new();
    *F.get_or_init(|| {
        let mut f = 0i64;
        unsafe {
            let _ = QueryPerformanceFrequency(&mut f);
        }
        f.max(1)
    })
}

/// Seconds on QueryPerformanceCounter: the clock Windows.Graphics.Capture's SystemRelativeTime and DXGI's LastPresentTime
/// are on, so a frame's `captured` and the server's `now()` compare directly.
pub fn now() -> f64 {
    let mut c = 0i64;
    unsafe {
        let _ = QueryPerformanceCounter(&mut c);
    }
    qpc_seconds(c)
}

pub fn qpc_seconds(ticks: i64) -> f64 {
    let f = frequency();
    // whole seconds and the rest apart: ticks × 1.0 / f would lose the fraction after weeks of uptime
    (ticks / f) as f64 + (ticks % f) as f64 / f as f64
}
