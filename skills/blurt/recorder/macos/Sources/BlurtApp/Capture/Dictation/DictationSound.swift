// The sounds of a take, for dictation (Fn) and voice notes (⌥V): Peep's peep when the mic is really listening, a
// double peck when the take stops and its words are on their way, one softer peck when it is cancelled.
//
// v1.0.6, the founder: a Fn press that didn't register went unnoticed — they talked, pressed again to stop, and that
// press started the take instead. With a cue for each edge, silence after a press says nothing started, and a start
// peep where a stop peck was expected says the same, before the words are lost.
//
// The start's peep on unless turned off, the stop's off unless turned on (v1.0.8: two cues on every take were too
// much on a fresh install; the start alone still tells a missed press) — record.dictation.sounds / stop_sound;
// Settings → Dictation; the cancel peck goes with the stop's. Never while a screen recording runs: the cue
// would be in it. The start cue waits for the first audio (Dictation.micStarted, NoteVoice.onFirstAudio), so it means
// "talk now", not "key seen". The clips: assets/sounds/build.py → Resources/Sounds (the film's peep and peck, both
// synthesized), copied into Blurt.app by record.py.
import AppKit

enum DictationSound: String, CaseIterable {
    case start, stop, cancel

    /// the start's peep (the key `sounds` predates the stop's own switch)
    static var startOn: Bool { Dictation.settings["sounds"] as? Bool ?? true }
    /// the stop's peck, and the cancel's
    static var stopOn: Bool { Dictation.settings["stop_sound"] as? Bool ?? false }

    /// Plays it when its switch is on and nothing is being recorded; a cue already playing is cut, not doubled.
    func play() {
        guard self == .start ? DictationSound.startOn : DictationSound.stopOn, (NSApp.delegate as? App)?.rec == nil,
              let s = sound else { return }
        if s.isPlaying { s.stop() }
        s.play()
        emit(["event": "dictation_sound", "cue": rawValue])
    }

    private var sound: NSSound? {
        if let s = DictationSound.cache[self] { return s }
        guard let dir = DictationSound.dir,
              let s = NSSound(contentsOf: dir.appendingPathComponent("\(rawValue).wav"), byReference: false) else { return nil }
        DictationSound.cache[self] = s
        return s
    }

    private static var cache: [DictationSound: NSSound] = [:]

    /// Contents/Resources/Sounds in the app, or next to the sources for a plain `swift build` run.
    private static let dir: URL? = {
        var roots: [URL] = []
        if let r = Bundle.main.resourceURL { roots.append(r.appendingPathComponent("Sounds")) }
        // Sources/BlurtApp/Capture/Dictation/DictationSound.swift → Sources/BlurtApp/Resources/Sounds
        roots.append(URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/Sounds"))
        return roots.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("start.wav").path) }
    }()

    /// Loads the clips ahead of the first take (a cold NSSound can lag the first play by ~50 ms).
    static func preload() { DispatchQueue.main.async { allCases.forEach { _ = $0.sound } } }
}
