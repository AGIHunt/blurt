// Recently Taken (v0.8.1): cards dragged out into another app in the last 7 days. A drop that kept only part of a card
// (Claude took the picture, not the note) must never lose it — so a taken card leaves its thread but stays here, with
// everything a card can do: copy it (picture + note, as a click on a card), copy the picture or the note alone, drag
// the picture out again (the same items as a card's drag), put it back on its thread, show it in the Finder.
//
// Two ways in: the island's right-click menu ("Recently Taken (N)", each one with its actions, and "Show All…" for
// this panel) and the main window's "Recently taken: N" row (Inbox and Unassigned). After 7 days Snapper.expireTaken
// moves a taken capture to the Trash.
//
// The panel: a small utility window on the island's screen, under the island; one row per capture — the picture
// (drag it), the note (two lines) and when it was taken, then Copy · Copy Image · Copy Note · Put Back.

import AppKit
import BlurtCore

final class TakenPanel: NSObject, NSWindowDelegate {
    static let shared = TakenPanel()
    private var window: NSPanel?
    private let list = NSStackView()
    private let empty = NSTextField(labelWithString: "")
    private(set) var rows: [TakenRow] = []

    var isOpen: Bool { window?.isVisible ?? false }

    /// `near`: a screen rect to open under (the island); nil = under the island anyway.
    func show(near: NSRect? = nil) {
        if window == nil { build() }
        reload()
        guard let w = window else { return }
        let anchor = near ?? island.frameOnScreen
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main ?? NSScreen.screens[0]
        let size = w.frame.size
        var x = anchor.midX - size.width / 2
        x = min(max(x, screen.visibleFrame.minX + 12), screen.visibleFrame.maxX - size.width - 12)
        let y = min(anchor.minY - 12, screen.visibleFrame.maxY) - size.height
        w.setFrameOrigin(NSPoint(x: x, y: max(screen.visibleFrame.minY + 12, y)))
        w.orderFrontRegardless()
        emit(["event": "taken_panel", "open": true, "count": rows.count])
    }

    func hide() { window?.orderOut(nil) }

    private func build() {
        let w = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 120),
                        styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel], backing: .buffered, defer: false)
        w.title = Loc.t("capture.taken.title", table: "Capture")
        w.isFloatingPanel = true
        w.level = .floating
        w.hidesOnDeactivate = false
        w.isReleasedWhenClosed = false
        w.becomesKeyOnlyIfNeeded = true
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.delegate = self
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 0
        list.translatesAutoresizingMaskIntoConstraints = false
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(list)
        let scroll = NSScrollView()
        scroll.documentView = doc
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let hint = NSTextField(wrappingLabelWithString: Loc.t("capture.taken.hint", table: "Capture"))
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.translatesAutoresizingMaskIntoConstraints = false
        empty.stringValue = Loc.t("capture.taken.empty", table: "Capture")
        empty.textColor = .secondaryLabelColor
        empty.alignment = .center
        empty.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        for v in [scroll, hint, empty] as [NSView] { root.addSubview(v) }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor), scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor), scroll.bottomAnchor.constraint(equalTo: hint.topAnchor, constant: -6),
            hint.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14), hint.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            hint.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
            empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor), empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor), doc.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            list.topAnchor.constraint(equalTo: doc.topAnchor), list.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: doc.trailingAnchor), list.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
        ])
        w.contentView = root
        w.setAccessibilityLabel(w.title)
        window = w
    }

    /// The rows again (a card taken, put back, expired; every minute's "2 h ago" is not worth a timer).
    func reload() {
        guard let w = window else { return }
        let shots = snapper.recentlyTaken
        for r in rows { r.removeFromSuperview() }
        rows = shots.map { TakenRow($0) }
        for r in rows {
            list.addArrangedSubview(r)
            r.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
        list.widthAnchor.constraint(equalToConstant: 460).isActive = true
        empty.isHidden = !rows.isEmpty
        let h = CGFloat(max(1, min(rows.count, 6))) * TakenRow.height + 44
        var f = w.frame
        let content = w.contentRect(forFrameRect: f)
        let dh = h - content.height
        f.size.height += dh
        f.origin.y -= dh
        w.setFrame(f, display: true)
    }

    func windowWillClose(_ notification: Notification) { emit(["event": "taken_panel", "open": false]) }

    // MARK: the island's right-click menu

    /// "Show N Hanging Cards", then "Recently Taken (N)" with each capture's actions, and "Show All…".
    static func islandMenu() -> NSMenu {
        let m = NSMenu()
        if hanging.count > 0 {
            m.addItem(ClosureMenuItem(Loc.plural("capture.menu.show_cards", table: "Capture", count: hanging.count)) { hanging.reveal(via: "island_menu") })
        }
        let taken = snapper.recentlyTaken
        let head = NSMenuItem(title: Loc.t("capture.taken.menu", table: "Capture", taken.count), action: nil, keyEquivalent: "")
        if taken.isEmpty {
            m.addItem(head)                                   // (dimmed: nothing to show)
            return m
        }
        let sub = NSMenu()
        for s in taken.prefix(12) {
            let it = NSMenuItem(title: title(s), action: nil, keyEquivalent: "")
            it.image = thumb(s, height: 22)
            it.submenu = actionsMenu(s, from: nil)
            sub.addItem(it)
        }
        sub.addItem(.separator())
        sub.addItem(ClosureMenuItem(Loc.t("capture.taken.show_all", table: "Capture")) { TakenPanel.shared.show() })
        head.submenu = sub
        m.addItem(head)
        return m
    }

    /// One taken capture's actions (its submenu in the island's menu; the same as its row's buttons).
    static func actionsMenu(_ s: Shot, from: (() -> NSRect?)?) -> NSMenu {
        let m = NSMenu()
        for (t, f) in actions(s, from: from) { m.addItem(ClosureMenuItem(t, f)) }
        if s.kind == .shot {
            m.addItem(ClosureMenuItem(Loc.t("capture.taken.drag_again", table: "Capture")) { TakenPanel.shared.show() })
        }
        if let u = s.bestURL {
            m.addItem(.separator())
            m.addItem(ClosureMenuItem(Loc.t("capture.card.reveal", table: "Capture")) { NSWorkspace.shared.activateFileViewerSelecting([u]) })
        }
        return m
    }

    /// Copy (as a click on its card) · Copy Image · Copy Note · Put Back on the Line.
    static func actions(_ s: Shot, from: (() -> NSRect?)?) -> [(String, () -> Void)] {
        var out: [(String, () -> Void)] = []
        out.append((Loc.t("capture.taken.copy", table: "Capture"), { copy(s, .click) }))
        if s.kind == .shot, s.bestURL != nil { out.append((Loc.t("capture.card.copy_image", table: "Capture"), { copy(s, .image) })) }
        if s.copyText != nil { out.append((Loc.t("capture.taken.copy_note", table: "Capture"), { copy(s, .text) })) }
        out.append((Loc.t("capture.taken.put_back", table: "Capture"), { snapper.putBack(s, from: from?()) }))
        return out
    }

    @discardableResult
    static func copy(_ s: Shot, _ what: HangingCards.Copy) -> Bool {
        let ok = HangingCards.copyShot(s, what)
        emit(["event": "taken_copied", "n": s.n, "what": what.rawValue, "ok": ok,
              "items": (capturePasteboard.pasteboardItems ?? []).map { $0.types.map(\.rawValue) }])
        if ok { island.toast(Loc.t("capture.card.copied", table: "Capture"), actionTitle: nil, action: nil) }
        return ok
    }

    /// The note's first line, or "Screenshot 15:30" / "Voice note 15:30".
    static func title(_ s: Shot) -> String {
        if let t = s.words?.split(whereSeparator: \.isNewline).first.map(String.init) { return t.count > 60 ? String(t.prefix(59)) + "…" : t }
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return Loc.t(s.kind == .voice ? "capture.card.ax_voice_n" : "capture.card.ax_shot_n", table: "Capture", s.n) + " · " +
            f.string(from: Date(timeIntervalSince1970: s.wall))
    }

    static func thumb(_ s: Shot, height: CGFloat) -> NSImage? {
        guard s.kind == .shot, let cg = s.markedThumb ?? s.thumb else { return BlurtIcon.mic.image(size: height * 0.8) }
        let w = height * CGFloat(cg.width) / CGFloat(max(1, cg.height))
        return NSImage(cgImage: cg, size: NSSize(width: min(w, height * 2), height: height))
    }
}

/// A row of Recently Taken: the picture (drag it out again), the note, when it was taken, and its actions.
final class TakenRow: NSView {
    static let height: CGFloat = 76
    let shot: Shot
    let thumb: TakenThumb

    init(_ s: Shot) {
        shot = s
        thumb = TakenThumb(s)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(wrappingLabelWithString: s.words ?? TakenPanel.title(s))
        title.font = .systemFont(ofSize: 12, weight: .medium)
        title.maximumNumberOfLines = 2
        title.lineBreakMode = .byTruncatingTail
        title.textColor = s.words == nil ? .secondaryLabelColor : .labelColor
        let ago = RelativeDateTimeFormatter()
        ago.locale = Locale(identifier: Loc.language == "zh-Hans" ? "zh-Hans" : "en")
        let now = Snapper.now
        let when = Loc.t("capture.taken.when", table: "Capture",
                         ago.localizedString(for: Date(timeIntervalSince1970: s.taken ?? now), relativeTo: Date(timeIntervalSince1970: now)))
        let left = Loc.plural("capture.taken.days_left", table: "Capture", count: TakenCaptures.daysLeft(taken: s.taken ?? now, now: now))
        let detail = NSTextField(labelWithString: when + " · " + left)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        let buttons = NSStackView()
        buttons.spacing = 6
        for (t, f) in TakenPanel.actions(s, from: { [weak thumbView = thumb] in
            guard let v = thumbView, let w = v.window else { return nil }
            return w.convertToScreen(v.convert(v.bounds, to: nil))
        }) {
            let b = ClosureButton(t, f)
            b.controlSize = .small
            b.bezelStyle = .rounded
            b.font = .systemFont(ofSize: 11)
            buttons.addArrangedSubview(b)
        }
        let text = NSStackView(views: [title, detail, buttons])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        let line = NSBox()
        line.boxType = .separator
        for v in [thumb, text, line] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: TakenRow.height),
            thumb.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12), thumb.centerYAnchor.constraint(equalTo: centerYAnchor),
            thumb.widthAnchor.constraint(equalToConstant: 80), thumb.heightAnchor.constraint(equalToConstant: 56),
            text.leadingAnchor.constraint(equalTo: thumb.trailingAnchor, constant: 12), text.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            title.widthAnchor.constraint(lessThanOrEqualToConstant: 340),
            line.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12), line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(TakenPanel.title(s))
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// The picture of a taken capture: drag it out again — the same items as a card's drag (a voice note: its words).
final class TakenThumb: NSImageView, NSDraggingSource {
    let shot: Shot
    private var downAt: NSPoint?
    private var cardDrag: CardDrag?

    init(_ s: Shot) {
        shot = s
        super.init(frame: .zero)
        image = TakenPanel.thumb(s, height: 56)
        imageScaling = .scaleProportionallyUpOrDown
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.separatorColor.cgColor
        toolTip = Loc.t("capture.taken.drag_tip", table: "Capture")
        setAccessibilityLabel(Loc.t("capture.taken.drag_tip", table: "Capture"))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with e: NSEvent) { downAt = e.locationInWindow }
    override func mouseDragged(with e: NSEvent) {
        guard let d = downAt, hypot(e.locationInWindow.x - d.x, e.locationInWindow.y - d.y) > 4 else { return }
        downAt = nil
        let drag = CardDrag(shot)            // its items follow the app under the pointer
        cardDrag = drag
        let items = drag.pasteboardItems().enumerated().map { i, it -> NSDraggingItem in
            let di = NSDraggingItem(pasteboardWriter: it)
            di.setDraggingFrame(i == 0 ? bounds : NSRect(x: bounds.midX, y: bounds.midY, width: 1, height: 1), contents: i == 0 ? image : nil)
            return di
        }
        emit(["event": "taken_drag", "n": shot.n, "items": items.count])
        let session = beginDraggingSession(with: items, event: e, source: self)
        session.draggingFormation = .none
        session.animatesToStartingPositionsOnCancelOrFail = true
        drag.session = session
    }

    func draggingSession(_ session: NSDraggingSession, movedTo p: NSPoint) { cardDrag?.moved(to: p) }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .generic] : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt p: NSPoint, operation: NSDragOperation) {
        emit(["event": "taken_drag_end", "n": shot.n, "operation": Int(operation.rawValue)])
        let drag = cardDrag
        cardDrag = nil
        // taken again: its 7 days start over, and the note goes on the clipboard as after any drag-out
        if !operation.isEmpty { snapper.takeOut(shot, fromPanel: true, delivered: drag?.delivered(at: p)) }
    }
}

final class ClosureButton: NSButton {
    private var fn: (() -> Void)?
    convenience init(_ title: String, _ fn: @escaping () -> Void) {
        self.init(title: title, target: nil, action: nil)
        self.fn = fn
        target = self
        action = #selector(fire)
    }
    @objc func fire() { fn?() }
}
