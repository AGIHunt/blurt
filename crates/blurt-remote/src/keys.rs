//! Key names on the wire (RemoteKey.all in RemoteKeys.swift), and what a viewer (a computer driving another,
//! docs/design/remote-desktop-viewer.md) sends for the keys of its own keyboard.
//!
//!  • `ALL`: every name, in RemoteKey.all's order: the phone deck's 73, then a full keyboard's (F13–F20, the keypad, Num Lock,
//!    Insert, Caps Lock, Menu, the ISO and JIS keys, the volume keys, Print Screen, Scroll Lock, Pause). Hosts press their own
//!    key for each (platform/windows/keymap.rs, platform/linux/keys.rs, the Mac's kVK codes).
//!  • The viewer reads its keyboard as the web's `KeyboardEvent.code` names ("KeyA", "ArrowLeft", "Numpad1"), which every
//!    webview gives and which the Windows hook's scan codes are turned into here (`code_of_scan`), so one table maps both.
//!  • Modifiers go as `ToMac::Mods` (what is held now), every other key as `ToMac::Key` with `down` (held across messages), so
//!    the host's own key repeat, Alt+Tab and a lone Win tap behave as on its own keyboard. To a Mac host, Ctrl is sent as ⌘ and
//!    Win / Super as ⌃ unless the ⋯ menu turns that off. Ctrl+Alt (left Alt: AltGr is Ctrl+right Alt on Windows) gives the
//!    keyboard back.

use crate::host::mods;
use crate::wire::ToMac;

/// Every wire key name, in RemoteKey.all's order.
pub const ALL: &[&str] = &[
    "A",
    "B",
    "C",
    "D",
    "E",
    "F",
    "G",
    "H",
    "I",
    "J",
    "K",
    "L",
    "M",
    "N",
    "O",
    "P",
    "Q",
    "R",
    "S",
    "T",
    "U",
    "V",
    "W",
    "X",
    "Y",
    "Z",
    "0",
    "1",
    "2",
    "3",
    "4",
    "5",
    "6",
    "7",
    "8",
    "9",
    "F1",
    "F2",
    "F3",
    "F4",
    "F5",
    "F6",
    "F7",
    "F8",
    "F9",
    "F10",
    "F11",
    "F12",
    "Return",
    "Tab",
    "Space",
    "Delete",
    "Escape",
    "ForwardDelete",
    "Left",
    "Right",
    "Down",
    "Up",
    "Home",
    "End",
    "PageUp",
    "PageDown",
    "-",
    "=",
    "[",
    "]",
    ";",
    "'",
    ",",
    ".",
    "/",
    "\\",
    "`",
    // a full keyboard's (2026-11-19)
    "F13",
    "F14",
    "F15",
    "F16",
    "F17",
    "F18",
    "F19",
    "F20",
    "Keypad0",
    "Keypad1",
    "Keypad2",
    "Keypad3",
    "Keypad4",
    "Keypad5",
    "Keypad6",
    "Keypad7",
    "Keypad8",
    "Keypad9",
    "KeypadDecimal",
    "KeypadMultiply",
    "KeypadPlus",
    "KeypadMinus",
    "KeypadDivide",
    "KeypadEnter",
    "KeypadEquals",
    "KeypadComma",
    "NumLock",
    "Insert",
    "CapsLock",
    "Menu",
    "IntlBackslash",
    "IntlYen",
    "IntlRo",
    "Lang2",
    "Lang1",
    "VolumeUp",
    "VolumeDown",
    "Mute",
    "PrintScreen",
    "ScrollLock",
    "Pause",
];

/// How many of `ALL` a phone's deck sends (everything up to "`").
pub const DECK: usize = 73;

pub fn known(name: &str) -> bool {
    ALL.contains(&name)
}

/// The web's `KeyboardEvent.code` → the wire's name. None: a modifier (see `modifier_of`), or a key the wire has no name for.
pub fn from_code(code: &str) -> Option<&'static str> {
    if let Some(l) = code.strip_prefix("Key") {
        return ALL[..26].iter().copied().find(|n| *n == l);
    }
    if let Some(d) = code.strip_prefix("Digit") {
        return ALL[26..36].iter().copied().find(|n| *n == d);
    }
    if let Some(d) = code.strip_prefix("Numpad").filter(|d| d.len() == 1) {
        return ALL
            .iter()
            .copied()
            .find(|n| n.strip_prefix("Keypad") == Some(d));
    }
    if code.starts_with('F') && code[1..].parse::<u8>().is_ok_and(|n| (1..=20).contains(&n)) {
        return ALL.iter().copied().find(|n| *n == code);
    }
    Some(match code {
        "Enter" => "Return",
        "Tab" => "Tab",
        "Space" => "Space",
        "Backspace" => "Delete",
        "Escape" => "Escape",
        "Delete" => "ForwardDelete",
        "ArrowLeft" => "Left",
        "ArrowRight" => "Right",
        "ArrowDown" => "Down",
        "ArrowUp" => "Up",
        "Home" => "Home",
        "End" => "End",
        "PageUp" => "PageUp",
        "PageDown" => "PageDown",
        "Minus" => "-",
        "Equal" => "=",
        "BracketLeft" => "[",
        "BracketRight" => "]",
        "Semicolon" => ";",
        "Quote" => "'",
        "Comma" => ",",
        "Period" => ".",
        "Slash" => "/",
        "Backslash" => "\\",
        "Backquote" => "`",
        "NumpadDecimal" => "KeypadDecimal",
        "NumpadMultiply" => "KeypadMultiply",
        "NumpadAdd" => "KeypadPlus",
        "NumpadSubtract" => "KeypadMinus",
        "NumpadDivide" => "KeypadDivide",
        "NumpadEnter" => "KeypadEnter",
        "NumpadEqual" => "KeypadEquals",
        "NumpadComma" => "KeypadComma",
        "NumLock" => "NumLock",
        "Insert" => "Insert",
        "CapsLock" => "CapsLock",
        "ContextMenu" => "Menu",
        "IntlBackslash" => "IntlBackslash",
        "IntlYen" => "IntlYen",
        "IntlRo" => "IntlRo",
        "Lang1" | "KanaMode" => "Lang1",
        "Lang2" => "Lang2",
        "AudioVolumeUp" | "VolumeUp" => "VolumeUp",
        "AudioVolumeDown" | "VolumeDown" => "VolumeDown",
        "AudioVolumeMute" | "VolumeMute" => "Mute",
        "PrintScreen" => "PrintScreen",
        "ScrollLock" => "ScrollLock",
        "Pause" => "Pause",
        _ => return None,
    })
}

/// The modifier keys, as the viewer's own keyboard names them.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Modifier {
    Control,
    Alt,
    Shift,
    /// Win on Windows, Super on Linux, ⌘ on a Mac
    Meta,
}

/// Which modifier a `KeyboardEvent.code` is, and whether it's the right-hand one.
pub fn modifier_of(code: &str) -> Option<(Modifier, bool)> {
    Some(match code {
        "ControlLeft" => (Modifier::Control, false),
        "ControlRight" => (Modifier::Control, true),
        "AltLeft" => (Modifier::Alt, false),
        "AltRight" => (Modifier::Alt, true),
        "ShiftLeft" => (Modifier::Shift, false),
        "ShiftRight" => (Modifier::Shift, true),
        "MetaLeft" | "OSLeft" => (Modifier::Meta, false),
        "MetaRight" | "OSRight" => (Modifier::Meta, true),
        _ => return None,
    })
}

/// The wire's bit for a modifier of this keyboard, sent to a host of `host` ("mac", "windows", "linux"). `mapped`: the ⋯ menu's
/// modifier mapping (on by default): to a Mac, Ctrl is ⌘ (shortcuts), Win / Super is ⌃. Between Windows and Linux, and with it
/// off, Ctrl is Ctrl and Win / Super is the command bit, as the protocol's table has it (remote-protocol.md §Hosts).
pub fn bit(m: Modifier, host: &str, mapped: bool) -> u8 {
    let pressed = match m {
        Modifier::Shift => mods::SHIFT,
        Modifier::Alt => mods::OPTION,
        Modifier::Control => mods::CONTROL,
        Modifier::Meta => mods::COMMAND,
    };
    map_mods(pressed, VIEWER_OS, host, mapped)
}

/// This computer, as a viewer: what its own keyboard's keys are (the Mac viewer is BlurtApp's, in Swift).
const VIEWER_OS: &str = if cfg!(windows) { "windows" } else { "linux" };

/// The modifier bits held on the viewer's keyboard (as the wire names that keyboard's keys: on a Mac ⌘ is command, elsewhere
/// Win / Super is command) → what the host is sent (RemoteViewerKeys.map). Between a Mac and anything else, with the mapping on,
/// command and control swap places: a Mac's ⌘C is Windows' Ctrl+C, Windows' Ctrl+C a Mac's ⌘C. Otherwise as pressed.
pub fn map_mods(pressed: u8, viewer: &str, host: &str, mapped: bool) -> u8 {
    if !mapped || (viewer == "mac") == (host == "mac") {
        return pressed;
    }
    let mut out = pressed & !(mods::COMMAND | mods::CONTROL);
    if pressed & mods::COMMAND != 0 {
        out |= mods::CONTROL;
    }
    if pressed & mods::CONTROL != 0 {
        out |= mods::COMMAND;
    }
    out
}

/// A Windows keyboard's scan code (set 1, `KBDLLHOOKSTRUCT.scanCode`) and its E0 flag → the web's `code` for that key, so the
/// low-level hook and the webview share one table. VK alone for keys some keyboards send without a usable scan code.
pub fn code_of_scan(scan: u32, extended: bool, vk: u32) -> Option<&'static str> {
    // by virtual key first: media keys and the IME keys have no stable scan code
    let by_vk = match vk {
        0xAD => Some("AudioVolumeMute"),
        0xAE => Some("AudioVolumeDown"),
        0xAF => Some("AudioVolumeUp"),
        0x13 => Some("Pause"),
        0x2C => Some("PrintScreen"),
        0x5B => Some("MetaLeft"),
        0x5C => Some("MetaRight"),
        0x5D => Some("ContextMenu"),
        0x16 | 0x15 => Some("Lang1"), // VK_IME_ON, VK_KANA / VK_HANGUL
        0x1A | 0x19 => Some("Lang2"), // VK_IME_OFF, VK_HANJA
        _ => None,
    };
    if by_vk.is_some() {
        return by_vk;
    }
    const LETTERS: [(u32, &str); 26] = [
        (0x1E, "KeyA"),
        (0x30, "KeyB"),
        (0x2E, "KeyC"),
        (0x20, "KeyD"),
        (0x12, "KeyE"),
        (0x21, "KeyF"),
        (0x22, "KeyG"),
        (0x23, "KeyH"),
        (0x17, "KeyI"),
        (0x24, "KeyJ"),
        (0x25, "KeyK"),
        (0x26, "KeyL"),
        (0x32, "KeyM"),
        (0x31, "KeyN"),
        (0x18, "KeyO"),
        (0x19, "KeyP"),
        (0x10, "KeyQ"),
        (0x13, "KeyR"),
        (0x1F, "KeyS"),
        (0x14, "KeyT"),
        (0x16, "KeyU"),
        (0x2F, "KeyV"),
        (0x11, "KeyW"),
        (0x2D, "KeyX"),
        (0x15, "KeyY"),
        (0x2C, "KeyZ"),
    ];
    if extended {
        return Some(match scan {
            0x1C => "NumpadEnter",
            0x1D => "ControlRight",
            0x35 => "NumpadDivide",
            0x37 => "PrintScreen",
            0x38 => "AltRight",
            0x45 => "NumLock",
            0x47 => "Home",
            0x48 => "ArrowUp",
            0x49 => "PageUp",
            0x4B => "ArrowLeft",
            0x4D => "ArrowRight",
            0x4F => "End",
            0x50 => "ArrowDown",
            0x51 => "PageDown",
            0x52 => "Insert",
            0x53 => "Delete",
            0x5B => "MetaLeft",
            0x5C => "MetaRight",
            0x5D => "ContextMenu",
            _ => return None,
        });
    }
    if let Some((_, c)) = LETTERS.iter().find(|(s, _)| *s == scan) {
        return Some(c);
    }
    Some(match scan {
        0x01 => "Escape",
        0x02 => "Digit1",
        0x03 => "Digit2",
        0x04 => "Digit3",
        0x05 => "Digit4",
        0x06 => "Digit5",
        0x07 => "Digit6",
        0x08 => "Digit7",
        0x09 => "Digit8",
        0x0A => "Digit9",
        0x0B => "Digit0",
        0x0C => "Minus",
        0x0D => "Equal",
        0x0E => "Backspace",
        0x0F => "Tab",
        0x1A => "BracketLeft",
        0x1B => "BracketRight",
        0x1C => "Enter",
        0x1D => "ControlLeft",
        0x27 => "Semicolon",
        0x28 => "Quote",
        0x29 => "Backquote",
        0x2A => "ShiftLeft",
        0x2B => "Backslash",
        0x33 => "Comma",
        0x34 => "Period",
        0x35 => "Slash",
        0x36 => "ShiftRight",
        0x37 => "NumpadMultiply",
        0x38 => "AltLeft",
        0x39 => "Space",
        0x3A => "CapsLock",
        0x3B => "F1",
        0x3C => "F2",
        0x3D => "F3",
        0x3E => "F4",
        0x3F => "F5",
        0x40 => "F6",
        0x41 => "F7",
        0x42 => "F8",
        0x43 => "F9",
        0x44 => "F10",
        0x45 => "NumLock",
        0x46 => "ScrollLock",
        0x47 => "Numpad7",
        0x48 => "Numpad8",
        0x49 => "Numpad9",
        0x4A => "NumpadSubtract",
        0x4B => "Numpad4",
        0x4C => "Numpad5",
        0x4D => "Numpad6",
        0x4E => "NumpadAdd",
        0x4F => "Numpad1",
        0x50 => "Numpad2",
        0x51 => "Numpad3",
        0x52 => "Numpad0",
        0x53 => "NumpadDecimal",
        0x56 => "IntlBackslash",
        0x57 => "F11",
        0x58 => "F12",
        0x59 => "NumpadEqual",
        0x64 => "F13",
        0x65 => "F14",
        0x66 => "F15",
        0x67 => "F16",
        0x68 => "F17",
        0x69 => "F18",
        0x6A => "F19",
        0x6B => "F20",
        0x73 => "IntlRo",
        0x7D => "IntlYen",
        0x7E => "NumpadComma",
        _ => return None,
    })
}

/// What one key event of the viewer's keyboard becomes.
#[derive(Clone, Debug, PartialEq)]
pub enum Sent {
    /// to the host
    Message(ToMac),
    /// Ctrl+Alt: the keyboard and mouse go back to this computer. Whatever was held has already been let go of on the host
    /// (the messages before it).
    Release,
}

/// The viewer's keyboard while captured: what's held, turned into the host's messages. One per window.
#[derive(Clone, Debug, Default)]
pub struct Keyboard {
    /// the modifier keys down now (left and right apart)
    mods_down: Vec<(Modifier, bool)>,
    /// the wire bits last sent in `Mods`
    sent_mods: u8,
    /// other keys down now, by wire name
    keys_down: Vec<&'static str>,
    /// Ctrl and left Alt are held, alone, with no other key since: letting go of either releases
    armed: bool,
}

impl Keyboard {
    pub fn new() -> Keyboard {
        Keyboard::default()
    }

    fn wire_mods(&self, host: &str, mapped: bool) -> u8 {
        self.mods_down
            .iter()
            .fold(0, |m, (k, _)| m | bit(*k, host, mapped))
    }

    /// One key went down (or repeated) or up. `host`: the host's platform; `mapped`: the modifier mapping.
    pub fn event(&mut self, code: &str, down: bool, host: &str, mapped: bool) -> Vec<Sent> {
        let mut out = vec![];
        if let Some((m, right)) = modifier_of(code) {
            let had = self.mods_down.contains(&(m, right));
            if down && !had {
                self.mods_down.push((m, right));
            } else if !down {
                self.mods_down.retain(|x| *x != (m, right));
            }
            // Ctrl+Alt, pressed together and let go with no other key between, gives the keys back (RemoteReleaseChord): so
            // Ctrl+Alt+T or Ctrl+Alt+Del's neighbours still reach the host. Left Alt only: AltGr is right Alt (with a fake
            // Ctrl on Windows, which the hook drops)
            let only_chord = |m: &[(Modifier, bool)]| {
                m.iter()
                    .all(|x| x.0 == Modifier::Control || *x == (Modifier::Alt, false))
            };
            let ctrl = self.mods_down.iter().any(|(k, _)| *k == Modifier::Control);
            let left_alt = self.mods_down.contains(&(Modifier::Alt, false));
            if down {
                self.armed =
                    ctrl && left_alt && only_chord(&self.mods_down) && self.keys_down.is_empty();
            } else if self.armed && only_chord(&self.mods_down) {
                self.armed = false;
                out.extend(self.let_go().into_iter().map(Sent::Message));
                out.push(Sent::Release);
                return out;
            }
            let now = self.wire_mods(host, mapped);
            if now != self.sent_mods {
                self.sent_mods = now;
                out.push(Sent::Message(ToMac::Mods(now)));
            }
            return out;
        }
        let Some(name) = from_code(code) else {
            return out;
        };
        if down {
            self.armed = false;
            // a repeat is another press, as the host's own keyboard would make it
            if !self.keys_down.contains(&name) {
                self.keys_down.push(name);
            }
        } else if let Some(i) = self.keys_down.iter().position(|k| *k == name) {
            self.keys_down.remove(i);
        } else {
            return out; // up for a key pressed before the capture: the host never had it
        }
        out.push(Sent::Message(ToMac::Key {
            chord: crate::wire::Chord::new(0, name),
            down: Some(down),
        }));
        out
    }

    /// Everything held goes up on the host (capture ends, the window loses focus).
    pub fn let_go(&mut self) -> Vec<ToMac> {
        let mut out: Vec<ToMac> = self
            .keys_down
            .drain(..)
            .map(|k| ToMac::Key {
                chord: crate::wire::Chord::new(0, k),
                down: Some(false),
            })
            .collect();
        if self.sent_mods != 0 {
            self.sent_mods = 0;
            out.push(ToMac::Mods(0));
        }
        self.mods_down.clear();
        self.armed = false;
        out
    }

    /// The mapping changed with keys held: the host gets the modifiers as they're now meant.
    pub fn remap(&mut self, host: &str, mapped: bool) -> Option<ToMac> {
        let now = self.wire_mods(host, mapped);
        (now != self.sent_mods).then(|| {
            self.sent_mods = now;
            ToMac::Mods(now)
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::wire::Chord;

    #[test]
    fn the_names_are_the_swift_lists() {
        assert_eq!(ALL.len(), 114);
        assert_eq!(ALL[DECK - 1], "`");
        let mut seen = std::collections::HashSet::new();
        for n in ALL {
            assert!(seen.insert(*n), "{n} twice");
        }
        // the phone deck's keys are what input.rs has always known
        for n in ["F12", "PageDown", "\\", "Z", "0"] {
            assert!(ALL[..DECK].contains(&n));
        }
        assert!(!known("F21") && !known("Enter") && !known(""));
    }

    /// The names RemoteKeys.swift lists: the first string of every `k("…"` call and `("X", n)` pair, and the ones it counts out
    /// (F1…F20, Keypad0…9). Skipped when the Swift tree isn't there.
    #[test]
    fn the_names_match_remote_keys_swift() {
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../skills/blurt/recorder/macos/Sources/BlurtRemoteKit/RemoteKeys.swift");
        let Ok(src) = std::fs::read_to_string(path) else {
            return;
        };
        let body = &src[src.find("public static let all").unwrap()..];
        let body = &body[..body.find("return t").unwrap()];
        let mut names: Vec<String> = vec![];
        let lit = |from: &str| -> Option<String> {
            let mut out = String::new();
            let mut it = from.chars();
            while let Some(c) = it.next() {
                match c {
                    '"' => return Some(out),
                    '\\' => out.push(it.next()?),
                    c => out.push(c),
                }
            }
            None
        };
        for (i, _) in body.match_indices("k(\"") {
            names.push(lit(&body[i + 3..]).unwrap());
        }
        for (i, _) in body.match_indices("(\"") {
            if body[..i].ends_with('k') {
                continue;
            }
            let n = lit(&body[i + 2..]).unwrap();
            if body[i + 2 + n.len() + 1..].starts_with(", ") {
                names.push(n);
            }
        }
        names.retain(|n| !n.contains("$0"));
        names.extend((1..=20).map(|i| format!("F{i}")));
        names.extend((0..=9).map(|i| format!("Keypad{i}")));
        let mut a: Vec<&str> = names.iter().map(String::as_str).collect();
        let mut b: Vec<&str> = ALL.to_vec();
        a.sort();
        a.dedup();
        b.sort();
        assert_eq!(a, b);
    }

    #[test]
    fn every_name_has_a_web_code_and_back() {
        // the codes a browser gives for each name: from_code maps them all, and to that name
        let codes = [
            "KeyA",
            "Digit0",
            "F1",
            "F12",
            "F13",
            "F20",
            "Enter",
            "Tab",
            "Space",
            "Backspace",
            "Escape",
            "Delete",
            "ArrowLeft",
            "ArrowRight",
            "ArrowDown",
            "ArrowUp",
            "Home",
            "End",
            "PageUp",
            "PageDown",
            "Minus",
            "Equal",
            "BracketLeft",
            "BracketRight",
            "Semicolon",
            "Quote",
            "Comma",
            "Period",
            "Slash",
            "Backslash",
            "Backquote",
            "Numpad0",
            "Numpad9",
            "NumpadDecimal",
            "NumpadMultiply",
            "NumpadAdd",
            "NumpadSubtract",
            "NumpadDivide",
            "NumpadEnter",
            "NumpadEqual",
            "NumpadComma",
            "NumLock",
            "Insert",
            "CapsLock",
            "ContextMenu",
            "IntlBackslash",
            "IntlYen",
            "IntlRo",
            "Lang1",
            "Lang2",
            "AudioVolumeUp",
            "AudioVolumeDown",
            "AudioVolumeMute",
            "PrintScreen",
            "ScrollLock",
            "Pause",
        ];
        let mut names = std::collections::HashSet::new();
        for c in codes {
            let n = from_code(c).unwrap_or_else(|| panic!("{c}"));
            assert!(known(n), "{c} → {n}");
            names.insert(n);
        }
        for l in 'A'..='Z' {
            assert_eq!(
                from_code(&format!("Key{l}")),
                Some(ALL[(l as u8 - b'A') as usize])
            );
        }
        for d in 0..10 {
            assert_eq!(from_code(&format!("Digit{d}")), Some(ALL[26 + d]));
            assert_eq!(
                from_code(&format!("Numpad{d}")),
                Some(
                    ALL.iter()
                        .copied()
                        .find(|n| *n == format!("Keypad{d}"))
                        .unwrap()
                )
            );
        }
        for f in 1..=20 {
            assert_eq!(
                from_code(&format!("F{f}")),
                Some(ALL.iter().copied().find(|n| *n == format!("F{f}")).unwrap())
            );
        }
        assert_eq!(from_code("F21"), None);
        assert_eq!(from_code("ControlLeft"), None, "modifiers go as Mods");
        assert_eq!(from_code("Fn"), None);
    }

    #[test]
    fn scan_codes_are_the_web_codes() {
        assert_eq!(code_of_scan(0x1E, false, 0x41), Some("KeyA"));
        assert_eq!(
            code_of_scan(0x10, false, 0x41),
            Some("KeyQ"),
            "a position, whatever the layout's letter"
        );
        assert_eq!(code_of_scan(0x4B, true, 0x25), Some("ArrowLeft"));
        assert_eq!(code_of_scan(0x4B, false, 0x64), Some("Numpad4"));
        assert_eq!(code_of_scan(0x1C, true, 0x0D), Some("NumpadEnter"));
        assert_eq!(code_of_scan(0x1C, false, 0x0D), Some("Enter"));
        assert_eq!(code_of_scan(0x5B, true, 0x5B), Some("MetaLeft"));
        assert_eq!(code_of_scan(0x38, true, 0xA5), Some("AltRight"));
        assert_eq!(code_of_scan(0x45, false, 0x13), Some("Pause"));
        assert_eq!(code_of_scan(0x45, true, 0x90), Some("NumLock"));
        assert_eq!(code_of_scan(0x64, false, 0x7C), Some("F13"));
        assert_eq!(code_of_scan(0x00, false, 0xAF), Some("AudioVolumeUp"));
        // every key a scan code names maps on to a wire name or a modifier
        for scan in 0..0x80 {
            for ext in [false, true] {
                if let Some(c) = code_of_scan(scan, ext, 0) {
                    assert!(
                        from_code(c).is_some() || modifier_of(c).is_some(),
                        "{scan:#x} {ext} {c}"
                    );
                }
            }
        }
    }

    #[test]
    fn modifiers_to_a_mac_swap_ctrl_and_win_unless_off() {
        assert_eq!(bit(Modifier::Control, "mac", true), mods::COMMAND);
        assert_eq!(bit(Modifier::Meta, "mac", true), mods::CONTROL);
        assert_eq!(bit(Modifier::Alt, "mac", true), mods::OPTION);
        assert_eq!(bit(Modifier::Shift, "mac", true), mods::SHIFT);
        assert_eq!(bit(Modifier::Control, "mac", false), mods::CONTROL);
        assert_eq!(bit(Modifier::Meta, "mac", false), mods::COMMAND);
        for host in ["windows", "linux"] {
            for mapped in [true, false] {
                assert_eq!(bit(Modifier::Control, host, mapped), mods::CONTROL);
                assert_eq!(bit(Modifier::Meta, host, mapped), mods::COMMAND);
            }
        }
    }

    fn messages(v: Vec<Sent>) -> Vec<ToMac> {
        v.into_iter()
            .filter_map(|s| {
                if let Sent::Message(m) = s {
                    Some(m)
                } else {
                    None
                }
            })
            .collect()
    }

    #[test]
    fn ctrl_c_to_a_mac_is_command_c() {
        let mut k = Keyboard::new();
        assert_eq!(
            messages(k.event("ControlLeft", true, "mac", true)),
            vec![ToMac::Mods(mods::COMMAND)]
        );
        assert_eq!(
            messages(k.event("KeyC", true, "mac", true)),
            vec![ToMac::Key {
                chord: Chord::new(0, "C"),
                down: Some(true)
            }]
        );
        assert_eq!(
            messages(k.event("KeyC", false, "mac", true)),
            vec![ToMac::Key {
                chord: Chord::new(0, "C"),
                down: Some(false)
            }]
        );
        assert_eq!(
            messages(k.event("ControlLeft", false, "mac", true)),
            vec![ToMac::Mods(0)]
        );
        // to Windows: Ctrl is Ctrl
        assert_eq!(
            messages(k.event("ControlRight", true, "windows", true)),
            vec![ToMac::Mods(mods::CONTROL)]
        );
        assert_eq!(
            messages(k.event("ControlRight", false, "windows", true)),
            vec![ToMac::Mods(0)]
        );
    }

    #[test]
    fn a_lone_win_tap_and_alt_tab_go_as_held_keys() {
        let mut k = Keyboard::new();
        assert_eq!(
            messages(k.event("MetaLeft", true, "windows", true)),
            vec![ToMac::Mods(mods::COMMAND)]
        );
        assert_eq!(
            messages(k.event("MetaLeft", false, "windows", true)),
            vec![ToMac::Mods(0)]
        );
        assert_eq!(
            messages(k.event("AltLeft", true, "windows", true)),
            vec![ToMac::Mods(mods::OPTION)]
        );
        assert_eq!(messages(k.event("Tab", true, "windows", true)).len(), 1);
        assert_eq!(messages(k.event("Tab", false, "windows", true)).len(), 1);
        assert_eq!(
            messages(k.event("Tab", true, "windows", true)).len(),
            1,
            "Alt held: a second Tab"
        );
        // a repeat is another press
        assert_eq!(
            messages(k.event("Tab", true, "windows", true)),
            vec![ToMac::Key {
                chord: Chord::new(0, "Tab"),
                down: Some(true)
            }]
        );
        assert_eq!(messages(k.event("Tab", false, "windows", true)).len(), 1);
        assert_eq!(
            messages(k.event("AltLeft", false, "windows", true)),
            vec![ToMac::Mods(0)]
        );
        // both Shifts: one bit, gone only when both are up
        assert_eq!(
            messages(k.event("ShiftLeft", true, "linux", true)),
            vec![ToMac::Mods(mods::SHIFT)]
        );
        assert_eq!(messages(k.event("ShiftRight", true, "linux", true)), vec![]);
        assert_eq!(messages(k.event("ShiftLeft", false, "linux", true)), vec![]);
        assert_eq!(
            messages(k.event("ShiftRight", false, "linux", true)),
            vec![ToMac::Mods(0)]
        );
    }

    #[test]
    fn ctrl_alt_alone_releases_when_let_go() {
        let mut k = Keyboard::new();
        k.event("ControlLeft", true, "windows", true);
        let out = k.event("AltLeft", true, "windows", true);
        assert_eq!(
            messages(out),
            vec![ToMac::Mods(mods::CONTROL | mods::OPTION)],
            "held, as on the host's keyboard, until let go"
        );
        let out = k.event("AltLeft", false, "windows", true);
        assert_eq!(out.last(), Some(&Sent::Release));
        assert_eq!(
            messages(out),
            vec![ToMac::Mods(0)],
            "nothing stays held on the host"
        );
        // the other one coming up afterwards says nothing
        assert_eq!(
            messages(k.event("ControlLeft", false, "windows", true)),
            vec![]
        );
        // Ctrl+Alt+T is a shortcut for the host, not a release
        let mut k = Keyboard::new();
        k.event("ControlRight", true, "linux", true);
        k.event("AltLeft", true, "linux", true);
        k.event("KeyT", true, "linux", true);
        k.event("KeyT", false, "linux", true);
        let out = k.event("AltLeft", false, "linux", true);
        assert!(!out.contains(&Sent::Release));
        // with Shift held too: a shortcut
        let mut k = Keyboard::new();
        k.event("ShiftLeft", true, "windows", true);
        k.event("ControlLeft", true, "windows", true);
        k.event("AltLeft", true, "windows", true);
        assert!(!k
            .event("AltLeft", false, "windows", true)
            .contains(&Sent::Release));
        // a key held from before: let go of on the host with the release
        let mut k = Keyboard::new();
        k.event("ControlLeft", true, "windows", true);
        k.event("AltLeft", true, "windows", true);
        let out = k.event("ControlLeft", false, "windows", true);
        assert_eq!(out.last(), Some(&Sent::Release));
        // AltGr (Ctrl + right Alt on Windows) types, it doesn't release
        let mut k = Keyboard::new();
        k.event("ControlLeft", true, "windows", true);
        assert_eq!(
            messages(k.event("AltRight", true, "windows", true)),
            vec![ToMac::Mods(mods::CONTROL | mods::OPTION)]
        );
        assert!(!k
            .event("AltRight", false, "windows", true)
            .contains(&Sent::Release));
    }

    #[test]
    fn turning_the_mapping_off_with_ctrl_held() {
        let mut k = Keyboard::new();
        k.event("ControlLeft", true, "mac", true);
        assert_eq!(k.remap("mac", false), Some(ToMac::Mods(mods::CONTROL)));
        assert_eq!(k.remap("mac", false), None);
    }
}
