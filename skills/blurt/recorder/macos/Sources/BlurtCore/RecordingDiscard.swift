// The recording's discard question (BlurtApp IslandContent.buildRecording: the trash button while recording).
// dogfood v0.9-2: the question was drawn under its own buttons, "3 snaps" counted the markers as snaps, and the red
// Discard sat exactly where Finish had been a click before. So:
//  • what goes with the take is said as the island counts it: the snaps the user took and the markers (⌥M), apart
//    (`lost`) — "Discard this recording, with 1 snap and 2 markers?";
//  • the answers, left to right: Discard · Restart · Keep Recording — the safe one rightmost, where Finish was;
//  • the question sits beside the answers only when it fits there, else on its own line above them (`ownLine`).
// Pure: RecordingDiscardTests.
import CoreGraphics

public enum RecordingDiscard {
    /// What the question names besides the recording.
    public enum Lost: Equatable {
        case nothing
        case snaps(Int)
        case markers(Int)
        case both(snaps: Int, markers: Int)
    }

    /// `stills`: snaps the user took (⌥A, the island's camera); `markers`: ⌥M's stills, counted apart.
    public static func lost(stills: Int, markers: Int) -> Lost {
        switch (max(0, stills), max(0, markers)) {
        case (0, 0): return .nothing
        case let (s, 0): return .snaps(s)
        case let (0, m): return .markers(m)
        case let (s, m): return .both(snaps: s, markers: m)
        }
    }

    public enum Answer: CaseIterable { case discard, restart, keep }
    /// Left to right: nothing destructive where Finish was (the right end), Keep Recording there instead.
    public static let order: [Answer] = [.discard, .restart, .keep]

    /// The question on its own line above the answers: when it doesn't fit between the left inset and the answers
    /// (with a gap). `question`: its one-line width; `answers`: the buttons' row, gaps included; `width`: the island's.
    public static func ownLine(question: CGFloat, answers: CGFloat, width: CGFloat, inset: CGFloat = 18,
                               trailing: CGFloat = 12, gap: CGFloat = 12) -> Bool {
        inset + question + gap + answers + trailing > width
    }
}
