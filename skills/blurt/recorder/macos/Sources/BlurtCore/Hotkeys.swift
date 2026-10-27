// Configurable global hotkeys (C7): config record.hotkeys {"record": "opt+shift+R", "snap": "off", …} — the grammar
// of _common.py's parse_hotkey, which the Windows recorder reads. Registration goes through Carbon
// (RegisterEventHotKey: works without Accessibility permission, even when we're not the active app).
//
// Never accepted: the keys every app already gives a meaning to (KeyCombo.reserved — ⌘ with any typing key: ⌘C, ⌘Q,
// ⌘Space…; the standard ⇧⌘ ones: ⇧⌘Z, ⇧⌘Q…; ⌃⌘Q, ⌃⌘F, ⌥⌘H…). The recorder field refuses them with the reason (a
// macOS system shortcut is named as macOS's first); one in config.json is never registered, and said so.
// Conflicts (shown by the Shortcuts window / settings, and once as a toast):
//  • a reserved combo read from config.json (not registered)                                 → .reserved
//  • two of our actions on the same keys (the second isn't registered; the recorder field asks to swap instead of
//    ever leaving this behind)                                                                 → .duplicate(first)
//  • RegisterEventHotKey refused it (only happens inside one process)                         → .failed(OSStatus)
//  • another running Blurt holds it (then we don't register it at all): every resident instance publishes its keys
//    — and the dictation key while it really hears it, so a second one leaves Fn alone, and a deaf one never keeps
//    it — in ~/Library/Caches/dev.blurt.recorder/hotkeys/<pid>.json, whatever its bundle id. An entry counts only
//    while its pid is still the process that wrote it (same start time: a crashed instance's file outlives it and
//    its pid is reused after a reboot; HotkeyCenter.isLive), others are deleted; an instance of our bundle id that
//    doesn't (older build) is assumed to hold the ⌥⇧ defaults once it has run 5 s (younger: still starting). The app
//    applies again when another instance quits, so the keys come over to the one left    → .taken(pid)
//  • a macOS system shortcut (CopySymbolicHotKeys: Spotlight, screenshots, Mission Control…) → .system
// BLURT_HOTKEY_MODS (tests) replaces the defaults' modifiers, e.g. ctrl+opt+shift+cmd.
//
// Besides the configurable actions (→ onFire), the app registers fixed keys of its own (Esc while the pen is on,
// ↩ / Esc / F in the area picker) through registerRaw / onRaw — ids below 100; actions use 100+.
import AppKit
import Carbon.HIToolbox

public let carbonModMask = cmdKey | shiftKey | optionKey | controlKey

/// "ctrl+opt+shift+cmd" → Carbon modifiers (nil for nil / ""). BLURT_HOTKEY_MODS uses it.
public func hotkeyMods(_ spec: String?) -> Int? {
    guard let spec = spec, !spec.isEmpty else { return nil }
    var m = 0
    for p in spec.lowercased().split(separator: "+") {
        switch p {
        case "ctrl", "control": m |= controlKey
        case "opt", "option", "alt": m |= optionKey
        case "shift": m |= shiftKey
        case "cmd", "command": m |= cmdKey
        default: break
        }
    }
    return m
}

/// The defaults' modifiers: ⌥⇧, or BLURT_HOTKEY_MODS (tests keep away from the user's running Blurt that way).
public let defaultHotkeyMods = hotkeyMods(ProcessInfo.processInfo.environment["BLURT_HOTKEY_MODS"]).flatMap { $0 == 0 ? nil : $0 }
    ?? (optionKey | shiftKey)

/// name (as stored) → (virtual key code, glyph shown to the user)
public let hotkeyKeyTable: [(name: String, code: Int, glyph: String)] = {
    var t: [(String, Int, String)] = []
    let letters: [Int] = [kVK_ANSI_A, kVK_ANSI_B, kVK_ANSI_C, kVK_ANSI_D, kVK_ANSI_E, kVK_ANSI_F, kVK_ANSI_G, kVK_ANSI_H, kVK_ANSI_I,
                          kVK_ANSI_J, kVK_ANSI_K, kVK_ANSI_L, kVK_ANSI_M, kVK_ANSI_N, kVK_ANSI_O, kVK_ANSI_P, kVK_ANSI_Q, kVK_ANSI_R,
                          kVK_ANSI_S, kVK_ANSI_T, kVK_ANSI_U, kVK_ANSI_V, kVK_ANSI_W, kVK_ANSI_X, kVK_ANSI_Y, kVK_ANSI_Z]
    for (i, c) in letters.enumerated() { let n = String(UnicodeScalar(UInt8(65 + i))); t.append((n, c, n)) }
    let digits: [Int] = [kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
    for (i, c) in digits.enumerated() { t.append(("\(i)", c, "\(i)")) }
    let f: [Int] = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12,
                    kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
    for (i, c) in f.enumerated() { t.append(("F\(i + 1)", c, "F\(i + 1)")) }
    t += [("Space", kVK_Space, "Space"), ("Tab", kVK_Tab, "⇥"), ("Return", kVK_Return, "↩"),
          ("Left", kVK_LeftArrow, "←"), ("Right", kVK_RightArrow, "→"), ("Up", kVK_UpArrow, "↑"), ("Down", kVK_DownArrow, "↓"),
          ("-", kVK_ANSI_Minus, "-"), ("=", kVK_ANSI_Equal, "="), ("[", kVK_ANSI_LeftBracket, "["), ("]", kVK_ANSI_RightBracket, "]"),
          (";", kVK_ANSI_Semicolon, ";"), ("'", kVK_ANSI_Quote, "'"), (",", kVK_ANSI_Comma, ","), (".", kVK_ANSI_Period, "."),
          ("/", kVK_ANSI_Slash, "/"), ("\\", kVK_ANSI_Backslash, "\\"), ("`", kVK_ANSI_Grave, "`")]
    return t
}()

/// A key + Carbon modifiers (cmdKey | optionKey | controlKey | shiftKey).
public struct KeyCombo: Hashable {
    public let mods: Int
    public let key: String     // canonical name from hotkeyKeyTable: "R", "F5", "Space", "Left"…
    public let code: Int       // virtual key code

    public init?(mods: Int, key: String) {
        guard let e = hotkeyKeyTable.first(where: { $0.name == key }) else { return nil }
        self.mods = mods & carbonModMask
        self.key = e.name
        self.code = e.code
    }
    public init?(mods: Int, code: Int) {
        guard let e = hotkeyKeyTable.first(where: { $0.code == code }) else { return nil }
        self.mods = mods & carbonModMask
        self.key = e.name
        self.code = code
    }

    /// Needs ⌃ / ⌥ / ⌘ — shift alone would steal typing — except F-keys.
    public var isAcceptable: Bool { mods & (cmdKey | optionKey | controlKey) != 0 || isFunctionKey }

    var isFunctionKey: Bool { key.hasPrefix("F") && key.count > 1 }

    /// The keys every Mac app (or macOS itself, outside CopySymbolicHotKeys) already gives a meaning to. As a global
    /// hotkey they would take Copy or Quit away from every app — never accepted (the recorder field says why), never
    /// registered from config.json. nil = free to use. The set:
    ///  • ⌘ alone with any typing or navigation key (⌘C, ⌘Q, ⌘1, ⌘←, ⌘Space…) — the app in front's menus and fields;
    ///  • ⇧⌘ only with the standard ones (⇧⌘Z Redo, ⇧⌘S, ⇧⌘N, ⇧⌘T, ⇧⌘G, ⇧⌘Q Log Out, ⇧⌘[ ⇧⌘] tabs, ⇧⌘/ Help,
    ///    ⇧⌘←→↑↓ selecting text, ⇧⌘Tab, ⇧⌘`) — ⇧⌘1 / ⇧⌘2 and the like are fine (screenshot tools use them);
    ///  • the app-menu and system standards: ⌃⌘Q Lock Screen, ⌃⌘F Full Screen, ⌃⌘Space Emoji & Symbols, ⌥⌘H Hide
    ///    Others, ⌥⌘W Close All, ⌥⌘M Minimize All.
    /// F-keys are never reserved. macOS's own configurable shortcuts (⇧⌘3 / 4 / 5, Spotlight…) are .system instead.
    public var reserved: StandardShortcut? {
        guard !isFunctionKey else { return nil }
        switch mods {
        case cmdKey:
            switch key {
            case "C": return .copy
            case "V": return .paste
            case "X": return .cut
            case "Z": return .undo
            case "A": return .selectAll
            case "Q": return .quit
            case "W": return .close
            case "S": return .save
            case "N": return .new
            case "O": return .open
            case "P": return .print
            case "F": return .find
            case "H": return .hide
            case "M": return .minimize
            case "T": return .newTab
            case "Tab": return .appSwitcher
            case "Space": return .spotlight
            case "`": return .windows
            case ",": return .settings
            default: return .menu
            }
        case cmdKey | shiftKey:
            switch key {
            case "Z": return .redo
            case "Q": return .logOut
            case "/": return .help
            case "Tab": return .appSwitcher
            case "`": return .windows
            case "Left", "Right", "Up", "Down": return .selectText
            case "S", "N", "T", "G", "[", "]": return .menu
            default: return nil
            }
        case cmdKey | controlKey:
            switch key {
            case "Q": return .lockScreen
            case "F": return .fullScreen
            case "Space": return .emoji
            default: return nil
            }
        case cmdKey | optionKey:
            switch key {
            case "H": return .hideOthers
            case "W": return .closeAll
            case "M": return .minimizeAll
            default: return nil
            }
        default:
            return nil
        }
    }

    /// "ctrl+opt+shift+cmd+R", the stored form
    public var spec: String {
        var p: [String] = []
        if mods & controlKey != 0 { p.append("ctrl") }
        if mods & optionKey != 0 { p.append("opt") }
        if mods & shiftKey != 0 { p.append("shift") }
        if mods & cmdKey != 0 { p.append("cmd") }
        return (p + [key]).joined(separator: "+")
    }
    /// "⌃⌥⇧⌘R", Apple's order
    public var label: String {
        var s = ""
        if mods & controlKey != 0 { s += "⌃" }
        if mods & optionKey != 0 { s += "⌥" }
        if mods & shiftKey != 0 { s += "⇧" }
        if mods & cmdKey != 0 { s += "⌘" }
        return s + (hotkeyKeyTable.first { $0.name == key }?.glyph ?? key)
    }

    public static func isOff(_ s: String) -> Bool {
        ["off", "none", "disabled", "-", ""].contains(s.trimmingCharacters(in: .whitespaces).lowercased())
    }

    /// "opt+shift+R" / "⌥⇧R" / "Alt+Shift+r" / "ctrl+F5" (as _common.py's parse_hotkey); nil for off / unparseable
    public static func parse(_ raw: String) -> KeyCombo? {
        var s = Substring(raw.trimmingCharacters(in: .whitespaces))
        if isOff(String(s)) { return nil }
        var mods = 0
        let glyph: [Character: Int] = ["⌃": controlKey, "^": controlKey, "⌥": optionKey, "⇧": shiftKey, "⌘": cmdKey]
        while let c = s.first, let m = glyph[c] { mods |= m; s = s.dropFirst() }
        let names: [String: Int] = ["ctrl": controlKey, "control": controlKey, "opt": optionKey, "option": optionKey, "alt": optionKey,
                                    "shift": shiftKey, "cmd": cmdKey, "command": cmdKey, "win": cmdKey, "super": cmdKey, "meta": cmdKey]
        let alias: [String: String] = ["space": "Space", "spacebar": "Space", "tab": "Tab", "return": "Return", "enter": "Return",
                                       "left": "Left", "right": "Right", "up": "Up", "down": "Down",
                                       "←": "Left", "→": "Right", "↑": "Up", "↓": "Down"]
        var key: String?
        for tok in s.replacingOccurrences(of: " ", with: "").split(separator: "+").map(String.init) where !tok.isEmpty {
            if tok.count > 1, let m = names[tok.lowercased()] { mods |= m; continue }
            if tok.count == 1, let c = tok.first, let m = glyph[c], c != "^" { mods |= m; continue }
            guard key == nil else { return nil }
            if let a = alias[tok.lowercased()] { key = a }
            else if tok.count == 1 { key = tok.uppercased() }
            else if tok.lowercased().hasPrefix("f"), let n = Int(tok.dropFirst()), (1...20).contains(n) { key = "F\(n)" }
            else { return nil }
        }
        guard let k = key, let sc = KeyCombo(mods: mods, key: k), sc.isAcceptable else { return nil }
        return sc
    }

    /// For NSMenuItem.keyEquivalent / keyEquivalentModifierMask
    public var menuKeyEquivalent: (String, NSEvent.ModifierFlags) {
        var f: NSEvent.ModifierFlags = []
        if mods & controlKey != 0 { f.insert(.control) }
        if mods & optionKey != 0 { f.insert(.option) }
        if mods & shiftKey != 0 { f.insert(.shift) }
        if mods & cmdKey != 0 { f.insert(.command) }
        let special: [String: Int] = ["Left": NSLeftArrowFunctionKey, "Right": NSRightArrowFunctionKey, "Up": NSUpArrowFunctionKey,
                                      "Down": NSDownArrowFunctionKey]
        if let u = special[key] { return (String(UnicodeScalar(UInt16(u)).map(Character.init) ?? " "), f) }
        if key.hasPrefix("F"), key.count > 1, let n = Int(key.dropFirst()) {
            return (String(UnicodeScalar(UInt16(NSF1FunctionKey + n - 1)).map(Character.init) ?? " "), f)
        }
        switch key {
        case "Space": return (" ", f)
        case "Tab": return ("\t", f)
        case "Return": return ("\r", f)
        default: return (key.lowercased(), f)
        }
    }

    public static func carbonMods(_ f: NSEvent.ModifierFlags) -> Int {
        var m = 0
        if f.contains(.control) { m |= controlKey }
        if f.contains(.option) { m |= optionKey }
        if f.contains(.shift) { m |= shiftKey }
        if f.contains(.command) { m |= cmdKey }
        return m
    }
}

/// What a reserved combo (KeyCombo.reserved) does everywhere: its menu item's name, or `.menu` — some app's own.
public enum StandardShortcut: String, CaseIterable {
    case copy, paste, cut, undo, redo, selectAll = "select_all", quit, close, save, new, open, print, find, hide, minimize
    case newTab = "new_tab", appSwitcher = "app_switcher", spotlight, windows, settings
    case logOut = "log_out", help, selectText = "select_text", lockScreen = "lock_screen", fullScreen = "full_screen", emoji
    case hideOthers = "hide_others", closeAll = "close_all", minimizeAll = "minimize_all"
    case menu

    /// "拷贝" / "Copy" (nil for `.menu`)
    public var name: String? { self == .menu ? nil : Loc.t("capture.keys.std.\(rawValue)", table: "Capture") }

    /// Under the action's name: "⌘C is Copy in every app — add ⌥ or ⌃" (a combo that has ⌥ or ⌃ already, ⌃⌘Q: "pick
    /// another").
    public func reason(_ c: KeyCombo) -> String {
        let pick = c.mods & (optionKey | controlKey) != 0 ? "_pick" : ""
        return name.map { Loc.t("capture.keys.reserved\(pick)", table: "Capture", c.label, $0) }
            ?? Loc.t("capture.keys.reserved_menu\(pick)", table: "Capture", c.label)
    }
    /// Inside the 140 pt field: "⌘C is Copy".
    public func short(_ c: KeyCombo) -> String {
        name.map { Loc.t("capture.keys.reserved_short", table: "Capture", c.label, $0) }
            ?? Loc.t("capture.keys.reserved_short_menu", table: "Capture", c.label)
    }
}

public enum HotkeyResult: Equatable {
    case ok
    case off                                  // no keys for this action
    case notHere                              // only the menu-bar app registers it (a chat-started recording doesn't)
    case duplicate(HotkeyCenter.Action)       // same keys as an earlier action: not registered
    case failed(Int32)                        // RegisterEventHotKey refused it (OSStatus)
    case taken(pid_t)                         // another running Blurt holds it: not registered
    case system                               // a macOS system shortcut (registered, but macOS may win)
    case reserved                             // ⌘ / ⇧⌘ + a typing key (KeyCombo.reserved), e.g. from a hand-edited
                                              // config.json: never registered

    public var isConflict: Bool {
        switch self {
        case .duplicate, .failed, .taken, .system, .reserved: return true
        default: return false
        }
    }
    /// The menu may show this key next to its row: it is registered (a macOS shortcut is registered too, macOS may
    /// win). Taken by another Blurt, refused, a duplicate or reserved: the row shows no key — pressing it does nothing.
    public var worksInMenu: Bool {
        switch self {
        case .ok, .system: return true
        default: return false
        }
    }

    public var text: String {
        switch self {
        case .ok, .notHere: return ""
        case .off: return Loc.t("capture.keys.state_off", table: "Capture")
        case .duplicate(let a): return Loc.t("capture.keys.duplicate", table: "Capture", a.title)
        case .failed: return Loc.t("capture.keys.failed", table: "Capture")      // the OSStatus goes to the log, not here
        case .taken(let pid): return Loc.t("capture.keys.taken", table: "Capture", "\(pid)")
        case .system: return Loc.t("capture.keys.system", table: "Capture")
        case .reserved: return Loc.t("capture.keys.reserved_state", table: "Capture")
        }
    }
}

public final class HotkeyCenter {
    public static let shared = HotkeyCenter()

    /// Raw values are the config keys (record.hotkeys) — shared with _common.py / the Windows recorder.
    public enum Action: String, CaseIterable {
        case toggleRecord = "record", openMenu = "menu", snap, pause, marker, pen, finish = "stop", openMain = "main", voice, project
        /// ⌥⇧H: every hanging card comes down and stays (K7; macOS only — the island's cards)
        case cards
        /// ⌥⇧L: reformat the last dictation — verbatim → light → structured, with undo (macOS only; dictation-styles.md)
        case reformat

        /// nil = off unless the user sets one
        public var defaultKey: String? {
            switch self {
            case .toggleRecord: return "R"
            case .openMenu: return "B"
            case .snap: return "A"
            case .pause: return "P"
            case .marker: return "M"
            case .pen: return "D"
            case .finish: return "S"
            case .openMain: return nil
            case .voice: return "V"
            case .project: return "O"
            case .cards: return "H"
            case .reformat: return "L"
            }
        }
        public var title: String {
            switch self {
            case .toggleRecord: return Loc.t("capture.action.record", table: "Capture")
            case .openMenu: return Loc.t("capture.action.menu", table: "Capture")
            case .snap: return Loc.t("capture.action.snap", table: "Capture")
            case .pause: return Loc.t("capture.action.pause", table: "Capture")
            case .marker: return Loc.t("capture.action.marker", table: "Capture")
            case .pen: return Loc.t("capture.action.pen", table: "Capture")
            case .finish: return Loc.t("capture.action.stop", table: "Capture")
            case .openMain: return Loc.t("capture.action.main", table: "Capture")
            case .voice: return Loc.t("capture.action.voice", table: "Capture")
            case .project: return Loc.t("capture.action.project", table: "Capture")
            case .cards: return Loc.t("capture.action.cards", table: "Capture")
            case .reformat: return Loc.t("capture.action.reformat", table: "Capture")
            }
        }
        /// Only the menu-bar app registers these (a recording started from the chat has no menu or window to open).
        public var residentOnly: Bool { [.toggleRecord, .openMenu, .openMain, .voice, .project, .cards, .reformat].contains(self) }
        public var defaultCombo: KeyCombo? { defaultKey.flatMap { KeyCombo(mods: defaultHotkeyMods, key: $0) } }
        var carbonID: UInt32 { 100 + UInt32(Action.allCases.firstIndex(of: self)!) }
    }

    public private(set) var map: [Action: KeyCombo] = [:]          // absent = off
    public private(set) var states: [Action: HotkeyResult] = [:]
    public private(set) var invalid: [Action: String] = [:]         // unparseable config entries (fall back to the default)
    /// The menu-bar app (registers residentOnly actions, publishes its keys for other instances).
    public var resident = false
    /// While a settings field records a shortcut: nothing registered, so the keys reach the field.
    public var suspended = false { didSet { apply() } }
    /// Actions that should not be offered or registered here (e.g. openMain before there is a main window).
    public var disabled: Set<Action> = []

    public var onFire: ((Action) -> Void)?
    /// The keys of an action were let go (only voice input cares: push-to-talk)
    public var onRelease: ((Action) -> Void)?
    /// Fixed keys registered with registerRaw
    public var onRaw: ((UInt32) -> Void)?
    /// any binding or state changed (settings UI refresh)
    public var onChange: (() -> Void)?

    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handlerInstalled = false

    public init() { load() }

    public func binding(_ a: Action) -> KeyCombo? { map[a] }
    public func state(_ a: Action) -> HotkeyResult { states[a] ?? (map[a] == nil ? .off : .ok) }
    public func label(_ a: Action) -> String { map[a]?.label ?? "" }

    /// Re-read record.hotkeys.
    public func load() {
        let user = Config.shared["record.hotkeys"] as? [String: Any] ?? [:]
        map = [:]
        invalid = [:]
        for a in Action.allCases {
            let v = user[a.rawValue]
            if v as? Bool == false { continue }
            if let s = v as? String {
                if KeyCombo.isOff(s) { continue }
                if let sc = KeyCombo.parse(s) { map[a] = sc; continue }
                invalid[a] = s
            }
            map[a] = a.defaultCombo
        }
    }

    /// Save one action (nil = off; only differences from the defaults are stored), re-register everything now, and
    /// return that action's new state.
    @discardableResult
    public func set(_ c: KeyCombo?, for a: Action) -> HotkeyResult {
        var user = Config.shared["record.hotkeys"] as? [String: Any] ?? [:]
        if c == a.defaultCombo { user.removeValue(forKey: a.rawValue) } else { user[a.rawValue] = c?.spec ?? "off" }
        Config.shared.set("record.hotkeys", user.isEmpty ? nil : user)
        load()
        apply()
        return state(a)
    }

    /// The other action these keys are set for now (nil: none, or only `a` itself) — the recorder field asks before
    /// taking them over, rather than leaving one of the two silently off.
    public func owner(of c: KeyCombo, except a: Action) -> Action? { HotkeyCenter.owner(of: c, in: map, except: a, disabled: disabled) }

    public static func owner(of c: KeyCombo, in map: [Action: KeyCombo], except a: Action, disabled: Set<Action> = []) -> Action? {
        Action.allCases.first { $0 != a && map[$0] == c && !disabled.contains($0) }
    }

    /// "Swap": `a` gets `c`, and the action that had it (`owner(of:except:)`) gets `a`'s keys until now — an exchange,
    /// as the word says; when `a` had none, that action is left without. One config write, one apply.
    @discardableResult
    public func swap(_ c: KeyCombo, to a: Action) -> Action? {
        let other = owner(of: c, except: a)
        let user = HotkeyCenter.swapped(Config.shared["record.hotkeys"] as? [String: Any] ?? [:], c, to: a, from: other,
                                        giving: map[a].flatMap { $0.reserved == nil ? $0 : nil })
        Config.shared.set("record.hotkeys", user.isEmpty ? nil : user)
        load()
        apply()
        return other
    }

    /// record.hotkeys after a swap: `a` has `c`, `other` has `previous` (`a`'s keys before; nil = off). Nothing is
    /// stored for an action back on its default.
    public static func swapped(_ user: [String: Any], _ c: KeyCombo, to a: Action, from other: Action?,
                               giving previous: KeyCombo? = nil) -> [String: Any] {
        var u = user
        func put(_ k: KeyCombo?, _ x: Action) { if k == x.defaultCombo { u.removeValue(forKey: x.rawValue) } else { u[x.rawValue] = k?.spec ?? "off" } }
        if let o = other { put(previous == c ? nil : previous, o) }
        put(c, a)
        return u
    }

    public func restoreDefaults() {
        Config.shared.set("record.hotkeys", nil)
        load()
        apply()
    }

    /// (Re-)register every action and work out each one's state.
    public func apply() {
        installHandler()
        for a in Action.allCases { unregisterRaw(a.carbonID) }
        states = [:]
        if suspended { return }
        let others = resident ? otherInstances() : []
        let system = systemShortcuts()
        var seen: [KeyCombo: Action] = [:]
        for a in Action.allCases {
            guard let s = map[a], !disabled.contains(a) else { states[a] = .off; continue }
            if a.residentOnly && !resident { states[a] = .notHere; continue }
            if s.reserved != nil { states[a] = .reserved; continue }      // ⌘C from a hand-edited config: never registered
            if let first = seen[s] { states[a] = .duplicate(first); continue }
            seen[s] = a
            // another Blurt app has it: leave it there (two owners = whichever macOS picks), say so. A recording started
            // from the chat (not resident) registers anyway, as before: while it runs, its keys are the ones that matter.
            // tests (BLURT_TEST_COMMANDS=1 BLURT_TEST_KEYS_FREE=1): every key as on a machine where it is free — shown
            // where the app shows its keys, never registered (the Blurt in use keeps its own)
            if HotkeyCenter.testKeysFree { states[a] = system.contains(s) ? .system : .ok; continue }
            if let o = others.first(where: { $0.keys.contains(s) }) { states[a] = .taken(o.pid); continue }
            let st = registerRaw(a.carbonID, code: s.code, mods: s.mods)
            if st != noErr { states[a] = .failed(st); continue }
            states[a] = system.contains(s) ? .system : .ok
        }
        if resident { publish() }
        onChange?()
    }

    static let testKeysFree: Bool = {
        let env = ProcessInfo.processInfo.environment
        return env["BLURT_TEST_COMMANDS"] == "1" && env["BLURT_TEST_KEYS_FREE"] == "1"
    }()

    public var conflicts: [Action] { Action.allCases.filter { states[$0]?.isConflict == true } }

    /// Which conflicts there are now ("snap=shift+cmd+3,…"): warned once per signature.
    public var conflictSignature: String { conflicts.map { "\($0.rawValue)=\(map[$0]?.spec ?? "")" }.joined(separator: ",") }

    /// The conflicts were said some other way (the first launch's welcome line names them): no toast of their own.
    public func markWarned() { if !conflicts.isEmpty { Config.shared.set("record.hotkeys_warned", conflictSignature) } }

    /// A one-time toast per distinct set of conflicts (remembered in config, so it doesn't nag every launch).
    public func warnOnce(_ toast: (String) -> Void) {
        let c = conflicts
        let sig = conflictSignature
        guard !c.isEmpty, Config.shared["record.hotkeys_warned"] as? String != sig else { return }
        Config.shared.set("record.hotkeys_warned", sig)
        // the first line is what the island shows: one key by name, several by how many (the list is in Settings —
        // eleven names never fit the island's row)
        let first = c[0], why = states[first]?.text ?? ""
        let head = c.count == 1 ? Loc.t("capture.keys.wont_work", table: "Capture", label(first))
            : Loc.t("capture.keys.wont_work_many", table: "Capture", "\(c.count)")
        toast(head + "\n"
              + (c.count == 1 ? Loc.t("capture.keys.why", table: "Capture", label(first), why) : Loc.t("capture.keys.taken_or_twice", table: "Capture"))
              + Loc.t("capture.keys.change_it", table: "Capture"))
    }

    // MARK: Carbon

    public func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        // pressed and released: voice input tells a tap from push-to-talk by the release (K7)
        var specs = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            if GetEventKind(event) == UInt32(kEventHotKeyReleased) { HotkeyCenter.shared.release(id.id) } else { HotkeyCenter.shared.fire(id.id) }
            return noErr
        }, 2, &specs, nil, nil)
    }

    func fire(_ id: UInt32) {
        if id >= 100, let a = Action.allCases.first(where: { $0.carbonID == id }) { onFire?(a) } else { onRaw?(id) }
    }

    func release(_ id: UInt32) {
        if id >= 100, let a = Action.allCases.first(where: { $0.carbonID == id }) { onRelease?(a) }
    }

    /// Test channel: the same path a real press / release of an action's keys takes.
    public func simulate(_ a: Action, released: Bool) { released ? onRelease?(a) : onFire?(a) }

    /// A fixed key of the app's own (id < 100). Already registered = noErr.
    @discardableResult
    public func registerRaw(_ id: UInt32, code: Int, mods: Int) -> OSStatus {
        installHandler()
        guard refs[id] == nil else { return noErr }
        var ref: EventHotKeyRef?
        let st = RegisterEventHotKey(UInt32(code), UInt32(mods), EventHotKeyID(signature: OSType(0x626C7274), id: id),
                                     GetApplicationEventTarget(), 0, &ref)
        if let r = ref { refs[id] = r }
        return st
    }

    public func unregisterRaw(_ id: UInt32) {
        if let r = refs.removeValue(forKey: id) { UnregisterEventHotKey(r) }
    }

    // MARK: other running Blurts

    public static let registryDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/dev.blurt.recorder/hotkeys")

    /// One running instance's entry in registryDir/<pid>.json — every Blurt build that publishes, whatever its bundle id
    /// (a release and a dev build hold the same keys and both hear Fn).
    public struct Registration: Equatable {
        public var pid: pid_t
        /// when it started (epoch s; 0 = an entry from a build that didn't say: it counts as the earliest)
        public var started: Double
        public var keys: Set<KeyCombo>
        /// the dictation key it listens to ("fn", "right_option"…); nil = it doesn't
        public var dictation: String?
        /// a test build: its key listener is simulated, so it only ever competes with other test builds
        public var test: Bool

        public init(pid: pid_t, started: Double, keys: Set<KeyCombo> = [], dictation: String? = nil, test: Bool = false) {
            self.pid = pid; self.started = started; self.keys = keys; self.dictation = dictation; self.test = test
        }
        public init?(json o: [String: Any]) {
            guard let pid = (o["pid"] as? NSNumber)?.int32Value else { return nil }
            self.init(pid: pid, started: (o["started"] as? NSNumber)?.doubleValue ?? 0,
                      keys: Set((o["hotkeys"] as? [String] ?? []).compactMap(KeyCombo.parse)),
                      dictation: o["dictation"] as? String, test: o["test"] as? Bool ?? false)
        }
    }

    /// When this instance's process started (its Registration's `started`): the kernel's start time, which is what
    /// another instance checks an entry against (`isLive`).
    public let startedAt = HotkeyCenter.processStart(getpid()) ?? Date().timeIntervalSince1970

    /// When process `pid` started (epoch s, from sysctl KERN_PROC_PID); nil = there is no such process.
    public static func processStart(_ pid: pid_t) -> Double? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        let tv = info.kp_proc.p_un.__p_starttime
        return Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000
    }

    /// How far an entry's `started` may be from its process's real start (an entry written by a build that took the
    /// time a moment after launch).
    public static let startSlack: Double = 30

    /// Is registry entry `r` a Blurt that is still running? Its file outlives a crash, a force quit or a power cut
    /// (~/Library/Caches survives reboots), and its pid then belongs to whatever process got it next — so the pid
    /// being alive isn't enough: the process must have started when the entry says. An entry without a start time
    /// (an older build) counts only while that pid is an app with a Blurt bundle id (`isBlurtApp`).
    public static func isLive(_ r: Registration, processStart: Double?, isBlurtApp: () -> Bool) -> Bool {
        guard let ps = processStart else { return false }
        if r.started > 0 { return abs(ps - r.started) <= startSlack }
        return isBlurtApp()
    }

    /// `isLive` for the process as it is now.
    public static func isLive(_ r: Registration) -> Bool {
        isLive(r, processStart: processStart(r.pid), isBlurtApp: {
            NSRunningApplication(processIdentifier: r.pid)?.bundleIdentifier?.hasPrefix("dev.blurt.recorder") == true
        })
    }

    /// The registry's entries (all of them, dead or alive, this one included).
    static func registryEntries() -> [(file: URL, entry: Registration)] {
        let fm = FileManager.default
        return ((try? fm.contentsOfDirectory(atPath: registryDir.path)) ?? []).filter { $0.hasSuffix(".json") }.compactMap { f in
            let u = registryDir.appendingPathComponent(f)
            guard let d = try? Data(contentsOf: u), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let r = Registration(json: o) else { return nil }
            return (u, r)
        }
    }
    /// A test build (Registration.test).
    public var testBuild = false
    /// The dictation key this instance hears now (Dictation sets it while its listener is in; nil while it doesn't
    /// listen or can't hear it), published so a second Blurt leaves the key to this one.
    public var dictationKey: String? { didSet { if resident, oldValue != dictationKey { publish() } } }

    /// Who listens to dictation key `key`: an instance publishes it only while it really hears the key (its tap or
    /// monitor is in — Dictation sets `dictationKey`), so a deaf one (a dev build macOS hasn't granted) never holds it.
    /// `me` doesn't hear it yet (`me.dictation` isn't `key`): any instance that does keeps it — the earliest started.
    /// Both hear it (they started together): the earliest started (then the lower pid) keeps it. nil = `me` listens.
    public static func dictationOwner(_ key: String, me: Registration, others: [Registration]) -> pid_t? {
        let rivals = others.filter { $0.pid != me.pid && $0.dictation == key && $0.test == me.test }
        guard let first = rivals.min(by: { ($0.started, $0.pid) < ($1.started, $1.pid) }) else { return nil }
        if me.dictation != key { return first.pid }
        return (first.started, first.pid) < (me.started, me.pid) ? first.pid : nil
    }

    /// The instance that hears dictation key `key` instead of this one (nil: this one should).
    public func dictationOwner(_ key: String) -> pid_t? {
        HotkeyCenter.dictationOwner(key, me: Registration(pid: getpid(), started: startedAt, dictation: dictationKey, test: testBuild),
                                    others: otherInstances())
    }

    func publish() {
        let fm = FileManager.default
        try? fm.createDirectory(at: HotkeyCenter.registryDir, withIntermediateDirectories: true)
        // instances that died without cleaning up (their pid may be some other process's by now: isLive)
        for (u, r) in HotkeyCenter.registryEntries() where r.pid != getpid() && !HotkeyCenter.isLive(r) { try? fm.removeItem(at: u) }
        let held = Action.allCases.compactMap { a -> String? in states[a] == .ok || states[a] == .system ? map[a]?.spec : nil }
        var obj: [String: Any] = ["pid": Int(getpid()), "home": BlurtPaths.home.path, "hotkeys": held, "started": startedAt,
                                  "bundle": Bundle.main.bundleIdentifier ?? "", "test": testBuild]
        if let k = dictationKey { obj["dictation"] = k }
        if let d = try? JSONSerialization.data(withJSONObject: obj) {
            try? d.write(to: HotkeyCenter.registryDir.appendingPathComponent("\(getpid()).json"), options: .atomic)
        }
    }

    public func unpublish() { try? FileManager.default.removeItem(at: HotkeyCenter.registryDir.appendingPathComponent("\(getpid()).json")) }

    /// An instance of our bundle id that has run this long without a registry entry is an older build (it holds the
    /// ⌥⇧ defaults); a younger one is still starting and about to publish its own.
    public static let legacyAfter: TimeInterval = 5

    /// The ⌥⇧ defaults an older build holds (it had no "cards" or "reformat" action yet).
    static var legacyKeys: Set<KeyCombo> {
        Set(Action.allCases.filter { $0 != .cards && $0 != .reformat }.compactMap { a in a.defaultKey.flatMap { KeyCombo(mods: optionKey | shiftKey, key: $0) } })
    }

    /// Every other running Blurt: the registry's live entries (any bundle id; `isLive` — the pid still runs the Blurt
    /// that wrote it), and running apps of our bundle id with none that have run for `legacyAfter` s (older builds).
    public func otherInstances() -> [Registration] {
        let me = getpid()
        var out = HotkeyCenter.registryEntries().map(\.entry).filter { $0.pid != me && HotkeyCenter.isLive($0) }
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "dev.blurt.recorder")
        for app in apps where app.processIdentifier != me && !app.isTerminated && !out.contains(where: { $0.pid == app.processIdentifier }) {
            guard let launched = app.launchDate, Date().timeIntervalSince(launched) > HotkeyCenter.legacyAfter else { continue }
            out.append(Registration(pid: app.processIdentifier, started: 0, keys: HotkeyCenter.legacyKeys))
        }
        return out
    }

    public func systemShortcuts() -> Set<KeyCombo> {
        var arr: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&arr) == noErr, let list = arr?.takeRetainedValue() as? [[String: Any]] else { return [] }
        var out = Set<KeyCombo>()
        for e in list where (e[kHISymbolicHotKeyEnabled as String] as? Bool) == true {
            guard let code = e[kHISymbolicHotKeyCode as String] as? Int, let mods = e[kHISymbolicHotKeyModifiers as String] as? Int,
                  let s = KeyCombo(mods: mods, code: code) else { continue }
            out.insert(s)
        }
        return out
    }
}
