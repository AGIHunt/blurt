// Brand concepts in the main window — eggs per kind, the session's state egg (to process / hatching / reviewed),
// the bug, the chicken that processes, the peck that fixes — come through this one indirection. Generic things use SF
// Symbols directly; no emoji anywhere. Kind eggs are drawn by Capture/Eggs.swift. The rest falls back to an SF Symbol
// until the BlurtIcon set (Sources/BlurtApp/Icons/BlurtIcon.swift) lands; then swap `fallback` for it here.
import AppKit
import BlurtCore

enum BrandIcon {
    enum Name: String { case egg, bug, chicken, peck, nest, hatching, perch }

    /// A brand icon at `size` points (height).
    static func image(_ n: Name, size: CGFloat) -> NSImage? {
        switch n {
        case .egg: return Look.egg(kind: "note", size: NSSize(width: size * 0.78, height: size))
        default: return fallback(n, size: size)
        }
    }

    /// The egg of an item kind (issue / idea / note / task / custom lens).
    static func kind(_ kind: String, variant: String = "", size: CGFloat) -> NSImage? {
        Look.egg(kind: kind, variant: variant, size: NSSize(width: (size * 0.78).rounded(), height: size))
    }

    /// A session's egg: to process, being processed, to review (hatching), reviewed.
    static func sessionImage(_ s: SessionRow, size: CGFloat) -> NSImage? {
        Look.sessionEgg(s, size: NSSize(width: (size * 0.78).rounded(), height: size))
    }

    private static func fallback(_ n: Name, size: CGFloat) -> NSImage? {
        let symbol: String
        switch n {
        case .bug: symbol = "ladybug"
        case .chicken: symbol = "sparkles"
        case .peck: symbol = "wand.and.stars"
        case .nest: symbol = "tray"
        case .hatching: symbol = "circle.dashed"
        case .perch: symbol = "rectangle.portrait.on.rectangle.portrait"
        case .egg: symbol = "oval.portrait"
        }
        return Look.symbol(symbol, n.rawValue, size: size * 0.8)
    }
}
