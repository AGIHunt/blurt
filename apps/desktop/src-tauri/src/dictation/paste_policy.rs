//! Where dictated text goes (docs/design/dictation.md §Insert), whether a double tap may press Return, and which
//! microphone dictation listens with — ported from the Mac's
//! `skills/blurt/recorder/macos/Sources/BlurtCore/DictationPastePolicy.swift` (tests: `DictationPastePolicyTests`, ported
//! below). Pure, so the rules are unit-tested.
//!
//! Paste: like Typeless, Ctrl+V goes to the app in front whenever it is another app and no password is being typed —
//! also when its focused element isn't a text control as far as the accessibility API can tell (WeChat's input box
//! isn't one, nor are many Electron and web editors). Refused only when:
//!   • there is no app in front;
//!   • Blurt itself is in front (its own text views get the text another way; panels get nothing);
//!   • a password is being typed (the Mac's secure event input; here the caller's reading — UI Automation's
//!     IsPassword on the focus, ES_PASSWORD), or the focus is a password field;
//!   • the paste can't reach the app (the Mac: Accessibility not granted; Windows: the window in front belongs to an
//!     elevated process and Blurt isn't, so UIPI drops the posted keys). The reason keeps the Mac's word,
//!     `no_accessibility`, so logs and lines read the same on both.
//! The app in front at paste time is the one that counts, also when it isn't the one the take started in (2026-10-31,
//! the founder: people speak while in A meaning to type into B). A double tap's queued Return goes after the paste there
//! too (`send::queued`), and ⌥C / ⌥T paste into the app in front by the same rule (`screen_text`). The user's clipboard
//! is put back after the paste either way.

/// What to do with a take's text.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Decision {
    /// Ctrl+V; `confirmed`: the focus is known to be a text field (else the island offers "Copy again")
    Paste { confirmed: bool },
    /// Blurt is in front: its own text view, or nothing
    Own,
    /// the text stays on the clipboard
    Copy { reason: &'static str },
    /// nothing typed, nothing copied: the text waits in the history and on the island's Copy (a password field has the
    /// focus — text said there by accident shouldn't land on the clipboard, where clipboard managers keep it; v0.9
    /// dogfood)
    Hold { reason: &'static str },
}

/// What the I/O layer reads at paste time.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Situation {
    pub has_front_app: bool,
    pub front_is_blurt: bool,
    /// a password is being typed somewhere (the Mac's IsSecureEventInputEnabled)
    pub secure_input: bool,
    /// a posted Ctrl+V would arrive (the Mac: Accessibility granted; Windows: not blocked by UIPI)
    pub accessibility: bool,
    /// the focused element is a password field (AXSecureTextField; UIA IsPassword)
    pub focus_secure: bool,
    /// the focused element is a text field as far as the accessibility API can tell (None: no element could be read)
    pub focus_is_text: Option<bool>,
}

impl Situation {
    pub fn new(
        has_front_app: bool,
        front_is_blurt: bool,
        secure_input: bool,
        accessibility: bool,
    ) -> Self {
        Situation {
            has_front_app,
            front_is_blurt,
            secure_input,
            accessibility,
            focus_secure: false,
            focus_is_text: None,
        }
    }
}

pub fn decide(s: &Situation) -> Decision {
    if !s.has_front_app {
        return Decision::Copy {
            reason: "no_front_app",
        };
    }
    if s.front_is_blurt {
        return Decision::Own;
    }
    if s.secure_input || s.focus_secure {
        return Decision::Hold {
            reason: "secure_input",
        };
    }
    if !s.accessibility {
        return Decision::Copy {
            reason: "no_accessibility",
        };
    }
    Decision::Paste {
        confirmed: s.focus_is_text == Some(true),
    }
}

/// When a posted Ctrl+V has landed, and when the user's clipboard may come back (v0.9 dogfood). The clipboard used to
/// come back on a fixed 0.6 s timer and a double tap's Return waited for that timer: a slow app (a busy Electron chat, a
/// machine under memory pressure) could read the clipboard after it was put back and paste — then send — the user's old
/// clipboard, and every send waited 0.6 s more than it needed. Now, where the field can be read, the text in it says when
/// the paste landed: Return goes at once and the clipboard comes back a moment later; where it can't (WeChat, Electron),
/// Return keeps the old 0.6 s (keys reach the app in order: Return after Ctrl+V) and the clipboard waits 1.5 s. Return
/// never waits longer than those 0.6 s: a readable field that never shows the text exactly (a rich-text or Electron field
/// that turns quotes or emoji into its own, or trims a space) only delays the clipboard (review).
pub mod landing {
    /// how often the field is read while waiting
    pub const POLL: f64 = 0.03;
    /// a readable field that never shows the text (it reformats it, or the paste went elsewhere): give up waiting
    pub const CONFIRM_TIMEOUT: f64 = 1.5;
    /// after the text is seen: the clipboard comes back this much later
    pub const RESTORE_MARGIN: f64 = 0.15;
    /// an unreadable field: Return after this (as before) …
    pub const UNCONFIRMED_RETURN: f64 = 0.6;
    /// … and the clipboard back after this
    pub const UNCONFIRMED_RESTORE: f64 = 1.5;

    /// When a double tap's Return goes, `seen` s after Ctrl+V the field showed the text (None: not seen, or
    /// unreadable): then, or after `UNCONFIRMED_RETURN` at the latest.
    pub fn return_after(seen: Option<f64>) -> f64 {
        seen.unwrap_or(f64::INFINITY).min(UNCONFIRMED_RETURN)
    }

    /// When the user's clipboard comes back: `RESTORE_MARGIN` after the text was seen, else `UNCONFIRMED_RESTORE`.
    pub fn restore_after(seen: Option<f64>) -> f64 {
        seen.map_or(UNCONFIRMED_RESTORE, |s| s + RESTORE_MARGIN)
    }

    /// The field's text shows the inserted text where the cursor was (`before` with the selection replaced by it), or at
    /// least it grew by it and has it — a field may tidy spacing around it. The selection (`sel_start`, `sel_len`) is in
    /// UTF-16 code units, as the Mac's NSRange — and as Win32 edit controls and UI Automation count.
    pub fn landed(
        before: &str,
        sel_start: usize,
        sel_len: usize,
        now: &str,
        inserted: &str,
    ) -> bool {
        if inserted.is_empty() || now == before {
            return false;
        }
        let b: Vec<u16> = before.encode_utf16().collect();
        let n: Vec<u16> = now.encode_utf16().collect();
        let ins: Vec<u16> = inserted.encode_utf16().collect();
        let loc = sel_start.min(b.len());
        let len = sel_len.min(b.len() - loc);
        let replaced: Vec<u16> = b[..loc]
            .iter()
            .chain(&ins)
            .chain(&b[loc + len..])
            .copied()
            .collect();
        if n == replaced {
            return true;
        }
        if loc + ins.len() <= n.len() && n[loc..loc + ins.len()] == ins[..] {
            return true;
        }
        n.len() >= b.len() - len + ins.len() && now.contains(inserted)
    }
}

/// ⌥C / ⌥T (docs/design/screen-text.md §Paste): whether the text read from the screen (or its translation) is also
/// pasted into the app in front. `decide` (the dictation's) decides, with one more refusal: a focus the accessibility
/// API reads as something other than a text field (the desktop, a page with nothing focused) — dictation pastes there
/// and keeps the text on the island; the screen's text is on the clipboard already, so Ctrl+V into nothing would only
/// beep. The app in front when the text is ready is the one that counts (2026-10-31, as a dictation's). The result stays
/// on the clipboard whatever is decided (⌥C's design: a copy the user made).
pub mod screen_text {
    use super::Situation;

    #[derive(Clone, Copy, Debug, PartialEq, Eq)]
    pub enum Decision {
        /// Ctrl+V into the app in front
        Paste,
        /// the clipboard only
        Copy { reason: &'static str },
    }

    pub fn decide(s: &Situation) -> Decision {
        match super::decide(s) {
            super::Decision::Paste { .. } => {
                if s.focus_is_text == Some(false) {
                    Decision::Copy { reason: "no_field" }
                } else {
                    Decision::Paste
                }
            }
            super::Decision::Own => Decision::Copy {
                reason: "blurt_in_front",
            },
            super::Decision::Copy { reason } | super::Decision::Hold { reason } => {
                Decision::Copy { reason }
            }
        }
    }

    /// What became of the result.
    #[derive(Clone, Copy, Debug, PartialEq, Eq)]
    pub enum Outcome {
        /// Ctrl+V went in and the field, read back, shows the text (`landing::landed`)
        Pasted,
        /// Ctrl+V went in but couldn't be confirmed: a field the accessibility API can't read (WeChat), or one that
        /// didn't show the text within `landing::CONFIRM_TIMEOUT` — "Copied · Ctrl+V to paste", never a "Pasted" that
        /// may be untrue
        Unconfirmed,
        /// no Ctrl+V (`decide` said copy)
        Copied,
        /// ⌥T into a fixed language the text was in already: the original, copied as it is (never pasted)
        AlreadyInTarget,
    }

    impl Outcome {
        pub const ALL: [Outcome; 4] = [
            Outcome::Pasted,
            Outcome::Unconfirmed,
            Outcome::Copied,
            Outcome::AlreadyInTarget,
        ];

        /// the Mac's raw values (logs, history)
        pub fn as_str(self) -> &'static str {
            match self {
                Outcome::Pasted => "pasted",
                Outcome::Unconfirmed => "unconfirmed",
                Outcome::Copied => "copied",
                Outcome::AlreadyInTarget => "already",
            }
        }
    }

    /// `pasted`: Ctrl+V was posted; `seen`: the field showed the text afterwards.
    pub fn outcome(pasted: bool, seen: bool) -> Outcome {
        if !pasted {
            return Outcome::Copied;
        }
        if seen {
            Outcome::Pasted
        } else {
            Outcome::Unconfirmed
        }
    }

    /// The island's line (a localisation key, the Mac's Capture.strings) for what happened to ⌥C's text or ⌥T's
    /// translation.
    pub fn line_key(o: Outcome, translate: bool) -> &'static str {
        match o {
            Outcome::Pasted => {
                if translate {
                    "capture.text.translation_pasted"
                } else {
                    "capture.text.typed"
                }
            }
            Outcome::Unconfirmed => "capture.text.copied_paste",
            Outcome::Copied => {
                if translate {
                    "capture.text.translation_copied"
                } else {
                    "capture.text.copied"
                }
            }
            Outcome::AlreadyInTarget => "capture.text.already",
        }
    }
}

/// Whether a double tap of the dictation key may press Return (`record.dictation.double_tap_send`): only into another
/// app in front, never while a password is being typed (Return would submit it), and only where a posted key arrives.
/// Test builds never post it at all.
pub mod send {
    #[derive(Clone, Copy, Debug, PartialEq, Eq)]
    pub enum Decision {
        Press,
        Skip { reason: &'static str },
    }

    pub fn decide(
        has_front_app: bool,
        front_is_blurt: bool,
        secure_input: bool,
        accessibility: bool,
    ) -> Decision {
        if !has_front_app {
            return Decision::Skip {
                reason: "no_front_app",
            };
        }
        if front_is_blurt {
            return Decision::Skip {
                reason: "blurt_in_front",
            };
        }
        if secure_input {
            return Decision::Skip {
                reason: "secure_input",
            };
        }
        if !accessibility {
            return Decision::Skip {
                reason: "no_accessibility",
            };
        }
        Decision::Press
    }

    /// A double tap that came while its take was on its way: Return once the text is in — not when nothing was pasted
    /// (Return would send without it), not into a focus read as no text field (it would rename the selected file or
    /// follow a link). Also after a switch: the text went into the app in front and Return follows it there — by the
    /// double tap the user is in that app and sees what was recognised (2026-10-31, the founder). The checks of `decide`
    /// (secure input, Blurt in front …) still come when Return is pressed.
    pub fn queued(pasted: bool, no_field: bool) -> Decision {
        if !pasted {
            return Decision::Skip {
                reason: "not_pasted",
            };
        }
        if no_field {
            return Decision::Skip { reason: "no_field" };
        }
        Decision::Press
    }
}

/// Which microphone dictation opens (`record.dictation.builtin_mic`). AirPods and other Bluetooth headsets switch to
/// their call profile (HFP) when their mic opens: ~1 s with no audio — the start of what was said is lost — and the music
/// in them drops to call quality while dictating. The machine's own mic is ready at once, at the price of being farther
/// from the mouth (more room, less voice). Automatic (unset): the built-in mic when the default input is Bluetooth;
/// `Some(true)`: always the built-in one when there is one; `Some(false)`: always the default input.
pub mod mic {
    pub fn use_built_in(
        setting: Option<bool>,
        default_is_bluetooth: bool,
        built_in_available: bool,
    ) -> bool {
        if !built_in_available {
            return false;
        }
        setting.unwrap_or(default_is_bluetooth)
    }
}

#[cfg(test)]
mod tests {
    //! Where dictated text goes (docs/design/dictation.md §Insert): Ctrl+V into any other app in front, like Typeless,
    //! also when the accessibility API can't see a text field there (WeChat); refused only for Blurt itself, a
    //! password being typed, no app.
    use super::*;

    fn s(
        front: bool,
        blurt: bool,
        secure: bool,
        ax: bool,
        secure_field: bool,
        text: Option<bool>,
    ) -> Situation {
        Situation {
            has_front_app: front,
            front_is_blurt: blurt,
            secure_input: secure,
            accessibility: ax,
            focus_secure: secure_field,
            focus_is_text: text,
        }
    }
    /// the Swift tests' `s()`: an app in front, not Blurt, no secure input, accessibility, a plain text field
    fn ok() -> Situation {
        s(true, false, false, true, false, Some(true))
    }

    /// The paste has landed when the field shows the text: Return may go then, and only then does the clipboard come
    /// back (a fixed 0.6 s could beat a slow app, which then pasted — and sent — the user's old clipboard).
    #[test]
    fn a_paste_has_landed_when_the_field_shows_it() {
        use landing::*;
        assert!(landed("Hi ", 3, 0, "Hi there.", "there."));
        assert!(landed(
            "我知道你就是的。",
            6,
            0,
            "我知道你就是从老家回来的。",
            "从老家回来"
        ));
        // a selection is replaced
        assert!(landed(
            "send the old text",
            9,
            3,
            "send the new text",
            "new"
        ));
        // not yet: the field is as it was
        assert!(!landed("Hi ", 3, 0, "Hi ", "there."));
        // something else changed (the user typed): not this paste
        assert!(!landed("Hi ", 3, 0, "Hi x", "there."));
        // a field that tidies the spacing around it still has it
        assert!(landed("a", 1, 0, "a there.", "there."));
        assert!(RESTORE_MARGIN < UNCONFIRMED_RESTORE);
        assert!(UNCONFIRMED_RESTORE > UNCONFIRMED_RETURN); // the clipboard never before Return
                                                           // Return: when seen, at 0.6 s at the latest — a field that never shows the text exactly (it converts quotes
                                                           // or emoji) no longer holds a send 1.5 s (review)
        assert_eq!(return_after(Some(0.09)), 0.09);
        assert_eq!(return_after(None), 0.6);
        assert_eq!(return_after(Some(1.2)), 0.6);
        assert!((restore_after(Some(0.09)) - 0.24).abs() < 1e-9);
        assert_eq!(restore_after(None), 1.5);
        assert!(restore_after(None) <= CONFIRM_TIMEOUT);
    }

    /// Windows only: the selection counts UTF-16 units, as the Mac's NSRange and Win32 / UIA do (an emoji is two).
    #[test]
    fn the_selection_counts_utf16_units() {
        assert!(landing::landed("😀 ", 3, 0, "😀 hi", "hi")); // glyph-ok: text data (OCR marks, emoji in a field), not an icon
        assert!(landing::landed("😀 old", 3, 3, "😀 new", "new")); // glyph-ok: text data (OCR marks, emoji in a field), not an icon
                                                                   // past the end: clamped, as on the Mac
        assert!(landing::landed("ab", 99, 99, "abc", "c"));
    }

    #[test]
    fn pastes_into_a_text_field() {
        assert_eq!(decide(&ok()), Decision::Paste { confirmed: true });
    }

    #[test]
    fn pastes_where_accessibility_sees_no_text_field() {
        // WeChat's input box: the focused element isn't a text control, or no element can be read at all
        assert_eq!(
            decide(&Situation {
                focus_is_text: Some(false),
                ..ok()
            }),
            Decision::Paste { confirmed: false }
        );
        assert_eq!(
            decide(&Situation {
                focus_is_text: None,
                ..ok()
            }),
            Decision::Paste { confirmed: false }
        );
    }

    #[test]
    fn refusals() {
        assert_eq!(
            decide(&Situation {
                has_front_app: false,
                ..ok()
            }),
            Decision::Copy {
                reason: "no_front_app"
            }
        );
        assert_eq!(
            decide(&Situation {
                front_is_blurt: true,
                ..ok()
            }),
            Decision::Own
        );
        // never on the clipboard by itself
        assert_eq!(
            decide(&Situation {
                secure_input: true,
                ..ok()
            }),
            Decision::Hold {
                reason: "secure_input"
            }
        );
        assert_eq!(
            decide(&Situation {
                focus_secure: true,
                ..ok()
            }),
            Decision::Hold {
                reason: "secure_input"
            }
        );
        assert_eq!(
            decide(&Situation {
                accessibility: false,
                ..ok()
            }),
            Decision::Copy {
                reason: "no_accessibility"
            }
        );
        // Blurt in front wins over everything but "no app" (its own text views get the text another way)
        assert_eq!(
            decide(&Situation {
                front_is_blurt: true,
                secure_input: true,
                ..ok()
            }),
            Decision::Own
        );
    }

    /// 2026-10-31, the founder: people speak in A meaning to type into B. A take whose user switched apps goes into the
    /// app in front by the same rules as any take: the situation is read at paste time and has no "which app the take
    /// started in" for a rule to look at.
    #[test]
    fn a_switched_app_gets_the_text_by_the_usual_rules() {
        assert_eq!(decide(&ok()), Decision::Paste { confirmed: true });
        assert_eq!(
            decide(&Situation {
                focus_secure: true,
                ..ok()
            }),
            Decision::Hold {
                reason: "secure_input"
            }
        ); // a password field in the new app
        assert_eq!(
            decide(&Situation {
                front_is_blurt: true,
                ..ok()
            }),
            Decision::Own
        ); // into Blurt: its own text view, or nothing
    }

    /// A queued Return (a double tap while the take was on its way) goes only where the text went in — also after a
    /// switch. `send::decide`'s checks (secure input, Blurt in front …) still come when Return is pressed.
    #[test]
    fn a_queued_return_follows_the_paste() {
        use send::*;
        assert_eq!(queued(true, false), Decision::Press);
        assert_eq!(queued(true, true), Decision::Skip { reason: "no_field" });
        assert_eq!(
            queued(false, false),
            Decision::Skip {
                reason: "not_pasted"
            }
        );
        assert_eq!(
            send::decide(true, false, true, true),
            Decision::Skip {
                reason: "secure_input"
            }
        );
        assert_eq!(
            send::decide(true, true, false, true),
            Decision::Skip {
                reason: "blurt_in_front"
            }
        );
    }

    /// ⌥C / ⌥T paste by the same rules (2026-10-30: WeChat only got a copy — the old check wanted a text role): wherever
    /// dictation pastes, except a focus read as no text field (the desktop: the text is on the clipboard already).
    #[test]
    fn screen_text_pastes_by_dictations_rules() {
        use screen_text::Decision as T;
        let d = screen_text::decide;
        assert_eq!(d(&ok()), T::Paste);
        assert_eq!(
            d(&Situation {
                focus_is_text: None,
                ..ok()
            }),
            T::Paste
        ); // WeChat: nothing the API can read
        assert_eq!(
            d(&Situation {
                focus_is_text: Some(false),
                ..ok()
            }),
            T::Copy { reason: "no_field" }
        ); // the desktop
        assert_eq!(
            d(&Situation {
                has_front_app: false,
                ..ok()
            }),
            T::Copy {
                reason: "no_front_app"
            }
        );
        assert_eq!(
            d(&Situation {
                front_is_blurt: true,
                ..ok()
            }),
            T::Copy {
                reason: "blurt_in_front"
            }
        );
        assert_eq!(
            d(&Situation {
                secure_input: true,
                ..ok()
            }),
            T::Copy {
                reason: "secure_input"
            }
        );
        assert_eq!(
            d(&Situation {
                focus_secure: true,
                ..ok()
            }),
            T::Copy {
                reason: "secure_input"
            }
        );
        assert_eq!(
            d(&Situation {
                accessibility: false,
                ..ok()
            }),
            T::Copy {
                reason: "no_accessibility"
            }
        );
        // every situation dictation pastes into, ⌥C pastes into too — unless the focus is read as no field
        for front in [true, false] {
            for blurt in [true, false] {
                for secure in [true, false] {
                    for ax in [true, false] {
                        for text in [Some(true), Some(false), None] {
                            let x = s(front, blurt, secure, ax, false, text);
                            if let Decision::Paste { .. } = decide(&x) {
                                assert_eq!(d(&x) == T::Paste, text != Some(false), "{x:?}");
                            } else {
                                assert_ne!(d(&x), T::Paste, "{x:?}");
                            }
                        }
                    }
                }
            }
        }
    }

    /// "Pasted" only once the field shows it; Ctrl+V that can't be confirmed says the text is on the clipboard.
    #[test]
    fn screen_text_says_pasted_only_when_seen() {
        use screen_text::*;
        assert_eq!(outcome(true, true), Outcome::Pasted);
        assert_eq!(outcome(true, false), Outcome::Unconfirmed);
        assert_eq!(outcome(false, false), Outcome::Copied);
        assert_eq!(outcome(false, true), Outcome::Copied);
        assert_eq!(line_key(Outcome::Pasted, false), "capture.text.typed");
        assert_eq!(
            line_key(Outcome::Pasted, true),
            "capture.text.translation_pasted"
        );
        assert_eq!(
            line_key(Outcome::Unconfirmed, false),
            "capture.text.copied_paste"
        );
        assert_eq!(
            line_key(Outcome::Unconfirmed, true),
            "capture.text.copied_paste"
        );
        assert_eq!(line_key(Outcome::Copied, false), "capture.text.copied");
        assert_eq!(
            line_key(Outcome::Copied, true),
            "capture.text.translation_copied"
        );
        assert_eq!(
            line_key(Outcome::AlreadyInTarget, true),
            "capture.text.already"
        );
        assert_eq!(Outcome::AlreadyInTarget.as_str(), "already");
        // (the Mac also checks every line exists in both languages; the Windows locales have no capture.text.* keys yet)
    }

    #[test]
    fn built_in_mic_choice() {
        let c = mic::use_built_in;
        assert!(c(None, true, true)); // automatic: AirPods are the default input → the machine's mic
        assert!(!c(None, false, true)); // automatic: a wired / built-in default stays
        assert!(!c(Some(false), true, true)); // the user said no
        assert!(c(Some(true), false, true)); // the user said always
        assert!(!c(Some(true), true, false)); // a machine without a mic (a desktop tower)
    }

    /// A double tap presses Return only into another app, never with a password being typed, and only where keys
    /// arrive.
    #[test]
    fn send_policy() {
        use send::{decide as d, Decision as D};
        assert_eq!(d(true, false, false, true), D::Press);
        assert_eq!(
            d(true, true, false, true),
            D::Skip {
                reason: "blurt_in_front"
            }
        );
        assert_eq!(
            d(true, false, true, true),
            D::Skip {
                reason: "secure_input"
            }
        );
        assert_eq!(
            d(true, false, false, false),
            D::Skip {
                reason: "no_accessibility"
            }
        );
        assert_eq!(
            d(false, false, false, true),
            D::Skip {
                reason: "no_front_app"
            }
        );
    }
}
