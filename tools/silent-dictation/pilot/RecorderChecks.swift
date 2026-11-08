// Compile with -D PILOT_CHECKS alongside PilotRecorder.swift and Localization.swift.
// Pass a disposable fixture dataset containing a six-second draft-tone.mov.
import Foundation
import AVFoundation

@main struct RecorderChecks {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let recorder = try Recorder(root: root, sessionID: "fixture")
        for _ in 0..<100 {
            if recorder.draft != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        precondition(recorder.draft != nil, "Draft recovery failed")
        precondition(!recorder.verified, "Recovery must not confirm participant text")
        recorder.includeAudio = true
        recorder.player?.isMuted = true
        recorder.player?.defaultRate = 0.5 // Simulate a stale native player speed.
        recorder.shortcut(35)
        try await Task.sleep(for: .milliseconds(500))
        let start = recorder.player!.currentTime().seconds
        let wall = ProcessInfo.processInfo.systemUptime
        try await Task.sleep(for: .seconds(2))
        let elapsed = ProcessInfo.processInfo.systemUptime - wall
        let advanced = recorder.player!.currentTime().seconds - start
        precondition(recorder.player!.rate == 1 && recorder.player!.defaultRate == 1)
        precondition(abs(advanced - elapsed) < 0.25, "Playback clock differs from wall clock")
        print(String(format: "Playback: %.3f media seconds / %.3f wall seconds, rate 1×", advanced, elapsed))
        recorder.player?.pause()
        recorder.shortcut(36)
        precondition(recorder.draft == nil && recorder.index == 1, "Enter failed to save and advance")
        precondition(recorder.includeAudio && recorder.isSilent, "Silent take erased the remembered audio choice")
        let data = try Data(contentsOf: root.appendingPathComponent("clips/fixture-0.json"))
        let manifest = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        precondition(manifest["reference_verified"] as? Bool == true)
        precondition(manifest["audio_recorded"] as? Bool == true)
        let reopened = try Recorder(root: root, sessionID: "fixture")
        precondition(reopened.includeAudio, "Audio preference did not survive recreation")
        precondition(reopened.take?.id == "fixture-1")
        print("Recovery, explicit submission, advancement, silent-mode preference retention and preference persistence passed.")
        print("Preferred microphone: \(Recorder.preferredMicrophone()?.localizedName ?? "unavailable")")
    }
}
