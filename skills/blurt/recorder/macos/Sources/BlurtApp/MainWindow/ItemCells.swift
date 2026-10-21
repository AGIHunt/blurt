// The item list's cells: an egg per item (Eggs.swift — the same eggs the perch and the HUD lay), the title with the
// session (or the search hit) underneath, a status pill, the agent fix state, the project, the time. Fixed row height,
// view-based, reused — 20k rows scroll like 20.
import AppKit
import BlurtCore

enum Look {
    static let rowHeight: CGFloat = 40
    static let titleFont = NSFont.systemFont(ofSize: 13, weight: .regular)
    static let subFont = NSFont.systemFont(ofSize: 11)
    static let smallFont = NSFont.systemFont(ofSize: 11, weight: .medium)

    /// Brand coral, only for the primary action and selection accents (§2.4): #FF5C3D light, #FF7A5C dark.
    static let brand = NSColor(name: nil) { ap in
        ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(srgbRed: 1, green: 0.478, blue: 0.361, alpha: 1)
                                                             : NSColor(srgbRed: 1, green: 0.36, blue: 0.24, alpha: 1)
    }

    static func kindName(_ k: String) -> String {
        switch k {
        case "issue": return L("问题", "Issue")
        case "idea": return L("想法", "Idea")
        case "note": return L("笔记", "Note")
        case "task": return L("任务", "Task")
        default: return k
        }
    }
    static func statusName(_ s: String) -> String {
        switch s {
        case "draft": return L("待审", "Draft")
        case "confirmed": return L("已确认", "Confirmed")
        case "deleted": return L("已丢弃", "Dropped")
        default: return s
        }
    }
    static func fixName(_ f: String?) -> String? {
        switch f {
        case "fixing": return L("修复中", "Fixing")
        case "fixed": return L("已修复", "Fixed")
        case "wontfix": return L("不修", "Won't fix")
        case "reopened": return L("重新打开", "Reopened")
        default: return nil
        }
    }
    static func fixSymbol(_ f: String?) -> (String, NSColor)? {
        switch f {
        case "fixing": return ("hammer.fill", .systemOrange)
        case "fixed": return ("checkmark.seal.fill", .systemGreen)
        case "wontfix": return ("minus.circle", .secondaryLabelColor)
        case "reopened": return ("arrow.uturn.backward.circle.fill", .systemRed)
        default: return nil
        }
    }
    static func sessionStateName(_ s: String) -> String {
        switch s {
        case "unprocessed": return L("待整理", "To process")
        case "processing": return L("整理中", "Processing")
        case "unreviewed": return L("待审核", "To review")
        default: return L("已审核", "Reviewed")
        }
    }

    static func symbol(_ name: String, _ label: String, size: CGFloat = 13, weight: NSFont.Weight = .regular) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: size, weight: weight))
    }

    private static var eggs: [String: NSImage] = [:]
    /// An item's egg: kind decides the egg, the uid a little speckle variation (8 per kind, cached).
    static func egg(kind: String, variant: String = "", size: NSSize = NSSize(width: 18, height: 23)) -> NSImage? {
        let k = EggKind(kind)
        let seed = k == .custom ? customEggHue(kind) : stableSeed(variant) % 8 + 3
        let key = "\(kind)-\(seed)-\(size.width)"
        if let i = eggs[key] { return i }
        guard let cg = eggImage(k, size: size, seed: seed, shadow: false) else { return nil }
        let img = NSImage(cgImage: cg, size: size)
        img.accessibilityDescription = kindName(kind)
        eggs[key] = img
        return img
    }

    /// A session's egg: 🥚 to process, a golden one while an agent works on it, a cracked one (🐣) to review, a nested
    /// one when reviewed.
    static func sessionEgg(_ s: SessionRow, size: NSSize = NSSize(width: 18, height: 23)) -> NSImage? {
        let key = "session-\(s.state)-\(size.width)"
        if let i = eggs[key] { return i }
        let kind: EggKind = s.state == "processing" ? .idea : s.state == "reviewed" ? .task : .note
        guard let cg = renderImage(size, { ctx in
            drawEgg(ctx, in: CGRect(origin: .zero, size: size), kind: kind, seed: 5, shadow: false)
            if s.state == "unreviewed" {          // the crack of a hatching egg
                ctx.setStrokeColor(NSColor(srgbRed: 0.35, green: 0.25, blue: 0.15, alpha: 0.85).cgColor)
                ctx.setLineWidth(1.1)
                ctx.setLineJoin(.round)
                let y = size.height * 0.55, w = size.width
                ctx.move(to: CGPoint(x: w * 0.12, y: y))
                for (k, x) in stride(from: 0.24, through: 0.9, by: 0.13).enumerated() {
                    ctx.addLine(to: CGPoint(x: w * x, y: y + (k % 2 == 0 ? 2.2 : -1.6)))
                }
                ctx.strokePath()
            }
        }) else { return nil }
        let img = NSImage(cgImage: cg, size: size)
        img.accessibilityDescription = sessionStateName(s.state)
        eggs[key] = img
        return img
    }
}

/// A small rounded label: status in the list, counts in the sidebar.
final class PillView: NSView {
    var text = "" { didSet { needsDisplay = true; invalidateIntrinsicContentSize() } }
    var color: NSColor = .secondaryLabelColor { didSet { needsDisplay = true } }
    var filled = false { didSet { needsDisplay = true } }
    var font = Look.smallFont

    override var intrinsicContentSize: NSSize {
        let s = (text as NSString).size(withAttributes: [.font: font])
        return NSSize(width: ceil(s.width) + 14, height: 18)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !text.isEmpty else { return }
        let size = intrinsicContentSize
        let r = NSRect(x: 0, y: (bounds.height - size.height) / 2, width: min(size.width, bounds.width), height: size.height)
        let path = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: r.height / 2, yRadius: r.height / 2)
        color.withAlphaComponent(filled ? 0.9 : 0.14).setFill()
        path.fill()
        let fg = filled ? NSColor.white : color
        let str = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: fg])
        let ts = str.size()
        str.draw(at: NSPoint(x: r.minX + (r.width - ts.width) / 2, y: r.minY + (r.height - ts.height) / 2))
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityValue() -> Any? { text }
}

/// Egg column
final class EggCell: NSTableCellView {
    let egg = NSImageView()
    let spinner = NSProgressIndicator()
    override init(frame: NSRect) {
        super.init(frame: frame)
        egg.imageScaling = .scaleProportionallyUpOrDown
        egg.translatesAutoresizingMaskIntoConstraints = false
        addSubview(egg)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(spinner)
        NSLayoutConstraint.activate([
            egg.centerXAnchor.constraint(equalTo: centerXAnchor), egg.centerYAnchor.constraint(equalTo: centerYAnchor),
            egg.widthAnchor.constraint(equalToConstant: 18), egg.heightAnchor.constraint(equalToConstant: 23),
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor), spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// Title + a secondary line (the session, or the search hit with the match in bold)
final class TitleCell: NSTableCellView {
    let title = NSTextField(labelWithString: "")
    let sub = NSTextField(labelWithString: "")
    override init(frame: NSRect) {
        super.init(frame: frame)
        for f in [title, sub] {
            f.lineBreakMode = .byTruncatingTail
            f.maximumNumberOfLines = 1
            f.usesSingleLineMode = true
            f.cell?.wraps = false
            f.translatesAutoresizingMaskIntoConstraints = false
            f.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            addSubview(f)
        }
        title.font = Look.titleFont
        sub.font = Look.subFont
        sub.textColor = .secondaryLabelColor
        textField = title
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            title.bottomAnchor.constraint(equalTo: centerYAnchor, constant: 1),
            sub.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            sub.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            sub.topAnchor.constraint(equalTo: centerYAnchor, constant: 2),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(title t: String, struck: Bool, sub s: String, highlight: Bool) {
        var attrs: [NSAttributedString.Key: Any] = [.font: Look.titleFont, .foregroundColor: struck ? NSColor.secondaryLabelColor : NSColor.labelColor]
        if struck { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        title.attributedStringValue = NSAttributedString(string: t.isEmpty ? L("（无标题）", "(untitled)") : t, attributes: attrs)
        sub.attributedStringValue = highlight ? TitleCell.marked(s) : NSAttributedString(string: s, attributes: [.font: Look.subFont, .foregroundColor: NSColor.secondaryLabelColor])
    }

    /// index.py snippets mark the hit as [hit]
    static func marked(_ s: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        var rest = Substring(s)
        let base: [NSAttributedString.Key: Any] = [.font: Look.subFont, .foregroundColor: NSColor.secondaryLabelColor]
        let hit: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.labelColor]
        while let a = rest.firstIndex(of: "["), let b = rest[a...].firstIndex(of: "]") {
            out.append(NSAttributedString(string: String(rest[..<a]), attributes: base))
            out.append(NSAttributedString(string: String(rest[rest.index(after: a)..<b]), attributes: hit))
            rest = rest[rest.index(after: b)...]
        }
        out.append(NSAttributedString(string: String(rest), attributes: base))
        return out
    }
}

/// Status pill
final class PillCell: NSTableCellView {
    let pill = PillView()
    override init(frame: NSRect) {
        super.init(frame: frame)
        pill.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pill)
        NSLayoutConstraint.activate([pill.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
                                     pill.centerYAnchor.constraint(equalTo: centerYAnchor),
                                     pill.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor)])
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// Symbol + text (fix state), or plain secondary text (project, time)
final class IconTextCell: NSTableCellView {
    let icon = NSImageView()
    let label = NSTextField(labelWithString: "")
    private var lead: NSLayoutConstraint!, bare: NSLayoutConstraint!
    override init(frame: NSRect) {
        super.init(frame: frame)
        icon.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = Look.subFont
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(icon)
        addSubview(label)
        imageView = icon
        textField = label
        lead = label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 4)
        bare = label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2), icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            lead, label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(_ text: String, symbol: (String, NSColor)? = nil, color: NSColor = .secondaryLabelColor) {
        label.stringValue = text
        setAccessibilityLabel(text)
        label.textColor = color
        if let (name, tint) = symbol {
            icon.image = Look.symbol(name, text, size: 12)
            icon.contentTintColor = tint
            icon.isHidden = false
            bare.isActive = false
            lead.isActive = true
        } else {
            icon.image = nil
            icon.isHidden = true
            lead.isActive = false
            bare.isActive = true
        }
    }
}
