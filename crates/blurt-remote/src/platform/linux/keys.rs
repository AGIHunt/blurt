//! Keys on Linux, as data: wire key names (RemoteKeys.swift `RemoteKey.all`) → evdev key codes (linux/input-event-codes.h) at
//! their US physical positions, the modifier bits → the left modifier keys, and the state machine that keeps what the phone
//! holds really held, in the order a keyboard would press it. Pure: the portal half (input.rs) only sends what this returns,
//! so the order and the "never leave one stuck" rule are tested on any machine.
//!
//! The order follows RemoteInput.swift: modifiers down first (Ctrl, Alt, Shift, Super), then the key, then up in reverse.
//! GNOME reads the real sequence: a lone Super down + up opens Activities exactly as a real tap does; Super held across a
//! key doesn't.

use crate::host::{mods, Button, SystemMove};

/// One key event for the portal: an evdev code and down (true) / up.
pub type KeyEvent = (i32, bool);

pub const KEY_ESC: i32 = 1;
pub const KEY_BACKSPACE: i32 = 14;
pub const KEY_TAB: i32 = 15;
pub const KEY_ENTER: i32 = 28;
pub const KEY_LEFTCTRL: i32 = 29;
pub const KEY_LEFTSHIFT: i32 = 42;
pub const KEY_LEFTALT: i32 = 56;
pub const KEY_SPACE: i32 = 57;
pub const KEY_V: i32 = 47;
pub const KEY_LEFTMETA: i32 = 125;

pub const BTN_LEFT: i32 = 0x110;
pub const BTN_RIGHT: i32 = 0x111;
pub const BTN_MIDDLE: i32 = 0x112;

/// The four modifier bits that exist here, in the order they go down. FUNCTION (Apple only) is dropped.
pub const MOD_KEYS: [(u8, i32); 4] =
    [(mods::CONTROL, KEY_LEFTCTRL), (mods::OPTION, KEY_LEFTALT), (mods::SHIFT, KEY_LEFTSHIFT), (mods::COMMAND, KEY_LEFTMETA)];
const MOD_MASK: u8 = mods::CONTROL | mods::OPTION | mods::SHIFT | mods::COMMAND;

/// Every wire key name and its evdev code. Letters and punctuation are physical positions on a US keyboard, as on the Mac
/// (kVK_ANSI_*): the user's layout decides what they type, which is what a shortcut wants (Ctrl+Z is the same key in AZERTY's
/// Ctrl+W spot on both computers).
pub const KEYS: &[(&str, i32)] = &[
    ("A", 30), ("B", 48), ("C", 46), ("D", 32), ("E", 18), ("F", 33), ("G", 34), ("H", 35), ("I", 23), ("J", 36),
    ("K", 37), ("L", 38), ("M", 50), ("N", 49), ("O", 24), ("P", 25), ("Q", 16), ("R", 19), ("S", 31), ("T", 20),
    ("U", 22), ("V", 47), ("W", 17), ("X", 45), ("Y", 21), ("Z", 44),
    ("1", 2), ("2", 3), ("3", 4), ("4", 5), ("5", 6), ("6", 7), ("7", 8), ("8", 9), ("9", 10), ("0", 11),
    ("F1", 59), ("F2", 60), ("F3", 61), ("F4", 62), ("F5", 63), ("F6", 64), ("F7", 65), ("F8", 66), ("F9", 67), ("F10", 68),
    ("F11", 87), ("F12", 88),
    ("Return", KEY_ENTER), ("Tab", KEY_TAB), ("Space", KEY_SPACE), ("Delete", KEY_BACKSPACE), ("Escape", KEY_ESC),
    ("ForwardDelete", 111), ("Left", 105), ("Right", 106), ("Down", 108), ("Up", 103),
    ("Home", 102), ("End", 107), ("PageUp", 104), ("PageDown", 109),
    ("-", 12), ("=", 13), ("[", 26), ("]", 27), (";", 39), ("'", 40), (",", 51), (".", 52), ("/", 53), ("\\", 43), ("`", 41),
];

pub fn key_code(name: &str) -> Option<i32> {
    KEYS.iter().find(|(n, _)| *n == name).map(|(_, c)| *c)
}

pub fn button_code(b: Button) -> i32 {
    match b {
        Button::Left => BTN_LEFT,
        Button::Right => BTN_RIGHT,
        Button::Middle => BTN_MIDDLE,
    }
}

/// What each named move presses on GNOME (docs/design/remote-protocol.md §Hosts): (modifiers, key name, "" = the modifiers alone).
pub fn system_chord(m: SystemMove) -> (u8, &'static str) {
    match m {
        // Super alone: the Activities overview, all windows
        SystemMove::MissionControl => (mods::COMMAND, ""),
        // Super+` (switch-group): the next window of the app in front
        SystemMove::AppExpose => (mods::COMMAND, "`"),
        // GNOME's own defaults; Ctrl+Alt+←/→ too, but terminals take those
        SystemMove::SpaceLeft => (mods::COMMAND, "PageUp"),
        SystemMove::SpaceRight => (mods::COMMAND, "PageDown"),
        SystemMove::ZoomIn => (mods::CONTROL, "="),
        SystemMove::ZoomOut => (mods::CONTROL, "-"),
        // a lone Ctrl: GNOME's "Locate Pointer" when it's on (Settings → Accessibility), else nothing
        SystemMove::FindCursor => (mods::CONTROL, ""),
    }
}

/// What the phone holds on this computer: sticky modifiers, keys held across calls (Alt during Alt+Tab), and which
/// modifier keys are really down now. Each call returns the events that make the computer match.
#[derive(Default, Debug)]
pub struct Keyboard {
    sticky: u8,
    /// held keys by id (the key's name, or "mods:<bits>" for modifiers alone), with the modifiers they brought, in order
    held: Vec<(String, u8, Option<i32>)>,
    down: u8,
}

impl Keyboard {
    pub fn down_mods(&self) -> u8 {
        self.down
    }

    pub fn holds_anything(&self) -> bool {
        self.down != 0 || !self.held.is_empty()
    }

    fn all_held(&self) -> u8 {
        self.held.iter().fold(self.sticky, |m, (_, h, _)| m | h)
    }

    /// Down what `want` has and isn't down (Ctrl first), then up what's down and isn't wanted (Super first).
    fn sync(&mut self, want: u8, out: &mut Vec<KeyEvent>) {
        let want = want & MOD_MASK;
        for (bit, code) in MOD_KEYS {
            if want & bit != 0 && self.down & bit == 0 {
                self.down |= bit;
                out.push((code, true));
            }
        }
        for (bit, code) in MOD_KEYS.iter().rev() {
            if want & bit == 0 && self.down & bit != 0 {
                self.down &= !bit;
                out.push((*code, false));
            }
        }
    }

    /// Press and release one key with `m` around it, on top of what's held. "" taps the modifiers alone (Super alone: the
    /// overview). An unknown name does nothing.
    pub fn press(&mut self, name: &str, m: u8) -> Vec<KeyEvent> {
        let mut out = vec![];
        let code = if name.is_empty() {
            None
        } else {
            match key_code(name) {
                Some(c) => Some(c),
                None => return out,
            }
        };
        let keep = self.all_held();
        self.sync(keep | m, &mut out);
        if let Some(c) = code {
            out.push((c, true));
            out.push((c, false));
        }
        self.sync(keep, &mut out);
        out
    }

    /// Hold a key (and its modifiers) down across calls, or let it go. Twice down is once; up without down is nothing.
    pub fn hold(&mut self, name: &str, m: u8, down: bool) -> Vec<KeyEvent> {
        let mut out = vec![];
        let code = if name.is_empty() {
            None
        } else {
            match key_code(name) {
                Some(c) => Some(c),
                None => return out,
            }
        };
        let id = if name.is_empty() { format!("mods:{}", m & MOD_MASK) } else { name.to_string() };
        if down {
            if self.held.iter().any(|(i, _, _)| *i == id) {
                return out;
            }
            self.held.push((id, m & MOD_MASK, code));
            let want = self.all_held();
            self.sync(want, &mut out);
            if let Some(c) = code {
                out.push((c, true));
            }
        } else {
            let Some(at) = self.held.iter().position(|(i, _, _)| *i == id) else { return out };
            let (_, _, code) = self.held.remove(at);
            if let Some(c) = code {
                out.push((c, false));
            }
            let want = self.all_held();
            self.sync(want, &mut out);
        }
        out
    }

    /// The phone's sticky modifiers: down until changed.
    pub fn set_sticky(&mut self, m: u8) -> Vec<KeyEvent> {
        self.sticky = m & MOD_MASK;
        let mut out = vec![];
        let want = self.all_held();
        self.sync(want, &mut out);
        out
    }

    /// Everything up: held keys (latest first), then the modifiers. Safe twice.
    pub fn release_all(&mut self) -> Vec<KeyEvent> {
        let mut out = vec![];
        while let Some((_, _, code)) = self.held.pop() {
            if let Some(c) = code {
                out.push((c, false));
            }
        }
        self.sticky = 0;
        self.sync(0, &mut out);
        out
    }

    /// The portal session went away (or was replaced): nothing is down on the computer any more.
    pub fn forget(&mut self) {
        *self = Self::default();
    }
}

/// How text from the phone gets in.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum TextStep {
    /// an X keysym: the compositor finds it on the user's own layout (and adds Shift), so `@` is `@` on any keyboard
    Keysym(i32),
    /// a key by code (Return, Tab)
    Key(i32),
    /// through the clipboard, as the desktop app's dictation does: anything not ASCII (CJK, accents, emoji: mutter drops
    /// keysyms that aren't on the layout), anything long, and anything while an input method would turn keys into composition
    Paste(String),
}

/// Typed key by key up to this many characters; longer is pasted (one paste is faster than 65 round trips).
pub const TYPE_MAX: usize = 64;

pub fn plan_text(text: &str, input_method: bool) -> Vec<TextStep> {
    if text.is_empty() {
        return vec![];
    }
    let plain = text.chars().all(|c| c.is_ascii_graphic() || matches!(c, ' ' | '\n' | '\t' | '\r'));
    if input_method || !plain || text.chars().count() > TYPE_MAX {
        return vec![TextStep::Paste(text.to_string())];
    }
    let mut out = vec![];
    let mut chars = text.chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            '\r' => {
                // \r\n is one Return
                if chars.peek() != Some(&'\n') {
                    out.push(TextStep::Key(KEY_ENTER));
                }
            }
            '\n' => out.push(TextStep::Key(KEY_ENTER)),
            '\t' => out.push(TextStep::Key(KEY_TAB)),
            // Latin-1 keysyms are the code points (X11 keysymdef.h): ' ' is XK_space 0x20 … '~' XK_asciitilde 0x7e
            c => out.push(TextStep::Keysym(c as i32)),
        }
    }
    out
}

/// GNOME's current input source is an input method (IBus: Pinyin, Anthy, Hangul…), from
/// `gsettings get org.gnome.desktop.input-sources mru-sources` (the first is the one in use; `sources` when that's empty).
pub fn input_method_active(mru_sources: &str, sources: &str) -> bool {
    let first = |s: &str| -> Option<String> {
        let s = s.trim().trim_start_matches("@a(ss)").trim();
        let open = s.find('(')?;
        let close = s[open..].find(')')? + open;
        Some(s[open + 1..close].to_string())
    };
    let pick = first(mru_sources).or_else(|| first(sources));
    pick.is_some_and(|p| p.trim_start().trim_start_matches(['\'', '"']).starts_with("ibus"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::host::mods::*;

    #[test]
    fn every_wire_key_has_a_code_and_codes_are_unique() {
        // the reference list, from the Swift source both phone apps follow
        let swift = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../skills/blurt/recorder/macos/Sources/BlurtRemoteKit/RemoteKeys.swift");
        let names: Vec<String> = match std::fs::read_to_string(&swift) {
            Ok(src) => {
                let mut names = vec![];
                let body = &src[src.find("public static let all").expect("RemoteKey.all")..];
                let body = &body[..body.find("return t").expect("end of RemoteKey.all")];
                // every string literal: ("A", 0) pairs, k("Return", 36, "↩") calls. Glyphs are skipped (not ASCII, or "esc"),
                // and F1…F12 are built from a count ("F\(…)")
                for (i, seg) in body.split('"').enumerate() {
                    if i % 2 == 0 || seg == "esc" || seg.contains("\\(") || !seg.is_ascii() {
                        continue;
                    }
                    names.push(if seg == "\\\\" { "\\".to_string() } else { seg.to_string() });
                }
                names.extend((1..=12).map(|i| format!("F{i}")));
                names
            }
            Err(_) => KEYS.iter().map(|(n, _)| n.to_string()).collect(),
        };
        for n in &names {
            assert!(key_code(n).is_some(), "no evdev code for wire key {n:?}");
        }
        assert_eq!(names.len(), KEYS.len(), "the wire has {} keys, the table {}", names.len(), KEYS.len());
        let mut codes: Vec<i32> = KEYS.iter().map(|(_, c)| *c).collect();
        codes.sort();
        codes.dedup();
        assert_eq!(codes.len(), KEYS.len(), "two names share a code");
    }

    #[test]
    fn known_positions() {
        assert_eq!(key_code("A"), Some(30));
        assert_eq!(key_code("Z"), Some(44));
        assert_eq!(key_code("0"), Some(11));
        assert_eq!(key_code("Delete"), Some(KEY_BACKSPACE));
        assert_eq!(key_code("ForwardDelete"), Some(111));
        assert_eq!(key_code("`"), Some(41));
        assert_eq!(key_code("\\"), Some(43));
        assert_eq!(key_code("F12"), Some(88));
        assert_eq!(key_code("Enter"), None);
    }

    #[test]
    fn a_chord_goes_down_in_order_and_up_in_reverse() {
        let mut k = Keyboard::default();
        let ev = k.press("C", CONTROL | SHIFT);
        assert_eq!(ev, vec![(KEY_LEFTCTRL, true), (KEY_LEFTSHIFT, true), (46, true), (46, false), (KEY_LEFTSHIFT, false), (KEY_LEFTCTRL, false)]);
        assert!(!k.holds_anything());
    }

    #[test]
    fn a_lone_super_tap_is_down_then_up_with_nothing_between() {
        let mut k = Keyboard::default();
        assert_eq!(k.press("", COMMAND), vec![(KEY_LEFTMETA, true), (KEY_LEFTMETA, false)]);
        let (m, key) = system_chord(SystemMove::MissionControl);
        assert_eq!(k.press(key, m), vec![(KEY_LEFTMETA, true), (KEY_LEFTMETA, false)]);
        assert!(!k.holds_anything());
    }

    #[test]
    fn function_bit_and_unknown_keys_press_nothing() {
        let mut k = Keyboard::default();
        assert_eq!(k.press("", FUNCTION), vec![]);
        assert_eq!(k.press("Bogus", CONTROL), vec![]);
        assert_eq!(k.hold("Bogus", CONTROL, true), vec![]);
        assert!(!k.holds_anything());
    }

    #[test]
    fn alt_tab_held_steps_and_lets_go() {
        let mut k = Keyboard::default();
        // the cycle key: Alt held, Tab stepped, Alt let go on lift
        assert_eq!(k.hold("", OPTION, true), vec![(KEY_LEFTALT, true)]);
        assert_eq!(k.press("Tab", 0), vec![(KEY_TAB, true), (KEY_TAB, false)]);
        assert_eq!(k.press("Tab", SHIFT), vec![(KEY_LEFTSHIFT, true), (KEY_TAB, true), (KEY_TAB, false), (KEY_LEFTSHIFT, false)]);
        assert_eq!(k.hold("", OPTION, true), vec![], "twice down is once");
        assert_eq!(k.hold("", OPTION, false), vec![(KEY_LEFTALT, false)]);
        assert_eq!(k.hold("", OPTION, false), vec![]);
        assert!(!k.holds_anything());
    }

    #[test]
    fn a_held_key_with_modifiers() {
        let mut k = Keyboard::default();
        assert_eq!(k.hold("Tab", OPTION, true), vec![(KEY_LEFTALT, true), (KEY_TAB, true)]);
        assert_eq!(k.hold("Tab", OPTION, false), vec![(KEY_TAB, false), (KEY_LEFTALT, false)]);
    }

    #[test]
    fn sticky_modifiers_stay_down_across_keys() {
        let mut k = Keyboard::default();
        assert_eq!(k.set_sticky(CONTROL), vec![(KEY_LEFTCTRL, true)]);
        // Ctrl is already down: only the key
        assert_eq!(k.press("V", CONTROL), vec![(47, true), (47, false)]);
        assert_eq!(k.down_mods(), CONTROL);
        assert_eq!(k.set_sticky(CONTROL | SHIFT), vec![(KEY_LEFTSHIFT, true)]);
        assert_eq!(k.set_sticky(0), vec![(KEY_LEFTSHIFT, false), (KEY_LEFTCTRL, false)]);
    }

    #[test]
    fn release_all_leaves_nothing_down_and_is_safe_twice() {
        let mut k = Keyboard::default();
        k.set_sticky(COMMAND);
        k.hold("Tab", OPTION, true);
        k.hold("", SHIFT, true);
        let ev = k.release_all();
        assert_eq!(ev, vec![(KEY_TAB, false), (KEY_LEFTMETA, false), (KEY_LEFTSHIFT, false), (KEY_LEFTALT, false)], "up in reverse: Super first");
        assert!(!k.holds_anything());
        assert_eq!(k.release_all(), vec![]);
        // and every key that went down came up
        let mut k = Keyboard::default();
        let mut all = vec![];
        all.extend(k.set_sticky(CONTROL | OPTION | SHIFT | COMMAND));
        all.extend(k.hold("A", 0, true));
        all.extend(k.press("B", CONTROL));
        all.extend(k.release_all());
        let mut down = std::collections::HashSet::new();
        for (c, d) in all {
            if d {
                assert!(down.insert(c), "{c} down twice");
            } else {
                assert!(down.remove(&c), "{c} up without down");
            }
        }
        assert!(down.is_empty(), "left down: {down:?}");
    }

    #[test]
    fn system_moves_are_gnome_shortcuts() {
        let mut k = Keyboard::default();
        let (m, key) = system_chord(SystemMove::SpaceRight);
        assert_eq!(k.press(key, m), vec![(KEY_LEFTMETA, true), (109, true), (109, false), (KEY_LEFTMETA, false)]);
        let (m, key) = system_chord(SystemMove::ZoomIn);
        assert_eq!(k.press(key, m), vec![(KEY_LEFTCTRL, true), (13, true), (13, false), (KEY_LEFTCTRL, false)]);
        for s in [SystemMove::MissionControl, SystemMove::AppExpose, SystemMove::SpaceLeft, SystemMove::ZoomOut, SystemMove::FindCursor] {
            let (_, key) = system_chord(s);
            assert!(key.is_empty() || key_code(key).is_some(), "{s:?}");
        }
    }

    #[test]
    fn text_is_typed_as_keysyms_or_pasted() {
        assert_eq!(plan_text("a@ ~", false), vec![TextStep::Keysym(0x61), TextStep::Keysym(0x40), TextStep::Keysym(0x20), TextStep::Keysym(0x7e)]);
        assert_eq!(plan_text("a\r\nb\t", false), vec![TextStep::Keysym(0x61), TextStep::Key(KEY_ENTER), TextStep::Keysym(0x62), TextStep::Key(KEY_TAB)]);
        assert_eq!(plan_text("café", false), vec![TextStep::Paste("café".into())]);
        assert_eq!(plan_text("这个feature", false), vec![TextStep::Paste("这个feature".into())]);
        assert_eq!(plan_text("ls", true), vec![TextStep::Paste("ls".into())], "an input method would compose it");
        let long = "x".repeat(TYPE_MAX + 1);
        assert_eq!(plan_text(&long, false), vec![TextStep::Paste(long.clone())]);
        assert_eq!(plan_text("", false), vec![]);
    }

    #[test]
    fn input_method_from_gsettings() {
        assert!(input_method_active("[('ibus', 'libpinyin'), ('xkb', 'us')]", "[('xkb', 'us')]"));
        assert!(!input_method_active("[('xkb', 'us'), ('ibus', 'libpinyin')]", ""));
        assert!(!input_method_active("@a(ss) []", "[('xkb', 'de')]"));
        assert!(input_method_active("@a(ss) []", "[('ibus', 'anthy')]"));
        assert!(!input_method_active("", ""));
    }
}
