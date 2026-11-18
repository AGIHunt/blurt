import XCTest
@testable import BlurtCore

/// The capability switches (Capabilities.swift): what is on by default, where a switch is stored, which shortcuts go
/// with which capability, and which are held when.
final class CapabilitiesTests: XCTestCase {
    private func scratchConfig() -> Config {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("blurt-cap-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return Config(url: dir.appendingPathComponent("config.json"))
    }

    func testEverythingIsOnUntilSwitchedOff() {
        let c = scratchConfig()
        for cap in Capability.allCases { XCTAssertTrue(Capability.isOn(cap, in: c), cap.rawValue) }
    }

    func testASwitchIsStoredAsFalseAndOnAsNothing() {
        let c = scratchConfig()
        XCTAssertTrue(Capability.set(.cards, on: false, in: c))
        XCTAssertEqual(c["app.capabilities.cards"] as? Bool, false)
        XCTAssertFalse(Capability.isOn(.cards, in: c))
        XCTAssertTrue(Capability.isOn(.recording, in: c))
        XCTAssertTrue(Capability.set(.cards, on: true, in: c))
        XCTAssertNil(c["app.capabilities.cards"])           // the default is not written: an old config stays as it was
        XCTAssertTrue(Capability.isOn(.cards, in: c))
    }

    func testDictationKeepsItsOwnKey() {
        let c = scratchConfig()
        XCTAssertEqual(Capability.dictation.configKey, "record.dictation.enabled")
        XCTAssertTrue(Capability.set(.dictation, on: false, in: c))
        XCTAssertEqual(c["record.dictation.enabled"] as? Bool, false)
        XCTAssertNil(c["app.capabilities.dictation"])
    }

    func testEverySwitchSaysItChanged() {
        let c = scratchConfig()
        let said = expectation(forNotification: Capability.didChange, object: nil) { $0.object as? String == "screen_text" }
        Capability.set(.screenText, on: false, in: c)
        wait(for: [said], timeout: 1)
    }

    func testEveryShortcutHasAtMostOneOwnerAndTheAppsOwnHaveNone() {
        for a in HotkeyCenter.Action.allCases {
            XCTAssertLessThanOrEqual(Capability.allCases.filter { $0.hotkeys.contains(a) }.count, 1, a.rawValue)
        }
        XCTAssertNil(Capability.owner(of: .openMenu))
        XCTAssertNil(Capability.owner(of: .openMain))
        // every other shortcut belongs to a capability: one added later must be given an owner (or be the app's own)
        for a in HotkeyCenter.Action.allCases where ![.openMenu, .openMain].contains(a) {
            XCTAssertNotNil(Capability.owner(of: a), a.rawValue)
        }
        XCTAssertEqual(Capability.owner(of: .snap), .cards)
        XCTAssertEqual(Capability.owner(of: .translateText), .screenText)
        XCTAssertEqual(Capability.owner(of: .project), .recording)
        XCTAssertEqual(Capability.owner(of: .reformat), .dictation)
    }

    func testAnOffCapabilityGivesItsShortcutsBack() {
        let off = Capability.disabledHotkeys(off: [.cards, .screenText], recording: false)
        XCTAssertEqual(off, [.snap, .voice, .cards, .text, .translateText])
        XCTAssertTrue(Capability.disabledHotkeys(off: [], recording: false).isEmpty)
        XCTAssertTrue(Capability.disabledHotkeys(off: [.phone], recording: false).isEmpty)
        XCTAssertEqual(Capability.disabledHotkeys(off: [.recording], recording: false), [.toggleRecord, .pause, .pen, .finish, .project])
    }

    func testSnapMarksAMomentWhileRecordingEvenWithCardsOff() {
        XCTAssertFalse(Capability.disabledHotkeys(off: [.cards], recording: true).contains(.snap))
        XCTAssertTrue(Capability.disabledHotkeys(off: [.cards], recording: true).contains(.voice))
        XCTAssertTrue(Capability.disabledHotkeys(off: [.cards], recording: false).contains(.snap))
        // (Recording off: there is no recording to mark)
        XCTAssertTrue(Capability.disabledHotkeys(off: [.cards, .recording], recording: true).contains(.snap))
    }

    func testTheRecordingsOwnKeysAreHeldOnlyWhileItRuns() {
        XCTAssertEqual(Capability.standbyHotkeys(recording: false), [.pause, .pen, .finish])
        XCTAssertTrue(Capability.standbyHotkeys(recording: true).isEmpty)
    }

    func testAllowsFollowsTheSwitches() {
        XCTAssertTrue(Capability.allows(.snap, off: [], recording: false))
        XCTAssertFalse(Capability.allows(.snap, off: [.cards], recording: false))
        XCTAssertTrue(Capability.allows(.snap, off: [.cards], recording: true))
        XCTAssertFalse(Capability.allows(.toggleRecord, off: [.recording], recording: false))
        XCTAssertTrue(Capability.allows(.openMenu, off: Set(Capability.allCases), recording: false))
        // Pause / Draw / Finish are not refused while idle — they are simply not held as keys; a command that reaches
        // them does nothing without a recording
        XCTAssertTrue(Capability.allows(.pause, off: [], recording: false))
    }

    func testAStandbyShortcutReadsAsSetAndIsNotRegistered() {
        let hk = HotkeyCenter()
        hk.standby = [.pause]
        XCTAssertEqual(hk.standby, [.pause])
        XCTAssertTrue(hk.disabled.isEmpty)
    }

    func testPanesFollowTheirCapability() {
        XCTAssertEqual(SettingsCatalog.capability(ofPane: "dictation"), .dictation)
        XCTAssertEqual(SettingsCatalog.capability(ofPane: "remote"), .phone)
        XCTAssertEqual(SettingsCatalog.capability(ofPane: "projects"), .recording)
        XCTAssertNil(SettingsCatalog.capability(ofPane: "general"))
        XCTAssertFalse(SettingsCatalog.paneShown("projects", off: [.recording]))
        XCTAssertTrue(SettingsCatalog.paneShown("projects", off: [.cards]))
        XCTAssertTrue(SettingsCatalog.paneShown("general", off: Set(Capability.allCases)))
    }
}
