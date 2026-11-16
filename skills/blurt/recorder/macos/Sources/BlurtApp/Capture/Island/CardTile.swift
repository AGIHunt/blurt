// A card's tile (v0.9.2; one look for a set of cards since v1.0.7, BA-62): the Cards page's grid
// (MainWindow/CardsPage.swift) — Current, the cards under the notch, and History, the ones used in other apps. Its
// picture cropped from the top-left on the card's opaque surface (a voice note: its words), its note under it in 13 pt
// medium, up to two lines of whole words (never an "…"); a used card on its last day says so in attention ink. The
// tile under the pointer gets a neutral wash and the actions in its top-right corner ([eye][···][Copy], CardActions);
// a selected one the wash, and with the keyboard on the grid the accent ring. It reports to its host (CardTileHost):
// a click, the menu, the preview, a copy, a drag.
//
// A drag takes the card out into any app (CardDrag: its items follow the app under the pointer; a voice card over a
// chat app pastes its words) — or, when the tile is part of a selection of several, the whole selection as one drag
// (the stack image with the system's count, as the cards under the notch do), a current one also onto a project in
// the island.

import AppKit
import BlurtCore

/// Who a card's tile reports to (the Cards page).
protocol CardTileHost: AnyObject {
    /// the pointer came onto the tile, or left it
    func pointed(_ t: CardTile, _ on: Bool)
    /// a click (`count` 2: a double-click), with the modifier keys held (⌘ toggles it in the selection, ⇧ a range)
    func clicked(_ t: CardTile, count: Int, modifiers: NSEvent.ModifierFlags)
    /// the tile's Copy chip, its VoiceOver press, its menu's copies
    func copy(_ t: CardTile, _ what: HangingCards.Copy)
    /// right-click and "···"
    func menu(for t: CardTile) -> NSMenu
    /// the eye chip
    func openPreview(_ t: CardTile, via: String)
    /// what a drag of this tile takes: its card, or the selection it is part of (in the order they show)
    func dragGroup(for t: CardTile) -> [CardTile]
    func dragStarted()
    func dragEnded()
}

/// One card of the grid: its picture (or a voice note's words), its note under it; pointed at, the wash and its
/// actions (the eye, "···", Copy).
final class CardTile: NSView, NSDraggingSource {
    /// the smallest picture a tile has (BlurtCore CardsPageRules.tileWidth × tileHeight)
    static let panelSize = CGSize(width: CardsPageRules.tileWidth, height: CardsPageRules.tileHeight)

    let shot: Shot
    /// a used card (dragged out or pasted, Snapper.recentlyTaken): its menu, its drag and its double-click differ
    let used: Bool
    /// its picture's size: at least 148 × 100 (panelSize), widened to fill the page's column
    let box: CGSize
    private weak var host: CardTileHost?
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
    /// the cards this tile's drag carries (itself, or the selection it is part of)
    private var dragShots: [Shot] = []

    /// a selected tile (a click, ⌘ / ⇧-click, the arrows): the wash; with the keyboard on the grid, the accent ring too
    var selected = false { didSet { restate() } }
    /// the keyboard's card (with the keyboard on the grid its actions show, as under the pointer)
    var focused = false { didSet { restate() } }
    var keyboard = false { didSet { restate() } }
    var hovering = false { didSet { if hovering != oldValue { restate(); host?.pointed(self, hovering) } } }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var needsPanelToBecomeKey: Bool { true }

    /// Its picture on screen (Cocoa coordinates): where a card put back flies up from, the tests' rects.
    var faceOnScreen: NSRect? {
        guard let w = window else { return nil }
        return w.convertToScreen(convert(NSRect(origin: .zero, size: box), to: nil))
    }

    init(_ s: Shot, host: CardTileHost, used: Bool = false, size: CGSize = CardTile.panelSize) {
        shot = s
        self.used = used
        self.host = host
        box = size
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        let sz = box
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
                    face.contents = CardTile.topLeading(t, box: sz)
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
        // its type, when the note gave it one (CardKindMark): a voice tile's before its mic, a snap's on the picture's
        // bottom-left corner (the top right is the actions')
        if let k = CardKindMark.tileView(s, voice: s.kind == .voice) {
            k.frame = s.kind == .voice ? NSRect(x: sz.width - 18 - 14, y: sz.height - 17, width: 10, height: 10)
                : NSRect(x: 6, y: sz.height - 6 - 16, width: HangingCards.badgeWidth(1), height: 16)
            addSubview(k)
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
        if let note = CardTile.note(s) {
            let band = CardBand.clamp(note) { CardTile.lineWidths($0, font: f, width: textW).count <= 2 }
            let widths = CardTile.lineWidths(band.text, font: f, width: textW)
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
            let days = TakenCaptures.daysLeft(taken: t, now: Snapper.now, days: Snapper.historyDays)
            if TakenCaptures.showsDaysLeft(days), let days {
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
        actions = CardActions(menu: { [weak self] in self.flatMap { $0.host?.menu(for: $0) } },
                              copy: { [weak self] in if let self { self.host?.copy(self, .click) } },
                              preview: { [weak self] in if let self { self.host?.openPreview(self, via: "chip") } })
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
        let sz = box, fit = actions.fittingSize
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
        let show = hovering || (focused && keyboard)
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

    override func accessibilityPerformPress() -> Bool { host?.copy(self, .click); return true }

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

    /// "Used 5 min ago", and "· kept 1 more day" in attention ink on its last day (History's heading says how long
    /// once for all).
    static func usedWhen(_ s: Shot) -> NSAttributedString {
        let now = Snapper.now
        // the cards' one relative time (CardTime): "Just now", "4 min ago" — never a live count of seconds
        var ago = CardTime.ago(s.taken ?? now, now: now)
        if Loc.language != "zh-Hans" { ago = ago.prefix(1).lowercased() + ago.dropFirst() }
        let f = NSFont.systemFont(ofSize: 11)
        let out = NSMutableAttributedString(string: Loc.t("capture.cards.history_when", table: "Capture", ago),
                                            attributes: [.font: f, .foregroundColor: NSColor.tertiaryLabelColor])
        let left = TakenCaptures.daysLeft(taken: s.taken ?? now, now: now, days: Snapper.historyDays)
        guard TakenCaptures.showsDaysLeft(left), let days = left else { return out }
        out.append(NSAttributedString(string: " · ", attributes: [.font: f, .foregroundColor: NSColor.tertiaryLabelColor]))
        out.append(NSAttributedString(string: Loc.plural("capture.taken.days_left", table: "Capture", count: days),
                                      attributes: [.font: f, .foregroundColor: BrandColor.attnInk]))
        return out
    }

    /// "✓ Copied" over the tile for a moment: the done pill (the ok check), as on a card on its thread.
    func flashCopied() {
        let tw = ceil(copiedText.frame.width)
        let w = 12 + 11 + 4 + tw + 12
        copiedPill.frame = NSRect(x: (box.width - w) / 2, y: (box.height - 22) / 2, width: w, height: 22)
        copiedCheck.frame = NSRect(x: 12, y: 5.5, width: 11, height: 11)
        copiedText.frame = NSRect(x: 12 + 11 + 4 - 2, y: (22 - copiedText.frame.height) / 2, width: tw, height: copiedText.frame.height)
        copiedPill.isHidden = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.copiedPill.isHidden = true }
    }

    override func mouseDown(with e: NSEvent) { downAt = e.locationInWindow }

    override func mouseUp(with e: NSEvent) {
        defer { downAt = nil }
        guard downAt != nil, bounds.contains(convert(e.locationInWindow, from: nil)) else { return }
        host?.clicked(self, count: e.clickCount, modifiers: e.modifierFlags)
    }

    override func rightMouseDown(with e: NSEvent) {
        guard let m = host?.menu(for: self) else { return }
        m.popUp(positioning: nil, at: convert(e.locationInWindow, from: nil), in: self)
    }

    /// Its picture as a drag shows it: the snap's thumbnail, or the tile as drawn (a voice note's words).
    func dragPicture() -> NSBitmapImageRep? {
        if let cg = shot.kind == .shot ? shot.markedThumb ?? shot.thumb : nil { return NSBitmapImageRep(cgImage: cg) }
        guard let rep = bitmapImageRepForCachingDisplay(in: NSRect(origin: .zero, size: box)) else { return nil }
        cacheDisplay(in: NSRect(origin: .zero, size: box), to: rep)
        return rep
    }

    override func mouseDragged(with e: NSEvent) {
        guard let d = downAt, hypot(e.locationInWindow.x - d.x, e.locationInWindow.y - d.y) > 4 else { return }
        downAt = nil
        // the selection it is part of goes with it (in the order the cards show); any other tile goes alone
        let group = host?.dragGroup(for: self) ?? [self]
        if group.count == 1, shot.kind == .voice, shot.copyText == nil { snapper.wantWords(shot); return }     // its words aren't here yet
        let shots = group.map(\.shot).filter { $0.kind != .voice || $0.copyText != nil }
        guard !shots.isEmpty else { return }
        host?.dragStarted()
        dragShots = shots
        let drag = CardDrag(shots)           // its items follow the app under the pointer
        cardDrag = drag
        var img = NSImage(size: box)
        if let rep = dragPicture() { img.addRepresentation(rep) }
        var frame = NSRect(origin: .zero, size: box)
        if group.count > 1 {
            // a stack: this tile on top, up to two more behind it; the system draws the count
            let (stack, f) = HangingCards.stackImage(top: img, others: group.filter { $0 !== self }.prefix(2).compactMap { $0.dragPicture() },
                                                     count: group.count, frame: frame)
            img = stack
            frame = f
        }
        let items = drag.pasteboardItems().enumerated().map { i, it -> NSDraggingItem in
            let di = NSDraggingItem(pasteboardWriter: it)
            di.setDraggingFrame(i == 0 ? frame : NSRect(x: frame.midX, y: frame.midY, width: 1, height: 1), contents: i == 0 ? img : nil)
            return di
        }
        emit(["event": used ? "taken_drag" : "page_drag", "n": shots.map(\.n), "items": items.count])
        drag.setBase(image: img, frame: frame, in: self)
        if !onlyUsed { island.dragBegan() }     // a project in the island can take hanging cards, as from the row
        let session = beginDraggingSession(with: items, event: e, source: self)
        session.draggingFormation = .none
        session.animatesToStartingPositionsOnCancelOrFail = true
        drag.session = session
    }

    /// every card the drag carries is a used one (History): nothing of it can be filed in the island
    private var onlyUsed: Bool { dragShots.allSatisfy { $0.taken != nil } }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? (dragShots.contains { $0.ref != nil } ? [.copy] : [.copy, .generic]) : (onlyUsed ? [] : [.generic, .move])
    }

    func draggingSession(_ session: NSDraggingSession, movedTo p: NSPoint) {
        cardDrag?.moved(to: p)
        if !onlyUsed { island.dragMoved(to: p) }
    }

    func draggingSession(_ session: NSDraggingSession, endedAt p: NSPoint, operation: NSDragOperation) {
        let drag = cardDrag, shots = dragShots, used = onlyUsed
        cardDrag = nil
        dragShots = []
        let host = self.host
        defer { host?.dragEnded() }        // (the grid follows the cards again once this tile is done with)
        let filed = used ? false : island.dragEnded(at: p)
        emit(["event": used ? "taken_drag_end" : "page_drag_end", "n": shots.map(\.n), "operation": Int(operation.rawValue), "filed": filed])
        guard !filed, !CardTile.ourWindow(at: p), !shots.isEmpty else { return }
        // one voice note over a chat app's window: its words go into that composer, wherever it was let go of
        if shots.count == 1, let t = drag?.voiceTarget(at: p) {
            snapper.takeOutVoice(shots[0], fromPanel: shots[0].taken != nil, landed: t, at: p, accepted: !operation.isEmpty,
                                 wordsWithheld: drag?.wordsWithheld(at: t) ?? false)
            return
        }
        // taken by another app: a hanging card leaves its thread ("Dragged out · Undo"); a used one is used again (its
        // days in History start over, and the note goes on the clipboard as after any drag-out)
        guard !operation.isEmpty else { return }
        let got = drag?.delivered(at: p)
        let noteFile = got.map { drag?.noteFile($0) ?? false } ?? false
        if shots.count == 1 {
            snapper.takeOut(shots[0], fromPanel: shots[0].taken != nil, delivered: got, noteFile: noteFile, landed: DropProbe.target(at: p), at: p)
        } else {
            snapper.takeOut(shots, delivered: got, noteFile: noteFile, landed: DropProbe.target(at: p), at: p)
        }
    }

    /// The window under a screen point is one of ours (the main window, a note, the preview): not "used in another
    /// app".
    static func ourWindow(at p: NSPoint) -> Bool {
        let n = NSWindow.windowNumber(at: p, belowWindowWithWindowNumber: 0)
        return n > 0 && NSApp.windows.contains { $0.windowNumber == n && !($0 is CardsPanel) }   // (the cards take no drops)
    }
}
