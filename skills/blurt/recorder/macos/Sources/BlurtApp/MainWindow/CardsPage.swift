// Cards (docs/design/capabilities.md, v1.0.24): the cards' home in the main window — every card on one page, to browse
// and to find. The Cards panel by the notch (Capture/Island/CardsOverview.swift, ⌥H) stays the place to use a card
// mid-work: it floats over the app in front. People who took snaps couldn't find them anywhere in the main window, and
// History had no search; this page is both.
//
// One column (FullPageFrame): a row with the search field and, trailing, Show Under the Notch ⌥H (while cards hang),
// Voice Note ⌥V and Snap ⌥A (the user's own keys as keycaps); then two sections —
//   Current N    the cards under the notch, newest first (Snapper.cards)
//   History N    used in the last 7 days, the last one used first (Snapper.recentlyTaken); "Kept for 7 days" once,
//                quietly; a card on its last day says so in attention ink
// — the Cards panel's own tile (OverviewTile, through OverviewTileHost: one look for a set of cards across the app) in
// rows of as many as fit, widened so a row fills the column. With no card at all: the app's one empty state, saying the one next thing, with the two
// buttons. A search that finds nothing says so.
//
// What a tile does (the panel's, except that a click selects: this page stays, so nothing is copied on the way):
//   click = select · double-click = edit the note (Current) / the big preview (History) · right-click or "···" = the
//   card's menu (HangingCards.cardMenu / TakenPanel.menu, Preview first) · the eye chip or Space = the big preview
//   (CardPreview) · the Copy chip, ↩ or ⌘C = copy (picture and note, "✓ Copied" for 1.2 s) · ⌫ = delete (Undo in the
//   island) · drag = out into any app (CardDrag), a current one also onto a project.
// The keyboard (BlurtCore CardsPageRules, the one key map): the arrows walk both sections as one grid, ↑ from the top
// row goes back to the search field; ⌘F or / focuses the search, typing with the keyboard on the grid starts one, ↓ or
// ↩ in it goes into the grid, Esc clears it (then lets go of the selected card).
//
// Live: it follows .blurtCardsChanged and .blurtTakenChanged while it shows and reads again when it comes on show;
// nothing runs while it is hidden (no timers at all: a tile says no relative time).
import AppKit
import BlurtCore
import SwiftUI

final class CardsPage: NSObject, FullPage, ObservableObject, OverviewTileHost, CardPreviewHost, NSSearchFieldDelegate {
    /// The search field (⌘F; MainWindowController.searchField can hand it to Find).
    let search = NSSearchField()
    let board = CardsBoardView()
    private let root = CardsPageView()
    private let preview = CardPreview()

    /// every card under the notch / used in the last 7 days, whatever the search shows
    @Published private(set) var hangingCount = 0
    @Published private(set) var usedCount = 0
    /// tiles showing
    @Published private(set) var shownCount = 0
    @Published private(set) var query = ""
    /// the board changed: the page measures it again
    @Published private(set) var revision = 0
    /// the shortcuts changed (Settings → Shortcuts): the keycaps again
    @Published private(set) var keysRevision = 0
    private lazy var notchButton: NSView = {
        let v = NSHostingView(rootView: CardsNotchButton(page: self))
        v.frame.size = v.fittingSize
        return v
    }()

    var isEmpty: Bool { hangingCount == 0 && usedCount == 0 }
    var searching: Bool { !CardsPageRules.terms(query).isEmpty }
    var hasFocusedCard: Bool { selected != nil }

    private var tiles: [OverviewTile] { board.tiles }
    private var selected: Int?
    private weak var hovered: OverviewTile?
    private var shown = false
    /// the keyboard is on the grid (the page's view is the window's first responder)
    private var gridFocused = false
    /// a tile is being dragged out: the board is not rebuilt under it until the drag is done
    private var dragging = false
    private var reloadLater = false
    private var reloadQueued = false
    private var observers: [NSObjectProtocol] = []
    private var findMonitor: Any?
    private var previewMonitor: Any?
    /// Tests: the grid drawn as with the keyboard on it, and a preview that never takes the keyboard from the app in front.
    private var testKeyboard = false

    lazy var viewController: NSViewController = {
        let host = NSHostingView(rootView: CardsPageContent(page: self))
        host.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(host)
        NSLayoutConstraint.activate([host.topAnchor.constraint(equalTo: root.topAnchor), host.bottomAnchor.constraint(equalTo: root.bottomAnchor),
                                     host.leadingAnchor.constraint(equalTo: root.leadingAnchor), host.trailingAnchor.constraint(equalTo: root.trailingAnchor)])
        let vc = NSViewController()
        vc.view = root
        return vc
    }()

    override init() {
        super.init()
        root.page = self
        preview.overview = self
        // the column got another width (the window, the sidebar): the tiles at the size that fills it — once per
        // pass, and never while SwiftUI is laying the board out
        board.onTileSize = { [weak self] in self?.reloadSoon() }
        search.placeholderString = T("cards.search.placeholder")
        search.sendsSearchStringImmediately = true
        search.sendsWholeSearchString = false
        search.controlSize = .large                 // as tall as the buttons at the other end of its row
        search.font = .systemFont(ofSize: 13)
        search.setAccessibilityLabel(T("cards.search.placeholder"))
        search.toolTip = T("cards.search.tip")
        search.delegate = self
        search.target = self
        search.action = #selector(searchSent)
        let nc = NotificationCenter.default
        for name in [Notification.Name.blurtCardsChanged, .blurtTakenChanged] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.reloadSoon() })
        }
        observers.append(nc.addObserver(forName: HotkeyCenter.didChange, object: nil, queue: .main) { [weak self] _ in self?.keysRevision += 1 })
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] n in
                guard let self, let w = n.object as? NSWindow, w === self.root.window else { return }
                self.restate()
            })
        }
        // the window closed (the page is not told): the preview goes with it, and ⌘F is the next window's again
        observers.append(nc.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] n in
            guard let self, let w = n.object as? NSWindow, w === self.root.window else { return }
            self.didHide()
        })
        // Blurt is no longer in front: the preview floats, and would stay over the app the user went to
        observers.append(nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.closePreview()
        })
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    // MARK: FullPage

    func didShow() {
        shown = true
        watchFind(true)
        reload()
    }

    func didHide() {
        shown = false
        closePreview()
        watchFind(false)
    }

    func windowChanged() { restate() }

    // MARK: the cards

    /// The cards changed (or the column's width did): read them again on the next pass — once, however many notices
    /// came, and after whoever posted has finished (a delete says the count changed before it marks the card deleted).
    private func reloadSoon() {
        guard shown, !reloadQueued else { return }
        reloadQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.reloadQueued = false
            if self.shown { self.reload() }
        }
    }

    /// The cards again: both sets, the search applied, the selection kept on its card — or, when that card is gone,
    /// on the one that took its place (`keepPlace`; a search that leaves it out just ends the selection).
    func reload(keepPlace: Bool = true) {
        if dragging { reloadLater = true; return }
        reloadLater = false
        let was = selected.flatMap { $0 < tiles.count ? tiles[$0].shot : nil }
        let before = tiles.count
        let hangingShots = Array(snapper.cards.reversed()), usedShots = snapper.recentlyTaken
        let q = query, finding = searching
        let size = board.tile
        let current = hangingShots.filter { CardsPage.matches($0, q) }.map { tile($0, used: false, size: size) }
        let history = usedShots.filter { CardsPage.matches($0, q) }.map { tile($0, used: true, size: size) }
        hovered = nil
        board.show([
            .init(title: T("cards.section.current"), count: current.count, note: nil, tiles: current,
                  empty: finding ? nil : T("cards.current.none"), accessory: notchButton),
            .init(title: T("cards.section.history"), count: history.count, note: history.isEmpty ? nil : T("cards.history.kept"), tiles: history,
                  empty: finding ? nil : T(snapper.takenExpiredAny ? "cards.history.expired" : "cards.history.none")),
        ], tile: size)
        let old = selected
        selected = was.flatMap { s in tiles.firstIndex { $0.shot === s } }
        if selected == nil, keepPlace, let o = old, !tiles.isEmpty {
            selected = min(CardsPageRules.focusAfterDelete(o, count: before) ?? 0, tiles.count - 1)
        }
        restate()
        if let s = preview.shot, !tiles.contains(where: { $0.shot === s }) { closePreview() }
        hangingCount = hangingShots.count
        usedCount = usedShots.count
        shownCount = tiles.count
        revision += 1
    }

    /// What the search reads of a card: its note (typed and said), its name ("Snap · 19:05"), the type chosen for it,
    /// and the file a file card refers to. (Which app a card was used in is not recorded on a card.)
    static func matches(_ s: Shot, _ query: String) -> Bool {
        CardsPageRules.matches(query, fields: [s.words, s.plainName, s.itemKind.map { KindChip.name($0) },
                                               s.ref.map { ($0 as NSString).lastPathComponent }])
    }

    private func tile(_ s: Shot, used: Bool, size: CGSize) -> OverviewTile {
        let t = OverviewTile(s, overview: self, used: used, size: size)
        t.setAccessibilityLabel(CardsPage.spoken(s, used: used))
        t.setAccessibilityHelp(T(used ? "cards.ax.help_history" : "cards.ax.help_current"))
        t.toolTip = OverviewTile.footerLine(s, used: used).string        // the whole note, and when
        return t
    }

    /// VoiceOver: "Snap, the checkout button stays grey, 19:05" — what it is, its note, when (History: when it was used).
    static func spoken(_ s: Shot, used: Bool) -> String {
        let when = used ? OverviewTile.usedWhen(s).string : s.takenAt
        let note = s.words?.replacingOccurrences(of: "\n", with: " ")
        return [T(s.kind == .voice ? "cards.ax.voice" : "cards.ax.snap"), note, when].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    private func index(of t: OverviewTile) -> Int? { tiles.firstIndex { $0 === t } }

    /// The tiles' states: the selected one's wash, and with the keyboard on the grid its accent ring and actions.
    private func restate() {
        let keyboard = testKeyboard || (gridFocused && root.window?.isKeyWindow == true)
        for (i, t) in tiles.enumerated() {
            t.selected = i == selected
            t.keyboard = keyboard
        }
    }

    private func select(_ i: Int?, scroll: Bool = true) {
        selected = tiles.isEmpty ? nil : i.map { min(max($0, 0), tiles.count - 1) }
        restate()
        guard let i = selected else { return }
        if scroll { tiles[i].scrollToVisible(tiles[i].bounds.insetBy(dx: -8, dy: -28)) }
        NSAccessibility.post(element: tiles[i], notification: .focusedUIElementChanged)
    }

    // MARK: focus and the search

    func gridFocus(_ on: Bool) {
        gridFocused = on
        restate()
    }

    private func focusGrid() { root.window?.makeFirstResponder(root) }

    /// ⌘F, /, ↑ from the top row: the search field, its text selected to type over.
    func focusSearch() {
        guard search.window != nil, !search.isHiddenOrHasHiddenAncestor else { return NSSound.beep() }
        root.window?.makeFirstResponder(search)
        search.currentEditor()?.selectAll(nil)
    }

    private func setQuery(_ q: String) {
        if search.stringValue != q { search.stringValue = q }
        guard q != query else { return }
        query = q
        reload(keepPlace: false)
        emit(["event": "cards_page_search", "query": q, "shown": tiles.count])
    }

    func clearSearch() {
        setQuery("")
        if root.window?.firstResponder === search.currentEditor() { focusGrid() }
    }

    @objc private func searchSent() { setQuery(search.stringValue) }
    func controlTextDidChange(_ n: Notification) { setQuery(search.stringValue) }

    /// In the search field: ↓ or ↩ go into the cards (the first one, if none is selected), Esc clears the search and
    /// goes back to them — the main window's list search.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        let down = sel == #selector(NSResponder.moveDown(_:)) || sel == #selector(NSResponder.insertNewline(_:))
        let esc = sel == #selector(NSResponder.cancelOperation(_:))
        guard down || esc else { return false }
        if esc, !search.stringValue.isEmpty { setQuery("") }
        focusGrid()
        if selected == nil, !tiles.isEmpty { select(0) }
        return true
    }

    /// ⌘F while the page shows. (The window's own ⌘F asks MainWindowController.searchField, which has none for a page.)
    private func watchFind(_ on: Bool) {
        if let m = findMonitor { NSEvent.removeMonitor(m); findMonitor = nil }
        guard on else { return }
        findMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, self.shown, let w = self.root.window, e.window === w, w.attachedSheet == nil,
                  e.modifierFlags.intersection([.command, .option, .control, .shift]) == .command,
                  e.charactersIgnoringModifiers?.lowercased() == "f", !self.isEmpty else { return e }
            self.focusSearch()
            return nil
        }
    }

    // MARK: the keyboard on the grid

    /// A key with the keyboard on the grid (BlurtCore CardsPageRules.action); false: not one of the page's.
    func key(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection([.command, .option, .control])
        guard mods.isEmpty, let k = CardsOverview.panelKey(e) else { return typeToSearch(e) }
        return act(k)
    }

    @discardableResult
    private func act(_ k: CardsPanelKey) -> Bool {
        let pointed = hovered.flatMap { index(of: $0) }
        switch CardsPageRules.action(k, focus: selected, sections: board.counts, columns: board.columns, pointed: pointed, searching: !query.isEmpty) {
        case .focus(let i): select(i)
        case .search: focusSearch()
        case .preview(let i): openPreview(tiles[i], via: "space")
        case .copy(let i): copy(tiles[i], .click)
        case .delete(let i): delete(tiles[i])
        case .clearSearch: clearSearch()
        case .deselect: select(nil)
        case .none: return false
        }
        return true
    }

    /// A letter or a digit typed with the keyboard on the grid starts a search with it ("/" only goes to the field).
    private func typeToSearch(_ e: NSEvent) -> Bool {
        guard e.modifierFlags.intersection([.command, .option, .control]).isEmpty, let ch = e.characters, !ch.isEmpty, !isEmpty else { return false }
        if ch == "/" { focusSearch(); return true }
        guard ch.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) else { return false }
        focusSearch()
        search.currentEditor()?.keyDown(with: e)        // through the field's editor, so an input method composes as usual
        return true
    }

    /// Edit ▸ Copy.
    func copyFocused() { act(.copy) }

    // MARK: OverviewTileHost

    func pointed(_ t: OverviewTile, _ on: Bool) {
        if on { hovered = t } else if hovered === t { hovered = nil }
    }

    /// A click selects (and brings the keyboard to the grid); two: the note to edit (Current), the big preview (History).
    func clicked(_ t: OverviewTile, count: Int) {
        focusGrid()
        select(index(of: t), scroll: false)
        guard count == 2 else { return }
        if t.used {
            openPreview(t, via: "double_click")
        } else {
            editNote(t.shot)
        }
    }

    /// Edit Note (a current card's double-click, its menu): the note bubble the panel opens, under this card's tile —
    /// where the user is looking, not by the notch (which may be on another display). The tile is looked up when
    /// asked: the board is rebuilt when the card's words come in.
    private func editNote(_ s: Shot) {
        emit(["event": "card_edit", "n": s.n, "from": "page"])
        NoteBubble.shared.begin(s, mode: .edit, anchor: { [weak self] in
            self?.tiles.first { $0.shot === s }?.faceOnScreen ?? hanging.screenRect(of: s) ?? island.frameOnScreen
        })
    }

    func copy(_ t: OverviewTile, _ what: HangingCards.Copy) {
        let ok = HangingCards.copyShot(t.shot, what)
        emit(["event": t.used ? "taken_copied" : "card_copied", "n": t.shot.n, "what": what.rawValue, "from": "page", "ok": ok])
        if ok { t.flashCopied() }
    }

    /// The card's menu, the panel's: Preview first, then Current's (HangingCards.cardMenu) or History's (TakenPanel.menu).
    func menu(for t: OverviewTile) -> NSMenu {
        focusGrid()
        select(index(of: t), scroll: false)
        let copy: (HangingCards.Copy) -> Void = { [weak self, weak t] what in if let t { self?.copy(t, what) } }
        let m = t.used ? TakenPanel.menu(t.shot, from: { [weak t] in t?.faceOnScreen }, copy: copy)
                       : hanging.cardMenu(t.shot, copy: copy)
        m.insertItem(ClosureMenuItem(Loc.t("capture.card.preview", table: "Capture")) { [weak self, weak t] in
            if let t { self?.openPreview(t, via: "menu") }
        }, at: 0)
        m.insertItem(.separator(), at: 1)
        // Edit Note…: the same bubble, under this tile (the menu's own opens it by the notch)
        let edit = Loc.t("capture.card.edit_note", table: "Capture")
        if !t.used, let i = m.items.firstIndex(where: { $0.title == edit }) {
            let s = t.shot
            m.removeItem(at: i)
            m.insertItem(ClosureMenuItem(edit) { [weak self] in self?.editNote(s) }, at: i)
        }
        return m
    }

    /// Delete (⌫): no question first — "Deleted · Undo" in the island, as everywhere a card is deleted.
    private func delete(_ t: OverviewTile) {
        let used = t.used
        snapper.delete(t.shot)
        if used { NotificationCenter.default.post(name: .blurtTakenChanged, object: nil, userInfo: ["count": snapper.recentlyTaken.count]) }
    }

    func dragStarted() { dragging = true }

    func dragEnded() {
        dragging = false
        if reloadLater { reload() }
    }

    // MARK: the big preview

    func openPreview(_ t: OverviewTile, via: String) {
        guard let i = index(of: t) else { return }
        select(i)
        // "2 / 6": its place among the cards of its own section
        let first = t.used ? board.counts[0] : 0
        preview.show(t.shot, used: t.used, index: i - first, of: board.counts[t.used ? 1 : 0], on: root.window?.screen, keyboard: !testKeyboard)
        watchPreview(true)
        emit(["event": "card_preview", "n": t.shot.n, "open": true, "via": via, "from": "page"])
    }

    /// Closed (Space, Esc, ×, a click anywhere else): the keyboard back on the grid.
    func closePreview() {
        watchPreview(false)
        guard preview.isOpen else { return }
        let hadKeys = preview.hasKeyboard
        preview.close()
        if hadKeys { root.window?.makeKey() }
        emit(["event": "card_preview", "open": false, "from": "page"])
    }

    /// ← / → in the preview: the card before / after it, through both sections.
    func previewStep(_ d: Int) {
        guard let cur = selected ?? preview.shot.flatMap({ s in tiles.firstIndex { $0.shot === s } }), !tiles.isEmpty else { return }
        let i = min(max(cur + d, 0), tiles.count - 1)
        guard i != cur || preview.shot !== tiles[i].shot else { return }
        openPreview(tiles[i], via: "arrow")
    }

    /// While the preview is open, a click anywhere but on it closes it (the click still does what it does).
    private func watchPreview(_ on: Bool) {
        if !on {
            if let m = previewMonitor { NSEvent.removeMonitor(m); previewMonitor = nil }
            return
        }
        guard previewMonitor == nil else { return }
        previewMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] e in
            if let self, let w = e.window, !self.preview.owns(w) { self.closePreview() }
            return e
        }
    }

    // MARK: the page's buttons

    /// Snap: the toolbar's own (the picker comes up over whatever is on screen).
    func snap() { MainWindowController.shared.snap() }
    func voiceNote() { VoiceInput.shared.toggle() }
    /// The Cards panel under the notch, on Current (it floats: the next click outside it closes it).
    func showUnderNotch() { CardsOverview.shared.show(keyboard: false, segment: .hanging, focusFirst: false) }

    // MARK: tests

    /// `cardspage …` (BLURT_TEST_COMMANDS): state · reload · query [TEXT] · focus on|off (the grid drawn with the
    /// keyboard on it) · find (⌘F) · searchkey down|return|esc · key left|right|up|down|space|return|delete|esc|copy ·
    /// type TEXT (typed with the keyboard on the grid) · post KEYCODE [cmd] [CHARS] (a real key event to the window) · editcopy (Edit ▸ Copy) · select N · click N · double N · hover [N] · copy N · copied N ·
    /// menu N · delete N · preview [N] · previewclose · previewstep ±1 — N is a capture's number. Every one ends
    /// with a "cards_page" event: what shows, in order.
    func testCommand(_ arg: String) {
        let a = arg.split(separator: " ").map(String.init)
        let tile = { (i: Int) -> OverviewTile? in a.count > i ? Int(a[i]).flatMap { n in self.tiles.first { $0.shot.n == n } } : nil }
        switch a.first ?? "" {
        case "reload": reload()
        case "query": setQuery(a.dropFirst().joined(separator: " "))
        case "focus": testKeyboard = !a.contains("off"); restate()
        case "find": focusSearch()
        case "searchkey":
            let sel = a.contains("esc") ? #selector(NSResponder.cancelOperation(_:)) : a.contains("down") ? #selector(NSResponder.moveDown(_:))
                : #selector(NSResponder.insertNewline(_:))
            _ = control(search, textView: NSTextView(), doCommandBy: sel)
        case "key":
            let keys: [String: CardsPanelKey] = ["left": .left, "right": .right, "up": .up, "down": .down, "space": .space, "return": .enter,
                                                 "delete": .delete, "esc": .escape, "copy": .copy]
            if a.count > 1, let k = keys[a[1]] {
                testKeyboard = true
                if preview.isOpen {
                    switch CardsPanelRules.previewAction(k) {
                    case .step(let d): previewStep(d)
                    case .close: closePreview()
                    case .none: break
                    }
                } else {
                    act(k)
                    restate()
                }
            }
        case "type":
            let text = a.dropFirst().joined(separator: " ")
            if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: root.window?.windowNumber ?? 0, context: nil, characters: text,
                                        charactersIgnoringModifiers: text, isARepeat: false, keyCode: 0) { _ = typeToSearch(e) }
        case "post":                                    // post KEYCODE [cmd] [CHARS]: a real key-down, through the app's event queue
            if a.count > 1, let code = UInt16(a[1]), let w = root.window {
                // the characters a keyboard sends with that key (an event without any is dropped on its way to the responder)
                let named: [UInt16: String] = [123: "\u{F702}", 124: "\u{F703}", 125: "\u{F701}", 126: "\u{F700}", 36: "\r", 49: " ", 51: "\u{7F}", 53: "\u{1B}"]
                let chars = a.dropFirst(2).first { $0 != "cmd" } ?? named[code] ?? ""
                let arrow: NSEvent.ModifierFlags = (123...126).contains(code) ? [.numericPad, .function] : []
                if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: a.contains("cmd") ? [.command] : arrow,
                                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil,
                                            characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) {
                    NSApp.postEvent(e, atStart: false)
                }
            }
            return DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.testCommand("state") }
        case "editcopy":                                // = Edit ▸ Copy: its action from the window's first responder, as the menu sends it
            let item = NSApp.mainMenu?.items.compactMap { $0.submenu?.items.first { $0.action == #selector(NSText.copy(_:)) } }.first
            let first = root.window?.firstResponder
            emit(["event": "cards_page_editcopy", "responder": first.map { String(describing: type(of: $0)) } ?? "",
                  "enabled": item.map { root.validateMenuItem($0) } ?? false,
                  "performed": first?.tryToPerform(#selector(NSText.copy(_:)), with: item) ?? false])
        case "select": select(tile(1).flatMap { index(of: $0) })
        case "click": if let t = tile(1) { clicked(t, count: 1) }
        case "double": if let t = tile(1) { clicked(t, count: 1); clicked(t, count: 2) }
        case "hover": for t in tiles { t.hovering = t === tile(1) }
        case "copy": if let t = tile(1) { copy(t, .click) }
        case "copied": tile(1)?.flashCopied()
        case "menu": if let t = tile(1) { emit(["event": "cards_page_menu", "n": t.shot.n, "items": menu(for: t).items.filter { !$0.isSeparatorItem }.map(\.title)]) }
        case "delete": if let t = tile(1) { delete(t) }
        case "preview": testKeyboard = true; if let t = tile(1) ?? tiles.first { openPreview(t, via: "test") }
        case "previewclose": closePreview()
        case "previewstep": previewStep(a.count > 1 ? Int(a[1]) ?? 1 : 1)
        default: break
        }
        let n0 = board.counts.first ?? 0
        emit(["event": "cards_page", "shown": shown, "current": tiles.prefix(n0).map(\.shot.n), "history": tiles.dropFirst(n0).map(\.shot.n),
              "hanging": hangingCount, "used": usedCount, "selected": selected.map { tiles[$0].shot.n } ?? -1, "columns": board.columns,
              "query": query, "grid_focus": gridFocused, "search_focus": root.window?.firstResponder === search.currentEditor() && search.currentEditor() != nil,
              "preview": preview.shot?.n ?? -1, "labels": tiles.map { $0.accessibilityLabel() ?? "" },
              "board": [board.frame.width, board.frame.height]])
    }
}

/// The page in SwiftUI: the frame every full page sits in, the row of search and buttons, then the board — or the
/// empty state.
struct CardsPageContent: View {
    @ObservedObject var page: CardsPage

    var body: some View {
        FullPageFrame(title: T("cards.title"), subtitle: T("cards.subtitle")) {
            if page.isEmpty {
                // no card anywhere: the one next thing, and the two ways to do it
                EmptyStateContent(title: T("cards.empty.title"), message: emptyMessage) {
                    HStack(spacing: 8) {
                        snapButton(primary: true)
                        voiceButton
                    }
                }
                .padding(.top, 36)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    // the search and, at the grid's right edge, the two ways to make a card
                    HStack(spacing: 8) {
                        CardsSearchField(field: page.search).frame(minWidth: 120, maxWidth: 280)
                        Spacer(minLength: 4)
                        voiceButton
                        snapButton(primary: false)
                    }
                    if page.shownCount == 0, page.searching {
                        VStack(spacing: 10) {
                            Text(T("cards.search.none", page.query.trimmingCharacters(in: .whitespaces)))
                                .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            Button(Look.menuCase(T("cards.search.clear"))) { page.clearSearch() }
                                .buttonStyle(SettingsOutlinedButtonStyle(compact: true))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 56)
                    } else {
                        CardsBoard(page: page, revision: page.revision)
                            .padding(.horizontal, -CardsBoardView.inset)
                            .padding(.top, 24)
                    }
                }
            }
        }
    }

    /// "Press ⌥A to take a snap…" with the user's own key; without one (the shortcut is off), the sentence without it.
    private var emptyMessage: String {
        let k = hk(.snap)
        return k.isEmpty ? T("cards.empty.message_nokey") : T("cards.empty.message", k)
    }

    @ViewBuilder private func snapButton(primary: Bool) -> some View {
        let label = CardsKeyedLabel(title: Look.menuCase(T("cards.action.snap")), key: hk(.snap), onBrand: primary)
        if primary {
            Button { page.snap() } label: { label }.buttonStyle(.brand).help(T("cards.action.snap.tip"))
        } else {
            Button { page.snap() } label: { label }.buttonStyle(SettingsOutlinedButtonStyle()).help(T("cards.action.snap.tip"))
        }
    }

    private var voiceButton: some View {
        Button { page.voiceNote() } label: { CardsKeyedLabel(title: Look.menuCase(T("cards.action.voice")), key: hk(.voice)) }
            .buttonStyle(SettingsOutlinedButtonStyle())
            .help(T("cards.action.voice.tip"))
    }
}
