// The layout at every size it meets: iPads full screen and in every multitasking size, and the iPhone Duo's two displays, open, folded
// and turned. PadLayout is a pure function, so a Duo needn't be at hand: these are its sizes and its fold, from UIKit's own numbers
// where the Duo simulator gave them (docs/design/remote.md §iPad and iPhone Duo).
import BlurtRemoteKit
import XCTest
@testable import BlurtRemote

/// Sizes in points, safe areas as UIKit reports them with the status bar hidden.
enum Rooms {
    struct Room {
        let name: String
        let size: CGSize
        var safe = UIEdgeInsets.zero
        var surround = PadSurround.none
        var islandLeft = true
    }

    // the iPhone Duo, iOS 27.1 simulator (Duo.outer / Duo.inner below). The fold, flat: a line down (or across) the middle
    static let outer = CGSize(width: Duo.outerShort, height: Duo.outerLong)
    static let inner = CGSize(width: Duo.innerLong, height: Duo.innerShort)

    static func fold(_ size: CGSize, active: Bool) -> PadSurround {
        let w = active ? Duo.foldBand : 2
        let across = size.height > size.width
        let f = across ? CGRect(x: 0, y: size.height / 2 - w / 2, width: size.width, height: w)
            : CGRect(x: size.width / 2 - w / 2, y: 0, width: w, height: size.height)
        return PadSurround(fold: f, foldActive: active, occlusions: [])
    }

    static var all: [Room] {
        let o = outer, i = inner, it = CGSize(width: inner.height, height: inner.width)
        return [
            Room(name: "iphone17pro-portrait", size: CGSize(width: 402, height: 874), safe: UIEdgeInsets(top: 62, left: 0, bottom: 34, right: 0)),
            Room(name: "iphone17pro-landscape", size: CGSize(width: 874, height: 402), safe: UIEdgeInsets(top: 0, left: 62, bottom: 21, right: 62)),
            Room(name: "duo-outer-portrait", size: o, safe: Duo.outerPortraitSafe, surround: PadSurround(occlusions: [Duo.outerCamera(portrait: true, o)])),
            Room(name: "duo-outer-landscape", size: CGSize(width: o.height, height: o.width), safe: Duo.outerLandscapeSafe,
                 surround: PadSurround(occlusions: [Duo.outerCamera(portrait: false, CGSize(width: o.height, height: o.width))]), islandLeft: false),
            Room(name: "duo-inner-open", size: i, safe: Duo.innerSafe, surround: fold(i, active: false)),
            Room(name: "duo-inner-book", size: i, safe: Duo.innerSafe, surround: fold(i, active: true)),
            Room(name: "duo-inner-tall", size: it, safe: Duo.innerSafe, surround: fold(it, active: false)),
            Room(name: "duo-inner-laptop", size: it, safe: Duo.innerSafe, surround: fold(it, active: true)),
            Room(name: "ipad13-landscape", size: CGSize(width: 1376, height: 1032), safe: UIEdgeInsets(top: 0, left: 0, bottom: 20, right: 0)),
            Room(name: "ipad13-portrait", size: CGSize(width: 1032, height: 1376), safe: UIEdgeInsets(top: 0, left: 0, bottom: 20, right: 0)),
            Room(name: "ipad11-landscape", size: CGSize(width: 1210, height: 834), safe: UIEdgeInsets(top: 0, left: 0, bottom: 20, right: 0)),
            Room(name: "ipad11-portrait", size: CGSize(width: 834, height: 1210), safe: UIEdgeInsets(top: 0, left: 0, bottom: 20, right: 0)),
            Room(name: "ipad13-split-half", size: CGSize(width: 683, height: 1032), safe: UIEdgeInsets(top: 0, left: 0, bottom: 20, right: 0)),
            Room(name: "ipad13-split-third", size: CGSize(width: 438, height: 1032), safe: UIEdgeInsets(top: 0, left: 0, bottom: 20, right: 0)),
            Room(name: "ipad13-split-two-thirds", size: CGSize(width: 932, height: 1032), safe: UIEdgeInsets(top: 0, left: 0, bottom: 20, right: 0)),
            Room(name: "ipad11-split-half", size: CGSize(width: 597, height: 834), safe: UIEdgeInsets(top: 0, left: 0, bottom: 20, right: 0)),
            Room(name: "ipad11-portrait-split-half", size: CGSize(width: 412, height: 1210), safe: UIEdgeInsets(top: 0, left: 0, bottom: 20, right: 0)),
            Room(name: "ipad-slide-over", size: CGSize(width: 320, height: 960), safe: UIEdgeInsets(top: 0, left: 0, bottom: 20, right: 0)),
            Room(name: "stage-manager-wide", size: CGSize(width: 900, height: 600), safe: UIEdgeInsets(top: 32, left: 0, bottom: 0, right: 0)),
            Room(name: "stage-manager-short", size: CGSize(width: 760, height: 460), safe: UIEdgeInsets(top: 32, left: 0, bottom: 0, right: 0)),
            Room(name: "stage-manager-small", size: CGSize(width: 520, height: 600), safe: UIEdgeInsets(top: 32, left: 0, bottom: 0, right: 0)),
        ]
    }
}

final class BigLayoutTests: XCTestCase {
    private func layouts(_ r: Rooms.Room) -> [(String, PadLayout)] {
        [false, true].flatMap { lefty in [true, false].map { open in
            ("\(r.name) \(lefty ? "lefty" : "righty") \(open ? "open" : "away")",
             PadLayout(size: r.size, safe: r.safe, lefty: lefty, islandLeft: r.islandLeft, drawerOpen: open, surround: r.surround))
        } }
    }

    /// What can be touched, as it shows.
    private func visible(_ l: PadLayout) -> [(String, CGRect)] {
        var r: [(String, CGRect)] = [("pad", l.pad), ("talk", l.talk), ("arrow", l.arrowKey)]
        if let t = l.thumbPad { r.append(("thumbPad", t)) }
        for (i, d) in l.dock.enumerated() where l.keysOut || l.mode != .landscape || PadLayout.staysOut(i) { r.append(("dock\(i)", d)) }
        if l.keysOut {
            // the list ignores its middle, where the thumb pad is
            if let s = l.listSplit {
                r.append(("list", CGRect(x: l.list.minX, y: l.list.minY, width: s.at, height: l.list.height)))
                r.append(("list", CGRect(x: l.list.minX + s.at + s.width, y: l.list.minY, width: l.list.width - s.at - s.width, height: l.list.height)))
            } else {
                r.append(("list", l.list))
            }
        }
        if l.keysOut || l.mode == .big { r.append(("strip", l.strip)) }
        for (n, b) in [("apps", l.appsKey), ("settings", l.settingsButton), ("find", l.findButton), ("screen", l.screenButton),
                       ("keyboard", l.keyboardButton), ("drawer", l.drawerButton)] where !b.isEmpty { r.append((n, b)) }
        return r
    }

    func testEverythingFitsAndNothingOverlapsAtEverySize() {
        for room in Rooms.all {
            for (name, l) in layouts(room) {
                let all = CGRect(origin: .zero, size: room.size)
                let v = visible(l)
                for (n, r) in v {
                    XCTAssertTrue(all.insetBy(dx: -0.5, dy: -0.5).contains(r), "\(name): \(n) \(r) is in view")
                    XCTAssertGreaterThan(r.width, 0, "\(name): \(n)")
                }
                for (i, a) in v.enumerated() {
                    for b in v[(i + 1)...] where a.1.intersection(b.1).width > 0.5 && a.1.intersection(b.1).height > 0.5 {
                        XCTFail("\(name): \(a.0) \(a.1) overlaps \(b.0) \(b.1)")
                    }
                }
                // nothing in the camera's way
                for o in room.surround.occlusions {
                    for (n, r) in v where r.intersects(o) { XCTFail("\(name): \(n) under the camera") }
                }
            }
        }
    }

    func testKeysStayKeySizedAndKeyShaped() {
        for room in Rooms.all {
            for (name, l) in layouts(room) {
                for d in l.dock + [l.talk] {
                    XCTAssertGreaterThanOrEqual(d.height, 44, "\(name): a thumb can hit it")
                    XCTAssertGreaterThanOrEqual(d.width, room.size.width < 360 ? 25 : 30, "\(name)")
                }
                XCTAssertGreaterThanOrEqual(l.keySize.width, 30, name)
                XCTAssertLessThanOrEqual(l.keySize.width, 90, "\(name): a phone's keys, not stretched")
                XCTAssertLessThanOrEqual(l.keySize.height, PadLayout.wideKeyHeight, name)
                if l.mode == .big, !l.halves.isEmpty {
                    for d in l.dock { XCTAssertLessThanOrEqual(d.height, d.width * PadLayout.wideKeyShape + 0.5, "\(name): key-shaped, ≤ 1.25× its width") }
                    if !room.surround.laptop { XCTAssertLessThanOrEqual(l.drawer.height, 320, "\(name): a phone's keyboard, not a wall") }
                }
                if l.mode == .portrait { XCTAssertLessThanOrEqual(l.drawer.width, PadLayout.blockWidth, "\(name): phone-sized in a wide window") }
            }
        }
    }

    func testTheFoldHasNoKeyOnIt() {
        for room in Rooms.all where room.surround.fold != nil {
            for (name, l) in layouts(room) {
                let f = room.surround.fold!
                for (n, r) in visible(l) where n != "pad" && n != "thumbPad" && n != "list" {
                    XCTAssertFalse(r.intersects(f), "\(name): \(n) \(r) straddles the fold \(f)")
                }
                // the list's gap is where the fold runs
                if l.keysOut, let s = l.listSplit, f.height > f.width {
                    XCTAssertLessThanOrEqual(l.list.minX + s.at, f.minX, name)
                    XCTAssertGreaterThanOrEqual(l.list.minX + s.at + s.width, f.maxX, name)
                }
                // the one-finger scroll strip stays on one side of it
                let strip = CGRect(x: l.pad.minX + l.scrollEdge.lowerBound, y: l.pad.minY + (l.scrollEdgeY?.lowerBound ?? 0),
                                   width: l.scrollEdge.upperBound - l.scrollEdge.lowerBound,
                                   height: (l.scrollEdgeY.map { $0.upperBound - $0.lowerBound } ?? l.pad.height))
                XCTAssertFalse(strip.intersects(f), "\(name): the scroll strip \(strip) crosses the fold")
                // words, chips and messages on the stage: clear of it
                XCTAssertFalse(l.hintArea.offsetBy(dx: l.pad.minX, dy: l.pad.minY).intersects(f), "\(name): hints clear of the fold")
            }
        }
    }

    func testBigScreensHaveAThumbAtEachLowerCorner() {
        for room in Rooms.all {
            for (name, l) in layouts(room) where l.mode == .big && l.halves.count == 2 {
                let lefty = name.contains("lefty")
                let w = room.size.width
                // the talk key in the corner by the dominant thumb, the modifiers under the other
                XCTAssertEqual(l.talk.maxY, l.dock.map(\.maxY).max()!, accuracy: 0.5, name)
                if lefty { XCTAssertLessThan(l.talk.minX, 30, name) } else { XCTAssertGreaterThan(l.talk.maxX, w - 30, name) }
                let mods = l.dock[0..<PadLayout.thumbSlots.esc]
                for m in mods { XCTAssertEqual(lefty ? m.midX > w / 2 : m.midX < w / 2, true, "\(name): modifiers under the other thumb") }
                // the arrow key has room every way: never at an edge, never in the bottom row
                XCTAssertGreaterThan(l.arrowKey.minX, 60, name)
                XCTAssertLessThan(l.arrowKey.maxX, w - 60, name)
                XCTAssertLessThan(l.arrowKey.maxY, l.dock[0].minY, name)
                // each half within a thumb's sweep of its edge
                for h in l.halves { XCTAssertLessThanOrEqual(h.width, PadLayout.halfWidth, name) }
                XCTAssertNotNil(l.thumbPad, "\(name): a trackpad where the thumbs meet")
                XCTAssertGreaterThanOrEqual(l.thumbPad?.width ?? 0, 100, name)
            }
        }
    }

    func testTheDockNeverMovesWhenTheKeysComeAndGo() {
        for room in Rooms.all {
            for lefty in [false, true] {
                let a = PadLayout(size: room.size, safe: room.safe, lefty: lefty, drawerOpen: true, surround: room.surround)
                let b = PadLayout(size: room.size, safe: room.safe, lefty: lefty, drawerOpen: false, surround: room.surround)
                guard a.mode == .big else { continue }
                XCTAssertEqual(a.dock, b.dock, room.name)
                XCTAssertEqual(a.talk, b.talk, room.name)
                if a.drawerMatters { XCTAssertGreaterThan(b.pad.height, a.pad.height + 150, "\(room.name): put away, the picture has room") }
                else { XCTAssertEqual(a.pad, b.pad, "\(room.name): nothing to put away for") }
            }
        }
    }

    /// The whole picture of a 16:10 screen, as big as it can be, at the stage's size.
    private func picture(_ l: PadLayout, aspect: CGFloat = 1.6) -> CGSize {
        let w = min(l.pad.width, l.pad.height * aspect)
        return CGSize(width: w, height: w / aspect)
    }

    func testThePictureIsLarge() {
        // the Duo open: keys away, a 16:10 screen nearly as wide as the display
        let open = PadLayout(size: Rooms.inner, safe: Duo.innerSafe, lefty: false, drawerOpen: false, surround: Rooms.fold(Rooms.inner, active: false))
        XCTAssertGreaterThan(picture(open).width, Rooms.inner.width * 0.85)
        // an iPad on its side: under a whole picture there's room for the deck, free
        let ipad = PadLayout(size: CGSize(width: 1376, height: 1032), safe: UIEdgeInsets(top: 0, left: 0, bottom: 20, right: 0), lefty: false, drawerOpen: false)
        XCTAssertGreaterThan(picture(ipad).width, 1376 - 30)
        // upright, all the keys stay out and the picture is still as wide as the screen
        let tall = PadLayout(size: CGSize(width: 1032, height: 1376), safe: UIEdgeInsets(top: 0, left: 0, bottom: 20, right: 0), lefty: false)
        XCTAssertFalse(tall.drawerMatters)
        XCTAssertGreaterThan(picture(tall).width, 1032 - 30)
        // laptop: the picture above the fold, the keys and trackpad below
        let laptopSize = CGSize(width: Rooms.inner.height, height: Rooms.inner.width)
        let laptop = PadLayout(size: laptopSize, safe: Duo.innerSafe, lefty: false, surround: Rooms.fold(laptopSize, active: true))
        let fold = Rooms.fold(laptopSize, active: true).fold!
        XCTAssertLessThanOrEqual(laptop.pad.maxY, fold.minY)
        XCTAssertGreaterThanOrEqual(laptop.drawer.minY, fold.maxY)
        XCTAssertGreaterThanOrEqual(laptop.thumbPad?.minY ?? 0, fold.maxY)
        // book: the picture on one page, a phone's remote on the other
        let book = PadLayout(size: Rooms.inner, safe: Duo.innerSafe, lefty: false, surround: Rooms.fold(Rooms.inner, active: true))
        let bf = Rooms.fold(Rooms.inner, active: true).fold!
        XCTAssertLessThanOrEqual(book.pad.maxX, bf.minX)
        XCTAssertGreaterThanOrEqual(book.drawer.minX, bf.maxX)
        XCTAssertGreaterThanOrEqual(book.thumbPad?.minX ?? 0, bf.maxX)
    }

    func testOpeningTheDuoChangesTheKindOfLayoutOnlyOnce() {
        XCTAssertEqual(PadLayout.mode(for: Rooms.outer), .portrait)
        XCTAssertEqual(PadLayout.mode(for: CGSize(width: Rooms.outer.height, height: Rooms.outer.width)), .landscape)
        XCTAssertEqual(PadLayout.mode(for: Rooms.inner), .big)
        XCTAssertEqual(PadLayout.mode(for: CGSize(width: Rooms.inner.height, height: Rooms.inner.width)), .big)
    }

    func testOutputFollowsTheStage() {
        // a wide stage: its width; a tall one: the picture's width at the stage's height, so a zoomed picture is sharp
        XCTAssertEqual(PadLayout.outputPixels(stage: CGSize(width: 1000, height: 500), aspect: 1.6, scale: 2), CGSize(width: 2000, height: 1250))
        XCTAssertEqual(PadLayout.outputPixels(stage: CGSize(width: 400, height: 500), aspect: 1.6, scale: 3), CGSize(width: 2400, height: 1500))
    }

    func testAPageSplitsAroundTheMiddle() {
        let c = KeyList.columns(6, width: 900, gap: 5, split: (at: 236, width: 428))
        XCTAssertEqual(c.count, 6)
        XCTAssertEqual(c[2].upperBound, 236, accuracy: 0.01)
        XCTAssertEqual(c[3].lowerBound, 664, accuracy: 0.01)
        XCTAssertEqual(c[5].upperBound, 900, accuracy: 0.01)
        let ten = KeyList.columns(10, width: 900, gap: 5, split: (at: 236, width: 428))
        XCTAssertEqual(ten[4].upperBound, 236, accuracy: 0.01)
        XCTAssertEqual(ten[5].lowerBound, 664, accuracy: 0.01)
    }
}

final class HardwareKeysTests: XCTestCase {
    func testKeysGoByPosition() {
        XCTAssertEqual(HardwareKeys.name(hid: 0x04), "A")
        XCTAssertEqual(HardwareKeys.name(hid: 0x1D), "Z")
        XCTAssertEqual(HardwareKeys.name(hid: 0x1E), "1")
        XCTAssertEqual(HardwareKeys.name(hid: 0x27), "0")
        XCTAssertEqual(HardwareKeys.name(hid: 0x28), "Return")
        XCTAssertEqual(HardwareKeys.name(hid: 0x2A), "Delete")
        XCTAssertEqual(HardwareKeys.name(hid: 0x3A), "F1")
        XCTAssertEqual(HardwareKeys.name(hid: 0x45), "F12")
        XCTAssertEqual(HardwareKeys.name(hid: 0x52), "Up")
        XCTAssertEqual(HardwareKeys.name(hid: 0x4C), "ForwardDelete")
        for u in 0x04...0x52 { if let n = HardwareKeys.name(hid: u) { XCTAssertNotNil(RemoteKey.named(n), "0x\(String(u, radix: 16)) → \(n) is a wire name") } }
        XCTAssertNil(HardwareKeys.name(hid: 0xE3), "⌘ is a modifier, not a key")
    }

    func testCommandIsCtrlOnWindowsAndLinux() {
        XCTAssertEqual(HardwareKeys.modifier(hid: 0xE3, host: .mac, command: .control), .command)
        XCTAssertEqual(HardwareKeys.modifier(hid: 0xE3, host: .windows, command: .control), .control, "⌘C copies on Windows")
        XCTAssertEqual(HardwareKeys.modifier(hid: 0xE7, host: .linux, command: .control), .control)
        XCTAssertEqual(HardwareKeys.modifier(hid: 0xE3, host: .windows, command: .system), .command, "or the Windows key, if asked")
        XCTAssertEqual(HardwareKeys.modifier(hid: 0xE0, host: .windows, command: .system), .control, "Control is Ctrl")
        XCTAssertEqual(HardwareKeys.modifier(hid: 0xE2, host: .windows, command: .control), .option, "Option is Alt")
        XCTAssertEqual(HardwareKeys.modifier(hid: 0xE1, host: .linux, command: .control), .shift)
        XCTAssertNil(HardwareKeys.modifier(hid: 0x04, host: .mac, command: .control))
    }

    func testNothingDestructiveRepeats() {
        XCTAssertTrue(HardwareKeys.repeats("Delete", held: []))
        XCTAssertTrue(HardwareKeys.repeats("Left", held: [.shift]))
        XCTAssertFalse(HardwareKeys.repeats("Escape", held: []))
        XCTAssertFalse(HardwareKeys.repeats("Return", held: []))
        XCTAssertFalse(HardwareKeys.repeats("C", held: [.control]))
    }
}
