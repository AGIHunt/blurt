// The small rules behind editing a capture and keeping it (v0.8.7, the capture audit). BlurtApp's NoteBubble,
// VoiceInput and Snapper do the UI and the files; what they decide is here, so it can be tested.
//
//  • NoteEdit — "Edit Note…" shows the whole note (typed, then said: CardNote.merged) as editable text, so words
//    that were heard wrong can be fixed. On save, an edit of a note that had spoken words replaces those words
//    (said = the edited text, typed = nil): the correction wins and nothing is said twice. A re-record's words are
//    still to come: the field keeps the typed part only. An emptied field never erases spoken words.
//  • VoiceRetake — a re-record in the edit bubble goes to shots/NNN.retake.wav, never over the note it replaces:
//    kept (⏎, or the pause after speech) it takes the original's place; Esc, or no speech, deletes only the retake.
//    (v0.8.6 recorded over shots/NNN.wav itself: Esc after a re-record lost the original for good.)
//  • CardBatches — which shots batches still hold cards at launch: any batch, however old, with a capture that is
//    still a card or was dragged out (v0.8.6 looked at the last 30 days only, and older cards vanished).

import Foundation

public enum NoteEdit {
    /// What the edit field starts with: the note as the card shows it ("" when there is none).
    public static func field(typed: String?, said: String?) -> String { CardNote.merged(typed: typed, said: said) ?? "" }

    /// The note after the edit bubble was saved. `opened…`: the note when the bubble opened; `currentSaid`: its words
    /// now (they may have arrived while it was open); `retaken`: a new recording was kept (its words are to come).
    /// `fieldHoldsSaid`: the field still shows the words said — false once a re-record set it to the typed part (the
    /// new take's words were to replace them); if that take was not kept, the words said stay as they were.
    public static func apply(openedTyped: String?, openedSaid: String?, currentSaid: String?, field: String,
                             fieldHoldsSaid: Bool = true, retaken: Bool) -> (typed: String?, said: String?) {
        let edited = CardNote.clean(field)
        if retaken { return (edited, nil) }
        let base = fieldHoldsSaid ? self.field(typed: openedTyped, said: openedSaid) : (openedTyped ?? "")
        if edited == CardNote.clean(base) { return (openedTyped, currentSaid) }
        if fieldHoldsSaid, CardNote.clean(openedSaid) != nil {
            // the words were in the field: the edited text is the note's words now
            guard let e = edited else { return (nil, openedSaid) }
            return (nil, e)
        }
        return (edited, currentSaid)
    }
}

public enum VoiceRetake {
    /// "shots/005.wav" → "shots/005.retake.wav"
    public static func path(for rel: String) -> String {
        let ext = (rel as NSString).pathExtension
        let base = (rel as NSString).deletingPathExtension
        return base + ".retake" + (ext.isEmpty ? "" : "." + ext)
    }

    /// The retake was kept: it takes the original's place (atomically when there is one).
    @discardableResult
    public static func commit(_ retake: URL, over original: URL, fileManager fm: FileManager = .default) -> Bool {
        guard fm.fileExists(atPath: retake.path) else { return false }
        if fm.fileExists(atPath: original.path) {
            return (try? fm.replaceItemAt(original, withItemAt: retake)) != nil
        }
        return (try? fm.moveItem(at: retake, to: original)) != nil
    }

    /// Esc, or nothing said: the retake goes, the original stays as it was.
    public static func discard(_ retake: URL, fileManager fm: FileManager = .default) {
        try? fm.removeItem(at: retake)
    }

    /// Retakes an edit left behind when Blurt quit with its bubble open (never saved, so never the note): they go.
    public static func sweep(_ shots: URL, fileManager fm: FileManager = .default) {
        for f in (try? fm.contentsOfDirectory(at: shots, includingPropertiesForKeys: nil)) ?? []
        where (f.deletingPathExtension().lastPathComponent as NSString).pathExtension == "retake" {
            try? fm.removeItem(at: f)
        }
    }
}

public enum CardBatches {
    /// shots.jsonl (later lines win, key by key) still holds a card — not deleted, not filed (no project, not handed
    /// to the AI) — or a capture dragged out (Recently Taken, or past its days for housekeeping).
    public static func holdsCards(jsonl raw: String) -> Bool {
        var byN: [Int: [String: Any]] = [:]
        for line in raw.split(separator: "\n") {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], let n = o["n"] as? Int else { continue }
            byN[n] = (byN[n] ?? [:]).merging(o) { $1 }
        }
        return byN.values.contains { o in
            guard o["deleted"] as? Bool != true else { return false }
            if o["taken"] is NSNumber { return true }
            return o["project"] as? String == nil && o["assigned_by"] as? String == nil
        }
    }
}
