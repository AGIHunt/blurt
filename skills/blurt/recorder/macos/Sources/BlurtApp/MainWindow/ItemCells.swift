// The item list's look and cells. One line per item (K8 density pass): an unread-style dot while it waits for review,
// the kind's icon in its colour, the title, the id and project folded into quiet text, the processing ring, the time.
// The full table (All Items) adds a header and the review / work columns. Fixed row height, view-based, reused —
// 20k rows scroll like 20.
import AppKit
import BlurtCore

enum Look {
    static let rowHeight: CGFloat = 30
    static let titleFont = NSFont.systemFont(ofSize: 13, weight: .regular)
    static let titleUnread = NSFont.systemFont(ofSize: 13, weight: .medium)
    static let subFont = NSFont.systemFont(ofSize: 11)
    static let monoSub = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    static let smallFont = NSFont.systemFont(ofSize: 11, weight: .medium)

    /// Brand coral, only for the primary action, the unread dot and selection accents: #FF5C3D light, #FF7A5C dark.
    static let brand = StatusRing.accent

    static func kindName(_ k: String) -> String {
        KindStyle.builtIn.contains(k) ? T("kind.\(k)") : k.replacingOccurrences(of: "_", with: " ").capitalized
    }
    static func reviewName(_ s: String) -> String { ["draft", "confirmed", "deleted"].contains(s) ? T("review.\(s)") : s }
    static func workName(_ w: String) -> String { StatusRing.states.contains(w) ? T("work.\(w)") : w }
    /// "With Claude Code" / "Copied to your agent" for handed_off, else the state's name.
    static func workLabel(_ it: ItemRow) -> String {
        guard it.workState == "handed_off" else { return workName(it.workState) }
        if it.workTo == "external" { return T("work.handed_off.external") }
        if let a = it.workAgent, let d = AgentHub.shared.def(a) { return T("work.handed_off.session", d.name) }
        return workName("handed_off")
    }

    static func symbol(_ name: String, _ label: String, size: CGFloat = 13, weight: NSFont.Weight = .regular) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: size, weight: weight))
    }

    private static var cache: [String: NSImage] = [:]
    static func kindImage(_ kind: String) -> NSImage {
        if let i = cache["k:" + kind] { return i }
        let i = KindStyle.image(kind, pointSize: 12, weight: .medium)
        cache["k:" + kind] = i
        return i
    }
    static func ring(_ state: String, size: CGFloat = 14) -> NSImage {
        let k = "r:\(state):\(size)"
        if let i = cache[k] { return i }
        let i = StatusRing.image(state, size: size)
        cache[k] = i
        return i
    }
}

/// The unread-style dot of a draft (K8: 6 pt, accent) and the kind icon, side by side.
final class LeadCell: NSTableCellView {
    let dot = DotView()
    let icon = NSImageView()
    /// The kind icon in its colour; white on a selected (emphasized) row, like the text next to it.
    var kindImage: NSImage? { didSet { restyle() } }
    override var backgroundStyle: NSView.BackgroundStyle { didSet { restyle() } }
    private func restyle() {
        let on = backgroundStyle == .emphasized
        dot.inverted = on
        guard let k = kindImage else { icon.image = nil; return }
        if on, let t = k.copy() as? NSImage { t.isTemplate = true; icon.image = t; icon.contentTintColor = .white }
        else { icon.image = k; icon.contentTintColor = nil }
    }
    override init(frame: NSRect) {
        super.init(frame: frame)
        for v in [dot, icon] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        icon.imageScaling = .scaleNone
        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2), dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 6), dot.heightAnchor.constraint(equalToConstant: 6),
            icon.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 6), icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

final class DotView: NSView {
    var on = false { didSet { needsDisplay = true } }
    var inverted = false { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        guard on else { return }
        (inverted ? NSColor.white : Look.brand).setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}

/// The title (one line), with the search hit after it when the hit isn't in the title.
final class TitleCell: NSTableCellView {
    let title = NSTextField(labelWithString: "")
    override init(frame: NSRect) {
        super.init(frame: frame)
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        title.usesSingleLineMode = true
        title.cell?.wraps = false
        title.translatesAutoresizingMaskIntoConstraints = false
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(title)
        textField = title
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(title t: String, unread: Bool, dimmed: Bool, struck: Bool, hit: String?) {
        var attrs: [NSAttributedString.Key: Any] = [.font: unread ? Look.titleUnread : Look.titleFont,
                                                    .foregroundColor: dimmed ? NSColor.secondaryLabelColor : NSColor.labelColor]
        if struck { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue; attrs[.strikethroughColor] = NSColor.tertiaryLabelColor }
        let s = NSMutableAttributedString(string: t.isEmpty ? T("main.item.untitled") : t, attributes: attrs)
        if let h = hit {
            s.append(NSAttributedString(string: "   ", attributes: [.font: Look.subFont]))
            s.append(TitleCell.marked(h))
        }
        // an attributed value drops the field's line break mode: without this a long title is clipped, no ellipsis
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byTruncatingTail
        s.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: s.length))
        title.attributedStringValue = s
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

/// An image (ring, icon) + quiet text — or just the text.
final class IconTextCell: NSTableCellView {
    let icon = NSImageView()
    let label = NSTextField(labelWithString: "")
    private var lead: NSLayoutConstraint!, bare: NSLayoutConstraint!
    override init(frame: NSRect) {
        super.init(frame: frame)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleNone
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = Look.subFont
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(icon)
        addSubview(label)
        imageView = icon
        textField = label
        lead = label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6)
        bare = label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2), icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            lead, label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(_ text: String, image: NSImage? = nil, color: NSColor = .secondaryLabelColor, font: NSFont = Look.subFont, align: NSTextAlignment = .left) {
        label.stringValue = text
        label.textColor = color
        label.font = font
        label.alignment = align
        label.isHidden = text.isEmpty
        if let img = image {
            icon.image = img
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

/// A small rounded label: the project key outside its project, the counts in the jobs section.
final class PillView: NSView {
    var text = "" { didSet { needsDisplay = true; invalidateIntrinsicContentSize() } }
    var color: NSColor = .secondaryLabelColor { didSet { needsDisplay = true } }
    var font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)

    override var intrinsicContentSize: NSSize {
        let s = (text as NSString).size(withAttributes: [.font: font])
        return NSSize(width: ceil(s.width) + 10, height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !text.isEmpty else { return }
        let size = intrinsicContentSize
        let r = NSRect(x: 0, y: (bounds.height - size.height) / 2, width: min(size.width, bounds.width), height: size.height)
        let path = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
        color.withAlphaComponent(0.12).setFill()
        path.fill()
        let str = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        let ts = str.size()
        str.draw(at: NSPoint(x: r.minX + (r.width - ts.width) / 2, y: r.minY + (r.height - ts.height) / 2))
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityValue() -> Any? { text }
}

/// The item's id and, outside its own project, the project — "BA-12" / "BA-12 · bug-agent".
final class MetaCell: NSTableCellView {
    let key = NSTextField(labelWithString: "")
    override init(frame: NSRect) {
        super.init(frame: frame)
        key.translatesAutoresizingMaskIntoConstraints = false
        key.font = Look.monoSub
        key.textColor = .tertiaryLabelColor
        key.lineBreakMode = .byTruncatingTail
        key.alignment = .right
        key.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(key)
        NSLayoutConstraint.activate([key.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
                                     key.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 2),
                                     key.centerYAnchor.constraint(equalTo: centerYAnchor)])
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// Row view: VoiceOver reads the whole row as one sentence (kind, title, review, work, project, time).
final class ItemRowView: NSTableRowView {
    var label = "" { didSet { setAccessibilityLabel(label) } }
}
