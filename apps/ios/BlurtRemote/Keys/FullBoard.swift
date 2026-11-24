// The computer keyboard, drawn and touched as one view: two thumbs land on it at once, and whose touch came first decides the order
// (FullTyping). Labels follow what's held: ⇧ shows what ⇧ types, fn what fn presses. Colours and corners are the pages' keys'.
import BlurtRemoteKit
import UIKit

final class FullBoard: UIView {
    /// the talk key's place, in this view
    private(set) var talkSlot: CGRect?
    private var host = RemoteHost.mac
    private var tier = FullTier.ten
    private var keys: [(key: FullKey, rect: CGRect)] = []
    private var faces: [(box: UIView, label: UILabel, second: UILabel)] = []
    private let typing = FullTyping()
    private var fingers: [ObjectIdentifier: (id: Int, index: Int)] = [:]
    private var nextID = 0
    private var ticker: CADisplayLink?
    private var plan: (frame: CGRect, tier: FullTier, heights: [CGFloat])?
    private var elements: [KeyElement] = []
    /// something was typed here: the phone's still in use
    var onKey: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        typing.mods = { Sticky.shared.held }
        Sticky.shared.wait(self) { [weak self] in if let self { self.apply(self.typing.flush()) } }
    }

    required init?(coder: NSCoder) { fatalError() }

    func arrange(tier: FullTier, heights: [CGFloat], host: RemoteHost) {
        guard plan.map({ $0.frame != bounds || $0.tier != tier || $0.heights != heights }) ?? true || host != self.host else { return }
        plan = (bounds, tier, heights)
        if host != self.host || tier != self.tier || keys.isEmpty { letGo() }
        self.host = host
        self.tier = tier
        keys = FullKeys.place(FullKeys.rows(tier, for: host), in: bounds, tier: tier, heights: heights)
        talkSlot = keys.first { $0.key.kind == .talk }?.rect
        while faces.count < keys.count {
            let box = UIView(), label = UILabel(), second = UILabel()
            box.isUserInteractionEnabled = false
            box.layer.cornerRadius = 8
            box.layer.cornerCurve = .continuous
            label.textAlignment = .center
            label.adjustsFontSizeToFitWidth = true
            label.minimumScaleFactor = 0.5
            label.baselineAdjustment = .alignCenters
            second.textAlignment = .center
            box.addSubview(label)
            box.addSubview(second)
            addSubview(box)
            faces.append((box, label, second))
        }
        for (i, f) in faces.enumerated() {
            f.box.isHidden = i >= keys.count || keys[i].key.kind == .talk
            guard i < keys.count else { continue }
            f.box.frame = keys[i].rect
        }
        elements = keys.enumerated().filter { $0.element.key.kind != .talk }.map { i, k in
            let e = KeyElement(accessibilityContainer: self)
            e.accessibilityFrameInContainerSpace = k.rect
            e.accessibilityTraits = .keyboardKey
            e.act = { [weak self] in self?.tapped(i) }
            return e
        }
        accessibilityElements = elements
        refresh()
    }

    // MARK: how it looks

    func refresh() {
        let s = Sticky.shared, fn = typing.fn, shift = s.held.contains(.shift), down = typing.pressed
        var n = 0
        for (i, k) in keys.enumerated() where k.key.kind != .talk {
            let f = faces[i], r = CGRect(origin: .zero, size: k.rect.size)
            let words = FullLabel.of(k.key, host: host, fn: fn, shift: shift, altGr: s.altGr, legends: Link.shared.legends)
            let (held, locked) = state(k.key)
            f.box.backgroundColor = locked ? Theme.slabLatched : down.contains(k.key) ? Theme.slabPressed : isMark(k.key) ? Theme.slabStrong : Theme.slab
            f.box.layer.borderWidth = held ? 2 : 0.5
            f.box.layer.borderColor = held ? Theme.slabLatched.cgColor : Theme.edge.cgColor
            f.label.text = words.main
            f.second.text = words.second
            let ink = locked ? UIColor.black : words.faint ? Theme.faint : Theme.mark
            f.label.textColor = ink
            f.second.textColor = locked ? UIColor(white: 0, alpha: 0.6) : Theme.caption
            let size = Self.size(words.main, in: r.size)
            f.label.font = .systemFont(ofSize: size, weight: .regular)
            f.second.font = .systemFont(ofSize: max(10, min(13, size * 0.6)), weight: .regular)
            if words.second == nil || r.height < 34 {
                f.second.text = nil
                f.label.frame = r.insetBy(dx: 2, dy: 1)
            } else if r.width > r.height * 1.25 {
                // a wide, low key: side by side, as there's no height for two lines
                f.label.frame = CGRect(x: r.width * 0.22, y: 0, width: r.width * 0.4, height: r.height)
                f.second.frame = CGRect(x: r.width * 0.6, y: 0, width: r.width * 0.28, height: r.height)
            } else {
                let up = min(r.height * 0.42, 20)
                f.second.frame = CGRect(x: 1, y: r.height * 0.09, width: r.width - 2, height: up * 0.8)
                f.label.frame = CGRect(x: 1, y: r.height * 0.38, width: r.width - 2, height: r.height * 0.56)
            }
            let e = elements[n]
            e.accessibilityLabel = words.spoken
            e.accessibilityValue = locked ? String(localized: "Locked") : held ? String(localized: "Held") : nil
            n += 1
        }
    }

    private func isMark(_ k: FullKey) -> Bool { if case .key("Return") = k.kind { true } else { false } }

    private func state(_ k: FullKey) -> (held: Bool, locked: Bool) {
        let s = Sticky.shared
        switch k.kind {
        case let .modifier(m): return (s.held.isSuperset(of: m) && !s.locked.isSuperset(of: m), s.locked.isSuperset(of: m))
        case .altGr: return (s.altGr && !s.altGrLocked, s.altGrLocked)
        case .fn: return (typing.fn && !typing.fnLocked, typing.fnLocked)
        default: return (false, false)
        }
    }

    private static func size(_ t: String, in s: CGSize) -> CGFloat {
        let most = min(22, s.height * 0.5)
        if t == "⇥" || t.hasPrefix("↩") { return min(26, s.height * 0.6) }
        return t.count <= 1 ? most : t.count <= 2 ? min(16, most) : t.count <= 4 ? min(14, most) : min(12, most)
    }

    // MARK: touches

    /// The key under the finger, the gaps shared out between their neighbours.
    func index(at p: CGPoint) -> Int? {
        func away(_ r: CGRect) -> CGFloat { hypot(max(r.minX - p.x, 0, p.x - r.maxX), max(r.minY - p.y, 0, p.y - r.maxY)) }
        guard let i = keys.indices.min(by: { away(keys[$0].rect) < away(keys[$1].rect) }), away(keys[i].rect) <= 8 else { return nil }
        return keys[i].key.kind == .talk ? nil : i
    }

    override func touchesBegan(_ t: Set<UITouch>, with e: UIEvent?) {
        for x in t.sorted(by: { $0.timestamp < $1.timestamp }) {
            guard let i = index(at: x.location(in: self)) else { continue }
            nextID += 1
            fingers[ObjectIdentifier(x)] = (nextID, i)
            apply(typing.began(nextID, keys[i].key, at: x.timestamp))
        }
        onKey?()
        refresh()
        startTicks()
    }

    override func touchesMoved(_ t: Set<UITouch>, with e: UIEvent?) {
        for x in t {
            guard let f = fingers[ObjectIdentifier(x)], keys.indices.contains(f.index) else { continue }
            apply(typing.moved(f.id, inside: keys[f.index].rect.insetBy(dx: -14, dy: -14).contains(x.location(in: self)), at: x.timestamp))
        }
        refresh()
    }

    override func touchesEnded(_ t: Set<UITouch>, with e: UIEvent?) {
        for x in t.sorted(by: { $0.timestamp < $1.timestamp }) {
            if let f = fingers.removeValue(forKey: ObjectIdentifier(x)) { apply(typing.ended(f.id, at: x.timestamp)) }
        }
        refresh()
    }

    override func touchesCancelled(_ t: Set<UITouch>, with e: UIEvent?) {
        for x in t { if let f = fingers.removeValue(forKey: ObjectIdentifier(x)) { apply(typing.cancelled(f.id)) } }
        refresh()
    }

    /// VoiceOver's double tap: down and up.
    private func tapped(_ i: Int) {
        guard keys.indices.contains(i) else { return }
        let now = CACurrentMediaTime()
        nextID += 1
        apply(typing.began(nextID, keys[i].key, at: now))
        apply(typing.ended(nextID, at: now + 0.05))
        refresh()
    }

    func letGo() {
        fingers = [:]
        apply(typing.letGo())
        if !keys.isEmpty, !faces.isEmpty { refresh() }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { letGo() }
    }

    private func startTicks() {
        guard ticker == nil, typing.needsTicks else { return }
        let l = CADisplayLink(target: self, selector: #selector(tick))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 20, maximum: 60, preferred: 30)
        l.add(to: .main, forMode: .common)
        ticker = l
    }

    @objc private func tick() {
        let out = typing.tick(at: CACurrentMediaTime())
        if !out.isEmpty { apply(out); refresh() }
        if !typing.needsTicks { ticker?.invalidate(); ticker = nil }
    }

    private func apply(_ out: [FullTyping.Output]) {
        let l = Link.shared, s = Sticky.shared, now = CACurrentMediaTime()
        for o in out {
            switch o {
            case let .press(n):
                l.send(.key(n == FullTyping.inputSource ? RemoteChord(.control, "Space") : RemoteChord([], n), down: nil))
            case let .hold(n, down): l.send(.key(RemoteChord([], n), down: down))
            case let .again(n): l.send(.key(RemoteChord([], n), down: true))
            case let .modifierDown(m): s.press(m)
            case let .modifierUp(m, t, cancelled): s.finish(m, after: t, at: now, cancelled: cancelled)
            case .altGrDown: s.pressAltGr()
            case let .altGrUp(t, cancelled): s.finishAltGr(after: t, at: now, cancelled: cancelled)
            case .engage: s.engage()
            case let .engageWith(t): s.engage(with: t)
            case .used: s.used()
            case .fnChanged: break
            case .tick: Haptics.tick()
            case .grab: Haptics.grab()
            }
        }
    }

    #if DEBUG
    var testKeys: [(key: FullKey, rect: CGRect)] { keys }
    #endif

    private final class KeyElement: UIAccessibilityElement {
        var act: (() -> Void)?
        override func accessibilityActivate() -> Bool { act?(); return true }
    }
}

/// What's printed on a key.
struct FullLabel: Equatable {
    var main: String
    var second: String?
    var faint = false
    var spoken: String

    static func of(_ k: FullKey, host: RemoteHost, fn: Bool, shift: Bool, altGr: Bool, legends: RemoteLegends?) -> FullLabel {
        switch k.kind {
        case let .modifier(m): return FullLabel(main: host.name(m), spoken: host.name(m))
        case .altGr: return FullLabel(main: "AltGr", spoken: "AltGr")
        case .fn: return FullLabel(main: "fn", spoken: "fn")
        case .inputSource: return FullLabel(main: "⌃␣", spoken: String(localized: "Next Input Source"))
        case .talk: return FullLabel(main: "", spoken: "")
        case let .key(name):
            if fn {
                guard let f = k.fn else { return named(name, host: host, shift: shift, altGr: altGr, legends: legends, faint: true) }
                return named(f, host: host, shift: false, altGr: false, legends: nil, faint: false)
            }
            return named(name, host: host, shift: shift, altGr: altGr, legends: legends, faint: false)
        }
    }

    private static func named(_ name: String, host: RemoteHost, shift: Bool, altGr: Bool, legends: RemoteLegends?, faint: Bool) -> FullLabel {
        guard name.count == 1 else {
            // in words: a small ↖ says nothing
            let moves = ["Home": "Home", "End": "End", "PageUp": "PgUp", "PageDown": "PgDn"]
            let w = moves[name] ?? (name == "Delete" && host != .mac ? "⌫" : name == "Return" && host != .mac ? "Enter" : name == "Space" ? "" : host.keyName(name))
            return FullLabel(main: w, faint: faint, spoken: name)
        }
        let l = legends?[name]
        let base = l?.base ?? name, up = l?.shift ?? FullKeys.shifted[name] ?? name
        if altGr, let a = l?.altGr { return FullLabel(main: a, faint: faint, spoken: a) }
        // a letter is one character whichever way; anything else shows both
        let letter = up.lowercased() == base.lowercased() && base.count == 1 && base.first?.isLetter == true
        if letter {
            let t = base == "ß" ? base : base.uppercased()
            return FullLabel(main: t, second: l?.altGr, faint: faint, spoken: t)
        }
        return shift ? FullLabel(main: up, faint: faint, spoken: up) : FullLabel(main: base, second: up, faint: faint, spoken: base)
    }
}
