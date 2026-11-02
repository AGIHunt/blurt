//! Windows: an overlay that takes the keys (the picker, the note bubble, the island's Cards panel and switcher) really
//! gets them. The Mac makes these windows key (makeKeyAndOrderFront); on Windows a plain SetForegroundWindow from a
//! worker thread a moment after the hotkey is refused under the foreground lock while another app is in front — Esc,
//! a typed note or Enter then land in the app behind. So: check, and while it isn't ours, join the foreground
//! thread's input (AttachThreadInput) and bring it forward from there; retried for ~360 ms.
//! Registered with blurt_capture::overlay::set_focus_hook (capture.rs overlay_config).

use std::time::Duration;

use windows::Win32::Foundation::HWND;
use windows::Win32::System::Threading::{AttachThreadInput, GetCurrentThreadId};
use windows::Win32::UI::Input::KeyboardAndMouse::SetFocus;
use windows::Win32::UI::WindowsAndMessaging::{BringWindowToTop, GetForegroundWindow, GetWindowThreadProcessId, IsWindow, IsWindowVisible, SetForegroundWindow};

pub fn force(h: isize) {
    let hwnd = HWND(h as *mut core::ffi::c_void);
    for i in 0..12 {
        // SAFETY: plain Win32 calls on a window handle; a destroyed window is checked first (IsWindow)
        unsafe {
            if !IsWindow(Some(hwnd)).as_bool() || !IsWindowVisible(hwnd).as_bool() {
                return;
            }
            let fg = GetForegroundWindow();
            if fg == hwnd {
                if i > 0 && std::env::var("BLURT_DEBUG_KEYS").is_ok() {
                    eprintln!("blurt: focus: forced after {i} tries");
                }
                return;
            }
            let me = GetCurrentThreadId();
            let fg_thread = if fg.0.is_null() { 0 } else { GetWindowThreadProcessId(fg, None) };
            let win_thread = GetWindowThreadProcessId(hwnd, None);
            let joined_fg = fg_thread != 0 && fg_thread != me && AttachThreadInput(me, fg_thread, true).as_bool();
            let joined_win = win_thread != me && AttachThreadInput(me, win_thread, true).as_bool();
            let _ = BringWindowToTop(hwnd);
            let _ = SetForegroundWindow(hwnd);
            let _ = SetFocus(Some(hwnd));
            if joined_win {
                let _ = AttachThreadInput(me, win_thread, false);
            }
            if joined_fg {
                let _ = AttachThreadInput(me, fg_thread, false);
            }
        }
        std::thread::sleep(Duration::from_millis(30));
    }
    eprintln!("blurt: focus: the overlay couldn't take the keyboard");
}
