// What a card's drag-out did, kept on disk (v0.9). The report: a picture + note card dragged into Feishu arrived as the
// picture alone, and there was nothing to look at — the app's events only go to its stdout, which a normal launch
// doesn't keep. The drag's own events (what the pasteboard was written for, what the app read, where it landed, the
// follow-up's focus and paste, the toast) now also go to <BLURT_HOME>/logs/card-drag.log, one JSON object per line,
// the last ~512 KB (one older file, .1). Never the words: a plan or a paste step keeps only its kind ("paste", not
// paste("…")), and fields that carry text are left out.

import Foundation

public enum DragLog {
    public static let fileName = "card-drag.log"
    public static let maxBytes = 512 * 1024

    /// The events that describe a drag-out and what followed it.
    public static let events: Set<String> = [
        "card_drag_target", "card_drag_provide", "card_drag_end", "card_taken_out", "card_drag_refused", "voice_drag_hint",
        "overview_drag_end", "taken_drag_end", "drag_note_plan", "drag_note_activate", "drag_note_composer",
        "drag_note_focus", "drag_note_follow_up", "voice_drop_plan", "take_out", "paste_key", "paste_step",
        "paste_step_read", "paste_run",
    ]

    /// Fields that may carry what the card says.
    static let textFields: Set<String> = ["text", "said", "note", "words", "typed"]

    /// The line to keep for `obj` (nil: not a drag event). `at`: when (seconds since 1970).
    public static func line(_ obj: [String: Any], at: TimeInterval) -> String? {
        guard let e = obj["event"] as? String, events.contains(e) else { return nil }
        var o: [String: Any] = [:]
        for (k, v) in obj where !textFields.contains(k) {
            if k == "plan" || k == "step" || k == "steps" { o[k] = redact(v); continue }
            o[k] = v
        }
        o["at"] = stamp(at)
        guard JSONSerialization.isValidJSONObject(o),
              let d = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) else { return nil }
        return String(data: d, encoding: .utf8)
    }

    /// `at` as local time with milliseconds ("2026-10-26T10:14:44.166+08:00"), to line up with what the user saw.
    static func stamp(_ at: TimeInterval) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = .current
        return f.string(from: Date(timeIntervalSince1970: at))
    }

    /// A plan or step's description without its payload: `paste("…")` → "paste", `none("app_took_it")` stays (a reason,
    /// not words), `pasteNote("…")` → "pasteNote".
    static func redact(_ v: Any) -> Any {
        if let a = v as? [Any] { return a.map(redact) }
        guard let s = v as? String else { return v }
        guard let i = s.firstIndex(of: "(") else { return s }
        let head = String(s[..<i])
        if head.hasSuffix("none") || head.hasSuffix("skip") { return s }
        return head
    }
}
