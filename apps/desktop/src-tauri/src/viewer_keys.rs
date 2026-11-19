//! A viewer window's keyboard capture (docs/design/remote-desktop-viewer.md §Keyboard): while the window is in front and its keys
//! are captured, every key goes to the computer it shows, system shortcuts included.
//!
//!  • Windows: a low-level keyboard hook (`WH_KEYBOARD_LL`) on a thread of its own, installed only while captured and in front.
//!    Each key is turned into the web's `KeyboardEvent.code` (blurt_remote::keys::code_of_scan) and swallowed, so Alt+Tab, the
//!    Windows key and Alt+F4 never act here. Windows keeps Ctrl+Alt+Del and Win+L to itself (no hook sees them). Keys Blurt
//!    itself injects (dictation's paste, the phone host's keys) are left alone, as is AltGr's fake left Ctrl.
//!  • Linux: the window grabs the keyboard through GDK (`gdk_seat_grab`), which on Wayland asks the compositor to stop its own
//!    shortcuts (keyboard-shortcuts-inhibit, GNOME asks the user once) and on X11 is a real grab. Keys still arrive in the
//!    webview as key events. Whether the compositor offers the protocol is read from the Wayland registry: without it, system
//!    shortcuts stay here, and the ⋯ menu says so.
//!  • Elsewhere (a Mac build of this app, for development): nothing more than the webview's own key events.

/// Whether system shortcuts reach the other computer while captured: "all" (Windows' hook, X11's grab, a compositor that
/// offers keyboard-shortcuts-inhibit) or "local" (they stay here; the ⋯ menu says so).
pub fn system_shortcuts() -> &'static str {
    #[cfg(windows)]
    return "all";
    #[cfg(target_os = "linux")]
    return if linux::inhibit_offered() { "all" } else { "local" };
    #[cfg(not(any(windows, target_os = "linux")))]
    "local"
}

#[cfg(windows)]
pub use win::{capture, KeyEvent};

#[cfg(windows)]
mod win {
    use std::sync::atomic::{AtomicBool, AtomicU32, Ordering::SeqCst};
    use std::sync::mpsc::Sender;
    use std::sync::Mutex;

    use windows::Win32::Foundation::{LPARAM, LRESULT, WPARAM};
    use windows::Win32::System::Threading::GetCurrentThreadId;
    use windows::Win32::UI::WindowsAndMessaging::{
        CallNextHookEx, DispatchMessageW, GetMessageW, PostThreadMessageW, SetWindowsHookExW, TranslateMessage, UnhookWindowsHookEx,
        KBDLLHOOKSTRUCT, LLKHF_EXTENDED, LLKHF_INJECTED, MSG, WH_KEYBOARD_LL, WM_KEYDOWN, WM_QUIT, WM_SYSKEYDOWN,
    };

    /// One key, as the web names it.
    pub struct KeyEvent {
        pub code: &'static str,
        pub down: bool,
    }

    static TX: Mutex<Option<Sender<KeyEvent>>> = Mutex::new(None);
    static ON: AtomicBool = AtomicBool::new(false);
    static THREAD: AtomicU32 = AtomicU32::new(0);
    const ALTGR_FAKE_CTRL_SCAN: u32 = 0x21D;

    /// Captures every key into `tx` (Some), or stops (None). Safe to call again either way.
    pub fn capture(tx: Option<Sender<KeyEvent>>) {
        let on = tx.is_some();
        *TX.lock().unwrap() = tx;
        if on == ON.swap(on, SeqCst) {
            return;
        }
        if !on {
            let t = THREAD.swap(0, SeqCst);
            if t != 0 {
                unsafe {
                    let _ = PostThreadMessageW(t, WM_QUIT, WPARAM(0), LPARAM(0));
                }
            }
            return;
        }
        let _ = std::thread::Builder::new().name("viewer-keys".into()).spawn(|| unsafe {
            THREAD.store(GetCurrentThreadId(), SeqCst);
            let h = match SetWindowsHookExW(WH_KEYBOARD_LL, Some(hook), None, 0) {
                Ok(h) => h,
                Err(e) => {
                    // the webview's own key events still carry the keys (no system shortcuts)
                    eprintln!("blurt viewer: keyboard hook not installed: {e}");
                    ON.store(false, SeqCst);
                    return;
                }
            };
            eprintln!("blurt viewer: keyboard hook on");
            let mut msg = MSG::default();
            while GetMessageW(&mut msg, None, 0, 0).as_bool() {
                let _ = TranslateMessage(&msg);
                DispatchMessageW(&msg);
            }
            let _ = UnhookWindowsHookEx(h);
        });
    }

    unsafe extern "system" fn hook(code: i32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
        if code >= 0 && ON.load(SeqCst) {
            let k = &*(lparam.0 as *const KBDLLHOOKSTRUCT);
            // only Blurt's own made-up keys stay here: what a phone or computer controlling this one sends ("BRMT", blurt-remote's
            // REMOTE_TAG) and dictation's typing ("BLRT", keys_win's INJECT_TAG). Other injected keys are the user's: an on-screen
            // keyboard, a remote-desktop tool, a key remapper
            let ours = (k.flags.0 & LLKHF_INJECTED.0) != 0 && matches!(k.dwExtraInfo, 0x4252_4D54 | 0x424C_5254);
            if !ours && k.scanCode != ALTGR_FAKE_CTRL_SCAN {
                let ext = (k.flags.0 & LLKHF_EXTENDED.0) != 0;
                let msg = wparam.0 as u32;
                let down = msg == WM_KEYDOWN || msg == WM_SYSKEYDOWN;
                if let Some(c) = blurt_remote::keys::code_of_scan(k.scanCode, ext, k.vkCode) {
                    if let Some(tx) = TX.lock().unwrap().as_ref() {
                        let _ = tx.send(KeyEvent { code: c, down });
                    }
                    return LRESULT(1); // the other computer's, not this one's
                }
            }
        }
        CallNextHookEx(None, code, wparam, lparam)
    }
}

#[cfg(target_os = "linux")]
pub use linux::grab;

#[cfg(target_os = "linux")]
mod linux {
    use std::sync::OnceLock;

    /// The compositor offers zwp_keyboard_shortcuts_inhibit_manager_v1 (GNOME, KDE, Sway do), or this is X11 (a grab takes
    /// everything). Read once.
    pub fn inhibit_offered() -> bool {
        static OFFERED: OnceLock<bool> = OnceLock::new();
        *OFFERED.get_or_init(|| {
            if std::env::var_os("WAYLAND_DISPLAY").is_none() {
                return std::env::var_os("DISPLAY").is_some();
            }
            registry_has("zwp_keyboard_shortcuts_inhibit_manager_v1")
        })
    }

    fn registry_has(name: &str) -> bool {
        use wayland_client::globals::{registry_queue_init, GlobalListContents};
        use wayland_client::protocol::wl_registry::{self, WlRegistry};
        use wayland_client::{Connection, Dispatch, QueueHandle};
        struct S;
        impl Dispatch<WlRegistry, GlobalListContents> for S {
            fn event(_: &mut S, _: &WlRegistry, _: wl_registry::Event, _: &GlobalListContents, _: &Connection, _: &QueueHandle<S>) {}
        }
        let Ok(conn) = Connection::connect_to_env() else { return false };
        let Ok((globals, _q)) = registry_queue_init::<S>(&conn) else { return false };
        globals.contents().with_list(|l| l.iter().any(|g| g.interface == name))
    }

    /// The window takes the keyboard (on), or gives it back. Main thread.
    pub fn grab(w: &tauri::WebviewWindow, on: bool) {
        use gtk::prelude::*;
        let Ok(win) = w.gtk_window() else { return };
        let Some(gdk_win) = win.window() else { return };
        let display = gdk_win.display();
        let Some(seat) = display.default_seat() else { return };
        if on {
            let _ = seat.grab(&gdk_win, gtk::gdk::SeatCapabilities::KEYBOARD, true, None, None, None);
        } else {
            seat.ungrab();
        }
    }
}
