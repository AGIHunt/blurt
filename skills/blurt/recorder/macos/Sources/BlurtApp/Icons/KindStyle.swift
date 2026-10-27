// K8: one icon and one colour per item kind — issue (bug), idea (light bulb), note (page), task (checkbox with a tick),
// a custom lens (tag, hue from its name). The kinds are one family of our own (assets/icons, docs/design/system.md §2.6):
// the 24 grid, the 1.75 line, one footprint — never SF Symbols, so the four always read as one set next to each other.
// The colour is dynamic (light / dark), from assets/color/tokens.json (generated BrandColor.Kind; web: tokens.css
// --kind-*, kinds.ts customKindColor), so the two can't drift.
import AppKit
import BlurtCore

enum KindStyle {
    static let builtIn = ["issue", "idea", "note", "task"]

    static func icon(_ kind: String) -> BlurtIcon {
        switch kind {
        case "issue": return .bug
        case "idea": return .lightbulb
        case "note": return .document
        case "task": return .checkbox
        default: return .tag
        }
    }

    /// light / dark sRGB, ≥ 3:1 on every surface of the app: generated from assets/color/tokens.json (kind.*)
    static let palette = BrandColor.Kind.palette

    static func color(_ kind: String) -> NSColor {
        if let (l, d) = palette[kind] { return dynamic(rgb(l), rgb(d)) }
        return dynamic(rgb(customColor(kind, dark: false)), rgb(customColor(kind, dark: true)))
    }

    /// The sizes the kind icon is drawn at (the glyph fills ~18 of the 24 grid): `row` in list rows (the 18 pt slot next
    /// to the 14 pt state ring), `small` in menus, the palette and the filter's segments.
    static let rowSize: CGFloat = 18
    static let smallSize: CGFloat = 16

    /// The kind's icon in its colour, `size` points square (our vector: the same drawing as the web's), with the
    /// localized kind (or the lens name) as its accessibility description.
    static func image(_ kind: String, size: CGFloat = rowSize) -> NSImage {
        let key = "kind.\(kind)"
        let name = Loc.t(key) == key ? kind : Loc.t(key)
        let c = color(kind)
        let ic = icon(kind)
        let im = NSImage(size: NSSize(width: size, height: size), flipped: true) { r in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ic.draw(in: ctx, rect: r, color: c.cgColor, flipped: true)
            return true
        }
        im.accessibilityDescription = name
        return im
    }

    /// A voice note's mark in lists: the waveform (the recording's own glyph, §3.2) in the note's colour, so the kind
    /// column keeps one hue per kind and a spoken note still reads as one.
    static func voiceImage(size: CGFloat = rowSize) -> NSImage {
        let c = color("note")
        let im = NSImage(size: NSSize(width: size, height: size), flipped: true) { r in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            BlurtIcon.waveform.draw(in: ctx, rect: r, color: c.cgColor, flipped: true)
            return true
        }
        im.accessibilityDescription = T("main.kind.voice_note")
        return im
    }

    // ---------------------------------------------------------------- custom lenses (kinds.ts customKindColor)
    /// h = (h·31 + UTF-16 code unit) mod 360 — the JS hash, so a lens has the same hue on every platform.
    static func hue(_ kind: String) -> Int {
        kind.utf16.reduce(0) { ($0 * 31 + Int($1)) % 360 }
    }

    /// The lens hue, moved 60° on when it lands in the brand / success band (BrandColor.Kind.customHueGap, inclusive),
    /// so no lens reads as mint or done. Same as kinds.ts customKindHue.
    static func customHue(_ kind: String) -> Int {
        let h = hue(kind)
        return BrandColor.Kind.customHueGap.contains(h) ? h + 60 : h
    }

    /// HSL(h, 55%, 42%) light / HSL(h, 70%, 68%) dark, stepped 2% darker / lighter until it has 3:1 on the lightest /
    /// darkest surface (#EAEAEA / #383838).
    static func customColor(_ kind: String, dark: Bool) -> UInt32 {
        let h = Double(customHue(kind))
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
