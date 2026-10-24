// K8: an item's K3 state as a small ring (14 pt in lists, 18 pt in the detail, 1.5 pt line):
//   new         dashed ring (16 equal parts from 12 o'clock, butt ends), brand ink
//   todo        empty ring, secondary text colour        handed_off  ring + 4 pt centre dot, brand ink
//   in_progress ring + right half filled, brand ink         to_verify   filled disc with a "!" shape, attention amber
//   done        filled disc with a check, ok green          wontfix     ring + a 45° slash, tertiary text colour
//   discarded   ring + an ×, tertiary text colour
// Drawn, not glyphs: the "!", the check and the × are paths. Same geometry and colours as web/packages/ui (kinds.ts
// ringShapes, base.css .sring). The image carries the localized state (`state.<state>`) for VoiceOver.
import AppKit
import BlurtCore

enum StatusRing {
    static let states = Lifecycle.states

    /// brand ink (--brand-ink), attention (--attn), done (--ok): the generated BrandColor (assets/color/tokens.json)
    static let accent = BrandColor.ink
    static let attention = BrandColor.attn
    static let keep = BrandColor.ok
    /// the "!" on the attention disc and the check on the done disc
    static let attentionGlyph = BrandColor.onAttn
    static let keepGlyph = BrandColor.onOk

    static func color(_ state: String) -> NSColor {
        switch state {
        case "new", "handed_off", "in_progress": return accent
        case "to_verify": return attention
        case "done": return keep
        case "wontfix", "discarded": return .tertiaryLabelColor
        default: return .secondaryLabelColor
        }
    }

    /// A colour (not template) image; dynamic colours resolve when it draws, so light / dark both work.
    static func image(_ state: String, size: CGFloat) -> NSImage {
        let im = NSImage(size: NSSize(width: size, height: size), flipped: true) { r in
            draw(state, in: r)
            return true
        }
        im.accessibilityDescription = Loc.t("state.\(state)")
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
        case "new":
            // the ring from 12 o'clock, clockwise (y-down), in 16 equal parts: 8 dashes, 8 gaps
            let p = NSBezierPath()
            p.move(to: pt(c, c - R))
            p.appendArc(withCenter: pt(c, c), radius: R, startAngle: -90, endAngle: 270, clockwise: false)
            let dash = 2 * .pi * R / 16
            p.setLineDash([dash, dash], count: 2, phase: 0)
            p.lineWidth = lw
            p.lineCapStyle = .butt
            p.stroke()
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
            keepGlyph.set()
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
        case "discarded":
            stroke(ring)
            let a = c - 2.1 * u, b = c + 2.1 * u
            let p = NSBezierPath()
            p.move(to: pt(a, a))
            p.line(to: pt(b, b))
            p.move(to: pt(b, a))
            p.line(to: pt(a, b))
            stroke(p)
        default:
            stroke(ring)
        }
    }
}
