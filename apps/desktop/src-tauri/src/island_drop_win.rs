//! Drops from other apps on the island, Windows (docs/design/drag-drop.md §3; the Mac's DropCatcher + watchDrags).
//!
//! The island is a transparent WebView2 window as big as the work area, click-through except over what it draws. It
//! must never be a drop target itself: under its transparent parts a browser's tab strip or an upload area must still
//! get their drops (WebView2's own external drops are off for it: lib.rs browser_ui_off). So drops come in through a
//! window of their own, the catcher: small (the notch + 40 px; the open drawer + 24 px), topmost, never activated, not
//! on the taskbar, nearly transparent (alpha 1/255: still hit-tested, which OLE's WindowFromPoint needs), shown only
//! while another app's drag is near the notch, gone at mouse-up (after a 0.5 s grace: OLE hands the drop over from the
//! source's own loop, after the button is up).
//!
//! Seeing another app's drag: Windows tells no bystander that a drag has begun, and a global mouse hook is what we
//! don't want (it runs inside every input event of the session, and security tools flag it). So a ~30 Hz timer looks
//! at what anyone may read: the primary button held (GetAsyncKeyState; swapped buttons respected), the pointer moved
//! past the system's drag distance since the press, the press not on a Blurt window (WindowFromPoint's process) and no
//! Blurt card drag under way (island::dragging_cards), the pointer near the notch. That only says "maybe": the catcher
//! shows, and OLE itself confirms it by entering the catcher (DragEnter, with the data object). A held button that is
//! no OLE drag — a browser tab dragged along its strip, a window moved, text selected — never enters it: once the
//! pointer has moved over the catcher for 200 ms without that, it goes for the rest of that press (drop_in::Watch).
//!
//! The catcher's IDropTarget reads what the island takes: CF_HDROP's paths (Explorer, most apps), a browser's virtual
//! files (FileGroupDescriptorW + FileContents: Edge / Chrome's dragged picture), picture data ("PNG", CF_DIBV5,
//! CF_DIB), text and links (UniformResourceLocatorW, CF_UNICODETEXT). It always answers DROPEFFECT_COPY — never move:
//! a text editor as the source would cut what was dragged. Blurt's own drags ("Blurt Cards") are refused.
//! The window, its timer and the drop target all live on one STA thread with its own message loop; the cards are made
//! on a worker thread (copies out of temporary places, thumbnails).
use std::cell::RefCell;
use std::ffi::c_void;
use std::os::windows::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::time::Instant;

use serde_json::json;
use tauri::AppHandle;
use windows::core::{implement, w, Interface, Ref, PCWSTR};
use windows::Win32::Foundation::{COLORREF, HGLOBAL, HINSTANCE, HWND, LPARAM, LRESULT, POINT, POINTL, RECT, SIZE, WPARAM};
use windows::Win32::Graphics::Gdi::{
    CreateCompatibleDC, CreateDIBSection, CreateFontW, CreateSolidBrush, DeleteDC, DeleteObject, DrawTextW, FillRect, GdiFlush, GetDIBits,
    GetObjectW, SelectObject, SetBkMode, SetTextColor, ANTIALIASED_QUALITY, BITMAP, BITMAPINFO, BITMAPINFOHEADER, BI_RGB, CLIP_DEFAULT_PRECIS,
    DEFAULT_CHARSET, DIB_RGB_COLORS, DT_CENTER, DT_NOPREFIX, DT_PATH_ELLIPSIS, DT_SINGLELINE, DT_VCENTER, HBITMAP, HGDIOBJ,
    OUT_DEFAULT_PRECIS, TRANSPARENT,
};
use windows::Win32::Graphics::Imaging::{
    CLSID_WICImagingFactory, GUID_WICPixelFormat32bppRGBA, IWICBitmapSource, IWICImagingFactory, WICBitmapInterpolationModeFant,
    WICConvertBitmapSource, WICDecodeMetadataCacheOnLoad,
};
use windows::Win32::System::Com::{
    CoCreateInstance, CoInitializeEx, CoUninitialize, IDataObject, CLSCTX_INPROC_SERVER, COINIT_APARTMENTTHREADED, DVASPECT_CONTENT, FORMATETC,
    TYMED_HGLOBAL, TYMED_ISTREAM,
};
use windows::Win32::System::DataExchange::{GetClipboardSequenceNumber, RegisterClipboardFormatW};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::System::Memory::{GlobalLock, GlobalSize, GlobalUnlock};
use windows::Win32::System::Ole::{
    IDropTarget, IDropTarget_Impl, OleGetClipboard, OleInitialize, OleUninitialize, RegisterDragDrop, ReleaseStgMedium, CF_DIB, CF_DIBV5, CF_HDROP, CF_UNICODETEXT, DROPEFFECT,
    DROPEFFECT_COPY, DROPEFFECT_NONE,
};
use windows::Win32::System::SystemServices::MODIFIERKEYS_FLAGS;
use windows::Win32::UI::Input::KeyboardAndMouse::{GetAsyncKeyState, VK_LBUTTON, VK_RBUTTON};
use windows::Win32::UI::Shell::{
    DragQueryFileW, IDropTargetHelper, IShellItemImageFactory, SHCreateItemFromParsingName, CLSID_DragDropHelper, HDROP, SIIGBF_RESIZETOFIT,
};
use windows::Win32::UI::WindowsAndMessaging::{
    CreateWindowExW, DefWindowProcW, DispatchMessageW, GetAncestor, GetCursorPos, GetMessageW, GetSystemMetrics, GetWindowThreadProcessId,
    RegisterClassExW, SetLayeredWindowAttributes, SetTimer, SetWindowPos, ShowWindow, TranslateMessage, WindowFromPoint, GA_ROOT, HWND_TOPMOST,
    LWA_ALPHA, MA_NOACTIVATE, MSG, SM_CXDRAG, SM_CYDRAG, SM_SWAPBUTTON, SWP_NOACTIVATE, SWP_SHOWWINDOW, SW_HIDE, WM_MOUSEACTIVATE, WM_TIMER,
    WNDCLASSEXW, WS_EX_LAYERED, WS_EX_NOACTIVATE, WS_EX_TOOLWINDOW, WS_EX_TOPMOST, WS_POPUP,
};

use super::drop_in::{self, DropIn, Landing, Watch, REPORT};

/// The longest file a browser's virtual file may be read into memory at the drop (a picture, a PDF; not a film).
const VIRTUAL_MAX: usize = 512 << 20;

/// Everything the catcher thread keeps (its window procedure and the drop target run on it, one at a time).
struct Ctx {
    app: AppHandle,
    hwnd: HWND,
    watch: Watch,
    t0: Instant,
    /// the drag over the catcher carries what the island takes (DragEnter's answer)
    takes: bool,
    /// the pointer last sent to the page (CSS px), so a still pointer isn't sent again
    sent: Option<(i64, i64)>,
    helper: Option<IDropTargetHelper>,
}

thread_local! {
    static CTX: RefCell<Option<Ctx>> = const { RefCell::new(None) };
}

fn with<R>(f: impl FnOnce(&mut Ctx) -> R) -> Option<R> {
    CTX.with(|c| c.try_borrow_mut().ok().and_then(|mut c| c.as_mut().map(f)))
}

/// Starts the catcher's thread (once the island is up). Nothing shows until another app drags something near the
/// notch.
pub fn start(app: &AppHandle) {
    let app = app.clone();
    let _ = std::thread::Builder::new().name("blurt-island-drop".into()).spawn(move || unsafe { run(app) });
}

unsafe fn run(app: AppHandle) {
    unsafe {
        // OLE's drop targets need an STA thread that pumps messages: this one
        if OleInitialize(None).is_err() {
            return eprintln!("blurt: island drops unavailable (OleInitialize)");
        }
        let hinst = GetModuleHandleW(None).map(|h| HINSTANCE(h.0)).unwrap_or_default();
        let class = w!("BlurtIslandDropCatcher");
        let wc = WNDCLASSEXW {
            cbSize: std::mem::size_of::<WNDCLASSEXW>() as u32,
            lpfnWndProc: Some(wndproc),
            hInstance: hinst,
            lpszClassName: class,
            ..Default::default()
        };
        RegisterClassExW(&wc);
        let Ok(hwnd) = CreateWindowExW(
            WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_LAYERED,
            class,
            w!(""),
            WS_POPUP,
            0,
            0,
            1,
            1,
            None,
            None,
            Some(hinst),
            None,
        ) else {
            return eprintln!("blurt: island drops unavailable (no window)");
        };
        // 1/255: invisible, but still a window the pointer is over (alpha 0 or WS_EX_TRANSPARENT would let OLE pass it)
        let _ = SetLayeredWindowAttributes(hwnd, COLORREF(0), 1, LWA_ALPHA);
        let target: IDropTarget = Catcher.into();
        if let Err(e) = RegisterDragDrop(hwnd, &target) {
            return eprintln!("blurt: island drops unavailable: {e}");
        }
        let helper = CoCreateInstance::<_, IDropTargetHelper>(&CLSID_DragDropHelper, None, CLSCTX_INPROC_SERVER).ok();
        CTX.with(|c| {
            *c.borrow_mut() = Some(Ctx { app, hwnd, watch: Watch::default(), t0: Instant::now(), takes: false, sent: None, helper });
        });
        SetTimer(Some(hwnd), 1, 33, None);
        let mut msg = MSG::default();
        while GetMessageW(&mut msg, None, 0, 0).as_bool() {
            let _ = TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
    }
}

unsafe extern "system" fn wndproc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    match msg {
        WM_TIMER => {
            with(tick);
            LRESULT(0)
        }
        // a click on it (there shouldn't be one) never takes the keyboard from the app in front
        WM_MOUSEACTIVATE => LRESULT(MA_NOACTIVATE as isize),
        _ => unsafe { DefWindowProcW(hwnd, msg, wp, lp) },
    }
}

/// The primary button is down now (the left one, unless the buttons are swapped).
fn primary_down() -> bool {
    unsafe {
        let vk = if GetSystemMetrics(SM_SWAPBUTTON) != 0 { VK_RBUTTON } else { VK_LBUTTON };
        GetAsyncKeyState(vk.0 as i32) < 0
    }
}

/// The window under `pt` belongs to Blurt (the island over a card, the main window, a note).
fn ours_at(pt: (i32, i32)) -> bool {
    unsafe {
        let h = WindowFromPoint(POINT { x: pt.0, y: pt.1 });
        if h.is_invalid() {
            return false;
        }
        let root = GetAncestor(h, GA_ROOT);
        let mut pid = 0u32;
        GetWindowThreadProcessId(if root.is_invalid() { h } else { root }, Some(&mut pid));
        pid == std::process::id()
    }
}

fn tick(c: &mut Ctx) {
    let now = c.t0.elapsed().as_secs_f64();
    let mut p = POINT::default();
    unsafe {
        let _ = GetCursorPos(&mut p);
    }
    let pt = (p.x, p.y);
    let rep = REPORT.lock().unwrap().clone();
    let alive = super::island(&c.app).is_some();
    let ours_now = super::dragging_cards().is_some();
    let slop = unsafe { GetSystemMetrics(SM_CXDRAG).max(GetSystemMetrics(SM_CYDRAG)).max(2) };
    let s = drop_in::Sense {
        now,
        down: primary_down() && alive,
        pt,
        notch: rep.notch,
        drawer: rep.drawer,
        slop,
        scale: rep.scale,
    };
    let dos = if ours_now { c.watch.end() } else { c.watch.tick(&s, || ours_at(pt)) };
    apply(c, &dos);
}

fn apply(c: &mut Ctx, dos: &[drop_in::Do]) {
    use drop_in::Do;
    for d in dos {
        match *d {
            Do::Show(z) => unsafe {
                let _ = SetWindowPos(c.hwnd, Some(HWND_TOPMOST), z.l, z.t, z.r - z.l, z.b - z.t, SWP_NOACTIVATE | SWP_SHOWWINDOW);
            },
            Do::Hide => unsafe {
                let _ = ShowWindow(c.hwnd, SW_HIDE);
            },
            Do::Open => super::send(&c.app, json!({"op": "ext", "phase": "open"})),
            Do::Close | Do::End => {
                REPORT.lock().unwrap().row = None;
                c.sent = None;
                c.takes = false;
                let phase = if *d == Do::End { "end" } else { "close" };
                super::send(&c.app, json!({"op": "ext", "phase": phase}));
            }
        }
    }
}

// ------------------------------------------------------------------ the drop target

#[implement(IDropTarget)]
struct Catcher;

fn now(c: &Ctx) -> f64 {
    c.t0.elapsed().as_secs_f64()
}

#[allow(non_snake_case)]
impl IDropTarget_Impl for Catcher_Impl {
    fn DragEnter(&self, obj: Ref<IDataObject>, _keys: MODIFIERKEYS_FLAGS, pt: &POINTL, effect: *mut DROPEFFECT) -> windows::core::Result<()> {
        let read = obj.ok().ok().map(|o| read(o, false));
        with(|c| {
            let (d, ours) = read.clone().unwrap_or_default();
            c.takes = !ours && !d.is_empty();
            crate::draglog::log(json!({"event": "drop_watch", "via": "catcher", "phase": "enter", "takes": c.takes, "ours": ours, "what": d.summary()}));
            let t = now(c);
            c.watch.entered(t, c.takes);
            REPORT.lock().unwrap().row = None;
            if c.takes {
                // the island grows a little (here it can go) and says what is coming once the drawer opens
                super::send(&c.app, json!({"op": "ext", "phase": "enter", "what": d.summary()}));
            }
            let e = if c.takes { DROPEFFECT_COPY } else { DROPEFFECT_NONE };
            unsafe {
                *effect = e;
                if let (Some(h), Ok(o)) = (&c.helper, obj.ok()) {
                    let _ = h.DragEnter(c.hwnd, o, &POINT { x: pt.x, y: pt.y }, e);
                }
            }
        });
        Ok(())
    }

    fn DragOver(&self, _keys: MODIFIERKEYS_FLAGS, pt: &POINTL, effect: *mut DROPEFFECT) -> windows::core::Result<()> {
        with(|c| {
            let mut e = if c.takes { DROPEFFECT_COPY } else { DROPEFFECT_NONE };
            if c.takes && c.watch.is_open() {
                // the page highlights the row under the pointer and says which (`ext.row`): More… takes nothing
                let rep = REPORT.lock().unwrap().clone();
                let (x, y) = rep.to_css((pt.x, pt.y));
                let at = (x.round() as i64, y.round() as i64);
                if c.sent != Some(at) {
                    c.sent = Some(at);
                    super::send(&c.app, json!({"op": "ext", "phase": "over", "x": x, "y": y}));
                }
                if drop_in::landing(rep.row.as_deref()) == Landing::Refuse {
                    e = DROPEFFECT_NONE;
                }
            }
            unsafe {
                *effect = e;
                if let Some(h) = &c.helper {
                    let _ = h.DragOver(&POINT { x: pt.x, y: pt.y }, e);
                }
            }
        });
        Ok(())
    }

    fn DragLeave(&self) -> windows::core::Result<()> {
        with(|c| {
            let t = now(c);
            c.watch.left(t);
            if let Some(h) = &c.helper {
                unsafe {
                    let _ = h.DragLeave();
                }
            }
        });
        Ok(())
    }

    fn Drop(&self, obj: Ref<IDataObject>, _keys: MODIFIERKEYS_FLAGS, pt: &POINTL, effect: *mut DROPEFFECT) -> windows::core::Result<()> {
        // where it lands: the drawer's row last under the pointer (the page said it), else the notch itself = hang
        let landing = with(|c| {
            if let (Some(h), Ok(o)) = (&c.helper, obj.ok()) {
                unsafe {
                    let _ = h.Drop(o, &POINT { x: pt.x, y: pt.y }, DROPEFFECT_COPY);
                }
            }
            let row = if c.watch.is_open() { REPORT.lock().unwrap().row.clone() } else { None };
            let l = if c.takes { drop_in::landing(row.as_deref()) } else { Landing::Refuse };
            let dos = c.watch.end();
            apply(c, &dos);
            (l, c.app.clone())
        });
        crate::draglog::log(json!({"event": "drop_external", "via": "catcher", "landing": format!("{:?}", landing.as_ref().map(|l| &l.0))}));
        let Some((landing, app)) = landing else {
            unsafe { *effect = DROPEFFECT_NONE };
            return Ok(());
        };
        let project = match landing {
            Landing::Refuse => {
                unsafe { *effect = DROPEFFECT_NONE };
                return Ok(());
            }
            Landing::Hang => None,
            Landing::Project(p) => Some(p),
        };
        // the data object is only valid during this call: everything is read now, the cards are made off this thread
        let Some((d, false)) = obj.ok().ok().map(|o| read(o, true)) else {
            unsafe { *effect = DROPEFFECT_NONE };
            return Ok(());
        };
        if d.is_empty() {
            unsafe { *effect = DROPEFFECT_NONE };
            return Ok(());
        }
        unsafe { *effect = DROPEFFECT_COPY };
        std::thread::spawn(move || unsafe {
            // the shell's thumbnails and WIC: COM on this thread
            let com = CoInitializeEx(None, COINIT_APARTMENTTHREADED).is_ok();
            let faces = drop_in::Faces { decode: &decode, face: &face, temporary: &drop_in::is_temporary };
            drop_in::hang(&app, &d, project, &faces);
            if com {
                CoUninitialize();
            }
        });
        Ok(())
    }
}

// ------------------------------------------------------------------ the clipboard (the main window's Ctrl+V)

/// What the clipboard holds, read the way a drop is (OLE gives the clipboard as the same kind of data object): the
/// files Explorer copied (CF_HDROP), a picture ("PNG", CF_DIBV5, CF_DIB → PNG), the text; whether it is a document's
/// copy (Word, Excel, WordPad: "Rich Text Format", which also carries a picture of itself) and whether it is Blurt's own
/// last picture (the clipboard's sequence number hasn't moved since: drop_in::mark_ours). On a thread of its own with
/// OLE initialised (the caller's may have none). A browser's or Outlook's virtual files aren't taken here.
pub fn clipboard() -> drop_in::ClipRead {
    std::thread::spawn(|| unsafe {
        let ole = OleInitialize(None).is_ok();
        let out = OleGetClipboard().ok().map(|obj| {
            let (d, cards) = read(&obj, true);
            let text = bytes(&obj, CF_UNICODETEXT.0, -1, 8 << 20).map(|b| utf16_text(&b));
            let rich = has(&obj, registered("Rich Text Format"));
            let ours = cards || drop_in::is_ours(*drop_in::OURS.lock().unwrap(), GetClipboardSequenceNumber(), None);
            let mut paths = d.images;
            paths.extend(d.files);
            drop_in::ClipRead { paths, png: d.image_data.into_iter().next(), text, rich, ours }
        });
        if ole {
            OleUninitialize();
        }
        out.unwrap_or_default()
    })
    .join()
    .unwrap_or_default()
}

// ------------------------------------------------------------------ reading a drag's data object

fn wide(s: &std::ffi::OsStr) -> Vec<u16> {
    s.encode_wide().chain(std::iter::once(0)).collect()
}

/// A registered clipboard format's id (0: none).
fn registered(name: &str) -> u16 {
    unsafe { RegisterClipboardFormatW(PCWSTR::from_raw(wide(std::ffi::OsStr::new(name)).as_ptr())) as u16 }
}

fn fmt(cf: u16, lindex: i32) -> FORMATETC {
    FORMATETC {
        cfFormat: cf,
        ptd: std::ptr::null_mut(),
        dwAspect: DVASPECT_CONTENT.0,
        lindex,
        tymed: (TYMED_HGLOBAL.0 | TYMED_ISTREAM.0) as u32,
    }
}

fn has(obj: &IDataObject, cf: u16) -> bool {
    cf != 0 && unsafe { obj.QueryGetData(&fmt(cf, -1)).is_ok() }
}

/// A format's bytes (from global memory or a stream), at most `max`.
fn bytes(obj: &IDataObject, cf: u16, lindex: i32, max: usize) -> Option<Vec<u8>> {
    if cf == 0 {
        return None;
    }
    unsafe {
        let mut m = obj.GetData(&fmt(cf, lindex)).ok()?;
        let out = if m.tymed == TYMED_HGLOBAL.0 as u32 {
            global_bytes(m.u.hGlobal, max)
        } else if m.tymed == TYMED_ISTREAM.0 as u32 {
            (*m.u.pstm).as_ref().and_then(|s| {
                let mut out = Vec::new();
                let mut buf = vec![0u8; 1 << 16];
                loop {
                    let mut n = 0u32;
                    if s.Read(buf.as_mut_ptr() as *mut c_void, buf.len() as u32, Some(&mut n)).is_err() || n == 0 {
                        break;
                    }
                    out.extend_from_slice(&buf[..n as usize]);
                    if out.len() > max {
                        return None;
                    }
                }
                Some(out)
            })
        } else {
            None
        };
        ReleaseStgMedium(&mut m);
        out
    }
}

unsafe fn global_bytes(h: HGLOBAL, max: usize) -> Option<Vec<u8>> {
    unsafe {
        let n = GlobalSize(h);
        if n == 0 || n > max {
            return None;
        }
        let p = GlobalLock(h);
        if p.is_null() {
            return None;
        }
        let v = std::slice::from_raw_parts(p as *const u8, n).to_vec();
        let _ = GlobalUnlock(h);
        Some(v)
    }
}

/// CF_HDROP's paths, in the drag's order.
fn hdrop_paths(obj: &IDataObject) -> Vec<PathBuf> {
    unsafe {
        let mut f = fmt(CF_HDROP.0, -1);
        f.tymed = TYMED_HGLOBAL.0 as u32;
        let Ok(mut m) = obj.GetData(&f) else { return vec![] };
        let drop = HDROP(m.u.hGlobal.0);
        let n = DragQueryFileW(drop, u32::MAX, None);
        let mut out = Vec::new();
        for i in 0..n.min(512) {
            let len = DragQueryFileW(drop, i, None) as usize;
            let mut buf = vec![0u16; len + 1];
            let got = DragQueryFileW(drop, i, Some(&mut buf)) as usize;
            out.push(PathBuf::from(String::from_utf16_lossy(&buf[..got.min(len)])));
        }
        ReleaseStgMedium(&mut m);
        out
    }
}

fn utf16_text(b: &[u8]) -> String {
    let units: Vec<u16> = b.chunks_exact(2).map(|c| u16::from_le_bytes([c[0], c[1]])).take_while(|u| *u != 0).collect();
    String::from_utf16_lossy(&units)
}

/// What the drag carries; `full`: at the drop, the data itself (virtual files' bytes, pictures as PNG) — else only
/// what is cheap to know (paths, names, that a picture is there) for the drawer. Also whether it is Blurt's own.
fn read(obj: &IDataObject, full: bool) -> (DropIn, bool) {
    let ours = has(obj, registered("Blurt Cards"));
    if ours {
        return (DropIn::default(), true);
    }
    let paths = hdrop_paths(obj);
    let mut d = if !paths.is_empty() {
        drop_in::sort_paths(&paths, |p| p.is_dir(), |p| std::fs::read_to_string(p).ok())
    } else {
        DropIn::default()
    };
    if paths.is_empty() {
        let (group, contents) = (registered("FileGroupDescriptorW"), registered("FileContents"));
        let names = if has(obj, group) { bytes(obj, group, -1, 1 << 20).map(|b| drop_in::file_group_names(&b)).unwrap_or_default() } else { vec![] };
        if !names.is_empty() {
            if full {
                // each file's bytes by its index; one that can't be read is left out (with its name)
                for (i, name) in names.iter().enumerate() {
                    if let Some(b) = bytes(obj, contents, i as i32, VIRTUAL_MAX).filter(|b| !b.is_empty()) {
                        d.virtual_names.push(name.clone());
                        d.virtual_data.push(b);
                    }
                }
            } else {
                d.virtual_names = names;
            }
        } else {
            let png_cf = registered("PNG");
            let pictures = [png_cf, CF_DIBV5.0, CF_DIB.0];
            if pictures.iter().any(|cf| has(obj, *cf)) {
                if full {
                    let png = bytes(obj, png_cf, -1, 256 << 20).filter(|b| b.get(1..4) == Some(b"PNG")).or_else(|| {
                        [CF_DIBV5.0, CF_DIB.0]
                            .iter()
                            .find_map(|cf| bytes(obj, *cf, -1, 512 << 20).and_then(|b| drop_in::dib_rgba(&b)).and_then(|(w, h, px)| drop_in::png(w, h, &px)))
                    });
                    d.image_data.extend(png);
                } else {
                    d.data_pictures = 1;
                }
            }
        }
    }
    // text or a link only when nothing else came (a browser's picture drag also carries its page's address)
    if d.is_empty() && d.folders == 0 {
        let url = registered("UniformResourceLocatorW");
        d.text = [url, CF_UNICODETEXT.0]
            .iter()
            .find_map(|cf| bytes(obj, *cf, -1, 8 << 20).map(|b| utf16_text(&b)).and_then(|t| drop_in::clean_text(&t)));
    }
    (d, false)
}

// ------------------------------------------------------------------ pictures and file faces (worker thread, COM)

/// A picture a card can't keep as it is (gif, webp, bmp, heic, tiff) as a PNG, its long side at most 6000 px: WIC
/// (Windows' own codecs; HEIC only with its extension installed). None: it becomes a file card.
fn decode(p: &Path) -> Option<Vec<u8>> {
    const MAX: u32 = 6000;
    unsafe {
        let wic: IWICImagingFactory = CoCreateInstance(&CLSID_WICImagingFactory, None, CLSCTX_INPROC_SERVER).ok()?;
        let name = wide(p.as_os_str());
        let dec = wic
            .CreateDecoderFromFilename(PCWSTR::from_raw(name.as_ptr()), None, windows::Win32::Foundation::GENERIC_READ, WICDecodeMetadataCacheOnLoad)
            .ok()?;
        let frame = dec.GetFrame(0).ok()?;
        let (mut w, mut h) = (0u32, 0u32);
        frame.GetSize(&mut w, &mut h).ok()?;
        let mut src: IWICBitmapSource = frame.cast().ok()?;
        if w.max(h) > MAX {
            let k = MAX as f64 / w.max(h) as f64;
            let (sw, sh) = (((w as f64 * k).round() as u32).max(1), ((h as f64 * k).round() as u32).max(1));
            let scaler = wic.CreateBitmapScaler().ok()?;
            scaler.Initialize(&src, sw, sh, WICBitmapInterpolationModeFant).ok()?;
            (w, h) = (sw, sh);
            src = scaler.cast().ok()?;
        }
        let rgba = WICConvertBitmapSource(&GUID_WICPixelFormat32bppRGBA, &src).ok()?;
        let mut px = vec![0u8; (w * h * 4) as usize];
        rgba.CopyPixels(std::ptr::null(), w * 4, &mut px).ok()?;
        drop_in::png(w, h, &px)
    }
}

/// A file card's face: the shell's thumbnail of it (a PDF's first page, a video's frame) — or, when it has none, its
/// icon: IShellItemImageFactory gives whichever it has — with the file's name on the band.
fn face(p: &Path) -> Option<Vec<u8>> {
    let thumb = thumbnail(p);
    let name = p.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    let band = name_band(&name);
    let px = drop_in::compose_face(thumb.as_ref().map(|(w, h, px)| (*w, *h, px.as_slice())), band.as_deref());
    drop_in::png(drop_in::FACE.0, drop_in::FACE.1, &px)
}

/// The shell's picture of `p`, fitted in the face's box: BGRA, top-down.
fn thumbnail(p: &Path) -> Option<(u32, u32, Vec<u8>)> {
    unsafe {
        let name = wide(p.as_os_str());
        let item: IShellItemImageFactory = SHCreateItemFromParsingName(PCWSTR::from_raw(name.as_ptr()), None).ok()?;
        let size = SIZE { cx: drop_in::THUMB.0 as i32, cy: drop_in::THUMB.1 as i32 };
        let bmp = item.GetImage(size, SIIGBF_RESIZETOFIT).ok()?;
        let out = bitmap_bgra(bmp);
        let _ = DeleteObject(HGDIOBJ(bmp.0));
        out
    }
}

unsafe fn bitmap_bgra(bmp: HBITMAP) -> Option<(u32, u32, Vec<u8>)> {
    unsafe {
        let mut bm = BITMAP::default();
        if GetObjectW(HGDIOBJ(bmp.0), std::mem::size_of::<BITMAP>() as i32, Some(&mut bm as *mut _ as *mut c_void)) == 0 {
            return None;
        }
        let (w, h) = (bm.bmWidth.max(0) as u32, bm.bmHeight.unsigned_abs());
        if w == 0 || h == 0 {
            return None;
        }
        let mut info = BITMAPINFO { bmiHeader: header(w, h), ..Default::default() };
        let mut px = vec![0u8; (w * h * 4) as usize];
        let dc = CreateCompatibleDC(None);
        let got = GetDIBits(dc, bmp, 0, h, Some(px.as_mut_ptr() as *mut c_void), &mut info, DIB_RGB_COLORS);
        let _ = DeleteDC(dc);
        (got == h as i32).then_some((w, h, px))
    }
}

/// A 32-bit top-down BI_RGB header.
fn header(w: u32, h: u32) -> BITMAPINFOHEADER {
    BITMAPINFOHEADER {
        biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
        biWidth: w as i32,
        biHeight: -(h as i32),
        biPlanes: 1,
        biBitCount: 32,
        biCompression: BI_RGB.0,
        ..Default::default()
    }
}

/// The band with the file's name (white, Segoe UI 21 px semibold on dark, cut in the middle when too long — the end of
/// the name and its extension stay), as GDI draws it: BGRA, top-down, FACE.0 × BAND.
fn name_band(name: &str) -> Option<Vec<u8>> {
    let (w, h) = (drop_in::FACE.0, drop_in::BAND);
    unsafe {
        let dc = CreateCompatibleDC(None);
        let info = BITMAPINFO { bmiHeader: header(w, h), ..Default::default() };
        let mut bits: *mut c_void = std::ptr::null_mut();
        let Ok(bmp) = CreateDIBSection(Some(dc), &info, DIB_RGB_COLORS, &mut bits, None, 0) else {
            let _ = DeleteDC(dc);
            return None;
        };
        let old = SelectObject(dc, HGDIOBJ(bmp.0));
        let [r, g, b, _] = drop_in::BAND_RGB;
        let brush = CreateSolidBrush(COLORREF(r as u32 | (g as u32) << 8 | (b as u32) << 16));
        FillRect(dc, &RECT { left: 0, top: 0, right: w as i32, bottom: h as i32 }, brush);
        let _ = DeleteObject(HGDIOBJ(brush.0));
        let font = CreateFontW(-21, 0, 0, 0, 600, 0, 0, 0, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, ANTIALIASED_QUALITY, 0, w!("Segoe UI"));
        let old_font = SelectObject(dc, HGDIOBJ(font.0));
        SetTextColor(dc, COLORREF(0x00FF_FFFF));
        SetBkMode(dc, TRANSPARENT);
        let mut text: Vec<u16> = name.encode_utf16().collect();
        let mut rc = RECT { left: 12, top: 0, right: w as i32 - 12, bottom: h as i32 };
        DrawTextW(dc, &mut text, &mut rc, DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_PATH_ELLIPSIS | DT_NOPREFIX);
        let _ = GdiFlush();
        let out = (!bits.is_null()).then(|| std::slice::from_raw_parts(bits as *const u8, (w * h * 4) as usize).to_vec());
        SelectObject(dc, old_font);
        SelectObject(dc, old);
        let _ = DeleteObject(HGDIOBJ(font.0));
        let _ = DeleteObject(HGDIOBJ(bmp.0));
        let _ = DeleteDC(dc);
        out
    }
}
