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
        for i in stride(from: 0, to: pw * ph * 4, by: 4) {
            let cov = CGFloat(px[i]) / 255 * alpha
            px[i] = UInt8((r * cov * 255).rounded())
            px[i + 1] = UInt8((g * cov * 255).rounded())
            px[i + 2] = UInt8((b * cov * 255).rounded())
            px[i + 3] = UInt8((cov * 255).rounded())
        }
        guard let img = ctx.makeImage() else { return nil }
        return Line(image: img, size: size)
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
