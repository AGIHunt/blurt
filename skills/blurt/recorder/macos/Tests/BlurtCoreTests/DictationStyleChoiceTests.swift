// Settings → Dictation's one Style choice over the engine's two keys, and what the history reports a take did
// (BlurtCore/DictationStyleChoice.swift).
import XCTest
@testable import BlurtCore

final class DictationStyleChoiceTests: XCTestCase {
    func testOneChoiceOverTheTwoKeys() {
        let none = DictationStyleConfig()
        XCTAssertEqual(DictationStyleChoice.current(polishOff: false, config: none), .light)
        XCTAssertEqual(DictationStyleChoice.current(polishOff: true, config: none), .verbatim)    // polish off = Verbatim

        let v = DictationStyleChoice.apply(.verbatim, to: none)
        XCTAssertEqual(v.polish, "off")                                    // no model loaded, nothing read
        XCTAssertEqual(v.config.fallback, .verbatim)                       // and takes say Verbatim in the history
        XCTAssertEqual(DictationStyleRouter.decide(config: v.config, bundle: nil).style, .verbatim)
        XCTAssertEqual(DictationStyleChoice.current(polishOff: true, config: v.config), .verbatim)

        for s in [DictationStyle.light, .structured, .auto] {
            let r = DictationStyleChoice.apply(s, to: v.config)
            XCTAssertNil(r.polish, "\(s)")                                 // polish back on
            XCTAssertEqual(DictationStyleChoice.current(polishOff: false, config: r.config), s)
            XCTAssertEqual(DictationStyleRouter.decide(config: r.config, bundle: nil).style, s)
        }
        XCTAssertNil(DictationStyleChoice.apply(.light, to: v.config).config.json)   // Light is the default: nothing stored

        // a category the user set keeps its own style
        var cfg = DictationStyleConfig()
        cfg.categories[.notes] = .structured
        let r = DictationStyleChoice.apply(.light, to: cfg)
        XCTAssertEqual(DictationStyleRouter.decide(config: r.config, bundle: "com.apple.Notes").style, .structured)
    }

    func entry(style: String?, polished: String?, fellBack: Bool = false, reason: String? = nil, model: String? = nil,
               rendered: Bool = false, timing: [String: Int]? = nil) -> DictationEntry {
        var e = DictationEntry(id: "d", time: Date(), app: "Notes", bundle: nil, duration: 2, raw: "嗯 你好", polished: polished,
                               text: polished ?? "嗯 你好", model: model, fellBack: fellBack, reason: reason, insert: "pasted",
                               timing: timing)
        if let s = style { e.style = DictationStyleRecord(style: s, source: "default", category: "notes", base: s, rendered: rendered) }
        return e
    }

    /// audit newc010: a take that nothing polished said "Polish Off · Style Light"
    func testTheStyleThatRan() {
        XCTAssertEqual(DictationEntryReport.styleRan(entry(style: "light", polished: nil)), .verbatim)       // no model
        XCTAssertEqual(DictationEntryReport.styleRan(entry(style: "light", polished: "你好。", fellBack: true)), .verbatim)
        XCTAssertEqual(DictationEntryReport.styleRan(entry(style: "light", polished: "你好。")), .light)
        XCTAssertEqual(DictationEntryReport.styleRan(entry(style: "verbatim", polished: nil)), .verbatim)
        XCTAssertEqual(DictationEntryReport.styleRan(entry(style: "auto", polished: "你好。")), .light)        // no list
        XCTAssertEqual(DictationEntryReport.styleRan(entry(style: "auto", polished: "你好。", rendered: true)), .structured)
        XCTAssertEqual(DictationEntryReport.styleRan(entry(style: "structured", polished: "你好。")), .light)  // no pass
        XCTAssertEqual(DictationEntryReport.styleRan(entry(style: "structured", polished: "你好。", timing: ["structure_ms": 800])), .structured)
        XCTAssertNil(DictationEntryReport.styleRan(entry(style: nil, polished: "你好。")))
    }

    func testWhatPolishDid() {
        XCTAssertEqual(DictationEntryReport.polish(entry(style: "light", polished: "你好。", model: "gemma4-e2b"), hasModel: true), .model("gemma4-e2b"))
        XCTAssertEqual(DictationEntryReport.polish(entry(style: "light", polished: "x", fellBack: true, reason: "timeout", model: "g"), hasModel: true), .fellBack("g"))
        XCTAssertEqual(DictationEntryReport.polish(entry(style: "light", polished: nil, reason: "short"), hasModel: true), .short)
        XCTAssertEqual(DictationEntryReport.polish(entry(style: "verbatim", polished: nil), hasModel: false), .off)
        XCTAssertEqual(DictationEntryReport.polish(entry(style: "light", polished: nil), hasModel: false), .noModel)
        XCTAssertEqual(DictationEntryReport.polish(entry(style: "light", polished: nil), hasModel: true), .off)
    }
}
