// The screen button, and with two or more displays on the computer, which one the picture shows (docs/design/remote.md §Several
// displays). No new control takes room: the screen button itself draws the arrangement, the display shown filled in.
//
//  • tap: the picture on and off, as always.
//  • press and slide sideways: the next display, or the one before, one per 36 pt, in the order they stand. Lift to show it. The
//    map comes up while sliding, over the keys and never over the picture, so the picture is in view the whole time.
//  • hold: the map stays up after lifting. Tap a display to show it, or Follow Pointer to have the picture follow the pointer from
//    display to display again (the default).
//  • a display chosen stays chosen, until Follow Pointer or until it's unplugged. The map says which; the button carries no badge for it.
import BlurtRemoteKit
import UIKit

/// What the picture shows: one display, or whichever the pointer is on.
enum DisplayChoice: Equatable {
    case follow
    case display(String)

    var id: String? { if case let .display(d) = self { d } else { nil } }
}

final class ScreenButton: UIControl {
    var onToggle: (() -> Void)?
    var onPick: ((DisplayChoice) -> Void)?
    /// where the map goes: the view it's put in, and its frame there (the keys' place; or one of this size beside the button)
    var mapPlace: ((CGSize) -> (UIView, CGRect)?)?

    private(set) var displays: [RemoteDisplay] = []
    private(set) var shown: String?
    private(set) var pinned: String?
    private var showing = false
    private var railed = false
    private let glyph = UIImageView()
    /// lit, in a row of icons: a key-shaped patch around the glyph, not the whole tall slot
    private let lit = UIView()

    private var start = CGPoint.zero
    private var moved = false
    private var hold: DispatchWorkItem?
    private var map: DisplayMap?
    private var catcher: UIView?
    /// the map was opened by holding still: it stays when the finger lifts
    private var sticky = false
    private var steps = 0

    static let step: CGFloat = 36
    static let slop: CGFloat = 12
    static let holdTime = 0.32

    var several: Bool { displays.count > 1 }
    private var current: DisplayChoice { pinned.map(DisplayChoice.display) ?? .follow }

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerCurve = .continuous
        glyph.contentMode = .center
        glyph.isUserInteractionEnabled = false
        lit.isUserInteractionEnabled = false
        lit.layer.cornerRadius = 9
        lit.layer.cornerCurve = .continuous
        addSubview(lit)
        addSubview(glyph)
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(displays: [RemoteDisplay], shown: String?, pinned: String?) {
        self.displays = displays
        self.shown = shown
        self.pinned = pinned
        map?.update(displays: displays, shown: shown, pinned: pinned)
        if !several { closeMap() }
        paint()
    }

    func paint(showing: Bool, railed: Bool) {
        self.showing = showing
        self.railed = railed
        paint()
    }

    private func paint() {
        // lit while it's on: a crossed-out eye over a live picture reads as off. A grey lift, not a modifier's white: white made it the
        // brightest thing on the screen, over the picture it's there to show
        let ink: UIColor = showing || railed ? Theme.mark : Theme.caption
        // on a rail it's a key and lights as one; among the top row's icons only the patch around the glyph does
        backgroundColor = railed ? (showing ? Theme.slabPressed : Theme.slab) : .clear
        lit.backgroundColor = showing && !railed ? Theme.slabPressed : .clear
        if several {
            glyph.image = Self.arrangement(displays, shown: showing ? shown : nil, ink: ink)
        } else {
            glyph.image = UIImage(systemName: "display", withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .regular))?
                .withTintColor(ink, renderingMode: .alwaysOriginal)
        }
        accessibilityLabel = showing ? String(localized: "Hide Screen") : String(localized: "Show Screen")
        let name = displays.first { $0.id == shown }?.name
        accessibilityValue = several ? [name, pinned == nil ? String(localized: "Follow Pointer") : nil].compactMap { $0 }.joined(separator: ", ") : nil
        accessibilityHint = several ? String(localized: "Hold to choose a display.") : nil
        accessibilityCustomActions = several ? displays.arranged.map { d in
            UIAccessibilityCustomAction(name: String(localized: "Show \(d.name)")) { [weak self] _ in self?.onPick?(.display(d.id)); return true }
        } + [UIAccessibilityCustomAction(name: String(localized: "Follow Pointer")) { [weak self] _ in self?.onPick?(.follow); return true }] : nil
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        glyph.frame = bounds
        // a little wider than a narrow slot: the neighbours' glyphs sit well inside theirs
        let w: CGFloat = several ? 44 : 40, h = min(bounds.height, 32)
        lit.frame = CGRect(x: bounds.midX - w / 2, y: bounds.midY - h / 2, width: w, height: h)
    }

    /// The displays as they stand, small, each on a foot so they read as screens: the one shown filled, the rest outlined.
    static func arrangement(_ displays: [RemoteDisplay], shown: String?, ink: UIColor) -> UIImage {
        let size = CGSize(width: 30, height: 21), foot: CGFloat = 4
        let map = RemoteDisplayMap.layout(displays, in: CGSize(width: size.width, height: size.height - foot), gap: 3, smallest: 7)
        return UIGraphicsImageRenderer(size: size).image { _ in
            ink.setStroke()
            ink.setFill()
            for d in displays {
                guard let r = map[d.id] else { continue }
                let p = UIBezierPath(roundedRect: r.insetBy(dx: 0.65, dy: 0.65), cornerRadius: 1)
                p.lineWidth = 1.3
                if d.id == shown { p.fill() } else { p.stroke() }
                // the foot, under the middle of each, unless another display stands there
                let footRect = CGRect(x: r.midX - 3.5, y: r.maxY, width: 7, height: foot)
                if map.contains(where: { $0.key != d.id && $0.value.intersects(footRect) }) { continue }
                UIBezierPath(rect: CGRect(x: r.midX - 0.65, y: r.maxY, width: 1.3, height: foot - 1.3)).fill()
                UIBezierPath(roundedRect: CGRect(x: r.midX - 3.5, y: r.maxY + foot - 1.4, width: 7, height: 1.4), cornerRadius: 0.7).fill()
            }
        }
    }

    // MARK: touches

    override func touchesBegan(_ t: Set<UITouch>, with e: UIEvent?) {
        guard let p = t.first?.location(in: self) else { return }
        start = p
        moved = false
        steps = 0
        sticky = false
        isHighlighted = true
        guard several else { return }
        let h = DispatchWorkItem { [weak self] in
            guard let self, !self.moved, self.map == nil else { return }
            self.sticky = true
            Haptics.grab()
            self.openMap(candidate: self.current)
        }
        hold = h
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdTime, execute: h)
    }

    override func touchesMoved(_ t: Set<UITouch>, with e: UIEvent?) {
        guard let touch = t.first else { return }
        let p = touch.location(in: self)
        let d = CGPoint(x: p.x - start.x, y: p.y - start.y)
        if !moved, hypot(d.x, d.y) > Self.slop { moved = true }
        guard several, moved else { return }
        hold?.cancel()
        if map == nil { openMap(candidate: shown.map(DisplayChoice.display) ?? current) }
        guard let map else { return }
        // over the map: what's under the finger. Elsewhere: steps sideways from the display shown
        let inMap = touch.location(in: map)
        if map.bounds.insetBy(dx: -10, dy: -10).contains(inMap) {
            if let c = map.choice(at: inMap) { map.candidate = c }
        } else {
            let n = Int((d.x / Self.step).rounded(.towardZero))
            if let s = displays.step(from: shown, by: n) { map.candidate = .display(s.id) }
        }
    }

    override func touchesEnded(_ t: Set<UITouch>, with e: UIEvent?) {
        hold?.cancel()
        isHighlighted = false
        if let map {
            if sticky, !moved { return }        // held still: it stays up, to be tapped
            let c = map.candidate
            closeMap()
            commit(c)
            return
        }
        guard let p = t.first?.location(in: self), bounds.insetBy(dx: -24, dy: -24).contains(p) else { return }
        onToggle?()
    }

    override func touchesCancelled(_ t: Set<UITouch>, with e: UIEvent?) {
        hold?.cancel()
        isHighlighted = false
        if !sticky { closeMap() }
    }

    /// A choice that changes something: another display, or following where it wasn't.
    private func commit(_ c: DisplayChoice?) {
        guard let c else { return }
        switch c {
        case .follow: if pinned == nil { return }
        case let .display(id): if id == pinned || (pinned == nil && id == shown && moved) { return }
        }
        Haptics.tick()
        onPick?(c)
    }

    #if DEBUG
    /// DisplayTest: held (nil), or slid `steps` along
    func pretendMap(steps: Int?) {
        guard several else { return }
        sticky = steps == nil
        moved = steps != nil
        openMap(candidate: steps.flatMap { n in displays.step(from: shown, by: n).map { .display($0.id) } } ?? current)
    }

    func pretendLift(commit c: Bool) {
        let choice = map?.candidate
        closeMap()
        if c { commit(choice) }
    }
    #endif

    // MARK: the map

    private func openMap(candidate: DisplayChoice) {
        guard map == nil else { return }
        let m = DisplayMap()
        m.update(displays: displays, shown: shown, pinned: pinned)
        m.candidate = candidate
        m.onPick = { [weak self] c in
            self?.closeMap()
            self?.commit(c)
        }
        guard let (host, frame) = mapPlace?(DisplayMap.floating(for: displays)) else { return }
        // held open: a tap anywhere else puts it away and does nothing else
        let c = UIControl(frame: host.bounds)
        c.addAction(UIAction { [weak self] _ in self?.closeMap() }, for: .touchDown)
        host.addSubview(c)
        catcher = c
        m.frame = frame
        host.addSubview(m)
        map = m
        m.alpha = 0
        m.transform = CGAffineTransform(scaleX: 0.96, y: 0.96)
        UIView.animate(withDuration: 0.14) {
            m.alpha = 1
            m.transform = .identity
        }
        UIAccessibility.post(notification: .layoutChanged, argument: m)
    }

    func closeMap() {
        catcher?.removeFromSuperview()
        catcher = nil
        guard let m = map else { return }
        map = nil
        UIView.animate(withDuration: 0.12, animations: { m.alpha = 0 }, completion: { _ in m.removeFromSuperview() })
    }
}

/// The arrangement drawn to scale, each display named, and Follow Pointer under it.
final class DisplayMap: UIView {
    var onPick: ((DisplayChoice) -> Void)?
    var candidate: DisplayChoice? {
        didSet {
            guard candidate != oldValue else { return }
            if oldValue != nil { Haptics.step() }
            paint()
        }
    }
    private var displays: [RemoteDisplay] = []
    private var shown: String?
    private var pinned: String?
    private var tiles: [String: (view: UIView, label: UILabel)] = [:]
    private let follow = UIView()
    private let followLabel = UILabel()
    private let followIcon = UIImageView()
    private var spots: [String: CGRect] = [:]

    static let pad: CGFloat = 10
    static let followHeight: CGFloat = 44
    /// With no keys to take the place of (landscape, keys put away): about a hand's width, as tall as the arrangement needs.
    static func floating(for displays: [RemoteDisplay]) -> CGSize {
        let all = displays.map(\.frame).reduce(CGRect.null) { $0.union($1) }
        let w: CGFloat = 260, area = w - pad * 2
        let tiles = all.isNull || all.width <= 0 ? 90 : min(130, max(64, area * all.height / all.width + 8))
        return CGSize(width: w, height: pad * 3 + tiles + followHeight)
    }
    /// the arrangement's room inside the map
    private var mapArea: CGSize {
        CGSize(width: max(1, bounds.width - Self.pad * 2), height: max(1, bounds.height - Self.pad * 3 - Self.followHeight))
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(white: 0.085, alpha: 1)
        layer.cornerRadius = Theme.radius
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.borderColor = Theme.hairline.cgColor
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.6
        layer.shadowRadius = 18
        layer.shadowOffset = CGSize(width: 0, height: 6)
        follow.layer.cornerRadius = Theme.keyRadius
        follow.layer.cornerCurve = .continuous
        followLabel.text = String(localized: "Follow Pointer")
        followLabel.font = .systemFont(ofSize: 14, weight: .medium)
        followIcon.image = UIImage(systemName: "cursorarrow.motionlines", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .medium))
        followIcon.contentMode = .center
        follow.addSubview(followIcon)
        follow.addSubview(followLabel)
        follow.isUserInteractionEnabled = false
        addSubview(follow)
        // VoiceOver chooses through the screen button's actions
        accessibilityElementsHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(displays: [RemoteDisplay], shown: String?, pinned: String?) {
        self.displays = displays
        self.shown = shown
        self.pinned = pinned
        let ids = Set(displays.map(\.id))
        for (id, t) in tiles where !ids.contains(id) { t.view.removeFromSuperview(); tiles[id] = nil }
        for d in displays where tiles[d.id] == nil {
            let v = UIView()
            v.layer.cornerRadius = 5
            v.layer.cornerCurve = .continuous
            v.isUserInteractionEnabled = false
            let l = UILabel()
            l.font = .systemFont(ofSize: 13, weight: .medium)
            l.textAlignment = .center
            l.numberOfLines = 2
            l.adjustsFontSizeToFitWidth = true
            l.minimumScaleFactor = 0.8
            l.lineBreakMode = .byTruncatingTail
            v.addSubview(l)
            addSubview(v)
            tiles[d.id] = (v, l)
        }
        for d in displays { tiles[d.id]?.label.text = Self.short(d.name) }
        setNeedsLayout()
        paint()
    }

    /// A display's name as people say it: "Built-in Retina Display" is the built-in one, a monitor goes by its model.
    static func short(_ name: String) -> String {
        name.hasPrefix("Built-in") ? String(localized: "Built-in") : name.replacingOccurrences(of: " Display", with: "")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        spots = RemoteDisplayMap.layout(displays, in: mapArea, gap: 8, smallest: 34)
        let o = CGPoint(x: Self.pad, y: Self.pad)
        for (id, t) in tiles {
            guard let r = spots[id] else { continue }
            t.view.frame = r.offsetBy(dx: o.x, dy: o.y)
            t.label.frame = t.view.bounds.insetBy(dx: 4, dy: 3)
            t.label.isHidden = t.view.bounds.width < 34 || t.view.bounds.height < 20
        }
        follow.frame = CGRect(x: Self.pad, y: Self.pad * 2 + mapArea.height, width: mapArea.width, height: Self.followHeight)
        let w = ceil(followLabel.intrinsicContentSize.width), iconW: CGFloat = 20
        let x = (follow.bounds.width - w - iconW - 6) / 2
        followIcon.frame = CGRect(x: x, y: 0, width: iconW, height: follow.bounds.height)
        followLabel.frame = CGRect(x: x + iconW + 6, y: 0, width: w, height: follow.bounds.height)
    }

    /// Lit: what the picture shows (the display; Follow Pointer when it follows). Outlined: where the finger would take it.
    private func paint() {
        for d in displays {
            guard let t = tiles[d.id] else { continue }
            let lit = d.id == shown
            t.view.backgroundColor = lit ? Theme.slabLatched : Theme.slab
            t.label.textColor = lit ? .black : Theme.mark
            let aimed = candidate == .display(d.id)
            t.view.layer.borderWidth = aimed ? 2 : 1
            t.view.layer.borderColor = (aimed ? Theme.mark : Theme.edge).cgColor
            t.view.accessibilityLabel = d.name
        }
        let following = pinned == nil
        follow.backgroundColor = following ? Theme.slabLatched : Theme.slab
        followLabel.textColor = following ? .black : Theme.mark
        followIcon.tintColor = following ? .black : Theme.caption
        let aimed = candidate == .follow
        follow.layer.borderWidth = aimed ? 2 : 1
        follow.layer.borderColor = (aimed ? Theme.mark : Theme.edge).cgColor
    }

    func choice(at p: CGPoint) -> DisplayChoice? {
        if follow.frame.insetBy(dx: -4, dy: -6).contains(p) { return .follow }
        let inMap = CGPoint(x: p.x - Self.pad, y: p.y - Self.pad)
        return RemoteDisplayMap.hit(inMap, in: spots, reach: 16).map(DisplayChoice.display)
    }

    override func touchesEnded(_ t: Set<UITouch>, with e: UIEvent?) {
        guard let p = t.first?.location(in: self), let c = choice(at: p) else { return }
        onPick?(c)
    }

}
