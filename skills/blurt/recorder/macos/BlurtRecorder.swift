// BlurtRecorder — native macOS recorder for blurt (ScreenCaptureKit + AVAssetWriter).
//
// Flow: region picker (drag / click a window / F = full screen) → 3-2-1 countdown → recording with a floating
// control bar (timer, mic level, pause, marker, stop) that is never captured. Output: H.264/AAC mp4 + events.jsonl
// (pauses, markers, clicks, cursor samples). Built on first use by record.py with `swiftc`.
//
// Control: HUD buttons, global hotkeys (⌥⇧P pause/resume, ⌥⇧M marker, ⌥⇧S stop), stdin lines
// ("pause" | "resume" | "toggle" | "marker" | "stop"), or SIGTERM/SIGINT (= stop).
// stdout: one JSON object per line: ready, selected, countdown, recording, paused, resumed, marker, level?, stopped,
// cancelled, error.

import AppKit
import AVFoundation
import Carbon.HIToolbox
import CoreMedia
import ScreenCaptureKit

// MARK: - Options & utilities

struct Options {
    var out = ""
    var events: String? = nil
    var standalone = false         // launched as an app (no --out): save to ~/Movies/Blurt/<timestamp>/
    var fps = 30
    var maxWidth = 2560
    var countdown = 3
    var lang = (Locale.preferredLanguages.first ?? "en").hasPrefix("zh") ? "zh" : "en"
    var region: CGRect? = nil      // skip picker (global top-left points)
    var lastRegion: CGRect? = nil  // offered in the picker
    var preselect: CGRect? = nil   // picker opens with this selection (testing / "last region")
    var mic = true
    var micName: String? = nil

    static func parse() -> Options {
        var o = Options()
        var it = CommandLine.arguments.dropFirst().makeIterator()
        func rect(_ s: String?) -> CGRect? {
            guard let p = s?.split(separator: ",").compactMap({ Double($0) }), p.count == 4 else { return nil }
            return CGRect(x: p[0], y: p[1], width: p[2], height: p[3])
        }
        while let a = it.next() {
            switch a {
            case "--out": o.out = it.next() ?? o.out
            case "--events": o.events = it.next()
            case "--fps": o.fps = Int(it.next() ?? "") ?? o.fps
            case "--max-width": o.maxWidth = Int(it.next() ?? "") ?? o.maxWidth
            case "--countdown": o.countdown = Int(it.next() ?? "") ?? o.countdown
            case "--lang": o.lang = it.next() ?? o.lang
            case "--region": o.region = rect(it.next())
            case "--last-region": o.lastRegion = rect(it.next())
            case "--preselect": o.preselect = rect(it.next())
            case "--no-mic": o.mic = false
            case "--mic": o.micName = it.next()
            default: break
            }
        }
        if o.out.isEmpty { o.standalone = true }
        return o
    }
}

// MARK: - Standalone app mode (double-click Blurt.app): recordings land in ~/Movies/Blurt/<timestamp>/

let configURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".blurt/config.json")

func readConfig() -> [String: Any] {
    guard let d = try? Data(contentsOf: configURL), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
    return o
}

func saveLastRegion(_ r: CGRect) {
    var cfg = readConfig()
    var rec = cfg["record"] as? [String: Any] ?? [:]
    rec["last_region"] = [Int(r.minX), Int(r.minY), Int(r.width), Int(r.height)]
    cfg["record"] = rec
    try? FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    if let d = try? JSONSerialization.data(withJSONObject: cfg, options: [.prettyPrinted, .sortedKeys]) { try? d.write(to: configURL) }
}

func prepareStandalone() {
    let f = DateFormatter()
    f.dateFormat = "yyyyMMdd-HHmmss"
    let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/Blurt/\(f.string(from: Date()))")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    opts.out = dir.appendingPathComponent("recording.mp4").path
    opts.events = dir.appendingPathComponent("events.jsonl").path
    if opts.lastRegion == nil, let r = (readConfig()["record"] as? [String: Any])?["last_region"] as? [Double], r.count == 4 {
        opts.lastRegion = CGRect(x: r[0], y: r[1], width: r[2], height: r[3])
    }
}

var opts = Options.parse()
func L(_ zh: String, _ en: String) -> String { opts.lang == "zh" ? zh : en }

func emit(_ obj: [String: Any]) {
    if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
       let s = String(data: d, encoding: .utf8) {
        print(s)
        fflush(stdout)
    }
}

/// Global coordinates: AppKit uses bottom-left origin, CoreGraphics / ScreenCaptureKit use top-left.
var primaryHeight: CGFloat { NSScreen.screens.first?.frame.maxY ?? 0 }
func toCG(_ r: NSRect) -> CGRect { CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height) }
func toNS(_ r: CGRect) -> NSRect { NSRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height) }

/// Our chrome is hidden from every screen capture; BLURT_DEBUG_CHROME=1 makes it screenshot-able (still excluded
/// from blurt's own recording via the content filter).
let chromeSharing: NSWindow.SharingType = ProcessInfo.processInfo.environment["BLURT_DEBUG_CHROME"] == nil ? .none : .readOnly

func hostNow() -> CMTime { CMClockGetTime(CMClockGetHostTimeClock()) }

let accent = NSColor(calibratedRed: 1.0, green: 0.36, blue: 0.24, alpha: 1)   // coral
let amber = NSColor(calibratedRed: 1.0, green: 0.76, blue: 0.24, alpha: 1)

func pill(_ text: String, font: NSFont, fg: NSColor, bg: NSColor, at p: NSPoint, pad: CGFloat = 8) -> NSRect {
    let s = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: fg])
    let sz = s.size()
    let r = NSRect(x: p.x, y: p.y, width: sz.width + pad * 2, height: sz.height + pad)
    bg.setFill()
    NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2).fill()
    s.draw(at: NSPoint(x: r.minX + pad, y: r.minY + pad / 2))
    return r
}

// MARK: - Region picker

final class KeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class PickerController {
    var windows: [KeyWindow] = []
    var selection: NSRect?          // global AppKit coords
    var hovered: NSRect?
    var onDone: ((CGRect?) -> Void)?
    let toolbar = PickerToolbar()
    var toolbarHost: NSView?

    func show(preselect: CGRect?) {
        for screen in NSScreen.screens {
            let w = KeyWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.level = .screenSaver
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            w.acceptsMouseMovedEvents = true
            let v = PickerView(frame: NSRect(origin: .zero, size: screen.frame.size))
            v.controller = self
            v.screen = screen
            w.contentView = v
            w.setFrame(screen.frame, display: true)
            w.orderFrontRegardless()
            windows.append(w)
        }
        toolbar.controller = self
        if let p = preselect { selection = toNS(p) }
        NSApp.activate(ignoringOtherApps: true)
        let mouse = NSEvent.mouseLocation
        let keyWin = windows.first(where: { $0.frame.contains(mouse) }) ?? windows.first
        keyWin?.makeKeyAndOrderFront(nil)
        refresh()
        emit(["event": "ready"])
    }

    func screenFrame(containing p: NSPoint) -> NSRect {
        (NSScreen.screens.first(where: { $0.frame.contains(p) }) ?? NSScreen.screens[0]).frame
    }

    func refresh() {
        windows.forEach { $0.contentView?.needsDisplay = true }
        placeToolbar()
    }

    func placeToolbar() {
        toolbar.removeFromSuperview()
        guard let sel = selection, sel.width >= 8, sel.height >= 8,
              let win = windows.first(where: { $0.frame.intersects(sel) }), let host = win.contentView else { return }
        toolbar.layoutButtons(hasLast: opts.lastRegion != nil)
        let size = toolbar.frame.size
        let local = NSRect(origin: NSPoint(x: sel.minX - win.frame.minX, y: sel.minY - win.frame.minY), size: sel.size)
        var origin = NSPoint(x: local.midX - size.width / 2, y: local.minY - size.height - 14)
        if origin.y < 12 { origin.y = local.maxY + 14 }                            // no room below → above
        if origin.y + size.height > host.bounds.height - 12 { origin.y = local.minY + 14 } // inside, bottom
        origin.x = max(12, min(origin.x, host.bounds.width - size.width - 12))
        toolbar.setFrameOrigin(origin)
        host.addSubview(toolbar)
        toolbarHost = host
    }

    func finish(_ start: Bool) {
        let result = start ? selection.map { toCG($0).integral } : nil
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        onDone?(result)
    }

    func fullScreen() {
        selection = screenFrame(containing: NSEvent.mouseLocation)
        refresh()
    }

    func useLast() {
        if let l = opts.lastRegion { selection = toNS(l); refresh() }
    }
}

final class PickerView: NSView {
    weak var controller: PickerController?
    weak var screen: NSScreen?
    enum Mode { case none, create(NSPoint), move(NSPoint, NSRect), resize(Int, NSRect) }
    var mode: Mode = .none
    var downAt: NSPoint = .zero

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate],
                                       owner: self))
    }
    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }

    func global(_ e: NSEvent) -> NSPoint { window!.convertPoint(toScreen: e.locationInWindow) }
    func local(_ r: NSRect) -> NSRect { r.offsetBy(dx: -window!.frame.minX, dy: -window!.frame.minY) }

    func handles(_ r: NSRect) -> [NSPoint] {
        [NSPoint(x: r.minX, y: r.minY), NSPoint(x: r.midX, y: r.minY), NSPoint(x: r.maxX, y: r.minY),
         NSPoint(x: r.maxX, y: r.midY), NSPoint(x: r.maxX, y: r.maxY), NSPoint(x: r.midX, y: r.maxY),
         NSPoint(x: r.minX, y: r.maxY), NSPoint(x: r.minX, y: r.midY)]
    }

    override func draw(_ dirty: NSRect) {
        guard let c = controller else { return }
        let hole = (c.selection ?? c.hovered).map(local)
        let dim = NSBezierPath(rect: bounds)
        if let h = hole {
            dim.append(NSBezierPath(rect: h))
            dim.windingRule = .evenOdd
        }
        NSColor(white: 0, alpha: 0.42).setFill()
        dim.fill()

        if let sel = c.selection.map(local) {
            NSColor.white.withAlphaComponent(0.95).setStroke()
            let b = NSBezierPath(rect: sel.insetBy(dx: -0.5, dy: -0.5))
            b.lineWidth = 1.5
            b.stroke()
            for p in handles(sel) {
                let r = NSRect(x: p.x - 4.5, y: p.y - 4.5, width: 9, height: 9)
                NSColor.white.setFill()
                NSBezierPath(roundedRect: r, xRadius: 2.5, yRadius: 2.5).fill()
                accent.setStroke()
                let hb = NSBezierPath(roundedRect: r, xRadius: 2.5, yRadius: 2.5)
                hb.lineWidth = 1
                hb.stroke()
            }
            let scale = screen?.backingScaleFactor ?? 2
            let label = "\(Int(sel.width)) × \(Int(sel.height))  ·  \(Int(sel.width * scale))×\(Int(sel.height * scale))px"
            let f = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
            var at = NSPoint(x: sel.minX, y: sel.maxY + 8)
            if at.y + 26 > bounds.height { at.y = sel.maxY - 30; at.x = sel.minX + 8 }
            _ = pill(label, font: f, fg: .white, bg: NSColor(white: 0.08, alpha: 0.82), at: at)
        } else if let h = hole {
            accent.withAlphaComponent(0.9).setStroke()
            let b = NSBezierPath(rect: h.insetBy(dx: 1, dy: 1))
            b.lineWidth = 3
            b.stroke()
        }

        // hint on every screen, top centre
        let hint = L("拖拽框选录制区域 · 单击选中整个窗口 · F 全屏 · ⏎ 开始 · Esc 取消",
                     "Drag to select an area · Click a window · F full screen · ⏎ start · Esc cancel")
        let f = NSFont.systemFont(ofSize: 13, weight: .medium)
        let w = NSAttributedString(string: hint, attributes: [.font: f]).size().width + 28
        _ = pill(hint, font: f, fg: .white, bg: NSColor(white: 0.06, alpha: 0.78),
                 at: NSPoint(x: bounds.midX - w / 2, y: bounds.height - 64), pad: 14)
    }

    override func mouseMoved(with e: NSEvent) {
        guard let c = controller, c.selection == nil else { return }
        let r = windowRect(at: global(e))
        if r != c.hovered { c.hovered = r; c.refresh() }
    }

    func windowRect(at p: NSPoint) -> NSRect? {
        let cg = CGPoint(x: p.x, y: primaryHeight - p.y)
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        let me = Int(getpid())
        for w in list {
            guard (w[kCGWindowLayer as String] as? Int) == 0, (w[kCGWindowOwnerPID as String] as? Int) != me,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let r = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            if r.width > 40, r.height > 40, r.contains(cg) {
                return toNS(r).intersection(controller!.screenFrame(containing: p))
            }
        }
        return nil
    }

    override func mouseDown(with e: NSEvent) {
        guard let c = controller else { return }
        let p = global(e)
        downAt = p
        if e.clickCount == 2, let s = c.selection, s.contains(p) { c.finish(true); return }
        if let s = c.selection {
            for (i, h) in handles(s).enumerated() where hypot(h.x - p.x, h.y - p.y) < 10 {
                mode = .resize(i, s); return
            }
            if s.contains(p) { mode = .move(p, s); return }
        }
        mode = .create(p)
    }

    override func mouseDragged(with e: NSEvent) {
        guard let c = controller else { return }
        let p = global(e)
        let bounds = c.screenFrame(containing: downAt)
        switch mode {
        case .create(let s):
            guard hypot(p.x - s.x, p.y - s.y) > 4 else { return }
            let q = NSPoint(x: min(max(p.x, bounds.minX), bounds.maxX), y: min(max(p.y, bounds.minY), bounds.maxY))
            c.selection = NSRect(x: min(s.x, q.x), y: min(s.y, q.y), width: abs(q.x - s.x), height: abs(q.y - s.y))
            c.hovered = nil
        case .move(let s, let r):
            var n = r.offsetBy(dx: p.x - s.x, dy: p.y - s.y)
            n.origin.x = min(max(n.minX, bounds.minX), bounds.maxX - n.width)
            n.origin.y = min(max(n.minY, bounds.minY), bounds.maxY - n.height)
            c.selection = n
        case .resize(let i, let r):
            var (x0, y0, x1, y1) = (r.minX, r.minY, r.maxX, r.maxY)
            if [0, 6, 7].contains(i) { x0 = p.x }
            if [2, 3, 4].contains(i) { x1 = p.x }
            if [0, 1, 2].contains(i) { y0 = p.y }
            if [4, 5, 6].contains(i) { y1 = p.y }
            c.selection = NSRect(x: min(x0, x1), y: min(y0, y1), width: abs(x1 - x0), height: abs(y1 - y0))
                .intersection(bounds)
        case .none: break
        }
        c.refresh()
    }

    override func mouseUp(with e: NSEvent) {
        guard let c = controller else { return }
        if case .create(let s) = mode, hypot(global(e).x - s.x, global(e).y - s.y) <= 4 {
            if let h = c.hovered ?? windowRect(at: s) { c.selection = h; c.hovered = nil }
        }
        if let s = c.selection, s.width < 16 || s.height < 16 { c.selection = nil }
        mode = .none
        c.refresh()
    }

    override func keyDown(with e: NSEvent) {
        guard let c = controller else { return }
        switch Int(e.keyCode) {
        case kVK_Escape:
            if c.selection != nil && e.modifierFlags.contains(.shift) { c.selection = nil; c.refresh() } else { c.finish(false) }
        case kVK_Return, kVK_ANSI_KeypadEnter, kVK_Space: if c.selection != nil { c.finish(true) }
        case kVK_ANSI_F: c.fullScreen()
        case kVK_ANSI_L: c.useLast()
        case kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow:
            guard var s = c.selection else { return }
            let d: CGFloat = e.modifierFlags.contains(.shift) ? 10 : 1
            switch Int(e.keyCode) {
            case kVK_LeftArrow: s.origin.x -= d
            case kVK_RightArrow: s.origin.x += d
            case kVK_UpArrow: s.origin.y += d
            default: s.origin.y -= d
            }
            c.selection = s
            c.refresh()
        default: super.keyDown(with: e)
        }
    }
}

final class PillButton: NSButton {
    var fill: NSColor = NSColor(white: 1, alpha: 0.12)
    var fg: NSColor = .white
    var hovering = false { didSet { needsDisplay = true } }

    convenience init(_ title: String, symbol: String? = nil, fill: NSColor, fg: NSColor = .white, target: AnyObject, action: Selector) {
        self.init(frame: .zero)
        self.title = title
        self.fill = fill
        self.fg = fg
        self.target = target
        self.action = action
        isBordered = false
        if let s = symbol { image = NSImage(systemSymbolName: s, accessibilityDescription: title) }
        let w = NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)])
            .size().width + (symbol == nil ? 28 : 46)
        setFrameSize(NSSize(width: w, height: 32))
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override var allowsVibrancy: Bool { false }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func draw(_ dirty: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        (hovering ? fill.blended(withFraction: 0.18, of: .white) ?? fill : fill).setFill()
        NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2).fill()
        let s = NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: fg])
        var x = (bounds.width - s.size().width) / 2
        if let img = image?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 12, weight: .bold).applying(.init(paletteColors: [fg]))) {
            x += 9
            let sz = img.size
            img.draw(in: NSRect(x: x - 9 - sz.width, y: (bounds.height - sz.height) / 2, width: sz.width, height: sz.height))
        }
        s.draw(at: NSPoint(x: x, y: (bounds.height - s.size().height) / 2))
    }
}

final class PickerToolbar: NSVisualEffectView {
    weak var controller: PickerController?
    private var built = false

    func layoutButtons(hasLast: Bool) {
        if built { return }
        built = true
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        appearance = NSAppearance(named: .vibrantDark)
        wantsLayer = true
        layer?.cornerRadius = 22
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor(white: 1, alpha: 0.14).cgColor
        layer?.masksToBounds = true
        var buttons: [NSButton] = []
        buttons.append(PillButton(L("全屏", "Full screen"), symbol: "arrow.up.left.and.arrow.down.right",
                                  fill: NSColor(white: 1, alpha: 0.1), target: self, action: #selector(full)))
        if hasLast {
            buttons.append(PillButton(L("上次区域", "Last area"), symbol: "clock.arrow.circlepath",
                                      fill: NSColor(white: 1, alpha: 0.1), target: self, action: #selector(last)))
        }
        buttons.append(PillButton(L("取消", "Cancel"), fill: NSColor(white: 1, alpha: 0.1), target: self, action: #selector(cancel)))
        buttons.append(PillButton(L("开始录制", "Start recording"), symbol: "record.circle.fill", fill: accent,
                                  target: self, action: #selector(start)))
        var x: CGFloat = 6
        for b in buttons {
            b.setFrameOrigin(NSPoint(x: x, y: 6))
            addSubview(b)
            x += b.frame.width + 6
        }
        setFrameSize(NSSize(width: x, height: 44))
    }
    @objc func full() { controller?.fullScreen() }
    @objc func last() { controller?.useLast() }
    @objc func cancel() { controller?.finish(false) }
    @objc func start() { controller?.finish(true) }
}

// MARK: - Recording chrome: border, countdown, HUD

final class BorderView: NSView {
    var color: NSColor = accent { didSet { needsDisplay = true } }
    override func draw(_ dirty: NSRect) {
        color.setStroke()
        let b = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 4, yRadius: 4)
        b.lineWidth = 2.5
        b.stroke()
    }
}

final class CountdownView: NSView {
    var n = 3 { didSet { needsDisplay = true } }
    var onSkip: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onSkip?() }
    override func draw(_ dirty: NSRect) {
        let d: CGFloat = 132
        let r = NSRect(x: bounds.midX - d / 2, y: bounds.midY - d / 2, width: d, height: d)
        NSColor(white: 0.05, alpha: 0.72).setFill()
        NSBezierPath(ovalIn: r).fill()
        accent.setStroke()
        let ring = NSBezierPath(ovalIn: r.insetBy(dx: 3, dy: 3))
        ring.lineWidth = 3
        ring.stroke()
        let s = NSAttributedString(string: "\(n)", attributes: [
            .font: NSFont.systemFont(ofSize: 64, weight: .bold), .foregroundColor: NSColor.white])
        s.draw(at: NSPoint(x: r.midX - s.size().width / 2, y: r.midY - s.size().height / 2))
        let sub = NSAttributedString(string: L("准备，开始吐槽", "Get ready to blurt"), attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.white])
        _ = pill(sub.string, font: NSFont.systemFont(ofSize: 13, weight: .medium), fg: .white,
                 bg: NSColor(white: 0.05, alpha: 0.72), at: NSPoint(x: bounds.midX - (sub.size().width + 24) / 2, y: r.minY - 40), pad: 12)
        let hint = L("⌥⇧P 暂停 / 继续   ·   ⌥⇧S 完成   ·   点一下跳过倒计时",
                     "⌥⇧P pause / resume   ·   ⌥⇧S finish   ·   click to skip")
        let hf = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        let hw = NSAttributedString(string: hint, attributes: [.font: hf]).size().width + 24
        _ = pill(hint, font: hf, fg: NSColor(white: 1, alpha: 0.85), bg: NSColor(white: 0.05, alpha: 0.6),
                 at: NSPoint(x: bounds.midX - hw / 2, y: r.minY - 76), pad: 12)
    }
}

final class LevelView: NSView {
    var level: Float = 0 { didSet { needsDisplay = true } }
    var muted = false { didSet { needsDisplay = true } }
    override func draw(_ dirty: NSRect) {
        let bars = 5
        let w: CGFloat = 3, gap: CGFloat = 2.5
        for i in 0..<bars {
            let th = Float(i + 1) / Float(bars + 1)
            let h = CGFloat(4 + i * 3)
            let r = NSRect(x: CGFloat(i) * (w + gap), y: (bounds.height - h) / 2, width: w, height: h)
            (muted ? NSColor(white: 1, alpha: 0.2) : (level >= th ? NSColor.systemGreen : NSColor(white: 1, alpha: 0.22))).setFill()
            NSBezierPath(roundedRect: r, xRadius: 1.5, yRadius: 1.5).fill()
        }
    }
}

final class IconButton: NSButton {
    var tint: NSColor = .white { didSet { needsDisplay = true } }
    var bg: NSColor = NSColor(white: 1, alpha: 0.1)
    var hovering = false { didSet { needsDisplay = true } }
    var symbol = "" { didSet { needsDisplay = true } }
    convenience init(symbol: String, tip: String, bg: NSColor = NSColor(white: 1, alpha: 0.1), target: AnyObject, action: Selector) {
        self.init(frame: NSRect(x: 0, y: 0, width: 32, height: 32))
        self.symbol = symbol
        self.bg = bg
        toolTip = tip
        self.target = target
        self.action = action
        isBordered = false
        title = ""
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override var allowsVibrancy: Bool { false }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func draw(_ dirty: NSRect) {
        (hovering ? bg.blended(withFraction: 0.25, of: .white) ?? bg : bg).setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)).fill()
        guard let img = NSImage(systemSymbolName: symbol, accessibilityDescription: toolTip)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .bold)
                .applying(.init(paletteColors: [tint]))) else { return }
        let s = img.size
        img.draw(in: NSRect(x: (bounds.width - s.width) / 2, y: (bounds.height - s.height) / 2, width: s.width, height: s.height))
    }
}

final class HUD: NSPanel {
    let dot = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
    let time = NSTextField(labelWithString: "00:00")
    let status = NSTextField(labelWithString: "")
    let meter = LevelView(frame: NSRect(x: 0, y: 0, width: 26, height: 20))
    var pauseBtn: IconButton!
    weak var rec: Recorder?

    init(rec: Recorder) {
        self.rec = rec
        super.init(contentRect: NSRect(x: 0, y: 0, width: 314, height: 48), styleMask: [.nonactivatingPanel, .borderless],
                   backing: .buffered, defer: false)
        level = .statusBar
        isFloatingPanel = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        sharingType = chromeSharing

        let fx = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 314, height: 48))
        fx.material = .hudWindow
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.appearance = NSAppearance(named: .vibrantDark)
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 24
        fx.layer?.masksToBounds = true
        fx.layer?.borderWidth = 0.5
        fx.layer?.borderColor = NSColor(white: 1, alpha: 0.14).cgColor
        contentView = fx

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 5
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.frame.origin = NSPoint(x: 18, y: 19)
        fx.addSubview(dot)
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1
        pulse.toValue = 0.25
        pulse.duration = 0.9
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        dot.layer?.add(pulse, forKey: "pulse")

        time.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        time.textColor = .white
        time.frame = NSRect(x: 36, y: 14, width: 62, height: 20)
        fx.addSubview(time)
        status.font = .systemFont(ofSize: 10, weight: .semibold)
        status.textColor = amber
        status.frame = NSRect(x: 36, y: 3, width: 70, height: 12)
        fx.addSubview(status)

        meter.frame.origin = NSPoint(x: 104, y: 14)
        fx.addSubview(meter)

        let div = NSView(frame: NSRect(x: 140, y: 14, width: 1, height: 20))
        div.wantsLayer = true
        div.layer?.backgroundColor = NSColor(white: 1, alpha: 0.15).cgColor
        fx.addSubview(div)

        pauseBtn = IconButton(symbol: "pause.fill", tip: L("暂停 / 继续（⌥⇧P）", "Pause / resume (⌥⇧P)"), target: self, action: #selector(togglePause))
        let redo = IconButton(symbol: "arrow.counterclockwise", tip: L("重录或放弃…", "Restart or discard…"), target: self, action: #selector(redoRec))
        pauseBtn.frame.origin = NSPoint(x: 150, y: 8)
        redo.frame.origin = NSPoint(x: 186, y: 8)
        fx.addSubview(pauseBtn)
        fx.addSubview(redo)
        let done = PillButton(L("完成", "Finish"), symbol: "stop.fill", fill: NSColor.systemRed.withAlphaComponent(0.92), target: self, action: #selector(stopRec))
        done.toolTip = L("结束录制，开始整理（⌥⇧S）", "Stop and process (⌥⇧S)")
        done.frame.origin = NSPoint(x: 224, y: 8)
        fx.addSubview(done)
        let w = done.frame.maxX + 8
        setContentSize(NSSize(width: w, height: 48))
        fx.frame.size.width = w
    }

    func place(near region: CGRect) {
        let r = toNS(region)
        let screen = (NSScreen.screens.first(where: { $0.frame.intersects(r) }) ?? NSScreen.screens[0]).visibleFrame
        var o = NSPoint(x: r.midX - frame.width / 2, y: r.minY - frame.height - 14)
        if o.y < screen.minY + 8 { o.y = r.maxY + 14 }
        if o.y + frame.height > screen.maxY - 8 { o.y = r.minY + 16 }   // inside the region: excluded from capture
        o.x = max(screen.minX + 8, min(o.x, screen.maxX - frame.width - 8))
        setFrameOrigin(o)
    }

    func update(elapsed: Double, paused: Bool, level lv: Float) {
        let s = Int(elapsed)
        time.stringValue = s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                                     : String(format: "%02d:%02d", s / 60, s % 60)
        status.stringValue = paused ? L("已暂停", "PAUSED") : ""
        pauseBtn.toolTip = paused ? L("继续录制（⌥⇧P）", "Resume (⌥⇧P)") : L("暂停（⌥⇧P）", "Pause (⌥⇧P)")
        time.frame.origin.y = paused ? 17 : 14
        dot.layer?.backgroundColor = (paused ? amber : NSColor.systemRed).cgColor
        pauseBtn.symbol = paused ? "play.fill" : "pause.fill"
        meter.level = paused ? 0 : lv
    }

    @objc func togglePause() { rec?.togglePause() }
    @objc func stopRec() { rec?.stop() }
    @objc func redoRec() {
        guard let rec = rec else { return }
        let wasPaused = rec.isPaused
        if !wasPaused { rec.togglePause() }          // don't keep recording while the dialog is open
        let a = NSAlert()
        a.messageText = L("这段不满意？", "Not happy with this take?")
        a.informativeText = L("重新录制：删掉刚才录的内容，保留同一区域，倒计时后重新开始。\n放弃：删掉并退出。",
                              "Restart: delete what was recorded and start over in the same area.\nDiscard: delete and quit.")
        a.addButton(withTitle: L("重新录制", "Restart"))
        a.addButton(withTitle: L("继续录制", "Keep recording"))
        a.addButton(withTitle: L("放弃", "Discard"))
        NSApp.activate(ignoringOtherApps: true)
        switch a.runModal() {
        case .alertFirstButtonReturn: rec.stop(discard: true, restart: true)
        case .alertThirdButtonReturn: rec.stop(discard: true)
        default: if !wasPaused { rec.togglePause() }
        }
    }
}

func overlayWindow(_ frame: NSRect, view: NSView) -> NSWindow {
    let w = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
    w.level = .statusBar
    w.isOpaque = false
    w.backgroundColor = .clear
    w.hasShadow = false
    w.ignoresMouseEvents = true
    w.sharingType = chromeSharing
    w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    view.frame = NSRect(origin: .zero, size: frame.size)
    w.contentView = view
    return w
}

// MARK: - Recorder

final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    let region: CGRect
    var stream: SCStream?
    var writer: AVAssetWriter!
    var vIn: AVAssetWriterInput!
    var aIn: AVAssetWriterInput?
    let q = DispatchQueue(label: "blurt.capture")
    var started = false
    var sessionStart = CMTime.invalid
    var offset = CMTime.zero          // accumulated pause time
    var pausedAt: CMTime? = nil
    var lastVideo = CMTime.invalid
    var stopping = false
    var discard = false
    var micLevel: Float = 0
    var captureSession: AVCaptureSession?
    var events: FileHandle?
    var hud: HUD!
    var border: NSWindow?
    var borderView = BorderView()
    var ticker: Timer?
    var cursorTicker: Timer?
    var clickMonitor: Any?
    var frames = 0
    var audioBuffers = 0
    var onRestart: (() -> Void)?

    init(region: CGRect) { self.region = region }

    var isPaused: Bool { pausedAt != nil }

    func elapsed() -> Double {
        guard sessionStart.isValid else { return 0 }
        let now = pausedAt ?? hostNow()
        return max(0, CMTimeGetSeconds(CMTimeSubtract(CMTimeSubtract(now, sessionStart), offset)))
    }

    func log(_ type: String, _ extra: [String: Any] = [:]) {
        guard let fh = events else { return }
        var o: [String: Any] = ["t": (elapsed() * 1000).rounded() / 1000, "type": type]
        extra.forEach { o[$0.key] = $0.value }
        if let d = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) {
            fh.write(d)
            fh.write("\n".data(using: .utf8)!)
        }
    }

    // --- setup
    func prepare(completion: @escaping (Error?) -> Void) {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { content, err in
            DispatchQueue.main.async {
                guard let content = content else { return completion(err ?? NSError(domain: "blurt", code: 1)) }
                do { try self.configure(content); completion(nil) } catch { completion(error) }
            }
        }
    }

    func configure(_ content: SCShareableContent) throws {
        let center = CGPoint(x: region.midX, y: region.midY)
        guard let display = content.displays.first(where: { $0.frame.contains(center) }) ?? content.displays.first else {
            throw NSError(domain: "blurt", code: 2, userInfo: [NSLocalizedDescriptionKey: "no display"])
        }
        let clipped = region.intersection(display.frame)
        let mine = content.windows.filter { $0.owningApplication?.processID == getpid() }
        let filter = SCContentFilter(display: display, excludingWindows: mine)
        let cfg = SCStreamConfiguration()
        let scale = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID
        })?.backingScaleFactor ?? 2
        var w = clipped.width * scale, h = clipped.height * scale
        if w > CGFloat(opts.maxWidth) { h = h * CGFloat(opts.maxWidth) / w; w = CGFloat(opts.maxWidth) }
        let W = Int(w) / 2 * 2, H = Int(h) / 2 * 2
        cfg.sourceRect = CGRect(x: clipped.minX - display.frame.minX, y: clipped.minY - display.frame.minY,
                                width: clipped.width, height: clipped.height)
        cfg.width = W
        cfg.height = H
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(opts.fps))
        cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        cfg.showsCursor = true
        cfg.queueDepth = 8
        var scMic = false
        if opts.mic, #available(macOS 15.0, *) {
            cfg.captureMicrophone = true
            if let name = opts.micName,
               let dev = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio,
                                                          position: .unspecified).devices
                .first(where: { $0.localizedName.localizedCaseInsensitiveContains(name) }) {
                cfg.microphoneCaptureDeviceID = dev.uniqueID
            }
            scMic = true
        }

        let url = URL(fileURLWithPath: opts.out)
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = false  // true leaves .sb-* temp files if we exit right after
        vIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: W, AVVideoHeightKey: H,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(1_500_000, Int(Double(W * H) * 2.2)),
                AVVideoExpectedSourceFrameRateKey: opts.fps,
                AVVideoMaxKeyFrameIntervalKey: opts.fps * 2,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ])
        vIn.expectsMediaDataInRealTime = true
        writer.add(vIn)
        if opts.mic {
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 96000,
            ])
            a.expectsMediaDataInRealTime = true
            writer.add(a)
            aIn = a
        }
        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: q)
        if scMic, #available(macOS 15.0, *) {
            try s.addStreamOutput(self, type: .microphone, sampleHandlerQueue: q)
        }
        stream = s
        if opts.mic && !scMic { try setupLegacyMic() }
        if let e = opts.events {
            FileManager.default.createFile(atPath: e, contents: nil)
            events = FileHandle(forWritingAtPath: e)
        }
        emit(["event": "configured", "width": W, "height": H, "display": Int(display.displayID),
              "region": [clipped.minX, clipped.minY, clipped.width, clipped.height], "mic": opts.mic ? (scMic ? "screencapturekit" : "avcapture") : "none"])
    }

    func setupLegacyMic() throws {
        let devs = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
        guard let dev = (opts.micName.flatMap { n in devs.first { $0.localizedName.localizedCaseInsensitiveContains(n) } })
                ?? AVCaptureDevice.default(for: .audio) else { return }
        let cs = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: dev)
        if cs.canAddInput(input) { cs.addInput(input) }
        let out = AVCaptureAudioDataOutput()
        out.setSampleBufferDelegate(self, queue: q)
        if cs.canAddOutput(out) { cs.addOutput(out) }
        captureSession = cs
    }

    // --- run
    func start() {
        stream?.startCapture { err in
            if let err = err {
                emit(["event": "error", "code": "capture", "message": err.localizedDescription])
                exit(3)
            }
        }
        captureSession?.startRunning()
        DispatchQueue.main.async { self.showChrome() }
    }

    func showChrome() {
        let r = toNS(region)
        border = overlayWindow(r.insetBy(dx: -4, dy: -4), view: borderView)
        border?.orderFrontRegardless()
        hud = HUD(rec: self)
        hud.place(near: region)
        hud.orderFrontRegardless()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.hud.update(elapsed: self.elapsed(), paused: self.isPaused, level: self.micLevel)
            self.borderView.color = self.isPaused ? amber : accent
        }
        cursorTicker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self, !self.isPaused, self.sessionStart.isValid else { return }
            self.logCursor()
        }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] e in
            guard let self = self, !self.isPaused, let p = self.relative(NSEvent.mouseLocation) else { return }
            self.log("click", ["x": p.x, "y": p.y, "button": e.type == .rightMouseDown ? "right" : "left"])
        }
    }

    func finishStandalone(duration: Double) {
        let dir = (opts.out as NSString).deletingLastPathComponent
        let meta: [String: Any] = ["engine": "native-app", "duration": duration, "video": "recording.mp4",
                                   "region": [region.minX, region.minY, region.width, region.height],
                                   "started_at": ISO8601DateFormatter().string(from: Date(timeIntervalSinceNow: -duration))]
        if let d = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: URL(fileURLWithPath: dir).appendingPathComponent("meta.json"))
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: opts.out)])
    }

    func relative(_ ns: NSPoint) -> CGPoint? {
        let cg = CGPoint(x: ns.x, y: primaryHeight - ns.y)
        guard region.contains(cg) else { return nil }
        return CGPoint(x: ((cg.x - region.minX) / region.width * 1000).rounded() / 1000,
                       y: ((cg.y - region.minY) / region.height * 1000).rounded() / 1000)
    }

    var lastCursor: CGPoint?
    func logCursor() {
        guard let p = relative(NSEvent.mouseLocation), p != lastCursor else { return }
        lastCursor = p
        log("cursor", ["x": p.x, "y": p.y])
    }

    func togglePause() {
        q.async {
            if let p = self.pausedAt {
                self.offset = CMTimeAdd(self.offset, CMTimeSubtract(hostNow(), p))
                self.pausedAt = nil
                DispatchQueue.main.async { self.log("resume"); emit(["event": "resumed", "t": self.elapsed()]) }
            } else if self.sessionStart.isValid {
                DispatchQueue.main.async { self.log("pause") }
                self.pausedAt = hostNow()
                DispatchQueue.main.async { emit(["event": "paused", "t": self.elapsed()]) }
            }
        }
    }

    func marker() {
        log("marker")
        emit(["event": "marker", "t": elapsed()])
        NSSound(named: "Tink")?.play()
    }

    func adjusted(_ sb: CMSampleBuffer) -> CMSampleBuffer? {
        if offset == .zero { return sb }
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count)
        for i in 0..<count {
            timing[i].presentationTimeStamp = CMTimeSubtract(timing[i].presentationTimeStamp, offset)
            if timing[i].decodeTimeStamp.isValid { timing[i].decodeTimeStamp = CMTimeSubtract(timing[i].decodeTimeStamp, offset) }
        }
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sb, sampleTimingEntryCount: count,
                                              sampleTimingArray: &timing, sampleBufferOut: &out)
        return out
    }

    // SCStreamOutput
    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sb.isValid, !stopping else { return }
        if type == .screen {
            guard let att = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let raw = att.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { return }
            handleVideo(sb)
        } else {
            handleAudio(sb)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        emit(["event": "error", "code": "stream_stopped", "message": error.localizedDescription])
        DispatchQueue.main.async { self.stop() }
    }

    // AVCapture (macOS < 15 mic)
    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let cs = captureSession, let clock = cs.synchronizationClock else { handleAudio(sb); return }
        let pts = CMSyncConvertTime(CMSampleBufferGetPresentationTimeStamp(sb), from: clock, to: CMClockGetHostTimeClock())
        var timing = CMSampleTimingInfo(duration: CMSampleBufferGetDuration(sb), presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sb, sampleTimingEntryCount: 1,
                                              sampleTimingArray: &timing, sampleBufferOut: &out)
        if let o = out { handleAudio(o) }
    }

    func handleVideo(_ sb: CMSampleBuffer) {
        if !started {
            let pts = CMSampleBufferGetPresentationTimeStamp(sb)
            guard writer.startWriting() else {
                emit(["event": "error", "code": "writer", "message": writer.error?.localizedDescription ?? "?"])
                return
            }
            writer.startSession(atSourceTime: pts)
            sessionStart = pts
            started = true
            DispatchQueue.main.async { emit(["event": "recording"]) }
        }
        if isPaused { return }
        guard let s = adjusted(sb), vIn.isReadyForMoreMediaData else { return }
        if vIn.append(s) {
            frames += 1
            lastVideo = CMSampleBufferGetPresentationTimeStamp(s)
        }
    }

    func handleAudio(_ sb: CMSampleBuffer) {
        micLevel = rms(sb)
        guard started, !isPaused, let a = aIn else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        guard CMTimeCompare(pts, sessionStart) >= 0, let s = adjusted(sb), a.isReadyForMoreMediaData else { return }
        if a.append(s) { audioBuffers += 1 }
    }

    func rms(_ sb: CMSampleBuffer) -> Float {
        guard let fmt = CMSampleBufferGetFormatDescription(sb),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee,
              let block = CMSampleBufferGetDataBuffer(sb) else { return 0 }
        var len = 0
        var ptr: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &len, dataPointerOut: &ptr) == noErr,
              let p = ptr, len > 0 else { return 0 }
        var sum: Float = 0
        var n = 0
        if asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
            p.withMemoryRebound(to: Float.self, capacity: len / 4) { f in
                for i in stride(from: 0, to: len / 4, by: 4) { sum += f[i] * f[i]; n += 1 }
            }
        } else {
            p.withMemoryRebound(to: Int16.self, capacity: len / 2) { f in
                for i in stride(from: 0, to: len / 2, by: 4) { let v = Float(f[i]) / 32768; sum += v * v; n += 1 }
            }
        }
        guard n > 0 else { return 0 }
        let db = 20 * log10(max(sqrt(sum / Float(n)), 1e-6))
        return max(0, min(1, (db + 55) / 45))       // -55 dB … -10 dB → 0 … 1
    }

    func stop(discard: Bool = false, restart: Bool = false) {
        guard !stopping else { return }
        self.discard = discard
        let endAt = CMTimeSubtract(pausedAt ?? hostNow(), offset)
        stopping = true
        ticker?.invalidate()
        cursorTicker?.invalidate()
        if let m = clickMonitor { NSEvent.removeMonitor(m) }
        log("stop")
        try? events?.close()
        hud?.orderOut(nil)
        border?.orderOut(nil)
        captureSession?.stopRunning()
        let finish = {
            self.q.async {
                guard self.started else {
                    DispatchQueue.main.async {
                        if restart { emit(["event": "restarting"]); self.onRestart?(); return }
                        emit(discard ? ["event": "cancelled"] : ["event": "error", "code": "no_frames", "message": "no video frames captured"])
                        exit(discard ? 2 : 4)
                    }
                    return
                }
                self.vIn.markAsFinished()
                self.aIn?.markAsFinished()
                // screen content may have been static at the end: extend to the real stop time
                self.writer.endSession(atSourceTime: CMTimeMaximum(endAt, self.lastVideo))
                self.writer.finishWriting {
                    DispatchQueue.main.async {
                        if discard {
                            try? FileManager.default.removeItem(atPath: opts.out)
                            if let e = opts.events { try? FileManager.default.removeItem(atPath: e) }
                            if restart { emit(["event": "restarting"]); self.onRestart?(); return }
                            if opts.standalone { try? FileManager.default.removeItem(atPath: (opts.out as NSString).deletingLastPathComponent) }
                            emit(["event": "cancelled", "reason": "discarded"])
                            exit(2)
                        }
                        if self.writer.status == .failed {
                            emit(["event": "error", "code": "writer", "message": self.writer.error?.localizedDescription ?? "?"])
                            exit(5)
                        }
                        emit(["event": "stopped", "file": opts.out, "duration": CMTimeGetSeconds(CMTimeSubtract(endAt, self.sessionStart)),
                              "frames": self.frames, "audio_buffers": self.audioBuffers])
                        NSSound(named: "Submarine")?.play()
                        if opts.standalone { self.finishStandalone(duration: CMTimeGetSeconds(CMTimeSubtract(endAt, self.sessionStart))) }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { exit(0) }
                    }
                }
            }
        }
        if let s = stream { s.stopCapture { _ in finish() } } else { finish() }
    }
}

// MARK: - Hotkeys & stdin

var hotkeyHandler: ((UInt32) -> Void)?

func registerHotkeys() {
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
        var id = EventHotKeyID()
        GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                          MemoryLayout<EventHotKeyID>.size, nil, &id)
        hotkeyHandler?(id.id)
        return noErr
    }, 1, &spec, nil, nil)
    let mods = UInt32(optionKey | shiftKey)
    for (i, key) in [kVK_ANSI_P, kVK_ANSI_M, kVK_ANSI_S].enumerated() {
        var ref: EventHotKeyRef?
        RegisterEventHotKey(UInt32(key), mods, EventHotKeyID(signature: OSType(0x626C7274), id: UInt32(i + 1)),
                            GetApplicationEventTarget(), 0, &ref)
    }
}

var signalSources: [DispatchSourceSignal] = []

// MARK: - App

final class App: NSObject, NSApplicationDelegate {
    var picker: PickerController?
    var rec: Recorder?
    var countdownWin: NSWindow?

    func applicationDidFinishLaunching(_ n: Notification) {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            s.setEventHandler { [weak self] in self?.command("stop") }
            s.resume()
            signalSources.append(s)
        }
        DispatchQueue.global().async {
            while let line = readLine() {
                let cmd = line.trimmingCharacters(in: .whitespaces).lowercased()
                DispatchQueue.main.async { self.command(cmd) }
            }
        }
        hotkeyHandler = { [weak self] id in
            self?.command(["", "toggle", "marker", "stop"][Int(id)])
        }
        registerHotkeys()
        // Probe permission early so the user isn't asked mid-flow.
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { _, err in
            DispatchQueue.main.async {
                if let err = err {
                    emit(["event": "error", "code": "screen_permission", "message": err.localizedDescription])
                    exit(3)
                }
                if let r = opts.region { self.begin(r) } else { self.pick() }
            }
        }
    }

    func command(_ c: String) {
        switch c {
        case "stop":
            if let r = rec { r.stop() } else { emit(["event": "cancelled"]); exit(2) }
        case "discard": rec?.stop(discard: true)
        case "restart": rec?.stop(discard: true, restart: true)
        case "pause": if rec?.isPaused == false { rec?.togglePause() }
        case "resume": if rec?.isPaused == true { rec?.togglePause() }
        case "toggle": rec?.togglePause()
        case "marker": rec?.marker()
        default: break
        }
    }

    func pick() {
        let p = PickerController()
        p.onDone = { [weak self] r in
            guard let self = self else { return }
            guard let r = r else { emit(["event": "cancelled"]); exit(2) }
            self.picker = nil
            self.begin(r)
        }
        picker = p
        p.show(preselect: opts.preselect)
    }

    func begin(_ region: CGRect) {
        emit(["event": "selected", "region": [region.minX, region.minY, region.width, region.height]])
        if opts.standalone { saveLastRegion(region) }
        let r = Recorder(region: region)
        r.onRestart = { [weak self] in
            // fresh file for the new take
            FileManager.default.createFile(atPath: opts.events ?? "/dev/null", contents: nil)
            self?.rec = nil
            self?.begin(region)
        }
        rec = r
        r.prepare { err in
            if let err = err {
                emit(["event": "error", "code": "setup", "message": err.localizedDescription])
                exit(3)
            }
            self.countdown(opts.countdown, over: region) { r.start() }
        }
    }

    func countdown(_ n: Int, over region: CGRect, then: @escaping () -> Void) {
        guard n > 0 else { return then() }
        let v = CountdownView()
        let w = overlayWindow(toNS(region), view: v)
        w.ignoresMouseEvents = false
        w.orderFrontRegardless()
        countdownWin = w
        var left = n
        var fired = false
        v.n = left
        emit(["event": "countdown", "n": left])
        NSSound(named: "Pop")?.play()
        var timer: Timer?
        let go = {
            guard !fired else { return }
            fired = true                 // a short beat after hiding so the countdown never lands in frame 1
            timer?.invalidate()
            w.orderOut(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { then() }
        }
        v.onSkip = go
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { t in
            left -= 1
            if left == 0 {
                go()
                return
            }
            v.n = left
            NSSound(named: "Pop")?.play()
            emit(["event": "countdown", "n": left])
        }
    }
}

if opts.standalone { prepareStandalone() }
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = App()
app.delegate = delegate
app.run()
