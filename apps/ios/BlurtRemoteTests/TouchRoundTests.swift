// The round of 2026-11-24 (docs/design/remote.md): the tabs two by two on a big screen, the scroll edge and its mark, turning the screen.
import XCTest
@testable import BlurtRemote

final class TouchRoundTests: XCTestCase {
    @MainActor
    private func strip(_ names: [String], _ size: CGSize) -> PageStrip {
        let s = PageStrip(frame: CGRect(origin: .zero, size: size))
        s.show(names: names, page: 0)
        s.layoutIfNeeded()
        return s
    }

    @MainActor
    private func labels(_ s: PageStrip) -> [UILabel] { s.subviews.compactMap { $0 as? UILabel } }

    @MainActor
    func testATallStripSetsFourTabsTwoByTwoAndLarger() {
        for names in [["常用", "字母", "符号", "更多"], ["Main", "Letters", "Symbols", "More"]] {
            let s = strip(names, CGSize(width: 144, height: 88))
            let l = labels(s)
            XCTAssertEqual(s.rows, 2)
            XCTAssertGreaterThanOrEqual(l[0].font.pointSize, 15, "\(names)")
            XCTAssertEqual(l[0].frame.minY, l[1].frame.minY)
            XCTAssertEqual(l[0].frame.minX, l[2].frame.minX)
            for x in l {
                XCTAssertGreaterThanOrEqual(x.frame.height, 44)
                XCTAssertLessThanOrEqual(x.intrinsicContentSize.width, x.frame.width, x.text ?? "")
            }
            for (i, x) in l.enumerated() { XCTAssertEqual(s.tab(at: CGPoint(x: x.frame.midX, y: x.frame.midY)), i) }
            XCTAssertEqual(s.tab(at: CGPoint(x: 200, y: 100)), 3, "past the end: the nearest")
        }
    }

    @MainActor
    func testAPhonesStripStaysOneLine() {
        for h in [30, 50] as [CGFloat] {
            let s = strip(["常用", "字母", "符号", "更多"], CGSize(width: 180, height: h))
            XCTAssertEqual(s.rows, 1)
            XCTAssertEqual(labels(s)[0].font.pointSize, 13)
        }
    }

    @MainActor
    func testManyTabsStillFit() {
        for names in [["Main"], ["Main", "More"], ["Main", "Letters", "Symbols", "Vibe Coding", "Switch", "More"],
                      ["常用", "字母", "符号", "Vibe Coding", "切换", "更多", "自定"]] {
            let l = labels(strip(names, CGSize(width: 144, height: 88)))
            for (i, a) in l.enumerated() {
                XCTAssertLessThanOrEqual(a.frame.maxX, 144.5)
                XCTAssertLessThanOrEqual(a.frame.maxY, 88.5)
                for b in l[(i + 1)...] { XCTAssertTrue(a.frame.insetBy(dx: 0.5, dy: 0.5).intersection(b.frame.insetBy(dx: 0.5, dy: 0.5)).isEmpty, "\(names)") }
            }
        }
    }

    func testTheScrollEdgeGrowsWithThePad() {
        XCTAssertEqual(PadLayout.scrollEdgeWidth(140), 32)
        XCTAssertEqual(PadLayout.scrollEdgeWidth(1200), 44)
        XCTAssertEqual(PadLayout.scrollEdge(width: 400, left: false), 364...400)
        XCTAssertEqual(PadLayout.scrollEdge(width: 874, left: true, inset: 62).upperBound, 106, "full screen: past the island")
    }

    /// On its side the thumb is at the end without the island, so that's where one finger scrolls: whichever hand, whatever Left-Handed says.
    func testOnItsSideTheEdgeIsByTheThumb() {
        for island in [true, false] {
            for lefty in [true, false] {
                let l = PadLayout(size: CGSize(width: 874, height: 402), safe: UIEdgeInsets(top: 0, left: 62, bottom: 21, right: 62), lefty: lefty, islandLeft: island)
                XCTAssertEqual(l.scrollsLeft, !island)
                XCTAssertEqual(l.scrollEdge.lowerBound <= 0, !island)
            }
        }
    }

    func testTheMarkIsInsideItsEdgeAndHalfAsTall() {
        for room in Rooms.all {
            for lefty in [true, false] {
                let l = PadLayout(size: room.size, safe: room.safe, lefty: lefty, surround: room.surround)
                let ys = l.scrollEdgeY ?? 0...l.pad.height
                let m = PadLayout.edgeMark(l.scrollEdge, y: ys, width: l.pad.width)
                XCTAssertTrue(l.scrollEdge.contains(m.minX) && l.scrollEdge.contains(m.maxX), room.name)
                XCTAssertTrue(ys.contains(m.minY) && ys.contains(m.maxY), room.name)
                XCTAssertGreaterThanOrEqual(m.height, min(96, ys.upperBound - ys.lowerBound - 24), room.name)
            }
        }
    }

    func testOnlyAPhoneIsTurned() {
        let phone = UIDevice.current.userInterfaceIdiom == .phone
        XCTAssertEqual(ScreenTurn.landscape.mask, phone ? .landscape : .all)
        XCTAssertEqual(ScreenTurn.portrait.mask, phone ? .portrait : .all)
        XCTAssertEqual(ScreenTurn.auto.mask, .all)
    }
}
