// ⌘ ⇧ ⌥ ⌃ as keys you tap, since one thumb can't hold a chord: one tap holds it for the next key or click, two tap it
// locked until it's tapped off. With a second thumb it's a key like any other: held down while another key is pressed or the pad is
// touched, it's held on the Mac for that long (`press`, `engage`, `lift`). Held a moment and lifted with nothing else, the key is
// pressed on its own (KeyCell), for a lone ⇧ that switches an input method. The Mac really holds them down, so ⌘-click and ⇧-arrows
// work everywhere.
import BlurtRemoteKit
import QuartzCore

final class Sticky {
    static let shared = Sticky()
    private(set) var once: RemoteModifiers = []
    private(set) var locked: RemoteModifiers = []
    /// under a finger now; on the Mac only once something else is pressed with it (`chord`)
    private(set) var down: RemoteModifiers = []
    private(set) var chord: RemoteModifiers = []
    /// what held modifiers say to the Mac: Link's, or a test's
    var tell: (RemoteModifiers) -> Void = { Link.shared.send(.mods($0)) }
    /// a PC's right Alt, which no modifier bit stands for: a key held by name
    private(set) var altGrOnce = false
    private(set) var altGrLocked = false
    private var altGrDown = false
    private var altGrAt = 0.0
    private var pressedAt: [UInt8: Double] = [:]
    private var altGrChord = false
    private var altGrSent = false
    var altGr: Bool { altGrOnce || altGrLocked || altGrChord }
    var tellAltGr: (Bool) -> Void = { Link.shared.send(.key(RemoteChord([], "AltGr"), down: $0)) }
    private var lastAltGrTap: Double?
    private var lastTap: (RemoteModifiers, Double)?
    var onChange: (() -> Void)?
    /// keys under a finger that act as it lifts: fingers rarely lift together, and ⌘ gone a moment before the C must not make it a plain C
    private var waiting: [ObjectIdentifier: () -> Void] = [:]
    func wait(_ o: AnyObject, _ act: @escaping () -> Void) { waiting[ObjectIdentifier(o)] = act }
    func done(_ o: AnyObject) { waiting[ObjectIdentifier(o)] = nil }
    private func beforeLetGo() { waiting.values.forEach { $0() } }

    var held: RemoteModifiers { once.union(locked).union(chord) }

    func tap(_ m: RemoteModifiers, at now: Double) {
        if locked.isSuperset(of: m) {
            locked.subtract(m)
        } else if let l = lastTap, l.0 == m, now - l.1 < 0.4 {
            once.subtract(m)
            locked.formUnion(m)
        } else if once.isSuperset(of: m) {
            once.subtract(m)
        } else {
            once.formUnion(m)
        }
        lastTap = (m, now)
        changed()
    }

    /// A finger is on the key. Nothing goes to the Mac yet: it may be a tap.
    func press(_ m: RemoteModifiers, at now: Double = CACurrentMediaTime()) {
        down.formUnion(m)
        pressedAt[m.rawValue] = now
    }

    /// A key that landed at `began` acts now. A modifier that landed with it, in the same instant but told of after, is held for it; one
    /// that came later is for what comes next: typing fast, the ⇧ for the next letter lands before this one lifts.
    func engage(with began: Double) {
        let together = RemoteModifiers(rawValue: pressedAt.reduce(0) { $1.value <= began + Self.together ? $0 | $1.key : $0 }).intersection(down)
        if altGrDown, !altGrChord, altGrAt <= began + Self.together { altGrChord = true; altGrChanged() }
        guard !together.isSubset(of: chord) else { return }
        chord.formUnion(together)
        changed()
    }
    static let together = 0.06

    /// Something else is being pressed or touched: what's under a finger is held for it.
    func engage() {
        if altGrDown, !altGrChord { altGrChord = true; altGrChanged() }
        guard !down.isSubset(of: chord) else { return }
        chord.formUnion(down)
        changed()
    }

    /// How a modifier's press ends, the same on the pages and the computer keyboard: held with something, that was it; a tap is for the next
    /// key; held alone, it's pressed on its own.
    func finish(_ m: RemoteModifiers, after t: Double, at now: Double, cancelled: Bool) {
        if lift(m) || cancelled { return }
        if t < FullTyping.tapTime { tap(m, at: now) } else { pressAlone(m) }
    }

    /// The modifier by itself, down and up, and not held for the next key.
    func pressAlone(_ m: RemoteModifiers) {
        // already held on the Mac: letting it go is the press on its own. Another down and up would switch the input method back
        let was = held.isSuperset(of: m)
        release(m)
        if !was { Link.shared.send(.key(RemoteChord(m, ""), down: nil)) }
    }

    func pressAltGr(at now: Double = CACurrentMediaTime()) { altGrDown = true; altGrAt = now }

    func finishAltGr(after t: Double, at now: Double, cancelled: Bool) {
        altGrDown = false
        if altGrChord { beforeLetGo(); altGrChord = false; return altGrChanged() }
        guard !cancelled, t < FullTyping.tapTime else { return }
        if altGrLocked { altGrLocked = false }
        else if let l = lastAltGrTap, now - l < 0.4 { altGrOnce = false; altGrLocked = true }
        else { altGrOnce.toggle() }
        lastAltGrTap = now
        altGrChanged()
    }

    private func altGrChanged() {
        if altGr != altGrSent { altGrSent = altGr; tellAltGr(altGr) }
        onChange?()
    }

    /// Everything held, let go of: the Clear button, the keyboard put away, a turn.
    func letGo() {
        down = []
        altGrDown = false
        if altGr { altGrOnce = false; altGrLocked = false; altGrChord = false; altGrChanged() }
        guard !held.isEmpty else { return }
        once = []
        locked = []
        chord = []
        changed()
    }

    /// something is held for the next key, or until it's tapped off
    var holding: Bool { !once.isEmpty || !locked.isEmpty || altGrOnce || altGrLocked }

    /// The finger left the key. True: it was held with something, so it's no tap and no press of its own.
    @discardableResult
    func lift(_ m: RemoteModifiers) -> Bool {
        down.subtract(m)
        guard !chord.intersection(m).isEmpty else { return false }
        beforeLetGo()
        chord.subtract(m)
        lastTap = nil
        changed()
        return true
    }

    /// Pressed on its own instead: not held any more, once or locked.
    func release(_ m: RemoteModifiers) {
        guard !held.intersection(m).isEmpty else { return }
        once.subtract(m)
        locked.subtract(m)
        chord.subtract(m)
        changed()
    }

    /// A key or a click went through: what was held for it is done.
    func used() {
        if altGrOnce { altGrOnce = false; altGrChanged() }
        guard !once.isEmpty else { return }
        once = []
        changed()
    }

    func clear() {
        down = []
        altGrOnce = false; altGrLocked = false; altGrChord = false; altGrDown = false; altGrSent = false
        guard !held.isEmpty else { return }
        once = []
        locked = []
        chord = []
        onChange?()
    }

    private func changed() {
        tell(held)
        onChange?()
    }
}
