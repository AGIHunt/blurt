// The pieces the capture chrome shares (docs/design/system.md §3.1): one surface — the island's black with a hairline
// (the picker's hint and toolbar, its size and window labels, the countdown) — one way to show a key (a small keycap
// followed by a plain word: "[F] Full screen", "Hold [⌃] to draw"), and a budget for teaching lines that only show the
// first few times (the picker's key legend, the recording's pen hint).
import AppKit
import BlurtCore

/// The capture chrome's one surface: the island's black at 88 %, a 0.5 pt white 14 % hairline, a soft shadow. Over
/// screen content it holds its edge on white and on black alike (it never takes the colour of what is under it).
enum CaptureGlass {
    static let fill = NSColor(white: 0, alpha: 0.88)
    static let rim = NSColor(white: 1, alpha: 0.14)
    static func apply(_ l: CALayer?, radius: CGFloat, shadow: Bool = true) {
        guard let l = l else { return }
        l.backgroundColor = fill.cgColor
        l.cornerRadius = radius
        l.borderWidth = 0.5
        l.borderColor = rim.cgColor
        if shadow {
            l.shadowColor = NSColor.black.cgColor
            l.shadowOpacity = 0.28
            l.shadowRadius = 10
            l.shadowOffset = CGSize(width: 0, height: -3)
        }
    }

    /// The surface drawn (the picker's labels, drawn with the dim): a capsule with its hairline, the text white.
    @discardableResult
    static func pill(_ text: String, font: NSFont, color: NSColor = NSColor(white: 1, alpha: 0.92), at p: NSPoint,
                     height: CGFloat = 24, pad: CGFloat = 10, icon: BlurtIcon? = nil) -> NSRect {
        let s = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        let sz = s.size()
        let iw: CGFloat = icon == nil ? 0 : 14 + 6
        let r = NSRect(x: p.x.rounded(), y: p.y.rounded(), width: ceil(sz.width) + pad * 2 + iw, height: height)
        let shape = NSBezierPath(roundedRect: r, xRadius: height / 2, yRadius: height / 2)
        fill.setFill()
        shape.fill()
        rim.setStroke()
        let edge = NSBezierPath(roundedRect: r.insetBy(dx: 0.25, dy: 0.25), xRadius: height / 2, yRadius: height / 2)
        edge.lineWidth = 0.5
        edge.stroke()
        if let icon = icon {
            icon.image(size: 14, color: color).draw(in: NSRect(x: r.minX + pad, y: r.midY - 7, width: 14, height: 14),
                                                    from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        s.draw(at: NSPoint(x: r.minX + pad + iw, y: r.midY - sz.height / 2))
        return r
    }

    /// Its size before drawing it.
    static func pillWidth(_ text: String, font: NSFont, pad: CGFloat = 10, icon: Bool = false) -> CGFloat {
        ceil(NSAttributedString(string: text, attributes: [.font: font]).size().width) + pad * 2 + (icon ? 20 : 0)
    }
}

/// A line of words and keys: "[F] Full screen   [L] Last area   [esc] Cancel", "Hold [⌃] to draw · [⇧] box · [⌥] ellipse".
/// Keys are small caps (white 12 % fill, a 0.5 pt white 20 % hairline, radius 4, 10.5 pt semibold); words are plain
/// labels (so the layout lint sees them and VoiceOver reads the line as one).
final class KeyLine: NSView {
    enum Run: Equatable { case text(String), key(String), gap(CGFloat), divider }

    static let capH: CGFloat = 17
    override var isFlipped: Bool { true }

    init(_ runs: [Run], size: CGFloat = 11.5, color: NSColor = NSColor(white: 1, alpha: 0.6), weight: NSFont.Weight = .regular,
         label: String? = nil) {
        super.init(frame: .zero)
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        let lineH = max(KeyLine.capH, ceil(font.ascender - font.descender + font.leading) + 1)
        var x: CGFloat = 0
        var spoken: [String] = []
        var afterKey = false
        for run in runs {
            switch run {
            case .text(let t):
                let l = NSTextField(labelWithString: t)
                l.font = font
                l.textColor = color
                l.lineBreakMode = .byClipping
                let w = ceil(NSAttributedString(string: t, attributes: [.font: font]).size().width) + 4
                let lead: CGFloat = afterKey && !t.hasPrefix(" ") ? 5 : 0
                l.frame = NSRect(x: x + lead - 2, y: (lineH - ceil(font.ascender - font.descender + font.leading) - 1) / 2,
                                 width: w, height: ceil(font.ascender - font.descender + font.leading) + 1)
                addSubview(l)
                x += lead + w - 4
                spoken.append(t)
                afterKey = false
            case .key(let k):
                let cap = KeyCap(k)
                if x > 0, !afterKey { x += 3 }
                cap.frame.origin = NSPoint(x: x, y: ((lineH - KeyLine.capH) / 2).rounded())
                addSubview(cap)
                x = cap.frame.maxX
                spoken.append(k)
                afterKey = true
            case .gap(let g):
                x += g
                afterKey = false
            case .divider:
                let d = NSView(frame: NSRect(x: x + 10, y: (lineH - 14) / 2, width: 1, height: 14))
                d.wantsLayer = true
                d.layer?.backgroundColor = NSColor(white: 1, alpha: 0.18).cgColor
                addSubview(d)
                x += 21
                afterKey = false
            }
        }
        frame = NSRect(x: 0, y: 0, width: ceil(x), height: lineH)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(label ?? spoken.joined(separator: " "))
    }
    required init?(coder: NSCoder) { fatalError() }

    /// A hint written with the key as `%@` and modifier glyphs in its text ("Hold %@ to draw · ⇧ box · ⌥ ellipse"):
    /// the key and every modifier become keycaps — all of them, so "⌃" never reads as "^".
    static func runs(format: String, key: String) -> [Run] {
        let modifiers: Set<Character> = ["⌃", "⌥", "⇧", "⌘"]
        var runs: [Run] = []
        for (k, part) in format.components(separatedBy: "%@").enumerated() {
            if k > 0 { runs.append(.key(key)) }
            var text = ""
            for c in part {
                guard modifiers.contains(c) else { text.append(c); continue }
                if !text.isEmpty { runs.append(.text(text)); text = "" }
                runs.append(.key(String(c)))
            }
            if !text.isEmpty { runs.append(.text(text)) }
        }
        return runs
    }

    /// "[F] Full screen   [esc] Cancel": key + word pairs, 12 pt apart.
    static func pairs(_ p: [(key: String, word: String)]) -> [Run] {
        var runs: [Run] = []
        for (i, kw) in p.enumerated() {
            if i > 0 { runs.append(.gap(12)) }
            runs.append(.key(kw.key))
            runs.append(.text(kw.word))
        }
        return runs
    }
}

/// One keycap.
final class KeyCap: NSView {
    init(_ key: String) {
        let font = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
        let l = NSTextField(labelWithString: key)
        l.font = font
        l.textColor = NSColor(white: 1, alpha: 0.88)
        l.alignment = .center
        let tw = ceil(NSAttributedString(string: key, attributes: [.font: font]).size().width)
        let w = max(KeyLine.capH + 1, tw + 10)
        super.init(frame: NSRect(x: 0, y: 0, width: w, height: KeyLine.capH))
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 1, alpha: 0.12).cgColor
        layer?.cornerRadius = 4
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor(white: 1, alpha: 0.2).cgColor
        let lh = ceil(font.ascender - font.descender) + 1
        l.frame = NSRect(x: 0, y: ((KeyLine.capH - lh) / 2).rounded(), width: w, height: lh)
        addSubview(l)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// Teaching lines that show the first few times only (the picker's key legend, the recording's pen hint): after
/// that the keys still work and the rarer ones are in the toolbar / the island's ··· menu. Counted in the app's own
/// defaults. Tests: BLURT_TEST_HINTS=always | never.
enum HintBudget {
    static func take(_ key: String, times: Int = 3) -> Bool {
        let env = ProcessInfo.processInfo.environment
        if env["BLURT_TEST_COMMANDS"] == "1", let v = env["BLURT_TEST_HINTS"] { return v == "always" }
        let k = "blurt.hints." + key
        let n = UserDefaults.standard.integer(forKey: k)
        guard n < times else { return false }
        UserDefaults.standard.set(n + 1, forKey: k)
        return true
    }
}
