// ⌥T's translation under the island (docs/design/screen-text.md §1b, 2026-10-30). The island's own line says only what
// became of it ("Translation pasted", "Copied · ⌘V to paste", "Translation copied"); the whole translation is here, to
// read and to copy again — before, the first 280 characters were pushed into the toast, which wrapped to several lines
// in uneven sizes, couldn't be clicked or copied and didn't say it was on the clipboard.
//
//  • It is the island's lower half, as the live-text panel is (docs/design/system.md §3.2 "Live-text panel"; the same
//    family, not a new pop-up): the island's black, 6 pt under it (under the hanging cards when they are down), the
//    live panel's width (IslandLayout.livePanelWidth) and corners, the system's soft shadow; no blur, no border.
//  • One text size: the live panel's 14 pt in 92 % white on 20 pt lines, up to eight lines (IslandLayout.liveTypedLines),
//    then it scrolls (an overlay scroller). Under it, on the right, Copy: a toast's quiet pill (IslandButton.quiet);
//    pressed, it says "Copied" with the ok check for a moment.
//  • It goes by itself 10 s after it shows — not while the pointer is over it: then 10 s after the pointer leaves. Esc
//    closes it only while the pointer is over it: a Carbon hotkey registered on enter and dropped on exit and on close
//    (as the hanging cards' Esc, CardReveal.holdsEsc). An Esc meant for the app in front — interrupting Claude Code,
//    closing a dialog — is never swallowed, and the card never takes the key focus. Otherwise it goes on its timer,
//    or the user copies and moves on. A dictation's live text, or the next ⌥C / ⌥T, takes its place.
//  • A non-activating panel that can't become key: a click on Copy or a scroll doesn't bring Blurt forward.
// Tests (test commands only): `textcard TEXT` (\n = a line break) shows it, `textcard state|copy|esc|close|hover on|off`.
import AppKit
import BlurtCore
import Carbon.HIToolbox

final class ScreenTextCard {
    static let shared = ScreenTextCard()
    /// how long it stays once the pointer isn't over it
    static let seconds: Double = 10
    static let gap = LiveTranscript.gap

    private var panel: NSPanel?
    private let view = ScreenTextCardView()
    private(set) var shown = false
    private(set) var text = ""
    private var hideToken = 0
    private var escHeld = false
    /// tests: `textcard hover on|off` stands in for the pointer
    private var testPointer: Bool?

    private init() {
        view.onCopy = { [weak self] in self?.copy(via: "button") }
        view.onPointer = { [weak self] inside in self?.pointer(inside: inside) }
    }

    private var pointerInside: Bool { testPointer ?? view.pointerInside }

    /// The translation: shown under the island (in place of the one before), for 10 s once the pointer isn't on it.
    func show(_ t: String) {
        let s = t.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return }
        text = s
        view.set(text: s)
        let p = ensurePanel()
        if !shown {
            shown = true
            island.wake()                   // a capsule takes the panel's width family (Island.target)
            place()
            p.alphaValue = 0
            p.orderFrontRegardless()
            island.orderFront()             // the island stays above (the card comes out from under it)
            NSAnimationContext.runAnimationGroup { c in
                c.duration = reduceMotion ? 0.12 : 0.22
                c.timingFunction = CAMediaTimingFunction(name: .easeOut)
                p.animator().alphaValue = 1
            }
        } else {
            place()
        }
        view.scrollToTop()
        // where the pointer is now (a tracking area says nothing until it moves; a closed card's last state is stale)
        view.pointerInside = p.frame.contains(NSEvent.mouseLocation)
        holdEsc(pointerInside)          // (a card that comes up under the pointer)
        later()
        emit(["event": "text_card_shown", "chars": s.count, "lines": view.lineCount, "scrolls": view.scrolls, "frame": frameDump])
    }

    /// It goes: `why` esc | timeout | new_capture | live_text | test.
    func close(why: String) {
        guard shown, let p = panel else { return }
        shown = false
        hideToken += 1
        holdEsc(false)
        testPointer = nil
        view.pointerInside = false
        island.wake()
        emit(["event": "text_card_closed", "why": why])
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = reduceMotion ? 0.12 : 0.3
            p.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self = self, !self.shown else { return }
            p.orderOut(nil)
        })
    }

    /// Copy: the translation on the clipboard again (the user copied something else meanwhile), and the button says so.
    func copy(via: String) {
        guard shown else { return }
        let pb = ScreenTextCopy.pasteboard
        pb.clearContents()
        pb.setString(text, forType: .string)
        view.showCopied()
        emit(["event": "text_card_copied", "via": via, "chars": text.count])
    }

    /// The island moved or changed size: the card follows its bottom edge; a dictation's live text takes its place.
    func islandMoved() {
        guard shown else { return }
        if LiveTranscript.shared.shown { return close(why: "live_text") }
        place()
    }

    // MARK: going by itself

    /// 10 s from now — unless the pointer is on it (then from when it leaves).
    private func later() {
        hideToken += 1
        guard !pointerInside else { return }
        let tok = hideToken
        DispatchQueue.main.asyncAfter(deadline: .now() + ScreenTextCard.seconds) { [weak self] in
            guard let self = self, tok == self.hideToken, !self.pointerInside else { return }
            self.close(why: "timeout")
        }
    }

    private func pointer(inside: Bool) {
        guard shown else { return }
        emit(["event": "text_card_pointer", "inside": inside])
        holdEsc(inside)
        later()
    }

    /// Esc is a system-wide hotkey only while the pointer is over the card (never for the whole 10 s it shows).
    private func holdEsc(_ on: Bool) {
        guard on != escHeld else { return }
        escHeld = on
        if on { registerHotkey(.translateEsc, key: kVK_Escape, mods: 0) } else { unregisterHotkey(.translateEsc) }
    }

    // MARK: the panel

    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private func ensurePanel() -> NSPanel {
        if let p = panel { return p }
        let p = Panel(contentRect: NSRect(x: 0, y: 0, width: 345, height: 80),
                      styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        p.hidesOnDeactivate = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = false
        p.becomesKeyOnlyIfNeeded = true
        p.acceptsMouseMovedEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.sharingType = chromeSharing
        p.animationBehavior = .none
        p.setAccessibilityTitle(Loc.t("capture.text.card.ax", table: "Capture"))
        p.contentView = view
        panel = p
        return p
    }

    /// Under the island, in the live panel's width (below the hanging cards when they are down).
    private func place() {
        guard let p = panel else { return }
        let isl = island.frameOnScreen
        let screen = island.screen ?? NSScreen.screens.first { $0.frame.contains(NSPoint(x: isl.midX, y: isl.midY)) } ?? NSScreen.main
        guard let s = screen else { return }
        let w = IslandLayout.livePanelWidth(islandWidth: island.restingWidth, open: island.open, screenWidth: s.frame.width)
        view.radius = IslandLayout.livePanelRadius(open: island.open, notch: island.onNotch)
        let h = view.fittingHeight(width: w)
        var top = isl.minY - ScreenTextCard.gap
        if let cards = hanging.shownBottom { top = min(top, cards - ScreenTextCard.gap) }
        let x = min(max(isl.midX - w / 2, s.frame.minX + 16), s.frame.maxX - 16 - w)
        let f = NSRect(x: x, y: top - h, width: w, height: h)
        guard p.frame != f else { return }
        let resized = p.frame.size != f.size
        p.setFrame(f, display: true)
        if resized { p.invalidateShadow() }
    }

    private var frameDump: [Double] {
        guard let p = panel else { return [] }
        let r = toCG(p.frame)
        return [r.minX, r.minY, r.width, r.height].map { Double($0) }
    }

    // MARK: tests

    /// `textcard TEXT | state | copy | esc | close | hover on|off | line pasted|unconfirmed|copied|already` — `line`
    /// puts up the island's line ⌥T would say for that outcome (a look at the two together)
    func testCommand(_ arg: String) {
        switch arg {
        case "state": break
        case let a where a.hasPrefix("line "):
            let o = ScreenTextPaste.Outcome(rawValue: String(a.dropFirst(5))) ?? .pasted
            let key = ScreenTextPaste.lineKey(o, translate: true)
            let t = ScreenTextCopy.translateConfig.target
            island.toast(o == .alreadyInTarget ? Loc.t(key, table: "Capture", Dictation.languageName(t == .auto ? .en : t))
                         : Loc.t(key, table: "Capture"), key: ScreenTextCopy.toastKey, icon: .check, seconds: 30)
        case "copy": copy(via: "test")
        case "esc": if escHeld { close(why: "esc") }        // = the Esc hotkey (registered only with the pointer on it)
        case "close": close(why: "test")
        case "hover on", "hover off":
            testPointer = arg == "hover on" ? true : nil
            pointer(inside: arg == "hover on")
        default: show(arg.replacingOccurrences(of: "\\n", with: "\n"))
        }
        emit(["event": "text_card_state", "shown": shown, "text": text, "lines": view.lineCount, "scrolls": view.scrolls, "more": view.more,
              "frame": frameDump, "esc": escHeld, "button": view.buttonTitle, "island": { let r = toCG(island.frameOnScreen)
                  return [r.minX, r.minY, r.width, r.height].map { Double($0) } }()])
    }
}

/// The card's face: the island's black, the translation in one size (14 pt, 92 % white, 20 pt lines; up to eight,
/// then it scrolls), Copy under it on the right.
final class ScreenTextCardView: NSView {
    static let font = LiveTextLines.font
    static let lineH = LiveTextLines.lineH
    static let pad = LiveTextLines.pad
    static let maxLines = IslandLayout.liveTypedLines
    /// between the text and the button row, and from the button to the right and bottom edges
    static let rowGap: CGFloat = 6
    static let buttonInset: CGFloat = 10
    /// the last line shown fades out over this much while there is more below (the live panel's "there is more")
    static let fadeH: CGFloat = 20

    var onCopy: (() -> Void)?
    var onPointer: ((Bool) -> Void)?
    /// the pointer is over the card (set by its tracking area; ScreenTextCard sets it when the card shows)
    var pointerInside = false
    var radius: CGFloat = 14 { didSet { if radius != oldValue { layer?.cornerRadius = radius } } }

    private let scroll = NSScrollView()
    private let textView = NSTextView()
    private let fade = CardFade()
    private var button: IslandButton!
    private var copiedToken = 0
    /// the text's lines at the width it was last laid out at
    private(set) var lineCount = 0

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = radius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.black.cgColor
        appearance = NSAppearance(named: .darkAqua)         // the overlay scroller's knob reads on the black

        textView.isEditable = false
        textView.isSelectable = false                       // Copy is the way (a panel that never takes the keys)
        textView.drawsBackground = false
        textView.isRichText = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.setAccessibilityRole(.staticText)
        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.scrollerKnobStyle = .light
        scroll.verticalScrollElasticity = .allowed
        addSubview(scroll)
        fade.isHidden = true
        addSubview(fade)
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification,
                                               object: scroll.contentView)

        button = IslandButton.quiet(Loc.t("capture.text.card.copy", table: "Capture")) { [weak self] in self?.onCopy?() }
        addSubview(button)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseEntered(with e: NSEvent) { pointerInside = true; onPointer?(true) }
    override func mouseExited(with e: NSEvent) { pointerInside = false; onPointer?(false) }

    var buttonTitle: String { button.title ?? "" }
    /// lines below the ones showing (the last one fades out; tests)
    var more: Bool { !fade.isHidden }

    @objc private func scrolled() { updateFade() }

    private func updateFade() {
        let below = textView.frame.height - scroll.contentView.bounds.maxY
        let on = scrolls && below > 1
        if fade.isHidden == on { fade.isHidden = !on }
    }
    /// more lines than show (it scrolls)
    var scrolls: Bool { lineCount > ScreenTextCardView.maxLines }

    private static var attributes: [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = lineH
        style.maximumLineHeight = lineH
        style.lineBreakMode = .byWordWrapping
        return [.font: font, .foregroundColor: NSColor(white: 1, alpha: 0.92), .paragraphStyle: style]
    }

    func set(text: String) {
        textView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: ScreenTextCardView.attributes))
        textView.setAccessibilityValue(text)
        resetButton()
        needsLayout = true
    }

    private var textWidth: CGFloat { max(40, bounds.width - ScreenTextCardView.pad.width * 2) }

    /// The text's lines at `width` (the card's).
    private func lines(width: CGFloat) -> Int {
        guard let lm = textView.layoutManager, let tc = textView.textContainer else { return 1 }
        tc.containerSize = NSSize(width: max(40, width - ScreenTextCardView.pad.width * 2), height: .greatestFiniteMagnitude)
        lm.ensureLayout(for: tc)
        return max(1, Int((lm.usedRect(for: tc).height / ScreenTextCardView.lineH).rounded(.up)))
    }

    func fittingHeight(width: CGFloat) -> CGFloat {
        lineCount = lines(width: width)
        let shownLines = CGFloat(min(lineCount, ScreenTextCardView.maxLines))
        return ScreenTextCardView.pad.height + shownLines * ScreenTextCardView.lineH + ScreenTextCardView.rowGap
            + button.frame.height + ScreenTextCardView.buttonInset
    }

    override func layout() {
        super.layout()
        let p = ScreenTextCardView.pad
        let textH = CGFloat(min(max(1, lineCount), ScreenTextCardView.maxLines)) * ScreenTextCardView.lineH
        // the scroll view reaches past the text's right edge: its overlay knob runs in the padding, never over words
        scroll.frame = NSRect(x: p.width, y: p.height, width: bounds.width - p.width - 4, height: textH)
        textView.textContainer?.containerSize = NSSize(width: textWidth, height: .greatestFiniteMagnitude)
        textView.frame = NSRect(x: 0, y: textView.frame.minY, width: textWidth, height: max(textH, CGFloat(lineCount) * ScreenTextCardView.lineH))
        fade.frame = NSRect(x: p.width, y: scroll.frame.maxY - ScreenTextCardView.fadeH, width: textWidth,
                            height: ScreenTextCardView.fadeH)       // (the scroller's knob, right of the text, stays clear)
        let b = button.frame.size
        button.setFrameOrigin(NSPoint(x: bounds.width - ScreenTextCardView.buttonInset - 2 - b.width,
                                      y: bounds.height - ScreenTextCardView.buttonInset - b.height))
        updateFade()
    }

    func scrollToTop() {
        layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        updateFade()
        if scrolls { scroll.flashScrollers() }       // it scrolls: the knob shows for a moment
    }

    /// Pressed: "Copied" with the ok check for a moment, then Copy again.
    func showCopied() {
        copiedToken += 1
        let tok = copiedToken
        button.title = Loc.t("capture.text.card.copied", table: "Capture")
        button.icon = .check
        button.iconColor = BrandColor.Island.ok
        resize()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            guard let self = self, tok == self.copiedToken else { return }
            self.resetButton()
        }
    }

    private func resetButton() {
        copiedToken += 1
        button.title = Loc.t("capture.text.card.copy", table: "Capture")
        button.icon = nil
        button.iconColor = nil
        resize()
    }

    private func resize() {
        button.setFrameSize(NSSize(width: button.intrinsicContentSize.width - 2, height: 24))
        needsLayout = true
    }
}

/// The bottom of the text while there is more below: the card's black over the last line, from clear to opaque — the
/// live panel's fading last line, so a cut line reads as "more", not as the end. Never takes a click or a scroll.
private final class CardFade: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirty: NSRect) {
        NSGradient(starting: NSColor(white: 0, alpha: 0), ending: NSColor(white: 0, alpha: 1))?.draw(in: bounds, angle: 90)
    }
}
