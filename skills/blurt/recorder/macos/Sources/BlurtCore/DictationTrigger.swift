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
//                       of the first one's release, say `.send`: the app presses Return. The window is macOS's own
//                       double-click interval clamped to 0.3–0.5 s (`window(doubleClickInterval:)`; 0.5 s here by
//                       default). The first tap still does what it always did, at once (no waiting for a second one):
//                         • it started a dictation (idle, auto / tap mode) → the second one cancels it (`.cancel`,
//                           nothing kept) and sends: Return in the app in front;
//                         • it stopped one (hands-free) → the second one sends: the app presses Return once the
//                           paste has landed — "dictate, then send";
//                         • it did nothing (hold mode, a tap right after a take ended by itself, the first tap after
//                           push-to-talk) → the second one sends.
//                       Push-to-talk: letting go stops it, and a double tap right after sends (release, tap, tap: a
//                       tap within the window of the release does nothing by itself) — what the help text says.
//                       A near miss — the stop tap went down within `nearMissWindow` (0.8 s) of the start tap's
//                       release — sets `quickStop`: the app sends instead of saying "nothing heard" when nothing was.
//                       The second press opens no mic when it can only send; held instead, it is push-to-talk as usual.
//   pending             (`pending`: the app sets it while the last take is still being transcribed, polished or
//                       pasted) a press is a press as when idle: once the double-tap window of the stop tap has passed,
//                       a tap starts the next take at once (the app pastes in order); within it, it is the double tap's
//                       second one and sends after the paste. Esc then cancels the take on its way (`.cancel`).
//   bounces             a tap within the double-tap window of a send does nothing (a third tap of a quick double tap
//                       never starts a take); for 2 s after a take ended by itself (the 5-minute limit,
//                       `endedByItself`) the next tap does nothing either: it was meant as the stop.
//   misses              (`miss`) a clean press the mode doesn't use — hold mode let go before `holdMin`, tap mode held
//                       past `tapMax` — is reported, so the app can say how to start in that mode.
//   repeats             the key reported down again while it is down (two listeners, a repeat) is the same press; a
//                       Globe keyDown (kVK 179, which some keyboards send with the Fn change) is part of the Fn press.
//   style               (docs/design/dictation-styles.md §3.2) ⇧ pressed and released alone while dictating says
//                       `.style`: the app toggles Structured for this take. In push-to-talk too: a lone ⇧ is the one
//                       key that joins in without cancelling (⇧ with another key still cancels, as any shortcut does).
//                       A click on Blurt's own island (`.islandClick`: the app tells which clicks land there) is the
//                       same toggle and never cancels. Fn+⇧ as the start press (⇧ held when Fn goes down, or pressed
//                       while it is down) starts in Structured: `startShift`. Only with Fn: with an ⌥ key, ⇧ stays a
//                       modifier (⌥⇧V and Blurt's other ⌥⇧ shortcuts never start anything).
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
        /// keyDowns that belong to the key's own press: the Globe key's (179) on keyboards that send one with Fn
        var ownKeyDowns: Set<Int> { self == .fn ? [179] : [] }
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
        /// ⇧ alone (or a click on the island) while dictating: toggle Structured for this take
        case style
    }
    public enum Event: Equatable {
        /// a modifier changed (CGEvent flagsChanged): its keyCode and the flags after the change
        case flags(keyCode: Int, flags: UInt64, time: Double)
        case keyDown(keyCode: Int, time: Double)
        case mouseDown(time: Double)
        /// a click on Blurt's own island (the app checks where a mouse-down landed): never cancels push-to-talk
        case islandClick(time: Double)
        /// the caller's timer, at or after `deadline`
        case tick(time: Double)
    }

    public static let escape = 53
    /// kVK_Shift, kVK_RightShift
    public static let shiftCodes: Set<Int> = [56, 60]
    static let shiftMask: UInt64 = 0x2_0000
    /// a lone ⇧ held longer than this is not a toggle (a finger resting on it)
    public var shiftTapMax = 1.0

    public var key: Key
    public var mode: Mode
    public var tapMax = 0.4
    public var holdMin = 0.25
    /// auto mode: shorter than this is a tap (hands-free); held alone this long is push-to-talk
    public var autoHold = 0.3
    /// Two quick taps press Return (record.dictation.double_tap_send, on by default).
    public var doubleTap = true
    /// the second tap must go down within this long of the first one's release (the app sets macOS's double-click
    /// interval, clamped: `window(doubleClickInterval:)`)
    public var doubleTapWindow = 0.5
    /// a stop tap going down this soon after the start tap's release is a near miss of a double tap (`quickStop`)
    public var nearMissWindow = 0.8
    /// The last take is still on its way (transcribing, polishing, pasting; the app sets it): Esc cancels it. A press
    /// starts the next take as usual.
    public var pending = false
    /// A press the mode doesn't use, set when it comes up (nil: none): the app says how this mode starts.
    public enum Miss: Equatable {
        /// hold mode: let go before `holdMin` (a tap) — this mode is push-to-talk
        case tappedInHoldMode
        /// tap mode: held past `tapMax` — this mode starts with a tap
        case heldInTapMode
    }
    public private(set) var miss: Miss?
    /// The miss, once: read and cleared together, so the keys and clicks that follow don't report it again.
    public mutating func takeMiss() -> Miss? {
        defer { miss = nil }
        return miss
    }

    /// macOS's double-click interval (System Settings → Accessibility → Pointer Control) as the double-tap window:
    /// a Fn tap with the little finger is slower than a click, so never under 0.3 s; never over 0.5 s, where two
    /// separate taps (stop, then start the next one) would start to read as one double tap.
    public static func window(doubleClickInterval: Double) -> Double { min(0.5, max(0.3, doubleClickInterval)) }

    private enum State: Equatable {
        case idle
        case down(at: Double, clean: Bool, code: Int)
        case holding
        case waitRelease          // push-to-talk cancelled while still held: ignore until the key comes up
    }
    private var state: State = .idle
    /// the key code that went down last (either-⌥: which side)
    private var holdingCode = 0
    /// What the last clean tap did (or that push-to-talk was let go), and when it came up: a tap soon after it is a
    /// double tap's second one (after a release: its first one).
    private enum TapDid { case started, stopped, released, nothing, sent }
    private var lastTap: (did: TapDid, up: Double)?
    /// The press now down is the second tap of a double tap (if it comes up quickly): what the first one did.
    private var second: TapDid?
    /// the press now down only ends a bounce (soon after a send, or after a take ended by itself): a tap of it does
    /// nothing
    private var pressQuiet = false
    /// …because a take had just ended by itself (its tap can still be a double tap's first one)
    private var pressAfterEnd = false
    /// a take ended by itself (`endedByItself`): a tap before this does nothing
    private var quietUntil: Double?
    /// when the tap that started the dictation in progress came up (hands-free): the near-miss window counts from it
    private var startTapUp: Double?
    /// ⇧ went down while dictating, alone so far: its release toggles the style
    private var shiftDownAt: Double?
    /// the press now down has ⇧ with it (Fn+⇧)
    private var chord = false
    /// The dictation in progress was started with Fn+⇧: it starts in Structured.
    public private(set) var startShift = false
    /// Dictating, as far as the trigger knows (the app calls `reset` when it ends one itself).
    public private(set) var active = false
    /// The dictation in progress was started by holding the key (hold mode, or auto held past `autoHold`): it ends
    /// when the key comes up, so it has no "nothing said" timeout.
    public private(set) var pushToTalk = false
    /// The `.stop` just given came from a tap soon after the start tap (`nearMissWindow`): a double tap that was a
    /// little slow. The app sends Return instead when nothing was heard.
    public private(set) var quickStop = false

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
        if case let .down(_, clean, _) = state { return clean && !active && !pressQuiet }
        return false
    }

    /// The dictation ended or was started some other way (a menu, the island, a time limit), or the app couldn't
    /// start the one the trigger asked for. `keepTap`: the tap that asked is still the first of a double tap (a start
    /// refused because a recording has the mic still lets the second tap send — Return needs no mic).
    public mutating func reset(active a: Bool, keepTap: Bool = false) {
        active = a
        pushToTalk = false
        startShift = false
        shiftDownAt = nil
        quickStop = false
        startTapUp = nil
        if !keepTap { lastTap = nil }
        second = nil
        quietUntil = nil
        if !a { settle() }
    }

    /// The take ended by itself (the time limit) at `t`: the user's next tap, a moment later, was meant as its stop —
    /// it does nothing instead of starting a new take.
    public mutating func endedByItself(at t: Double) {
        reset(active: false)
        quietUntil = t + 2.0
    }

    /// Not dictating any more: a key still held is waited out (its release must not start or stop anything).
    private mutating func settle() {
        if state == .holding { state = .waitRelease } else if case .down = state { state = .idle }
    }

    public mutating func handle(_ e: Event) -> [Output] {
        switch e {
        case let .flags(code, flags, t):
            if DictationTrigger.shiftCodes.contains(code) {
                return shiftChanged(down: flags & DictationTrigger.shiftMask != 0, t)
            }
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
                startTapUp = nil
                settle()
                return [.cancel]
            }
            // the take on its way (transcribing, polishing, pasting): Esc throws it away
            if code == DictationTrigger.escape && pending && state == .idle { lastTap = nil; return [.cancel] }
            // the Globe key's own keyDown while it is down (or just coming up) is the same press, not a shortcut
            if key.ownKeyDowns.contains(code) { return [] }
            return otherInput(t)
        case let .mouseDown(t):
            return otherInput(t)
        case .islandClick:
            return active ? [.style] : []
        case let .tick(t):
            return tick(t)
        }
    }

    private mutating func keyDown(_ code: Int, _ flags: UInt64, _ t: Double) -> [Output] {
        if state == .holding || state == .waitRelease { return [] }        // a repeat of what we know
        if case let .down(_, _, held) = state, held == code { return [] }   // the same press reported again
        // Fn+⇧ (⇧ held when Fn goes down) is still a clean press: it starts in Structured
        let withShift = key == .fn && !active && flags & DictationTrigger.shiftMask != 0
        let alone = flags & (Key.otherMods(code) & (withShift ? ~DictationTrigger.shiftMask : ~UInt64(0))) == 0
        state = .down(at: t, clean: alone, code: code)
        holdingCode = code
        second = nil
        shiftDownAt = nil                   // the key joined a ⇧ that was down: no toggle when ⇧ comes up
        chord = withShift && alone
        miss = nil
        let bounce = lastTap.map { $0.did == .sent && t - $0.up <= doubleTapWindow } ?? false
        let afterEnd = quietUntil.map { t < $0 } ?? false
        quietUntil = nil
        pressQuiet = alone && !active && (bounce || afterEnd)
        pressAfterEnd = pressQuiet && afterEnd
        if doubleTap, alone, !chord, !pressQuiet, let l = lastTap, t - l.up <= doubleTapWindow { second = l.did }
        lastTap = nil
        // a second tap can only send (or cancel the dictation the first one started): no mic for it; nor for a press
        // that only ends a bounce
        if second != nil || pressQuiet { return [] }
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
        let quiet = pressQuiet, afterEnd = pressAfterEnd
        pressQuiet = false
        pressAfterEnd = false
        quickStop = false
        // the second tap of a double tap: send (cancelling the dictation the first one started)
        if let f = first, case let .down(at, clean, _) = was, clean, t - at <= tapLimit {
            if f == .started && active {
                active = false
                pushToTalk = false
                startTapUp = nil
                lastTap = (.sent, t)
                return [.cancel, .send]
            }
            // push-to-talk was just let go: this is the double tap's first tap
            if f == .released { lastTap = (.nothing, t); return [] }
            lastTap = (.sent, t)
            return [.send]
        }
        // a tap soon after a send, or right after a take ended by itself: nothing (after the end it can still be a
        // double tap's first one)
        if quiet, case let .down(at, clean, _) = was, clean, t - at <= tapLimit {
            if afterEnd { lastTap = (.nothing, t) }
            return []
        }
        switch (mode, was) {
        case let (.tap, .down(at, clean, _)):
            guard clean, t - at <= tapMax else {
                if clean, !active { miss = .heldInTapMode }
                return []
            }
            active.toggle()
            lastTap = (active ? .started : .stopped, t)
            if active { startShift = chord; startTapUp = t } else { stopped(at: at) }
            return [active ? .start : .stop]
        case let (.auto, .down(at, clean, _)):
            guard clean else { return [] }
            if active {                     // hands-free: the next clean press stops it, however long
                active = false
                pushToTalk = false
                lastTap = (.stopped, t)
                if t - at <= tapLimit { stopped(at: at) } else { startTapUp = nil; shiftDownAt = nil }
                return [.stop]
            }
            guard t - at < autoHold else { return [] }      // held past the threshold with no tick: never started
            active = true
            pushToTalk = false
            startShift = chord
            startTapUp = t
            lastTap = (.started, t)
            return [.start]
        case (.hold, .holding), (.auto, .holding):
            active = false
            pushToTalk = false
            shiftDownAt = nil
            startTapUp = nil
            lastTap = (.released, t)
            return [.stop]
        case let (.hold, .down(at, clean, _)):
            // let go before 250 ms: nothing said — but it can be the first tap of a double tap
            if clean, t - at < holdMin { lastTap = (.nothing, t); miss = .tappedInHoldMode }
            return []
        default:            // a dirty tap, a release we wait out
            return []
        }
    }

    /// A hands-free dictation stopped by a tap that went down at `at`: a near miss of a double tap when that was soon
    /// after the start tap came up.
    private mutating func stopped(at: Double) {
        shiftDownAt = nil
        if let up = startTapUp, at - up <= nearMissWindow, doubleTap { quickStop = true }
        startTapUp = nil
    }

    /// Another key, modifier or click: a tap in progress is no longer clean; push-to-talk is cancelled. Nor is the
    /// next tap the second of a double tap (or a near miss of one).
    private mutating func otherInput(_ t: Double) -> [Output] {
        lastTap = nil
        startTapUp = nil
        shiftDownAt = nil                   // ⇧ with another key: a shortcut (or a capital), not the style toggle
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
        pressQuiet = false
        active = true
        pushToTalk = true
        startShift = chord
        second = nil
        return [.start]
    }

    /// ⇧ went down or up. While dictating, alone and let go within `shiftTapMax`: the style toggle (push-to-talk is
    /// not cancelled by it). While the Fn start press is down: Fn+⇧, a Structured start. Otherwise ⇧ is any other
    /// modifier.
    private mutating func shiftChanged(down: Bool, _ t: Double) -> [Output] {
        if case let .down(_, clean, _) = state, !active, key == .fn {
            // the start press with ⇧ joining in (Fn+⇧): still clean; a key after it makes it a shortcut, as before
            if down && clean { chord = true }
            return []
        }
        if active, state == .holding || state == .idle {
            if down {
                lastTap = nil
                startTapUp = nil
                shiftDownAt = t
                return []
            }
            defer { shiftDownAt = nil }
            if let d = shiftDownAt, t - d <= shiftTapMax { return [.style] }
            return []
        }
        if state == .waitRelease { return [] }
        return otherInput(t)
    }
}

extension DictationTrigger {
    /// A compact script of events for tests and the app's test hook (`dictation keys …`), one token per event,
    /// times in ms: "ropt-down@0 ropt-up@120", "fn-down@0 tick@300 fn-up@900", "ropt-down@0 key:9@50 ropt-up@90",
    /// "click@40", "island@40" (a click on Blurt's island), "esc@500", "shift-down@0 shift-up@10". Modifier tokens:
    /// ropt, lopt, fn, shift, rshift, cmd, ctrl.
    public static func parse(_ script: String, holding: Set<String> = []) -> [Event] {
        var held = holding
        let bits: [String: (code: Int, mask: UInt64)] = [
            "ropt": (61, 0x80000 | 0x40), "lopt": (58, 0x80000 | 0x20), "fn": (63, 0x80_0000),
            "shift": (56, 0x2_0000), "rshift": (60, 0x2_0000), "cmd": (55, 0x10_0000), "ctrl": (59, 0x4_0000),
        ]
        func flags() -> UInt64 { held.reduce(0) { $0 | (bits[$1]?.mask ?? 0) } }
        var out: [Event] = []
        for tok in script.split(separator: " ") {
            let parts = tok.split(separator: "@")
            guard parts.count == 2, let ms = Double(parts[1]) else { continue }
            let t = ms / 1000, name = String(parts[0])
            if name == "tick" { out.append(.tick(time: t)) } else if name == "click" { out.append(.mouseDown(time: t)) }
            else if name == "island" { out.append(.islandClick(time: t)) }
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

    /// When a keyboard event happened, on CACurrentMediaTime's clock (`now`), from its CGEventTimestamp `raw`: the
    /// trigger's windows are a few hundred ms, and the main thread can get to an event late (the mic opening on the
    /// key-down), so the event's own time counts, not when it was handled. CGEventTimestamp is documented in
    /// nanoseconds but is mach_absolute_time ticks on Apple Silicon (`ticksToNs` = 125/3 there): whichever reading lies
    /// within the last two seconds is it; neither (a synthetic event's 0) → `now`.
    public static func eventTime(raw: UInt64, now: Double, ticksToNs: Double) -> Double {
        guard raw > 0 else { return now }
        for s in [Double(raw) / 1e9, Double(raw) * ticksToNs / 1e9] where s <= now + 0.05 && now - s < 2 { return s }
        return now
    }

    /// The same for a time already in seconds on that clock (NSEvent.timestamp): used when it is plausible.
    public static func eventTime(seconds: Double, now: Double) -> Double {
        seconds > 0 && seconds <= now + 0.05 && now - seconds < 2 ? seconds : now
    }

    /// Runs a script; the outputs in order (ticks are delivered only where the script has them).
    public mutating func run(_ script: String) -> [Output] {
        DictationTrigger.parse(script).flatMap { handle($0) }
    }
}
