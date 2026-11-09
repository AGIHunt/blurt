// Icons SF Symbols doesn't have. Each is what the key looks like on the computer (Alt+Tab is the same row of apps): ⌘Tab's row of apps with one picked out, a tab bar with the tab
// you'd land on filled in, selected text. Template images, so they take a key's colours like any symbol.
import SwiftUI
import UIKit

enum KeyMarks {
    static func image(_ name: String) -> UIImage? {
        switch name {
        case "apps": apps
        case "tabNext": tabs(next: true)
        case "tabPrevious": tabs(next: false)
        case "tabNew": tabNew
        case "tabClose": tabClose
        case "selectAll": selectAll
        case "win": win
        default: nil
        }
    }

    private static func draw(_ w: CGFloat, _ h: CGFloat, _ body: (CGContext) -> Void) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: w, height: h)).image { body($0.cgContext) }.withRenderingMode(.alwaysTemplate)
    }

    /// The Mac's switcher: a row of apps, one of them picked out.
    private static let apps = draw(36, 18) { c in
        c.setFillColor(UIColor.black.cgColor)
        for x in [0.5, 12.5, 22.5, 30] as [CGFloat] {
            c.addPath(UIBezierPath(roundedRect: CGRect(x: x, y: 6, width: 5.5, height: 6), cornerRadius: 1.6).cgPath)
        }
        c.fillPath()
        c.setStrokeColor(UIColor.black.cgColor)
        c.setLineWidth(1.5)
        c.addPath(UIBezierPath(roundedRect: CGRect(x: 8.75, y: 2.75, width: 13, height: 12.5), cornerRadius: 3.4).cgPath)
        c.strokePath()
    }

    /// A window with a tab bar: all the keys about tabs look like one family.
    private static func window(_ c: CGContext) {
        c.setStrokeColor(UIColor.black.cgColor)
        c.setFillColor(UIColor.black.cgColor)
        c.setLineWidth(1.4)
        c.addPath(UIBezierPath(roundedRect: CGRect(x: 1.2, y: 1.2, width: 21.6, height: 15.6), cornerRadius: 3).cgPath)
        c.move(to: CGPoint(x: 1, y: 6.5)); c.addLine(to: CGPoint(x: 23, y: 6.5))
        c.strokePath()
        c.setLineWidth(1.5)
        c.setLineCap(.round)
        c.setLineJoin(.round)
    }

    private static func tabs(next: Bool) -> UIImage {
        draw(24, 18) { c in
            c.saveGState()
            c.addPath(UIBezierPath(roundedRect: CGRect(x: 1.2, y: 1.2, width: 21.6, height: 15.6), cornerRadius: 3).cgPath)
            c.clip()
            c.setFillColor(UIColor.black.cgColor)
            c.fill(CGRect(x: next ? 12 : 0, y: 0, width: 12, height: 6.5))
            c.restoreGState()
            window(c)
            // which way, in the page under the tabs
            let x: CGFloat = 12, y: CGFloat = 11.6, d: CGFloat = next ? 1 : -1
            c.move(to: CGPoint(x: x - 1.5 * d, y: y - 2.6)); c.addLine(to: CGPoint(x: x + 1.5 * d, y: y)); c.addLine(to: CGPoint(x: x - 1.5 * d, y: y + 2.6))
            c.strokePath()
        }
    }

    private static let tabNew = draw(24, 18) { c in
        window(c)
        c.move(to: CGPoint(x: 12, y: 9)); c.addLine(to: CGPoint(x: 12, y: 14.4))
        c.move(to: CGPoint(x: 9.3, y: 11.7)); c.addLine(to: CGPoint(x: 14.7, y: 11.7))
        c.strokePath()
    }

    private static let tabClose = draw(24, 18) { c in
        window(c)
        c.move(to: CGPoint(x: 9.9, y: 9.6)); c.addLine(to: CGPoint(x: 14.1, y: 13.8))
        c.move(to: CGPoint(x: 14.1, y: 9.6)); c.addLine(to: CGPoint(x: 9.9, y: 13.8))
        c.strokePath()
    }

    /// The Windows key, as ⊞ writes it: a square of four panes, drawn in the same line as the window marks. Not the logo: no colour, no slant,
    /// no gaps between filled panes.
    private static let win = draw(18, 18) { c in
        c.setStrokeColor(UIColor.black.cgColor)
        c.setLineWidth(1.5)
        c.addPath(UIBezierPath(roundedRect: CGRect(x: 1.75, y: 1.75, width: 14.5, height: 14.5), cornerRadius: 3).cgPath)
        c.move(to: CGPoint(x: 9, y: 2)); c.addLine(to: CGPoint(x: 9, y: 16))
        c.move(to: CGPoint(x: 2, y: 9)); c.addLine(to: CGPoint(x: 16, y: 9))
        c.strokePath()
    }

    /// Text selected: the lines between the two handles a phone shows.
    private static let selectAll = draw(26, 20) { c in
        c.setStrokeColor(UIColor.black.cgColor)
        c.setFillColor(UIColor.black.cgColor)
        c.setLineCap(.round)
        c.setLineWidth(1.6)
        for (y, x0, x1) in [(5.0, 7.0, 21.0), (10.0, 5.0, 21.0), (15.0, 5.0, 16.0)] as [(CGFloat, CGFloat, CGFloat)] {
            c.move(to: CGPoint(x: x0, y: y)); c.addLine(to: CGPoint(x: x1, y: y))
        }
        c.strokePath()
        c.setLineWidth(1.3)
        c.move(to: CGPoint(x: 3.2, y: 4)); c.addLine(to: CGPoint(x: 3.2, y: 12))
        c.move(to: CGPoint(x: 22.8, y: 8)); c.addLine(to: CGPoint(x: 22.8, y: 16))
        c.strokePath()
        c.fillEllipse(in: CGRect(x: 1, y: 0.8, width: 4.4, height: 4.4))
        c.fillEllipse(in: CGRect(x: 20.6, y: 14.8, width: 4.4, height: 4.4))
    }
}

/// A key's face in the sheets: the same icon or text as on the key.
struct KeyFaceView: View {
    let face: String
    var font: Font = .subheadline

    var body: some View {
        if face.hasPrefix("sf:") {
            Image(systemName: String(face.dropFirst(3))).font(font)
        } else if face.hasPrefix("mark:"), let i = KeyMarks.image(String(face.dropFirst(5))) {
            Image(uiImage: i).renderingMode(.template)
        } else {
            Text(face).font(font).lineLimit(1).minimumScaleFactor(0.5)
        }
    }
}
