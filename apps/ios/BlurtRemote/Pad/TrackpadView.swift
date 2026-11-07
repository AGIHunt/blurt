// The glass: raw touches to PadEngine, what it says to the Mac. No gesture recognisers: they add delay, and they can't
// share touches the way a trackpad needs.
import BlurtRemoteKit
import UIKit

final class TrackpadView: UIView {
    let engine = PadEngine()
    var onHaptic: ((PadHaptic) -> Void)?
    var onViewEnd: (() -> Void)?
    /// the phone's sticky modifiers were used by a click: one-shot ones clear
    var onClick: (() -> Void)?

    private var ids: [ObjectIdentifier: Int] = [:]
    private var nextID = 0
    private var ticker: Timer?
    private var palms = Set<ObjectIdentifier>()
    /// the touch landed off the picture, where there's nothing to click
    private var offPicture = false
    private var dragOff = false
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

    override func touchesBegan(_ t: Set<UITouch>, with e: UIEvent?) {
        light(t.first, on: true)
        apply(engine.began(pads(t, new: true), at: CACurrentMediaTime()))
        startTicks()
    }

    override func touchesMoved(_ t: Set<UITouch>, with e: UIEvent?) {
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

    override func touchesEnded(_ t: Set<UITouch>, with e: UIEvent?) {
        let g = gone(t)
        if ids.isEmpty { light(nil, on: false) }
        if !g.isEmpty { apply(engine.ended(g, at: CACurrentMediaTime())) }
        startTicks()
    }

    override func touchesCancelled(_ t: Set<UITouch>, with e: UIEvent?) {
        let g = gone(t)
        if ids.isEmpty {
            light(nil, on: false)
            apply(engine.cancel())
        } else if !g.isEmpty {      // some of them: the rest of the gesture goes on, and must still end
            apply(engine.ended(g, at: CACurrentMediaTime()))
        }
    }

    func letGo() {
        ids = [:]
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
        for o in out {
            switch o {
            case let .move(x, y):
                ScreenStream.shared.bringPointerIntoView()
                link.pointer(.move(dx: x, dy: y))
                ScreenStream.shared.predict(dx: x, dy: y)
            case let .view(scale, dx, dy, at):
                ScreenStream.shared.change(scale: scale, dx: dx, dy: dy, at: at)
            case .viewEnd:
                ScreenStream.shared.gestureEnded()
                onViewEnd?()
            case let .pointAt(p):
                offPicture = !ScreenStream.shared.placePointer(at: p)
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
                let f: Float = Prefs.shared.reverseScroll ? -1 : 1
                link.pointer(.scroll(dx: x * f, dy: y * f, phase: p))
            case let .fling(x, y):
                let f: Float = Prefs.shared.reverseScroll ? -1 : 1
                link.pointer(.scrollFling(vx: x * f, vy: y * f))
            case .scrollStop: link.pointer(.scrollStop)
            case let .system(m): link.send(.system(m))
            case let .haptic(h): onHaptic?(h)
            }
        }
    }
}
