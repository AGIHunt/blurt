// BlurtCore/IslandLayout.swift: ears anchored to the island's outer edges, toasts that line up with the island, the
// time left rounded up, the live-text panel in the island's width family, and aspect-aware snap cards.
import XCTest
@testable import BlurtCore

final class IslandLayoutTests: XCTestCase {
    // a 14" MacBook Pro: notch 185 pt, island 297 pt from x 0
    let notch: CGFloat = 185
    var islandW: CGFloat { notch + 2 * IslandLayout.earWidth }

    /// The dogfood's stop tap: the keyboard + level (39 pt) and the wand (15 pt) start at the same x, and the clock,
    /// the dots and the count end at the same x.
    func testEarContentKeepsOneEdgeAcrossStates() {
        let leftOuter: CGFloat = 0, leftInner = IslandLayout.earWidth
        let listening = IslandLayout.earOrigin(.left, width: 39, outer: leftOuter, inner: leftInner)
        let polishing = IslandLayout.earOrigin(.left, width: 15, outer: leftOuter, inner: leftInner)
        XCTAssertEqual(listening, polishing)
        XCTAssertEqual(listening, IslandLayout.earInset)
        let rightOuter = islandW, rightInner = islandW - IslandLayout.earWidth
        let clock = IslandLayout.earOrigin(.right, width: 28, outer: rightOuter, inner: rightInner) + 28
        let dots = IslandLayout.earOrigin(.right, width: 20, outer: rightOuter, inner: rightInner) + 20
        let count = IslandLayout.earOrigin(.right, width: 17, outer: rightOuter, inner: rightInner) + 17
        XCTAssertEqual(clock, dots)
        XCTAssertEqual(dots, count)
        XCTAssertEqual(rightOuter - count, IslandLayout.earInset)
    }

    func testWideEarContentGivesUpTheInsetBeforeTheNotch() {
        let x = IslandLayout.earOrigin(.left, width: 50, outer: 0, inner: IslandLayout.earWidth)
        XCTAssertLessThan(x, IslandLayout.earInset)
        XCTAssertLessThanOrEqual(x + 50, IslandLayout.earWidth - 2, "never under the notch")
        let r = IslandLayout.earOrigin(.right, width: 50, outer: islandW, inner: islandW - IslandLayout.earWidth)
        XCTAssertGreaterThanOrEqual(r, islandW - IslandLayout.earWidth + 2)
    }

    /// "✓ 已发送" (check 12 + gap 4 + ~39 pt of text): the ear widens so the word keeps the 14 pt inset (v0.9 dogfood:
    /// it sat 4 pt from the rounded corner).
    func testTheSentWordKeepsTheInset() {
        let content: CGFloat = 55
        let ear = IslandLayout.earWidth(content: content)
        XCTAssertEqual(ear, 71)
        let r: CGFloat = 600                              // the notch's right edge
        let x = IslandLayout.earOrigin(.right, width: content, outer: r + ear, inner: r)
        XCTAssertEqual(r + ear - (x + content), IslandLayout.earInset)
        XCTAssertEqual(IslandLayout.earWidth(content: 30), IslandLayout.earWidth)   // a short one: the usual ear
    }

    func testCapsuleEarsUseTheSameInset() {
        XCTAssertEqual(IslandLayout.earOrigin(.left, width: 30, outer: 100, inner: nil), 114)
        XCTAssertEqual(IslandLayout.earOrigin(.right, width: 30, outer: 300, inner: nil), 256)
    }

    /// "没听到内容" on a notched Mac: the content spans the whole shape and the line is centred in it.
    func testAShortLineIsCentredInTheWholeShape() {
        let floor = IslandLayout.toastFloor(notchWidth: notch)
        XCTAssertEqual(floor, islandW)
        let t = IslandLayout.toast(text: 70, lead: 0, button: nil, floor: floor, maxWidth: 480)
        XCTAssertEqual(t.width, islandW, "the content box is the shape, not a narrower box centred in it")
        XCTAssertEqual(t.leadX + t.textWidth / 2, islandW / 2, accuracy: 0.5)
    }

    /// "这条像清单 [排成清单]": text at 18 pt, the button's right edge 14 pt in (under the right ear's number).
    func testALineWithAButtonLinesUpWithTheEars() {
        let t = IslandLayout.toast(text: 90, lead: 0, button: 72, floor: IslandLayout.toastFloor(notchWidth: notch), maxWidth: 480)
        XCTAssertEqual(t.leadX, IslandLayout.toastInset)
        XCTAssertEqual(t.width - (t.buttonX! + 72), IslandLayout.earInset)
        XCTAssertEqual(t.width, islandW)
    }

    func testALongLineGrowsTheShapeUpToTheOpenWidth() {
        let t = IslandLayout.toast(text: 600, lead: 24, button: 60, floor: 297, maxWidth: 480)
        XCTAssertEqual(t.width, 480)
        XCTAssertEqual(t.leadX + 24 + t.textWidth + 10 + 60 + IslandLayout.earInset, 480, accuracy: 0.5, "cut short, not overlapping the button")
    }

    func testTheMascotLineStartsAtTheEdge() {
        let t = IslandLayout.toast(text: 80, lead: 64, art: true, button: nil, floor: 297, maxWidth: 480)
        XCTAssertEqual(t.leadX, 0)
    }

    func testCapsuleFloor() {
        XCTAssertEqual(IslandLayout.toastFloor(notchWidth: nil), 260)
    }

    /// 40 s cap, 37.6 s in: "0:37" and "0:03" — they add up to the limit.
    func testTimeLeftRoundsUpSoItAddsUpWithTheClock() {
        XCTAssertEqual(IslandLayout.timeLeft(limit: 40, elapsed: 37.6), 3)
        XCTAssertEqual(Int(37.6) + IslandLayout.timeLeft(limit: 40, elapsed: 37.6), 40)
        XCTAssertEqual(IslandLayout.timeLeft(limit: 40, elapsed: 41), 0)
        XCTAssertEqual(IslandLayout.timeLeft(limit: 600, elapsed: 540), 60)
    }

    func testLivePanelIsInTheIslandsWidthFamily() {
        // dictation: the ears only → a little wider than them, not a 460 pt slab
        let d = IslandLayout.livePanelWidth(islandWidth: 297, open: false, screenWidth: 1728)
        XCTAssertEqual(d, 345)
        XCTAssertLessThanOrEqual(d - 297, 48)
        // a voice note: the open island → exactly its width
        XCTAssertEqual(IslandLayout.livePanelWidth(islandWidth: 480, open: true, screenWidth: 1728), 480)
        // a capsule screen: never too narrow for a phrase
        XCTAssertEqual(IslandLayout.livePanelWidth(islandWidth: 120, open: false, screenWidth: 1440), 340)
        XCTAssertEqual(IslandLayout.livePanelWidth(islandWidth: 297, open: false, screenWidth: 300), 268)
    }

    /// A capsule screen (no notch): the capsule widens while live text shows, so the pair has the notch's
    /// proportions — the panel 24 pt a side wider than the island, not 2.8 times as wide (the review's 340 under 120).
    func testOnACapsuleTheIslandWidensToThePanelsFamily() {
        let island = max(120, IslandLayout.liveCapsuleWidth())
        let panel = IslandLayout.livePanelWidth(islandWidth: island, open: false, screenWidth: 1440)
        XCTAssertEqual(panel - island, 48, "the panel is the island plus 24 pt a side, as under the notch")
        XCTAssertLessThan(panel / island, 1.2)
        XCTAssertEqual(abs(island - 297), 5, accuracy: 6, "about the notch with its ears")
        // the corners follow the shape above
        XCTAssertEqual(IslandLayout.livePanelRadius(open: false, notch: false), 15)
        XCTAssertEqual(IslandLayout.livePanelRadius(open: false, notch: true), 14)
        XCTAssertEqual(IslandLayout.livePanelRadius(open: true, notch: false), 22)
    }

    // MARK: cards

    func testAnOrdinarySnapKeepsTheClassicCard() {
        let f = CardShape.shot(CGSize(width: 1440, height: 1080))
        XCTAssertEqual(f.size, CGSize(width: 112, height: 84))
        XCTAssertTrue(f.fills)
    }

    func testAWideScreenSnapIsWiderAndStillFills() {
        let f = CardShape.shot(CGSize(width: 1920, height: 1080))
        XCTAssertEqual(f.size.width, 149)
        XCTAssertTrue(f.fills)
    }

    /// The dogfood's 2400 × 120 toolbar and 320 × 1800 sidebar: shown whole, never a blurry slice of the middle.
    func testAToolbarOrASidebarIsShownWhole() {
        let wide = CardShape.shot(CGSize(width: 2400, height: 120))
        XCTAssertEqual(wide.size.width, CardShape.maxWidth)
        XCTAssertFalse(wide.fills)
        let tall = CardShape.shot(CGSize(width: 320, height: 1800))
        XCTAssertEqual(tall.size.width, CardShape.minWidth)
        XCTAssertFalse(tall.fills)
    }

    func testAPortraitSnapFillsASquareCard() {
        let f = CardShape.shot(CGSize(width: 900, height: 1200))
        XCTAssertEqual(f.size.width, 84)
        XCTAssertTrue(f.fills, "a quarter cut is fine")
    }

    func testFillsRule() {
        XCTAssertTrue(CardShape.fills(picture: CGSize(width: 4, height: 3), box: CGSize(width: 56, height: 40)))
        XCTAssertFalse(CardShape.fills(picture: CGSize(width: 20, height: 1), box: CGSize(width: 56, height: 40)))
        XCTAssertTrue(CardShape.shot(nil).fills)
    }
    // MARK: dogfood 2

    /// "✓ 已发送" (16 + 39 pt) after a double tap sat 4 pt from the rounded corner: the ears widen to keep 14 pt.
    func testWideEarContentWidensTheEarsInsteadOfGivingUpTheInset() {
        let sent: CGFloat = 16 + 39
        let span = IslandLayout.earSpan(left: 39, right: sent)
        XCTAssertGreaterThan(span, IslandLayout.earWidth)
        let r = notch + span            // the right ear's outer edge, from the notch's left edge at 0
        let x = IslandLayout.earOrigin(.right, width: sent, outer: r, inner: notch)
        XCTAssertEqual(r - (x + sent), IslandLayout.earInset, "the same 14 pt as the clock and the count")
        XCTAssertGreaterThanOrEqual(x, notch + 2, "clear of the notch")
        // the usual ears stay 56 pt
        XCTAssertEqual(IslandLayout.earSpan(left: 39, right: 28), IslandLayout.earWidth)
    }

    /// The review: "✓ 已发送" widened both ears, and the keyboard glyph across the notch jumped 11 pt out and back.
    /// The ear that doesn't need the room keeps its content where it was; the one that does rides the shape's edge.
    func testTheOtherEarsGlyphStaysPutWhenOneEarWidens() {
        let glyph: CGFloat = 16, sent: CGFloat = 16 + 39
        let span = IslandLayout.earSpan(left: glyph, right: sent)
        let before = IslandLayout.earOrigin(.left, width: glyph, outer: -IslandLayout.earReach(content: glyph, shape: IslandLayout.earWidth), inner: 0)
        for shape in [IslandLayout.earWidth, (IslandLayout.earWidth + span) / 2, span] {     // as the shape springs out
            let reach = IslandLayout.earReach(content: glyph, shape: shape)
            XCTAssertEqual(IslandLayout.earOrigin(.left, width: glyph, outer: -reach, inner: 0), before)
        }
        // the wide one is never outside the black while it grows, and ends 14 pt in
        XCTAssertEqual(IslandLayout.earReach(content: sent, shape: IslandLayout.earWidth + 3), IslandLayout.earWidth + 3)
        XCTAssertEqual(IslandLayout.earReach(content: sent, shape: span), span)
    }

    /// "Couldn't snap — macOS needs Screen Recording allo…": a line too long for the open width wraps, never "…".
    func testALineTooLongForTheOpenWidthWraps() {
        let t = IslandLayout.toast(text: 520, lead: 0, button: 90, floor: 297, maxWidth: 480)
        XCTAssertTrue(t.wraps)
        XCTAssertEqual(t.width, 480)
        XCTAssertEqual(t.leadX + t.textWidth + 10 + 90 + IslandLayout.earInset, 480, accuracy: 0.5, "wraps beside the button")
        XCTAssertFalse(IslandLayout.toast(text: 200, lead: 0, button: 90, floor: 297, maxWidth: 480).wraps)
        XCTAssertEqual(IslandLayout.toastHeight(lines: 1), 46)
        XCTAssertEqual(IslandLayout.toastHeight(lines: 2), 46 + IslandLayout.toastLineHeight)
        // the launch line with a list of shortcuts was cut at two ("…and ⌃⌥⇧⌘L w…"): a third line holds it
        XCTAssertEqual(IslandLayout.toastLines(wrapped: 16, line: 16), 1)
        XCTAssertEqual(IslandLayout.toastLines(wrapped: 32, line: 16), 2)
        XCTAssertEqual(IslandLayout.toastLines(wrapped: 48, line: 16), 3)
        XCTAssertEqual(IslandLayout.toastLines(wrapped: 80, line: 16), IslandLayout.toastMaxLines, "never past the cap")
        XCTAssertEqual(IslandLayout.toastHeight(lines: 3), 46 + 2 * IslandLayout.toastLineHeight)
        XCTAssertEqual(IslandLayout.toastHeight(lines: 5), IslandLayout.toastHeight(lines: IslandLayout.toastMaxLines))
    }

    /// After stop the panel showed the last three lines, so a Structured list lost its heading before a double tap.
    func testTypedTextShowsFromTheTopUpToEightLines() {
        XCTAssertEqual(IslandLayout.liveLines(total: 6, typed: false).range, 3..<6, "listening: the newest three")
        let list = IslandLayout.liveLines(total: 6, typed: true)
        XCTAssertEqual(list.range, 0..<6, "typed: the heading and every item")
        XCTAssertFalse(list.more)
        let long = IslandLayout.liveLines(total: 12, typed: true)
        XCTAssertEqual(long.range, 0..<IslandLayout.liveTypedLines)
        XCTAssertTrue(long.more, "the last line fades: there is more")
        XCTAssertEqual(IslandLayout.liveLines(total: 0, typed: true).range, 0..<0)
    }

    /// A voice note's finish: the panel under the open island narrowed and dropped below the new card for 1.2 s.
    func testThePanelUnderAnOpenIslandGoesWhenItCloses() {
        XCTAssertTrue(IslandLayout.livePanelGoes(laidOutOpen: true, open: false))
        XCTAssertFalse(IslandLayout.livePanelGoes(laidOutOpen: true, open: true))
        XCTAssertFalse(IslandLayout.livePanelGoes(laidOutOpen: false, open: false), "dictation's panel under the ears stays")
    }
}
