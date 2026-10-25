// Where dictated text goes (docs/design/dictation.md §Insert), and which microphone dictation listens with. Pure, so
// the rules are unit-tested (DictationPastePolicyTests).
//
// Paste: like Typeless, ⌘V goes to the app in front whenever it is another app and no password is being typed — also
// when its focused element isn't an Accessibility text role (WeChat's input box isn't one, nor are many Electron and
// web editors). The old rule ("the focused element must belong to the front app and not be a button or a list")
// refused those and left the text on the clipboard. Refused only when:
//   • there is no app in front;
//   • Blurt itself is in front (its own text views get a paste: action instead; panels get nothing);
//   • secure event input is on (IsSecureEventInputEnabled: a password field anywhere), or the focus is a secure field;
//   • Accessibility isn't granted (a posted ⌘V wouldn't arrive);
//   • the app in front isn't the one the take started in (`appChanged`: a slow take — a cold model, the 5-minute
//     limit — whose user moved on): the text goes to the clipboard ("Copied — paste with ⌘V"), never into whatever
//     happens to be in front by then, and a queued Return is dropped.
// The user's clipboard is put back after the paste either way.
import Foundation

public enum DictationPastePolicy {
    public enum Decision: Equatable {
        /// ⌘V; `confirmed`: the focus is known to be a text field (else the island offers "Copy again")
        case paste(confirmed: Bool)
        /// Blurt is in front: its own text view (paste:), or nothing
        case own
        /// the text stays on the clipboard
        case copy(reason: String)
    }

    public struct Situation: Equatable {
        public var hasFrontApp: Bool
        public var frontIsBlurt: Bool
        public var secureInput: Bool
        public var accessibility: Bool
        /// the focused element is a secure text field (AXSecureTextField role or subrole)
        public var focusSecure: Bool
        /// the focused element is a text field as far as Accessibility can tell (nil: no element could be read)
        public var focusIsText: Bool?
        /// the app in front now isn't the one the take started in
        public var appChanged: Bool

        public init(hasFrontApp: Bool, frontIsBlurt: Bool, secureInput: Bool, accessibility: Bool, focusSecure: Bool = false,
                    focusIsText: Bool? = nil, appChanged: Bool = false) {
            self.hasFrontApp = hasFrontApp; self.frontIsBlurt = frontIsBlurt; self.secureInput = secureInput
            self.accessibility = accessibility; self.focusSecure = focusSecure; self.focusIsText = focusIsText
            self.appChanged = appChanged
        }
    }

    public static func decide(_ s: Situation) -> Decision {
        guard s.hasFrontApp else { return .copy(reason: "no_front_app") }
        if s.appChanged { return .copy(reason: "app_changed") }
        if s.frontIsBlurt { return .own }
        if s.secureInput || s.focusSecure { return .copy(reason: "secure_input") }
        guard s.accessibility else { return .copy(reason: "no_accessibility") }
        return .paste(confirmed: s.focusIsText == true)
    }
}

/// Whether a double tap of the dictation key may press Return (`record.dictation.double_tap_send`): only into another
/// app in front, never while secure input is on (a password field anywhere: Return would submit it), and only with
/// Accessibility (a posted key wouldn't arrive otherwise). Test builds never post it at all (DictationInsert.testMode).
public enum DictationSendPolicy {
    public enum Decision: Equatable { case press, skip(reason: String) }

    public static func decide(hasFrontApp: Bool, frontIsBlurt: Bool, secureInput: Bool, accessibility: Bool) -> Decision {
        guard hasFrontApp else { return .skip(reason: "no_front_app") }
        if frontIsBlurt { return .skip(reason: "blurt_in_front") }
        if secureInput { return .skip(reason: "secure_input") }
        guard accessibility else { return .skip(reason: "no_accessibility") }
        return .press
    }
}

/// Which microphone dictation opens (`record.dictation.builtin_mic`). AirPods and other Bluetooth headsets switch to
/// their call profile (HFP) when their mic opens: ~1 s with no audio — the start of what was said is lost — and the
/// music in them drops to call quality while dictating. The Mac's own mic is ready at once, at the price of being
/// farther from the mouth (more room, less voice). Automatic (unset): the built-in mic when the default input is
/// Bluetooth; `true`: always the built-in one when there is one; `false`: always the default input.
public enum DictationMicChoice {
    public static func useBuiltIn(setting: Bool?, defaultIsBluetooth: Bool, builtInAvailable: Bool) -> Bool {
        guard builtInAvailable else { return false }
        return setting ?? defaultIsBluetooth
    }
}
