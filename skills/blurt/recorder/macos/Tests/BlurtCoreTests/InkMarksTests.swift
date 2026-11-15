// BlurtCore/InkMarks.swift: the snap's markup tools — the tool chosen from ⌘-letters (bare letters type the note), what
// a drag makes with each tool and modifier, the arrow's head, the mosaic's block size, the text box staying inside the
// picture, the marks kept next to the old strokes, undo / redo, and where the tool strip goes.
import CoreGraphics
import Foundation
import XCTest
@testable import BlurtCore

final class InkMarksTests: XCTestCase {

    // MARK: the tool from the keys

    private func key(_ c: String, cmd: Bool = true, shift: Bool = false, opt: Bool = false, ctl: Bool = false) -> InkPick? {
        InkPick.forCommandKey(c, command: cmd, shift: shift, option: opt, control: ctl)
    }

    func testEachToolHasItsCommandLetter() {
        XCTAssertEqual(key("p"), .pen)
        XCTAssertEqual(key("r"), .box)
        XCTAssertEqual(key("o"), .ellipse)
        XCTAssertEqual(key("l"), .arrow)
        XCTAssertEqual(key("t"), .text)
        XCTAssertEqual(key("m"), .mosaic)
        XCTAssertEqual(key("T"), .text, "caps lock on")
        XCTAssertEqual(Set(InkPick.allCases.map(\.key)).count, InkPick.allCases.count, "one letter each")
        XCTAssertEqual(InkPick.arrow.keyLabel, "⌘L")
    }

    func testBareLettersAlwaysTypeTheNote() {
        for c in ["p", "r", "o", "l", "t", "m", "a"] { XCTAssertNil(key(c, cmd: false), c) }
        XCTAssertNil(key("p", cmd: false, shift: true))
    }

    func testTheNotesOwnCommandKeysStayTheNotes() {
        // ⌘A select all, ⌘C ⌘V ⌘X copy / paste / cut, ⌘Z undo: never a tool
        for c in ["a", "c", "v", "x", "z"] { XCTAssertNil(key(c), c) }
        // ⌘-digits are the type (NoteKeys); other modifiers with a tool's letter are not the tool
        for d in 0...9 { XCTAssertNil(key("\(d)")) }
        XCTAssertNil(key("t", shift: true))
        XCTAssertNil(key("t", opt: true))
        XCTAssertNil(key("t", ctl: true))
        XCTAssertNil(key(""))
    }

    // MARK: what a drag makes

    func testThePenKeepsTheZeroClickModifiers() {
        XCTAssertEqual(InkSnapDrag.decide(.pen, shift: false, option: false), .stroke(.free, constrained: false))
        XCTAssertEqual(InkSnapDrag.decide(.pen, shift: true, option: false), .stroke(.box, constrained: false))
        XCTAssertEqual(InkSnapDrag.decide(.pen, shift: false, option: true), .stroke(.ellipse, constrained: false))
        XCTAssertEqual(InkSnapDrag.decide(.pen, shift: true, option: true), .stroke(.arrow, constrained: false))
    }

    func testAChosenShapeIsDrawnPlainAndShiftConstrainsIt() {
        XCTAssertEqual(InkSnapDrag.decide(.box, shift: false, option: false), .stroke(.box, constrained: false))
        XCTAssertEqual(InkSnapDrag.decide(.box, shift: true, option: false), .stroke(.box, constrained: true))
        XCTAssertEqual(InkSnapDrag.decide(.ellipse, shift: true, option: false), .stroke(.ellipse, constrained: true))
        XCTAssertEqual(InkSnapDrag.decide(.arrow, shift: false, option: true), .stroke(.arrow, constrained: false))
        XCTAssertEqual(InkSnapDrag.decide(.text, shift: true, option: true), .text)
        XCTAssertEqual(InkSnapDrag.decide(.mosaic, shift: false, option: false), .mosaic(brush: false))
        XCTAssertEqual(InkSnapDrag.decide(.mosaic, shift: true, option: false), .mosaic(brush: true))
    }

    func testShiftMakesASquareACircleOrA45DegreeArrow() {
        let a = CGPoint(x: 10, y: 10)
        XCTAssertEqual(InkFit.constrain(.box, from: a, to: CGPoint(x: 50, y: 20)), CGPoint(x: 50, y: 50))
        XCTAssertEqual(InkFit.constrain(.ellipse, from: a, to: CGPoint(x: -20, y: 0)), CGPoint(x: -20, y: -20))
        let p = InkFit.constrain(.arrow, from: a, to: CGPoint(x: 110, y: 20))      // ~6°: level
        XCTAssertEqual(p.y, 10, accuracy: 0.001)
        let q = InkFit.constrain(.arrow, from: a, to: CGPoint(x: 60, y: 55))       // ~42°: on 45°
        XCTAssertEqual(q.x - a.x, q.y - a.y, accuracy: 0.001)
    }

    // MARK: arrow

    func testTheArrowHeadGrowsWithTheLineAndStaysShortOnAShortArrow() {
        XCTAssertEqual(InkArrow.headLength(width: 4, shaft: 200), 18)
        XCTAssertEqual(InkArrow.headLength(width: 2, shaft: 200), 12, "never under 12")
        XCTAssertEqual(InkArrow.headLength(width: 6, shaft: 200), 27)
        XCTAssertEqual(InkArrow.headLength(width: 6, shaft: 20), 9, "45 % of a short shaft")
    }

    func testTheHeadIsSymmetricBehindTheTip() {
        let (l, r) = InkArrow.head(tail: CGPoint(x: 0, y: 0), tip: CGPoint(x: 100, y: 0), width: 4)
        XCTAssertEqual(l.x, 82, accuracy: 0.001)
        XCTAssertEqual(r.x, 82, accuracy: 0.001)
        XCTAssertEqual(l.y, -r.y, accuracy: 0.001)
        XCTAssertEqual(abs(l.y), 18 * InkArrow.spread, accuracy: 0.001)
    }

    func testAnArrowIsOnePointListWithItsCornersDoubled() {
        let tail = CGPoint(x: 0, y: 0), tip = CGPoint(x: 0, y: 100)
        let pts = InkArrow.points(tail: tail, tip: tip, width: 4)
        XCTAssertEqual(pts.count, 9)
        XCTAssertEqual(pts.first, tail)
        XCTAssertEqual(pts.last, tip)
        XCTAssertEqual(pts[1], pts[2])
        XCTAssertEqual(pts[3], pts[4])
        XCTAssertEqual(pts[5], pts[6])
        XCTAssertEqual(InkFit.points(.arrow(tail, tip, width: 4)), pts)
        // a stroke drawn with the arrow keeps that list
        let s = InkStroke(at: tail, tool: .arrow, lineWidth: 4, now: 0)
        s.move(to: tip, tool: .arrow, now: 0.1)
        XCTAssertEqual(s.kind, "arrow")
        XCTAssertEqual(s.kept(minGap: 2), pts)
    }

    // MARK: mosaic

    func testTheMosaicBlockFollowsThePicturesScale() {
        XCTAssertEqual(InkMosaic.block(pixelsPerPoint: 2, shortSidePx: 800), 24, "12 pt on a Retina picture")
        XCTAssertEqual(InkMosaic.block(pixelsPerPoint: 1, shortSidePx: 600), 12)
        XCTAssertEqual(InkMosaic.block(pixelsPerPoint: 2, shortSidePx: 3200), 50, "a big picture: a 64th of its short side")
        XCTAssertEqual(InkMosaic.block(pixelsPerPoint: 0.3, shortSidePx: 100), 12, "scale under 1 counts as 1")
        XCTAssertGreaterThanOrEqual(InkMosaic.block(pixelsPerPoint: 0, shortSidePx: 0), 6)
    }

    func testTheMosaicRectAndBrush() {
        XCTAssertEqual(InkMosaic.rect(from: CGPoint(x: 50, y: 40), to: CGPoint(x: 10, y: 10)), CGRect(x: 10, y: 10, width: 40, height: 30))
        XCTAssertNil(InkMosaic.rect(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 12, y: 11)), "a click is no mosaic")
        XCTAssertEqual(InkMosaic.brush(lineWidth: 3), 24)
        XCTAssertEqual(InkMosaic.brush(lineWidth: 6), 36)
    }

    // MARK: text

    func testTheTextSizeFollowsThePicture() {
        XCTAssertEqual(InkText.fontSize(pictureShortSide: 200), 16, "never under 16")
        XCTAssertEqual(InkText.fontSize(pictureShortSide: 440), 20)
        XCTAssertEqual(InkText.fontSize(pictureShortSide: 982), 28, "never over 28")
    }

    func testTheTextBoxStartsAtTheClickAndStaysInsideThePicture() {
        let pic = CGRect(x: 0, y: 0, width: 400, height: 300)
        let size = CGSize(width: 120, height: 24)
        XCTAssertEqual(InkText.box(at: CGPoint(x: 50, y: 100), size: size, lineHeight: 24, in: pic),
                       CGRect(x: 50, y: 88, width: 120, height: 24), "left edge at the click, the line centred on it")
        XCTAssertEqual(InkText.box(at: CGPoint(x: 350, y: 295), size: size, lineHeight: 24, in: pic),
                       CGRect(x: 280, y: 276, width: 120, height: 24), "near the corner: moved in, whole")
        XCTAssertEqual(InkText.box(at: CGPoint(x: -5, y: 2), size: size, lineHeight: 24, in: pic).origin, CGPoint(x: 0, y: 0))
        // wider than the picture: its top-left stays in
        XCTAssertEqual(InkText.box(at: CGPoint(x: 100, y: 100), size: CGSize(width: 500, height: 24), lineHeight: 24, in: pic).minX, 0)
    }

    func testAnEmptyTextBoxMakesNoMark() {
        XCTAssertNil(InkText.clean("  \n "))
        XCTAssertEqual(InkText.clean(" 这里 \n"), "这里")
        XCTAssertNil(InkMark(json: ["kind": "text", "points": [[0.1, 0.1]], "text": " "]))
    }

    // MARK: kept

    func testMarksRoundTripAndOldReadersKeepTheirStrokes() {
        let marks = [
            InkMark(kind: .pen, points: [[0.1, 0.1], [0.2, 0.2]]),
            InkMark(kind: .arrow, color: .blue, points: [[0.1, 0.5], [0.4, 0.5], [0.4, 0.5]]),
            InkMark(kind: .text, color: .yellow, points: [[0.3, 0.3]], text: "这里不对", size: 0.06),
            InkMark(kind: .mosaic, points: [[0.5, 0.5], [0.9, 0.7]]),
            InkMark(kind: .mosaic, points: [[0.1, 0.8], [0.2, 0.85]], size: 0.05, brush: true),
        ]
        let json = marks.map(\.json)
        let data = try! JSONSerialization.data(withJSONObject: json)
        let back = InkMark.parse(try! JSONSerialization.jsonObject(with: data))
        XCTAssertEqual(back, marks)
        // "strokes": the lines only, in order — text and mosaic are in the marked picture
        XCTAssertEqual(InkMark.strokes(marks), [[[0.1, 0.1], [0.2, 0.2]], [[0.1, 0.5], [0.4, 0.5], [0.4, 0.5]]])
    }

    func testAnOlderCapturesStrokesAreBrandColouredPenMarks() {
        XCTAssertNil(InkMark.parse(nil), "no marks key: build them from the strokes")
        let m = InkMark.fromStrokes([[[0.1, 0.2]], [], [[0.3, 0.3], [0.4, 0.4]]])
        XCTAssertEqual(m.count, 2)
        XCTAssertTrue(m.allSatisfy { $0.kind == .pen && $0.color == .markup })
        XCTAssertEqual(InkMark.strokes(m), [[[0.1, 0.2]], [[0.3, 0.3], [0.4, 0.4]]])
        // a newer build's colour or a broken entry: read as well as it can be
        XCTAssertEqual(InkMark(json: ["kind": "pen", "color": "violet", "points": [[0.1, 0.1]]])?.color, .markup)
        XCTAssertNil(InkMark(json: ["kind": "laser", "points": [[0.1, 0.1]]]))
        XCTAssertNil(InkMark(json: ["kind": "pen", "points": []]))
    }

    func testMosaicsAreDrawnFirstUnderTheInk() {
        let pen = InkMark(kind: .pen, points: [[0, 0]]), mo = InkMark(kind: .mosaic, points: [[0, 0], [1, 1]])
        let text = InkMark(kind: .text, points: [[0, 0]], text: "x", size: 0.05)
        XCTAssertEqual(InkMark.drawOrder([pen, mo, text]), [mo, pen, text])
    }

    func testTheBrandColourComesFirst() {
        XCTAssertEqual(InkColor.allCases.first, .markup)
        XCTAssertEqual(InkColor.markup.rgb, 0xFF5C3D, "BrandColor.markup")
        XCTAssertTrue(InkColor.black.outlineIsLight)
        XCTAssertFalse(InkColor.white.outlineIsLight)
    }

    // MARK: undo / redo

    func testUndoRedoAcrossAllMarks() {
        let a = InkMark(kind: .pen, points: [[0, 0]]), b = InkMark(kind: .text, points: [[0, 0]], text: "x", size: 0.05)
        let c = InkMark(kind: .mosaic, points: [[0, 0], [1, 1]])
        var h = InkHistory()
        XCTAssertFalse(h.undo())
        h.add(a); h.add(b); h.add(c)
        XCTAssertTrue(h.undo())
        XCTAssertTrue(h.undo())
        XCTAssertEqual(h.marks, [a])
        XCTAssertTrue(h.redo())
        XCTAssertEqual(h.marks, [a, b])
        h.add(a)
        XCTAssertFalse(h.canRedo, "a new mark clears what was undone")
        h.reset([c])
        XCTAssertEqual(h.marks, [c])
        XCTAssertFalse(h.canRedo)
    }

    // MARK: the strip

    func testTheStripGoesUnderTheSelectionRightAligned() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 944)
        let sel = CGRect(x: 300, y: 300, width: 500, height: 300)
        let o = StripDock.place(strip: CGSize(width: 320, height: 40), selection: sel, screen: screen)
        XCTAssertEqual(o, CGPoint(x: 480, y: 252))
    }

    func testTheStripNeverCoversTheBubbleOrLeavesTheScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 944)
        let sel = CGRect(x: 300, y: 300, width: 200, height: 300)
        // a strip wider than the selection, a bubble on the left hanging below the selection: left-aligned instead
        let bubble = CGRect(x: 0, y: 150, width: 288, height: 450)
        let o = StripDock.place(strip: CGSize(width: 320, height: 40), selection: sel, screen: screen, avoid: bubble)
        XCTAssertFalse(CGRect(origin: o, size: CGSize(width: 320, height: 40)).intersects(bubble))
        XCTAssertEqual(o.y, 252)
        // no room under it: above it
        let low = CGRect(x: 300, y: 20, width: 500, height: 300)
        XCTAssertEqual(StripDock.place(strip: CGSize(width: 320, height: 40), selection: low, screen: screen).y, 328)
        // the whole screen: inside, along its bottom
        let all = StripDock.place(strip: CGSize(width: 320, height: 40), selection: screen, screen: screen)
        XCTAssertTrue(screen.contains(CGRect(origin: all, size: CGSize(width: 320, height: 40))))
    }
}
