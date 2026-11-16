// BlurtCore/ScreenText.swift: copy text from the screen. The fixture (tests/fixtures/screen_text: page.html drawn at
// 2× by Chrome, cropped the way Bob's ⌥C demo was dragged — half lines, half characters, wrapped list items, check
// icons, a path broken at hyphens — plus code, a terminal, an English paragraph, a table and a nested list) runs
// through Vision here, so a macOS update that reads differently shows up as numbers, not a guess.
import AppKit
import CoreText
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
        var bobErr = 0.0, ourErr = 0.0, bobLayout = 0, ourLayout = 0, seconds = 0
        for r in rows {
            let name = r["name"] as! String, exp = r["expected"] as! String
            let img = try image(name)
            let (text, pieces, _, second) = try S.text(in: img)
            if second.ran { seconds += 1; print("second reading \(name): kept \(second.kept)") }
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
        print("screen text: second reading ran on \(seconds)/\(rows.count)")
    }

    /// Lines drawn the way a page draws them (black on white, the system font), for the languages the Chinese-and-English
    /// reading misses.
    private func drawn(_ lines: [String]) -> CGImage {
        let w = 620, h = lines.count * 48 + 24
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let font = CTFontCreateUIFontForLanguage(.system, 28, nil)!
        for (i, l) in lines.enumerated() {
            let a = NSAttributedString(string: l, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font,
                                                               NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)])
            ctx.textPosition = CGPoint(x: 12, y: CGFloat(h - 44 - i * 48))
            CTLineDraw(CTLineCreateWithAttributedString(a), ctx)
        }
        return ctx.makeImage()!
    }

    /// The founder's ⌥T on 「、貼り」 (2026-11-16): a crop of a few characters, drawn tight. Vision read 「，貼」 and the edge
    /// rule dropped what was left ("no text"); the second reading, enlarged, reads it.
    func testATinySelectionOfJapanese() throws {
        let r = try S.text(in: try image("ja_tiny_selection"))
        XCTAssertTrue(r.second.kept)
        XCTAssertTrue(r.text.hasSuffix("貼り"), r.text)
    }

    /// The same, drawn around 「貼り」 only: Chinese first read nothing, Vision's own detection nothing, Japanese first 「貼り」.
    func testTwoJapaneseCharacters() throws {
        let r = try S.text(in: try image("ja_two_chars"))
        XCTAssertEqual(r.text, "貼り")
    }

    /// A word or two in many languages, at two screen sizes (2026-11-16, "doesn't Japanese first make the others
    /// worse?"): the first reading stays Chinese and English, the others only win when they read clearly more. Measured:
    /// no Chinese word changed (two the first reading missed — 说明, 删除 — came back), English only gained (APl → API),
    /// Japanese, Korean, Thai went from nothing to right, Russian / Spanish / Vietnamese from look-alikes to right.
    func testSmallSelectionsInManyLanguages() throws {
        func drawn(_ l: String, size: CGFloat) -> CGImage {
            let font = CTFontCreateUIFontForLanguage(.system, size, nil)!
            let a = NSAttributedString(string: l, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font,
                                                               NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.1, alpha: 1)])
            let line = CTLineCreateWithAttributedString(a)
            let w = Int(CTLineGetTypographicBounds(line, nil, nil, nil)) + 16, h = Int(size * 1.8)
            let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.textPosition = CGPoint(x: 8, y: size * 0.5); CTLineDraw(line, ctx)
            return ctx.makeImage()!
        }
        let chinese = ["记录", "设置", "显示", "翻译记录", "听写历史", "粘贴", "取字与翻译", "复制", "确认", "该区域", "关闭", "删除", "发送", "说明"]
        let others = ["Copy", "Settings", "Cancel", "Save as", "API key", "README.md", "設定", "貼り", "はい", "コピー", "ありがとう",
                      "안녕", "설정", "Bonjour", "Привет", "Español", "Tiếng Việt", "สวัสดี"]
        var right = 0, all = 0
        for size in [26.0, 32.0] as [CGFloat] {
            for w in chinese + others {
                let img = drawn(w, size: size)
                let first = S.layout(try S.read(img), S.Gray(img)!)
                let r = try S.text(in: img)
                all += 1
                if r.text.filter({ !$0.isWhitespace }) == w.filter({ !$0.isWhitespace }) { right += 1 }
                if chinese.contains(w), !first.isEmpty { XCTAssertEqual(r.text, first, "a Chinese word read right first must stay: \(w)") }
            }
        }
        XCTAssertGreaterThanOrEqual(right, all - 2, "\(right)/\(all)")
    }

    func testOtherLanguagesGetTheSecondReading() throws {
        for (lines, expect) in [(["はい、そうです"], "はい、そうです"), (["会議は明日の午後3時からです"], "会議は明日の午後3時からです"),
                                (["회의는 내일 오후 3시입니다"], "회의는 내일 오후 3시입니다"),
                                (["設定を開いてください", "Release notes"], "設定を開いてください Release notes")] {
            let r = try S.text(in: drawn(lines))
            XCTAssertTrue(r.second.ran && r.second.kept, "\(lines)")
            let squash = { (t: String) in t.filter { !$0.isWhitespace } }
            XCTAssertEqual(squash(r.text), squash(expect), "\(lines)")
        }
        // Chinese and English: the first reading stands
        let zh = try S.text(in: drawn(["两类数据采集方案：网关直采"]))
        XCTAssertFalse(zh.second.kept && zh.text != "两类数据采集方案：网关直采")
        XCTAssertEqual(zh.text, "两类数据采集方案：网关直采")
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
