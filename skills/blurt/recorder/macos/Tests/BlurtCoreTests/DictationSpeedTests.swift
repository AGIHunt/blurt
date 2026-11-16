// BlurtCore/DictationSpeed.swift: the usual wait after key-up, from the history's own timings.
import Foundation
import XCTest
@testable import BlurtCore

final class DictationSpeedTests: XCTestCase {
    func take(_ n: Int, total: Int?, asr: Int? = nil, polish: Int? = nil, load: Int? = nil, spoken: Double = 5,
              text: String = "好的，我晚点看一下。", reason: String? = nil, insert: String = "pasted", model: String? = "m") -> DictationEntry {
        var t: [String: Int] = [:]
        if let v = total { t["total_ms"] = v }
        if let v = asr { t["asr_ms"] = v }
        if let v = polish { t["polish_ms"] = v }
        if let v = load { t["load_ms"] = v }
        return DictationEntry(id: "d\(n)", time: Date(timeIntervalSince1970: TimeInterval(1000 + n)), app: nil, bundle: nil,
                              duration: spoken, raw: text, polished: nil, text: text, model: nil, fellBack: false,
                              reason: reason, insert: insert, asrModel: model, timing: t.isEmpty ? nil : t)
    }

    func testMedianOddAndEven() {
        XCTAssertEqual(DictationSpeed.median([]), 0)
        XCTAssertEqual(DictationSpeed.median([900, 100, 400]), 400)
        XCTAssertEqual(DictationSpeed.median([100, 400, 500, 2000]), 450)
    }

    /// Nothing is said from fewer than five takes: one slow first take (a model loading) isn't "usually".
    func testNeedsFiveTakes() {
        let four = (0..<4).map { take($0, total: 400) }
        XCTAssertNil(DictationSpeed(four))
        let s = DictationSpeed(four + [take(4, total: 3000)])
        XCTAssertEqual(s?.count, 5)
        XCTAssertEqual(s?.medianMS, 400)
    }

    /// Older entries without timings, and cancelled / failed / empty takes, are not counted at all.
    func testIgnoresTakesWithoutTimingsAndFailedOnes() {
        var es = (0..<5).map { take($0, total: 500) }
        es.append(take(10, total: nil))                                               // an older entry
        es.append(take(11, total: 9000, text: "", reason: DictationHistory.cancelledReason, insert: "none"))
        es.append(take(12, total: 9000, text: "", reason: "asr_failed:model_missing", insert: "none"))
        es.append(take(13, total: 9000, text: "", reason: "nothing_heard", insert: "none"))
        es.append(take(14, total: 9000, insert: "none"))                             // heard, nothing typed
        let s = DictationSpeed(es)
        XCTAssertEqual(s?.count, 5)
        XCTAssertEqual(s?.medianMS, 500)
        XCTAssertFalse(DictationSpeed.counts(take(15, total: nil)))
        XCTAssertTrue(DictationSpeed.counts(take(16, total: 300, insert: "copied")))
        // the most a take that fell back to the raw text is: still a wait for text
        XCTAssertTrue(DictationSpeed.counts(take(17, total: 300, reason: "timeout")))
    }

    /// The last 50 takes by time, whatever order they come in.
    func testLooksAtTheLastFifty() {
        let old = (0..<60).map { take($0, total: 5000) }
        let new = (100..<150).map { take($0, total: 300) }
        let s = DictationSpeed((old + new).shuffled())
        XCTAssertEqual(s?.count, 50)
        XCTAssertEqual(s?.medianMS, 300)
    }

    func testOneModelOnly() {
        let es = (0..<5).map { take($0, total: 300, model: "a") } + (5..<9).map { take($0, total: 2000, model: "b") }
        XCTAssertEqual(DictationSpeed(es, model: "a")?.medianMS, 300)
        XCTAssertNil(DictationSpeed(es, model: "b"))
        XCTAssertEqual(DictationSpeed(es)?.count, 9)
    }

    /// Recognition's own median needs five takes that recorded it; long takes (≥ 30 s spoken) need three.
    func testRecognitionAndLongTakes() {
        var es = (0..<5).map { take($0, total: 400, asr: 150) }
        XCTAssertEqual(DictationSpeed(es)?.asrMedianMS, 150)
        XCTAssertNil(DictationSpeed(es)?.longMedianMS)
        es += (5..<8).map { take($0, total: 700, spoken: 60) }
        let s = DictationSpeed(es)
        XCTAssertEqual(s?.longCount, 3)
        XCTAssertEqual(s?.longMedianMS, 700)
        XCTAssertEqual(s?.asrMedianMS, 150)
        XCTAssertNil(DictationSpeed((0..<5).map { take($0, total: 400, asr: $0 < 4 ? nil : 100) })?.asrMedianMS)
    }

    /// One take's wait: only the stages that ran after key-up, in order; nothing for an older entry.
    func testStagesOnlyWhatRan() {
        let e = take(1, total: 1180, asr: 324, polish: 720, load: 0)
        XCTAssertEqual(DictationSpeed.stages(e).map(\.stage), [.asr, .polish])
        XCTAssertEqual(DictationSpeed.stages(e).map(\.ms), [324, 720])
        XCTAssertEqual(DictationSpeed.stages(take(2, total: 2400, asr: 200, polish: 300, load: 1500)).map(\.stage), [.load, .asr, .polish])
        XCTAssertTrue(DictationSpeed.stages(take(3, total: nil)).isEmpty)
        XCTAssertEqual(DictationSpeed.total(take(4, total: 412)), 412)
        XCTAssertNil(DictationSpeed.total(take(5, total: 412, text: "", insert: "none")))
    }

    /// Tenths below 10 s, whole seconds above, nothing under 0.1 s ("under 0.1 s"), never "412ms".
    func testSeconds() {
        XCTAssertNil(DictationSpeed.seconds(9))
        XCTAssertNil(DictationSpeed.seconds(99))
        XCTAssertEqual(DictationSpeed.seconds(100), 0.1)
        XCTAssertEqual(DictationSpeed.seconds(412), 0.4)
        XCTAssertEqual(DictationSpeed.seconds(1150), 1.2)
        XCTAssertEqual(DictationSpeed.seconds(12_400), 12)
        let en = Locale(identifier: "en_US"), de = Locale(identifier: "de_DE")
        XCTAssertEqual(DictationSpeed.secondsText(412, locale: en), "0.4")
        XCTAssertEqual(DictationSpeed.secondsText(1000, locale: en), "1")
        XCTAssertEqual(DictationSpeed.secondsText(412, locale: de), "0,4")
        XCTAssertEqual(DictationSpeed.secondsText(12_400, locale: en), "12")
        XCTAssertNil(DictationSpeed.secondsText(40, locale: en))
    }
}
