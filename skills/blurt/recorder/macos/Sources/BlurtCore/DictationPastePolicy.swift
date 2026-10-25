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

/// When a posted ⌘V has landed, and when the user's clipboard may come back (v0.9 dogfood). The clipboard used to come
/// back on a fixed 0.6 s timer and a double tap's Return waited for that timer: a slow app (a busy Electron chat, a
/// Mac under memory pressure) could read the clipboard after it was put back and paste — then send — the user's old
/// clipboard, and every send waited 0.6 s more than it needed. Now, where the field can be read, the text in it says
/// when the paste landed: Return goes at once and the clipboard comes back a moment later; where it can't (WeChat,
/// Electron), Return keeps the old 0.6 s (keys reach the app in order: Return after ⌘V) and the clipboard waits 1.5 s.
/// Return never waits longer than those 0.6 s: a readable field that never shows the text exactly (a rich-text or
/// Electron field that turns quotes or emoji into its own, or trims a space) only delays the clipboard (review).
public enum DictationPasteLanding {
    /// how often the field is read while waiting
    public static let poll = 0.03
    /// a readable field that never shows the text (it reformats it, or the paste went elsewhere): give up waiting
    public static let confirmTimeout = 1.5
    /// after the text is seen: the clipboard comes back this much later
    public static let restoreMargin = 0.15
    /// an unreadable field: Return after this (as before) …
    public static let unconfirmedReturn = 0.6
    /// … and the clipboard back after this
    public static let unconfirmedRestore = 1.5

    /// When a double tap's Return goes, `seen` s after ⌘V the field showed the text (nil: not seen, or unreadable):
    /// then, or after `unconfirmedReturn` at the latest.
    public static func returnAfter(seen: Double?) -> Double { min(seen ?? .infinity, unconfirmedReturn) }
    /// When the user's clipboard comes back: `restoreMargin` after the text was seen, else `unconfirmedRestore`.
    public static func restoreAfter(seen: Double?) -> Double { seen.map { $0 + restoreMargin } ?? unconfirmedRestore }

    /// The field's text shows the inserted text where the cursor was (`before` with `selection` replaced by it), or
    /// at least it grew by it and has it — a field may tidy spacing around it.
    public static func landed(before: String, selection: NSRange, now: String, inserted: String) -> Bool {
        let b = before as NSString, n = now as NSString
        guard !inserted.isEmpty, now != before else { return false }
        let loc = min(max(0, selection.location), b.length), len = min(max(0, selection.length), b.length - loc)
        if now == b.replacingCharacters(in: NSRange(location: loc, length: len), with: inserted) { return true }
        let ins = inserted as NSString
        if loc + ins.length <= n.length, n.substring(with: NSRange(location: loc, length: ins.length)) == inserted { return true }
        return n.length >= b.length - len + ins.length && now.contains(inserted)
    }
}

public enum DictationPastePolicy {
    public enum Decision: Equatable {
        /// ⌘V; `confirmed`: the focus is known to be a text field (else the island offers "Copy again")
        case paste(confirmed: Bool)
        /// Blurt is in front: its own text view (paste:), or nothing
        case own
        /// the text stays on the clipboard
        case copy(reason: String)
        /// nothing typed, nothing copied: the text waits in the history and on the island's Copy (a password field
        /// has the focus — text said there by accident shouldn't land on the clipboard, where clipboard managers
        /// keep it; v0.9 dogfood)
        case hold(reason: String)
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
        if s.secureInput || s.focusSecure { return .hold(reason: "secure_input") }
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
