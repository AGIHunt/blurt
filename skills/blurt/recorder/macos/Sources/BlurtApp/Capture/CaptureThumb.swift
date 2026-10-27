// A capture as a small designed tile (v0.9), wherever a list shows captures outside the cards themselves — Recently
// Dragged Out's rows and the island menu's "Recently Dragged Out" submenu:
//   shot   the picture filling a rounded tile (aspect fill, like the cards overview), a 0.5 pt hairline round it — a
//          picture too wide or too tall for that (a toolbar, a sidebar) is shown whole on the tile's neutral surface
//   voice  a soft brand-tint tile (brand.tint: it is one of blurt's own captures) with the waveform mark in brand ink,
//          sized like the icons next to it, and the note's length under it when the tile is tall enough
// Drawn at draw time, so the dynamic colours follow the light / dark appearance of whatever shows it. It replaces the
// bare mic glyph scaled up to the tile (big, coarse, and unlike any other thumbnail in the app).
import AppKit
import BlurtCore

enum CaptureThumb {
    /// Draws `s` into `r` (a flipped context: NSView.isFlipped / NSImage(flipped: true)).
    static func draw(_ s: Shot, in r: NSRect, radius: CGFloat) {
        let shape = NSBezierPath(roundedRect: r.insetBy(dx: 0.25, dy: 0.25), xRadius: radius, yRadius: radius)
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        if s.kind == .shot, let cg = s.markedThumb ?? s.thumb {
            NSColor(white: 0.5, alpha: 0.2).setFill()
            r.fill()
            let iw = CGFloat(cg.width), ih = CGFloat(cg.height)
            // aspect fill, unless that would cut most of it (a toolbar, a sidebar): then whole (BlurtCore CardShape)
            let fill = CardShape.fills(picture: CGSize(width: iw, height: ih), box: r.size)
            let k = fill ? max(r.width / max(iw, 1), r.height / max(ih, 1)) : min(r.width / max(iw, 1), r.height / max(ih, 1))
            let sz = NSSize(width: iw * k, height: ih * k)
            NSImage(cgImage: cg, size: sz).draw(in: NSRect(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2,
                                                          width: sz.width, height: sz.height))
        } else {
            BrandColor.tint.setFill()
            r.fill()
            voiceMark(s, in: r)
        }
        NSGraphicsContext.restoreGraphicsState()
        NSColor.separatorColor.setStroke()
        shape.lineWidth = 0.5
        shape.stroke()
    }

    /// The waveform in brand ink, centred; with the length under it when there is room (a row's tile, not a menu's).
    private static func voiceMark(_ s: Shot, in r: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let side = (min(r.height * 0.42, 18)).rounded()
        let showLength = r.height >= 36 && (s.duration ?? 0) > 0
        let len = showLength ? NSAttributedString(string: Loc.duration(s.duration ?? 0), attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor]) : nil
        let gap: CGFloat = 2
        let total = side + (len.map { gap + $0.size().height } ?? 0)
        let top = (r.midY - total / 2).rounded()
        BlurtIcon.waveform.draw(in: ctx, rect: CGRect(x: r.midX - side / 2, y: top, width: side, height: side),
                                color: BrandColor.ink.cgColor, flipped: true, weight: 1.1)
        if let l = len {
            let w = l.size().width
            l.draw(at: NSPoint(x: (r.midX - w / 2).rounded(), y: top + side + gap))
        }
    }

    /// The tile as an image (menu items, the drag image), drawn when it is shown.
    static func image(_ s: Shot, size: NSSize, radius: CGFloat) -> NSImage {
        let im = NSImage(size: size, flipped: true) { r in
            draw(s, in: r, radius: radius)
            return true
        }
        im.accessibilityDescription = TakenPanel.title(s)
        return im
    }
}
