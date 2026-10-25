// BlurtCore/Hotkeys.swift: the combos no global hotkey may take (⌘C is Copy in every app), the swap that replaces a
// silent duplicate, and which of two running Blurts listens to the dictation key. Pure parts only: nothing here
// registers a Carbon hotkey or writes a config.
import Carbon.HIToolbox
import XCTest
@testable import BlurtCore

final class HotkeysTests: XCTestCase {
    func combo(_ s: String) -> KeyCombo { KeyCombo.parse(s)! }

    func testPlainCommandWithATypingKeyIsReserved() {
        XCTAssertEqual(combo("cmd+C").reserved, .copy)
        XCTAssertEqual(combo("cmd+V").reserved, .paste)
        XCTAssertEqual(combo("cmd+Q").reserved, .quit)
        XCTAssertEqual(combo("cmd+W").reserved, .close)
        XCTAssertEqual(combo("cmd+Z").reserved, .undo)
        XCTAssertEqual(combo("shift+cmd+Z").reserved, .redo)
        XCTAssertEqual(combo("cmd+Space").reserved, .spotlight)
        XCTAssertEqual(combo("cmd+Tab").reserved, .appSwitcher)
        XCTAssertEqual(combo("cmd+,").reserved, .settings)
        // some app's own menu item: still the app's
        XCTAssertEqual(combo("cmd+K").reserved, .menu)
        XCTAssertEqual(combo("cmd+1").reserved, .menu)
        XCTAssertEqual(combo("shift+cmd+D").reserved, .menu)
        XCTAssertEqual(combo("cmd+Left").reserved, .menu)
    }

    func testCombosWithOptionOrControlOrFunctionKeysAreFree() {
        XCTAssertNil(combo("opt+shift+A").reserved)          // the defaults
        XCTAssertNil(combo("opt+cmd+C").reserved)
        XCTAssertNil(combo("ctrl+cmd+V").reserved)
        XCTAssertNil(combo("ctrl+opt+shift+cmd+R").reserved)
        XCTAssertNil(combo("cmd+F5").reserved)
        XCTAssertNil(combo("F6").reserved)
        XCTAssertNil(combo("ctrl+Space").reserved)
    }

    func testAReservedComboIsAConflictThatSaysWhy() {
        XCTAssertTrue(HotkeyResult.reserved.isConflict)
        XCTAssertFalse(HotkeyResult.reserved.text.isEmpty)
        let c = combo("cmd+C")
        XCTAssertTrue(c.reserved!.reason(c).contains(c.label))
        XCTAssertTrue(c.reserved!.short(c).contains(c.label))
        XCTAssertNotNil(StandardShortcut.copy.name)
        XCTAssertNil(StandardShortcut.menu.name)
        let k = combo("cmd+K")
        XCTAssertTrue(k.reserved!.reason(k).contains(k.label))
    }

    func testOwnerFindsTheOtherActionWithTheKeys() {
        let v = combo("opt+shift+V")
        let map: [HotkeyCenter.Action: KeyCombo] = [.snap: combo("opt+shift+A"), .voice: v]
        XCTAssertEqual(HotkeyCenter.owner(of: v, in: map, except: .snap), .voice)
        XCTAssertNil(HotkeyCenter.owner(of: v, in: map, except: .voice))      // its own keys
        XCTAssertNil(HotkeyCenter.owner(of: combo("opt+shift+X"), in: map, except: .snap))
        XCTAssertNil(HotkeyCenter.owner(of: v, in: map, except: .snap, disabled: [.voice]))
    }

    func testSwapMovesTheKeysAndTurnsTheOtherOff() {
        let v = combo("opt+shift+V")
        let u = HotkeyCenter.swapped(["record": "ctrl+R"], v, to: .snap, from: .voice)
        XCTAssertEqual(u["snap"] as? String, v.spec)
        XCTAssertEqual(u["voice"] as? String, "off")
        XCTAssertEqual(u["record"] as? String, "ctrl+R")       // untouched
        // back to an action's own default: nothing stored for it
        let d = HotkeyCenter.Action.snap.defaultCombo!
        let back = HotkeyCenter.swapped(["snap": "ctrl+A"], d, to: .snap, from: nil)
        XCTAssertNil(back["snap"])
    }

    func testRegistrationReadsWhatAnInstancePublished() {
        let r = HotkeyCenter.Registration(json: ["pid": 42, "started": 100.5, "hotkeys": ["opt+shift+A", "nonsense"],
                                                 "dictation": "fn", "test": true])
        XCTAssertEqual(r?.pid, 42)
        XCTAssertEqual(r?.started, 100.5)
        XCTAssertEqual(r?.keys, [combo("opt+shift+A")])
        XCTAssertEqual(r?.dictation, "fn")
        XCTAssertEqual(r?.test, true)
        // an older build's entry: no start time (counts as the earliest), no dictation key
        let old = HotkeyCenter.Registration(json: ["pid": 7, "hotkeys": []])
        XCTAssertEqual(old?.started, 0)
        XCTAssertNil(old?.dictation)
        XCTAssertNil(HotkeyCenter.Registration(json: ["hotkeys": []]))
    }

    func testTheFirstBlurtKeepsTheDictationKey() {
        typealias R = HotkeyCenter.Registration
        let me = R(pid: 200, started: 50)
        // nobody else listens: this one does
        XCTAssertNil(HotkeyCenter.dictationOwner("fn", me: me, others: []))
        XCTAssertNil(HotkeyCenter.dictationOwner("fn", me: me, others: [R(pid: 100, started: 10, dictation: nil)]))
        // an earlier instance listens to Fn: leave it to that one
        XCTAssertEqual(HotkeyCenter.dictationOwner("fn", me: me, others: [R(pid: 100, started: 10, dictation: "fn")]), 100)
        // a later one doesn't take it away
        XCTAssertNil(HotkeyCenter.dictationOwner("fn", me: me, others: [R(pid: 300, started: 90, dictation: "fn")]))
        // another key: no clash
        XCTAssertNil(HotkeyCenter.dictationOwner("fn", me: me, others: [R(pid: 100, started: 10, dictation: "right_option")]))
        // started in the same instant: the lower pid
        XCTAssertEqual(HotkeyCenter.dictationOwner("fn", me: me, others: [R(pid: 150, started: 50, dictation: "fn")]), 150)
        // a test build (simulated listener) never competes with a real one
        XCTAssertNil(HotkeyCenter.dictationOwner("fn", me: me, others: [R(pid: 100, started: 10, dictation: "fn", test: true)]))
        let testMe = R(pid: 200, started: 50, test: true)
        XCTAssertEqual(HotkeyCenter.dictationOwner("fn", me: testMe, others: [R(pid: 100, started: 10, dictation: "fn", test: true)]), 100)
    }
}
