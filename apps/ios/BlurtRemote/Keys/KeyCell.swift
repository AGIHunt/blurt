// One key. Raw touches, because a key here does more than a button does:
//
//   a plain key fires when the thumb lifts, so a thumb that lands wrong can slide off and nothing happens; held still it
//   does nothing.
//   a cycle key (⌘Tab) presses at once and keeps the modifier down: slide to step through, a detent every 22 pt, left to go
//   back; at the edge of the screen it keeps stepping, so twenty apps are as reachable as three. Lifting lets go. A quick tap
//   is the quick ⌘Tab: back to the last app. The other keys are out of play meanwhile: the thumb passes over them.
//   the arrow key is four keys in one, each edge marked with its arrow: tap towards an edge for that arrow, hold to repeat; a tap in the
//   very middle is nobody's. Or drag, one step per 24 pt, keeping to the way it set off until it clearly turns; past 72 pt, or at the
//   screen's edge, it repeats, faster with distance. Tap and then drag does the same with ⇧. (The arithmetic: ArrowStroke, below.)
//   a repeating key (⌫, an arrow) fires at once and repeats while held. Nothing destructive repeats: never Esc, ⌃C or Return.
//   a modifier (⇧ ⌘ ⌥ ⌃) tapped holds for the next key; held a moment, it's pressed on its own instead, the way a lone ⇧ switches
//   a Chinese or Japanese input method between its own letters and English.
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
        UIImageView(image: UIImage(systemName: n, withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)))
    }
    private var cycle: Cycle?
    private var start = CGPoint.zero
    private var moved = false
    private var cancelled = false
    private var armed = false
    /// a modifier held long enough to be pressed on its own
    private var loneTimer: Timer?
    private var wentAlone = false
    private static let loneAfter = 0.45

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
    private var stroke = ArrowStroke(at: .zero)
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
        caption.font = .systemFont(ofSize: 10, weight: .regular)
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
        // the face and its small line sit together in the middle, however tall the key
        captionFits()
        modifierWordsFit()
        let hasCaption = !(caption.text ?? "").isEmpty
        let top = hasCaption ? (h - 36) / 2 : (h - 22) / 2
        glyph.frame = CGRect(x: 1, y: top, width: w - 2, height: 22)
        icon.frame = glyph.frame
        caption.frame = CGRect(x: 1, y: top + 23, width: w - 2, height: 13)
        // a key with room both ways (a big screen's) has its marks further in, where each edge's zone is
        let roomy = w >= 80 && h >= 80
        let mid = CGPoint(x: w / 2, y: h / 2), inX = roomy ? w * 0.2 : min(13, w * 0.2), inY = roomy ? h * 0.2 : min(11, h * 0.22)
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
        icon.tintColor = latched ? .black : Theme.mark
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
            icon.image = UIImage(systemName: String(f.dropFirst(3)), withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .regular))
            glyph.text = nil
        } else if f.hasPrefix("mark:"), let m = KeyMarks.image(String(f.dropFirst(5))) {
            icon.image = m
            glyph.text = nil
        } else {
            icon.image = nil
            glyph.text = f
            glyph.font = .systemFont(ofSize: Self.faceSize(f, on: .shown), weight: .regular)
        }
        caption.text = s.detail
        captionFits()
        setNeedsLayout()
    }

    /// Ctrl+Shift+Tab is three words where a Mac has three glyphs: a long small line goes narrower before it goes smaller.
    private func captionFits() {
        let regular = UIFont.systemFont(ofSize: 10, weight: .regular)
        guard RemoteHost.shown != .mac, let t = caption.text, bounds.width > 0,
              (t as NSString).size(withAttributes: [.font: regular]).width > bounds.width - 4 else { return caption.font = regular }
        caption.font = .systemFont(ofSize: 10, weight: .regular, width: .condensed)
    }

    /// Ctrl, Super, Alt, Shift side by side: one size for all four, the size the longest fits, so none reads smaller than the others.
    private func modifierWordsFit() {
        let h = RemoteHost.shown
        guard h != .mac, bounds.width > 0, slot?.glyph == nil, case .sticky? = slot?.action, glyph.text != nil else { return }
        // narrower letters before smaller ones: at arm's length the height is what reads
        func fit(_ width: UIFont.Width) -> UIFont {
            let widest = h.modifierOrder.map { (h.name($0) as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: 16, weight: .regular, width: width)]).width }.max() ?? 1
            return .systemFont(ofSize: min(16, floor(16 * (bounds.width - max(7, bounds.width * 0.12)) / widest)), weight: .regular, width: width)
        }
        let plain = fit(.standard)
        glyph.font = plain.pointSize >= 14 ? plain : fit(.condensed)
    }


    /// The shorter the text, the larger: a key has little room, so a long name reads small and a short one is worth choosing.
    private static func faceSize(_ f: String, on h: RemoteHost) -> CGFloat {
        if f.contains(where: { "⌘⌃⌥⇧".contains($0) }) { return 16 }     // a shortcut written out, not a letter on a keyboard
        // a PC's keys are words (Ctrl, Shift, Esc, PgUp): as large as fits, the way a Mac's glyphs are
        if h != .mac, f.count <= 6 { return f.count <= 2 ? 20 : 16 }
        return switch f.count {
        case ...2: 20
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
        wentAlone = false
        if case let .sticky(m) = s.action {
            loneTimer = Timer.scheduledTimer(withTimeInterval: Self.loneAfter, repeats: false) { [weak self] _ in self?.alone(m) }
        }
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
        case let .nextTerminalTab(forward, back):
            Haptics.tick()
            cycle = Cycle(hold: [], key: forward.key, forward: forward, back: back)
            Link.shared.send(.key(forward, down: nil))
            onCycle?(true)
        case let .chord(c, cycle: false) where Self.repeats(c):
            fire(c)
            startRepeat(c, after: 0.35, every: 0.08)
        case .arrows:
            stroke = ArrowStroke(at: p)
            arrowShift = ArrowStroke.shifted(now: CACurrentMediaTime(), lastTap: lastArrowEnd)
            arrowRepeated = false
            // the very middle: nothing until it moves
            guard let key = ArrowStroke.tapKey(p, in: bounds.size) else { return }
            Haptics.step()
            startRepeat(RemoteChord([], key), after: 0.35, every: 0.08)
        default: break
        }
    }

    private enum Resolved {
        case chord(RemoteChord, cycle: Bool)
        /// a terminal's own next and previous tab, stepped through like a cycle with nothing held
        case nextTerminalTab(RemoteChord, back: RemoteChord)
        case other(KeyAction)
        case arrows
    }

    private static let terminals: Set<String> = ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
                                                 "net.kovidgoyal.kitty", "org.alacritty", "com.github.wez.wezterm", "co.zeit.hyper"]
    /// Linux terminals whose tabs aren't Ctrl+Tab, by desktop file id or WM class. Windows Terminal takes Ctrl+Tab, as everything else there does
    private static let linuxTerminals: Set<String> = ["org.gnome.terminal", "gnome-terminal-server", "gnome-terminal", "org.gnome.ptyxis", "org.gnome.console",
                                                      "kgx", "com.gexperts.tilix", "tilix", "xfce4-terminal", "mate-terminal", "terminator"]

    /// Where the app in front keeps its tabs: ⌘⇧] in a Mac's terminals, Ctrl+PgDn in GNOME's and the like, Ctrl+Tab anywhere else.
    static func nextTab(on h: RemoteHost, front: String?) -> (forward: RemoteChord, back: RemoteChord)? {
        let app = (front ?? "").lowercased().replacingOccurrences(of: ".desktop", with: "")
        switch h {
        case .mac where terminals.contains(front ?? ""): return (RemoteChord([.command, .shift], "]"), RemoteChord([.command, .shift], "["))
        case .linux where linuxTerminals.contains(app): return (RemoteChord(.control, "PageDown"), RemoteChord(.control, "PageUp"))
        default: return nil
        }
    }

    private func resolved(_ a: KeyAction) -> Resolved {
        switch a {
        case let .chord(c, cycle): return .chord(c, cycle: cycle)
        case .arrows: return .arrows
        case .nextTab:
            if let t = Self.nextTab(on: .shown, front: Link.shared.front?.bundle) { return .nextTerminalTab(t.forward, back: t.back) }
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
        if !inside { stopRepeat(); stopLone() }
        press(inside)
    }

    override func touchesEnded(_ t: Set<UITouch>, with e: UIEvent?) {
        commit()
        stopRepeat()
        stopLone()
        press(false)
        guard let s = slot else { return }
        if wentAlone { wentAlone = false; return }
        if cycle != nil {
            endCycle()
            Sticky.shared.used()
            return
        }
        if case .arrows = s.action {
            var tapped = false
            if !moved, !arrowRepeated, let key = ArrowStroke.tapKey(start, in: bounds.size) {
                Link.shared.send(.key(RemoteChord([], key), down: nil))
                done()
                tapped = true
            }
            // only a tap that sent an arrow makes the next drag a ⇧ one
            lastArrowEnd = tapped ? CACurrentMediaTime() : 0
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
        stopLone()
        wentAlone = false
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

    /// Held: the modifier by itself, down and up, and not held for the next key.
    private func alone(_ m: RemoteModifiers) {
        loneTimer = nil
        guard armed, !cancelled else { return }
        wentAlone = true
        Haptics.grab()
        // already held on the Mac: letting it go is the press on its own. Another down and up would switch the input method back
        if Sticky.shared.held.isSuperset(of: m) {
            Sticky.shared.release(m)
        } else {
            Sticky.shared.release(m)
            Link.shared.send(.key(RemoteChord(m, ""), down: nil))
        }
        UIView.animate(withDuration: 0.12, animations: { self.backgroundColor = Theme.slabLatched }) { _ in
            guard self.wentAlone else { return self.refresh() }     // lifted meanwhile
            UIView.animate(withDuration: 0.2) { self.backgroundColor = Theme.slabPressed }
        }
    }

    private func stopLone() {
        loneTimer?.invalidate()
        loneTimer = nil
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
        // the thumb has run out of screen: at that edge, sliding towards it, it repeats as if it had gone on
        var edge = 0
        if let win = window {
            let x = convert(p, to: win).x, band = Self.edge * 0.6
            edge = x < band ? -1 : x > win.bounds.width - band ? 1 : 0
        }
        switch stroke.move(to: p, screenEdge: edge) {
        case let .repeating(key, every):
            if repeatKey?.key != key || abs(repeatRate - every) > 0.01 {
                stopRepeat()
                startRepeat(RemoteChord(arrowShift ? .shift : [], key), after: 0, every: every)
            }
        case let .step(key):
            stopRepeat()
            step(key)
        case .none:
            stopRepeat()
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

/// The arrow key's arithmetic, apart from the view, so it can be tested: which arrow a touch taps, and what a drag sends.
///
/// A drag keeps to its way: once it has taken a step, steps come only along that axis, and the other one follows the finger at each
/// step, so a thumb's arc never adds up to an arrow of its own (sliding right, it fired a Down, which in a shell swaps the line for
/// history). It changes axis only on a clear turn: 36 pt across since the last step, and more across than along. Then it starts again
/// from that step, as a new drag would: steps every 24 pt, a repeat past 72.
struct ArrowStroke: Equatable {
    static let step: CGFloat = 24
    /// past this along the way it goes (or at the screen's edge) the arrow repeats, faster with distance
    static let far: CGFloat = 72
    static let turn: CGFloat = 36
    /// a touch this near the middle both ways (a fraction of the key's width and height) taps nothing
    static let middle: CGFloat = 0.12
    /// a drag begun this soon after a tap adds ⇧
    static let shiftWithin = 0.3

    enum Move: Equatable { case none, step(String), repeating(String, every: Double) }

    /// The arrow towards the edge of the key under the thumb; nil in the very middle, where the four zones meet.
    static func tapKey(_ p: CGPoint, in size: CGSize) -> String? {
        let x = (p.x - size.width / 2) / max(size.width, 1), y = (p.y - size.height / 2) / max(size.height, 1)
        if abs(x) < middle && abs(y) < middle { return nil }
        return key(abs(x) > abs(y), abs(x) > abs(y) ? x : y)
    }

    static func shifted(now: Double, lastTap: Double) -> Bool { now - lastTap < shiftWithin }

    private static func key(_ horizontal: Bool, _ d: CGFloat) -> String {
        horizontal ? (d > 0 ? "Right" : "Left") : (d > 0 ? "Down" : "Up")
    }

    /// the axis it keeps to, once it has stepped: true across, false up and down
    private(set) var horizontal: Bool?
    /// where this run began: the touch, or the step a turn came from
    private var origin: CGPoint
    /// the next step comes 24 pt from here
    private var anchor: CGPoint
    /// the finger at the last step
    private var last: CGPoint

    init(at p: CGPoint) { origin = p; anchor = p; last = p }

    /// `screenEdge`: the finger is at the screen's left (-1) or right (1) edge.
    mutating func move(to p: CGPoint, screenEdge: Int = 0) -> Move {
        if let h = horizontal {
            let along = h ? p.x - last.x : p.y - last.y, across = h ? p.y - last.y : p.x - last.x
            if abs(across) >= Self.turn, abs(across) > abs(along) {
                horizontal = !h
                origin = last
                anchor = last
            }
        }
        let dx = p.x - anchor.x, dy = p.y - anchor.y
        let h = horizontal ?? (abs(dx) > abs(dy))
        let d = h ? dx : dy
        let run = h ? p.x - origin.x : p.y - origin.y
        var far = horizontal == nil ? hypot(p.x - origin.x, p.y - origin.y) : abs(run)
        if h, screenEdge != 0, abs(run) >= Self.step, (run > 0) == (screenEdge > 0) { far = max(far, 90) }
        if far > Self.far {
            horizontal = h
            return .repeating(Self.key(h, d != 0 ? d : run), every: max(0.03, 0.11 - Double(far - Self.far) * 0.001))
        }
        guard abs(d) >= Self.step else { return .none }
        horizontal = h
        if h {
            anchor.x += d > 0 ? Self.step : -Self.step
            anchor.y = p.y
        } else {
            anchor.y += d > 0 ? Self.step : -Self.step
            anchor.x = p.x
        }
        last = p
        return .step(Self.key(h, d))
    }
}
