// Screen Recording when a snap or a recording needs it (v0.9 dogfood): one island line and the permission guide for
// both — the recording used to open a modal alert with three buttons, one of them Quit.
//
//  • missing (macOS doesn't allow it): "Snap / Recording needs Screen Recording" · Open Settings → the guide's
//    Screen Recording step (Blurt in the list, the pane, the helper panel beside it). A snap says it before the
//    picker opens, so no area is dragged for nothing.
//  • stale (macOS says it is on, ScreenCaptureKit refuses: a grant made for an older build — common after an update):
//    "macOS needs Screen Recording allowed again" · Re-allow… → the guide's re-add form: remove Blurt with −, add it
//    again, Restart Blurt. ("Try again" never helped there.)
//  • passing (allowed and working): the snap failed once — "try again".
// BlurtCore ScreenGrant decides; ScreenHelp.probe asks ScreenCaptureKit. Tests: BLURT_TEST_SCREEN_STALE=1 | 0 answers
// the probe (with BLURT_TEST_SCREEN_RECORDING=1 for macOS's own answer), so no real capture is asked for.
import AppKit
import BlurtCore
import ScreenCaptureKit

enum ScreenHelp {
    /// `text`: ⌥C / ⌥T read the screen — told as copying text, not as a snap (the dogfood's Copy Text said "Snapping
    /// needs Screen Recording").
    enum Use: String {
        case snap, record, text
        var missingKey: String { ["snap": "capture.snap.no_permission", "record": "capture.record.no_permission",
                                  "text": "capture.text.no_permission"][rawValue]! }
        var staleKey: String { ["snap": "capture.snap.stale", "record": "capture.record.stale", "text": "capture.text.stale"][rawValue]! }
    }

    /// Does ScreenCaptureKit answer (main queue)? false: a stale grant when macOS says it is allowed.
    static func probe(_ done: @escaping (Bool) -> Void) {
        let env = ProcessInfo.processInfo.environment
        if env["BLURT_TEST_COMMANDS"] == "1", let t = env["BLURT_TEST_SCREEN_STALE"] {
            return DispatchQueue.main.async { done(t != "1") }
        }
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, err in
            DispatchQueue.main.async { done(err == nil && content != nil) }
        }
    }

    /// The island's line for `grant` (nothing for a passing failure of a recording: it says its own).
    static func show(_ use: Use, grant: ScreenGrant) {
        emit(["event": "screen_help", "use": use.rawValue, "grant": grant.rawValue])
        switch grant {
        case .passing:
            island.toast(Loc.t(use == .text ? "capture.text.failed" : "capture.snap.failed", table: "Capture"), key: nil, icon: .warning)
        case .missing:
            var t = Island.Toast(text: Loc.t(use.missingKey, table: "Capture"),
                                 actionTitle: Loc.t("capture.snap.open_settings", table: "Capture")) {
                MainActor.assumeIsolated { PermissionGuide.shared.start(.all, only: [.screen], source: use == .record ? .capture : .island) }
            }
            t.icon = .warning
            t.seconds = 8
            island.toast(t)
        case .stale:
            var t = Island.Toast(text: Loc.t(use.staleKey, table: "Capture"),
                                 actionTitle: Loc.t("capture.screen.reallow", table: "Capture")) {
                MainActor.assumeIsolated { PermissionGuide.shared.start(.all, only: [.screen], source: .capture, reauthorize: true) }
            }
            t.icon = .warning
            t.seconds = 10
            island.toast(t)
        }
    }
}
