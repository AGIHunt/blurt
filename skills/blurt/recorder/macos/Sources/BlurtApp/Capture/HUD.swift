import AppKit
import AVFoundation
import Carbon.HIToolbox
import CoreMedia
import ScreenCaptureKit
import ServiceManagement

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
        let sub = NSAttributedString(string: L("准备，开喷", "Get ready to blurt"), attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.white])
        _ = pill(sub.string, font: NSFont.systemFont(ofSize: 13, weight: .medium), fg: .white,
                 bg: NSColor(white: 0.05, alpha: 0.72), at: NSPoint(x: bounds.midX - (sub.size().width + 24) / 2, y: r.minY - 40), pad: 12)
        let hint = [hkHint(.pause, "暂停 / 继续", "pause / resume"), hkHint(.finish, "完成", "finish"),
                    L("点一下跳过倒计时", "click to skip")].compactMap { $0 }.joined(separator: "   ·   ")
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
    var penBtn: IconButton!
    var live: HUDLive?               // 📸, the egg nest, live caption (HUDLive.swift)
    weak var rec: Recorder?

    init(rec: Recorder) {
        self.rec = rec
        super.init(contentRect: NSRect(x: 0, y: 0, width: 350, height: 48), styleMask: [.nonactivatingPanel, .borderless],
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

        let fx = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 350, height: 48))
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
        status.frame = NSRect(x: 36, y: 3, width: 96, height: 12)
        fx.addSubview(status)

        meter.frame.origin = NSPoint(x: 104, y: 14)
        fx.addSubview(meter)

        let div = NSView(frame: NSRect(x: 140, y: 14, width: 1, height: 20))
        div.wantsLayer = true
        div.layer?.backgroundColor = NSColor(white: 1, alpha: 0.15).cgColor
        fx.addSubview(div)

        pauseBtn = IconButton(symbol: "pause.fill", tip: L("暂停 / 继续", "Pause / resume") + hkTip(.pause), target: self, action: #selector(togglePause))
        let redo = IconButton(symbol: "arrow.counterclockwise", tip: L("重录或放弃…", "Restart or discard…"), target: self, action: #selector(redoRec))
        penBtn = IconButton(symbol: "scribble.variable", tip: "", target: self, action: #selector(togglePen))
        penBtn.toolTip = (rec.penKey.map { L("画笔：按住 \($0.1) 拖动圈出重点；点这里常开，再点一次或按 Esc 关", "Pen: hold \($0.1) and drag to circle things; click to keep it on, click again or press Esc to stop") }
            ?? L("画笔：圈出重点；再点一次或按 Esc 关", "Pen: circle things; click again or press Esc to stop")) + hkTip(.pen)
        pauseBtn.frame.origin = NSPoint(x: 150, y: 8)
        penBtn.frame.origin = NSPoint(x: 186, y: 8)
        redo.frame.origin = NSPoint(x: 222, y: 8)
        fx.addSubview(pauseBtn)
        fx.addSubview(penBtn)
        fx.addSubview(redo)
        let done = PillButton(L("完成", "Finish"), symbol: "stop.fill", fill: NSColor.systemRed.withAlphaComponent(0.92), target: self, action: #selector(stopRec))
        done.toolTip = L("结束录制，开始整理", "Stop and process") + hkTip(.finish)
        done.frame.origin = NSPoint(x: 260, y: 8)
        fx.addSubview(done)
        let w = done.frame.maxX + 8
        setContentSize(NSSize(width: w, height: 48))
        fx.frame.size.width = w
        fx.autoresizingMask = [.width]
        live = HUDLive(hud: self, rec: rec, fx: fx, pen: penBtn, redo: redo, done: done)
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
        status.stringValue = paused ? L("已暂停", "PAUSED") : rec?.penSticky == true ? L("画笔 · Esc 关", "PEN · Esc off") : ""
        pauseBtn.toolTip = (paused ? L("继续录制", "Resume") : L("暂停", "Pause")) + hkTip(.pause)
        time.frame.origin.y = paused ? 17 : 14
        dot.layer?.backgroundColor = (paused ? amber : NSColor.systemRed).cgColor
        pauseBtn.symbol = paused ? "play.fill" : "pause.fill"
        meter.level = paused ? 0 : lv
        penBtn.bg = rec?.inkOn == true ? accent : NSColor(white: 1, alpha: 0.1)
        penBtn.needsDisplay = true
    }

    @objc func togglePause() { rec?.togglePause() }
    @objc func togglePen() { rec?.togglePen() }
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
        activateApp()
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
