// BlurtCore/TextImage.swift: a line drawn as AppKit draws it on an opaque ground (font smoothing on), so a layer-built
// island button keeps its semibold weight — a CATextLayer (no smoothing) came out about as light as regular.
import AppKit
import XCTest
@testable import BlurtCore

final class TextImageTests: XCTestCase {
    func ink(_ text: String, _ w: NSFont.Weight, smoothed: Bool = true) -> Int {
        let f = NSFont.systemFont(ofSize: 12.5, weight: w) as CTFont
        guard let l = TextImage.line(text, font: f, color: CGColor(gray: 1, alpha: 1), scale: 2, smoothed: smoothed) else { return 0 }
        return TextImage.ink(l.image)
    }

    /// AppKit's own draw of the same line on black: the weight the island's drawn buttons had.
    func appKitInk(_ text: String, _ w: NSFont.Weight) -> Int {
        let a = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12.5, weight: w), .foregroundColor: NSColor.white])
        let sz = a.size()
        let pw = Int(ceil(sz.width + 2) * 2), ph = Int(ceil(sz.height + 2) * 2)
        let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: pw * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: pw, height: ph))
        ctx.scaleBy(x: 2, y: 2)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        a.draw(at: NSPoint(x: 1, y: 1))
        NSGraphicsContext.restoreGraphicsState()
        let px = ctx.data!.bindMemory(to: UInt8.self, capacity: pw * ph * 4)
        var n = 0
        for i in stride(from: 0, to: pw * ph * 4, by: 4) { n += Int(px[i]) }
        return n / 255
    }

    func testASemiboldTitleKeepsAppKitsWeight() {
        for t in ["Show in Finder", "在访达中显示", "Undo"] {
            let smooth = ink(t, .semibold), flat = ink(t, .semibold, smoothed: false), regular = ink(t, .regular)
            let appKit = appKitInk(t, .semibold)
            XCTAssertEqual(Double(smooth), Double(appKit), accuracy: Double(appKit) * 0.04, "\(t): as heavy as AppKit's draw")
            XCTAssertGreaterThan(Double(smooth), Double(flat) * 1.12, "\(t): heavier than an unsmoothed (CATextLayer) line")
            XCTAssertGreaterThan(smooth, regular, "\(t): semibold reads heavier than regular")
        }
    }

    func testTheLineIsInItsColourAndSizedInPoints() {
        let f = NSFont.systemFont(ofSize: 12.5, weight: .semibold) as CTFont
        let l = TextImage.line("Undo", font: f, color: CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1), scale: 2)!
        XCTAssertEqual(CGFloat(l.image.width), l.size.width * 2)
        XCTAssertEqual(l.size.width, ceil(("Undo" as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12.5, weight: .semibold)]).width) + 1, accuracy: 1)
        XCTAssertNil(TextImage.line("", font: f, color: CGColor(gray: 1, alpha: 1), scale: 2))
    }
}
