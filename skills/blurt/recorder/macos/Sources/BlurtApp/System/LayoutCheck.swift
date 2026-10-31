// `layoutcheck` (test channel, SelfTests.swift): the deterministic layout lint. Walks every visible window of the app —
// the main window, Settings, the onboarding, panels, the island's windows, sheets, popovers — through the accessibility
// tree (AppKit and SwiftUI alike) and reports, per window, what a person would see as broken:
//   outside_window       a button / text / control / labelled image not fully inside the window (4 pt tolerance;
//                        the title bar counts as inside)
//   under_traffic_lights such an element under the close / minimise / zoom buttons
//   overlap              two interactive elements on top of each other
//   truncated            a text that doesn't fit its frame: an NSTextField (its cell's own size), or a SwiftUI text
//                        whose font the accessibility tree tells (measured with that font); texts in lists and tables
//                        are left out (a long title cut with … is by design there), and so are texts with a tooltip
//                        (a long path cut in the middle, the whole of it on hover); or a button, pop-up or menu
//                        button whose title doesn't fit: an NSButton by its cell, an NSPopUpButtonCell (SwiftUI's
//                        Picker and Menu too) by its title against the cell's titleRect, a SwiftUI button by its label
//                        at the tree's font plus the least bezel its height implies — then the window's rendering is
//                        read back (Vision) for titles that show as their beginning plus "…" (a split button's chevron
//                        is invisible to the geometry). Icon-only buttons (about square, or named after their SF
//                        Symbol) are left out
// The rules are BlurtCore's LayoutLint (unit-tested); this file only collects the elements.
//   layoutcheck            the windows as they are
//   layoutcheck min        first every resizable window with a minimum size is made that small (top-left kept)
//   layoutcheck restore    the windows `min` shrank get their size back, then the check
//   layoutcheck dump       also every element seen ("nodes"), for tuning
// Answer: {"event":"layoutcheck","windows":[{"title","size","elements","problems":[{"kind","role","label","frame","bounds"}]}]}
// (frames in window points, top-left origin).
import AppKit
import BlurtCore
import Vision

@MainActor
enum LayoutCheck {
    private static var shrunk: [(NSWindow, NSRect)] = []

    static func run(_ arg: String) {
        var delay = 0.35
        switch arg {
        case "min":
            restore()
            for w in windows() where w.styleMask.contains(.resizable) && w.minSize.width > 1 && w.minSize.height > 1 {
                let f = w.frame
                shrunk.append((w, f))
                w.setFrame(NSRect(x: f.minX, y: f.maxY - w.minSize.height, width: w.minSize.width, height: w.minSize.height), display: true)
            }
            delay = 0.9
        case "restore":
            restore()
            delay = 0.9
        default: break
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            emit(["event": "layoutcheck", "arg": arg, "windows": windows().map { report($0, dump: arg == "dump") }])
        }
    }

    private static func restore() {
        for (w, f) in shrunk { w.setFrame(f, display: true) }
        shrunk = []
    }

    /// The app's windows a person can see (menus, tooltips and the menu-bar item's own window aren't layouts).
    static func windows() -> [NSWindow] {
        NSApp.windows.filter { w in
            let cls = String(describing: type(of: w))
            return w.isVisible && w.alphaValue > 0.01 && w.frame.width > 1 && w.frame.height > 1
                && !["StatusBar", "Menu", "ToolTip", "TUINS"].contains { cls.contains($0) }
        }
    }

    static func report(_ w: NSWindow, dump: Bool) -> [String: Any] {
        w.layoutIfNeeded()
        let wf = w.frame
        var nodes: [LayoutNode] = []
        var visited = Set<ObjectIdentifier>()

        func local(_ r: NSRect) -> CGRect { CGRect(x: r.minX - wf.minX, y: wf.maxY - r.maxY, width: r.width, height: r.height) }

        func walk(_ any: Any, parent: Int?, clip: CGRect?, inList: Bool, depth: Int) {
            guard depth < 60, nodes.count < 4000 else { return }
            let o = any as AnyObject
            guard visited.insert(ObjectIdentifier(o)).inserted else { return }
            if let v = o as? NSView, v.isHiddenOrHasHiddenAncestor || v.alphaValue < 0.01 || (v.window != nil && v.window !== w) { return }
            let role = o.accessibilityRole?()?.rawValue ?? ""
            let subrole = o.accessibilitySubrole?()?.rawValue ?? ""
            let frame = local(o.accessibilityFrame?() ?? .zero)
            var label = o.accessibilityLabel?() ?? ""
            if label.isEmpty { label = o.accessibilityTitle?() ?? "" }
            if label.isEmpty, let s = axValue(o) as? String { label = s }
            label = String(label.replacingOccurrences(of: "\n", with: " ").prefix(80))
            let listy = inList || ["AXRow", "AXCell", "AXTable", "AXOutline", "AXList", "AXBrowser"].contains(role)
            var n = LayoutNode(role: role, subrole: subrole, label: label, frame: frame, clip: clip, parent: parent)
            // a text with a tooltip (.help) shows its whole self on hover: a path cut in the middle is by design there
            let help = o.accessibilityHelp?() ?? ""
            if role == "AXStaticText" || role == "AXTextField", !listy, help.isEmpty { n.truncated = truncated(o, frame: frame) }
            if LayoutLint.titled.contains(role), !listy { n.truncated = titleClipped(o, frame: frame, label: label) }
            nodes.append(n)
            let me = nodes.count - 1
            // web content is its own world (and another process); a terminal's lines are its own scrolling
            let cls = String(describing: type(of: o))
            if cls.contains("WKWebView") || cls.contains("TerminalView") { return }
            var inner = clip
            if role == "AXScrollArea" { inner = clip.map { $0.intersection(frame) } ?? frame }
            for c in o.accessibilityChildren?() ?? [] { walk(c, parent: me, clip: inner, inList: listy, depth: depth + 1) }
        }
        for c in w.accessibilityChildren() ?? [] { walk(c, parent: nil, clip: nil, inList: false, depth: 0) }
        // what geometry can't see (more in a label than its words): read the rendering back, once per window
        if nodes.contains(where: { LayoutLint.titled.contains($0.role) && !$0.truncated && !$0.label.isEmpty }) {
            for i in LayoutLint.cutTitles(nodes, texts: renderedTexts(w)) { nodes[i].truncated = true }
        }

        // the traffic lights, as one strip (the gaps between them too)
        let lights = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { w.standardWindowButton($0) }
            .filter { !$0.isHiddenOrHasHiddenAncestor && $0.window === w }
            .map { b -> CGRect in
                let r = b.convert(b.bounds, to: nil)
                return CGRect(x: r.minX, y: wf.height - r.maxY, width: r.width, height: r.height)
            }
        let strip = lights.isEmpty ? [] : [lights.dropFirst().reduce(lights[0]) { $0.union($1) }]
        let problems = LayoutLint.check(nodes, window: wf.size, trafficLights: strip)
        var o: [String: Any] = [
            "title": w.title.isEmpty ? String(describing: type(of: w)) : w.title,
            "class": String(describing: type(of: w)),
            "size": [Double(wf.width), Double(wf.height)],
            "elements": nodes.filter(LayoutLint.checked).count,
            "problems": problems.map(\.json),
        ]
        if w.minSize.width > 1, w.styleMask.contains(.resizable) { o["min_size"] = [Double(w.minSize.width), Double(w.minSize.height)] }
        if dump { o["nodes"] = nodes.map { [$0.role, $0.subrole, $0.label, LayoutLint.array($0.frame)] as [Any] } }
        return o
    }

    /// The text doesn't fit its frame: an NSTextField by its cell; a SwiftUI text by its accessibility font, when told.
    static func truncated(_ o: AnyObject, frame: CGRect) -> Bool {
        if let tf = o as? NSTextField {
            guard !tf.isEditable, !tf.stringValue.isEmpty, let cell = tf.cell, !tf.allowsExpansionToolTips else { return false }
            let b = tf.bounds
            if tf.maximumNumberOfLines == 1 || cell.usesSingleLineMode || !cell.wraps {
                return cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: 100_000, height: b.height)).width > b.width + 1.5
            }
            return cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: b.width, height: 100_000)).height > b.height + 1.5
        }
        guard !(o is NSView), let s = axValue(o) as? String ?? o.accessibilityLabel?(), !s.isEmpty,
              frame.width > 1, frame.height > 1 else { return false }
        let len = (s as NSString).length
        guard let attr = o.accessibilityAttributedString?(for: NSRange(location: 0, length: len)), attr.length > 0,
              let font = font(attr) else { return false }
        let text = NSAttributedString(string: s, attributes: [.font: font])
        let line = font.ascender - font.descender + font.leading
        if frame.height < line * 1.7 {
            return text.size().width > frame.width + max(2, frame.width * 0.03)
        }
        let need = text.boundingRect(with: CGSize(width: frame.width, height: 100_000), options: NSString.DrawingOptions.usesLineFragmentOrigin).height
        return need > frame.height + line * 0.6
    }

    /// A button / pop-up / menu button whose title doesn't fit (see the header). Icon-only ones never count.
    static func titleClipped(_ o: AnyObject, frame: CGRect, label: String) -> Bool {
        // a pop-up or pull-down: AppKit's, or SwiftUI's Picker / Menu (its element is the NSPopUpButtonCell itself)
        if let cell = (o as? NSPopUpButtonCell) ?? ((o as? NSPopUpButton)?.cell as? NSPopUpButtonCell) {
            guard let view = cell.controlView, !cell.title.isEmpty else { return false }
            let title = cell.attributedTitle.length > 0 ? cell.attributedTitle
                : NSAttributedString(string: cell.title, attributes: [.font: cell.font ?? NSFont.systemFont(ofSize: 13)])
            return LayoutLint.popupTitleClipped(titleWidth: title.size().width,
                                                titleRectWidth: cell.titleRect(forBounds: view.bounds).width)
        }
        if let b = o as? NSButton {
            guard let cell = b.cell as? NSButtonCell, !b.title.isEmpty, b.imagePosition != .imageOnly, !cell.wraps else { return false }
            return cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: 100_000, height: b.bounds.height)).width > b.bounds.width + 1.5
        }
        guard !(o is NSView), !(o is NSCell), !label.isEmpty, frame.width > 1, frame.height > 1 else { return false }
        let id = o.accessibilityIdentifier?() ?? ""
        let symbol = !id.isEmpty && NSImage(systemSymbolName: id, accessibilityDescription: nil) != nil
        guard !LayoutLint.iconOnly(frame: frame.size, symbolIdentifier: symbol) else { return false }
        // SwiftUI tells a button's label font in its attributed description; else the control size its height implies
        let size = labelFontSize(o) ?? (frame.height >= 22 ? 13 : frame.height >= 17 ? 11 : 9)
        let width = NSAttributedString(string: label, attributes: [.font: NSFont.systemFont(ofSize: size)]).size().width
        return LayoutLint.controlTitleClipped(titleWidth: width, fontSize: size, frame: frame.size)
    }

    private static func labelFontSize(_ o: AnyObject) -> CGFloat? {
        guard let n = o as? NSObject,
              let a = n.accessibilityAttributeValue(NSAccessibility.Attribute(rawValue: "AXAttributedDescription")) as? NSAttributedString,
              a.length > 0,
              let d = a.attribute(NSAttributedString.Key(rawValue: "AXFont"), at: 0, effectiveRange: nil) as? [String: Any]
        else { return nil }
        return d["AXFontSize"] as? CGFloat
    }

    /// The window's own rendering, read with Vision: each line of text and where it is (window points, top-left origin).
    /// Web content isn't drawn this way (it is its own process): nothing is read there.
    static func renderedTexts(_ w: NSWindow) -> [(String, CGRect)] {
        guard let view = w.contentView?.superview ?? w.contentView, view.bounds.width > 1, view.bounds.height > 1,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return [] }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let image = rep.cgImage else { return [] }
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = false
        req.recognitionLanguages = ["en-US", "zh-Hans"]
        do { try VNImageRequestHandler(cgImage: image, options: [:]).perform([req]) } catch { return [] }
        let r = view.convert(view.bounds, to: nil)          // window base coordinates, bottom-left origin
        let wh = w.frame.height
        return (req.results ?? []).compactMap { obs in
            guard let text = obs.topCandidates(1).first?.string else { return nil }
            let b = obs.boundingBox                          // normalised, bottom-left origin
            return (text, CGRect(x: r.minX + b.minX * r.width, y: wh - r.maxY + (1 - b.maxY) * r.height,
                                 width: b.width * r.width, height: b.height * r.height))
        }
    }

    /// accessibilityValue() is declared with two types (NSAccessibility's Any? and some views' own): ask by selector.
    static func axValue(_ o: AnyObject) -> Any? {
        let sel = NSSelectorFromString("accessibilityValue")
        guard let n = o as? NSObject, n.responds(to: sel) else { return nil }
        return n.perform(sel)?.takeUnretainedValue()
    }

    private static func font(_ attr: NSAttributedString) -> NSFont? {
        if let f = attr.attribute(.font, at: 0, effectiveRange: nil) as? NSFont { return f }
        guard let d = attr.attribute(.accessibilityFont, at: 0, effectiveRange: nil)
                as? [String: Any], let size = d["AXFontSize"] as? CGFloat else { return nil }
        if let name = d["AXFontName"] as? String, let f = NSFont(name: name, size: size) { return f }
        return NSFont.systemFont(ofSize: size)
    }
}
