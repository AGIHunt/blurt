// Voice input (K7, ⌥⇧V): talk, and it becomes a capture — no screen recording, just the words.
//
//  • press once: listening starts; 1.5 s of silence after you spoke ends it (record.voice.silence_ms), 120 s at most,
//    nothing heard within 8 s = nothing filed. Press again (or click the island's mic) to finish now; Esc cancels.
//  • hold longer than 0.35 s: push-to-talk — it ends when you let go.
//  • record.voice.mode: auto (both, default) | toggle | hold.
//  • the wav goes to shots/<NNN>.wav of the current store's open shots batch; `transcribe.py note` (K9) fills `said`.
//    Pressing starts `transcribe.py serve --preload` (once; it exits by itself when idle), so the model is warm by the
//    time you stop talking and `note` answers in well under a second.
//    With a current project it goes straight into the island; in auto mode it hangs from the island on a thread.
//  • while recording it does nothing (the recording already has the mic) and says so.
// Tests: BLURT_TEST_MIC_WAV (or BLURT_NOTE_WAV) is fed through the same path instead of the microphone.

import AppKit
import BlurtCore
import Carbon.HIToolbox

final class VoiceInput {
    static let shared = VoiceInput()
    static let holdThreshold: CFTimeInterval = 0.35

    private(set) var active = false
    private(set) var holding = false
    private(set) var levels: [Float] = []
    private(set) var liveText: String?
    private var voice: NoteVoice?
    private var batch: ShotBatch?
    private var n = 0
    private var pressedAt: CFTimeInterval?
    private var startedAt = Date()
    private var heardSpeech = false

    var elapsed: Double { active ? voice?.elapsed ?? Date().timeIntervalSince(startedAt) : 0 }

    private var settings: [String: Any] { recordConfig()["voice"] as? [String: Any] ?? [:] }
    private var mode: String { settings["mode"] as? String ?? "auto" }
    private var silence: Double { (settings["silence_ms"] as? Double ?? 1500) / 1000 }

    // MARK: the hotkey: down / up

    func pressed() {
        if (NSApp.delegate as? App)?.rec != nil {
            island.toast(Loc.t("capture.voice.recording_busy", table: "Capture"), actionTitle: nil, action: nil)
            return
        }
        pressedAt = CACurrentMediaTime()
        if active {
            if mode != "hold" { finish(keep: true) }
            return
        }
        start()
    }

    func released() {
        guard let t = pressedAt else { return }
        pressedAt = nil
        guard active else { return }
        let held = CACurrentMediaTime() - t >= VoiceInput.holdThreshold
        if mode == "hold" || (mode == "auto" && held) {
            if holding || mode == "hold" { finish(keep: true) }
        }
    }

    /// The island's mic button.
    func toggle() { active ? finish(keep: true) : start() }

    func cancel() { if active { finish(keep: false) } }

    // MARK: listening

    private func start() {
        guard !active else { return }
        // one listener at a time: dictation has the microphone (and Esc) until it is done
        if Dictation.shared.phase == .listening {
            island.toast(Loc.t("capture.voice.dictation_busy", table: "Capture"), actionTitle: nil, action: nil)
            return
        }
        if NoteBubble.shared.isOpen { NoteBubble.shared.commit() }
        let b = snapper.openBatch(for: snapper.target)
        let k = b.reserve()
        let url = b.dir.appendingPathComponent("shots/\(ShotBatch.name(k)).wav")
        let v = NoteVoice(url: url)
        v.inject = ProcessInfo.processInfo.environment["BLURT_TEST_MIC_WAV"] ?? ProcessInfo.processInfo.environment["BLURT_NOTE_WAV"]
        v.silenceToEnd = silence
        v.noSpeechTimeout = 8
        v.maxLength = 120
        v.onLevel = { [weak self] l in
            guard let self = self else { return }
            self.levels.append(l)
            if self.levels.count > 120 { self.levels.removeFirst(self.levels.count - 120) }
        }
        v.onSpeech = { [weak self] in self?.heardSpeech = true }
        v.onEnd = { [weak self] e in
            guard let self = self, self.voice === v else { return }
            self.finish(keep: e != .noSpeech, ended: true)
        }
        voice = v
        batch = b
        n = k
        levels = []
        liveText = nil
        heardSpeech = false
        holding = false
        startedAt = Date()
        active = true
        Self.warmSpeechModel()
        registerHotkey(.voiceEsc, key: kVK_Escape, mods: 0)
        emit(["event": "voice_start", "n": k, "session": b.dir.path])
        island.voiceChanged()
        v.start { [weak self] ok in
            guard let self = self, self.voice === v else { return }
            if !ok {
                self.finish(keep: false)
                NoteVoice.toastUnavailable()
            }
        }
        // held past the threshold: push-to-talk — only letting go ends it
        DispatchQueue.main.asyncAfter(deadline: .now() + VoiceInput.holdThreshold) { [weak self] in
            guard let self = self, self.voice === v, self.pressedAt != nil, self.mode != "toggle" else { return }
            self.holding = true
            v.silenceToEnd = .infinity
            v.noSpeechTimeout = .infinity
            emit(["event": "voice_hold"])
            island.voiceChanged()
        }
    }

    private static var server: Process?

    /// K9's voice-note server: answers "already" when one runs (this app's or another), else stays up on its own
    /// (unloads the model after 5 idle minutes, exits after 30).
    /// dictation: its own model (record.dictation.asr_model / the recommended one) — a running server is asked to
    /// load it, a new one preloads it.
    static func warmSpeechModel(dictation: Bool = false) {
        if dictation && WarmServer.running("asr-serve") {
            DispatchQueue.global(qos: .userInitiated).async {
                _ = WarmServer.call("asr-serve", ["cmd": "load", "purpose": "dictation"], timeout: 30)
            }
            return
        }
        if let s = server, s.isRunning { return }
        server = try? ScriptRunner.shared.spawn("transcribe.py", ["serve", "--preload"] + (dictation ? ["--purpose", "dictation"] : [])) { _ in }
    }

    private func finish(keep: Bool, ended: Bool = false) {
        guard active, let v = voice, let b = batch else { return }
        let dur = v.elapsed
        let kept = keep && heardSpeech
        if !ended { v.stop(keep: kept) } else if !kept { v.stop(keep: false) }
        voice = nil
        batch = nil
        active = false
        holding = false
        unregisterHotkey(.voiceEsc)
        emit(["event": "voice_end", "kept": kept, "duration": (dur * 100).rounded() / 100])
        let project = snapper.target
        island.voiceChanged()
        if kept {
            snapper.voiceFinished(batch: b, n: n, duration: dur, project: project.isInbox ? nil : project.id)
        } else if keep {
            island.toast(Loc.t("capture.voice.nothing", table: "Capture"), actionTitle: nil, action: nil)
        }
    }
}
