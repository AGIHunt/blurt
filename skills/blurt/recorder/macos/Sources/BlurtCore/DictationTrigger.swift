// Dictation's trigger (docs/design/dictation.md): a modifier key alone — Fn (default), right ⌥ or either ⌥ — which
// Carbon hotkeys can't register, read from an event tap (flagsChanged, keyDown, mouse down). This is the pure part:
// events with timestamps in, start / stop / cancel out. No AppKit, no timers — the caller asks for a tick at
// `deadline` (hold's 250 ms, auto's 300 ms) — so every sequence is unit-testable (Tests/BlurtCoreTests/DictationTriggerTests).
//
//   auto mode (default) a short tap starts hands-free and the next clean press stops it; held alone past `autoHold`
//                       (300 ms) it is push-to-talk instead: it starts then, and letting go stops. Like Typeless.
//   tap mode            a clean tap starts, the next clean tap stops. Clean = the key went down and up within
//                       `tapMax` (400 ms) with no other key, modifier or click in between, and no other modifier
//                       held when it went down — so the key as a modifier (⌥-letter, ⌥⇧V, Fn-←) never triggers.
//   hold mode           held alone for `holdMin` (250 ms) starts; letting go stops; another key or a click joining
//                       in cancels (the user is typing a shortcut, not talking).
//   all                 Esc cancels a dictation in progress; `arm` on a clean key-down (warm the models, open the mic
//                       early); `armedDown` says whether that press can still start (else the app closes the mic).
//   double tap          (`doubleTap`, on by default) two clean taps, the second going down within `doubleTapWindow`
//                       (300 ms) of the first one's release, say `.send`: the app presses Return. The first tap still
//                       does what it always did, at once (no waiting to see whether a second one comes):
//                         • it started a dictation (idle, auto / tap mode) → the second one cancels it (`.cancel`,
//                           nothing kept) and sends: Return in the app in front;
//                         • it stopped one (a tap, or letting go of push-to-talk) → the second one sends: the app
//                           presses Return once the paste has landed — "dictate, then send";
//                         • it did nothing (hold mode, a tap too short to start) → the second one sends.
//                       The second press opens no mic when it can only send; held instead, it is push-to-talk as usual.
import Foundation

public struct DictationTrigger {
    public enum Key: String, CaseIterable {
        /// Fn / 🌐 (the default), right ⌥, or either ⌥ — left or right, whichever is tapped alone
        case fn, rightOption = "right_option", eitherOption = "either_option"
        /// kVK_RightOption 61, kVK_Option (left) 58, kVK_Function 63
        public var keyCodes: Set<Int> {
            switch self {
            case .rightOption: return [61]
            case .fn: return [63]
            case .eitherOption: return [58, 61]
            }
        }
        /// The flag bit that says the key `code` is down: NX_DEVICERALTKEYMASK (right ⌥), NX_DEVICELALTKEYMASK
        /// (left ⌥), NX_SECONDARYFNMASK (Fn).
        static func downMask(_ code: Int) -> UInt64 { code == 61 ? 0x40 : code == 58 ? 0x20 : 0x80_0000 }
        /// Other modifiers that make a press of `code` "not alone": ⌘ ⌃ ⇧, the other ⌥ and Fn (for an ⌥) / any ⌥
        /// (for Fn).
        static func otherMods(_ code: Int) -> UInt64 {
            let common: UInt64 = 0x10_0000 | 0x4_0000 | 0x2_0000      // ⌘ ⌃ ⇧ (device-independent bits)
            switch code {
            case 61: return common | 0x20 | 0x80_0000
            case 58: return common | 0x40 | 0x80_0000
            default: return common | 0x8_0000
            }
        }
    }
    /// auto (the default): a tap is hands-free, a hold is push-to-talk; tap: tap / tap; hold: push-to-talk only
    public enum Mode: String, CaseIterable { case auto, tap, hold }
    public enum Output: Equatable {
        case arm, start, stop, cancel
        /// a double tap: press Return in the app in front (after the paste, when a dictation just stopped)
        case send
    }
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
    /// auto mode: shorter than this is a tap (hands-free); held alone this long is push-to-talk
    public var autoHold = 0.3
    /// Two quick taps press Return (record.dictation.double_tap_send, on by default).
    public var doubleTap = true
    /// the second tap must go down within this long of the first one's release
    public var doubleTapWindow = 0.3

    private enum State: Equatable {
        case idle
        case down(at: Double, clean: Bool, code: Int)
        case holding
        case waitRelease          // push-to-talk cancelled while still held: ignore until the key comes up
    }
    private var state: State = .idle
    /// the key code that went down last (either-⌥: which side)
    private var holdingCode = 0
    /// What the last clean tap did, and when it came up: a second tap soon after it is a double tap.
    private enum TapDid { case started, stopped, nothing }
    private var lastTap: (did: TapDid, up: Double)?
    /// The press now down is the second tap of a double tap (if it comes up quickly): what the first one did.
    private var second: TapDid?
    /// Dictating, as far as the trigger knows (the app calls `reset` when it ends one itself).
    public private(set) var active = false
    /// The dictation in progress was started by holding the key (hold mode, or auto held past `autoHold`): it ends
    /// when the key comes up, so it has no "nothing said" timeout.
    public private(set) var pushToTalk = false

    public init(key: Key = .fn, mode: Mode = .auto) {
        self.key = key
        self.mode = mode
    }

    /// How long the key must be held alone to start push-to-talk (nil: tap mode has no hold).
    private var holdThreshold: Double? {
        switch mode {
        case .hold: return holdMin
        case .auto: return autoHold
        case .tap: return nil
        }
    }

    /// When hold / auto mode wants a `.tick` (the key has been down alone this long), nil otherwise.
    public var deadline: Double? {
        if let h = holdThreshold, case let .down(at, clean, _) = state, clean, !active { return at + h }
        return nil
    }

    /// The key is down alone and nothing has started yet: what `.arm` said may still become a `.start`. The app opens
    /// the microphone on `.arm` (so the first words aren't lost while the trigger waits for the key to come up) and
    /// closes it again as soon as this turns false without a start — the press became a shortcut (Fn-←, ⌥A), a click
    /// joined in, or it was let go too early or too late.
    public var armedDown: Bool {
        if case let .down(_, clean, _) = state { return clean && !active }
        return false
    }

    /// The dictation ended or was started some other way (a menu, the island, a time limit).
    public mutating func reset(active a: Bool) {
        active = a
        pushToTalk = false
        lastTap = nil
        second = nil
        if !a { settle() }
    }

    /// Not dictating any more: a key still held is waited out (its release must not start or stop anything).
    private mutating func settle() {
        if state == .holding { state = .waitRelease } else if case .down = state { state = .idle }
    }

    public mutating func handle(_ e: Event) -> [Output] {
        switch e {
        case let .flags(code, flags, t):
            if key.keyCodes.contains(code) {
                // either-⌥: the other side going down or up while one is held is another key, not this one
                if case let .down(_, _, held) = state, held != code { return otherInput(t) }
                if state == .holding, holdingCode != code { return otherInput(t) }
                return flags & Key.downMask(code) != 0 ? keyDown(code, flags, t) : keyUp(t)
            }
            return otherInput(t)
        case let .keyDown(code, t):
            if code == DictationTrigger.escape && active {
                active = false
                pushToTalk = false
                lastTap = nil
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

    private mutating func keyDown(_ code: Int, _ flags: UInt64, _ t: Double) -> [Output] {
        if state == .holding || state == .waitRelease { return [] }        // a repeat of what we know
        let alone = flags & Key.otherMods(code) == 0
        state = .down(at: t, clean: alone, code: code)
        holdingCode = code
        second = nil
        if doubleTap, alone, let l = lastTap, t - l.up <= doubleTapWindow { second = l.did }
        lastTap = nil
        // the second tap after a stop (or after a tap that did nothing) can only send: no mic for it
        if second == .stopped || second == .nothing { return [] }
        return alone && !active ? [.arm] : []
    }

    /// How long a press may last and still be a tap.
    private var tapLimit: Double {
        switch mode {
        case .tap: return tapMax
        case .auto: return autoHold
        case .hold: return holdMin
        }
    }

    private mutating func keyUp(_ t: Double) -> [Output] {
        let was = state
        state = .idle
        let first = second
        second = nil
        // the second tap of a double tap: send (cancelling the dictation the first one started)
        if let f = first, case let .down(at, clean, _) = was, clean, t - at <= tapLimit {
            if f == .started && active {
                active = false
                pushToTalk = false
                return [.cancel, .send]
            }
            return [.send]
        }
        switch (mode, was) {
        case let (.tap, .down(at, clean, _)):
            guard clean, t - at <= tapMax else { return [] }
            active.toggle()
            lastTap = (active ? .started : .stopped, t)
            return [active ? .start : .stop]
        case let (.auto, .down(at, clean, _)):
            guard clean else { return [] }
            if active {                     // hands-free: the next clean press stops it, however long
                active = false
                pushToTalk = false
                lastTap = (.stopped, t)
                return [.stop]
            }
            guard t - at < autoHold else { return [] }      // held past the threshold with no tick: never started
            active = true
            pushToTalk = false
            lastTap = (.started, t)
            return [.start]
        case (.hold, .holding), (.auto, .holding):
            active = false
            pushToTalk = false
            lastTap = (.stopped, t)
            return [.stop]
        case let (.hold, .down(at, clean, _)):
            // let go before 250 ms: nothing said — but it can be the first tap of a double tap
            if clean, t - at < holdMin { lastTap = (.nothing, t) }
            return []
        default:            // a dirty tap, a release we wait out
            return []
        }
    }

    /// Another key, modifier or click: a tap in progress is no longer clean; push-to-talk is cancelled. Nor is the
    /// next tap the second of a double tap.
    private mutating func otherInput(_ t: Double) -> [Output] {
        lastTap = nil
        switch state {
        case let .down(at, _, code):
            if holdThreshold != nil, let out = holdIfDue(at: at, t) { return out + otherInput(t) }   // held long enough: started, and now joined
            state = .down(at: at, clean: false, code: code)
            return []
        case .holding:
            state = .waitRelease
            active = false
            pushToTalk = false
            return [.cancel]
        default:
            return []
        }
    }

    private mutating func tick(_ t: Double) -> [Output] {
        guard holdThreshold != nil, case let .down(at, clean, _) = state, clean, !active else { return [] }
        return holdIfDue(at: at, t) ?? []
    }

    /// Hold / auto mode: the key has been down alone for the threshold by `t` → push-to-talk starts (the other
    /// input, if any, came later).
    private mutating func holdIfDue(at: Double, _ t: Double) -> [Output]? {
        guard let h = holdThreshold, case let .down(_, clean, _) = state, clean, !active, t - at >= h else { return nil }
        state = .holding
        active = true
        pushToTalk = true
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
