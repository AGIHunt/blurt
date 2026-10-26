// ⌘K: one field for every action, place and item, in the shape of Linear's ⌘K and Raycast's root search.
//
//   [kind icon  BA-1  Login button does nothing…]     the context chip: what "Selected Item" acts on (⌫ on an
//   🔍 Type a command, a project or an item…           empty field clears it, leaving the global commands)
//   ─────────────────────────────────────────────
//   SELECTED ITEM   Hand Off to Agent · Copy Instruction · Keep · Won't Do · Discard · Move to Project…
//   CAPTURE         Record · Snap
//   GO TO           Inbox · In Progress · All Items · Dictation History
//   ─────────────────────────────────────────────
//   the chosen row's hint ("Move to Discarded — you can restore it")          [↩] Run   [esc] Close
//
// The empty field shows the useful few (above); everything else (Open Folder, Rescan, Settings, the projects, Use X,
// Show Only…, running jobs) comes when searched. With a query: "Items" (the index's search, top 8; an ID puts that
// item on top, discarded or not) then "Commands" — commands first only when one's title starts with the query.
// A command matches on a contiguous run (two or more characters, or one at a word start) or on word prefixes
// ("cop ins" → Copy Instruction), never on a loose subsequence: "log" doesn't reach "Move to billing-api". A command
// that changes items (Keep, Discard, Move to X, Use X) is never pre-chosen from a weak match.
//
// One row anatomy, 36 pt: a 16 pt glyph (commands: SF Symbols in secondary ink; items: the kind icon in its colour),
// for items the ID in a fixed column, the title (the matched characters semibold), then one right-aligned accessory:
// keycaps for commands (§2.7: the UI font, tabular), the state ring and word for items (and the project when the
// results span several). A search hit shows on a second line only when the title doesn't hold it, once per run of
// identical snippets. The panel is the raised surface (§2.4 raise, 0.5 pt ring, the window's shadow) over a scrim,
// a fixed height (the list scrolls, with a fade at the bottom) so nothing jumps while typing.
import AppKit
import BlurtCore

final class PalettePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
}

final class CommandPalette: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSWindowDelegate {
    enum Section { case selected, capture, go, more }

    struct Entry {
        enum Kind { case command, place, item }
        var title: String
        var image: NSImage?
        var keys: String = ""
        var hint: String = ""
        var kind: Kind = .command
        /// changes items or settings (state, move, current project): never pre-chosen from a weak match
        var mutates = false
        var enabled = true
        var section: Section = .more
        /// shown on the empty field (else only when searched)
        var pinned = false
        // items
        var itemID = "", state = "", stateLabel = "", project = ""
        var snippet: NSAttributedString?
        var titleRanges: [NSRange] = [], idRanges: [NSRange] = []
        var run: () -> Void

        init(_ title: String, image: NSImage?, keys: String = "", hint: String = "", kind: Kind = .command, mutates: Bool = false,
             enabled: Bool = true, section: Section = .more, pinned: Bool = false, run: @escaping () -> Void) {
            self.title = title; self.image = image; self.keys = keys; self.hint = hint; self.kind = kind; self.mutates = mutates
            self.enabled = enabled; self.section = section; self.pinned = pinned; self.run = run
        }
    }

    enum Row {
        case header(String, first: Bool)
        case entry(Entry)
        case note(String)
    }

    static let width: CGFloat = 640
    static let rowHeight: CGFloat = 36
    static let snippetRowHeight: CGFloat = 46
    /// The list's fixed height (about ten rows), so the bottom edge never moves while typing. The empty state's third
    /// section starts just inside it, under the fade: there is more below.
    static let listHeight: CGFloat = 10 * rowHeight + 20

    unowned let controller: MainWindowController
    let panel: PalettePanel
    let field = PaletteField()
    let table = NSTableView()
    private let scroll = NSScrollView()
    private let surface = PaletteSurface()
    private let chip = PaletteChip()
    private let fade = PaletteFade()
    private let footerHint = NSTextField(labelWithString: "")
    private let footerRun = KeyCapsView(), footerRunLabel = NSTextField(labelWithString: "")
    private let footerEsc = KeyCapsView(), footerEscLabel = NSTextField(labelWithString: "")
    private let scrim = PaletteScrim()
    private var chipRow: NSLayoutConstraint!, chipGap: NSLayoutConstraint!
    var rows: [Row] = []
    /// The selectable rows in order (the test hooks read titles from here).
    var entries: [Entry] { rows.compactMap { if case .entry(let e) = $0 { return e } else { return nil } } }
    /// What the "Selected Item" commands act on: the list's selection when ⌘K opened, until ⌫ clears the chip.
    private(set) var scope: [ItemRow] = []
    private var idWidth: CGFloat = 0

    init(controller: MainWindowController) {
        self.controller = controller
        panel = PalettePanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 480),
                             styleMask: [.borderless], backing: .buffered, defer: true)
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.delegate = self
        panel.setAccessibilityLabel(T("menu.palette"))
        panel.contentView = surface

        let icon = NSImageView(image: Look.symbol("magnifyingglass", "", size: 17, weight: .medium) ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 20, weight: .regular)
        field.placeholderAttributedString = PaletteField.placeholder(T("main.palette.placeholder"))
        field.delegate = self
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.setAccessibilityLabel(T("main.palette.field"))
        field.setAccessibilityPlaceholderValue(T("main.palette.placeholder"))
        let sep = Hairline(), footSep = Hairline()

        table.addTableColumn(NSTableColumn(identifier: .init("e")))
        table.headerView = nil
        table.rowHeight = Self.rowHeight
        table.style = .plain
        table.backgroundColor = .clear
        table.intercellSpacing = .zero
        table.selectionHighlightStyle = .regular
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(runSelected)
        table.action = #selector(clicked)
        table.setAccessibilityLabel(T("main.palette.section.commands"))
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.verticalScrollElasticity = .none
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification,
                                               object: scroll.contentView)

        footerHint.font = .systemFont(ofSize: 11)
        footerHint.textColor = .secondaryLabelColor
        footerHint.lineBreakMode = .byTruncatingTail
        footerHint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for l in [footerRunLabel, footerEscLabel] {
            l.font = .systemFont(ofSize: 11)
            l.textColor = .secondaryLabelColor
            l.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        footerEsc.keys = ["esc"]
        footerEscLabel.stringValue = T("main.palette.footer.close")
        let runStack = NSStackView(views: [footerRun, footerRunLabel])
        let escStack = NSStackView(views: [footerEsc, footerEscLabel])
        for s in [runStack, escStack] { s.spacing = 5; s.setHuggingPriority(.required, for: .horizontal) }
        let keysStack = NSStackView(views: [runStack, escStack])
        keysStack.spacing = 14

        chip.onClear = { [weak self] in self?.clearScope() }
        for v in [chip, icon, field, sep, scroll, fade, footSep, footerHint, keysStack] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            surface.addSubview(v)
        }
        chipRow = chip.heightAnchor.constraint(equalToConstant: PaletteChip.height)
        chipGap = field.topAnchor.constraint(equalTo: chip.bottomAnchor, constant: 8)
        NSLayoutConstraint.activate([
            surface.widthAnchor.constraint(equalToConstant: Self.width),
            chip.topAnchor.constraint(equalTo: surface.topAnchor, constant: 14),
            chip.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 16),
            chip.trailingAnchor.constraint(lessThanOrEqualTo: surface.trailingAnchor, constant: -16),
            chipRow, chipGap,
            icon.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 18), icon.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            field.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -18),
            sep.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 12),
            sep.leadingAnchor.constraint(equalTo: surface.leadingAnchor), sep.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: sep.bottomAnchor, constant: 2),
            scroll.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -8),
            scroll.heightAnchor.constraint(equalToConstant: Self.listHeight),
            fade.leadingAnchor.constraint(equalTo: scroll.leadingAnchor), fade.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            fade.bottomAnchor.constraint(equalTo: scroll.bottomAnchor), fade.heightAnchor.constraint(equalToConstant: 28),
            footSep.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 6),
            footSep.leadingAnchor.constraint(equalTo: surface.leadingAnchor), footSep.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            footerHint.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 16),
            footerHint.centerYAnchor.constraint(equalTo: keysStack.centerYAnchor),
            footerHint.trailingAnchor.constraint(lessThanOrEqualTo: keysStack.leadingAnchor, constant: -16),
            keysStack.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -14),
            keysStack.topAnchor.constraint(equalTo: footSep.bottomAnchor),
            keysStack.heightAnchor.constraint(equalToConstant: 30),
            keysStack.bottomAnchor.constraint(equalTo: surface.bottomAnchor),
        ])
        scrim.onClick = { [weak self] in self?.close() }
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    var isOpen: Bool { panel.isVisible }

    func toggle() { isOpen ? close() : open() }

    func open() {
        guard let w = controller.window else { return }
        scope = controller.list.selectedItems
        setChip()
        field.stringValue = ""
        refresh()
        surface.layoutSubtreeIfNeeded()
        let h = surface.fittingSize.height
        // centred on the window, its top at about a sixth of the way down (never over the toolbar)
        let f = w.frame
        let top = f.maxY - max(96, f.height * 0.16)
        panel.setFrame(NSRect(x: f.midX - Self.width / 2, y: top - h, width: Self.width, height: h), display: false)
        showScrim(on: w)
        w.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }

    func close() {
        guard panel.isVisible else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        scrim.removeFromSuperview()
    }

    func windowDidResignKey(_ notification: Notification) { close() }

    /// The test hooks' typing: the text as if typed, the caret after it (never the text selected).
    func setQuery(_ q: String) {
        field.stringValue = q
        if let ed = field.currentEditor() { ed.selectedRange = NSRange(location: (q as NSString).length, length: 0) }
        refresh()
    }

    /// The window behind dims (the palette is the one focus); a click on it closes the palette.
    private func showScrim(on w: NSWindow) {
        guard let frameView = w.contentView?.superview else { return }
        scrim.frame = frameView.bounds
        scrim.autoresizingMask = [.width, .height]
        frameView.addSubview(scrim, positioned: .above, relativeTo: nil)
    }

    // MARK: the context chip

    private func setChip() {
        let on = !scope.isEmpty
        chip.isHidden = !on
        chipRow.constant = on ? PaletteChip.height : 0
        chipGap.constant = on ? 8 : 2
        guard on else { return }
        if scope.count == 1, let it = scope.first {
            chip.set(image: Look.kindImage(it.kind, size: 14), id: it.itemID, title: it.title.isEmpty ? it.itemID : it.title)
        } else {
            chip.set(image: Look.symbol("square.stack", "", size: 12), id: "", title: T("main.palette.chip.n", Loc.number(scope.count)))
        }
    }

    /// ⌫ on an empty field: the chip goes, and with it the commands that act on the selection.
    func clearScope() {
        guard !scope.isEmpty else { return }
        scope = []
        setChip()
        refresh()
        surface.layoutSubtreeIfNeeded()
        let h = surface.fittingSize.height
        var f = panel.frame
        f.origin.y += f.height - h
        f.size.height = h
        panel.setFrame(f, display: true)
    }

    // MARK: entries

    func commands() -> [Entry] {
        let c = controller
        let items = scope
        let has = !items.isEmpty
        func e(_ t: String, _ sym: String, _ keys: String = "", hint: String = "", kind: Entry.Kind = .command, section: Section = .more,
               pinned: Bool = false, mutates: Bool = false, enabled: Bool = true, _ run: @escaping () -> Void) -> Entry {
            Entry(t, image: Self.glyph(sym, t), keys: keys, hint: hint, kind: kind, mutates: mutates, enabled: enabled,
                  section: section, pinned: pinned, run: run)
        }
        func tip(_ key: String) -> String { T(key, "").trimmingCharacters(in: .whitespaces) }
        var out: [Entry] = []
        if has {
            out += [
                e(T("main.menu.start_session"), "paperplane", "⌘↩", hint: T("main.toolbar.handoff.tip"), section: .selected, pinned: true) { c.handOffSelection() },
                e(T("main.cmd.copy_instruction"), "doc.on.doc", "⇧⌘C", hint: T("main.palette.hint.copy_instruction"), section: .selected, pinned: true) { c.mCopyInstruction() },
                e(T("main.cmd.copy_full"), "text.alignleft", hint: T("main.palette.hint.copy_full"), section: .selected) { c.mCopyFull() },
            ]
            // K3: what the selection can do from its state (hand off is above); the hint goes to the footer
            // the same marks as the ring's menu (the shape of the state each leads to), so ⌘K and the menu read alike
            out += StateMenu.actions(for: items, canHandOff: false).map { a in
                Entry(StateMenu.title(a), image: StateMenu.icon(a, items, size: 14), keys: a == "discard" ? "⌫" : Lifecycle.keyLabel(a),
                      hint: StateMenu.hint(a, items), mutates: true, enabled: Scripts.canWrite, section: .selected, pinned: true) { c.apply(a, to: items) }
            }
            out += [
                e(T("main.palette.move_pick"), "arrow.turn.up.right", "M", section: .selected, pinned: true, enabled: Scripts.canWrite) {
                    DispatchQueue.main.async { c.pickProject() }
                },
                e(T("main.menu.export_bundle"), "archivebox", section: .selected) { c.mExportBundle() },
                e(T("main.menu.quick_look"), "eye", T("main.keys.space"), section: .selected) { c.list.toggleQuickLook() },
                e(T("action.reveal_in_finder"), "arrow.up.forward.app", "⇧⌘R", section: .selected) { c.mReveal() },
                e(T("action.copy_path"), "link", "⌥⌘C", section: .selected) { c.copyPaths() },
                e(T("main.menu.rename"), "pencil", "E", section: .selected) { c.renameSelection() },
            ]
        }
        out += [
            e(T("main.action.record"), "record.circle", hk(.toggleRecord), hint: tip("main.toolbar.record.tip"), section: .capture, pinned: true) { c.record() },
            e(T("main.action.snap"), "camera.viewfinder", hk(.snap), hint: tip("main.toolbar.snap.tip"), section: .capture, pinned: true) { c.snap() },
            e(T("main.place.inbox"), "tray", "⌘1", kind: .place, section: .go, pinned: true) { c.go(.inbox) },
            e(T("main.place.progress"), "circle.righthalf.filled", "⌘2", kind: .place, section: .go, pinned: true) { c.go(.inProgress) },
            e(T("project.inbox"), "tray.2", "⌘3", kind: .place, section: .go) { c.go(.unassigned) },
            e(T("main.place.all"), "list.bullet.rectangle", "⌘4", kind: .place, section: .go, pinned: true) { c.go(.all) },
            e(T("dictation.history.menu"), "character.cursor.ibeam", "⌥⌘D", kind: .place, section: .go, pinned: true) { c.showDictation() },
            e(T("project.open_folder"), "folder.badge.plus", "⌘O") { c.openFolder() },
            e(T("main.palette.switch_project"), "arrow.left.arrow.right", hk(.project)) { AppEnvironment.island?.showSwitcher() },
            e(T("main.empty.clear_filters"), "line.3.horizontal.decrease.circle", enabled: c.model.filtered) { c.clearFilters() },
            e(T("menu.rescan"), "arrow.clockwise") { c.model.scan() },
            e(T("menu.shortcuts"), "keyboard", "?") { c.showShortcuts() },
        ]
        if DictationLabModel.enabled { out.append(e(T("dictation.lab.menu"), "waveform", "⌥⌘L", kind: .place) { c.showDictationLab() }) }
        for k in KindStyle.builtIn {
            out.append(Entry(T("main.palette.only_kind", Look.kindName(k)), image: Look.kindImage(k, size: KindStyle.smallSize)) {
                c.model.kinds = [k]; c.model.reload()
            })
        }
        // what's running (organising, agent sessions): its progress or its terminal
        for j in JobStore.shared.active {
            out.append(e(JobLook.title(j), JobLook.symbol(j), hint: JobLook.status(j), kind: .place) { c.reveal(job: j.id) })
        }
        if AppEnvironment.settings != nil { out.append(e(T("menu.settings"), "gearshape", "⌘,") { AppEnvironment.settings?.show(pane: nil) }) }
        let current = ProjectStore.shared.currentID
        for p in c.model.projects where p.registered {
            let path = (p.path.path as NSString).abbreviatingWithTildeInPath
            out.append(e(p.name, "folder", hint: p.id == current ? T("main.project.current_count", path) : T("main.palette.project", path),
                         kind: .place) { c.reveal(project: p.id) })
            if has {
                out.append(e(T("main.palette.move_to", p.name), "arrow.turn.up.right", section: .selected, mutates: true) {
                    c.move(uids: items.map(\.uid), to: p.id)
                })
            }
            // where new captures go: the user's pick, never a guess (K2)
            if p.id != current {
                out.append(e(T("main.palette.use_project", p.name), "scope", hint: T("main.project.use.tip"), mutates: true) { c.useProject(p.id) })
            }
        }
        if current != nil {
            out.append(e(T("main.palette.use_none"), "tray.2", hint: T("app.menu.project.none_tip"), mutates: true) { c.useProject(nil) })
        }
        return out.filter(\.enabled)
    }

    /// Commands' glyphs: SF Symbols, one size and weight, template (the cell tints them secondary ink).
    static func glyph(_ name: String, _ label: String) -> NSImage? {
        let i = Look.symbol(name, label, size: 14) ?? Look.symbol("circle", label, size: 14)
        i?.isTemplate = true
        return i
    }

    /// The lifecycle verbs as SF Symbols in the ring's shape language (circle, slashed, crossed, checked), drawn at the
    /// same weight and ink as every other command — not the list's coloured rings, which read as faded here.
    static func lifecycleSymbol(_ a: String) -> String {
        switch a {
        case "keep": return "circle"
        case "done": return "checkmark.circle"
        case "send_back", "restore": return "arrow.uturn.backward.circle"
        case "take_back": return "arrow.uturn.left.circle"
        case "reopen": return "arrow.counterclockwise.circle"
        case "wontfix": return "circle.slash"
        case "discard": return "xmark.circle"
        default: return "circle"
        }
    }

    // MARK: matching

    struct Match {
        let score: Int
        let ranges: [NSRange]
        /// a contiguous run that starts a word: the user typed the start of this command's name
        let strong: Bool
        /// the title starts with the query
        let leading: Bool
    }

    /// How `text` matches `q`, nil = no match. A contiguous run (2+ characters, or 1 at a word start, or CJK), else
    /// word prefixes in order ("cop ins" → Copy Instruction, "mtp" → Move to Project). Never a loose subsequence.
    static func match(_ text: String, _ q: String) -> Match? {
        let query = q.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return Match(score: 0, ranges: [], strong: false, leading: false) }
        let ns = text as NSString
        let starts = wordStarts(text)
        let qlen = (query as NSString).length
        var best: Match?
        var from = 0
        while from < ns.length {
            let r = ns.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: NSRange(location: from, length: ns.length - from))
            guard r.location != NSNotFound else { break }
            let atWord = starts.contains(r.location)
            let cjk = query.unicodeScalars.contains { $0.properties.isIdeographic }
            if qlen >= 2 || atWord || cjk {
                let s = 100 + (atWord ? 40 : 0) + (r.location == 0 ? 30 : 0) - min(r.location, 20)
                if best == nil || s > best!.score {
                    best = Match(score: s, ranges: [r], strong: atWord, leading: r.location == 0)
                }
            }
            from = r.location + 1
        }
        if let b = best { return b }
        // word prefixes: each piece of the query (spaces dropped) is the start of a later word
        let p = Array(query.lowercased().filter { !$0.isWhitespace }.utf16)
        let t = Array(text.lowercased().utf16)
        guard t.count == ns.length else { return nil }      // lowercasing changed the length: no index mapping
        let ws = starts.sorted()
        func go(_ pi: Int, _ wi: Int) -> [NSRange]? {
            if pi == p.count { return [] }
            var k = wi
            while k < ws.count {
                let s = ws[k]
                var n = 0
                while pi + n < p.count, s + n < t.count, t[s + n] == p[pi + n], !(n > 0 && ws.contains(s + n)) { n += 1 }
                // the longest prefix of this word first, then shorter ones
                var m = n
                while m >= 1 {
                    if let rest = go(pi + m, k + 1) { return [NSRange(location: s, length: m)] + rest }
                    m -= 1
                }
                k += 1
            }
            return nil
        }
        guard p.count >= 2, let rs = go(0, 0) else { return nil }
        return Match(score: 60 - rs.count, ranges: rs, strong: false, leading: false)
    }

    /// UTF-16 offsets where a word starts: the first letter, and any letter after a space or punctuation.
    static func wordStarts(_ text: String) -> Set<Int> {
        var out = Set<Int>()
        var prevWord = false, k = 0
        for ch in text {
            let isWord = ch.isLetter || ch.isNumber
            if isWord && (!prevWord || ch.unicodeScalars.first.map { $0.properties.isIdeographic } == true) { out.insert(k) }
            prevWord = isWord
            k += ch.utf16.count
        }
        return out
    }

    /// The old scorer's contract for callers that only rank (higher is better, nil = no match).
    static func score(_ text: String, _ q: String) -> Int? { match(text, q)?.score }

    // MARK: rows

    func refresh() {
        let q = field.stringValue.trimmingCharacters(in: .whitespaces)
        let all = commands()
        var out: [Row] = []
        var preselect: Int?
        if q.isEmpty {
            let groups: [(Section, String)] = [
                (.selected, scope.count > 1 ? T("main.palette.section.selected_n") : T("main.palette.section.selected")),
                (.capture, T("main.palette.section.capture")),
                (.go, T("main.palette.section.go")),
            ]
            for (s, name) in groups {
                let es = all.filter { $0.pinned && $0.section == s }
                guard !es.isEmpty else { continue }
                out.append(.header(name, first: out.isEmpty))
                out += es.map { .entry($0) }
            }
            idWidth = 0
            preselect = out.firstIndex { if case .entry = $0 { return true } else { return false } }
        } else {
            var cmds: [(Match, Entry)] = all.compactMap { e in Self.match(e.title, q).map { m in
                var x = e
                x.titleRanges = m.ranges
                return (m, x)
            } }
            cmds.sort { $0.0.score > $1.0.score }
            let items = itemEntries(q)
            let commandsFirst = cmds.first.map { $0.0.leading && (q as NSString).length >= 2 && !$0.1.mutates } ?? false
            let itemRows: [Row] = items.isEmpty ? [] : [.header(T("main.palette.section.items"), first: false)] + items.map { .entry($0) }
            let cmdRows: [Row] = cmds.isEmpty ? [] : [.header(T("main.palette.section.commands"), first: false)] + cmds.map { .entry($0.1) }
            out = commandsFirst ? cmdRows + itemRows : itemRows + cmdRows
            if case .header(let h, _)? = out.first { out[0] = .header(h, first: true) }
            if out.isEmpty { out = [.note(T("main.palette.no_results", q))] }
            // the first row, unless it would change items on a weak match: then the first one that wouldn't
            let strong = Dictionary(cmds.map { ($0.1.title, $0.0.strong) }, uniquingKeysWith: { a, _ in a })
            preselect = out.indices.first { k in
                guard case .entry(let e) = out[k] else { return false }
                return !e.mutates || strong[e.title] == true
            }
        }
        rows = out
        table.reloadData()
        if let k = preselect {
            table.selectRowIndexes([k], byExtendingSelection: false)
            table.scrollRowToVisible(k)
        } else {
            table.deselectAll(nil)
        }
        table.scroll(.zero)
        if let k = preselect { table.scrollRowToVisible(k) }
        updateFooter()
        scrolled()
    }

    /// The index's search (the toolbar field's), top 8, as rows: the ID column, the title with the hit semibold, the
    /// state on the right, a snippet line only when the title doesn't hold the hit (and not the row above's again).
    private func itemEntries(_ q: String) -> [Entry] {
        guard let r = controller.model.reader else { idWidth = 0; return [] }
        // an id ("AW-11") is that item, wherever it is — a discarded one too — and it goes on top
        let byID = q.split(separator: " ").count == 1 && ItemQuery.isItemID(q)
        var rows = (try? r.items(ItemQuery(text: q, states: byID ? Lifecycle.states : [], limit: 8))) ?? []
        if byID, let k = rows.firstIndex(where: { $0.itemID.uppercased() == q.uppercased() }), k > 0 { rows.insert(rows.remove(at: k), at: 0) }
        let manyProjects = Set(rows.map(\.projectID)).count > 1
        let idFont = PaletteCell.idFont
        idWidth = rows.map { ceil(($0.itemID as NSString).size(withAttributes: [.font: idFont]).width) }.max().map { min(max($0, 30), 72) } ?? 0
        var lastSnippet = ""
        return rows.map { it in
            let title = SearchHit.oneLine(it.title.isEmpty ? it.itemID : it.title)
            var e = Entry(title, image: Look.kindImage(it.kind, size: KindStyle.smallSize), kind: .item) { [weak self] in
                self?.controller.reveal(uid: it.uid)
            }
            e.itemID = it.itemID
            e.state = it.state
            e.stateLabel = Look.stateLabel(it)
            e.project = manyProjects ? it.projectName : ""
            // the footer says where it is (the ID is on the row already)
            e.hint = it.projectID == "inbox" || it.projectName.isEmpty ? T("project.inbox") : it.projectName
            e.titleRanges = Self.occurrences(of: q, in: title)
            e.idRanges = Self.occurrences(of: q, in: it.itemID)
            if e.titleRanges.isEmpty, e.idRanges.isEmpty, SearchHit.adds(it.snippet, to: title), let s = it.snippet {
                let shown = SearchHit.shown(s)
                let plain = SearchHit.unmarked(shown)
                if plain != lastSnippet { e.snippet = Self.marked(shown) }
                lastSnippet = plain
            } else {
                lastSnippet = ""
            }
            return e
        }
    }

    /// Every case-insensitive occurrence of the query (or of its words) in `s`.
    static func occurrences(of q: String, in s: String) -> [NSRange] {
        let ns = s as NSString
        var out: [NSRange] = []
        let words = [q] + (q.contains(" ") ? q.split(separator: " ").map(String.init) : [])
        for w in words where !w.isEmpty {
            var from = 0
            while from < ns.length {
                let r = ns.range(of: w, options: [.caseInsensitive, .diacriticInsensitive], range: NSRange(location: from, length: ns.length - from))
                guard r.location != NSNotFound else { break }
                if !out.contains(where: { NSIntersectionRange($0, r).length > 0 }) { out.append(r) }
                from = r.location + r.length
            }
        }
        return out
    }

    /// index.db's "[hit]" markers as semibold ink, the rest secondary.
    static func marked(_ s: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let base: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
        let hit: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.labelColor]
        var inHit = false, run = ""
        func flush() { if !run.isEmpty { out.append(NSAttributedString(string: run, attributes: inHit ? hit : base)); run = "" } }
        for ch in s {
            if ch == "[" { flush(); inHit = true } else if ch == "]" { flush(); inHit = false } else { run.append(ch) }
        }
        flush()
        return out
    }

    func controlTextDidChange(_ obj: Notification) { refresh() }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { PaletteRowView() }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch rows[row] {
        case .header(_, let first): return first ? 26 : 32
        case .entry(let e): return e.snippet == nil ? Self.rowHeight : Self.snippetRowHeight
        case .note: return 64
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveDown(_:)): step(1); return true
        case #selector(NSResponder.moveUp(_:)): step(-1); return true
        case #selector(NSResponder.insertNewline(_:)): runSelected(); return true
        case #selector(NSResponder.cancelOperation(_:)): close(); return true
        case #selector(NSResponder.deleteBackward(_:)) where field.stringValue.isEmpty && !scope.isEmpty:
            clearScope(); return true
        default: return false
        }
    }

    /// The next selectable row, wrapping around; headers and notes are skipped.
    func step(_ d: Int) {
        let n = rows.count
        let ok = rows.indices.filter { if case .entry = rows[$0] { return true } else { return false } }
        guard !ok.isEmpty else { return }
        var k = table.selectedRow < 0 ? (d > 0 ? -1 : n) : table.selectedRow
        for _ in 0..<n {
            k = ((k + d) % n + n) % n
            if ok.contains(k) { break }
        }
        table.selectRowIndexes([k], byExtendingSelection: false)
        table.scrollRowToVisible(k)
    }

    @objc func clicked() { if table.clickedRow >= 0 { runSelected() } }

    @objc func runSelected() {
        let k = table.selectedRow
        guard k >= 0, k < rows.count, case .entry(let e) = rows[k], e.enabled else { NSSound.beep(); return }
        close()
        controller.window?.makeKeyAndOrderFront(nil)
        e.run()
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateFooter() }

    /// Left: what the chosen row does or where it is. Right: what ↩ does to it, and esc.
    private func updateFooter() {
        let k = table.selectedRow
        guard k >= 0, k < rows.count, case .entry(let e) = rows[k] else {
            footerHint.stringValue = ""
            footerRun.isHidden = true; footerRunLabel.isHidden = true
            return
        }
        footerHint.stringValue = e.hint
        footerRun.isHidden = false; footerRunLabel.isHidden = false
        footerRun.keys = ["↩"]
        footerRunLabel.stringValue = e.kind == .command ? T("main.palette.footer.run") : T("main.palette.footer.open")
    }

    /// The fade at the bottom shows only while there is more below.
    @objc private func scrolled() {
        let clip = scroll.contentView
        let more = (scroll.documentView?.frame.height ?? 0) - clip.bounds.maxY > 2
        fade.isHidden = !more
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .header(let s, _):
            let id = NSUserInterfaceItemIdentifier("ph")
            let v = tableView.makeView(withIdentifier: id, owner: self) as? PaletteHeader ?? PaletteHeader(id: id)
            v.label.stringValue = s
            return v
        case .note(let s):
            let v = PaletteHeader(id: .init("pn"))
            v.label.stringValue = s
            v.label.alignment = .center
            v.label.font = .systemFont(ofSize: 13)
            return v
        case .entry(let e):
            let id = NSUserInterfaceItemIdentifier("pe")
            let v = tableView.makeView(withIdentifier: id, owner: self) as? PaletteCell ?? PaletteCell(id: id)
            v.set(e, idWidth: e.kind == .item ? idWidth : 0)
            return v
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .entry(let e) = rows[row] { return e.enabled }
        return false
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { false }
}

// MARK: - surface

/// The raised surface (§2.4 raise: white / #323232), radius 12, a 0.5 pt ring; the window adds its shadow.
final class PaletteSurface: NSView {
    static let radius: CGFloat = 12
    static let raise = NSColor(name: nil) { ap in
        ap.isDark ? BrandColor.srgb(0x323232) : BrandColor.srgb(0xFFFFFF)
    }
    static let ring = NSColor(name: nil) { ap in
        ap.isDark ? NSColor(white: 1, alpha: 0.16) : NSColor(white: 0, alpha: 0.16)
    }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Self.radius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
    }
    required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = Self.raise.cgColor
        layer?.borderColor = Self.ring.cgColor
    }
}

/// The dim over the main window while the palette is up (light 14 %, dark 32 % black). A click on it closes.
final class PaletteScrim: NSView {
    var onClick: (() -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = NSColor.black.withAlphaComponent(effectiveAppearance.isDark ? 0.32 : 0.14).cgColor
    }
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func mouseDown(with event: NSEvent) { onClick?() }
}

/// The fade over the list's last rows while it scrolls on (the surface colour, clear → opaque).
final class PaletteFade: NSView {
    private let g = CAGradientLayer()
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(g)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        let c = PaletteSurface.raise.cgColor
        g.colors = [c.copy(alpha: 0)!, c]
        g.startPoint = CGPoint(x: 0.5, y: 1)
        g.endPoint = CGPoint(x: 0.5, y: 0)
    }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        g.frame = bounds
        CATransaction.commit()
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A 0.5 pt full-width rule (separatorColor).
final class Hairline: NSView {
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 1) }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 0.5).fill()
    }
}

/// The query field: its placeholder starts a hair after the caret, so the caret never sits on its first glyph.
final class PaletteField: NSTextField {
    static func placeholder(_ s: String) -> NSAttributedString {
        let p = NSMutableParagraphStyle()
        p.firstLineHeadIndent = 3
        p.lineBreakMode = .byTruncatingTail
        return NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: 20), .foregroundColor: NSColor.placeholderTextColor,
                                                          .paragraphStyle: p])
    }
}

// MARK: - the context chip

/// What the selection commands act on: kind icon, ID, title — or "3 items". Neutral fill, r 6.
final class PaletteChip: NSView {
    static let height: CGFloat = 24
    var onClear: (() -> Void)?
    private let icon = NSImageView(), id = NSTextField(labelWithString: ""), title = NSTextField(labelWithString: "")
    private let clear = NSButton()
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 6
        id.font = PaletteCell.idFont
        id.textColor = .secondaryLabelColor
        title.font = .systemFont(ofSize: 12, weight: .medium)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        icon.contentTintColor = .secondaryLabelColor
        clear.image = Look.symbol("xmark", T("main.palette.chip.clear"), size: 9, weight: .semibold)
        clear.isBordered = false
        clear.contentTintColor = .secondaryLabelColor
        clear.target = self
        clear.action = #selector(clearIt)
        clear.toolTip = T("main.palette.chip.clear")
        let stack = NSStackView(views: [icon, id, title, clear])
        stack.spacing = 6
        stack.setCustomSpacing(8, after: title)
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 7, bottom: 0, right: 7)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            title.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
            icon.widthAnchor.constraint(equalToConstant: 14), icon.heightAnchor.constraint(equalToConstant: 14),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityHelp(T("main.palette.chip.help"))
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func clearIt() { onClear?() }
    func set(image: NSImage?, id i: String, title t: String) {
        icon.image = image
        id.stringValue = i
        id.isHidden = i.isEmpty
        title.stringValue = SearchHit.oneLine(t)
        toolTip = T("main.palette.chip.help")
        setAccessibilityLabel([i, t].filter { !$0.isEmpty }.joined(separator: " "))
    }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor }
}

// MARK: - rows

/// The chosen row: the brand tint (§3.3), r 6, text stays `labelColor`. On the raised dark surface the tint goes to
/// 26 % so the row separates from the panel (≈ 1.3 : 1); light keeps `BrandColor.tint`. The panel never takes key
/// from the main window, so it doesn't fall back to the neutral not-key wash.
final class PaletteRowView: NSTableRowView {
    static let wash = NSColor(name: nil) { ap in
        if ap.isDark && !BrandColor.increaseContrast { return BrandColor.srgb(0x61DBBD, 0.26) }
        return BrandColor.tint
    }
    override var isEmphasized: Bool { get { false } set {} }
    override func drawSelection(in dirtyRect: NSRect) {
        Self.wash.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 1), xRadius: 6, yRadius: 6).fill()
    }
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
}

/// A section's name: 11 pt medium secondary, at the icon column, 4 pt above its first row.
final class PaletteHeader: NSTableCellView {
    let label = NSTextField(labelWithString: "")
    init(id: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        identifier = id
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
        ])
        setAccessibilityRole(.staticText)
    }
    required init?(coder: NSCoder) { fatalError() }
}

final class PaletteCell: NSTableCellView {
    static let idFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    let icon = NSImageView(), id = NSTextField(labelWithString: ""), title = NSTextField(labelWithString: "")
    let snippet = NSTextField(labelWithString: ""), project = NSTextField(labelWithString: "")
    let ring = NSImageView(), state = NSTextField(labelWithString: ""), keys = KeyCapsView()
    private var idW: NSLayoutConstraint!, idGap: NSLayoutConstraint!
    private var titleCenter: NSLayoutConstraint!, titleTop: NSLayoutConstraint!

    init(id ident: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        identifier = ident
        let accessory = NSStackView(views: [project, ring, state, keys])
        accessory.spacing = 5
        accessory.setCustomSpacing(10, after: project)
        accessory.setHuggingPriority(.required, for: .horizontal)
        accessory.setContentCompressionResistancePriority(.required, for: .horizontal)
        for v in [icon, id, title, snippet, accessory] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        icon.imageScaling = .scaleProportionallyDown
        icon.contentTintColor = .secondaryLabelColor
        id.font = Self.idFont
        id.textColor = .secondaryLabelColor
        title.font = .systemFont(ofSize: 13)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        snippet.lineBreakMode = .byTruncatingTail
        snippet.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for l in [project, state] {
            l.font = .systemFont(ofSize: 11)
            l.textColor = .secondaryLabelColor
            l.lineBreakMode = .byTruncatingTail
        }
        project.setContentCompressionResistancePriority(.init(700), for: .horizontal)
        project.widthAnchor.constraint(lessThanOrEqualToConstant: 120).isActive = true
        state.setContentCompressionResistancePriority(.required, for: .horizontal)
        imageView = icon
        textField = title
        idW = id.widthAnchor.constraint(equalToConstant: 0)
        idGap = title.leadingAnchor.constraint(equalTo: id.trailingAnchor, constant: 0)
        titleCenter = title.centerYAnchor.constraint(equalTo: centerYAnchor)
        titleTop = title.topAnchor.constraint(equalTo: topAnchor, constant: 6)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            icon.widthAnchor.constraint(equalToConstant: 20), icon.heightAnchor.constraint(equalToConstant: 18),
            icon.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            id.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10), idW,
            id.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
            idGap, titleCenter,
            snippet.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            snippet.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),
            snippet.trailingAnchor.constraint(lessThanOrEqualTo: accessory.leadingAnchor, constant: -16),
            accessory.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 16),
            accessory.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            accessory.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            ring.widthAnchor.constraint(equalToConstant: 12), ring.heightAnchor.constraint(equalToConstant: 12),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(_ e: CommandPalette.Entry, idWidth: CGFloat) {
        icon.image = e.image
        let isItem = e.kind == .item
        id.isHidden = !isItem
        idW.constant = isItem ? idWidth : 0
        idGap.constant = isItem ? 10 : 0
        id.attributedStringValue = Self.highlight(e.itemID, e.idRanges, font: Self.idFont, color: .secondaryLabelColor)
        title.attributedStringValue = Self.highlight(SearchHit.oneLine(e.title), e.titleRanges, font: .systemFont(ofSize: 13),
                                                     color: e.enabled ? .labelColor : .tertiaryLabelColor)
        snippet.isHidden = e.snippet == nil
        snippet.attributedStringValue = e.snippet ?? NSAttributedString()
        titleCenter.isActive = e.snippet == nil
        titleTop.isActive = e.snippet != nil
        project.isHidden = e.project.isEmpty
        project.stringValue = e.project
        ring.isHidden = !isItem
        state.isHidden = !isItem
        if isItem {
            ring.image = Look.ring(e.state, size: 12)
            state.stringValue = e.stateLabel
            state.textColor = Look.stateColor(e.state)
        }
        keys.isHidden = isItem || e.keys.isEmpty
        keys.keys = KeyCaps.split(e.keys)
        setAccessibilityLabel([e.itemID, e.title, e.stateLabel, e.project, e.keys].filter { !$0.isEmpty }.joined(separator: ", "))
    }

    /// `s` with `ranges` semibold in ink, the rest in `color`.
    static func highlight(_ s: String, _ ranges: [NSRange], font: NSFont, color: NSColor) -> NSAttributedString {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byTruncatingTail
        let a = NSMutableAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: p])
        let bold = font == idFont ? NSFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: .semibold)
            : NSFont.systemFont(ofSize: font.pointSize, weight: .semibold)
        for r in ranges where NSMaxRange(r) <= a.length {
            a.addAttributes([.font: bold, .foregroundColor: NSColor.labelColor], range: r)
        }
        return a
    }
}

// MARK: - keycaps

/// Shortcut keys as small keycaps (§2.7: the UI font with tabular figures, never a monospace — ⌘O must not read as
/// ⌘0): each modifier and the key in its own rounded box (r 4, quaternary fill), 11 pt medium, secondary ink. The
/// one AppKit keycap view (the palette, the keyboard shortcuts panel), twin of the SwiftUI `KeyCaps`
/// (HotkeySettings.swift), whose `split` it uses.
final class KeyCapsView: NSView {
    static let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    static let symbolFont = NSFont.systemFont(ofSize: 12, weight: .medium)
    static let capHeight: CGFloat = 18, gap: CGFloat = 3, pad: CGFloat = 5

    var keys: [String] = [] { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }

    convenience init(_ keys: [String]) {
        self.init(frame: .zero)
        self.keys = keys
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    private func attrs(_ k: String) -> [NSAttributedString.Key: Any] {
        let symbol = k.count == 1 && !(k.first?.isLetter ?? false) && !(k.first?.isNumber ?? false)
        return [.font: symbol ? Self.symbolFont : Self.font, .foregroundColor: NSColor.secondaryLabelColor]
    }

    private func widths() -> [CGFloat] {
        keys.map { max(Self.capHeight, ceil(($0 as NSString).size(withAttributes: attrs($0)).width) + Self.pad * 2) }
    }

    override var intrinsicContentSize: NSSize {
        let w = widths()
        return NSSize(width: w.reduce(0, +) + Self.gap * CGFloat(max(w.count - 1, 0)), height: Self.capHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        var x: CGFloat = 0
        let y = (bounds.height - Self.capHeight) / 2
        for (k, w) in zip(keys, widths()) {
            let r = NSRect(x: x, y: y, width: w, height: Self.capHeight)
            NSColor.quaternaryLabelColor.setFill()
            NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()
            let a = attrs(k)
            let sz = (k as NSString).size(withAttributes: a)
            (k as NSString).draw(at: NSPoint(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2), withAttributes: a)
            x += w + Self.gap
        }
    }
}
