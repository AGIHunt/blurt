// The island, open (Island.swift draws the shape): what is under the ears row.
//
//   home        the current project (click = switch) · record / snap / voice · up to 3 jobs in progress (step,
//               progress) · agent sessions that need you (click = their terminal) · "5 to review" · "Let AI sort"
//   recording   pause / resume · snap + note (pauses) · discard (asks first: keep / restart / discard) · mic level ·
//               finish · "hold ⌃ to draw" · how many items were spotted so far · the project (changeable)
//   voice       the live waveform, the words if any, "pause to finish · Esc to cancel", where it will go
//   drawer      switcher (⌥⇧O): Auto, recent projects (≤ 8, "More…", type to filter), Open Folder… ⌘O
//               drop (a card dragged in): recent projects, Unassigned, Let AI sort
//               ↑↓ select · ↩ choose · Esc close; the target under the pointer / selection: ×1.02 on a 12 % accent wash
//   toast       one quiet line (K4), optionally with art (the completion chicken) and an action
// Dark on black in both appearances (it is the notch); white text at 92 / 60 / 40 %.

import AppKit
import BlurtCore

private let ink = NSColor(white: 1, alpha: 0.92)
private let ink2 = NSColor(white: 1, alpha: 0.6)
private let ink3 = NSColor(white: 1, alpha: 0.38)

/// A control on the island: a round icon button, or a pill with a title.
final class IslandButton: NSView {
    var action: () -> Void
    var symbol: String { didSet { needsDisplay = true } }
    var title: String?
    var fill: NSColor?
    var tip: String
    private var hover = false, pressed = false

    init(symbol: String, title: String? = nil, tip: String, fill: NSColor? = nil, action: @escaping () -> Void) {
        self.symbol = symbol
        self.title = title
        self.tip = tip
        self.fill = fill
        self.action = action
        super.init(frame: .zero)
        toolTip = tip
        setFrameSize(intrinsicContentSize)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title ?? tip)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }

    static let titleFont = NSFont.systemFont(ofSize: 12.5, weight: .semibold)

    override var intrinsicContentSize: NSSize {
        guard let t = title else { return NSSize(width: 30, height: 30) }
        let tw = (t as NSString).size(withAttributes: [.font: IslandButton.titleFont]).width
        return NSSize(width: ceil(tw) + (symbol.isEmpty ? 26 : 44), height: 28)
    }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with e: NSEvent) { hover = true; needsDisplay = true }
    override func mouseExited(with e: NSEvent) { hover = false; pressed = false; needsDisplay = true }
    override func mouseDown(with e: NSEvent) { pressed = true; needsDisplay = true }
    override func mouseUp(with e: NSEvent) {
        let inside = bounds.contains(convert(e.locationInWindow, from: nil))
        pressed = false
        needsDisplay = true
        if inside { action() }
    }
    override func accessibilityPerformPress() -> Bool { action(); return true }

    override func draw(_ dirty: NSRect) {
        let base = fill ?? NSColor(white: 1, alpha: 0.1)
        let c = pressed ? base.blended(withFraction: 0.3, of: .white) ?? base : hover ? base.blended(withFraction: 0.16, of: .white) ?? base : base
        c.setFill()
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2).fill()
        var x: CGFloat = title == nil ? 0 : 14
        if !symbol.isEmpty, let img = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold).applying(.init(paletteColors: [.white]))) {
            let s = img.size
            let ix = title == nil ? (bounds.width - s.width) / 2 : x
            img.draw(in: NSRect(x: ix, y: (bounds.height - s.height) / 2, width: s.width, height: s.height))
            x = ix + s.width + 6
        }
        if let t = title {
            let a = NSAttributedString(string: t, attributes: [.font: IslandButton.titleFont, .foregroundColor: NSColor.white])
            a.draw(at: NSPoint(x: symbol.isEmpty ? 13 : x, y: (bounds.height - a.size().height) / 2))
        }
    }
}

/// A row: icon, title (+ subtitle), an accessory on the right, an optional progress line. Hover / selection wash.
final class IslandRow: NSView {
    var icon: NSImage?
    var title: String
    var subtitle: String?
    var accessory: String?
    var accessoryIsKey = false
    var checked = false
    var progress: Double?
    var dot: NSColor?
    var action: (() -> Void)?
    var selected = false { didSet { if selected != oldValue { needsDisplay = true; animateScale() } } }
    var onHover: (() -> Void)?
    var target: IslandContent.Target?

    init(icon: NSImage?, title: String, subtitle: String? = nil, height: CGFloat = 36, action: (() -> Void)? = nil) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.action = action
        super.init(frame: NSRect(x: 0, y: 0, width: 100, height: height))
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(action == nil ? .staticText : .button)
        setAccessibilityLabel([title, subtitle].compactMap { $0 }.joined(separator: ", "))
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with e: NSEvent) { if action != nil || target != nil { onHover?(); selected = true } }
    override func mouseExited(with e: NSEvent) { if onHover == nil { selected = false } }
    override func mouseUp(with e: NSEvent) { if bounds.contains(convert(e.locationInWindow, from: nil)) { action?() } }
    override func accessibilityPerformPress() -> Bool { action?(); return action != nil }

    private func animateScale() {
        guard let l = layer else { return }
        let s: CGFloat = selected && !reduceMotion ? 1.02 : 1
        l.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        l.position = CGPoint(x: frame.midX, y: frame.midY)
        CATransaction.begin()
        CATransaction.setAnimationDuration(reduceMotion ? 0 : 0.14)
        l.transform = CATransform3DMakeScale(s, s, 1)
        CATransaction.commit()
    }

    override func draw(_ dirty: NSRect) {
        if selected {
            accent.withAlphaComponent(0.12 * 1.6).setFill()      // 12 % of the accent's weight on black reads as ~19 %
            NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 1), xRadius: 9, yRadius: 9).fill()
        }
        var x: CGFloat = 18
        if let d = dot {
            d.setFill()
            NSBezierPath(ovalIn: NSRect(x: x + 3, y: bounds.midY - 4, width: 8, height: 8)).fill()
            x += 24
        } else if let im = icon {
            let s = im.size
            im.draw(in: NSRect(x: x + (16 - s.width) / 2, y: (bounds.height - s.height) / 2, width: s.width, height: s.height),
                    from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            x += 26
        }
        var right = bounds.width - 18
        if checked, let c = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .bold).applying(.init(paletteColors: [accent]))) {
            right -= c.size.width
            c.draw(in: NSRect(x: right, y: (bounds.height - c.size.height) / 2, width: c.size.width, height: c.size.height))
            right -= 10
        }
        if let a = accessory {
            let f = accessoryIsKey ? NSFont.systemFont(ofSize: 10.5, weight: .semibold) : NSFont.systemFont(ofSize: 11.5)
            let s = NSAttributedString(string: a, attributes: [.font: f, .foregroundColor: ink2])
            let sz = s.size()
            if accessoryIsKey {
                let r = NSRect(x: right - sz.width - 10, y: (bounds.height - 18) / 2, width: sz.width + 10, height: 18)
                NSColor(white: 1, alpha: 0.22).setStroke()
                let p = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
                p.lineWidth = 1
                p.stroke()
                s.draw(at: NSPoint(x: r.minX + 5, y: r.midY - sz.height / 2))
                right = r.minX - 10
            } else {
                s.draw(at: NSPoint(x: right - sz.width, y: (bounds.height - sz.height) / 2))
                right -= sz.width + 10
            }
        }
        let tf = NSFont.systemFont(ofSize: 13, weight: .medium)
        let ps = NSMutableParagraphStyle()
        ps.lineBreakMode = .byTruncatingTail
        let t = NSAttributedString(string: title, attributes: [.font: tf, .foregroundColor: ink, .paragraphStyle: ps])
        if let sub = subtitle {
            let st = NSAttributedString(string: sub, attributes: [.font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: ink2, .paragraphStyle: ps])
            t.draw(in: NSRect(x: x, y: bounds.midY - 17, width: right - x, height: 17))
            st.draw(in: NSRect(x: x, y: bounds.midY + 1, width: right - x, height: 15))
        } else {
            t.draw(in: NSRect(x: x, y: (bounds.height - 17) / 2, width: right - x, height: 17))
        }
        if let p = progress {
            let track = NSRect(x: x, y: bounds.height - 4, width: bounds.width - x - 18, height: 2)
            NSColor(white: 1, alpha: 0.12).setFill()
            NSBezierPath(roundedRect: track, xRadius: 1, yRadius: 1).fill()
            accent.setFill()
            NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY, width: track.width * CGFloat(min(1, max(0, p))), height: 2), xRadius: 1, yRadius: 1).fill()
        }
    }
}

/// Bars that follow a level (recording: the mic) or a history (voice input: a scrolling waveform).
final class Bars: NSView {
    var values: [Float] = [] { didSet { needsDisplay = true } }
    var color: NSColor = .systemGreen
    var bar: CGFloat = 3, gap: CGFloat = 2.5
    override var isFlipped: Bool { true }
    override func draw(_ dirty: NSRect) {
        let n = max(1, Int((bounds.width + gap) / (bar + gap)))
        let vals = Array(values.suffix(n))
        let pad = n - vals.count
        for i in 0..<n {
            let v = i < pad ? 0 : CGFloat(vals[i - pad])
            let hh = max(bar, v * bounds.height)
            let r = NSRect(x: CGFloat(i) * (bar + gap), y: (bounds.height - hh) / 2, width: bar, height: hh)
            (v > 0.02 ? color : NSColor(white: 1, alpha: 0.18)).setFill()
            NSBezierPath(roundedRect: r, xRadius: bar / 2, yRadius: bar / 2).fill()
        }
    }
}

final class IslandContent: NSView {
    /// Every view of the open content redrawn in full (see Island.frame: the pieces drawn while the clip grew).
    func redrawAll() {
        func mark(_ v: NSView) { v.needsDisplay = true; v.subviews.forEach(mark) }
        mark(self)
    }
    weak var island: Island?
    override var isFlipped: Bool { true }
    var query = ""
    private(set) var fittingHeight: CGFloat = 0
    private(set) var toastWidth: CGFloat = 300
    var preferredWidth: CGFloat {
        guard let i = island else { return Island.openW }
        return !i.open && i.drawer == nil && i.currentToast != nil ? toastWidth : Island.openW
    }

    enum Target: Equatable { case project(String), inbox, aiSort, auto, openFolder, more }

    private var rows: [IslandRow] = []
    private var selected: Int?
    private var showAll = false
    // live parts
    private weak var level: Bars?
    private weak var wave: Bars?
    private weak var time: NSTextField?
    private weak var voiceText: NSTextField?
    private weak var spotted: NSTextField?
    private weak var pauseBtn: IslandButton?

    private func label(_ s: String, size: CGFloat = 13, weight: NSFont.Weight = .regular, color: NSColor = ink, mono: Bool = false) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = mono ? .monospacedDigitSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
        l.textColor = color
        l.lineBreakMode = .byTruncatingTail
        l.maximumNumberOfLines = 1
        l.sizeToFit()
        return l
    }

    private func hk(_ a: HotAction) -> String { Hotkeys.shared.label(a) }

    private func tip(_ key: String, _ a: HotAction) -> String {
        let k = hk(a)
        return k.isEmpty ? Loc.t(key, table: "Capture") : Loc.t("capture.island.tip_with_key", table: "Capture", Loc.t(key, table: "Capture"), k)
    }

    // MARK: build

    /// Home and the drawer put their first row beside the notch (in the ears row); the others start under it.
    private(set) var usesRow = false

    /// The ears row: its height, and the room on each side of the notch (the whole width without one).
    private var row: CGFloat { island?.rowHeight ?? 30 }
    private func side(_ w: CGFloat) -> CGFloat { island.map { $0.notchGap > 0 ? (w - $0.notchGap) / 2 : w / 2 } ?? w / 2 }

    func rebuild() {
        subviews.forEach { $0.removeFromSuperview() }
        rows = []
        selected = nil
        guard let i = island else { return }
        let w = preferredWidth
        var y: CGFloat = 0
        usesRow = false
        if let d = i.drawer {
            usesRow = true
            y = buildDrawer(d, w)
        } else if !i.open, let t = i.currentToast {
            y = buildToast(t, w, top: row)
        } else if i.isRecording {
            y = buildRecording(w, top: row)
        } else if VoiceInput.shared.active {
            y = buildVoice(w, top: row)
        } else {
            usesRow = true
            y = buildHome(w)
        }
        fittingHeight = y
    }

    private func place(_ v: NSView, x: CGFloat, y: CGFloat, w: CGFloat? = nil, h: CGFloat? = nil) {
        v.frame = NSRect(x: x, y: y, width: w ?? v.frame.width, height: h ?? v.frame.height)
        addSubview(v)
    }

    private func chip(_ w: CGFloat, small: Bool = false) -> IslandButton {
        let p = ProjectStore.shared.current
        let name = p?.name ?? Loc.t("project.auto")
        let b = IslandButton(symbol: p == nil ? "sparkles" : "folder.fill", title: name,
                             tip: tip("capture.island.switch_project", .project)) { [weak self] in self?.island?.showSwitcher() }
        b.fill = NSColor(white: 1, alpha: 0.1)
        b.setAccessibilityLabel(Loc.t("capture.island.project_ax", table: "Capture", name))
        let maxW = small ? 180 : max(110, side(w) - 22)
        b.setFrameSize(NSSize(width: min(maxW, b.intrinsicContentSize.width + 14), height: 26))
        let chev = NSImageView(image: NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)!
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 8.5, weight: .bold).applying(.init(paletteColors: [ink2])))!)
        chev.frame = NSRect(x: b.frame.width - 18, y: 8, width: 10, height: 10)
        chev.setAccessibilityElement(false); chev.cell?.setAccessibilityElement(false)      // decoration: the button already says what it does
        b.addSubview(chev)
        return b
    }

    private func buildHome(_ w: CGFloat) -> CGFloat {
        guard let i = island else { return 0 }
        // the ears row: the project on the left of the notch, record / snap / voice on its right
        let rowY = (row - 26) / 2
        let c = chip(w)
        place(c, x: 12, y: rowY)
        let buttons: [(String, String, HotAction, () -> Void)] = [
            ("record.circle", "capture.island.record", .toggleRecord, { (NSApp.delegate as? App)?.startRecording(useLast: false) }),
            ("camera.viewfinder", "capture.island.snap", .snap, { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { snapper.hotkey() } }),
            ("mic.fill", "capture.island.voice", .voice, { VoiceInput.shared.toggle() }),
        ]
        var bx = w - 12
        for (sym, key, act, f) in buttons.reversed() {
            let b = IslandButton(symbol: sym, tip: tip(key, act)) { [weak i] in i?.setOpen(false); f() }
            b.setFrameSize(NSSize(width: 26, height: 26))
            bx -= 26
            place(b, x: bx, y: rowY)
            bx -= 6
        }
        var y = row + 4
        let jobs = i.activeJobs
        if !jobs.isEmpty { y += 4 }
        for j in jobs {
            let step = j.steps.last { $0.state == .running } ?? j.steps.last { $0.state != .pending }
            let r = IslandRow(icon: IslandContent.jobIcon(j.type), title: IslandContent.jobTitle(j),
                              subtitle: step.map { Loc.t("job.step.\($0.id)") }, height: 42) { [weak i] in
                i?.setOpen(false)
                AppEnvironment.mainWindow?.reveal(job: j.id)
            }
            r.progress = j.progress ?? step?.progress
            place(r, x: 0, y: y, w: w, h: 42)
            y += 42
        }
        for j in i.sessionsNeedingYou {
            guard let a = j.agent else { continue }
            let st = a.status
            // what it is about first ("Sign-in button does nothing"), then which item, its state and the agent
            let ids = a.windowName?.replacingOccurrences(of: ",", with: ", ")
            let r = IslandRow(icon: nil, title: j.title ?? ids ?? Loc.t("job.type.agent"),
                              subtitle: [j.title == nil ? nil : ids, Loc.t("session.\(st.rawValue)"), AgentNames.name(a.agent)]
                                  .compactMap { $0 }.joined(separator: " · "), height: 40) { [weak i] in
                i?.setOpen(false)
                AppEnvironment.mainWindow?.reveal(job: j.id)
            }
            r.dot = st == .waitingInput ? amber : st == .error ? .systemRed : NSColor.systemGreen
            place(r, x: 0, y: y, w: w, h: 40)
            y += 40
        }
        let review = i.toReview, cards = i.cardCount
        if review > 0 || cards > 0 {
            let sep = NSView(frame: NSRect(x: 18, y: y + 4, width: w - 36, height: 1))
            sep.wantsLayer = true
            sep.layer?.backgroundColor = NSColor(white: 1, alpha: 0.08).cgColor
            addSubview(sep)
            y += 9
            if review > 0 {
                let r = IslandRow(icon: NSImage(systemSymbolName: "tray.full", accessibilityDescription: nil)?
                    .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .medium).applying(.init(paletteColors: [ink2]))),
                                  title: Loc.plural("capture.island.to_review", table: "Capture", count: review), height: 36) { [weak i] in
                    i?.setOpen(false)
                    AppEnvironment.mainWindow?.showInbox()
                }
                r.accessory = ""
                place(r, x: 0, y: y, w: cards > 0 ? w - 150 : w, h: 36)
            }
            if cards > 0 {
                let b = IslandButton(symbol: "wand.and.stars", title: Loc.t("project.ai_sort"), tip: Loc.plural("capture.island.ai_sort_tip", table: "Capture", count: cards),
                                     fill: accent.withAlphaComponent(0.9)) { snapper.aiSort() }
                place(b, x: w - 14 - b.frame.width, y: y + 4)
                if review == 0 {
                    let l = label(Loc.plural("capture.island.cards_waiting", table: "Capture", count: cards), size: 12.5, color: ink2)
                    place(l, x: 20, y: y + 9)
                }
            }
            y += 36
        }
        if jobs.isEmpty && i.sessionsNeedingYou.isEmpty && review == 0 && cards == 0 {
            // nothing going on: what the keys do
            let hint = [hkHint(.snap, "capture.island.snap"), hkHint(.voice, "capture.island.voice"), hkHint(.project, "capture.island.switch_project")]
                .compactMap { $0 }.joined(separator: "   ·   ")
            let l = label(hint, size: 11.5, color: ink3)
            l.alignment = .center
            place(l, x: 16, y: y + 2, w: w - 32)
            y += 22
        }
        return y + 8
    }

    static func jobIcon(_ t: JobType) -> NSImage? {
        let sym: String
        switch t {
        case .record: sym = "record.circle"
        case .snap: sym = "camera.viewfinder"
        case .voice: sym = "mic"
        case .process: sym = "sparkles"
        case .route: sym = "arrow.triangle.branch"
        case .agent: sym = "terminal"
        }
        return NSImage(systemSymbolName: sym, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .medium).applying(.init(paletteColors: [ink2])))
    }

    static func jobTitle(_ j: Job) -> String { j.title ?? Loc.t("job.type.\(j.type.rawValue)") }

    // MARK: recording

    private func buildRecording(_ w: CGFloat, top: CGFloat) -> CGFloat {
        guard let i = island, let rec = i.rec else { return 0 }
        var y: CGFloat = top + 6
        if i.isConfirmingDiscard {
            let q = label(Loc.t("capture.rec.discard_q", table: "Capture"), size: 13, weight: .medium)
            place(q, x: 18, y: y + 7)
            var bx = w - 12
            let items: [(String, NSColor?, () -> Void)] = [
                (Loc.t("capture.rec.discard", table: "Capture"), NSColor.systemRed.withAlphaComponent(0.9), { rec.stop(discard: true) }),
                (Loc.t("capture.rec.restart", table: "Capture"), nil, { rec.stop(discard: true, restart: true) }),
                (Loc.t("capture.rec.keep", table: "Capture"), nil, { [weak i] in i?.confirmDiscard(false) }),
            ]
            for (t, f, a) in items {
                let b = IslandButton(symbol: "", title: t, tip: t, fill: f, action: a)
                bx -= b.frame.width
                place(b, x: bx, y: y + 2)
                bx -= 8
            }
            return y + 40 + 8
        }
        let paused = rec.isPaused
        let pb = IslandButton(symbol: paused ? "play.fill" : "pause.fill", tip: tip(paused ? "capture.rec.resume" : "capture.rec.pause", .pause)) {
            rec.togglePause()
        }
        place(pb, x: 14, y: y + 3)
        pauseBtn = pb
        let sb = IslandButton(symbol: "camera.fill", tip: Loc.t("capture.rec.snap_note", table: "Capture")) { [weak i] in i?.snapWithNote() }
        place(sb, x: 52, y: y + 3)
        let db = IslandButton(symbol: "trash", tip: Loc.t("capture.rec.discard_tip", table: "Capture")) { [weak i] in i?.confirmDiscard(true) }
        place(db, x: 90, y: y + 3)
        let fin = IslandButton(symbol: "stop.fill", title: Loc.t("capture.rec.finish", table: "Capture"), tip: tip("capture.rec.finish_tip", .finish),
                               fill: NSColor.systemRed.withAlphaComponent(0.92)) { rec.stop() }
        place(fin, x: w - 14 - fin.frame.width, y: y + 4)
        let lv = Bars(frame: NSRect(x: 136, y: y + 8, width: 30, height: 20))
        lv.bar = 3; lv.gap = 3
        lv.setAccessibilityElement(true)
        lv.setAccessibilityLabel(Loc.t("capture.rec.mic_level", table: "Capture"))
        addSubview(lv)
        level = lv
        y += 42
        var hint = Loc.t("capture.rec.paused", table: "Capture")
        if !paused {
            hint = rec.penKey.map { Loc.t("capture.rec.pen_hint", table: "Capture", $0.1) } ?? ""
        }
        let h = label(hint, size: 11.5, color: paused ? amber : ink2)
        place(h, x: 18, y: y + 7, w: min(h.frame.width, w - 230))
        let sp = label("", size: 11.5, color: ink3)
        place(sp, x: h.frame.maxX + (hint.isEmpty ? 0 : 10), y: y + 7, w: 140)
        spotted = sp
        if (NSApp.delegate as? App)?.resident == true {     // a recording started from the chat has its session already
            let c = chip(w, small: true)
            place(c, x: w - 14 - c.frame.width, y: y + 2)
        }
        y += 34
        return y + 6
    }

    // MARK: voice input

    private func buildVoice(_ w: CGFloat, top: CGFloat) -> CGFloat {
        let v = VoiceInput.shared
        var y: CGFloat = top + 8
        let wv = Bars(frame: NSRect(x: 18, y: y, width: w - 36, height: 34))
        wv.color = accent
        wv.bar = 3; wv.gap = 2.5
        addSubview(wv)
        wave = wv
        y += 44
        let words = v.liveText
        let tx = label(words ?? Loc.t(v.holding ? "capture.voice.hold_hint" : "capture.voice.hint", table: "Capture"), size: 12.5,
                       color: words == nil ? ink2 : ink)
        place(tx, x: 18, y: y, w: w - 36)
        voiceText = tx
        y += 24
        let dest: String
        if let p = ProjectStore.shared.current { dest = Loc.t("capture.voice.goes_to", table: "Capture", p.name) } else {
            dest = Loc.t("capture.voice.goes_card", table: "Capture")
        }
        let d = label(dest, size: 11.5, color: ink3)
        place(d, x: 18, y: y, w: w - 36)
        return y + 26
    }

    // MARK: the drawer

    private func buildDrawer(_ d: Island.Drawer, _ w: CGFloat) -> CGFloat {
        let store = ProjectStore.shared
        func ic(_ s: String, _ c: NSColor = ink2) -> NSImage? {
            NSImage(systemSymbolName: s, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12.5, weight: .medium).applying(.init(paletteColors: [c])))
        }
        // the ears row: what this is on the left of the notch, the filter typed so far on its right
        let head = label(Loc.t(d == .drop ? "capture.drawer.drop_title" : "capture.drawer.switch_title", table: "Capture"), size: 11, weight: .semibold, color: ink3)
        place(head, x: 20, y: (row - head.frame.height) / 2, w: min(head.frame.width, side(w) - 26))
        if !query.isEmpty {
            let q = label("\u{201C}\(query)\u{201D}", size: 12, weight: .medium, color: accent)
            q.alignment = .right
            place(q, x: w - 20 - min(q.frame.width, side(w) - 26), y: (row - q.frame.height) / 2, w: min(q.frame.width, side(w) - 26))
        }
        var y = row + 4
        func add(_ r: IslandRow, _ t: Target) {
            r.target = t
            let idx = rows.count
            r.onHover = { [weak self] in self?.select(idx) }
            r.action = { [weak self] in self?.choose(t) }
            r.setAccessibilityRole(.button)
            rows.append(r)
            place(r, x: 0, y: y, w: w, h: r.frame.height)
            y += r.frame.height
        }
        if d == .switcher && query.isEmpty {
            let r = IslandRow(icon: ic("sparkles"), title: Loc.t("project.auto"), subtitle: Loc.t("capture.drawer.auto_sub", table: "Capture"), height: 44)
            r.checked = store.currentID == nil
            add(r, .auto)
        }
        let q = query.lowercased()
        let matches = store.projects.filter { q.isEmpty || $0.name.lowercased().contains(q) || $0.key.lowercased().hasPrefix(q) }
        let shown = q.isEmpty && !showAll ? Array(matches.prefix(8)) : matches
        for p in shown {
            let r = IslandRow(icon: ic("folder.fill", NSColor(calibratedRed: 0.55, green: 0.72, blue: 1, alpha: 0.9)), title: p.name, height: 36)
            r.accessory = p.key
            r.accessoryIsKey = true
            r.checked = d == .switcher && store.currentID == p.id
            add(r, .project(p.id))
        }
        if q.isEmpty && !showAll && matches.count > 8 {
            add(IslandRow(icon: ic("ellipsis"), title: Loc.t("capture.drawer.more", table: "Capture"), height: 34), .more)
        }
        if store.projects.isEmpty {
            let l = label(Loc.t("capture.drawer.no_projects", table: "Capture"), size: 12, color: ink3)
            place(l, x: 20, y: y + 6, w: w - 40)
            y += 30
        }
        let sep = NSView(frame: NSRect(x: 18, y: y + 4, width: w - 36, height: 1))
        sep.wantsLayer = true
        sep.layer?.backgroundColor = NSColor(white: 1, alpha: 0.08).cgColor
        addSubview(sep)
        y += 9
        if d == .switcher {
            let r = IslandRow(icon: ic("folder.badge.plus"), title: Loc.t("project.open_folder"), height: 36)
            r.accessory = "\u{2318}O"
            add(r, .openFolder)
        } else {
            add(IslandRow(icon: ic("tray"), title: Loc.t("project.inbox"), subtitle: Loc.t("capture.drawer.inbox_sub", table: "Capture"), height: 44), .inbox)
            add(IslandRow(icon: ic("wand.and.stars", accent), title: Loc.t("project.ai_sort"),
                          subtitle: Loc.plural("capture.drawer.ai_sub", table: "Capture", count: island?.cardCount ?? 0), height: 44), .aiSort)
        }
        if d == .switcher { select(rows.firstIndex { $0.checked } ?? 0) }
        return y + 8
    }

    private func select(_ i: Int?) {
        selected = i
        for (k, r) in rows.enumerated() { r.selected = k == i }
    }

    /// The drop target under a point (content coordinates), highlighted; nil clears.
    @discardableResult
    func highlight(at p: NSPoint?) -> Target? {
        guard let p = p, let i = rows.firstIndex(where: { $0.frame.contains(p) }), rows[i].target != .more else {
            if p == nil || selected != nil { select(nil) }
            return nil
        }
        if selected != i { select(i) }
        return rows[i].target
    }

    func perform(_ t: Target, shot: Shot?) {
        switch t {
        case .project(let id): if let s = shot { snapper.assign(s, to: id) }
        case .inbox: if let s = shot { snapper.assign(s, to: "inbox") }
        case .aiSort: snapper.aiSort()
        default: break
        }
    }

    private func choose(_ t: Target) {
        switch t {
        case .more: showAll = true; rebuild(); island?.wake()
        case .openFolder: island?.closeSwitcher(); IslandContent.openFolder()
        case .auto, .project:
            let id: String? = { if case .project(let i) = t { return i }; return nil }()
            island?.closeSwitcher()
            island?.setOpen(false)
            Task { try? await ProjectStore.shared.use(id); await MainActor.run { island?.projectChanged() } }
        case .inbox, .aiSort:
            perform(t, shot: nil)
        }
    }

    static func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = Loc.t("capture.drawer.open_prompt", table: "Capture")
        panel.message = Loc.t("capture.drawer.open_message", table: "Capture")
        activateApp()
        guard panel.runModal() == .OK, let u = panel.url else { return }
        Task {
            do {
                let p = try await ProjectStore.shared.open(folder: u)
                try await ProjectStore.shared.use(p.id)
                await MainActor.run { Island.shared.projectChanged() }
            } catch {
                await MainActor.run { Island.shared.toast(Loc.t("capture.drawer.open_failed", table: "Capture"), actionTitle: nil, action: nil) }
            }
        }
    }

    func key(_ e: NSEvent) -> Bool {
        switch Int(e.keyCode) {
        case 53: island?.closeSwitcher(); return true                                     // Esc
        case 125: select(min(rows.count - 1, (selected ?? -1) + 1)); return true           // ↓
        case 126: select(max(0, (selected ?? rows.count) - 1)); return true                // ↑
        case 36, 76: if let i = selected, i < rows.count, let t = rows[i].target { choose(t) }; return true
        case 51:                                                                           // ⌫
            if !query.isEmpty { query.removeLast(); rebuild(); island?.wake() }
            return true
        default: break
        }
        if e.modifierFlags.contains(.command), e.charactersIgnoringModifiers == "o" { choose(.openFolder); return true }
        if let c = e.characters, !c.isEmpty, !e.modifierFlags.contains(.command), !e.modifierFlags.contains(.control),
           c.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
            query += c
            rebuild()
            select(rows.isEmpty ? nil : rows.firstIndex { if case .project = $0.target { return true }; return false } ?? 0)
            island?.wake()
            return true
        }
        return false
    }

    // MARK: toast

    private func buildToast(_ t: Island.Toast, _ w: CGFloat, top: CGFloat) -> CGFloat {
        // the label's own fitted width (its cell has an inset): at the string's measured width the field ended in "…"
        // (the Claude Code fallback notice read "…organizing with Codex inste…")
        let l = label(t.text, size: 13, weight: .medium)
        let tw = ceil(l.frame.width)
        var x: CGFloat = 18
        if let art = t.art {
            art.frame = NSRect(x: 10, y: top - 2, width: 50, height: 50)
            addSubview(art)
            x = 64
        }
        var right: CGFloat = 18
        var btn: IslandButton?
        if let a = t.actionTitle, let act = t.action {
            let b = IslandButton(symbol: "", title: a, tip: a, fill: NSColor(white: 1, alpha: 0.14)) { [weak self] in
                act(); self?.island?.dismissToast()
            }
            btn = b
            right += b.frame.width + 10
        }
        toastWidth = min(Island.openW, max(240, x + tw + right))
        place(l, x: x, y: top + 13, w: min(tw, toastWidth - x - right))
        if let b = btn { place(b, x: toastWidth - 14 - b.frame.width, y: top + 9) }
        return top + 46
    }

    // MARK: live values

    func tick(_ now: CFTimeInterval) {
        guard let i = island, i.open || i.currentToast != nil else { return }
        if let rec = i.rec, rec.sessionStart.isValid {
            time?.stringValue = Island.clock(rec.elapsed())
            level?.values = [Float](repeating: rec.isPaused ? 0 : rec.micLevel, count: 1).flatMap { v in (0..<5).map { k in Float(k + 1) / 6 <= v ? Float(0.35 + 0.13 * Double(k)) : 0 } }
            let n = i.spottedCount
            spotted?.stringValue = n > 0 ? Loc.plural("capture.rec.spotted", table: "Capture", count: n) : ""
            if pauseBtn != nil, (pauseBtn?.symbol == "play.fill") != rec.isPaused { rebuild() }
        } else if VoiceInput.shared.active {
            wave?.values = VoiceInput.shared.levels
            time?.stringValue = Island.clock(VoiceInput.shared.elapsed)
            if let t = VoiceInput.shared.liveText, voiceText?.stringValue != t { voiceText?.stringValue = t; voiceText?.textColor = ink }
        }
    }
}
