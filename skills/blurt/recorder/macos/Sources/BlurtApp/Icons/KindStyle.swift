// K8: one icon and one colour per item kind — issue (bug), idea (lightbulb), note (document), task (checklist), a
// custom lens (tag, hue from its name). On macOS the SF Symbol, like every native list; the colour is dynamic
// (light / dark). Same values as web/packages/ui (tokens.css --kind-*, kinds.ts customKindColor); tests/test_icons.py
// keeps the two in step.
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
        default: return .tag
        }
    }

    /// light / dark sRGB, ≥ 3:1 on every surface of the app (web: tokens.css)
    static let palette: [String: (UInt32, UInt32)] = [
        "issue": (0xD93D42, 0xFF6B6B),
        "idea": (0xA8710A, 0xFFC53D),
        "note": (0x3E63DD, 0x8DA4EF),
        "task": (0x218358, 0x3DD68C),
    ]

    static func color(_ kind: String) -> NSColor {
        if let (l, d) = palette[kind] { return dynamic(rgb(l), rgb(d)) }
        return dynamic(rgb(customColor(kind, dark: false)), rgb(customColor(kind, dark: true)))
    }

    /// The kind's icon in its colour, `pointSize` like text (an SF Symbol where macOS has it), with the localized kind
    /// (or the lens name) as its accessibility description.
    static func image(_ kind: String, pointSize: CGFloat = 13, weight: NSFont.Weight = .medium) -> NSImage {
        let key = "kind.\(kind)"
        let name = Loc.t(key) == key ? kind : Loc.t(key)
        let ic = icon(kind)
        let base = ic.sfSymbols.lazy.compactMap { NSImage(systemSymbolName: $0, accessibilityDescription: name) }.first?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: weight)) ?? ic.image(size: (pointSize * 1.15).rounded())
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

    // ---------------------------------------------------------------- custom lenses (kinds.ts customKindColor)
    /// h = (h·31 + UTF-16 code unit) mod 360 — the JS hash, so a lens has the same hue on every platform.
    static func hue(_ kind: String) -> Int {
        kind.utf16.reduce(0) { ($0 * 31 + Int($1)) % 360 }
    }

    /// HSL(h, 55%, 42%) light / HSL(h, 70%, 68%) dark, stepped 2% darker / lighter until it has 3:1 on the lightest /
    /// darkest surface (#EAEAEA / #383838).
    static func customColor(_ kind: String, dark: Bool) -> UInt32 {
        let h = Double(hue(kind))
        if dark {
            var l = 68.0
            while l < 95, contrast(hsl(h, 70, l), 0x383838) < 3 { l += 2 }
            return hsl(h, 70, min(l, 95))
        }
        var l = 42.0
        while l > 10, contrast(hsl(h, 55, l), 0xEAEAEA) < 3 { l -= 2 }
        return hsl(h, 55, max(l, 10))
    }

    static func hsl(_ h: Double, _ s: Double, _ l: Double) -> UInt32 {
        let s = s / 100, l = l / 100
        let a = s * min(l, 1 - l)
        func f(_ n: Double) -> UInt32 {
            let k = (n + h / 30).truncatingRemainder(dividingBy: 12)
            let v = l - a * max(-1, min(k - 3, min(9 - k, 1)))
            return UInt32((v * 255).rounded())
        }
        return f(0) << 16 | f(8) << 8 | f(4)
    }

    static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        func lum(_ c: UInt32) -> Double {
            func ch(_ v: UInt32) -> Double {
                let x = Double(v) / 255
                return x <= 0.03928 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * ch(c >> 16 & 0xff) + 0.7152 * ch(c >> 8 & 0xff) + 0.0722 * ch(c & 0xff)
        }
        let (x, y) = (lum(a), lum(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }

    static func dynamic(_ light: NSColor, _ dark: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light }
    }
}
