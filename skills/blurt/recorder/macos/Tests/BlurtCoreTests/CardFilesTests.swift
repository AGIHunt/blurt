// BlurtCore/CardFiles.swift: what a shot card hands out (the picture with its note inside, the note as .md), which
// pasteboard item carries what (the drop into Claude that kept only the picture; per kind of app: CardDropTargetTests),
// and how long a taken card is kept.
import ImageIO
import XCTest
@testable import BlurtCore

final class CardFilesTests: XCTestCase {
    // MARK: names and the .md

    func testStemAndNames() {
        let utc = TimeZone(identifier: "UTC")!
        let wall = Date(timeIntervalSince1970: 1_792_766_412)          // 14:40:12 UTC
        let stem = CardFiles.stem(prefix: "截图", wall: wall, timeZone: utc)
        XCTAssertEqual(stem, "截图-144012")
        XCTAssertEqual(CardFiles.imageName(stem: stem), "截图-144012.png")
        XCTAssertEqual(CardFiles.noteName(stem: stem, noteWord: "备注"), "截图-144012-备注.md")
        XCTAssertEqual(CardFiles.noteName(stem: CardFiles.stem(prefix: "Screenshot", wall: wall, timeZone: utc), noteWord: "note"),
                       "Screenshot-144012-note.md")
        XCTAssertEqual(CardFiles.safeName("a/b:c\nd"), "a-b-c-d")
        XCTAssertEqual(CardFiles.safeName("  "), "capture")
    }

    /// v0.8.2: the .md is the note and nothing else — the image line was noise wherever the file was opened.
    func testMarkdownIsJustTheNote() {
        let md = CardFiles.markdown(note: "  结账按钮被挡住了\nthe banner covers it \n")
        XCTAssertEqual(md, "结账按钮被挡住了\nthe banner covers it\n")
        XCTAssertFalse(md.contains("!["))
        XCTAssertFalse(md.hasPrefix("#"))
        XCTAssertEqual(CardFiles.markdown(note: "x"), "x\n")
    }

    // MARK: the note inside the PNG

    func testPNGDescriptionRoundTripsAndImageIOReadsIt() throws {
        let png = try XCTUnwrap(Self.tinyPNG())
        let note = "结账按钮被挡住了\nthe banner covers it"
        let tagged = try XCTUnwrap(PNGText.withText(png, text: note))
        XCTAssertEqual(PNGText.text(tagged), note)
        // ImageIO (Preview, Finder's Get Info, every image pipeline on the Mac) sees it, and the picture still decodes
        let src = try XCTUnwrap(CGImageSourceCreateWithData(tagged as CFData, nil))
        XCTAssertNotNil(CGImageSourceCreateImageAtIndex(src, 0, nil))
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let pngProps = props?[kCGImagePropertyPNGDictionary] as? [CFString: Any]
        XCTAssertEqual(pngProps?[kCGImagePropertyPNGDescription] as? String, note)
        // written again (the note was edited): one Description, the new one
        let again = try XCTUnwrap(PNGText.withText(tagged, text: "edited"))
        XCTAssertEqual(PNGText.text(again), "edited")
        XCTAssertEqual(again.count, tagged.count - note.utf8.count + "edited".utf8.count, "the old chunk is gone")
        XCTAssertNil(PNGText.withText(Data("not a png".utf8), text: "x"))
        XCTAssertNil(PNGText.text(png))
    }

    func testCRC32() {
        XCTAssertEqual(PNGText.crc32(Array("IEND".utf8)), 0xAE42_6082)       // every PNG's last chunk
        XCTAssertEqual(PNGText.crc32(Array("123456789".utf8)), 0xCBF4_3926)
    }

    static func tinyPNG() -> Data? {
        guard let ctx = CGContext(data: nil, width: 4, height: 3, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 0.5, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 3))
        guard let img = ctx.makeImage() else { return nil }
        let d = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(d, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, img, nil)
        return CGImageDestinationFinalize(dest) ? d as Data : nil
    }

    // MARK: which item carries what

    let img = URL(fileURLWithPath: "/s/out/003/截图-144012.png")
    let img2 = URL(fileURLWithPath: "/s/out/004/截图-144230.png")
    let md = URL(fileURLWithPath: "/s/out/003/截图-144012-备注.md")
    func card(_ note: String?, image: URL? = URL(fileURLWithPath: "/s/out/003/截图-144012.png"), md: URL? = URL(fileURLWithPath: "/s/out/003/截图-144012-备注.md")) -> CardPasteboard.Card {
        CardPasteboard.Card(image: image, note: note, noteFile: md)
    }

    /// The reports (v0.8.1 Claude desktop, v0.8.5 DeepSeek in a browser): a web composer takes the files and drops
    /// the loose text and the HTML. A chat app now gets the picture as the only file — the note is pasted after it.
    func testDragOfASnapWithANoteIntoAChatApp() {
        XCTAssertEqual(CardPasteboard.drag(for: .chat, card: card("see the header\nthe logo overlaps")), [
            CardPasteboard.Item(file: img, image: img, tag: true),
            CardPasteboard.Item(tag: true),
        ])
    }

    func testDragTextIsSafeForATerminal() {
        let note = "ls\n\u{1B}[201~rm -rf ~\r"
        XCTAssertEqual(CardPasteboard.drag(for: .rich, card: card(note))[0].text, "ls · [201~rm -rf ~",
                       "the one-line form: the app that reads it may not be the one it lands in")
        for c in [DropClass.chat, .finder, .terminal] {
            XCTAssertTrue(CardPasteboard.drag(for: c, card: card(note), attachNote: true).allSatisfy { $0.text == nil && !$0.rich }, "\(c)")
        }
    }

    func testDragWithoutANote() {
        for c in DropClass.allCases {
            let first = CardPasteboard.drag(for: c, card: card(nil, md: nil))
            XCTAssertEqual(first.count, 1, "\(c)")
            XCTAssertEqual(first[0].file, img)
            XCTAssertTrue(first[0].tag)
            XCTAssertEqual(CardPasteboard.drag(for: c, card: card(" \n ", md: nil)), first, "\(c)")
        }
    }

    /// No .md (it couldn't be written): the second item is inert everywhere — and a terminal still gets only the
    /// picture's path.
    func testDragWhenTheNoteFileCouldNotBeWritten() {
        XCTAssertEqual(CardPasteboard.drag(for: .rich, card: card("words", md: nil)),
                       [CardPasteboard.Item(file: img, image: img, rich: true, text: "words", tag: true), CardPasteboard.Item(tag: true)])
        XCTAssertEqual(CardPasteboard.drag(for: .terminal, card: card("words", md: nil)),
                       [CardPasteboard.Item(file: img, tag: true), CardPasteboard.Item(tag: true)], "a terminal never gets the note as text")
    }

    /// A voice card is text that happened to be spoken: its words, no audio file, no .md — whatever the app.
    func testDragOfAVoiceCard() {
        for c in DropClass.allCases {
            XCTAssertEqual(CardPasteboard.drag(for: c, card: card("call Ana\nabout pricing", image: nil, md: nil)),
                           [CardPasteboard.Item(text: "call Ana · about pricing", tag: true)], "\(c)")
            XCTAssertEqual(CardPasteboard.drag(for: c, card: card("words", image: nil)), [CardPasteboard.Item(text: "words", tag: true)])
            XCTAssertEqual(CardPasteboard.drag(for: c, card: card(nil, image: nil, md: nil)), [])
        }
    }

    /// A click: one rich item — picture bytes, HTML / RTFD / RTF, the note with its line breaks — and no file URL (with
    /// one, WebKit's paste inserts nothing) and no .md.
    func testCopyOfOneCardIsOneRichItem() {
        XCTAssertEqual(CardPasteboard.copy([card(" see the header\nthe logo overlaps ")]), [
            CardPasteboard.Item(image: img, rich: true, text: "see the header\nthe logo overlaps"),
        ])
        XCTAssertEqual(CardPasteboard.copy([card(nil)]), [CardPasteboard.Item(image: img, rich: true)])
        XCTAssertEqual(CardPasteboard.copy([card("a\nb", image: nil, md: nil)]), [CardPasteboard.Item(text: "a\nb")], "a voice card: its words")
        XCTAssertEqual(CardPasteboard.copy([]), [])
        XCTAssertTrue(CardPasteboard.copy([card("x")]).allSatisfy { $0.file == nil })
    }

    /// Several cards (⌘-click, Copy All): one rich item with all of them in order, the notes separated by a blank line;
    /// every picture's file too (Chromium exposes one image/png at most, but every file), each on an item of its own —
    /// and nothing but the first item carries text (a text view would add it again).
    func testCopyOfSeveralCards() {
        let items = CardPasteboard.copy([card("first\nline two"), card("call Ana", image: nil, md: nil), card(nil, image: img2), card("last", image: img2)])
        XCTAssertEqual(items, [
            CardPasteboard.Item(file: img, image: img, rich: true, text: "first\nline two\n\ncall Ana\n\nlast"),
            CardPasteboard.Item(file: img2),
            CardPasteboard.Item(file: img2),
        ])
        XCTAssertTrue(items.dropFirst().allSatisfy { $0.text == nil && !$0.rich && $0.image == nil })
    }

    // MARK: the HTML

    func testHTMLIsPictureThenNoteForEachCard() {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let h = CardPasteboard.html([
            .init(image: ("image/png", png, 864, 540), note: "结账按钮被挡住了\n<b>not bold</b> & \"quoted\""),
            .init(image: nil, note: "  call Ana  "),
            .init(image: ("image/jpeg", Data([1, 2, 3]), 10, 20), note: nil),
        ])
        XCTAssertEqual(h, "<meta charset=\"utf-8\">"
            + "<p><img src=\"data:image/png;base64,\(png.base64EncodedString())\" width=\"864\" height=\"540\"></p>"
            + "<p>结账按钮被挡住了<br>&lt;b&gt;not bold&lt;/b&gt; &amp; &quot;quoted&quot;</p>"
            + "<p>call Ana</p>"
            + "<p><img src=\"data:image/jpeg;base64,AQID\" width=\"10\" height=\"20\"></p>")
        XCTAssertTrue(h.hasPrefix("<meta charset=\"utf-8\">"), "WebKit reads HTML without a charset as Latin-1")
    }

    // MARK: taken: 7 days

    func testTakenIsKeptSevenDays() {
        let t = 1_792_766_412.0
        XCTAssertTrue(TakenCaptures.isRecent(taken: t, now: t))
        XCTAssertTrue(TakenCaptures.isRecent(taken: t, now: t + 7 * 86400 - 1))
        XCTAssertFalse(TakenCaptures.isRecent(taken: t, now: t + 7 * 86400))
        XCTAssertTrue(TakenCaptures.isExpired(taken: t, now: t + 8 * 86400))
        XCTAssertEqual(TakenCaptures.daysLeft(taken: t, now: t), 7)
        XCTAssertEqual(TakenCaptures.daysLeft(taken: t, now: t + 6.5 * 86400), 1)
        XCTAssertEqual(TakenCaptures.daysLeft(taken: t, now: t + 9 * 86400), 0)
        // only the last day is worth a word on the row (the footer says 7 days for all)
        XCTAssertFalse(TakenCaptures.showsDaysLeft(7))
        XCTAssertTrue(TakenCaptures.showsDaysLeft(1))
    }

    // MARK: when it was taken (review of v0.9-fix2: a fixed "HH:mm", no day, ignored a 12-hour Mac)

    func testCaptureTimeFollowsTheLocaleAndSaysTheDayBeforeToday() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        // (anchored to the real day: DateFormatter's "Yesterday" is relative to the clock, not to `now`)
        let day = cal.startOfDay(for: Date())
        let now = cal.date(byAdding: .hour, value: 22, to: day)!
        let today = cal.date(byAdding: .minute, value: 19 * 60 + 3, to: day)!
        let yesterday = cal.date(byAdding: .day, value: -1, to: today)!
        let earlier = cal.date(byAdding: .day, value: -5, to: today)!
        let earlierDay = cal.component(.day, from: earlier), earlierMonth = cal.component(.month, from: earlier)
        let usMonth = { let f = DateFormatter(); f.locale = Locale(identifier: "en_US"); return f.shortMonthSymbols[earlierMonth - 1] }()
        let us = Locale(identifier: "en_US"), gb = Locale(identifier: "en_GB"), zh = Locale(identifier: "zh_Hans_CN")
        // (CardName.when: the user's 12/24-hour choice is passed in — a locale built from identifiers doesn't carry it)
        let t = CardName.when(taken: today, now: now, locale: us, uses24Hour: false, calendar: cal)
        XCTAssertTrue(t.contains("7:03") && t.contains("PM"), t)                 // a 12-hour Mac
        XCTAssertFalse(t.contains(usMonth), t)                                     // today: the time alone
        XCTAssertEqual(CardName.when(taken: today, now: now, locale: gb, uses24Hour: true, calendar: cal), "19:03")
        let y = CardName.when(taken: yesterday, now: now, locale: us, uses24Hour: false, calendar: cal)
        XCTAssertTrue(y.contains("Yesterday") && y.contains("7:03"), y)            // before today: the day too
        let e = CardName.when(taken: earlier, now: now, locale: us, uses24Hour: false, calendar: cal)
        XCTAssertTrue(e.contains(usMonth) && e.contains("\(earlierDay)") && e.contains("7:03"), e)
        let z = CardName.when(taken: earlier, now: now, locale: zh, uses24Hour: true, calendar: cal)
        XCTAssertTrue(z.contains("\(earlierMonth)月\(earlierDay)日"), z)
    }
}
