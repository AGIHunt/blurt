// A switch during a take sticks to its app (BlurtCore/DictationRemember.swift; docs/design/dictation-styles.md §3.5).
import XCTest
@testable import BlurtCore

final class DictationRememberTests: XCTestCase {
    let wechat = "com.tencent.xinWeChat"

    func testStructuredSticksToTheAppAndSwitchingBackForgetsIt() {
        let none = DictationStyleConfig()
        // ⇧ in WeChat: Structured from now on there, listed as learned (Settings → Reset)
        let on = DictationRemember.style(final: .structured, source: .shift, toggles: 1, config: none, bundle: wechat)
        XCTAssertEqual(on?.apps[wechat], .structured)
        XCTAssertEqual(on?.learned, [wechat])
        XCTAssertEqual(DictationStyleRouter.decide(config: on!, bundle: wechat).style, .structured)
        // other apps keep their own style
        XCTAssertNil(on?.apps["com.apple.Notes"])
        // the next take there starts Structured; ⇧ back to Light: forgotten, the app's category style again
        let off = DictationRemember.style(final: .light, source: .shift, toggles: 1, config: on!, bundle: wechat)
        XCTAssertNil(off?.apps[wechat])
        XCTAssertEqual(off?.learned, [])
        // Fn+⇧ as the start press counts too, the island as well
        XCTAssertEqual(DictationRemember.style(final: .structured, source: .chord, toggles: 0, config: none, bundle: wechat)?.apps[wechat], .structured)
        XCTAssertEqual(DictationRemember.style(final: .structured, source: .island, toggles: 1, config: none, bundle: wechat)?.apps[wechat], .structured)
    }

    func testNoSwitchOrNoChangeLeavesTheConfigAlone() {
        let none = DictationStyleConfig()
        // a take in the app's own style, no switch
        XCTAssertNil(DictationRemember.style(final: .light, source: .category, toggles: 0, config: none, bundle: wechat))
        // switched twice within the take, back where it started
        XCTAssertNil(DictationRemember.style(final: .light, source: .shift, toggles: 2, config: none, bundle: wechat))
        // already remembered
        var c = none
        c.apps[wechat] = .structured
        c.learned = [wechat]
        XCTAssertNil(DictationRemember.style(final: .structured, source: .shift, toggles: 2, config: c, bundle: wechat))
    }

    func testAStyleChosenInSettingsForTheCategoryIsTheOneSwitchedBackTo() {
        var c = DictationStyleConfig()
        c.categories[.chat] = .verbatim
        // Structured in WeChat, then back: to the chat category's Verbatim, so nothing of the app's own is kept
        let on = DictationRemember.style(final: .structured, source: .shift, toggles: 1, config: c, bundle: wechat)!
        XCTAssertNil(DictationRemember.style(final: .verbatim, source: .shift, toggles: 1, config: on, bundle: wechat)?.apps[wechat])
    }

    func testTranslateSticksAndSwitchingOffForgetsIt() {
        let none = DictationTranslateConfig()
        let on = DictationRemember.translate(on: true, toggles: 1, config: none, bundle: wechat)
        XCTAssertEqual(on?.apps, [wechat])
        XCTAssertTrue(on!.startsOn(bundle: wechat))
        XCTAssertFalse(on!.startsOn(bundle: "com.anthropic.claudefordesktop"))
        let off = DictationRemember.translate(on: false, toggles: 1, config: on!, bundle: wechat)
        XCTAssertEqual(off?.apps, [])
        // no ⌘ this take, or on → off → on: nothing to write
        XCTAssertNil(DictationRemember.translate(on: true, toggles: 0, config: on!, bundle: wechat))
        XCTAssertNil(DictationRemember.translate(on: true, toggles: 2, config: on!, bundle: wechat))
    }

    func testRemindsAfterAnHourOrTheFirstTimeSinceLaunch() {
        let now = Date()
        XCTAssertTrue(DictationRemember.remind(lastTake: nil, now: now))
        XCTAssertFalse(DictationRemember.remind(lastTake: now.addingTimeInterval(-600), now: now))
        XCTAssertTrue(DictationRemember.remind(lastTake: now.addingTimeInterval(-3600), now: now))
    }
}
