import XCTest
@testable import BlurtCore

/// Home's timeline and the keyboard's walk over the page (HomeFeed.swift).
final class HomeFeedTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }()

    /// 2026-11-16 12:00 +08:00, minus `h` hours.
    private func at(_ h: Double) -> Date {
        let noon = cal.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 12))!
        return noon.addingTimeInterval(-h * 3600)
    }

    private func d(_ k: String, _ h: Double) -> HomeFeed.Entry { .init(kind: .dictation, key: k, time: at(h), source: "Slack", text: k) }
    private func c(_ k: String, _ h: Double) -> HomeFeed.Entry { .init(kind: .card, key: k, time: at(h), source: "Snap") }
    private func i(_ k: String, _ h: Double) -> HomeFeed.Entry { .init(kind: .item, key: k, time: at(h), source: "BA-1", text: k) }

    // MARK: merge

    func testOneTimelineNewestFirstWhateverTheListsOrder() {
        let f = HomeFeed.merge(dictations: [d("d2", 5), d("d1", 1)], cards: [c("c1", 3)], items: [i("i1", 2), i("i2", 8)])
        XCTAssertEqual(f.entries.map(\.id), ["dictation:d1", "item:i1", "card:c1", "dictation:d2", "item:i2"])
        XCTAssertEqual(f.kinds, [.dictation, .card, .item])
        XCTAssertTrue(f.cut.isEmpty)
    }

    func testRowsOfOneMomentKeepTheCapabilitiesOrder() {
        let f = HomeFeed.merge(dictations: [d("b", 1), d("a", 1)], cards: [c("c", 1)], items: [i("i", 1)])
        XCTAssertEqual(f.entries.map(\.id), ["dictation:a", "dictation:b", "card:c", "item:i"])
    }

    func testTheCutSaysWhichKindsHaveMore() {
        let ds = (0..<50).map { d("d\($0)", Double($0)) }
        let f = HomeFeed.merge(dictations: ds, cards: [c("c1", 0.5)], items: [i("old", 400)], limit: 40)
        XCTAssertEqual(f.entries.count, 40)
        XCTAssertEqual(f.entries.first?.id, "dictation:d0")
        XCTAssertEqual(f.entries[1].id, "card:c1")
        XCTAssertEqual(f.kinds, [.dictation, .card, .item])      // the item is not among the 40, but it has its link
        XCTAssertEqual(f.cut, [.dictation, .item])
    }

    func testAnOffCapabilitysRowsAreLeftOut() {
        let f = HomeFeed.merge(dictations: [d("d1", 1)], cards: [c("c1", 2)], items: [i("i1", 3)], off: [.cards, .recording])
        XCTAssertEqual(f.entries.map(\.id), ["dictation:d1"])
        XCTAssertEqual(f.kinds, [.dictation])
        let none = HomeFeed.merge(dictations: [d("d1", 1)], cards: [], items: [], off: [.dictation])
        XCTAssertTrue(none.isEmpty)
        XCTAssertTrue(none.kinds.isEmpty)
    }

    func testACardListedTwiceShowsOnce() {
        let f = HomeFeed.merge(dictations: [], cards: [c("s#1", 1), c("s#1", 1), c("s#2", 2)], items: [])
        XCTAssertEqual(f.entries.map(\.key), ["s#1", "s#2"])
    }

    func testNothingMadeYetIsAnEmptyFeed() {
        let f = HomeFeed.merge(dictations: [], cards: [], items: [])
        XCTAssertTrue(f.isEmpty)
        XCTAssertEqual(HomeFeed.days(f.entries, calendar: cal), [])
    }

    func testAKindBelongsToItsCapability() {
        XCTAssertEqual(HomeFeed.Kind.dictation.capability, .dictation)
        XCTAssertEqual(HomeFeed.Kind.card.capability, .cards)
        XCTAssertEqual(HomeFeed.Kind.item.capability, .recording)
    }

    // MARK: days

    func testRowsFallUnderTheirDaysInTheUsersCalendar() {
        // noon, 11:00 and 00:30 today; 23:30 yesterday; three days ago
        let es = [d("a", 0), i("b", 1), c("c", 11.5), d("y", 12.5), d("old", 72)]
        let days = HomeFeed.days(es, calendar: cal)
        XCTAssertEqual(days.map { $0.rows.map(\.key) }, [["a", "b", "c"], ["y"], ["old"]])
        XCTAssertEqual(days[0].day, cal.startOfDay(for: at(0)))
        XCTAssertEqual(days[1].day, cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: at(0))))
    }

    // MARK: the keyboard's walk

    private let walk = HomeFeed.Walk(on: [.dictation, .cards, .phone], waiting: ["cards"],
                                     entries: ["dictation:a", "card:b"], closing: ["all.dictation"])

    func testArrowsGoLineByLineAndAnOffRowIsItsSwitch() {
        XCTAssertEqual(walk.lines, [.row(.dictation), .row(.cards), .toggle(.screenText), .toggle(.recording), .row(.phone),
                                    .link("cards"), .entry("dictation:a"), .entry("card:b"), .link("all.dictation")])
        XCTAssertEqual(walk.vertical(from: nil, down: true), .row(.dictation))
        XCTAssertEqual(walk.vertical(from: nil, down: false), .link("all.dictation"))
        XCTAssertEqual(walk.vertical(from: .row(.cards), down: true), .toggle(.screenText))
        XCTAssertEqual(walk.vertical(from: .row(.phone), down: true), .link("cards"))
        XCTAssertEqual(walk.vertical(from: .entry("dictation:a"), down: false), .link("cards"))
        // the ends hold: no wrapping
        XCTAssertEqual(walk.vertical(from: .row(.dictation), down: false), .row(.dictation))
        XCTAssertEqual(walk.vertical(from: .link("all.dictation"), down: true), .link("all.dictation"))
    }

    func testOnASwitchTheArrowsStayInTheSwitchesColumn() {
        XCTAssertEqual(walk.vertical(from: .toggle(.dictation), down: true), .toggle(.cards))
        XCTAssertEqual(walk.vertical(from: .toggle(.recording), down: false), .toggle(.screenText))
        XCTAssertEqual(walk.vertical(from: .toggle(.dictation), down: false), .toggle(.dictation))
        XCTAssertEqual(walk.vertical(from: .toggle(.phone), down: true), .link("cards"))
        XCTAssertEqual(walk.horizontal(from: .row(.cards), right: true), .toggle(.cards))
        XCTAssertEqual(walk.horizontal(from: .toggle(.cards), right: false), .row(.cards))
        XCTAssertEqual(walk.horizontal(from: .toggle(.recording), right: false), .toggle(.recording))   // off: no row to go to
        XCTAssertEqual(walk.horizontal(from: .entry("card:b"), right: true), .entry("card:b"))
    }

    func testTabVisitsRowsSwitchesLinksAndTheTimelineAsOneStop() {
        XCTAssertEqual(walk.tabs(current: nil), [.row(.dictation), .toggle(.dictation), .row(.cards), .toggle(.cards), .toggle(.screenText),
                                                 .toggle(.recording), .row(.phone), .toggle(.phone), .link("cards"),
                                                 .entry("dictation:a"), .link("all.dictation")])
        XCTAssertEqual(walk.tab(from: nil, forward: true), .row(.dictation))
        XCTAssertEqual(walk.tab(from: .toggle(.phone), forward: true), .link("cards"))
        XCTAssertEqual(walk.tab(from: .link("cards"), forward: true), .entry("dictation:a"))
        // from a row inside the timeline Tab leaves the timeline
        XCTAssertEqual(walk.tab(from: .entry("card:b"), forward: true), .link("all.dictation"))
        XCTAssertEqual(walk.tab(from: .entry("card:b"), forward: false), .link("cards"))
        XCTAssertEqual(walk.tab(from: .link("all.dictation"), forward: true), .row(.dictation))
        XCTAssertEqual(walk.tab(from: .row(.dictation), forward: false), .link("all.dictation"))
    }

    func testARowsFixSitsBetweenTheRowAndItsSwitch() {
        let w = HomeFeed.Walk(on: [.dictation, .cards], fixes: [.dictation, .recording], entries: ["dictation:a"])
        XCTAssertEqual(w.fixes, [.dictation])                    // an off row shows no fix
        XCTAssertEqual(Array(w.tabs(current: nil).prefix(4)), [.row(.dictation), .fix(.dictation), .toggle(.dictation), .row(.cards)])
        XCTAssertEqual(w.horizontal(from: .row(.dictation), right: true), .fix(.dictation))
        XCTAssertEqual(w.horizontal(from: .fix(.dictation), right: true), .toggle(.dictation))
        XCTAssertEqual(w.horizontal(from: .toggle(.dictation), right: false), .fix(.dictation))
        XCTAssertEqual(w.horizontal(from: .toggle(.cards), right: false), .row(.cards))
        XCTAssertEqual(w.vertical(from: .fix(.dictation), down: true), .row(.cards))     // a fix is on its row's line
        XCTAssertEqual(w.keep(.fix(.dictation)), .fix(.dictation))
        XCTAssertEqual(HomeFeed.Walk(on: [.dictation]).keep(.fix(.dictation)), .row(.dictation))      // fixed
        XCTAssertEqual(HomeFeed.Walk(on: []).keep(.fix(.dictation)), .toggle(.dictation))             // turned off
    }

    func testAFreshInstallWalksOnlyTheBox() {
        let w = HomeFeed.Walk(on: Capability.allCases)
        XCTAssertEqual(w.lines.count, 5)
        XCTAssertEqual(w.vertical(from: .row(.phone), down: true), .row(.phone))
        XCTAssertEqual(w.vertical(from: .toggle(.phone), down: true), .toggle(.phone))
        XCTAssertEqual(w.tab(from: .toggle(.phone), forward: true), .row(.dictation))
    }

    func testTheKeyboardStaysPutWhenThePageChangesUnderIt() {
        XCTAssertEqual(walk.keep(.row(.cards)), .row(.cards))
        XCTAssertEqual(walk.keep(.row(.recording)), .toggle(.recording))        // turned off under the keyboard
        XCTAssertEqual(walk.keep(.entry("item:gone")), .entry("dictation:a"))
        XCTAssertEqual(walk.keep(.link("inbox")), nil)
        XCTAssertNil(walk.keep(nil))
        XCTAssertNil(HomeFeed.Walk(on: []).keep(.entry("x")))
    }

    func testScreenTextRowsJoinTheTimelineInTheCapabilitiesOrder() {
        let st = HomeFeed.Entry(kind: .screenText, key: "s1", time: at(1), source: "Screen Text", text: "hello")
        let f = HomeFeed.merge(dictations: [d("d1", 1)], cards: [c("c1", 1)], screenTexts: [st], items: [i("i1", 1)])
        XCTAssertEqual(f.entries.map(\.kind), [.dictation, .card, .screenText, .item])
        XCTAssertEqual(f.kinds, [.dictation, .card, .screenText, .item])
        let off = HomeFeed.merge(dictations: [], cards: [], screenTexts: [st], items: [], off: [.screenText])
        XCTAssertTrue(off.isEmpty)
    }
}
