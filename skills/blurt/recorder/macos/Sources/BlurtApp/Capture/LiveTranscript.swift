// The words while you talk (v0.8.6): a small dark panel under the island with the last line or two of what has been
// recognised so far — the voice note (⌥⇧V, VoiceNoteStream) and dictation (DictationStream's pieces) — the newest
// words fading in. The report: nothing to see while talking, and seeing it would help.
//
//  • Settings → General → "Show text while I talk" (边说边显示文字; record.live_text, on).
//  • It shows nothing until there are words (the island already says it is listening), follows the island's bottom
//    edge (and goes below the hanging cards when they are down), and fades away a moment after the take ends.
//  • It never takes the focus or a click (a non-activating panel that ignores the mouse), is never captured
//    (sharingType none, like the other chrome; excluded from Blurt's own recordings by process), and stays clear of
//    what you type into: when dictation's caret (Accessibility, read once at the start, read-only) is under where
//    the panel would be, it sits at the bottom of the screen instead, like subtitles.
//  • Nothing here changes what is typed or filed, or when: it only shows the pieces that were transcribed anyway.
// Tests (test commands only): `live state` reports what it shows and where; `live caret X,Y,W,H` stands in for
// dictation's caret (global top-left points), `live caret -` clears it.

import AppKit
import BlurtCore

final class LiveTranscript {
    static let shared = LiveTranscript()

    enum Source: String { case voice, dictation }

    /// "Show text while I talk" (on)
    static var enabled: Bool { recordConfig()["live_text"] as? Bool ?? true }
    static func setEnabled(_ on: Bool) { setRecordConfig("live_text", on ? nil : false) }

    static let width: CGFloat = 460
    static let gap: CGFloat = 8

    private var panel: NSPanel?
    private let view = LiveTextView()
    private var session = 0
    private var source: Source?
    private var text = ""
    private(set) var shown = false
    private var hideToken = 0
    /// where the take types (dictation's caret, global Cocoa points): the panel stays off it
    private var avoid: NSRect?
    private var bottom = false
    /// tests: `live caret …`
    var testCaret: NSRect?

    // MARK: a take

    /// A take starts listening: a new session (the words of an older one no longer land here).
    @discardableResult
    func begin(_ s: Source, avoid caret: NSRect? = nil) -> Int {
        session += 1
        source = s
        text = ""
        avoid = caret
        hideToken += 1
        view.reset()
        if shown { hide(animated: false) }
        return session
    }

    /// Dictation's caret, once it has been read (Accessibility answers off the main thread).
    func setAvoid(_ r: NSRect?, session s: Int) {
        guard s == session else { return }
        avoid = r
        emit(["event": "live_avoid", "caret": r.map { c -> [Double] in let g = toCG(c); return [g.minX, g.minY, g.width, g.height].map { Double($0) } } ?? []])
        if shown { place(animated: true) }
    }

    /// The words so far.
    func update(_ t: String, session s: Int) {
        guard s == session, LiveTranscript.enabled else { return }
        let words = t.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty, words != text else { return }
        text = words
        view.show(words, animated: !reduceMotion)
        emit(["event": "live_text", "source": source?.rawValue ?? "", "chars": words.count, "session": s])
        if !shown { show() } else { place(animated: true) }
    }

    /// The take is over: the panel goes after `after` seconds (now: at once).
    func end(session s: Int, after: Double = 0) {
        guard s == session else { return }
        hideToken += 1
        let tok = hideToken
        let go = { [weak self] in
            guard let self = self, tok == self.hideToken, s == self.session else { return }
            self.source = nil
            self.hide(animated: true)
        }
        if after > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + after, execute: go) } else { go() }
    }

    /// The island grew, shrank or moved: the panel follows its bottom edge.
    func islandMoved() { if shown { place(animated: false) } }

    // MARK: the panel

    private func ensurePanel() -> NSPanel {
        if let p = panel { return p }
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: LiveTranscript.width, height: 60),
                        styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        p.hidesOnDeactivate = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.becomesKeyOnlyIfNeeded = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.sharingType = chromeSharing
        p.animationBehavior = .none
        p.setAccessibilityTitle(Loc.t("capture.live.ax", table: "Capture"))
        p.contentView = view
        panel = p
        return p
    }

    private func show() {
        let p = ensurePanel()
        shown = true
        place(animated: false)
        p.alphaValue = 0
        p.orderFrontRegardless()
        island.orderFront()                 // the island stays above (the panel comes out from under it)
        NSAnimationContext.runAnimationGroup { c in
            c.duration = reduceMotion ? 0.12 : 0.22
            c.timingFunction = CAMediaTimingFunction(name: .easeOut)
            p.animator().alphaValue = 1
        }
        emit(["event": "live_shown", "source": source?.rawValue ?? "", "bottom": bottom, "frame": frameDump])
    }

    private func hide(animated: Bool) {
        guard shown, let p = panel else { return }
        shown = false
        emit(["event": "live_hidden", "chars": text.count])
        guard animated else { p.orderOut(nil); return }
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = reduceMotion ? 0.12 : 0.3
            p.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self = self, !self.shown else { return }
            p.orderOut(nil)
        })
    }

    /// Under the island (below the hanging cards when they are down), or at the bottom of the screen when that
    /// would cover the caret.
    private func place(animated: Bool) {
        guard let p = panel else { return }
        let isl = island.frameOnScreen
        let screen = island.screen ?? NSScreen.screens.first { $0.frame.contains(NSPoint(x: isl.midX, y: isl.midY)) } ?? NSScreen.main
        guard let s = screen else { return }
        let w = min(LiveTranscript.width, s.frame.width - 32)
        let h = view.fittingHeight(width: w)
        if view.frame.size != NSSize(width: w, height: h) { view.frame = NSRect(x: 0, y: 0, width: w, height: h) }
        var top = isl.minY - LiveTranscript.gap
        if let cards = hanging.shownBottom { top = min(top, cards - LiveTranscript.gap) }
        var f = NSRect(x: (isl.midX - w / 2).clamped(s.frame.minX + 16, s.frame.maxX - 16 - w), y: top - h, width: w, height: h)
        let caret = testCaret ?? avoid
        bottom = false
        // what is about to be typed there: the caret's line, rightwards, and the line under it (a caret is 0 wide)
        let typing = caret.map { NSRect(x: $0.minX - 8, y: $0.minY - $0.height - 4, width: 360, height: $0.height * 2 + 8) }
        if let c = typing, f.insetBy(dx: -6, dy: -10).intersects(c) {
            // the caret is up here: like subtitles, at the bottom of the screen instead
            let b = NSRect(x: f.minX, y: s.visibleFrame.minY + 28, width: w, height: h)
            if !b.insetBy(dx: -6, dy: -10).intersects(c) { f = b; bottom = true }
        }
        if p.frame != f {
            if animated && p.frame.size == f.size && abs(p.frame.minY - f.minY) < 60 && !reduceMotion {
                NSAnimationContext.runAnimationGroup { c in c.duration = 0.18; p.animator().setFrame(f, display: true) }
            } else {
                p.setFrame(f, display: true)
            }
        }
    }

    private var frameDump: [Double] {
        guard let p = panel else { return [] }
        let r = toCG(p.frame)
        return [r.minX, r.minY, r.width, r.height].map { Double($0) }
    }

    // MARK: tests

    /// `live state | caret X,Y,W,H | caret - | set on|off`
    func testCommand(_ arg: String) {
        let a = arg.split(separator: " ").map(String.init)
        switch a.first ?? "" {
        case "caret":
            let v = (a.count > 1 ? a[1] : "-").split(separator: ",").compactMap { Double($0) }
            testCaret = v.count == 4 ? toNS(CGRect(x: v[0], y: v[1], width: v[2], height: v[3])) : nil
            if shown { place(animated: false) }
        case "set":
            LiveTranscript.setEnabled(a.count > 1 ? a[1] != "off" : true)
        default: break
        }
        emit(["event": "live_state", "enabled": LiveTranscript.enabled, "shown": shown, "source": source?.rawValue ?? NSNull(),
              "text": text, "lines": view.shownLines, "bottom": bottom, "frame": frameDump, "session": session])
    }
}

private extension CGFloat {
    func clamped(_ lo: CGFloat, _ hi: CGFloat) -> CGFloat { hi < lo ? lo : Swift.min(Swift.max(self, lo), hi) }
}

/// The panel's face: a dark, slightly translucent rounded rect (a HUD blur under a black tint), the text on top.
final class LiveTextView: NSView {
    private let blur = NSVisualEffectView()
    private let tint = NSView()
    private let text = LiveTextLines()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor(white: 1, alpha: 0.10).cgColor
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.appearance = NSAppearance(named: .darkAqua)
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor(white: 0, alpha: 0.62).cgColor
        for v in [blur, tint, text] as [NSView] {
            v.frame = bounds
            v.autoresizingMask = [.width, .height]
            addSubview(v)
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// the lines drawn now (tests)
    var shownLines: [String] { text.lines }
    func reset() { text.reset() }
    func fittingHeight(width: CGFloat) -> CGFloat { text.fittingHeight(width: width) }
    func show(_ t: String, animated: Bool) { text.show(t, animated: animated) }
}

/// The last two lines of the text, the older one dimmer; the words new since the last update fade in.
final class LiveTextLines: NSView {
    static let font = NSFont.systemFont(ofSize: 14, weight: .regular)
    static let pad = NSSize(width: 16, height: 10)
    static let lineH: CGFloat = 20

    private var text = ""
    /// characters of `text` that were already showing (the rest fades in)
    private var stable = 0
    private var fade: CGFloat = 1
    private var fadeStart: CFTimeInterval = 0
    private var timer: Timer?
    private(set) var lines: [String] = []

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var allowsVibrancy: Bool { false }

    func reset() {
        text = ""; stable = 0; fade = 1; lines = []
        timer?.invalidate(); timer = nil
        needsDisplay = true
    }

    /// One line when it fits on one, else two.
    func fittingHeight(width: CGFloat) -> CGFloat {
        let n = max(1, min(2, layout(width: width).count))
        return LiveTextLines.pad.height * 2 + CGFloat(n) * LiveTextLines.lineH
    }

    func show(_ t: String, animated: Bool) {
        // what was there stays; what is new fades in (a rewrite — a hard cut's overlap dropped — fades in whole)
        stable = t.hasPrefix(text) ? (text as NSString).length : 0
        text = t
        fade = animated ? 0 : 1
        fadeStart = CACurrentMediaTime()
        timer?.invalidate()
        timer = nil
        if animated {
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] tm in
                guard let self = self else { return tm.invalidate() }
                let k = min(1, (CACurrentMediaTime() - self.fadeStart) / 0.45)
                self.fade = CGFloat(1 - pow(1 - k, 3))
                self.needsDisplay = true
                if k >= 1 { tm.invalidate(); self.timer = nil }
            }
        }
        needsDisplay = true
    }

    /// The text's lines at this width — the tail only (two lines never need more than the last few hundred
    /// characters) — as (range in `text`, the line).
    private func layout(width: CGFloat) -> [(NSRange, String)] {
        // the island ticks this every frame while it moves: the same text at the same width is laid out once
        if let c = cached, c.text == text, c.width == width { return c.lines }
        let out = layoutTail(width: width)
        cached = (text, width, out)
        return out
    }
    private var cached: (text: String, width: CGFloat, lines: [(NSRange, String)])?

    private func layoutTail(width: CGFloat) -> [(NSRange, String)] {
        let ns = text as NSString
        guard ns.length > 0 else { return [] }
        let from = max(0, ns.length - 320)
        let tail = ns.substring(from: from)
        let storage = NSTextStorage(string: tail, attributes: [.font: LiveTextLines.font])
        let lm = NSLayoutManager()
        let tc = NSTextContainer(size: NSSize(width: max(40, width - LiveTextLines.pad.width * 2), height: .greatestFiniteMagnitude))
        tc.lineFragmentPadding = 0
        lm.addTextContainer(tc)
        storage.addLayoutManager(lm)
        var out: [(NSRange, String)] = []
        var g = 0
        let glyphs = lm.numberOfGlyphs
        while g < glyphs {
            var r = NSRange()
            _ = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: &r)
            let cr = lm.characterRange(forGlyphRange: r, actualGlyphRange: nil)
            let line = (tail as NSString).substring(with: cr).trimmingCharacters(in: .newlines)
            out.append((NSRange(location: cr.location + from, length: cr.length), line))
            g = max(g + 1, NSMaxRange(r))
        }
        return out
    }

    override func draw(_ dirty: NSRect) {
        let shown = Array(layout(width: bounds.width).suffix(2))
        lines = shown.map(\.1)
        let ink = NSColor(white: 1, alpha: 0.93), dim = NSColor(white: 1, alpha: 0.5)
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byClipping
        for (i, (range, line)) in shown.enumerated() {
            // the line before the last is dimmer where it was already showing; the newest words are bright, fading in
            let base = i == shown.count - 1 ? ink : dim
            let s = NSMutableAttributedString(string: line, attributes: [.font: LiveTextLines.font, .foregroundColor: base,
                                                                         .paragraphStyle: style])
            let len = (line as NSString).length
            let newFrom = max(0, stable - range.location)       // what is new on this line since the last update
            if newFrom < len {
                s.addAttribute(.foregroundColor, value: ink.withAlphaComponent(ink.alphaComponent * fade),
                               range: NSRange(location: newFrom, length: len - newFrom))
            }
            let y = LiveTextLines.pad.height + CGFloat(i) * LiveTextLines.lineH + 1
            s.draw(with: NSRect(x: LiveTextLines.pad.width, y: y, width: bounds.width - LiveTextLines.pad.width * 2, height: LiveTextLines.lineH),
                   options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }
}
