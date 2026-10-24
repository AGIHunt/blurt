// The item list's look and cells. One line per item (K8 density pass): the kind's icon in its colour, the item's one
// state ring (K3 — click it for what you can do from there), the title (medium weight while it's new), the id and
// project folded into quiet text, the time. The full table (All Items) adds a header and a State column (ring + name)
// instead of the ring up front. Fixed row height, view-based, reused — 20k rows scroll like 20.
import AppKit
import BlurtCore

enum Look {
    static let rowHeight: CGFloat = 30
    static let titleFont = NSFont.systemFont(ofSize: 13, weight: .regular)
    static let titleUnread = NSFont.systemFont(ofSize: 13, weight: .medium)
    static let subFont = NSFont.systemFont(ofSize: 11)
    static let monoSub = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    static let smallFont = NSFont.systemFont(ofSize: 11, weight: .medium)

    /// Brand ink (deep mint #0B735E light, mint #61DBBD dark): brand as text, icons and state rings
    /// (docs/design/system.md §2.1). Selection is `BrandColor.tint` (BrandRowView), primaries are BrandButton.
    static let brand = BrandColor.ink

    static func kindName(_ k: String) -> String {
        KindStyle.builtIn.contains(k) ? T("kind.\(k)") : k.replacingOccurrences(of: "_", with: " ").capitalized
    }
    static func stateName(_ s: String) -> String { Lifecycle.isState(s) ? T("state.\(s)") : s }
    /// "With Claude Code" / "Copied to your agent" for handed_off, else the state's name.
    static func stateLabel(_ it: ItemRow) -> String {
        guard it.state == "handed_off" else { return stateName(it.state) }
        if it.workTo == "external" { return T("state.handed_off.external") }
        if let a = it.workAgent, let d = AgentHub.shared.def(a) { return T("state.handed_off.session", d.name) }
        return stateName("handed_off")
    }
    /// The state's text colour next to its ring: the ring's own colour where it asks for you, quiet otherwise.
    static func stateColor(_ s: String) -> NSColor {
        switch s {
        case "new", "handed_off", "in_progress": return BrandColor.ink
        case "to_verify": return BrandColor.attnInk
        case "done": return BrandColor.ok
        case "wontfix", "discarded": return .tertiaryLabelColor
        default: return .secondaryLabelColor
        }
    }
    /// Menus in English use title case (the macOS convention); the shared catalog is in sentence case.
    static func menuCase(_ t: String) -> String {
        guard !Loc.isChinese else { return t }
        let small: Set<String> = ["a", "an", "as", "at", "by", "for", "in", "of", "on", "or", "the", "to"]
        return t.split(separator: " ", omittingEmptySubsequences: false).enumerated().map { k, w in
            let s = String(w)
            return k > 0 && small.contains(s.lowercased()) ? s : s.prefix(1).uppercased() + s.dropFirst()
        }.joined(separator: " ")
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

/// An image in its colours; white on a selected (emphasized) row, like the text next to it.
private func onRow(_ image: NSImage?, emphasized: Bool) -> NSImage? {
    guard emphasized, let t = image?.copy() as? NSImage else { return image }
    t.isTemplate = true
    return t
}

/// The kind icon and — in the dense list — the state ring, side by side. The ring is a button: it opens the state menu.
final class LeadCell: NSTableCellView {
    let icon = NSImageView()
    let ring = StateRingButton()
    /// The kind icon in its colour; white on a selected (emphasized) row, like the text next to it.
    var kindImage: NSImage? { didSet { restyle() } }
    var showsRing = true { didSet { ring.isHidden = !showsRing } }
    override var backgroundStyle: NSView.BackgroundStyle { didSet { restyle() } }
    private func restyle() {
        let on = backgroundStyle == .emphasized
        icon.image = onRow(kindImage, emphasized: on)
        icon.contentTintColor = on ? .white : nil
        ring.emphasized = on
    }
    override init(frame: NSRect) {
        super.init(frame: frame)
        for v in [icon, ring] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        icon.imageScaling = .scaleNone
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2), icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            ring.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 3), ring.centerYAnchor.constraint(equalTo: centerYAnchor),
            ring.widthAnchor.constraint(equalToConstant: 20), ring.heightAnchor.constraint(equalToConstant: 20),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// The state ring as a borderless button (14 pt ring in a 20 pt target). Hover shows a soft circle, like a toolbar
/// button; the click goes to the list (target / action), which opens the state menu under it.
final class StateRingButton: NSButton {
    var ringState = "new" { didSet { if ringState != oldValue { restyle() } } }
    var emphasized = false { didSet { if emphasized != oldValue { restyle() } } }
    private var hovering = false { didSet { needsDisplay = true } }
    private var area: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        imagePosition = .imageOnly
        imageScaling = .scaleNone
        title = ""
        setButtonType(.momentaryPushIn)
        focusRingType = .none
        restyle()
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(_ state: String, label: String) {
        ringState = state
        toolTip = label
        setAccessibilityLabel(T("main.state.ax", label))
    }

    private func restyle() {
        image = onRow(Look.ring(ringState), emphasized: emphasized)
        contentTintColor = emphasized ? .white : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        area.map(removeTrackingArea)
        let a = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(a)
        area = a
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func draw(_ dirtyRect: NSRect) {
        if hovering || isHighlighted {
            (emphasized ? NSColor.white.withAlphaComponent(0.22) : NSColor.labelColor.withAlphaComponent(isHighlighted ? 0.14 : 0.08)).setFill()
            NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5)).fill()
        }
        super.draw(dirtyRect)
    }
}

/// The full table's State column: ring + the state's name, one button that opens the state menu.
final class StateCell: NSTableCellView {
    let button = NSButton()
    private var state = "new", label = ""
    override var backgroundStyle: NSView.BackgroundStyle { didSet { restyle() } }
    override init(frame: NSRect) {
        super.init(frame: frame)
        button.isBordered = false
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        button.alignment = .left
        button.focusRingType = .none
        button.setButtonType(.momentaryPushIn)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 0),
            button.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(_ state: String, label: String) {
        self.state = state
        self.label = label
        button.toolTip = label
        button.setAccessibilityLabel(T("main.state.ax", label))
        restyle()
    }

    private func restyle() {
        let on = backgroundStyle == .emphasized
        button.image = onRow(Look.ring(state), emphasized: on)
        button.contentTintColor = on ? .white : nil
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byTruncatingTail
        button.attributedTitle = NSAttributedString(string: " " + label, attributes: [
            .font: Look.subFont, .foregroundColor: on ? NSColor.white : Look.stateColor(state), .paragraphStyle: p])
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
        key.textColor = .secondaryLabelColor
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

/// Row view: VoiceOver reads the whole row as one sentence (kind, title, id, state, project, time). Selection is the
/// brand tint (BrandRowView).
final class ItemRowView: BrandRowView {
    var label = "" { didSet { setAccessibilityLabel(label) } }
}

/// The selection blurt draws in its own lists (§3.3): a rounded `BrandColor.tint` wash (r 6), a neutral 6 % wash when the
/// window isn't key; never emphasized, so the text on it stays `labelColor`.
class BrandRowView: NSTableRowView {
    /// The table still tells us when its window gains or loses key (it sets this): redraw the selection then.
    override var isEmphasized: Bool { get { false } set { if isSelected { needsDisplay = true } } }
    private var keyObservers: [NSObjectProtocol] = []
    /// Screenshots of a test build launched in the background (test commands only): BLURT_TEST_KEY_LOOK=1 draws the
    /// selection as in a key window.
    static let testKeyLook = ProcessInfo.processInfo.environment["BLURT_TEST_COMMANDS"] == "1"
        && ProcessInfo.processInfo.environment["BLURT_TEST_KEY_LOOK"] == "1"

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let key = window?.isKeyWindow == true && NSApp.isActive || BrandRowView.testKeyLook
        (key ? BrandColor.tint : NSColor.labelColor.withAlphaComponent(0.06)).setFill()
        // the inset / source-list styles inset the row itself; a row as wide as its table keeps a margin like theirs
        let pad: CGFloat = frame.minX < 1 && abs(frame.width - (superview?.bounds.width ?? 0)) < 1 ? 10 : 0
        NSBezierPath(roundedRect: bounds.insetBy(dx: pad, dy: 0), xRadius: 6, yRadius: 6).fill()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        keyObservers.forEach(NotificationCenter.default.removeObserver)
        keyObservers = []
        guard let w = window else { return }
        for n in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            keyObservers.append(NotificationCenter.default.addObserver(forName: n, object: w, queue: .main) { [weak self] _ in
                if self?.isSelected == true { self?.needsDisplay = true }
            })
        }
    }

    deinit { keyObservers.forEach(NotificationCenter.default.removeObserver) }
}
