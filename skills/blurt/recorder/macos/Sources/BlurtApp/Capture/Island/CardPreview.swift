// The big view of one card (BA-62): Space on the Cards page, the eye chip on a tile, "Preview" in a card's menu, a
// used card's double-click. Its own panel, not Quick Look: the same family as the cards' other surfaces — the dark
// surface, the header row, the hairline footer — and it never needs a responder chain of its own.
//
// One floating panel, centred on the page's screen: the header row (the card's name, "3 / 7" in its section, a real
// ×), the picture at its own size or fitted to 80 % of the screen (a voice note: its words, large), then a hairline and
// the footer — the whole note with when it was taken (or used), and the keys while it has the keyboard (← → for the
// card before / after it, Space to close). ← / →, Space and Esc follow BlurtCore CardsPanelRules.previewAction; a click
// anywhere else closes it (CardsPage.watchPreview).

import AppKit
import BlurtCore

final class CardPreview: NSObject, NSWindowDelegate {
    static let pad: CGFloat = 16
    static let footerH: CGFloat = 50
    static let minWidth: CGFloat = 480

    weak var host: CardPreviewHost?             // the main window's Cards page
    private var window: PreviewPanel?
    private var header: PanelHeader?
    private let picture = NSImageView()
    private let words = NSTextField(wrappingLabelWithString: "")
    private let rule = NSBox()
    private let caption = NSTextField(wrappingLabelWithString: "")
    private let keys = KeyHintView()
    private(set) var shot: Shot?
    private var used = false

    var isOpen: Bool { window?.isVisible ?? false }
    var hasKeyboard: Bool { window?.isKeyWindow == true }
    var frame: NSRect? { isOpen ? window?.frame : nil }
    func owns(_ w: NSWindow) -> Bool { w === window }

    func close() {
        guard let w = window, w.isVisible else { return }
        w.orderOut(nil)
        shot = nil
    }

    /// "Saturday, November 21" (with the year when it isn't this one), in the app's language.
    static func day(_ d: Date, now: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Loc.locale
        let sameYear = Calendar.current.isDate(d, equalTo: now, toGranularity: .year)
        f.setLocalizedDateFormatFromTemplate(sameYear ? "EEEEMMMMd" : "yMMMMEEEEd")
        return f.string(from: d)
    }

    /// Shows `s` (card `index` of `count` in its segment) on `screen`, taking the keyboard when `keyboard`.
    func show(_ s: Shot, used: Bool, index: Int, of count: Int, on screen: NSScreen?, keyboard: Bool) {
        if window == nil { build() }
        guard let w = window, let head = header else { return }
        shot = s
        self.used = used
        head.title.stringValue = s.plainName          // "Snap · 19:03": the note itself is the footer's, whole
        head.count.stringValue = count > 1 ? Loc.number(index + 1) + " / " + Loc.number(count) : ""
        // the whole note and when; a card without one: its day, written out ("Saturday, November 21") — the header has
        // its name and time already, and the footer repeated "00:37" under "Snap · 00:37"
        let hasWords = !(s.words ?? "").isEmpty
        caption.attributedStringValue = hasWords ? CardTile.footerLine(s, used: used)
            : used ? CardTile.usedWhen(s)
            : NSAttributedString(string: CardPreview.day(Date(timeIntervalSince1970: s.wall)),
                                 attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.tertiaryLabelColor])
        let scr = screen ?? NSScreen.main ?? NSScreen.screens[0]
        let vf = scr.visibleFrame
        let p = CardPreview.pad
        // the room the picture may take: 80 % of the screen, less the header and the footer
        let maxW = (vf.width * 0.8).rounded(), maxH = (vf.height * 0.8).rounded() - PanelHeader.height - CardPreview.footerH - p - 1
        var body = NSSize(width: 420, height: 160)
        if s.kind == .shot, let img = CardPreview.image(s) {
            picture.image = img
            picture.isHidden = false
            words.isHidden = true
            let sz = img.size
            let k = min(1, (maxW - p * 2) / max(sz.width, 1), maxH / max(sz.height, 1))
            body = NSSize(width: (sz.width * k).rounded(), height: (sz.height * k).rounded())
        } else {
            picture.isHidden = true
            words.isHidden = false
            words.stringValue = s.words ?? HangingCards.statusText(s.note.status) ?? s.plainName
            let ww = min(560, maxW - p * 2)
            let h = ceil(words.sizeThatFits(NSSize(width: ww, height: maxH)).height)
            body = NSSize(width: ww, height: min(maxH, max(80, h)))
        }
        let contentW = max(CardPreview.minWidth, body.width + p * 2, KeyHint.size(KeyHint.preview).width + p * 2 + 160)
        let contentH = PanelHeader.height + body.height + p + 1 + CardPreview.footerH
        let bodyRect = NSRect(x: ((contentW - body.width) / 2).rounded(), y: CardPreview.footerH + 1 + p, width: body.width, height: body.height)
        picture.frame = bodyRect
        words.frame = bodyRect
        let size = NSSize(width: contentW, height: contentH)
        let origin = NSPoint(x: (vf.midX - size.width / 2).rounded(), y: (vf.midY - size.height / 2).rounded())
        w.setFrame(NSRect(origin: origin, size: size), display: true)
        w.title = head.title.stringValue
        w.setAccessibilityLabel(Loc.t("capture.card.preview", table: "Capture") + ", " + head.title.stringValue)
        w.orderFrontRegardless()
        if keyboard { w.makeKey() }
        updateKeys()
    }

    /// The picture at full size: the marked-up one when there is one, else the snap (the thumbnail if the file is gone).
    static func image(_ s: Shot) -> NSImage? {
        for u in [s.markedURL, s.url].compactMap({ $0 }) where FileManager.default.fileExists(atPath: u.path) {
            if let img = NSImage(contentsOf: u) {
                // the picture's own size in points (a Retina snap is 2 × its points in pixels)
                if let rep = img.representations.first, rep.pixelsWide > 0 {
                    img.size = NSSize(width: CGFloat(rep.pixelsWide) / max(s.scale, 1), height: CGFloat(rep.pixelsHigh) / max(s.scale, 1))
                }
                return img
            }
        }
        return (s.markedThumb ?? s.thumb).map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
    }

    func windowDidBecomeKey(_ notification: Notification) { updateKeys() }
    func windowDidResignKey(_ notification: Notification) { updateKeys() }

    private func updateKeys() {
        keys.items = hasKeyboard ? KeyHint.preview : []
        keys.isHidden = !hasKeyboard
    }

    /// Its keys (BlurtCore CardsPanelRules.previewAction): ← → the card before / after, Space or Esc back to the grid.
    func key(_ e: NSEvent) -> Bool {
        guard let k = CardPreview.panelKey(e) else { return false }
        switch CardsPanelRules.previewAction(k) {
        case .step(let d): host?.previewStep(d)
        case .close: host?.closePreview()
        case .none: return false
        }
        return true
    }

    /// A key event as one of the cards' keys (nil: not one of them) — the preview's and the Cards page's.
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

    private func build() {
        let w = PreviewPanel(contentRect: NSRect(x: 0, y: 0, width: CardPreview.minWidth, height: 300),
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
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.backgroundColor = BubbleBackground.surface
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { w.standardWindowButton(b)?.isHidden = true }
        let root = NSView()
        let head = PanelHeader(title: "", accessory: nil) { [weak self] in self?.host?.closePreview() }
        head.title.lineBreakMode = .byTruncatingTail
        head.title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        header = head
        picture.imageScaling = .scaleProportionallyUpOrDown
        picture.imageAlignment = .alignCenter
        picture.wantsLayer = true
        picture.layer?.cornerRadius = 8
        picture.layer?.masksToBounds = true
        picture.layer?.borderWidth = 0.5
        picture.layer?.borderColor = NSColor(white: 0.5, alpha: 0.3).cgColor
        picture.setAccessibilityLabel(Loc.t("capture.card.preview", table: "Capture"))
        words.font = .systemFont(ofSize: 17, weight: .medium)
        words.textColor = .labelColor
        words.isSelectable = true
        rule.boxType = .separator
        caption.font = .systemFont(ofSize: 12)
        caption.textColor = .secondaryLabelColor
        caption.maximumNumberOfLines = 2
        caption.lineBreakMode = .byWordWrapping
        caption.isSelectable = true
        caption.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        keys.setContentHuggingPriority(.required, for: .horizontal)
        keys.setContentCompressionResistancePriority(.required, for: .horizontal)
        for v in [head, rule, caption, keys] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false }
        for v in [head, picture, words, rule, caption, keys] as [NSView] { root.addSubview(v) }
        let p = CardPreview.pad
        NSLayoutConstraint.activate([
            head.topAnchor.constraint(equalTo: root.topAnchor),
            head.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            head.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            rule.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: p),
            rule.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -p),
            rule.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -CardPreview.footerH),
            caption.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: p),
            caption.trailingAnchor.constraint(lessThanOrEqualTo: keys.leadingAnchor, constant: -16),
            caption.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -p),
            caption.centerYAnchor.constraint(equalTo: root.bottomAnchor, constant: -CardPreview.footerH / 2),
            keys.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -p),
            keys.centerYAnchor.constraint(equalTo: caption.centerYAnchor),
            keys.heightAnchor.constraint(equalToConstant: KeyHint.capH),
        ])
        w.contentView = root
        window = w
    }
}

/// The preview's panel: it can take the keyboard, and its keys go to `onKey` first.
final class PreviewPanel: NSPanel {
    var onKey: ((NSEvent) -> Bool)?
    override var canBecomeKey: Bool { true }
    override func sendEvent(_ e: NSEvent) {
        if e.type == .keyDown, onKey?(e) == true { return }
        super.sendEvent(e)
    }
}
