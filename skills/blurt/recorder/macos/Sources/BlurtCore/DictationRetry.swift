// Where a dictation that wasn't recognised can be retried besides the notch's 8-second line (2026-11-16, a user: "the
// local model didn't keep up, it kept the recording, and I couldn't find a copy or retry anywhere"). Retry was only in
// the notch's line and on the Dictation page (menu bar → Dictation History…). Now also:
//   the menu bar   "Copy Last Dictation" becomes "Retry Last Dictation" while the latest take is one that failed with
//                  its recording kept;
//   Home           a failed take is a row of the timeline, with Retry.
// A take the user cancelled (Esc) was meant: neither place offers it (the Dictation page still does). A retry from
// either place puts the text on the clipboard: by then the user may be anywhere.
import Foundation

public enum DictationRetry {
    /// Recognition failed (no text) and the user didn't cancel it: the speech model failed, was too slow, the app quit
    /// before the text came.
    public static func failed(_ e: DictationEntry) -> Bool {
        e.text.isEmpty && (e.reason ?? "").hasPrefix("asr_failed") && e.reason != DictationHistory.cancelledReason
    }

    /// The menu bar's row for the last dictation.
    public enum MenuRow: Equatable {
        /// copy this entry's text (the newest with text)
        case copy(String)
        /// retry this entry (the newest, failed, its recording kept)
        case retry(String)
    }

    /// `entries` newest first (DictationHistory.load); `audioKept`: its recording is still on disk.
    public static func menuRow(_ entries: [DictationEntry], audioKept: (DictationEntry) -> Bool) -> MenuRow? {
        if let first = entries.first, failed(first), audioKept(first) { return .retry(first.id) }
        return entries.first { !$0.finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map { .copy($0.id) }
    }

    /// Home's timeline lists it: a dictation with text, or a failed one whose recording is kept (cancelled ones aren't).
    public static func onHome(_ e: DictationEntry, audioKept: (DictationEntry) -> Bool) -> Bool {
        if !e.finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        return failed(e) && audioKept(e)
    }
}
