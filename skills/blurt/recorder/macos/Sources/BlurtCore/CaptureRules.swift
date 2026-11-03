// The capture rules the v0.9 dogfood run asked for (docs/design/next-round.md §K7 细则 v0.9). BlurtApp's NoteBubble,
// VoiceInput, Snapper, App and PermissionGuide do the UI and the files; what they decide is here, so it can be tested
// (CaptureRulesTests).
//
//  • ScreenGrant — a snap or a recording got no picture: Screen Recording is missing (preflight false), stale (macOS
//    says it is on, but ScreenCaptureKit refuses: a grant made for an older build — "re-allow Screen Recording"), or
//    it was a passing failure ("try again").
//  • NoteTyping / NoteEsc — the snap's note bubble: only committed text counts as typed (an IME composition doesn't,
//    and an emptied field shows the words heard again); Esc in two steps (typed text first, then the shot). The bubble
//    never closes by itself (2026-10-31: no pause end, no "Saved" moment): its keys are NoteKeys.
//  • CaptureRoute — where a capture goes once its note is complete: with a project it is filed (with a note, or
//    without one: "Screenshot 14:32"); a spoken note is transcribed first; one whose words couldn't be had (the
//    transcription failed, or a voice note the speech model found no words in) waits as a card that remembers its
//    project and is filed there once Retry has its words — never an empty item.
//  • VoiceKeep — whether a ⌥V voice note is kept: one the user ended (key, Done, letting go, quitting) is kept when it
//    lasted and held a sound above the room (`soundSeconds`: NoteEndpointer's held sound 6 dB over the noise floor),
//    even if the room hid the speech from the endpointer — the speech model decides, and a take with no words stays as
//    audio ("No words recognized · Retry"). A take the user ended that the endpointer heard nothing in is never deleted
//    outright unless it is a slip of the key or digital silence (v0.9-fix2: 13 s of quiet speech in fan noise was
//    deleted): "Didn't hear anything · Keep" (`unsure`) keeps its audio for the Undo window, and Keep files it (the
//    speech model then decides). The stream's segmenter hearing something is a reason to ask (its looser test also
//    hears a fan), and makes an Esc'd take undoable.
//  • VoiceDiscard — a voice note cancelled with Esc waits for its Undo as NNN.discarded.wav, which a quit or a crash
//    never brings back (CaptureRestore ignores it; the next launch sweeps it).
//  • RecordingNotes — a recording's snap notes pause the take once per note session, however often the bubble
//    switches between its snaps, and the take resumes when the last one closes (only if the notes paused it).
//  • MicWatchdog — a microphone that stopped delivering (AirPods gone, the input device changed) ends the note.
//  • CaptureRestore / WavRepair — captures a quit or a crash left half-done come back at launch: a project capture
//    that was never filed, and a voice note's wav without its shots.jsonl line (its header is rewritten from the size).
//  • TakeEnd — a recording that failed (writer error, no frames) keeps the stills and notes taken during it.
import Foundation

// MARK: - The picker's last area

/// "L last area" (the snap picker): the area of the last snap that produced a picture — saved only once the picture
/// exists (v0.9-fix2: a snap that failed still saved its area), and offered only while it is on a display that is
/// still there (one unplugged since: no L).
public enum LastArea {
    /// `saved`: global top-left points; `screens`: the displays' frames in the same coordinates.
    public static func usable(_ saved: CGRect?, screens: [CGRect]) -> CGRect? {
        guard let r = saved, r.width >= 1, r.height >= 1 else { return nil }
        return screens.contains { $0.intersects(r) } ? r : nil
    }
}

// MARK: - Screen Recording

public enum ScreenGrant: String, Equatable {
    /// macOS doesn't allow it: "needs Screen Recording" → the permission guide
    case missing
    /// allowed, but ScreenCaptureKit refuses (an older build's grant): "re-allow Screen Recording" → remove + add, relaunch
    case stale
    /// allowed and working: the capture failed once — "try again"
    case passing

    /// `preflight`: CGPreflightScreenCaptureAccess; `probe`: SCShareableContent answered (nil: not asked).
    public static func diagnose(preflight: Bool, probe: Bool?) -> ScreenGrant {
        guard preflight else { return .missing }
        return probe == false ? .stale : .passing
    }
}

// MARK: - The note bubble

public enum NoteTyping {
    /// The text the user has committed: the field's text without an IME composition still under way (marked text).
    public static func committed(_ text: String, marked: NSRange?) -> String {
        guard let m = marked, m.location != NSNotFound, m.length > 0 else { return text }
        let ns = text as NSString
        guard m.location <= ns.length else { return text }
        let r = NSRange(location: m.location, length: min(m.length, ns.length - m.location))
        return ns.replacingCharacters(in: r, with: "")
    }

    /// Typed = something committed that isn't just spaces. An emptied field is not typed any more.
    public static func typed(_ text: String, marked: NSRange?) -> Bool {
        !committed(text, marked: marked).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Esc in the note bubble.
public enum NoteEsc: Equatable {
    /// the typed text goes; the shot (and what was said and drawn) stays, the bubble stays open
    case clearText
    /// a fresh shot is discarded (with Undo); an edit goes back to what it was; a recording's note resumes
    case close

    /// `fresh`: a shot just taken (not an edit, not a recording's note); `field`: what the field holds.
    public static func action(fresh: Bool, field: String) -> NoteEsc {
        fresh && !field.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .clearText : .close
    }
}

// MARK: - Where a capture goes

public enum CaptureRoute: Equatable {
    /// filed into this project now (captures.py, no agent)
    case file(String)
    /// its spoken note is transcribed first, then it is routed again
    case transcribeFirst
    /// it hangs as a card (auto mode, or dragged / sorted later)
    case card
    /// its words couldn't be had: a card that keeps its project (filed there once Retry has the words)
    case cardKeepingProject(String)
    /// nothing to do (filed elsewhere, deleted, a card waiting)
    case none

    /// `project`: the capture's project when it was taken with one (assigned by "capture"), else nil; `intended`: the
    /// project a card remembers from words it couldn't get; `needsWords`: a spoken note without words yet (not given
    /// up on); `noWords`: its spoken note gave no words — the transcription failed, or it is a voice note the speech
    /// model found none in (a shot's empty voice is just dropped: the picture is its content); `hasNote`: typed text
    /// or words said. A voice note with nothing typed and no words is never filed as an empty item.
    public static func decide(project: String?, intended: String?, isCard: Bool, needsWords: Bool, noWords: Bool,
                              hasNote: Bool) -> CaptureRoute {
        if let p = project {
            if needsWords { return .transcribeFirst }
            if noWords && !hasNote { return .cardKeepingProject(p) }
            return .file(p)
        }
        if isCard, let p = intended {
            if needsWords { return .transcribeFirst }
            return noWords && !hasNote ? .none : .file(p)
        }
        return isCard && needsWords ? .transcribeFirst : isCard ? .card : .none
    }
}

// MARK: - Voice notes

public enum VoiceKeep: Equatable {
    public enum Ended: String, Equatable {
        /// the key again, Done, letting go of a held key, Blurt quitting
        case user
        /// Esc
        case cancel
        /// nothing heard within the no-speech time
        case noSpeech
        /// the pause after speech (end on pause), or the maximum length
        case silence, maxed
        /// the microphone went away mid-note
        case micLost
        /// the microphone never started
        case noMic
    }

    /// what the island says when nothing is kept (`micLost`: the mic went, what was said is kept; `micGone`: it went
    /// before anything was said)
    public enum Toast: Equatable { case none, nothing, checkMic, micLost, micGone }

    case keep(toast: Toast)
    /// discarded with "Voice note discarded · Undo"
    case undoable
    /// nothing was heard in a take the user ended: "Didn't hear anything · Keep" — the audio waits for the answer
    case unsure
    case drop(toast: Toast)

    /// A take shorter than this the user ended is a slip of the key, not a note.
    public static let minUserSeconds = 1.5
    /// A take with less held sound above the room than this is the room alone (a fan, a hum, a muted input) — not a
    /// note the endpointer missed. Quiet speech in a café holds 0.7 s in 9 s; steady noise holds none.
    public static let minSoundSeconds = 0.4
    /// Below this peak a take is digital silence (a muted input, a virtual device with nothing on it): nothing to keep.
    public static let silencePeakDB = -60.0

    /// `heardSpeech`: the endpointer heard speech; `soundSeconds`: how long the take held a sound above the room
    /// (NoteEndpointer.soundSeconds); `streamHeard`: the stream's segmenter heard speech in a piece (it cuts and
    /// transcribes pieces with a looser test than the endpointer's); `peakDB`: the take's loudest moment.
    public static func decide(_ ended: Ended, heardSpeech: Bool, seconds: Double, soundSeconds: Double,
                              streamHeard: Bool = false, peakDB: Double = -.infinity) -> VoiceKeep {
        let sound = seconds >= minUserSeconds && soundSeconds >= minSoundSeconds
        // the user ended it after a while and it isn't digital silence (or the segmenter heard something): ask, never
        // delete in silence — the segmenter's looser test also hears a fan, so it is a reason to ask, not to keep
        let ask = seconds >= minUserSeconds && (peakDB > silencePeakDB || streamHeard)
        switch ended {
        case .cancel: return heardSpeech || streamHeard ? .undoable : .drop(toast: .none)
        case .noMic: return .drop(toast: .none)
        case .noSpeech: return .drop(toast: .checkMic)
        case .user, .maxed: return heardSpeech || sound ? .keep(toast: .none) : ask ? .unsure : .drop(toast: .nothing)
        case .silence: return heardSpeech || sound ? .keep(toast: .none) : .drop(toast: .nothing)
        case .micLost: return heardSpeech || sound ? .keep(toast: .micLost) : .drop(toast: .micGone)
        }
    }
}

/// A running microphone that stopped delivering buffers (a Bluetooth headset gone, the input device switched: macOS
/// stops the engine). Only after the first buffer: a headset switching profiles may take a second or two to start.
public enum MicWatchdog {
    public static let timeout = 1.5

    public static func stalled(now: Double, firstAudio: Double?, lastBuffer: Double?, timeout: Double = MicWatchdog.timeout) -> Bool {
        guard firstAudio != nil, let last = lastBuffer else { return false }
        return now - last > timeout
    }
}

// MARK: - After a quit or a crash

public enum CaptureRestore {
    /// shots.jsonl folded by n (later lines win, key by key).
    public static func fold(_ raw: String) -> [Int: [String: Any]] {
        var byN: [Int: [String: Any]] = [:]
        for line in raw.split(separator: "\n") {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], let n = o["n"] as? Int else { continue }
            byN[n] = (byN[n] ?? [:]).merging(o) { $1 }
        }
        return byN
    }

    /// Captures taken with a project that were never filed (Blurt quit before their words came back or before
    /// captures.py ran): assigned by "capture", a project, not deleted or dragged out, and no batch.json local id C-NNN.
    public static func unfiled(jsonl raw: String, filed: Set<String>) -> [Int] {
        fold(raw).filter { n, o in
            o["assigned_by"] as? String == "capture" && o["project"] is String && o["deleted"] as? Bool != true
                && !(o["taken"] is NSNumber) && !filed.contains(String(format: "C-%03d", n))
        }.keys.sorted()
    }

    /// shots/NNN.wav files with no shots.jsonl line: voice notes cut off by a quit or a crash (a retake is not one).
    public static func orphanVoices(files: [String], known: Set<Int>) -> [Int] {
        files.compactMap { f -> Int? in
            guard f.hasSuffix(".wav"), !f.contains(".retake"), let n = Int(f.dropLast(4)), f.count == 7 else { return nil }
            return known.contains(n) ? nil : n
        }.sorted()
    }

    /// The highest n a batch already uses, on disk or in shots.jsonl (a new capture never writes over a cut-off one).
    public static func highestN(files: [String], known: Set<Int>) -> Int {
        let onDisk = files.compactMap { f -> Int? in f.count >= 3 ? Int(f.prefix(3)) : nil }
        return max(onDisk.max() ?? 0, known.max() ?? 0)
    }
}

/// A WAV whose writer never closed it (Blurt quit or crashed mid-note): its RIFF and data chunk sizes still say 0.
/// The header is rewritten from the file's size so the audio can be played and transcribed.
public enum WavRepair {
    /// Where the samples start (the byte after the data chunk's header), nil when it isn't a RIFF/WAVE header.
    public static func dataStart(header: Data) -> Int? {
        let b = [UInt8](header)
        guard b.count >= 12, String(bytes: b[0..<4], encoding: .ascii) == "RIFF", String(bytes: b[8..<12], encoding: .ascii) == "WAVE"
        else { return nil }
        var i = 12
        while i + 8 <= b.count {
            let size = Int(b[i + 4]) | Int(b[i + 5]) << 8 | Int(b[i + 6]) << 16 | Int(b[i + 7]) << 24
            if String(bytes: b[i..<(i + 4)], encoding: .ascii) == "data" { return i + 8 }
            i += 8 + size + (size & 1)
        }
        return nil
    }

    /// The fixed header (the first bytes of the file, up to and including the data chunk's header), or nil when it
    /// isn't a RIFF/WAVE file or needs no repair.
    public static func repair(header: Data, fileSize: Int) -> Data? {
        let b = [UInt8](header)
        guard b.count >= 12, String(bytes: b[0..<4], encoding: .ascii) == "RIFF", String(bytes: b[8..<12], encoding: .ascii) == "WAVE"
        else { return nil }
        var out = b
        func u32(_ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 | Int(b[i + 2]) << 16 | Int(b[i + 3]) << 24 }
        func put(_ v: Int, at i: Int) { for k in 0..<4 { out[i + k] = UInt8((v >> (8 * k)) & 0xFF) } }
        var i = 12
        while i + 8 <= b.count {
            let id = String(bytes: b[i..<(i + 4)], encoding: .ascii) ?? ""
            let size = u32(i + 4)
            if id == "data" {
                let data = max(0, fileSize - (i + 8))
                let riff = max(0, fileSize - 8)
                guard size != data || u32(4) != riff else { return nil }
                put(riff, at: 4)
                put(data, at: i + 4)
                return Data(out)
            }
            i += 8 + size + (size & 1)
        }
        return nil
    }
}

/// A voice note cancelled with Esc: "Discarded · Undo" for a few seconds. Its wav waits under another name, so a quit
/// or a crash in that time never brings it back as a note (CaptureRestore.orphanVoices only takes NNN.wav).
public enum VoiceDiscard {
    /// shots/005.wav → shots/005.discarded.wav
    public static func parked(_ wav: URL) -> URL {
        wav.deletingPathExtension().appendingPathExtension("discarded").appendingPathExtension(wav.pathExtension)
    }

    public static func isParked(_ name: String) -> Bool { name.hasSuffix(".discarded.wav") }

    /// Cancelled notes a quit or a crash left waiting for their Undo: they go.
    public static func sweep(_ shots: URL, fileManager fm: FileManager = .default) {
        for f in (try? fm.contentsOfDirectory(atPath: shots.path)) ?? [] where isParked(f) {
            try? fm.removeItem(at: shots.appendingPathComponent(f))
        }
    }
}

// MARK: - Recordings

/// A recording's snap notes (the island's snap button, ⌥A while recording): the take pauses while a note is open.
public enum RecordingNotes {
    /// The bubble opens on a snap of this take. `open`: its notes were already open (the bubble switches to another
    /// snap; the session goes on); `carriedResume`: that session's resume-on-close; `paused`: the take is paused now.
    /// → pause it now; resume it when the notes close (only when they were what paused it).
    public static func open(alreadyOpen: Bool, carriedResume: Bool, paused: Bool) -> (pause: Bool, resumeOnClose: Bool) {
        alreadyOpen ? (false, carriedResume) : (!paused, !paused)
    }
}

public enum TakeEnd {
    /// sessionEnded codes: 0 saved, 2 cancelled / discarded, 3 capture / setup error, 4 no frames, 5 writer error.
    /// The session folder goes only when nothing in it is worth keeping: a cancelled take, or a failed one with no
    /// stills, no notes and no video that plays (`video`: keepsVideo).
    public static func keepsFolder(code: Int32, stills: Int, notes: Bool, video: Bool = false) -> Bool {
        if code == 0 { return true }
        if code == 2 { return false }
        return stills > 0 || notes || video
    }

    /// A failed take's video is kept when this much of it plays (the recorder writes it in 10 s fragments, so a take
    /// whose writer failed partway plays up to its last fragment). Less than a second is nothing to watch.
    public static func keepsVideo(seconds: Double) -> Bool { seconds >= 1 }
}
