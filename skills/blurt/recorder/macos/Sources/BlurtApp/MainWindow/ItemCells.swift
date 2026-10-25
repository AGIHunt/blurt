// The item list's look and cells. One line per item (Linear's list): the kind's icon in its colour (a voice note's
// waveform), the id in a fixed column of quiet tabular digits, the title taking the rest (regular weight; medium only
// where "new" sets an item apart — never in the Inbox, where every row is new), then the one state mark that says
// something (to verify, in progress…; the Inbox's "new" ring only under the pointer — click it for what you can do
// from there) and a short date ("10:42", "Mon", "Oct 24"). The Inbox and In Progress come grouped by project: a quiet
// header above each run (drawn in the top band of the run's first row), so a row never repeats its project's name. An
// item whose file can't be read has a small warning mark before its title (its tooltip says to fix it in an editor).
// The full table (All Items) adds a header and Project / State columns. Fixed row heights, view-based, reused — 20k
// rows scroll like 20.
import AppKit
import BlurtCore

enum Look {
    static let rowHeight: CGFloat = 32
    /// The band above a project run's first row that holds its header (the first run's is shorter: no gap above it).
    static let sectionHeight: CGFloat = 34, firstSectionHeight: CGFloat = 28
    /// The id column: the UI font with tabular figures (system.md §2.7: a monospace O reads as zero), quiet.
    static let idFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    static let sectionFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
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
    /// "Issues", "Ideas"… — the Filter menu and the filter line name kinds in the plural.
    static func kindPlural(_ k: String) -> String {
        switch k {
        case "issue": return menuCase(T("main.filter.kind_plural.issue"))
        case "idea": return menuCase(T("main.filter.kind_plural.idea"))
        case "note": return menuCase(T("main.filter.kind_plural.note"))
        case "task": return menuCase(T("main.filter.kind_plural.task"))
        default: return kindName(k)
        }
    }
    static func stateName(_ s: String) -> String { Lifecycle.isState(s) ? T("state.\(s)") : s }
    /// "With Claude Code" / "Copied to your agent" for handed_off, else the state's name.
    static func stateLabel(_ it: ItemRow) -> String {
        guard it.state == "handed_off" else { return stateName(it.state) }
        if it.workTo == "external" { return T("state.handed_off.external") }
        if let j = it.workJob.flatMap({ JobStore.shared.job($0) }), let a = j.agent, a.isDesktop {
            return T("state.handed_off.desktop", DesktopApp.name(a.agent))
        }
        if let a = it.workAgent { return T("state.handed_off.session", AgentNames.name(a)) }
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
    /// The kind icon in its colour: 18 pt in list rows, `KindStyle.smallSize` (16) in menus, the palette and the filter.
    static func kindImage(_ kind: String, size: CGFloat = KindStyle.rowSize) -> NSImage {
        let k = "k:\(kind):\(size)"
        if let i = cache[k] { return i }
        let i = KindStyle.image(kind, size: size)
        cache[k] = i
        return i
    }
    /// A list row's leading mark: the kind's icon, or for a note that was spoken (a voice note) the waveform in the
    /// note's colour — the recording's own mark (system.md §3.2), so a voice note reads as one before its title does.
    static func leadImage(kind: String, voice: Bool, size: CGFloat = KindStyle.rowSize) -> NSImage {
        guard voice, kind == "note" else { return kindImage(kind, size: size) }
        let k = "v:\(size)"
        if let i = cache[k] { return i }
        let i = KindStyle.voiceImage(size: size)
        cache[k] = i
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

/// Cells centre their content on the row's own 32 pt band at the bottom: the run's first row is taller and keeps its
/// section header in the band above.
func rowMiddle(_ v: NSView, in cell: NSView) -> NSLayoutConstraint {
    v.centerYAnchor.constraint(equalTo: cell.bottomAnchor, constant: -Look.rowHeight / 2)
}

/// The kind icon (a voice note's waveform).
final class LeadCell: NSTableCellView {
    let icon = NSImageView()
    /// The kind icon in its colour; white on a selected (emphasized) row, like the text next to it.
    var kindImage: NSImage? { didSet { restyle() } }
    override var backgroundStyle: NSView.BackgroundStyle { didSet { restyle() } }
    private func restyle() {
        let on = backgroundStyle == .emphasized
        icon.image = onRow(kindImage, emphasized: on)
        icon.contentTintColor = on ? .white : nil
    }
    override init(frame: NSRect) {
        super.init(frame: frame)
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        icon.imageScaling = .scaleNone
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2), rowMiddle(icon, in: self),
            icon.widthAnchor.constraint(equalToConstant: 18),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// The dense list's state mark, after the title: the ring of a state that says something (to verify, in progress,
/// handed off, to do…). Where every row is new (the Inbox) the "new" ring shows only on the row under the pointer
/// (S opens the state menu for the selection), so it stays one click away without a column of identical rings.
final class MarkCell: NSTableCellView {
    let ring = StateRingButton()
    /// a "new" ring stays hidden until the row is pointed at or selected
    var quietWhenNew = false { didSet { update() } }
    var rowActive = false { didSet { if rowActive != oldValue { update() } } }
    override var backgroundStyle: NSView.BackgroundStyle { didSet { ring.emphasized = backgroundStyle == .emphasized } }
    override init(frame: NSRect) {
        super.init(frame: frame)
        ring.translatesAutoresizingMaskIntoConstraints = false
        addSubview(ring)
        NSLayoutConstraint.activate([
            ring.centerXAnchor.constraint(equalTo: centerXAnchor), rowMiddle(ring, in: self),
            ring.widthAnchor.constraint(equalToConstant: 20), ring.heightAnchor.constraint(equalToConstant: 20),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    func update() { ring.isHidden = quietWhenNew && ring.ringState == "new" && !rowActive }
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
            rowMiddle(button, in: self),
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
final class TitleCell: NSTableCellView, InlineEditable {
    let title = NSTextField(labelWithString: "")
    var editField: NSTextField { title }
    /// Unassigned rows with a suggested project: "Looks like X · Move" after the title (ProjectPicking.swift)
    let suggest = SuggestChip()
    override init(frame: NSRect) {
        super.init(frame: frame)
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        title.usesSingleLineMode = true
        title.cell?.wraps = false
        title.translatesAutoresizingMaskIntoConstraints = false
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        suggest.translatesAutoresizingMaskIntoConstraints = false
        suggest.isHidden = true
        addSubview(title)
        addSubview(suggest)
        textField = title
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            title.trailingAnchor.constraint(lessThanOrEqualTo: suggest.leadingAnchor, constant: -8),
            rowMiddle(title, in: self),
            suggest.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            rowMiddle(suggest, in: self),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The row's suggested project (nil: none, or not an Unassigned row); `move` moves this row's item there.
    func setSuggestion(_ project: String?, move: (() -> Void)?) {
        suggest.isHidden = project == nil
        if let p = project { suggest.set(project: p) } else { suggest.attributedTitle = NSAttributedString(string: "") }
        suggest.onMove = move
    }

    /// unreadable: the item's file doesn't parse — a small warning mark before the title says so in the list,
    /// before the row is even selected (its detail then says what to do).
    func set(title t: String, unread: Bool, dimmed: Bool, struck: Bool, hit: String?, unreadable: Bool = false) {
        var attrs: [NSAttributedString.Key: Any] = [.font: unread ? Look.titleUnread : Look.titleFont,
                                                    .foregroundColor: dimmed ? NSColor.secondaryLabelColor : NSColor.labelColor]
        if struck { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue; attrs[.strikethroughColor] = NSColor.tertiaryLabelColor }
        let s = NSMutableAttributedString()
        if unreadable, let mark = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: T("main.unreadable.fix_first"))?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular).applying(.init(paletteColors: [BrandColor.attnInk]))) {
            let a = NSTextAttachment()
            a.image = mark
            a.bounds = NSRect(x: 0, y: -1.5, width: mark.size.width, height: mark.size.height)
            s.append(NSAttributedString(attachment: a))
            s.append(NSAttributedString(string: " ", attributes: attrs))
        }
        s.append(NSAttributedString(string: t.isEmpty ? T("main.item.untitled") : t, attributes: attrs))
        if let h = hit {
            s.append(NSAttributedString(string: "   ", attributes: [.font: Look.subFont]))
            s.append(TitleCell.marked(SearchHit.shown(h)))
        }
        // an attributed value drops the field's line break mode: without this a long title is clipped, no ellipsis
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byTruncatingTail
        s.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: s.length))
        title.attributedStringValue = s
    }

    // MARK: rename in place (E, the menus' Rename)

    private var shown: NSAttributedString?
    /// The title becomes an editable field over the row, the whole title selected (InlineRename drives it).
    func beginEditing(_ text: String, delegate: NSTextFieldDelegate) {
        shown = title.attributedStringValue
        title.isEditable = true
        title.isSelectable = true
        title.drawsBackground = true
        title.backgroundColor = .textBackgroundColor
        title.font = Look.titleFont
        title.textColor = .labelColor
        title.stringValue = text
        title.delegate = delegate
        title.setAccessibilityLabel(T("main.rename.title"))
    }
    func setInvalid(_ on: Bool) {
        title.wantsLayer = true
        title.layer?.borderWidth = on ? 1 : 0
        title.layer?.borderColor = NSColor.systemRed.cgColor
        title.layer?.cornerRadius = 3
    }
    /// Back to a label: `text` (the new title, shown at once — the index follows) or what it showed before.
    func endEditing(showing text: String?) {
        setInvalid(false)
        title.delegate = nil
        title.isEditable = false
        title.isSelectable = false
        title.drawsBackground = false
        if let t = text, let s = shown?.mutableCopy() as? NSMutableAttributedString {
            s.replaceCharacters(in: NSRange(location: 0, length: s.length), with: t)
            title.attributedStringValue = s
        } else if let s = shown {
            title.attributedStringValue = s
        }
        shown = nil
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
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2), rowMiddle(icon, in: self),
            lead, rowMiddle(label, in: self),
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

/// The item's id ("BA-12"), left-aligned in its own fixed column so every id starts at one x (Linear's list).
final class MetaCell: NSTableCellView {
    let key = NSTextField(labelWithString: "")
    override init(frame: NSRect) {
        super.init(frame: frame)
        key.translatesAutoresizingMaskIntoConstraints = false
        key.font = Look.idFont
        key.textColor = .secondaryLabelColor
        key.lineBreakMode = .byTruncatingTail
        key.alignment = .left
        key.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(key)
        NSLayoutConstraint.activate([key.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
                                     key.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2),
                                     rowMiddle(key, in: self)])
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// Row view: VoiceOver reads the whole row as one sentence (kind, title, id, state, project, time). Selection is the
/// brand tint (BrandRowView). The first row of a project run (the grouped Inbox) is taller and draws the run's header
/// — the project's name and how many items it has here — in its top band; the selection covers the row's own band only.
/// The row under the pointer tells its state mark (the Inbox's hidden "new" ring shows then).
final class ItemRowView: BrandRowView {
    var label = "" { didSet { setAccessibilityLabel(label) } }
    /// (name, count) of the run this row starts, nil for every other row
    var section: (name: String, count: String)? { didSet { needsDisplay = true } }
    private(set) var hovering = false { didSet { if hovering != oldValue { tellMark() } } }
    private var area: NSTrackingArea?

    override var selectionBand: NSRect {
        let h = min(bounds.height, Look.rowHeight)
        return NSRect(x: bounds.minX, y: isFlipped ? bounds.maxY - h : bounds.minY, width: bounds.width, height: h)
    }

    func tellMark() {
        for case let c as MarkCell in subviews { c.rowActive = hovering }
    }
    override func didAddSubview(_ v: NSView) {
        super.didAddSubview(v)
        if let c = v as? MarkCell { c.rowActive = hovering }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        area.map(removeTrackingArea)
        let a = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(a)
        area = a
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func prepareForReuse() { super.prepareForReuse(); hovering = false; section = nil }
    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize.height != frame.height
        super.setFrameSize(newSize)
        if changed { needsDisplay = true }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard let s = section, bounds.height > Look.rowHeight + 1 else { return }
        let name = NSAttributedString(string: s.name, attributes: [.font: Look.sectionFont, .foregroundColor: NSColor.labelColor])
        let count = NSAttributedString(string: s.count, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
                                                                    .foregroundColor: NSColor.secondaryLabelColor])
        // the header ends 5 pt above the row's own band, its text where the kind icons start
        let x = (subviews.first { $0 is LeadCell }?.frame.minX ?? 4) + 2
        let nh = ceil(name.size().height)
        let y = isFlipped ? bounds.maxY - Look.rowHeight - 5 - nh : bounds.minY + Look.rowHeight + 5
        let room = max(0, bounds.width - x - 16 - count.size().width - 6)
        let w = min(ceil(name.size().width), room)
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byTruncatingMiddle
        let cut = NSMutableAttributedString(attributedString: name)
        cut.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: cut.length))
        cut.draw(in: NSRect(x: x, y: y, width: w, height: nh))
        count.draw(at: NSPoint(x: x + w + 6, y: y + (nh - ceil(count.size().height)) / 2 + (isFlipped ? 0.5 : -0.5)))
    }
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

    /// The part of the row the selection covers (a row with a section header above it keeps the header unwashed).
    var selectionBand: NSRect { bounds }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let key = window?.isKeyWindow == true && NSApp.isActive || BrandRowView.testKeyLook
        (key ? BrandColor.tint : NSColor.labelColor.withAlphaComponent(0.06)).setFill()
        // the inset / source-list styles inset the row itself; a row as wide as its table keeps a margin like theirs
        let pad: CGFloat = frame.minX < 1 && abs(frame.width - (superview?.bounds.width ?? 0)) < 1 ? 10 : 0
        NSBezierPath(roundedRect: selectionBand.insetBy(dx: pad, dy: 0), xRadius: 6, yRadius: 6).fill()
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
