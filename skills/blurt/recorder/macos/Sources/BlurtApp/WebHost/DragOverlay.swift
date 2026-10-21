// Native drag-out of frames shown in the web canvas (WP5): the page reports where its frames are
// (BlurtHost.registerDragRects, C6), and this transparent view sits over the web view and claims exactly those rects.
// A press that turns into a drag becomes an NSDraggingSession with the frame's file URL — Finder copies the file,
// Terminal pastes the path, Slack / Mail attach it. A press that doesn't move is handed to the web view as the click
// it was (as are wheel and right clicks), so the page keeps working underneath.
import AppKit
import WebKit

struct DragRect {
    var rect: CGRect        // CSS px in the viewport
    var file: URL
}

final class DragOverlay: NSView, NSDraggingSource, NSViewToolTipOwner {
    weak var web: WKWebView?
    private(set) var regions: [(NSRect, URL)] = []
    private var down: NSEvent?
    private var dragging = false

    override var isFlipped: Bool { true }

    func set(_ rects: [DragRect]) {
        let scale = (web?.pageZoom ?? 1) * (web?.magnification ?? 1)
        regions = rects.map { (NSRect(x: $0.rect.minX * scale, y: $0.rect.minY * scale, width: $0.rect.width * scale, height: $0.rect.height * scale), $0.file) }
        discardCursorRects()
        window?.invalidateCursorRects(for: self)
        toolTip = nil
        removeAllToolTips()
        for (r, _) in regions { addToolTip(r, owner: self, userData: nil) }
    }

    override func resetCursorRects() {
        for (r, _) in regions { addCursorRect(r, cursor: .openHand) }
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        L("拖到访达或终端", "Drag to Finder or a terminal")
    }

    func region(at p: NSPoint) -> URL? { regions.first { $0.0.contains(p) }?.1 }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let sv = superview else { return nil }
        let p = convert(point, from: sv)
        return region(at: p) == nil ? nil : self
    }

    override func mouseDown(with e: NSEvent) {
        down = e
        dragging = false
    }

    override func mouseDragged(with e: NSEvent) {
        guard let d = down, !dragging else { return }
        let a = d.locationInWindow, b = e.locationInWindow
        guard hypot(b.x - a.x, b.y - a.y) > 4, let file = region(at: convert(a, from: nil)) else { return }
        dragging = true
        let item = NSDraggingItem(pasteboardWriter: file as NSURL)
        let p = convert(a, from: nil)
        let img = NSImage(contentsOf: file) ?? NSWorkspace.shared.icon(forFile: file.path)
        let w: CGFloat = 160, h = img.size.width > 0 ? w * img.size.height / img.size.width : w
        item.setDraggingFrame(NSRect(x: p.x - w / 2, y: p.y - min(h, 200) / 2, width: w, height: min(h, 200)), contents: img)
        beginDraggingSession(with: [item], event: d, source: self)
    }

    override func mouseUp(with e: NSEvent) {
        defer { down = nil; dragging = false }
        guard !dragging, let d = down, let web = web else { return }
        web.mouseDown(with: d)          // it was a click: the page gets it
        web.mouseUp(with: e)
    }

    override func scrollWheel(with e: NSEvent) { web?.scrollWheel(with: e) }
    override func rightMouseDown(with e: NSEvent) { web?.rightMouseDown(with: e) }
    override func rightMouseUp(with e: NSEvent) { web?.rightMouseUp(with: e) }
    override func otherMouseDown(with e: NSEvent) { web?.otherMouseDown(with: e) }
    override func magnify(with e: NSEvent) { web?.magnify(with: e) }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .generic] : .copy
    }

    // VoiceOver: the drag handles are not separate elements; the page's images carry the labels
    override func isAccessibilityElement() -> Bool { false }
}
