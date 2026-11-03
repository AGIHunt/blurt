// Structured for a voice note (⌥V), the same as dictation's (docs/design/dictation-styles.md §3.2, v0.9-userfix):
// while the note listens, ⇧ pressed and let go on its own toggles Structured — or a click on the island's list mark.
// When the note's words are in, Structured runs the polish model's structuring pass over them (the same `structure`
// request dictation's Structured makes: lists laid out, self-corrections resolved, or a paragraph left a paragraph);
// the card's note is that text and the raw transcript stays with it (shots.jsonl `said_raw`). No word lists, no rules
// about what a list is: the model decides.
//
// LoneShift is the key half, and it asks the same way a dictation does (DictationTrigger.modifierChanged): a double
// ⇧ (the second press inside `doubleTapWindow`, a `cooldown` after a fire) or — when the user set the dictation's
// modifier tap back to "single" — one ⇧ let go within `tapMax`. Same window and cooldown defaults, same ⇧⌘ rule.
// ⌥V itself never counts (its ⇧ goes down with ⌥ held), nor a capital letter, nor a ⇧-click. Two listeners can hand
// the same change over (the dictation key's tap and the voice note's own monitor): the same change within 30 ms
// counts once. Pure: VoiceNoteStyleTests.
import Foundation

public struct LoneShift {
    /// single mode: a ⇧ held longer than this is a finger resting on it, not a toggle (dictation's `shiftTapMax`)
    public var tapMax = 1.0
    /// what the user chose for the dictation's ⇧ (Dictation.modifierTapShift): double by default
    public var mode: DictationTrigger.ModifierTap = DictationTrigger.shippedModifierTap
    public var doubleTapWindow = DictationTrigger.shippedDoubleTapWindow
    public var cooldown = DictationTrigger.shippedModifierCooldown
    private var downAt: Double?
    /// double mode: when the first ⇧ went down, and when the cooldown after a fire ends
    private var lastTapAt: Double?
    private var cooldownUntil: Double = 0
    /// the last few changes seen (two listeners may hand them over interleaved: tap down, tap up, monitor down, …)
    private var recent: [(code: Int, flags: UInt64, at: Double)] = []
    /// ⌘ ⌃ ⌥ Fn
    static let others: UInt64 = 0x10_0000 | 0x4_0000 | 0x8_0000 | 0x80_0000

    public init() {}

    /// true: this event asked for the toggle — the second ⇧ press of a double tap, or (single mode) the release of
    /// one ⇧.
    public mutating func handle(_ e: DictationTrigger.Event) -> Bool {
        switch e {
        case let .flags(code, flags, t):
            if recent.contains(where: { $0.code == code && $0.flags == flags && abs(t - $0.at) < 0.03 }) { return false }
            recent.append((code, flags, t))
            if recent.count > 6 { recent.removeFirst(recent.count - 6) }
            guard DictationTrigger.shiftCodes.contains(code) else { downAt = nil; lastTapAt = nil; return false }
            let down = flags & DictationTrigger.shiftMask != 0
            let alone = flags & LoneShift.others == 0
            if down {
                // ⇧ with another modifier held is a chord (⌥⇧V itself, ⌘⇧S): neither a tap nor the first of two
                guard alone else { downAt = nil; lastTapAt = nil; return false }
                guard mode == .double else { downAt = t; return false }
                if t < cooldownUntil { lastTapAt = nil; return false }
                if let l = lastTapAt, t - l <= doubleTapWindow {
                    lastTapAt = nil
                    cooldownUntil = t + cooldown
                    return true
                }
                lastTapAt = t
                return false
            }
            guard alone else { downAt = nil; lastTapAt = nil; return false }
            if mode == .single {
                defer { downAt = nil }
                guard let d = downAt, t - d <= tapMax else { return false }
                return true
            }
            return false                    // double: the fire was on the second press
        case .keyDown, .mouseDown:
            downAt = nil
            lastTapAt = nil
            return false
        case .islandClick, .islandTranslateClick, .tick:
            return false
        }
    }

    /// Forget a ⇧ half pressed (the note ended).
    public mutating func reset() { downAt = nil; lastTapAt = nil; recent = [] }
}

/// What a voice note's card keeps when it was Structured: the structured text as its note (`said`), the transcript as
/// it was heard (`said_raw`) — only when the two differ; a refusal or no model keeps the transcript as the note.
public enum VoiceNoteStructure {
    public static func keep(raw: String, structured: String?) -> (said: String, raw: String?) {
        let r = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let s = structured?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty, s != r else { return (r, nil) }
        return (s, r)
    }
}
