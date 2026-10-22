// Recording chrome that isn't the island: the border around the recorded area, the 3-2-1 countdown, the live caption
// line, and the overlay windows they live in. All of it is excluded from the recording (and from screen captures).
import AppKit
import BlurtCore

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
        let s = NSAttributedString(string: Loc.number(n), attributes: [
            .font: NSFont.systemFont(ofSize: 64, weight: .bold), .foregroundColor: NSColor.white])
        s.draw(at: NSPoint(x: r.midX - s.size().width / 2, y: r.midY - s.size().height / 2))
        let sub = Loc.t("capture.countdown.ready", table: "Capture")
        let sf = NSFont.systemFont(ofSize: 13, weight: .medium)
        let sw = NSAttributedString(string: sub, attributes: [.font: sf]).size().width
        _ = pill(sub, font: sf, fg: .white, bg: NSColor(white: 0.05, alpha: 0.72), at: NSPoint(x: bounds.midX - (sw + 24) / 2, y: r.minY - 40), pad: 12)
        let hint = [hkHint(.pause, "capture.countdown.pause"), hkHint(.finish, "capture.countdown.finish"),
                    Loc.t("capture.countdown.skip", table: "Capture")].compactMap { $0 }.joined(separator: "   ·   ")
        let hf = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        let hw = NSAttributedString(string: hint, attributes: [.font: hf]).size().width + 24
        _ = pill(hint, font: hf, fg: NSColor(white: 1, alpha: 0.85), bg: NSColor(white: 0.05, alpha: 0.6),
                 at: NSPoint(x: bounds.midX - hw / 2, y: r.minY - 76), pad: 12)
    }
}

/// One line of what was just said, under the island while recording (record.live_caption, default on). Never captured.
final class CaptionPanel {
    let win: NSWindow
    let fx = NSVisualEffectView()
    let label = NSTextField(labelWithString: "")
    var hideWork: DispatchWorkItem?

    init() {
        win = overlayWindow(NSRect(x: 0, y: 0, width: 300, height: 28), view: fx)
        fx.material = .hudWindow
        fx.state = .active
        fx.appearance = NSAppearance(named: .vibrantDark)
        fx.wantsLayer = true
        fx.maskImage = roundedMask(14)
        label.font = .systemFont(ofSize: 12.5, weight: .medium)
        label.textColor = NSColor(white: 1, alpha: 0.92)
        label.lineBreakMode = .byTruncatingHead      // the newest words matter most
        label.maximumNumberOfLines = 1
        fx.addSubview(label)
        win.alphaValue = 0
    }

    /// Centred under `anchor` (the island, in screen coordinates).
    func show(_ text: String, under anchor: NSRect) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        label.stringValue = t
        let tw = ceil((t as NSString).size(withAttributes: [.font: label.font!]).width)
        let w = min(max(160, tw + 36), 560)
        var f = NSRect(x: anchor.midX - w / 2, y: anchor.minY - 10 - 28, width: w, height: 28)
        if let s = NSScreen.screens.first(where: { $0.frame.intersects(anchor) })?.frame {
            f.origin.x = max(s.minX + 8, min(f.minX, s.maxX - w - 8))
        }
        win.setFrame(f, display: true)
        fx.frame = NSRect(origin: .zero, size: f.size)
        label.frame = NSRect(x: 14, y: 6, width: w - 28, height: 16)
        win.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { c in c.duration = 0.2; win.animator().alphaValue = 1 }
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            NSAnimationContext.runAnimationGroup({ c in c.duration = 0.6; self.win.animator().alphaValue = 0 },
                                                 completionHandler: { if self.win.alphaValue == 0 { self.win.orderOut(nil) } })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    func close() { hideWork?.cancel(); win.orderOut(nil) }
}

var liveCaptionOn: Bool { recordConfig()["live_caption"] as? Bool ?? true }

/// A stretchable rounded-rect mask. A layer corner radius doesn't clip a behind-window material on every macOS: the
/// blur then shows as a pale rectangle around the pill on light backgrounds. maskImage does clip it.
func roundedMask(_ radius: CGFloat) -> NSImage {
    let d = radius * 2 + 1
    let img = NSImage(size: NSSize(width: d, height: d), flipped: false) { r in
        NSColor.black.setFill()
        NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
        return true
    }
    img.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
    img.resizingMode = .stretch
    return img
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
