// ⌘ ⇧ ⌥ ⌃ as keys you tap, since one thumb can't hold a chord: one tap holds it for the next key or click, two tap it
// locked until it's tapped off. Held a moment, the key is pressed on its own (KeyCell), for a lone ⇧ that switches an input method. The Mac really holds them down, so ⌘-click and ⇧-arrows work everywhere.
import BlurtRemoteKit
import Foundation

final class Sticky {
    static let shared = Sticky()
    private(set) var once: RemoteModifiers = []
    private(set) var locked: RemoteModifiers = []
    private var lastTap: (RemoteModifiers, Double)?
    var onChange: (() -> Void)?

    var held: RemoteModifiers { once.union(locked) }

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

    /// Pressed on its own instead: not held any more, once or locked.
    func release(_ m: RemoteModifiers) {
        guard !held.intersection(m).isEmpty else { return }
        once.subtract(m)
        locked.subtract(m)
        changed()
    }

    /// A key or a click went through: what was held for it is done.
    func used() {
        guard !once.isEmpty else { return }
        once = []
        changed()
    }

    func clear() {
        guard !held.isEmpty else { return }
        once = []
        locked = []
        onChange?()
    }

    private func changed() {
        Link.shared.send(.mods(held))
        onChange?()
    }
}
