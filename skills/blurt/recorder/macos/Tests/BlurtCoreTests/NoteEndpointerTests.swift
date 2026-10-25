// BlurtCore/NoteEndpointer.swift: the voice note's speech start and the pause that ends it — in quiet rooms, noisy
// rooms (white / pink noise at real laptop-mic levels), with key clicks, and with a real `say` voice.
import AVFoundation
import XCTest
@testable import BlurtCore

final class NoteEndpointerTests: XCTestCase {
    static let sr = 16000.0

    /// Deterministic noise.
    struct Rng {
        var s: UInt64
        mutating func next() -> Float {
            s ^= s << 13; s ^= s >> 7; s ^= s << 17
            return Float(s % 2_000_001) / 1_000_000 - 1
        }
    }

    enum Noise { case none, white, pink }

    /// `seconds` of noise at `db` dBFS RMS.
    static func noise(_ seconds: Double, db: Float, kind: Noise = .pink, seed: UInt64 = 7) -> [Float] {
        let n = Int(seconds * sr)
        guard kind != .none else { return [Float](repeating: 0, count: n) }
        var r = Rng(s: seed | 1)
        var b0: Float = 0, b1: Float = 0, b2: Float = 0
        var x = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let w = r.next()
            if kind == .white { x[i] = w; continue }
            b0 = 0.99765 * b0 + w * 0.0990460       // Paul Kellet's economy pink filter
            b1 = 0.96300 * b1 + w * 0.2965164
            b2 = 0.57000 * b2 + w * 1.0526913
            x[i] = b0 + b1 + b2 + w * 0.1848
        }
        return scaled(x, to: db)
    }

    static func scaled(_ x: [Float], to db: Float) -> [Float] {
        let rms = NoteEndpointer.level(x)
        let k = pow(10, (db - rms) / 20)
        return x.map { $0 * k }
    }

    /// Something like talking: voiced syllables (a 140 Hz buzz with harmonics), ~4 per second, short gaps between them
    /// and a longer one between "words"; `db` = the syllables' level.
    static func talk(_ seconds: Double, db: Float, seed: UInt64 = 3) -> [Float] {
        let n = Int(seconds * sr)
        var x = [Float](repeating: 0, count: n)
        var r = Rng(s: seed | 1)
        var t = 0
        var syll = 0
        while t < n {
            let len = Int((0.16 + 0.08 * Double(abs(r.next()))) * sr)
            let f0 = 120 + 40 * Double(abs(r.next()))
            for i in 0..<min(len, n - t) {
                let env = sin(Double.pi * Double(i) / Double(len))
                let ph = 2 * Double.pi * f0 * Double(i) / sr
                x[t + i] = Float(env * (sin(ph) + 0.5 * sin(2 * ph) + 0.3 * sin(3 * ph) + 0.15 * sin(5 * ph)))
            }
            syll += 1
            t += len + Int((syll % 4 == 0 ? 0.22 : 0.05) * sr)
        }
        return scaled(x, to: db + 2)        // the gaps pull the RMS down; the syllables sit near `db`
    }

    static func mix(_ a: [Float], _ b: [Float]) -> [Float] {
        (0..<max(a.count, b.count)).map { (($0 < a.count) ? a[$0] : 0) + (($0 < b.count) ? b[$0] : 0) }
    }

    /// Key clicks: 25 ms bursts every `every` s, at `db`.
    static func clicks(_ seconds: Double, every: Double, db: Float) -> [Float] {
        var x = [Float](repeating: 0, count: Int(seconds * sr))
        var r = Rng(s: 99)
        var t = 0.05
        while t < seconds - 0.03 {
            let s = Int(t * sr)
            for i in 0..<Int(0.025 * sr) { x[s + i] = r.next() * Float(exp(-Double(i) / (0.006 * sr))) }
            t += every
        }
        let burst = Array(x[Int(0.05 * sr)..<Int(0.05 * sr) + Int(0.025 * sr)])
        let k = pow(10, (db - NoteEndpointer.level(burst)) / 20)
        return x.map { $0 * k }
    }

    struct Run { var started: Double?; var ended: (NoteEndpointer.End, Double)?; var speech: Double }

    /// Feeds `x` in 100 ms buffers (as the mic tap does); when speech started and when it ended.
    static func run(_ x: [Float], configure: (inout NoteEndpointer) -> Void = { _ in }) -> Run {
        var e = NoteEndpointer(sampleRate: sr)
        configure(&e)
        var r = Run(started: nil, ended: nil, speech: 0)
        var i = 0
        let chunk = Int(sr / 10)
        while i < x.count, r.ended == nil {
            for ev in e.feed(Array(x[i..<min(x.count, i + chunk)])) {
                switch ev {
                case .speechStarted: r.started = e.heard
                case .ended(let end): r.ended = (end, e.heard)
                }
            }
            i += chunk
        }
        r.speech = e.speechSeconds
        return r
    }

    /// The user's own mic (shots/002.wav): −52 dBFS for the first 0.2 s, then the room at about −42.
    static func room(_ seconds: Double, db: Float, kind: Noise = .pink) -> [Float] {
        noise(0.2, db: -52, kind: .white, seed: 11) + noise(seconds - 0.2, db: db, kind: kind, seed: 5)
    }

    /// v0.7's detector (NoteBubble's NoteVoice.feed), for the record: 100 ms buffers, the floor = the quietest of the
    /// first three, frozen once speech started. Returns when it ended the note (nil: never).
    static func legacyEnd(_ x: [Float]) -> Double? {
        var floorDB: Float = -60, floorN = 0, speaking = false, loudRun = 0.0, silentFor = 0.0, heard = 0.0
        let n = Int(sr / 10)
        var i = 0
        while i + n <= x.count {
            let db = NoteEndpointer.level(x[i..<(i + n)])
            let dt = 0.1
            heard += dt
            if floorN < 3 { floorDB = floorN == 0 ? db : min(floorDB, db); floorN += 1 }
            else if !speaking { floorDB = db < floorDB ? db : floorDB + Float(dt) * 0.5 }
            let on = max(floorDB + 12, -48), off = max(floorDB + 6, -54)
            if !speaking {
                loudRun = db > on ? loudRun + dt : 0
                if loudRun >= 0.2 { speaking = true; silentFor = 0 } else if heard >= 8 { return heard }
            } else {
                silentFor = db < off ? silentFor + dt : 0
                if silentFor >= 1.8 { return heard }
            }
            i += n
        }
        return nil
    }

    // MARK: the bug: a room louder than its first moments

    func testEndsInARoomLouderThanTheMicsFirstMoments() {
        let lead = 0.8, said = 2.4
        let total = lead + said + 4
        let x = Self.mix(Self.room(total, db: -42), [Float](repeating: 0, count: Int(lead * Self.sr)) + Self.talk(said, db: -24))
        XCTAssertNil(Self.legacyEnd(x), "the old detector should reproduce the bug here (it never ended)")
        let r = Self.run(x)
        XCTAssertNotNil(r.started)
        XCTAssertEqual(r.ended?.0, .silence)
        let endsAt = r.ended?.1 ?? 99
        XCTAssertGreaterThan(endsAt, lead + said + 1.6, "ended in the middle of talking")
        XCTAssertLessThan(endsAt, lead + said + 2.6, "1.8 s of the room after talking should end it")
        XCTAssertGreaterThan(r.speech, 1.0)
    }

    func testEndsInPinkAndWhiteNoiseAtLaptopLevels() {
        for kind in [Noise.pink, .white] {
            for db: Float in [-55, -48, -42, -38] {
                let x = Self.mix(Self.room(7, db: db, kind: kind), [Float](repeating: 0, count: Int(0.6 * Self.sr)) + Self.talk(2, db: -22))
                let r = Self.run(x)
                XCTAssertNotNil(r.started, "\(kind) \(db): speech not heard")
                XCTAssertEqual(r.ended?.0, .silence, "\(kind) \(db)")
                XCTAssertLessThan(r.ended?.1 ?? 99, 0.6 + 2 + 2.6, "\(kind) \(db): the pause didn't end it")
            }
        }
    }

    func testEndsInDigitalSilence() {
        let x = Self.talk(1.5, db: -20) + [Float](repeating: 0, count: Int(3 * Self.sr))
        let r = Self.run(x)
        XCTAssertNotNil(r.started, "talking from the first moment is still talking")
        XCTAssertEqual(r.ended?.0, .silence)
        XCTAssertLessThan(r.ended?.1 ?? 99, 1.5 + 2.4)
    }

    func testQuietSecondsWhenSilenceNeverEnds() {
        // dictation hands-free: silence never ends the take, so `speaking` stays on — `quietSeconds` still says how
        // long nobody has talked (the "still listening" reminder goes by it)
        var e = NoteEndpointer(sampleRate: Self.sr)
        e.silenceToEnd = .infinity
        e.noSpeechTimeout = .infinity
        e.maxLength = .infinity
        _ = e.feed(Self.talk(2, db: -20))
        XCTAssertTrue(e.speaking)
        XCTAssertLessThan(e.quietSeconds, 0.5)
        _ = e.feed([Float](repeating: 0, count: Int(25 * Self.sr)))
        XCTAssertTrue(e.speaking)
        XCTAssertGreaterThan(e.quietSeconds, 24)
        // before anyone spoke: the whole time
        var q = NoteEndpointer(sampleRate: Self.sr)
        q.noSpeechTimeout = .infinity
        _ = q.feed([Float](repeating: 0, count: Int(3 * Self.sr)))
        XCTAssertEqual(q.quietSeconds, 3, accuracy: 0.05)
    }

    // MARK: what isn't speech

    func testTheRoomAloneIsNoSpeech() {
        for kind in [Noise.pink, .white, .none] {
            for db: Float in [-70, -55, -42, -32] {
                let r = Self.run(Self.room(9, db: db, kind: kind))
                XCTAssertNil(r.started, "\(kind) \(db) dBFS counted as speech")
                XCTAssertEqual(r.ended?.0, .noSpeech, "\(kind) \(db)")
                XCTAssertEqual(r.ended?.1 ?? 0, 8, accuracy: 0.05)
            }
        }
    }

    func testKeyClicksAreNotSpeech() {
        for every in [0.3, 0.14, 0.1] {         // typing, up to ten keys a second
            let x = Self.mix(Self.room(9, db: -45), Self.clicks(9, every: every, db: -18))
            XCTAssertNil(Self.run(x).started, "a key every \(every) s counted as speech")
        }
    }

    func testClicksInThePauseDontKeepItOpen() {
        let lead = 0.6, said = 2.0
        let pause = Self.clicks(4, every: 0.3, db: -20)
        let voice = [Float](repeating: 0, count: Int(lead * Self.sr)) + Self.talk(said, db: -24) + pause
        let r = Self.run(Self.mix(Self.room(lead + said + 4, db: -44), voice))
        XCTAssertEqual(r.ended?.0, .silence)
        XCTAssertLessThan(r.ended?.1 ?? 99, lead + said + 2.6)
    }

    // MARK: what is

    func testShortPausesWhileTalkingDontEndIt() {
        // three phrases with 1.2 s pauses: still one note
        let phrase = Self.talk(1.5, db: -24)
        let gap = [Float](repeating: 0, count: Int(1.2 * Self.sr))
        let voice = [Float](repeating: 0, count: Int(0.5 * Self.sr)) + phrase + gap + phrase + gap + phrase
        let total = Double(voice.count) / Self.sr + 3
        let r = Self.run(Self.mix(Self.room(total, db: -44), voice))
        XCTAssertEqual(r.ended?.0, .silence)
        XCTAssertGreaterThan(r.ended?.1 ?? 0, Double(voice.count) / Self.sr + 1.6)
    }

    func testMaxLength() {
        let r = Self.run(Self.mix(Self.room(12, db: -45), Self.talk(12, db: -22))) { $0.maxLength = 5 }
        XCTAssertEqual(r.ended?.0, .maxed)
        XCTAssertEqual(r.ended?.1 ?? 0, 5, accuracy: 0.05)
    }

    func testNoSpeechTimeoutCanBeExtended() {
        let r = Self.run(Self.room(14, db: -45)) { $0.noSpeechTimeout = 12 }
        XCTAssertEqual(r.ended?.0, .noSpeech)
        XCTAssertEqual(r.ended?.1 ?? 0, 12, accuracy: 0.05)
    }

    func testOddBufferSizes() {
        let x = Self.mix(Self.room(7, db: -42), [Float](repeating: 0, count: 8000) + Self.talk(2, db: -24))
        var e = NoteEndpointer(sampleRate: Self.sr)
        var events: [NoteEndpointer.Event] = []
        var i = 0
        var k = 1
        while i < x.count, e.ended == nil {
            let n = [1, 77, 319, 320, 321, 1600, 4801][k % 7]
            events += e.feed(Array(x[i..<min(x.count, i + n)]))
            i += n; k += 1
        }
        XCTAssertEqual(events.first, .speechStarted)
        XCTAssertEqual(events.last, .ended(.silence))
    }

    // MARK: a real voice (macOS `say`), in the room

    /// `say` → 16 kHz mono samples at `db` dBFS (skips the test where there is no `say`).
    static func say(_ text: String, db: Float, voice: String? = nil) throws -> [Float] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("blurt-endpointer-\(getpid())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("say.wav")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        p.arguments = (voice.map { ["-v", $0] } ?? []) + ["-o", wav.path, "--file-format=WAVE", "--data-format=LEI16@16000", text]
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0, let f = try? AVAudioFile(forReading: wav),
              let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)) else {
            throw XCTSkip("say isn't available here")
        }
        try f.read(into: buf)
        XCTAssertEqual(f.processingFormat.sampleRate, sr)
        return scaled(Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength))), to: db)
    }

    /// Dictation and ⌥⇧V only keep what was heard as speech: one short word, right away, still is.
    func testOneShortWordRightAwayIsSpeech() throws {
        for word in ["Yes.", "OK.", "好的。"] {
            let v = try Self.say(word, db: -26, voice: word.hasSuffix("。") ? "Tingting" : nil)
            let x = Self.mix(Self.room(4, db: -44), [Float](repeating: 0, count: Int(0.1 * Self.sr)) + v)
            let r = Self.run(x)
            XCTAssertNotNil(r.started, "\(word) (\(Double(v.count) / Self.sr) s) wasn't heard as speech")
        }
    }

    func testSayVoiceInRoomNoise() throws {
        let voice = try Self.say("The save button hides under the banner. Please fix it.", db: -26)
        let said = Double(voice.count) / Self.sr
        for (kind, db) in [(Noise.pink, Float(-42)), (.white, -46), (.none, -90)] {
            let lead = [Float](repeating: 0, count: Int(0.7 * Self.sr))
            let x = Self.mix(Self.room(0.7 + said + 4, db: db, kind: kind), lead + voice)
            let r = Self.run(x)
            XCTAssertNotNil(r.started, "\(kind)")
            XCTAssertEqual(r.ended?.0, .silence, "\(kind) \(db)")
            XCTAssertGreaterThan(r.ended?.1 ?? 0, 0.7 + said + 1.0, "\(kind): ended before the sentence was over")
            XCTAssertLessThan(r.ended?.1 ?? 99, 0.7 + said + 2.6, "\(kind): didn't end after it")
        }
    }
}
