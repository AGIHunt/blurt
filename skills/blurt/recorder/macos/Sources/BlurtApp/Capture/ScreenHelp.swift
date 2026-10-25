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
    enum Use: String { case snap, record }

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
            island.toast(Loc.t("capture.snap.failed", table: "Capture"), actionTitle: nil, action: nil)
        case .missing:
            var t = Island.Toast(text: Loc.t(use == .snap ? "capture.snap.no_permission" : "capture.record.no_permission", table: "Capture"),
                                 actionTitle: Loc.t("capture.snap.open_settings", table: "Capture")) {
                MainActor.assumeIsolated { PermissionGuide.shared.start(.all, only: [.screen], source: use == .snap ? .island : .capture) }
            }
            t.seconds = 8
            island.toast(t)
        case .stale:
            var t = Island.Toast(text: Loc.t(use == .snap ? "capture.snap.stale" : "capture.record.stale", table: "Capture"),
                                 actionTitle: Loc.t("capture.screen.reallow", table: "Capture")) {
                MainActor.assumeIsolated { PermissionGuide.shared.start(.all, only: [.screen], source: .capture, reauthorize: true) }
            }
            t.seconds = 10
            island.toast(t)
        }
    }
}
