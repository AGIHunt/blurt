// The detail for several selected items: what is selected and what you can do with all of it (Mail's "4 messages
// selected" over its stack, Linear's selection actions). Top-aligned at the detail's content inset, never a centred
// placeholder: the moment you pick several items is the moment you act on them.
//
//   4 items selected                                              17 pt semibold
//   [bug] 3 issues · [bulb] 1 idea · Unassigned, billing-api      what the batch is, from the rows themselves
//   [Hand Off to Claude Code…] [Move to Project…] [Keep] [⋯]      the one B primary, two native buttons, the rest in ⋯
//   (i) Choose items from one project                             why hand off can't go, when it can't (one line)
//   ┌───────────────────────────────────────────────┐
//   │ [bug] ◌ Search results flicker while typing  IN-2 │          the batch, one line each, the key in a mono column;
//   │ …                                     +3 more     │          × on hover drops a row from the selection
//   └───────────────────────────────────────────────┘
//
// What the buttons are is decided by MainWindowController.selectionPlan (the same rules as ⌘↩, the state menu and the
// Item menu: HandOffCheck, StateMenu); the ⋯ menu is built there from the same entries, so nothing is defined twice.
// Shortcuts live in the tooltips and the menu, never in prose.
import AppKit
import BlurtCore

struct SelectionPlan {
    struct Action: Equatable {
        var id: String          // hand_off | move | a K3 state action
        var title: String
        var tip: String
        var enabled = true
    }
    /// Inline, in order; `primary` (an id among them) is drawn as the brand button.
    var actions: [Action] = []
    var primary: String?
    /// Why hand off can't go for these items (HandOffCheck's sentence), shown under the buttons.
    var blocked: String?
    /// The ⋯ menu: everything else that applies to the selection.
    var more: NSMenu?
}

final class SelectionView: NSView {
    var onAction: ((String, NSView) -> Void)?
    /// × on a row: take that item out of the selection.
    var onRemove: ((String) -> Void)?

    static let maxRows = 8
    static let inset: CGFloat = 24
    static let columnWidth: CGFloat = 520

    private let scroll = NSScrollView()
    private let doc = FlippedView()
    private let title = NSTextField(labelWithString: "")
    private let summary = NSTextField(labelWithString: "")
    private let buttons = NSStackView()
    private let reason = NSStackView()
    private let reasonText = NSTextField(labelWithString: "")
    private let card = SelectionCard()
    private(set) var plan = SelectionPlan()
    private(set) var shownUIDs: [String] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingTail
        summary.font = .systemFont(ofSize: 12)
        summary.textColor = .secondaryLabelColor
        summary.lineBreakMode = .byTruncatingTail
        summary.maximumNumberOfLines = 1
        summary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.alignment = .centerY
        let info = NSImageView(image: Look.symbol("info.circle", "", size: 12) ?? NSImage())
        info.contentTintColor = .secondaryLabelColor
        reasonText.font = .systemFont(ofSize: 12)
        reasonText.textColor = .secondaryLabelColor
        reasonText.lineBreakMode = .byTruncatingTail
        reasonText.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        reason.orientation = .horizontal
        reason.spacing = 5
        reason.alignment = .centerY
        reason.addArrangedSubview(info)
        reason.addArrangedSubview(reasonText)
        card.onRemove = { [weak self] uid in self?.onRemove?(uid) }

        let column = NSStackView(views: [title, summary, buttons, reason, card])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 0
        column.setCustomSpacing(4, after: title)
        column.setCustomSpacing(16, after: summary)
        column.setCustomSpacing(8, after: buttons)
        column.setCustomSpacing(18, after: reason)
        column.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(column)
        doc.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = doc
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        let clip = scroll.contentView
        let wide = column.widthAnchor.constraint(equalToConstant: Self.columnWidth)
        wide.priority = .defaultHigh
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            doc.leadingAnchor.constraint(equalTo: clip.leadingAnchor), doc.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            doc.topAnchor.constraint(equalTo: clip.topAnchor),
            column.topAnchor.constraint(equalTo: doc.topAnchor, constant: 22),
            column.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: Self.inset),
            column.trailingAnchor.constraint(lessThanOrEqualTo: doc.trailingAnchor, constant: -Self.inset),
            column.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -24),
            wide,
            title.widthAnchor.constraint(lessThanOrEqualTo: column.widthAnchor),
            summary.widthAnchor.constraint(lessThanOrEqualTo: column.widthAnchor),
            reason.widthAnchor.constraint(lessThanOrEqualTo: column.widthAnchor),
            card.widthAnchor.constraint(equalTo: column.widthAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ items: [ItemRow], plan p: SelectionPlan) {
        plan = p
        shownUIDs = items.map(\.uid)
        title.stringValue = TP("main.detail.multi", items.count)
        summary.attributedStringValue = Self.summary(items)
        summary.toolTip = summary.stringValue
        buttons.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for a in p.actions {
            let b: NSButton
            if a.id == p.primary && a.enabled {
                let bb = BrandButton(title: a.title, target: self, action: #selector(tap(_:)))
                bb.hPad = 14
                bb.radius = nil         // a capsule, like the native buttons beside it
                b = bb
            } else {
                b = NSButton(title: a.title, target: self, action: #selector(tap(_:)))
                b.bezelStyle = .rounded
                b.controlSize = .large
            }
            b.isEnabled = a.enabled
            b.toolTip = a.tip
            b.identifier = .init(a.id)
            b.setAccessibilityHelp(a.tip)
            buttons.addArrangedSubview(b)
            if b is BrandButton { b.heightAnchor.constraint(equalToConstant: 28).isActive = true }
        }
        if let m = p.more, !m.items.isEmpty {
            let b = NSButton(image: Look.symbol("ellipsis.circle", T("main.selection.more"), size: 15) ?? NSImage(),
                             target: self, action: #selector(showMore(_:)))
            b.isBordered = false
            b.bezelStyle = .regularSquare
            b.contentTintColor = .secondaryLabelColor
            b.toolTip = T("main.selection.more")
            b.setAccessibilityLabel(T("main.selection.more"))
            b.menu = m
            b.identifier = .init("more")
            b.widthAnchor.constraint(equalToConstant: 28).isActive = true
            b.heightAnchor.constraint(equalToConstant: 28).isActive = true
            buttons.addArrangedSubview(b)
        }
        reasonText.stringValue = p.blocked ?? ""
        reasonText.toolTip = p.blocked
        reason.isHidden = p.blocked == nil
        card.show(items)
        isHidden = false
        setAccessibilityLabel([title.stringValue, summary.stringValue].joined(separator: ". "))
    }

    /// The inline button for an action id (self-tests press it).
    func button(_ id: String) -> NSButton? {
        buttons.arrangedSubviews.compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == id }
    }

    @objc private func tap(_ b: NSButton) { b.identifier.map { onAction?($0.rawValue, b) } }

    @objc private func showMore(_ b: NSButton) {
        b.menu?.popUp(positioning: nil, at: NSPoint(x: 0, y: b.bounds.maxY + 4), in: b)
    }

    /// The inline actions' ids and titles, then the ⋯ menu's titles (self-tests).
    var testDescription: [String: Any] {
        ["title": title.stringValue, "summary": summary.stringValue, "blocked": plan.blocked ?? NSNull(),
         "primary": plan.primary ?? NSNull(),
         "buttons": buttons.arrangedSubviews.compactMap { v -> String? in
            guard let b = v as? NSButton, b.identifier?.rawValue != "more" else { return nil }
            return "\(b.identifier?.rawValue ?? "")=\(b.title)\(b.isEnabled ? "" : " (off)")" },
         "more": plan.more?.items.map { $0.isSeparatorItem ? "—" : $0.title } ?? [],
         "rows": card.rowTitles]
    }

    /// "[bug] 3 issues · [bulb] 1 idea · Unassigned, billing-api": the kinds (built-in order, then the lenses, each
    /// with its icon in its colour) and where the items are.
    static func summary(_ items: [ItemRow]) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: 12)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
        let out = NSMutableAttributedString()
        func dot() { out.append(NSAttributedString(string: "  ·  ", attributes: attrs)) }
        let counts = Dictionary(grouping: items, by: \.kind).mapValues(\.count)
        let kinds = KindStyle.builtIn.filter { counts[$0] != nil } + counts.keys.filter { !KindStyle.builtIn.contains($0) }.sorted()
        for (n, k) in kinds.enumerated() {
            if n > 0 { dot() }
            let a = NSTextAttachment()
            let img = Look.kindImage(k, size: 14)
            a.image = img
            a.bounds = CGRect(x: 0, y: (font.capHeight - img.size.height) / 2, width: img.size.width, height: img.size.height)
            out.append(NSAttributedString(attachment: a))
            let c = counts[k] ?? 0
            let text: String
            switch k {
            case "issue": text = TP("main.selection.kind.issue", c)
            case "idea": text = TP("main.selection.kind.idea", c)
            case "note": text = TP("main.selection.kind.note", c)
            case "task": text = TP("main.selection.kind.task", c)
            default: text = "\(Loc.number(c)) \(Look.kindName(k))"      // a lens: its own name
            }
            out.append(NSAttributedString(string: " " + text, attributes: attrs))
        }
        var places: [String] = []
        for it in items {
            let name = it.projectID == "inbox" ? T("project.inbox") : it.projectName
            if !places.contains(name) { places.append(name) }
        }
        if !places.isEmpty {
            dot()
            out.append(NSAttributedString(string: places.count <= 2 ? places.joined(separator: Loc.isChinese ? "、" : ", ")
                                                                    : TP("main.selection.projects", places.count), attributes: attrs))
        }
        return out
    }
}

/// The selected items, one line each, on a quiet card: kind, state ring, title, key (a fixed mono column).
final class SelectionCard: NSView {
    var onRemove: ((String) -> Void)?
    private let stack = NSStackView()
    static let rowHeight: CGFloat = 30

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 6), stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.list)
        setAccessibilityLabel(T("main.selection.list"))
    }
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(isDarkAppearance ? 0.05 : 0.035).cgColor
        layer?.borderColor = NSColor.labelColor.withAlphaComponent(isDarkAppearance ? 0.1 : 0.07).cgColor
        layer?.borderWidth = 1
    }

    var rowTitles: [String] { stack.arrangedSubviews.compactMap { ($0 as? SelectionRow)?.label ?? ($0 as? NSTextField)?.stringValue } }

    func show(_ items: [ItemRow]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let shown = items.count > SelectionView.maxRows ? Array(items.prefix(SelectionView.maxRows - 1)) : items
        let keyFont = Look.monoSub
        let keyWidth = ceil(shown.map { ($0.itemID as NSString).size(withAttributes: [.font: keyFont]).width }.max() ?? 0)
        for it in shown {
            let r = SelectionRow(it, keyWidth: keyWidth, removable: true)
            r.onRemove = { [weak self] in self?.onRemove?(it.uid) }
            stack.addArrangedSubview(r)
            r.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        if shown.count < items.count {
            let more = NSTextField(labelWithString: TP("main.selection.more_rows", items.count - shown.count))
            more.font = .systemFont(ofSize: 12)
            more.textColor = .secondaryLabelColor
            let wrap = NSView()
            more.translatesAutoresizingMaskIntoConstraints = false
            wrap.addSubview(more)
            NSLayoutConstraint.activate([
                wrap.heightAnchor.constraint(equalToConstant: 26),
                more.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 12 + 16 + 8 + 14 + 8),
                more.centerYAnchor.constraint(equalTo: wrap.centerYAnchor),
            ])
            stack.addArrangedSubview(wrap)
            wrap.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }
}

final class SelectionRow: NSView {
    var onRemove: (() -> Void)?
    let label: String
    private let remove: NSButton
    private let key: NSTextField
    private var hover = false { didSet { remove.isHidden = !hover; needsDisplay = true } }

    init(_ it: ItemRow, keyWidth: CGFloat, removable: Bool) {
        let t = it.title.isEmpty ? T("main.item.untitled") : it.title
        label = t
        remove = NSButton(image: Look.symbol("xmark.circle.fill", T("main.selection.remove"), size: 13) ?? NSImage(),
                          target: nil, action: nil)
        key = NSTextField(labelWithString: it.itemID)
        super.init(frame: .zero)
        let kind = NSImageView(image: Look.kindImage(it.kind, size: KindStyle.smallSize))
        kind.setAccessibilityElement(false)
        let ring = NSImageView(image: Look.ring(it.state, size: 14))
        ring.toolTip = Look.stateLabel(it)
        ring.setAccessibilityElement(false)
        let title = NSTextField(labelWithString: t)
        title.font = .systemFont(ofSize: 13)
        title.textColor = it.discarded || Lifecycle.closed.contains(it.state) ? .secondaryLabelColor : .labelColor
        title.lineBreakMode = .byTruncatingTail
        title.toolTip = t
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        key.font = Look.monoSub
        key.textColor = .secondaryLabelColor
        key.toolTip = it.projectID == "inbox" ? T("project.inbox") : it.projectName
        remove.isBordered = false
        remove.bezelStyle = .regularSquare
        remove.contentTintColor = .tertiaryLabelColor
        remove.toolTip = T("main.selection.remove")
        remove.target = self
        remove.action = #selector(removeTapped)
        remove.isHidden = true
        remove.isEnabled = removable
        for v in [kind, ring, title, key, remove] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: SelectionCard.rowHeight),
            kind.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12), kind.centerYAnchor.constraint(equalTo: centerYAnchor),
            kind.widthAnchor.constraint(equalToConstant: 16), kind.heightAnchor.constraint(equalToConstant: 16),
            ring.leadingAnchor.constraint(equalTo: kind.trailingAnchor, constant: 8), ring.centerYAnchor.constraint(equalTo: centerYAnchor),
            ring.widthAnchor.constraint(equalToConstant: 14), ring.heightAnchor.constraint(equalToConstant: 14),
            title.leadingAnchor.constraint(equalTo: ring.trailingAnchor, constant: 8), title.centerYAnchor.constraint(equalTo: centerYAnchor),
            key.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 12),
            key.trailingAnchor.constraint(equalTo: remove.leadingAnchor, constant: -6),
            key.widthAnchor.constraint(equalToConstant: keyWidth + 2), key.centerYAnchor.constraint(equalTo: centerYAnchor),
            remove.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8), remove.centerYAnchor.constraint(equalTo: centerYAnchor),
            remove.widthAnchor.constraint(equalToConstant: 16), remove.heightAnchor.constraint(equalToConstant: 16),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.row)
        setAccessibilityLabel([Look.kindName(it.kind), t, it.itemID, Look.stateLabel(it)].joined(separator: ", "))
        if removable {
            setAccessibilityCustomActions([NSAccessibilityCustomAction(name: T("main.selection.remove")) { [weak self] in
                self?.onRemove?(); return true
            }])
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func removeTapped() { onRemove?() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hover = remove.isEnabled }
    override func mouseExited(with event: NSEvent) { hover = false }

    override func draw(_ dirtyRect: NSRect) {
        guard hover else { return }
        NSColor.labelColor.withAlphaComponent(0.05).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 6, yRadius: 6).fill()
    }
}
