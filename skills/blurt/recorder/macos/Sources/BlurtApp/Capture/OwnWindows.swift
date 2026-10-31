// Blurt's own windows as captures see them (BlurtCore CaptureExclusion has the rules): every window is captured like
// any app's unless it is one of the few a capture draws about itself. The windows that are say so with their
// identifier (`mark`); the island panel and the area picker's overlays are known by their class.
//
// Tests: BLURT_TEST_CAPTURE_SELF=1 (with BLURT_TEST_COMMANDS=1) narrows every capture — a recording and a still — to
// this app's own windows (the rest of the screen comes out empty), so a scripted take on a Mac someone is using never
// records their other apps.
import AppKit
import BlurtCore
import ScreenCaptureKit

extension Notification.Name {
    /// A window a capture leaves out came or went (the recorder updates its filter).
    static let blurtOwnWindowsChanged = Notification.Name("dev.blurt.own-windows-changed")
}

enum OwnWindows {
    static func kind(_ w: NSWindow) -> OwnWindow {
        if w is IslandPanel { return .island }
        if w is KeyWindow { return .snapChrome }        // the area picker (snap, record, ⌥C / ⌥T): its dim, loupe, crosshair
        return w.identifier.flatMap { OwnWindow(rawValue: $0.rawValue) } ?? .other
    }

    /// `w` is one of the windows a capture may leave out.
    static func mark(_ w: NSWindow, _ k: OwnWindow) {
        w.identifier = NSUserInterfaceItemIdentifier(k.rawValue)
        NotificationCenter.default.post(name: .blurtOwnWindowsChanged, object: w)
    }

    /// This app's windows with what they are (main thread).
    static var all: [(id: UInt32, kind: OwnWindow)] {
        // (a window the window server doesn't know yet can carry a number past CGWindowID's range: not on screen, skipped)
        NSApp.windows.compactMap { w in UInt32(exactly: w.windowNumber).flatMap { $0 > 0 ? ($0, kind(w)) : nil } }
    }

    /// Record → "Don't record the notch" (record.hide_notch, off by default).
    static var hideNotch: Bool { recordConfig()[CaptureExclusion.hideNotchKey] as? Bool ?? false }

    static var testSelfOnly: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["BLURT_TEST_COMMANDS"] == "1" && env["BLURT_TEST_CAPTURE_SELF"] == "1"
    }

    /// A filter for `display` without the windows `leaveOut` names (this process's), from `content`. Tests
    /// (testSelfOnly): only this app's windows.
    static func filter(_ content: SCShareableContent, display: SCDisplay, leaveOut: Set<UInt32>) -> SCContentFilter {
        let pid = getpid()
        let out = content.windows.filter { $0.owningApplication?.processID == pid && leaveOut.contains($0.windowID) }
        if testSelfOnly, let me = content.applications.first(where: { $0.processID == pid }) {
            return SCContentFilter(display: display, including: [me], exceptingWindows: out)
        }
        return SCContentFilter(display: display, excludingWindows: out)
    }

    /// What a recording leaves out now (main thread).
    static func recordingLeavesOut() -> Set<UInt32> {
        CaptureExclusion.recordingExclusions(all, hideNotch: hideNotch)
    }

    /// What a snap leaves out now (main thread); `keep` stays in.
    static func snapLeavesOut(keep: Set<UInt32> = []) -> Set<UInt32> {
        CaptureExclusion.snapExclusions(all, keep: keep)
    }
}
