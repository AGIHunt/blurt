// Configurable global hotkeys (C7): config record.hotkeys {"record": "opt+shift+R", "snap": "off", …} — the grammar
// of _common.py's parse_hotkey, which the Windows recorder reads. Registration goes through Carbon
// (RegisterEventHotKey: works without Accessibility permission, even when we're not the active app).
//
// Conflicts (shown by the Shortcuts window / settings, and once as a toast):
//  • two of our actions on the same keys (the second isn't registered)                       → .duplicate(first)
//  • RegisterEventHotKey refused it (only happens inside one process)                         → .failed(OSStatus)
//  • another running Blurt holds it (then we don't register it at all): every resident instance publishes its keys
//    in ~/Library/Caches/dev.blurt.recorder/hotkeys/<pid>.json; an instance that doesn't (older build) is assumed to
//    hold the ⌥⇧ defaults                                                                     → .taken(pid)
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
    public var isAcceptable: Bool { mods & (cmdKey | optionKey | controlKey) != 0 || (key.hasPrefix("F") && key.count > 1) }

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

public enum HotkeyResult: Equatable {
    case ok
    case off                                  // no keys for this action
    case notHere                              // only the menu-bar app registers it (a chat-started recording doesn't)
    case duplicate(HotkeyCenter.Action)       // same keys as an earlier action: not registered
    case failed(Int32)                        // RegisterEventHotKey refused it (OSStatus)
    case taken(pid_t)                         // another running Blurt holds it: not registered
    case system                               // a macOS system shortcut (registered, but macOS may win)

    public var isConflict: Bool {
        switch self {
        case .duplicate, .failed, .taken, .system: return true
        default: return false
        }
    }
    public var text: String {
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

public final class HotkeyCenter {
    public static let shared = HotkeyCenter()

    /// Raw values are the config keys (record.hotkeys) — shared with _common.py / the Windows recorder.
    public enum Action: String, CaseIterable {
        case toggleRecord = "record", openMenu = "menu", snap, pause, marker, pen, finish = "stop", openMain = "main", voice, project

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
            }
        }
        public var title: String {
            switch self {
            case .toggleRecord: return L("开始 / 结束录制", "Start / finish recording")
            case .openMenu: return L("打开菜单", "Open the menu")
            case .snap: return L("截图", "Snap")
            case .pause: return L("暂停 / 继续", "Pause / resume")
            case .marker: return L("标记（同时截图）", "Marker (also snaps)")
            case .pen: return L("画笔常开 / 关", "Pen on / off")
            case .finish: return L("完成录制", "Finish recording")
            case .openMain: return L("打开口喷鸡窗口", "Open the Blurt window")
            case .voice: return L("语音输入", "Voice input")
            case .project: return L("切换当前项目", "Switch project")
            }
        }
        /// Only the menu-bar app registers these (a recording started from the chat has no menu or window to open).
        public var residentOnly: Bool { self == .toggleRecord || self == .openMenu || self == .openMain || self == .voice || self == .project }
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
            if let first = seen[s] { states[a] = .duplicate(first); continue }
            seen[s] = a
            // another Blurt app has it: leave it there (two owners = whichever macOS picks), say so. A recording started
            // from the chat (not resident) registers anyway, as before: while it runs, its keys are the ones that matter.
            if let o = others.first(where: { $0.keys.contains(s) }) { states[a] = .taken(o.pid); continue }
            let st = registerRaw(a.carbonID, code: s.code, mods: s.mods)
            if st != noErr { states[a] = .failed(st); continue }
            states[a] = system.contains(s) ? .system : .ok
        }
        if resident { publish() }
        onChange?()
    }

    public var conflicts: [Action] { Action.allCases.filter { states[$0]?.isConflict == true } }

    /// A one-time toast per distinct set of conflicts (remembered in config, so it doesn't nag every launch).
    public func warnOnce(_ toast: (String) -> Void) {
        let c = conflicts
        let sig = c.map { "\($0.rawValue)=\(map[$0]?.spec ?? "")" }.joined(separator: ",")
        guard !c.isEmpty, Config.shared["record.hotkeys_warned"] as? String != sig else { return }
        Config.shared.set("record.hotkeys_warned", sig)
        let keys = c.map { label($0) }.joined(separator: L("、", ", "))
        let first = c[0], why = states[first]?.text ?? ""
        toast(L("快捷键 \(keys) 用不了", "Shortcut \(keys) won't work") + "\n"
              + (c.count == 1 ? "\(label(first))：\(why)" : L("被别的 App 占用或互相重复", "taken by another app or used twice"))
              + L(" · 菜单 → 快捷键… 可以换", " · menu → Shortcuts… to change it"))
    }

    // MARK: Carbon

    public func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            HotkeyCenter.shared.fire(id.id)
            return noErr
        }, 1, &spec, nil, nil)
    }

    func fire(_ id: UInt32) {
        if id >= 100, let a = Action.allCases.first(where: { $0.carbonID == id }) { onFire?(a) } else { onRaw?(id) }
    }

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

    func publish() {
        let fm = FileManager.default
        try? fm.createDirectory(at: HotkeyCenter.registryDir, withIntermediateDirectories: true)
        for f in (try? fm.contentsOfDirectory(atPath: HotkeyCenter.registryDir.path)) ?? [] {   // instances that died without cleaning up
            if let pid = Int32(f.replacingOccurrences(of: ".json", with: "")), kill(pid, 0) != 0, errno == ESRCH {
                try? fm.removeItem(at: HotkeyCenter.registryDir.appendingPathComponent(f))
            }
        }
        let held = Action.allCases.compactMap { a -> String? in states[a] == .ok || states[a] == .system ? map[a]?.spec : nil }
        let obj: [String: Any] = ["pid": Int(getpid()), "home": BlurtPaths.home.path, "hotkeys": held]
        if let d = try? JSONSerialization.data(withJSONObject: obj) {
            try? d.write(to: HotkeyCenter.registryDir.appendingPathComponent("\(getpid()).json"))
        }
    }

    public func unpublish() { try? FileManager.default.removeItem(at: HotkeyCenter.registryDir.appendingPathComponent("\(getpid()).json")) }

    public func otherInstances() -> [(pid: pid_t, keys: Set<KeyCombo>)] {
        let me = getpid()
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "dev.blurt.recorder")
            .filter { $0.processIdentifier != me && !$0.isTerminated }
        return apps.map { app in
            let f = HotkeyCenter.registryDir.appendingPathComponent("\(app.processIdentifier).json")
            if let d = try? Data(contentsOf: f), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               let list = o["hotkeys"] as? [String] {
                return (app.processIdentifier, Set(list.compactMap(KeyCombo.parse)))
            }
            // an older build: it holds the ⌥⇧ defaults
            let legacy = Action.allCases.compactMap { a in a.defaultKey.flatMap { KeyCombo(mods: optionKey | shiftKey, key: $0) } }
            return (app.processIdentifier, Set(legacy))
        }
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
