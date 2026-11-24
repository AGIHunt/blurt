// The computer keyboard's rules, without UIKit: touches and time in, key presses out, so they can be tested as plain sequences.
//
//   a key acts as the finger lifts, so one that landed wrong can slide off and nothing happens. Another finger landing first sends it at
//   once and holds it until its own finger lifts: what two thumbs type fast keeps its order, and two keys held are two keys held
//   held still for `holdAfter`, it goes down on the computer and stays down, pressing on (FullKeys.repeats) as a real keyboard does
//   the arrows and ⌫ act as the finger lands
//   modifiers are Sticky's: tapped, for the next key; held while another is pressed, for that; held alone and lifted, on their own
//   fn the same, here: it's the phone's own
import BlurtRemoteKit
import Foundation

final class FullTyping {
    enum Output: Equatable {
        case press(String)
        case hold(String, down: Bool)
        /// held, and down again: the computer's own repeat
        case again(String)
        /// Sticky's: a modifier under a finger, what's held taking part in what comes next, and the finger gone
        case modifierDown(RemoteModifiers)
        case modifierUp(RemoteModifiers, after: Double, cancelled: Bool)
        case altGrDown
        case altGrUp(after: Double, cancelled: Bool)
        case engage
        /// the same for a key that landed then: what landed in the same instant, not what came after it
        case engageWith(Double)
        /// a key went down: what was held for one is done
        case used
        case fnChanged
        case tick, grab
    }

    static let holdAfter = 0.4
    static let repeatEvery = 0.05
    static let repeatAfter = 0.35
    static let tapTime = 0.45

    private enum State { case pending, held, acting, modifier, fn, done }
    private struct Finger {
        let key: FullKey
        let name: String?
        let at: Double
        var state: State
        var next: Double?
        var slid = false
    }

    private var fingers: [Int: Finger] = [:]
    private var newest: Int?
    /// what's held for the next key or for this one, as it was when asked
    var mods: () -> RemoteModifiers = { [] }

    private(set) var fnOnce = false
    private(set) var fnLocked = false
    private var fnUsed = false
    private var lastFnTap: Double?
    private var fnDown: Bool { fingers.values.contains { $0.state == .fn } }
    /// the keys show and press what fn makes of them
    var fn: Bool { fnOnce || fnLocked || fnDown }
    var isEmpty: Bool { fingers.isEmpty }
    /// something is waiting for time to pass
    var needsTicks: Bool { fingers.values.contains { $0.state == .pending || $0.next != nil } }
    /// the keys under a finger now
    var pressed: [FullKey] { fingers.values.filter { !$0.slid }.map(\.key) }

    func began(_ id: Int, _ key: FullKey, at now: Double) -> [Output] {
        switch key.kind {
        case let .modifier(m):
            fingers[id] = Finger(key: key, name: nil, at: now, state: .modifier)
            return [.modifierDown(m), .tick]
        case .altGr:
            fingers[id] = Finger(key: key, name: nil, at: now, state: .modifier)
            return [.altGrDown, .tick]
        case .fn:
            fnUsed = false
            fingers[id] = Finger(key: key, name: nil, at: now, state: .fn)
            return [.fnChanged, .tick]
        case .talk: return []
        case .inputSource, .key: break
        }
        var out: [Output] = []
        out += flush()
        out.append(.engage)
        for i in fingers.keys { fingers[i]?.next = nil }      // only the last key down repeats
        var name: String? = nil
        if case let .key(n) = key.kind { name = fn ? key.fn ?? n : n }
        if fn { fnUsed = true }
        newest = id
        if let n = name, FullKeys.atOnce(n) {
            fingers[id] = Finger(key: key, name: n, at: now, state: .acting, next: FullKeys.repeats(n, mods: mods()) ? now + Self.repeatAfter : nil)
            out += [.press(n), .tick] + spent()
        } else {
            fingers[id] = Finger(key: key, name: name, at: now, state: .pending)
            out.append(.tick)
        }
        return out
    }

    /// Who is still down and hasn't acted goes now, and is held from here, in the order they landed: another key is landing, or the modifier
    /// that was held for it is letting go.
    func flush() -> [Output] {
        var out: [Output] = []
        for (i, f) in fingers.sorted(by: { $0.value.at < $1.value.at }) where f.state == .pending && !f.slid {
            guard let n = f.name else { continue }
            out += [.engageWith(f.at), .hold(n, down: true)] + spent()
            fingers[i]?.state = .held
        }
        return out
    }

    /// The finger is on its key still, or has slid off it.
    func moved(_ id: Int, inside: Bool, at now: Double) -> [Output] {
        guard var f = fingers[id], !inside, !f.slid else { return [] }
        f.slid = true
        f.next = nil
        var out: [Output] = []
        if f.state == .held, let n = f.name { out.append(.hold(n, down: false)); f.state = .done }
        if f.state == .pending || f.state == .acting { f.state = .done }
        fingers[id] = f
        return out
    }

    func ended(_ id: Int, at now: Double) -> [Output] {
        guard let f = fingers.removeValue(forKey: id) else { return [] }
        switch f.state {
        case .pending:
            return [.engageWith(f.at), .press(f.name ?? FullTyping.inputSource)] + spent()
        case .held: return f.name.map { [.hold($0, down: false)] } ?? []
        case .modifier:
            if case let .modifier(m) = f.key.kind { return [.modifierUp(m, after: now - f.at, cancelled: f.slid)] }
            return [.altGrUp(after: now - f.at, cancelled: f.slid)]
        case .fn:
            guard !f.slid, !fnUsed else { return [.fnChanged] }
            if fnLocked { fnLocked = false }
            else if let l = lastFnTap, now - l < 0.4 { fnOnce = false; fnLocked = true }
            else { fnOnce.toggle() }
            lastFnTap = now
            return [.fnChanged]
        case .acting, .done: return []
        }
    }

    /// Time passing, called while `needsTicks`.
    func tick(at now: Double) -> [Output] {
        var out: [Output] = []
        for (i, f) in fingers {
            if f.state == .pending, let n = f.name, now - f.at >= Self.holdAfter, FullKeys.repeats(n, mods: mods()) {
                out += [.engageWith(f.at), .hold(n, down: true), .grab] + spent()
                fingers[i]?.state = .held
                fingers[i]?.next = i == newest ? now + Self.repeatEvery : nil
            } else if let t = f.next, now >= t, let n = f.name {
                out.append(f.state == .held ? .again(n) : .press(n))
                fingers[i]?.next = now + Self.repeatEvery
            }
        }
        return out
    }

    /// Put away, turned, the app left: nothing stays down.
    func letGo() -> [Output] {
        let out: [Output] = fingers.values.compactMap { f in
            switch f.state {
            case .held: return f.name.map { .hold($0, down: false) }
            case .modifier:
                if case let .modifier(m) = f.key.kind { return .modifierUp(m, after: 0, cancelled: true) }
                return .altGrUp(after: 0, cancelled: true)
            default: return nil
            }
        }
        fingers = [:]
        fnOnce = false
        fnLocked = false
        return out + [.fnChanged]
    }

    func cancelled(_ id: Int) -> [Output] {
        let out = moved(id, inside: false, at: 0)
        guard let f = fingers.removeValue(forKey: id) else { return out }
        if f.state == .modifier {
            if case let .modifier(m) = f.key.kind { return out + [.modifierUp(m, after: 0, cancelled: true)] }
            return out + [.altGrUp(after: 0, cancelled: true)]
        }
        return out
    }

    private func spent() -> [Output] {
        guard fnOnce else { return [.used] }
        fnOnce = false
        return [.used, .fnChanged]
    }

    /// stands for ⌃Space, the Mac's own way to the next input source
    static let inputSource = "⌃Space"
}
