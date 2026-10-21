// K8: the processing state as a small ring (14 pt in lists, 18 pt in the detail, 1.5 pt line):
//   todo        empty ring, secondary text colour        handed_off  ring + 4 pt centre dot, accent
//   in_progress ring + right half filled, accent          to_verify   filled disc with a "!" shape, attention amber
//   done        filled disc with a check, green           wontfix     ring + a 45° slash, tertiary text colour
// Drawn, not glyphs: the "!" and the check are paths. The image carries the state's name for VoiceOver.
//
// G0 (docs/design/next-round.md "所有权、闸门和合并"): written by P4 so the packages compile against it; P6 owns this
// file and sets the final drawing.
import AppKit
import BlurtCore

enum StatusRing {
    static let states = ["todo", "handed_off", "in_progress", "to_verify", "done", "wontfix"]

    static func dyn(_ light: UInt32, _ dark: UInt32) -> NSColor {
        func c(_ h: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat(h >> 16 & 0xff) / 255, green: CGFloat(h >> 8 & 0xff) / 255, blue: CGFloat(h & 0xff) / 255, alpha: 1)
        }
        return NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? c(dark) : c(light) }
    }
    /// Brand coral (--accent)
    static let accent = dyn(0xFF5C3D, 0xFF7A5C)
    static let attention = dyn(0xE5A000, 0xFFC53D)
    static let keep = dyn(0x218358, 0x3DD68C)

    static func color(_ state: String) -> NSColor {
        switch state {
        case "handed_off", "in_progress": return accent
        case "to_verify": return attention
        case "done": return keep
        case "wontfix": return .tertiaryLabelColor
        default: return .secondaryLabelColor
        }
    }

    static func image(_ state: String, size: CGFloat) -> NSImage {
        let im = NSImage(size: NSSize(width: size, height: size), flipped: false) { r in
            draw(state, in: r)
            return true
        }
        im.accessibilityDescription = Loc.t("work.\(state)")
        return im
    }

    static func draw(_ state: String, in r: NSRect) {
        let lw: CGFloat = 1.5
        let ring = r.insetBy(dx: lw / 2 + 0.5, dy: lw / 2 + 0.5)
        let c = color(state)
        c.set()
        let circle = NSBezierPath(ovalIn: ring)
        circle.lineWidth = lw
        let mid = NSPoint(x: r.midX, y: r.midY), rad = ring.width / 2
        switch state {
        case "handed_off":
            circle.stroke()
            NSBezierPath(ovalIn: NSRect(x: mid.x - 2, y: mid.y - 2, width: 4, height: 4)).fill()
        case "in_progress":
            circle.stroke()
            let half = NSBezierPath()
            half.move(to: NSPoint(x: mid.x, y: mid.y + rad - lw))
            half.appendArc(withCenter: mid, radius: rad - lw, startAngle: 90, endAngle: -90, clockwise: true)
            half.close()
            half.fill()
        case "to_verify":
            NSBezierPath(ovalIn: ring.insetBy(dx: -lw / 2, dy: -lw / 2)).fill()
            NSColor.white.set()
            let w = max(1.4, r.width * 0.12), top = r.height * 0.24
            NSBezierPath(roundedRect: NSRect(x: mid.x - w / 2, y: mid.y - r.height * 0.05, width: w, height: top + r.height * 0.05),
                         xRadius: w / 2, yRadius: w / 2).fill()
            NSBezierPath(ovalIn: NSRect(x: mid.x - w * 0.6, y: mid.y - r.height * 0.27, width: w * 1.2, height: w * 1.2)).fill()
        case "done":
            NSBezierPath(ovalIn: ring.insetBy(dx: -lw / 2, dy: -lw / 2)).fill()
            NSColor.white.set()
            let p = NSBezierPath()
            p.move(to: NSPoint(x: r.minX + r.width * 0.29, y: r.minY + r.height * 0.5))
            p.line(to: NSPoint(x: r.minX + r.width * 0.44, y: r.minY + r.height * 0.34))
            p.line(to: NSPoint(x: r.minX + r.width * 0.72, y: r.minY + r.height * 0.66))
            p.lineWidth = max(1.4, r.width * 0.11)
            p.lineCapStyle = .round
            p.lineJoinStyle = .round
            p.stroke()
        case "wontfix":
            circle.stroke()
            let d = rad * 0.7071
            let p = NSBezierPath()
            p.move(to: NSPoint(x: mid.x - d, y: mid.y - d))
            p.line(to: NSPoint(x: mid.x + d, y: mid.y + d))
            p.lineWidth = lw
            p.stroke()
        default:
            circle.stroke()
        }
    }
}
