// K8: the processing state as a small ring (14 pt in lists, 18 pt in the detail, 1.5 pt line):
//   todo        empty ring, secondary text colour        handed_off  ring + 4 pt centre dot, accent
//   in_progress ring + right half filled, accent          to_verify   filled disc with a "!" shape, attention amber
//   done        filled disc with a check, green           wontfix     ring + a 45° slash, tertiary text colour
// Drawn, not glyphs: the "!" and the check are paths. Same geometry and colours as web/packages/ui (kinds.ts
// ringShapes, base.css .sring). The image carries the localized state (`work.<state>`) for VoiceOver.
import AppKit
import BlurtCore

enum StatusRing {
    static let states = ["todo", "handed_off", "in_progress", "to_verify", "done", "wontfix"]

    /// Brand coral (--accent), attention (--warn), keep (--keep): tokens.css, light / dark
    static let accent = KindStyle.dynamic(KindStyle.rgb(0xF55B3E), KindStyle.rgb(0xFF7A5C))
    static let attention = KindStyle.dynamic(KindStyle.rgb(0xB86E00), KindStyle.rgb(0xF5A524))
    static let keep = KindStyle.dynamic(KindStyle.rgb(0x15965F), KindStyle.rgb(0x2B9466))
    /// the "!" on the attention disc: white on light amber, deep brown on the dark theme's brighter amber
    static let attentionGlyph = KindStyle.dynamic(.white, KindStyle.rgb(0x2A1A00))

    static func color(_ state: String) -> NSColor {
        switch state {
        case "handed_off", "in_progress": return accent
        case "to_verify": return attention
        case "done": return keep
        case "wontfix": return .tertiaryLabelColor
        default: return .secondaryLabelColor
        }
    }

    /// A colour (not template) image; dynamic colours resolve when it draws, so light / dark both work.
    static func image(_ state: String, size: CGFloat) -> NSImage {
        let im = NSImage(size: NSSize(width: size, height: size), flipped: true) { r in
            draw(state, in: r)
            return true
        }
        im.accessibilityDescription = Loc.t("work.\(state)")
        return im
    }

    /// Draws in a flipped (y-down) rect, exactly the web geometry for `r.width`.
    static func draw(_ state: String, in r: NSRect) {
        let size = r.width, c = size / 2, u = size / 14, lw: CGFloat = 1.5
        let R = c - 0.75 - 0.5
        let o = NSPoint(x: r.minX, y: r.minY)
        func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: o.x + x, y: o.y + y) }
        func disc(_ x: CGFloat, _ y: CGFloat, _ rad: CGFloat) -> NSBezierPath {
            NSBezierPath(ovalIn: NSRect(x: o.x + x - rad, y: o.y + y - rad, width: rad * 2, height: rad * 2))
        }
        func stroke(_ p: NSBezierPath) {
            p.lineWidth = lw
            p.lineCapStyle = .round
            p.lineJoinStyle = .round
            p.stroke()
        }
        color(state).set()
        let ring = disc(c, c, R)
        switch state {
        case "handed_off":
            stroke(ring)
            disc(c, c, 2 * u).fill()
        case "in_progress":
            stroke(ring)
            let ri = R - 1.75 * u
            let half = NSBezierPath()
            half.move(to: pt(c, c - ri))
            // y-down: from the top through the right side to the bottom
            half.appendArc(withCenter: pt(c, c), radius: ri, startAngle: -90, endAngle: 90, clockwise: false)
            half.close()
            half.fill()
        case "to_verify":
            disc(c, c, R + 0.75).fill()
            attentionGlyph.set()
            let bar = NSBezierPath()
            bar.move(to: pt(c, c - 3 * u))
            bar.line(to: pt(c, c + 0.6 * u))
            stroke(bar)
            disc(c, c + 2.85 * u, 0.95 * u).fill()
        case "done":
            disc(c, c, R + 0.75).fill()
            NSColor.white.set()
            let p = NSBezierPath()
            p.move(to: pt(c - 2.9 * u, c + 0.1 * u))
            p.line(to: pt(c - 0.9 * u, c + 2 * u))
            p.line(to: pt(c + 3 * u, c - 2.2 * u))
            stroke(p)
        case "wontfix":
            stroke(ring)
            let d = R * 0.7071
            let p = NSBezierPath()
            p.move(to: pt(c - d, c + d))
            p.line(to: pt(c + d, c - d))
            stroke(p)
        default:
            stroke(ring)
        }
    }
}
