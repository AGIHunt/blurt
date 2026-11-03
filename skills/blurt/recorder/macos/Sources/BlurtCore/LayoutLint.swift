// The layout lint's rules (the app's `layoutcheck` test hook walks every visible window's accessibility tree and hands
// the elements here): pure geometry, so the rules are unit-tested without a window.
//   outside_window       a button / text / control / labelled image not fully inside its window. The title bar counts
//                        as inside (a full-size content view puts controls there on purpose). Texts and images get 4 pt
//                        of tolerance (their accessibility frames carry line padding); a control's frame is its bezel,
//                        so more than 1 pt past the edge is a visibly cut control (the setup assistant's Next button,
//                        2 pt under the window's bottom edge, was the bug that made this lint).
//   under_traffic_lights such an element under the close / minimise / zoom buttons
//   overlap              two interactive elements on top of each other (one inside the other doesn't count)
//   truncated            a text the app measured as not fitting its frame (the app decides; see LayoutCheck.swift),
//                        or a button / pop-up / menu button whose title doesn't fit: an AppKit control by its cell, a
//                        SwiftUI button by its label at the accessibility tree's font plus the least bezel its height
//                        implies (controlTitleClipped), and — for what geometry can't see, a label with more in it than
//                        its words (a split button's chevron) — the window's rendering read back, where a title that
//                        shows as its own beginning plus "…" is cut (cutTitles). Icon-only buttons have no title to cut.
// A scroll bar counts as a control: one past the window edge can't be seen or dragged.
// Elements inside a scroll area are judged by the part the scroll area shows: scrolled out of sight is not a problem,
// but a scroll area that itself runs past the window edge is (its visible rows come out cut off).
// Frames are window coordinates, top-left origin, in points.
import CoreGraphics
import Foundation

public struct LayoutNode {
    public var role: String
    public var subrole: String
    public var label: String
    public var frame: CGRect
    /// What the enclosing scroll areas show (their intersection), nil outside any
    public var clip: CGRect?
    /// Index of the parent in the same array, nil for the window's own children
    public var parent: Int?
    public var truncated: Bool

    public init(role: String, subrole: String = "", label: String = "", frame: CGRect, clip: CGRect? = nil, parent: Int? = nil,
                truncated: Bool = false) {
        self.role = role; self.subrole = subrole; self.label = label; self.frame = frame; self.clip = clip
        self.parent = parent; self.truncated = truncated
    }
}

public struct LayoutProblem: Equatable {
    public var kind: String
    public var role: String
    public var label: String
    public var frame: CGRect
    /// outside_window: the window's area; under_traffic_lights: the buttons'; overlap: the other element's frame
    public var bounds: CGRect
    /// overlap: the other element's label
    public var other: String?
    public var subrole: String = ""

    public var json: [String: Any] {
        var o: [String: Any] = ["kind": kind, "role": role, "label": label, "frame": LayoutLint.array(frame),
                                "bounds": LayoutLint.array(bounds)]
        if let other { o["other"] = other }
        if !subrole.isEmpty { o["subrole"] = subrole }
        return o
    }
}

public enum LayoutLint {
    public static let tolerance: CGFloat = 4
    /// A control's bezel past the window edge by more than this is cut off
    public static let controlTolerance: CGFloat = 1

    /// Controls a person clicks or types into.
    public static let interactive: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXTextField", "AXTextArea",
        "AXSlider", "AXComboBox", "AXLink", "AXDisclosureTriangle", "AXIncrementor", "AXSegmentedControl", "AXColorWell",
        "AXDateField", "AXStepper",
    ]
    /// The window's own title-bar buttons (they are the traffic lights, not content)
    public static let trafficLights: Set<String> = ["AXCloseButton", "AXMinimizeButton", "AXZoomButton", "AXFullScreenButton"]

    /// A scroll bar's own parts (arrows, page areas, the knob): the bar is checked as a whole
    public static let scrollBarParts: Set<String> = ["AXIncrementArrow", "AXDecrementArrow", "AXIncrementPage", "AXDecrementPage"]

    /// The elements the lint looks at: controls, scroll bars, texts, images that say something.
    public static func checked(_ n: LayoutNode) -> Bool {
        if trafficLights.contains(n.subrole) || scrollBarParts.contains(n.subrole) { return false }
        if interactive.contains(n.role) || n.role == "AXStaticText" || n.role == "AXScrollBar" { return true }
        return n.role == "AXImage" && !n.label.isEmpty
    }

    /// The part of the element a person can see (nil: scrolled out of sight, or no size at all).
    public static func visible(_ n: LayoutNode) -> CGRect? {
        guard n.frame.width > 0.5, n.frame.height > 0.5 else { return nil }
        guard let c = n.clip else { return n.frame }
        let r = n.frame.intersection(c)
        return r.isNull || r.width < 0.5 || r.height < 0.5 ? nil : r
    }

    public static func check(_ nodes: [LayoutNode], window size: CGSize, trafficLights lights: [CGRect] = []) -> [LayoutProblem] {
        let bounds = CGRect(origin: .zero, size: size)
        let allowed = bounds.insetBy(dx: -tolerance, dy: -tolerance)
        let allowedControl = bounds.insetBy(dx: -controlTolerance, dy: -controlTolerance)
        var out: [LayoutProblem] = []
        var seen = Set<String>()
        func add(_ p: LayoutProblem, _ n: LayoutNode) {
            var p = p
            p.subrole = n.subrole
            // the same element reached twice (SwiftUI exposes some nodes under two parents) is one problem
            let key = "\(p.kind)|\(p.role)|\(p.label)|\(Int(p.frame.minX)),\(Int(p.frame.minY)),\(Int(p.frame.width)),\(Int(p.frame.height))|\(p.other ?? "")"
            if seen.insert(key).inserted { out.append(p) }
        }
        var shown: [(Int, CGRect)] = []
        for (i, n) in nodes.enumerated() where checked(n) {
            guard let v = visible(n) else { continue }
            shown.append((i, v))
            let control = interactive.contains(n.role) || n.role == "AXScrollBar"
            if !(control ? allowedControl : allowed).contains(v) {
                add(LayoutProblem(kind: "outside_window", role: n.role, label: n.label, frame: v, bounds: bounds), n)
            }
            for l in lights {
                let x = v.intersection(l.insetBy(dx: 1, dy: 1))
                if !x.isNull, x.width > tolerance / 2, x.height > tolerance / 2 {
                    add(LayoutProblem(kind: "under_traffic_lights", role: n.role, label: n.label, frame: v, bounds: l), n)
                    break
                }
            }
            if n.truncated { add(LayoutProblem(kind: "truncated", role: n.role, label: n.label, frame: v, bounds: n.frame), n) }
        }
        // overlaps between controls (a control inside another — a button's own image, a row's button — is not one)
        let controls = shown.filter { interactive.contains(nodes[$0.0].role) }
        for a in 0..<controls.count {
            for b in (a + 1)..<max(a + 1, controls.count) {
                let (i, ri) = controls[a], (j, rj) = controls[b]
                if related(i, j, nodes) { continue }
                let x = ri.intersection(rj)
                guard !x.isNull, x.width > tolerance / 2, x.height > tolerance / 2 else { continue }
                // the same control reported twice (identical frame, role and label) is not two controls
                if ri == rj, nodes[i].role == nodes[j].role, nodes[i].label == nodes[j].label { continue }
                add(LayoutProblem(kind: "overlap", role: nodes[i].role, label: nodes[i].label, frame: ri, bounds: rj,
                                  other: "\(nodes[j].role) \(nodes[j].label)"), nodes[i])
            }
        }
        return out
    }

    // MARK: control titles

    /// Buttons, pop-ups and menu buttons: the controls whose title can be cut.
    public static let titled: Set<String> = ["AXButton", "AXPopUpButton", "AXMenuButton"]

    /// A button that shows an icon, not its label (the label is only for VoiceOver): about square, or labelled with an
    /// SF Symbol (SwiftUI names an image-only button's element after its symbol). Its label was never meant to fit.
    public static func iconOnly(frame: CGSize, symbolIdentifier: Bool = false) -> Bool {
        symbolIdentifier || frame.width < frame.height * 1.75
    }

    /// A SwiftUI button's title is cut: the label at its font, plus the least bezel padding its height allows, is wider
    /// than the button. A bezel (bordered, prominent, the default style) makes the button at least 4 pt taller than a
    /// line of its font and adds about its own height in side padding (measured: 16 pt mini, 20 small, 24 regular, 28
    /// large); three quarters of that is counted, so a button that fits is never flagged. A plain / borderless one is
    /// as tall as its line and adds nothing. Anything else in the label (an icon, a split button's chevron) only makes
    /// the real need larger — that is cutTitles' to find.
    public static func controlTitleClipped(titleWidth: CGFloat, fontSize: CGFloat, frame: CGSize) -> Bool {
        guard titleWidth > 0, frame.width > 1, frame.height > 1 else { return false }
        let line = (fontSize * 1.25).rounded(.up)
        let chrome = frame.height >= line + 4 ? frame.height * 0.75 : 0
        return titleWidth + chrome > frame.width + 1.5
    }

    /// An AppKit pop-up (NSPopUpButtonCell): its title is wider than the rect the cell draws it in.
    public static func popupTitleClipped(titleWidth: CGFloat, titleRectWidth: CGFloat) -> Bool {
        titleWidth > 0 && titleRectWidth >= 0 && titleWidth > titleRectWidth + 1
    }

    static func normalized(_ s: String) -> String {
        s.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation }
    }

    /// What the window shows for a title (read back from its rendering) is that title cut: the beginning of it, then
    /// "…" (or "..."), and the title itself doesn't end so. What the reading puts after the "…" — a split button's
    /// divider and chevron ("| v"), a pop-up's arrows — is a few marks at most. Case, spaces and punctuation don't
    /// count (the reading isn't exact about them).
    public static func showsCut(label: String, shown: String) -> Bool {
        let t = shown.trimmingCharacters(in: .whitespacesAndNewlines)
        let l = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !l.hasSuffix("…"), !l.hasSuffix("..."),
              let cut = ["…", "..."].compactMap({ t.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound }),
              t[cut.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: ". ")).count <= 3 else { return false }
        let stem = normalized(String(t[..<cut.lowerBound]))
        let whole = normalized(l)
        return stem.count >= 2 && stem.count < whole.count && whole.hasPrefix(stem)
    }

    /// The titled controls (by index) whose rendering shows their title cut: a piece of text read inside the control's
    /// frame (its centre inside) that showsCut says is its label's beginning plus "…". `texts`: what was read, with
    /// where (window points, top-left origin).
    public static func cutTitles(_ nodes: [LayoutNode], texts: [(String, CGRect)]) -> Set<Int> {
        var out = Set<Int>()
        for (i, n) in nodes.enumerated() where titled.contains(n.role) && !n.label.isEmpty {
            guard let v = visible(n) else { continue }
            let box = v.insetBy(dx: -2, dy: -2)
            if texts.contains(where: { box.contains(CGPoint(x: $0.1.midX, y: $0.1.midY)) && showsCut(label: n.label, shown: $0.0) }) {
                out.insert(i)
            }
        }
        return out
    }

    /// One is the other's ancestor.
    static func related(_ a: Int, _ b: Int, _ nodes: [LayoutNode]) -> Bool {
        func isAncestor(_ x: Int, of y: Int) -> Bool {
            var p = nodes[y].parent
            var guardN = 0
            while let q = p, guardN < 200 { if q == x { return true }; p = nodes[q].parent; guardN += 1 }
            return false
        }
        return isAncestor(a, of: b) || isAncestor(b, of: a)
    }

    public static func array(_ r: CGRect) -> [Double] {
        [r.minX, r.minY, r.width, r.height].map { (Double($0) * 10).rounded() / 10 }
    }
}
