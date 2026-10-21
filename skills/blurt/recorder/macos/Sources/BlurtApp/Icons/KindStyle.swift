// K8: one icon and one colour per item kind — issue (bug), idea (lightbulb), note (document), task (checklist), a
// custom lens (tag, hue from its name). On macOS the SF Symbol, like every native list; the colour is dynamic
// (light / dark).
//
// G0 (docs/design/next-round.md "所有权、闸门和合并"): written by P4 so the packages compile against it; P6 owns this
// file and sets the final icons and colours.
import AppKit
import BlurtCore

enum KindStyle {
    static let builtIn = ["issue", "idea", "note", "task"]

    static func icon(_ kind: String) -> BlurtIcon {
        switch kind {
        case "issue": return .bug
        case "idea": return .lightbulb
        case "note": return .document
        case "task": return .checklist
        default: return BlurtIcon(named: "tag") ?? .document
        }
    }

    static func symbol(_ kind: String) -> String {
        switch kind {
        case "issue": return "ladybug"
        case "idea": return "lightbulb"
        case "note": return "doc.text"
        case "task": return "checklist"
        default: return "tag"
        }
    }

    static func color(_ kind: String) -> NSColor {
        func rgb(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: 1)
        }
        func dyn(_ light: NSColor, _ dark: NSColor) -> NSColor {
            NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light }
        }
        switch kind {
        case "issue": return dyn(rgb(0xD93D42), rgb(0xFF6B6B))
        case "idea": return dyn(rgb(0xB7791F), rgb(0xFFC53D))
        case "note": return dyn(rgb(0x3E63DD), rgb(0x8DA4EF))
        case "task": return dyn(rgb(0x218358), rgb(0x3DD68C))
        default:
            let h = CGFloat(kind.unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value } % 360) / 360
            return dyn(NSColor(hue: h, saturation: 0.55, brightness: 0.42 * 1.55, alpha: 1), NSColor(hue: h, saturation: 0.5, brightness: 0.9, alpha: 1))
        }
    }

    /// The kind's icon in its colour, `pointSize` like text (an SF Symbol where macOS has it).
    static func image(_ kind: String, pointSize: CGFloat = 13, weight: NSFont.Weight = .medium) -> NSImage {
        let name = Loc.t("kind.\(kind)") == "kind.\(kind)" ? kind : Loc.t("kind.\(kind)")
        let base = NSImage(systemSymbolName: symbol(kind), accessibilityDescription: name)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: weight)) ?? icon(kind).image(size: pointSize + 2)
        let c = color(kind)
        let im = NSImage(size: base.size, flipped: false) { r in
            base.draw(in: r)
            c.set()
            r.fill(using: .sourceIn)
            return true
        }
        im.accessibilityDescription = name
        return im
    }
}
