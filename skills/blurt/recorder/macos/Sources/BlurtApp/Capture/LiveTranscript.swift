// The words while you talk (v0.8.6): a panel under the island with the last lines (up to three, newest at
// the bottom) of what has been recognised so far — the voice note (⌥⇧V, VoiceNoteStream) and dictation
// (DictationStream) — the newest words fading in. The report: nothing to see while talking, and seeing it would help.
//  • Dictation keeps up with the speech (v0.9, docs/design/dictation.md §Live text): after the finished pieces'
//    transcripts (committed, 92 % white) comes the piece still being said, decoded about once a second (pending,
//    60 %: provisional until its piece's own transcript replaces it). Seeing it is how the user decides between
//    fixing it by hand and double-tapping to send. A take's panel doesn't jump: it keeps the height it reached, and
//    the lines showing aren't re-wrapped as the text grows (LiveTextLines' anchor). When the take stops and its text
//    goes in, the panel shows that text — the polished or structured version actually typed, not the transcript —
//    for about 1.5 s (`showTyped`), the caret after the words turned into the ok check (it is in): the moment to check
//    before a double tap sends it. When there is text above the top line, that line's start fades in from the left
//    edge, so a line that begins mid-sentence reads as continued, not cut.
//
//  • It is the island's lower half, not a second pop-up (v0.9 dogfood: a 460 pt grey glass card under a 297 pt black
//    notch read as two unrelated things): the island's own black, 6 pt under it, in its width family — exactly the
//    open island's width under a voice note, the ears plus 24 pt a side while dictation listens (IslandLayout
//    .livePanelWidth, from the width the island is settling to without a toast, so the words don't re-wrap while it
//    springs or while a toast grows it) — with the window's own soft shadow, which keeps its edge on a dark
//    wallpaper. On a capsule screen the capsule widens to the same family while the panel shows (15 pt corners).
//  • Settings → General → "Show text while I talk" (边说边显示文字; record.live_text, on).
//  • It shows nothing until there are words (the island already says it is listening), follows the island's bottom
//    edge (and goes below the hanging cards when they are down), and fades away a moment after the take ends.
//  • It never takes the focus or a click (a non-activating panel that ignores the mouse), is never captured
//    (sharingType none, like the other chrome; excluded from Blurt's own recordings by process), and stays clear of
//    what you type into: when dictation's caret (Accessibility, read once at the start, read-only) is under where
//    the panel would be, it sits at the bottom of the screen instead, like subtitles.
//  • Nothing here changes what is typed or filed, or when: it only shows the pieces that were transcribed anyway.
// Tests (test commands only): `live state` reports what it shows and where; `live caret X,Y,W,H` stands in for
// dictation's caret (global top-left points), `live caret -` clears it; `live show COMMITTED|PENDING` puts words up.

import AppKit
import BlurtCore

final class LiveTranscript {
    static let shared = LiveTranscript()

    enum Source: String { case voice, dictation }

    /// "Show text while I talk" (on)
    static var enabled: Bool { recordConfig()["live_text"] as? Bool ?? true }
    static func setEnabled(_ on: Bool) { setRecordConfig("live_text", on ? nil : false) }

    static let gap: CGFloat = 6

    private var panel: NSPanel?
    private let view = LiveTextView()
    private var session = 0
    private var source: Source?
    private var text = ""
    private var pending = ""
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
        pending = ""
        avoid = caret
        hideToken += 1
        view.reset()
        view.setListening(true)
        view.setTyped(false)
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

    /// The words so far: `committed` (transcribed pieces) then `pending` (dictation's piece still being said,
    /// provisional — shown quieter).
    func update(_ committed: String, pending p: String = "", session s: Int) {
        guard s == session, LiveTranscript.enabled else { return }
        var c = String(committed.drop { $0.isWhitespace || $0.isNewline })
        var q = c.isEmpty ? String(p.drop { $0.isWhitespace || $0.isNewline }) : p
        q = String(q.reversed().drop { $0.isWhitespace || $0.isNewline }.reversed())
        if q.isEmpty { c = c.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !(c + q).isEmpty, c != text || q != pending else { return }
        text = c
        pending = q
        view.show(committed: c, pending: q, animated: !reduceMotion)
        emit(["event": "live_text", "source": source?.rawValue ?? "", "chars": c.count + q.count, "pending": q.count,
              "session": s])
        if !shown { show() } else { place(animated: true) }
    }

    /// Dictation's text went in: the panel shows what was actually typed (polished, structured — what a double tap
    /// now sends) in place of the transcript, for `seconds`, then goes. Only while it is still this take's panel.
    func showTyped(_ typed: String, session s: Int, seconds: Double) {
        guard s == session, LiveTranscript.enabled else { return }
        let t = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return end(session: s) }
        view.setListening(false)
        view.setTyped(true)
        if t != text || !pending.isEmpty {
            text = t
            pending = ""
            view.show(committed: t, pending: "", animated: !reduceMotion)
        }
        emit(["event": "live_typed", "chars": t.count, "session": s, "seconds": seconds])
        if !shown { show() } else { place(animated: true) }
        end(session: s, after: seconds)
    }

    /// The take is over: the panel goes after `after` seconds (now: at once).
    func end(session s: Int, after: Double = 0) {
        guard s == session else { return }
        view.setListening(false)            // the line is committed: the caret goes
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
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 345, height: 60),
                        styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        p.hidesOnDeactivate = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true              // the system's soft shadow round the black shape: its edge on any wallpaper
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
        island.wake()                       // a capsule widens to the panel's width family (Island.target)
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
        island.wake()                       // a capsule goes back to its ears' width
        emit(["event": "live_hidden", "chars": text.count + pending.count])
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
        let w = IslandLayout.livePanelWidth(islandWidth: island.restingWidth, open: island.open, screenWidth: s.frame.width)
        let h = view.fittingHeight(width: w)
        view.radius = IslandLayout.livePanelRadius(open: island.open, notch: island.onNotch)
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
            let resized = p.frame.size != f.size
            if animated && !resized && abs(p.frame.minY - f.minY) < 60 && !reduceMotion {
                NSAnimationContext.runAnimationGroup { c in c.duration = 0.18; p.animator().setFrame(f, display: true) }
            } else {
                p.setFrame(f, display: true)
            }
            if resized { p.invalidateShadow() }
        }
    }

    private var frameDump: [Double] {
        guard let p = panel else { return [] }
        let r = toCG(p.frame)
        return [r.minX, r.minY, r.width, r.height].map { Double($0) }
    }

    // MARK: tests

    /// `live state | caret X,Y,W,H | caret - | set on|off | show TEXT[|PENDING] | end` — `show` puts TEXT up as a
    /// listening voice note's words would (a take begins if none is on; no microphone), PENDING after it as
    /// dictation's provisional words; `end` commits it (the caret goes, the panel goes 1.5 s later).
    func testCommand(_ arg: String) {
        let a = arg.split(separator: " ").map(String.init)
        switch a.first ?? "" {
        case "show":
            if source == nil { begin(.voice) }
            let parts = String(arg.dropFirst(4)).trimmingCharacters(in: .whitespaces).split(separator: "|", maxSplits: 1,
                                                                                          omittingEmptySubsequences: false)
            update(String(parts.first ?? ""), pending: parts.count > 1 ? String(parts[1]) : "", session: session)
        case "end":
            end(session: session, after: 1.5)
        case "caret":
            let v = (a.count > 1 ? a[1] : "-").split(separator: ",").compactMap { Double($0) }
            testCaret = v.count == 4 ? toNS(CGRect(x: v[0], y: v[1], width: v[2], height: v[3])) : nil
            if shown { place(animated: false) }
        case "set":
            LiveTranscript.setEnabled(a.count > 1 ? a[1] != "off" : true)
        default: break
        }
        emit(["event": "live_state", "enabled": LiveTranscript.enabled, "shown": shown, "source": source?.rawValue ?? NSNull(),
              "text": text, "pending": pending, "lines": view.shownLines, "bottom": bottom, "frame": frameDump,
              "typed": view.typed, "continued": view.continued,
              "session": session])
    }
}

private extension CGFloat {
    func clamped(_ lo: CGFloat, _ hi: CGFloat) -> CGFloat { hi < lo ? lo : Swift.min(Swift.max(self, lo), hi) }
}

/// The panel's face: the island's own black (#000), rounded like the island's bottom corners, the
/// text on top — neutral white (92 % committed, 60 % pending) and a flat mint caret after the words while the take
/// listens. No blur, no border, no rule or underline: it is the island's lower half, and the island's level bars
/// already say blurt is hearing.
final class LiveTextView: NSView {
    private let text = LiveTextLines()
    var radius: CGFloat = 14 { didSet { if radius != oldValue { layer?.cornerRadius = radius } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = radius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.black.cgColor
        text.frame = bounds
        text.autoresizingMask = [.width, .height]
        addSubview(text)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The take listens (the caret shows) or its line has committed (the caret goes).
    func setListening(_ on: Bool) {
        text.listening = on
    }
    /// The text shown is what was typed (the check after it).
    func setTyped(_ on: Bool) { text.typed = on }
    var typed: Bool { text.typed }
    /// the top line continues text above it (its start fades in)
    var continued: Bool { text.continued }

    /// the lines drawn now (tests)
    var shownLines: [String] { text.lines }
    func reset() { text.reset() }
    func fittingHeight(width: CGFloat) -> CGFloat { text.fittingHeight(width: width) }
    func show(committed: String, pending: String, animated: Bool) { text.show(committed: committed, pending: pending, animated: animated) }
}

/// The last three lines of the text, newest at the bottom: the committed words 92 % white, the pending ones (the piece
/// still being said, provisional) 60 %; the words new since the last update fade in. No jumping: the lines are laid
/// out from a line start that only moves forward (a long take doesn't re-wrap what is showing), and the panel keeps
/// the height it reached during the take.
final class LiveTextLines: NSView {
    static let font = NSFont.systemFont(ofSize: 14, weight: .regular)
    static let pad = NSSize(width: 16, height: 10)
    static let lineH: CGFloat = 20
    static let maxLines = 3

    private var text = ""
    /// where the pending words start in `text` (UTF-16; = its length when everything is committed)
    private var pendingFrom = 0
    /// characters of `text` that were already showing (the rest fades in)
    private var stable = 0
    private var fade: CGFloat = 1
    private var fadeStart: CFTimeInterval = 0
    private var timer: Timer?
    /// the layout starts here (UTF-16, a line start of an earlier layout) while the text before it stays the same
    private var anchor = 0
    private var anchorPrefix = ""
    /// the most lines shown this take: the panel never shrinks back while it is up
    private var tallest = 1
    private(set) var lines: [String] = []
    /// the lines' pending part (tests)
    private(set) var pendingText = ""
    /// the take listens: a flat 2 pt mint caret after the last word (steady: the island's level moves)
    var listening = false { didSet { if listening != oldValue { needsDisplay = true } } }
    /// the text is what was typed: the ok check after the last word, where the caret was
    var typed = false { didSet { if typed != oldValue { needsDisplay = true } } }
    /// there is text above the top line shown (tests)
    private(set) var continued = false
    /// the top line's start fades in over this much when it continues text above
    static let continueFade: CGFloat = 28

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var allowsVibrancy: Bool { false }

    func reset() {
        text = ""; pendingFrom = 0; stable = 0; fade = 1; lines = []; pendingText = ""
        anchor = 0; anchorPrefix = ""; tallest = 1; cached = nil
        timer?.invalidate(); timer = nil
        needsDisplay = true
    }

    /// As many lines as the text needs, up to three — and never fewer than this take already showed.
    func fittingHeight(width: CGFloat) -> CGFloat {
        tallest = max(tallest, min(LiveTextLines.maxLines, max(1, layout(width: width).count)))
        return LiveTextLines.pad.height * 2 + CGFloat(tallest) * LiveTextLines.lineH
    }

    /// `committed` then `pending` (provisional: the piece still being said).
    func show(committed: String, pending: String, animated: Bool) {
        let t = committed + pending
        let old = text as NSString, new = t as NSString
        // what was there stays; only what changed fades in (a revision of the pending words, a rewrite at a seam)
        var common = 0
        let n = min(old.length, new.length)
        while common < n, old.character(at: common) == new.character(at: common) { common += 1 }
        stable = common
        text = t
        pendingFrom = (committed as NSString).length
        pendingText = pending
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

    /// The text's lines at this width from the anchor on, as (range in `text`, the line).
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
        // the text before the anchor changed (a seam rewritten, a new take): start over near the end
        if anchor > ns.length || !text.hasPrefix(anchorPrefix) {
            anchor = max(0, ns.length - 240)
            anchorPrefix = ns.substring(to: anchor)
        }
        var out = lineRanges(ns, from: anchor, width: width)
        // more lines than show: the anchor moves to a line start above the visible ones, where the next layout
        // breaks exactly as this one did
        if out.count > LiveTextLines.maxLines + 2 {
            anchor = out[out.count - LiveTextLines.maxLines - 1].0.location
            anchorPrefix = ns.substring(to: anchor)
            out = Array(out.suffix(LiveTextLines.maxLines + 1))
        }
        return out
    }

    private func lineRanges(_ ns: NSString, from: Int, width: CGFloat) -> [(NSRange, String)] {
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
        let all = layout(width: bounds.width)
        let shown = Array(all.suffix(LiveTextLines.maxLines))
        lines = shown.map(\.1)
        continued = (shown.first?.0.location ?? 0) > 0
        let ink = NSColor(white: 1, alpha: 0.92), dim = NSColor(white: 1, alpha: 0.6)      // neutral, never brand
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byClipping
        let rows = max(shown.count, Int((bounds.height - LiveTextLines.pad.height * 2) / LiveTextLines.lineH + 0.5))
        let room = bounds.width - LiveTextLines.pad.width * 2
        for (i, (range, line)) in shown.enumerated() {
            let s = NSMutableAttributedString(string: line, attributes: [.font: LiveTextLines.font, .foregroundColor: ink,
                                                                         .paragraphStyle: style])
            let len = (line as NSString).length
            // the pending words (the piece still being said) are quieter until their piece is final
            let pendingAt = min(len, max(0, pendingFrom - range.location))
            if pendingAt < len { s.addAttribute(.foregroundColor, value: dim, range: NSRange(location: pendingAt, length: len - pendingAt)) }
            // what is new on this line since the last update fades in, in its own tone
            let newFrom = min(len, max(0, stable - range.location))
            if newFrom < len, fade < 1 {
                s.enumerateAttribute(.foregroundColor, in: NSRange(location: newFrom, length: len - newFrom)) { v, r, _ in
                    guard let c = v as? NSColor else { return }
                    s.addAttribute(.foregroundColor, value: c.withAlphaComponent(c.alphaComponent * fade), range: r)
                }
            }
            // newest at the bottom: a take that showed more lines before keeps them in place from below
            let row = rows - shown.count + i
            let y = LiveTextLines.pad.height + CGFloat(row) * LiveTextLines.lineH + 1
            s.draw(with: NSRect(x: LiveTextLines.pad.width, y: y, width: room, height: LiveTextLines.lineH),
                   options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            // a top line that continues text above: its start fades in from the edge (it doesn't look cut off)
            if i == 0, continued, let ctx = NSGraphicsContext.current,
               let g = NSGradient(starting: NSColor(white: 0, alpha: 1), ending: NSColor(white: 0, alpha: 0)) {
                ctx.saveGraphicsState()
                ctx.compositingOperation = .destinationOut
                g.draw(in: NSRect(x: LiveTextLines.pad.width - 1, y: y - 1, width: LiveTextLines.continueFade, height: LiveTextLines.lineH),
                       angle: 0)
                ctx.restoreGraphicsState()
            }
            if (listening || typed) && i == shown.count - 1 {
                let tw = min(room, ceil(s.size().width))
                if listening {
                    BrandColor.Island.fill.setFill()
                    NSBezierPath(roundedRect: NSRect(x: LiveTextLines.pad.width + tw + 1.5, y: y + 1, width: 2, height: LiveTextLines.lineH - 3),
                                 xRadius: 1, yRadius: 1).fill()
                } else if let c = LiveTextLines.check {
                    // typed: the ok check (the design system's done shape), where the caret was
                    let x = min(LiveTextLines.pad.width + tw + 5, bounds.width - LiveTextLines.pad.width / 2 - c.size.width)
                    c.draw(in: NSRect(x: x, y: y + (LiveTextLines.lineH - c.size.height) / 2 - 1, width: c.size.width, height: c.size.height),
                           from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                }
            }
        }
    }

    /// SF checkmark, 11 pt semibold, in the island's ok.
    private static let check: NSImage? = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [BrandColor.Island.ok])))
}
