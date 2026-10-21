// App-side glue for BlurtCore's HotkeyCenter (the configurable global hotkeys, conflict detection, Carbon
// registration): the old names the app's code uses, the action → HK mapping, and hint helpers.
import AppKit
import BlurtCore

typealias HotAction = HotkeyCenter.Action
typealias Shortcut = KeyCombo
typealias HotState = HotkeyResult
typealias Hotkeys = HotkeyCenter

extension HotkeyCenter.Action {
    /// the app's handler id (CarbonHotkeys.swift); nil = handled outside the recorder (openMain)
    var hk: HK? {
        switch self {
        case .toggleRecord: return .toggleRec
        case .openMenu: return .menu
        case .snap: return .snap
        case .pause: return .pause
        case .marker: return .marker
        case .pen: return .pen
        case .finish: return .stop
        case .openMain, .voice, .project: return nil
        }
    }
}

extension HotkeyCenter {
    func shortcut(_ a: HotAction) -> Shortcut? { binding(a) }
}

/// The user's actual keys, for hints: "⌥⇧A", "" when that hotkey is off.
func hk(_ a: HotAction) -> String { Hotkeys.shared.label(a) }
/// "（⌥⇧P）" / " (⌥⇧P)" for tooltips, "" when off.
func hkTip(_ a: HotAction) -> String {
    let l = hk(a)
    return l.isEmpty ? "" : L("（\(l)）", " (\(l))")
}
/// "⌥⇧A 下一张" — a hint that only exists while the hotkey does.
func hkHint(_ a: HotAction, _ zh: String, _ en: String) -> String? {
    let l = hk(a)
    return l.isEmpty ? nil : "\(l) " + L(zh, en)
}

extension NSMenuItem {
    /// Show (and accept) the user's hotkey for this action as the item's key equivalent.
    func showHotkey(_ a: HotAction) {
        guard let s = Hotkeys.shared.shortcut(a) else { return }
        let (k, f) = s.menuKeyEquivalent
        keyEquivalent = k
        keyEquivalentModifierMask = f
    }
}
