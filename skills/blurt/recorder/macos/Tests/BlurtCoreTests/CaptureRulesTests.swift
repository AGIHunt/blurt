// BlurtCore/CaptureRules.swift (+ NoteEndpointer.activity / peakDB / soundSeconds, CardNote.noWords,
// CardPasteSequence.arm): the capture rules the v0.9 dogfood run asked for — stale Screen Recording, the note bubble's
// close / typing / Esc / Saved moment, where a capture goes, which voice notes are kept, the mic watchdog, what a quit
// leaves behind (a cancelled note never comes back), a failed recording, a recording's note sessions.
import XCTest
@testable import BlurtCore

final class CaptureRulesTests: XCTestCase {

    // MARK: Screen Recording

    func testScreenGrantTellsMissingStaleAndPassing() {
        XCTAssertEqual(ScreenGrant.diagnose(preflight: false, probe: nil), .missing)
        XCTAssertEqual(ScreenGrant.diagnose(preflight: false, probe: true), .missing)
        // macOS says on, ScreenCaptureKit refuses: an older build's grant — "try again" would never help
        XCTAssertEqual(ScreenGrant.diagnose(preflight: true, probe: false), .stale)
        XCTAssertEqual(ScreenGrant.diagnose(preflight: true, probe: true), .passing)
        XCTAssertEqual(ScreenGrant.diagnose(preflight: true, probe: nil), .passing)
    }

    // MARK: the note bubble

    func testOnlyCommittedTextCountsAsTyping() {
        XCTAssertFalse(NoteTyping.typed("", marked: nil))
        XCTAssertFalse(NoteTyping.typed("  \n", marked: nil))
        XCTAssertTrue(NoteTyping.typed("fb", marked: nil))
        // an IME composition under way ("ni" being composed into 你) is not typing yet
        XCTAssertFalse(NoteTyping.typed("ni", marked: NSRange(location: 0, length: 2)))
        XCTAssertTrue(NoteTyping.typed("你好ni", marked: NSRange(location: 2, length: 2)))
        XCTAssertEqual(NoteTyping.committed("你好ni", marked: NSRange(location: 2, length: 2)), "你好")
        XCTAssertEqual(NoteTyping.committed("abc", marked: NSRange(location: NSNotFound, length: 0)), "abc")
        XCTAssertEqual(NoteTyping.committed("abc", marked: NSRange(location: 2, length: 9)), "ab")
    }

    func testTheBubbleNeverClosesUnderThePen() {
        var h = NoteHold()
        XCTAssertNil(h.closeIn(now: 10), "still listening: the voice decides")
        h.voiceDone = true
        XCTAssertEqual(h.closeIn(now: 10), 0)
        h.drawing = true
        XCTAssertNil(h.closeIn(now: 10), "a stroke is being drawn: never closed under the pen")
        h.drawing = false
        h.lastInk = 10
        XCTAssertEqual(h.closeIn(now: 10.5)!, NoteHold.inkGrace - 0.5, accuracy: 1e-9)
        XCTAssertEqual(h.closeIn(now: 10 + NoteHold.inkGrace + 0.1), 0)
    }

    func testTypingKeepsItOpenOnlyWhileThereIsText() {
        var h = NoteHold()
        h.voiceDone = true
        h.typed = true
        XCTAssertNil(h.closeIn(now: 0), "typed text waits for ⏎")
        h.typed = false
        h.emptiedAt = 5
        XCTAssertEqual(h.closeIn(now: 5)!, NoteHold.emptiedGrace, accuracy: 1e-9)
        XCTAssertEqual(h.closeIn(now: 5 + NoteHold.emptiedGrace), 0)
    }

    func testSavedShowsTheWordsBeforeItCloses() {
        var h = NoteHold()
        h.voiceDone = true
        h.waitingWords = true
        XCTAssertNil(h.closeIn(now: 0), "the words are still coming")
        h.waitingWords = false
        h.savedUntil = 1.2
        XCTAssertEqual(h.closeIn(now: 0)!, 1.2, accuracy: 1e-9)
        XCTAssertEqual(h.closeIn(now: 2), 0)
        h.pinned = true
        XCTAssertNil(h.closeIn(now: 2), "an Esc just cleared the text: the user decides")
    }

    func testTheSavedMomentWaitsForTheReader() {
        var h = NoteHold()
        h.voiceDone = true
        h.savedUntil = 1.2
        // the pointer is over the bubble: it stays a moment after it leaves, however long the words were shown
        h.hovering = true
        XCTAssertEqual(h.closeIn(now: 5)!, NoteHold.hoverGrace, accuracy: 1e-9)
        XCTAssertEqual(h.closeIn(now: 0)!, 1.2, accuracy: 1e-9)
        h.hovering = false
        XCTAssertEqual(h.closeIn(now: 5), 0)
        // hovering doesn't hold anything but the Saved moment (the pen rests on the picture after a circle)
        var ink = NoteHold()
        ink.voiceDone = true
        ink.lastInk = 0
        ink.hovering = true
        XCTAssertEqual(ink.closeIn(now: 10), 0)
        // a click into the words (the app pins it and drops the Saved timer): only ⏎ or Esc closes it
        h.savedUntil = nil
        h.pinned = true
        XCTAssertNil(h.closeIn(now: 10))
    }

    func testEscClearsTypedTextFirstThenDiscards() {
        XCTAssertEqual(NoteEsc.action(fresh: true, field: "the button overlaps"), .clearText)
        XCTAssertEqual(NoteEsc.action(fresh: true, field: "   "), .close)
        XCTAssertEqual(NoteEsc.action(fresh: true, field: ""), .close)
        // an edit or a recording's note: Esc puts it back / resumes, as before
        XCTAssertEqual(NoteEsc.action(fresh: false, field: "edited"), .close)
    }

    // MARK: where a capture goes

    func testAProjectCaptureWithoutANoteGoesToTheProject() {
        XCTAssertEqual(CaptureRoute.decide(project: "p1", intended: nil, isCard: false, needsWords: false, noWords: false, hasNote: false),
                       .file("p1"))
        XCTAssertEqual(CaptureRoute.decide(project: "p1", intended: nil, isCard: false, needsWords: false, noWords: false, hasNote: true),
                       .file("p1"))
        XCTAssertEqual(CaptureRoute.decide(project: "p1", intended: nil, isCard: false, needsWords: true, noWords: false, hasNote: false),
                       .transcribeFirst)
    }

    func testAFailedTranscriptionKeepsItsProject() {
        XCTAssertEqual(CaptureRoute.decide(project: "p1", intended: nil, isCard: false, needsWords: false, noWords: true, hasNote: false),
                       .cardKeepingProject("p1"))
        // typed text next to it: the typed note is enough to file it
        XCTAssertEqual(CaptureRoute.decide(project: "p1", intended: nil, isCard: false, needsWords: false, noWords: true, hasNote: true),
                       .file("p1"))
        // Retry: its words now → filed where it was taken for; failed again → it stays a card
        XCTAssertEqual(CaptureRoute.decide(project: nil, intended: "p1", isCard: true, needsWords: true, noWords: false, hasNote: false),
                       .transcribeFirst)
        XCTAssertEqual(CaptureRoute.decide(project: nil, intended: "p1", isCard: true, needsWords: false, noWords: false, hasNote: true),
                       .file("p1"))
        XCTAssertEqual(CaptureRoute.decide(project: nil, intended: "p1", isCard: true, needsWords: false, noWords: true, hasNote: false),
                       .none)
    }

    func testAVoiceNoteWithNoWordsIsNeverFiledEmpty() {
        // ⌥⇧V with a project, nothing the speech model could read: a card that keeps its project ("No words
        // recognized · Retry"), not an empty item in the project (rvcapture: AW-6 '语音 13:51' with no note)
        XCTAssertEqual(CaptureRoute.decide(project: "p1", intended: nil, isCard: false, needsWords: false, noWords: true, hasNote: false),
                       .cardKeepingProject("p1"))
        // Retry found words: filed there; none again: it stays a card
        XCTAssertEqual(CaptureRoute.decide(project: nil, intended: "p1", isCard: true, needsWords: false, noWords: false, hasNote: true),
                       .file("p1"))
        XCTAssertEqual(CaptureRoute.decide(project: nil, intended: "p1", isCard: true, needsWords: false, noWords: true, hasNote: false),
                       .none)
    }

    func testAutoModeCardsStayCards() {
        XCTAssertEqual(CaptureRoute.decide(project: nil, intended: nil, isCard: true, needsWords: true, noWords: false, hasNote: false),
                       .transcribeFirst)
        XCTAssertEqual(CaptureRoute.decide(project: nil, intended: nil, isCard: true, needsWords: false, noWords: false, hasNote: true), .card)
        XCTAssertEqual(CaptureRoute.decide(project: nil, intended: nil, isCard: false, needsWords: false, noWords: false, hasNote: true), .none)
    }

    // MARK: voice notes

    func testAVoiceNoteTheUserEndedIsKeptWhenTheRoomHidTheSpeech() {
        // the café: quiet speech in noise never passed the endpointer, but held 0.7 s of sound; Done at 9 s
        XCTAssertEqual(VoiceKeep.decide(.user, heardSpeech: false, seconds: 9, soundSeconds: 0.7), .keep(toast: .none))
        XCTAssertEqual(VoiceKeep.decide(.user, heardSpeech: true, seconds: 0.8, soundSeconds: 0.6), .keep(toast: .none))
        // a slip of the key; the room alone (a fan, a hum, a muted input): nothing to keep
        XCTAssertEqual(VoiceKeep.decide(.user, heardSpeech: false, seconds: 0.6, soundSeconds: 0.5), .drop(toast: .nothing))
        XCTAssertEqual(VoiceKeep.decide(.user, heardSpeech: false, seconds: 9, soundSeconds: 0), .drop(toast: .nothing))
        XCTAssertEqual(VoiceKeep.decide(.user, heardSpeech: false, seconds: 4, soundSeconds: 0.2), .drop(toast: .nothing))
    }

    func testANoteThatHeardNothingSaysToCheckTheMic() {
        XCTAssertEqual(VoiceKeep.decide(.noSpeech, heardSpeech: false, seconds: 20, soundSeconds: 0), .drop(toast: .checkMic))
        XCTAssertEqual(VoiceKeep.decide(.noMic, heardSpeech: false, seconds: 0, soundSeconds: 0), .drop(toast: .none))
    }

    func testEscAndMicLoss() {
        XCTAssertEqual(VoiceKeep.decide(.cancel, heardSpeech: true, seconds: 4, soundSeconds: 3), .undoable)
        XCTAssertEqual(VoiceKeep.decide(.cancel, heardSpeech: false, seconds: 4, soundSeconds: 3), .drop(toast: .none))
        XCTAssertEqual(VoiceKeep.decide(.micLost, heardSpeech: true, seconds: 6, soundSeconds: 4), .keep(toast: .micLost))
        // gone before anything was said: not "what was said is kept"
        XCTAssertEqual(VoiceKeep.decide(.micLost, heardSpeech: false, seconds: 0.4, soundSeconds: 0), .drop(toast: .micGone))
        XCTAssertEqual(VoiceKeep.decide(.maxed, heardSpeech: true, seconds: 600, soundSeconds: 300), .keep(toast: .none))
    }

    func testHeldSoundTellsQuietSpeechFromTheRoom() {
        // steady room noise (rvcapture's noise.wav: −41 dBFS, flat): no held sound — a stray ⌥⇧V isn't a note
        var room = NoteEndpointer(sampleRate: 16000)
        _ = feed(&room, NoteEndpointerTests.noise(4, db: -41))
        XCTAssertLessThan(room.soundSeconds, VoiceKeep.minSoundSeconds)
        XCTAssertGreaterThan(room.peakDB, -70, "a real mic's floor is far above digital silence: peak alone can't tell")
        // digital silence
        var mute = NoteEndpointer(sampleRate: 16000)
        _ = feed(&mute, [Float](repeating: 0, count: 64000))
        XCTAssertEqual(mute.soundSeconds, 0)
        // quiet speech a few dB over a café's noise: held sound, though maybe too quiet for the endpointer
        var cafe = NoteEndpointer(sampleRate: 16000)
        _ = feed(&cafe, NoteEndpointerTests.mix(NoteEndpointerTests.noise(1, db: -45),
                                               NoteEndpointerTests.mix(NoteEndpointerTests.noise(8, db: -45, seed: 5),
                                                                       [Float](repeating: 0, count: 16000) + NoteEndpointerTests.talk(6, db: -37))))
        XCTAssertGreaterThanOrEqual(cafe.soundSeconds, VoiceKeep.minSoundSeconds)
        // ordinary speech
        var talk = NoteEndpointer(sampleRate: 16000)
        _ = feed(&talk, NoteEndpointerTests.mix(NoteEndpointerTests.noise(4, db: -60), [Float](repeating: 0, count: 8000) + NoteEndpointerTests.talk(3, db: -24)))
        XCTAssertGreaterThan(talk.soundSeconds, 1)
    }

    func testACancelledVoiceNoteWaitsUnderAnotherName() throws {
        let wav = URL(fileURLWithPath: "/x/shots/005.wav")
        XCTAssertEqual(VoiceDiscard.parked(wav).lastPathComponent, "005.discarded.wav")
        XCTAssertTrue(VoiceDiscard.isParked("005.discarded.wav"))
        XCTAssertFalse(VoiceDiscard.isParked("005.wav"))
        // a quit within its Undo: never an orphan voice note at the next launch
        XCTAssertEqual(CaptureRestore.orphanVoices(files: ["005.discarded.wav", "006.wav"], known: []), [6])
        // …and the next launch sweeps it
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for f in ["005.discarded.wav", "006.wav", "006.png"] { try Data([1]).write(to: dir.appendingPathComponent(f)) }
        VoiceDiscard.sweep(dir)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted(), ["006.png", "006.wav"])
        // a new capture still never takes its number while it waits
        XCTAssertEqual(CaptureRestore.highestN(files: ["005.discarded.wav"], known: [3]), 5)
    }

    func testARecordingsNotesPauseOncePerSession() {
        // opened on a running take: pause it, resume on close
        XCTAssertTrue(RecordingNotes.open(alreadyOpen: false, carriedResume: false, paused: false) == (true, true))
        // the user had paused it: leave it paused
        XCTAssertTrue(RecordingNotes.open(alreadyOpen: false, carriedResume: false, paused: true) == (false, false))
        // the bubble switches to another snap (it is paused by the notes now): the session's resume goes on —
        // the replaced bubble doesn't resume the take under the new one, and the new one still resumes it
        XCTAssertTrue(RecordingNotes.open(alreadyOpen: true, carriedResume: true, paused: true) == (false, true))
        XCTAssertTrue(RecordingNotes.open(alreadyOpen: true, carriedResume: false, paused: true) == (false, false))
    }

    func testTheWatchdogWaitsForTheFirstBuffer() {
        XCTAssertFalse(MicWatchdog.stalled(now: 10, firstAudio: nil, lastBuffer: nil), "a headset may take a while to start")
        XCTAssertFalse(MicWatchdog.stalled(now: 10, firstAudio: 1, lastBuffer: 9.9))
        XCTAssertTrue(MicWatchdog.stalled(now: 10, firstAudio: 1, lastBuffer: 10 - MicWatchdog.timeout - 0.1))
    }

    func testDrawingHoldsTheNotesPause() {
        // speech, then quiet: ends 1.8 s into the quiet — unless the pen is moving on the picture
        var e = NoteEndpointer(sampleRate: 16000)
        let talk = NoteEndpointerTests.mix(NoteEndpointerTests.talk(2, db: -24), NoteEndpointerTests.noise(2, db: -60))
        var started = false
        for ev in feed(&e, talk) where ev == .speechStarted { started = true }
        XCTAssertTrue(started)
        let quiet = NoteEndpointerTests.noise(1.5, db: -60, seed: 9)
        XCTAssertTrue(feed(&e, quiet).isEmpty)
        e.activity(grace: 2.5)                      // the stroke goes on…
        XCTAssertTrue(feed(&e, NoteEndpointerTests.noise(2.0, db: -60, seed: 10)).isEmpty, "the pause waits for the pen")
        XCTAssertEqual(feed(&e, NoteEndpointerTests.noise(1.0, db: -60, seed: 12)), [.ended(.silence)])
    }

    func testDrawingHoldsTheNoSpeechEnd() {
        var e = NoteEndpointer(sampleRate: 16000)
        e.noSpeechTimeout = 2
        XCTAssertTrue(feed(&e, NoteEndpointerTests.noise(1.5, db: -60)).isEmpty)
        e.activity(grace: 2.5)
        XCTAssertTrue(feed(&e, NoteEndpointerTests.noise(1.5, db: -60, seed: 3)).isEmpty, "a silent snap being circled stays open")
        XCTAssertEqual(feed(&e, NoteEndpointerTests.noise(1.5, db: -60, seed: 4)), [.ended(.noSpeech)])
    }

    func testPeakTellsDigitalSilenceFromAQuietRoom() {
        var a = NoteEndpointer(sampleRate: 16000)
        _ = feed(&a, [Float](repeating: 0, count: 32000))
        XCTAssertLessThan(a.peakDB, -100)
        var b = NoteEndpointer(sampleRate: 16000)
        _ = feed(&b, NoteEndpointerTests.noise(2, db: -45))
        XCTAssertGreaterThan(b.peakDB, -50)
    }

    private func feed(_ e: inout NoteEndpointer, _ x: [Float]) -> [NoteEndpointer.Event] {
        var out: [NoteEndpointer.Event] = []
        var i = 0
        while i < x.count { out += e.feed(Array(x[i..<min(x.count, i + 1600)])); i += 1600 }
        return out
    }

    // MARK: after a quit or a crash

    func testUnfiledProjectCapturesComeBack() {
        let raw = """
        {"n":1,"type":"shot","project":"p1","assigned_by":"capture","voice":"shots/001.wav"}
        {"n":2,"type":"shot","project":"p1","assigned_by":"capture"}
        {"n":3,"type":"shot","project":null}
        {"n":4,"type":"shot","project":"p1","assigned_by":"capture"}
        {"n":4,"deleted":true}
        {"n":5,"type":"shot","project":"p1","assigned_by":"user"}
        {"n":6,"type":"shot","project":"p1","assigned_by":"capture","taken":17000}
        """
        // 2 was filed (batch.json local C-002); 3 is a card; 4 deleted; 5 assigned by the user (filed as it was dragged)
        XCTAssertEqual(CaptureRestore.unfiled(jsonl: raw, filed: ["C-002"]), [1])
        XCTAssertEqual(CaptureRestore.unfiled(jsonl: raw, filed: []), [1, 2])
    }

    func testACutOffVoiceNoteIsFoundAndNeverWrittenOver() {
        let files = ["001.png", "001.wav", "001.marked.png", "002.wav", "003.retake.wav", "004.png"]
        XCTAssertEqual(CaptureRestore.orphanVoices(files: files, known: [1, 4]), [2])
        XCTAssertEqual(CaptureRestore.highestN(files: files, known: [1]), 4)
        XCTAssertEqual(CaptureRestore.highestN(files: [], known: []), 0)
    }

    func testAWavLeftOpenGetsItsHeaderBack() {
        // RIFF/WAVE, a 16-byte fmt chunk, a FLLR pad, then data — every size 0, as a writer that never closed leaves it
        var h = Data("RIFF".utf8) + le(0) + Data("WAVE".utf8)
        h += Data("fmt ".utf8) + le(16) + Data(count: 16)
        h += Data("FLLR".utf8) + le(8) + Data(count: 8)
        h += Data("data".utf8) + le(0)
        let start = h.count
        XCTAssertEqual(WavRepair.dataStart(header: h), start)
        let size = start + 32000
        let fixed = WavRepair.repair(header: h, fileSize: size)!
        XCTAssertEqual(u32(fixed, 4), size - 8)
        XCTAssertEqual(u32(fixed, start - 4), 32000)
        XCTAssertNil(WavRepair.repair(header: fixed, fileSize: size), "a good header needs nothing")
        XCTAssertNil(WavRepair.repair(header: Data("not a wav".utf8), fileSize: 100))
    }

    private func le(_ v: Int) -> Data { Data([UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24 & 0xFF)]) }
    private func u32(_ d: Data, _ i: Int) -> Int { let b = [UInt8](d); return Int(b[i]) | Int(b[i + 1]) << 8 | Int(b[i + 2]) << 16 | Int(b[i + 3]) << 24 }

    // MARK: recordings

    func testAFailedRecordingKeepsItsStills() {
        XCTAssertTrue(TakeEnd.keepsFolder(code: 0, stills: 0, notes: false))
        XCTAssertFalse(TakeEnd.keepsFolder(code: 2, stills: 3, notes: true), "discarded on purpose")
        XCTAssertTrue(TakeEnd.keepsFolder(code: 5, stills: 3, notes: false), "the writer failed: the stills stay")
        XCTAssertTrue(TakeEnd.keepsFolder(code: 4, stills: 0, notes: true))
        XCTAssertFalse(TakeEnd.keepsFolder(code: 3, stills: 0, notes: false), "nothing in it: no empty folder")
    }

    // MARK: cards

    func testAVoiceNoteWithNoWordsOffersRetry() {
        let n = CardNote.make(typed: nil, said: "", hasVoice: true, transcription: .idle)
        XCTAssertEqual(n.status, .noWords)
        XCTAssertTrue(n.status.needsRetry)
        XCTAssertFalse(n.showsMic)
        XCTAssertEqual(CardNote.make(typed: nil, said: nil, hasVoice: true, transcription: .idle).status, .transcribing)
        XCTAssertEqual(CardNote.make(typed: nil, said: "", hasVoice: true, transcription: .pending).status, .transcribing,
                       "a Retry under way")
        XCTAssertTrue(CardNote.make(typed: nil, said: nil, hasVoice: true, transcription: .failed).status.needsRetry)
        XCTAssertFalse(CardNote.make(typed: nil, said: nil, hasVoice: true, transcription: .idle).status.needsRetry)
    }

    func testClickCopyWithoutAccessibilityIsNotArmed() {
        let both = [PasteStep.image(URL(fileURLWithPath: "/tmp/a.png")), .text("note")]
        XCTAssertEqual(CardPasteSequence.arm(enabled: true, steps: both, accessibility: true), .arm)
        XCTAssertEqual(CardPasteSequence.arm(enabled: true, steps: both, accessibility: false), .needsAccessibility)
        XCTAssertEqual(CardPasteSequence.arm(enabled: false, steps: both, accessibility: true), .skip("off"))
        XCTAssertEqual(CardPasteSequence.arm(enabled: true, steps: [.text("note")], accessibility: false), .skip("one_thing"))
    }
}
