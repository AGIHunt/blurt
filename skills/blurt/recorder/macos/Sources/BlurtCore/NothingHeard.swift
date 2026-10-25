// A dictation that heard nothing (Capture/Dictation/Dictation.swift: no speech before the key-up, or an empty
// transcript): the island names the microphone it listened with and offers the way to change it, instead of a bare
// "Didn't catch anything". Whether the mic gave any sound at all decides the words: a level that never left the floor
// the whole take is a mic that gives silence (muted, the wrong input, a Bluetooth headset still connecting) — "No
// sound from AirPods" — anything else is "Didn't catch anything (AirPods)". Unit-tested in Tests/BlurtCoreTests/NothingHeardTests.
import Foundation

public enum NothingHeard {
    public enum Why: String, Equatable { case silentMic = "silent_mic", noSpeech = "no_speech" }

    /// The floor: NoteVoice's level is 0 at −55 dB and below (1 at −10 dB); a room's own noise sits above it.
    public static let floor: Float = 0.01

    /// `levels`: the take's mic levels (0…1). Too few to tell (the take was a blink): no speech, not a silent mic.
    public static func why(levels: [Float]) -> Why {
        levels.count >= 5 && (levels.max() ?? 0) < floor ? .silentMic : .noSpeech
    }

    /// The string key for the line (Dictation table) — with a mic name, or the plain line without one.
    public static func key(_ why: Why, hasName: Bool) -> String {
        guard hasName else { return "dictation.toast.nothing" }
        return why == .silentMic ? "dictation.toast.nothing.silent" : "dictation.toast.nothing.named"
    }
}
