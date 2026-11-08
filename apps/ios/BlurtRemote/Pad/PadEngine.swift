// The trackpad's rules, without UIKit: touches and time in, pointer actions out, so every gesture can be tested as a plain
// sequence (BlurtRemoteTests/PadEngineTests).
//
//   one finger   move · tap = click · tap, tap = double click · tap then press and move = drag; lifting during a drag
//                leaves the button down for `dragGrace`, so a long drag can take a new stroke
//   `touchMode`  with the Mac's screen showing, the glass is the screen: a tap or a press lands under the finger and a drag follows it.
//                Moving a finger is still the pointer, for what's too small to hit
//   hold still   `holdTime` (the phone taps back), then move = drag, the same press-and-drag as any mouse; or lift = right click
//   the edge     one finger along the side by the thumb = scroll, for when there's only the one thumb
//   two fingers  move = scroll what's under the pointer, as on the Mac's trackpad, both ways; tap = right click; pinch = zoom the app
//                on the Mac. With the screen showing, a pinch zooms the view on the phone instead, and the scroll is under the fingers.
//                Two fingers moving together never stay exactly the same distance apart: a scroll stays a scroll until they clearly pinch.
//                The zoomed view follows the pointer, so it never needs moving by hand
//   three        swipe left/right = change desktop, up = all windows, down = this app's windows
//
// A touch that stops a coasting scroll is only that: no click. A thumb resting still never clicks (`tapTime`).
import BlurtRemoteKit
import CoreGraphics
import Foundation

struct PadTouch {
    let id: Int
    var x: CGFloat
    var y: CGFloat
}

enum PadOutput: Equatable {
    case move(Float, Float)
    case click(RemoteMouseButton)
    case button(RemoteMouseButton, down: Bool)
    case scroll(Float, Float, RemoteScrollPhase)
    case fling(Float, Float)
    case scrollStop
    case system(RemoteSystemMove)
    case haptic(PadHaptic)
    /// the Mac's screen is showing: the view on the phone, this much closer and moved this far since the last one, about this point
    case view(scale: CGFloat, dx: CGFloat, dy: CGFloat, at: CGPoint)
    /// the pointer goes under this point on the pad, ready for what comes next
    case pointAt(CGPoint)
    /// and follows the finger, with the button down
    case dragTo(CGPoint)
    case viewEnd
}

enum PadHaptic { case tap, grab, release, step }

final class PadEngine {
    static let slop: CGFloat = 6
    static let tapTime = 0.22
    static let doubleWindow = 0.30
    static let doubleReach: CGFloat = 44
    static let holdTime = 0.40
    static let dragGrace = 0.45
    /// held longer than this and lifted, it was a resting thumb, not a right click
    static let holdLimit = 1.2
    static let coastTime = 2.0
    static let pinchStep: CGFloat = 36
    static let swipeTrip: CGFloat = 40
    /// how far fingers moving the view must come apart or together before it's a pinch
    static let pinchRatio: CGFloat = 0.14

    private enum State {
        case idle
        case one(start: CGPoint, last: CGPoint, at: Double)     // may yet be a tap
        case moving(last: CGPoint)
        case second(start: CGPoint, at: Double)                 // pressed right after a tap: a double click or a drag
        case dragging(last: CGPoint)
        case held(start: CGPoint, at: Double)                   // held still: right click or scroll
        case scrolling(last: CGPoint, two: Bool)
        case two(start: CGPoint, spread: CGFloat, at: Double)   // undecided
        case pinch(spread: CGFloat)
        // fingers on the view; spread 0 with one of them lifted. Not zooming: only moving, until they've come apart from `from`
        case view(spread: CGFloat, center: CGPoint, from: CGFloat, zooming: Bool)
        case three(start: CGPoint)
        case spent                                              // a gesture finished; wait for all fingers to lift
    }

    private var state = State.idle
    private var touches: [Int: CGPoint] = [:]
    private var lastTap: (at: Double, point: CGPoint)?
    /// the Mac is coasting a scroll until about then
    private var coastUntil: Double?
    private var dragLetGo: Double?
    private var lastMoveAt: Double = 0
    private var samples: [(t: Double, dx: CGFloat, dy: CGFloat)] = []
    /// how far apart two scrolling fingers started
    private var scrollSpread: CGFloat = 0

    var curve = RemotePointerCurve()
    var pinchZoomsView = false
    var touchMode = false
    /// where one finger scrolls, across the pad; nil = nowhere
    var scrollEdge: ClosedRange<CGFloat>?
    var scrollGain: CGFloat = 2.4

    private var centroid: CGPoint {
        let n = CGFloat(max(touches.count, 1))
        let s = touches.values.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: s.x / n, y: s.y / n)
    }

    private var spread: CGFloat {
        let p = Array(touches.values)
        return p.count >= 2 ? hypot(p[0].x - p[1].x, p[0].y - p[1].y) : 0
    }

    private func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

    func began(_ ts: [PadTouch], at now: Double) -> [PadOutput] {
        guard !ts.isEmpty else { return [] }    // a palm, filtered out by the view
        var out: [PadOutput] = []
        for t in ts { touches[t.id] = CGPoint(x: t.x, y: t.y) }
        if let c = coastUntil {
            coastUntil = nil
            if now < c { out.append(.scrollStop); state = .spent }
        }

        switch touches.count {
        case 1:
            guard case .idle = state else { break }
            let p = centroid
            if let g = dragLetGo, now - g < Self.dragGrace {
                dragLetGo = nil
                state = .dragging(last: p)
            } else if let l = lastTap, now - l.at < Self.doubleWindow, dist(l.point, p) < Self.doubleReach {
                state = .second(start: p, at: now)
            } else {
                state = .one(start: p, last: p, at: now)
            }
        case 2:
            switch state {
            case .idle, .one, .moving, .second, .held:
                state = .two(start: centroid, spread: spread, at: now)
            case .dragging:
                state = .dragging(last: centroid)   // a second finger joining a drag changes nothing
            case let .scrolling(_, two):
                state = .scrolling(last: centroid, two: two)
            case let .view(_, _, _, zooming):
                state = .view(spread: spread, center: centroid, from: spread, zooming: zooming)
            default: break
            }
        default:
            switch state {
            case .dragging: state = .dragging(last: centroid)
            case .spent: break
            case .scrolling:
                // the first two fingers moved a little before the third landed: it was three all along
                out += [.scroll(0, 0, .ended)]
                state = .three(start: centroid)
            case .view:
                out.append(.viewEnd)
                state = .three(start: centroid)
            default: state = .three(start: centroid)
            }
        }
        return out
    }

    func moved(_ ts: [PadTouch], at now: Double) -> [PadOutput] {
        for t in ts where touches[t.id] != nil { touches[t.id] = CGPoint(x: t.x, y: t.y) }
        let p = centroid
        var out: [PadOutput] = []
        switch state {
        case let .one(start, _, _):
            if dist(p, start) > Self.slop {
                if let e = scrollEdge, e.contains(start.x), abs(p.y - start.y) > abs(p.x - start.x) {
                    samples = []
                    out.append(.scroll(0, 0, .began))
                    state = .scrolling(last: p, two: false)
                } else {
                    lastMoveAt = now
                    state = .moving(last: p)
                }
            }
        case let .moving(last):
            out += pointer(from: last, to: p, now)
            state = .moving(last: p)
        case let .second(start, _):
            if dist(p, start) > Self.slop {
                lastTap = nil
                lastMoveAt = now
                if touchMode { out.append(.pointAt(start)) }
                out += [.button(.left, down: true), .haptic(.grab)]
                state = .dragging(last: p)
            }
        case let .dragging(last):
            if touchMode {
                if let k = touches.keys.min(), let f = touches[k] { out.append(.dragTo(f)) }     // the finger that started it
            } else {
                out += pointer(from: last, to: p, now)
            }
            state = .dragging(last: p)
        case let .held(start, _):
            if dist(p, start) > Self.slop {
                lastTap = nil
                lastMoveAt = now
                out.append(.button(.left, down: true))
                state = .dragging(last: p)
            }
        case let .scrolling(last, two):
            // a scroll that turns into a clear pinch: the picture zooms from here, and the scroll ends without coasting
            // (by a third and 36 pt both, so fingers drifting over a long scroll don't count)
            if two, pinchZoomsView, touches.count >= 2, scrollSpread > 0, abs(spread - scrollSpread) > max(Self.pinchStep, scrollSpread / 3) {
                out.append(.scroll(0, 0, .ended))
                state = .view(spread: spread, center: p, from: spread, zooming: true)
                break
            }
            let dx = p.x - last.x, dy = p.y - last.y
            samples.append((now, dx, dy))
            samples.removeAll { now - $0.t > 0.09 }
            out.append(.scroll(Float(dx * scrollGain), Float(dy * scrollGain), .changed))
            state = .scrolling(last: p, two: two)
        case let .two(start, s, _):
            guard touches.count >= 2 else { break }
            if pinchZoomsView, abs(spread - s) > Self.pinchStep * 0.35 {
                state = .view(spread: spread, center: p, from: spread, zooming: true)
            } else if !pinchZoomsView, abs(spread - s) > Self.pinchStep * 0.7 {
                state = .pinch(spread: spread)
            } else if dist(p, start) > Self.slop {
                // zoomed or not, two fingers scroll the Mac, as on its own trackpad: what's under the pointer scrolls. With the picture
                // showing, that's what's under the fingers, the same as a tap
                samples = []
                scrollSpread = spread
                if touchMode { out.append(.pointAt(start)) }
                out.append(.scroll(0, 0, .began))
                state = .scrolling(last: p, two: true)
            }
        case let .pinch(s):
            guard touches.count >= 2 else { break }
            if abs(spread - s) > Self.pinchStep {
                out += [.system(spread > s ? .zoomIn : .zoomOut), .haptic(.step)]
                state = .pinch(spread: spread)
            }
        case let .view(s, c, from, zooming):
            guard touches.count >= 2, s > 0, spread > 0 else { break }
            let now = zooming || abs(spread / from - 1) > Self.pinchRatio
            // the moment it becomes a pinch, it starts from here: nothing jumps
            out.append(.view(scale: zooming ? spread / s : 1, dx: p.x - c.x, dy: p.y - c.y, at: p))
            state = .view(spread: spread, center: p, from: from, zooming: now)
        case let .three(start):
            let dx = p.x - start.x, dy = p.y - start.y
            if touches.count >= 3, max(abs(dx), abs(dy)) > Self.swipeTrip {
                let m: RemoteSystemMove = abs(dx) > abs(dy) ? (dx > 0 ? .spaceLeft : .spaceRight) : (dy < 0 ? .missionControl : .appExpose)
                out += [.system(m), .haptic(.grab)]
                state = .spent
            }
        default: break
        }
        return out
    }

    private func pointer(from a: CGPoint, to b: CGPoint, _ now: Double) -> [PadOutput] {
        let dx = Float(b.x - a.x), dy = Float(b.y - a.y)
        let dt = Float(now - lastMoveAt)
        lastMoveAt = now
        if dx == 0, dy == 0 { return [] }
        let (x, y) = curve.apply(dx: dx, dy: dy, dt: dt)
        return [.move(x, y)]
    }

    func ended(_ ids: [Int], at now: Double) -> [PadOutput] {
        for i in ids { touches[i] = nil }
        var out: [PadOutput] = []
        guard touches.isEmpty else {
            // a finger of two lifted: what's left of the gesture stays with the fingers still down
            switch state {
            case let .scrolling(_, two):
                scrollSpread = 0
                state = .scrolling(last: centroid, two: two)
            case .dragging: state = .dragging(last: centroid)
            case let .view(_, _, _, zooming): state = .view(spread: 0, center: centroid, from: 1, zooming: zooming)
            default: break
            }
            return out
        }
        switch state {
        case let .one(start, _, at):
            if now - at < Self.tapTime {
                if touchMode { out.append(.pointAt(start)) }
                out += [.click(.left), .haptic(.tap)]
                lastTap = (now, start)
            }
        case let .second(start, _):
            out += [.click(.left), .haptic(.tap)]
            lastTap = nil
            _ = start
        case .dragging:
            if touchMode {
                out += [.button(.left, down: false), .haptic(.release)]     // no new stroke to wait for: it goes where the finger goes
            } else {
                dragLetGo = now
            }
        case let .held(_, at):
            if now - at < Self.holdLimit { out += [.click(.right), .haptic(.tap)] }
        case .scrolling:
            out.append(.scroll(0, 0, .ended))
            if let v = releaseVelocity() {
                out.append(.fling(Float(v.dx * scrollGain), Float(v.dy * scrollGain)))
                coastUntil = now + Self.coastTime
            }
        case let .two(start, _, at):
            if now - at < Self.tapTime + 0.1 {
                if touchMode { out.append(.pointAt(start)) }
                out += [.click(.right), .haptic(.tap)]
            }
        case .view:
            out.append(.viewEnd)
        default: break
        }
        state = .idle
        return out
    }

    private func releaseVelocity() -> CGVector? {
        guard let first = samples.first, let last = samples.last, last.t > first.t, samples.count >= 2 else { return nil }
        let span = max(last.t - first.t, 0.016)
        let dx = samples.reduce(0) { $0 + $1.dx }, dy = samples.reduce(0) { $0 + $1.dy }
        let v = CGVector(dx: dx / span, dy: dy / span)
        return hypot(v.dx, v.dy) > 120 ? v : nil
    }

    /// Time passing, called about ten times a second while anything is down or pending.
    func tick(at now: Double) -> [PadOutput] {
        var out: [PadOutput] = []
        if case let .one(start, _, at) = state, now - at >= Self.holdTime {
            state = .held(start: start, at: now)
            if touchMode { out.append(.pointAt(start)) }    // the pointer comes to the finger as the phone taps back
            out.append(.haptic(.grab))
        }
        if let g = dragLetGo, now - g >= Self.dragGrace {
            dragLetGo = nil
            out += [.button(.left, down: false), .haptic(.release)]
        }
        return out
    }

    var needsTicks: Bool {
        if dragLetGo != nil { return true }
        if case .one = state { return true }
        return false
    }

    /// Everything ends: the app left the screen, or a system gesture took the touches.
    func cancel() -> [PadOutput] {
        var out: [PadOutput] = []
        switch state {
        case .dragging: out.append(.button(.left, down: false))
        case .scrolling: out.append(.scroll(0, 0, .ended))
        case .view: out.append(.viewEnd)
        default: break
        }
        if dragLetGo != nil { out.append(.button(.left, down: false)); dragLetGo = nil }
        touches = [:]
        state = .idle
        lastTap = nil
        return out
    }
}
