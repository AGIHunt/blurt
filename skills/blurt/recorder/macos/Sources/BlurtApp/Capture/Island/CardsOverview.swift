// Every hanging card at once (v0.9). The row under the island shows the newest few (BlurtCore CardRow: at most 5, newest
// first); the rest wait behind a quiet "+N" tile at its end, and a click on it (↩ on it with the keyboard, its
// VoiceOver press) opens this panel: every card, newest first, in a grid — with what a card on its thread can do:
//   click = copy (once the double-click interval has passed: a double-click edits the note instead, and never copies
//   first) · right-click = the card's menu (HangingCards.cardMenu: Copy Image / Text, Copy All, Edit Note…, Move To ▸,
//   Organize, Delete) · drag = out into any app (the same items as a card's drag, CardDrag; a voice card over a chat
//   app pastes its words), or onto a project in the island · with the keyboard (a click puts it on the panel; ↩ on the
//   tile or its VoiceOver press opens it with the keyboard on the newest card): arrows move, ↩ / ⌘C copies and closes
//   it (the keyboard back where the user was, so ⌘V pastes), ⌫ deletes (Undo in the island), Esc closes.
// A small utility panel under the strip the cards hang in (HangingCards.panelTop, whether they are down or not, so
// cards that come down again never cover its title), like Recently Dragged Out; it follows the cards as they change
// (never in the middle of a drag out of it or a click's pending copy: that waits until they are done) and closes itself
// when none are left. It never activates Blurt.
//
// The look (v0.9.1, the same family as Recently Dragged Out, docs/design/system.md §3.2): no window title in inactive
// grey and no dead minimise / zoom — a transparent title bar with only the close button, and the panel's own heading in
// it ("Cards  7", ink; "···" on the right with what concerns every card: Copy All, Organize All, Delete All). A grid that
// fits its count (≤ 4 in one row, then 3 a row, then 4 with a scroll), tiles as wide as a card can be (148 × 100),
// pictures cropped from their top-left (where a window's title is), on the card's opaque surface with a hairline. Under
// each: one line of what it is (the note, or "Snap · 19:03") and one quiet line of when ("5 min ago"; "Couldn't
// transcribe" in attention ink). The tile under the pointer gets the brand-tint wash and its actions — Copy (the one
// primary) and a quiet "···" — no other tile shows any; the keyboard's tile the same wash plus the accent ring. A
// hairline, then one hint line: how to use a tile, or the keys while the panel has the keyboard. "Copied" is the done
// pill with the ok check.

import AppKit
import BlurtCore

final class OverviewPanel: NSPanel {
    var onKey: ((NSEvent) -> Bool)?
    override var canBecomeKey: Bool { true }
    override func sendEvent(_ e: NSEvent) {
        if e.type == .keyDown, onKey?(e) == true { return }
        super.sendEvent(e)
    }
}

final class CardsOverview: NSObject, NSWindowDelegate {
    static let shared = CardsOverview()
    static let tile = CGSize(width: 148, height: 100)
    /// the two caption lines under a tile: what it is, then when
    static let caption: CGFloat = 38
    static let gap: CGFloat = 14
    static let pad: CGFloat = 16
    static let footerH: CGFloat = 36

    /// Columns for `n` cards: one row up to 4, then 3 a row (5–9: no holes in 6 or 9), then 4 and a scroll.
    static func columns(_ n: Int) -> Int { n <= 4 ? max(1, n) : n <= 9 ? 3 : 4 }

    private var window: OverviewPanel?
    private let grid = FlippedView()
    private let scroll = NSScrollView()
    private let heading = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let more = ClosureButton("", {})
    private let rule = NSBox()
    private let hint = NSTextField(labelWithString: "")
    private(set) var tiles: [OverviewTile] = []
    private var selected: Int?
    private var click = DeferredClick<ObjectIdentifier>()
    private var titleBar: CGFloat = 28

    var isOpen: Bool { window?.isVisible ?? false }
    /// It has the keyboard (the cards' Esc hotkey stays out of its way).
    var hasKeyboard: Bool { window?.isKeyWindow == true || keyboardShown }
    /// Tests: opened "with the keyboard" without taking it from the app in front — drawn as if it had it.
    private var keyboardShown = false
    /// A tile is being dragged out, or a click's copy is pending: the grid is not rebuilt under it until it is done.
    private var dragging = false
    private var reloadLater = false
    /// Tests: "with the keyboard" selects the first tile but never takes the keyboard from the app in front.
    var testKeyless = false

    /// Opens under the cards (`keyboard`: with the keyboard on it, from ↩ on the "+N" tile).
    func show(keyboard: Bool = false) {
        if window == nil { build() }
        guard let w = window else { return }
        keyboardShown = keyboard && testKeyless
        rebuild()
        guard !tiles.isEmpty else { return hide() }
        let size = w.frame.size
        let anchor = island.frameOnScreen
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main ?? NSScreen.screens[0]
        let top = min(hanging.panelTop, anchor.minY - 12)
        var x = anchor.midX - size.width / 2
        x = min(max(x, screen.visibleFrame.minX + 12), screen.visibleFrame.maxX - size.width - 12)
        w.setFrameOrigin(NSPoint(x: x, y: max(screen.visibleFrame.minY + 12, min(top, screen.visibleFrame.maxY) - size.height)))
        w.orderFrontRegardless()
        if keyboard {
            if !testKeyless {
                snapper.rememberFrontApp()
                w.makeKey()
            }
            select(0)
        }
        updateHint()
        emit(["event": "cards_overview_open", "count": tiles.count, "order": tiles.map(\.shot.n)])
    }

    func hide() {
        guard let w = window, w.isVisible else { return }
        let wasKey = w.isKeyWindow
        keyboardShown = false
        w.orderOut(nil)
        if wasKey { snapper.restoreFocus() }
        emit(["event": "cards_overview_open", "open": false])
    }

    /// The cards changed (one copied out, filed, deleted, a new one caught): the grid again, if it is open.
    func reload() {
        guard isOpen else { return }
        if dragging || click.pending != nil { reloadLater = true; return }
        reloadLater = false
        rebuild()
        if tiles.isEmpty { hide() }
    }

    /// A drag or a pending click is done: the reload it held back, if any.
    private func settled() {
        guard reloadLater, !dragging, click.pending == nil else { return }
        reload()
    }

    func windowWillClose(_ notification: Notification) { emit(["event": "cards_overview_open", "open": false]) }
    func windowDidBecomeKey(_ notification: Notification) { updateHint() }
    func windowDidResignKey(_ notification: Notification) { keyboardShown = false; updateHint() }

    private func build() {
        let w = OverviewPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                              styleMask: [.titled, .closable, .fullSizeContentView, .utilityWindow, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        w.isFloatingPanel = true
        w.level = .floating
        w.hidesOnDeactivate = false
        w.isReleasedWhenClosed = false
        w.becomesKeyOnlyIfNeeded = true
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.sharingType = chromeSharing
        w.delegate = self
        w.onKey = { [weak self] e in self?.key(e) ?? false }
        // only the close button: a panel that can't be minimised or zoomed doesn't show those (they read as disabled)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.standardWindowButton(.miniaturizeButton)?.isHidden = true
        w.standardWindowButton(.zoomButton)?.isHidden = true
        titleBar = max(24, w.frame.height - w.contentLayoutRect.height)
        let root = NSView()
        // the heading, in the title bar's row and centred like a window title — but drawn by the panel, in ink, so it
        // never reads as an inactive window
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        heading.textColor = .labelColor
        heading.stringValue = Loc.t("capture.cards.overview_heading", table: "Capture")
        countLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        countLabel.textColor = .secondaryLabelColor
        let head = NSStackView(views: [heading, countLabel])
        head.spacing = 6
        head.translatesAutoresizingMaskIntoConstraints = false
        let moreTitle = Loc.t("capture.taken.more", table: "Capture")
        more.image = Look.symbol("ellipsis", moreTitle, size: 13, weight: .medium)
        more.imagePosition = .imageOnly
        more.isBordered = false
        more.contentTintColor = .secondaryLabelColor
        more.toolTip = moreTitle
        more.setAccessibilityLabel(moreTitle)
        more.set { [weak self] in self?.popAllMenu() }
        more.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = grid
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        rule.boxType = .separator
        rule.translatesAutoresizingMaskIntoConstraints = false
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.lineBreakMode = .byTruncatingTail
        hint.translatesAutoresizingMaskIntoConstraints = false
        for v in [head, more, scroll, rule, hint] as [NSView] { root.addSubview(v) }
        NSLayoutConstraint.activate([
            head.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            head.centerYAnchor.constraint(equalTo: root.topAnchor, constant: titleBar / 2),
            more.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            more.centerYAnchor.constraint(equalTo: head.centerYAnchor),
            more.widthAnchor.constraint(equalToConstant: 24), more.heightAnchor.constraint(equalToConstant: 22),
            scroll.topAnchor.constraint(equalTo: root.topAnchor, constant: titleBar),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: rule.topAnchor),
            rule.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: CardsOverview.pad),
            rule.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -CardsOverview.pad),
            rule.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -CardsOverview.footerH),
            hint.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: CardsOverview.pad),
            hint.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -CardsOverview.pad),
            hint.centerYAnchor.constraint(equalTo: root.bottomAnchor, constant: -CardsOverview.footerH / 2),
        ])
        w.contentView = root
        window = w
    }

    /// "···" in the heading: what concerns every card (the island's menu without Show: the cards are here).
    private func popAllMenu() {
        let m = NSMenu()
        for (t, f) in hanging.islandMenuItems().dropFirst() { m.addItem(ClosureMenuItem(t, f)) }
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: more.bounds.height + 3), in: more)
    }

    private func rebuild() {
        guard let w = window else { return }
        let was = selected.flatMap { $0 < tiles.count ? tiles[$0].shot : nil }
        for t in tiles { t.removeFromSuperview() }
        // newest first, the order they hang in
        tiles = snapper.cards.reversed().map { OverviewTile($0, overview: self) }
        let cols = CardsOverview.columns(tiles.count), sz = CardsOverview.tile, g = CardsOverview.gap, pad = CardsOverview.pad
        let cellH = sz.height + CardsOverview.caption
        for (i, t) in tiles.enumerated() {
            t.frame = NSRect(x: pad + CGFloat(i % cols) * (sz.width + g), y: pad + CGFloat(i / cols) * (cellH + g), width: sz.width, height: cellH)
            grid.addSubview(t)
        }
        let rows = max(1, (tiles.count + cols - 1) / cols)
        let width = pad * 2 + CGFloat(cols) * sz.width + CGFloat(cols - 1) * g
        let full = pad * 2 + CGFloat(rows) * cellH + CGFloat(rows - 1) * g
        grid.frame = NSRect(x: 0, y: 0, width: width, height: full)
        let shown = pad * 2 + CGFloat(min(rows, 3)) * cellH + CGFloat(min(rows, 3) - 1) * g
        // the heading and "···" need room too: never narrower than 300
        let contentW = max(300, width), contentH = titleBar + shown + 1 + CardsOverview.footerH
        var f = w.frame
        let dh = contentH - f.height
        f.size.width = contentW
        f.size.height = contentH
        f.origin.y -= dh
        w.setFrame(f, display: true)
        grid.frame.origin.x = (contentW - width) / 2
        countLabel.stringValue = Loc.number(tiles.count)
        w.title = Loc.plural("capture.cards.overview_title", table: "Capture", count: tiles.count)
        w.setAccessibilityLabel(w.title)
        selected = was.flatMap { s in tiles.firstIndex { $0.shot === s } } ?? selected.map { min($0, tiles.count - 1) }
        if tiles.isEmpty { selected = nil }
        for (i, t) in tiles.enumerated() { t.selected = i == selected; t.keyboard = hasKeyboard }
        updateHint()
    }

    /// The footer's one line: how to use a tile, or the keys while the panel has the keyboard.
    private func updateHint() {
        hint.stringValue = Loc.t(hasKeyboard ? "capture.cards.overview_keys" : "capture.cards.overview_hint", table: "Capture")
        for t in tiles { t.keyboard = hasKeyboard }
    }

    // MARK: actions

    fileprivate func select(_ i: Int?) {
        selected = i.map { min(max($0, 0), tiles.count - 1) }
        for (k, t) in tiles.enumerated() { t.selected = k == selected }
        if let i = selected {
            tiles[i].scrollToVisible(tiles[i].bounds)
            NSAccessibility.post(element: tiles[i], notification: .focusedUIElementChanged)
        }
    }

    /// A click on a tile: two = edit the note; one = copy, after the double-click interval (DeferredClick).
    fileprivate func clicked(_ t: OverviewTile, count: Int) {
        select(tiles.firstIndex { $0 === t })
        switch click.click(ObjectIdentifier(t.shot), count: count, at: CACurrentMediaTime(), interval: NSEvent.doubleClickInterval) {
        case .edit:
            emit(["event": "card_edit", "n": t.shot.n, "from": "overview"])
            NoteBubble.shared.begin(t.shot, mode: .edit)
            settled()
        case .copy(let at):
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, at - CACurrentMediaTime())) { [weak self, weak t] in
                guard let self = self else { return }
                defer { self.settled() }
                guard let t = t, self.click.fire(at: CACurrentMediaTime() + 0.01) == ObjectIdentifier(t.shot) else { return }
                self.copy(t, .click)
            }
        }
    }

    fileprivate func copy(_ t: OverviewTile, _ what: HangingCards.Copy) {
        let ok = HangingCards.copyShot(t.shot, what)
        emit(["event": "card_copied", "n": t.shot.n, "what": what.rawValue, "from": "overview", "ok": ok])
        if ok { t.flashCopied() }
    }

    fileprivate func menu(for t: OverviewTile) -> NSMenu {
        click.cancel()
        defer { settled() }
        select(tiles.firstIndex { $0 === t })
        return hanging.cardMenu(t.shot) { [weak self, weak t] what in if let t = t { self?.copy(t, what) } }
    }

    fileprivate func dragStarted() {
        click.cancel()
        dragging = true
    }

    fileprivate func dragEnded() {
        dragging = false
        settled()
    }

    private func key(_ e: NSEvent) -> Bool {
        let cols = CardsOverview.columns(tiles.count)
        let cmd = e.modifierFlags.contains(.command)
        let cur = selected
        switch Int(e.keyCode) {
        case 123: select((cur ?? 0) - 1)                       // ←
        case 124: select(cur.map { $0 + 1 } ?? 0)              // →
        case 126: select((cur ?? 0) - cols)                    // ↑
        case 125: select(cur.map { $0 + cols } ?? 0)           // ↓
        case 36, 76:                                           // ↩, enter: copied, and the keyboard back (⌘V)
            if let i = cur { copyAndClose(tiles[i]) }
        case 8 where cmd:                                      // ⌘C
            if let i = cur { copyAndClose(tiles[i]) }
        case 51, 117:                                          // ⌫, ⌦: Undo in the island
            if let i = cur { snapper.delete(tiles[i].shot) }
        case 53: hide()                                        // Esc
        case 13 where cmd: hide()                              // ⌘W
        default: return false
        }
        return true
    }

    /// ↩ / ⌘C: copied — and the overview closes, handing the keyboard back to the app the user was in, so the next ⌘V
    /// pastes the card there.
    private func copyAndClose(_ t: OverviewTile) {
        guard HangingCards.copyShot(t.shot, .click) else { return }
        emit(["event": "card_copied", "n": t.shot.n, "what": HangingCards.Copy.click.rawValue, "from": "overview", "ok": true])
        hide()
    }

    /// Tests: the tiles in order, and acting on tile N as a click / double-click / ⌫ would; `key K` = that key with the
    /// keyboard on the overview; `hover N` = as if the pointer rested on tile N (no N: none).
    func testCommand(_ arg: String) {
        let a = arg.split(separator: " ").map(String.init)
        let tile = { (i: Int) -> OverviewTile? in a.count > i ? Int(a[i]).flatMap { n in self.tiles.first { $0.shot.n == n } } : nil }
        switch a.first ?? "" {
        case "open": show(keyboard: a.count > 1 && a[1] == "keyboard")
        case "close": hide()
        case "click": if let t = tile(1) { clicked(t, count: 1) }
        case "double": if let t = tile(1) { clicked(t, count: 1); clicked(t, count: 2) }
        case "delete": if let t = tile(1) { snapper.delete(t.shot) }
        case "hover": for t in tiles { t.hovering = t === tile(1) }
        case "copied": tile(1)?.flashCopied()
        case "menu": if let t = tile(1) { emit(["event": "overview_menu", "items": menu(for: t).items.filter { !$0.isSeparatorItem }.map(\.title)]) }
        case "key":
            let codes = ["left": 123, "right": 124, "down": 125, "return": 36, "delete": 51, "esc": 53]
            if a.count > 1, let code = codes[a[1]],
               let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: window?.windowNumber ?? 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                                        isARepeat: false, keyCode: UInt16(code)) { _ = key(e) }
        default: break
        }
        emit(["event": "cards_overview", "open": isOpen, "order": tiles.map(\.shot.n), "selected": selected ?? -1,
              "title": window?.title ?? "", "key": hasKeyboard, "columns": CardsOverview.columns(tiles.count)])
    }
}

/// One card in the overview: its picture (or a voice note's words), what it is and when under it; pointed at, the
/// wash and its actions (Copy, "···").
final class OverviewTile: NSView, NSDraggingSource {
    let shot: Shot
    private weak var overview: CardsOverview?
    private let wash = CALayer()
    private let face = CALayer()
    private let ring = CALayer()
    /// "✓ Copied" over the tile for a moment: the ok check and the word on the dark done pill
    private let copiedPill = NSView(), copiedText = NSTextField(labelWithString: ""), copiedCheck = NSImageView()
    private let actions = NSStackView()
    private var copyRun: ClosureButton?
    private var downAt: NSPoint?
    private var cardDrag: CardDrag?

    /// the selected tile (a click, the arrows): the wash; with the keyboard on the panel, the accent ring too
    var selected = false { didSet { restate() } }
    var keyboard = false { didSet { restate() } }
    var hovering = false { didSet { restate() } }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var needsPanelToBecomeKey: Bool { true }

    init(_ s: Shot, overview: CardsOverview) {
        shot = s
        self.overview = overview
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        let sz = CardsOverview.tile
        wash.frame = CGRect(x: -6, y: -6, width: sz.width + 12, height: sz.height + CardsOverview.caption + 8)
        wash.cornerRadius = 10
        wash.isHidden = true
        layer?.addSublayer(wash)
        face.frame = CGRect(origin: .zero, size: sz)
        face.cornerRadius = 7
        face.masksToBounds = true
        face.borderWidth = 0.5
        face.contentsGravity = .resizeAspectFill
        layer?.addSublayer(face)
        if s.kind == .shot {
            // a toolbar or a sidebar is shown whole on the tile's surface, never as a slice of its middle (CardShape);
            // a picture that fills is cropped from its top-left corner, where a window's title is
            if let t = s.markedThumb ?? s.thumb {
                let px = CGSize(width: t.width, height: t.height)
                if CardShape.fills(picture: px, box: sz) {
                    face.contents = OverviewTile.topLeading(t, box: sz)
                    face.contentsGravity = .resize
                } else {
                    face.contents = t
                    face.contentsGravity = .resizeAspect
                }
            }
        } else {
            // a voice note is its words, on the card's own surface, with the small mic mark (colours: restyle())
            let words = NSTextField(wrappingLabelWithString: s.words ?? HangingCards.statusText(s.note.status) ?? "")
            words.font = .systemFont(ofSize: 11.5, weight: .medium)
            words.textColor = s.words != nil ? .labelColor : s.note.needsYou ? BrandColor.attnInk : .secondaryLabelColor
            words.maximumNumberOfLines = 4
            words.lineBreakMode = .byWordWrapping            // (truncating-tail made it one line: "Ship the beta o…")
            words.cell?.truncatesLastVisibleLine = true
            words.frame = NSRect(x: 9, y: 7, width: sz.width - 18, height: sz.height - 22)
            words.toolTip = s.words
            addSubview(words)
            let mic = NSImageView(image: BlurtIcon.mic.image(size: 10, color: BrandColor.ink))
            mic.frame = NSRect(x: sz.width - 18, y: sz.height - 17, width: 10, height: 10)
            addSubview(mic)
        }
        ring.frame = face.frame.insetBy(dx: -4, dy: -4)
        ring.cornerRadius = 11
        ring.borderWidth = 2.5
        ring.isHidden = true
        layer?.addSublayer(ring)
        // what it is (its note, else "Snap · 19:03"), then when — one line each, flush with the picture's edge
        let title = NSTextField(labelWithString: OverviewTile.line(s))
        title.font = .systemFont(ofSize: 12, weight: s.words != nil ? .medium : .regular)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingTail
        title.toolTip = s.words
        title.frame = NSRect(x: -2, y: sz.height + 6, width: sz.width + 4, height: 16)
        addSubview(title)
        let meta = NSTextField(labelWithAttributedString: OverviewTile.meta(s))
        meta.lineBreakMode = .byTruncatingTail
        meta.frame = NSRect(x: -2, y: sz.height + 22, width: sz.width + 4, height: 15)
        addSubview(meta)
        // the hovered tile's actions: Copy (the one primary) and "···", over the picture's bottom-right corner
        let run = ClosureButton("", { [weak self] in if let self { self.overview?.copy(self, .click) } })
        copyRun = run
        let b = BrandButton(title: Loc.t("capture.taken.copy", table: "Capture"), target: run, action: #selector(ClosureButton.fire))
        b.fontSize = 11.5
        b.hPad = 10
        b.radius = 6
        let moreTitle = Loc.t("capture.taken.more", table: "Capture")
        let mb = GlassButton(symbol: "ellipsis", label: moreTitle)
        mb.set { [weak self, weak mb] in
            guard let self, let mb, let m = self.overview?.menu(for: self) else { return }
            m.popUp(positioning: nil, at: NSPoint(x: 0, y: mb.bounds.height + 3), in: mb)
        }
        actions.addArrangedSubview(mb)
        actions.addArrangedSubview(b)
        actions.spacing = 6
        actions.alphaValue = 0
        actions.frame = NSRect(x: 0, y: 0, width: 10, height: 24)
        addSubview(actions)
        copiedText.font = .systemFont(ofSize: 11.5, weight: .semibold)
        copiedText.textColor = .white
        copiedText.stringValue = Loc.t("capture.card.copied", table: "Capture")
        copiedText.sizeToFit()
        copiedCheck.image = BlurtIcon.check.image(size: 11, color: BrandColor.Island.ok)
        copiedPill.addSubview(copiedCheck)
        copiedPill.addSubview(copiedText)
        copiedPill.wantsLayer = true
        copiedPill.layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.88).cgColor
        copiedPill.layer?.cornerRadius = 11
        copiedPill.isHidden = true
        addSubview(copiedPill)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(HangingCards.cardLabel(s))
        setAccessibilityRoleDescription(Loc.t(s.kind == .voice ? "capture.card.ax_voice" : "capture.card.ax_shot", table: "Capture"))
        setAccessibilityHelp(Loc.t("capture.card.ax_help", table: "Capture"))
        setAccessibilityCustomActions(HangingCards.axActions(s))
        restyle()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let sz = CardsOverview.tile, fit = actions.fittingSize
        actions.frame = NSRect(x: sz.width - fit.width - 6, y: sz.height - fit.height - 6, width: fit.width, height: fit.height)
    }

    /// The picture cropped to the tile's shape from its top-left corner (a window's title and tabs stay in view).
    static func topLeading(_ img: CGImage, box: CGSize) -> CGImage {
        let iw = CGFloat(img.width), ih = CGFloat(img.height)
        let scale = max(box.width / iw, box.height / ih)
        let r = CGRect(x: 0, y: 0, width: min(iw, (box.width / scale).rounded()), height: min(ih, (box.height / scale).rounded()))
        return img.cropping(to: r) ?? img
    }

    /// The layers' colours in this view's appearance. A CGColor is resolved once, in whatever appearance is current
    /// when it is read: built outside drawing, the voice tile kept the light surface under dark-mode (white) words.
    private func restyle() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        effectiveAppearance.performAsCurrentDrawingAppearance {
            face.borderColor = HangingCards.hairline(dark: dark).cgColor
            face.backgroundColor = (shot.kind == .shot ? HangingCards.surface(dark: dark) : NSColor.controlBackgroundColor).cgColor
            ring.borderColor = BrandColor.accent.cgColor
            wash.backgroundColor = BrandColor.tint.cgColor
        }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); restyle() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); restyle() }

    private func restate() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        wash.isHidden = !(hovering || selected)
        ring.isHidden = !(selected && keyboard)
        CATransaction.commit()
        NSAnimationContext.runAnimationGroup { c in
            c.duration = 0.12
            actions.animator().alphaValue = hovering ? 1 : 0
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func accessibilityPerformPress() -> Bool { overview?.copy(self, .click); return true }

    /// What it is: its note (one line); a snap without one, "Snap · 19:03" (as its card's name); a voice note "Voice
    /// note · 19:03" (its words are on the tile already).
    static func line(_ s: Shot) -> String {
        if s.kind == .shot, let w = s.words { return w.replacingOccurrences(of: "\n", with: " · ") }
        return s.plainName
    }

    /// When, quietly: "5 min ago"; a snap whose note couldn't be transcribed says so instead, in attention ink.
    static func meta(_ s: Shot) -> NSAttributedString {
        let f = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        if s.kind == .shot, s.note.needsYou, let st = HangingCards.statusText(s.note.status) {
            return NSAttributedString(string: st, attributes: [.font: f, .foregroundColor: BrandColor.attnInk])
        }
        let ago = RelativeDateTimeFormatter()
        ago.locale = Loc.locale
        ago.unitsStyle = .full
        let now = Date(timeIntervalSince1970: Snapper.now)
        let when = Date(timeIntervalSince1970: min(s.wall, Snapper.now))
        var text = now.timeIntervalSince(when) < 60 ? Loc.t("time.just_now") : ago.localizedString(for: when, relativeTo: now)
        text = text.prefix(1).uppercased() + text.dropFirst()
        return NSAttributedString(string: text, attributes: [.font: f, .foregroundColor: NSColor.secondaryLabelColor])
    }

    /// "✓ Copied" over the tile for a moment: the done pill (the ok check), as on a card on its thread.
    func flashCopied() {
        let tw = ceil(copiedText.frame.width)
        let w = 12 + 11 + 4 + tw + 12
        copiedPill.frame = NSRect(x: (CardsOverview.tile.width - w) / 2, y: (CardsOverview.tile.height - 22) / 2, width: w, height: 22)
        copiedCheck.frame = NSRect(x: 12, y: 5.5, width: 11, height: 11)
        copiedText.frame = NSRect(x: 12 + 11 + 4 - 2, y: (22 - copiedText.frame.height) / 2, width: tw, height: copiedText.frame.height)
        copiedPill.isHidden = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.copiedPill.isHidden = true }
    }

    override func mouseDown(with e: NSEvent) { downAt = e.locationInWindow }

    override func mouseUp(with e: NSEvent) {
        defer { downAt = nil }
        guard downAt != nil, bounds.contains(convert(e.locationInWindow, from: nil)) else { return }
        overview?.clicked(self, count: e.clickCount)
    }

    override func rightMouseDown(with e: NSEvent) {
        guard let m = overview?.menu(for: self) else { return }
        m.popUp(positioning: nil, at: convert(e.locationInWindow, from: nil), in: self)
    }

    override func mouseDragged(with e: NSEvent) {
        guard let d = downAt, hypot(e.locationInWindow.x - d.x, e.locationInWindow.y - d.y) > 4 else { return }
        downAt = nil
        if shot.kind == .voice, shot.copyText == nil { snapper.wantWords(shot); return }     // its words aren't here yet
        overview?.dragStarted()
        let drag = CardDrag(shot)            // its items follow the app under the pointer
        cardDrag = drag
        let img = NSImage(size: CardsOverview.tile)
        if let cg = shot.kind == .shot ? shot.markedThumb ?? shot.thumb : nil {
            img.addRepresentation(NSBitmapImageRep(cgImage: cg))
        } else if let rep = bitmapImageRepForCachingDisplay(in: NSRect(origin: .zero, size: CardsOverview.tile)) {
            cacheDisplay(in: NSRect(origin: .zero, size: CardsOverview.tile), to: rep)
            img.addRepresentation(rep)
        }
        let frame = NSRect(origin: .zero, size: CardsOverview.tile)
        let items = drag.pasteboardItems().enumerated().map { i, it -> NSDraggingItem in
            let di = NSDraggingItem(pasteboardWriter: it)
            di.setDraggingFrame(i == 0 ? frame : NSRect(x: frame.midX, y: frame.midY, width: 1, height: 1), contents: i == 0 ? img : nil)
            return di
        }
        emit(["event": "overview_drag", "n": shot.n, "items": items.count])
        drag.setBase(image: img, frame: frame, in: self)
        island.dragBegan()                  // a project in the island can take it, as from the row
        let session = beginDraggingSession(with: items, event: e, source: self)
        session.draggingFormation = .none
        session.animatesToStartingPositionsOnCancelOrFail = true
        drag.session = session
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .generic] : [.generic, .move]
    }

    func draggingSession(_ session: NSDraggingSession, movedTo p: NSPoint) {
        cardDrag?.moved(to: p)
        island.dragMoved(to: p)
    }

    func draggingSession(_ session: NSDraggingSession, endedAt p: NSPoint, operation: NSDragOperation) {
        let drag = cardDrag
        cardDrag = nil
        let overview = self.overview
        defer { overview?.dragEnded() }        // (the grid follows the cards again once this tile is done with)
        let filed = island.dragEnded(at: p)
        emit(["event": "overview_drag_end", "n": shot.n, "operation": Int(operation.rawValue), "filed": filed])
        guard !filed, !OverviewTile.ourWindow(at: p) else { return }
        // a voice note over a chat app's window: its words go into that composer, wherever it was let go of
        if let t = drag?.voiceTarget(at: p) {
            snapper.takeOutVoice(shot, landed: t, at: p, accepted: !operation.isEmpty, wordsWithheld: drag?.wordsWithheld(at: t) ?? false)
            return
        }
        // taken by another app: off its thread, like a card dragged from the row ("Dragged out · Undo")
        if !operation.isEmpty {
            let got = drag?.delivered(at: p)
            snapper.takeOut(shot, delivered: got, noteFile: got.map { drag?.noteFile($0) ?? false } ?? false,
                            landed: DropProbe.target(at: p), at: p)
        }
    }

    /// The window under a screen point is one of ours (the overview itself, the main window, a note): not "used in
    /// another app".
    static func ourWindow(at p: NSPoint) -> Bool {
        let n = NSWindow.windowNumber(at: p, belowWindowWithWindowNumber: 0)
        return n > 0 && NSApp.windows.contains { $0.windowNumber == n && !($0 is CardsPanel) }   // (the cards take no drops)
    }
}

/// A quiet round "···" over a picture: a small disc of the window's surface with a hairline, so it reads on any
/// picture (the overview's tiles).
final class GlassButton: ClosureButton {
    convenience init(symbol: String, label: String) {
        self.init("", {})
        image = Look.symbol(symbol, label, size: 11, weight: .semibold)
        imagePosition = .imageOnly
        isBordered = false
        contentTintColor = .secondaryLabelColor
        toolTip = label
        setAccessibilityLabel(label)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 0.5
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 24).isActive = true
        heightAnchor.constraint(equalToConstant: 24).isActive = true
    }
    override func updateLayer() {
        super.updateLayer()
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.94).cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
    }
    override var wantsUpdateLayer: Bool { true }
}
