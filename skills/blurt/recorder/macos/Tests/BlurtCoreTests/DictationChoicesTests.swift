// BlurtCore/DictationChoices.swift: dictation's five choices from the 2026-10-31 eval, said as "1 mistake every N
// words", what fits a Mac, the recommendation (until the default logic's own function lands) and the row in use.
import XCTest
@testable import BlurtCore

final class DictationChoicesTests: XCTestCase {
    typealias C = DictationChoice
    func mac(_ ram: Double, apple: Bool = true, speech: Bool = true, text: Bool = false, asr: Bool = false, rtf: Double? = nil,
             langs: [String] = []) -> DictationChoices.Mac {
        .init(ramGB: ram, appleSilicon: apple, macOSSpeech: speech, textKey: text, speechKey: asr, rtf: rtf, languages: langs)
    }

    func testAccuracyIsAMeterNeverAMistakeCount() {
        // §7 on Chinese + English: macOS 3, 0.6B 4, Fun-ASR-Nano 4, 1.7B 5, + cloud polish 5, cloud recogniser 5
        XCTAssertEqual(C.allCases.map { DictationChoices.level(DictationChoices.facts($0).mixed) }, [3, 4, 4, 5, 5, 5])
        // cloud polish over the 0.6B (§6.3: 2.84 %)
        XCTAssertEqual(DictationChoices.level(DictationChoices.facts(.cloudPolish, on: .qwenSmall).mixed), 4)
        // English (LibriSpeech clean): macOS Speech is a 5 there
        XCTAssertEqual(DictationChoices.level(DictationChoices.facts(.macOSSpeech).languages["en"]!), 5)
        XCTAssertEqual(DictationChoices.level(0.2), 3, "never fewer than 3 marks")
        XCTAssertEqual(DictationChoices.level(0), 0)
        // one row per choice, in the order shown
        XCTAssertEqual(DictationChoices.table.map(\.choice), C.allCases)
    }

    func testTheOwnLanguageLineIsForNonChineseSpeakersWithANumber() {
        XCTAssertNil(DictationChoices.ownLanguage(["zh", "en"]))
        XCTAssertNil(DictationChoices.ownLanguage(["zh-Hans"]))
        XCTAssertEqual(DictationChoices.ownLanguage(["en", "zh"]), "en")
        XCTAssertEqual(DictationChoices.ownLanguage(["de-DE"]), "de")
        // Japanese is measured but its level isn't comparable (§3): no line
        XCTAssertNil(DictationChoices.ownLanguage(["ja"]))
        XCTAssertNil(DictationChoices.ownLanguage(["fr"]))
        XCTAssertNil(DictationChoices.ownLanguage([]))
    }

    func testWhatFitsThisMac() {
        let m8 = mac(8), m16 = mac(15.9), intel = mac(32, apple: false)
        XCTAssertEqual(DictationChoices.fit(.qwenSmall, mac: m8), .fits)
        XCTAssertEqual(DictationChoices.fit(.qwenLarge, mac: m8), .needsMemory(16))
        XCTAssertEqual(DictationChoices.fit(.qwenLarge, mac: m16), .fits)
        XCTAssertEqual(DictationChoices.fit(.qwenLarge, mac: intel), .needsAppleSilicon)
        XCTAssertEqual(DictationChoices.fit(.macOSSpeech, mac: mac(16, speech: false)), .needsMacOS26)
        // cloud rows: a key first; cloud polish over the 0.6B fits an 8 GB Mac
        XCTAssertEqual(DictationChoices.fit(.cloudPolish, mac: m16), .needsKey)
        XCTAssertEqual(DictationChoices.fit(.cloudPolish, on: .qwenSmall, mac: mac(8, text: true)), .fits)
        XCTAssertEqual(DictationChoices.fit(.cloudRecognizer, mac: mac(8, text: true)), .needsKey)
        XCTAssertEqual(DictationChoices.fit(.cloudRecognizer, mac: mac(8, asr: true)), .fits)
    }

    func testTheRecommendationFollowsTheTiers() {
        XCTAssertEqual(DictationChoices.recommended(mac(8)), .qwenSmall)
        XCTAssertEqual(DictationChoices.recommended(mac(16)), .qwenLarge)
        XCTAssertEqual(DictationChoices.recommended(mac(128)), .qwenLarge)
        // a slow GPU (base M1): the small model whatever the memory
        XCTAssertEqual(DictationChoices.recommended(mac(16, rtf: 0.09)), .qwenSmall)
        XCTAssertEqual(DictationChoices.recommended(mac(16, rtf: 0.03)), .qwenLarge)
        XCTAssertEqual(DictationChoices.recommended(mac(32, apple: false)), .macOSSpeech)
        // a key: cloud polish on the local model — never the cloud recogniser (§4.1)
        XCTAssertEqual(DictationChoices.recommended(mac(16, text: true, asr: true)), .cloudPolish)
        XCTAssertEqual(DictationChoices.polishBase(recognizer: nil, mac: mac(8)), .qwenSmall)
        XCTAssertEqual(DictationChoices.polishBase(recognizer: "qwen3-asr-0.6b-mlx", mac: mac(64)), .qwenSmall)
        XCTAssertEqual(DictationChoices.polishBase(recognizer: "apple-speech", mac: mac(64)), .qwenLarge)
    }

    /// Fun-ASR-Nano: where the 1.7B doesn't go, for people who speak only Chinese, English and Japanese.
    func testFunASRNanoForItsLanguages() {
        let zh = ["zh-Hans", "en"]
        XCTAssertEqual(DictationChoices.recommended(mac(8, langs: zh)), .funNano)
        XCTAssertEqual(DictationChoices.recommended(mac(8, langs: ["de", "en"])), .qwenSmall)
        XCTAssertEqual(DictationChoices.recommended(mac(16, rtf: 0.09, langs: ["ja"])), .funNano)
        XCTAssertEqual(DictationChoices.recommended(mac(16, langs: zh)), .qwenLarge, "the 1.7B stays on fast 16 GB Macs")
        XCTAssertEqual(DictationChoices.fit(.funNano, mac: mac(8, langs: zh)), .fits)
        XCTAssertEqual(DictationChoices.fit(.funNano, mac: mac(32, apple: false, langs: zh)), .needsAppleSilicon)
        // with a key: cloud polish over Fun-ASR-Nano
        let key = mac(8, text: true, langs: zh)
        XCTAssertEqual(DictationChoices.recommended(key), .cloudPolish)
        XCTAssertEqual(DictationChoices.polishBase(recognizer: nil, mac: key), .funNano)
        XCTAssertEqual(DictationChoices.facts(.cloudPolish, on: .funNano), DictationChoices.cloudPolishOnFun)
        XCTAssertEqual(DictationChoices.inUse(recognizer: "fun-asr-nano-mlx", cloudPolish: false), .funNano)
        XCTAssertEqual(DictationChoices.inUse(recognizer: "fun-asr-nano-mlx", cloudPolish: true), .cloudPolish)
        // the row: only for its languages, unless dictation already uses it
        XCTAssertTrue(DictationChoices.choices(mac(8, langs: zh)).contains(.funNano))
        XCTAssertFalse(DictationChoices.choices(mac(8, langs: ["de", "en"])).contains(.funNano))
        XCTAssertTrue(DictationChoices.choices(mac(8, langs: ["de"]), inUse: .funNano).contains(.funNano))
        XCTAssertEqual(DictationChoices.choices(mac(8, langs: ["fr"])).count, C.allCases.count - 1)
        // no German line: a German speaker never sees the row, so the meter never needs one
        XCTAssertNil(DictationChoices.facts(.funNano).languages["de"])
    }

    func testTheRowInUseIsOnlyATrueRow() {
        XCTAssertEqual(DictationChoices.inUse(recognizer: "qwen3-asr-1.7b-mlx", cloudPolish: false), .qwenLarge)
        XCTAssertEqual(DictationChoices.inUse(recognizer: "qwen3-asr-0.6b-mlx", cloudPolish: true), .cloudPolish)
        XCTAssertEqual(DictationChoices.inUse(recognizer: "qwen3-asr-flash", cloudPolish: true), .cloudRecognizer)
        XCTAssertEqual(DictationChoices.inUse(recognizer: "apple-speech", cloudPolish: false), .macOSSpeech)
        // macOS Speech with cloud polish sends text out: not the "stays on this Mac" row
        XCTAssertNil(DictationChoices.inUse(recognizer: "apple-speech", cloudPolish: true))
        XCTAssertNil(DictationChoices.inUse(recognizer: "sensevoice-small", cloudPolish: false))
        XCTAssertNil(DictationChoices.inUse(recognizer: nil, cloudPolish: false))
    }
}
