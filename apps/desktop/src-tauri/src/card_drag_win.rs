//! A card dragged out of the island into another app (Windows): our own OLE drag (the Mac's CardDrag), in place of
//! the `drag` crate, which could only drag files.
//!
//!  • a snap's card: the shell's own data object for its file(s) — Explorer, chat apps and editors take it as a
//!    file — and nothing else: a chat app given the picture *and* text pastes the text and drops the picture (the
//!    Mac's chat class gets the picture alone; the note goes on the clipboard after the drop instead).
//!  • a voice card: its words as text (CF_UNICODETEXT, one line: the app that reads it may not be where it lands), so
//!    a message box, Notepad or a terminal takes them.
//!  • the drag image is the card as the island draws it (a PNG the page renders), held where the pointer took it.
//!
//! DoDragDrop runs its own modal loop: call this on the main thread. Returns whether another app took the drop
//! (a drop the target refused, or Esc, is not one: the card comes back to its thread).
use std::ffi::c_void;
use std::iter::once;
use std::os::windows::ffi::OsStrExt;
use std::path::PathBuf;
use std::sync::Once;

use windows::core::{implement, BOOL, GUID, HRESULT, PCWSTR};
use windows::Win32::Foundation::{COLORREF, DRAGDROP_S_CANCEL, DRAGDROP_S_DROP, DRAGDROP_S_USEDEFAULTCURSORS, HGLOBAL, POINT, SIZE, S_OK};
use windows::Win32::Graphics::Gdi::{CreateBitmap, HBITMAP};
use windows::Win32::Graphics::Imaging::{
    CLSID_WICImagingFactory, GUID_WICPixelFormat32bppPBGRA, IWICImagingFactory, WICConvertBitmapSource, WICDecodeMetadataCacheOnDemand,
};
use windows::Win32::System::Com::{
    CoCreateInstance, IDataObject, CLSCTX_INPROC_SERVER, DVASPECT_CONTENT, FORMATETC, STGMEDIUM, STGMEDIUM_0, TYMED_HGLOBAL,
};
use windows::Win32::System::Memory::{GlobalAlloc, GlobalLock, GlobalUnlock, GMEM_MOVEABLE};
use windows::Win32::System::Ole::{
    DoDragDrop, IDropSource, IDropSource_Impl, OleInitialize, CF_UNICODETEXT, DROPEFFECT, DROPEFFECT_COPY, DROPEFFECT_NONE,
};
use windows::Win32::System::SystemServices::{MK_LBUTTON, MODIFIERKEYS_FLAGS};
use windows::Win32::UI::Shell::{
    BHID_DataObject, CLSID_DragDropHelper, Common::ITEMIDLIST, IDragSourceHelper, ILCreateFromPathW, ILFree, SHCreateDataObject,
    SHCreateShellItemArrayFromIDLists, SHDRAGIMAGE,
};

/// What is dragged: files (a snap's picture, its note's .md) or text (a voice card's words).
pub enum Payload {
    Files(Vec<PathBuf>),
    Text(String),
}

#[implement(IDropSource)]
struct Source;

#[allow(non_snake_case)]
impl IDropSource_Impl for Source_Impl {
    fn QueryContinueDrag(&self, escape: BOOL, keys: MODIFIERKEYS_FLAGS) -> HRESULT {
        if escape.as_bool() {
            DRAGDROP_S_CANCEL
        } else if (keys & MK_LBUTTON) == MODIFIERKEYS_FLAGS(0) {
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
        let units: Vec<u16> = text.encode_utf16().chain(once(0)).collect();
        let bytes = units.len() * 2;
        let h: HGLOBAL = GlobalAlloc(GMEM_MOVEABLE, bytes)?;
        let p = GlobalLock(h);
        std::ptr::copy_nonoverlapping(units.as_ptr() as *const u8, p as *mut u8, bytes);
        let _ = GlobalUnlock(h);
        let fmt = FORMATETC { cfFormat: CF_UNICODETEXT.0, ptd: std::ptr::null_mut(), dwAspect: DVASPECT_CONTENT.0, lindex: -1, tymed: TYMED_HGLOBAL.0 as u32 };
        let medium = STGMEDIUM { tymed: TYMED_HGLOBAL.0 as u32, u: STGMEDIUM_0 { hGlobal: h }, pUnkForRelease: std::mem::ManuallyDrop::new(None) };
        // (the data object owns the memory from here: fRelease)
        obj.SetData(&fmt, &medium, true)?;
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

/// Drags `payload` out of our window (the main thread). `image`: the card as drawn (PNG), `offset` where the pointer
/// holds it (physical px). True when another app took it.
pub fn drag(payload: &Payload, image: Option<&[u8]>, offset: (i32, i32)) -> bool {
    if !ole() {
        return false;
    }
    let obj = match payload {
        Payload::Files(f) if !f.is_empty() => files_object(f),
        Payload::Text(t) if !t.trim().is_empty() => text_object(t),
        _ => return false,
    };
    let Ok(obj) = obj else { return false };
    unsafe {
        if let Some(img) = image.and_then(|png| drag_image(png, offset)) {
            if let Ok(helper) = CoCreateInstance::<_, IDragSourceHelper>(&CLSID_DragDropHelper, None, CLSCTX_INPROC_SERVER) {
                let _ = helper.InitializeFromBitmap(&img, &obj);
            }
        }
        let source: IDropSource = Source.into();
        let mut effect = DROPEFFECT_NONE;
        let t0 = std::time::Instant::now();
        let r = DoDragDrop(&obj, &source, DROPEFFECT_COPY, &mut effect);
        if std::env::var_os("BLURT_DEBUG_KEYS").is_some() {
            eprintln!("blurt: card drag: {r:?} effect {} after {:?}", effect.0, t0.elapsed());
        }
        r == DRAGDROP_S_DROP && effect != DROPEFFECT_NONE
    }
}

/// One line of a voice card's words for a text drop (the Mac's CardTransfer.dragText): control characters out, never
/// a Return — the app that reads it may not be where it lands.
pub fn drag_text(words: &str) -> String {
    words.split(|c: char| c.is_control()).map(str::trim).filter(|s| !s.is_empty()).collect::<Vec<_>>().join(" ")
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
