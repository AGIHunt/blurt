// One key. Raw touches, because a key here does more than a button does:
//
//   a plain key fires when the thumb lifts, so a thumb that lands wrong can slide off and nothing happens; held still it
//   does nothing.
//   a cycle key (⌘Tab) presses at once and keeps the modifier down: slide to step through, a detent every 22 pt, left to go
//   back; at the edge of the screen it keeps stepping, so twenty apps are as reachable as three. Lifting lets go. A quick tap
//   is the quick ⌘Tab: back to the last app. The other keys are out of play meanwhile: the thumb passes over them.
//   the arrow key is four keys in one, each edge marked with its arrow: tap towards an edge for that arrow, hold to repeat. Or drag, one
//   step per 24 pt; past 72 pt it repeats, faster with distance. Tap and then drag does the same with ⇧.
//   a repeating key (⌫, an arrow) fires at once and repeats while held. Nothing destructive repeats: never Esc, ⌃C or Return.
//
//   In the list a thumb may land on any of these meaning to scroll. So there, the keys that act at once wait to be sure: a moment held,
//   or a slide sideways, or a lift. Until then a scroll may take the touch and nothing has happened. In the dock they act at once.
import BlurtRemoteKit
import UIKit

final class KeyCell: UIView {
    var slot: KeySlot? { didSet { refresh() } }
    /// a cycle started or ended: the other keys sit out
    var onCycle: ((Bool) -> Void)?
    /// on the scrolling list
    var inList = false
    /// something has been sent, or is about to be: a scroll can't take this touch any more
    private var committed = true
    private var commitTimer: Timer?
    private static let commitDelay = 0.12

    private let glyph = UILabel()
    private let icon = UIImageView()
    private let caption = UILabel()
    private let arrowMarks = ["chevron.up", "chevron.down", "chevron.left", "chevron.right"].map { n in
        UIImageView(image: UIImage(systemName: n, withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold)))
    }
    private var cycle: Cycle?
    private var start = CGPoint.zero
    private var moved = false
    private var cancelled = false
    private var armed = false

    private struct Cycle {
        var hold: RemoteModifiers
        var key: String
        var forward: RemoteChord
        var back: RemoteChord
        var steps = 0
        /// steps the screen edge added
        var carried = 0
    }

    private static let cycleStep: CGFloat = 22
    private static let edge: CGFloat = 36
    private static let edgeEvery = 0.14
    private var edgeTimer: Timer?
    private var edgeDirection = 0

    // arrows
    private var arrowAnchor = CGPoint.zero
    private var arrowShift = false
    private var lastArrowEnd: Double = 0
    private var arrowRepeated = false
    private var repeater: Timer?
    private var repeatKey: RemoteChord?
    private var repeatRate = 0.0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Theme.slab
        layer.cornerRadius = Theme.keyRadius
        layer.cornerCurve = .continuous
        isMultipleTouchEnabled = false
        for v in [glyph, icon, caption] as [UIView] { addSubview(v) }
        for m in arrowMarks {
            m.tintColor = Theme.mark
            m.isHidden = true
            addSubview(m)
        }
        glyph.textAlignment = .center
        glyph.textColor = Theme.mark
        glyph.adjustsFontSizeToFitWidth = true
        glyph.minimumScaleFactor = 0.6
        caption.textAlignment = .center
        caption.textColor = Theme.caption
        caption.font = .systemFont(ofSize: 9, weight: .regular)
        caption.adjustsFontSizeToFitWidth = true
        caption.minimumScaleFactor = 0.7
        icon.contentMode = .center
        icon.tintColor = Theme.mark
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = bounds.width, h = bounds.height
        let hasCaption = !(caption.text ?? "").isEmpty
        let center = hasCaption ? h * 0.37 : h * 0.5
        glyph.frame = CGRect(x: 1, y: center - 11, width: w - 2, height: 22)
        icon.frame = glyph.frame
        caption.frame = CGRect(x: 1, y: h - 14, width: w - 2, height: 12)
        let mid = CGPoint(x: w / 2, y: h / 2), inX = min(13, w * 0.2), inY = min(11, h * 0.22)
        arrowMarks[0].center = CGPoint(x: mid.x, y: inY)
        arrowMarks[1].center = CGPoint(x: mid.x, y: h - inY)
        arrowMarks[2].center = CGPoint(x: inX, y: mid.y)
        arrowMarks[3].center = CGPoint(x: w - inX, y: mid.y)
    }

    func refresh() {
        guard let s = slot else {
            glyph.text = nil; icon.image = nil; caption.text = nil
            backgroundColor = .clear
            layer.borderWidth = 1
            layer.borderColor = Theme.hairline.cgColor
            accessibilityLabel = String(localized: "Empty")
            return
        }
        let held = Sticky.shared
        var latched = false, once = false
        if case let .sticky(m) = s.action {
            latched = held.locked.isSuperset(of: m)
            once = held.once.isSuperset(of: m) && !latched
        }
        var strong = false
        if case let .chord(c, _) = s.action, c.mods.isEmpty, c.key == "Return" { strong = true }
        backgroundColor = latched ? Theme.slabLatched : strong ? Theme.slabStrong : Theme.slab
        layer.borderWidth = once ? 1.5 : 0.5
        layer.borderColor = once ? Theme.slabLatched.cgColor : Theme.edge.cgColor
        glyph.textColor = latched ? .black : Theme.mark
        caption.textColor = latched ? UIColor(white: 0, alpha: 0.6) : Theme.caption
        var isArrows = false
        if case .arrows = s.action { isArrows = true }
        arrowMarks.forEach { $0.isHidden = !isArrows }
        accessibilityLabel = s.title
        let f = s.face
        if isArrows {
            icon.image = nil
            glyph.text = nil
            caption.text = nil
            setNeedsLayout()
            return
        }
        if f.hasPrefix("sf:") {
            icon.image = UIImage(systemName: String(f.dropFirst(3)), withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .regular))
            glyph.text = nil
        } else {
            icon.image = nil
            glyph.text = f
            glyph.font = .systemFont(ofSize: Self.faceSize(f), weight: .regular)
        }
        caption.text = s.detail
        setNeedsLayout()
    }

    /// The shorter the text, the larger: a key has little room, so a long name reads small and a short one is worth choosing.
    private static func faceSize(_ f: String) -> CGFloat {
        switch f.count {
        case ...2: 18
        case 3: 15
        case 4: 13
        case 5...6: 11
        default: 9
        }
    }

    // MARK: touches

    private func press(_ on: Bool) {
        guard slot != nil else { return }
        if on { backgroundColor = Theme.slabPressed } else { refresh() }
    }

    override func touchesBegan(_ t: Set<UITouch>, with e: UIEvent?) {
        guard let p = t.first?.location(in: self) else { return }
        start = p
        moved = false
        cancelled = false
        armed = true
        guard let s = slot else { return }
        press(true)
        committed = true
        guard inList, actsAtOnce(s) else { return act(s, at: p) }
        committed = false
        commitTimer = Timer.scheduledTimer(withTimeInterval: Self.commitDelay, repeats: false) { [weak self] _ in self?.commit() }
    }

    private func actsAtOnce(_ s: KeySlot) -> Bool {
        switch resolved(s.action) {
        case .chord(_, cycle: true), .nextTerminalTab, .arrows: true
        case let .chord(c, cycle: false): Self.repeats(c)
        default: false
        }
    }

    /// May a scroll take this touch? Yes until the key has done something the scroll couldn't undo.
    var givesWay: Bool {
        guard let s = slot else { return true }
        return !committed || !actsAtOnce(s)
    }

    private func commit() {
        commitTimer?.invalidate()
        commitTimer = nil
        guard !committed, let s = slot else { return }
        committed = true
        act(s, at: start)
    }

    private func act(_ s: KeySlot, at p: CGPoint) {
        switch resolved(s.action) {
        case let .chord(c, cycle: true):
            Haptics.tick()
            beginCycle(c)
        case .nextTerminalTab:
            Haptics.tick()
            cycle = Cycle(hold: [], key: "]", forward: RemoteChord([.command, .shift], "]"), back: RemoteChord([.command, .shift], "["))
            Link.shared.send(.key(RemoteChord([.command, .shift], "]"), down: nil))
            onCycle?(true)
        case let .chord(c, cycle: false) where Self.repeats(c):
            fire(c)
            startRepeat(c, after: 0.35, every: 0.08)
        case .arrows:
            arrowAnchor = p
            arrowShift = CACurrentMediaTime() - lastArrowEnd < 0.3
            arrowRepeated = false
            Haptics.step()
            startRepeat(arrowChord(p), after: 0.35, every: 0.08)
        default: break
        }
    }

    /// The arrow towards the edge of the key under the thumb.
    private func arrowChord(_ p: CGPoint) -> RemoteChord {
        let x = (p.x - bounds.midX) / max(bounds.width, 1), y = (p.y - bounds.midY) / max(bounds.height, 1)
        let key = abs(x) > abs(y) ? (x > 0 ? "Right" : "Left") : (y > 0 ? "Down" : "Up")
        return RemoteChord([], key)
    }

    private enum Resolved {
        case chord(RemoteChord, cycle: Bool)
        case nextTerminalTab
        case other(KeyAction)
        case arrows
    }

    private static let terminals: Set<String> = ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
                                                 "net.kovidgoyal.kitty", "org.alacritty", "com.github.wez.wezterm", "co.zeit.hyper"]

    private func resolved(_ a: KeyAction) -> Resolved {
        switch a {
        case let .chord(c, cycle): return .chord(c, cycle: cycle)
        case .arrows: return .arrows
        case .nextTab:
            if let b = Link.shared.front?.bundle, Self.terminals.contains(b) { return .nextTerminalTab }
            return .chord(RemoteChord(.control, "Tab"), cycle: true)
        default: return .other(a)
        }
    }

    private static func repeats(_ c: RemoteChord) -> Bool {
        !c.mods.contains(.command) && ["Delete", "ForwardDelete", "Left", "Right", "Up", "Down"].contains(c.key)   // ⌘⌫ deletes a line
    }

    private func beginCycle(_ c: RemoteChord) {
        let back = c.mods.contains(.shift) ? RemoteChord(c.mods.subtracting(.shift), c.key) : RemoteChord(c.mods.union(.shift), c.key)
        cycle = Cycle(hold: c.mods.subtracting(.shift), key: c.key, forward: c, back: back)
        Link.shared.send(.key(RemoteChord(c.mods.subtracting(.shift), ""), down: true))
        Link.shared.send(.key(c, down: nil))
        onCycle?(true)
    }

    override func touchesMoved(_ t: Set<UITouch>, with e: UIEvent?) {
        guard let p = t.first?.location(in: self) else { return }
        let dx = p.x - start.x, dy = p.y - start.y
        if hypot(dx, dy) > 8 { moved = true }
        if !committed, abs(dx) > 8, abs(dx) > abs(dy) { commit() }
        if cycle != nil {
            cycleTo(Int((dx / Self.cycleStep).rounded(.towardZero)))
            let x = t.first?.location(in: nil).x ?? 0, w = window?.bounds.width ?? bounds.width
            setEdge(x > w - Self.edge ? 1 : x < Self.edge ? -1 : 0)
            return
        }
        guard armed else { return }
        if case .arrows? = slot?.action { return committed && moved ? arrows(p) : () }
        // slid off the key: nothing happens, and what was repeating stops
        let inside = bounds.insetBy(dx: -14, dy: -14).contains(p)
        cancelled = !inside
        if !inside { stopRepeat() }
        press(inside)
    }

    override func touchesEnded(_ t: Set<UITouch>, with e: UIEvent?) {
        commit()
        stopRepeat()
        press(false)
        guard let s = slot else { return }
        if cycle != nil {
            endCycle()
            Sticky.shared.used()
            return
        }
        if case .arrows = s.action {
            if !moved, !arrowRepeated {
                Link.shared.send(.key(arrowChord(start), down: nil))
                done()
            }
            lastArrowEnd = moved || arrowRepeated ? 0 : CACurrentMediaTime()
            return
        }
        guard armed, !cancelled else { return }
        tapped(s)
    }

    override func touchesCancelled(_ t: Set<UITouch>, with e: UIEvent?) {
        letGo()
        press(false)
    }

    /// Taken away mid-press, with the deck reloaded under it: nothing stays held on the Mac.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { letGo() }
    }

    private func letGo() {
        commitTimer?.invalidate()
        commitTimer = nil
        committed = true
        stopRepeat()
        if cycle != nil { endCycle() }
    }

    private func cycleTo(_ fingerSteps: Int) {
        guard var c = cycle else { return }
        let target = fingerSteps + c.carried
        while c.steps != target {
            let forward = target > c.steps
            c.steps += forward ? 1 : -1
            Link.shared.send(.key(forward ? c.forward : c.back, down: nil))
            Haptics.step()
        }
        cycle = c
    }

    /// The thumb has run out of screen: holding it there keeps stepping.
    private func setEdge(_ d: Int) {
        guard d != edgeDirection else { return }
        edgeDirection = d
        edgeTimer?.invalidate()
        edgeTimer = nil
        guard d != 0 else { return }
        let t = Timer(timeInterval: Self.edgeEvery, repeats: true) { [weak self] _ in
            guard let self, var c = self.cycle else { return }
            c.carried += self.edgeDirection
            let fingerSteps = c.steps - (c.carried - self.edgeDirection)
            self.cycle = c
            self.cycleTo(fingerSteps)
        }
        RunLoop.main.add(t, forMode: .common)
        edgeTimer = t
    }

    private func endCycle() {
        setEdge(0)
        if let c = cycle, !c.hold.isEmpty { Link.shared.send(.key(RemoteChord(c.hold, ""), down: false)) }
        cycle = nil
        onCycle?(false)
    }

    private func tapped(_ s: KeySlot) {
        let l = Link.shared
        switch s.action {
        case let .chord(c, _):
            if !Self.repeats(c) { fire(c) }
        case let .sequence(steps):
            Haptics.tick()
            l.send(.run(steps))
            done()
        case let .text(t, enter):
            Haptics.tick()
            l.send(.run([.text(t)] + (enter ? [.wait(60), .key(RemoteChord([], "Return"))] : [])))
            done()
        case let .sticky(m):
            Haptics.grab()
            Sticky.shared.tap(m, at: CACurrentMediaTime())
        case let .blurt(c):
            Haptics.tick()
            l.send(.blurt(c))
        case let .system(m):
            Haptics.tick()
            l.send(.system(m))
        case .arrows, .nextTab: break
        }
    }

    private func fire(_ c: RemoteChord) {
        // the two keys that matter most can be told apart in the thumb
        if c.mods.isEmpty, c.key == "Return" || c.key == "Escape" { Haptics.grab() } else { Haptics.tick() }
        Link.shared.send(.key(c, down: nil))
        done()
    }

    private func done() {
        Sticky.shared.used()
    }

    // MARK: arrows

    private func step(_ key: String) {
        Haptics.step()
        Link.shared.send(.key(RemoteChord(arrowShift ? .shift : [], key), down: nil))
    }

    private func arrows(_ p: CGPoint) {
        let dx = p.x - arrowAnchor.x, dy = p.y - arrowAnchor.y
        let horizontal = abs(dx) > abs(dy)
        let d = horizontal ? dx : dy
        let key = horizontal ? (dx > 0 ? "Right" : "Left") : (dy > 0 ? "Down" : "Up")
        let far = hypot(p.x - start.x, p.y - start.y)
        if far > 72 {
            let rate = max(0.03, 0.11 - Double(far - 72) * 0.001)
            if repeatKey?.key != key || abs(repeatRate - rate) > 0.01 {
                stopRepeat()
                startRepeat(RemoteChord(arrowShift ? .shift : [], key), after: 0, every: rate)
            }
            return
        }
        stopRepeat()
        if abs(d) >= 24 {
            step(key)
            if horizontal { arrowAnchor.x += dx > 0 ? 24 : -24 } else { arrowAnchor.y += dy > 0 ? 24 : -24 }
        }
    }

    private func startRepeat(_ c: RemoteChord, after: Double, every: Double) {
        repeatKey = c
        repeatRate = every
        let r = Timer(fire: Date().addingTimeInterval(after), interval: every, repeats: true) { [weak self] _ in
            self?.arrowRepeated = true
            Haptics.step()
            Link.shared.send(.key(c, down: nil))
        }
        RunLoop.main.add(r, forMode: .common)
        repeater = r
    }

    private func stopRepeat() {
        repeater?.invalidate()
        repeater = nil
        repeatKey = nil
    }
}
