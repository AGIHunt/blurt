//! A card dragged out of the island into another app (Windows): our own OLE drag (the Mac's CardDrag), in place of
//! the `drag` crate, which could only drag files.
//!
//!  • a snap's card: the shell's own data object for its file(s) — Explorer, chat apps and editors take it as a
//!    file — and nothing else: a chat app given the picture *and* text pastes the text and drops the picture (the
//!    Mac's chat class gets the picture alone; the note goes on the clipboard after the drop instead).
//!    Over a terminal that takes a text drop (card_drop.rs: Windows Terminal, mintty) the same drag is one line of
//!    text instead, `"<picture path>" <note>` (CF_UNICODETEXT alone, no CF_HDROP), so Claude Code or Codex there get
//!    the picture with its own words. An agent app gets that line too (card_drop::AGENTS and the user's own list,
//!    Settings → General → Cards → Agents…, read once as the drag starts; none with record.agent_drag "same"):
//!    Codex, Cursor, WorkBuddy… open the picture from its path, and several cards keep each picture next to its own
//!    note. A terminal that takes only files (the classic console, Alacritty…) gets the file, as before. Which one is decided when the app asks, not when the drag starts (the data object
//!    is built before anyone knows where it lands): `CardData` wraps the shell's object and answers each
//!    EnumFormatEtc / QueryGetData / GetData for the window under the pointer at that moment — the window OLE itself
//!    hands the drop to (WindowFromPoint), the way the Mac's CardDrag answers for the app under the pointer. A target
//!    asks while the pointer is over it (DragEnter, DragOver, Drop), so each app sees the layout meant for it.
//!  • a voice card: its words as text (CF_UNICODETEXT, one line: the app that reads it may not be where it lands), so
//!    a message box, Notepad or a terminal takes them.
//!  • several cards (a Ctrl/Shift-click selection dragged as one, drag-drop.md §2): one data object with every
//!    picture (the shell's object for all the files); over a terminal one line with every card's path and note (two
//!    spaces between cards), over a desktop agent's composer (card_drop::COMPOSERS) one line per card. All-voice: the
//!    words as text, answered the same way.
//!  • every drag also carries which cards it is (card_drop::CARDS_MIME as the web's custom data, `add_cards`): Blurt's
//!    own main window reads it and files the cards or adds them to an item (Landed::Ours) instead of a bare picture.
//!  • the drag image is the card as the island draws it (a PNG the page renders; a group's count in its corner),
//!    held where the pointer took it.
//!
//! DoDragDrop runs its own modal loop: call this on the main thread. Returns whether another app took the drop
//! (a drop the target refused, or Esc, is not one: the card comes back to its thread), where, and whether Alt was
//! held as it was let go (the cards then stay: a copy drag).
use std::collections::HashMap;
use std::ffi::c_void;
use std::iter::once;
use std::os::windows::ffi::OsStrExt;
use std::path::PathBuf;
use std::sync::Once;

use windows::core::{implement, BOOL, GUID, HRESULT, PCWSTR, PWSTR};
use windows::Win32::Foundation::{
    CloseHandle, COLORREF, DRAGDROP_S_CANCEL, DRAGDROP_S_DROP, DRAGDROP_S_USEDEFAULTCURSORS, DV_E_FORMATETC, E_POINTER, HGLOBAL,
    OLE_E_ADVISENOTSUPPORTED, POINT, SIZE, S_OK,
};
use windows::Win32::Graphics::Gdi::{CreateBitmap, HBITMAP};
use windows::Win32::Graphics::Imaging::{
    CLSID_WICImagingFactory, GUID_WICPixelFormat32bppPBGRA, IWICImagingFactory, WICConvertBitmapSource, WICDecodeMetadataCacheOnDemand,
};
use windows::Win32::System::Com::{
    CoCreateInstance, IAdviseSink, IDataObject, IDataObject_Impl, IEnumFORMATETC, IEnumSTATDATA, CLSCTX_INPROC_SERVER, DATADIR_GET,
    DVASPECT_CONTENT, FORMATETC, STGMEDIUM, STGMEDIUM_0, TYMED_HGLOBAL,
};
use windows::Win32::System::DataExchange::GetClipboardFormatNameW;
use windows::Win32::System::Memory::{GlobalAlloc, GlobalLock, GlobalUnlock, GMEM_MOVEABLE};
use windows::Win32::System::Ole::{
    DoDragDrop, IDropSource, IDropSource_Impl, OleInitialize, CF_UNICODETEXT, DROPEFFECT, DROPEFFECT_COPY, DROPEFFECT_NONE,
};
use windows::Win32::System::SystemServices::{MK_LBUTTON, MODIFIERKEYS_FLAGS};
use windows::Win32::System::Threading::{OpenProcess, QueryFullProcessImageNameW, PROCESS_NAME_WIN32, PROCESS_QUERY_LIMITED_INFORMATION};
use windows::Win32::UI::Shell::{
    BHID_DataObject, CLSID_DragDropHelper, Common::ITEMIDLIST, IDragSourceHelper, ILCreateFromPathW, ILFree, SHCreateDataObject,
    SHCreateShellItemArrayFromIDLists, SHCreateStdEnumFmtEtc, SHDRAGIMAGE,
};
use windows::Win32::UI::WindowsAndMessaging::{GetAncestor, GetClassNameW, GetCursorPos, GetWindowThreadProcessId, WindowFromPoint, GA_ROOT};

use super::card_drop::{self, Target};

/// What a terminal or an agent gets instead of the files: `line` for a shell prompt (several cards on one line, two
/// spaces between them), `lines` for an agent's own composer (card_drop::COMPOSERS: one line per card).
#[derive(Clone)]
pub struct Lines {
    pub line: String,
    pub lines: String,
}

/// What is dragged: files (a snap's picture, its note's .md; several cards' pictures) or text (a voice card's words);
/// either may carry the lines a terminal or an agent gets instead (`terminal`: card_drop::terminal_text).
pub enum Payload {
    Files { files: Vec<PathBuf>, terminal: Option<Lines> },
    Text { text: String, terminal: Option<Lines> },
}

/// Where a taken drag landed, as far as what it got goes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Landed {
    /// a terminal or an agent app: the pictures' paths and the notes as text (card_drop::Target::Terminal / Composer)
    Terminal,
    /// Blurt's own main window: it read which cards they are (card_drop::CARDS_MIME) and files them itself
    Ours,
    /// anything else: the files (or a voice card's words)
    Other,
}

/// A drop another app (or our main window) took: where, and whether Alt was held as it was let go (the cards stay on
/// their thread: the same group can go to a second agent).
#[derive(Clone, Copy, Debug)]
pub struct Dropped {
    pub landed: Landed,
    pub alt: bool,
}

#[implement(IDropSource)]
struct Source {
    /// Alt was down when the drop happened (QueryContinueDrag's key state as it said "drop")
    alt: std::sync::Arc<std::sync::atomic::AtomicBool>,
}

/// MK_ALT in a drag's key state (OLE's own flag; the windows crate names only the mouse-message ones)
const MK_ALT: MODIFIERKEYS_FLAGS = MODIFIERKEYS_FLAGS(0x20);

#[allow(non_snake_case)]
impl IDropSource_Impl for Source_Impl {
    fn QueryContinueDrag(&self, escape: BOOL, keys: MODIFIERKEYS_FLAGS) -> HRESULT {
        if escape.as_bool() {
            DRAGDROP_S_CANCEL
        } else if (keys & MK_LBUTTON) == MODIFIERKEYS_FLAGS(0) {
            self.alt.store((keys & MK_ALT) != MODIFIERKEYS_FLAGS(0), std::sync::atomic::Ordering::SeqCst);
            DRAGDROP_S_DROP
        } else {
            S_OK
        }
    }

    fn GiveFeedback(&self, _effect: DROPEFFECT) -> HRESULT {
        DRAGDROP_S_USEDEFAULTCURSORS
    }
}

fn ole() -> bool {
    static INIT: Once = Once::new();
    static mut OK: bool = false;
    INIT.call_once(|| unsafe { OK = OleInitialize(None).is_ok() });
    unsafe { OK }
}

fn wide(s: &std::ffi::OsStr) -> Vec<u16> {
    s.encode_wide().chain(once(0)).collect()
}

/// The shell's data object for these files (what Explorer itself drags: CF_HDROP, the shell's ID lists, …).
fn files_object(paths: &[PathBuf]) -> windows::core::Result<IDataObject> {
    unsafe {
        let ids: Vec<*mut ITEMIDLIST> = paths.iter().map(|p| ILCreateFromPathW(PCWSTR::from_raw(wide(p.as_os_str()).as_ptr()))).collect();
        if ids.iter().any(|p| p.is_null()) {
            ids.iter().filter(|p| !p.is_null()).for_each(|p| ILFree(Some(*p as *const _)));
            return Err(windows::Win32::Foundation::E_INVALIDARG.into());
        }
        let list: Vec<*const ITEMIDLIST> = ids.iter().map(|p| *p as *const _).collect();
        let r = SHCreateShellItemArrayFromIDLists(&list).and_then(|a| a.BindToHandler(None, &BHID_DataObject));
        ids.iter().for_each(|p| ILFree(Some(*p as *const _)));
        r
    }
}

/// An empty shell data object with `text` set on it as CF_UNICODETEXT.
fn text_object(text: &str) -> windows::core::Result<IDataObject> {
    unsafe {
        let obj: IDataObject = SHCreateDataObject(None, None, None::<&IDataObject>)?;
        // (the data object owns the memory from here: fRelease)
        obj.SetData(&text_format(), &text_medium(text)?, true)?;
        Ok(obj)
    }
}

/// The card as the island draws it, as a drag image: a PNG decoded by WIC into a premultiplied 32-bit bitmap.
fn drag_image(png: &[u8], offset: (i32, i32)) -> Option<SHDRAGIMAGE> {
    unsafe {
        let wic: IWICImagingFactory = CoCreateInstance(&CLSID_WICImagingFactory, None, CLSCTX_INPROC_SERVER).ok()?;
        let stream = wic.CreateStream().ok()?;
        stream.InitializeFromMemory(png).ok()?;
        let decoder = wic.CreateDecoderFromStream(&stream, std::ptr::null::<GUID>(), WICDecodeMetadataCacheOnDemand).ok()?;
        let frame = decoder.GetFrame(0).ok()?;
        let (mut w, mut h) = (0u32, 0u32);
        frame.GetSize(&mut w, &mut h).ok()?;
        let mut px = vec![0u8; (w * h * 4) as usize];
        let src = WICConvertBitmapSource(&GUID_WICPixelFormat32bppPBGRA, &frame).ok()?;
        src.CopyPixels(std::ptr::null(), w * 4, &mut px).ok()?;
        let bmp: HBITMAP = CreateBitmap(w as i32, h as i32, 1, 32, Some(px.as_ptr() as *const c_void));
        if bmp.is_invalid() {
            return None;
        }
        Some(SHDRAGIMAGE {
            sizeDragImage: SIZE { cx: w as i32, cy: h as i32 },
            ptOffset: POINT { x: offset.0.clamp(0, w as i32), y: offset.1.clamp(0, h as i32) },
            hbmpDragImage: bmp,
            crColorKey: COLORREF(0xFFFF_FFFF), // no colour key: the alpha says what is transparent
        })
    }
}

/// Which cards a drag carries, for Blurt's own main window (card_drop::cards_json): as the web's custom data — the
/// format Chromium (WebView2) reads a page's extra DataTransfer types from — and under our own format name for anything
/// native. Set on the data object before the drag; a target that doesn't know them never asks.
fn add_cards(obj: &IDataObject, json: &str) {
    use windows::Win32::System::DataExchange::RegisterClipboardFormatW;
    let put = |name: &str, bytes: &[u8]| unsafe {
        let cf = RegisterClipboardFormatW(PCWSTR::from_raw(wide(std::ffi::OsStr::new(name)).as_ptr()));
        if cf == 0 {
            return;
        }
        let fmt = FORMATETC { cfFormat: cf as u16, ptd: std::ptr::null_mut(), dwAspect: DVASPECT_CONTENT.0, lindex: -1, tymed: TYMED_HGLOBAL.0 as u32 };
        if let Ok(m) = bytes_medium(bytes) {
            let _ = obj.SetData(&fmt, &m, true);
        }
    };
    put("Chromium Web Custom MIME Data Format", &card_drop::web_custom_data(&[(card_drop::CARDS_MIME, json)]));
    put("Blurt Cards", json.as_bytes());
}

/// Drags `payload` out of our window (the main thread). `cards`: which cards it is (card_drop::cards_json), for our
/// own main window. `image`: the card as drawn (PNG), `offset` where the pointer holds it (physical px). Some(where)
/// when another app — or our main window — took it.
pub fn drag(payload: &Payload, cards: Option<&str>, image: Option<&[u8]>, offset: (i32, i32)) -> Option<Dropped> {
    if !ole() {
        return None;
    }
    // the agent apps a card goes into as path + note, once for the whole drag (Settings → General → Cards)
    let agents = card_drop::agents(&card_drop::registry(), crate::settings::read_config().get("record"));
    let wrap = |inner: IDataObject, terminal: &Option<Lines>| -> IDataObject {
        match terminal {
            Some(lines) => CardData { inner, lines: lines.clone(), agents: agents.clone(), exes: Default::default() }.into(),
            None => inner,
        }
    };
    let obj = match payload {
        Payload::Files { files, terminal } if !files.is_empty() => files_object(files).map(|o| wrap(o, terminal)),
        Payload::Text { text, terminal } if !text.trim().is_empty() => text_object(text).map(|o| wrap(o, terminal)),
        _ => return None,
    };
    let Ok(obj) = obj else { return None };
    if let Some(json) = cards {
        add_cards(&obj, json); // (CardData passes SetData on to the shell's object)
    }
    unsafe {
        if let Some(img) = image.and_then(|png| drag_image(png, offset)) {
            if let Ok(helper) = CoCreateInstance::<_, IDragSourceHelper>(&CLSID_DragDropHelper, None, CLSCTX_INPROC_SERVER) {
                let _ = helper.InitializeFromBitmap(&img, &obj);
            }
        }
        let alt_down = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
        let source: IDropSource = Source { alt: alt_down.clone() }.into();
        let mut effect = DROPEFFECT_NONE;
        let t0 = std::time::Instant::now();
        let r = DoDragDrop(&obj, &source, DROPEFFECT_COPY, &mut effect);
        // where it was let go of (the pointer hasn't moved since): the window the drop went to
        let landed = if over_ours() {
            Landed::Ours
        } else {
            match under_pointer(&mut Default::default(), &agents) {
                Target::Terminal | Target::Composer => Landed::Terminal,
                _ => Landed::Other,
            }
        };
        let alt = alt_down.load(std::sync::atomic::Ordering::SeqCst);
        if std::env::var_os("BLURT_DEBUG_KEYS").is_some() {
            eprintln!("blurt: card drag: {r:?} effect {} after {:?} over {landed:?} alt {alt}", effect.0, t0.elapsed());
        }
        (r == DRAGDROP_S_DROP && effect != DROPEFFECT_NONE).then_some(Dropped { landed, alt })
    }
}

/// The window under the pointer is one of ours (the main window: the island is click-through during the drag).
fn over_ours() -> bool {
    unsafe {
        let mut p = POINT::default();
        if GetCursorPos(&mut p).is_err() {
            return false;
        }
        let h = WindowFromPoint(p);
        !h.is_invalid() && ours(h)
    }
}

// ------------------------------------------------------------------ a card's data object: files, or a terminal's line

/// The shell's data object for a card's files (or several cards' words), answering for the window under the pointer
/// when it is asked: over a terminal (or an agent app) it offers the cards as text (CF_UNICODETEXT: `lines.line` at a
/// shell, `lines.lines` in an agent's composer) and hides the rest (CF_HDROP, the shell's ID lists, …) — the drag
/// image's own formats still pass, so the image shows over the terminal too; anywhere else it is the shell's object as
/// it is. SetData (the drag image helper, a target's drop description, the cards' own data) always goes to the
/// shell's object.
#[implement(IDataObject)]
struct CardData {
    inner: IDataObject,
    lines: Lines,
    /// the agent apps in effect for this drag (card_drop::agents)
    agents: card_drop::Agents,
    /// pid → executable, looked up once (GetData is asked many times during a drag)
    exes: std::sync::Mutex<HashMap<u32, Option<String>>>,
}

impl CardData {
    /// The text for the window under the pointer, when it is a terminal or an agent; None: anything else.
    fn text(&self) -> Option<&str> {
        match under_pointer(&mut self.exes.lock().unwrap(), &self.agents) {
            Target::Terminal => Some(&self.lines.line),
            Target::Composer => Some(&self.lines.lines),
            _ => None,
        }
    }
}

/// The window under the pointer — the one OLE hands the drop to — as a drop target kind (`agents`: the agent apps in
/// effect). Ours (the island, the main window) or nothing: Other.
fn under_pointer(exes: &mut HashMap<u32, Option<String>>, agents: &card_drop::Agents) -> Target {
    unsafe {
        let mut p = POINT::default();
        if GetCursorPos(&mut p).is_err() {
            return Target::Other;
        }
        let h = WindowFromPoint(p);
        if h.is_invalid() {
            return Target::Other;
        }
        let root = GetAncestor(h, GA_ROOT);
        let root = if root.is_invalid() { h } else { root };
        let mut pid = 0u32;
        GetWindowThreadProcessId(root, Some(&mut pid));
        if pid == 0 || pid == std::process::id() {
            return Target::Other;
        }
        let mut buf = [0u16; 256];
        let n = GetClassNameW(root, &mut buf);
        let class = (n > 0).then(|| String::from_utf16_lossy(&buf[..n as usize]));
        let exe = exes.entry(pid).or_insert_with(|| exe_name(pid)).clone();
        card_drop::target(exe.as_deref(), class.as_deref(), agents)
    }
}

/// The executable's file name of process `pid` ("WindowsTerminal.exe").
fn exe_name(pid: u32) -> Option<String> {
    unsafe {
        let h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid).ok()?;
        let mut buf = [0u16; 1024];
        let mut n = buf.len() as u32;
        let ok = QueryFullProcessImageNameW(h, PROCESS_NAME_WIN32, PWSTR(buf.as_mut_ptr()), &mut n).is_ok();
        let _ = CloseHandle(h);
        let path = ok.then(|| String::from_utf16_lossy(&buf[..n as usize]))?;
        Some(path.rsplit('\\').next().unwrap_or(&path).to_string())
    }
}

/// The drag image's own formats (and what a target writes back): they pass over a terminal too.
const IMAGE_FORMATS: &[&str] = &[
    "DragImageBits", "DragContext", "DragSourceHelperFlags", "DragWindow", "IsShowingLayered", "IsComputingImage", "IsShowingText",
    "DropDescription", "DisableDragText", "UsingDefaultDragImage", "InShellDragLoop", "Preferred DropEffect", "Performed DropEffect",
    "Logical Performed DropEffect", "Paste Succeeded", "TargetCLSID",
];

fn is_image_format(cf: u16) -> bool {
    if cf < 0xC000 {
        return false;
    }
    let mut buf = [0u16; 128];
    let n = unsafe { GetClipboardFormatNameW(u32::from(cf), &mut buf) };
    n > 0 && IMAGE_FORMATS.contains(&String::from_utf16_lossy(&buf[..n as usize]).as_str())
}

fn text_format() -> FORMATETC {
    FORMATETC { cfFormat: CF_UNICODETEXT.0, ptd: std::ptr::null_mut(), dwAspect: DVASPECT_CONTENT.0, lindex: -1, tymed: TYMED_HGLOBAL.0 as u32 }
}

/// `text` (with its NUL) in a new HGLOBAL, the caller's to free.
fn text_medium(text: &str) -> windows::core::Result<STGMEDIUM> {
    let units: Vec<u16> = text.encode_utf16().chain(once(0)).collect();
    let bytes: Vec<u8> = units.iter().flat_map(|u| u.to_le_bytes()).collect();
    bytes_medium(&bytes)
}

/// `bytes` in a new HGLOBAL of exactly that size (a reader may take GlobalSize as the data's length), the caller's
/// to free.
fn bytes_medium(bytes: &[u8]) -> windows::core::Result<STGMEDIUM> {
    unsafe {
        let h: HGLOBAL = GlobalAlloc(GMEM_MOVEABLE, bytes.len().max(1))?;
        let p = GlobalLock(h);
        std::ptr::copy_nonoverlapping(bytes.as_ptr(), p as *mut u8, bytes.len());
        let _ = GlobalUnlock(h);
        Ok(STGMEDIUM { tymed: TYMED_HGLOBAL.0 as u32, u: STGMEDIUM_0 { hGlobal: h }, pUnkForRelease: std::mem::ManuallyDrop::new(None) })
    }
}

#[allow(non_snake_case)]
impl IDataObject_Impl for CardData_Impl {
    fn GetData(&self, fmt: *const FORMATETC) -> windows::core::Result<STGMEDIUM> {
        let f = unsafe { fmt.as_ref() }.ok_or(windows::core::Error::from(E_POINTER))?;
        let Some(text) = self.text() else { return unsafe { self.inner.GetData(fmt) } };
        if f.cfFormat == CF_UNICODETEXT.0 && f.tymed & TYMED_HGLOBAL.0 as u32 != 0 {
            return text_medium(text);
        }
        if is_image_format(f.cfFormat) {
            return unsafe { self.inner.GetData(fmt) };
        }
        Err(DV_E_FORMATETC.into())
    }

    fn GetDataHere(&self, fmt: *const FORMATETC, medium: *mut STGMEDIUM) -> windows::core::Result<()> {
        if self.text().is_some() {
            return Err(DV_E_FORMATETC.into());
        }
        unsafe { self.inner.GetDataHere(fmt, medium) }
    }

    fn QueryGetData(&self, fmt: *const FORMATETC) -> HRESULT {
        let Some(f) = (unsafe { fmt.as_ref() }) else { return E_POINTER };
        if self.text().is_none() {
            return unsafe { self.inner.QueryGetData(fmt) };
        }
        if f.cfFormat == CF_UNICODETEXT.0 && f.tymed & TYMED_HGLOBAL.0 as u32 != 0 {
            return S_OK;
        }
        if is_image_format(f.cfFormat) {
            return unsafe { self.inner.QueryGetData(fmt) };
        }
        DV_E_FORMATETC
    }

    fn GetCanonicalFormatEtc(&self, fmt: *const FORMATETC, out: *mut FORMATETC) -> HRESULT {
        unsafe { self.inner.GetCanonicalFormatEtc(fmt, out) }
    }

    fn SetData(&self, fmt: *const FORMATETC, medium: *const STGMEDIUM, release: BOOL) -> windows::core::Result<()> {
        unsafe { self.inner.SetData(fmt, medium, release.as_bool()) }
    }

    fn EnumFormatEtc(&self, direction: u32) -> windows::core::Result<IEnumFORMATETC> {
        if direction == DATADIR_GET.0 as u32 && self.text().is_some() {
            return unsafe { SHCreateStdEnumFmtEtc(&[text_format()]) };
        }
        unsafe { self.inner.EnumFormatEtc(direction) }
    }

    fn DAdvise(&self, _: *const FORMATETC, _: u32, _: windows::core::Ref<IAdviseSink>) -> windows::core::Result<u32> {
        Err(OLE_E_ADVISENOTSUPPORTED.into())
    }

    fn DUnadvise(&self, _: u32) -> windows::core::Result<()> {
        Err(OLE_E_ADVISENOTSUPPORTED.into())
    }

    fn EnumDAdvise(&self) -> windows::core::Result<IEnumSTATDATA> {
        Err(OLE_E_ADVISENOTSUPPORTED.into())
    }
}

// ------------------------------------------------------------------ the keyboard, lent to the island and given back

static LENT_BY: std::sync::atomic::AtomicIsize = std::sync::atomic::AtomicIsize::new(0);

/// The island takes the keyboard (the switcher, the Cards panel, Discard's question): remember the window that had it.
pub fn remember_foreground() {
    use windows::Win32::UI::WindowsAndMessaging::GetForegroundWindow;
    let h = unsafe { GetForegroundWindow() };
    if !h.is_invalid() && !ours(h) {
        LENT_BY.store(h.0 as isize, std::sync::atomic::Ordering::SeqCst);
    }
}

/// …and gives it back to that window — only while ours is still in front (a click on a third app took it already):
/// Ctrl+V after "copy and close" pastes where the user was.
pub fn restore_foreground() {
    use windows::Win32::Foundation::HWND;
    use windows::Win32::UI::WindowsAndMessaging::{GetForegroundWindow, IsWindow, SetForegroundWindow};
    let prev = LENT_BY.swap(0, std::sync::atomic::Ordering::SeqCst);
    unsafe {
        let front = GetForegroundWindow();
        let back = HWND(prev as *mut c_void);
        if prev != 0 && (front.is_invalid() || ours(front)) && IsWindow(Some(back)).as_bool() {
            let _ = SetForegroundWindow(back);
        }
    }
}

fn ours(h: windows::Win32::Foundation::HWND) -> bool {
    use windows::Win32::UI::WindowsAndMessaging::GetWindowThreadProcessId;
    let mut pid = 0u32;
    unsafe { GetWindowThreadProcessId(h, Some(&mut pid)) };
    pid == std::process::id()
}
