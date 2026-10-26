// The permission guide's pure parts (docs/design/dictation.md §Permissions, the app: Onboarding/PermissionGuide.swift):
// which steps a flow walks and in what order, what macOS's 🌐-key setting means, and where the helper panel docks next
// to the System Settings window. Unit-tested in Tests/BlurtCoreTests/PermissionFlowTests.
//
//   the flow     one "Set up permissions" walk through what's missing, in order: Settings → Privacy walks
//                everything, Screen Recording last (it may want Blurt restarted, which shouldn't cut the walk short);
//                dictation (the setup assistant, Settings → Dictation, the menu row, the island) walks what dictation
//                needs — Screen Recording is asked the first time a snap or a recording needs it. A step is skipped
//                when it is already satisfied (the app decides what that means: Input Monitoring is satisfied once
//                the key is heard by a tap, e.g. the Fn filter on Accessibility).
//   the 🌐 key   `defaults read com.apple.HIToolbox AppleFnUsageType` (System Settings → Keyboard → "Press 🌐 key
//                to"): 0 Do Nothing, 1 Change Input Source, 2 Show Emoji & Symbols, 3 Start Dictation (macOS 26 shows
//                "Start Dictation (Press 🌐 Twice)"). Read only — Blurt never writes it. Unset = macOS's default, which
//                is not "Do Nothing".
//   docking      to the right of the System Settings window if it fits on that screen, else to its left, else inside
//                its lower right corner; with no window, the screen's top right corner.
import Foundation

public enum PermissionKind: String, CaseIterable, Equatable {
    case screen, microphone, accessibility
    case inputMonitoring = "input_monitoring"
    /// not a permission: System Settings → Keyboard → "Press 🌐 key to" set to "Do Nothing" (Fn as the dictation key)
    case fnKey = "fn_key"

    /// The System Settings pane (x-apple.systempreferences URL) — the anchors open the exact list on macOS 13–26.
    public var paneURL: String {
        switch self {
        case .screen: return "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        case .microphone: return "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        case .accessibility: return "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case .inputMonitoring: return "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
        case .fnKey: return "x-apple.systempreferences:com.apple.Keyboard-Settings.extension"
        }
    }

    /// The list takes an app dragged into it (the "+" lists). The microphone list only shows apps that asked.
    public var acceptsDrop: Bool { self == .screen || self == .accessibility || self == .inputMonitoring }
}

public enum PermissionFlowKind: String, Equatable {
    /// everything Blurt uses (Settings → Privacy; a row's Allow, e.g. Screen Recording at the first snap)
    case all
    /// what dictation needs (the setup assistant, Settings → Dictation, the menu row, the island's reminder)
    case dictation

    /// The order the guide walks. Everything: dictation's first, Screen Recording last (it may need a restart).
    /// Dictation: Accessibility first (it pastes, and with Fn it alone hears the key), then Input Monitoring (the key
    /// in every app when it isn't Fn), the microphone, the 🌐 key.
    public var order: [PermissionKind] {
        switch self {
        case .all: return [.microphone, .accessibility, .inputMonitoring, .fnKey, .screen]
        case .dictation: return [.accessibility, .inputMonitoring, .microphone, .fnKey]
        }
    }
}

public enum PermissionPlan {
    /// The steps still to walk: `kinds` (or the flow's order) minus what's satisfied, in the flow's order.
    public static func steps(_ flow: PermissionFlowKind, only kinds: [PermissionKind]? = nil,
                             satisfied: Set<PermissionKind>) -> [PermissionKind] {
        flow.order.filter { (kinds?.contains($0) ?? true) && !satisfied.contains($0) }
            + (kinds ?? []).filter { !flow.order.contains($0) && !satisfied.contains($0) }
    }
}

/// System Settings → Keyboard → "Press 🌐 key to" (com.apple.HIToolbox AppleFnUsageType).
public enum FnUsage: Int, Equatable {
    case doNothing = 0, changeInputSource = 1, emojiAndSymbols = 2, startDictation = 3

    /// The stored value (an NSNumber or a string from `defaults`), nil when unset or unknown.
    public static func from(_ raw: Any?) -> FnUsage? {
        if let n = raw as? Int { return FnUsage(rawValue: n) }
        if let n = raw as? NSNumber { return FnUsage(rawValue: n.intValue) }
        if let s = raw as? String, let n = Int(s.trimmingCharacters(in: .whitespacesAndNewlines)) { return FnUsage(rawValue: n) }
        return nil
    }

    /// Does pressing Fn also do something in macOS? Unset counts as yes (macOS's default is an action).
    public static func clashes(_ u: FnUsage?) -> Bool { u != .doNothing }
}

public enum HelperDock {
    public enum Side: String { case below, right, left, inside, free }

    /// The card's width docked beside the window (or with no window), and its range docked under the list.
    public static let sideWidth: CGFloat = 340
    public static let belowWidth: ClosedRange<CGFloat> = 340...460
    /// System Settings' sidebar, as a share of its window and in pt: the list is the column right of it.
    static let sidebarShare: CGFloat = 0.31
    static let sidebarWidth: ClosedRange<CGFloat> = 190...260
    /// The list's own inset in its column (the rows start this far in).
    static let listInset: CGFloat = 20

    /// The column that holds the permission's list: the window right of its sidebar (Cocoa or CG; only x and width).
    public static func listColumn(_ t: CGRect) -> CGRect {
        let sidebar = min(max(t.width * sidebarShare, sidebarWidth.lowerBound), sidebarWidth.upperBound)
        return CGRect(x: t.minX + sidebar, y: t.minY, width: max(t.width - sidebar, 0), height: t.height)
    }

    /// The helper panel's frame (Cocoa coordinates, y up) for a card of `height` (the window's height: the card and
    /// the notch's room above it when docked below). Under the System Settings window first — as wide as its list less
    /// the list's insets and centred on it, so the card lines up with the list it points at, the notch's tip 2 pt under
    /// the window — when there is room on that screen; else beside the window (`place`). `notch` = the room the window
    /// keeps on each side of the card for the notch.
    public static func dock(height: CGFloat, target: CGRect?, screen: CGRect, notch: CGFloat = 8) -> (frame: CGRect, side: Side) {
        if let t = target, t.width > 40, t.height > 40 {
            let list = listColumn(t)
            let card = min(max(list.width - 2 * listInset, belowWidth.lowerBound), belowWidth.upperBound)
            let w = card + 2 * notch
            let y = t.minY - 2 - height
            if y >= screen.minY + 4 {
                let x = min(max(list.midX - w / 2, screen.minX + 4), screen.maxX - w - 4)
                return (CGRect(x: x, y: y, width: w, height: height), .below)
            }
        }
        let size = CGSize(width: sideWidth + 2 * notch, height: height)
        let (o, side) = place(panel: size, target: target, screen: screen)
        return (CGRect(origin: o, size: size), side)
    }

    /// Beside the window (Cocoa coordinates, y up): `target` = the System Settings window, `screen` = the visible frame
    /// of the screen it is on (or the main screen when there is no window).
    public static func place(panel: CGSize, target: CGRect?, screen: CGRect, gap: CGFloat = 12) -> (origin: CGPoint, side: Side) {
        func clamp(_ p: CGPoint) -> CGPoint {
            CGPoint(x: min(max(p.x, screen.minX + 4), screen.maxX - panel.width - 4),
                    y: min(max(p.y, screen.minY + 4), screen.maxY - panel.height - 4))
        }
        guard let t = target, t.width > 40, t.height > 40 else {
            return (clamp(CGPoint(x: screen.maxX - panel.width - 24, y: screen.maxY - panel.height - 24)), .free)
        }
        // level with the top of the list (below the title bar and the pane's header)
        let y = t.maxY - panel.height - 64
        if t.maxX + gap + panel.width <= screen.maxX {
            return (clamp(CGPoint(x: t.maxX + gap, y: y)), .right)
        }
        if t.minX - gap - panel.width >= screen.minX {
            return (clamp(CGPoint(x: t.minX - gap - panel.width, y: y)), .left)
        }
        return (clamp(CGPoint(x: t.maxX - panel.width - 20, y: t.minY + 20)), .inside)
    }
}
