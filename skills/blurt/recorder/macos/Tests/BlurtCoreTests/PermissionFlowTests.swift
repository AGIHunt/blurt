// BlurtCore/PermissionFlow.swift: the permission guide's walk (order, what's skipped), the 🌐-key setting and where
// the helper panel docks next to the System Settings window.
import XCTest
@testable import BlurtCore

final class PermissionFlowTests: XCTestCase {
    func testWalksOnlyWhatIsMissingInOrder() {
        // everything: dictation's first, Screen Recording last (it may want a restart, which shouldn't cut the walk)
        XCTAssertEqual(PermissionPlan.steps(.all, satisfied: []), [.microphone, .accessibility, .inputMonitoring, .fnKey, .screen])
        XCTAssertEqual(PermissionPlan.steps(.all, satisfied: [.screen, .accessibility, .fnKey]), [.microphone, .inputMonitoring])
        XCTAssertEqual(PermissionPlan.steps(.all, satisfied: [.microphone, .accessibility, .inputMonitoring]), [.fnKey, .screen])
        // dictation: Accessibility first; Input Monitoring is skipped once the Fn filter hears the key
        XCTAssertEqual(PermissionPlan.steps(.dictation, satisfied: []), [.accessibility, .inputMonitoring, .microphone, .fnKey])
        XCTAssertEqual(PermissionPlan.steps(.dictation, satisfied: [.inputMonitoring, .microphone]), [.accessibility, .fnKey])
        XCTAssertFalse(PermissionPlan.steps(.dictation, satisfied: []).contains(.screen))
        XCTAssertEqual(PermissionPlan.steps(.dictation, satisfied: Set(PermissionKind.allCases)), [])
    }

    func testOnlySomeKinds() {
        // a row's Allow walks that one; the order is the flow's whatever the caller's order
        XCTAssertEqual(PermissionPlan.steps(.all, only: [.inputMonitoring], satisfied: []), [.inputMonitoring])
        XCTAssertEqual(PermissionPlan.steps(.dictation, only: [.microphone, .accessibility], satisfied: []), [.accessibility, .microphone])
        XCTAssertEqual(PermissionPlan.steps(.dictation, only: [.fnKey], satisfied: [.fnKey]), [])
        // the first snap / recording asks for Screen Recording alone
        XCTAssertEqual(PermissionPlan.steps(.all, only: [.screen], satisfied: []), [.screen])
        XCTAssertEqual(PermissionPlan.steps(.all, only: [.screen], satisfied: [.screen]), [])
        // a kind outside the flow still comes (after the flow's own)
        XCTAssertEqual(PermissionPlan.steps(.dictation, only: [.screen], satisfied: []), [.screen])
    }

    func testPaneURLs() {
        XCTAssertEqual(PermissionKind.accessibility.paneURL, "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        XCTAssertEqual(PermissionKind.inputMonitoring.paneURL, "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
        XCTAssertEqual(PermissionKind.screen.paneURL, "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        XCTAssertEqual(PermissionKind.microphone.paneURL, "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        XCTAssertEqual(PermissionKind.fnKey.paneURL, "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")
        XCTAssertTrue(PermissionKind.accessibility.acceptsDrop)
        XCTAssertFalse(PermissionKind.microphone.acceptsDrop)        // only apps that asked are listed there
        XCTAssertFalse(PermissionKind.fnKey.acceptsDrop)
    }

    func testFnUsage() {
        XCTAssertEqual(FnUsage.from(0), .doNothing)
        XCTAssertEqual(FnUsage.from(NSNumber(value: 1)), .changeInputSource)
        XCTAssertEqual(FnUsage.from("2\n"), .emojiAndSymbols)        // `defaults read` output
        XCTAssertEqual(FnUsage.from(3), .startDictation)
        XCTAssertNil(FnUsage.from(nil))
        XCTAssertNil(FnUsage.from(9))
        XCTAssertFalse(FnUsage.clashes(.doNothing))
        XCTAssertTrue(FnUsage.clashes(.startDictation))
        XCTAssertTrue(FnUsage.clashes(nil))                           // unset: macOS's default is an action
    }

    func testDocking() {
        let screen = CGRect(x: 0, y: 0, width: 1800, height: 1100)
        let panel = CGSize(width: 330, height: 220)
        // room on the right: beside the window, level with the top of its list
        var p = HelperDock.place(panel: panel, target: CGRect(x: 300, y: 200, width: 720, height: 640), screen: screen)
        XCTAssertEqual(p.side, .right)
        XCTAssertEqual(p.origin, CGPoint(x: 1032, y: 200 + 640 - 220 - 64))
        // window against the right edge: on its left
        p = HelperDock.place(panel: panel, target: CGRect(x: 1060, y: 200, width: 720, height: 640), screen: screen)
        XCTAssertEqual(p.side, .left)
        XCTAssertEqual(p.origin.x, 1060 - 12 - 330)
        // a window filling the screen: inside its lower right corner
        p = HelperDock.place(panel: panel, target: CGRect(x: 0, y: 0, width: 1800, height: 1100), screen: screen)
        XCTAssertEqual(p.side, .inside)
        XCTAssertEqual(p.origin, CGPoint(x: 1800 - 330 - 20, y: 20))
        // no window: the screen's top right corner
        p = HelperDock.place(panel: panel, target: nil, screen: screen)
        XCTAssertEqual(p.side, .free)
        XCTAssertEqual(p.origin, CGPoint(x: 1800 - 330 - 24, y: 1100 - 220 - 24))
        // a window near the top keeps the panel on screen
        p = HelperDock.place(panel: panel, target: CGRect(x: 100, y: 900, width: 600, height: 150), screen: screen)
        XCTAssertLessThanOrEqual(p.origin.y + panel.height, screen.maxY)
        XCTAssertGreaterThanOrEqual(p.origin.y, screen.minY)
        // a second screen to the left (negative x)
        let left = CGRect(x: -1440, y: 0, width: 1440, height: 900)
        p = HelperDock.place(panel: panel, target: CGRect(x: -1300, y: 100, width: 700, height: 600), screen: left)
        XCTAssertEqual(p.side, .right)
        XCTAssertEqual(p.origin.x, -1300 + 700 + 12)
    }

    /// Under the list first: as wide as the list column (the window right of its sidebar) less its insets, centred on
    /// it, the notch's tip just under the window; beside it only when there is no room below.
    func testDockingUnderTheList() {
        let screen = CGRect(x: 0, y: 0, width: 1800, height: 1100)
        // System Settings at its usual 715 pt: a 222 pt sidebar, a 493 pt list → a 453 pt card (+ the notch's room)
        let t = CGRect(x: 300, y: 300, width: 715, height: 640)
        let list = HelperDock.listColumn(t)
        XCTAssertEqual(list.minX, 300 + 715 * 0.31, accuracy: 0.01)
        XCTAssertEqual(list.maxX, t.maxX, accuracy: 0.01)
        var d = HelperDock.dock(height: 110, target: t, screen: screen, notch: 8)
        XCTAssertEqual(d.side, .below)
        XCTAssertEqual(d.frame.width - 16, list.width - 40, accuracy: 0.01)
        XCTAssertEqual(d.frame.midX, list.midX, accuracy: 0.01)                   // centred on the list, not the window
        XCTAssertEqual(d.frame.maxY, t.minY - 2, accuracy: 0.01)                  // right under it
        // a narrow window: never under 340; a wide one: never over 460
        d = HelperDock.dock(height: 110, target: CGRect(x: 300, y: 300, width: 500, height: 600), screen: screen, notch: 8)
        XCTAssertEqual(d.frame.width, 340 + 16)
        d = HelperDock.dock(height: 110, target: CGRect(x: 100, y: 300, width: 1400, height: 600), screen: screen, notch: 8)
        XCTAssertEqual(d.frame.width, 460 + 16)
        // no room below (the window at the screen's foot): beside it, at the side width
        d = HelperDock.dock(height: 110, target: CGRect(x: 300, y: 60, width: 715, height: 640), screen: screen, notch: 8)
        XCTAssertEqual(d.side, .right)
        XCTAssertEqual(d.frame.width, HelperDock.sideWidth + 16)
        XCTAssertEqual(d.frame.minX, 300 + 715 + 12)
        // no window: the screen's top right
        XCTAssertEqual(HelperDock.dock(height: 110, target: nil, screen: screen).side, .free)
        // near a screen edge it stays on that screen
        d = HelperDock.dock(height: 110, target: CGRect(x: 1500, y: 400, width: 715, height: 600), screen: screen, notch: 8)
        XCTAssertLessThanOrEqual(d.frame.maxX, screen.maxX)
    }
}
