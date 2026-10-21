// Global hotkeys (C7). Config record.hotkeys {"record": "opt+shift+R", "snap": "off", …} — the grammar of
// _common.py's parse_hotkey; Action raw values are those config keys. WP4 gate: API only; the implementation
// (today's BlurtApp/App/Hotkeys.swift, Carbon RegisterEventHotKey + conflict detection) moves here next.
import Foundation

/// A key + Carbon modifiers (cmdKey | optionKey | controlKey | shiftKey).
public struct KeyCombo: Hashable {
    public let mods: Int
    public let key: String      // canonical key name: "R", "F5", "Space", "Left"…
    public let code: Int        // virtual key code

    public init(mods: Int, key: String, code: Int) { self.mods = mods; self.key = key; self.code = code }
    /// "ctrl+opt+shift+cmd+R" / "⌥⇧R" / "Alt+Shift+r" → combo; nil for "off" or anything unparseable
    public static func parse(_ s: String) -> KeyCombo? { nil }
    /// stored form, "opt+shift+R"
    public var spec: String { key }
    /// shown form, "⌥⇧R"
    public var label: String { key }
}

public enum HotkeyResult: Equatable {
    case ok
    case off                                  // no keys for this action
    case notHere                              // only the menu-bar app registers it (a chat-started recording doesn't)
    case duplicate(HotkeyCenter.Action)       // same keys as an earlier action: not registered
    case failed(Int32)                        // RegisterEventHotKey refused it (OSStatus)
    case taken(pid_t)                         // another running Blurt holds it
    case system                               // a macOS system shortcut (registered, but macOS may win)

    public var isConflict: Bool {
        switch self {
        case .duplicate, .failed, .taken, .system: return true
        default: return false
        }
    }
}

public final class HotkeyCenter {
    public static let shared = HotkeyCenter()

    public enum Action: String, CaseIterable {
        case toggleRecord = "record", openMenu = "menu", snap, pause, marker, pen, finish = "stop", openMain = "main"
    }

    /// nil = off
    public func binding(_ a: Action) -> KeyCombo? { nil }
    public func state(_ a: Action) -> HotkeyResult { .off }
    /// Saves to config (only differences from the defaults) and re-registers everything at once.
    @discardableResult
    public func set(_ c: KeyCombo?, for a: Action) -> HotkeyResult { .off }
    public func restoreDefaults() {}
    public var conflicts: [Action] { [] }

    public var onFire: ((Action) -> Void)?
    /// any binding or state changed (settings UI refresh)
    public var onChange: (() -> Void)?
}
