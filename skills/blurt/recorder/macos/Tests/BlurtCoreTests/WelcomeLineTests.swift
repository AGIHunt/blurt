// BlurtCore/WelcomeLine.swift: the first launch's line only advertises keys that work, and a shortcut that doesn't is
// said on that same line.
import XCTest
@testable import BlurtCore

final class WelcomeLineTests: XCTestCase {
    func testEverythingWorks() {
        let l = WelcomeLine.compose(dictation: .works, dictationKey: "Fn", snap: "⌥⇧A", record: "⌥⇧R", conflicts: [])
        XCTAssertEqual(l.key, "app.toast.welcome")
        XCTAssertEqual(l.args, ["Fn", "⌥⇧A"])
        XCTAssertNil(l.action)
    }

    func testFnIsOnlyAdvertisedWhenDictationCanServeIt() {
        // the key isn't heard (no Accessibility): the line says how to turn it on, with the button
        let deaf = WelcomeLine.compose(dictation: .needsSetup, dictationKey: "Fn", snap: "⌥⇧A", record: nil, conflicts: [])
        XCTAssertEqual(deaf.key, "app.toast.welcome_setup")
        XCTAssertFalse(deaf.args.contains("Fn"))
        XCTAssertEqual(deaf.action, .turnOnDictation)
        // no speech model yet: download it first
        let noModel = WelcomeLine.compose(dictation: .noModel, dictationKey: "Fn", snap: "⌥⇧A", record: nil, conflicts: [])
        XCTAssertEqual(noModel.key, "app.toast.welcome_no_model")
        XCTAssertEqual(noModel.action, .downloadModel)
    }

    func testASnapKeyThatDoesNotWorkIsLeftOutAndNamed() {
        // ⇧⌘3 is macOS's: not advertised; the same line says it won't work, and the button changes it
        let l = WelcomeLine.compose(dictation: .works, dictationKey: "Fn", snap: nil, record: "⌥⇧R", conflicts: ["⇧⌘3"])
        XCTAssertEqual(l.key, "app.toast.welcome_dictation_only")
        XCTAssertEqual(l.args, ["Fn"])
        XCTAssertEqual(l.conflicts, ["⇧⌘3"])
        XCTAssertEqual(l.action, .changeShortcut)
        // a more urgent button stays; the conflict is still named
        let both = WelcomeLine.compose(dictation: .needsSetup, dictationKey: "Fn", snap: nil, record: nil, conflicts: ["⌥⇧A"])
        XCTAssertEqual(both.action, .turnOnDictation)
        XCTAssertEqual(both.conflicts, ["⌥⇧A"])
    }

    func testDictationOff() {
        XCTAssertEqual(WelcomeLine.compose(dictation: .off, dictationKey: "Fn", snap: "⌥⇧A", record: "⌥⇧R", conflicts: []).key,
                       "app.toast.welcome_no_dictation")
        XCTAssertEqual(WelcomeLine.compose(dictation: .off, dictationKey: "Fn", snap: "⌥⇧A", record: nil, conflicts: []).key,
                       "app.toast.welcome_snap_only")
        XCTAssertEqual(WelcomeLine.compose(dictation: .off, dictationKey: "Fn", snap: nil, record: nil, conflicts: []).key,
                       "app.toast.welcome_plain")
    }
}
