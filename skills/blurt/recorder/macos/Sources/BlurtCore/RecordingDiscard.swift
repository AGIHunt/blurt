// The recording's discard question (BlurtApp IslandContent.buildRecording: the trash button while recording).
// dogfood v0.9-2: the question was drawn under its own buttons, "3 snaps" counted ⌥M's markers as snaps, and the red
// Discard sat exactly where Finish had been a click before. So:
//  • what goes with the take is said as the island counts it (`lost`): "Discard this recording, with 2 snaps?" (⌥M's
//    markers, counted apart until 1.0.7, are gone: ⌥A snaps without pausing while recording);
//  • the answers, left to right: Discard · Restart · Keep Recording — the safe one rightmost, where Finish was;
//  • the question sits beside the answers only when it fits there, else on its own line above them (`ownLine`).
// Pure: RecordingDiscardTests.
import CoreGraphics

public enum RecordingDiscard {
    /// What the question names besides the recording.
    public enum Lost: Equatable {
        case nothing
        case snaps(Int)
    }

    /// `stills`: the snaps taken during the take (⌥A, the island's camera, `record.py snap`).
    public static func lost(stills: Int) -> Lost {
        stills > 0 ? .snaps(stills) : .nothing
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
