// BlurtCore/Ink.swift: the in-place markup's rules — the same modifiers for a snap and the
// recording pen, the rough stroke that snaps to a clean line / box / ellipse, shapes stored as point lists every renderer
// draws with sharp corners, the line width, the first-times hint, where the note bubble docks beside the selection,
// the project chip's list; the recording pen's arming (PenArm) and its shape for every press order,
// the stroke being drawn (InkStroke) when a modifier comes and goes mid-drag.
import CoreGraphics
import Foundation
import XCTest
@testable import BlurtCore

final class InkTests: XCTestCase {

    // MARK: modifiers

    func testSnapModifiers() {
        XCTAssertEqual(InkModifiers.snapTool(shift: false, option: false), .free)
        XCTAssertEqual(InkModifiers.snapTool(shift: true, option: false), .box)
        XCTAssertEqual(InkModifiers.snapTool(shift: false, option: true), .ellipse)
        XCTAssertEqual(InkModifiers.snapTool(shift: true, option: true), .box)
    }

    func testTheRecordingPenUsesTheSameModifiersUnderItsKey() {
        func t(_ pen: InkModifiers.PenKey, ctl: Bool = false, opt: Bool = false, sh: Bool = false, cmd: Bool = false, fn: Bool = false) -> InkTool? {
            InkModifiers.recordingTool(pen: pen, control: ctl, option: opt, shift: sh, command: cmd, fn: fn)
        }
        XCTAssertNil(t(.control), "the pen key is not down: off")
        XCTAssertEqual(t(.control, ctl: true), .free)
        XCTAssertEqual(t(.control, ctl: true, sh: true), .box)
        XCTAssertEqual(t(.control, ctl: true, opt: true), .ellipse)
        XCTAssertNil(t(.control, ctl: true, cmd: true), "⌃⌘ is a shortcut, not the pen")
        XCTAssertNil(t(.control, opt: true, sh: true), "⌥⇧ without the pen key draws nothing")
        // ⌥ as the pen key: the ellipse takes ⌃
        XCTAssertEqual(InkModifiers.ellipseKey(pen: .option), .control)
        XCTAssertEqual(t(.option, opt: true), .free)
        XCTAssertEqual(t(.option, ctl: true, opt: true), .ellipse)
        XCTAssertEqual(t(.option, opt: true, sh: true), .box)
        // fn: ⌥ ellipse, ⌃ means nothing here
        XCTAssertEqual(t(.fn, opt: true, fn: true), .ellipse)
        XCTAssertNil(t(.fn, ctl: true, fn: true))
    }

    // MARK: fitting

    private func wobble(_ i: Int) -> CGFloat { CGFloat((i * 37) % 7) - 3 }      // ±3 pt of a hand's shake

    func testARoughLineSnapsStraightAndLevel() {
        let pts = (0...40).map { i in CGPoint(x: 100 + CGFloat(i) * 5, y: 200 + wobble(i) * 0.8 + CGFloat(i) * 0.1) }
        guard case .line(let a, let b)? = InkFit.fit(pts) else { return XCTFail("a line") }
        XCTAssertEqual(a, pts[0])
        XCTAssertEqual(b.y, a.y, "a nearly level line is made level")
        XCTAssertEqual(b.x, pts.last!.x)
        // a steep diagonal stays diagonal
        let diag = (0...30).map { i in CGPoint(x: CGFloat(i) * 4, y: CGFloat(i) * 3 + wobble(i) * 0.5) }
        guard case .line(_, let e)? = InkFit.fit(diag) else { return XCTFail("a diagonal line") }
        XCTAssertEqual(e, diag.last!)
    }

    func testARoughBoxSnapsToItsRectangle() {
        var pts: [CGPoint] = []
        let (x0, y0, x1, y1): (CGFloat, CGFloat, CGFloat, CGFloat) = (50, 60, 250, 180)
        for i in 0..<20 { pts.append(CGPoint(x: x0 + (x1 - x0) * CGFloat(i) / 20, y: y0 + wobble(i) * 0.6)) }
        for i in 0..<12 { pts.append(CGPoint(x: x1 + wobble(i) * 0.6, y: y0 + (y1 - y0) * CGFloat(i) / 12)) }
        for i in 0..<20 { pts.append(CGPoint(x: x1 - (x1 - x0) * CGFloat(i) / 20, y: y1 + wobble(i) * 0.6)) }
        for i in 0...12 { pts.append(CGPoint(x: x0 + wobble(i) * 0.6, y: y1 - (y1 - y0) * CGFloat(i) / 12)) }
        guard case .rect(let r)? = InkFit.fit(pts) else { return XCTFail("a box, got \(String(describing: InkFit.fit(pts)))") }
        XCTAssertEqual(r.minX, x0 - 1.8, accuracy: 3)
        XCTAssertEqual(r.width, 200, accuracy: 6)
    }

    func testARoughCircleSnapsToAnEllipse() {
        let pts = (0...60).map { i -> CGPoint in
            let a = Double(i) / 60 * 2 * .pi
            return CGPoint(x: 300 + (120 + wobble(i)) * CGFloat(cos(a)), y: 300 + (70 + wobble(i)) * CGFloat(sin(a)))
        }
        guard case .ellipse(let r)? = InkFit.fit(pts) else { return XCTFail("an ellipse, got \(String(describing: InkFit.fit(pts)))") }
        XCTAssertEqual(r.midX, 300, accuracy: 4)
        XCTAssertEqual(r.width, 240, accuracy: 8)
    }

    func testAScribbleOrATickStaysFreehand() {
        let tick = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 12), CGPoint(x: 18, y: 20), CGPoint(x: 40, y: -20), CGPoint(x: 60, y: -50)]
        XCTAssertNil(InkFit.fit(tick), "a tick is neither a line nor a loop")
        let zigzag = (0...20).map { i in CGPoint(x: CGFloat(i) * 10, y: i % 2 == 0 ? 0 : 40) }
        XCTAssertNil(InkFit.fit(zigzag))
        XCTAssertNil(InkFit.fit([CGPoint(x: 0, y: 0), CGPoint(x: 3, y: 3), CGPoint(x: 5, y: 5)]), "a dot")
        // an open "C": round, but it doesn't close
        let c = (0...40).map { i -> CGPoint in let a = Double(i) / 40 * 1.3 * .pi; return CGPoint(x: 100 * cos(a), y: 100 * sin(a)) }
        XCTAssertNil(InkFit.fit(c))
    }

    func testShapesFromAModifiedDrag() {
        XCTAssertEqual(InkFit.shape(.box, from: CGPoint(x: 50, y: 40), to: CGPoint(x: 10, y: 90)), .rect(CGRect(x: 10, y: 40, width: 40, height: 50)))
        XCTAssertEqual(InkFit.shape(.ellipse, from: .zero, to: CGPoint(x: 30, y: 20)), .ellipse(CGRect(x: 0, y: 0, width: 30, height: 20)))
        XCTAssertNil(InkFit.shape(.box, from: .zero, to: CGPoint(x: 2, y: 2)), "still a dot")
        XCTAssertNil(InkFit.shape(.free, from: .zero, to: CGPoint(x: 30, y: 30)))
    }

    /// The point list keeps a box's corners sharp under the midpoint smoothing every renderer uses: each corner is
    /// doubled, so the curve through it is a straight segment into and out of the corner.
    func testABoxIsStoredWithDoubledCorners() {
        let pts = InkFit.points(.rect(CGRect(x: 0, y: 0, width: 10, height: 5)))
        XCTAssertEqual(pts.count, 10)
        XCTAssertEqual(pts.first, pts.last)
        for i in stride(from: 0, to: pts.count, by: 2) { XCTAssertEqual(pts[i], pts[i + 1]) }
        // the smoothed path reaches each corner exactly (the midpoint of a doubled point is the point)
        for i in 1..<(pts.count - 1) where pts[i] == pts[i + 1] {
            let mid = CGPoint(x: (pts[i].x + pts[i + 1].x) / 2, y: (pts[i].y + pts[i + 1].y) / 2)
            XCTAssertEqual(mid, pts[i])
        }
        let ell = InkFit.points(.ellipse(CGRect(x: 0, y: 0, width: 20, height: 10)))
        XCTAssertEqual(ell.count, 73)
        XCTAssertEqual(ell.first!.x, ell.last!.x, accuracy: 1e-9)
        XCTAssertEqual(ell.first!.y, ell.last!.y, accuracy: 1e-9)
        for p in ell { XCTAssertEqual(pow((p.x - 10) / 10, 2) + pow((p.y - 5) / 5, 2), 1, accuracy: 1e-9) }
        XCTAssertEqual(InkFit.points(.line(.zero, CGPoint(x: 5, y: 5))).count, 2)
    }

    func testHoldingStill() {
        XCTAssertFalse(InkHold.rested(lastMove: 10, now: 10.3))
        XCTAssertTrue(InkHold.rested(lastMove: 10, now: 10 + InkHold.seconds))
    }

    // MARK: style, hint

    func testTheLineIsWiderOnABiggerDisplay() {
        XCTAssertEqual(InkStyle.width(screenShortSide: 600), 3)
        XCTAssertEqual(InkStyle.width(screenShortSide: 982), 4)       // a 14" MacBook Pro
        XCTAssertEqual(InkStyle.width(screenShortSide: 1440), 5.5)    // a 5K display
        XCTAssertEqual(InkStyle.width(screenShortSide: 3000), 6)
        XCTAssertLessThan(InkStyle.width(screenShortSide: 982), InkStyle.width(screenShortSide: 1440))
    }

    func testTheHintShowsTheFirstFewTimesOnly() {
        XCTAssertTrue(InkHint.shows(alreadyShown: 0))
        XCTAssertTrue(InkHint.shows(alreadyShown: InkHint.times - 1))
        XCTAssertFalse(InkHint.shows(alreadyShown: InkHint.times))
    }

    // MARK: the bubble's dock

    func testTheBubbleDocksBesideTheSelectionNeverOverIt() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 944)
        let bubble = CGSize(width: 340, height: 90)
        // room on the right: there, its top at the selection's top
        var sel = CGRect(x: 200, y: 300, width: 500, height: 300)
        var d = BubbleDock.place(bubble: bubble, selection: sel, screen: screen)
        XCTAssertEqual(d.side, .right)
        XCTAssertEqual(d.origin, CGPoint(x: 712, y: 510))
        XCTAssertFalse(CGRect(origin: d.origin, size: bubble).intersects(sel))
        // near the right edge: it flips to the left
        sel = CGRect(x: 900, y: 300, width: 500, height: 300)
        d = BubbleDock.place(bubble: bubble, selection: sel, screen: screen)
        XCTAssertEqual(d.side, .left)
        XCTAssertEqual(d.origin.x, 900 - 12 - 340)
        XCTAssertFalse(CGRect(origin: d.origin, size: bubble).intersects(sel))
        // a wide selection: below it, its right edge at the selection's
        sel = CGRect(x: 100, y: 300, width: 1300, height: 500)
        d = BubbleDock.place(bubble: bubble, selection: sel, screen: screen)
        XCTAssertEqual(d.side, .below)
        XCTAssertEqual(d.origin, CGPoint(x: 1400 - 340, y: 300 - 12 - 90))
        // wide and low: above it
        sel = CGRect(x: 100, y: 20, width: 1300, height: 700)
        XCTAssertEqual(BubbleDock.place(bubble: bubble, selection: sel, screen: screen).side, .above)
        // a selection near the top: the bubble stays on the screen
        sel = CGRect(x: 100, y: 880, width: 300, height: 60)
        d = BubbleDock.place(bubble: bubble, selection: sel, screen: screen)
        XCTAssertEqual(d.side, .right)
        XCTAssertLessThanOrEqual(d.origin.y + bubble.height, screen.maxY - 8)
        // the whole screen: inside, in the corner — the only time it covers the picture
        d = BubbleDock.place(bubble: bubble, selection: screen, screen: screen)
        XCTAssertEqual(d.side, .inside)
        XCTAssertTrue(screen.contains(CGRect(origin: d.origin, size: bubble)))
        // a second display, left of the main one (negative x): its own coordinates
        let left = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        d = BubbleDock.place(bubble: bubble, selection: CGRect(x: -1900, y: 400, width: 600, height: 300), screen: left)
        XCTAssertEqual(d.side, .right)
        XCTAssertTrue(left.contains(CGRect(origin: d.origin, size: bubble)))
    }

    // MARK: the project chip

    private func p(_ id: String, _ name: String, key: String, used: TimeInterval, inbox: Bool = false) -> Project {
        Project(id: id, name: name, key: key, slug: id, description: "", path: URL(fileURLWithPath: "/tmp/\(id)"),
                store: URL(fileURLWithPath: "/tmp/\(id)/.blurt"), isInbox: inbox, isGitRepo: false, worktree: false, defaultAgent: nil,
                modules: [], lastUsed: Date(timeIntervalSince1970: used), pinned: false)
    }

    func testTheChipListsRecentProjectsAndFilters() {
        let all = [p("a", "Atlas Web", key: "AW", used: 1), p("b", "billing-api", key: "BA", used: 3),
                   p("c", "口喷鸡 iOS", key: "IOS", used: 2), p("inbox", "Inbox", key: "IN", used: 9, inbox: true)]
        XCTAssertEqual(ProjectPick.rows(all, query: "").map(\.id), ["b", "c", "a"], "most recent first, never the inbox")
        XCTAssertEqual(ProjectPick.rows(all, query: "  ").map(\.id), ["b", "c", "a"])
        XCTAssertEqual(ProjectPick.rows(all, query: "ios").map(\.id), ["c"], "by key too, any case")
        XCTAssertEqual(ProjectPick.rows(all, query: "口喷").map(\.id), ["c"])
        XCTAssertEqual(ProjectPick.rows(all, query: "b").map(\.id), ["b", "a"], "the ones that start with it first (\"Atlas Web\" has a b too)")
        XCTAssertEqual(ProjectPick.rows(all, query: "ＡＷ").map(\.id), ["a"], "full-width letters match")
        XCTAssertEqual(ProjectPick.rows(all, query: "zzz"), [])
        XCTAssertEqual(ProjectPick.rows(all, query: "", limit: 2).count, 2)
    }

    /// The chip, the island's switcher and the M popover list the same rows: recent projects (pinned first), then
    /// Unassigned last — while nothing is typed, or when its own name matches.
    func testEveryPickerListsTheSameRowsUnassignedLast() {
        var pinned = p("d", "Docs", key: "DO", used: 0)
        pinned = Project(id: pinned.id, name: pinned.name, key: pinned.key, slug: pinned.slug, description: "", path: pinned.path,
                         store: pinned.store, isInbox: false, isGitRepo: false, worktree: false, defaultAgent: nil, modules: [],
                         lastUsed: pinned.lastUsed, pinned: true)
        let all = [p("a", "Atlas Web", key: "AW", used: 1), p("b", "billing-api", key: "BA", used: 3), pinned]
        XCTAssertEqual(ProjectPick.recent(all).map(\.id), ["d", "b", "a"], "pinned, then recently used")
        XCTAssertEqual(ProjectPick.choices(all, query: "", unassigned: "Unassigned").map(\.id), ["d", "b", "a", "inbox"])
        XCTAssertEqual(ProjectPick.choices(all, query: "", unassigned: "Unassigned", limit: 1), [.project(pinned), .unassigned],
                       "the limit is on projects; Unassigned is always reachable")
        XCTAssertEqual(ProjectPick.choices(all, query: "bill", unassigned: "Unassigned").map(\.id), ["b"])
        XCTAssertEqual(ProjectPick.choices(all, query: "unas", unassigned: "Unassigned").map(\.id), ["inbox"])
        XCTAssertEqual(ProjectPick.choices(all, query: "未归", unassigned: "未归类").map(\.id), ["inbox"])
        XCTAssertNil(ProjectPick.Choice.unassigned.project)
    }

    // MARK: the recording pen: the keys held, never the order they went down in (BA-59)

    /// Replays key presses through the 30 Hz poll (PenArm fed by recordingTool, as Recorder.syncInk does) and returns
    /// what a drag starting `dragAfter` s after the last press draws: nil when the pen is off (the drag is the app's).
    /// `steps`: groups of keys going down; the keys of one group go down in the same poll ("together"), groups 50 ms apart.
    private func dragStart(pen: InkModifiers.PenKey, _ steps: [InkModifiers.Held], dragAfter: Double = 0.3) -> InkTool? {
        var arm = PenArm()
        var held: InkModifiers.Held = []
        var now = 0.0
        var on: InkTool?
        for step in steps {
            held.formUnion(step)
            for _ in 0..<2 { on = arm.update(InkModifiers.recordingTool(pen: pen, held: held), now: now); now += 0.025 }
        }
        let end = now + dragAfter
        while now < end { on = arm.update(InkModifiers.recordingTool(pen: pen, held: held), now: now); now += 1.0 / 30 }
        guard on != nil else { return nil }
        return InkModifiers.dragTool(pen: pen, held: held)        // InkView.mouseDown with the same keys
    }

    /// Every order a set of keys can go down in: one at a time in each permutation, all together, and each pair together.
    private func pressOrders(_ keys: [InkModifiers.Held]) -> [[InkModifiers.Held]] {
        func perms(_ a: [InkModifiers.Held]) -> [[InkModifiers.Held]] {
            a.count <= 1 ? [a] : a.indices.flatMap { i -> [[InkModifiers.Held]] in
                var rest = a
                let x = rest.remove(at: i)
                return perms(rest).map { [x] + $0 }
            }
        }
        var out = perms(keys)
        out.append([keys.reduce(InkModifiers.Held()) { $0.union($1) }])
        if keys.count == 3 {
            for i in 0..<3 {
                let other = keys[i]
                let pair = keys.enumerated().filter { $0.offset != i }.reduce(InkModifiers.Held()) { $0.union($1.element) }
                out.append([pair, other])
                out.append([other, pair])
            }
        }
        return out
    }

    func testEveryPressOrderGivesTheSameShape() {
        let c: InkModifiers.Held = .control, o: InkModifiers.Held = .option, sh: InkModifiers.Held = .shift
        let f: InkModifiers.Held = .fn, cmd: InkModifiers.Held = .command
        let cases: [(InkModifiers.PenKey, [InkModifiers.Held], InkTool?)] = [
            (.control, [c], .free),
            (.control, [c, sh], .box),                 // ⌃ then ⇧, ⇧ then ⌃, ⌃⇧ together: a box (the founder's case)
            (.control, [c, o], .ellipse),              // ⌥ first or together too
            (.control, [c, sh, o], .box),              // ⇧ wins when both shape keys are down, as on a snap
            (.control, [c, cmd], nil),                 // ⌃⌘ is a shortcut in any order
            (.control, [c, sh, cmd], nil),
            (.control, [sh, o], nil),                  // no pen key: never the pen
            (.option, [o, sh], .box),                  // ⌥ as the pen key: ⌃ is the ellipse
            (.option, [o, c], .ellipse),
            (.option, [o, c, sh], .box),
            (.fn, [f, sh], .box),
            (.fn, [f, o], .ellipse),
            (.fn, [f, c], nil),                        // ⌃ means nothing with fn as the pen key
        ]
        for (pen, keys, want) in cases {
            for order in pressOrders(keys) {
                XCTAssertEqual(dragStart(pen: pen, order), want, "pen \(pen), pressed \(order.map(\.rawValue))")
            }
        }
    }

    func testTheShapeFollowsTheKeysWhileDragging() {
        // the drag started as ⌃ (freehand); keys joining or going during it change the tool, in any order
        XCTAssertEqual(InkModifiers.dragTool(pen: .control, held: [.control]), .free)
        XCTAssertEqual(InkModifiers.dragTool(pen: .control, held: [.control, .shift]), .box)
        XCTAssertEqual(InkModifiers.dragTool(pen: .control, held: [.control, .option]), .ellipse)
        // ⌃ let go before ⇧ / ⌥ mid-drag: the shape key alone still says what it said (the pen's window has the drag)
        XCTAssertEqual(InkModifiers.dragTool(pen: .control, held: [.shift]), .box)
        XCTAssertEqual(InkModifiers.dragTool(pen: .control, held: [.option]), .ellipse)
        XCTAssertEqual(InkModifiers.dragTool(pen: .control, held: []), .free)
        // a latched pen (⌥D, no key held): ⇧ / ⌥ alone
        XCTAssertEqual(InkModifiers.dragTool(pen: nil, held: [.shift]), .box)
        // the old Bool form is the same function
        XCTAssertEqual(InkModifiers.recordingTool(pen: .control, control: true, option: false, shift: true, command: false, fn: false),
                       InkModifiers.recordingTool(pen: .control, held: [.control, .shift]))
    }

    func testThePenWaitsAMomentAndThenFollowsTheKeys() {
        var a = PenArm()
        XCTAssertNil(a.update(.box, now: 0), "⌃⇧ just went down together: not yet")
        XCTAssertNil(a.update(.box, now: 0.1))
        XCTAssertEqual(a.update(.box, now: PenArm.settle), .box, "held a moment: on, a box")
        XCTAssertEqual(a.update(.ellipse, now: 0.3), .ellipse, "⇧ up, ⌥ down: an ellipse")
        XCTAssertEqual(a.update(.free, now: 0.4), .free)
        XCTAssertNil(a.update(nil, now: 0.5), "all up: off")
        XCTAssertFalse(a.armed)
        // a quick ⌃-shortcut (⌃A, let go within the settle) never turns it on
        XCTAssertNil(a.update(.free, now: 1))
        XCTAssertNil(a.update(.free, now: 1.1))
        XCTAssertNil(a.update(nil, now: 1.13))
        // ⌘ joining (a shortcut) turns it off and the wait starts again
        XCTAssertNil(a.update(.free, now: 2))
        XCTAssertEqual(a.update(.free, now: 2 + PenArm.settle + 0.01), .free)
        XCTAssertNil(a.update(nil, now: 2.5))
        XCTAssertNil(a.update(.ellipse, now: 2.6))
        XCTAssertEqual(a.update(.ellipse, now: 2.6 + PenArm.settle + 0.01), .ellipse)
    }

    // MARK: the stroke being drawn

    func testAModifierLetGoMidDragCarriesOnFromThePointer() {
        let s = InkStroke(at: CGPoint(x: 0, y: 0), tool: .free, now: 0)
        s.move(to: CGPoint(x: 10, y: 0), tool: .free, now: 0.01)
        // ⇧ down: a box from the start to the pointer
        for (i, x) in stride(from: 20, through: 60, by: 10).enumerated() {
            s.move(to: CGPoint(x: CGFloat(x), y: CGFloat(x) / 2), tool: .box, now: 0.02 + Double(i) * 0.01)
        }
        XCTAssertTrue(s.isShape)
        XCTAssertEqual(s.kind, "box")
        // ⇧ up: freehand again, and the path is where the pointer went (no straight jump from x 10)
        XCTAssertTrue(s.move(to: CGPoint(x: 70, y: 35), tool: .free, now: 0.1))
        XCTAssertFalse(s.isShape)
        XCTAssertEqual(s.kind, "free")
        let pts = s.display
        XCTAssertEqual(pts.last, CGPoint(x: 70, y: 35))
        for (a, b) in zip(pts, pts.dropFirst()) {
            XCTAssertLessThan(hypot(b.x - a.x, b.y - a.y), 15, "no jump in the freehand path")
        }
    }

    func testAShapeAfterASnapIsTheShapeNotTheSnap() {
        let s = InkStroke(at: CGPoint(x: 0, y: 0), tool: .free, now: 0)
        for i in 1...20 { s.move(to: CGPoint(x: CGFloat(i * 5), y: 0), tool: .free, now: Double(i) * 0.01) }
        XCTAssertTrue(s.checkRest(now: 5))
        XCTAssertEqual(s.kind, "line")
        s.move(to: CGPoint(x: 101, y: 1), tool: .ellipse, now: 5.1)
        XCTAssertEqual(s.kind, "ellipse")
    }
}
