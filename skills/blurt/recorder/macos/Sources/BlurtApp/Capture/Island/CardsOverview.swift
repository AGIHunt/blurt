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
// The look (v0.9.2, the same family as Recently Dragged Out, docs/design/system.md §3.2; the parts in CardChrome.swift):
// one header row — "Cards  7" left-aligned, "···" (what concerns every card: Copy All, Organize All, Delete All) and a
// real × on the right, no traffic light. A grid with no orphan (CardGrid: 7 = 4 + 3), 148 × 100 tiles cropped from
// their top-left on the card's opaque surface. Under a tile: its note in 13 pt medium, up to two lines of whole words
// (a third fades out — never an "…"), then the time it was taken in 11 pt tertiary ("18:27"); a snap without a note
// only the time (the picture says what it is). The tile under the pointer — or the keyboard's — gets a neutral wash
// and the card's actions in its top-right corner ([···][Copy], CardActions, the same cluster as a Recently Dragged
// Out row); the keyboard's also the accent ring. The footer: that tile's whole note (nothing needs an ellipsis to be
// read) or how to use a tile, and the keys as keycaps (KeyHint) while the panel has the keyboard.

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
    static let gap: CGFloat = 14
    static let pad: CGFloat = 16
    static let footerH: CGFloat = 50

    /// Columns for `n` cards (BlurtCore CardGrid): one row up to 4, then half a row each (7 = 4 + 3), at most 4.
    static func columns(_ n: Int) -> Int { CardGrid.columns(n) }

    private var window: OverviewPanel?
    private let grid = FlippedView()
    private let scroll = NSScrollView()
    private var header: PanelHeader?
    private let more = ClosureButton("", {})
    private let rule = NSBox()
    /// the footer: the pointed-at (or keyboard's) tile's whole note, else how to use a tile; the keys on the right
    private let hint = NSTextField(wrappingLabelWithString: "")
    private let keys = KeyHintView()
    private var hovered: OverviewTile?
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
        // no traffic lights: the header row has its own title, "···" and a real × (CardChrome.PanelHeader) — a lone grey
        // close button read as an inactive window
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.backgroundColor = BubbleBackground.surface        // the bubble's neutral grey, not the wallpaper-tinted default
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { w.standardWindowButton(b)?.isHidden = true }
        let root = NSView()
        let moreTitle = Loc.t("capture.taken.more", table: "Capture")
        more.image = Look.symbol("ellipsis", moreTitle, size: 13, weight: .medium)
        more.imagePosition = .imageOnly
        more.isBordered = false
        more.contentTintColor = .secondaryLabelColor
        more.toolTip = moreTitle
        more.setAccessibilityLabel(moreTitle)
        more.set { [weak self] in self?.popAllMenu() }
        more.translatesAutoresizingMaskIntoConstraints = false
        more.widthAnchor.constraint(equalToConstant: 24).isActive = true
        more.heightAnchor.constraint(equalToConstant: 22).isActive = true
        let head = PanelHeader(title: Loc.t("capture.cards.overview_heading", table: "Capture"), accessory: more) { [weak self] in self?.hide() }
        header = head
        titleBar = PanelHeader.height
        scroll.documentView = grid
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        rule.boxType = .separator
        rule.translatesAutoresizingMaskIntoConstraints = false
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .secondaryLabelColor
        hint.maximumNumberOfLines = 2
        hint.lineBreakMode = .byWordWrapping
        hint.translatesAutoresizingMaskIntoConstraints = false
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        keys.translatesAutoresizingMaskIntoConstraints = false
        keys.setContentHuggingPriority(.required, for: .horizontal)
        keys.setContentCompressionResistancePriority(.required, for: .horizontal)
        for v in [head, scroll, rule, hint, keys] as [NSView] { root.addSubview(v) }
        NSLayoutConstraint.activate([
            head.topAnchor.constraint(equalTo: root.topAnchor),
            head.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            head.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: root.topAnchor, constant: titleBar),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: rule.topAnchor),
            rule.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: CardsOverview.pad),
            rule.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -CardsOverview.pad),
            rule.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -CardsOverview.footerH),
            hint.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: CardsOverview.pad),
            hint.trailingAnchor.constraint(lessThanOrEqualTo: keys.leadingAnchor, constant: -16),
            hint.centerYAnchor.constraint(equalTo: root.bottomAnchor, constant: -CardsOverview.footerH / 2),
            keys.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -CardsOverview.pad),
            keys.centerYAnchor.constraint(equalTo: hint.centerYAnchor),
            keys.heightAnchor.constraint(equalToConstant: KeyHint.capH),
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
        // each row as tall as its tallest caption (a row of bare pictures doesn't keep two empty lines under them)
        let rows = max(1, (tiles.count + cols - 1) / cols)
        let rowH = (0..<rows).map { r in sz.height + (tiles[min(tiles.count, r * cols)..<min(tiles.count, (r + 1) * cols)].map(\.captionHeight).max() ?? 6) }
        var y = pad
        for r in 0..<rows {
            for (k, t) in tiles[min(tiles.count, r * cols)..<min(tiles.count, (r + 1) * cols)].enumerated() {
                t.frame = NSRect(x: pad + CGFloat(k) * (sz.width + g), y: y, width: sz.width, height: rowH[r])
                grid.addSubview(t)
            }
            y += rowH[r] + g
        }
        let width = pad * 2 + CGFloat(cols) * sz.width + CGFloat(cols - 1) * g
        let full = pad * 2 + rowH.reduce(0, +) + CGFloat(rows - 1) * g
        grid.frame = NSRect(x: 0, y: 0, width: width, height: full)
        let shown = pad * 2 + rowH.prefix(3).reduce(0, +) + CGFloat(min(rows, 3) - 1) * g
        // the header and the footer's keys need room too: never narrower than 360
        let contentW = max(360, width), contentH = titleBar + shown + 1 + CardsOverview.footerH
        var f = w.frame
        let dh = contentH - f.height
        f.size.width = contentW
        f.size.height = contentH
        f.origin.y -= dh
        w.setFrame(f, display: true)
        grid.frame.origin.x = (contentW - width) / 2
        header?.count.stringValue = Loc.number(tiles.count)
        w.title = Loc.plural("capture.cards.overview_title", table: "Capture", count: tiles.count)
        w.setAccessibilityLabel(w.title)
        selected = was.flatMap { s in tiles.firstIndex { $0.shot === s } } ?? selected.map { min($0, tiles.count - 1) }
        if tiles.isEmpty { selected = nil }
        for (i, t) in tiles.enumerated() { t.selected = i == selected; t.keyboard = hasKeyboard }
        updateHint()
    }

    /// The footer: the pointed-at tile's — else the keyboard's — whole note (or its name), else how to use a tile; the
    /// keys as keycaps on the right while the panel has the keyboard (the same KeyHint as the row's hover note).
    private func updateHint() {
        for t in tiles { t.keyboard = hasKeyboard }
        keys.items = hasKeyboard ? KeyHint.cards : []
        keys.isHidden = !hasKeyboard
        let focus = hovered ?? selected.flatMap { $0 < tiles.count ? tiles[$0] : nil }
        if let t = focus {
            hint.attributedStringValue = OverviewTile.footerLine(t.shot)
        } else {
            hint.stringValue = Loc.t("capture.cards.overview_hint", table: "Capture")
            hint.textColor = .secondaryLabelColor
        }
    }

    /// A tile is pointed at (nil: none): the footer says what it is.
    fileprivate func pointed(_ t: OverviewTile, _ on: Bool) {
        if on { hovered = t } else if hovered === t { hovered = nil }
        updateHint()
    }

    // MARK: actions

    fileprivate func select(_ i: Int?) {
        selected = i.map { min(max($0, 0), tiles.count - 1) }
        for (k, t) in tiles.enumerated() { t.selected = k == selected }
        updateHint()
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
        case "hover": for t in tiles { t.hovering = t === tile(1) }; hovered = tiles.first { $0.hovering }; updateHint()
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
    private var actions: CardActions!
    private let title = NSTextField(wrappingLabelWithString: "")
    /// how much room its caption takes under the picture (the grid gives a row its tallest)
    private(set) var captionHeight: CGFloat = 6
    private var downAt: NSPoint?
    private var cardDrag: CardDrag?

    /// the selected tile (a click, the arrows): the wash; with the keyboard on the panel, the accent ring and its actions too
    var selected = false { didSet { restate() } }
    var keyboard = false { didSet { restate() } }
    var hovering = false { didSet { if hovering != oldValue { restate(); overview?.pointed(self, hovering) } } }

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
        wash.frame = CGRect(x: -6, y: -6, width: sz.width + 12, height: sz.height + 12)
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
        ring.borderWidth = 2
        ring.isHidden = true
        layer?.addSublayer(ring)
        // its note: up to two lines of whole words (13 pt medium) — when there is more, the second line's last word fades
        // out (never an "…"; the footer has every word). No time under every tile (seven "19:05"s said nothing): the
        // footer says when, for the tile pointed at. A note that couldn't be transcribed says so, in attention ink.
        let f = NSFont.systemFont(ofSize: 13, weight: .medium)
        let tw = sz.width + 2, textW = tw - 4
        let lineH = ceil(NSLayoutManager().defaultLineHeight(for: f))
        var lines: CGFloat = 0
        if let note = OverviewTile.note(s) {
            let band = CardBand.clamp(note) { OverviewTile.lineWidths($0, font: f, width: textW).count <= 2 }
            let widths = OverviewTile.lineWidths(band.text, font: f, width: textW)
            lines = CGFloat(max(1, widths.count))
            title.stringValue = band.text
            title.toolTip = band.clipped ? note : nil
            title.font = f
            title.textColor = .labelColor
            title.maximumNumberOfLines = 2
            title.lineBreakMode = .byWordWrapping
            title.frame = NSRect(x: -2, y: sz.height + 8, width: tw, height: lines * lineH + 2)
            if band.clipped, let last = widths.last {
                title.wantsLayer = true
                let m = CALayer()
                let solid = CALayer()
                solid.backgroundColor = NSColor.black.cgColor
                solid.frame = CGRect(x: 0, y: 0, width: tw, height: (lines - 1) * lineH + 1)
                let fade = CAGradientLayer()
                fade.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
                fade.startPoint = CGPoint(x: 0, y: 0.5)
                fade.endPoint = CGPoint(x: 1, y: 0.5)
                let end = min(tw, last + 3)
                fade.locations = [0, NSNumber(value: Double(max(0, end - 30) / tw)), NSNumber(value: Double(end / tw))]
                fade.frame = CGRect(x: 0, y: (lines - 1) * lineH + 1, width: tw, height: lineH + 1)
                m.addSublayer(solid)
                m.addSublayer(fade)
                m.frame = CGRect(x: 0, y: 0, width: tw, height: lines * lineH + 2)
                title.layer?.mask = m
            }
            addSubview(title)
        }
        if s.kind == .shot, s.note.needsYou, let st = HangingCards.statusText(s.note.status) {
            let status = NSTextField(labelWithString: st)
            status.font = .systemFont(ofSize: 11)
            status.textColor = BrandColor.attnInk
            status.frame = NSRect(x: -2, y: sz.height + 8 + lines * lineH + (lines > 0 ? 3 : 0), width: sz.width + 4, height: 15)
            addSubview(status)
            lines += 1
        }
        captionHeight = lines == 0 ? 6 : 8 + lines * lineH + 6
        // the card's actions, in the picture's top-right corner: [···][Copy] — the same cluster as a Recently Dragged
        // Out row; shown on hover and on the keyboard's tile
        actions = CardActions(menu: { [weak self] in self.flatMap { $0.overview?.menu(for: $0) } },
                              copy: { [weak self] in if let self { self.overview?.copy(self, .click) } })
        actions.alphaValue = 0
        actions.translatesAutoresizingMaskIntoConstraints = true
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
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        wash.frame = CGRect(x: -6, y: -6, width: bounds.width + 12, height: bounds.height + 6)
        CATransaction.commit()
        let sz = CardsOverview.tile, fit = actions.fittingSize
        actions.frame = NSRect(x: sz.width - fit.width - 6, y: 6, width: fit.width, height: fit.height)
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
            // a neutral wash (no brand tint behind every pointed-at tile)
            wash.backgroundColor = NSColor(white: dark ? 1 : 0, alpha: dark ? 0.08 : 0.05).cgColor
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
        // the actions: under the pointer, and on the keyboard's tile (as a focused Recently Dragged Out row)
        let show = hovering || (selected && keyboard)
        NSAnimationContext.runAnimationGroup { c in
            c.duration = 0.12
            actions.animator().alphaValue = show ? 1 : 0
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

    /// A snap's note (its line breaks as spaces); nil for a snap without one and for a voice note (its words are on
    /// the tile already).
    static func note(_ s: Shot) -> String? {
        guard s.kind == .shot, let w = s.words, !w.isEmpty else { return nil }
        return w.replacingOccurrences(of: "\n", with: " ")
    }


    /// The widths of the lines `text` wraps into at `width` (the tile's caption).
    static func lineWidths(_ text: String, font: NSFont, width: CGFloat) -> [CGFloat] {
        let storage = NSTextStorage(string: text, attributes: [.font: font])
        let lm = NSLayoutManager()
        let tc = NSTextContainer(size: NSSize(width: width, height: 10_000))
        tc.lineFragmentPadding = 2
        lm.addTextContainer(tc)
        storage.addLayoutManager(lm)
        var out: [CGFloat] = []
        lm.enumerateLineFragments(forGlyphRange: lm.glyphRange(for: tc)) { _, used, _, _, _ in out.append(ceil(used.maxX)) }
        return out
    }

    /// The footer's line for the tile pointed at: its whole note in ink and, quieter, when it was taken ("19:05"); a
    /// snap without a note its name ("Snap · 19:05").
    static func footerLine(_ s: Shot) -> NSAttributedString {
        let f = NSFont.systemFont(ofSize: 12)
        guard let w = s.words?.replacingOccurrences(of: "\n", with: " "), !w.isEmpty else {
            return NSAttributedString(string: s.plainName, attributes: [.font: f, .foregroundColor: NSColor.labelColor])
        }
        let out = NSMutableAttributedString(string: w, attributes: [.font: f, .foregroundColor: NSColor.labelColor])
        out.append(NSAttributedString(string: "  " + s.takenAt, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                                                                             .foregroundColor: NSColor.tertiaryLabelColor]))
        return out
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
