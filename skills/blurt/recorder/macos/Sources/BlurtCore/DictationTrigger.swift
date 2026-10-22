// Dictation's trigger (docs/design/dictation.md): a modifier key alone — right ⌥ (default) or Fn — which Carbon
// hotkeys can't register, read from a listen-only CGEventTap (flagsChanged, keyDown, mouse down). This is the pure
// part: events with timestamps in, start / stop / cancel out. No AppKit, no timers — the caller asks for a tick at
// `deadline` (hold mode's 250 ms) — so every sequence is unit-testable (Tests/BlurtCoreTests/DictationTriggerTests).
//
//   tap mode (default)  a clean tap starts, the next clean tap stops. Clean = the key went down and up within
//                       `tapMax` (400 ms) with no other key, modifier or click in between, and no other modifier
//                       held when it went down — so right ⌥ as a modifier (⌥-letter, ⌥⇧V) never triggers.
//   hold mode           held alone for `holdMin` (250 ms) starts; letting go stops; another key or a click joining
//                       in cancels (the user is typing a shortcut, not talking).
//   both                Esc cancels a dictation in progress; `arm` on a clean key-down (warm the models early).
import Foundation

public struct DictationTrigger {
    public enum Key: String, CaseIterable {
        case rightOption = "right_option", fn
        /// kVK_RightOption / kVK_Function
        public var keyCode: Int { self == .rightOption ? 61 : 63 }
        /// The flag bit that says this key is down: NX_DEVICERALTKEYMASK (right ⌥ only), NX_SECONDARYFNMASK.
        public var downMask: UInt64 { self == .rightOption ? 0x40 : 0x80_0000 }
        /// Other modifiers that make a press "not alone": ⌘ ⌃ ⇧, the other ⌥, Fn (for right ⌥) / ⌥ (for Fn).
        var otherMods: UInt64 {
            let common: UInt64 = 0x10_0000 | 0x4_0000 | 0x2_0000      // ⌘ ⌃ ⇧ (device-independent bits)
            return self == .rightOption ? common | 0x20 | 0x80_0000 : common | 0x8_0000
        }
    }
    public enum Mode: String, CaseIterable { case tap, hold }
    public enum Output: Equatable { case arm, start, stop, cancel }
    public enum Event: Equatable {
        /// a modifier changed (CGEvent flagsChanged): its keyCode and the flags after the change
        case flags(keyCode: Int, flags: UInt64, time: Double)
        case keyDown(keyCode: Int, time: Double)
        case mouseDown(time: Double)
        /// the caller's timer, at or after `deadline`
        case tick(time: Double)
    }

    public static let escape = 53

    public var key: Key
    public var mode: Mode
    public var tapMax = 0.4
    public var holdMin = 0.25

    private enum State: Equatable {
        case idle
        case down(at: Double, clean: Bool)
        case holding
        case waitRelease          // hold mode, cancelled while still held: ignore until the key comes up
    }
    private var state: State = .idle
    /// Dictating, as far as the trigger knows (the app calls `reset` when it ends one itself).
    public private(set) var active = false

    public init(key: Key = .rightOption, mode: Mode = .tap) {
        self.key = key
        self.mode = mode
    }

    /// When hold mode wants a `.tick` (the key has been down alone this long), nil otherwise.
    public var deadline: Double? {
        if mode == .hold, case let .down(at, clean) = state, clean, !active { return at + holdMin }
        return nil
    }

    /// The dictation ended or was started some other way (a menu, the island, a time limit).
    public mutating func reset(active a: Bool) {
        active = a
        if !a { settle() }
    }

    /// Not dictating any more: a key still held is waited out (its release must not start or stop anything).
    private mutating func settle() {
        if state == .holding { state = .waitRelease } else if case .down = state { state = .idle }
    }

    public mutating func handle(_ e: Event) -> [Output] {
        switch e {
        case let .flags(code, flags, t):
            if code == key.keyCode {
                return flags & key.downMask != 0 ? keyDown(flags, t) : keyUp(t)
            }
            return otherInput(t)
        case let .keyDown(code, t):
            if code == DictationTrigger.escape && active {
                active = false
                settle()
                return [.cancel]
            }
            return otherInput(t)
        case let .mouseDown(t):
            return otherInput(t)
        case let .tick(t):
            return tick(t)
        }
    }

    private mutating func keyDown(_ flags: UInt64, _ t: Double) -> [Output] {
        if state == .holding || state == .waitRelease { return [] }        // a repeat of what we know
        let alone = flags & key.otherMods == 0
        state = .down(at: t, clean: alone)
        return alone && !active ? [.arm] : []
    }

    private mutating func keyUp(_ t: Double) -> [Output] {
        let was = state
        state = .idle
        switch (mode, was) {
        case let (.tap, .down(at, clean)):
            guard clean, t - at <= tapMax else { return [] }
            active.toggle()
            return [active ? .start : .stop]
        case (.hold, .holding):
            active = false
            return [.stop]
        default:            // hold mode let go before 250 ms (nothing said), a dirty tap, a release we wait out
            return []
        }
    }

    /// Another key, modifier or click: a tap in progress is no longer clean; push-to-talk is cancelled.
    private mutating func otherInput(_ t: Double) -> [Output] {
        switch state {
        case let .down(at, _):
            if mode == .hold, let out = holdIfDue(at: at, t) { return out + otherInput(t) }   // held long enough: started, and now joined
            state = .down(at: at, clean: false)
            return []
        case .holding:
            state = .waitRelease
            active = false
            return [.cancel]
        default:
            return []
        }
    }

    private mutating func tick(_ t: Double) -> [Output] {
        guard mode == .hold, case let .down(at, clean) = state, clean, !active else { return [] }
        return holdIfDue(at: at, t) ?? []
    }

    /// Hold mode: the key has been down alone for holdMin by `t` → start (the other input, if any, came later).
    private mutating func holdIfDue(at: Double, _ t: Double) -> [Output]? {
        guard case let .down(_, clean) = state, clean, !active, t - at >= holdMin else { return nil }
        state = .holding
        active = true
        return [.start]
    }
}

extension DictationTrigger {
    /// A compact script of events for tests and the app's test hook (`dictation keys …`), one token per event,
    /// times in ms: "ropt-down@0 ropt-up@120", "fn-down@0 tick@300 fn-up@900", "ropt-down@0 key:9@50 ropt-up@90",
    /// "click@40", "esc@500", "shift-down@0 shift-up@10". Modifier tokens: ropt, lopt, fn, shift, cmd, ctrl.
    public static func parse(_ script: String, holding: Set<String> = []) -> [Event] {
        var held = holding
        let bits: [String: (code: Int, mask: UInt64)] = [
            "ropt": (61, 0x80000 | 0x40), "lopt": (58, 0x80000 | 0x20), "fn": (63, 0x80_0000),
            "shift": (56, 0x2_0000), "cmd": (55, 0x10_0000), "ctrl": (59, 0x4_0000),
        ]
        func flags() -> UInt64 { held.reduce(0) { $0 | (bits[$1]?.mask ?? 0) } }
        var out: [Event] = []
        for tok in script.split(separator: " ") {
            let parts = tok.split(separator: "@")
            guard parts.count == 2, let ms = Double(parts[1]) else { continue }
            let t = ms / 1000, name = String(parts[0])
            if name == "tick" { out.append(.tick(time: t)) } else if name == "click" { out.append(.mouseDown(time: t)) }
            else if name == "esc" { out.append(.keyDown(keyCode: escape, time: t)) }
            else if name.hasPrefix("key:"), let c = Int(name.dropFirst(4)) { out.append(.keyDown(keyCode: c, time: t)) }
            else {
                let mp = name.split(separator: "-").map(String.init)
                guard mp.count == 2, let b = bits[mp[0]] else { continue }
                if mp[1] == "down" { held.insert(mp[0]) } else { held.remove(mp[0]) }
                out.append(.flags(keyCode: b.code, flags: flags(), time: t))
            }
        }
        return out
    }

    /// Runs a script; the outputs in order (ticks are delivered only where the script has them).
    public mutating func run(_ script: String) -> [Output] {
        DictationTrigger.parse(script).flatMap { handle($0) }
    }
}
