// The middle column: the running jobs (K4) above a filter bar and a view-based NSTableView with a fixed row height.
// Dense one-line rows everywhere; All Items shows the same table with a header and every column. Keyboard-first:
// J/K, ↩, ⌘↩ (hand off), E, 1–4 (kind), Space (Quick Look), ⌘C (path), and K3's state keys — A keep, D done,
// R the one way back (send back / take back / reopen / restore), W won't do, X / ⌫ discard, S the state menu. Rows
// drag out as their primary frame (a file) and onto a project in the sidebar (move). Empty states for first run, no
// matches, nothing yet.
import AppKit
import BlurtCore
import Quartz

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

/// Rename in place (micro 1, 10): the row's title turns into a field with the whole title selected. Return, Tab or a click
/// elsewhere commits; Esc puts the title back. An empty title is refused right there (a red ring and a beep — it
/// never commits). The focus goes back to the list with the row still selected; ⌘Z undoes it ("Undo Rename").
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
        let t = text
        let changed = save && t != original
        cell.endEditing(showing: changed ? t : nil)
        done()
        if changed { commit(t) }
    }
}

/// Big centred message with an image and up to two buttons — the one empty state (docs/design/system.md §3.5,
/// `EmptyState` metrics, the same as SwiftUI's `EmptyStateContent`). The friendly states (first launch, inbox zero,
/// nothing here yet, no results) show the brand mark: the app icon, the 4A chick on its tile. Trouble (scan failed, a
/// missing folder) keeps a quiet symbol: warnings are never brand. The first button is the view's one primary
/// (BrandButton, ↩) when it moves you on (scan, open a folder, record); a button that only clears filters stays a
/// secondary native one.
final class EmptyStateView: NSView {
    let icon = NSImageView()
    let mark = BrandMarkView()
    let title = NSTextField(labelWithString: "")
    let message = NSTextField(wrappingLabelWithString: "")
    let buttons = NSStackView()
    let spinner = BrandSpinner(size: 26)
    var onButton: ((Int) -> Void)?
    /// tags whose button is never the primary (they undo a filter rather than move on)
    static let secondaryTags: Set<Int> = [2]
    private let stack = NSStackView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        title.font = .systemFont(ofSize: EmptyState.titleSize, weight: .semibold)
        title.alignment = .center
        message.font = .systemFont(ofSize: EmptyState.messageSize)
        message.textColor = .secondaryLabelColor
        message.alignment = .center
        message.preferredMaxLayoutWidth = EmptyState.messageWidth
        icon.symbolConfiguration = .init(pointSize: 34, weight: .light)
        icon.contentTintColor = .tertiaryLabelColor
        buttons.orientation = .horizontal
        buttons.spacing = 8
        for v in [icon, mark, spinner, title, message, buttons] as [NSView] { stack.addArrangedSubview(v) }
        stack.orientation = .vertical
        stack.spacing = 0
        stack.setCustomSpacing(EmptyState.markToTitle, after: mark)
        stack.setCustomSpacing(12, after: icon)
        stack.setCustomSpacing(12, after: spinner)
        stack.setCustomSpacing(EmptyState.titleToMessage, after: title)
        stack.setCustomSpacing(EmptyState.messageToButtons, after: message)
        mark.isHidden = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo: centerXAnchor),
                                     stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -20),
                                     stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -40)])
    }
    required init?(coder: NSCoder) { fatalError() }

    /// `mark`: the brand mark instead of the symbol (the friendly states).
    /// `oneLine`: a path — one line, cut in the middle (both ends say where it was).
    func show(symbol: String?, image: NSImage? = nil, mark showMark: Bool = false, title t: String,
              message m: String, oneLine: Bool = false, buttons bs: [(String, Int)] = [], busy: Bool = false) {
        message.maximumNumberOfLines = oneLine ? 1 : 0
        message.lineBreakMode = oneLine ? .byTruncatingMiddle : .byWordWrapping
        message.toolTip = oneLine ? m : nil
        message.cell?.wraps = !oneLine
        message.usesSingleLineMode = oneLine
        icon.image = showMark ? nil : image ?? symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        icon.isHidden = icon.image == nil || busy
        mark.isHidden = !showMark || busy
        icon.setAccessibilityElement(false); icon.cell?.setAccessibilityElement(false)      // decoration (an SF Symbol's own name, e.g. "split view", says nothing here)
        busy ? spinner.startAnimation() : spinner.stopAnimation()     // stopped, it is hidden: it takes no room
        title.stringValue = t
        message.stringValue = m
        message.isHidden = m.isEmpty
        // with no hint the title takes the hint's gap to the buttons
        stack.setCustomSpacing(m.isEmpty ? EmptyState.messageToButtons : EmptyState.titleToMessage, after: title)
        buttons.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (k, (label, tag)) in bs.enumerated() {
            let b: NSButton
            if k == 0 && !Self.secondaryTags.contains(tag) {
                b = BrandButton(title: label, target: self, action: #selector(tap(_:)))
            } else {
                b = NSButton(title: label, target: self, action: #selector(tap(_:)))
                b.bezelStyle = .rounded
            }
            b.tag = tag
            // the brand primary takes Return; a plain button never does (it would draw as the system default)
            if k == 0 && !Self.secondaryTags.contains(tag) { b.keyEquivalent = "\r" }
            buttons.addArrangedSubview(b)
        }
        buttons.isHidden = bs.isEmpty
        isHidden = false
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel([t, m].filter { !$0.isEmpty }.joined(separator: ". "))
    }

    @objc func tap(_ b: NSButton) { onButton?(b.tag) }
}

/// The inbox's top row while captures hang under the island waiting for a project (K7): "Unfiled captures: 3" — a click
/// opens the island with every card down (they stay until the pointer has come and gone). Hidden when there are none.
final class CapturesBanner: NSView {
    var onClick: (() -> Void)?
    private let row = JobRow()
    /// the keyboard cursor is on it (↑ from the first item, micro 15)
    var selected: Bool {
        get { row.selected }
        set { row.selected = newValue }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.title.font = .systemFont(ofSize: 12, weight: .semibold)
        row.status.textColor = BrandColor.ink
        row.bar.isHidden = true
        row.spinner.isHidden = true
        row.icon.image = BlurtIcon.snap.image(size: 15)
        row.icon.contentTintColor = BrandColor.ink
        row.onClick = { [weak self] in self?.onClick?() }
        addSubview(row)
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 6), row.bottomAnchor.constraint(equalTo: line.topAnchor, constant: -6),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10), row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            line.leadingAnchor.constraint(equalTo: leadingAnchor), line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(count: Int) {
        isHidden = count == 0
        guard count > 0 else { return }
        row.title.stringValue = TP("main.captures.unfiled", count)
        row.status.stringValue = T("main.captures.show")
        row.setAccessibilityLabel("\(row.title.stringValue), \(row.status.stringValue)")
        row.toolTip = T("main.captures.tip")
    }
}

/// "Recently dragged out: 2" on top of the Inbox and Unassigned (v0.8.1): cards dragged out into other apps in the last 7
/// days — a click opens Recently Taken (TakenPanel: copy, drag out again, put back). Hidden when there are none.
final class TakenBanner: NSView {
    var onClick: (() -> Void)?
    private let row = JobRow()
    /// the keyboard cursor is on it (↑ from the first item, micro 15)
    var selected: Bool {
        get { row.selected }
        set { row.selected = newValue }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.title.font = .systemFont(ofSize: 12, weight: .regular)
        row.status.textColor = BrandColor.ink
        row.bar.isHidden = true
        row.spinner.isHidden = true
        row.icon.image = Look.symbol("arrow.up.right.square", "", size: 14)
        row.icon.contentTintColor = .secondaryLabelColor
        row.onClick = { [weak self] in self?.onClick?() }
        addSubview(row)
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 4), row.bottomAnchor.constraint(equalTo: line.topAnchor, constant: -4),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10), row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            line.leadingAnchor.constraint(equalTo: leadingAnchor), line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(count: Int) {
        isHidden = count == 0
        guard count > 0 else { return }
        row.title.stringValue = T("main.captures.taken", count)
        row.status.stringValue = T("main.captures.taken.show")
        row.setAccessibilityLabel("\(row.title.stringValue), \(row.status.stringValue)")
        row.toolTip = T("main.captures.taken.tip")
    }
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

/// Kind segments and the state filter (the count is the window's subtitle).
final class FilterBar: NSView {
    let kinds = NSSegmentedControl()
    let state = NSPopUpButton()
    var onChange: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        kinds.segmentCount = KindStyle.builtIn.count
        kinds.trackingMode = .selectAny
        kinds.segmentStyle = .roundRect
        kinds.controlSize = .small
        for (k, key) in KindStyle.builtIn.enumerated() {
            kinds.setImage(Look.kindImage(key, size: KindStyle.smallSize), forSegment: k)
            kinds.setImageScaling(.scaleNone, forSegment: k)
            kinds.setWidth(28, forSegment: k)
            kinds.setToolTip(T("main.filter.only_kind", Look.kindName(key), k + 1), forSegment: k)
        }
        kinds.target = self
        kinds.action = #selector(changed)
        kinds.setAccessibilityLabel(T("main.filter.kind"))
        state.controlSize = .small
        state.font = .systemFont(ofSize: 11)
        state.bezelStyle = .recessed
        state.isBordered = true
        state.target = self
        state.action = #selector(changed)
        // All but discarded · Needs you · each live state · Discarded (only here: K3)
        func add(_ title: String, _ value: String?, ring: String?) {
            state.addItem(withTitle: title)
            state.lastItem?.representedObject = value
            state.lastItem?.image = ring.map { Look.ring($0, size: 12) }
        }
        add(T("main.filter.live"), nil, ring: nil)
        add(T("main.filter.needs_you"), "inbox", ring: nil)
        state.lastItem?.image = Look.symbol("tray", "", size: 11)
        state.menu?.addItem(.separator())
        for s in Lifecycle.live { add(Look.stateName(s), s, ring: s) }
        state.menu?.addItem(.separator())
        add(Look.stateName("discarded"), "discarded", ring: "discarded")
        state.setAccessibilityLabel(T("main.filter.state"))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView(views: [kinds, state, spacer])
        row.orientation = .horizontal
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 14)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            line.leadingAnchor.constraint(equalTo: leadingAnchor), line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 32),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc func changed() { onChange?() }

    var selectedKinds: Set<String> {
        Set(KindStyle.builtIn.enumerated().filter { kinds.isSelected(forSegment: $0.offset) }.map(\.element))
    }

    func sync(_ m: MainModel) {
        for (k, key) in KindStyle.builtIn.enumerated() { kinds.setSelected(m.kinds.contains(key), forSegment: k) }
        state.selectItem(at: state.itemArray.firstIndex { !$0.isSeparatorItem && $0.representedObject as? String == m.state } ?? 0)
        let ready = m.indexState == .ready
        kinds.isHidden = !ready
        state.isHidden = !ready || m.scope == .inbox
        isHidden = m.isEmptyWorld && !m.filtered      // nothing to filter yet: the first-run state alone
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
    let bar = FilterBar()
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
    static var columns: [Col] { [
        Col(id: "lead", title: "", width: 44, min: 22, max: 44, sort: "kind"),
        Col(id: "title", title: T("main.col.title"), width: 260, min: 120, max: 4000, sort: "title"),
        Col(id: "meta", title: T("main.col.id"), width: 64, min: 48, max: 120, sort: "id"),
        Col(id: "project", title: T("main.col.project"), width: 110, min: 60, max: 240, sort: "project"),
        Col(id: "state", title: T("main.col.state"), width: 120, min: 60, max: 220, sort: "state"),
        Col(id: "time", title: T("main.col.updated"), width: 78, min: 56, max: 140, sort: "updated"),
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
        bar.onChange = { [weak self] in self?.filtersChanged() }
        jobs.onSelect = { [weak self] id in self?.actions?.selectJob(id) }
        empty.isHidden = true
        empty.onButton = { [weak self] t in self?.actions?.emptyAction(t) }
        captures.onClick = { AppEnvironment.island?.revealCards() }
        missing.onLocate = { [weak self] in self?.actions?.emptyAction(7) }
        NotificationCenter.default.addObserver(forName: .blurtCardsChanged, object: nil, queue: .main) { [weak self] _ in self?.reloadCaptures() }
        taken.onClick = { [weak self] in
            let w = self?.view.window
            TakenPanel.shared.show(near: w.map { NSRect(x: $0.frame.midX - 1, y: $0.frame.maxY - 80, width: 2, height: 2) })
        }
        NotificationCenter.default.addObserver(forName: .blurtTakenChanged, object: nil, queue: .main) { [weak self] _ in self?.reloadCaptures() }
        let stack = NSStackView(views: [captures, taken, missing, jobs, bar])
        stack.orientation = .vertical
        stack.spacing = 0
        for v in [stack, scroll, empty] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(v) }
        NSLayoutConstraint.activate([
            captures.widthAnchor.constraint(equalTo: stack.widthAnchor), taken.widthAnchor.constraint(equalTo: stack.widthAnchor),
            missing.widthAnchor.constraint(equalTo: stack.widthAnchor),
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
        // only when the layout changes: a column the user resized keeps its width across reloads
        guard appliedLayout != [full, inProject] else { return }
        appliedLayout = [full, inProject]
        metaWant = full ? 0 : (inProject ? 56 : 132)
        for c in table.tableColumns {
            switch c.identifier.rawValue {
            case "lead": c.width = full ? 22 : 44
            case "project": c.isHidden = inProject || !full; c.width = 100; projectHiddenForRoom = false
            case "meta": c.width = full ? 58 : (inProject ? 56 : 132); c.maxWidth = full ? 120 : 200
            case "state": c.isHidden = !full; c.width = 120
            case "time": c.width = 72
            default: break
            }
        }
        table.headerView = full ? header : nil
        fitTitle()
    }

    /// The title column takes whatever the fixed columns leave (users can still resize those).
    override func viewDidLayout() {
        super.viewDidLayout()
        fitTitle()
    }

    /// The dense list's id column at full width ("AW-2 · Atlas Web"); 0 in the table, where the user sizes it.
    private var metaWant: CGFloat = 0
    /// Below this the id column shows the key alone.
    static let metaWithProject: CGFloat = 110

    func fitTitle() {
        guard let title = table.tableColumn(withIdentifier: .init("title")) else { return }
        let others = table.tableColumns.filter { $0 !== title && !$0.isHidden }
        let spacing = table.intercellSpacing.width * CGFloat(others.count + 1) + 24   // + the inset style's margins
        func room() -> CGFloat { scroll.contentView.bounds.width - others.reduce(0) { $0 + $1.width } - spacing }
        // a narrow list (a job's detail beside it): the id column gives up the project name before the title is
        // squeezed, and no column ever ends up past the list's edge
        if metaWant > 0, let meta = table.tableColumn(withIdentifier: .init("meta")) {
            let mw = min(metaWant, max(meta.minWidth, room() + meta.width - 200))
            if abs(meta.width - mw) > 0.5 {
                let crossed = (meta.width < Self.metaWithProject) != (mw < Self.metaWithProject)
                meta.width = mw
                if crossed, let col = table.tableColumns.firstIndex(of: meta) {
                    table.reloadData(forRowIndexes: IndexSet(integersIn: 0..<table.numberOfRows), columnIndexes: [col])
                }
            }
        }
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
        let e = InlineRename(cell: cell, uid: it.uid, original: it.title, commit: { commit(it, $0) }) { [weak self] in
            guard let self = self else { return }
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

    func filtersChanged() {
        model.kinds = bar.selectedKinds
        model.state = bar.state.selectedItem?.representedObject as? String
        model.reload()
        scrollToStart()
    }

    func reloadJobs() { jobs.set(model.jobs, store: ProjectStore.shared, showProject: model.scope.projectID == nil) }
    /// "Unfiled captures: N" on top of the inbox while cards hang under the island.
    /// "Recently taken: N" on top of the Inbox and Unassigned while cards dragged out in the last 7 days are there.
    func reloadCaptures() {
        captures.set(count: model.scope == .inbox ? AppEnvironment.island?.hangingCount ?? 0 : 0)
        taken.set(count: model.scope == .inbox || model.scope == .unassigned ? snapper.recentlyTaken.count : 0)
    }

    /// "Can't find this folder" over a registered project whose folder is gone.
    func reloadMissing() {
        guard case .project(let p) = model.scope, let e = model.project(id: p) else { missing.isHidden = true; return }
        // with no rows the empty state says it (and offers Locate) instead
        missing.isHidden = !e.registered || model.rowCount == 0 || FileManager.default.fileExists(atPath: e.path.path)
    }

    /// Tests (wp6 `mainempty KIND`): one empty state on show, whatever the index holds, for screenshots; the next
    /// reload puts the real one back. KIND: first | inbox_zero | progress | unassigned | project | no_results |
    /// no_match | no_index | outdated | failed | missing | scanning | discarded.
    func testEmpty(_ kind: String) {
        scroll.isHidden = true
        switch kind {
        case "inbox_zero": empty.show(symbol: nil, mark: true, title: T("main.empty.inbox_zero"), message: T("main.empty.inbox_zero.detail"))
        case "progress": empty.show(symbol: nil, mark: true, title: T("main.empty.nothing_in_progress"), message: T("main.empty.nothing_in_progress.detail"))
        case "unassigned": empty.show(symbol: nil, mark: true, title: T("main.empty.all_filed"), message: T("main.empty.all_filed.detail"))
        case "project":
            empty.show(symbol: nil, mark: true, title: T("main.empty.project"), message: T("main.empty.project.detail", hk(.toggleRecord), hk(.snap)),
                       buttons: [(T("main.action.record"), 3), (T("main.action.snap"), 4)])
        case "no_results":
            empty.show(symbol: nil, mark: true, title: T("main.empty.no_results", "zebra"), message: T("main.empty.try_shorter"),
                       buttons: [(T("main.empty.clear_all"), 2)])
        case "no_match": empty.show(symbol: nil, mark: true, title: T("main.empty.no_match"), message: "", buttons: [(T("main.empty.clear_filters"), 2)])
        case "no_index": empty.show(symbol: nil, mark: true, title: T("main.empty.no_index"), message: T("main.empty.no_index.detail"), buttons: [(T("main.empty.scan"), 1)])
        case "outdated": empty.show(symbol: nil, mark: true, title: T("main.empty.outdated"), message: T("main.empty.outdated.detail"), buttons: [(T("main.empty.rebuild"), 1)])
        case "failed": empty.show(symbol: "exclamationmark.triangle", title: T("main.empty.scan_failed"), message: "index.py scan: exit 1", buttons: [(T("action.retry"), 1)])
        case "missing": empty.show(symbol: "questionmark.folder", title: T("main.missing.title"), message: T("main.missing.detail_empty"), buttons: [(T("main.missing.locate"), 7)])
        case "scanning": empty.show(symbol: nil, title: T("main.empty.scanning"), message: "", busy: true)
        case "discarded":
            empty.show(symbol: nil, mark: true, title: T("main.empty.discarded"), message: T("main.empty.discarded.detail"),
                       buttons: [(T("main.empty.clear_filters"), 2)])
        default:
            empty.show(symbol: nil, mark: true, title: T("main.empty.first"), message: T("main.empty.first.detail", hk(.toggleRecord), hk(.snap)),
                       buttons: [(T("project.open_folder"), 5), (T("main.action.record"), 3)])
        }
    }

    func updateEmpty() {
        switch model.indexState {
        case .scanning:
            empty.show(symbol: nil, title: T("main.empty.scanning"), message: "", busy: true)
            return
        case .noScripts:
            empty.show(symbol: "puzzlepiece.extension", title: T("main.empty.no_scripts"), message: T("main.empty.no_scripts.detail"))
            return
        case .missing:
            empty.show(symbol: nil, mark: true, title: T("main.empty.no_index"), message: T("main.empty.no_index.detail"),
                       buttons: [(T("main.empty.scan"), 1)])
            return
        case .outdated:
            empty.show(symbol: nil, mark: true, title: T("main.empty.outdated"), message: T("main.empty.outdated.detail"),
                       buttons: [(T("main.empty.rebuild"), 1)])
            return
        case .failed(let e):
            empty.show(symbol: "exclamationmark.triangle", title: T("main.empty.scan_failed"), message: e, buttons: [(T("action.retry"), 1)])
            return
        case .ready: break
        }
        guard model.rowCount == 0 else { empty.isHidden = true; return }
        let q = model.text.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty, let (it, why) = elsewhere(q) {
            // an id typed here for an item this place doesn't list (discarded, filtered out, another project): say
            // where it is and take you there — ⌘K finds it anywhere, the search shouldn't just say "no results"
            elsewhereUID = it.uid
            empty.show(symbol: nil, mark: true, title: T("main.empty.no_results", q), message: why,
                       buttons: [(T("main.empty.show_item", it.itemID), 8), (T("main.empty.clear_all"), 2)])
        } else if !q.isEmpty {
            empty.show(symbol: nil, mark: true, title: T("main.empty.no_results", q),
                       message: model.kinds.count + (model.shownState == nil ? 0 : 1) > 0
                           ? T("main.empty.filters_on") : T("main.empty.try_shorter"),
                       buttons: [(T("main.empty.clear_all"), 2)])
        } else if model.shownState == "discarded", model.kinds.isEmpty {
            empty.show(symbol: nil, mark: true, title: T("main.empty.discarded"), message: T("main.empty.discarded.detail"),
                       buttons: [(T("main.empty.clear_filters"), 2)])
        } else if model.filtered {
            empty.show(symbol: nil, mark: true, title: T("main.empty.no_match"), message: "",
                       buttons: [(T("main.empty.clear_filters"), 2)])
        } else {
            switch model.scope {
            case .inbox where model.counts.all > 0:
                empty.show(symbol: nil, mark: true, title: T("main.empty.inbox_zero"), message: T("main.empty.inbox_zero.detail"))
            case .inProgress:
                empty.show(symbol: nil, mark: true, title: T("main.empty.nothing_in_progress"), message: T("main.empty.nothing_in_progress.detail"))
            case .unassigned:
                empty.show(symbol: nil, mark: true, title: T("main.empty.all_filed"), message: T("main.empty.all_filed.detail"))
            case .project(let p) where model.project(id: p).map { $0.registered && !FileManager.default.fileExists(atPath: $0.path.path) } == true:
                empty.show(symbol: "questionmark.folder", title: T("main.missing.title"), message: T("main.missing.detail_empty"),
                           buttons: [(T("main.missing.locate"), 7)])
            case .project(let p):
                let current = ProjectStore.shared.currentID == p
                empty.show(symbol: nil, mark: true, title: T("main.empty.project"), message: T("main.empty.project.detail", hk(.toggleRecord), hk(.snap)),
                           buttons: current ? [(T("main.action.record"), 3), (T("main.action.snap"), 4)]
                                            : [(T("main.project.use"), 6), (T("main.action.record"), 3)])
            default:
                empty.show(symbol: nil, mark: true, title: T("main.empty.first"), message: T("main.empty.first.detail", hk(.toggleRecord), hk(.snap)),
                           buttons: [(T("project.open_folder"), 5), (T("main.action.record"), 3)])
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
            let c = make("lead") { () -> LeadCell in
                let c = LeadCell()
                c.ring.target = self
                c.ring.action = #selector(ringClicked(_:))
                return c
            }
            c.kindImage = Look.kindImage(it.kind)
            c.icon.alphaValue = it.discarded ? 0.4 : 1
            c.icon.setAccessibilityLabel(Look.kindName(it.kind))
            c.showsRing = !model.scope.isTable
            c.ring.set(it.state, label: Look.stateLabel(it))
            c.ring.isEnabled = !it.legacy
            return c
        case "title":
            let c = make("title") { TitleCell() }
            // the search hit, unless it is just the title again
            let searching = !model.text.trimmingCharacters(in: .whitespaces).isEmpty
            let hit = searching && SearchHit.adds(it.snippet, to: it.title) ? it.snippet : nil
            c.set(title: it.title, unread: it.state == "new", dimmed: quiet, struck: false, hit: hit)
            c.toolTip = [it.quote.isEmpty ? nil : "“\(it.quote)”", it.sessionTitle].compactMap { $0 }.joined(separator: "\n")
            return c
        case "meta":
            let c = make("meta") { MetaCell() }
            let full = model.scope.isTable
            let roomy = (table.tableColumn(withIdentifier: .init("meta"))?.width ?? 0) >= Self.metaWithProject
            c.key.stringValue = full || inOwnProject || it.projectID == "inbox" || !roomy ? it.itemID : "\(it.itemID) · \(it.projectName)"
            c.toolTip = it.projectID == "inbox" ? nil : it.projectName
            c.key.alignment = full ? .left : .right
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
            let c = make("time") { IconTextCell() }
            c.set(MainModel.relative(it.updated), font: Look.monoSub, align: .right)
            c.label.textColor = .secondaryLabelColor
            c.toolTip = MainModel.shortDate(it.updated)
            return c
        default: return nil
        }
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let v = make("row") { ItemRowView() }
        if let it = model.item(at: row) {
            v.label = [Look.kindName(it.kind), it.title.isEmpty ? T("main.item.untitled") : it.title, it.itemID, Look.stateLabel(it),
                       it.projectID == "inbox" ? T("project.inbox") : it.projectName,
                       MainModel.relative(it.updated)].joined(separator: ", ")
        }
        return v
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
        let r = table.row(for: sender)
        guard r >= 0 else { return }
        if !table.selectedRowIndexes.contains(r) { table.selectRowIndexes([r], byExtendingSelection: false) }
        view.window?.makeFirstResponder(table)
        actions?.showStateMenu(row: r, from: sender)
    }

    /// The ring of a row on screen (the S key opens the menu under it).
    func ringView(row r: Int) -> NSView? {
        let id = model.scope.isTable ? "state" : "lead"
        guard let col = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == id }) else { return nil }
        table.scrollRowToVisible(r)
        switch table.view(atColumn: col, row: r, makeIfNecessary: false) {
        case let c as LeadCell: return c.ring
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
