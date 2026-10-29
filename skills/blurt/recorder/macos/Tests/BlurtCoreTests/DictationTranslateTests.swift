import XCTest
@testable import BlurtCore

final class DictationTranslateTests: XCTestCase {
    func testTheTargetIsTheOtherLanguageOfTheOneHeard() {
        XCTAssertEqual(DictationTranslateRoute.target(.auto, spoken: "zh"), "en")
        XCTAssertEqual(DictationTranslateRoute.target(.auto, spoken: "en"), "zh")
        XCTAssertEqual(DictationTranslateRoute.target(.auto, spoken: "zh-Hans"), "en")
        XCTAssertEqual(DictationTranslateRoute.target(.auto, spoken: "yue"), "en")
        // the speech model said nothing (or something else): the model decides
        XCTAssertEqual(DictationTranslateRoute.target(.auto, spoken: nil), "auto")
        XCTAssertEqual(DictationTranslateRoute.target(.auto, spoken: "ja"), "auto")
        // a fixed target: nothing to send when the take is already in it
        XCTAssertEqual(DictationTranslateRoute.target(.en, spoken: "zh"), "en")
        // already in the target: into the user's own language (v1.0.6), nothing when that is the target too
        XCTAssertEqual(DictationTranslateRoute.target(.en, spoken: "en", home: "zh"), "zh")
        XCTAssertNil(DictationTranslateRoute.target(.en, spoken: "en", home: "en"))
        XCTAssertNil(DictationTranslateRoute.target(.zh, spoken: "zh", home: "zh"))
        // nothing heard: the model gets both ("into X, or home if it was X")
        XCTAssertEqual(DictationTranslateRoute.target(.zh, spoken: nil, home: "zh"), "zh|en")
        XCTAssertEqual(DictationTranslateRoute.target(.ja, spoken: nil, home: "zh"), "ja|zh")
        // the other languages (v1.0.6)
        XCTAssertEqual(DictationTranslateRoute.target(.ja, spoken: "zh", home: "zh"), "ja")
        XCTAssertEqual(DictationTranslateRoute.target(.ja, spoken: "ja", home: "zh"), "zh")
        XCTAssertEqual(DictationTranslateRoute.target(.zhHant, spoken: "zh", home: "zh"), "zh-Hant")
        XCTAssertEqual(DictationTranslateRoute.home(["ja-JP", "en-US"]), "ja")
        XCTAssertEqual(DictationTranslateRoute.home(["zh-Hans-CN"]), "zh")
        XCTAssertEqual(DictationTranslateTarget.en.request(home: "zh"), "en|zh")
        XCTAssertEqual(DictationTranslateTarget.auto.request(home: "zh"), "auto")
    }

    func testCloudFirstWithItsSwitchThenThisMacThenNothing() {
        XCTAssertEqual(DictationTranslateRoute.engine(cloudReady: true, useCloud: true, localModel: true), .cloud)
        XCTAssertEqual(DictationTranslateRoute.engine(cloudReady: true, useCloud: true, localModel: false), .cloud)
        XCTAssertEqual(DictationTranslateRoute.engine(cloudReady: true, useCloud: false, localModel: true), .local)
        XCTAssertEqual(DictationTranslateRoute.engine(cloudReady: false, useCloud: true, localModel: true), .local)
        // a Mac with neither (no key, no room for the model; later Windows / Linux without one): it can't translate
        XCTAssertEqual(DictationTranslateRoute.engine(cloudReady: false, useCloud: true, localModel: false), .none)
        XCTAssertEqual(DictationTranslateRoute.engine(cloudReady: true, useCloud: false, localModel: false), .none)
        // the cloud is pointed to once, only when none is set up and the user didn't turn it off
        XCTAssertTrue(DictationTranslateRoute.suggestsCloud(engine: .local, cloudReady: false, useCloud: true, alreadySaid: false))
        XCTAssertFalse(DictationTranslateRoute.suggestsCloud(engine: .local, cloudReady: false, useCloud: true, alreadySaid: true))
        XCTAssertFalse(DictationTranslateRoute.suggestsCloud(engine: .local, cloudReady: true, useCloud: false, alreadySaid: false))
        XCTAssertFalse(DictationTranslateRoute.suggestsCloud(engine: .cloud, cloudReady: true, useCloud: true, alreadySaid: false))
    }

    func testTheConfigRoundTripsAndDropsDefaults() {
        XCTAssertNil(DictationTranslateConfig().json)
        var c = DictationTranslateConfig()
        c.target = .en
        c.cloud = false
        c.apps = ["com.openai.codex", "com.apple.Terminal"]
        c.asked = ["com.tencent.xinWeChat"]
        let back = DictationTranslateConfig(json: c.json)
        XCTAssertEqual(back, c)
        XCTAssertEqual(c.json?["apps"] as? [String], ["com.apple.Terminal", "com.openai.codex"])
        // never on by default anywhere; on from the start only in the listed apps
        XCTAssertFalse(DictationTranslateConfig().startsOn(bundle: "com.apple.Terminal"))
        XCTAssertTrue(c.startsOn(bundle: "com.openai.codex"))
        XCTAssertFalse(c.startsOn(bundle: nil))
    }

    func testTheHistoryKeepsWhatWasSaid() {
        let r = DictationTranslateRecord(source: "command", toggles: 1, target: "en", engine: "cloud", sourceText: "在本地安装一下",
                                         cloudError: nil, ms: 980)
        var e = entry(bundle: "com.openai.codex", translate: r)
        e.text = "Install it locally"
        let back = DictationEntry(json: e.json)
        XCTAssertEqual(back?.translate, r)
        XCTAssertEqual(back?.translate?.said, "在本地安装一下")
        XCTAssertNil(DictationEntry(json: entry(bundle: nil, translate: nil).json)?.translate)
    }

    func testAnAppTranslatedByHandIsAskedAboutOnce() {
        let b = "com.openai.codex"
        let byHand = DictationTranslateRecord(source: "command", target: "en", engine: "cloud")
        var entries = (0..<3).map { _ in entry(bundle: b, translate: byHand) }
        XCTAssertTrue(DictationTranslateLearn.suggest(entries: entries, bundle: b, config: DictationTranslateConfig()))
        // fewer than three, or mostly not translated there: no
        XCTAssertFalse(DictationTranslateLearn.suggest(entries: Array(entries.prefix(2)), bundle: b, config: DictationTranslateConfig()))
        entries += (0..<4).map { _ in entry(bundle: b, translate: nil) }
        XCTAssertFalse(DictationTranslateLearn.suggest(entries: entries, bundle: b, config: DictationTranslateConfig()))
        // asked already, or already in the list: never again
        var c = DictationTranslateConfig()
        c.asked = [b]
        XCTAssertFalse(DictationTranslateLearn.suggest(entries: Array(entries.prefix(3)), bundle: b, config: c))
        c = DictationTranslateConfig()
        c.apps = [b]
        XCTAssertFalse(DictationTranslateLearn.suggest(entries: Array(entries.prefix(3)), bundle: b, config: c))
        // on because the app is listed: no signal
        let listed = DictationTranslateRecord(source: "app", target: "en", engine: "cloud")
        XCTAssertFalse(DictationTranslateLearn.suggest(entries: (0..<5).map { _ in entry(bundle: b, translate: listed) }, bundle: b,
                                                       config: DictationTranslateConfig()))
    }

    private func entry(bundle: String?, translate: DictationTranslateRecord?) -> DictationEntry {
        var e = DictationEntry(id: UUID().uuidString, time: Date(), app: "Codex", bundle: bundle, duration: 2, raw: "在本地安装一下",
                               polished: "在本地安装一下", text: "在本地安装一下", model: nil, fellBack: false, reason: nil, insert: "pasted")
        e.translate = translate
        return e
    }
}
