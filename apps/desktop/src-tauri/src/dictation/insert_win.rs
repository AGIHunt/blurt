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
    let path = exe_path(pid)?;
    Some(path.rsplit('\\').next().unwrap_or(&path).to_string())
}

/// The process's executable, its full path.
fn exe_path(pid: u32) -> Option<String> {
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
        Some(String::from_utf16_lossy(&buf[..n as usize]))
    }
}

/// The app's name as Windows shows it (Task Manager, the taskbar): its executable's FileDescription, in the user's
/// language where the exe has one (system apps are MUI-localised: notepad.exe is 记事本 on a Chinese Windows) — never
/// the exe's stem when there is a name. Cached per executable. None: no version information to read.
pub fn app_name(f: &Front) -> Option<String> {
    use std::collections::HashMap;
    use std::sync::Mutex;
    static NAMES: Mutex<Option<HashMap<String, Option<String>>>> = Mutex::new(None);
    let key = f.exe.to_lowercase();
    if let Some(n) = NAMES.lock().unwrap().as_ref().and_then(|m| m.get(&key)) {
        return n.clone();
    }
    let name = exe_path(f.pid).and_then(|p| file_description(&p));
    NAMES.lock().unwrap().get_or_insert_with(HashMap::new).insert(key, name.clone());
    name
}

/// The front app's executable, its full path (the history keeps it: the Dictation page shows the app's icon).
pub fn exe_full_path(f: &Front) -> Option<String> {
    exe_path(f.pid)
}

/// An app's icon (32 px, as Explorer shows the file) as PNG bytes. `exe`: a full path, or a file name ("notepad.exe")
/// whose path Windows' folders, App Paths or a running process of that name gives. Cached per executable.
pub fn icon_png(exe: &str) -> Option<Vec<u8>> {
    use std::collections::HashMap;
    use std::sync::Mutex;
    static ICONS: Mutex<Option<HashMap<String, Option<Vec<u8>>>>> = Mutex::new(None);
    let key = exe.to_lowercase();
    if let Some(v) = ICONS.lock().unwrap().as_ref().and_then(|m| m.get(&key)) {
        return v.clone();
    }
    let png = if exe.contains('\\') || exe.contains('/') {
        unsafe { file_icon_png(exe) }
    } else {
        // Windows' own folders and App Paths first, then any running process of that name (the first one that gives an
        // icon: a process can be one we may not read)
        let want = if key.ends_with(".exe") { key.clone() } else { format!("{key}.exe") };
        installed_path(&want)
            .into_iter()
            .chain(running_paths().into_iter().filter(|p| p.rsplit('\\').next().is_some_and(|n| n.to_lowercase() == want)))
            .find_map(|p| unsafe { file_icon_png(&p) })
    };
    if png.is_some() {
        ICONS.lock().unwrap().get_or_insert_with(HashMap::new).insert(key, png.clone());
    }
    png
}

/// Where an executable that isn't running lives: Windows' own folders, then its App Paths entry (how Run finds it).
fn installed_path(exe: &str) -> Option<String> {
    use windows::Win32::System::Registry::{RegGetValueW, HKEY_CURRENT_USER, HKEY_LOCAL_MACHINE, RRF_RT_REG_SZ};
    let root = std::env::var("SystemRoot").unwrap_or_else(|_| "C:\\Windows".into());
    for dir in [root.clone(), format!("{root}\\System32")] {
        let p = format!("{dir}\\{exe}");
        if std::path::Path::new(&p).is_file() {
            return Some(p);
        }
    }
    let sub: Vec<u16> = format!("SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\App Paths\\{exe}").encode_utf16().chain(std::iter::once(0)).collect();
    for hive in [HKEY_CURRENT_USER, HKEY_LOCAL_MACHINE] {
        let mut buf = vec![0u16; 1024];
        let mut n = (buf.len() * 2) as u32;
        let r = unsafe {
            RegGetValueW(hive, windows::core::PCWSTR(sub.as_ptr()), windows::core::PCWSTR::null(), RRF_RT_REG_SZ, None,
                         Some(buf.as_mut_ptr() as *mut _), Some(&mut n))
        };
        if r.is_ok() {
            let p = String::from_utf16_lossy(&buf[..(n as usize / 2).saturating_sub(1)]).trim_matches('"').to_string();
            if std::path::Path::new(&p).is_file() {
                return Some(p);
            }
        }
    }
    None
}

/// The executables' full paths of the processes running in this session.
fn running_paths() -> Vec<String> {
    use windows::Win32::System::ProcessStatus::EnumProcesses;
    let mut pids = vec![0u32; 4096];
    let mut got = 0u32;
    if unsafe { EnumProcesses(pids.as_mut_ptr(), (pids.len() * 4) as u32, &mut got) }.is_err() {
        return vec![];
    }
    pids.truncate(got as usize / 4);
    pids.into_iter().filter(|&p| p > 4).filter_map(exe_path).collect()
}

/// The file's shell icon, drawn into 32-bit RGBA: its alpha where it has one, else its mask.
unsafe fn file_icon_png(path: &str) -> Option<Vec<u8>> {
    use windows::Win32::Graphics::Gdi::{
        CreateCompatibleDC, DeleteDC, DeleteObject, GetDIBits, GetObjectW, BITMAP, BITMAPINFO, BITMAPINFOHEADER, BI_RGB,
        DIB_RGB_COLORS, HGDIOBJ,
    };
    use windows::Win32::Storage::FileSystem::FILE_FLAGS_AND_ATTRIBUTES;
    use windows::Win32::UI::Shell::{SHGetFileInfoW, SHFILEINFOW, SHGFI_ICON, SHGFI_LARGEICON};
    use windows::Win32::UI::WindowsAndMessaging::{DestroyIcon, GetIconInfo, ICONINFO};
    // SHGetFileInfo wants COM on its thread, and is asked one at a time (the page asks for every row's icon at once;
    // some came back empty when they raced)
    static ONE: std::sync::Mutex<()> = std::sync::Mutex::new(());
    let _one = ONE.lock().unwrap_or_else(|e| e.into_inner());
    let _ = windows::Win32::System::Com::CoInitializeEx(None, windows::Win32::System::Com::COINIT_APARTMENTTHREADED);
    let w: Vec<u16> = path.encode_utf16().chain(std::iter::once(0)).collect();
    let mut info = SHFILEINFOW::default();
    let r = SHGetFileInfoW(windows::core::PCWSTR(w.as_ptr()), FILE_FLAGS_AND_ATTRIBUTES(0), Some(&mut info),
                           std::mem::size_of::<SHFILEINFOW>() as u32, SHGFI_ICON | SHGFI_LARGEICON);
    if r == 0 || info.hIcon.is_invalid() {
        return None;
    }
    let mut ii = ICONINFO::default();
    let ok = GetIconInfo(info.hIcon, &mut ii).is_ok();
    let _ = DestroyIcon(info.hIcon);
    if !ok {
        return None;
    }
    let read = |bmp: windows::Win32::Graphics::Gdi::HBITMAP| -> Option<(u32, u32, Vec<u8>)> {
        if bmp.is_invalid() {
            return None;
        }
        let mut b = BITMAP::default();
        if GetObjectW(HGDIOBJ(bmp.0), std::mem::size_of::<BITMAP>() as i32, Some(&mut b as *mut _ as *mut _)) == 0 {
            return None;
        }
        let (wd, ht) = (b.bmWidth.max(0) as u32, b.bmHeight.max(0) as u32);
        let mut bi = BITMAPINFO::default();
        bi.bmiHeader = BITMAPINFOHEADER {
            biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
            biWidth: wd as i32,
            biHeight: -(ht as i32), // top-down
            biPlanes: 1,
            biBitCount: 32,
            biCompression: BI_RGB.0,
            ..Default::default()
        };
        let mut px = vec![0u8; (wd * ht * 4) as usize];
        let dc = CreateCompatibleDC(None);
        let n = GetDIBits(dc, bmp, 0, ht, Some(px.as_mut_ptr() as *mut _), &mut bi, DIB_RGB_COLORS);
        let _ = DeleteDC(dc);
        (n > 0).then_some((wd, ht, px))
    };
    let color = read(ii.hbmColor);
    let mask = read(ii.hbmMask);
    let _ = DeleteObject(HGDIOBJ(ii.hbmColor.0));
    let _ = DeleteObject(HGDIOBJ(ii.hbmMask.0));
    let (wd, ht, mut px) = color?;
    // BGRA → RGBA; no alpha at all (an old icon): the mask says what is transparent
    let has_alpha = px.chunks(4).any(|c| c[3] != 0);
    for (i, c) in px.chunks_mut(4).enumerate() {
        c.swap(0, 2);
        if !has_alpha {
            let transparent = mask.as_ref().is_some_and(|(mw, _, m)| *mw == wd && m.get(i * 4).is_some_and(|v| *v != 0));
            c[3] = if transparent { 0 } else { 255 };
        }
    }
    let mut out = Vec::new();
    {
        let mut e = png::Encoder::new(&mut out, wd, ht);
        e.set_color(png::ColorType::Rgba);
        e.set_depth(png::BitDepth::Eight);
        let mut wr = e.write_header().ok()?;
        wr.write_image_data(&px).ok()?;
    }
    Some(out)
}

/// An executable's FileDescription (its localised version resource when there is one).
fn file_description(path: &str) -> Option<String> {
    use windows::Win32::Storage::FileSystem::{
        GetFileVersionInfoExW, GetFileVersionInfoSizeExW, VerQueryValueW, FILE_VER_GET_LOCALISED,
    };
    let w: Vec<u16> = path.encode_utf16().chain(std::iter::once(0)).collect();
    unsafe {
        let mut h = 0u32;
        let size = GetFileVersionInfoSizeExW(FILE_VER_GET_LOCALISED, windows::core::PCWSTR(w.as_ptr()), &mut h);
        if size == 0 {
            return None;
        }
        let mut buf = vec![0u8; size as usize];
        GetFileVersionInfoExW(FILE_VER_GET_LOCALISED, windows::core::PCWSTR(w.as_ptr()), None, size, buf.as_mut_ptr() as _).ok()?;
        let query = |sub: &str| -> Option<(*mut core::ffi::c_void, u32)> {
            let q: Vec<u16> = sub.encode_utf16().chain(std::iter::once(0)).collect();
            let mut p: *mut core::ffi::c_void = std::ptr::null_mut();
            let mut n = 0u32;
            VerQueryValueW(buf.as_ptr() as _, windows::core::PCWSTR(q.as_ptr()), &mut p, &mut n)
                .as_bool()
                .then_some((p, n))
                .filter(|(p, n)| !p.is_null() && *n > 0)
        };
        // the language / code page pairs it has (the localised one first), then the usual English / Unicode one
        let mut pairs: Vec<(u16, u16)> = vec![];
        if let Some((p, n)) = query("\\VarFileInfo\\Translation") {
            let t = std::slice::from_raw_parts(p as *const u16, (n as usize / 2) & !1);
            pairs.extend(t.chunks(2).map(|c| (c[0], c[1])));
        }
        pairs.extend([(0x0409, 0x04B0), (0x0409, 0x04E4)]);
        for (lang, cp) in pairs {
            if let Some((p, n)) = query(&format!("\\StringFileInfo\\{lang:04x}{cp:04x}\\FileDescription")) {
                let s = String::from_utf16_lossy(std::slice::from_raw_parts(p as *const u16, n as usize));
                let s = s.trim_end_matches('\0').trim().to_string();
                if !s.is_empty() {
                    return Some(s);
                }
            }
        }
        None
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
    let f = focus_read(false)?;
    Some((f.password, f.editable == Some(true)))
}

/// A text field's contents as UI Automation reads it: the text (at most `FIELD_MAX` UTF-16 units from its start) and
/// the selection in UTF-16 units (`cursor_known` false: a field with a value but no selection to read — the cursor is
/// taken to be at its end).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Field {
    pub text: String,
    pub sel_start: usize,
    pub sel_len: usize,
    pub cursor_known: bool,
}

/// What the focused element is.
#[derive(Clone, Debug, Default)]
pub struct FocusRead {
    pub pid: u32,
    /// a password field (UIA IsPassword): nothing of it is read
    pub password: bool,
    /// a text field (Some(true)), clearly not one — a list, a button, the desktop's icons (Some(false)) — or not known
    /// (None: a pane or a custom control, WeChat's input box, a web page's document)
    pub editable: Option<bool>,
    pub field: Option<Field>,
}

/// The longest field read whole (the paste's landing compares it before and after): longer documents count as
/// unreadable there and fall back to the timers.
const FIELD_MAX: i32 = 20_000;

thread_local! {
    static UIA: std::cell::RefCell<Option<windows::Win32::UI::Accessibility::IUIAutomation>> = const { std::cell::RefCell::new(None) };
}

fn automation() -> Option<windows::Win32::UI::Accessibility::IUIAutomation> {
    use windows::core::Interface;
    use windows::Win32::System::Com::{CoCreateInstance, CoInitializeEx, CLSCTX_INPROC_SERVER, COINIT_MULTITHREADED};
    use windows::Win32::UI::Accessibility::{CUIAutomation, IUIAutomation, IUIAutomation2};
    UIA.with(|c| {
        if let Some(a) = c.borrow().as_ref() {
            return Some(a.clone());
        }
        unsafe {
            let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
            let a: IUIAutomation = CoCreateInstance(&CUIAutomation, None, CLSCTX_INPROC_SERVER).ok()?;
            // a hung app must not hold the take: UIA's own timeouts are seconds
            if let Ok(a2) = a.cast::<IUIAutomation2>() {
                let _ = a2.SetConnectionTimeout(500);
                let _ = a2.SetTransactionTimeout(500);
            }
            *c.borrow_mut() = Some(a.clone());
            Some(a)
        }
    })
}

/// The focused element: what it is and, with `read_text`, its text and selection (never a password field's).
pub fn focus_read(read_text: bool) -> Option<FocusRead> {
    use windows::Win32::UI::Accessibility::*;
    let a = automation()?;
    unsafe {
        let e = a.GetFocusedElement().ok()?;
        let pid = e.CurrentProcessId().ok().unwrap_or(0) as u32;
        let password = e.CurrentIsPassword().map(|b| b.as_bool()).unwrap_or(false);
        let t = e.CurrentControlType().ok()?;
        let value: Option<IUIAutomationValuePattern> = e.GetCurrentPatternAs(UIA_ValuePatternId).ok();
        let writable = value.as_ref().and_then(|v| v.CurrentIsReadOnly().ok()).map(|r| !r.as_bool());
        let text_pattern: Option<IUIAutomationTextPattern> = e.GetCurrentPatternAs(UIA_TextPatternId).ok();
        let not_text = [
            UIA_ListControlTypeId, UIA_ListItemControlTypeId, UIA_ButtonControlTypeId, UIA_TreeControlTypeId,
            UIA_TreeItemControlTypeId, UIA_HyperlinkControlTypeId, UIA_MenuItemControlTypeId, UIA_MenuControlTypeId,
            UIA_MenuBarControlTypeId, UIA_DataItemControlTypeId, UIA_DataGridControlTypeId, UIA_ImageControlTypeId,
            UIA_CheckBoxControlTypeId, UIA_RadioButtonControlTypeId, UIA_TabControlTypeId, UIA_TabItemControlTypeId,
            UIA_TableControlTypeId, UIA_ToolBarControlTypeId, UIA_SliderControlTypeId, UIA_ScrollBarControlTypeId,
            UIA_HeaderControlTypeId, UIA_HeaderItemControlTypeId, UIA_SplitButtonControlTypeId, UIA_CalendarControlTypeId,
        ];
        // the file list's own panes (Explorer's, the desktop's): their empty area has the focus with no item selected
        let shell_pane = (t == UIA_PaneControlTypeId || t == UIA_GroupControlTypeId)
            && e.CurrentClassName().map(|c| SHELL_PANES.contains(&c.to_string().as_str())).unwrap_or(false);
        // the control's type first: Explorer's files and the desktop's icons are list items with a writable value (to
        // rename them), and were taken for a text field — the take showed ✓ and its words were lost (dogfood 11-02)
        let editable = if password {
            Some(true)
        } else if t == UIA_EditControlTypeId {
            Some(writable != Some(false))
        } else if not_text.contains(&t) || shell_pane {
            Some(false)
        } else if writable == Some(true) {
            Some(true) // a document, a combo box … with a value that can be written
        } else {
            None
        };
        let mut out = FocusRead { pid, password, editable, field: None };
        if read_text && !password && editable != Some(false) {
            out.field = text_pattern
                .as_ref()
                .and_then(|tp| read_text_pattern(tp))
                .or_else(|| {
                    let v = value.as_ref()?.CurrentValue().ok()?.to_string();
                    let n = v.encode_utf16().count();
                    (n as i32 <= FIELD_MAX).then_some(Field { text: v, sel_start: n, sel_len: 0, cursor_known: false })
                });
            // no cursor through UI Automation: a classic Win32 Edit (Notepad) answers its own messages
            if out.field.as_ref().is_none_or(|f| !f.cursor_known) {
                if let Some(fd) = edit_focus(pid).and_then(edit_read) {
                    out.field = Some(fd);
                    out.editable = Some(true);
                }
            }
        }
        if std::env::var_os("BLURT_DEBUG_FOCUS").is_some() {
            let class = e.CurrentClassName().map(|c| c.to_string()).unwrap_or_default();
            eprintln!(
                "dictation: focus type {} class {class:?} writable {writable:?} text_pattern {} → editable {:?} cursor {:?}",
                t.0,
                text_pattern.is_some(),
                out.editable,
                out.field.as_ref().map(|f| (f.cursor_known, f.sel_start, f.sel_len, f.text.encode_utf16().count()))
            );
        }
        Some(out)
    }
}

/// The shell's own file-list panes (Explorer's folder view, the desktop): never a text field.
const SHELL_PANES: [&str; 3] = ["SHELLDLL_DefView", "SysListView32", "UIItemsView"];

/// The window with the keyboard focus when it is a classic Win32 Edit control of process `pid` (Notepad's page, a
/// dialog's box): UI Automation's proxy gives it no selection to read, its own messages do.
fn edit_focus(pid: u32) -> Option<HWND> {
    use windows::Win32::UI::WindowsAndMessaging::{GetClassNameW, GetGUIThreadInfo, GUITHREADINFO};
    unsafe {
        let fg = GetForegroundWindow();
        if fg.0.is_null() {
            return None;
        }
        let mut p = 0u32;
        let tid = GetWindowThreadProcessId(fg, Some(&mut p));
        if pid != 0 && p != pid {
            return None;
        }
        let mut gi = GUITHREADINFO { cbSize: std::mem::size_of::<GUITHREADINFO>() as u32, ..Default::default() };
        GetGUIThreadInfo(tid, &mut gi).ok()?;
        let h = gi.hwndFocus;
        if h.0.is_null() {
            return None;
        }
        let mut buf = [0u16; 64];
        let n = GetClassNameW(h, &mut buf);
        let class = String::from_utf16_lossy(&buf[..n.max(0) as usize]);
        class.eq_ignore_ascii_case("Edit").then_some(h)
    }
}

/// A message to another process's window that gives up after 300 ms on a hung app. None: no answer.
fn send_msg(h: HWND, msg: u32, w: usize, l: isize) -> Option<usize> {
    use windows::Win32::Foundation::{LPARAM, WPARAM};
    use windows::Win32::UI::WindowsAndMessaging::{SendMessageTimeoutW, SMTO_ABORTIFHUNG};
    let mut r = 0usize;
    let ok = unsafe { SendMessageTimeoutW(h, msg, WPARAM(w), LPARAM(l), SMTO_ABORTIFHUNG, 300, Some(&mut r)) };
    (ok.0 != 0).then_some(r)
}

const WM_GETTEXT: u32 = 0x000D;
const WM_GETTEXTLENGTH: u32 = 0x000E;
const EM_GETSEL: u32 = 0x00B0;
const EM_SETSEL: u32 = 0x00B1;

/// An Edit control's text (its lines joined by \r\n, as its offsets count them) and selection.
fn edit_read(h: HWND) -> Option<Field> {
    let len = send_msg(h, WM_GETTEXTLENGTH, 0, 0)?;
    if len as i32 > FIELD_MAX {
        return None;
    }
    let mut buf = vec![0u16; len + 1];
    let got = send_msg(h, WM_GETTEXT, len + 1, buf.as_mut_ptr() as isize)?;
    let text = String::from_utf16_lossy(&buf[..got.min(len)]);
    // without pointers EM_GETSEL answers the selection in its result: start in the low word, end in the high one
    let sel = send_msg(h, EM_GETSEL, 0, 0)?;
    let (start, end) = (sel & 0xFFFF, (sel >> 16) & 0xFFFF);
    let n = text.encode_utf16().count();
    (start <= end && end <= n).then_some(Field { text, sel_start: start, sel_len: end - start, cursor_known: true })
}

/// A TextPattern's text and selection: the text before the selection's start is its offset.
unsafe fn read_text_pattern(tp: &windows::Win32::UI::Accessibility::IUIAutomationTextPattern) -> Option<Field> {
    use windows::Win32::UI::Accessibility::*;
    let doc = tp.DocumentRange().ok()?;
    let text = doc.GetText(FIELD_MAX + 1).ok()?.to_string();
    let n = text.encode_utf16().count();
    if n as i32 > FIELD_MAX {
        return None;
    }
    let sels = tp.GetSelection().ok()?;
    if sels.Length().ok()? < 1 {
        return Some(Field { text, sel_start: n, sel_len: 0, cursor_known: false });
    }
    let sel = sels.GetElement(0).ok()?;
    let pre = doc.Clone().ok()?;
    pre.MoveEndpointByRange(TextPatternRangeEndpoint_End, &sel, TextPatternRangeEndpoint_Start).ok()?;
    let start = pre.GetText(FIELD_MAX + 1).ok()?.to_string().encode_utf16().count();
    let len = sel.GetText(FIELD_MAX + 1).ok()?.to_string().encode_utf16().count();
    Some(Field { text, sel_start: start.min(n), sel_len: len, cursor_known: true })
}

/// Select `len` UTF-16 units from `start` in the focused field (reformat-last replaces the last take there): through its
/// TextPattern, counted in characters, then checked — the selection must read exactly `expect` (a surrogate pair or a
/// field that counts otherwise would select the wrong text: then nothing is selected and the caller copies instead).
pub fn select_range(start: usize, len: usize, expect: &str) -> bool {
    use windows::Win32::UI::Accessibility::*;
    let Some(a) = automation() else { return false };
    unsafe {
        let run = || -> Option<bool> {
            let e = a.GetFocusedElement().ok()?;
            if e.CurrentIsPassword().ok()?.as_bool() {
                return Some(false);
            }
            let tp: IUIAutomationTextPattern = e.GetCurrentPatternAs(UIA_TextPatternId).ok()?;
            let doc = tp.DocumentRange().ok()?;
            let r = doc.Clone().ok()?;
            // collapse to the start, then out to start + len and in from start
            r.MoveEndpointByRange(TextPatternRangeEndpoint_End, &doc, TextPatternRangeEndpoint_Start).ok()?;
            r.MoveEndpointByUnit(TextPatternRangeEndpoint_End, TextUnit_Character, (start + len) as i32).ok()?;
            r.MoveEndpointByUnit(TextPatternRangeEndpoint_Start, TextUnit_Character, start as i32).ok()?;
            if r.GetText(FIELD_MAX).ok()?.to_string() != expect {
                return Some(false);
            }
            r.Select().ok()?;
            Some(true)
        };
        if run().unwrap_or(false) {
            return true;
        }
    }
    // a classic Edit control: EM_SETSEL, once its text there reads exactly `expect`
    let pid = front().map_or(0, |f| f.pid);
    let Some(h) = edit_focus(pid) else { return false };
    let Some(f) = edit_read(h) else { return false };
    let units: Vec<u16> = f.text.encode_utf16().collect();
    if start + len > units.len() || String::from_utf16_lossy(&units[start..start + len]) != expect {
        return false;
    }
    send_msg(h, EM_SETSEL, start, (start + len) as isize).is_some()
}

/// The focused field's text now (the paste's landing check): None when it can't be read.
pub fn field_text() -> Option<String> {
    focus_read(true)?.field.map(|f| f.text)
}

/// The window's title (the field context's `title`).
pub fn window_title(hwnd: isize) -> String {
    use windows::Win32::UI::WindowsAndMessaging::GetWindowTextW;
    let mut buf = [0u16; 512];
    let n = unsafe { GetWindowTextW(HWND(hwnd as *mut _), &mut buf) };
    String::from_utf16_lossy(&buf[..n.max(0) as usize])
}

/// The executables running in this session that we may query (other users' and protected ones are skipped).
pub fn running_exes() -> Vec<String> {
    use windows::Win32::System::ProcessStatus::EnumProcesses;
    let mut pids = vec![0u32; 4096];
    let mut got = 0u32;
    let ok = unsafe { EnumProcesses(pids.as_mut_ptr(), (pids.len() * 4) as u32, &mut got) }.is_ok();
    if !ok {
        return vec![];
    }
    pids.truncate(got as usize / 4);
    pids.into_iter().filter(|&p| p > 4).filter_map(exe_name).collect()
}
