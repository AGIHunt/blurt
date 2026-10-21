// Configurable global hotkeys: config record.hotkeys {"record": "opt+shift+R", "snap": "off", …} (same grammar as
// _common.py's parse_hotkey, which the Windows recorder reads). Registration goes through Carbon (RegisterEventHotKey:
// works without Accessibility permission, even when we're not the active app).
//
// Conflicts, shown in the Settings window (HotkeySettings.swift) and once as a toast:
//  • two of our actions on the same keys (the second isn't registered);
//  • RegisterEventHotKey refused it (only happens inside one process — macOS doesn't tell us about other apps);
//  • another running Blurt holds it (then we don't register it at all): every resident instance publishes its keys in
//    ~/Library/Caches/dev.blurt.recorder/hotkeys/<pid>.json; an instance that doesn't (older build) is assumed to hold
//    the ⌥⇧ defaults;
//  • a macOS system shortcut (CopySymbolicHotKeys: Spotlight, screenshots, Mission Control…).
// BLURT_HOTKEY_MODS (tests) replaces the defaults' modifiers, e.g. ctrl+opt+shift+cmd.

import AppKit
import Carbon.HIToolbox

enum HotAction: String, CaseIterable {
    case record, menu, snap, pause, marker, pen, stop

    var hk: HK {
        switch self {
        case .record: return .toggleRec
        case .menu: return .menu
        case .snap: return .snap
        case .pause: return .pause
        case .marker: return .marker
        case .pen: return .pen
        case .stop: return .stop
        }
    }
    var defaultKey: String {
        switch self {
        case .record: return "R"
        case .menu: return "B"
        case .snap: return "A"
        case .pause: return "P"
        case .marker: return "M"
        case .pen: return "D"
        case .stop: return "S"
        }
    }
    var title: String {
        switch self {
        case .record: return L("开始 / 结束录制", "Start / finish recording")
        case .menu: return L("打开菜单", "Open the menu")
        case .snap: return L("截图", "Snap")
        case .pause: return L("暂停 / 继续", "Pause / resume")
        case .marker: return L("标记（同时截图）", "Marker (also snaps)")
        case .pen: return L("画笔常开 / 关", "Pen on / off")
        case .stop: return L("完成录制", "Finish recording")
        }
    }
    /// Only the menu-bar app registers these (a recording started from the chat has no menu to open).
    var residentOnly: Bool { self == .record || self == .menu }
    var defaultShortcut: Shortcut? { Shortcut(mods: defaultHotkeyMods, key: defaultKey) }
}

let carbonModMask = cmdKey | shiftKey | optionKey | controlKey
/// The defaults' modifiers: ⌥⇧, or BLURT_HOTKEY_MODS (tests keep away from the user's running Blurt that way).
let defaultHotkeyMods = hotkeyMods(ProcessInfo.processInfo.environment["BLURT_HOTKEY_MODS"]).flatMap { $0 == 0 ? nil : $0 } ?? (optionKey | shiftKey)

/// name (as stored) → (virtual key code, glyph shown to the user)
let hotkeyKeyTable: [(name: String, code: Int, glyph: String)] = {
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

struct Shortcut: Hashable {
    let mods: Int       // Carbon modifiers (cmdKey | optionKey …)
    let key: String     // canonical name from hotkeyKeyTable
    let code: Int

    init?(mods: Int, key: String) {
        guard let e = hotkeyKeyTable.first(where: { $0.name == key }) else { return nil }
        self.mods = mods & carbonModMask
        self.key = e.name
        self.code = e.code
    }
    init?(mods: Int, code: Int) {
        guard let e = hotkeyKeyTable.first(where: { $0.code == code }) else { return nil }
        self.mods = mods & carbonModMask
        self.key = e.name
        self.code = code
    }

    /// Needs ⌃ / ⌥ / ⌘ — shift alone would steal typing — except F-keys.
    var isAcceptable: Bool { mods & (cmdKey | optionKey | controlKey) != 0 || (key.hasPrefix("F") && key.count > 1) }

    /// "ctrl+opt+shift+cmd+R", the stored form
    var spec: String {
        var p: [String] = []
        if mods & controlKey != 0 { p.append("ctrl") }
        if mods & optionKey != 0 { p.append("opt") }
        if mods & shiftKey != 0 { p.append("shift") }
        if mods & cmdKey != 0 { p.append("cmd") }
        return (p + [key]).joined(separator: "+")
    }
    /// "⌃⌥⇧⌘R", Apple's order
    var label: String {
        var s = ""
        if mods & controlKey != 0 { s += "⌃" }
        if mods & optionKey != 0 { s += "⌥" }
        if mods & shiftKey != 0 { s += "⇧" }
        if mods & cmdKey != 0 { s += "⌘" }
        return s + (hotkeyKeyTable.first { $0.name == key }?.glyph ?? key)
    }

    static func isOff(_ s: String) -> Bool { ["off", "none", "disabled", "-", ""].contains(s.trimmingCharacters(in: .whitespaces).lowercased()) }

    /// "opt+shift+R" / "⌥⇧R" / "Alt+Shift+r" / "ctrl+F5" (as _common.py's parse_hotkey)
    static func parse(_ raw: String) -> Shortcut? {
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
        guard let k = key, let sc = Shortcut(mods: mods, key: k), sc.isAcceptable else { return nil }
        return sc
    }

    var menuKeyEquivalent: (String, NSEvent.ModifierFlags) {
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

    static func carbonMods(_ f: NSEvent.ModifierFlags) -> Int {
        var m = 0
        if f.contains(.control) { m |= controlKey }
        if f.contains(.option) { m |= optionKey }
        if f.contains(.shift) { m |= shiftKey }
        if f.contains(.command) { m |= cmdKey }
        return m
    }
}

enum HotState: Equatable {
    case ok, off, notHere
    case duplicate(HotAction)       // same keys as an earlier action: not registered
    case failed(OSStatus)           // RegisterEventHotKey said no
    case taken(pid_t)               // another running Blurt holds it
    case system                     // a macOS system shortcut

    var isConflict: Bool {
        switch self {
        case .duplicate, .failed, .taken, .system: return true
        default: return false
        }
    }
    var text: String {
        switch self {
        case .ok, .notHere: return ""
        case .off: return L("已关闭", "Off")
        case .duplicate(let a): return L("和「\(a.title)」重复，没生效", "Same as “\(a.title)” — not active")
        case .failed(let st): return L("注册失败（\(st)），可能被占用", "Couldn't register it (\(st)) — probably taken")
        case .taken(let pid): return L("被另一个口喷鸡（pid \(pid)）占用", "Taken by another Blurt (pid \(pid))")
        case .system: return L("和 macOS 系统快捷键冲突", "Clashes with a macOS system shortcut")
        }
    }
}

final class Hotkeys {
    static let shared = Hotkeys()
    private(set) var map: [HotAction: Shortcut] = [:]      // absent = off
    private(set) var states: [HotAction: HotState] = [:]
    private(set) var invalid: [HotAction: String] = [:]     // unparseable config entries (fall back to the default)
    var resident = false
    var suspended = false { didSet { apply() } }            // while the settings window records a shortcut
    var onChange: (() -> Void)?

    init() { load() }

    func shortcut(_ a: HotAction) -> Shortcut? { map[a] }
    func label(_ a: HotAction) -> String { map[a]?.label ?? "" }

    func load() {
        let user = recordConfig()["hotkeys"] as? [String: Any] ?? [:]
        map = [:]
        invalid = [:]
        for a in HotAction.allCases {
            let v = user[a.rawValue]
            if v as? Bool == false { continue }
            if let s = v as? String {
                if Shortcut.isOff(s) { continue }
                if let sc = Shortcut.parse(s) { map[a] = sc; continue }
                invalid[a] = s
            }
            map[a] = a.defaultShortcut
        }
    }

    /// Save one action (nil = off). Only differences from the defaults are stored.
    func set(_ a: HotAction, _ s: Shortcut?) {
        var user = recordConfig()["hotkeys"] as? [String: Any] ?? [:]
        if s == a.defaultShortcut { user.removeValue(forKey: a.rawValue) } else { user[a.rawValue] = s?.spec ?? "off" }
        setRecordConfig("hotkeys", user.isEmpty ? nil : user)
        load()
        apply()
    }

    func restoreDefaults() {
        setRecordConfig("hotkeys", nil)
        load()
        apply()
    }

    /// (Re-)register everything and work out each action's state.
    func apply() {
        for a in HotAction.allCases { unregisterHotkey(a.hk) }
        states = [:]
        if suspended { return }
        let others = otherInstances()
        let system = systemShortcuts()
        var seen: [Shortcut: HotAction] = [:]
        for a in HotAction.allCases {
            guard let s = map[a] else { states[a] = .off; continue }
            if a.residentOnly && !resident { states[a] = .notHere; continue }
            if let first = seen[s] { states[a] = .duplicate(first); continue }
            seen[s] = a
            // another Blurt app has it: leave it there (two owners = whichever macOS picks), say so. A recording started
            // from the chat (not resident) registers anyway, as before: while it runs, its keys are the ones that matter.
            if resident, let o = others.first(where: { $0.keys.contains(s) }) { states[a] = .taken(o.pid); continue }
            let st = registerHotkey(a.hk, key: s.code, mods: s.mods)
            if st != noErr { states[a] = .failed(st); continue }
            states[a] = system.contains(s) ? .system : .ok
        }
        if resident { publish() }
        onChange?()
    }

    var conflicts: [HotAction] { HotAction.allCases.filter { states[$0]?.isConflict == true } }

    /// A one-time toast per distinct set of conflicts (remembered in config, so it doesn't nag every launch).
    func warnOnce(_ toast: (String) -> Void) {
        let c = conflicts
        let sig = c.map { "\($0.rawValue)=\(map[$0]?.spec ?? "")" }.joined(separator: ",")
        guard !c.isEmpty, recordConfig()["hotkeys_warned"] as? String != sig else { return }
        setRecordConfig("hotkeys_warned", sig)
        let keys = c.map { label($0) }.joined(separator: L("、", ", "))
        let first = c[0], why = states[first]?.text ?? ""
        toast(L("快捷键 \(keys) 用不了", "Shortcut \(keys) won't work") + "\n"
              + (c.count == 1 ? "\(label(first))：\(why)" : L("被别的 App 占用或互相重复", "taken by another app or used twice"))
              + L(" · 菜单 → 快捷键… 可以换", " · menu → Shortcuts… to change it"))
    }

    // MARK: other running Blurts

    static let registryDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/dev.blurt.recorder/hotkeys")

    func publish() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Hotkeys.registryDir, withIntermediateDirectories: true)
        let held = HotAction.allCases.compactMap { a -> String? in states[a] == .ok || states[a] == .system ? map[a]?.spec : nil }
        let obj: [String: Any] = ["pid": Int(getpid()), "home": blurtHome.path, "hotkeys": held]
        if let d = try? JSONSerialization.data(withJSONObject: obj) {
            try? d.write(to: Hotkeys.registryDir.appendingPathComponent("\(getpid()).json"))
        }
    }

    func unpublish() { try? FileManager.default.removeItem(at: Hotkeys.registryDir.appendingPathComponent("\(getpid()).json")) }

    func otherInstances() -> [(pid: pid_t, keys: Set<Shortcut>)] {
        let me = getpid()
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "dev.blurt.recorder")
            .filter { $0.processIdentifier != me && !$0.isTerminated }
        return apps.map { app in
            let f = Hotkeys.registryDir.appendingPathComponent("\(app.processIdentifier).json")
            if let d = try? Data(contentsOf: f), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               let list = o["hotkeys"] as? [String] {
                return (app.processIdentifier, Set(list.compactMap(Shortcut.parse)))
            }
            // an older build: it holds the ⌥⇧ defaults
            let legacy = HotAction.allCases.compactMap { Shortcut(mods: optionKey | shiftKey, key: $0.defaultKey) }
            return (app.processIdentifier, Set(legacy))
        }
    }

    func systemShortcuts() -> Set<Shortcut> {
        var arr: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&arr) == noErr, let list = arr?.takeRetainedValue() as? [[String: Any]] else { return [] }
        var out = Set<Shortcut>()
        for e in list where (e[kHISymbolicHotKeyEnabled as String] as? Bool) == true {
            guard let code = e[kHISymbolicHotKeyCode as String] as? Int, let mods = e[kHISymbolicHotKeyModifiers as String] as? Int,
                  let s = Shortcut(mods: mods, code: code) else { continue }
            out.insert(s)
        }
        return out
    }
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
