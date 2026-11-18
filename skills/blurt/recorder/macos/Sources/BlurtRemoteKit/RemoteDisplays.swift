// Several displays (docs/design/remote.md §Several displays, remote-protocol.md §Displays): what both ends agree on, as plain arithmetic.
// The order they're stepped through, which one the pointer is on, when a pointer that crossed over has really gone, and the
// arrangement drawn small, to scale, for the phone's map.
import CoreGraphics
import Foundation

public extension RemoteDisplay {
    /// in the desktop's points, top-left origin
    var frame: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    var middle: CGPoint { CGPoint(x: x + width / 2, y: y + height / 2) }
}

public extension Array where Element == RemoteDisplay {
    /// Left to right by their middles, as they stand in the computer's arrangement (top first where two are centred alike): the order a
    /// step goes in.
    var arranged: [RemoteDisplay] {
        sorted { a, b in
            let ax = a.middle.x.rounded(), bx = b.middle.x.rounded()
            if ax != bx { return ax < bx }
            return a.y != b.y ? a.y < b.y : a.id < b.id
        }
    }

    /// The display a point is on; nil in a gap between them.
    func at(_ p: CGPoint) -> RemoteDisplay? { first { $0.frame.contains(p) } }

    /// The one after `id` in arrangement order, `by` steps (negative goes back), wrapping round. The first one when `id` isn't here.
    func step(from id: String?, by n: Int) -> RemoteDisplay? {
        let a = arranged
        guard !a.isEmpty else { return nil }
        guard let i = a.firstIndex(where: { $0.id == id }) else { return a.first }
        let c = a.count
        return a[((i + n) % c + c) % c]
    }
}

/// Following the pointer from display to display. A pointer on the edge, or flicked across a corner, mustn't make the picture flip back
/// and forth: it changes once the pointer has stayed on the other display for `dwell`, or gone `depth` points into it.
public struct RemoteDisplayFollow: Sendable {
    public static let dwell = 0.15
    public static let depth: CGFloat = 20

    public private(set) var candidate: String?
    private var since = 0.0

    public init() {}

    /// Each tick: the display to change to now, or nil to stay.
    public mutating func update(shown: String?, pointer p: CGPoint, displays: [RemoteDisplay], now: Double) -> String? {
        guard let d = displays.at(p) else { return nil }     // between displays: nothing has changed yet
        guard d.id != shown else { candidate = nil; return nil }
        if candidate != d.id {
            candidate = d.id
            since = now
        }
        let f = d.frame
        let inside = Swift.min(p.x - f.minX, f.maxX - p.x, p.y - f.minY, f.maxY - p.y)
        // the shown display gone from the list: no reason to wait
        let gone = shown.map { s in !displays.contains { $0.id == s } } ?? true
        guard gone || now - since >= Self.dwell || inside >= Self.depth else { return nil }
        candidate = nil
        return d.id
    }

    public mutating func reset() { candidate = nil }
}

/// The arrangement drawn to scale in a box: the phone's map. Every display stays big enough to hit.
public enum RemoteDisplayMap {
    /// `box` in points; `gap` between displays that touch, so they read as separate screens; at least `smallest` on the short side.
    public static func layout(_ displays: [RemoteDisplay], in box: CGSize, gap: CGFloat = 4, smallest: CGFloat = 22) -> [String: CGRect] {
        guard !displays.isEmpty, box.width > 0, box.height > 0 else { return [:] }
        let all = displays.map(\.frame).reduce(CGRect.null) { $0.union($1) }
        guard all.width > 0, all.height > 0 else { return [:] }
        let k = Swift.min(box.width / all.width, box.height / all.height)
        let w = all.width * k, h = all.height * k
        let ox = (box.width - w) / 2, oy = (box.height - h) / 2
        var out: [String: CGRect] = [:]
        for d in displays {
            var r = CGRect(x: ox + (d.x - all.minX) * k, y: oy + (d.y - all.minY) * k, width: d.width * k, height: d.height * k)
            r = r.insetBy(dx: Swift.min(gap / 2, r.width / 4), dy: Swift.min(gap / 2, r.height / 4))
            // a small display next to a big one: grown about its middle, so it's still a target
            if Swift.min(r.width, r.height) < smallest {
                let g = smallest / Swift.max(1, Swift.min(r.width, r.height))
                r = CGRect(x: r.midX - r.width * g / 2, y: r.midY - r.height * g / 2, width: r.width * g, height: r.height * g)
            }
            out[d.id] = r
        }
        return out
    }

    /// The display under a point of the map, or the nearest one to it within `reach`.
    public static func hit(_ p: CGPoint, in map: [String: CGRect], reach: CGFloat = 24) -> String? {
        if let (id, _) = map.first(where: { $0.value.contains(p) }) { return id }
        let near = map.map { (id: $0.key, d: distance(p, $0.value)) }.min { $0.d < $1.d }
        return near.flatMap { $0.d <= reach ? $0.id : nil }
    }

    private static func distance(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        let dx = Swift.max(r.minX - p.x, 0, p.x - r.maxX), dy = Swift.max(r.minY - p.y, 0, p.y - r.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }
}
