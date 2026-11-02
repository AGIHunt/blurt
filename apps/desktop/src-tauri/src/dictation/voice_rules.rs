//! A voice note's pure rules, ported from the Mac's BlurtCore (`VoiceNoteStyle.swift`: LoneShift, VoiceNoteStructure;
//! `CaptureRules.swift`: VoiceKeep, VoiceDiscard) with their tests (VoiceNoteStyleTests, CaptureRulesTests). voice.rs
//! (Windows) acts on them.
//!
//!   LoneShift          Structured for a note, as dictation's: Shift double-tapped alone while the note listens (or,
//!                      with `record.dictation.modifier_tap` = single, one Shift let go within 1 s). The voice-note
//!                      hotkey itself never counts (its Shift goes down with Alt held), nor a capital letter, nor a
//!                      Shift-click. Windows repeats a held key's down events: a repeat is the same press.
//!   VoiceNoteStructure what the card keeps when it was Structured: the structured text as its note, the transcript as
//!                      heard beside it (`said_raw`) — only when the two differ
//!   VoiceKeep          what becomes of a note that ended: kept, discarded with Undo (Esc after something was said),
//!                      "No sound detected · Keep" (a note the user ended in which nothing was heard), or dropped
//!   VoiceDiscard       a discarded note's wav waits for its Undo as NNN.discarded.wav: a quit or a crash then never
//!                      brings it back as a note

use super::trigger::{vk, DictationTrigger, ModifierTap};

/// Shift alone, for a voice note's Structured toggle.
#[derive(Clone, Debug)]
pub struct LoneShift {
    /// single mode: a Shift held longer than this is a finger resting on it, not a toggle
    pub tap_max: f64,
    pub mode: ModifierTap,
    pub double_tap_window: f64,
    pub cooldown: f64,
    down_at: Option<f64>,
    last_tap_at: Option<f64>,
    cooldown_until: f64,
    /// Ctrl, Alt, Win held (by VK code); Shift itself
    others: u8,
    shift_held: bool,
}

impl Default for LoneShift {
    fn default() -> Self {
        LoneShift {
            tap_max: 1.0,
            mode: DictationTrigger::SHIPPED_MODIFIER_TAP,
            double_tap_window: DictationTrigger::SHIPPED_DOUBLE_TAP_WINDOW,
            cooldown: DictationTrigger::SHIPPED_MODIFIER_COOLDOWN,
            down_at: None,
            last_tap_at: None,
            cooldown_until: 0.0,
            others: 0,
            shift_held: false,
        }
    }
}

fn other_bit(code: u32) -> Option<u8> {
    match code {
        vk::LCONTROL | vk::RCONTROL | 0x11 => Some(1),
        vk::LMENU | vk::RMENU | 0x12 => Some(2),
        vk::LWIN | vk::RWIN => Some(4),
        _ => None,
    }
}

impl LoneShift {
    pub fn new() -> Self {
        Self::default()
    }

    /// One key down / up at `t` (seconds). true: this event asked for the toggle — the second Shift press of a double
    /// tap, or (single mode) the release of one Shift.
    pub fn key(&mut self, code: u32, down: bool, t: f64) -> bool {
        if let Some(bit) = other_bit(code) {
            if down {
                self.others |= bit;
            } else {
                self.others &= !bit;
            }
            // another modifier joining is a chord: neither a tap nor the first of two
            self.down_at = None;
            self.last_tap_at = None;
            return false;
        }
        let shift = code == vk::LSHIFT || code == vk::RSHIFT || code == 0x10;
        if !shift {
            if down {
                // a letter (a capital), Enter …: no toggle
                self.down_at = None;
                self.last_tap_at = None;
            }
            return false;
        }
        let alone = self.others == 0;
        if down {
            if self.shift_held {
                return false; // the key's auto-repeat
            }
            self.shift_held = true;
            if !alone {
                self.down_at = None;
                self.last_tap_at = None;
                return false;
            }
            if self.mode != ModifierTap::Double {
                self.down_at = Some(t);
                return false;
            }
            if t < self.cooldown_until {
                self.last_tap_at = None;
                return false;
            }
            if let Some(l) = self.last_tap_at {
                if t - l <= self.double_tap_window {
                    self.last_tap_at = None;
                    self.cooldown_until = t + self.cooldown;
                    return true;
                }
            }
            self.last_tap_at = Some(t);
            return false;
        }
        self.shift_held = false;
        if !alone {
            self.down_at = None;
            self.last_tap_at = None;
            return false;
        }
        if self.mode == ModifierTap::Single {
            let d = self.down_at.take();
            return d.is_some_and(|d| t - d <= self.tap_max);
        }
        false // double: the fire was on the second press
    }

    /// A click: no toggle from a Shift-click.
    pub fn mouse_down(&mut self) {
        self.down_at = None;
        self.last_tap_at = None;
    }

    /// Forget a Shift half pressed (the note ended).
    pub fn reset(&mut self) {
        *self = LoneShift { mode: self.mode, tap_max: self.tap_max, double_tap_window: self.double_tap_window, cooldown: self.cooldown, ..LoneShift::default() };
    }
}

/// What a voice note's card keeps when it was Structured: (`said`, `said_raw`).
pub fn structure_keep(raw: &str, structured: Option<&str>) -> (String, Option<String>) {
    let r = raw.trim().to_string();
    match structured.map(str::trim) {
        Some(s) if !s.is_empty() && s != r => (s.to_string(), Some(r)),
        _ => (r, None),
    }
}

/// How a note ended.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Ended {
    /// the key again, Done, letting go of a held key, Blurt quitting
    User,
    /// Esc
    Cancel,
    /// nothing heard within the no-speech time
    NoSpeech,
    /// the pause after speech (end on pause)
    Silence,
    /// the maximum length
    Maxed,
}

/// What the island says when nothing is kept.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum KeepToast {
    None,
    Nothing,
    CheckMic,
}

/// What becomes of a note that ended.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum VoiceKeep {
    Keep,
    /// discarded with "Voice note discarded · Undo"
    Undoable,
    /// nothing was heard in a take the user ended: "No sound detected · Keep" — the audio waits for the answer
    Unsure,
    Drop(KeepToast),
}

impl VoiceKeep {
    /// A take shorter than this the user ended is a slip of the key, not a note.
    pub const MIN_USER_SECONDS: f64 = 1.5;
    /// A take with less held sound above the room than this is the room alone (a fan, a hum, a muted input).
    pub const MIN_SOUND_SECONDS: f64 = 0.4;
    /// Below this peak a take is digital silence (a muted input): nothing to keep.
    pub const SILENCE_PEAK_DB: f64 = -60.0;

    /// `heard_speech`: speech was heard (a piece had speech in it); `sound_seconds`: how long the take held a sound
    /// above the room; `peak_db`: its loudest moment.
    pub fn decide(ended: Ended, heard_speech: bool, seconds: f64, sound_seconds: f64, peak_db: f64) -> VoiceKeep {
        let sound = seconds >= Self::MIN_USER_SECONDS && sound_seconds >= Self::MIN_SOUND_SECONDS;
        let ask = seconds >= Self::MIN_USER_SECONDS && peak_db > Self::SILENCE_PEAK_DB;
        match ended {
            Ended::Cancel => {
                if heard_speech {
                    VoiceKeep::Undoable
                } else {
                    VoiceKeep::Drop(KeepToast::None)
                }
            }
            Ended::NoSpeech => VoiceKeep::Drop(KeepToast::CheckMic),
            Ended::User | Ended::Maxed => {
                if heard_speech || sound {
                    VoiceKeep::Keep
                } else if ask {
                    VoiceKeep::Unsure
                } else {
                    VoiceKeep::Drop(KeepToast::Nothing)
                }
            }
            Ended::Silence => {
                if heard_speech || sound {
                    VoiceKeep::Keep
                } else {
                    VoiceKeep::Drop(KeepToast::Nothing)
                }
            }
        }
    }
}

/// How long "Voice note discarded · Undo" can bring a cancelled note back (its audio is kept until then).
pub const UNDO_SECONDS: f64 = 5.0;
/// How long "No sound detected · Keep" waits.
pub const UNSURE_SECONDS: f64 = 6.0;

/// shots/005.wav → shots/005.discarded.wav
pub fn parked(file: &str) -> String {
    match file.strip_suffix(".wav") {
        Some(b) => format!("{b}.discarded.wav"),
        None => format!("{file}.discarded.wav"),
    }
}

pub fn is_parked(name: &str) -> bool {
    name.ends_with(".discarded.wav")
}

#[cfg(test)]
mod tests {
    use super::*;

    const S: u32 = vk::LSHIFT;

    /// VoiceNoteStyleTests.testDoubleShiftToggles
    #[test]
    fn a_double_shift_toggles() {
        let mut l = LoneShift::new();
        assert!(!l.key(S, true, 1.0));
        assert!(!l.key(S, false, 1.08));
        assert!(l.key(S, true, 1.25)); // the second press
        assert!(!l.key(S, false, 1.3));
        // the cooldown: a third press right after doesn't start another
        assert!(!l.key(S, true, 1.4));
        assert!(!l.key(S, false, 1.45));
        // too far apart: nothing
        let mut m = LoneShift::new();
        m.key(S, true, 1.0);
        m.key(S, false, 1.1);
        assert!(!m.key(S, true, 2.0));
    }

    #[test]
    fn one_shift_is_nothing_in_double_mode_but_a_toggle_in_single() {
        let mut d = LoneShift::new();
        assert!(!d.key(S, true, 1.0));
        assert!(!d.key(S, false, 1.1));
        let mut s = LoneShift { mode: ModifierTap::Single, ..LoneShift::new() };
        assert!(!s.key(S, true, 1.0));
        assert!(s.key(S, false, 1.2));
        // held: a finger resting on it
        assert!(!s.key(S, true, 2.0));
        assert!(!s.key(S, false, 3.5));
    }

    #[test]
    fn a_held_shift_repeats_are_one_press() {
        let mut l = LoneShift::new();
        assert!(!l.key(S, true, 1.0));
        assert!(!l.key(S, true, 1.05)); // Windows' auto-repeat
        assert!(!l.key(S, true, 1.1));
        assert!(!l.key(S, false, 1.15));
        assert!(l.key(S, true, 1.3));
    }

    /// VoiceNoteStyleTests.testChordsAndCapitalsDontCount
    #[test]
    fn chords_capitals_and_clicks_dont_count() {
        // the voice-note hotkey (Alt+Shift+V): Shift goes down with Alt held
        let mut l = LoneShift::new();
        l.key(vk::LMENU, true, 1.0);
        assert!(!l.key(S, true, 1.01));
        l.key(S, false, 1.05);
        l.key(vk::LMENU, false, 1.06);
        assert!(!l.key(S, true, 1.2)); // the first lone press after the chord, not a second one
        // a capital letter between the two presses
        let mut c = LoneShift::new();
        c.key(S, true, 1.0);
        c.key(0x41, true, 1.05);
        c.key(0x41, false, 1.08);
        c.key(S, false, 1.1);
        assert!(!c.key(S, true, 1.2));
        // a Shift-click
        let mut k = LoneShift::new();
        k.key(S, true, 1.0);
        k.key(S, false, 1.05);
        k.mouse_down();
        assert!(!k.key(S, true, 1.2));
        // either Shift counts
        let mut r = LoneShift::new();
        r.key(vk::RSHIFT, true, 1.0);
        r.key(vk::RSHIFT, false, 1.05);
        assert!(r.key(vk::LSHIFT, true, 1.2));
    }

    /// VoiceNoteStyleTests.testStructureKeep
    #[test]
    fn what_a_structured_note_keeps() {
        assert_eq!(structure_keep(" a b ", Some("- a\n- b")), ("- a\n- b".to_string(), Some("a b".to_string())));
        assert_eq!(structure_keep("a b", Some("a b")), ("a b".to_string(), None));
        assert_eq!(structure_keep("a b", Some("  ")), ("a b".to_string(), None));
        assert_eq!(structure_keep("a b", None), ("a b".to_string(), None));
    }

    /// CaptureRulesTests.testVoiceKeep
    #[test]
    fn what_becomes_of_a_note() {
        use VoiceKeep::*;
        assert_eq!(VoiceKeep::decide(Ended::Cancel, true, 3.0, 1.0, -20.0), Undoable);
        assert_eq!(VoiceKeep::decide(Ended::Cancel, false, 3.0, 0.0, -20.0), Drop(KeepToast::None));
        assert_eq!(VoiceKeep::decide(Ended::NoSpeech, false, 20.0, 0.0, -70.0), Drop(KeepToast::CheckMic));
        assert_eq!(VoiceKeep::decide(Ended::User, true, 3.0, 1.0, -20.0), Keep);
        assert_eq!(VoiceKeep::decide(Ended::User, false, 3.0, 0.5, -30.0), Keep); // sound the segmenter missed
        assert_eq!(VoiceKeep::decide(Ended::User, false, 3.0, 0.1, -40.0), Unsure); // a fan? ask
        assert_eq!(VoiceKeep::decide(Ended::User, false, 3.0, 0.0, -75.0), Drop(KeepToast::Nothing)); // digital silence
        assert_eq!(VoiceKeep::decide(Ended::User, false, 1.0, 0.0, -30.0), Drop(KeepToast::Nothing)); // a slip of the key
        assert_eq!(VoiceKeep::decide(Ended::Maxed, true, 600.0, 100.0, -20.0), Keep);
        assert_eq!(VoiceKeep::decide(Ended::Silence, false, 3.0, 0.1, -40.0), Drop(KeepToast::Nothing));
    }

    #[test]
    fn a_discarded_note_waits_under_another_name() {
        assert_eq!(parked("shots/005.wav"), "shots/005.discarded.wav");
        assert!(is_parked("005.discarded.wav"));
        assert!(!is_parked("005.wav"));
    }
}
