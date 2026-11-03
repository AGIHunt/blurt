// Which of Blurt's own windows a capture leaves out (BA-60…66 round, 2026-10-31). The founder reports Blurt's own
// problems with Blurt, so Blurt is captured as it looks — the main window, Settings, panels, the hanging cards, the
// note bubble, the pen's ink and the island — like any other app. Only what a capture draws about itself stays out:
//
//   recording   the 3-2-1 before it (the take starts after it is gone, and it is left out as well should it still be
//               on screen), the frame round the recorded area (it lies just outside the area: left out anyway, so a
//               region flush with a display edge never shows a sliver of it), and — with "Don't record the notch"
//               (record.hide_notch, off by default) — the island and the caption line that hangs under it.
//               Everything a snap taken during the take draws (the picker's dim, the loupe, the flash, the card
//               flying up) is recorded: that is the snap flow the founder wants to see in the video.
//   snap        the snap flow's own chrome only: the area picker's overlay (its dim, loupe and crosshair) and the
//               short-lived flash / flight windows. The island and the hanging cards are in the picture. The notch
//               setting is about recordings only.
import Foundation

/// What one of Blurt's own windows is, as far as captures care. The raw value is the window's identifier (BlurtApp
/// OwnWindows marks the windows it makes); `other` is every ordinary window — captured like any app's.
public enum OwnWindow: String, CaseIterable {
    case island = "blurt.island"
    case islandCaption = "blurt.island-caption"
    case countdown = "blurt.countdown"
    case recordingFrame = "blurt.recording-frame"
    case snapChrome = "blurt.snap-chrome"
    case other = "blurt.window"
}

public enum CaptureExclusion {
    /// The setting's key under record (Settings → General → Recording, "Don't record the notch").
    public static let hideNotchKey = "hide_notch"

    /// A recording leaves this window out.
    public static func leftOutOfRecording(_ w: OwnWindow, hideNotch: Bool) -> Bool {
        switch w {
        case .countdown, .recordingFrame: return true
        case .island, .islandCaption: return hideNotch
        case .snapChrome, .other: return false
        }
    }

    /// A snap (⌥A, ⌥C / ⌥T's picture, a still taken while recording) leaves this window out.
    public static func leftOutOfSnap(_ w: OwnWindow) -> Bool { w == .snapChrome }

    /// The window ids to leave out of a recording, from (id, kind) pairs of this process's windows.
    public static func recordingExclusions(_ windows: [(id: UInt32, kind: OwnWindow)], hideNotch: Bool) -> Set<UInt32> {
        Set(windows.filter { leftOutOfRecording($0.kind, hideNotch: hideNotch) }.map(\.id))
    }

    /// The window ids to leave out of a snap; `keep` stays in whatever it is.
    public static func snapExclusions(_ windows: [(id: UInt32, kind: OwnWindow)], keep: Set<UInt32> = []) -> Set<UInt32> {
        Set(windows.filter { leftOutOfSnap($0.kind) && !keep.contains($0.id) }.map(\.id))
    }
}

/// The clicks a recording logs (events.jsonl "click"): from the global monitor (other apps) and, since Blurt's own
/// windows are in the video, from the local one (Blurt's windows). One mouse-down reaches only one of them; a repeat
/// of the same event (same time stamp and button) is dropped all the same, so nothing is ever logged twice.
public struct ClickLog {
    private var last: (time: Double, button: String)?
    public init() {}

    /// Log this mouse-down (its event time stamp, "left" | "right")?
    public mutating func fresh(time: Double, button: String) -> Bool {
        if let l = last, l.button == button, abs(l.time - time) < 0.0005 { return false }
        last = (time, button)
        return true
    }
}
