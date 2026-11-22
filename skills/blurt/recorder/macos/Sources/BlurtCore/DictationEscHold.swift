// Esc while a take listens is Blurt's: it cancels the take, and the app in front sees neither the press nor the
// release — in Claude Code an Esc that gets through stops the running turn as well (docs/design/dictation.md §Trigger).
// The pure parts of keeping it out, unit-tested in Tests/BlurtCoreTests/DictationEscHoldTests.swift:
//
//   DictationEscFilter  what the Fn filter (an active event tap) does with an Esc. It drops the press where a Carbon
//                       hotkey can't match it (Fn is held in push-to-talk), and the repeats and the release of a press
//                       it kept — by which time the take has ended.
//   DictationEscHold    when the hotkeys may go back. A Carbon hotkey keeps a key only while it is registered, and the
//                       take ends the moment Blurt hears Esc. Measured on the window server, with a key of no use to
//                       anything standing in for Esc: dropped the moment the filter handed the press on, press and
//                       release reached the app 20 times of 20 (macOS hadn't matched the hotkey yet); dropped the
//                       moment a listen-only tap heard the press, the release did, 20 of 20. Held until the key is up
//                       and has settled: neither.
import Foundation

public struct DictationEscFilter: Equatable {
    /// While a take listens: a press of the cancel key is Blurt's.
    public var armed = false
    /// The modifier the cancel key takes, as a CGEvent's flags have it: none (Esc), ⌃ (⌃Esc), ⇧ (⇧Esc).
    public var needs: UInt64 = 0
    /// The press now down was kept from the app.
    public private(set) var kept = false

    public init() {}

    /// ⌘ ⌃ ⇧ ⌥ (device-independent bits). Fn and caps lock are left out on purpose: a hotkey doesn't see them either, and
    /// Fn is the dictation key, held in push-to-talk.
    static let modifiers: UInt64 = 0x10_0000 | 0x4_0000 | 0x2_0000 | 0x8_0000

    /// An Esc press or release reaching the filter: true = keep it from the app. Another key's modifier held with Esc
    /// (⌘Esc, ⇧Esc with Esc as the cancel key) is the app's own, as it is where no filter runs.
    public mutating func drop(keyDown: Bool, flags: UInt64) -> Bool {
        guard keyDown else {
            defer { kept = false }
            return kept
        }
        if kept { return true }             // a repeat of the press it kept
        guard armed, flags & DictationEscFilter.modifiers == needs else { return false }
        kept = true
        return true
    }

    /// The tap went away: a release it will never see must not hold the next press.
    public mutating func forgetPress() { kept = false }
}

public struct DictationEscHold: Equatable {
    /// how long the key must have been up: macOS still has to take the release through the hotkey
    public static let settle = 0.08
    /// Never longer than this, whatever the key's state says: Esc must not stay out of every app.
    public static let limit = 3.0

    private let since: Double
    private var upAt: Double?

    public init(since: Double) { self.since = since }

    /// Asked every few ms after the take ended: may the hotkeys go now?
    public mutating func canRelease(now: Double, keyDown: Bool) -> Bool {
        if now - since >= DictationEscHold.limit { return true }
        if keyDown {
            upAt = nil
            return false
        }
        let up = upAt ?? now
        upAt = up
        return now - up >= DictationEscHold.settle
    }
}
