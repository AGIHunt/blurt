// Recently Dragged Out (v0.8.1; "Recently Taken" in the code): cards dragged out into another app in the last 7 days.
// A drop that kept only part of a card (Claude took the picture, not the note) must never lose it — so a taken card
// leaves its thread but stays here, with everything a card can do: copy it (picture + note, as a click on a card),
// copy the picture or the note alone, drag the picture out again (the same items as a card's drag), hang it back on
// the notch (a card again), show it in the Finder.
//
// Two ways in: the island's right-click menu ("Recently Dragged Out (N)", each one with its tile and its actions, and
// "Show All…" for this panel) and the main window's "Recently dragged out: N" row (Inbox and Unassigned). After 7 days
// Snapper.expireTaken moves a taken capture to the Trash.
//
// The panel (v0.9 look, docs/design/system.md §3.2): a small utility window on the island's screen, under the island;
// one compact row per capture, like the main window's lists — its tile (CaptureThumb: the picture, or a voice note's
// brand-tint tile with the waveform and its length; drag it out), the note on one line, then when it was dragged out
// and how long it stays (in attention ink on its last day). Pointing at a row gives it the brand-tint wash and shows
// its actions: one primary, Copy (picture and note, the thing people come back for; a BrandButton), and a quiet "···"
// with the rest — Copy Image · Copy Note · Hang Back on the Notch · Show in Finder (the same menu on a right-click of
// the row). Only the row under the pointer shows them, so there is one primary at a time. A hairline, then the hint.
// v0.8.6 had four buttons of the same weight on every row; v0.9.0 a 56 pt mic glyph as a voice note's picture.

import AppKit
import BlurtCore

final class TakenPanel: NSObject, NSWindowDelegate {
    static let shared = TakenPanel()
    static let width: CGFloat = 440
    static let rowGap: CGFloat = 2
    static let footerPad: CGFloat = 10
    private var window: NSPanel?
    private let list = NSStackView()
    private let empty = NSTextField(labelWithString: "")
    private let hint = NSTextField(wrappingLabelWithString: "")
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
        let w = NSPanel(contentRect: NSRect(x: 0, y: 0, width: TakenPanel.width, height: 120),
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
        list.spacing = TakenPanel.rowGap
        list.edgeInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
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
        // the footer, like the main window's quiet hints: a hairline, then one small secondary paragraph
        let rule = NSBox()
        rule.boxType = .separator
        rule.translatesAutoresizingMaskIntoConstraints = false
        hint.stringValue = Loc.t("capture.taken.hint", table: "Capture")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.preferredMaxLayoutWidth = TakenPanel.width - 32
        hint.translatesAutoresizingMaskIntoConstraints = false
        empty.stringValue = Loc.t("capture.taken.empty", table: "Capture")
        empty.font = .systemFont(ofSize: 13)
        empty.textColor = .secondaryLabelColor
        empty.alignment = .center
        empty.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        for v in [scroll, rule, hint, empty] as [NSView] { root.addSubview(v) }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor), scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor), scroll.bottomAnchor.constraint(equalTo: rule.topAnchor),
            rule.leadingAnchor.constraint(equalTo: root.leadingAnchor), rule.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            hint.topAnchor.constraint(equalTo: rule.bottomAnchor, constant: TakenPanel.footerPad),
            hint.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            hint.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            hint.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -TakenPanel.footerPad),
            empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor), empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor), doc.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            list.topAnchor.constraint(equalTo: doc.topAnchor), list.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: doc.trailingAnchor), list.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            list.widthAnchor.constraint(equalToConstant: TakenPanel.width),
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
        empty.isHidden = !rows.isEmpty
        // up to 6 rows, then it scrolls; the list's insets, the hairline and the footer under them
        let n = CGFloat(max(1, min(rows.count, 6)))
        let h = 12 + n * TakenRow.height + (n - 1) * TakenPanel.rowGap + 1 + TakenPanel.footerPad * 2 + ceil(hint.fittingSize.height)
        var f = w.frame
        let content = w.contentRect(forFrameRect: f)
        let dh = h - content.height
        f.size.height += dh
        f.origin.y -= dh
        w.setFrame(f, display: true)
    }

    /// Tests: the row of capture N as if the pointer were on it (its wash and its actions); nil = none.
    func testHover(_ n: Int?) { for r in rows { r.hovering = r.shot.n == n } }

    func windowWillClose(_ notification: Notification) { emit(["event": "taken_panel", "open": false]) }

    // MARK: the island's right-click menu

    /// What concerns every hanging card (HangingCards.islandMenuItems: Show, Copy All, Sort All with AI, Delete All),
    /// then "Recently Taken (N)" with each capture's actions, and "Show All…".
    static func islandMenu() -> NSMenu {
        let m = NSMenu()
        for (t, f) in hanging.islandMenuItems() { m.addItem(ClosureMenuItem(t, f)) }
        if hanging.count > 0 { m.addItem(.separator()) }
        let taken = snapper.recentlyTaken
        let head = NSMenuItem(title: Loc.t("capture.taken.menu", table: "Capture", taken.count), action: nil, keyEquivalent: "")
        if taken.isEmpty {
            m.addItem(head)                                   // (dimmed: nothing to show)
            return m
        }
        let sub = NSMenu()
        for s in taken.prefix(12) {
            let it = NSMenuItem(title: title(s), action: nil, keyEquivalent: "")
            it.image = CaptureThumb.image(s, size: NSSize(width: 30, height: 20), radius: 4)    // one tile size: titles line up
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

    /// What a row's "more" button (and its right-click) offers besides Copy: Copy Image · Copy Note · Hang Back on
    /// the Notch, then Show in Finder.
    static func moreMenu(_ s: Shot, from: (() -> NSRect?)?) -> NSMenu {
        let m = NSMenu()
        for (t, f) in actions(s, from: from).dropFirst() { m.addItem(ClosureMenuItem(t, f)) }
        if let u = s.bestURL {
            m.addItem(.separator())
            m.addItem(ClosureMenuItem(Loc.t("capture.card.reveal", table: "Capture")) { NSWorkspace.shared.activateFileViewerSelecting([u]) })
        }
        return m
    }

    /// Copy (as a click on its card) · Copy Image · Copy Note · Hang Back on the Notch — Copy first: a row's one button.
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
        if ok {
            var t = Island.Toast(text: Loc.t("capture.card.copied", table: "Capture"), actionTitle: nil, action: nil)
            t.icon = .check
            island.toast(t)
        }
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
}

/// A row of Recently Taken: its tile (drag it out again), the note, when it was taken; pointed at: Copy and "···".
final class TakenRow: NSView {
    static let height: CGFloat = 56
    let shot: Shot
    let thumb: TakenThumb
    let actions = NSStackView()
    /// keeps the Copy button's closure (BrandButton is a plain target / action button)
    private var copyRun: ClosureButton?
    /// the note ends before the actions (only while they show)
    private var beside: NSLayoutConstraint?
    /// The pointer is on it: the brand-tint wash, and its actions show (they stay in the accessibility tree anyway).
    var hovering = false {
        didSet {
            guard hovering != oldValue else { return }
            needsDisplay = true
            beside?.isActive = hovering         // the note uses the whole row until the actions show

            NSAnimationContext.runAnimationGroup { c in
                c.duration = 0.12
                actions.animator().alphaValue = hovering ? 1 : 0
            }
        }
    }

    init(_ s: Shot) {
        shot = s
        thumb = TakenThumb(s)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: s.words.map { $0.split(whereSeparator: \.isNewline).joined(separator: " ") } ?? TakenPanel.title(s))
        title.font = .systemFont(ofSize: 13, weight: s.words == nil ? .regular : .medium)
        title.lineBreakMode = .byTruncatingTail
        title.textColor = s.words == nil ? .secondaryLabelColor : .labelColor
        title.toolTip = s.words
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let detail = NSTextField(labelWithAttributedString: TakenRow.detail(s))
        detail.lineBreakMode = .byTruncatingTail
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // one primary (Copy: picture and note), the rest in "···" — shown on the row under the pointer
        let from = { [weak thumbView = thumb] () -> NSRect? in
            guard let v = thumbView, let w = v.window else { return nil }
            return w.convertToScreen(v.convert(v.bounds, to: nil))
        }
        actions.spacing = 4
        if let (t, f) = TakenPanel.actions(s, from: from).first {
            let run = ClosureButton("", f)
            let b = BrandButton(title: t, target: run, action: #selector(ClosureButton.fire))
            b.fontSize = 12
            b.hPad = 12
            b.radius = 6
            copyRun = run
            actions.addArrangedSubview(b)
        }
        let more = TakenPanel.moreMenu(s, from: from)
        let moreTitle = Loc.t("capture.taken.more", table: "Capture")
        let mb = ClosureButton("", {})
        mb.image = Look.symbol("ellipsis", moreTitle, size: 13, weight: .medium)
        mb.imagePosition = .imageOnly
        mb.isBordered = false
        mb.contentTintColor = .secondaryLabelColor
        mb.toolTip = moreTitle
        mb.setAccessibilityLabel(moreTitle)
        mb.set { [weak mb] in
            guard let b = mb else { return }
            more.popUp(positioning: nil, at: NSPoint(x: 0, y: b.bounds.height + 3), in: b)
        }
        mb.translatesAutoresizingMaskIntoConstraints = false
        mb.widthAnchor.constraint(equalToConstant: 24).isActive = true
        mb.heightAnchor.constraint(equalToConstant: 24).isActive = true
        actions.addArrangedSubview(mb)
        actions.alphaValue = 0
        actions.setHuggingPriority(.required, for: .horizontal)
        actions.setContentCompressionResistancePriority(.required, for: .horizontal)
        rowMenu = TakenPanel.moreMenu(s, from: from)
        let text = NSStackView(views: [title, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        for v in [thumb, text, actions] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        beside = actions.leadingAnchor.constraint(greaterThanOrEqualTo: text.trailingAnchor, constant: 8)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: TakenRow.height),
            thumb.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16), thumb.centerYAnchor.constraint(equalTo: centerYAnchor),
            thumb.widthAnchor.constraint(equalToConstant: TakenThumb.size.width),
            thumb.heightAnchor.constraint(equalToConstant: TakenThumb.size.height),
            text.leadingAnchor.constraint(equalTo: thumb.trailingAnchor, constant: 12), text.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            actions.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14), actions.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(TakenPanel.title(s))
    }
    required init?(coder: NSCoder) { fatalError() }

    /// "Dragged out 5 minutes ago · kept 7 more days" — the days in attention ink on the last day.
    static func detail(_ s: Shot) -> NSAttributedString {
        let ago = RelativeDateTimeFormatter()
        ago.locale = Locale(identifier: Loc.language == "zh-Hans" ? "zh-Hans" : "en")
        let now = Snapper.now
        let when = Loc.t("capture.taken.when", table: "Capture",
                         ago.localizedString(for: Date(timeIntervalSince1970: s.taken ?? now), relativeTo: Date(timeIntervalSince1970: now)))
        let days = TakenCaptures.daysLeft(taken: s.taken ?? now, now: now)
        let f = NSFont.systemFont(ofSize: 11)
        let out = NSMutableAttributedString(string: when + " · ", attributes: [.font: f, .foregroundColor: NSColor.secondaryLabelColor])
        out.append(NSAttributedString(string: Loc.plural("capture.taken.days_left", table: "Capture", count: days),
                                      attributes: [.font: f, .foregroundColor: days <= 1 ? BrandColor.attnInk : NSColor.secondaryLabelColor]))
        return out
    }

    override func draw(_ dirtyRect: NSRect) {
        guard hovering else { return }
        BrandColor.tint.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 0), xRadius: 8, yRadius: 8).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    /// the right-click menu: the same as the "more" button's
    private var rowMenu: NSMenu?
    override func menu(for event: NSEvent) -> NSMenu? { rowMenu }
}

/// The tile of a taken capture (CaptureThumb): drag it out again — the same items as a card's drag (a voice note: its
/// words).
final class TakenThumb: NSView, NSDraggingSource {
    static let size = NSSize(width: 56, height: 40)
    let shot: Shot
    private var downAt: NSPoint?
    private var cardDrag: CardDrag?

    init(_ s: Shot) {
        shot = s
        super.init(frame: .zero)
        toolTip = Loc.t("capture.taken.drag_tip", table: "Capture")
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(Loc.t("capture.taken.drag_tip", table: "Capture"))
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) { CaptureThumb.draw(shot, in: bounds, radius: 6) }
    /// The tile as the drag image.
    var image: NSImage { CaptureThumb.image(shot, size: bounds.size, radius: 6) }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with e: NSEvent) { downAt = e.locationInWindow }
    override func mouseDragged(with e: NSEvent) {
        guard let d = downAt, hypot(e.locationInWindow.x - d.x, e.locationInWindow.y - d.y) > 4 else { return }
        downAt = nil
        let drag = CardDrag(shot)            // its items follow the app under the pointer
        cardDrag = drag
        let img = image
        let items = drag.pasteboardItems().enumerated().map { i, it -> NSDraggingItem in
            let di = NSDraggingItem(pasteboardWriter: it)
            di.setDraggingFrame(i == 0 ? bounds : NSRect(x: bounds.midX, y: bounds.midY, width: 1, height: 1), contents: i == 0 ? img : nil)
            return di
        }
        emit(["event": "taken_drag", "n": shot.n, "items": items.count])
        drag.setBase(image: img, frame: bounds, in: self)
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
        // a voice note over a chat app's window: its words go into that composer, wherever it was let go of
        if let t = drag?.voiceTarget(at: p) {
            snapper.takeOutVoice(shot, fromPanel: true, landed: t, at: p, accepted: !operation.isEmpty)
            return
        }
        // taken again: its 7 days start over, and the note goes on the clipboard as after any drag-out
        if !operation.isEmpty {
            let got = drag?.delivered(at: p)
            snapper.takeOut(shot, fromPanel: true, delivered: got, noteFile: got.map { drag?.noteFile($0) ?? false } ?? false,
                            landed: DropProbe.target(at: p), at: p)
        }
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
    /// what a click does (after init: a closure that needs the button itself)
    func set(_ fn: @escaping () -> Void) { self.fn = fn }
    @objc func fire() { fn?() }
}
