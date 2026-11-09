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
