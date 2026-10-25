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
        case .openMain: return nil
        case .voice: return .voice
        case .project: return .project
        case .cards: return .cards
        case .reformat: return .reformat
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
    return l.isEmpty ? "" : Loc.t("capture.hotkey.tip", table: "Capture", l)
}
/// "⌥⇧A next shot" — a hint (a Capture table key) that only exists while the hotkey does.
func hkHint(_ a: HotAction, _ key: String) -> String? {
    let l = hk(a)
    return l.isEmpty ? nil : Loc.t("capture.hotkey.hint", table: "Capture", l, Loc.t(key, table: "Capture"))
}

extension NSMenuItem {
    /// Show (and accept) the user's hotkey for this action as the item's key equivalent — only when it works
    /// (HotkeyResult.worksInMenu): a key another app or another Blurt holds, one that failed to register or a
    /// duplicate isn't advertised; the row's tooltip says why, and where to change it (the menu is rebuilt each time
    /// it opens, so it follows a key that comes free).
    func showHotkey(_ a: HotAction) {
        guard let s = Hotkeys.shared.shortcut(a) else { return }
        let st = Hotkeys.shared.state(a)
        guard st.worksInMenu else {
            toolTip = Loc.t("capture.keys.menu_not_working", table: "Capture", s.label, st.text)
            // the key column never just goes blank: the row says, under its title, that its key isn't working
            if #available(macOS 14.4, *) { subtitle = T("app.menu.key_off", s.label) }
            return
        }
        let (k, f) = s.menuKeyEquivalent
        keyEquivalent = k
        keyEquivalentModifierMask = f
    }
}
