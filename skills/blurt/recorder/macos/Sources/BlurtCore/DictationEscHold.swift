// Esc while a take is under way is Blurt's: it cancels the take and the app in front never sees it (docs/design/
// dictation.md §Trigger). In Claude Code an Esc that gets through stops the running turn as well. The pure parts of
// keeping it out, unit-tested in Tests/BlurtCoreTests/DictationEscHoldTests.swift:
//
//   isBlurts            when: while a take listens, and while takes are on their way unless another of Blurt's Esc keys
//                       (the picker, a card) wants it — that one was opened after the take and Esc is meant for it.
//   DictationEscFilter  what the Fn filter (an active event tap) does with an Esc: it can drop the press whatever is
//                       held with it, Fn too, which a Carbon hotkey can't match. The release and the repeats of a press
//                       it kept go with it, even though the take has ended by then.
//   DictationEscHold    when the Esc hotkey may go back. A Carbon hotkey only keeps a key while it is registered, and the
//                       take ends the moment the listener hears Esc. Measured with a key of no use to anything
//                       (2026-11-05): dropped at once from the filter's hand-off, the press and the release reached the
//                       app 20 times out of 20 (macOS hadn't matched the hotkey yet); dropped at once from the
//                       listen-only tap, the release did, 20 of 20. Held until the key is up and has settled: neither.
import Foundation

public struct DictationEscFilter: Equatable {
    /// A take is under way: a press of the cancel key is Blurt's.
    public var armed = false
    /// The modifier bits the cancel key needs (0: Esc; ⌃Esc / ⇧Esc: that bit). Plain Esc stays the app's then.
    public var needs: UInt64 = 0
    /// The press now down was kept from the app.
    public private(set) var kept = false

    public init() {}

    /// An Esc press or release reaching the filter: true = keep it from the app.
    public mutating func drop(keyDown: Bool, flags: UInt64) -> Bool {
        guard keyDown else {
            defer { kept = false }
            return kept
        }
        if kept { return true }             // a repeat of the press it kept
        guard armed, flags & needs == needs else { return false }
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

    /// Esc is the take's now.
    public static func isBlurts(listening: Bool, onItsWay: Bool, otherHolder: Bool) -> Bool {
        listening || (onItsWay && !otherHolder)
    }

    /// Asked every few ms after the take ended: may the hotkey go now?
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
