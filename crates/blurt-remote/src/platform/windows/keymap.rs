//! Wire key names (host.rs `Input::key`, RemoteKey.all in RemoteKeys.swift) → what a real keyboard sends on Windows.
//!
//! * Letters, digits and punctuation are physical positions on a US keyboard, as the Mac's kVK codes are: they go as scan
//!   codes alone (KEYEVENTF_SCANCODE), so Windows turns them into whatever the active layout has there. On a French
//!   AZERTY layout the wire's "Q" lands as A, exactly as a real keyboard's key in that place would.
//! * The rest (Return, arrows, F-keys …) mean the same on every layout: virtual-key code plus its scan code, and
//!   KEYEVENTF_EXTENDEDKEY for the keys a real keyboard sends with an E0 prefix (arrows, Home, End, PgUp, PgDn, Delete,
//!   Insert, the Win keys, right Ctrl / Alt). Without that flag an arrow is the numeric keypad's 4/6/8/2 to apps and games
//!   that read scan codes, and NumLock changes what it does.
//! * Pure tables: unit-tested on any OS.

use crate::host::mods;

/// One key as SendInput wants it.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct Key {
    /// virtual-key code (VK_*)
    pub vk: u16,
    /// set-1 make code, without the E0 prefix
    pub scan: u16,
    /// KEYEVENTF_EXTENDEDKEY: the E0 prefix
    pub extended: bool,
    /// send as the scan code alone (KEYEVENTF_SCANCODE): a position on the keyboard, the layout decides the character
    pub positional: bool,
}

const fn pos(vk: u16, scan: u16) -> Key {
    Key { vk, scan, extended: false, positional: true }
}
const fn plain(vk: u16, scan: u16) -> Key {
    Key { vk, scan, extended: false, positional: false }
}
const fn ext(vk: u16, scan: u16) -> Key {
    Key { vk, scan, extended: true, positional: false }
}

// VK_* values from WinUser.h (kept here as numbers so the table is testable off Windows)
pub const VK_BACK: u16 = 0x08;
pub const VK_TAB: u16 = 0x09;
pub const VK_RETURN: u16 = 0x0D;
pub const VK_ESCAPE: u16 = 0x1B;
pub const VK_SPACE: u16 = 0x20;
pub const VK_PRIOR: u16 = 0x21;
pub const VK_NEXT: u16 = 0x22;
pub const VK_END: u16 = 0x23;
pub const VK_HOME: u16 = 0x24;
pub const VK_LEFT: u16 = 0x25;
pub const VK_UP: u16 = 0x26;
pub const VK_RIGHT: u16 = 0x27;
pub const VK_DOWN: u16 = 0x28;
pub const VK_INSERT: u16 = 0x2D;
pub const VK_DELETE: u16 = 0x2E;
pub const VK_LWIN: u16 = 0x5B;
pub const VK_F1: u16 = 0x70;
pub const VK_LSHIFT: u16 = 0xA0;
pub const VK_LCONTROL: u16 = 0xA2;
pub const VK_LMENU: u16 = 0xA4;
pub const VK_OEM_1: u16 = 0xBA; // ;
pub const VK_OEM_PLUS: u16 = 0xBB; // =
pub const VK_OEM_COMMA: u16 = 0xBC;
pub const VK_OEM_MINUS: u16 = 0xBD;
pub const VK_OEM_PERIOD: u16 = 0xBE;
pub const VK_OEM_2: u16 = 0xBF; // /
pub const VK_OEM_3: u16 = 0xC0; // `
pub const VK_OEM_4: u16 = 0xDB; // [
pub const VK_OEM_5: u16 = 0xDC; // \
pub const VK_OEM_6: u16 = 0xDD; // ]
pub const VK_OEM_7: u16 = 0xDE; // '
/// Unassigned (0xE8): pressed and released before letting go of a Win or Alt that a click or a scroll went through, so
/// Windows doesn't take the release as a lone tap (Start opening, the menu bar taking the focus). AutoHotkey's "menu mask
/// key" does the same.
pub const VK_MASK: u16 = 0xE8;

/// The modifiers, in the order they go down (and the reverse order they come up): Ctrl, Alt, Shift, Win, as the Mac
/// presses ⌃ ⌥ ⇧ ⌘. Left-hand keys: what a phone's single modifier key means.
pub const MOD_KEYS: [(u8, Key); 4] = [
    (mods::CONTROL, plain(VK_LCONTROL, 0x1D)),
    (mods::OPTION, plain(VK_LMENU, 0x38)),
    (mods::SHIFT, plain(VK_LSHIFT, 0x2A)),
    (mods::COMMAND, ext(VK_LWIN, 0x5B)),
];

/// The bits a Windows keyboard has (FUNCTION is an Apple key: nothing here).
pub const WINDOWS_MODS: u8 = mods::CONTROL | mods::OPTION | mods::SHIFT | mods::COMMAND;

pub fn mod_key(bit: u8) -> Option<Key> {
    MOD_KEYS.iter().find(|(b, _)| *b == bit).map(|(_, k)| *k)
}

pub const MASK_KEY: Key = plain(VK_MASK, 0);

/// The key for a wire name; None for "" and unknown names.
pub fn key(name: &str) -> Option<Key> {
    let b = name.as_bytes();
    if b.len() == 1 {
        let c = b[0];
        return match c {
            b'A'..=b'Z' => Some(pos(c as u16, LETTER_SCANS[(c - b'A') as usize])),
            b'0'..=b'9' => Some(pos(c as u16, if c == b'0' { 0x0B } else { 0x02 + (c - b'1') as u16 })),
            b'-' => Some(pos(VK_OEM_MINUS, 0x0C)),
            b'=' => Some(pos(VK_OEM_PLUS, 0x0D)),
            b'[' => Some(pos(VK_OEM_4, 0x1A)),
            b']' => Some(pos(VK_OEM_6, 0x1B)),
            b';' => Some(pos(VK_OEM_1, 0x27)),
            b'\'' => Some(pos(VK_OEM_7, 0x28)),
            b'`' => Some(pos(VK_OEM_3, 0x29)),
            b'\\' => Some(pos(VK_OEM_5, 0x2B)),
            b',' => Some(pos(VK_OEM_COMMA, 0x33)),
            b'.' => Some(pos(VK_OEM_PERIOD, 0x34)),
            b'/' => Some(pos(VK_OEM_2, 0x35)),
            _ => None,
        };
    }
    if let Some(n) = name.strip_prefix('F').and_then(|n| n.parse::<u16>().ok()) {
        if (1..=12).contains(&n) && !name[1..].starts_with('0') {
            // F1–F10 are 3B–44; F11 and F12 came later and sit at 57, 58
            let scan = if n <= 10 { 0x3A + n } else { 0x57 + (n - 11) };
            return Some(plain(VK_F1 + n - 1, scan));
        }
        return None;
    }
    Some(match name {
        "Return" => plain(VK_RETURN, 0x1C),
        "Tab" => plain(VK_TAB, 0x0F),
        "Space" => plain(VK_SPACE, 0x39),
        "Delete" => plain(VK_BACK, 0x0E), // the wire's Delete is the Mac's: backspace
        "Escape" => plain(VK_ESCAPE, 0x01),
        "ForwardDelete" => ext(VK_DELETE, 0x53),
        "Insert" => ext(VK_INSERT, 0x52), // not on the phone's keys yet; a real keyboard's Insert
        "Left" => ext(VK_LEFT, 0x4B),
        "Right" => ext(VK_RIGHT, 0x4D),
        "Up" => ext(VK_UP, 0x48),
        "Down" => ext(VK_DOWN, 0x50),
        "Home" => ext(VK_HOME, 0x47),
        "End" => ext(VK_END, 0x4F),
        "PageUp" => ext(VK_PRIOR, 0x49),
        "PageDown" => ext(VK_NEXT, 0x51),
        _ => return None,
    })
}

/// Set-1 make codes of A…Z on a US keyboard.
const LETTER_SCANS: [u16; 26] = [
    0x1E, 0x30, 0x2E, 0x20, 0x12, 0x21, 0x22, 0x23, 0x17, 0x24, 0x25, 0x26, 0x32, // A–M
    0x31, 0x18, 0x19, 0x10, 0x13, 0x1F, 0x14, 0x16, 0x2F, 0x11, 0x2D, 0x15, 0x2C, // N–Z
];

#[cfg(test)]
mod tests {
    use super::*;

    /// RemoteKey.all (RemoteKeys.swift), the names host.rs lists.
    fn wire_names() -> Vec<String> {
        let mut v: Vec<String> = ('A'..='Z').chain('0'..='9').map(|c| c.to_string()).collect();
        v.extend((1..=12).map(|n| format!("F{n}")));
        for n in [
            "Return", "Tab", "Space", "Delete", "Escape", "ForwardDelete", "Left", "Right", "Down", "Up", "Home", "End", "PageUp",
            "PageDown", "-", "=", "[", "]", ";", "'", ",", ".", "/", "\\", "`",
        ] {
            v.push(n.into());
        }
        v
    }

    #[test]
    fn every_wire_name_has_a_key() {
        let names = wire_names();
        assert_eq!(names.len(), 73);
        for n in &names {
            assert!(key(n).is_some(), "{n}");
        }
    }

    #[test]
    fn keys_are_distinct() {
        let mut seen = std::collections::HashSet::new();
        for n in wire_names() {
            let k = key(&n).unwrap();
            assert!(seen.insert((k.scan, k.extended)), "{n} shares a scan code");
            assert!(seen.insert((k.vk | 0x8000, false)), "{n} shares a VK");
        }
    }

    #[test]
    fn unknown_names_are_nothing() {
        for n in ["", "a", "F0", "F13", "F01", "Enter", "Backspace", "Ä", "AB", "§", " "] {
            assert_eq!(key(n), None, "{n:?}");
        }
    }

    #[test]
    fn positions_match_a_us_keyboard() {
        // a few checked against the scan code set 1 table by hand
        assert_eq!(key("Q").unwrap(), pos(0x51, 0x10));
        assert_eq!(key("A").unwrap(), pos(0x41, 0x1E));
        assert_eq!(key("Z").unwrap(), pos(0x5A, 0x2C));
        assert_eq!(key("M").unwrap(), pos(0x4D, 0x32));
        assert_eq!(key("1").unwrap(), pos(0x31, 0x02));
        assert_eq!(key("9").unwrap(), pos(0x39, 0x0A));
        assert_eq!(key("0").unwrap(), pos(0x30, 0x0B));
        assert_eq!(key("`").unwrap().scan, 0x29);
        assert_eq!(key("\\").unwrap().scan, 0x2B);
        assert_eq!(key("F1").unwrap(), plain(0x70, 0x3B));
        assert_eq!(key("F10").unwrap(), plain(0x79, 0x44));
        assert_eq!(key("F11").unwrap(), plain(0x7A, 0x57));
        assert_eq!(key("F12").unwrap(), plain(0x7B, 0x58));
    }

    #[test]
    fn navigation_is_extended_and_not_positional() {
        for n in ["Left", "Right", "Up", "Down", "Home", "End", "PageUp", "PageDown", "ForwardDelete", "Insert"] {
            let k = key(n).unwrap();
            assert!(k.extended && !k.positional, "{n}");
        }
        for n in ["Return", "Tab", "Space", "Delete", "Escape", "F5"] {
            let k = key(n).unwrap();
            assert!(!k.extended && !k.positional, "{n}");
        }
        // every printable key is a position
        for n in wire_names().iter().filter(|n| n.len() == 1) {
            assert!(key(n).unwrap().positional, "{n}");
        }
    }

    #[test]
    fn modifiers() {
        assert_eq!(mod_key(mods::COMMAND).unwrap().vk, VK_LWIN);
        assert!(mod_key(mods::COMMAND).unwrap().extended);
        assert_eq!(mod_key(mods::CONTROL).unwrap().vk, VK_LCONTROL);
        assert_eq!(mod_key(mods::OPTION).unwrap().vk, VK_LMENU);
        assert_eq!(mod_key(mods::SHIFT).unwrap().vk, VK_LSHIFT);
        assert_eq!(mod_key(mods::FUNCTION), None);
        assert_eq!(MOD_KEYS.iter().fold(0, |a, (b, _)| a | b), WINDOWS_MODS);
    }
}
