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

    /// A project's name in a menu (the status menu's Project ▸, Open Recent, Go, Move to Project): cut in the middle
    /// past 40 characters, "Customer Onboarding Redes…Q1 2027 Launch", so one long name doesn't widen the whole menu to
    /// 600 pt (dogfood 2026-11-21); the item's tooltip carries the whole name.
    static func menuTitle(_ name: String, limit: Int = 40) -> String {
        guard name.count > limit else { return name }
        let head = (limit - 1) * 3 / 5, tail = limit - 1 - head
        return name.prefix(head).trimmingCharacters(in: .whitespaces) + "…" + name.suffix(tail).trimmingCharacters(in: .whitespaces)
    }

    /// The whole name when the menu shows it cut, then the folder.
    static func menuTip(_ p: Project) -> String { menuTip(name: p.name, path: p.path) }
    static func menuTip(name: String, path: URL) -> String {
        let where_ = (path.path as NSString).abbreviatingWithTildeInPath
        return menuTitle(name) == name ? where_ : name + "\n" + where_
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
