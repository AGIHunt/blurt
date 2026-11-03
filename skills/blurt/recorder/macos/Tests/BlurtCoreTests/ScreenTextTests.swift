// BlurtCore/ScreenText.swift: copy text from the screen. The fixture (tests/fixtures/screen_text: page.html drawn at
// 2× by Chrome, cropped the way Bob's ⌥C demo was dragged — half lines, half characters, wrapped list items, check
// icons, a path broken at hyphens — plus code, a terminal, an English paragraph, a table and a nested list) runs
// through Vision here, so a macOS update that reads differently shows up as numbers, not a guess.
import AppKit
import XCTest
@testable import BlurtCore

final class ScreenTextTests: XCTestCase {
    typealias S = ScreenText

    static var fixtures: URL {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { u.deleteLastPathComponent() }
        return u.appendingPathComponent("tests/fixtures/screen_text")
    }

    /// Content: NFKC, bullets as one mark, no whitespace — what was read, not how it was spaced.
    static func content(_ s: String) -> [Character] {
        let n = s.precomposedStringWithCompatibilityMapping
        let lines = n.split(separator: "\n").map { l -> String in
            let t = l.trimmingCharacters(in: .whitespaces)
            if let f = t.first, "-•◦○◎。·▪●*".contains(f), t.dropFirst().first == " " { return "-" + t.dropFirst(2) }
            return t
        }
        return Array(lines.joined().filter { !$0.isWhitespace })
    }

    static func distance(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        var prev = Array(0...b.count)
        for (i, ca) in a.enumerated() {
            var cur = [i + 1]
            for (j, cb) in b.enumerated() { cur.append(min(prev[j + 1] + 1, cur[j] + 1, prev[j] + (ca == cb ? 0 : 1))) }
            prev = cur
        }
        return prev[b.count]
    }

    static func lines(_ s: String) -> [String] { s.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }

    func image(_ name: String) throws -> CGImage {
        let d = try Data(contentsOf: Self.fixtures.appendingPathComponent(name + ".png"))
        let src = try XCTUnwrap(CGImageSourceCreateWithData(d as CFData, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
    }

    func testFixtureAgainstBobsBehaviour() throws {
        let rows = try String(contentsOf: Self.fixtures.appendingPathComponent("cases.jsonl"), encoding: .utf8)
            .split(separator: "\n").compactMap { try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        XCTAssertGreaterThanOrEqual(rows.count, 17)
        var bobErr = 0.0, ourErr = 0.0, bobLayout = 0, ourLayout = 0
        for r in rows {
            let name = r["name"] as! String, exp = r["expected"] as! String
            let img = try image(name)
            let (text, pieces, _) = try S.text(in: img)
            let bob = pieces.map(\.text).joined(separator: "\n")      // Vision's lines as they come: what Bob pastes
            // the drafts the second pass's eval reads (screen_text.py eval): BLURT_WRITE_DRAFTS=1 swift test --filter ScreenText
            if ProcessInfo.processInfo.environment["BLURT_WRITE_DRAFTS"] == "1" {
                let d = Self.fixtures.appendingPathComponent("drafts")
                try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
                try text.write(to: d.appendingPathComponent(name + ".txt"), atomically: true, encoding: .utf8)
            }
            let e = Self.content(exp)
            let ob = Double(Self.distance(Self.content(bob), e)) / Double(e.count)
            let oo = Double(Self.distance(Self.content(text), e)) / Double(e.count)
            bobErr += ob; ourErr += oo
            if Self.lines(bob).count == Self.lines(exp).count { bobLayout += 1 }
            if Self.lines(text).count == Self.lines(exp).count { ourLayout += 1 } else { print("layout \(name):\n\(text)\n---") }
            XCTAssertLessThanOrEqual(oo, max(ob, 0.06), "\(name): \(text)")
        }
        let n = Double(rows.count)
        print(String(format: "screen text: Vision lines %.1f %% wrong, %d/%d laid out; ScreenText %.1f %%, %d/%d",
                     100 * bobErr / n, bobLayout, rows.count, 100 * ourErr / n, ourLayout, rows.count))
        XCTAssertLessThan(ourErr / n, 0.02)
        XCTAssertGreaterThanOrEqual(ourLayout, rows.count - 2)
    }

    func testEdgeCuts() throws {
        // the half line at the top (Vision reads it as 网关数掂米果…) and half 生 / 状 at the sides are left out
        XCTAssertEqual(try S.text(in: image("both_halfcut")).text, "/telemetry，不要落 Nginx 日志；数据库一路先直接读只读实例的表，不解析 binlog。")
        XCTAssertEqual(try S.text(in: image("half_chars")).text, "产库现")
        // a check icon list: "- " for the ◎ / • Vision reads
        XCTAssertEqual(try S.text(in: image("checks")).text, "- 整理结论成 Markdown 文件\n- 发送文件给用户")
    }

    func testMarkers() {
        XCTAssertEqual(S.marker("2.ordo_ai 的做法")?.text, "2. ordo_ai 的做法")
        XCTAssertEqual(S.marker("◎ 发送文件给用户")?.text, "- 发送文件给用户")
        XCTAssertNil(S.marker("10.5 GB resident"))
        XCTAssertNil(S.marker("e.g. this"))
        XCTAssertEqual(S.marker("a. first")?.text, "a. first")
    }

    func testJoinerAndPunctuation() {
        XCTAssertEqual(S.joiner("现有的", "/telemetry", cjkSpace: true), " ")
        XCTAssertEqual(S.joiner("a700-", "ecea", cjkSpace: true), "")
        XCTAssertEqual(S.joiner("只读实", "例，", cjkSpace: true), "")
        XCTAssertEqual(S.joiner("If we", "keep", cjkSpace: false), " ")
        XCTAssertEqual(S.asciiPunctuation("job （etl_nightly_v2） can"), "job (etl_nightly_v2) can")
        XCTAssertEqual(S.asciiPunctuation("不需要 DTS；但前端"), "不需要 DTS；但前端")
        XCTAssertEqual(S.asciiPunctuation("test_read_only.py：：test_lag"), "test_read_only.py::test_lag")
    }
}

extension ScreenTextTests {
    func testMissingListNumber() {
        XCTAssertEqual(S.fillMissingNumbers(["1. a", "ordo_ai 的做法", "3. c"]), ["1. a", "2. ordo_ai 的做法", "3. c"])
        XCTAssertEqual(S.fillMissingNumbers(["1. a", "note", "more", "2. c"]), ["1. a", "note", "more", "2. c"])
    }
}

extension ScreenTextTests {
    /// Found making the site demo (2026-10-29): a bullet Vision read with no space after it, a query string's "？".
    func testSolidBulletWithoutSpaceAndQueryQuestionMark() {
        XCTAssertEqual(S.marker("•日志已经附在工单里")?.text, "- 日志已经附在工单里")
        XCTAssertNil(S.marker("-1 是默认值"))
        XCTAssertNil(S.marker("·分隔"))
        XCTAssertEqual(S.asciiPunctuation("搜索页不认 ？sort=price"), "搜索页不认 ?sort=price")
        XCTAssertEqual(S.asciiPunctuation("你好？我在"), "你好？我在")
    }

    /// The bottom line cut in half (Vision's box for it stops short of the edge): left out.
    func testBottomHalfLineLeftOut() throws {
        let t = try S.text(in: image("en_bottom_cut")).text
        XCTAssertTrue(t.hasSuffix("- One owner for each item"), t)
    }
}
