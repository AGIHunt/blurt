//! What the keyboard layout in front prints on its keys, for a phone's computer keyboard (docs/design/remote.md §Computer keyboard).
//! Asks Windows, changes nothing: ToUnicodeEx with flag 4 leaves the dead-key state alone (Windows 10 1607 and later).
use super::keymap;
use crate::wire::{Legend, Legends, LEGEND_NAMES};
use std::sync::{Mutex, OnceLock};
use windows::Win32::Globalization::{GetLocaleInfoEx, LCIDToLocaleName, LOCALE_SLOCALIZEDLANGUAGENAME};
use windows::Win32::UI::Input::KeyboardAndMouse::{GetKeyboardLayout, MapVirtualKeyExW, ToUnicodeEx, HKL, MAPVK_VSC_TO_VK_EX};
use windows::Win32::UI::WindowsAndMessaging::{GetForegroundWindow, GetWindowThreadProcessId};

const VK_SHIFT: usize = 0x10;
const VK_CONTROL: usize = 0x11;
const VK_MENU: usize = 0x12;

fn typed(vk: u32, scan: u32, hkl: HKL, held: &[usize]) -> Option<String> {
    let mut state = [0u8; 256];
    for k in held {
        state[*k] = 0x80;
    }
    let mut buf = [0u16; 8];
    let n = unsafe { ToUnicodeEx(vk, scan, &state, &mut buf, 4, Some(hkl)) };
    // a dead key (-1) leaves its own character in the buffer
    let n = if n < 0 { 1 } else { n as usize };
    let s = String::from_utf16_lossy(&buf[..n.min(buf.len())]);
    (!s.is_empty() && !s.chars().any(|c| c.is_control())).then_some(s)
}

fn source(hkl: HKL) -> String {
    let lang = (hkl.0 as usize & 0xFFFF) as u32;
    let mut name = [0u16; 85];
    let n = unsafe { LCIDToLocaleName(lang, Some(&mut name), 0) };
    if n <= 1 {
        return String::new();
    }
    let mut out = [0u16; 128];
    let n = unsafe { GetLocaleInfoEx(windows::core::PCWSTR(name.as_ptr()), LOCALE_SLOCALIZEDLANGUAGENAME, Some(&mut out)) };
    String::from_utf16_lossy(&out[..(n.max(1) as usize - 1)])
}

/// The layout of the window in front; kept until that changes, since it's asked every 2 s.
pub fn legends() -> Option<Legends> {
    static LAST: OnceLock<Mutex<Option<(isize, Legends)>>> = OnceLock::new();
    let hkl = unsafe {
        let w = GetForegroundWindow();
        GetKeyboardLayout(if w.is_invalid() { 0 } else { GetWindowThreadProcessId(w, None) })
    };
    if hkl.is_invalid() {
        return None;
    }
    let mut last = LAST.get_or_init(Default::default).lock().unwrap();
    if let Some((h, l)) = last.as_ref() {
        if *h == hkl.0 as isize {
            return Some(l.clone());
        }
    }
    let mut l = Legends { source: source(hkl), ..Default::default() };
    for c in LEGEND_NAMES.chars() {
        let name = c.to_string();
        let Some(k) = keymap::key(&name) else { continue };
        let scan = k.scan as u32;
        let vk = unsafe { MapVirtualKeyExW(scan, MAPVK_VSC_TO_VK_EX, Some(hkl)) };
        if vk == 0 {
            continue;
        }
        let Some(base) = typed(vk, scan, hkl, &[]) else { continue };
        let shift = typed(vk, scan, hkl, &[VK_SHIFT]).unwrap_or_else(|| base.clone());
        // AltGr is Ctrl and Alt together; a layout without one types nothing there
        let alt_gr = typed(vk, scan, hkl, &[VK_CONTROL, VK_MENU]).filter(|a| *a != base);
        l.keys.insert(name, Legend { base, shift, alt_gr });
    }
    *last = Some((hkl.0 as isize, l.clone()));
    Some(l)
}
