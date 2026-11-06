//! The dictation key on Linux (docs/design/linux-port.md §The dictation key), read like keys_win.rs reads its hook:
//! events go to the trigger (trigger.rs) as sided virtual-key codes stamped with their own time.
//!
//! Two sources, decided at launch:
//! * **evdev** — when the user may read `/dev/input` (the `input` group: Settings' "Use right Alt alone" step). Every
//!   key of every keyboard, < 1 ms; keyboards that come later (USB, Bluetooth) are picked up by a rescan. It only
//!   reads: the key still reaches the app in front, so Esc cancels a take *and* goes to the app (Windows keeps it).
//!   A lone right Alt opens some apps' menu bar (Firefox): F24 is sent through the RemoteDesktop session while it is
//!   down (insert_linux `mask_alt`), the hook's menu-mask trick.
//! * **the GlobalShortcuts portal** — otherwise. hotkeys.rs binds `dictate` with the record / snap keys (one session,
//!   one dialog) and forwards its Activated / Deactivated here; the trigger sees them as right Alt going down and up,
//!   alone. No other keys in this mode (no double-tap ⇧ / ⌃ inside a take: the island's buttons do it).

use std::fs::File;
use std::io::Read;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicU8, Ordering::SeqCst};
use std::sync::mpsc::Sender;
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

#[derive(Clone, Copy, Debug)]
pub struct KeyEvent {
    pub code: u32,
    pub down: bool,
    pub tick_ms: u32,
}

/// Esc is Blurt's (a voice note's first seconds): reported; on Linux it still reaches the app (evdev only reads).
pub static ESC_TAKEN: AtomicBool = AtomicBool::new(false);
/// Esc cancels the listening take (reported; it also reaches the app).
pub static ESC_DICTATION: AtomicBool = AtomicBool::new(false);
/// The cancel key's modifier (record.dictation.cancel_key): 0 Esc alone, 1 Ctrl+Esc, 2 Shift+Esc.
pub static CANCEL_MODS: AtomicU8 = AtomicU8::new(0);

static TX: OnceLock<Mutex<Sender<KeyEvent>>> = OnceLock::new();
/// "evdev" | "portal"
static MODE: Mutex<&'static str> = Mutex::new("portal");
/// evdev codes held now (768 bits)
static HELD: [AtomicU64; 12] = [const { AtomicU64::new(0) }; 12];
static PORTAL_DOWN: AtomicBool = AtomicBool::new(false);

const VK_RMENU: u32 = 0xA5;

fn base() -> Instant {
    static B: OnceLock<Instant> = OnceLock::new();
    *B.get_or_init(Instant::now)
}

/// Seconds on the events' clock (for events the app makes itself, e.g. a timer).
pub fn now() -> f64 {
    base().elapsed().as_secs_f64()
}

fn tick() -> u32 {
    base().elapsed().as_millis() as u32
}

fn send(code: u32, down: bool) {
    if let Some(tx) = TX.get() {
        let _ = tx.lock().unwrap().send(KeyEvent { code, down, tick_ms: tick() });
    }
}

/// Which source drives the key: "evdev" or "portal".
pub fn mode() -> &'static str {
    *MODE.lock().unwrap()
}

/// A keyboard can be read directly (the user is in the `input` group): evdev drives the key. BLURT_KEYS_PORTAL=1
/// forces the portal (tests).
pub fn evdev_available() -> bool {
    std::env::var_os("BLURT_KEYS_PORTAL").is_none() && keyboards().iter().any(|p| File::open(p).is_ok())
}

/// The key suggested in GNOME's "Add Keyboard Shortcuts" dialog: Menu, a single key next to right Alt, on keyboards
/// that have one (press and release both come through); else Ctrl+Alt+Space. The user can pick another there.
pub fn portal_trigger() -> &'static str {
    let menu = std::fs::read_dir("/sys/class/input").into_iter().flatten().flatten().any(|e| {
        let caps = std::fs::read_to_string(e.path().join("device/capabilities/key")).unwrap_or_default();
        e.file_name().to_string_lossy().starts_with("event") && has_key(&caps, 30) && has_key(&caps, 127)
    });
    if menu {
        "Menu"
    } else {
        "CTRL+ALT+space"
    }
}

/// Start (once, at launch). Also starts following the focus (insert_linux, AT-SPI).
pub fn start(tx: Sender<KeyEvent>) -> Result<(), String> {
    if TX.set(Mutex::new(tx)).is_err() {
        return Ok(());
    }
    base();
    super::insert_linux::watch();
    if evdev_available() {
        *MODE.lock().unwrap() = "evdev";
        std::thread::Builder::new().name("dictation-keys".into()).spawn(scan).map_err(|e| e.to_string())?;
    }
    eprintln!("dictation: keys from {}", mode());
    Ok(())
}

/// The dictation shortcut from the portal (hotkeys.rs): auto-repeat's extra Activated are dropped.
pub fn portal_key(down: bool) {
    if mode() != "portal" || PORTAL_DOWN.swap(down, SeqCst) == down {
        return;
    }
    send(VK_RMENU, down);
}

/// The key is down now (0x11 either Ctrl, 0x10 either Shift; else a sided VK). Portal mode: never known.
pub fn held(vk: i32) -> bool {
    let codes: &[u16] = match vk {
        0x11 => &[29, 97],
        0x10 => &[42, 54],
        0x12 => &[56, 100],
        v => match to_evdev(v as u32) {
            Some(c) => return is_held(c),
            None => return false,
        },
    };
    codes.iter().any(|&c| is_held(c))
}

fn is_held(c: u16) -> bool {
    let c = c as usize;
    c < 768 && HELD[c / 64].load(SeqCst) & (1 << (c % 64)) != 0
}

fn set_held(c: u16, down: bool) {
    let c = c as usize;
    if c >= 768 {
        return;
    }
    if down {
        HELD[c / 64].fetch_or(1 << (c % 64), SeqCst);
    } else {
        HELD[c / 64].fetch_and(!(1 << (c % 64)), SeqCst);
    }
}

/// The double-tap window: GNOME's double-click time, 0.3–0.5 s (as on the Mac).
pub fn double_tap_window() -> f64 {
    let ms = std::process::Command::new("gsettings")
        .args(["get", "org.gnome.desktop.peripherals.mouse", "double-click"])
        .output()
        .ok()
        .and_then(|o| String::from_utf8_lossy(&o.stdout).split_whitespace().last().and_then(|s| s.parse::<f64>().ok()))
        .unwrap_or(400.0);
    (ms / 1000.0).clamp(0.3, 0.5)
}

// ------------------------------------------------------------------ evdev

/// The event devices that are keyboards (they can type A and Enter): sysfs capability bitmaps.
fn keyboards() -> Vec<String> {
    let mut out = vec![];
    let Ok(rd) = std::fs::read_dir("/sys/class/input") else { return out };
    for e in rd.flatten() {
        let name = e.file_name().to_string_lossy().into_owned();
        if !name.starts_with("event") {
            continue;
        }
        let caps = std::fs::read_to_string(e.path().join("device/capabilities/key")).unwrap_or_default();
        if has_key(&caps, 30) && has_key(&caps, 28) {
            out.push(format!("/dev/input/{name}"));
        }
    }
    out.sort();
    out
}

/// Bit `code` of a sysfs bitmap ("hex words, most significant first").
fn has_key(caps: &str, code: usize) -> bool {
    let words: Vec<&str> = caps.split_whitespace().collect();
    let i = code / 64;
    if i >= words.len() {
        return false;
    }
    u64::from_str_radix(words[words.len() - 1 - i], 16).is_ok_and(|w| w & (1 << (code % 64)) != 0)
}

/// New keyboards every 2 s, each read on a thread of its own until it goes away.
fn scan() {
    let open: Mutex<Vec<String>> = Mutex::new(vec![]);
    let open: &'static Mutex<Vec<String>> = Box::leak(Box::new(open));
    loop {
        for p in keyboards() {
            if open.lock().unwrap().contains(&p) {
                continue;
            }
            let Ok(f) = File::open(&p) else { continue };
            open.lock().unwrap().push(p.clone());
            let _ = std::thread::Builder::new().name("dictation-kbd".into()).spawn(move || {
                read_device(f);
                open.lock().unwrap().retain(|x| x != &p);
            });
        }
        std::thread::sleep(Duration::from_secs(2));
    }
}

/// struct input_event on 64-bit Linux: timeval (16 bytes), type u16, code u16, value i32.
fn read_device(mut f: File) {
    let mut buf = [0u8; 24 * 64];
    loop {
        let n = match f.read(&mut buf) {
            Ok(0) | Err(_) => return,
            Ok(n) => n,
        };
        for ev in buf[..n].chunks_exact(24) {
            let ty = u16::from_ne_bytes([ev[16], ev[17]]);
            let code = u16::from_ne_bytes([ev[18], ev[19]]);
            let value = i32::from_ne_bytes([ev[20], ev[21], ev[22], ev[23]]);
            if ty != 1 || value == 2 {
                continue; // EV_KEY only, no auto-repeat
            }
            let down = value == 1;
            set_held(code, down);
            if code == 100 && down {
                super::insert_linux::mask_alt();
            }
            send(to_vk(code), down);
        }
    }
}

const LETTERS: [(u16, u8); 26] = [
    (30, b'A'), (48, b'B'), (46, b'C'), (32, b'D'), (18, b'E'), (33, b'F'), (34, b'G'), (35, b'H'), (23, b'I'),
    (36, b'J'), (37, b'K'), (38, b'L'), (50, b'M'), (49, b'N'), (24, b'O'), (25, b'P'), (16, b'Q'), (19, b'R'),
    (31, b'S'), (20, b'T'), (22, b'U'), (47, b'V'), (17, b'W'), (45, b'X'), (21, b'Y'), (44, b'Z'),
];
const OTHERS: [(u16, u32); 22] = [
    (1, 0x1B), (42, 0xA0), (54, 0xA1), (29, 0xA2), (97, 0xA3), (56, 0xA4), (100, 0xA5), (125, 0x5B), (126, 0x5C),
    (28, 0x0D), (57, 0x20), (15, 0x09), (14, 0x08), (103, 0x26), (105, 0x25), (106, 0x27), (108, 0x28), (11, 0x30),
    (111, 0x2E), (102, 0x24), (107, 0x23), (127, 0x5D),
];

/// An evdev key code → the Windows virtual-key code trigger.rs speaks (letters, digits, the modifiers by side, the
/// keys the tests name); anything else gets a code of its own above 0x100 — "another key" to the trigger.
fn to_vk(code: u16) -> u32 {
    if let Some(&(_, c)) = LETTERS.iter().find(|(e, _)| *e == code) {
        return c as u32;
    }
    if (2..=10).contains(&code) {
        return 0x31 + (code as u32 - 2); // 1–9
    }
    OTHERS.iter().find(|(e, _)| *e == code).map(|&(_, v)| v).unwrap_or(0x100 + code as u32)
}

fn to_evdev(vk: u32) -> Option<u16> {
    if let Some(&(e, _)) = LETTERS.iter().find(|(_, c)| *c as u32 == vk) {
        return Some(e);
    }
    if (0x31..=0x39).contains(&vk) {
        return Some((vk - 0x31 + 2) as u16);
    }
    if vk >= 0x100 {
        return Some((vk - 0x100) as u16);
    }
    OTHERS.iter().find(|(_, v)| *v == vk).map(|&(e, _)| e)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn codes_both_ways() {
        assert_eq!(to_vk(100), 0xA5); // right Alt
        assert_eq!(to_vk(56), 0xA4);
        assert_eq!(to_vk(1), 0x1B);
        assert_eq!(to_vk(47), 0x56); // V
        assert_eq!(to_vk(2), 0x31);
        assert_eq!(to_vk(183), 0x100 + 183); // F13: another key
        for c in [100u16, 56, 1, 47, 2, 183, 105] {
            assert_eq!(to_evdev(to_vk(c)), Some(c));
        }
    }

    #[test]
    fn sysfs_bitmaps() {
        // a keyboard's: KEY_A (30) and KEY_ENTER (28) in the lowest word
        assert!(has_key("ffffffff 50000000", 30)); // lowest word 0x50000000: bits 28, 30
        assert!(has_key("ffffffff 50000000", 28));
        assert!(!has_key("ffffffff 50000000", 29));
        assert!(has_key("1 0", 64)); // second word's bit 0
        assert!(!has_key("", 30));
    }
}
