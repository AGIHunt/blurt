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
        XCTAssertEqual(combo("cmd+Left").reserved, .menu)
    }

    func testOnlyTheStandardShiftCommandCombosAreReserved() {
        XCTAssertEqual(combo("shift+cmd+Q").reserved, .logOut)
        XCTAssertEqual(combo("shift+cmd+/").reserved, .help)
        XCTAssertEqual(combo("shift+cmd+Left").reserved, .selectText)
        XCTAssertEqual(combo("shift+cmd+S").reserved, .menu)
        XCTAssertEqual(combo("shift+cmd+T").reserved, .menu)
        // screenshot tools' keys (Shottr, CleanShot) and the like stay free; ⇧⌘3 / 4 / 5 are macOS's (.system)
        XCTAssertNil(combo("shift+cmd+1").reserved)
        XCTAssertNil(combo("shift+cmd+2").reserved)
        XCTAssertNil(combo("shift+cmd+3").reserved)
        XCTAssertNil(combo("shift+cmd+D").reserved)
        XCTAssertNil(combo("shift+cmd+A").reserved)
    }

    func testAppMenuAndSystemStandardsWithControlOrOptionAreReserved() {
        XCTAssertEqual(combo("ctrl+cmd+Q").reserved, .lockScreen)
        XCTAssertEqual(combo("ctrl+cmd+F").reserved, .fullScreen)
        XCTAssertEqual(combo("ctrl+cmd+Space").reserved, .emoji)
        XCTAssertEqual(combo("opt+cmd+H").reserved, .hideOthers)
        XCTAssertEqual(combo("opt+cmd+W").reserved, .closeAll)
        XCTAssertEqual(combo("opt+cmd+M").reserved, .minimizeAll)
        // the reason doesn't tell them to add the ⌃ they already hold
        let q = combo("ctrl+cmd+Q")
        XCTAssertNotEqual(q.reserved!.reason(q), Loc.t("capture.keys.reserved", table: "Capture", q.label, StandardShortcut.lockScreen.name!))
        let c = combo("cmd+C")
        XCTAssertEqual(c.reserved!.reason(c), Loc.t("capture.keys.reserved", table: "Capture", c.label, StandardShortcut.copy.name!))
    }

    func testCombosWithOptionOrControlOrFunctionKeysAreFree() {
        XCTAssertNil(combo("opt+shift+A").reserved)          // the defaults
        XCTAssertNil(combo("opt+cmd+C").reserved)
        XCTAssertNil(combo("ctrl+cmd+V").reserved)
        XCTAssertNil(combo("opt+cmd+K").reserved)
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

    func testTheMenuShowsOnlyKeysThatWork() {
        // a key another Blurt or app holds, refused or a duplicate does nothing when pressed: not shown in the menu
        XCTAssertTrue(HotkeyResult.ok.worksInMenu)
        XCTAssertTrue(HotkeyResult.system.worksInMenu, "registered; macOS may win")
        for st in [HotkeyResult.taken(123), .failed(-9878), .duplicate(.snap), .reserved, .off, .notHere] {
            XCTAssertFalse(st.worksInMenu, "\(st)")
        }
        // the reason never carries the raw OSStatus
        XCTAssertFalse(HotkeyResult.failed(-9878).text.contains("9878"))
    }

    func testOwnerFindsTheOtherActionWithTheKeys() {
        let v = combo("opt+shift+V")
        let map: [HotkeyCenter.Action: KeyCombo] = [.snap: combo("opt+shift+A"), .voice: v]
        XCTAssertEqual(HotkeyCenter.owner(of: v, in: map, except: .snap), .voice)
        XCTAssertNil(HotkeyCenter.owner(of: v, in: map, except: .voice))      // its own keys
        XCTAssertNil(HotkeyCenter.owner(of: combo("opt+shift+X"), in: map, except: .snap))
        XCTAssertNil(HotkeyCenter.owner(of: v, in: map, except: .snap, disabled: [.voice]))
    }

    func testSwapExchangesTheKeys() {
        // snap had ⌃⌥A and takes voice's ⌥⇧V: voice gets ⌃⌥A
        let v = combo("opt+shift+V"), mine = combo("ctrl+opt+A")
        let x = HotkeyCenter.swapped(["snap": mine.spec], v, to: .snap, from: .voice, giving: mine)
        XCTAssertEqual(x["snap"] as? String, v.spec)
        XCTAssertEqual(x["voice"] as? String, mine.spec)
        // swapping two defaults back: nothing stored for either
        let snapD = HotkeyCenter.Action.snap.defaultCombo!, voiceD = HotkeyCenter.Action.voice.defaultCombo!
        let back = HotkeyCenter.swapped(["snap": voiceD.spec, "voice": snapD.spec], snapD, to: .snap, from: .voice, giving: voiceD)
        XCTAssertTrue(back.isEmpty)
    }

    func testMoveTakesTheKeysAndTurnsTheOtherOff() {
        // the action had no keys to give: the other one is left off
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

    func testARegistryEntryCountsOnlyWhileItsProcessIsTheBlurtThatWroteIt() {
        typealias R = HotkeyCenter.Registration
        let e = R(pid: 321, started: 1_000_000)
        XCTAssertTrue(HotkeyCenter.isLive(e, processStart: 1_000_000.2, isBlurtApp: { false }))
        // gone
        XCTAssertFalse(HotkeyCenter.isLive(e, processStart: nil, isBlurtApp: { true }))
        // the pid belongs to some other process now (crashed Blurt, reboot, pid reused): not a Blurt
        XCTAssertFalse(HotkeyCenter.isLive(e, processStart: 1_090_000, isBlurtApp: { true }))
        XCTAssertFalse(HotkeyCenter.isLive(e, processStart: 999_000, isBlurtApp: { true }))
        // an older build's entry (no start time): only while that pid is a Blurt app
        let old = R(pid: 321, started: 0)
        XCTAssertTrue(HotkeyCenter.isLive(old, processStart: 5, isBlurtApp: { true }))
        XCTAssertFalse(HotkeyCenter.isLive(old, processStart: 5, isBlurtApp: { false }))
    }

    func testProcessStartIsTheKernelsAndThisInstancePublishesIt() {
        let mine = HotkeyCenter.processStart(getpid())
        XCTAssertNotNil(mine)
        XCTAssertLessThanOrEqual(mine!, Date().timeIntervalSince1970)
        XCTAssertEqual(HotkeyCenter.shared.startedAt, mine)
        // our own entry as another instance would read it: live
        XCTAssertTrue(HotkeyCenter.isLive(HotkeyCenter.Registration(pid: getpid(), started: HotkeyCenter.shared.startedAt)))
        XCTAssertFalse(HotkeyCenter.isLive(HotkeyCenter.Registration(pid: getpid(), started: 1000)))
    }

    func testADeafInstanceNeverHoldsTheDictationKey() {
        typealias R = HotkeyCenter.Registration
        // this one doesn't hear the key yet (not published): one that does keeps it, even if it started later
        let deaf = R(pid: 200, started: 50, dictation: nil)
        XCTAssertEqual(HotkeyCenter.dictationOwner("fn", me: deaf, others: [R(pid: 300, started: 90, dictation: "fn")]), 300)
        // both hear it (they started together): the earlier one keeps it
        let hearing = R(pid: 200, started: 50, dictation: "fn")
        XCTAssertNil(HotkeyCenter.dictationOwner("fn", me: hearing, others: [R(pid: 300, started: 90, dictation: "fn")]))
        XCTAssertEqual(HotkeyCenter.dictationOwner("fn", me: hearing, others: [R(pid: 100, started: 10, dictation: "fn")]), 100)
        // an instance that can't hear it publishes nothing, so it is never deferred to
        XCTAssertNil(HotkeyCenter.dictationOwner("fn", me: deaf, others: [R(pid: 100, started: 10, dictation: nil)]))
    }

    func testTheFirstBlurtKeepsTheDictationKey() {
        typealias R = HotkeyCenter.Registration
        let me = R(pid: 200, started: 50, dictation: "fn")
        // nobody else listens: this one does
        XCTAssertNil(HotkeyCenter.dictationOwner("fn", me: me, others: []))
        XCTAssertNil(HotkeyCenter.dictationOwner("fn", me: me, others: [R(pid: 100, started: 10, dictation: nil)]))
        // an earlier instance listens to Fn: leave it to that one
        XCTAssertEqual(HotkeyCenter.dictationOwner("fn", me: me, others: [R(pid: 100, started: 10, dictation: "fn")]), 100)
        // a later one doesn't take it away from one that hears it
        XCTAssertNil(HotkeyCenter.dictationOwner("fn", me: me, others: [R(pid: 300, started: 90, dictation: "fn")]))
        // another key: no clash
        XCTAssertNil(HotkeyCenter.dictationOwner("fn", me: me, others: [R(pid: 100, started: 10, dictation: "right_option")]))
        // started in the same instant: the lower pid
        XCTAssertEqual(HotkeyCenter.dictationOwner("fn", me: me, others: [R(pid: 150, started: 50, dictation: "fn")]), 150)
        // a test build (simulated listener) never competes with a real one
        XCTAssertNil(HotkeyCenter.dictationOwner("fn", me: me, others: [R(pid: 100, started: 10, dictation: "fn", test: true)]))
        let testMe = R(pid: 200, started: 50, dictation: "fn", test: true)
        XCTAssertEqual(HotkeyCenter.dictationOwner("fn", me: testMe, others: [R(pid: 100, started: 10, dictation: "fn", test: true)]), 100)
    }
}
