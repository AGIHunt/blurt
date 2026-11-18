//! What the phone holds down, and the key events that follow from each call: the Mac's RemoteInput bookkeeping
//! (`syncMods`, `press`, `hold`, `setSticky`, `releaseAll`), as a pure state machine so it's tested without a keyboard.
//!
//! * Keys go down and up as a keyboard's would: modifiers first, then the key, then back up in reverse. Apps and Windows'
//!   own shortcuts (Alt+Tab, Win+Tab) read the real sequence.
//! * A modifier is down while anything holds it (the sticky ones, a held chord) and comes up when the last lets go, so
//!   nothing is ever left down: `release_all` lets go of all of it, and is safe twice.
//! * A lone Win tap (down, up, nothing between) opens Start, as a real one does. A Win or Alt held while a click or a scroll
//!   went through would also look like a lone tap when it comes up (Start opening after Win+click, the menu bar taking the
//!   focus after Alt+drag): those get the mask key first (keymap::MASK_KEY).

use super::keymap::{self, Key, MOD_KEYS, WINDOWS_MODS};
use crate::host::mods;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct KeyEvent {
    pub key: Key,
    pub down: bool,
}

#[derive(Default, Debug)]
pub struct Keyboard {
    sticky: u8,
    /// held chords by id (the key's name, or "mods:N" for modifiers alone), with the modifiers each holds
    held: Vec<(String, u8)>,
    /// the modifiers really down now
    down: u8,
    /// Win / Alt down while a click or a scroll happened: masked when they come up
    touched: u8,
}

const MASKED: u8 = mods::COMMAND | mods::OPTION;

impl Keyboard {
    pub fn down_mods(&self) -> u8 {
        self.down
    }

    fn all_held(&self) -> u8 {
        self.held.iter().fold(self.sticky, |a, (_, m)| a | m) & WINDOWS_MODS
    }

    /// Bring the modifiers really down to `want`, appending the events.
    fn sync(&mut self, want: u8, out: &mut Vec<KeyEvent>) {
        let want = want & WINDOWS_MODS;
        for (bit, key) in MOD_KEYS {
            if want & bit != 0 && self.down & bit == 0 {
                self.down |= bit;
                self.touched &= !bit;
                out.push(KeyEvent { key, down: true });
            }
        }
        for (bit, key) in MOD_KEYS.iter().rev() {
            if want & bit == 0 && self.down & bit != 0 {
                if self.touched & bit != 0 {
                    out.push(KeyEvent { key: keymap::MASK_KEY, down: true });
                    out.push(KeyEvent { key: keymap::MASK_KEY, down: false });
                    self.touched &= !bit;
                }
                self.down &= !bit;
                out.push(KeyEvent { key: *key, down: false });
            }
        }
    }

    /// A click or a scroll went through: any Win or Alt down now gets masked on its way up.
    pub fn pointer_used(&mut self) {
        self.touched |= self.down & MASKED;
    }

    /// Press and release `name` with `mods` (on top of whatever is held). "" taps the modifiers alone; unknown names do nothing.
    pub fn press(&mut self, name: &str, mods: u8) -> Vec<KeyEvent> {
        let key = keymap::key(name);
        if key.is_none() && !name.is_empty() {
            return Vec::new();
        }
        self.press_key(key, mods)
    }

    /// Press and release a key that isn't a wire name (the layout's own + and − for zoom), or the modifiers alone (None).
    pub fn press_key(&mut self, key: Option<Key>, mods: u8) -> Vec<KeyEvent> {
        let mut out = Vec::new();
        let keep = self.all_held();
        self.sync(keep | mods, &mut out);
        if let Some(k) = key {
            out.push(KeyEvent { key: k, down: true });
            out.push(KeyEvent { key: k, down: false });
        }
        self.sync(keep, &mut out);
        out
    }

    /// Hold (or let go of) a chord across calls: Alt during Alt+Tab, a repeating arrow.
    pub fn hold(&mut self, name: &str, mods: u8, down: bool) -> Vec<KeyEvent> {
        let mut out = Vec::new();
        let key = keymap::key(name);
        if key.is_none() && !name.is_empty() {
            return out;
        }
        let id = if name.is_empty() { format!("mods:{mods}") } else { name.to_string() };
        if down {
            if self.held.iter().any(|(i, _)| *i == id) {
                return out;
            }
            self.held.push((id, mods));
            let want = self.all_held();
            self.sync(want, &mut out);
            if let Some(k) = key {
                out.push(KeyEvent { key: k, down: true });
            }
        } else {
            let Some(i) = self.held.iter().position(|(i, _)| *i == id) else { return out };
            self.held.remove(i);
            if let Some(k) = key {
                out.push(KeyEvent { key: k, down: false });
            }
            let want = self.all_held();
            self.sync(want, &mut out);
        }
        out
    }

    /// The phone's sticky modifiers: really down until changed.
    pub fn set_sticky(&mut self, mods: u8) -> Vec<KeyEvent> {
        let mut out = Vec::new();
        self.sticky = mods & WINDOWS_MODS;
        let want = self.all_held();
        self.sync(want, &mut out);
        out
    }

    /// Everything up: held keys, then the modifiers.
    pub fn release_all(&mut self) -> Vec<KeyEvent> {
        let mut out = Vec::new();
        for (id, _) in std::mem::take(&mut self.held) {
            if let Some(k) = keymap::key(&id) {
                out.push(KeyEvent { key: k, down: false });
            }
        }
        self.sticky = 0;
        self.sync(0, &mut out);
        out
    }

    /// Modifiers to let go of around a paste (Ctrl+V must not be Win+V, the clipboard history, or Alt+V, a menu), and the events
    /// that put them back afterwards. Ctrl stays as it is.
    pub fn around_paste(&self) -> (Vec<KeyEvent>, Vec<KeyEvent>) {
        let lift = self.down & !mods::CONTROL;
        let mut up = Vec::new();
        let mut again = Vec::new();
        for (bit, key) in MOD_KEYS.iter().rev() {
            if lift & bit != 0 {
                if *bit & MASKED != 0 {
                    up.push(KeyEvent { key: keymap::MASK_KEY, down: true });
                    up.push(KeyEvent { key: keymap::MASK_KEY, down: false });
                }
                up.push(KeyEvent { key: *key, down: false });
            }
        }
        for (bit, key) in MOD_KEYS {
            if lift & bit != 0 {
                again.push(KeyEvent { key, down: true });
            }
        }
        (up, again)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::host::mods::*;

    /// "Ctrl↓ C↓ C↑ Ctrl↑", with the mask key as "mask".
    fn show(evs: &[KeyEvent]) -> String {
        evs.iter()
            .map(|e| {
                let n = match e.key.vk {
                    keymap::VK_LCONTROL => "Ctrl".to_string(),
                    keymap::VK_LMENU => "Alt".to_string(),
                    keymap::VK_LSHIFT => "Shift".to_string(),
                    keymap::VK_LWIN => "Win".to_string(),
                    keymap::VK_MASK => "mask".to_string(),
                    keymap::VK_TAB => "Tab".to_string(),
                    keymap::VK_LEFT => "Left".to_string(),
                    vk if (0x41..=0x5A).contains(&vk) => (vk as u8 as char).to_string(),
                    vk => format!("{vk:#x}"),
                };
                format!("{n}{}", if e.down { "↓" } else { "↑" })
            })
            .collect::<Vec<_>>()
            .join(" ")
    }

    #[test]
    fn a_chord_goes_down_and_up_in_order() {
        let mut k = Keyboard::default();
        assert_eq!(show(&k.press("C", CONTROL)), "Ctrl↓ C↓ C↑ Ctrl↑");
        assert_eq!(show(&k.press("Z", CONTROL | SHIFT)), "Ctrl↓ Shift↓ Z↓ Z↑ Shift↑ Ctrl↑");
        assert_eq!(show(&k.press("D", COMMAND | OPTION | CONTROL | SHIFT)), "Ctrl↓ Alt↓ Shift↓ Win↓ D↓ D↑ Win↑ Shift↑ Alt↑ Ctrl↑");
        assert_eq!(k.down_mods(), 0);
    }

    #[test]
    fn a_lone_win_is_a_real_tap() {
        let mut k = Keyboard::default();
        // nothing between: Windows opens Start
        assert_eq!(show(&k.press("", COMMAND)), "Win↓ Win↑");
        assert_eq!(show(&k.press("", SHIFT)), "Shift↓ Shift↑");
    }

    #[test]
    fn function_and_unknown_do_nothing() {
        let mut k = Keyboard::default();
        assert_eq!(show(&k.press("C", FUNCTION)), "C↓ C↑");
        assert!(k.press("Nope", CONTROL).is_empty());
        assert!(k.hold("Nope", CONTROL, true).is_empty());
        assert_eq!(k.down_mods(), 0);
    }

    #[test]
    fn sticky_mods_stay_down_across_keys() {
        let mut k = Keyboard::default();
        assert_eq!(show(&k.set_sticky(CONTROL)), "Ctrl↓");
        assert_eq!(show(&k.press("C", 0)), "C↓ C↑");
        assert_eq!(show(&k.press("V", SHIFT)), "Shift↓ V↓ V↑ Shift↑");
        assert_eq!(show(&k.press("V", CONTROL)), "V↓ V↑");
        assert_eq!(show(&k.set_sticky(0)), "Ctrl↑");
    }

    #[test]
    fn alt_tab_held_and_stepped() {
        let mut k = Keyboard::default();
        // the cycle key: Alt held, Tab pressed for each step, Alt let go on lift
        assert_eq!(show(&k.hold("", OPTION, true)), "Alt↓");
        assert_eq!(show(&k.press("Tab", 0)), "Tab↓ Tab↑");
        assert_eq!(show(&k.press("Tab", SHIFT)), "Shift↓ Tab↓ Tab↑ Shift↑");
        // the same hold twice is one hold
        assert!(k.hold("", OPTION, true).is_empty());
        assert_eq!(show(&k.hold("", OPTION, false)), "Alt↑");
        // a release nobody holds does nothing
        assert!(k.hold("", OPTION, false).is_empty());
    }

    #[test]
    fn a_held_key_with_its_mods() {
        let mut k = Keyboard::default();
        assert_eq!(show(&k.hold("Left", SHIFT, true)), "Shift↓ Left↓");
        assert_eq!(show(&k.hold("Left", SHIFT, false)), "Left↑ Shift↑");
    }

    #[test]
    fn a_modifier_two_things_hold_comes_up_with_the_last() {
        let mut k = Keyboard::default();
        assert_eq!(show(&k.set_sticky(SHIFT)), "Shift↓");
        assert_eq!(show(&k.hold("Left", SHIFT, true)), "Left↓");
        assert_eq!(show(&k.set_sticky(0)), "");
        assert_eq!(show(&k.hold("Left", SHIFT, false)), "Left↑ Shift↑");
    }

    #[test]
    fn release_all_lets_go_of_everything_and_is_safe_twice() {
        let mut k = Keyboard::default();
        k.set_sticky(CONTROL | COMMAND);
        k.hold("Left", SHIFT, true);
        k.hold("", OPTION, true);
        assert_eq!(k.down_mods(), CONTROL | COMMAND | SHIFT | OPTION);
        assert_eq!(show(&k.release_all()), "Left↑ Win↑ Shift↑ Alt↑ Ctrl↑");
        assert_eq!(k.down_mods(), 0);
        assert!(k.release_all().is_empty());
        // and a later press is clean
        assert_eq!(show(&k.press("A", 0)), "A↓ A↑");
    }

    #[test]
    fn win_or_alt_held_through_a_click_is_masked_on_release() {
        let mut k = Keyboard::default();
        k.set_sticky(COMMAND);
        k.pointer_used();
        assert_eq!(show(&k.set_sticky(0)), "mask↓ mask↑ Win↑");
        // Alt held through a drag, Ctrl and Shift aren't masked: they don't do anything alone
        k.set_sticky(OPTION | SHIFT | CONTROL);
        k.pointer_used();
        assert_eq!(show(&k.set_sticky(0)), "Shift↑ mask↓ mask↑ Alt↑ Ctrl↑");
        // a fresh press after that is a fresh tap
        assert_eq!(show(&k.press("", COMMAND)), "Win↓ Win↑");
        // a click before the press doesn't count
        k.pointer_used();
        assert_eq!(show(&k.press("", COMMAND)), "Win↓ Win↑");
    }

    #[test]
    fn paste_lifts_everything_but_ctrl_and_puts_it_back() {
        let mut k = Keyboard::default();
        k.set_sticky(COMMAND | SHIFT | CONTROL);
        let (up, again) = k.around_paste();
        assert_eq!(show(&up), "mask↓ mask↑ Win↑ Shift↑");
        assert_eq!(show(&again), "Shift↓ Win↓");
        assert_eq!(k.down_mods(), COMMAND | SHIFT | CONTROL);
    }
}
