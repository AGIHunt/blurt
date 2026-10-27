// A project's colour and key badge, the same wherever the island names a project in passing (the current-project
// chip, "Filed to …"): the hue comes from the project id, so it stays put across renames and machines. The inbox
// (Unassigned) is neutral grey.
import AppKit
import BlurtCore

enum ProjectLook {
    /// Hues that hold up on the island's black, distinct from each other and from the brand mint: no .systemTeal /
    /// .systemMint (they read as brand). The index is hashed from the id, so projects that had teal or mint changed
    /// colour once, in v0.8.
    static let palette: [NSColor] = [.systemBlue, .systemOrange, .systemGreen, .systemPurple, .systemPink, .systemIndigo,
                                     .systemBrown, .systemYellow]

    static func color(_ p: Project) -> NSColor {
        guard !p.isInbox else { return .systemGray }
        var h: UInt32 = 2166136261                       // FNV-1a: stable across launches, unlike hashValue
        for b in p.id.utf8 { h = (h ^ UInt32(b)) &* 16777619 }
        return palette[Int(h % UInt32(palette.count))]
    }

    static let badgeFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .bold)

    static func badgeSize(_ key: String, height: CGFloat = 16) -> NSSize {
        let w = (key as NSString).size(withAttributes: [.font: badgeFont]).width
        return NSSize(width: ceil(w) + 10, height: height)
    }

    /// The key on a rounded tile of the project's colour (dark ink on the light hues, white on the rest).
    static func drawBadge(_ key: String, color: NSColor, in r: NSRect) {
        let c = color.usingColorSpace(.sRGB) ?? color
        c.setFill()
        NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()
        let lum = 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
        let ink = lum > 0.6 ? NSColor(white: 0, alpha: 0.85) : NSColor.white
        let a = NSAttributedString(string: key, attributes: [.font: badgeFont, .foregroundColor: ink])
        let s = a.size()
        a.draw(at: NSPoint(x: r.midX - s.width / 2, y: r.midY - s.height / 2))
    }
}

/// A project's key badge as a view (the island's "Filed to …" line).
final class BadgeView: NSView {
    let text: String
    let color: NSColor
    init(text: String, color: NSColor) {
        self.text = text
        self.color = color
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirty: NSRect) { ProjectLook.drawBadge(text, color: color, in: bounds) }
}
