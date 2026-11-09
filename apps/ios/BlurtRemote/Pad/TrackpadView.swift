// The glass: raw touches to PadEngine, what it says to the Mac. No gesture recognisers for fingers: they add delay, and they can't
// share touches the way a trackpad needs.
//
// An iPad also has a pointer (a mouse or a trackpad) and a Pencil, and those aren't fingers. With the picture showing, the pointer over
// it is the computer's pointer, where it is, and its buttons and scrolling are the computer's; the iPad's own pointer hides over the
// pad, since the computer's is drawn. The Pencil is the finger of Touch Mode with the precision of a pen: down is the button down where
// it lands, a stroke drags, and hovering (iPad Pro) moves the pointer to the tip. With no picture the pointer moves the computer's
// relatively, a mouse's own speed, not a thumb's curve: it already has the iPad's acceleration.
import BlurtRemoteKit
import UIKit

final class TrackpadView: UIView, UIPointerInteractionDelegate {
    let engine = PadEngine()
    var onHaptic: ((PadHaptic) -> Void)?
    var onViewEnd: (() -> Void)?
    /// the phone's sticky modifiers were used by a click: one-shot ones clear
    var onClick: (() -> Void)?
    /// false: the trackpad between the thumbs (big screens). It never puts the pointer under a touch, and a pinch zooms the stage's view
    var isStage = true
    /// for the thumb pad: the stage's middle, in the stage's coordinates, for a pinch to zoom about
    var stageMiddle: (() -> CGPoint)?
    /// the picture is showing on the stage
    var showing = false
    /// the pointer, the Pencil: what they hold down, and where they were
    private var pointerTouches: [ObjectIdentifier: (button: RemoteMouseButton, last: CGPoint, placed: Bool)] = [:]
    private var lastHover: CGPoint?
    private var lastHoverSent = 0.0

    private var ids: [ObjectIdentifier: Int] = [:]
    private var nextID = 0
    private var ticker: Timer?
    private var palms = Set<ObjectIdentifier>()
    /// the touch landed off the picture, where there's nothing to click
    private var offPicture = false
    private var dragOff = false
    /// this scroll began where the pointer was just put
    private var scrollPlaced = false
    /// and that was off the picture: it goes nowhere
    private var scrollOff = false
    /// a soft light under the finger: says the glass feels it
    private let glow = CAGradientLayer()

    private func light(_ t: UITouch?, on: Bool) {
        guard !engine.pinchZoomsView else { return }    // on the picture it would only be in the way
        CATransaction.begin()
        CATransaction.setAnimationDuration(on ? 0.05 : 0.3)
        if let p = t?.location(in: self), on {
            CATransaction.setDisableActions(glow.opacity > 0)
            glow.position = p
        }
        glow.opacity = on ? 1 : 0
        CATransaction.commit()
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = Theme.glass
        clipsToBounds = true
        glow.type = .radial
        glow.colors = [UIColor(white: 1, alpha: 0.13).cgColor, UIColor(white: 1, alpha: 0).cgColor]
        glow.startPoint = CGPoint(x: 0.5, y: 0.5)
        glow.endPoint = CGPoint(x: 1, y: 1)
        glow.frame = CGRect(x: 0, y: 0, width: 150, height: 150)
        glow.opacity = 0
        layer.addSublayer(glow)
        layer.cornerRadius = 22
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.borderColor = Theme.hairline.cgColor
        isAccessibilityElement = true
        accessibilityLabel = String(localized: "Trackpad")

        let hover = UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:)))
        addGestureRecognizer(hover)
        // two fingers on a trackpad, a mouse's wheel: scroll events only, never a touch
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(scrolled(_:)))
        scroll.allowedScrollTypesMask = .all
        scroll.allowedTouchTypes = []
        addGestureRecognizer(scroll)
        addInteraction(UIPointerInteraction(delegate: self))
    }

    /// The computer's pointer is the one that counts here.
    func pointerInteraction(_ i: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? { .hidden() }

    private var mouseGain: Float { 1.5 * Float(Prefs.shared.pointerSpeed) }

    @objc private func hovered(_ g: UIHoverGestureRecognizer) {
        let p = g.location(in: self)
        switch g.state {
        case .began, .changed:
            let pencil = g.zOffset > 0
            if showing && isStage {
                // where the pointer or the Pencil's tip is, the computer's pointer is: no more than 60 times a second
                let now = CACurrentMediaTime()
                guard now - lastHoverSent >= 1.0 / 60 else { return }
                lastHoverSent = now
                _ = ScreenStream.shared.placePointer(at: p)
            } else if !pencil, let l = lastHover {
                let dx = Float(p.x - l.x) * mouseGain, dy = Float(p.y - l.y) * mouseGain
                if dx != 0 || dy != 0 { Link.shared.pointer(.move(dx: dx, dy: dy)); ScreenStream.shared.predict(dx: dx, dy: dy) }
            }
            lastHover = p
        default:
            lastHover = nil
        }
    }

    private var scrollLast = CGPoint.zero

    @objc private func scrolled(_ g: UIPanGestureRecognizer) {
        let f: CGFloat = Prefs.shared.reverseScroll ? -1 : 1
        let gain = CGFloat(Prefs.shared.scrollSpeed) * f
        let t = g.translation(in: self)
        switch g.state {
        case .began:
            scrollLast = t
            Link.shared.pointer(.scroll(dx: 0, dy: 0, phase: .began))
        case .changed:
            let dx = Float((t.x - scrollLast.x) * gain), dy = Float((t.y - scrollLast.y) * gain)
            scrollLast = t
            Link.shared.pointer(.scroll(dx: dx, dy: dy, phase: .changed))
        case .ended:
            Link.shared.pointer(.scroll(dx: 0, dy: 0, phase: .ended))
            let v = g.velocity(in: self)
            if hypot(v.x, v.y) > 120 { Link.shared.pointer(.scrollFling(vx: Float(v.x * gain), vy: Float(v.y * gain))) }
        case .cancelled, .failed:
            Link.shared.pointer(.scroll(dx: 0, dy: 0, phase: .ended))
        default: break
        }
    }

    /// A pointer's click, or the Pencil on the picture: a button, not a finger.
    private func isButton(_ t: UITouch) -> Bool {
        t.type == .indirectPointer || (t.type == .pencil && isStage && showing && engine.touchMode)
    }

    private func buttonsBegan(_ ts: [UITouch], _ e: UIEvent?) {
        for t in ts {
            let p = t.preciseLocation(in: self)
            let b: RemoteMouseButton = e?.buttonMask.contains(.secondary) == true ? .right : .left
            var placed = true
            if showing && isStage { placed = ScreenStream.shared.placePointer(at: p) }
            pointerTouches[ObjectIdentifier(t)] = (b, p, placed)
            guard placed else { continue }      // off the picture: nothing to press
            Link.shared.send(.button(b, down: true))
        }
    }

    private func buttonsMoved(_ ts: [UITouch]) {
        for t in ts {
            guard var s = pointerTouches[ObjectIdentifier(t)], s.placed else { continue }
            let p = t.preciseLocation(in: self)
            if showing && isStage {
                ScreenStream.shared.dragPointer(to: p)
            } else {
                let dx = Float(p.x - s.last.x) * mouseGain, dy = Float(p.y - s.last.y) * mouseGain
                Link.shared.pointer(.move(dx: dx, dy: dy))
                ScreenStream.shared.predict(dx: dx, dy: dy)
            }
            s.last = p
            pointerTouches[ObjectIdentifier(t)] = s
        }
    }

    private func buttonsEnded(_ ts: [UITouch]) {
        for t in ts {
            guard let s = pointerTouches.removeValue(forKey: ObjectIdentifier(t)), s.placed else { continue }
            ScreenStream.shared.finishDrag()
            Link.shared.send(.button(s.button, down: false))
            onClick?()
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    private func pads(_ ts: Set<UITouch>, new: Bool) -> [PadTouch] {
        ts.compactMap { t in
            let k = ObjectIdentifier(t)
            if new {
                // a resting palm or the side of a thumb
                if t.majorRadius > 44 { palms.insert(k); return nil }
                ids[k] = nextID
                nextID += 1
            }
            guard let id = ids[k] else { return nil }
            let p = t.preciseLocation(in: self)
            return PadTouch(id: id, x: p.x, y: p.y)
        }
    }

    override func touchesBegan(_ all: Set<UITouch>, with e: UIEvent?) {
        let buttons = all.filter(isButton)
        if !buttons.isEmpty { buttonsBegan(Array(buttons), e) }
        let t = all.subtracting(buttons)
        guard !t.isEmpty else { return }
        light(t.first, on: true)
        apply(engine.began(pads(t, new: true), at: CACurrentMediaTime()))
        startTicks()
    }

    override func touchesMoved(_ all: Set<UITouch>, with e: UIEvent?) {
        let t = all.filter { pointerTouches[ObjectIdentifier($0)] == nil }
        buttonsMoved(Array(all.subtracting(t)))
        guard !t.isEmpty else { return }
        light(t.first, on: true)
        apply(engine.moved(pads(t, new: false), at: CACurrentMediaTime()))
    }

    private func gone(_ t: Set<UITouch>) -> [Int] {
        t.compactMap { x in
            let k = ObjectIdentifier(x)
            palms.remove(k)
            return ids.removeValue(forKey: k)
        }
    }

    override func touchesEnded(_ all: Set<UITouch>, with e: UIEvent?) {
        let t = all.filter { pointerTouches[ObjectIdentifier($0)] == nil }
        buttonsEnded(Array(all.subtracting(t)))
        guard !t.isEmpty else { return }
        let g = gone(t)
        if ids.isEmpty { light(nil, on: false) }
        if !g.isEmpty { apply(engine.ended(g, at: CACurrentMediaTime())) }
        startTicks()
    }

    override func touchesCancelled(_ all: Set<UITouch>, with e: UIEvent?) {
        let t = all.filter { pointerTouches[ObjectIdentifier($0)] == nil }
        buttonsEnded(Array(all.subtracting(t)))
        guard !t.isEmpty else { return }
        let g = gone(t)
        if ids.isEmpty {
            light(nil, on: false)
            apply(engine.cancel())
        } else if !g.isEmpty {      // some of them: the rest of the gesture goes on, and must still end
            apply(engine.ended(g, at: CACurrentMediaTime()))
        }
    }

    /// Everything held ends cleanly: the window is changing size (a turn, the Duo opening), or the app is leaving.
    func letGo() {
        ids = [:]
        palms = []
        light(nil, on: false)
        for (_, s) in pointerTouches where s.placed { Link.shared.send(.button(s.button, down: false)) }
        pointerTouches = [:]
        apply(engine.cancel())
    }

    private func startTicks() {
        guard ticker == nil, engine.needsTicks else { return }
        ticker = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] t in
            guard let self else { return t.invalidate() }
            self.apply(self.engine.tick(at: CACurrentMediaTime()))
            if !self.engine.needsTicks { t.invalidate(); self.ticker = nil }
        }
    }

    private func apply(_ out: [PadOutput]) {
        let link = Link.shared
        var placed = false
        for o in out {
            switch o {
            case let .move(x, y):
                ScreenStream.shared.bringPointerIntoView()
                link.pointer(.move(dx: x, dy: y))
                ScreenStream.shared.predict(dx: x, dy: y)
            case let .view(scale, dx, dy, at):
                if isStage {
                    ScreenStream.shared.change(scale: scale, dx: dx, dy: dy, at: at)
                } else if let m = stageMiddle?() {
                    // between the thumbs: closer or further, about the middle of what's in view; moving is the pointer's job
                    ScreenStream.shared.change(scale: scale, dx: 0, dy: 0, at: m)
                }
            case .viewEnd:
                ScreenStream.shared.gestureEnded()
                onViewEnd?()
            case let .pointAt(p):
                offPicture = !ScreenStream.shared.placePointer(at: p)
                placed = true
            case let .dragTo(p):
                if !dragOff { ScreenStream.shared.dragPointer(to: p) }
            case let .click(b):
                if offPicture, engine.touchMode { continue }    // a double tap off the picture is two of nothing
                ScreenStream.shared.bringPointerIntoView()
                link.send(.button(b, down: true))
                link.send(.button(b, down: false))
                onClick?()
            case let .button(b, down):
                if down {
                    dragOff = offPicture && engine.touchMode
                    if dragOff { continue }
                    ScreenStream.shared.bringPointerIntoView()
                } else {
                    if dragOff { dragOff = false; continue }
                    ScreenStream.shared.finishDrag()
                }
                link.send(down ? .dragBegin : .button(b, down: false))
                if !down { onClick?() }
            case let .scroll(x, y, p):
                if p == .began {
                    // a scroll that starts where the pointer was just put: in order behind it, and not at all off the picture
                    scrollPlaced = placed
                    scrollOff = placed && offPicture && engine.touchMode
                }
                if scrollOff { continue }
                let f: Float = Prefs.shared.reverseScroll ? -1 : 1
                link.pointer(.scroll(dx: x * f, dy: y * f, phase: p), inOrder: scrollPlaced)
            case let .fling(x, y):
                if scrollOff { continue }
                let f: Float = Prefs.shared.reverseScroll ? -1 : 1
                link.pointer(.scrollFling(vx: x * f, vy: y * f), inOrder: scrollPlaced)
            case .scrollStop: link.pointer(.scrollStop)
            case let .system(m): link.send(.system(m))
            case let .haptic(h): onHaptic?(h)
            }
        }
    }
}
