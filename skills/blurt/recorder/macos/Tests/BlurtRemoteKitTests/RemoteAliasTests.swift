// A paired device's or computer's name on this machine (docs/design/remote-1.1.md §6): kept beside the record, shown first, never in
// place of the id, and still there after the host says its own name again.
import XCTest
@testable import BlurtRemoteKit

final class RemoteAliasTests: XCTestCase {
    private func studio(_ name: String = "Studio", alias: String? = nil) -> RemoteComputer {
        var c = RemoteComputer(id: "host-1", deviceID: "viewer-1", name: name, port: 7000, addresses: ["192.168.1.20"], platform: "mac")
        c.alias = alias
        return c
    }

    func testWhatARenameKeeps() {
        XCTAssertEqual(RemoteAlias.typed("  Office Mac ", own: "Studio"), "Office Mac")
        // an empty field, or the device's own name, brings its own name back
        XCTAssertNil(RemoteAlias.typed("", own: "Studio"))
        XCTAssertNil(RemoteAlias.typed("   ", own: "Studio"))
        XCTAssertNil(RemoteAlias.typed("Studio", own: "Studio"))
        XCTAssertEqual(RemoteAlias.typed(String(repeating: "a", count: 100), own: "Studio")?.count, RemoteAlias.maxLength)
    }

    func testTheAliasIsShownFirst() {
        XCTAssertEqual(studio().shownName, "Studio")
        XCTAssertEqual(studio(alias: "Office Mac").shownName, "Office Mac")
        XCTAssertEqual(studio(alias: "").shownName, "Studio")
        XCTAssertEqual(RemoteAlias.shown("iPhone", alias: "Work phone"), "Work phone")
        XCTAssertEqual(RemoteAlias.shown("iPhone", alias: nil), "iPhone")
    }

    func testTheAliasSurvivesARefreshedName() {
        let kept = studio(alias: "Office Mac")
        // the host's hello (or DNS-SD) says its own name, maybe a new one, with new addresses
        var hello = studio("Studio Pro")
        hello.addresses = ["10.0.0.5"]
        let saved = kept.heard(hello)
        XCTAssertEqual(saved.alias, "Office Mac")
        XCTAssertEqual(saved.shownName, "Office Mac")
        XCTAssertEqual(saved.name, "Studio Pro")
        XCTAssertEqual(saved.addresses, ["10.0.0.5"])
        XCTAssertEqual(saved.id, kept.id)
        // a link that opened before the rename carries no alias: what it says never takes the alias away
        XCTAssertEqual(kept.heard(studio()).alias, "Office Mac")
        // and the alias cleared on this Mac stays cleared
        XCTAssertNil(studio().heard(studio("Studio Pro")).alias)
    }

    func testOldRecordsReadWithoutAnAlias() throws {
        // computers.json from before 1.1.0 has no alias
        let old = #"[{"id":"host-1","deviceID":"viewer-1","name":"Studio","port":7000,"addresses":[]}]"#
        let list = try JSONDecoder().decode([RemoteComputer].self, from: Data(old.utf8))
        XCTAssertNil(list[0].alias)
        XCTAssertEqual(list[0].shownName, "Studio")
        // and an alias is written beside the record, the id untouched
        let back = try JSONDecoder().decode(RemoteComputer.self, from: JSONEncoder().encode(studio(alias: "Office Mac")))
        XCTAssertEqual(back.alias, "Office Mac")
        XCTAssertEqual(back.id, "host-1")
    }
}
