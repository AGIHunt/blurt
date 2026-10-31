// One line of text as a picture, drawn the way AppKit draws text on an opaque background (BlurtApp Capture/Island/
// IslandContent.swift IslandButton's title). A CATextLayer can't do that: it draws into a transparent layer, where
// macOS turns font smoothing off, and smoothing is what gives light text on a dark ground its weight — the island's
// semibold titles came out about 20 % lighter than the draw(_:) button they replaced (the review measured "Show in
// Finder" at 12.5 pt: 1393 px of ink drawn, 1101 through a CATextLayer, 1092 drawn regular).
//
// So the line is drawn white on opaque black with smoothing on, and that coverage becomes the picture's alpha in the
// text's colour: the same ink as AppKit's, on whatever is under it (the brand gradient, a fill), composited as a
// whole — so a layer-built button keeps its weight and never paints in pieces.
import CoreGraphics
import CoreText
import Foundation

public enum TextImage {
    public struct Line {
        public var image: CGImage
        /// In points (the picture is `scale` times as many pixels).
        public var size: CGSize
        /// From the picture's top, in points: the baseline, and the first and last rows that carry ink (BA-60).
        public var baseline: CGFloat = 0
        public var inkTop: CGFloat = 0
        public var inkBottom: CGFloat = 0
        /// Han, kana or hangul in it: those glyphs sit in their own em box, centred as drawn (not on the baseline).
        public var ideographic = false
        /// From the picture's top: the font's cap height above the baseline.
        public var capTop: CGFloat = 0

        /// The height, from the picture's top, to centre in a control (BA-60: "完成" sat 1 pt low in the recording's
        /// Finish, centred by its typographic box, whose CJK fallback font hangs further below the baseline). Latin:
        /// between the baseline and the cap height — descenders and lowercase don't move it (for SF that is about the
        /// typographic box's own middle, so Latin titles stay where they were). Ideographic text: the middle of its ink.
        public var opticalMid: CGFloat {
            if ideographic, inkBottom > inkTop { return (inkTop + inkBottom) / 2 }
            return capTop < baseline ? (capTop + baseline) / 2 : size.height / 2
        }

        /// The picture's y (top) that puts its optical middle on `mid` (pixel-aligned at `scale`).
        public func top(centredOn mid: CGFloat, scale: CGFloat) -> CGFloat {
            ((mid - opticalMid) * max(1, scale)).rounded() / max(1, scale)
        }
    }

    /// Han, kana or hangul in `text`.
    public static func isIdeographic(_ text: String) -> Bool {
        text.unicodeScalars.contains { s in
            switch s.value {
            case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0x20000...0x2FA1F: return true
            default: return false
            }
        }
    }

    /// `text` in `font` and `color`, `scale` pixels a point; nil for an empty string.
    public static func line(_ text: String, font: CTFont, color: CGColor, scale: CGFloat, smoothed: Bool = true) -> Line? {
        guard !text.isEmpty, scale > 0 else { return nil }
        let white = CGColor(gray: 1, alpha: 1)
        let a = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): white,
        ])
        let ctLine = CTLineCreateWithAttributedString(a)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(ctLine, &ascent, &descent, &leading))
        let size = CGSize(width: ceil(width) + 1, height: ceil(ascent + descent))
        let pw = Int(size.width * scale), ph = Int(size.height * scale)
        guard pw > 0, ph > 0,
              let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: pw * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: pw, height: ph))
        ctx.scaleBy(x: scale, y: scale)
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)
        ctx.setAllowsFontSmoothing(smoothed)
        ctx.setShouldSmoothFonts(smoothed)
        ctx.textPosition = CGPoint(x: 0, y: descent)
        CTLineDraw(ctLine, ctx)
        // the coverage (white on black) becomes the alpha, in the text's colour (premultiplied)
        guard let data = ctx.data else { return nil }
        let px = data.bindMemory(to: UInt8.self, capacity: pw * ph * 4)
        let rgb = (color.converted(to: CGColorSpaceCreateDeviceRGB(), intent: .defaultIntent, options: nil) ?? color).components ?? [1, 1, 1, 1]
        let (r, g, b) = rgb.count >= 3 ? (rgb[0], rgb[1], rgb[2]) : (rgb[0], rgb[0], rgb[0])
        let alpha = color.alpha
        // the rows with ink (coverage over a quarter: the anti-aliased fringe doesn't move the middle)
        var first = -1, last = -1
        for row in 0..<ph {
            var hit = false
            for col in 0..<pw where px[(row * pw + col) * 4] > 64 { hit = true; break }
            if hit { if first < 0 { first = row }; last = row }
        }
        for i in stride(from: 0, to: pw * ph * 4, by: 4) {
            let cov = CGFloat(px[i]) / 255 * alpha
            px[i] = UInt8((r * cov * 255).rounded())
            px[i + 1] = UInt8((g * cov * 255).rounded())
            px[i + 2] = UInt8((b * cov * 255).rounded())
            px[i + 3] = UInt8((cov * 255).rounded())
        }
        guard let img = ctx.makeImage() else { return nil }
        var line = Line(image: img, size: size)
        // the bitmap's first row is the picture's top (CGBitmapContext memory runs top-down)
        line.baseline = size.height - descent
        if first >= 0 {
            line.inkTop = CGFloat(first) / scale
            line.inkBottom = CGFloat(last + 1) / scale
        }
        line.ideographic = isIdeographic(text)
        line.capTop = line.baseline - CTFontGetCapHeight(font)
        return line
    }

    /// The ink a picture carries (the sum of its alpha, in whole pixels): tests compare weights with it.
    public static func ink(_ img: CGImage) -> Int {
        let w = img.width, h = img.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return 0 }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        let px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var n = 0
        for i in stride(from: 3, to: w * h * 4, by: 4) { n += Int(px[i]) }
        return n / 255
    }
}
