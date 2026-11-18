import BlurtRemoteKit
import XCTest
@testable import BlurtRemote

/// The deck as JSON with every id the same, so two decks compare by what they hold.
func stableJSON(_ deck: Deck) throws -> Data {
    let zero = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    var d = deck
    for i in d.dock.indices { d.dock[i].id = zero }
    for s in d.sections.indices {
        d.sections[s].id = zero
        for k in d.sections[s].slots.indices { d.sections[s].slots[k].id = zero }
    }
    let e = JSONEncoder()
    e.outputFormatting = [.sortedKeys, .prettyPrinted]
    return try e.encode(d)
}

let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
/// what the strings are in on this run: the fixtures are per language
let language = Bundle.main.preferredLocalizations.first ?? "en"
let writeFixtures = ProcessInfo.processInfo.environment["BLURT_WRITE_DECK"] == "1"

func golden(_ name: String, _ now: String) throws {
    let url = fixtures.appendingPathComponent("\(name)-\(language).txt")
    if writeFixtures {
        try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
        try now.write(to: url, atomically: true, encoding: .utf8)
    }
    guard let was = try? String(contentsOf: url, encoding: .utf8) else { throw XCTSkip("no \(name) fixture for \(language)") }
    XCTAssertEqual(now, was)
}

/// docs/design/remote.md §Keys and remote-protocol.md §Default keys per host, for every kind of computer.
final class HostDeckTests: XCTestCase {
    override func tearDown() { RemoteHost.shown = .mac }

    private func chords(_ s: [KeySlot]) -> [RemoteChord] { s.compactMap { if case let .chord(c, _) = $0.action { c } else { nil } } }

    func testNoKeyTwice() {
        for h in RemoteHost.allCases {
            let d = Deck.standard(for: h)
            let all = d.dock + d.sections.flatMap(\.slots)
            XCTAssertEqual(Set(all.map(\.action)).count, all.count, "\(h)")
        }
    }

    func testTheShapeIsTheSameEverywhere() {
        let mac = Deck.standard
        for h in RemoteHost.allCases {
            let d = Deck.standard(for: h)
            XCTAssertEqual(d.dock.count, Deck.dockCount, "\(h)")
            XCTAssertEqual(d.sections.map(\.columns), [6, 10, 10, 6], "\(h)")
            XCTAssertEqual(d.sections.map(\.name), mac.sections.map(\.name), "\(h)")
            XCTAssertEqual(d.sections[0].slots.count, 24, "\(h): four rows of six")
            // the dock: the four modifiers, then the same keys in the same places
            XCTAssertEqual(d.dock.prefix(4).map { if case let .sticky(m) = $0.action { m.rawValue } else { 0 } }.reduce(0, |), 15, "\(h)")
            XCTAssertEqual(Array(d.dock.dropFirst(4).map(\.action)), Array(mac.dock.dropFirst(4).map(\.action)), "\(h)")
            // 字母 and 符号 are the same everywhere, and so are the Blurt keys and ⇧Tab on the last row
            XCTAssertEqual(d.sections[1].slots.map(\.action), mac.sections[1].slots.map(\.action))
            XCTAssertEqual(d.sections[2].slots.map(\.action), mac.sections[2].slots.map(\.action))
            XCTAssertEqual(d.sections[0].slots.suffix(6).prefix(4).map(\.action), mac.sections[0].slots.suffix(6).prefix(4).map(\.action))
            XCTAssertEqual(d.sections[0].slots.last?.action, .chord(RemoteChord(.shift, "Tab"), cycle: false))
        }
        // the dock as each keyboard has its modifiers, left to right
        XCTAssertEqual(Deck.standard(for: .windows).dock.prefix(4).map { $0.face(on: .windows) }, ["Ctrl", "mark:win", "Alt", "Shift"])
        XCTAssertEqual(Deck.standard(for: .linux).dock.prefix(4).map { $0.face(on: .linux) }, ["Ctrl", "Super", "Alt", "Shift"])
        XCTAssertEqual(Deck.standard.dock.prefix(4).map { $0.face(on: .mac) }, ["⌃", "⌥", "⌘", "⇧"])
    }

    func testPCsUseTheirOwnKeys() {
        for h in [RemoteHost.windows, .linux] {
            let main = Deck.standard(for: h).sections[0].slots
            let editing: [RemoteModifiers] = h == .linux ? [.control, .control, .control, .control, [.control, .shift], .control] : Array(repeating: .control, count: 6)
            XCTAssertEqual(chords(Array(main.prefix(6))).map(\.mods), editing, "\(h): editing is Ctrl")
            XCTAssertEqual(h.label(chords(main)[0]), "Ctrl+C")
            // the cycle keys hold Alt and Ctrl, never Win or Super
            for case let .chord(c, true) in main.map(\.action) { XCTAssertFalse(c.mods.contains(.command), "\(h) \(c)") }
            XCTAssertTrue(main.contains { $0.action == .chord(RemoteChord(.option, "Tab"), cycle: true) }, "\(h): Alt+Tab")
            // Win or Super alone, for Start or Activities; Ctrl+Shift+C where a Mac has ⌃C
            XCTAssertEqual(main[14].action, .chord(RemoteChord(.command, ""), cycle: false))
            XCTAssertEqual(main[15].action, .chord(RemoteChord([.control, .shift], "C"), cycle: false))
            XCTAssertEqual(main[15].face(on: h), "C")
            XCTAssertEqual(main[15].detail(on: h), "Ctrl+Shift")
            XCTAssertEqual(main[13].face(on: h), "K")
            XCTAssertEqual(main[14].detail(on: h), h == .windows ? "Win" : "Super")
            XCTAssertEqual(Deck.appsKey(for: h).action, .chord(RemoteChord(.option, "Tab"), cycle: true))
        }
        XCTAssertEqual(Deck.standard(for: .windows).sections[0].slots[4].action, .chord(RemoteChord(.control, "Y"), cycle: false), "redo")
        XCTAssertEqual(Deck.standard(for: .windows).sections[0].slots[7].action, .chord(RemoteChord(.command, "Tab"), cycle: false), "Task View")
        XCTAssertEqual(Deck.standard(for: .linux).sections[0].slots[7].action, .chord(RemoteChord(.option, "`"), cycle: true))
        XCTAssertEqual(Deck.appsKey(for: .mac).action, .chord(RemoteChord(.command, "Tab"), cycle: true))
    }

    /// Everything taken off a page is in the picker.
    func testEveryPageKeyIsInThePicker() {
        for h in RemoteHost.allCases {
            let picker = Set(Deck.catalogue(for: h).flatMap(\.slots).map(\.action))
            for s in Deck.standard(for: h).sections.flatMap(\.slots) { XCTAssertTrue(picker.contains(s.action), "\(h): \(s.title(on: h))") }
        }
    }

    /// No Mac-only keys on a PC, no key twice in its picker (the letters' digits aside, which the agents' Option 1–3 are too), and the Mac's
    /// moves named as that computer names them.
    func testPCPickerHasNothingMacOnly() {
        for h in [RemoteHost.windows, .linux] {
            let groups = Deck.catalogue(for: h)
            // the pages' own groups aside (the letters' digits are Option 1–3 too, and Main is the 常用 page again)
            let own: Set<String> = [String(localized: "Letters"), String(localized: "Symbols"), "Blurt"]
            let rest = groups.filter { !own.contains($0.group) }.flatMap(\.slots).filter {
                if case let .chord(c, _) = $0.action, c.mods.isEmpty, Int(c.key) != nil { return false }
                return true
            }
            let twice = Dictionary(grouping: rest, by: \.action).filter { $0.value.count > 1 }.map { $0.value.map { $0.title(on: h) } }
            XCTAssertTrue(twice.isEmpty, "\(h): \(twice)")
            // the Win / Super key only where it's that computer's own shortcut
            let allowed: Set<String> = ["", "Tab", "D", "E", "L", "S", "Space"]
            for c in chords(groups.flatMap(\.slots)) where c.mods.contains(.command) { XCTAssertTrue(allowed.contains(c.key), "\(h): \(h.label(c))") }
            let names = groups.flatMap(\.slots).map { $0.title(on: h) }
            XCTAssertFalse(names.contains("Spotlight"))
            XCTAssertFalse(names.contains(String(localized: "All Windows")))
            XCTAssertTrue(names.contains(h == .windows ? String(localized: "Task View") : String(localized: "Activities")))
            XCTAssertFalse(names.contains { $0.contains("⌘") || $0.contains("⌥") || $0.contains("⌃") }, "\(h): \(names.filter { $0.contains("⌘") })")
        }
        XCTAssertFalse(Deck.catalogue(for: .windows).flatMap(\.slots).contains { $0.action == .system(.appExpose) }, "no app windows on Windows")
    }

    /// Every icon a deck or picker uses exists on this iOS.
    func testEveryIconExists() {
        for h in RemoteHost.allCases {
            for s in Deck.standard(for: h).dock + Deck.standard(for: h).sections.flatMap(\.slots) + Deck.catalogue(for: h).flatMap(\.slots) {
                let f = s.face(on: h)
                if f.hasPrefix("sf:") { XCTAssertNotNil(UIImage(systemName: String(f.dropFirst(3))), f) }
                if f.hasPrefix("mark:") { XCTAssertNotNil(KeyMarks.image(String(f.dropFirst(5))), f) }
            }
        }
    }

    /// Each kind of computer keeps its own layout, and a Mac's stays where it always was.
    func testDecksAreStoredPerComputer() {
        let u = UserDefaults.standard
        let keys = ["deck.v9", "deck.windows.v1", "deck.linux.v1"]
        let before = keys.map { u.data(forKey: $0) }
        defer { for (k, v) in zip(keys, before) { u.set(v, forKey: k) } }
        keys.forEach { u.removeObject(forKey: $0) }
        var w = Deck.standard(for: .windows)
        w.sections[0].name = "Mine"
        w.save(for: .windows)
        XCTAssertEqual(Deck.load(for: .windows).sections[0].name, "Mine")
        XCTAssertNil(u.data(forKey: "deck.v9"), "the Mac's is untouched")
        XCTAssertEqual(try stableJSON(Deck.load(for: .linux)), try stableJSON(Deck.standard(for: .linux)))
        var m = Deck.standard
        m.sections[0].name = "Mac"
        m.save(for: .mac)
        XCTAssertNotNil(u.data(forKey: "deck.v9"))
        XCTAssertEqual(Deck.load(for: .mac).sections[0].name, "Mac")
        XCTAssertEqual(Deck.load().sections[0].name, "Mac")
        XCTAssertEqual(Deck.load(for: .windows).sections[0].name, "Mine")
    }

    /// The names on the keys follow the computer in hand.
    func testLabelsFollowTheComputerShown() {
        let copy = Deck.standard.sections[0].slots[0]
        XCTAssertEqual(copy.detail, "⌘C")
        RemoteHost.shown = .windows
        let w = Deck.standard(for: .windows)
        XCTAssertEqual(w.sections[0].slots[0].detail, "Ctrl+C")
        XCTAssertEqual(w.sections[0].slots[10].detail, "Ctrl+Shift+Tab")
        XCTAssertEqual(w.dock[1].face, "mark:win")
        XCTAssertEqual(w.dock[1].detail, "Win")
        XCTAssertEqual(w.dock[6].face, "Esc")
        XCTAssertEqual(w.sections[3].slots.first { $0.hint == String(localized: "Close Window") }?.detail, "Alt+F4")
        XCTAssertEqual(KeySlot(.nextTab).title, "Ctrl+Tab")
        RemoteHost.shown = .linux
        XCTAssertEqual(Deck.standard(for: .linux).dock[1].face, "Super")
        XCTAssertNil(Deck.standard(for: .linux).dock[1].detail)
    }

    /// Tabs: a Mac's terminals take ⌘⇧], GNOME's Ctrl+PgDn, everything else Ctrl+Tab.
    func testSmartTabsPerComputer() {
        XCTAssertEqual(KeyCell.nextTab(on: .mac, front: "com.apple.Terminal")?.forward, RemoteChord([.command, .shift], "]"))
        XCTAssertNil(KeyCell.nextTab(on: .mac, front: "com.google.Chrome"))
        XCTAssertEqual(KeyCell.nextTab(on: .linux, front: "org.gnome.Terminal.desktop")?.forward, RemoteChord(.control, "PageDown"))
        XCTAssertEqual(KeyCell.nextTab(on: .linux, front: "org.gnome.Terminal")?.back, RemoteChord(.control, "PageUp"))
        XCTAssertNil(KeyCell.nextTab(on: .linux, front: "firefox"))
        XCTAssertNil(KeyCell.nextTab(on: .windows, front: "WindowsTerminal.exe"))
        XCTAssertNil(KeyCell.nextTab(on: .windows, front: "com.apple.Terminal"), "a Mac's bundle id means nothing on Windows")
    }

    func testWords() {
        XCTAssertEqual(Words.modifiers(.mac), "⇧ ⌘ ⌥ ⌃")
        XCTAssertEqual(Words.modifiers(.windows), "Ctrl Win Alt Shift")
        XCTAssertEqual(Words.modifiers(.linux), "Ctrl Super Alt Shift")
        XCTAssertEqual(Words.useComputerMic(.mac), String(localized: "Use Mac Microphone"))
        XCTAssertFalse(Words.cantControl(.windows, "Studio PC").contains("Mac"))
        XCTAssertTrue(Words.cantControl(.linux, "ubuntu-desk").contains("ubuntu-desk"))
    }
}

final class MacDeckGoldenTests: XCTestCase {
    /// The Mac's deck as it shipped up to 1.0.14, written by that version (BLURT_WRITE_DECK=1).
    func testMacDeckIsAsItShipped() throws {
        try golden("mac-deck", String(decoding: try stableJSON(Deck.standard), as: UTF8.self))
    }

    /// Every key the Mac's deck and picker show, as each reads: face, small line, name.
    func testMacKeysReadAsBefore() throws {
        let all = Deck.standard.dock + Deck.standard.sections.flatMap(\.slots) + Deck.catalogue.flatMap { [KeySlot(.text($0.group, enter: false))] + $0.slots }
        try golden("mac-keys", all.map { "\($0.face)\t\($0.detail ?? "-")\t\($0.title)" }.joined(separator: "\n") + "\n")
    }
}

/// The keys round of 2026-11-18 (docs/design/remote.md §Keys): ⌫ by the thumb in landscape, ↩ by the talk key, ⇧Tab and reload on 常用.
final class DeckRoundTests: XCTestCase {
    private func blurtRow(_ h: RemoteHost) -> [KeySlot] { Deck.catalogue(for: h).first { $0.group == "Blurt" }?.slots ?? [] }

    /// A deck as 1.0.25 shipped it: the space bar last in the dock, the whole Blurt row on 常用, nothing of it on 更多.
    private func before(_ h: RemoteHost) -> Deck {
        var d = Deck.standard(for: h)
        let space = d.dock.remove(at: 5)
        d.dock.append(space)
        d.sections[0].slots = Array(d.sections[0].slots.prefix(18)) + blurtRow(h)
        d.sections[3].slots.removeLast(2)
        if h == .windows { d.sections[3].slots.append(KeySlot(.chord(RemoteChord([.command, .shift], "S"), cycle: false))) }    // Snip was there
        return d
    }

    func testTheDockEndsWithReturnByTheTalkKey() {
        for h in RemoteHost.allCases {
            let keys = Deck.standard(for: h).dock.suffix(4).compactMap { if case let .chord(c, _) = $0.action { c.key } else { nil } }
            XCTAssertEqual(keys, ["Space", "Escape", "Delete", "Return"], "\(h)")
        }
    }

    func testAnUntouchedDeckTakesTheNewDefaults() {
        for h in RemoteHost.allCases {
            var d = before(h)
            XCTAssertTrue(Deck.modernise(&d, for: h))
            let now = Deck.standard(for: h)
            XCTAssertEqual(d.dock.map(\.action), now.dock.map(\.action), "\(h)")
            XCTAssertEqual(d.sections.map { $0.slots.map(\.action) }, now.sections.map { $0.slots.map(\.action) }, "\(h)")
            XCTAssertFalse(Deck.modernise(&d, for: h), "once")
        }
    }

    func testAChangedDeckIsLeftAsItIs() {
        var d = before(.mac)
        d.dock.swapAt(0, 1)
        d.sections[0].slots.removeLast()
        let was = d
        XCTAssertFalse(Deck.modernise(&d, for: .mac))
        XCTAssertEqual(d, was)
    }

    func testTheThumbColumnFindsItsKeysWhereverTheyAre() {
        let d = Deck.standard.dock
        let t = Deck.thumbSlots(d)
        XCTAssertEqual([t.esc, t.delete, t.enter], [6, 7, 8])
        // an old dock, left as its owner had it: esc ⌫ ↩ are still the column, the space bar in the drawer
        var old = d
        old.append(old.remove(at: 5))
        let o = Deck.thumbSlots(old)
        XCTAssertEqual([o.esc, o.delete, o.enter], [5, 6, 7])
        // ⌫ taken out of the dock: what's in its place goes by the thumb
        var mine = d
        mine[7] = KeySlot(.chord(RemoteChord(.command, "Z"), cycle: false))
        let m = Deck.thumbSlots(mine)
        XCTAssertEqual([m.esc, m.delete, m.enter], [6, 7, 8])
    }

    func testEveryDefaultPageFitsFourRows() {
        for h in RemoteHost.allCases {
            for p in Deck.standard(for: h).sections { XCTAssertLessThanOrEqual(p.slots.count, p.columns * 4, "\(h) \(p.name)") }
        }
    }

    func testTemplatesAreEachComputersOwn() {
        for t in KeyTemplate.allCases {
            for h in RemoteHost.allCases {
                let s = Deck.section(t, for: h)
                XCTAssertFalse(s.slots.isEmpty)
                XCTAssertLessThanOrEqual(s.slots.count, 12, "two rows at most")
                if h != .mac {
                    XCTAssertFalse(s.slots.contains { if case let .chord(c, _) = $0.action { c.mods.contains(.command) && c.key != "P" } else { false } },
                                   "\(t) on \(h): Ctrl, not ⌘")
                }
            }
        }
        let project = KeySlot(.chord(RemoteChord(.command, "P"), cycle: false)).action
        XCTAssertTrue(Deck.section(.presenting, for: .windows).slots.contains { $0.action == project }, "Win+P")
        XCTAssertFalse(Deck.section(.presenting, for: .linux).slots.contains { $0.action == project })
    }
}
