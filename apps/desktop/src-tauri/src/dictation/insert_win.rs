//! Putting the text in on Windows (docs/design/dictation.md §Insert; the Mac's DictationInsert): the clipboard is
//! saved (every format it holds), the text goes on it, Ctrl+V goes to the window in front, and the old clipboard comes
//! back once the paste has landed (paste_policy.rs decides when; 0.6 s without a read-back).
//!
//! * Only into the app the take started in: `foreground_pid` at key-down vs at paste time; else copy.
//! * UIPI: a window of a process running elevated (as admin) ignores our SendInput — such a target gets the copy, with
//!   "Copied — paste with Ctrl+V".
//! * Formats Windows renders on demand (delayed rendering) or that are handles rather than memory (bitmaps, metafiles)
//!   can't be read as bytes: those are left out of the copy we restore; CF_BITMAP comes back through CF_DIB, which
//!   Windows synthesizes from it.

use std::time::Duration;

use windows::Win32::Foundation::{CloseHandle, HANDLE, HGLOBAL, HWND};
use windows::Win32::Security::{GetTokenInformation, TokenElevation, TOKEN_ELEVATION, TOKEN_QUERY};
use windows::Win32::System::DataExchange::{
    CloseClipboard, EmptyClipboard, EnumClipboardFormats, GetClipboardData,
    GetClipboardSequenceNumber, OpenClipboard, SetClipboardData,
};
use windows::Win32::System::Memory::{
    GlobalAlloc, GlobalLock, GlobalSize, GlobalUnlock, GMEM_MOVEABLE,
};
use windows::Win32::System::Threading::{
    GetCurrentProcess, OpenProcess, OpenProcessToken, QueryFullProcessImageNameW,
    PROCESS_NAME_WIN32, PROCESS_QUERY_LIMITED_INFORMATION,
};
use windows::Win32::UI::Input::KeyboardAndMouse::{
    GetAsyncKeyState, VK_CONTROL, VK_LMENU, VK_LSHIFT, VK_LWIN, VK_RETURN, VK_RMENU, VK_RSHIFT,
    VK_RWIN, VK_V,
};
use windows::Win32::UI::WindowsAndMessaging::{GetForegroundWindow, GetWindowThreadProcessId};

use super::keys_win::send_keys;

const CF_UNICODETEXT: u32 = 13;
const CF_BITMAP: u32 = 2;
const CF_METAFILEPICT: u32 = 3;
const CF_PALETTE: u32 = 9;
const CF_ENHMETAFILE: u32 = 14;
const CF_OWNERDISPLAY: u32 = 0x80;
const CF_DSPBITMAP: u32 = 0x82;
const CF_DSPMETAFILEPICT: u32 = 0x83;
const CF_DSPENHMETAFILE: u32 = 0x8E;

/// The window in front and its process.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Front {
    pub pid: u32,
    pub hwnd: isize,
    /// the executable's file name, e.g. "WindowsTerminal.exe" (for the history's `app` and the terminal variant)
    pub exe: String,
}

pub fn front() -> Option<Front> {
    unsafe {
        let hwnd = GetForegroundWindow();
        if hwnd.0.is_null() {
            return None;
        }
        let mut pid = 0u32;
        GetWindowThreadProcessId(hwnd, Some(&mut pid));
        Some(Front {
            pid,
            hwnd: hwnd.0 as isize,
            exe: exe_name(pid).unwrap_or_default(),
        })
    }
}

fn exe_name(pid: u32) -> Option<String> {
    unsafe {
        let h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid).ok()?;
        let mut buf = [0u16; 1024];
        let mut n = buf.len() as u32;
        let ok = QueryFullProcessImageNameW(
            h,
            PROCESS_NAME_WIN32,
            windows::core::PWSTR(buf.as_mut_ptr()),
            &mut n,
        )
        .is_ok();
        let _ = CloseHandle(h);
        if !ok {
            return None;
        }
        let path = String::from_utf16_lossy(&buf[..n as usize]);
        Some(path.rsplit('\\').next().unwrap_or(&path).to_string())
    }
}

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

/// UIPI: a target running elevated while we aren't won't take our keys. A process we can't even query is treated
/// the same way (protected / elevated).
pub fn blocks_input(pid: u32) -> bool {
    unsafe {
        let me = elevated(GetCurrentProcess()).unwrap_or(false);
        if me {
            return false;
        }
        match OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid) {
            Ok(h) => {
                let e = elevated(h).unwrap_or(true);
                let _ = CloseHandle(h);
                e
            }
            Err(_) => true,
        }
    }
}

/// What the clipboard held, to put back.
pub struct Saved {
    items: Vec<(u32, Vec<u8>)>,
}

fn open_clipboard() -> bool {
    // another app may hold it for a moment
    for _ in 0..10 {
        if unsafe { OpenClipboard(Some(HWND::default())) }.is_ok() {
            return true;
        }
        std::thread::sleep(Duration::from_millis(15));
    }
    false
}

fn readable(f: u32) -> bool {
    !matches!(
        f,
        CF_BITMAP
            | CF_METAFILEPICT
            | CF_PALETTE
            | CF_ENHMETAFILE
            | CF_OWNERDISPLAY
            | CF_DSPBITMAP
            | CF_DSPMETAFILEPICT
            | CF_DSPENHMETAFILE
    )
}

pub fn save() -> Saved {
    let mut items = Vec::new();
    if !open_clipboard() {
        return Saved { items };
    }
    unsafe {
        let mut f = 0u32;
        loop {
            f = EnumClipboardFormats(f);
            if f == 0 {
                break;
            }
            if !readable(f) {
                continue;
            }
            let Ok(h) = GetClipboardData(f) else { continue };
            let g = HGLOBAL(h.0);
            let size = GlobalSize(g);
            let p = GlobalLock(g);
            if p.is_null() || size == 0 {
                continue;
            }
            items.push((f, std::slice::from_raw_parts(p as *const u8, size).to_vec()));
            let _ = GlobalUnlock(g);
        }
        let _ = CloseClipboard();
    }
    Saved { items }
}

fn put(items: &[(u32, Vec<u8>)]) -> bool {
    if !open_clipboard() {
        return false;
    }
    let mut ok = true;
    unsafe {
        let _ = EmptyClipboard();
        for (f, bytes) in items {
            let Ok(g) = GlobalAlloc(GMEM_MOVEABLE, bytes.len().max(1)) else {
                ok = false;
                continue;
            };
            let p = GlobalLock(g);
            if p.is_null() {
                ok = false;
                continue;
            }
            std::ptr::copy_nonoverlapping(bytes.as_ptr(), p as *mut u8, bytes.len());
            let _ = GlobalUnlock(g);
            // the clipboard owns the memory once SetClipboardData succeeds
            if SetClipboardData(*f, Some(HANDLE(g.0))).is_err() {
                ok = false;
            }
        }
        let _ = CloseClipboard();
    }
    ok
}

pub fn set_text(text: &str) -> bool {
    let mut w: Vec<u16> = text.encode_utf16().collect();
    w.push(0);
    let bytes: Vec<u8> = w.iter().flat_map(|c| c.to_le_bytes()).collect();
    put(&[(CF_UNICODETEXT, bytes)])
}

pub fn restore(s: &Saved) {
    if s.items.is_empty() {
        // it was empty: leave our text rather than an empty clipboard? The Mac restores exactly, so empty it
        if open_clipboard() {
            unsafe {
                let _ = EmptyClipboard();
                let _ = CloseClipboard();
            }
        }
        return;
    }
    put(&s.items);
}

pub fn sequence() -> u32 {
    unsafe { GetClipboardSequenceNumber() }
}

fn held(vk: windows::Win32::UI::Input::KeyboardAndMouse::VIRTUAL_KEY) -> bool {
    unsafe { (GetAsyncKeyState(vk.0 as i32) as u16 & 0x8000) != 0 }
}

/// Ctrl+V into the window in front. Modifiers the user still holds (Shift, Alt, Win) are let go first — Win+V would
/// open the clipboard history, Alt+V a menu — and pressed again afterwards so the keyboard stays as they hold it.
pub fn paste_keys() -> bool {
    let mut keys: Vec<(u16, bool, bool)> = Vec::new();
    let mods = [
        (VK_LSHIFT, false),
        (VK_RSHIFT, false),
        (VK_LMENU, false),
        (VK_RMENU, true),
        (VK_LWIN, true),
        (VK_RWIN, true),
    ];
    let down: Vec<_> = mods.iter().filter(|(vk, _)| held(*vk)).copied().collect();
    for (vk, ext) in &down {
        keys.push((vk.0, true, *ext));
    }
    keys.extend([
        (VK_CONTROL.0, false, false),
        (VK_V.0, false, false),
        (VK_V.0, true, false),
        (VK_CONTROL.0, true, false),
    ]);
    for (vk, ext) in &down {
        keys.push((vk.0, false, *ext));
    }
    send_keys(&keys)
}

pub fn press_return() -> bool {
    send_keys(&[(VK_RETURN.0, false, false), (VK_RETURN.0, true, false)])
}

/// The focused element through UI Automation: (is a password field, is a text field). None: nothing could be read
/// (an app without UIA support). COM is set up on the calling thread once (multi-threaded).
pub fn focus() -> Option<(bool, bool)> {
    use windows::Win32::System::Com::{
        CoCreateInstance, CoInitializeEx, CLSCTX_INPROC_SERVER, COINIT_MULTITHREADED,
    };
    use windows::Win32::UI::Accessibility::{
        CUIAutomation, IUIAutomation, UIA_DocumentControlTypeId, UIA_EditControlTypeId,
    };
    thread_local!(static COM: () = unsafe { let _ = CoInitializeEx(None, COINIT_MULTITHREADED); });
    COM.with(|_| ());
    unsafe {
        let a: IUIAutomation = CoCreateInstance(&CUIAutomation, None, CLSCTX_INPROC_SERVER).ok()?;
        let e = a.GetFocusedElement().ok()?;
        let password = e.CurrentIsPassword().ok()?.as_bool();
        let t = e.CurrentControlType().ok()?;
        Some((
            password,
            t == UIA_EditControlTypeId || t == UIA_DocumentControlTypeId,
        ))
    }
}
