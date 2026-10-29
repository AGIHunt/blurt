// The middle column: the place's heading, the running jobs (K4) and the notices above one view-based NSTableView with
// fixed row heights. One dense row grammar in every place (kind, id, title, the state only where the list doesn't say
// it, a short date), grouped where it helps (ListSections: the Inbox by project in the one project order, Unassigned
// last; In Progress, All Items and a project by state). The kind / state filter and the sort live in the toolbar's
// Filter menu (and the View menu); a quiet line above the list says which filter is on, with Clear, only while one is.
// Keyboard-first: J/K, ↩, ⌘↩ (hand off), E, M (move to a project: a type-to-filter popover), 1–4 (kind), Space (Quick
// Look), ⌘C (path), and K3's state keys — A keep, D done, R the one way back (send back / take back / reopen /
// restore), W won't do, X / ⌫ discard, S the state menu. Rows drag out as their primary frame (a file) and onto a
// project in the sidebar (move). In Unassigned, a row an organizing run suggested a project for ends in "Looks like X ·
// Move", and the groups of them sit above the list with Move All (ProjectPicking.swift). The empty states
// (EmptyStateView) own the window when a place has nothing: first run, inbox zero, nothing listed yet, a missing folder.
import AppKit
import BlurtCore
import Quartz
import Carbon.HIToolbox

protocol ItemListActions: AnyObject {
    func listSelectionChanged()
    func openSelection()                       // ↩: focus the detail
    func handOffSelection()                    // ⌘↩
    func renameSelection()                     // E
    func setKind(_ kind: String)               // 1–4
    func act(key: String)                      // A D R W X ⌫: K3's actions, each item from its own state
    func showStateMenu(row: Int?, from view: NSView?)   // S, a click on a row's ring
    func copyPaths()                           // ⌘C
    func contextMenu(for rows: IndexSet) -> NSMenu?
    func showShortcuts()                       // ?
    func focusSearch()                         // /
    func emptyAction(_ tag: Int)               // buttons in the empty states
    func selectJob(_ id: String)               // a row of the jobs section
    /// ↑ / ↓ at the edge between the jobs and the items: true when it moved among the jobs (or back to the items)
    func stepJobs(_ d: Int, fromRow row: Int) -> Bool
    /// Items to a project, the user's move (⌘Z puts them back): a row's "Looks like X · Move", a group's Move All
    func move(uids: [String], to project: String)
    func pickProject()                         // M: the Move popover at the selection
}

/// Pasteboard type for item uids dragged inside the window (onto a project in the sidebar).
extension NSPasteboard.PasteboardType {
    static let blurtItems = NSPasteboard.PasteboardType("dev.blurt.items")
}

final class ItemTableView: NSTableView {
    weak var actions: ItemListActions?
    var quickLook: (() -> Void)?

    override func keyDown(with e: NSEvent) {
        let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
        let ch = e.charactersIgnoringModifiers ?? ""
        if mods == .command, e.keyCode == 36 || e.keyCode == 76 { actions?.handOffSelection(); return }
        // ⌘⌫ = delete these (Finder's Move to Trash): the items are discarded, as ⌫ does — never the project
        if mods == .command, e.keyCode == 51 || e.keyCode == 117 { actions?.act(key: "delete"); return }
        if mods.isEmpty || mods == .shift {
            switch (e.keyCode, ch) {
            case (36, _), (76, _): actions?.openSelection(); return
            case (49, _): quickLook?(); return
            case (51, _), (117, _): actions?.act(key: "delete"); return
            case (_, "j"): move(1); return
            case (_, "k"): move(-1); return
            // plain ↑ / ↓ as J / K, so they reach the jobs above the list too (⇧ extends the selection as usual)
            case (125, _) where mods.isEmpty: move(1); return
            case (126, _) where mods.isEmpty: move(-1); return
            case (_, "e"): actions?.renameSelection(); return
            case (_, "m") where mods.isEmpty: actions?.pickProject(); return
            case (_, "s"): actions?.showStateMenu(row: selectedRowIndexes.first, from: nil); return
            case (_, "a"), (_, "d"), (_, "r"), (_, "w"), (_, "x"): actions?.act(key: ch.lowercased()); return
            case (_, "/"): actions?.focusSearch(); return
            case (_, "?"): actions?.showShortcuts(); return
            case (_, "1"): actions?.setKind("issue"); return
            case (_, "2"): actions?.setKind("idea"); return
            case (_, "3"): actions?.setKind("note"); return
            case (_, "4"): actions?.setKind("task"); return
            default: break
            }
        }
        super.keyDown(with: e)
    }

    func move(_ d: Int) {
        // ↑ from the first item enters the running jobs above the list, ↓ from the last job comes back (micro 15)
        if actions?.stepJobs(d, fromRow: selectedRow) == true { return }
        guard numberOfRows > 0 else { return }
        let cur = selectedRow < 0 ? (d > 0 ? -1 : numberOfRows) : selectedRow
        let n = max(0, min(numberOfRows - 1, cur + d))
        selectRowIndexes([n], byExtendingSelection: false)
        scrollRowToVisible(n)
    }

    @objc func copy(_ sender: Any?) { actions?.copyPaths() }

    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        let r = row(at: p)
        guard r >= 0 else { return nil }
        if !selectedRowIndexes.contains(r) { selectRowIndexes([r], byExtendingSelection: false) }
        return actions?.contextMenu(for: selectedRowIndexes)
    }

    // Quick Look panel (Space): the controller supplies the items
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = (delegate as? QLPreviewPanelDataSource)
        panel.delegate = (delegate as? QLPreviewPanelDelegate)
    }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }
}

/// A row whose title can be renamed in place: an item's title (TitleCell), a project's name in the sidebar (SourceCell).
protocol InlineEditable: AnyObject {
    var editField: NSTextField { get }
    func beginEditing(_ text: String, delegate: NSTextFieldDelegate)
    func setInvalid(_ on: Bool)
    func endEditing(showing text: String?)
}

/// Rename in place (micro 1, 10): the row's title turns into a field with the whole title selected, its glyphs where they
/// were. Return, Tab or a click elsewhere commits; Esc puts the title back. An empty title is refused right there (the
/// field's edge in `err`, the reason at its end, a beep — it never commits). The focus goes back to the list with the
/// row still selected; ⌘Z undoes it ("Undo Rename").
final class InlineRename: NSObject, NSTextFieldDelegate {
    let cell: InlineEditable
    let uid: String
    let original: String
    let commit: (String) -> Void
    let done: () -> Void
    private var finished = false

    init(cell: InlineEditable, uid: String, original: String, commit: @escaping (String) -> Void, done: @escaping () -> Void) {
        self.cell = cell
        self.uid = uid
        self.original = original
        self.commit = commit
        self.done = done
        super.init()
    }

    func start() {
        cell.beginEditing(original, delegate: self)
        cell.editField.window?.makeFirstResponder(cell.editField)
        cell.editField.currentEditor()?.selectAll(nil)
        // a test build shot in the background draws the key window's look (BrandRowView.testKeyLook): a window that isn't
        // key greys its selection whatever the text view's attributes say, so the whole title is painted as selected
        if BrandRowView.testKeyLook, let tv = cell.editField.currentEditor() as? NSTextView {
            let all = NSRange(location: 0, length: (tv.string as NSString).length)
            tv.setSelectedRange(NSRange(location: all.length, length: 0))
            tv.layoutManager?.addTemporaryAttribute(.backgroundColor, value: NSColor.selectedTextBackgroundColor, forCharacterRange: all)
        }
    }

    private func clearTestSelection() {
        guard BrandRowView.testKeyLook, let tv = cell.editField.currentEditor() as? NSTextView else { return }
        tv.layoutManager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: (tv.string as NSString).length))
    }

    var text: String { cell.editField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }

    func controlTextDidChange(_ obj: Notification) { cell.setInvalid(text.isEmpty) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.cancelOperation(_:)): finish(save: false); return true
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
            if text.isEmpty { NSSound.beep(); cell.setInvalid(true); return true }
            finish(save: true)
            return true
        default: return false
        }
    }

    /// A click elsewhere: commit what's there (an empty title puts the old one back).
    func controlTextDidEndEditing(_ obj: Notification) { finish(save: !text.isEmpty) }

    func finish(save: Bool) {
        guard !finished else { return }
        finished = true
        clearTestSelection()
        let t = text
        let changed = save && t != original
        cell.endEditing(showing: changed ? t : nil)
        done()
        if changed { commit(t) }
    }
}

/// The one empty state (docs/design/system.md §3.5, `EmptyState` metrics, the same as SwiftUI's `EmptyStateContent`).
/// Three looks, one layout:
///   • friendly — the brand mark (Peep alone, idling; thinking while a first read of your items runs): first run,
///     inbox zero, nothing here yet, a first read of your items. Its first button is the view's one primary (BrandButton, ↩) when it moves you on.
///   • miss — a quiet symbol (a search or a filter that matched nothing): no brand, and its buttons only undo the
///     search or the filter, so they are plain and never take ↩.
///   • trouble — a quiet symbol (a scan that failed, a folder that's gone): warnings are never brand; its first button
///     is the native default (↩).
/// Everything sits on one centre line, its middle about 40 % down the pane (the optical centre: the space above is
/// two thirds of the space below); a hint that wraps is balanced (no word alone on its last line); a path is one line,
/// cut in the middle, the whole path its tooltip; a quiet text link (brand ink, never ↩) can follow the buttons.
final class EmptyStateView: NSView {
    enum Tone { case friendly, miss, trouble }
    let icon = NSImageView()
    let mark = BrandMarkView()
    let title = NSTextField(wrappingLabelWithString: "")
    let message = NSTextField(wrappingLabelWithString: "")
    let path = NSTextField(labelWithString: "")
    let buttons = NSStackView()
    let link = NSButton()
    let spinner = TrackedSpinner(size: 22)          // the brand arc on a faint track: reads as busy, never as a stray "("
    var onButton: ((Int) -> Void)?
    /// tags whose button only undoes a search or a filter: never the primary, never ↩
    static let secondaryTags: Set<Int> = [2, 9]
    private let stack = NSStackView()
    private var messageWidth: NSLayoutConstraint!
    private(set) var tone: Tone = .friendly
    private var primary: NSButton?

    override init(frame: NSRect) {
        super.init(frame: frame)
        title.font = .systemFont(ofSize: EmptyState.titleSize, weight: .semibold)
        title.alignment = .center
        title.maximumNumberOfLines = 2
        title.lineBreakMode = .byTruncatingTail
        title.preferredMaxLayoutWidth = 360
        message.font = .systemFont(ofSize: EmptyState.messageSize)
        message.textColor = .secondaryLabelColor
        message.alignment = .center
        path.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        path.textColor = .secondaryLabelColor
        path.alignment = .center
        path.lineBreakMode = .byTruncatingMiddle
        path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        icon.symbolConfiguration = .init(pointSize: 34, weight: .light)
        icon.contentTintColor = .tertiaryLabelColor
        icon.setAccessibilityElement(false)
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.setHuggingPriority(.required, for: .horizontal)
        link.isBordered = false
        link.font = .systemFont(ofSize: 12)
        link.contentTintColor = BrandColor.ink
        link.target = self
        link.action = #selector(tap(_:))
        for v in [icon, mark, title, message, path, spinner, buttons, link] as [NSView] { stack.addArrangedSubview(v) }
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 0
        stack.setCustomSpacing(EmptyState.markToTitle, after: mark)
        stack.setCustomSpacing(14, after: icon)
        stack.setCustomSpacing(EmptyState.titleToMessage, after: title)
        stack.setCustomSpacing(6, after: message)
        stack.setCustomSpacing(EmptyState.messageToButtons, after: path)
        stack.setCustomSpacing(EmptyState.messageToButtons, after: spinner)
        stack.setCustomSpacing(10, after: buttons)
        mark.isHidden = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        // the optical centre: the space above the group is two thirds of the space below it, never under 16 pt
        let above = NSLayoutGuide(), below = NSLayoutGuide()
        addLayoutGuide(above)
        addLayoutGuide(below)
        messageWidth = message.widthAnchor.constraint(equalToConstant: EmptyState.messageWidth)
        let ratio = above.heightAnchor.constraint(equalTo: below.heightAnchor, multiplier: 2.0 / 3.0)
        ratio.priority = .defaultHigh
        NSLayoutConstraint.activate([
            above.topAnchor.constraint(equalTo: topAnchor), above.bottomAnchor.constraint(equalTo: stack.topAnchor),
            below.topAnchor.constraint(equalTo: stack.bottomAnchor), below.bottomAnchor.constraint(equalTo: bottomAnchor),
            ratio, above.heightAnchor.constraint(greaterThanOrEqualToConstant: 16),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -40),
            messageWidth,
            path.widthAnchor.constraint(lessThanOrEqualToConstant: EmptyState.messageWidth),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    /// `mark`: the brand mark (the friendly states) instead of the symbol. `busy`: the brand spinner where the buttons
    /// go (a first read of your items). `path`: one line under the hint, cut in the middle. `link`: a quiet text button
    /// after the buttons (tag). `oneLine` is kept for callers that pass a path as the message.
    func show(symbol: String?, image: NSImage? = nil, mark showMark: Bool = false, title t: String,
              message m: String, oneLine: Bool = false, path p: String? = nil, buttons bs: [(String, Int)] = [],
              link l: (String, Int)? = nil, busy: Bool = false, tone forced: Tone? = nil) {
        tone = forced ?? (showMark ? .friendly : bs.contains { Self.secondaryTags.contains($0.1) } ? .miss : .trouble)
        message.maximumNumberOfLines = oneLine ? 1 : 0
        message.lineBreakMode = oneLine ? .byTruncatingMiddle : .byWordWrapping
        message.toolTip = oneLine ? m : nil
        icon.image = showMark ? nil : image ?? symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        icon.isHidden = icon.image == nil
        mark.isHidden = !showMark
        mark.state = busy ? .thinking : .idle
        busy ? spinner.startAnimation() : spinner.stopAnimation()     // stopped, it is hidden: it takes no room
        title.stringValue = t
        message.stringValue = m
        message.isHidden = m.isEmpty
        messageWidth.constant = oneLine ? EmptyState.messageWidth : Self.balancedWidth(m, font: message.font!, max: EmptyState.messageWidth)
        path.stringValue = p ?? ""
        path.toolTip = p
        path.isHidden = p == nil
        // with no hint (and no path) the title takes the hint's gap to what follows
        stack.setCustomSpacing(m.isEmpty && p == nil ? EmptyState.messageToButtons : EmptyState.titleToMessage, after: title)
        stack.setCustomSpacing(p == nil ? EmptyState.messageToButtons : 6, after: message)
        buttons.arrangedSubviews.forEach { $0.removeFromSuperview() }
        primary = nil
        for (k, (label, tag)) in bs.enumerated() {
            let b: NSButton
            let first = k == 0 && !Self.secondaryTags.contains(tag)
            if first && tone == .friendly {
                b = BrandButton(title: label, target: self, action: #selector(tap(_:)))
            } else {
                b = NSButton(title: label, target: self, action: #selector(tap(_:)))
                b.bezelStyle = .rounded
            }
            b.tag = tag
            // the primary takes Return; a button that only undoes a search or a filter never does
            if first && tone != .miss { b.keyEquivalent = "\r"; primary = b }
            buttons.addArrangedSubview(b)
        }
        buttons.isHidden = bs.isEmpty
        link.isHidden = l == nil
        if let l = l {
            link.title = l.0
            link.tag = l.1
        }
        isHidden = false
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel([t, m, p ?? ""].filter { !$0.isEmpty }.joined(separator: ". "))
    }

    /// Return on the list while the empty state shows: its primary (when it has one).
    @discardableResult func pressPrimary() -> Bool {
        guard !isHidden, let b = primary else { return false }
        b.performClick(nil)
        return true
    }

    /// The narrowest width (≤ `max`) that keeps the hint's line count: the lines come out even, no word alone at the end.
    static func balancedWidth(_ s: String, font: NSFont, max: CGFloat) -> CGFloat {
        guard !s.isEmpty else { return max }
        func lines(_ w: CGFloat) -> Int {
            let r = (s as NSString).boundingRect(with: NSSize(width: w, height: 10_000), options: [.usesLineFragmentOrigin],
                                                 attributes: [.font: font])
            return Int((r.height / ceil(font.ascender - font.descender + font.leading)).rounded())
        }
        let n = lines(max)
        guard n > 1 else { return ceil((s as NSString).size(withAttributes: [.font: font]).width) + 4 }
        var lo: CGFloat = 80, hi = max
        while hi - lo > 2 {
            let mid = (lo + hi) / 2
            if lines(mid) > n { lo = mid } else { hi = mid }
        }
        return ceil(hi) + 4
    }

    @objc func tap(_ b: NSButton) { onButton?(b.tag) }
}

/// A notice above the list (system.md §3.3, "Notices above the list"): one card a list row high, inset on the list's own
/// grid — the glyph on the kind-icon column, the sentence on the title column, one small button ending where the times
/// end, the card's edges where a selected row's wash would be (ItemListController.alignNotices). No hairline of its
/// own: the wash sets it apart, and the filter bar below keeps the one rule above the rows. The whole card is the click
/// target (a pointer cursor, a hover wash); the keyboard reaches it with ↑ from the first item (micro 15) and draws it
/// selected like a row. Tones: `attn`, something waits on you (§2.3 "needs you": the attn-soft wash, the glyph in
/// `attn`); `quiet`, information (a neutral wash, the glyph in secondary). Text is 13 pt regular like a row's title,
/// the count in medium inside the sentence; never brand colour — mint stays live, primary and selection.
class NoticeCard: NSView {
    enum Tone { case attn, quiet }
    var onClick: (() -> Void)?
    /// it came back on screen: the list puts it on the grid (alignNotices)
    var onShow: (() -> Void)?
    override var isHidden: Bool { didSet { if oldValue && !isHidden { onShow?() } } }
    let glyph = NSImageView()
    let text = NSTextField(labelWithString: "")
    let action = NSButton(title: "", target: nil, action: nil)
    private let tone: Tone
    /// the keyboard cursor is on it (↑ from the first item, micro 15)
    var selected = false { didSet { if selected != oldValue { needsDisplay = true; setAccessibilitySelected(selected) } } }
    private var hover = false { didSet { if hover != oldValue { needsDisplay = true } } }
    private var pressed = false { didSet { if pressed != oldValue { needsDisplay = true } } }
    private var area: NSTrackingArea?

    /// The gap above the card (to the toolbar, or to the card above it) and the card itself: one list row.
    static let gap: CGFloat = 8
    static let height: CGFloat = Look.rowHeight
    static let radius: CGFloat = 6          // the row selection's radius (BrandRowView)

    // the grid, set by the list (align): leading things from the left edge, trailing ones from the right edge
    private var cardLead: NSLayoutConstraint!, cardTrail: NSLayoutConstraint!
    private var glyphX: NSLayoutConstraint!, textLead: NSLayoutConstraint!, actionTrail: NSLayoutConstraint!
    private let plate = NSLayoutGuide()

    /// attn-soft (web `--attn-soft`): attn at 14 % in light, 12 % in dark
    static let attnSoft = BrandColor.dynamic(0xB86E00, 0.14, 0xF5A524, 0.12)
    /// the neutral notice wash: black 5 % in light, white 7 % in dark
    static let quietWash = BrandColor.dynamic(0x000000, 0.05, 0xFFFFFF, 0.07)

    init(tone: Tone, glyph image: NSImage?) {
        self.tone = tone
        super.init(frame: .zero)
        glyph.image = image
        glyph.imageScaling = .scaleNone
        glyph.contentTintColor = tone == .attn ? BrandColor.attn : .secondaryLabelColor
        glyph.setAccessibilityElement(false)
        text.font = Look.titleFont
        text.textColor = .labelColor
        text.lineBreakMode = .byTruncatingTail
        text.maximumNumberOfLines = 1
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        text.setAccessibilityElement(false)
        action.bezelStyle = .push
        action.controlSize = .small
        action.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        action.target = self
        action.action = #selector(tapped)
        action.setContentCompressionResistancePriority(.required, for: .horizontal)
        action.setContentHuggingPriority(.required, for: .horizontal)
        action.setAccessibilityElement(false)          // the card is the one button VoiceOver reads (its label names the action)
        addLayoutGuide(plate)
        for v in [glyph, text, action] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        cardLead = plate.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10)
        cardTrail = trailingAnchor.constraint(equalTo: plate.trailingAnchor, constant: 10)
        glyphX = glyph.centerXAnchor.constraint(equalTo: leadingAnchor, constant: 25)
        textLead = text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 64)
        actionTrail = trailingAnchor.constraint(equalTo: action.trailingAnchor, constant: 16)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.gap + Self.height),
            plate.topAnchor.constraint(equalTo: topAnchor, constant: Self.gap), plate.heightAnchor.constraint(equalToConstant: Self.height),
            cardLead, cardTrail, glyphX, textLead, actionTrail,
            glyph.centerYAnchor.constraint(equalTo: plate.centerYAnchor), glyph.widthAnchor.constraint(equalToConstant: 18),
            text.centerYAnchor.constraint(equalTo: plate.centerYAnchor),
            text.trailingAnchor.constraint(lessThanOrEqualTo: action.leadingAnchor, constant: -12),
            action.centerYAnchor.constraint(equalTo: plate.centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// Puts the card on the list's grid (x in this view's coordinates; trailing values from its right edge).
    func align(cardLeading: CGFloat, glyphCenter: CGFloat, textLeading: CGFloat, actionTrailing: CGFloat, cardTrailing: CGFloat) {
        let want: [(NSLayoutConstraint, CGFloat)] = [(cardLead, cardLeading), (glyphX, glyphCenter), (textLead, textLeading),
                                                     (actionTrail, actionTrailing), (cardTrail, cardTrailing)]
        var moved = false
        for (c, v) in want where abs(c.constant - v) > 0.25 { c.constant = v; moved = true }
        if moved { needsDisplay = true; window?.invalidateCursorRects(for: self) }
    }

    /// The sentence with its count in medium (the count is the part to read first).
    func say(_ s: String, count: Int, action label: String, tip: String) {
        let a = NSMutableAttributedString(string: s, attributes: [.font: Look.titleFont, .foregroundColor: NSColor.labelColor])
        if let r = s.range(of: "\(count)") { a.addAttribute(.font, value: Look.titleUnread, range: NSRange(r, in: s)) }
        text.attributedStringValue = a
        action.title = Look.menuCase(label)
        toolTip = tip
        action.toolTip = tip
        setAccessibilityLabel("\(s), \(action.title)")
        setAccessibilityHelp(tip)
    }

    var card: NSRect { plate.frame }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: card, xRadius: Self.radius, yRadius: Self.radius)
        // the keyboard cursor on it: drawn as a selected row is
        (selected ? BrandColor.tint : tone == .attn ? Self.attnSoft : Self.quietWash).setFill()
        path.fill()
        if (hover || pressed) && !selected {
            NSColor.labelColor.withAlphaComponent(pressed ? 0.08 : 0.04).setFill()
            path.fill()
        }
    }

    // the whole card is the target; the button keeps its own clicks
    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        guard !isHidden, card.contains(p) else { return nil }
        if action.frame.contains(p) { return super.hitTest(point) }
        return self
    }
    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseDragged(with event: NSEvent) { pressed = card.contains(convert(event.locationInWindow, from: nil)) }
    override func mouseUp(with event: NSEvent) {
        let inside = card.contains(convert(event.locationInWindow, from: nil))
        pressed = false
        if inside { onClick?() }
    }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
    @objc private func tapped() { onClick?() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let a = area { removeTrackingArea(a) }
        let a = NSTrackingArea(rect: card, options: [.mouseEnteredAndExited, .activeInActiveApp], owner: self)
        addTrackingArea(a)
        area = a
    }
    override func layout() {
        super.layout()
        updateTrackingAreas()
        window?.invalidateCursorRects(for: self)
    }
    override func mouseEntered(with event: NSEvent) { hover = true }
    override func mouseExited(with event: NSEvent) { hover = false; pressed = false }
    override func resetCursorRects() { addCursorRect(card, cursor: .pointingHand) }
}

/// The Inbox's notice while captures hang under the island waiting for a project (K7): "3 captures are waiting for a
/// project · Choose Projects…" (attn: they wait on you). A click opens the island with every card down (they stay until
/// the pointer has come and gone), where each one gets its project. Hidden when there are none.
final class CapturesBanner: NoticeCard {
    init() { super.init(tone: .attn, glyph: BlurtIcon.cards.image(size: 16)) }     // the island's own count glyph (§3.2)
    required init?(coder: NSCoder) { fatalError() }

    func set(count: Int) {
        isHidden = count == 0
        guard count > 0 else { return }
        say(TP("main.captures.waiting", count), count: count, action: TP("main.captures.choose", count), tip: T("main.captures.tip"))
    }
}

/// "Recently dragged out: 2" on top of the Inbox and Unassigned (v0.8.1): cards dragged out into other apps in the last 7
/// days — a click opens Recently Dragged Out (TakenPanel: copy, drag out again, put back). Information only: the quiet
/// tone. Hidden when there are none.
final class TakenBanner: NoticeCard {
    init() { super.init(tone: .quiet, glyph: Look.symbol("arrow.up.right.square", "", size: 14)) }
    required init?(coder: NSCoder) { fatalError() }

    func set(count: Int) {
        isHidden = count == 0
        guard count > 0 else { return }
        say(T("main.captures.taken", count), count: count, action: T("main.captures.taken.show"), tip: T("main.captures.taken.tip"))
    }
}

/// The dense list's time: right-aligned on the column's trailing edge, so every row's time (and the notices' buttons
/// above the list) end on one line.
final class TimeCell: NSTableCellView {
    let label = NSTextField(labelWithString: "")
    override init(frame: NSRect) {
        super.init(frame: frame)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = Look.monoSub
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
                                     label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 2),
                                     rowMiddle(label, in: self)])
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// On top of a project whose folder is gone (moved, renamed, an unplugged disk): what happened, and "Locate…" — the
/// folder opened again is the same project (projects.py add relocates it). Hidden otherwise.
final class MissingFolderBanner: NSView {
    var onLocate: (() -> Void)?
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let locate = NSButton()

    override init(frame: NSRect) {
        super.init(frame: frame)
        icon.image = Look.symbol("questionmark.folder", "", size: 15)
        icon.contentTintColor = .secondaryLabelColor
        icon.setAccessibilityElement(false)
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.stringValue = T("main.missing.title")
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.stringValue = T("main.missing.detail")
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        locate.title = T("main.missing.locate")
        locate.bezelStyle = .rounded
        locate.controlSize = .small
        locate.target = self
        locate.action = #selector(tapped)
        locate.setContentCompressionResistancePriority(.required, for: .horizontal)
        let text = NSStackView(views: [title, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        let line = NSBox()
        line.boxType = .separator
        for v in [icon, text, locate, line] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16), icon.centerYAnchor.constraint(equalTo: text.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            text.topAnchor.constraint(equalTo: topAnchor, constant: 8), text.bottomAnchor.constraint(equalTo: line.topAnchor, constant: -8),
            locate.leadingAnchor.constraint(greaterThanOrEqualTo: text.trailingAnchor, constant: 10),
            locate.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14), locate.centerYAnchor.constraint(equalTo: text.centerYAnchor),
            line.leadingAnchor.constraint(equalTo: leadingAnchor), line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("\(title.stringValue). \(detail.stringValue)")
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc func tapped() { onLocate?() }
}

/// The top of the list: the place's name in 17 pt semibold (system.md §7) with its counts beside it in secondary
/// ("Inbox  9 new · 6 to verify") — Linear's and Reminders' page heading. In the content, not the toolbar: a bar
/// item is drawn washed out whenever the window isn't key, and the list's anchor should outweigh its rows.
final class ListHeading: NSView {
    let title = NSTextField(labelWithString: "")
    let counts = NSTextField(labelWithString: "")
    /// New Item (BA-21): the list's own way to add one by hand (⌘N too); hidden where items can't be added
    let add = NSButton()
    var onAdd: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.textColor = .labelColor
        counts.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        counts.textColor = .secondaryLabelColor
        for t in [title, counts] {
            t.lineBreakMode = .byTruncatingTail
            t.translatesAutoresizingMaskIntoConstraints = false
            addSubview(t)
        }
        title.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        counts.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        add.bezelStyle = .accessoryBarAction
        add.image = Look.symbol("plus", T("main.new_item.button"), size: 12)
        add.title = T("main.new_item.button")
        add.imagePosition = .imageLeading
        add.font = .systemFont(ofSize: 12)
        add.toolTip = T("main.new_item.tip")
        add.target = self
        add.action = #selector(addTapped)
        add.translatesAutoresizingMaskIntoConstraints = false
        add.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(add)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            counts.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 8),
            counts.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
            counts.trailingAnchor.constraint(lessThanOrEqualTo: add.leadingAnchor, constant: -10),
            add.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            add.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            heightAnchor.constraint(equalToConstant: 38),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc func addTapped() { onAdd?() }

    func set(title t: String, counts c: String) {
        title.stringValue = t
        counts.stringValue = c
        setAccessibilityLabel([t, c].filter { !$0.isEmpty }.joined(separator: ", "))
    }
}

/// The filter in effect, said above the list only while one is on ("Showing Issues, Ideas · To Verify  Clear") — the
/// filter itself is the toolbar's Filter menu (Linear's display menu, Mail's filter button): no band of unlabelled
/// segments for a control that's rarely changed. A click on the line opens that menu right there.
final class FilterBar: NSView {
    let summary = NSButton()
    let clear = NSButton()
    var onClear: (() -> Void)?
    /// the Filter menu, built when it opens (MainWindowController.filterMenu)
    var makeMenu: (() -> NSMenu?)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        summary.isBordered = false
        summary.imagePosition = .imageLeading
        summary.image = Look.symbol("line.3.horizontal.decrease.circle.fill", "", size: 13)
        summary.contentTintColor = BrandColor.ink
        summary.font = .systemFont(ofSize: 12)
        summary.lineBreakMode = .byTruncatingTail
        summary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        summary.target = self
        summary.action = #selector(openMenu)
        summary.toolTip = T("main.filter.change")
        clear.title = T("main.filter.clear")
        clear.bezelStyle = .recessed
        clear.controlSize = .small
        clear.font = .systemFont(ofSize: 11)
        clear.target = self
        clear.action = #selector(clearTapped)
        clear.setContentCompressionResistancePriority(.required, for: .horizontal)
        for v in [summary, clear] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            summary.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18), summary.centerYAnchor.constraint(equalTo: centerYAnchor),
            clear.leadingAnchor.constraint(greaterThanOrEqualTo: summary.trailingAnchor, constant: 8),
            clear.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16), clear.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 30),
        ])
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc func clearTapped() { onClear?() }
    @objc func openMenu() {
        guard let m = makeMenu?() else { return }
        m.popUp(positioning: nil, at: NSPoint(x: summary.frame.minX, y: summary.frame.minY - 4), in: self)
    }

    /// What the line says: the kinds picked and the state, in the menu's own words.
    static func describe(_ m: MainModel) -> String? {
        let parts = parts(m)
        return parts.isEmpty ? nil : T("main.filter.showing", parts.joined(separator: " · "))
    }

    /// The filter's parts: "Issues, Ideas", "To Verify".
    static func parts(_ m: MainModel) -> [String] {
        var parts: [String] = []
        if !m.kinds.isEmpty {
            parts.append(Loc.list(KindStyle.builtIn.filter(m.kinds.contains).map { Look.kindPlural($0) }
                                  + m.kinds.filter { !KindStyle.builtIn.contains($0) }.sorted().map(Look.kindName)))
        }
        if let st = m.shownState { parts.append(st == "inbox" ? T("main.filter.needs_you") : Look.stateName(st)) }
        return parts
    }

    func sync(_ m: MainModel) {
        let text = m.indexState == .ready && !m.isEmptyWorld ? Self.describe(m) : nil
        isHidden = text == nil
        // with nothing left to show, the empty state below has the one Clear Filters
        clear.isHidden = m.rowCount == 0
        summary.title = " " + (text ?? "")
        summary.setAccessibilityLabel(text)
    }
}

final class ItemListController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    let model: MainModel
    weak var actions: ItemListActions? { didSet { table.actions = actions } }
    let table = ItemTableView()
    let jobs = JobsSection()
    let captures = CapturesBanner()
    let taken = TakenBanner()
    let missing = MissingFolderBanner()
    let suggestions = SuggestionsBanner()
    let bar = FilterBar()
    /// the place's name and counts at the top of the list (ListHeading)
    let heading = ListHeading()
    let empty = EmptyStateView()
    /// the item the empty state's "Show AW-11" goes to
    private(set) var elsewhereUID: String?

    /// A search for an item's id that this place doesn't list: the item, and where it is instead.
    func elsewhere(_ q: String) -> (ItemRow, String)? {
        let ids = ItemQuery(text: q).idTerms
        guard ids.count == 1, let r = model.reader,
              let it = ((try? r.items(ItemQuery(text: ids[0], states: Lifecycle.states, limit: 4))) ?? []).first(where: { $0.itemID.uppercased() == ids[0] })
        else { return nil }
        if it.discarded { return (it, T("main.empty.id_in", it.itemID, Look.stateName("discarded"))) }
        let here: Bool
        switch model.scope {
        case .project(let p): here = it.projectID == p
        case .unassigned: here = it.projectID == "inbox"
        case .all: here = true
        default: here = false
        }
        return (it, here ? T("main.empty.id_filtered", it.itemID) : T("main.empty.id_in", it.itemID, it.projectID == "inbox" ? T("project.inbox") : it.projectName))
    }
    let scroll = NSScrollView()
    private var suppressSelection = false
    private var header: NSTableHeaderView?
    private var appliedLayout: [Bool] = []

    init(model: MainModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    struct Col { let id: String; let title: String; let width: CGFloat; let min: CGFloat; let max: CGFloat; let sort: String? }
    /// kind · id · title · (project · state, the table) · the state mark (the dense list) · date
    static var columns: [Col] { [
        Col(id: "lead", title: "", width: 22, min: 22, max: 30, sort: "kind"),
        Col(id: "meta", title: T("main.col.id"), width: 52, min: 44, max: 120, sort: "id"),
        Col(id: "title", title: T("main.col.title"), width: 260, min: 120, max: 4000, sort: "title"),
        Col(id: "project", title: T("main.col.project"), width: 110, min: 60, max: 240, sort: "project"),
        Col(id: "state", title: T("main.col.state"), width: 120, min: 60, max: 220, sort: "state"),
        Col(id: "mark", title: "", width: 20, min: 20, max: 20, sort: nil),
        Col(id: "time", title: T("main.col.updated"), width: 64, min: 56, max: 140, sort: "updated"),
    ] }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 600))
        for c in Self.columns {
            let col = NSTableColumn(identifier: .init(c.id))
            col.title = c.title
            col.width = c.width
            col.minWidth = c.min
            col.maxWidth = c.max
            if let s = c.sort { col.sortDescriptorPrototype = NSSortDescriptor(key: s, ascending: ["title", "kind", "state", "project"].contains(s)) }
            if c.id == "lead" { col.headerToolTip = T("main.col.kind") }
            if c.id == "time" { col.headerCell.alignment = .right }
            table.addTableColumn(col)
        }
        table.style = .inset
        table.rowHeight = Look.rowHeight
        table.usesAutomaticRowHeights = false
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = false
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.intercellSpacing = NSSize(width: 6, height: 0)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        table.setAccessibilityLabel(T("main.list.label"))
        table.quickLook = { [weak self] in self?.toggleQuickLook() }
        table.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        header = table.headerView
        table.tableColumns.forEach { $0.resizingMask = $0.identifier.rawValue == "title" ? [.autoresizingMask, .userResizingMask] : .userResizingMask }
        scroll.documentView = table
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(noteTop), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        bar.onClear = { [weak self] in self?.clearKindAndState() }
        jobs.onSelect = { [weak self] id in self?.actions?.selectJob(id) }
        empty.isHidden = true
        empty.onButton = { [weak self] t in self?.actions?.emptyAction(t) }
        captures.onClick = { AppEnvironment.island?.revealCards() }
        for n in [captures, taken] as [NoticeCard] { n.onShow = { [weak self] in self?.noticesChanged() } }
        missing.onLocate = { [weak self] in self?.actions?.emptyAction(7) }
        NotificationCenter.default.addObserver(forName: .blurtCardsChanged, object: nil, queue: .main) { [weak self] _ in self?.reloadCaptures() }
        taken.onClick = { [weak self] in
            let w = self?.view.window
            TakenPanel.shared.show(near: w.map { NSRect(x: $0.frame.midX - 1, y: $0.frame.maxY - 80, width: 2, height: 2) })
        }
        NotificationCenter.default.addObserver(forName: .blurtTakenChanged, object: nil, queue: .main) { [weak self] _ in self?.reloadCaptures() }
        suggestions.onMoveAll = { [weak self] p, uids in self?.actions?.move(uids: uids, to: p) }
        let stack = NSStackView(views: [heading, captures, taken, missing, jobs, suggestions, bar])
        stack.orientation = .vertical
        stack.spacing = 0
        for v in [stack, scroll, empty] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(v) }
        NSLayoutConstraint.activate([
            heading.widthAnchor.constraint(equalTo: stack.widthAnchor),
            captures.widthAnchor.constraint(equalTo: stack.widthAnchor), taken.widthAnchor.constraint(equalTo: stack.widthAnchor),
            missing.widthAnchor.constraint(equalTo: stack.widthAnchor), suggestions.widthAnchor.constraint(equalTo: stack.widthAnchor),
            jobs.widthAnchor.constraint(equalTo: stack.widthAnchor), bar.widthAnchor.constraint(equalTo: stack.widthAnchor),
            stack.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor), stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: stack.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            empty.topAnchor.constraint(equalTo: stack.bottomAnchor), empty.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            empty.leadingAnchor.constraint(equalTo: root.leadingAnchor), empty.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])
        view = root
        applyLayout()
    }

    /// Dense list vs. full table: which columns show, whether there is a header.
    func applyLayout() {
        let full = model.scope.isTable
        let inProject: Bool = { if case .project = model.scope { return true }; return model.scope == .unassigned }()
        // the id column fits the widest id this list can show ("IOS-128"), so every title starts at one x
        let idWidth = idColumnWidth()
        // only when the layout changes: a column the user resized keeps its width across reloads
        guard appliedLayout != [full, inProject] || (!full && abs((table.tableColumn(withIdentifier: .init("meta"))?.width ?? 0) - idWidth) > 0.5) else { return }
        appliedLayout = [full, inProject]
        for c in table.tableColumns {
            switch c.identifier.rawValue {
            case "lead": c.width = 22
            case "project": c.isHidden = inProject || !full; c.width = 100; projectHiddenForRoom = false
            case "meta": c.width = full ? 58 : idWidth
            case "state": c.isHidden = !full; c.width = 120
            case "mark": c.isHidden = full
            case "time": c.width = full ? 72 : 60
            default: break
            }
        }
        table.headerView = full ? header : nil
        fitTitle()
    }

    /// The dense list's id column: wide enough for the longest key here plus a three-digit number, in the id font.
    func idColumnWidth() -> CGFloat {
        let keys = model.projects.map(\.key) + ["IN"]
        let longest = keys.max { $0.count < $1.count } ?? "IN"
        let w = ("\(longest)-888" as NSString).size(withAttributes: [.font: Look.idFont]).width
        return min(72, max(44, ceil(w) + 6))
    }

    /// The title column takes whatever the fixed columns leave (users can still resize those).
    override func viewDidLayout() {
        super.viewDidLayout()
        fitTitle()
        alignNotices()
    }

    /// The notices above the list sit on its grid (NoticeCard): the glyph on the kind icons' column, the sentence where
    /// the titles start, the button's edge where the times end, the card's edges where a selected row's wash is.
    /// Measured from the table's own columns, so they follow a resized column, the inset style's margins and the
    /// scroller.
    func alignNotices() {
        let cards: [NoticeCard] = [captures, taken].filter { !$0.isHidden }
        guard !cards.isEmpty, view.bounds.width > 0, table.bounds.width > 0 else { return }
        func rect(_ id: String) -> NSRect? {
            let i = table.column(withIdentifier: .init(id))
            guard i >= 0, !table.tableColumns[i].isHidden else { return nil }
            // a cell sits in its column inset by half the intercell spacing (frameOfCell)
            return table.rect(ofColumn: i).insetBy(dx: table.intercellSpacing.width / 2, dy: 0)
        }
        guard let lead = rect("lead"), let title = rect("title"), let time = rect("time") else { return }
        func x(_ v: CGFloat) -> CGFloat { table.convert(NSPoint(x: v, y: 0), to: view).x }
        let w = view.bounds.width
        // a selected row's wash: the row view's frame (the inset style insets it), or the columns' span with no rows
        let row: NSRect = table.numberOfRows > 0 ? table.rect(ofRow: 0) : lead.union(time)
        let pad: CGFloat = row.minX < 1 && abs(row.width - table.bounds.width) < 1 ? 10 : 0      // as BrandRowView draws it
        let edges = (x(row.minX + pad), x(row.maxX - pad))
        for c in cards {
            c.align(cardLeading: edges.0, glyphCenter: x(lead.minX + 2 + 9),       // LeadCell: the icon 2 pt in, 18 wide
                    textLeading: x(title.minX + 2),                                 // TitleCell: the title 2 pt in
                    // TimeCell: the label 2 pt from the cell's end, its text 2 more (the field's padding)
                    actionTrailing: w - x(time.maxX - 4),
                    cardTrailing: w - edges.1)
        }
    }

    func fitTitle() {
        guard let title = table.tableColumn(withIdentifier: .init("title")) else { return }
        let others = table.tableColumns.filter { $0 !== title && !$0.isHidden }
        let spacing = table.intercellSpacing.width * CGFloat(others.count + 1) + 24   // + the inset style's margins
        func room() -> CGFloat { scroll.contentView.bounds.width - others.reduce(0) { $0 + $1.width } - spacing }
        // the full table in a narrow list (a small window, the detail at its minimum): Project, then State give way
        // before State and Updated end up past the list's edge; they grow back to their usual width when there's room
        if model.scope.isTable, let project = table.tableColumn(withIdentifier: .init("project")) {
            // narrower still: the project goes (the detail says it), back once the title has room again
            if projectHiddenForRoom, room() - project.minWidth - table.intercellSpacing.width >= title.minWidth + 20 {
                projectHiddenForRoom = false
                project.isHidden = false
                return fitTitle()
            }
            for (id, _) in Self.yielding {
                guard let c = table.tableColumn(withIdentifier: .init(id)), !c.isHidden else { continue }
                let short = title.minWidth - room()
                if short > 0.5 { c.width = max(c.minWidth, c.width - short) }
            }
            for (id, want) in Self.yielding.reversed() {
                guard let c = table.tableColumn(withIdentifier: .init(id)), !c.isHidden, c.width < want else { continue }
                let spare = room() - title.minWidth - 60
                if spare > 0.5 { c.width = min(want, c.width + spare) }
            }
            if !project.isHidden, room() < title.minWidth - 0.5 {
                projectHiddenForRoom = true
                project.isHidden = true
                return fitTitle()
            }
        }
        let w = room()
        if abs(title.width - max(title.minWidth, w)) > 0.5 { title.width = max(title.minWidth, w) }
    }

    private var projectHiddenForRoom = false

    /// The table's columns that shrink for the title, in that order, with their usual width.
    static let yielding: [(String, CGFloat)] = [("project", 100), ("state", 120), ("time", 72), ("meta", 58)]

    func tableViewColumnDidResize(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in self?.alignNotices() }
        guard let c = notification.userInfo?["NSTableColumn"] as? NSTableColumn, c.identifier.rawValue != "title" else { return }
        DispatchQueue.main.async { [weak self] in self?.fitTitle() }
    }

    // MARK: reload

    // MARK: rename in place

    private(set) var renaming: InlineRename?
    private var reloadAfterRename = false

    /// E (or Rename in a menu) on the one selected row: its title becomes editable right there.
    func beginRename(commit: @escaping (ItemRow, String) -> Void) -> Bool {
        guard renaming == nil, table.selectedRowIndexes.count == 1, let r = table.selectedRowIndexes.first, let it = model.item(at: r),
              let col = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == "title" }) else { return false }
        table.scrollRowToVisible(r)
        guard let cell = table.view(atColumn: col, row: r, makeIfNecessary: true) as? TitleCell else { return false }
        // the kind icon and ring step back while the title is the one thing in focus (a click on the ring only commits);
        // the id's place says how to save or cancel
        func rowCell<C: NSView>(_ id: String) -> C? {
            table.tableColumns.firstIndex { $0.identifier.rawValue == id }.flatMap { table.view(atColumn: $0, row: r, makeIfNecessary: false) as? C }
        }
        let lead: LeadCell? = rowCell("lead"), meta: MetaCell? = rowCell("meta")
        lead?.quiet = true
        meta?.showsRenameKeys = true
        let e = InlineRename(cell: cell, uid: it.uid, original: it.title, commit: { commit(it, $0) }) { [weak self] in
            guard let self = self else { return }
            lead?.quiet = false
            meta?.showsRenameKeys = false
            self.renaming = nil
            self.view.window?.makeFirstResponder(self.table)       // back to the list, the row still selected
            if self.reloadAfterRename { self.reloadAfterRename = false; self.reload() }
        }
        renaming = e
        e.start()
        return true
    }

    /// Reload rows, keeping the selection (by uid) and the scroll position where possible.
    func reload(keep: [String]? = nil) {
        // never under a title being renamed: once it's done
        if renaming != nil { reloadAfterRename = true; return }
        let keepIDs = keep ?? selectionIDs     // captured before the model changed (row numbers mean other rows now)
        let top = table.rows(in: table.visibleRect).location
        let topID = topIDSeen                  // likewise: the model's rows are the new ones already
        let firstSelected = table.selectedRowIndexes.first
        suppressSelection = true
        applyLayout()
        table.reloadData()
        var set = IndexSet()
        for k in keepIDs { if let r = model.row(of: k) { set.insert(r) } }
        // the selection left this list (kept out of the inbox, discarded, moved): the next row takes its place, like Mail
        if set.isEmpty, keep == nil, !keepIDs.isEmpty, let f = firstSelected, model.rowCount > 0, view.window?.firstResponder === table {
            set.insert(min(f, model.rowCount - 1))
        }
        table.selectRowIndexes(set, byExtendingSelection: false)
        if let t = topID, let r = model.row(of: t), r != top, keep == nil {
            table.scroll(NSPoint(x: 0, y: table.rect(ofRow: r).minY - (table.headerView?.frame.height ?? 0)))
        } else if keep != nil, let first = set.first {
            table.scrollRowToVisible(first)
        }
        suppressSelection = false
        bar.sync(model)
        reloadCaptures()
        reloadMissing()
        suggestions.set(model.indexState == .ready && Scripts.canWrite ? model.suggestionGroups : [], projects: model.projects)
        updateEmpty()
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { QLPreviewPanel.shared().reloadData() }
        let ids = set.compactMap { id(at: $0) }
        noteTop()
        if ids != selectionIDs { selectionIDs = ids; actions?.listSelectionChanged() }
    }

    /// The item at the top of the visible rows, as of the last scroll: a reload keeps it there (new rows above it
    /// don't push the list around).
    private var topIDSeen: String?
    @objc func noteTop() { topIDSeen = id(at: table.rows(in: table.visibleRect).location) }

    /// A new place, filter, search or sort: the list starts at its top — or at the selection when one is kept.
    func scrollToStart() {
        if let r = table.selectedRowIndexes.first, r > 0 { table.scrollRowToVisible(r) }
        else { table.scroll(NSPoint(x: 0, y: -(table.headerView?.frame.height ?? 0))) }
        noteTop()
    }
    /// The selected uids, kept up to date on every selection change.
    private(set) var selectionIDs: [String] = []
    func forgetSelection() { selectionIDs = [] }

    func id(at row: Int) -> String? { row >= 0 && row < model.uids.count ? model.uids[row] : nil }
    var selectedIDs: [String] { table.selectedRowIndexes.compactMap { id(at: $0) } }
    var selectedItems: [ItemRow] { table.selectedRowIndexes.compactMap { model.item(at: $0) } }

    func select(id: String) {
        guard let r = model.row(of: id) else { return }
        table.selectRowIndexes([r], byExtendingSelection: false)
        table.scrollRowToVisible(r)
    }

    /// The Filter menu's picks (or the filter line's Clear): the list starts at its top again.
    func filtersChanged() {
        model.reload()
        scrollToStart()
    }
    func clearKindAndState() {
        model.kinds = []
        model.state = nil
        filtersChanged()
    }

    func reloadJobs() { jobs.set(model.jobs, store: ProjectStore.shared, showProject: model.scope.projectID == nil) }
    /// "N captures are waiting for a project" on top of the inbox while cards hang under the island.
    /// "Recently dragged out: N" on top of the Inbox and Unassigned while cards dragged out in the last 7 days are there.
    func reloadCaptures() {
        captures.set(count: model.scope == .inbox ? AppEnvironment.island?.hangingCount ?? 0 : 0)
        taken.set(count: 0)         // Recently Dragged Out is a sidebar row now (SidebarController), not a notice over the list
    }

    /// A notice came or went: put it on the grid once the stack has laid it out.
    func noticesChanged() {
        DispatchQueue.main.async { [weak self] in self?.view.layoutSubtreeIfNeeded(); self?.alignNotices() }
    }

    /// "Can't find this folder" over a registered project whose folder is gone.
    func reloadMissing() {
        guard case .project(let p) = model.scope, let e = model.project(id: p) else { missing.isHidden = true; return }
        // with no rows the empty state says it (and offers Locate) instead
        missing.isHidden = !e.registered || model.rowCount == 0 || FileManager.default.fileExists(atPath: e.path.path)
    }

    /// Tests (wp6 `mainempty KIND`): the place really in that state — the model shows it empty (MainModel.testEmpty),
    /// with the counts and the index state such a world has, so the sidebar, the heading, the filter line and the
    /// detail all follow, as they would. `off` puts the real world back. KIND: first | inbox_zero | progress |
    /// unassigned | project | no_results | no_match | no_index | outdated | failed | missing | scanning | discarded.
    func testEmpty(_ kind: String, go: (Scope) -> Void) {
        model.testMissing = nil
        model.testEmptyProject = nil
        guard kind != "off" else { model.kinds = []; model.state = nil; model.text = ""; model.setTestEmpty(nil); return }
        let firstProject = model.projects.first(where: \.registered)?.id ?? ""
        model.kinds = []
        model.state = nil
        model.text = ""
        switch kind {
        case "project": model.testEmptyProject = firstProject
        case "missing": model.testMissing = firstProject
        default: break
        }
        model.setTestEmpty(["no_results", "no_match"].contains(kind) ? nil : kind)
        switch kind {
        case "inbox_zero", "first", "no_index", "outdated", "failed", "scanning": go(.inbox)
        case "progress": go(.inProgress)
        case "unassigned": go(.unassigned)
        case "project", "missing": go(.project(firstProject))
        case "discarded":
            go(.all)
            model.state = "discarded"
        case "no_results":
            go(.inbox)
            model.text = "zebra"
        case "no_match":
            go(.inbox)
            model.kinds = ["task"]
        default: break
        }
        model.reloadAll()
    }

    func updateEmpty() {
        elsewhereUID = nil
        let tilde = { (u: URL) in (u.path as NSString).abbreviatingWithTildeInPath }
        switch model.indexState {
        case .scanning where model.firstScan || model.rowCount == 0:
            empty.show(symbol: nil, mark: true, title: T("main.empty.scanning"), message: T("main.empty.scanning.detail"), busy: true)
            return
        case .scanning: break
        case .noScripts:
            empty.show(symbol: "puzzlepiece.extension", title: T("main.empty.no_scripts"), message: T("main.empty.no_scripts.detail"), tone: .trouble)
            return
        case .missing:
            empty.show(symbol: nil, mark: true, title: T("main.empty.no_index"), message: T("main.empty.no_index.detail"),
                       buttons: [(T("main.empty.scan"), 1)])
            return
        case .outdated:
            empty.show(symbol: nil, mark: true, title: T("main.empty.outdated"), message: T("main.empty.outdated.detail"), busy: true)
            return
        case .failed:
            empty.show(symbol: "exclamationmark.triangle", title: T("main.empty.scan_failed"), message: T("main.empty.scan_failed.detail"),
                       path: tilde(BlurtPaths.workspace), buttons: [(T("action.retry"), 1)], tone: .trouble)
            return
        case .ready: break
        }
        guard model.rowCount == 0 else { empty.isHidden = true; return }
        let q = model.text.trimmingCharacters(in: .whitespaces)
        let filters = !model.kinds.isEmpty || model.shownState != nil
        if !q.isEmpty, let (it, why) = elsewhere(q) {
            // an id typed here for an item this place doesn't list (discarded, filtered out, another project): say
            // where it is and take you there — ⌘K finds it anywhere, the search shouldn't just say "no results"
            elsewhereUID = it.uid
            empty.show(symbol: "magnifyingglass", title: T("main.empty.no_results", q), message: why,
                       buttons: [(T("main.empty.show_item", it.itemID), 8), (T(filters ? "main.empty.clear_all" : "main.empty.clear_search"), 2)],
                       tone: .miss)
        } else if !q.isEmpty {
            let elsewhereCount = model.scope == .all ? 0 : model.matchesInAllItems()
            let hint = filters ? T("main.empty.filters_on", FilterBar.parts(model).joined(separator: " · "))
                : elsewhereCount > 0 ? TP("main.empty.elsewhere", elsewhereCount) : T("main.empty.try_shorter")
            var bs: [(String, Int)] = []
            if elsewhereCount > 0, !filters { bs.append((T("main.empty.search_all"), 9)) }
            bs.append((T(filters ? "main.empty.clear_all" : "main.empty.clear_search"), 2))
            empty.show(symbol: "magnifyingglass", title: model.scope == .all ? T("main.empty.no_results", q)
                           : T("main.empty.no_results_in", q, model.scopeTitle),
                       message: hint, buttons: bs, tone: .miss)
        } else if model.shownState == "discarded", model.kinds.isEmpty {
            empty.show(symbol: nil, mark: true, title: T("main.empty.discarded"), message: T("main.empty.discarded.detail"))
        } else if model.filtered {
            empty.show(symbol: "line.3.horizontal.decrease.circle", title: T("main.empty.no_match"),
                       message: T("main.empty.no_match.detail", FilterBar.parts(model).joined(separator: " · ")),
                       buttons: [(T("main.empty.clear_filters"), 2)], tone: .miss)
        } else {
            switch model.scope {
            case .inbox where model.counts.all > 0 || model.testEmpty == "inbox_zero":
                empty.show(symbol: nil, mark: true, title: T("main.empty.inbox_zero"), message: T("main.empty.inbox_zero.detail"))
            case .inProgress:
                empty.show(symbol: nil, mark: true, title: T("main.empty.nothing_in_progress"), message: T("main.empty.nothing_in_progress.detail"),
                           buttons: model.counts.inbox > 0 ? [(T("main.empty.go_inbox"), 11)] : [], tone: .friendly)
            case .unassigned:
                empty.show(symbol: nil, mark: true, title: T("main.empty.all_filed"), message: T("main.empty.all_filed.detail"))
            case .project(let p) where model.folderMissing(p):
                let e = model.project(id: p)
                empty.show(symbol: "questionmark.folder", title: T("main.missing.title_named", e?.name ?? model.scopeTitle),
                           message: T(ProjectStore.shared.currentID == p ? "main.missing.detail_current" : "main.missing.detail_named"),
                           path: e.map { tilde($0.path) }, buttons: [(T("main.missing.locate_folder"), 7)],
                           link: (T("main.missing.remove"), 10), tone: .trouble)
            case .project(let p):
                let current = ProjectStore.shared.currentID == p
                empty.show(symbol: nil, mark: true, title: T("main.empty.project"),
                           message: T(current ? "main.empty.project.detail" : "main.empty.project.detail_other"),
                           buttons: current ? [(T("main.action.record"), 3), (T("main.action.snap"), 4)]
                                            : [(T("main.project.use"), 6), (T("main.action.record"), 3)])
            default:
                // nothing captured anywhere yet: open a folder first — or, with projects already open, record
                let noProjects = model.projects.filter(\.registered).isEmpty
                empty.show(symbol: nil, mark: true, title: T("main.empty.first"),
                           message: T(noProjects ? "main.empty.first.detail" : "main.empty.project.detail"),
                           buttons: noProjects ? [(T("project.open_folder"), 5), (T("main.action.record"), 3)]
                                               : [(T("main.action.record"), 3), (T("main.action.snap"), 4)])
            }
        }
    }

    // MARK: table

    func numberOfRows(in tableView: NSTableView) -> Int { model.indexState == .ready ? model.rowCount : 0 }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let col = tableColumn?.identifier.rawValue, let it = model.item(at: row) else { return nil }
        return itemCell(col, it)
    }

    func make<T: NSView>(_ id: String, _ f: () -> T) -> T {
        if let v = table.makeView(withIdentifier: .init(id), owner: self) as? T { return v }
        let v = f()
        v.identifier = .init(id)
        return v
    }

    var inOwnProject: Bool { if case .project = model.scope { return true }; return model.scope == .unassigned }

    func itemCell(_ col: String, _ it: ItemRow) -> NSView? {
        let quiet = it.discarded || Lifecycle.closed.contains(it.state)
        switch col {
        case "lead":
            let c = make("lead") { LeadCell() }
            let voice = it.sourceType == "voice" && it.kind == "note"
            c.kindImage = Look.leadImage(kind: it.kind, voice: voice)
            c.icon.alphaValue = it.discarded ? 0.4 : 1
            c.quiet = renaming?.uid == it.uid
            c.icon.setAccessibilityLabel(voice ? T("main.kind.voice_note") : Look.kindName(it.kind))
            return c
        case "mark":
            let c = make("mark") { () -> MarkCell in
                let c = MarkCell()
                c.ring.target = self
                c.ring.action = #selector(ringClicked(_:))
                return c
            }
            c.ring.set(it.state, label: Look.stateLabel(it))
            c.ring.isEnabled = !it.legacy
            // a row shows its state only where the list doesn't already say it: never "new" (the default of a fresh
            // item), nothing in a list grouped by state (its header says it) — pointed at or selected, it shows
            c.quietAtRest = model.grouping == .state || it.state == "new"
            return c
        case "title":
            let c = make("title") { TitleCell() }
            // the search hit, unless it is just the title again
            let searching = !model.text.trimmingCharacters(in: .whitespaces).isEmpty
            let hit = searching && SearchHit.adds(it.snippet, to: it.title) ? it.snippet : nil
            // one weight for every title: the groups already set new items apart (Linear's list); closed ones dim
            c.set(title: it.title, unread: false, dimmed: quiet, struck: false, hit: hit,
                  unreadable: it.unreadable)
            c.toolTip = it.unreadable ? T("main.unreadable.fix_first")
                : [it.quote.isEmpty ? nil : "“\(it.quote)”", it.sessionTitle].compactMap { $0 }.joined(separator: "\n")
            // an Unassigned item the organizing run suggested a project for: one click files it there (⌘Z undoes)
            let sug = it.projectID == "inbox" && !it.discarded && Scripts.canWrite
                ? it.suggestedProject.flatMap { s in model.project(id: s).flatMap { $0.registered ? $0 : nil } } : nil
            c.setSuggestion(sug?.name, move: sug.map { p in { [weak self] in self?.actions?.move(uids: [it.uid], to: p.id) } })
            return c
        case "meta":
            let c = make("meta") { MetaCell() }
            c.key.stringValue = it.itemID
            c.key.textColor = quiet ? .tertiaryLabelColor : .secondaryLabelColor
            c.toolTip = it.projectID == "inbox" ? T("project.inbox") : it.projectName
            return c
        case "project":
            let c = make("icontext") { IconTextCell() }
            c.set(it.projectID == "inbox" ? T("project.inbox") : it.projectName)
            return c
        case "state":
            let c = make("state") { () -> StateCell in
                let c = StateCell()
                c.button.target = self
                c.button.action = #selector(ringClicked(_:))
                return c
            }
            c.set(it.state, label: Look.stateLabel(it))
            c.button.isEnabled = !it.legacy
            return c
        case "time":
            let c = make("time") { TimeCell() }
            c.label.stringValue = MainModel.listDate(it.updated)
            c.toolTip = MainModel.shortDate(it.updated)
            return c
        default: return nil
        }
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let v = make("row") { ItemRowView() }
        let sec = model.section(at: row)
        v.section = sec.map { (sectionName($0), Loc.number($0.count), model.grouping == .state ? Look.ring($0.key, size: 14) : nil) }
        v.nextOwnsBand = model.section(at: row + 1) == nil
        if let it = model.item(at: row) {
            v.label = ([sec.map { "\(sectionName($0)), \(TP("main.items.count", $0.count))" }, Look.kindName(it.kind),
                        it.title.isEmpty ? T("main.item.untitled") : it.title, it.itemID, Look.stateLabel(it),
                        it.projectID == "inbox" ? T("project.inbox") : it.projectName, MainModel.shortDate(it.updated)] as [String?])
                .compactMap { $0 }.joined(separator: ", ")
        }
        return v
    }

    /// A run's header: the state's name (a list grouped by state), else the project's name (Unassigned for the inbox store).
    func sectionName(_ s: ListSection) -> String {
        if model.grouping == .state { return Look.stateName(s.key) }
        if s.project == "inbox" { return T("project.inbox") }
        return model.project(id: s.project)?.name ?? model.item(at: s.start)?.projectName ?? s.project
    }

    /// A project run's first row is taller: its header sits above the row's own band.
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard model.section(at: row) != nil else { return Look.rowHeight }
        return Look.rowHeight + (row == 0 ? Look.firstSectionHeight : Look.sectionHeight)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelection else { return }    // reload() settles the selection itself
        selectionIDs = selectedIDs
        actions?.listSelectionChanged()
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { QLPreviewPanel.shared().reloadData() }
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let d = tableView.sortDescriptors.first, let key = d.key, key != model.sort || d.ascending != model.ascending else { return }
        model.sort = key
        model.ascending = d.ascending
        model.reload()
        scrollToStart()
    }

    /// A row's ring (or the State column): select that row unless it is part of the selection, then its state menu.
    @objc func ringClicked(_ sender: NSButton) {
        // during a rename a click on a ring only ends it (commits, like any click outside the field), no menu on top
        if renaming != nil { view.window?.makeFirstResponder(table); return }
        let r = table.row(for: sender)
        guard r >= 0 else { return }
        if !table.selectedRowIndexes.contains(r) { table.selectRowIndexes([r], byExtendingSelection: false) }
        view.window?.makeFirstResponder(table)
        actions?.showStateMenu(row: r, from: sender)
    }

    /// The ring of a row on screen (the S key opens the menu under it).
    func ringView(row r: Int) -> NSView? {
        let id = model.scope.isTable ? "state" : "mark"
        guard let col = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == id }) else { return nil }
        table.scrollRowToVisible(r)
        switch table.view(atColumn: col, row: r, makeIfNecessary: false) {
        case let c as MarkCell: return c.ring
        case let c as StateCell: return c.button
        default: return nil
        }
    }

    @objc func doubleClicked() {
        guard table.clickedRow >= 0 else { return }
        actions?.openSelection()
    }

    // drag rows: the uids (onto a project), the primary frame (else the item's .md) as a file (Finder makes a copy,
    // Terminal pastes the path)
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard let it = model.item(at: row) else { return nil }
        let pb = NSPasteboardItem()
        pb.setString(it.uid, forType: .blurtItems)
        // no frame (a voice note, a typed one): the item's own .md — like Reveal in Finder and Copy Path
        let file = it.primaryFrame.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
            ?? (FileManager.default.fileExists(atPath: it.fileURL.path) && !it.legacy ? it.fileURL.path : nil)
        if let f = file { pb.setString(URL(fileURLWithPath: f).absoluteString, forType: .fileURL) }
        pb.setString(it.title, forType: .string)
        return pb
    }

    /// The rows a drag carries (set as it starts): their text follows a picture into a chat app (below).
    private var draggedUIDs: [String] = []

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint,
                   forRowIndexes rowIndexes: IndexSet) {
        draggedUIDs = rowIndexes.compactMap { model.item(at: $0)?.uid }
    }

    /// An item dropped into a chat app (WeChat, QQ, a browser's chat…): the app took its picture and nothing else, so
    /// its text is pasted into the composer after it — the hanging cards' follow-up (DragNoteFollowUp; BA-22: only the
    /// picture arrived). One item with a picture; the Finder and terminals keep the file alone.
    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint,
                   operation: NSDragOperation) {
        defer { draggedUIDs = [] }
        guard operation != [], draggedUIDs.count == 1, let it = model.itemRow(uid: draggedUIDs[0]),
              it.primaryFrame.map({ FileManager.default.fileExists(atPath: $0) }) == true,
              SmartPaste.enabled, SmartPaste.accessibility, !IsSecureEventInputEnabled(),
              let t = DropProbe.target(at: screenPoint), t.cls == .chat else { return }
        let text = ItemListController.dragText(it)
        guard !text.isEmpty else { return }
        emit(["event": "item_drag_note", "bundle": t.bundleID ?? NSNull()])
        DragNoteFollowUp.run(note: text, target: t, at: screenPoint) { pasted in
            emit(["event": "item_drag_note_done", "pasted": pasted])
        }
    }

    /// What an item says in a chat: its title, then its own words (the Markdown body without its pictures).
    static func dragText(_ it: ItemRow) -> String {
        var lines = [it.title]
        if let md = try? String(contentsOf: it.fileURL, encoding: .utf8) {
            let parts = md.components(separatedBy: "\n---\n")
            let body = parts.count > 1 ? parts.dropFirst().joined(separator: "\n---\n") : md
            var skip = false
            for ln in body.components(separatedBy: "\n") {
                let t = ln.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("## ") {          // a section: its heading as a plain line; the pictures' section goes
                    skip = ["## 截图", "## Screenshots"].contains(t)
                    if !skip { lines += ["", String(t.dropFirst(3))] }
                    continue
                }
                if skip || t.hasPrefix("![") { continue }
                lines.append(ln)
            }
        }
        let text = lines.joined(separator: "\n").replacingOccurrences(of: "\n\n\n+", with: "\n\n", options: .regularExpression)
        return String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4000))
    }

    // MARK: Quick Look

    var previewURLs: [URL] {
        selectedItems.compactMap { $0.primaryFrame.map { URL(fileURLWithPath: $0) } }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }
    var quickLookOverride: [URL]?

    func toggleQuickLook(_ urls: [URL]? = nil) {
        quickLookOverride = urls
        let p = QLPreviewPanel.shared()!
        if p.isVisible && urls == nil {
            p.orderOut(nil)
        } else {
            guard !(urls ?? previewURLs).isEmpty else { NSSound.beep(); return }
            view.window?.makeFirstResponder(table)
            p.makeKeyAndOrderFront(nil)
            p.reloadData()
        }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { (quickLookOverride ?? previewURLs).count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        let u = quickLookOverride ?? previewURLs
        return index < u.count ? u[index] as NSURL : nil
    }
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        if event.type == .keyDown, quickLookOverride == nil, [125, 126].contains(event.keyCode) || ["j", "k"].contains(event.charactersIgnoringModifiers ?? "") {
            table.move(event.keyCode == 125 || event.charactersIgnoringModifiers == "j" ? 1 : -1)
            return true
        }
        return false
    }
    func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: QLPreviewItem!) -> NSRect {
        guard quickLookOverride == nil, let r = table.selectedRowIndexes.first, let w = view.window else { return .zero }
        let cell = table.frameOfCell(atColumn: 0, row: r)
        return w.convertToScreen(table.convert(cell, to: nil))
    }
}
