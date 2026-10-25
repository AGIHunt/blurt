// BlurtCore/HandoffBundle.swift: the name the Save panel suggests is the skill's (tests/test_bundle.py
// test_bundle_name_and_slug has the same cases), and old Export links land in Settings → Agents.
import XCTest
@testable import BlurtCore

final class HandoffBundleTests: XCTestCase {
    let day: Date = {
        var c = DateComponents()
        c.year = 2026; c.month = 10; c.day = 25; c.hour = 12
        return Calendar(identifier: .gregorian).date(from: c)!
    }()

    func testFileName() {
        XCTAssertEqual(HandoffBundle.fileName(project: "Checkout Web", count: 12, chinese: false, day: day),
                       "checkout-web-2026-10-25-12-items.zip")
        XCTAssertEqual(HandoffBundle.fileName(project: "Checkout Web", count: 1, chinese: false, day: day),
                       "checkout-web-2026-10-25-1-item.zip")
        XCTAssertEqual(HandoffBundle.fileName(project: "官网 / 首页", count: 3, chinese: true, day: day), "官网-首页-2026-10-25-3条.zip")
        XCTAssertEqual(HandoffBundle.fileName(project: nil, count: 2, chinese: false, day: day), "blurt-2026-10-25-2-items.zip")
    }

    func testSlug() {
        XCTAssertEqual(HandoffBundle.slug("  ../a:b\\c  "), "a-b-c")
        XCTAssertEqual(HandoffBundle.slug("***"), "blurt")
        XCTAssertEqual(HandoffBundle.slug("My App 2"), "my-app-2")
        XCTAssertEqual(HandoffBundle.slug("a - b"), "a-b")
        XCTAssertEqual(HandoffBundle.slug(String(repeating: "x", count: 80)).count, 60)
    }

    func testTheFailureAlertSaysWhyInWords() {
        // the app's sentence for the code (with what to do), else the general one — never the script's English
        XCTAssertEqual(HandoffBundle.failureText(ours: "Choose another folder.", fallback: "Something went wrong."), "Choose another folder.")
        XCTAssertEqual(HandoffBundle.failureText(ours: nil, fallback: "G"), "G")
        XCTAssertEqual(HandoffBundle.failureText(ours: "  ", fallback: "G"), "G")
    }

    func testTheExportPaneMovedToAgents() {
        XCTAssertNil(SettingsCatalog.pane("export"))
        XCTAssertEqual(SettingsCatalog.redirect("export"), "agents/agents.ask")
        XCTAssertEqual(SettingsCatalog.redirect("export/target"), "agents/agents.ask")
        XCTAssertEqual(SettingsCatalog.redirect("speech/dictation"), "speech/dictation")
        XCTAssertEqual(SettingsCatalog.redirect(""), "")
        XCTAssertEqual(SettingsCatalog.section("agents.ask")?.pane, "agents")
        XCTAssertEqual(SettingsCatalog.entry("agents.ask")?.kind, .section)
    }

    func testSearchingForExportFindsWhereItWent() {
        defer { Loc.setting = nil }
        for lang in ["en", "zh-Hans"] {
            Loc.setting = lang
            for q in ["export", "导出", "bundle", "交接包"] {
                XCTAssertEqual(SettingsCatalog.search(q).first?.entry.id, "agents.ask", "\(lang): \(q)")
            }
            for q in ["Feishu", "飞书", "Slack"] {      // smart paste (chat apps) is found too
                XCTAssertTrue(SettingsCatalog.search(q).contains { $0.entry.id == "agents.ask" }, "\(lang): \(q)")
            }
        }
    }
}
