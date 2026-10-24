// Every hanging card at once (v0.9). The row under the island shows the newest few (BlurtCore CardRow: at most 5, newest
// first); the rest wait behind a quiet "+N" tile at its end, and a click on it (↩ on it with the keyboard, its
// VoiceOver press) opens this panel: every card, newest first, in a grid — with what a card on its thread can do:
//   click = copy (once the double-click interval has passed: a double-click edits the note instead, and never copies
//   first) · right-click = the card's menu (HangingCards.cardMenu: Copy Image / Text, Copy All, Edit Note…, Move To ▸,
//   Sort with AI, Delete) · drag = out into any app (the same items as a card's drag, CardDrag; a voice card over a chat
//   app pastes its words), or onto a project in the island · with the keyboard (a click puts it on the panel): arrows
//   move, ↩ / ⌘C copies, ⌫ deletes (Undo in the island), Esc closes.
// A small utility panel under the cards, like Recently Taken; it follows the cards as they change and closes itself
// when none are left. It never activates Blurt.

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
    static let columns = 4
    static let tile = CGSize(width: 120, height: 90)
    static let caption: CGFloat = 32
    static let gap: CGFloat = 12
    static let pad: CGFloat = 16

    private var window: OverviewPanel?
    private let grid = FlippedView()
    private let scroll = NSScrollView()
    private(set) var tiles: [OverviewTile] = []
    private var selected: Int?
    private var click = DeferredClick<ObjectIdentifier>()

    var isOpen: Bool { window?.isVisible ?? false }

    /// Opens under the cards (`keyboard`: with the keyboard on it, from ↩ on the "+N" tile).
    func show(keyboard: Bool = false) {
        if window == nil { build() }
        guard let w = window else { return }
        rebuild()
        guard !tiles.isEmpty else { return hide() }
        let size = w.frame.size
        let anchor = island.frameOnScreen
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main ?? NSScreen.screens[0]
        let top = min(hanging.shownBottom ?? anchor.minY, anchor.minY) - 12
        var x = anchor.midX - size.width / 2
        x = min(max(x, screen.visibleFrame.minX + 12), screen.visibleFrame.maxX - size.width - 12)
        w.setFrameOrigin(NSPoint(x: x, y: max(screen.visibleFrame.minY + 12, min(top, screen.visibleFrame.maxY) - size.height)))
        w.orderFrontRegardless()
        if keyboard {
            snapper.rememberFrontApp()
            w.makeKey()
            select(0)
        }
        emit(["event": "cards_overview_open", "count": tiles.count, "order": tiles.map(\.shot.n)])
    }

    func hide() {
        guard let w = window, w.isVisible else { return }
        let wasKey = w.isKeyWindow
        w.orderOut(nil)
        if wasKey { snapper.restoreFocus() }
        emit(["event": "cards_overview_open", "open": false])
    }

    /// The cards changed (one copied out, filed, deleted, a new one caught): the grid again, if it is open.
    func reload() {
        guard isOpen else { return }
        rebuild()
        if tiles.isEmpty { hide() }
    }

    func windowWillClose(_ notification: Notification) { emit(["event": "cards_overview_open", "open": false]) }

    private func build() {
        let w = OverviewPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                              styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel], backing: .buffered, defer: false)
        w.isFloatingPanel = true
        w.level = .floating
        w.hidesOnDeactivate = false
        w.isReleasedWhenClosed = false
        w.becomesKeyOnlyIfNeeded = true
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.sharingType = chromeSharing
        w.delegate = self
        w.onKey = { [weak self] e in self?.key(e) ?? false }
        scroll.documentView = grid
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        w.contentView = scroll
        window = w
    }

    private func rebuild() {
        guard let w = window else { return }
        let was = selected.flatMap { $0 < tiles.count ? tiles[$0].shot : nil }
        for t in tiles { t.removeFromSuperview() }
        // newest first, the order they hang in
        tiles = snapper.cards.reversed().map { OverviewTile($0, overview: self) }
        let cols = CardsOverview.columns, sz = CardsOverview.tile, g = CardsOverview.gap, pad = CardsOverview.pad
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
        var f = w.frame
        let content = w.contentRect(forFrameRect: f)
        let dh = shown - content.height
        f.size.width += width - content.width
        f.size.height += dh
        f.origin.y -= dh
        w.setFrame(f, display: true)
        w.title = Loc.plural("capture.cards.overview_title", table: "Capture", count: tiles.count)
        w.setAccessibilityLabel(w.title)
        selected = was.flatMap { s in tiles.firstIndex { $0.shot === s } } ?? selected.map { min($0, tiles.count - 1) }
        if tiles.isEmpty { selected = nil }
        for (i, t) in tiles.enumerated() { t.selected = i == selected }
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
        case .copy(let at):
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, at - CACurrentMediaTime())) { [weak self, weak t] in
                guard let self = self, let t = t, self.click.fire(at: CACurrentMediaTime() + 0.01) == ObjectIdentifier(t.shot) else { return }
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
        select(tiles.firstIndex { $0 === t })
        return hanging.cardMenu(t.shot) { [weak self, weak t] what in if let t = t { self?.copy(t, what) } }
    }

    fileprivate func dragStarted() { click.cancel() }

    private func key(_ e: NSEvent) -> Bool {
        let cols = CardsOverview.columns
        let cmd = e.modifierFlags.contains(.command)
        let cur = selected
        switch Int(e.keyCode) {
        case 123: select((cur ?? 0) - 1)                       // ←
        case 124: select(cur.map { $0 + 1 } ?? 0)              // →
        case 126: select((cur ?? 0) - cols)                    // ↑
        case 125: select(cur.map { $0 + cols } ?? 0)           // ↓
        case 36, 76:                                           // ↩, enter
            if let i = cur { copy(tiles[i], .click) }
        case 8 where cmd:                                      // ⌘C
            if let i = cur { copy(tiles[i], .click) }
        case 51, 117:                                          // ⌫, ⌦: Undo in the island
            if let i = cur { snapper.delete(tiles[i].shot) }
        case 53: hide()                                        // Esc
        case 13 where cmd: hide()                              // ⌘W
        default: return false
        }
        return true
    }

    /// Tests: the tiles in order, and acting on tile N as a click / double-click / ⌫ would.
    func testCommand(_ arg: String) {
        let a = arg.split(separator: " ").map(String.init)
        let tile = { (i: Int) -> OverviewTile? in a.count > i ? Int(a[i]).flatMap { n in self.tiles.first { $0.shot.n == n } } : nil }
        switch a.first ?? "" {
        case "open": show()
        case "close": hide()
        case "click": if let t = tile(1) { clicked(t, count: 1) }
        case "double": if let t = tile(1) { clicked(t, count: 1); clicked(t, count: 2) }
        case "delete": if let t = tile(1) { snapper.delete(t.shot) }
        case "menu": if let t = tile(1) { emit(["event": "overview_menu", "items": menu(for: t).items.filter { !$0.isSeparatorItem }.map(\.title)]) }
        default: break
        }
        emit(["event": "cards_overview", "open": isOpen, "order": tiles.map(\.shot.n), "selected": selected ?? -1,
              "title": window?.title ?? ""])
    }
}

/// One card in the overview: its picture (or a voice note's words) and a line under it.
final class OverviewTile: NSView, NSDraggingSource {
    let shot: Shot
    private weak var overview: CardsOverview?
    private let face = CALayer()
    private let ring = CALayer()
    private let copiedPill = NSTextField(labelWithString: "")
    private var downAt: NSPoint?
    private var cardDrag: CardDrag?

    var selected = false { didSet { ring.isHidden = !selected } }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var needsPanelToBecomeKey: Bool { true }

    init(_ s: Shot, overview: CardsOverview) {
        shot = s
        self.overview = overview
        super.init(frame: .zero)
        wantsLayer = true
        let sz = CardsOverview.tile
        face.frame = CGRect(origin: .zero, size: sz)
        face.cornerRadius = 7
        face.masksToBounds = true
        face.borderWidth = 0.5
        face.borderColor = NSColor.separatorColor.cgColor
        face.contentsGravity = .resizeAspectFill
        layer?.addSublayer(face)
        if s.kind == .shot {
            face.contents = s.markedThumb ?? s.thumb
            face.backgroundColor = NSColor(white: 0.5, alpha: 0.2).cgColor
        } else {
            // a voice note is its words, on the card's own surface, with the small mic mark
            face.backgroundColor = NSColor.controlBackgroundColor.cgColor
            let words = NSTextField(wrappingLabelWithString: s.words ?? HangingCards.statusText(s.note.status) ?? "")
            words.font = .systemFont(ofSize: 11.5, weight: .medium)
            words.textColor = s.words == nil ? .secondaryLabelColor : .labelColor
            words.maximumNumberOfLines = 4
            words.lineBreakMode = .byTruncatingTail
            words.frame = NSRect(x: 9, y: 7, width: sz.width - 18, height: sz.height - 22)
            addSubview(words)
            let mic = NSImageView(image: BlurtIcon.mic.image(size: 10, color: BrandColor.ink))
            mic.frame = NSRect(x: sz.width - 18, y: sz.height - 17, width: 10, height: 10)
            addSubview(mic)
        }
        ring.frame = face.frame.insetBy(dx: -3, dy: -3)
        ring.cornerRadius = 10
        ring.borderWidth = 2.5
        ring.borderColor = BrandColor.accent.cgColor
        ring.isHidden = true
        layer?.addSublayer(ring)
        let line = NSTextField(labelWithString: OverviewTile.line(s))
        line.font = .systemFont(ofSize: 11)
        line.textColor = s.kind == .shot && s.words != nil ? .labelColor : .secondaryLabelColor
        line.maximumNumberOfLines = 2
        line.cell?.wraps = true
        line.lineBreakMode = .byWordWrapping
        line.cell?.truncatesLastVisibleLine = true
        line.frame = NSRect(x: 0, y: sz.height + 4, width: sz.width, height: CardsOverview.caption - 4)
        addSubview(line)
        copiedPill.font = .systemFont(ofSize: 11, weight: .semibold)
        copiedPill.textColor = .white
        copiedPill.alignment = .center
        copiedPill.wantsLayer = true
        copiedPill.layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.88).cgColor
        copiedPill.layer?.cornerRadius = 10
        copiedPill.isHidden = true
        addSubview(copiedPill)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(HangingCards.cardLabel(s))
        setAccessibilityRoleDescription(Loc.t(s.kind == .voice ? "capture.card.ax_voice" : "capture.card.ax_shot", table: "Capture"))
        setAccessibilityHelp(Loc.t("capture.card.ax_help", table: "Capture"))
        setAccessibilityCustomActions(HangingCards.axActions(s))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func accessibilityPerformPress() -> Bool { overview?.copy(self, .click); return true }

    /// Under the picture: its note (a voice tile has its words on it already: when it was said).
    static func line(_ s: Shot) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        let when = f.string(from: Date(timeIntervalSince1970: s.wall))
        if s.kind == .shot, let w = s.words { return w.replacingOccurrences(of: "\n", with: " · ") }
        return when
    }

    func flashCopied() {
        copiedPill.stringValue = Loc.t("capture.card.copied", table: "Capture")
        copiedPill.sizeToFit()
        let w = copiedPill.frame.width + 20
        copiedPill.frame = NSRect(x: (CardsOverview.tile.width - w) / 2, y: (CardsOverview.tile.height - 20) / 2, width: w, height: 20)
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
        let filed = island.dragEnded(at: p)
        emit(["event": "overview_drag_end", "n": shot.n, "operation": Int(operation.rawValue), "filed": filed])
        guard !filed, !OverviewTile.ourWindow(at: p) else { return }
        // a voice note over a chat app's window: its words go into that composer, wherever it was let go of
        if let t = drag?.voiceTarget(at: p) {
            snapper.takeOutVoice(shot, landed: t, at: p, accepted: !operation.isEmpty)
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
