// Structured for a voice note (⌥⇧V), the same as dictation's (docs/design/dictation-styles.md §3.2, v0.9-userfix):
// while the note listens, ⇧ pressed and let go on its own toggles Structured — or a click on the island's list mark.
// When the note's words are in, Structured runs the polish model's structuring pass over them (the same `structure`
// request dictation's Structured makes: lists laid out, self-corrections resolved, or a paragraph left a paragraph);
// the card's note is that text and the raw transcript stays with it (shots.jsonl `said_raw`). No word lists, no rules
// about what a list is: the model decides.
//
// LoneShift is the key half: ⇧ down with no other modifier held, up again within `tapMax`, nothing pressed between.
// ⌥⇧V itself never counts (its ⇧ goes down with ⌥ held), nor a capital letter, nor a ⇧-click. Two listeners can hand
// the same change over (the dictation key's tap and the voice note's own monitor): the same change within 30 ms
// counts once. Pure: VoiceNoteStyleTests.
import Foundation

public struct LoneShift {
    /// a ⇧ held longer than this is a finger resting on it, not a toggle (dictation's `shiftTapMax`)
    public var tapMax = 1.0
    private var downAt: Double?
    /// the last few changes seen (two listeners may hand them over interleaved: tap down, tap up, monitor down, …)
    private var recent: [(code: Int, flags: UInt64, at: Double)] = []
    /// ⌘ ⌃ ⌥ Fn
    static let others: UInt64 = 0x10_0000 | 0x4_0000 | 0x8_0000 | 0x80_0000

    public init() {}

    /// true: this event let go of a lone ⇧ — toggle Structured.
    public mutating func handle(_ e: DictationTrigger.Event) -> Bool {
        switch e {
        case let .flags(code, flags, t):
            if recent.contains(where: { $0.code == code && $0.flags == flags && abs(t - $0.at) < 0.03 }) { return false }
            recent.append((code, flags, t))
            if recent.count > 6 { recent.removeFirst(recent.count - 6) }
            guard DictationTrigger.shiftCodes.contains(code) else { downAt = nil; return false }
            let down = flags & DictationTrigger.shiftMask != 0
            let alone = flags & LoneShift.others == 0
            if down {
                downAt = alone ? t : nil
                return false
            }
            defer { downAt = nil }
            guard alone, let d = downAt, t - d <= tapMax else { return false }
            return true
        case .keyDown, .mouseDown:
            downAt = nil
            return false
        case .islandClick, .tick:
            return false
        }
    }

    /// Forget a ⇧ half pressed (the note ended).
    public mutating func reset() { downAt = nil; recent = [] }
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
