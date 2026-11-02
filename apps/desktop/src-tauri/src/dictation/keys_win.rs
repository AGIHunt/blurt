//! The dictation key on Windows (TODO.md §Dictation, Windows): a low-level keyboard hook (`WH_KEYBOARD_LL`) on a
//! thread of its own with a message loop, read like the Mac's DictationKeys reads its event tap. The key is right
//! Alt (`VK_RMENU`) used alone. What the hook sees goes to the trigger (trigger.rs) as events stamped with their own
//! time (the hook's `time`, ms since boot), never the time we got round to them.
//!
//! * AltGr layouts send a fake left Ctrl (scan code 0x21D) before right Alt: ignored, so AltGr+key stays a shortcut.
//! * Alt pressed and let go alone opens the menu bar of the app in front. When the key was used alone its release is
//!   swallowed and sent again behind the menu mask key (VK 0xE8, unassigned — AutoHotkey's `#MenuMaskKey`), so the app
//!   sees "Alt + something" and keeps its menu shut.
//! * Our own injected input (the mask, Ctrl+V, Return) is marked with `INJECT_TAG` and never read back.
//! * Every other key is reported, never eaten: the trigger reads Esc, Shift and Ctrl inside a take. Esc alone is
//!   reported and kept from the app in front while a dictation listens (`ESC_DICTATION`) or in a voice note's first
//!   seconds (`ESC_TAKEN`).

use std::sync::mpsc::Sender;
use std::sync::OnceLock;

use windows::Win32::Foundation::{LPARAM, LRESULT, WPARAM};
use windows::Win32::UI::Input::KeyboardAndMouse::{
    SendInput, INPUT, INPUT_0, INPUT_KEYBOARD, KEYBDINPUT, KEYBD_EVENT_FLAGS,
    KEYEVENTF_EXTENDEDKEY, KEYEVENTF_KEYUP, VIRTUAL_KEY, VK_LCONTROL, VK_RMENU,
};
use windows::Win32::UI::WindowsAndMessaging::{
    CallNextHookEx, DispatchMessageW, GetMessageW, SetWindowsHookExW, TranslateMessage,
    KBDLLHOOKSTRUCT, LLKHF_INJECTED, MSG, WH_KEYBOARD_LL, WM_KEYDOWN, WM_KEYUP, WM_SYSKEYDOWN,
    WM_SYSKEYUP,
};

/// dwExtraInfo of every key Blurt sends itself
pub const INJECT_TAG: usize = 0x424C_5254; // "BLRT"
const VK_MASK: u16 = 0xE8;
const ALTGR_FAKE_CTRL_SCAN: u32 = 0x21D;

/// One key down or up as the hook saw it: the sided virtual-key code and the hook's tick (ms since boot). The trigger
/// (trigger.rs) reads every key: it tracks the modifiers itself and turns the tick into seconds (`event_time`).
#[derive(Clone, Copy, Debug)]
pub struct KeyEvent {
    pub code: u32,
    pub down: bool,
    pub tick_ms: u32,
}

struct Hook {
    tx: Sender<KeyEvent>,
}

static HOOK: OnceLock<Hook> = OnceLock::new();
/// the dictation key is down and nothing else was pressed with it (its release is then masked)
static ALONE: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
static RHELD: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
/// Esc is Blurt's (a voice note's first seconds, voice.rs): it is reported but never reaches the app in front
pub static ESC_TAKEN: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
/// Esc is Blurt's while a dictation listens (the Mac's Esc hotkey, held from the start to the stop): it cancels the
/// take and never reaches the app in front. Once the take stops it goes back to the app, as on the Mac — Esc then
/// still cancels the take on its way, with Undo, because it was likely meant for the app.
pub static ESC_DICTATION: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
/// The cancel key's modifier (record.dictation.cancel_key): 0 Esc alone, 1 Ctrl+Esc, 2 Shift+Esc — only that Esc is
/// kept from the app while a dictation listens.
pub static CANCEL_MODS: std::sync::atomic::AtomicU8 = std::sync::atomic::AtomicU8::new(0);

/// The key is down now, as the system says (GetAsyncKeyState; VK_CONTROL 0x11 / VK_SHIFT 0x10 for either side).
pub fn held(vk: i32) -> bool {
    unsafe { (windows::Win32::UI::Input::KeyboardAndMouse::GetAsyncKeyState(vk) as u16 & 0x8000) != 0 }
}

fn cancel_esc_now() -> bool {
    match CANCEL_MODS.load(std::sync::atomic::Ordering::SeqCst) {
        1 => held(0x11),
        2 => held(0x10),
        _ => true,
    }
}
const VK_ESC: u32 = 0x1B;

/// Install the hook on its own thread; events arrive on `tx` until the app ends. Err when Windows refused the hook.
pub fn start(tx: Sender<KeyEvent>) -> Result<(), String> {
    if HOOK.set(Hook { tx }).is_err() {
        return Ok(());
    }
    let (ready_tx, ready_rx) = std::sync::mpsc::channel::<Result<(), String>>();
    std::thread::Builder::new()
        .name("dictation-keys".into())
        .spawn(move || unsafe {
            match SetWindowsHookExW(WH_KEYBOARD_LL, Some(hook_proc), None, 0) {
                Ok(_) => {
                    let _ = ready_tx.send(Ok(()));
                }
                Err(e) => {
                    let _ = ready_tx.send(Err(e.to_string()));
                    return;
                }
            }
            let mut msg = MSG::default();
            while GetMessageW(&mut msg, None, 0, 0).as_bool() {
                let _ = TranslateMessage(&msg);
                DispatchMessageW(&msg);
            }
        })
        .map_err(|e| e.to_string())?;
    ready_rx
        .recv()
        .unwrap_or_else(|_| Err("hook thread ended".into()))
}

unsafe extern "system" fn hook_proc(code: i32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    if code >= 0 {
        let k = &*(lparam.0 as *const KBDLLHOOKSTRUCT);
        let injected = (k.flags.0 & LLKHF_INJECTED.0) != 0;
        if !(injected && k.dwExtraInfo == INJECT_TAG)
            && !(k.vkCode == VK_LCONTROL.0 as u32 && k.scanCode == ALTGR_FAKE_CTRL_SCAN)
        {
            let msg = wparam.0 as u32;
            let down = msg == WM_KEYDOWN || msg == WM_SYSKEYDOWN;
            let up = msg == WM_KEYUP || msg == WM_SYSKEYUP;
            if down || up {
                use std::sync::atomic::Ordering::SeqCst;
                let rmenu = k.vkCode == VK_RMENU.0 as u32;
                if down && rmenu {
                    if !RHELD.swap(true, SeqCst) {
                        ALONE.store(true, SeqCst); // a fresh press (not a key repeat) starts alone
                    }
                } else if down {
                    ALONE.store(false, SeqCst);
                } else if rmenu {
                    RHELD.store(false, SeqCst);
                }
                if let Some(h) = HOOK.get() {
                    let _ = h.tx.send(KeyEvent {
                        code: k.vkCode,
                        down,
                        tick_ms: k.time,
                    });
                }
                if rmenu && up && ALONE.swap(false, SeqCst) {
                    // swallow this release and send mask + release again, so no menu bar opens
                    send_keys(&[
                        (VK_MASK, false, false),
                        (VK_MASK, true, false),
                        (VK_RMENU.0, true, true),
                    ]);
                    return LRESULT(1);
                }
                if k.vkCode == VK_ESC && (ESC_TAKEN.load(SeqCst) || (ESC_DICTATION.load(SeqCst) && cancel_esc_now())) {
                    return LRESULT(1);
                }
            }
        }
    }
    CallNextHookEx(None, code, wparam, lparam)
}

/// Send (vk, key_up, extended) presses, tagged so the hook skips them.
pub fn send_keys(keys: &[(u16, bool, bool)]) -> bool {
    let inputs: Vec<INPUT> = keys
        .iter()
        .map(|&(vk, up, ext)| {
            let mut flags = KEYBD_EVENT_FLAGS(0);
            if up {
                flags |= KEYEVENTF_KEYUP;
            }
            if ext {
                flags |= KEYEVENTF_EXTENDEDKEY;
            }
            INPUT {
                r#type: INPUT_KEYBOARD,
                Anonymous: INPUT_0 {
                    ki: KEYBDINPUT {
                        wVk: VIRTUAL_KEY(vk),
                        wScan: 0,
                        dwFlags: flags,
                        time: 0,
                        dwExtraInfo: INJECT_TAG,
                    },
                },
            }
        })
        .collect();
    let n = unsafe { SendInput(&inputs, std::mem::size_of::<INPUT>() as i32) };
    n as usize == inputs.len()
}

/// The double-tap window: the system's double-click time, 0.3–0.5 s (as on the Mac).
pub fn double_tap_window() -> f64 {
    let ms = unsafe { windows::Win32::UI::Input::KeyboardAndMouse::GetDoubleClickTime() };
    (ms as f64 / 1000.0).clamp(0.3, 0.5)
}

/// Seconds since boot, the hook's clock (for events the app makes itself, e.g. a timer).
pub fn now() -> f64 {
    // GetTickCount, not ...64: the hook's `time` is the same 32-bit clock
    unsafe { windows::Win32::System::SystemInformation::GetTickCount() as f64 / 1000.0 }
}
