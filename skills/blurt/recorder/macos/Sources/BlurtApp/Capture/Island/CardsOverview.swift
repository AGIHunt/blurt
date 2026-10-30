// The Cards panel (v0.9; one panel for every set of cards since v1.0.7, BA-62/63): "Cards" with two segments —
// **Current N**, the cards under the notch, and **History N**, the ones dragged out or pasted into another app in the
// last 7 days (Recently Taken in the code: TakenPanel.swift, Snapper.recentlyTaken; `CardsSegment.hanging / .used`).
// The same grid, tile, actions and preview for both; only the source and what makes sense for it differ. Two looks
// for "a set of cards" (the old "Recently Dragged Out" panel's 56 × 40 rows beside this grid) read as two things, and
// its thumbnails were too small to tell apart; that panel and its own ways in (the island's menu, the menu bar, the
// main window's sidebar row) are gone.
//
// Ways in: ⌥H ("Show Cards", also the menu bar's row) opens it with the keyboard — on Current, or on History when
// nothing hangs — and closes it when it is open (BlurtCore CardsPanelRules.toggle); the island's cards row and the row's
// "+N" tile (a click, ↩ on it with the keyboard, its VoiceOver press) open Current. It stays a panel by the notch,
// never a page in the main window: cards are used while working in another app (dragged into WeChat, a browser, an
// editor), so it floats over that app and never makes the user switch to Blurt. It never activates Blurt and takes
// the keyboard only from ⌥H or a click on it.
//
// A light panel (BA-63): a click anywhere outside it — another app, the desktop, Blurt's own main window — closes it;
// so does Esc while it has the keyboard, while Blurt is the app in front, or while the pointer is on it (Esc is held
// as a hotkey only then: an Esc meant for the app in front, stopping an agent in a terminal, is never swallowed).
// Clicks on the notch's own things (the island, the hanging cards, a note bubble) leave it open.
//
// What a tile does, in both segments:
//   click = copy (once the double-click interval has passed) · double-click = edit the note (Current) / the big
//   preview (History) · right-click or "···" = the card's menu (Preview first; Current: HangingCards.cardMenu — Copy
//   Image / Text, Copy All, Edit Note…, Move To ▸, Organize, Delete; History: Copy Image · Copy Note · Put Back Under
//   the Notch · Show in Finder · Delete) · the eye chip or Space = the big preview (CardPreview.swift) · drag = out into
//   any app again (the same items as a card's drag, CardDrag; a voice card over a chat app pastes its words), a
//   current one also onto a project in the island · with the keyboard (BlurtCore CardsPanelRules.action, the one key map):
//   Tab — or ← / → while no card is focused — switches the segment, ↓ goes into the grid and the arrows move in it
//   (↑ from the top row back out), Space previews, ↩ / ⌘C copies and closes (the keyboard back where the user was, so
//   ⌘V pastes), ⌫ deletes (Undo in the island), Esc or ⌥H closes.
//
// Where: under the strip the cards hang in (HangingCards.panelTop, whether they are down or not, so cards that come
// down again never cover its title); it follows them down as they change (Put Back hangs a card above it) — never in
// the middle of a drag out of it or a click's pending copy: that waits until they are done. It closes itself when
// both segments are empty; one empty segment is the app's one empty state.
//
// The look (v0.9.2, docs/design/system.md §3.2; the parts in CardChrome.swift): one header row — "Cards", then the
// Current | History segments (a native segmented control with a neutral selected segment, every segment one width),
// "···" (Current: Copy All, Organize All, Delete All) and a real × on the right, no traffic light. A grid with no
// orphan (CardGrid: 7 = 4 + 3), 148 × 100 tiles cropped from their top-left on the card's opaque surface; at most
// three rows, then it scrolls. The panel is as wide as the wider of the two segments' grids, so switching never
// changes its shape. Under a tile: its note in 13 pt medium, up to two lines of whole words (never an "…"); a used
// card on its last day says so in attention ink. The tile under the pointer — or the keyboard's — gets a neutral wash
// and the actions in its top-right corner ([eye][···][Copy], CardActions); the keyboard's also the accent ring. The
// footer: that tile's whole note with when (Current: the time it was taken; History: "Used 4 min ago"), or how to use
// a tile, and the keys as keycaps (KeyHint) while the panel has the keyboard.

import AppKit
import BlurtCore
import Carbon.HIToolbox
import SwiftUI

final class OverviewPanel: NSPanel {
    var onKey: ((NSEvent) -> Bool)?
    override var canBecomeKey: Bool { true }
    override func sendEvent(_ e: NSEvent) {
        if e.type == .keyDown, onKey?(e) == true { return }
        super.sendEvent(e)
    }
}

/// A panel's content view that says when the pointer is on it (Esc closes the panel only then, unless it has the keys).
final class PointerView: NSView {
    var onPointer: ((Bool) -> Void)?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { onPointer?(true) }
    override func mouseExited(with event: NSEvent) { onPointer?(false) }
}

final class CardsOverview: NSObject, NSWindowDelegate {
    static let shared = CardsOverview()
    static let tile = CGSize(width: 148, height: 100)
    static let gap: CGFloat = 14
    static let pad: CGFloat = 16
    static let footerH: CGFloat = 50
    /// The empty state (the mark, the title, one line of hint and the padding round them).
    static let emptyH: CGFloat = 200
    /// Never narrower: the header's segments and the footer's keys need the room.
    static let minWidth: CGFloat = 440

    /// Columns for `n` cards (BlurtCore CardGrid): one row up to 4, then half a row each (7 = 4 + 3), at most 4.
    static func columns(_ n: Int) -> Int { CardGrid.columns(n) }
    /// A grid of `cols` tiles, edge to edge with its padding.
    static func gridWidth(_ cols: Int) -> CGFloat { pad * 2 + CGFloat(cols) * tile.width + CGFloat(max(0, cols - 1)) * gap }

    private var window: OverviewPanel?
    private let grid = FlippedView()
    private let scroll = NSScrollView()
    private var header: PanelHeader?
    private let segments = NSSegmentedControl(labels: ["", ""], trackingMode: .selectOne, target: nil, action: nil)
    private let more = ClosureButton("", {})
    private let rule = NSBox()
    /// the footer: the pointed-at (or keyboard's) tile's whole note, else how to use a tile; the keys on the right
    private let hint = NSTextField(wrappingLabelWithString: "")
    private let keys = KeyHintView()
    private let empty = NSHostingView(rootView: EmptyStateContent(title: "", message: ""))
    private var hovered: OverviewTile?
    private(set) var tiles: [OverviewTile] = []
    private var selected: Int?
    private var click = DeferredClick<ObjectIdentifier>()
    private var titleBar: CGFloat = PanelHeader.height
    /// The big view of one card (Space, the eye chip, a used card's double-click).
    let preview = CardPreview()

    /// The segment showing.
    private(set) var segment: CardsSegment = .hanging
    var isOpen: Bool { window?.isVisible ?? false }
    /// It has the keyboard (the cards' Esc hotkey stays out of its way).
    var hasKeyboard: Bool { window?.isKeyWindow == true || preview.hasKeyboard || keyboardShown }
    /// Tests: opened "with the keyboard" without taking it from the app in front — drawn as if it had it.
    private var keyboardShown = false
    /// Opened with the keyboard (↩ on the "+N" tile): closing it hands the keyboard back to the app the user was in.
    private var restoreFocusOnHide = false
    /// A tile is being dragged out, or a click's copy is pending: the grid is not rebuilt under it until it is done.
    private var dragging = false
    private var reloadLater = false
    /// Tests: "with the keyboard" selects the first tile but never takes the keyboard from the app in front.
    var testKeyless = false
    /// The outside-click and Esc watchers while it is open; Esc as a hotkey while the pointer is on it.
    private var monitors: [Any] = []
    private var pointerOnPanel = false, pointerOnPreview = false
    private var escHeld = false

    private var hangingShots: [Shot] { snapper.cards.reversed() }     // newest first, the order they hang in
    private var usedShots: [Shot] { snapper.recentlyTaken }             // the last one used first

    /// ⌥H: opens with the keyboard on Hanging (on Used when nothing hangs), or closes it when it is open; nothing in
    /// either: the island says so.
    func toggle(via: String) {
        switch CardsPanelRules.toggle(isOpen: isOpen, hanging: snapper.cards.count, used: usedShots.count) {
        case .close: hide()
        case .open(let seg): show(keyboard: true, segment: seg, focusFirst: false)
        case .nothing: island.toast(Loc.t("capture.cards.none", table: "Capture"), actionTitle: nil, action: nil)
        }
        emit(["event": "cards_overview_toggle", "via": via, "open": isOpen, "segment": segment.rawValue])
    }

    /// Opens under the cards on `segment` (`keyboard`: with the keyboard on it — ⌥H, ↩ on the "+N" tile; `focusFirst`:
    /// on the newest card, else on no card, where ← / → switch the segment). Already open: it switches to that segment
    /// where it is.
    func show(keyboard: Bool = false, segment seg: CardsSegment = .hanging, focusFirst: Bool = true) {
        if window == nil { build() }
        guard let w = window else { return }
        let wasOpen = w.isVisible
        if seg != segment { selected = nil; preview.close() }
        segment = seg
        keyboardShown = keyboard && testKeyless
        rebuild()
        if !wasOpen {
            let size = w.frame.size
            let anchor = island.frameOnScreen
            let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main ?? NSScreen.screens[0]
            let top = min(hanging.panelTop, anchor.minY - 12, screen.visibleFrame.maxY)
            var x = anchor.midX - size.width / 2
            x = min(max(x, screen.visibleFrame.minX + 12), screen.visibleFrame.maxX - size.width - 12)
            w.setFrameOrigin(NSPoint(x: x, y: max(screen.visibleFrame.minY + 12, top - size.height)))
        }
        w.orderFrontRegardless()
        watch(true)
        if keyboard {
            if !testKeyless {
                snapper.rememberFrontApp()
                restoreFocusOnHide = true
                w.makeKey()
            }
            if focusFirst, !tiles.isEmpty { select(0) } else { select(nil) }
        }
        updateHint()
        emit(["event": "cards_overview_open", "count": tiles.count, "order": tiles.map(\.shot.n), "segment": seg.rawValue,
              "hanging": snapper.cards.count, "used": usedShots.count])
        if seg == .used { emit(["event": "taken_panel", "open": true, "count": tiles.count, "below_cards": hanging.count > 0]) }
    }

    func hide() {
        preview.close()
        guard let w = window, w.isVisible else { return }
        let wasKey = w.isKeyWindow
        keyboardShown = false
        selected = nil
        watch(false)
        w.orderOut(nil)
        if wasKey && restoreFocusOnHide { snapper.restoreFocus() }
        restoreFocusOnHide = false
        emit(["event": "cards_overview_open", "open": false, "segment": segment.rawValue])
        if segment == .used { emit(["event": "taken_panel", "open": false]) }
    }

    /// Esc (its own key, Blurt's main window in front, or the hotkey while the pointer is on it): the preview first,
    /// then the panel.
    func escape() {
        if preview.isOpen { return closePreview() }
        hide()
    }

    /// The cards changed (one copied out, filed, deleted, used, put back, a new one caught): the grid again, if it is
    /// open. Both segments empty: it closes.
    func reload() {
        guard isOpen else { return }
        if dragging || click.pending != nil { reloadLater = true; return }
        reloadLater = false
        if snapper.cards.isEmpty && usedShots.isEmpty { return hide() }
        rebuild()
        if let s = preview.shot, !tiles.contains(where: { $0.shot === s }) { preview.close() }
    }

    /// A card was put back from Used: the panel moves down out of the cards' strip (when it isn't there already) —
    /// right away, while the card is still on its way (it counts as hanging only once it has landed).
    func makeRoomForCards() {
        guard isOpen, let w = window else { return }
        follow(cardsHang: true)
        emit(["event": "taken_panel_moved", "frame": [w.frame.minX, w.frame.minY, w.frame.width, w.frame.height]])
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
        let w = OverviewPanel(contentRect: NSRect(x: 0, y: 0, width: CardsOverview.minWidth, height: 200),
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
        // no traffic lights: the header row has its own title, segments, "···" and a real × (CardChrome.PanelHeader) —
        // a lone grey close button read as an inactive window
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.backgroundColor = BubbleBackground.surface        // the bubble's neutral grey, not the wallpaper-tinted default
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { w.standardWindowButton(b)?.isHidden = true }
        let root = PointerView()
        root.onPointer = { [weak self] on in self?.pointerOnPanel = on; self?.pointerMoved() }
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
        // Hanging | Used: a native segmented control, the selected segment neutral (a view is where you are, never a
        // brand fill), every segment one width so it keeps its shape as the counts change
        segments.target = self
        segments.action = #selector(segmentPicked)
        segments.controlSize = .regular
        segments.font = .systemFont(ofSize: 12)
        segments.selectedSegmentBezelColor = NeutralSegments<Int>.selectedFill
        segments.setAccessibilityLabel(Loc.t("capture.cards.segments_ax", table: "Capture"))
        segments.setContentHuggingPriority(.required, for: .horizontal)
        segments.setContentCompressionResistancePriority(.required, for: .horizontal)
        let head = PanelHeader(title: Loc.t("capture.cards.overview_heading", table: "Capture"), lead: segments, accessory: more) { [weak self] in
            self?.hide()
        }
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
        // an empty segment: the one empty state of the app (the mark, a neutral title, the hint) — no footer under it
        empty.translatesAutoresizingMaskIntoConstraints = false
        empty.sizingOptions = []            // the panel sizes the empty state (emptyH), not the other way round
        for v in [head, scroll, rule, hint, keys, empty] as [NSView] { root.addSubview(v) }
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
            hint.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -CardsOverview.pad),
            hint.centerYAnchor.constraint(equalTo: root.bottomAnchor, constant: -CardsOverview.footerH / 2),
            keys.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -CardsOverview.pad),
            keys.centerYAnchor.constraint(equalTo: hint.centerYAnchor),
            keys.heightAnchor.constraint(equalToConstant: KeyHint.capH),
            empty.topAnchor.constraint(equalTo: root.topAnchor, constant: titleBar),
            empty.leadingAnchor.constraint(equalTo: root.leadingAnchor), empty.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            empty.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        w.contentView = root
        window = w
        preview.overview = self
        preview.onPointer = { [weak self] on in self?.pointerOnPreview = on; self?.pointerMoved() }
    }

    /// "···" in the heading: what concerns every hanging card (the island's menu without Show: the cards are here).
    private func popAllMenu() {
        let m = NSMenu()
        for (t, f) in hanging.islandMenuItems().dropFirst() { m.addItem(ClosureMenuItem(t, f)) }
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: more.bounds.height + 3), in: more)
    }

    @objc private func segmentPicked() { switchTo(segments.selectedSegment == 1 ? .used : .hanging, via: "click") }

    /// The other segment (a click on it, Tab): the grid again, the selection reset, scrolled to the top.
    func switchTo(_ seg: CardsSegment, via: String) {
        guard isOpen, seg != segment else { return }
        click.cancel()
        segment = seg
        selected = nil
        preview.close()
        rebuild()
        select(nil)                         // on the segments: ← / → switch again, ↓ goes into the grid
        emit(["event": "cards_overview_segment", "segment": seg.rawValue, "via": via, "count": tiles.count])
    }

    private func rebuild() {
        guard let w = window else { return }
        let was = selected.flatMap { $0 < tiles.count ? tiles[$0].shot : nil }
        for t in tiles { t.removeFromSuperview() }
        hovered = nil
        let hangingN = snapper.cards.count, usedN = usedShots.count
        let used = segment == .used
        tiles = (used ? usedShots : hangingShots).map { OverviewTile($0, overview: self, used: used) }
        // the segments: "Hanging 5" | "Used 3", one width each (the wider title's)
        let titles = [Loc.t("capture.cards.seg_current", table: "Capture", Loc.number(hangingN)),
                      Loc.t("capture.cards.seg_history", table: "Capture", Loc.number(usedN))]
        let font = segments.font ?? .systemFont(ofSize: 12)
        let segW = ceil(max(titles.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0, 48) + 24)
        for (i, t) in titles.enumerated() { segments.setLabel(t, forSegment: i); segments.setWidth(segW, forSegment: i) }
        segments.selectedSegment = used ? 1 : 0
        segments.invalidateIntrinsicContentSize()
        more.isHidden = used || hangingN == 0
        // as wide as the wider of the two grids (switching never changes its shape), and room for the keys
        let cols = CardsOverview.columns(tiles.count), sz = CardsOverview.tile, g = CardsOverview.gap, pad = CardsOverview.pad
        let widest = max(CardsOverview.columns(max(hangingN, 1)), CardsOverview.columns(max(usedN, 1)))
        let keysW = KeyHint.size(KeyHint.overview).width
        let contentW = max(CardsOverview.minWidth, CardsOverview.gridWidth(widest), keysW + pad * 2 + 150)
        let none = tiles.isEmpty
        var contentH: CGFloat
        if none {
            let expired = used && snapper.takenExpiredAny
            let title = used ? (expired ? "capture.cards.history_expired_title" : "capture.cards.history_empty_title") : "capture.cards.current_empty_title"
            let hint = used ? (expired ? "capture.cards.history_expired_hint" : "capture.cards.history_empty_hint") : "capture.cards.current_empty_hint"
            empty.rootView = EmptyStateContent(title: Loc.t(title, table: "Capture"), message: Loc.t(hint, table: "Capture"))
            grid.frame = NSRect(x: 0, y: 0, width: contentW, height: 0)
            contentH = titleBar + CardsOverview.emptyH
        } else {
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
            let width = CardsOverview.gridWidth(cols)
            let full = pad * 2 + rowH.reduce(0, +) + CGFloat(rows - 1) * g
            grid.frame = NSRect(x: (contentW - width) / 2, y: 0, width: width, height: full)
            // three rows show, then it scrolls
            let shown = pad * 2 + rowH.prefix(3).reduce(0, +) + CGFloat(min(rows, 3) - 1) * g
            contentH = titleBar + shown + 1 + CardsOverview.footerH
        }
        empty.isHidden = !none
        for v in [scroll, rule, hint] as [NSView] { v.isHidden = none }
        var f = w.frame
        let dh = contentH - f.height
        f.size.width = contentW
        f.size.height = contentH
        f.origin.y -= dh
        w.setFrame(f, display: true)
        if was == nil || !tiles.contains(where: { $0.shot === was }) { grid.scroll(.zero) }
        w.title = Loc.plural("capture.cards.overview_title", table: "Capture", count: tiles.count)
        w.setAccessibilityLabel(w.title)
        selected = was.flatMap { s in tiles.firstIndex { $0.shot === s } } ?? selected.map { min($0, tiles.count - 1) }
        if tiles.isEmpty { selected = nil }
        for (i, t) in tiles.enumerated() { t.selected = i == selected; t.keyboard = hasKeyboard }
        updateHint()
        follow()
    }

    /// Its top edge: under the cards' strip (HangingCards.panelTop) — Put Back hangs a card again, so the panel moves
    /// down out of its way (never up, under the pointer, while it is open). `cardsHang`: a card is on its way back.
    private func follow(cardsHang: Bool = false) {
        guard let w = window, w.isVisible else { return }
        let top = min(island.frameOnScreen.minY - 12, hanging.panelTop(cardsHang: cardsHang || hanging.count > 0))
        guard w.frame.maxY > top + 0.5 else { return }
        let screen = w.screen ?? NSScreen.main ?? NSScreen.screens[0]
        var f = w.frame
        f.origin.y = max(screen.visibleFrame.minY + 12, top - f.height)
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { return w.setFrame(f, display: true) }
        NSAnimationContext.runAnimationGroup { c in
            c.duration = 0.25
            c.timingFunction = CAMediaTimingFunction(name: .easeOut)
            w.animator().setFrame(f, display: true)
        }
    }

    /// The footer: the pointed-at tile's — else the keyboard's — whole note (or its name) and when, else how to use a
    /// tile; the keys as keycaps on the right while the panel has the keyboard (the same KeyHint as the row's).
    private func updateHint() {
        for t in tiles { t.keyboard = hasKeyboard }
        let none = tiles.isEmpty
        keys.items = hasKeyboard ? KeyHint.overview : []
        keys.isHidden = !hasKeyboard || none
        let focus = hovered ?? selected.flatMap { $0 < tiles.count ? tiles[$0] : nil }
        if let t = focus {
            hint.attributedStringValue = OverviewTile.footerLine(t.shot, used: t.used)
        } else if hasKeyboard {
            hint.stringValue = ""           // the keys say how to use it (the mouse's hint would only be squeezed beside them)
        } else {
            hint.stringValue = Loc.t(segment == .used ? "capture.cards.history_hint" : "capture.cards.overview_hint", table: "Capture")
            hint.textColor = .secondaryLabelColor
        }
    }

    /// A tile is pointed at (nil: none): the footer says what it is.
    fileprivate func pointed(_ t: OverviewTile, _ on: Bool) {
        if on { hovered = t } else if hovered === t { hovered = nil }
        updateHint()
    }

    // MARK: closing like a light panel (BA-63)

    /// While open: a click in another app (the global monitor) or in one of Blurt's regular windows (the main window,
    /// Settings) closes it; Esc while Blurt is in front closes it. Nothing is swallowed but that Esc.
    private func watch(_ on: Bool) {
        guard on else {
            monitors.forEach(NSEvent.removeMonitor)
            monitors = []
            pointerOnPanel = false
            pointerOnPreview = false
            holdEsc(false)
            return
        }
        guard monitors.isEmpty else { return }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] _ in
            self?.clickedOutside(via: "other_app")
        }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown], handler: { [weak self] e in
            self?.local(e) ?? e
        }) { monitors.append(l) }
    }

    /// One of Blurt's own events while it is open.
    private func local(_ e: NSEvent) -> NSEvent? {
        guard let w = e.window else { return e }
        if e.type == .keyDown {
            // Esc in Blurt's main window (or Settings) while the panel floats: the panel goes first, as a popover's
            // would (its own keys, and a note bubble's Esc, are theirs)
            guard e.keyCode == 53, CardsOverview.outside(w) else { return e }
            escape()
            return nil
        }
        if w === window {
            if preview.isOpen { closePreview() }        // a click on the grid: back from the preview to it
            return e
        }
        if preview.owns(w) { return e }
        if CardsOverview.outside(w) { clickedOutside(via: "blurt_window") }
        return e
    }

    /// One of Blurt's windows that is not the notch's (the main window, Settings, a sheet): a click there is outside the
    /// panel. The island, the hanging cards, a note bubble and the menu bar's menu are the notch's own (panels or
    /// above the normal level): a click on them leaves it open.
    static func outside(_ w: NSWindow) -> Bool { !(w is NSPanel) && w.level == .normal }

    private func clickedOutside(via: String) {
        guard isOpen, !dragging else { return }
        emit(["event": "cards_overview_outside", "via": via])
        hide()
    }

    /// The pointer came onto (or left) the panel or its preview: Esc is a hotkey only while it is on them.
    private func pointerMoved() { holdEsc(isOpen && (pointerOnPanel || pointerOnPreview)) }

    private func holdEsc(_ on: Bool) {
        guard on != escHeld else { return }
        if on {
            escHeld = registerHotkey(.overviewEsc, key: kVK_Escape, mods: 0) == noErr
        } else {
            unregisterHotkey(.overviewEsc)
            escHeld = false
        }
        emit(["event": "cards_overview_esc", "held": escHeld])
    }

    // MARK: actions

    fileprivate func select(_ i: Int?) {
        selected = tiles.isEmpty ? nil : i.map { min(max($0, 0), tiles.count - 1) }
        for (k, t) in tiles.enumerated() { t.selected = k == selected }
        updateHint()
        if let i = selected {
            tiles[i].scrollToVisible(tiles[i].bounds)
            NSAccessibility.post(element: tiles[i], notification: .focusedUIElementChanged)
        }
    }

    /// A click on a tile: two = edit the note (Hanging) or the preview (Used); one = copy, after the double-click
    /// interval (DeferredClick).
    fileprivate func clicked(_ t: OverviewTile, count: Int) {
        select(tiles.firstIndex { $0 === t })
        switch click.click(ObjectIdentifier(t.shot), count: count, at: CACurrentMediaTime(), interval: NSEvent.doubleClickInterval) {
        case .edit:
            if t.used {
                openPreview(t, via: "double_click")
            } else {
                emit(["event": "card_edit", "n": t.shot.n, "from": "overview"])
                NoteBubble.shared.begin(t.shot, mode: .edit)
            }
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
        emit(["event": t.used ? "taken_copied" : "card_copied", "n": t.shot.n, "what": what.rawValue, "from": "overview", "ok": ok])
        if ok { t.flashCopied() }
    }

    /// The card's menu: Preview first, then the segment's own (Hanging: the card's menu on its thread; Used:
    /// TakenPanel.menu — Copy Image · Copy Note · Put Back · Show in Finder · Delete).
    fileprivate func menu(for t: OverviewTile) -> NSMenu {
        click.cancel()
        defer { settled() }
        select(tiles.firstIndex { $0 === t })
        let copy: (HangingCards.Copy) -> Void = { [weak self, weak t] what in if let t = t { self?.copy(t, what) } }
        let m = t.used ? TakenPanel.menu(t.shot, from: { [weak t] in t?.faceOnScreen }, copy: copy)
                       : hanging.cardMenu(t.shot, copy: copy)
        m.insertItem(ClosureMenuItem(Loc.t("capture.card.preview", table: "Capture")) { [weak self, weak t] in
            if let t = t { self?.openPreview(t, via: "menu") }
        }, at: 0)
        m.insertItem(.separator(), at: 1)
        return m
    }

    /// Delete (⌫, the menu): no question first — "Deleted · Undo" in the island, as on a card's thread.
    fileprivate func delete(_ t: OverviewTile) {
        let used = t.used
        snapper.delete(t.shot)
        if used {
            NotificationCenter.default.post(name: .blurtTakenChanged, object: nil, userInfo: ["count": usedShots.count])
            reload()
        }
    }

    fileprivate func dragStarted() {
        click.cancel()
        dragging = true
    }

    fileprivate func dragEnded() {
        dragging = false
        settled()
    }

    // MARK: the preview

    /// The big view of a tile's card (the eye chip, Space, the menu, a used card's double-click). A click on the panel
    /// is a click: the panel and then the preview take the keyboard (←, → and Space work in it), never activating Blurt.
    fileprivate func openPreview(_ t: OverviewTile, via: String) {
        guard let i = tiles.firstIndex(where: { $0 === t }) else { return }
        select(i)
        let keyed = !testKeyless
        if keyed, window?.isKeyWindow == false { window?.makeKey() }
        preview.show(t.shot, used: t.used, index: i, of: tiles.count, on: window?.screen, keyboard: keyed)
        emit(["event": "card_preview", "n": t.shot.n, "open": true, "via": via, "segment": segment.rawValue,
              "frame": preview.frame.map { [$0.minX, $0.minY, $0.width, $0.height] } ?? []])
    }

    /// Closed (Space, Esc, ×, a click on the grid): the keyboard back on the panel if the preview had it.
    func closePreview() {
        guard preview.isOpen else { return }
        let hadKeys = preview.hasKeyboard
        preview.close()
        if hadKeys, isOpen { window?.makeKey() }
        emit(["event": "card_preview", "open": false])
    }

    /// ← / → in the preview: the card before / after it in this segment.
    func previewStep(_ d: Int) {
        guard let cur = selected ?? preview.shot.flatMap({ s in tiles.firstIndex { $0.shot === s } }), !tiles.isEmpty else { return }
        let i = min(max(cur + d, 0), tiles.count - 1)
        guard i != cur || preview.shot !== tiles[i].shot else { return }
        openPreview(tiles[i], via: "arrow")
    }

    /// A key event as one of the panel's keys (nil: not one of them).
    static func panelKey(_ e: NSEvent) -> CardsPanelKey? {
        let cmd = e.modifierFlags.contains(.command)
        switch Int(e.keyCode) {
        case 123: return .left
        case 124: return .right
        case 126: return .up
        case 125: return .down
        case 49: return cmd ? nil : .space
        case 48: return .tab
        case 36, 76: return .enter
        case 8 where cmd: return .copy
        case 51, 117: return .delete
        case 53: return .escape
        case 13 where cmd: return .close
        default: return nil
        }
    }

    /// The keyboard on the panel: BlurtCore CardsPanelRules.action says what each key does.
    private func key(_ e: NSEvent) -> Bool {
        guard let k = CardsOverview.panelKey(e) else { return false }
        let pointed = hovered.flatMap { h in tiles.firstIndex { $0 === h } }
        switch CardsPanelRules.action(k, segment: segment, focus: selected, count: tiles.count,
                                 columns: CardsOverview.columns(tiles.count), pointed: pointed) {
        case .segment(let seg): switchTo(seg, via: k == .tab ? "tab" : "arrow")
        case .focus(let i): select(i)
        case .preview(let i): openPreview(tiles[i], via: "space")
        case .copyAndClose(let i): copyAndClose(tiles[i])
        case .delete(let i): delete(tiles[i])
        case .close: escape()
        case .none: break
        }
        return true
    }

    /// ↩ / ⌘C: copied — and the panel closes, handing the keyboard back to the app the user was in, so the next ⌘V
    /// pastes the card there.
    private func copyAndClose(_ t: OverviewTile) {
        guard HangingCards.copyShot(t.shot, .click) else { return }
        emit(["event": t.used ? "taken_copied" : "card_copied", "n": t.shot.n, "what": HangingCards.Copy.click.rawValue, "from": "overview", "ok": true])
        hide()
    }

    /// Tests: the tiles in order, and acting on tile N as a click / double-click / ⌫ would; `key K` = that key with the
    /// keyboard on the panel; `hover N` = as if the pointer rested on tile N (no N: none); `open [keyboard] [used]`;
    /// `segment hanging|used`; `preview N` / `previewclose` / `previewstep ±1`; `outside` = a click in another app;
    /// `esc` = the Esc hotkey (the pointer on it).
    func testCommand(_ arg: String) {
        testKeyless = true                  // scripted runs never take the keyboard from the app in front
        let a = arg.split(separator: " ").map(String.init)
        let tile = { (i: Int) -> OverviewTile? in a.count > i ? Int(a[i]).flatMap { n in self.tiles.first { $0.shot.n == n } } : nil }
        switch a.first ?? "" {
        case "open": show(keyboard: a.contains("keyboard"), segment: a.contains("used") ? .used : .hanging, focusFirst: !a.contains("nofocus"))
        case "toggle": toggle(via: "test")
        case "close": hide()
        case "segment": switchTo(a.count > 1 && a[1] == "used" ? .used : .hanging, via: "test")
        case "click": if let t = tile(1) { clicked(t, count: 1) }
        case "double": if let t = tile(1) { clicked(t, count: 1); clicked(t, count: 2) }
        case "delete": if let t = tile(1) { delete(t) }
        case "hover": for t in tiles { t.hovering = t === tile(1) }; hovered = tiles.first { $0.hovering }; updateHint()
        case "copied": tile(1)?.flashCopied()
        case "menu": if let t = tile(1) { emit(["event": "overview_menu", "items": menu(for: t).items.filter { !$0.isSeparatorItem }.map(\.title)]) }
        case "preview": if let t = tile(1) ?? tiles.first { openPreview(t, via: "test") }      // preview [N]: the first tile
        case "previewclose": closePreview()
        case "previewstep": previewStep(a.count > 1 ? Int(a[1]) ?? 1 : 1)
        case "outside": clickedOutside(via: "test")
        case "esc": escape()
        case "key":
            let codes = ["left": 123, "right": 124, "up": 126, "down": 125, "return": 36, "delete": 51, "esc": 53, "space": 49, "tab": 48]
            if a.count > 1, let code = codes[a[1]],
               let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: window?.windowNumber ?? 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                                        isARepeat: false, keyCode: UInt16(code)) {
                if preview.isOpen, preview.hasKeyboard || testKeyless { _ = preview.key(e) } else { _ = key(e) }
            }
        default: break
        }
        emit(["event": "cards_overview", "open": isOpen, "order": tiles.map(\.shot.n), "selected": selected ?? -1,
              "title": window?.title ?? "", "key": hasKeyboard, "columns": CardsOverview.columns(tiles.count),
              "segment": segment.rawValue, "hanging": snapper.cards.count, "used": usedShots.count,
              "preview": preview.shot?.n ?? -1, "frame": window.map { [$0.frame.minX, $0.frame.minY, $0.frame.width, $0.frame.height] } ?? []])
    }

    /// Tests: tile N's picture on screen (Cocoa coordinates), for each tile showing.
    var tileFrames: [(n: Int, rect: NSRect)] { tiles.compactMap { t in t.faceOnScreen.map { (t.shot.n, $0) } } }
}

/// One card in the panel: its picture (or a voice note's words), its note under it; pointed at, the wash and its
/// actions (the eye, "···", Copy).
final class OverviewTile: NSView, NSDraggingSource {
    let shot: Shot
    /// a used card (dragged out or pasted, Snapper.recentlyTaken): its menu, its drag and its double-click differ
    let used: Bool
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

    /// Its picture on screen (Cocoa coordinates): where a card put back flies up from, the tests' rects.
    var faceOnScreen: NSRect? {
        guard let w = window else { return nil }
        return w.convertToScreen(convert(NSRect(origin: .zero, size: CardsOverview.tile), to: nil))
    }

    init(_ s: Shot, overview: CardsOverview, used: Bool = false) {
        shot = s
        self.used = used
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
        // one line in attention ink under the note: a snap whose words couldn't be had, or a used card on its last day
        var status: String?
        if s.kind == .shot, s.note.needsYou { status = HangingCards.statusText(s.note.status) }
        if used, let t = s.taken {
            let days = TakenCaptures.daysLeft(taken: t, now: Snapper.now)
            if TakenCaptures.showsDaysLeft(days) {
                let d = Loc.plural("capture.taken.days_left", table: "Capture", count: days)
                status = d.prefix(1).uppercased() + d.dropFirst()
            }
        }
        if let st = status {
            let line = NSTextField(labelWithString: st)
            line.font = .systemFont(ofSize: 11)
            line.textColor = BrandColor.attnInk
            line.lineBreakMode = .byTruncatingTail
            line.frame = NSRect(x: -2, y: sz.height + 8 + lines * lineH + (lines > 0 ? 3 : 0), width: sz.width + 4, height: 15)
            addSubview(line)
            lines += 1
        }
        captionHeight = lines == 0 ? 6 : 8 + lines * lineH + 6
        // the card's actions, in the picture's top-right corner: [eye][···][Copy] — shown on hover and on the
        // keyboard's tile
        actions = CardActions(menu: { [weak self] in self.flatMap { $0.overview?.menu(for: $0) } },
                              copy: { [weak self] in if let self { self.overview?.copy(self, .click) } },
                              preview: { [weak self] in if let self { self.overview?.openPreview(self, via: "chip") } })
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
        setAccessibilityHelp(Loc.t(used ? "capture.cards.history_ax_help" : "capture.card.ax_help", table: "Capture"))
        if !used { setAccessibilityCustomActions(HangingCards.axActions(s)) }
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
        // the actions: under the pointer, and on the keyboard's tile
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

    /// The footer's line for the tile pointed at: its whole note in ink and, quieter, when — the time it was taken
    /// ("19:05"), or for a used card when it was used ("Used 4 min ago", and "· kept 1 more day" in attention ink on
    /// its last day). A card without a note: its name ("Snap · 19:05").
    static func footerLine(_ s: Shot, used: Bool = false) -> NSAttributedString {
        let f = NSFont.systemFont(ofSize: 12)
        let quiet: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                                                    .foregroundColor: NSColor.tertiaryLabelColor]
        let words = s.words?.replacingOccurrences(of: "\n", with: " ")
        let hasWords = !(words ?? "").isEmpty
        let out = NSMutableAttributedString(string: hasWords ? words! : s.plainName, attributes: [.font: f, .foregroundColor: NSColor.labelColor])
        if used {
            out.append(NSAttributedString(string: "  ", attributes: quiet))
            out.append(usedWhen(s))
        } else if hasWords {
            out.append(NSAttributedString(string: "  " + s.takenAt, attributes: quiet))
        }
        return out
    }

    /// "Used 5 min ago", and "· kept 1 more day" in attention ink on its last day (the hint says 7 days once for all).
    static func usedWhen(_ s: Shot) -> NSAttributedString {
        let now = Snapper.now
        // the cards' one relative time (CardTime): "Just now", "4 min ago" — never a live count of seconds
        var ago = CardTime.ago(s.taken ?? now, now: now)
        if Loc.language != "zh-Hans" { ago = ago.prefix(1).lowercased() + ago.dropFirst() }
        let f = NSFont.systemFont(ofSize: 11)
        let out = NSMutableAttributedString(string: Loc.t("capture.cards.history_when", table: "Capture", ago),
                                            attributes: [.font: f, .foregroundColor: NSColor.tertiaryLabelColor])
        let days = TakenCaptures.daysLeft(taken: s.taken ?? now, now: now)
        guard TakenCaptures.showsDaysLeft(days) else { return out }
        out.append(NSAttributedString(string: " · ", attributes: [.font: f, .foregroundColor: NSColor.tertiaryLabelColor]))
        out.append(NSAttributedString(string: Loc.plural("capture.taken.days_left", table: "Capture", count: days),
                                      attributes: [.font: f, .foregroundColor: BrandColor.attnInk]))
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
        emit(["event": used ? "taken_drag" : "overview_drag", "n": shot.n, "items": items.count])
        drag.setBase(image: img, frame: frame, in: self)
        if !used { island.dragBegan() }     // a project in the island can take a hanging card, as from the row
        let session = beginDraggingSession(with: items, event: e, source: self)
        session.draggingFormation = .none
        session.animatesToStartingPositionsOnCancelOrFail = true
        drag.session = session
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .generic] : (used ? [] : [.generic, .move])
    }

    func draggingSession(_ session: NSDraggingSession, movedTo p: NSPoint) {
        cardDrag?.moved(to: p)
        if !used { island.dragMoved(to: p) }
    }

    func draggingSession(_ session: NSDraggingSession, endedAt p: NSPoint, operation: NSDragOperation) {
        let drag = cardDrag
        cardDrag = nil
        let overview = self.overview
        defer { overview?.dragEnded() }        // (the grid follows the cards again once this tile is done with)
        let filed = used ? false : island.dragEnded(at: p)
        emit(["event": used ? "taken_drag_end" : "overview_drag_end", "n": shot.n, "operation": Int(operation.rawValue), "filed": filed])
        guard !filed, !OverviewTile.ourWindow(at: p) else { return }
        // a voice note over a chat app's window: its words go into that composer, wherever it was let go of
        if let t = drag?.voiceTarget(at: p) {
            snapper.takeOutVoice(shot, fromPanel: used, landed: t, at: p, accepted: !operation.isEmpty,
                                 wordsWithheld: drag?.wordsWithheld(at: t) ?? false)
            return
        }
        // taken by another app: a hanging card leaves its thread ("Dragged out · Undo"); a used one is used again (its
        // 7 days start over, and the note goes on the clipboard as after any drag-out)
        if !operation.isEmpty {
            let got = drag?.delivered(at: p)
            snapper.takeOut(shot, fromPanel: used, delivered: got, noteFile: got.map { drag?.noteFile($0) ?? false } ?? false,
                            landed: DropProbe.target(at: p), at: p)
        }
    }

    /// The window under a screen point is one of ours (the panel itself, the main window, a note): not "used in
    /// another app".
    static func ourWindow(at p: NSPoint) -> Bool {
        let n = NSWindow.windowNumber(at: p, belowWindowWithWindowNumber: 0)
        return n > 0 && NSApp.windows.contains { $0.windowNumber == n && !($0 is CardsPanel) }   // (the cards take no drops)
    }
}
