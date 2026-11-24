// The computer keyboard (docs/design/remote.md §Computer keyboard): what's pressed, in which order and for how long; held modifiers; and that
// it fits every size without covering anything or going under a thumb's reach.
import BlurtRemoteKit
import XCTest
@testable import BlurtRemote

final class FullTypingTests: XCTestCase {
    private let a = FullKey("A"), b = FullKey("B"), left = FullKey("Left", fn: "Home"), one = FullKey("1", fn: "F1"), esc = FullKey("Escape")
    private let fn = FullKey(.fn), shift = FullKey(.modifier(.shift))
    private var mods: RemoteModifiers = []

    private func engine() -> FullTyping {
        let e = FullTyping()
        e.mods = { [unowned self] in self.mods }
        return e
    }

    func testAKeyActsAsItLifts() {
        let e = engine()
        XCTAssertEqual(e.began(1, a, at: 0), [.engage, .tick])
        XCTAssertEqual(e.ended(1, at: 0.1), [.engageWith(0), .press("A"), .used])
    }

    func testSlidOffNothingHappens() {
        let e = engine()
        _ = e.began(1, a, at: 0)
        XCTAssertEqual(e.moved(1, inside: false, at: 0.1), [])
        XCTAssertEqual(e.moved(1, inside: true, at: 0.15), [], "not even back on it")
        XCTAssertEqual(e.ended(1, at: 0.2), [])
    }

    /// Typed fast, the second key lands before the first lifts. The order is the order they landed in, and each is one letter.
    func testRolloverKeepsTheOrder() {
        let e = engine()
        _ = e.began(1, a, at: 0)
        XCTAssertEqual(e.began(2, b, at: 0.05), [.engageWith(0), .hold("A", down: true), .used, .engage, .tick])
        XCTAssertEqual(e.ended(2, at: 0.09), [.engageWith(0.05), .press("B"), .used], "b lifts first")
        XCTAssertEqual(e.ended(1, at: 0.12), [.hold("A", down: false)])
    }

    func testHeldItGoesDownAndRepeats() {
        let e = engine()
        _ = e.began(1, a, at: 0)
        XCTAssertEqual(e.tick(at: 0.3), [])
        XCTAssertEqual(e.tick(at: 0.41), [.engageWith(0), .hold("A", down: true), .grab, .used])
        XCTAssertEqual(e.tick(at: 0.47), [.again("A")])
        XCTAssertEqual(e.ended(1, at: 0.5), [.hold("A", down: false)])
    }

    /// W and A in a game: both are down, and only the last one repeats.
    func testTwoHeldTogether() {
        let e = engine()
        _ = e.began(1, a, at: 0)
        _ = e.tick(at: 0.41)
        _ = e.began(2, b, at: 0.5)
        let o = e.tick(at: 0.95) + e.tick(at: 1.02)
        XCTAssertTrue(o.contains(.hold("B", down: true)))
        XCTAssertTrue(o.contains(.again("B")))
        XCTAssertFalse(o.contains(.again("A")))
        XCTAssertEqual(e.ended(1, at: 1.1), [.hold("A", down: false)])
        XCTAssertEqual(e.ended(2, at: 1.2), [.hold("B", down: false)])
    }

    func testNothingDestructiveRepeats() {
        for (n, m) in [("Escape", []), ("Return", []), ("C", .control), ("W", .command), ("Delete", .command), ("F5", []), ("Tab", [])] as [(String, RemoteModifiers)] {
            XCTAssertFalse(FullKeys.repeats(n, mods: m), "\(n)")
        }
        for (n, m) in [("A", []), ("Left", .command), ("=", .command), ("-", .control), ("Delete", []), ("Space", []), ("J", .shift)] as [(String, RemoteModifiers)] {
            XCTAssertTrue(FullKeys.repeats(n, mods: m), "\(n)")
        }
        let e = engine()
        _ = e.began(1, esc, at: 0)
        XCTAssertEqual(e.tick(at: 2), [])
        XCTAssertEqual(e.ended(1, at: 2.1), [.engageWith(0), .press("Escape"), .used], "held long, it's still one press")
    }

    func testTheArrowsActAtOnce() {
        let e = engine()
        XCTAssertEqual(e.began(1, left, at: 0), [.engage, .press("Left"), .tick, .used])
        XCTAssertEqual(e.tick(at: 0.36), [.press("Left")])
        XCTAssertEqual(e.ended(1, at: 0.4), [])
    }

    func testFnTappedIsForTheNextKeyAndTwiceStays() {
        let e = engine()
        _ = e.began(1, fn, at: 0); _ = e.ended(1, at: 0.1)
        XCTAssertTrue(e.fn)
        _ = e.began(2, one, at: 1)
        XCTAssertEqual(e.ended(2, at: 1.1), [.engageWith(1), .press("F1"), .used, .fnChanged])
        XCTAssertFalse(e.fn)
        _ = e.began(3, fn, at: 2); _ = e.ended(3, at: 2.1)
        _ = e.began(4, fn, at: 2.2); _ = e.ended(4, at: 2.3)
        XCTAssertTrue(e.fnLocked)
        _ = e.began(5, left, at: 3); _ = e.ended(5, at: 3.1)
        XCTAssertTrue(e.fn)
    }

    func testFnHeldIsForAsLongAsItIs() {
        let e = engine()
        _ = e.began(1, fn, at: 0)
        XCTAssertEqual(e.began(2, left, at: 0.2), [.engage, .tick])
        XCTAssertEqual(e.ended(2, at: 0.3), [.engageWith(0.2), .press("Home"), .used])
        _ = e.ended(1, at: 0.4)
        XCTAssertFalse(e.fn, "used, so it's no tap")
    }

    func testLettingGoLeavesNothingDown() {
        let e = engine()
        _ = e.began(1, a, at: 0); _ = e.tick(at: 0.5)
        _ = e.began(2, shift, at: 0.6)
        let o = e.letGo()
        XCTAssertTrue(o.contains(.hold("A", down: false)))
        XCTAssertTrue(o.contains(.modifierUp(.shift, after: 0, cancelled: true)))
        XCTAssertTrue(e.isEmpty)
        XCTAssertFalse(e.needsTicks)
    }

    func testACancelledTouchLeavesNothingDown() {
        let e = engine()
        _ = e.began(1, a, at: 0); _ = e.tick(at: 0.5)
        XCTAssertEqual(e.cancelled(1), [.hold("A", down: false)])
        _ = e.began(2, a, at: 1)
        XCTAssertEqual(e.cancelled(2), [])
        XCTAssertTrue(e.isEmpty)
    }
}

final class HeldModifierTests: XCTestCase {
    private var said: [RemoteModifiers] = []
    private var alt: [Bool] = []
    private func sticky() -> Sticky {
        let s = Sticky()
        s.tell = { [unowned self] in self.said.append($0) }
        s.tellAltGr = { [unowned self] in self.alt.append($0) }
        return s
    }

    /// ⌘ under one thumb, C under the other: ⌘ goes down before the C and up as its thumb lifts.
    func testHeldWithAnotherKey() {
        let s = sticky()
        s.press(.command)
        XCTAssertEqual(said, [], "it may yet be a tap")
        s.engage()
        XCTAssertEqual(said, [.command])
        s.used()
        XCTAssertEqual(s.held, .command, "still under the thumb: ⌘C ⌘V with one hold")
        s.finish(.command, after: 1.2, at: 1.2, cancelled: false)
        XCTAssertEqual(said, [.command, []], "and it was no tap and no press of its own")
    }

    /// Landed in the same instant, it's held for the key whichever was told of first; landed after, it's for the next one.
    func testTogetherAndAfter() {
        let s = sticky()
        s.press(.command, at: 10.02)
        s.engage(with: 10)
        XCTAssertEqual(s.held, .command)
        _ = s.lift(.command)
        s.press(.shift, at: 20.1)
        s.engage(with: 20)
        XCTAssertEqual(s.held, [], "the ⇧ of the next letter")
        s.engage()
        XCTAssertEqual(s.held, .shift)
    }

    /// ⌘ lifts a moment before the C: the C goes first, and is ⌘C.
    func testTheModifierLiftsFirst() {
        let s = sticky(), e = FullTyping()
        var keys: [String] = []
        s.wait(e) { for o in e.flush() { if case let .hold(n, true) = o { keys.append("\(s.held.contains(.command) ? "⌘" : "")\(n)") } } }
        s.press(.command)
        for o in e.began(1, FullKey("C"), at: 0) where o == .engage { s.engage() }
        s.finish(.command, after: 0.5, at: 0.5, cancelled: false)
        XCTAssertEqual(keys, ["⌘C"])
        XCTAssertEqual(s.held, [])
        XCTAssertEqual(e.ended(1, at: 0.55), [.hold("C", down: false)], "and not a second time")
    }

    func testATapIsStillForTheNextKey() {
        let s = sticky()
        s.press(.shift)
        s.finish(.shift, after: 0.1, at: 0.1, cancelled: false)
        XCTAssertEqual(s.once, .shift)
        s.used()
        XCTAssertEqual(said, [.shift, []])
    }

    func testTwoHeldAndOneTapped() {
        let s = sticky()
        s.press(.command); s.press(.shift)
        s.engage()
        XCTAssertEqual(s.held, [.command, .shift])
        s.finish(.shift, after: 0.5, at: 0.5, cancelled: false)
        XCTAssertEqual(s.held, .command)
        s.finish(.command, after: 0.8, at: 0.8, cancelled: false)
        XCTAssertEqual(s.held, [])
    }

    func testAltGrIsAKeyOfItsOwn() {
        let s = sticky()
        s.pressAltGr()
        s.engage()
        s.finishAltGr(after: 0.9, at: 0.9, cancelled: false)
        XCTAssertEqual(alt, [true, false])
        s.pressAltGr()
        s.finishAltGr(after: 0.1, at: 2, cancelled: false)
        XCTAssertTrue(s.altGrOnce)
        s.used()
        XCTAssertEqual(alt, [true, false, true, false])
        XCTAssertEqual(said, [])
    }

    func testClearLetsGoOfEverything() {
        let s = sticky()
        s.tap(.command, at: 0); s.tap(.command, at: 0.1)
        s.tap(.shift, at: 1)
        s.pressAltGr(); s.finishAltGr(after: 0.1, at: 2, cancelled: false)
        s.letGo()
        XCTAssertEqual(s.held, [])
        XCTAssertFalse(s.altGr)
        XCTAssertEqual(said.last, [])
        XCTAssertEqual(alt.last, false)
        XCTAssertFalse(s.holding)
    }
}

final class FullLayoutTests: XCTestCase {
    private func layouts(_ r: Rooms.Room) -> [(String, PadLayout)] {
        [false, true].flatMap { lefty in [false, true].map { showing in
            ("\(r.name) \(lefty ? "lefty" : "righty")\(showing ? " picture" : "")",
             PadLayout(size: r.size, safe: r.safe, lefty: lefty, islandLeft: r.islandLeft, drawerOpen: !showing, surround: r.surround, showing: showing, board: true))
        } }
    }

    private func visible(_ l: PadLayout) -> [(String, CGRect)] {
        let b = l.board!, big = !b.quick.isEmpty
        var r: [(String, CGRect)] = [("pad", l.pad), ("board", b.frame)] + b.quick.enumerated().map { ("quick\($0.offset)", $0.element) }
        if let t = l.thumbPad { r.append(("thumbPad", t)) }
        if !big {
            r += [("talk", l.talk), ("arrow", l.arrowKey)]
            for (i, d) in l.dock.enumerated() where l.mode != .landscape || PadLayout.staysOut(i) { r.append(("dock\(i)", d)) }
        }
        if l.mode != .landscape { r.append(("switch", l.strip)) }
        for (n, x) in [("apps", l.appsKey), ("settings", l.settingsButton), ("find", l.findButton), ("screen", l.screenButton),
                       ("keyboard", l.keyboardButton), ("drawer", l.drawerButton)] where !x.isEmpty { r.append((n, x)) }
        return r
    }

    func testItFitsEverywhereAndCoversNothing() {
        for room in Rooms.all {
            for (name, l) in layouts(room) {
                let all = CGRect(origin: .zero, size: room.size), v = visible(l)
                for (n, r) in v {
                    XCTAssertTrue(all.insetBy(dx: -0.5, dy: -0.5).contains(r), "\(name): \(n) \(r) is in view")
                    XCTAssertGreaterThan(r.width, 0, "\(name): \(n)")
                    XCTAssertGreaterThan(r.height, 0, "\(name): \(n)")
                }
                for (i, a) in v.enumerated() {
                    for b in v[(i + 1)...] where a.1.intersection(b.1).width > 0.5 && a.1.intersection(b.1).height > 0.5 {
                        XCTFail("\(name): \(a.0) \(a.1) overlaps \(b.0) \(b.1)")
                    }
                }
                for o in room.surround.occlusions { for (n, r) in v where r.intersects(o) { XCTFail("\(name): \(n) under the camera") } }
            }
        }
    }

    func testRowsAreFullAndKeysDoNotOverlap() {
        for t in FullTier.allCases {
            for h in [RemoteHost.mac, .windows, .linux] {
                let rows = FullKeys.rows(t, for: h)
                for (i, r) in rows.enumerated() { XCTAssertEqual(r.reduce(0) { $0 + $1.units }, CGFloat(t.rawValue), accuracy: 0.001, "\(t) \(h) row \(i)") }
                let names = rows.joined().compactMap { k -> String? in if case let .key(n) = k.kind { n } else { nil } }
                XCTAssertEqual(Set(names).count, names.count, "\(t) \(h): no key twice")
                for n in names + rows.joined().compactMap(\.fn) { XCTAssertNotNil(RemoteKey.named(n), n) }
                // everything a US keyboard types, and Esc's F-keys, on every size
                for c in RemoteLegends.names { XCTAssertTrue(names.contains(c), "\(t) \(h): \(c)") }
                let reach = Set(names + rows.joined().compactMap(\.fn))
                for n in (1...12).map({ "F\($0)" }) + ["Home", "End", "PageUp", "PageDown", "ForwardDelete"] { XCTAssertTrue(reach.contains(n), "\(t) \(h): \(n)") }
                if h != .mac { for n in ["Insert", "PrintScreen", "Pause", "Menu", "CapsLock"] { XCTAssertTrue(reach.contains(n), "\(t) \(h): \(n)") } }
            }
        }
    }

    func testKeysAreBigEnoughToHit() {
        for room in Rooms.all {
            for (name, l) in layouts(room) {
                let b = l.board!
                let unit = FullTier.unit(b.frame.width, b.tier)
                XCTAssertGreaterThanOrEqual(unit, room.size.width < 360 ? 25 : 31, "\(name) \(b.tier)")
                XCTAssertGreaterThanOrEqual(b.heights.dropFirst().min()!, 32, name)
                if room.name.hasPrefix("ipad11-landscape") || room.name.hasPrefix("ipad13-landscape") { XCTAssertGreaterThanOrEqual(unit, 60, name) }
                if room.name.hasPrefix("ipad"), l.mode == .big, room.size.width > 760 { XCTAssertGreaterThanOrEqual(unit, 44, name) }
            }
        }
    }

    /// A phone never loses its trackpad to it, and upright the picture is whole.
    func testThePadStays() {
        for room in Rooms.all {
            for (name, l) in layouts(room) {
                XCTAssertGreaterThanOrEqual(l.pad.height, room.name.contains("laptop") ? 100 : 118, name)
                if l.mode == .portrait, room.name.hasPrefix("iphone") { XCTAssertGreaterThanOrEqual(l.pad.height, l.pad.width / 1.6, name) }
                if let b = l.board, l.mode == .big, !b.quick.isEmpty { XCTAssertTrue(b.bandsArePad != (l.thumbPad != nil), "\(name): one trackpad or the other") }
            }
        }
    }

    func testLabels() {
        func main(_ n: String, fn: Bool = false, shift: Bool = false, h: RemoteHost = .mac, l: RemoteLegends? = nil, f: String? = nil, altGr: Bool = false) -> String {
            FullLabel.of(FullKey(n, fn: f), host: h, fn: fn, shift: shift, altGr: altGr, legends: l).main
        }
        XCTAssertEqual(main("1"), "1")
        XCTAssertEqual(main("1", shift: true), "!")
        XCTAssertEqual(main("A"), "A")
        XCTAssertEqual(main("1", fn: true, f: "F1"), "F1")
        let german = RemoteLegends(source: "German", keys: ["Y": .init(base: "z", shift: "Z"), "Q": .init(base: "q", shift: "Q", altGr: "@"), "-": .init(base: "ß", shift: "?", altGr: "\\")])
        XCTAssertEqual(main("Y", l: german), "Z")
        XCTAssertEqual(main("-", l: german), "ß")
        XCTAssertEqual(main("-", shift: true, l: german), "?")
        XCTAssertEqual(main("Q", l: german, altGr: true), "@")
    }
}
