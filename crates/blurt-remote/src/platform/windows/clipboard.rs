//! The clipboard for a paste that keeps it: what it held is saved (every format readable as bytes), the text goes on, Ctrl+V,
//! and the old contents come back once the app has read it. The same as the desktop app's dictation insert
//! (apps/desktop/src-tauri/src/dictation/insert_win.rs), which this crate can't depend on: kept in step by hand.

use std::time::Duration;

use ::windows::Win32::Foundation::{HANDLE, HGLOBAL, HWND};
use ::windows::Win32::System::DataExchange::{
    CloseClipboard, EmptyClipboard, EnumClipboardFormats, GetClipboardData, GetClipboardSequenceNumber, OpenClipboard,
    SetClipboardData,
};
use ::windows::Win32::System::Memory::{GlobalAlloc, GlobalLock, GlobalSize, GlobalUnlock, GMEM_MOVEABLE};

const CF_UNICODETEXT: u32 = 13;
// formats that are handles (bitmaps, metafiles, palettes) or rendered by their owner: not bytes we can keep
const NOT_BYTES: [u32; 8] = [2, 3, 9, 14, 0x80, 0x82, 0x83, 0x8E];

pub struct Saved {
    items: Vec<(u32, Vec<u8>)>,
}

fn open() -> bool {
    // another app may hold it for a moment
    for _ in 0..10 {
        if unsafe { OpenClipboard(Some(HWND::default())) }.is_ok() {
            return true;
        }
        std::thread::sleep(Duration::from_millis(15));
    }
    false
}

pub fn save() -> Saved {
    let mut items = Vec::new();
    if !open() {
        return Saved { items };
    }
    unsafe {
        let mut f = 0u32;
        loop {
            f = EnumClipboardFormats(f);
            if f == 0 {
                break;
            }
            if NOT_BYTES.contains(&f) {
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
    if !open() {
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
    let bytes: Vec<u8> = text.encode_utf16().chain(std::iter::once(0)).flat_map(|c| c.to_le_bytes()).collect();
    put(&[(CF_UNICODETEXT, bytes)])
}

pub fn restore(s: &Saved) {
    if s.items.is_empty() {
        if open() {
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
