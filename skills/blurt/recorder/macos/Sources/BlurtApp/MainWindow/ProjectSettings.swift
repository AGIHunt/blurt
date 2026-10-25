// Project settings (K2), a sheet on the main window: name, key (the item id prefix), description (what the AI reads
// when it sorts captures into projects), the default agent, and whether hand-offs get their own git worktree.
// Saved with projects.py set; the registry is never written here.
//
// The look is SettingsKit's row grammar in AppKit (§3.4): the project's name as the title, then two short sections —
// Project (name, key, description) and Hand-off (agent, separate branch) — each a 13 pt semibold heading, rows over a
// hairline (label on the left, value on the right) and at most one 12 pt footnote. One rhythm: 12 pt between rows,
// 20 pt between sections; every value's text starts on one left edge (`M.valueText`). The folder sits in the footer,
// opposite Cancel / Save, and shows itself in Finder; Save stays the native default (↩, §3.3).
import AppKit
import BlurtCore

final class ProjectSettingsSheet: NSObject, NSTextFieldDelegate, NSTextViewDelegate {
    private static var open: ProjectSettingsSheet?
    private let panel: NSPanel
    private let project: Project
    private let onSave: ([String: Any]) -> Void
    private let name = NSTextField()
    private let key = NSTextField()
    private let keyCaption = NSTextField(wrappingLabelWithString: "")
    private let desc = DescriptionTextView()
    private let descBox = FieldBox()
    private let agent = NSPopUpButton()
    private let worktree = NSSwitch()
    /// a dialog's default stays native (§3.3), like every other sheet's: ↩ (⌘↩ from the description)
    private let save = SheetDefaultButton()
    /// projects.py set refuses a new key once the store has items (their ids carry it): the key is read-only then.
    private let keyLocked: Bool

    /// The sheet's measures (pt).
    enum M {
        static let width: CGFloat = 480
        static let side: CGFloat = 24
        static let labelWidth: CGFloat = 96         // the label column; values start after it
        static let rowPad: CGFloat = 6              // above and below a row's control: 12 between rows
        static let sectionGap: CGFloat = 20
        static let caption: CGFloat = 12
        /// where a rounded field draws its first character, from its outer edge: the description and the locked key
        /// start their text there too, so the column has one left edge
        static let valueText: CGFloat = 6.5
        static let descLines: CGFloat = 3
    }

    static func show(_ p: Project, on window: NSWindow, onSave: @escaping ([String: Any]) -> Void) {
        let s = ProjectSettingsSheet(p, onSave: onSave)
        open = s
        window.beginSheet(s.panel) { _ in open = nil }
        s.panel.makeFirstResponder(s.name)
    }

    private init(_ p: Project, onSave: @escaping ([String: Any]) -> Void) {
        project = p
        self.onSave = onSave
        keyLocked = ((try? FileManager.default.contentsOfDirectory(atPath: p.store.appendingPathComponent("items").path)) ?? [])
            .contains { $0.hasSuffix(".md") && !$0.hasPrefix(".") }
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: M.width, height: 400), styleMask: [.titled, .docModalWindow],
                        backing: .buffered, defer: true)
        super.init()
        panel.title = T("main.project.settings.subtitle")

        // header: the project, and what this sheet is
        let title = NSTextField(labelWithString: p.name)
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.setAccessibilityRole(.staticText)
        let subtitle = caption(T("main.project.settings.subtitle"))
        let header = vstack([title, subtitle], spacing: 2)

        // Project: name, key, description
        name.stringValue = p.name
        name.bezelStyle = .roundedBezel
        name.font = .systemFont(ofSize: 13)
        name.delegate = self                // an emptied name turns Save off
        name.setAccessibilityLabel(T("main.project.name"))

        let keyValue: NSView
        keyCaption.font = .systemFont(ofSize: M.caption)
        keyCaption.textColor = .secondaryLabelColor
        if keyLocked {
            let token = KeyToken(p.key, inset: M.valueText)
            token.toolTip = T("main.project.key.locked")
            keyCaption.toolTip = token.toolTip
            token.setAccessibilityLabel("\(T("main.project.key")) \(p.key). \(T("main.project.key.locked"))")
            keyValue = hstack([token, keyCaption], spacing: 8)
        } else {
            key.stringValue = p.key
            key.bezelStyle = .roundedBezel
            key.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
            key.delegate = self
            key.placeholderString = "BA"
            key.setAccessibilityLabel(T("main.project.key"))
            key.widthAnchor.constraint(equalToConstant: 72).isActive = true
            keyValue = hstack([key, keyCaption], spacing: 8)
        }
        keyCaption.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        desc.string = p.description
        desc.placeholder = T("main.project.description.placeholder")
        desc.delegate = self
        desc.onCommandReturn = { [weak self] in
            guard let self else { return }
            if self.save.isEnabled { self.saveTapped() } else { NSSound.beep() }
        }
        desc.onFocus = { [weak self] on in self?.descBox.focused = on }
        desc.setAccessibilityLabel(T("main.project.description"))
        desc.toolTip = T("main.project.description.keys")
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = desc
        desc.minSize = .zero
        desc.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        desc.isVerticallyResizable = true
        desc.isHorizontallyResizable = false
        desc.autoresizingMask = [.width]
        desc.textContainer?.widthTracksTextView = true
        descBox.embed(scroll)
        let lineHeight = ceil(NSLayoutManager().defaultLineHeight(for: desc.font ?? .systemFont(ofSize: 13)))
        descBox.heightAnchor.constraint(equalToConstant: lineHeight * M.descLines + 2 * desc.textContainerInset.height + 2 + 2 * FieldBox.ring)
            .isActive = true

        let projectSection = section(T("main.project.section.project"), rows: [
            formRow(T("main.project.name"), name, baseline: name),
            formRow(T("main.project.key"), keyValue, baseline: keyLocked ? keyValue.subviews[0] : key),
            formRow(T("main.project.description"), descBox, baselineOffset: FieldBox.ring + desc.firstBaseline, outset: FieldBox.ring),
        ], footnote: T("main.project.description.note"))

        // Hand-off: agent, separate branch
        let resolved = (Config.shared["record.default_agent"] as? String).flatMap(AgentHub.shared.def) ?? AgentHub.shared.order().first
        agent.addItem(withTitle: resolved.map { T("main.project.agent.default_named", $0.name) } ?? T("main.project.agent.default"))
        agent.lastItem?.representedObject = nil
        agent.menu?.addItem(.separator())
        for d in AgentHub.shared.defs {
            agent.addItem(withTitle: d.name)
            agent.lastItem?.representedObject = d.id
            if d.id == p.defaultAgent { agent.select(agent.lastItem) }
        }
        agent.setAccessibilityLabel(T("main.project.agent"))
        agent.setContentHuggingPriority(.required, for: .horizontal)

        worktree.state = p.isGitRepo && p.worktree ? .on : .off
        worktree.isEnabled = p.isGitRepo
        worktree.controlSize = .small
        worktree.setAccessibilityLabel(T("main.project.worktree"))
        let wtDetail = p.isGitRepo ? T("main.project.worktree.note") : T("main.project.worktree.no_git")
        worktree.setAccessibilityHelp(wtDetail)

        let handoffSection = section(T("main.project.section.handoff"), rows: [
            settingRow(T("main.project.agent"), detail: nil, control: agent),
            settingRow(T("main.project.worktree"), detail: wtDetail, control: worktree, enabled: p.isGitRepo),
        ], footnote: nil)

        // footer: the folder (shows itself in Finder), then Cancel and Save
        let folder = NSButton(title: p.path.lastPathComponent, target: self, action: #selector(revealTapped))
        folder.isBordered = false
        folder.font = .systemFont(ofSize: M.caption)
        folder.contentTintColor = .secondaryLabelColor
        folder.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
        folder.imagePosition = .imageLeading
        folder.imageHugsTitle = true
        (folder.cell as? NSButtonCell)?.lineBreakMode = .byTruncatingMiddle
        folder.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        folder.toolTip = "\(T("action.reveal_in_finder"))\n\((p.path.path as NSString).abbreviatingWithTildeInPath)"
        folder.setAccessibilityLabel("\(T("action.reveal_in_finder")): \(p.path.lastPathComponent)")
        folder.widthAnchor.constraint(lessThanOrEqualToConstant: 200).isActive = true

        let cancel = NSButton(title: T("action.cancel"), target: self, action: #selector(cancelTapped))
        cancel.keyEquivalent = "\u{1b}"
        save.title = T("action.save")
        save.bezelStyle = .rounded
        save.target = self
        save.action = #selector(saveTapped)
        save.keyEquivalent = "\r"
        save.textView = desc
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let footer = hstack([folder, spacer, cancel, save], spacing: 8)
        footer.alignment = .centerY
        cancel.widthAnchor.constraint(greaterThanOrEqualToConstant: 76).isActive = true
        save.widthAnchor.constraint(equalTo: cancel.widthAnchor).isActive = true

        let stack = vstack([header, projectSection, handoffSection, footer], spacing: M.sectionGap)
        stack.setCustomSpacing(16, after: header)
        stack.edgeInsets = NSEdgeInsets(top: 18, left: M.side, bottom: 18, right: M.side)
        for v in [header, projectSection, handoffSection, footer] {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -2 * M.side).isActive = true
        }
        stack.widthAnchor.constraint(equalToConstant: M.width).isActive = true
        panel.contentView = stack
        panel.setContentSize(stack.fittingSize)
        panel.autorecalculatesKeyViewLoop = true
        validate()
    }

    // MARK: building blocks

    private func caption(_ s: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: s)
        l.font = .systemFont(ofSize: M.caption)
        l.textColor = .secondaryLabelColor
        l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return l
    }

    private func vstack(_ v: [NSView], spacing: CGFloat) -> NSStackView {
        let s = NSStackView(views: v)
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = spacing
        s.setHuggingPriority(.defaultHigh, for: .vertical)
        return s
    }

    private func hstack(_ v: [NSView], spacing: CGFloat) -> NSStackView {
        let s = NSStackView(views: v)
        s.orientation = .horizontal
        s.alignment = .firstBaseline
        s.spacing = spacing
        return s
    }

    /// A section: its heading, each row over a hairline, an optional one-line footnote.
    private func section(_ heading: String, rows: [NSView], footnote: String?) -> NSView {
        let h = NSTextField(labelWithString: heading)
        h.font = .systemFont(ofSize: 13, weight: .semibold)
        h.setAccessibilityRole(.staticText)
        var views: [NSView] = [h]
        for r in rows {
            let line = NSBox()
            line.boxType = .separator
            views += [line, r]
        }
        let s = vstack(views, spacing: 0)
        s.setCustomSpacing(6, after: h)
        for v in views.dropFirst() { v.widthAnchor.constraint(equalTo: s.widthAnchor).isActive = true }
        if let f = footnote {
            let c = caption(f)
            s.addArrangedSubview(c)
            s.setCustomSpacing(2, after: rows.last!)
            c.widthAnchor.constraint(equalTo: s.widthAnchor).isActive = true
        }
        return s
    }

    /// A form row: the label in the left column, the value filling the rest; the label sits on the value's first
    /// baseline (a field's, or `baselineOffset` from the value's top for the description).
    /// `outset`: the value draws that far outside its box (room for a focus ring), so it is placed that much out.
    private func formRow(_ label: String, _ value: NSView, baseline: NSView? = nil, baselineOffset: CGFloat = 0, outset: CGFloat = 0) -> NSView {
        let row = NSView()
        let l = NSTextField(labelWithString: label)
        l.font = .systemFont(ofSize: 13)
        l.lineBreakMode = .byTruncatingTail
        for v in [l, value] { v.translatesAutoresizingMaskIntoConstraints = false; row.addSubview(v) }
        var c = [
            l.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            l.widthAnchor.constraint(lessThanOrEqualToConstant: M.labelWidth - 8),
            value.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: M.labelWidth - outset),
            value.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: outset),
            value.topAnchor.constraint(equalTo: row.topAnchor, constant: M.rowPad - outset),
            value.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -M.rowPad + outset),
        ]
        if let b = baseline {
            c.append(l.firstBaselineAnchor.constraint(equalTo: b.firstBaselineAnchor))
        } else {
            c.append(l.firstBaselineAnchor.constraint(equalTo: value.topAnchor, constant: baselineOffset))
        }
        NSLayoutConstraint.activate(c)
        return row
    }

    /// A setting row (SettingsKit's SettingRow): the title and its one-line description on the left, the control on
    /// the right; the description 2 pt under the title.
    private func settingRow(_ title: String, detail: String?, control: NSView, enabled: Bool = true) -> NSView {
        let row = NSView()
        let t = NSTextField(labelWithString: title)
        t.font = .systemFont(ofSize: 13)
        t.textColor = enabled ? .labelColor : .secondaryLabelColor
        var left: [NSView] = [t]
        if let d = detail {
            let c = caption(d)
            if !enabled { c.textColor = .tertiaryLabelColor }
            left.append(c)
        }
        let text = vstack(left, spacing: 2)
        for v in [text, control] { v.translatesAutoresizingMaskIntoConstraints = false; row.addSubview(v) }
        let minHeight: CGFloat = 22
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            text.trailingAnchor.constraint(lessThanOrEqualTo: control.leadingAnchor, constant: -16),
            text.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor, constant: M.rowPad),
            text.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            control.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            control.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: minHeight + 2 * M.rowPad),
            row.heightAnchor.constraint(greaterThanOrEqualTo: text.heightAnchor, constant: 2 * M.rowPad),
        ])
        let fit = row.heightAnchor.constraint(equalToConstant: 0)
        fit.priority = .defaultLow
        fit.isActive = true
        return row
    }

    // MARK: editing

    func controlTextDidChange(_ obj: Notification) { validate() }

    /// Tab and ⇧Tab leave the description (a text view would type a tab); Return adds a line, ⌘Return saves.
    func textView(_ textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.insertTab(_:)): panel.selectNextKeyView(nil); return true
        case #selector(NSResponder.insertBacktab(_:)): panel.selectPreviousKeyView(nil); return true
        default: return false
        }
    }

    /// K2: ^[A-Z][A-Z0-9]{1,4}$, and "IN" belongs to Unassigned.
    private var keyValid: Bool {
        let k = key.stringValue
        return k.range(of: "^[A-Z][A-Z0-9]{1,4}$", options: .regularExpression) != nil && k != "IN"
    }

    private func validate() {
        let up = key.stringValue.uppercased()
        if !keyLocked, up != key.stringValue { key.stringValue = up }
        save.isEnabled = (keyLocked || keyValid) && !name.stringValue.trimmingCharacters(in: .whitespaces).isEmpty
        let k = keyLocked ? project.key : key.stringValue
        keyCaption.stringValue = keyLocked || keyValid ? T("main.project.key.note", k)
            : k == "IN" ? T("main.project.key.taken") : T("main.project.key.invalid")
        keyCaption.textColor = keyLocked || keyValid ? .secondaryLabelColor : BrandColor.err
    }

    /// Test hook (SelfTests `mainprojectset FIELD VALUE`): type into the open sheet's key or description, as the user
    /// would; returns what the sheet now shows.
    static func testSet(_ field: String, _ value: String) -> [String: Any] {
        guard let s = open else { return ["error": "no sheet"] }
        switch field {
        case "key" where !s.keyLocked:
            s.key.stringValue = value
            s.panel.makeFirstResponder(s.key)
        case "description":
            s.panel.makeFirstResponder(s.desc)
            s.desc.string = value
            s.desc.didChangeText()
        case "press":                   // press return|cmdreturn in the description: a line, or Save
            s.panel.makeFirstResponder(s.desc)
            let lines = s.desc.string.components(separatedBy: "\n").count
            let flags: NSEvent.ModifierFlags = value == "cmdreturn" ? .command : []
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: s.panel.windowNumber, context: nil, characters: "\r",
                                            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) {
                    NSApp.sendEvent(e)
                }
            }
            return ["lines_before": lines, "lines": s.desc.string.components(separatedBy: "\n").count, "open": open != nil && s.panel.isVisible]
        default: return ["error": "can't set \(field)"]
        }
        s.validate()
        return ["key": s.keyLocked ? s.project.key : s.key.stringValue, "caption": s.keyCaption.stringValue, "save": s.save.isEnabled]
    }

    @objc func revealTapped() { NSWorkspace.shared.activateFileViewerSelecting([project.path]) }

    @objc func cancelTapped() { panel.sheetParent?.endSheet(panel) }

    @objc func saveTapped() {
        var patch: [String: Any] = [:]
        let n = name.stringValue.trimmingCharacters(in: .whitespaces)
        if n != project.name { patch["name"] = n }
        if !keyLocked, key.stringValue != project.key { patch["key"] = key.stringValue }
        if desc.string != project.description { patch["description"] = desc.string }
        let a = agent.selectedItem?.representedObject as? String
        if a != project.defaultAgent { patch["default_agent"] = a ?? NSNull() }
        if project.isGitRepo, (worktree.state == .on) != project.worktree { patch["worktree"] = worktree.state == .on }
        panel.sheetParent?.endSheet(panel)
        if !patch.isEmpty { onSave(patch) }
    }
}

/// The sheet's default button: ↩ saves from every field but the description, where it adds a line (⌘↩ saves there).
private final class SheetDefaultButton: NSButton {
    weak var textView: NSTextView?
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        if let tv = textView, window?.firstResponder === tv, e.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
            return false
        }
        return super.performKeyEquivalent(with: e)
    }
}

/// The description: a real text view (scrolls past three lines), with a placeholder and ⌘↩.
private final class DescriptionTextView: NSTextView {
    var placeholder = "" { didSet { needsDisplay = true } }
    var onCommandReturn: (() -> Void)?
    var onFocus: ((Bool) -> Void)?

    convenience init() {
        self.init(frame: NSRect(x: 0, y: 0, width: 300, height: 60))
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        drawsBackground = false
        font = .systemFont(ofSize: 13)
        textColor = .labelColor
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        // the text starts where a rounded field's does (ProjectSettingsSheet.M.valueText)
        textContainerInset = NSSize(width: ProjectSettingsSheet.M.valueText - 5, height: 4)
        textContainer?.lineFragmentPadding = 5
    }

    /// From the box's top to the first line's baseline (the row's label sits on it).
    var firstBaseline: CGFloat { 1 + textContainerInset.height + ceil((font ?? .systemFont(ofSize: 13)).ascender) }

    override func draw(_ r: NSRect) {
        super.draw(r)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let f = font ?? .systemFont(ofSize: 13)
        let o = textContainerOrigin
        NSAttributedString(string: placeholder, attributes: [.font: f, .foregroundColor: NSColor.placeholderTextColor])
            .draw(at: NSPoint(x: o.x + (textContainer?.lineFragmentPadding ?? 0), y: o.y))
    }

    override func didChangeText() { super.didChangeText(); needsDisplay = true }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocus?(true) }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { onFocus?(false) }
        return ok
    }

    /// ⌘↩ saves. A key equivalent reaches the window's views before the main menu (whose ⌘↩ is Hand Off to Agent).
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        if window?.firstResponder === self, [36, 76].contains(e.keyCode),
           e.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
            onCommandReturn?()
            return true
        }
        return super.performKeyEquivalent(with: e)
    }
}

/// The description's frame: drawn like a rounded text field (fill, a hairline border, and the accent focus ring while
/// it is being edited), so Name and Description read as the same kind of control. The view is `ring` pt larger than
/// the box on every side, room for the ring; the row places it that much outside the value column.
private final class FieldBox: NSView {
    static let ring: CGFloat = 3
    var focused = false { didSet { needsDisplay = true } }
    private let radius: CGFloat = 5

    func embed(_ v: NSView) {
        let i = Self.ring + 1
        v.translatesAutoresizingMaskIntoConstraints = false
        addSubview(v)
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: leadingAnchor, constant: i), v.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -i),
            v.topAnchor.constraint(equalTo: topAnchor, constant: i), v.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -i),
        ])
    }

    override var isOpaque: Bool { false }

    /// the system's own rounded field bezel, drawn at the box's size: the same fill and edge as Name in both modes
    private let bezel: NSTextFieldCell = {
        let c = NSTextFieldCell(textCell: "")
        c.isBezeled = true
        c.bezelStyle = .roundedBezel
        c.drawsBackground = true
        c.backgroundColor = .textBackgroundColor
        return c
    }()

    override func draw(_ r: NSRect) {
        let inner = bounds.insetBy(dx: Self.ring, dy: Self.ring)
        bezel.draw(withFrame: inner, in: self)
        guard focused, window?.isKeyWindow == true else { return }
        let ring = NSBezierPath(roundedRect: inner.insetBy(dx: -Self.ring / 2 + 0.5, dy: -Self.ring / 2 + 0.5),
                                xRadius: radius + 1, yRadius: radius + 1)
        ring.lineWidth = Self.ring
        NSColor.keyboardFocusIndicatorColor.setStroke()
        ring.stroke()
    }
}

/// A locked key: a small neutral token with a lock, its text on the value column's text edge.
private final class KeyToken: NSView {
    private let text: NSAttributedString
    private let inset: CGFloat
    private let lock = NSImageView()
    private static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
    private let height: CGFloat = 20

    init(_ key: String, inset: CGFloat) {
        text = NSAttributedString(string: key, attributes: [.font: Self.font, .foregroundColor: NSColor.secondaryLabelColor])
        self.inset = inset
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        lock.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        lock.contentTintColor = .secondaryLabelColor
        lock.setAccessibilityElement(false)
        addSubview(lock)
    }
    required init?(coder: NSCoder) { fatalError() }

    private var lockSize: NSSize { lock.image?.size ?? .zero }
    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil(inset + text.size().width + 5 + lockSize.width + 6), height: height)
    }
    override var firstBaselineOffsetFromTop: CGFloat { textY + ceil(Self.font.ascender) }
    private var textY: CGFloat { floor((height - (Self.font.ascender - Self.font.descender)) / 2) }
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let s = lockSize
        lock.frame = NSRect(x: inset + ceil(text.size().width) + 5, y: floor((height - s.height) / 2), width: s.width, height: s.height)
    }

    override func draw(_ r: NSRect) {
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        text.draw(at: NSPoint(x: inset, y: textY))
    }
}
