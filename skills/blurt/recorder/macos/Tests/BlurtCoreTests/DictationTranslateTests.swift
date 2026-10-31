import XCTest
@testable import BlurtCore

final class DictationTranslateTests: XCTestCase {
    let zhEn = TranslateAutoPair(home: .zh, other: .en)
    let jaEn = TranslateAutoPair(home: .ja, other: .en)

    func testTheTargetIsTheOtherLanguageOfTheOneHeard() {
        let t = DictationTranslateRoute.target
        // Auto, a Chinese user: Chinese → English, anything else → Chinese
        XCTAssertEqual(t(.auto, "zh", zhEn), "en")
        XCTAssertEqual(t(.auto, "en", zhEn), "zh")
        XCTAssertEqual(t(.auto, "zh-Hans", zhEn), "en")
        XCTAssertEqual(t(.auto, "yue", zhEn), "en")
        XCTAssertEqual(t(.auto, "Chinese", zhEn), "en")
        XCTAssertEqual(t(.auto, "ja", zhEn), "zh")                // another language of the list: into home
        // Auto, a Japanese user (global-first: nothing hard-codes Chinese ↔ English)
        XCTAssertEqual(t(.auto, "ja", jaEn), "en")
        XCTAssertEqual(t(.auto, "Japanese", jaEn), "en")
        XCTAssertEqual(t(.auto, "en", jaEn), "ja")
        XCTAssertEqual(t(.auto, "zh", jaEn), "ja")
        // the speech model said nothing (or a language the list hasn't): the model decides, with the pair
        XCTAssertEqual(t(.auto, nil, zhEn), "auto:zh|en")
        XCTAssertEqual(t(.auto, "sw", jaEn), "auto:ja|en")
        // Auto with no pair (English, no second language): English is typed as said, the rest into English
        let enOnly = TranslateAutoPair(home: .en, other: nil)
        XCTAssertNil(t(.auto, "en", enOnly))
        XCTAssertEqual(t(.auto, "de", enOnly), "en")
        XCTAssertEqual(t(.auto, nil, enOnly), "en|keep")
        // a fixed target: always that language, whatever Auto would be
        XCTAssertEqual(t(.en, "zh", zhEn), "en")
        // already in the target: nothing to send, typed as said (2026-10-30, ⌥T's rule; v1.0.6 went into the system's
        // language instead)
        XCTAssertNil(t(.en, "en", zhEn))
        XCTAssertNil(t(.en, "en-US", zhEn))
        XCTAssertNil(t(.zh, "zh", zhEn))
        XCTAssertNil(t(.ja, "ja", zhEn))
        // nothing heard: the model decides whether it is X already ("into X, or as it is")
        XCTAssertEqual(t(.zh, nil, zhEn), "zh|keep")
        XCTAssertEqual(t(.ja, nil, zhEn), "ja|keep")
        // the other languages (v1.0.6)
        XCTAssertEqual(t(.ja, "zh", zhEn), "ja")
        XCTAssertEqual(t(.fr, "en", zhEn), "fr")
        // Chinese speech into Traditional is still a translation
        XCTAssertEqual(t(.zhHant, "zh", zhEn), "zh-Hant")
    }

    /// Auto's pair (the founder, 2026-10-30, global-first): home = Blurt's language when picked, else the system's
    /// first that the list has; other = English, or — home being English — the next system language in the list.
    func testAutoIsYourLanguageAndTheOtherOne() {
        let of = TranslateAutoPair.of
        XCTAssertEqual(of(nil, ["zh-Hans-CN", "en-US"]), zhEn)
        XCTAssertEqual(of(nil, ["ja-JP", "en-US"]), jaEn)
        XCTAssertEqual(of(nil, ["zh-Hant-TW"]), TranslateAutoPair(home: .zhHant, other: .en))
        XCTAssertEqual(of(nil, ["zh-HK"]), TranslateAutoPair(home: .zhHant, other: .en))
        XCTAssertEqual(of(nil, ["de-DE"]), TranslateAutoPair(home: .de, other: .en))
        // English first: the next language of the list is the other one
        XCTAssertEqual(of(nil, ["en-US", "ja-JP"]), TranslateAutoPair(home: .en, other: .ja))
        XCTAssertEqual(of(nil, ["en-GB", "sw-KE", "fr-FR"]), TranslateAutoPair(home: .en, other: .fr))
        // English alone (or with languages the list hasn't): no pair — Settings says to pick one
        XCTAssertEqual(of(nil, ["en-US"]), TranslateAutoPair(home: .en, other: nil))
        XCTAssertEqual(of(nil, ["en-US", "sw-KE"]), TranslateAutoPair(home: .en, other: nil))
        // Blurt's own language, when picked, comes first
        XCTAssertEqual(of("zh-Hans", ["en-US"]), zhEn)
        XCTAssertEqual(of("en", ["zh-Hans-CN", "en-US"]), TranslateAutoPair(home: .en, other: .zh))
        // nothing the list has at all: English
        XCTAssertEqual(of(nil, ["sw-KE"]), TranslateAutoPair(home: .en, other: nil))
        // polish.py's target
        XCTAssertEqual(zhEn.request, "auto:zh|en")
        XCTAssertEqual(TranslateAutoPair(home: .en, other: .ja).request, "auto:en|ja")
        XCTAssertEqual(TranslateAutoPair(home: .en, other: nil).request, "en|keep")
        // codes and names the system and the speech model give
        XCTAssertEqual(DictationTranslateTarget.of("zh_CN"), .zh)
        XCTAssertEqual(DictationTranslateTarget.of("zh-Hans-HK"), .zh)
        XCTAssertEqual(DictationTranslateTarget.of("pt-BR"), .pt)
        XCTAssertEqual(DictationTranslateTarget.of("Korean"), .ko)
        XCTAssertNil(DictationTranslateTarget.of("sw"))
    }

    /// ⌥T sends its setting (it can't know what it will read): Auto's pair, or "X|keep" — never the user's own
    /// language in place of the one they chose.
    func testTheScreenRequestKeepsAFixedLanguage() {
        XCTAssertEqual(DictationTranslateTarget.auto.request(auto: zhEn), "auto:zh|en")
        XCTAssertEqual(DictationTranslateTarget.auto.request(auto: jaEn), "auto:ja|en")
        XCTAssertEqual(DictationTranslateTarget.en.request(auto: zhEn), "en|keep")
        XCTAssertEqual(DictationTranslateTarget.zh.request(auto: jaEn), "zh|keep")
        XCTAssertEqual(DictationTranslateTarget.zhHant.request(auto: zhEn), "zh-Hant|keep")
        for t in DictationTranslateTarget.allCases where t != .auto { XCTAssertEqual(t.request(auto: jaEn), t.rawValue + "|keep") }
    }

    /// The model's answer is the text as it was: "already in X" — for a request that keeps it (a fixed language, Auto
    /// without a pair), and only when nothing but spacing changed.
    func testKeptAsIsComparesTheAnswerWithTheText() {
        let k = DictationTranslateRoute.keptAsIs
        let src = "The replica is billed\nby the hour."
        XCTAssertEqual(k("en|keep", src, "The replica is billed by the hour. "), .en)
        XCTAssertEqual(k("en|keep", src, src), .en)
        XCTAssertNil(k("en|keep", src, "The replica is billed per hour."))
        XCTAssertNil(k("zh|keep", src, "副本按小时计费。"))
        // Auto with a pair: a command or a name back as it is was simply nothing to translate
        XCTAssertNil(k("auto:zh|en", "git status", "git status"))
        XCTAssertNil(k("auto", "git status", "git status"))
        XCTAssertNil(k("en|keep", "  ", "  "))
    }

    /// ⌥T's own settings (2026-10-30): the first launch starts it at Auto, with the cloud as dictation's switch was;
    /// dictation keeps its own.
    func testScreenTranslateHasItsOwnSettings() {
        var d = DictationTranslateConfig()
        d.target = .en
        d.cloud = false
        let m = ScreenTranslateConfig.migrated(from: d)
        XCTAssertEqual(m.target, .auto)
        XCTAssertFalse(m.cloud)
        XCTAssertTrue(ScreenTranslateConfig.migrated(from: DictationTranslateConfig()).cloud)
        // always written (the key says the migration happened), and read back
        XCTAssertEqual(m.json["cloud"] as? Bool, false)
        var c = ScreenTranslateConfig()
        c.target = .ja
        XCTAssertEqual(ScreenTranslateConfig(json: c.json), c)
        XCTAssertEqual(ScreenTranslateConfig(json: nil), ScreenTranslateConfig())
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
