// What the island says, and for how long it stays true (BlurtApp Capture/Island/Island.swift shows the toasts, BlurtCore
// ToastQueue orders them; Capture/Dictation and Capture/Island/IslandContent.swift post these).
//
//  • dictation's toasts end with what they describe (DictationToastKeys). A new take drops what was said about the
//    last one — its Undo, "copied", the tips about it (`notice`), "still listening" and the 5-minute limit
//    (`listening`) — so the island never says "Stopped at the 5-minute limit" over a take that listens. A take that
//    stops listening drops ⇧'s style line ("Structured · ⇧ to go back"): ⇧ does nothing once it has stopped. A failed
//    take's Retry, "Cancelled · Undo" and the model's Download… stay (their own keys): they are still true.
//  • a double tap whose text could only be copied (DictationCopyToast): one line that says both — copied, and not
//    sent — instead of "Not sent" replaced in the same frame by "Copied — paste with ⌘V". A plain copy carries the
//    ok check like every other done line.
//  • discarding a recording (RecordingDiscard): the question names what goes with it — its snaps and its markers
//    apart (the island counts them apart; "3 snaps" for one still and two markers didn't match it).
//  • a card's name where its words can't stand in (CardName): its first line, else what it is and when ("Snap ·
//    19:03"), never a session counter ("Screenshot 15" skipped numbers and told cards apart by nothing).
import Foundation

public enum DictationToastKeys {
    /// what the island says about the last take: reformat's Undo, the list chip, "nothing heard", "copied"
    public static let take = "dictation"
    /// ⇧'s style line while a take listens
    public static let style = "dictation.style"
    /// once-a-day notices and the first takes' tips
    public static let notice = "dictation.notice"
    /// "still listening" and the 5-minute limit
    public static let listening = "dictation.listening"
    /// "Cancelled · Undo"
    public static let cancel = "dictation.cancel"
    /// "no speech model · Download…" / "the model is ready · Retry"
    public static let model = "dictation.model"

    /// Dropped when a new take starts: everything about the last take, and the notices it ended with.
    public static let droppedAtStart = [take, notice, listening]
    /// Dropped when a take stops listening (stopped, cancelled, or ended by itself): ⇧ means nothing after that.
    public static let droppedWhenListeningEnds = [style]
}

public enum DictationCopyToast {
    /// The line for a take whose text was left on the clipboard (`copied`), or nil (it was pasted). `sendWanted`: a
    /// double tap asked for Return after it, which couldn't go (it would send without the text) — said in the same line.
    public static func key(copied: Bool, appChanged: Bool, sendWanted: Bool) -> String? {
        guard copied else { return nil }
        if sendWanted { return "dictation.toast.not_sent.copied" }
        return appChanged ? "dictation.toast.copied_app" : "dictation.toast.copied"
    }

    /// The copied lines carry the ok check (it worked: the text is on the clipboard); "not sent" doesn't.
    public static func checked(_ key: String) -> Bool { key == "dictation.toast.copied" || key == "dictation.toast.copied_app" }
}

public enum RecordingDiscard {
    public enum Part: Equatable { case snaps(Int), markers(Int) }

    /// What goes with a discarded recording, in the island's words: the stills, then the markers — none that is zero.
    public static func lost(stills: Int, markers: Int) -> [Part] {
        (stills > 0 ? [.snaps(stills)] : []) + (markers > 0 ? [.markers(markers)] : [])
    }
}

public enum CardName {
    /// The longest a name runs before it ends in "…".
    public static let maxLength = 60

    /// A card's name: the first line of its words, cut at `maxLength`; nil when it has none (the caller says what it
    /// is and when instead: "Snap · 19:03").
    public static func words(_ w: String?) -> String? {
        guard let first = w?.split(whereSeparator: \.isNewline).first.map({ $0.trimmingCharacters(in: .whitespaces) }),
              !first.isEmpty else { return nil }
        return first.count > maxLength ? String(first.prefix(maxLength - 1)) + "…" : first
    }
}
