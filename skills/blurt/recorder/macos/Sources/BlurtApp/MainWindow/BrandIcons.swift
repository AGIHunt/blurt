// Brand concepts in the main window — eggs per kind, a session's state egg (to process / hatching / reviewed), the bug,
// the chicken that processes, the peck that fixes, the snap — all come from the BlurtIcon set (Icons/BlurtIcon.swift).
// Generic things use SF Symbols directly. No emoji anywhere.
import AppKit
import BlurtCore

enum BrandIcon {
    enum Name: String { case egg, bug, chicken, peck, nest, hatching, perch, snap, agentRun }

    static func icon(_ n: Name) -> BlurtIcon {
        switch n {
        case .egg: return .egg
        case .bug: return .bug
        case .chicken: return .chicken
        case .peck: return .peck
        case .nest: return .nest
        case .hatching: return .hatch
        case .perch: return .perch
        case .snap: return .snap
        case .agentRun: return .agentRun
        }
    }

    /// A brand glyph `size` points square, template (tints like text). The plain egg is the full-colour note egg.
    static func image(_ n: Name, size: CGFloat) -> NSImage? {
        n == .egg ? BlurtIcon.egg(.note, size: size) : icon(n).image(size: size)
    }

    /// The egg of an item kind (issue / idea / note / task / custom lens); `variant` picks one of 8 speckle patterns.
    static func kind(_ kind: String, variant: String = "", size: CGFloat) -> NSImage? {
        Look.egg(kind: kind, variant: variant, size: NSSize(width: (size * 0.78).rounded(), height: size))
    }

    /// A session's egg: to process, being processed, to review (hatching), reviewed.
    static func sessionImage(_ s: SessionRow, size: CGFloat) -> NSImage? {
        Look.sessionEgg(s, size: NSSize(width: (size * 0.78).rounded(), height: size))
    }
}
